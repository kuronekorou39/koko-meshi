import 'package:shared_preferences/shared_preferences.dart';

/// AI解析のモード
/// - off: AI解析を使わない(手動入力のみ)
/// - onDevice: 端末内Gemma(E2B)で解析(オフライン・無料)
enum AiAnalysisMode { off, onDevice }

/// 本文フォント。日本語フォントはサブセット化されないため、同梱すると
/// 1ウェイトあたり数MBかかる。既定の BIZ UDゴシックだけを同梱している。
///
/// Zen角ゴシック New / M PLUS 2 / Noto Sans JP も比較したうえで不採用。
/// 比較のやり直しは tool/fetch_fonts.py のコメントを参照。
enum AppFont {
  bizUdGothic('BIZUDGothic', 'BIZ UDゴシック', 'ユニバーサルデザイン設計。可読性重視'),

  /// 端末既定(同梱フォントを使わない)。機種によって表示が変わる
  system(null, '端末の標準', '同梱フォントを使わず、機種ごとの標準で表示します');

  const AppFont(this.family, this.label, this.description);

  /// pubspec.yaml で宣言したファミリ名。null なら端末既定
  final String? family;
  final String label;
  final String description;
}

class AppSettings {
  AppSettings._();

  static SharedPreferences? _prefs;

  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
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

  // --- 本文フォント ---
  static const _keyFont = 'app_font';

  static AppFont get font {
    final name = _prefs?.getString(_keyFont);
    // 未設定や、廃止したファミリ名が保存されている場合は既定へ落とす
    return AppFont.values.firstWhere(
      (f) => f.name == name,
      orElse: () => AppFont.bizUdGothic,
    );
  }

  static Future<void> setFont(AppFont font) async {
    await _prefs?.setString(_keyFont, font.name);
  }
}
