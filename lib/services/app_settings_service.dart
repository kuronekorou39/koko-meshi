import 'package:shared_preferences/shared_preferences.dart';

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
}
