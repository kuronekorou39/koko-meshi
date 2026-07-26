import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

/// PoC で切り替え可能なオンデバイスGemmaモデル。
enum GemmaModelKind {
  e2b(
    label: 'Gemma 4 E2B',
    note: '軽量・8GB端末で安定',
    fileName: 'gemma-4-E2B-it.litertlm',
    // resolve/mainではなくコミットにピン留め(上流が同名で差し替えても
    // expectedBytesとの食い違いで「毎回破損扱い」にならないように)
    url:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/9262660a1676eed6d0c477ab1a86344430854664/gemma-4-E2B-it.litertlm',
    approxSize: '約2.4GB',
    // HuggingFaceのlfs.size。DL完了後のサイズ検証に使う(過去にDL中断の
    // 追記破損ファイルが「インストール済み」になった実績があるため)
    expectedBytes: 2588147712,
    // visualTokenBudget 1120(画像だけで1120トークン)+プロンプト+出力が
    // 収まるように確保。KVキャッシュ増は2B級では数十MBで8GB端末でも許容
    maxTokens: 3072,
    // 画像1枚の実効解像度を決める(280≈384px相当が既定。1120≈768px相当で
    // 麺の質感など細部に有利。_maxImageSideの768px入力がほぼ1:1で活きる)
    visualTokenBudget: 1120,
  ),
  e4b(
    label: 'Gemma 4 E4B',
    note: '高精度・12GB+推奨（8GBでは不安定/OOM）',
    fileName: 'gemma-4-E4B-it.litertlm',
    // コミットピン留め(E2B側のコメント参照)
    url:
        'https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/f7ad3343bd6ebc9607f4dc3bc4f2398bd5749bc5/gemma-4-E4B-it.litertlm',
    approxSize: '約3.4GB',
    // HuggingFaceのlfs.size(E2B側のコメント参照)
    expectedBytes: 3659530240,
    // E4Bはメモリが厳しいのでコンテキスト窓(=KVキャッシュ)を絞る。ただし
    // 画像280+プロンプト+出力で~1200トークン使うため1024では溢れる
    maxTokens: 1536,
    // メモリ節約のため画像はネイティブ既定と同じ280に据え置く
    visualTokenBudget: 280,
  );

  const GemmaModelKind({
    required this.label,
    required this.note,
    required this.fileName,
    required this.url,
    required this.approxSize,
    required this.expectedBytes,
    required this.maxTokens,
    required this.visualTokenBudget,
  });

  final String label;
  final String note;
  final String fileName;
  final String url;
  final String approxSize;

  /// 正規モデルファイルの正確なバイト数(DL完了後のサイズ検証用)
  final int expectedBytes;

  final int maxTokens;
  final int visualTokenBudget;
}

enum GemmaInstallSource { localFile, network }

/// オンデバイス Gemma 4 (vision, LiteRT-LM) サービス。
/// E2B / E4B の両方を個別にインストールでき、どちらをロードするか選べる。
/// プロンプトは小型モデル向けの精度対策(ジャンル固定リスト・麺類の観察
/// ヒント)と image_type 判定を含む端末内解析専用版。
class GemmaOnDeviceService {
  GemmaOnDeviceService._();
  static final GemmaOnDeviceService instance = GemmaOnDeviceService._();

  /// AI用に画像を縮小する長辺(px)。プリフィル遅延の支配要因なので小さめに。
  static const _maxImageSide = 768;

  /// cuisine_genreの選択肢。自由記述より固定リストからの選択のほうが
  /// 小型モデルの細粒度分類に強い(MCQ化)。麺類は誤認しやすいので分割。
  static const _genreList =
      'ラーメン、うどん・そば、パスタ、ピザ、寿司、海鮮、和食、丼・定食、カレー、'
      '中華、イタリアン、フレンチ、洋食、焼肉・ステーキ、韓国料理、エスニック、'
      'ファストフード、パン・サンドイッチ、カフェ・スイーツ、居酒屋・鍋、'
      '弁当・惣菜、その他';

