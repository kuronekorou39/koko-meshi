import 'dart:io';

import 'package:flutter/foundation.dart';

import '../database/local_database.dart';
import '../models/meal_photo.dart';
import '../models/meal_type.dart';
import '../models/saved_place.dart';
import 'app_settings_service.dart';
import 'gemma_ondevice_service.dart';

class AiAnalysisService {
  /// pending状態の写真をすべて解析する
  static Future<void> processPendingPhotos() async {
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

    try {
      await svc.load(GemmaModelKind.e2b);
    } catch (e) {
      debugPrint('[AI] on-device load failed: $e');
      return; // ロード失敗(OOM等)。pendingのまま
    }

    // 撮影状況コンテキストの組み立てに使う(バッチ中は不変なので1回だけ読む)
    final savedPlaces = await LocalDatabase.getSavedPlaces();

    debugPrint('[AI] Processing ${photos.length} photos on-device (E2B)');
    try {
      for (final photo in photos) {
        await _analyzePhotoOnDevice(photo, svc, savedPlaces);
      }
    } finally {
      // バッチ後にモデルを解放して~3GBのRAMを空ける
      await svc.disposeModel();
    }
  }

  static const _onDeviceModelLabel = 'Gemma 4 E2B（端末内）';

  /// センシティブ画像(悪ふざけ入力)に付けるタイトルの「雰囲気」パターン。
  /// タイトル文言はモデルが写真を踏まえて生成する(モデルの結果を尊重)。
  /// ここで決めるのは口調・方向性だけで、写真ごとにハッシュで決定的に選ぶ。
  /// fallbackはモデルがタイトル生成を拒否した場合の、雰囲気だけの単独文言
  /// (拒否時は写真の描写も取れていないことが多いため内容には触れない)。
  static const List<({String label, String instruction, String fallback})>
      _sensitiveMoods = [
    (
      label: '妖艶',
      instruction: '妖艶で思わせぶりな、大人の色気を漂わせる口調',
      fallback: 'ふふ…これは…大人の時間ね…',
    ),
    (
      label: '興奮ツッコミ',
      instruction: '見た瞬間に思わず叫んでしまった勢いのツッコミ口調（「エッチ！！」のようなノリ）',
      fallback: 'って、エッチ！！',
    ),
    (
      label: '恥じらい',
      instruction: '恥ずかしくてどもりながら小声になってしまう口調',
      fallback: 'こ、これは…お見せできません…///',
    ),
    (
      label: 'てんぱり',
      instruction: '慌てふためいて完全にテンパっている口調',
      fallback: 'え、えっと、これ記録していいやつ！？',
    ),
    (
      label: '食いしん坊',
      instruction: '何を見ても食べ物に見える食いしん坊が、あくまで料理として大真面目に評価してしまう口調',
      fallback: '本日の一皿…カロリー計測不能',
    ),
  ];

  static Future<void> _analyzePhotoOnDevice(
    MealPhoto photo,
    GemmaOnDeviceService svc,
    List<SavedPlace> savedPlaces,
  ) async {
    await _writeAiResult(photo.id, aiStatus: 'processing');
    try {
      final file = File(photo.localPath);
      if (!await file.exists()) {
        await _writeAiResult(photo.id, aiStatus: 'failed');
        return;
      }
      final bytes = await file.readAsBytes();
      final context = await _buildOnDeviceContext(photo, savedPlaces);
      final res = await svc.analyze(bytes, context: context);

      // センシティブ画像: 判定はモデル、タイトルもモデルに写真を踏まえて
      // 生成させ、口調(雰囲気)だけを決められたパターンから当てる。
      // 安全アラインメントが先に発火してJSONを返さず拒否文になるケースも
      // 同じ扱いにする(拒否応答自体を判定シグナルとして使う)
      if (res.imageType == 'sensitive' ||
          (res.parsed == null && _looksLikeSafetyRefusal(res.rawText))) {
        final mood =
            _sensitiveMoods[photo.id.hashCode.abs() % _sensitiveMoods.length];
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
        await _writeAiResult(photo.id, aiStatus: 'failed');
        return;
      }
      await _writeAiResult(
        photo.id,
        aiStatus: 'completed',
        aiMenuName: res.menuName,
        aiEstimatedPrice: res.price,
        aiEstimatedCalories: res.calories,
        aiCuisineGenre: res.genre,
        aiModel: _onDeviceModelLabel,
      );
      debugPrint('[AI] on-device completed: ${res.menuName} '
          '(${res.inferenceMs}ms)');
    } catch (e) {
      debugPrint('[AI] on-device analyze error for ${photo.id}: $e');
      await _writeAiResult(photo.id, aiStatus: 'failed');
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
      aiMenuName: aiMenuName,
      aiEstimatedPrice: aiEstimatedPrice,
      aiEstimatedCalories: aiEstimatedCalories,
      aiCuisineGenre: aiCuisineGenre,
      aiModel: aiModel,
    ));
  }

  /// オンデバイス解析用の撮影状況コンテキストを組み立てる。
  /// 生のGPS座標は端末内モデルには解釈できない(かつ誤ったコンテキストは
  /// 逆効果になる)ため入れず、確度の高い情報だけを渡す。
  static Future<String> _buildOnDeviceContext(
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

    return '撮影状況:\n${lines.join('\n')}';
  }

  static String _timeBandLabel(int hour) {
    if (hour >= 4 && hour < 11) return '朝';
    if (hour >= 11 && hour < 16) return '昼';
    if (hour >= 16 && hour < 23) return '夜';
    return '深夜';
  }

  /// センシティブ画像用のタイトルを、同じ会話(画像が文脈に残っている)への
  /// 追い質問でモデル自身に生成させる。写真の内容を踏まえた文言に、指定の
  /// 雰囲気だけを当てる。モデルが拒否したりタイトルとして成立しない出力を
  /// 返した場合は、雰囲気だけの固定fallback文言に落とす。
  static Future<String> _generateSensitiveTitle(
    GemmaOnDeviceService svc,
    ({String label, String instruction, String fallback}) mood,
  ) async {
    try {
      final raw = await svc.followUpText(
          'この写真に、食事ログアプリ用のふざけたタイトルを付け直します。'
          '写真に写っているものを踏まえつつ、${mood.instruction}で、'
          '短いタイトルを1つだけ考えてください。'
          '露骨・下品な表現は避けて、冗談として笑える範囲にしてください。'
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
