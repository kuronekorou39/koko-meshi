import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../database/local_database.dart';
import '../models/meal_photo.dart';
import '../models/meal_type.dart';
import '../models/saved_place.dart';
import '../models/sensitive_mood.dart';
import 'analysis_foreground_service.dart';
import 'app_settings_service.dart';
import 'device_capability.dart';
import 'gemma_ondevice_service.dart';
import 'meal_stats.dart';
import 'photo_cache_service.dart';

class AiAnalysisService {
  /// AI解析結果がDBへ書き込まれるたびにインクリメントされる通知。
  /// 一覧のカード等がこれを購読して表示を自動更新する
  /// (書き込みは processing 遷移も含むため「解析中」表示も即時に反映される)。
  static final ValueNotifier<int> resultsVersion = ValueNotifier(0);

  /// バッチの排他制御。トリガーは複数ある(起動時/保存時/モデルDL完了時/
  /// 手動再解析)ため、並行実行すると同一チャットを同時に使って応答が壊れる。
  /// 実行中に再度呼ばれた場合は「終わったらもう一周」に畳み込む。
  static bool _batchRunning = false;
  static bool _rerunRequested = false;

  /// pending状態の写真をすべて解析する
  static Future<void> processPendingPhotos() async {
    if (_batchRunning) {
      _rerunRequested = true;
      return;
    }
    _batchRunning = true;
    try {
      do {
        _rerunRequested = false;
        await _runBatchOnce();
      } while (_rerunRequested);
    } finally {
      _batchRunning = false;
    }
  }

  /// AIが返したメニュー名を「1つの料理名への断定」に整形する純関数。
  /// プロンプト側でも断定を指示しているが、小型モデルは併記・推測表現を
  /// 混ぜることがあるため、保険としてDB保存前にここで刈り取る。
  ///
  /// 括弧の除去を先に行うのが重要。「パスタ（または麺料理）」のように括弧の
  /// **内側**に併記がある場合、先に「または」で切ると「パスタ（」と括弧が
  /// 開いたまま残ってしまう。
  ///
  /// (a)併記・推測を含む括弧を丸ごと除去 (b)残った「または」以降を除去
  /// (c)閉じられていない括弧を落とす (d)前後の空白と末尾の読点を除去
  /// (e)空になったら元の文字列を返す。
  static String sanitizeMenuName(String raw) {
    var s = raw;

    // (a) 推測・併記を含む括弧(全角/半角)を丸ごと除去。断定的な補足
    //     (「(大盛り)」等)は残したいので、括弧内が該当語を含む場合のみ削る
    const hedgeMarkers = [
      'おそらく', '恐らく', 'たぶん', '多分', 'かも', '思われ', '推定', '思う',
      'または', 'もしくは', '類する', 'のような',
    ];
    s = s.replaceAllMapped(
      RegExp(r'[（(]([^（()）]*)[)）]'),
      (m) {
        final inner = m.group(1) ?? '';
        return hedgeMarkers.any(inner.contains) ? '' : m.group(0)!;
      },
    );

    // (b) 括弧の外に残った併記を切り落とす
    for (final sep in const ['または', 'もしくは']) {
      final idx = s.indexOf(sep);
      if (idx >= 0) s = s.substring(0, idx);
    }

    // (c) 対応する閉じ括弧が無い開き括弧以降を落とす(保険)
    final open = s.lastIndexOf(RegExp(r'[（(]'));
    if (open >= 0 && !RegExp(r'[)）]').hasMatch(s.substring(open))) {
      s = s.substring(0, open);
    }

    // (d) 前後の空白を除去し、末尾に残った読点(、。)を落とす
    s = s.trim().replaceAll(RegExp(r'[、。]+$'), '').trim();

    // (e) 整形の結果すべて消えてしまったら、元の文字列(前後空白のみ除去)を使う
    return s.isEmpty ? raw.trim() : s;
  }