  /// 小型モデルに一発でJSONを書かせると、カロリーが「それらしい丸い数字」に
  /// 寄る(実測: 同じ550kcalを連発)。構成要素に分けて積み上げさせると値が
  /// 写真ごとに動くようになる。
  /// (JSONは `_extractJson` が前後の文から救い出すので、前置きがあってよい)
  ///
  /// 観察ステップ(主食・主菜・盛りを先に書かせる)も試したが、料理名の精度は
  /// 上がらず1枚あたり8秒→15秒になっただけだったので入れていない。
  ///
  /// 内訳の例は必ず抽象形にすること。具体的な料理名で例示すると、似た写真で
  /// 例文の中身と合計値をそのまま書き写してくる(実測: 鮭の例文を出したら
  /// 鮭の写真で例文の合計515kcalがそのまま返ってきた)。
  static const _prompt = '''この写真の料理を特定してください。

【1】内訳: 見えているものを分けて、それぞれのカロリーを積み上げる（1〜2行）
書き方) 〈見えた品〉=〈kcal〉, 〈見えた品〉=〈kcal〉 → 合計〈kcal〉

【2】そのうえでJSONを1つだけ出力する（すべて日本語）:
{
  "image_type": "food",
  "menu_name": "メニュー名（日本語）",
  "estimated_price": 数値（円、整数）,
  "estimated_calories": 数値（kcal、整数）,
  "cuisine_genre": "料理ジャンル"
}

image_typeは次の3つから1つ選んでください:
- "food": 料理・食べ物・飲み物が写っている
- "sensitive": 性的・アダルトな写真、裸や下着姿など露出の多い写真
- "not_food": 上記以外（風景・人物・物など）

注意:
- menu_nameは【1】で挙げた中身と矛盾しない、具体的な料理名にしてください（例: 「味噌ラーメン」「カルボナーラ」）
- menu_nameは必ず1つの料理名に断定してください。「AまたはB」のような併記や、「おそらく」「〜かもしれない」といった推測表現は禁止です。確信が持てない場合も、最も可能性が高い1つの名前だけを書いてください
- 「和風の肉料理」「琥珀色の飲み物」のような、料理名になっていない曖昧な説明は禁止です
- menu_nameに【1】の内訳をそのまま並べないでください。「鮭の塩焼き、ご飯、味噌汁」のような列挙ではなく、「焼き鮭定食」のように1つの料理名・献立名にまとめてください
- 麺料理は、麺の色と太さ・スープの有無・器の形・箸かフォークかを観察して、ラーメン/うどん/そば/パスタ/焼きそばを慎重に区別してください
- 複数の料理が写っている場合はメインの料理名を記載してください
- estimated_caloriesは【1】の合計と一致させてください。盛りが多ければ増やし、少なければ減らしてください
- estimated_priceは、その料理をその場で食べるとしたらいくら払うかを日本の相場で答えてください。撮影状況に食事種別があれば必ず従ってください（外食=店で出る値段 / テイクアウト・出前=中食の値段 / 自炊=材料費）
- cuisine_genreは次のリストから最も近いものを1つだけ選んでください: $_genreList
- 撮影状況（食事種別・場所・時間帯）が与えられている場合は、判断の参考にしてください
- image_typeが"food"でない場合は【1】を省き、JSONだけを返してください。写っているものを短く描写してmenu_nameに入れ、estimated_priceとestimated_caloriesは0、cuisine_genreは「写真」としてください（例: menu_name「夕焼けの海」）''';

  bool _initialized = false;
  InferenceModel? _model;
  InferenceChat? _chat;
  GemmaModelKind? _loadedKind;
  bool _firstQuery = true;

  GemmaModelKind? get loadedKind => _loadedKind;

  /// engine登録(1回だけ)
  Future<void> _ensureInit() async {
    if (_initialized) return;
    await FlutterGemma.initialize(inferenceEngines: [LiteRtLmEngine()]);
    _initialized = true;
  }

  /// 指定モデルが端末に既にインストール済みか
  Future<bool> isInstalled(GemmaModelKind kind) async {
    await _ensureInit();
    return FlutterGemma.isModelInstalled(kind.fileName);
  }

  /// 指定モデルをインストール(進捗0-100)。返り値はインストール元。
  /// 端末外部に adb push で事前配置された正規ファイルがあればそれを使い、
  /// 無ければネットワークDLにフォールバック(中断時に追記破損する既知問題に注意)。
  Future<GemmaInstallSource> install(
    GemmaModelKind kind, {
    required void Function(int) onProgress,
  }) async {
    await _ensureInit();
    return _ensureInstalledAndActive(kind, onProgress);
  }

