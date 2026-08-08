/// LiteRT-LM (.litertlm) on-device inference engine for flutter_gemma.
///
/// Opt-in. Add to pubspec.yaml and pass an instance to
/// `FlutterGemma.initialize(inferenceEngines: [LiteRtLmEngine()])`.
///
/// ```dart
/// import 'package:flutter_gemma/flutter_gemma.dart';
/// import 'package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart';
///
/// await FlutterGemma.initialize(inferenceEngines: [LiteRtLmEngine()]);
/// ```
library flutter_gemma_litertlm;

export 'src/litert_lm_engine_web.dart'
    if (dart.library.ffi) 'src/litert_lm_engine.dart';
// ココメシ vendorパッチ: visual token budget設定用のグローバル変数
export 'src/visual_token_budget.dart';
// ココメシ vendorパッチ: ネイティブのログをリリースビルドでも拾うためのフラグ
export 'src/native_log.dart';
// ココメシ vendorパッチ: 画像エンコーダだけ別のバックエンドに逃がすための設定
export 'src/vision_backend.dart';
