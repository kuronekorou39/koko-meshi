import 'package:shared_preferences/shared_preferences.dart';

/// AI解析のモード
/// - off: AI解析を使わない(手動入力のみ)
/// - onDevice: 端末内Gemma(E2B)で解析(オフライン・無料)
enum AiAnalysisMode { off, onDevice }

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

  // --- AI解析モード(オフ / 端末内) ---
  static const _keyAiMode = 'ai_analysis_mode';

  static AiAnalysisMode get aiMode {
    switch (_prefs?.getString(_keyAiMode)) {
      case 'off':
        return AiAnalysisMode.off;
      default:
        // 'cloud'(廃止済み)や不明値を含め、既定は端末内AI
        return AiAnalysisMode.onDevice;
    }
  }

  static Future<void> setAiMode(AiAnalysisMode mode) async {
    await _prefs?.setString(_keyAiMode, mode.name);
  }
}