  /// 指定モデルをロードしてチャットを準備。ロード所要msを返す。
  /// 別モデルがロード済みなら破棄してから切り替える。
  Future<int> load(GemmaModelKind kind) async {
    await _ensureInit();
    if (_loadedKind == kind && _chat != null) return 0;
    await _disposeModel();
    // アクティブモデルをこのkindに設定(インストール済みならDLはスキップされる)
    await _ensureInstalledAndActive(kind, null);
    // vendorパッチ経由で画像の実効解像度を設定(メッセージ送信時に反映される)
    litertLmVisualTokenBudget = kind.visualTokenBudget;
    final sw = Stopwatch()..start();
    _model = await FlutterGemma.getActiveModel(
      maxTokens: kind.maxTokens,
      preferredBackend: PreferredBackend.gpu,
      supportImage: true,
      maxNumImages: 1,
    );
    _chat = await _model!.createChat(supportImage: true);
    _loadedKind = kind;
    _firstQuery = true;
    sw.stop();
    return sw.elapsedMilliseconds;
  }

  /// 画像1枚を解析。生テキスト・パース結果・推論msを返す。
  /// [context] に撮影状況(食事種別・場所・時間帯など)を渡すとプロンプトに
  /// 前置される(精度に効く)。
  Future<GemmaAnalysisResult> analyze(
    Uint8List originalBytes, {
    String? context,
  }) async {
    if (_chat == null) {
      throw StateError('モデルが未ロードです');
    }
    final chat = _chat!;
    if (!_firstQuery) {
      await chat.clearHistory();
    }
    _firstQuery = false;

    final resized = await compute(_resizeJpeg, originalBytes);

    final prompt = (context == null || context.isEmpty)
        ? _prompt
        : '$context\n\n$_prompt';
    final sw = Stopwatch()..start();
    await chat.addQueryChunk(Message.withImages(
      text: prompt,
      imageBytes: [resized],
      isUser: true,
    ));
    final ModelResponse resp = await chat.generateChatResponse();
    sw.stop();

    final text = resp is TextResponse ? resp.token : resp.toString();
    return GemmaAnalysisResult(
      modelKind: _loadedKind,
      rawText: text,
      parsed: _extractJson(text),
      inferenceMs: sw.elapsedMilliseconds,
    );
  }

  /// 直前のanalyze()と同じ会話にテキストのみの追い質問を送り、生テキストを返す。
  /// 画像がチャット履歴に残っているため、モデルは写真の内容を踏まえて答える
  /// (センシティブ画像のタイトル雰囲気変換に使用)。履歴は次のanalyze()で
  /// クリアされるので、この呼び出しが後続の解析を汚すことはない。
  Future<String> followUpText(String prompt) async {
    final chat = _chat;
    if (chat == null) {
      throw StateError('モデルが未ロードです');
    }
    await chat.addQueryChunk(Message.text(text: prompt, isUser: true));
    final ModelResponse resp = await chat.generateChatResponse();
    return resp is TextResponse ? resp.token : resp.toString();
  }

  Future<void> _disposeModel() async {
    await _chat?.close();
    await _model?.close();
    _chat = null;
    _model = null;
    _loadedKind = null;
  }

  Future<void> disposeModel() => _disposeModel();

  /// バンドルしたテスト画像3枚でこの端末での動作を自己診断する。
  /// ギャラリー選択が不要なので、確実に「この端末で動くか・速度」を測れる。
  static const _selfTestAssets = [
    'assets/poc_test/meal1_curry_udon.jpg',
    'assets/poc_test/meal2_sushi.jpg',
    'assets/poc_test/meal3_pasta.jpg',
  ];

  Future<GemmaSelfTestResult> runSelfTest({
    void Function(int done, int total)? onProgress,
  }) async {
    if (_chat == null) throw StateError('モデルが未ロードです');
    final results = <GemmaAnalysisResult>[];
    for (var i = 0; i < _selfTestAssets.length; i++) {
      final data = await rootBundle.load(_selfTestAssets[i]);
      final res = await analyze(data.buffer.asUint8List());
      results.add(res);
      onProgress?.call(i + 1, _selfTestAssets.length);
    }
    return GemmaSelfTestResult(modelKind: _loadedKind, results: results);
  }

  // ─── ヘルパー ───