  static Future<void> _runBatchOnce() async {
    final mode = AppSettings.aiMode;
    if (mode == AiAnalysisMode.off) return; // AI解析オフ: 何もしない

    var photos = await LocalDatabase.getPendingAiPhotos();
    // failed・processing状態の写真もリトライ対象に含める
    final failedPhotos = await LocalDatabase.getFailedAiPhotos();
    final stuckPhotos = await LocalDatabase.getStuckAiPhotos();
    photos = [...photos, ...failedPhotos, ...stuckPhotos];
    if (photos.isEmpty) return;

    // 端末内AI(オンデバイスGemma)
    await _processOnDevice(photos);
  }

  // ─── オンデバイス解析 (端末内 Gemma E2B) ───

  /// 端末内E2Bでバッチ解析する。モデルを1回ロード→全件解析→解放(RAM節約)。
  static Future<void> _processOnDevice(List<MealPhoto> photos) async {
    // 32bit端末にはLiteRT-LMのライブラリが入らない。触れば
    // UnsatisfiedLinkError になるだけなので、その手前で降りる
    // (写真はpendingのまま残り、表示側が非対応として扱う)
    if (!DeviceCapability.onDeviceAi) {
      debugPrint('[AI] この端末は端末内AI非対応。解析しない');
      return;
    }

    final svc = GemmaOnDeviceService.instance;

    bool installed;
    try {
      installed = await svc.isInstalled(GemmaModelKind.e2b);
    } catch (e) {
      debugPrint('[AI] on-device init failed: $e');
      return;
    }
    if (!installed) {
      // モデル未DL: pendingのまま残す(設定画面でDLを促す)
      debugPrint('[AI] on-device model not installed; leaving photos pending');
      return;
    }

    // ここから実際に解析する。アプリがバックグラウンドへ回っても解析を完走
    // できるよう、フォアグラウンドサービスでプロセスを保ちつつ進捗を通知する。
    // (起動失敗は握られ、通知が出ないだけで解析自体は続行される)
    await AnalysisForegroundService.start(photos.length);
    try {
      try {
        await svc.load(GemmaModelKind.e2b);
      } catch (e) {
        debugPrint('[AI] on-device load failed: $e');
        return; // ロード失敗(OOM等)。pendingのまま(finallyでFGS停止)
      }

      // 撮影状況コンテキストの組み立てに使う(バッチ中は不変なので1回だけ読む)
      final savedPlaces = await LocalDatabase.getSavedPlaces();

      // 直後に別バッチが来たとき(連続撮影等)に毎回20秒のロードを繰り返さない
      // よう、解放は猶予つきで予約する
      _disposeTimer?.cancel();
      _disposeTimer = null;

      debugPrint('[AI] Processing ${photos.length} photos on-device (E2B)');
      try {
        var done = 0;
        for (final photo in photos) {
          await _analyzePhotoOnDevice(photo, svc, savedPlaces);
          done++;
          await AnalysisForegroundService.updateProgress(done, photos.length);
        }
      } finally {
        // バッチ後すぐには解放せず、アイドルが続いたら~3GBのRAMを空ける
        _disposeTimer?.cancel();
        _disposeTimer = Timer(_modelIdleTimeout, () {
          if (!_batchRunning && _modelHolds == 0) {
            debugPrint('[AI] idle timeout -> dispose on-device model');
            GemmaOnDeviceService.instance.disposeModel();
          }
        });
      }
    } finally {
      // バッチ終了(正常/失敗/例外いずれも)でFGSを停止し通知を消す
      await AnalysisForegroundService.stop();
    }
  }

  /// モデルをアイドル解放するまでの猶予
  static const _modelIdleTimeout = Duration(minutes: 3);
  static Timer? _disposeTimer;

  static const _onDeviceModelLabel = 'Gemma 4 E2B（端末内）';


