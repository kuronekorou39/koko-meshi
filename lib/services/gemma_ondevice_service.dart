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
    url:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm',
    approxSize: '約2.4GB',
    maxTokens: 2048,
  ),
  e4b(
    label: 'Gemma 4 E4B',
    note: '高精度・12GB+推奨（8GBでは不安定/OOM）',
    fileName: 'gemma-4-E4B-it.litertlm',
    url:
        'https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/main/gemma-4-E4B-it.litertlm',
    approxSize: '約3.4GB',
    // E4Bはメモリが厳しいのでコンテキスト窓(=KVキャッシュ)を絞る
    maxTokens: 1024,
  );

  const GemmaModelKind({
    required this.label,
    required this.note,
    required this.fileName,
    required this.url,
    required this.approxSize,
    required this.maxTokens,
  });

  final String label;
  final String note;
  final String fileName;
  final String url;
  final String approxSize;
  final int maxTokens;
}

enum GemmaInstallSource { localFile, network }

/// オンデバイス Gemma 4 (vision, LiteRT-LM) 実機PoC サービス。
/// E2B / E4B の両方を個別にインストールでき、どちらをロードするか選べる。
/// 現行 Edge Function (analyze-meal-photo) と同一プロンプトを使う。
class GemmaOnDeviceService {
  GemmaOnDeviceService._();
  static final GemmaOnDeviceService instance = GemmaOnDeviceService._();

  /// AI用に画像を縮小する長辺(px)。プリフィル遅延の支配要因なので小さめに。
  static const _maxImageSide = 768;

  static const _prompt = '''この写真を分析して、以下の情報をJSON形式で返してください。

必ず以下のJSON形式のみで回答してください（説明文は不要）:
{
  "menu_name": "メニュー名（日本語）",
  "estimated_price": 数値（円、整数）,
  "estimated_calories": 数値（kcal、整数）,
  "cuisine_genre": "料理ジャンル（例: ラーメン、寿司、カフェ、中華、イタリアン等）"
}

注意:
- menu_nameは具体的な料理名を推定してください（例: 「味噌ラーメン」「カルボナーラ」）
- 複数の料理が写っている場合はメインの料理名を記載してください
- 価格は日本の一般的な相場から推定してください
- カロリーは一般的な1人前の量から推定してください
- 料理が写っていない場合も必ず同じJSON形式で回答してください。写っているものを短く描写してmenu_nameに入れ、priceとcaloriesは0、cuisine_genreは「写真」としてください（例: menu_name「夕焼けの海」）''';

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
  Future<GemmaAnalysisResult> analyze(Uint8List originalBytes) async {
    if (_chat == null) {
      throw StateError('モデルが未ロードです');
    }
    final chat = _chat!;
    if (!_firstQuery) {
      await chat.clearHistory();
    }
    _firstQuery = false;

    final resized = await compute(_resizeJpeg, originalBytes);

    final sw = Stopwatch()..start();
    await chat.addQueryChunk(Message.withImages(
      text: _prompt,
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
    builder =
        localPath != null ? builder.fromFile(localPath) : builder.fromNetwork(kind.url);
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

  /// Edge Function の extractJson 相当。fenced/braces からJSONを救出。
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
}
