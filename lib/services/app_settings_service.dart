import 'package:shared_preferences/shared_preferences.dart';

/// AI解析のモード
/// - off: AI解析を使わない(手動入力のみ)
/// - onDevice: 端末内Gemma(E2B)で解析(オフライン・無料)
/// - cloud: クラウド(Edge Function経由)で解析(レガシー)
enum AiAnalysisMode { off, onDevice, cloud }

class AppSettings {
  AppSettings._();

  static SharedPreferences? _prefs;

  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  // --- カメラロールにも保存するか ---
  static const _keySaveToCameraRoll = 'save_to_camera_roll';

  static bool get saveToCameraRoll =>
      _prefs?.getBool(_keySaveToCameraRoll) ?? false;

  static Future<void> setSaveToCameraRoll(bool value) async {
    await _prefs?.setBool(_keySaveToCameraRoll, value);
  }

  // --- クラウド保存後にローカルのオリジナルを削除するか ---
  static const _keyDeleteAfterUpload = 'delete_after_upload';

  static bool get deleteAfterUpload =>
      _prefs?.getBool(_keyDeleteAfterUpload) ?? false;

  static Future<void> setDeleteAfterUpload(bool value) async {
    await _prefs?.setBool(_keyDeleteAfterUpload, value);
  }

  // --- AI解析モード(オフ / 端末内 / クラウド) ---
  static const _keyAiMode = 'ai_analysis_mode';

  static AiAnalysisMode get aiMode {
    switch (_prefs?.getString(_keyAiMode)) {
      case 'off':
        return AiAnalysisMode.off;
      case 'onDevice':
        return AiAnalysisMode.onDevice;
      case 'cloud':
        return AiAnalysisMode.cloud;
      default:
        return AiAnalysisMode.cloud; // 既定はクラウド(既存挙動を維持)
    }
  }

  static Future<void> setAiMode(AiAnalysisMode mode) async {
    await _prefs?.setString(_keyAiMode, mode.name);
  }
}