  static Future<void> _analyzePhotoOnDevice(
    MealPhoto photo,
    GemmaOnDeviceService svc,
    List<SavedPlace> savedPlaces,
  ) async {
    await _writeAiResult(photo.id, aiStatus: 'processing');
    try {
      // ローカル実体が無い写真(クラウド後削除・復元レコード等)は
      // クラウドのオリジナルをDLして解析する(表示系と同じフォールバック)
      final path = await PhotoCacheService.getOriginalPath(
        localPath: photo.localPath,
        originalUrl: photo.originalUrl,
      );
      if (path == null) {
        final hasUrl = photo.originalUrl?.isNotEmpty ?? false;
        debugPrint('[AI] photo file unavailable (local+cloud) for ${photo.id}');
        await _writeAiResult(
          photo.id,
          aiStatus: 'failed',
          aiError: hasUrl
              ? '写真ファイルがローカルに無く、クラウドからの取得にも失敗しました。通信環境を確認して再解析してください'
              : '写真ファイルがローカルに無く、クラウドにも保存されていないため解析できません',
        );
        return;
      }
      final bytes = await File(path).readAsBytes();
      final context = await buildOnDeviceContext(photo, savedPlaces);
      final res = await svc.analyze(bytes, context: context);

      // センシティブ画像: 判定はモデル、タイトルもモデルに写真を踏まえて
      // 生成させ、口調(雰囲気)だけを決められたパターンから当てる。
      // 安全アラインメントが先に発火してJSONを返さず拒否文になるケースも
      // 同じ扱いにする(拒否応答自体を判定シグナルとして使う)
      if (res.imageType == 'sensitive' ||
          (res.parsed == null && _looksLikeSafetyRefusal(res.rawText))) {
        final mood = SensitiveMood.random();
        final title = await _generateSensitiveTitle(svc, mood);
        await _writeAiResult(
          photo.id,
          aiStatus: 'completed',
          aiMenuName: title,
          aiEstimatedPrice: 0,
          aiEstimatedCalories: 0,
          aiCuisineGenre: '写真',
          aiModel: _onDeviceModelLabel,
        );
        debugPrint(
            '[AI] on-device sensitive image -> ${mood.label}: $title');
        return;
      }

      if (res.parsed == null) {
        debugPrint('[AI] on-device parse failed for ${photo.id}');
        final head = res.rawText.trim();
        await _writeAiResult(
          photo.id,
          aiStatus: 'failed',
          aiError: 'AIの応答を解釈できませんでした'
              '${head.isEmpty ? '（応答が空）' : '（応答: ${head.length > 60 ? '${head.substring(0, 60)}…' : head}）'}',
        );
        return;
      }
      // JSONは読めたのに料理名だけ欠けている場合を completed にしない。
      // 一覧はメニュー名で解析結果を表すので、名前が無いまま「解析済み」に
      // すると、待ち表示も結果も出ない空のカードになって手が出せなくなる
      final rawName = res.menuName?.trim();
      if (rawName == null || rawName.isEmpty) {
        debugPrint('[AI] on-device result has no menu_name for ${photo.id}');
        await _writeAiResult(
          photo.id,
          aiStatus: 'failed',
          aiError: '料理名を判定できませんでした',
        );
        return;
      }
      await _writeAiResult(
        photo.id,
        aiStatus: 'completed',
        aiMenuName: sanitizeMenuName(rawName),
        aiEstimatedPrice: res.price,
        aiEstimatedCalories: res.calories,
        aiCuisineGenre: res.genre,
        aiModel: _onDeviceModelLabel,
      );
      debugPrint('[AI] on-device completed: ${res.menuName} '
          '(${res.inferenceMs}ms)');
    } catch (e) {
      debugPrint('[AI] on-device analyze error for ${photo.id}: $e');
      final msg = e.toString();
      await _writeAiResult(
        photo.id,
        aiStatus: 'failed',
        aiError:
            '解析中にエラーが発生しました: ${msg.length > 120 ? '${msg.substring(0, 120)}…' : msg}',
      );
    }
  }

