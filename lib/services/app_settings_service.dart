import 'package:shared_preferences/shared_preferences.dart';

import 'map_style.dart';

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

/// 記録そのものには要らないが、あると楽しい機能。
///
/// 食事を記録するのに必要ではないので、既定では出さない。使いたい人だけが
/// 設定で足す。増やすときはここに追加すれば、設定画面にも項目が並ぶ。
enum FunFeature {
  trace(
    '軌跡の再生',
    '記録した場所の動きを、地図の上で再生します',
    'マップの右上に再生ボタンが出ます',
  );

  const FunFeature(this.label, this.description, this.hint);

  final String label;
  final String description;

  /// どこに出るのかの案内。オンにしたあと迷わせないため
  final String hint;
}

/// 初めての人に一度だけ見せる操作の案内。
/// 増やしすぎると読まれなくなるので、無いと先へ進めないものだけにする。
enum CoachTip {
  /// 記録がまだ無いときに、撮影ボタンを教える
  camera('coach_tip_camera_seen'),

  /// 記録ができたあとに、表示の切り替えを教える
  viewMode('coach_tip_view_mode_seen');

  const CoachTip(this.prefsKey);

  final String prefsKey;
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

  // --- 地図に出すラベル ---
  static const _keyMapLabels = 'map_label_layers';

  /// 既定は空(まっさらな地図)。自分の記録のピンを主役にするため
  static Set<MapLabelLayer> get mapLabelLayers {
    final names = _prefs?.getStringList(_keyMapLabels);
    if (names == null) return const {};
    return names
        .map((n) =>
            MapLabelLayer.values.where((l) => l.name == n).firstOrNull)
        .whereType<MapLabelLayer>()
        .toSet();
  }

  static Future<void> setMapLabelLayers(Set<MapLabelLayer> layers) async {
    await _prefs?.setStringList(
      _keyMapLabels,
      layers.map((l) => l.name).toList(),
    );
  }

  // --- 遊び要素 ---
  static const _keyFunFeatures = 'fun_features';

  /// 有効にしている遊び要素。既定は空(どれも出さない)
  static Set<FunFeature> get funFeatures {
    final names = _prefs?.getStringList(_keyFunFeatures);
    if (names == null) return const {};
    return names
        .map((n) => FunFeature.values.where((f) => f.name == n).firstOrNull)
        .whereType<FunFeature>()
        .toSet();
  }

  static bool isFunEnabled(FunFeature feature) =>
      funFeatures.contains(feature);

  static Future<void> setFunFeature(FunFeature feature, bool enabled) async {
    final next = {...funFeatures};
    if (enabled) {
      next.add(feature);
    } else {
      next.remove(feature);
    }
    await _prefs?.setStringList(
      _keyFunFeatures,
      next.map((f) => f.name).toList(),
    );
  }

  // --- 書き出す写真に位置情報を含めるか ---
  static const _keyExportExifGps = 'export_exif_gps';

  /// カメラロールへ保存する写真に、記録の位置情報をEXIFで書き込むか。
  ///
  /// 既定はオフ。書き出した写真は端末の外に出ていく(共有・バックアップ)ので、
  /// 食べた場所が一緒に付いていくことを選んでいない利用者に黙って付けない。
  static bool get exportExifGps => _prefs?.getBool(_keyExportExifGps) ?? false;

  static Future<void> setExportExifGps(bool enabled) async {
    await _prefs?.setBool(_keyExportExifGps, enabled);
  }

  // --- 操作の案内 ---

  /// その案内をもう見せたか。一度見せたら二度と出さない
  static bool isCoachTipSeen(CoachTip tip) =>
      _prefs?.getBool(tip.prefsKey) ?? false;

  static Future<void> markCoachTipSeen(CoachTip tip) async {
    await _prefs?.setBool(tip.prefsKey, true);
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