  Future<GemmaInstallSource> _ensureInstalledAndActive(
    GemmaModelKind kind,
    void Function(int)? onProgress,
  ) async {
    var builder = FlutterGemma.installModel(
      modelType: ModelType.gemma4,
      fileType: ModelFileType.litertlm,
    );
    final localPath = await _prePlacedModelPath(kind);
    // foreground: true → background_downloaderが通知+フォアグラウンドサービスで
    // DLする(非フォアグラウンドWorkManagerの9分タイムアウト→0%リトライ対策)。
    // 必要なPOST_NOTIFICATIONS権限はSmartDownloaderがDL開始前に自動要求する
    builder = localPath != null
        ? builder.fromFile(localPath)
        : builder.fromNetwork(kind.url, foreground: true);
    if (onProgress != null) {
      builder = builder.withProgress(onProgress);
    }
    await builder.install();
    return localPath != null ? GemmaInstallSource.localFile : GemmaInstallSource.network;
  }

  /// adb push で配置された正規モデルのパス(存在すれば)。
  /// アプリ自身の外部ファイルディレクトリ `/sdcard/Android/data/<pkg>/files` を見る。
  Future<String?> _prePlacedModelPath(GemmaModelKind kind) async {
    try {
      final dir = await getExternalStorageDirectory();
      if (dir == null) return null;
      final f = File('${dir.path}/${kind.fileName}');
      return await f.exists() ? f.path : null;
    } catch (_) {
      return null;
    }
  }

  /// 別isolateで長辺_maxImageSideにリサイズしJPEGバイトを返す
  static Uint8List _resizeJpeg(Uint8List bytes) {
    final image = img.decodeImage(bytes);
    if (image == null) return bytes;
    img.Image out = image;
    if (image.width > _maxImageSide || image.height > _maxImageSide) {
      out = image.width >= image.height
          ? img.copyResize(image, width: _maxImageSide)
          : img.copyResize(image, height: _maxImageSide);
    }
    return Uint8List.fromList(img.encodeJpg(out, quality: 85));
  }

  /// モデル出力の fenced/braces からJSONを救出する。
  static Map<String, dynamic>? _extractJson(String text) {
    if (text.isEmpty) return null;
    final fenced = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(text);
    if (fenced != null) {
      final m = _tryDecode(fenced.group(1)!.trim());
      if (m != null) return m;
    }
    final braces = RegExp(r'\{[\s\S]*\}').firstMatch(text);
    if (braces != null) {
      final raw = braces.group(0)!;
      final m = _tryDecode(raw);
      if (m != null) return m;
      final fixed = raw
          .replaceAll(RegExp(r',\s*\}'), '}')
          .replaceAll(RegExp(r',\s*\]'), ']');
      return _tryDecode(fixed);
    }
    return null;
  }

  static Map<String, dynamic>? _tryDecode(String s) {
    try {
      final v = jsonDecode(s);
      return v is Map<String, dynamic> ? v : null;
    } catch (_) {
      return null;
    }
  }
}

/// 端末での動作判定
enum GemmaDeviceVerdict { smooth, usable, slow, unstable }

class GemmaSelfTestResult {
  final GemmaModelKind? modelKind;
  final List<GemmaAnalysisResult> results;

  GemmaSelfTestResult({required this.modelKind, required this.results});

  int get count => results.length;
  int get parseOk => results.where((r) => r.parsed != null).length;
  double get avgSeconds => results.isEmpty
      ? 0
      : results.map((r) => r.inferenceMs).reduce((a, b) => a + b) /
          results.length /
          1000;

  /// 平均速度とパース成功から端末での実用度を判定
  GemmaDeviceVerdict get verdict {
    if (results.isEmpty || parseOk < count) return GemmaDeviceVerdict.unstable;
    final s = avgSeconds;
    if (s <= 12) return GemmaDeviceVerdict.smooth;
    if (s <= 25) return GemmaDeviceVerdict.usable;
    return GemmaDeviceVerdict.slow;
  }
}

class GemmaAnalysisResult {
  final GemmaModelKind? modelKind;
  final String rawText;
  final Map<String, dynamic>? parsed;
  final int inferenceMs;

  GemmaAnalysisResult({
    required this.modelKind,
    required this.rawText,
    required this.parsed,
    required this.inferenceMs,
  });

  String? get menuName => parsed?['menu_name'] as String?;
  int? get price => (parsed?['estimated_price'] as num?)?.toInt();
  int? get calories => (parsed?['estimated_calories'] as num?)?.toInt();
  String? get genre => parsed?['cuisine_genre'] as String?;

  /// 画像の種別判定: "food" / "sensitive" / "not_food"。
  /// 旧プロンプトの結果やモデルがフィールドを省いた場合はnull。
  String? get imageType => parsed?['image_type'] as String?;
}