  /// AI解析結果をDBへ書き戻す。解析中に写真の編集(localPath/サムネ/編集
  /// パラメータ等)が入っている可能性があるため、書き込み直前に最新レコードを
  /// 取得してAI関連フィールドだけを重ねる。渡さなかったフィールド(null)は
  /// copyWithが既存値を維持するので、状態遷移だけの更新でも他の列を壊さない。
  /// レコードが取得できなければ(削除済み等)何もしない。
  static Future<void> _writeAiResult(
    String photoId, {
    required String aiStatus,
    String? aiError,
    String? aiMenuName,
    int? aiEstimatedPrice,
    int? aiEstimatedCalories,
    String? aiCuisineGenre,
    String? aiModel,
  }) async {
    final current = await LocalDatabase.getMealPhoto(photoId);
    if (current == null) return;
    await LocalDatabase.updateMealPhoto(current.copyWith(
      aiStatus: aiStatus,
      // 失敗時は理由を保存し、それ以外の遷移では古い理由を消す
      aiError: aiError,
      clearAiError: aiStatus != 'failed',
      aiMenuName: aiMenuName,
      aiEstimatedPrice: aiEstimatedPrice,
      aiEstimatedCalories: aiEstimatedCalories,
      aiCuisineGenre: aiCuisineGenre,
      aiModel: aiModel,
    ));
    resultsVersion.value++;
  }

  /// 再解析キーワードの文字数上限。
  ///
  /// キーワードはエスケープせずプロンプトの先頭へ入れている。端末内で完結し
  /// 外部送信もツール実行も無いため乗っ取られても実害は無いが、長文を入れると
  /// コンテキスト窓(画像だけで1120トークン使う)から後続の指示が押し出されて
  /// 解析が失敗する。入力欄でも制限するが、バックアップ復元など画面を通らない
  /// 経路があるのでここでも切り詰める。
  static const int maxHintLength = 100;

  /// バッチ解析中か。解析ベンチが同じモデルを取り合わないための確認用。
  static bool get isBusy => _batchRunning;

  /// モデルを掴み続けたい処理の数。
  /// バッチ解析はアイドル3分でモデルを解放するタイマーを仕掛けるが、
  /// その後に解析ベンチや口調プレビューを始めると、実行の途中で解放されて
  /// 「モデルが未ロードです」で落ちる。走っている間はカウントを上げて防ぐ。
  static int _modelHolds = 0;

  /// [endModelHold] と必ず対で呼ぶこと(finallyで解放する)。
  static void beginModelHold() {
    _modelHolds++;
    _disposeTimer?.cancel();
    _disposeTimer = null;
  }

  static void endModelHold() {
    if (_modelHolds > 0) _modelHolds--;
  }

  /// オンデバイス解析用の撮影状況コンテキストを組み立てる。
  /// 生のGPS座標は端末内モデルには解釈できない(かつ誤ったコンテキストは
  /// 逆効果になる)ため入れず、確度の高い情報だけを渡す。
  static Future<String> buildOnDeviceContext(
    MealPhoto photo,
    List<SavedPlace> savedPlaces,
  ) async {
    final lines = <String>[];
    final mealLog = await LocalDatabase.getMealLog(photo.mealLogId);

    final mealType = mealLog?.mealType;
    if (mealType != null && mealType != MealType.unset) {
      lines.add('食事種別: ${mealType.label}');
    }

    final tag = mealLog?.locationTag;
    if (tag == 'home') {
      lines.add('撮影場所: 自宅');
    } else if (tag != null) {
      final place = savedPlaces.where((p) => p.id == tag).firstOrNull;
      if (place != null) lines.add('撮影場所: ${place.name}');
    }

    // 時間帯は常に確度が高いので必ず入れる(朝食/夕食で価格・料理の傾向が変わる)
    lines.add('時間帯: ${_timeBandLabel(photo.shotAt.hour)}');

    final buf = StringBuffer();
    // ユーザーが再解析時に入力したキーワードは最優先の手がかり。撮影状況より
    // 上に置き、料理特定の指針として明示する。
    // 複数行で入力されうるので箇条書きに開く(1行に連結すると末尾の指示句が
    // 2行目以降と切り離されて意味が通らなくなる)
    final rawHint = photo.aiHint ?? '';
    final hintLines = (rawHint.length > maxHintLength
            ? rawHint.substring(0, maxHintLength)
            : rawHint)
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (hintLines.isNotEmpty) {
      buf.writeln('ユーザーからのヒント（この料理を特定する最優先の手がかりとして扱うこと）:');
      for (final line in hintLines) {
        buf.writeln('- $line');
      }
    }
    buf.write('撮影状況:\n${lines.join('\n')}');
    return buf.toString();
  }

  /// 時間帯の区切りは集計側と共有する(ずれると解析の文脈と振り返りの
  /// グラフで違う「夜」を指してしまう)
  static String _timeBandLabel(int hour) => TimeBand.ofHour(hour).label;

  /// センシティブ画像用のタイトルを、同じ会話(画像が文脈に残っている)への
  /// 追い質問でモデル自身に生成させる。写真の内容を踏まえた文言に、指定の
  /// 雰囲気だけを当てる。モデルが拒否したりタイトルとして成立しない出力を
  /// 返した場合は、雰囲気だけの固定fallback文言に落とす。
  static Future<String> _generateSensitiveTitle(
    GemmaOnDeviceService svc,
    SensitiveMood mood,
  ) async {
    try {
      // 「露骨・下品な表現は避けて」という一文は入れていない。
      // ぼかす方向の口調では元々不要で、踏み込む口調には効かなかったうえ、
      // 全体を無難な語(「サプライズ」等)へ逃がして口調の差を潰していたため。
      final raw = await svc.followUpText(
          'この写真に、食事ログアプリ用のふざけたタイトルを付け直します。'
          '写真に写っているものを踏まえつつ、${mood.instruction}で、'
          '短いタイトルを1つだけ考えてください。'
          '「秘密」「神秘」「誘惑」「戯れ」のような、ぼかして格好つけた言葉は'
          '使わないでください。写っているものをそのまま指してください。'
          'JSONや説明文は不要です。タイトルの文字列だけを25文字以内で返してください。');
      final title = _cleanupGeneratedTitle(raw);
      if (title != null && !_looksLikeTitleRefusal(title)) {
        return title;
      }
    } catch (e) {
      debugPrint('[AI] sensitive title follow-up failed: $e');
    }
    return mood.fallback;
  }

  /// followUpTextの生テキストからタイトル1行を取り出す。
  /// 直前ターンのJSON形式に引きずられた場合はmenu_nameを救出する。
  static String? _cleanupGeneratedTitle(String raw) {
    var text = raw.trim();
    final jsonName =
        RegExp(r'"menu_name"\s*:\s*"([^"]+)"').firstMatch(text)?.group(1);
    if (jsonName != null) text = jsonName;
    text = text.replaceAll(RegExp(r'```[a-z]*'), '');
    final line = text
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.isNotEmpty, orElse: () => '');
    if (line.isEmpty) return null;
    final title = line
        .replaceAll(RegExp('^[「『"\']+'), '')
        .replaceAll(RegExp('[」』"\']+\$'), '')
        .trim();
    if (title.isEmpty || title.length > 40) return null;
    return title;
  }

  /// 生成されたタイトルが実は拒否文だったかの判定(タイトルは短文なので
  /// 一般的な謝罪・不能語も含めて広めに弾き、テンプレfallbackに落とす)
  static bool _looksLikeTitleRefusal(String title) {
    if (_looksLikeSafetyRefusal(title)) return true;
    const markers = ['できません', '申し訳', 'ごめんなさい', 'sorry', 'cannot'];
    final lower = title.toLowerCase();
    return markers.any((m) => lower.contains(m));
  }

  /// モデルがJSONを返さず安全アラインメントの拒否文を返したかの判定。
  /// 「料理を特定できません」のような一般的な解析不能文をセンシティブ扱い
  /// しないよう、センシティブ固有の語を必須にする(固有語のない失敗は
  /// 従来どおりfailed→再解析に落ちる)
  static bool _looksLikeSafetyRefusal(String text) {
    const markers = [
      '不適切',
      '性的',
      'アダルト',
      'わいせつ',
      '露骨',
      'ポリシー',
      'inappropriate',
      'explicit',
      'sexual',
      'adult content',
      'nsfw',
      'policy',
    ];
    final lower = text.toLowerCase();
    return markers.any((m) => lower.contains(m));
  }
}
