import 'package:flutter/material.dart';

/// ココメシのデザインシステム。
///
/// 方向性: 「和の食記録帳」。
/// - 温かい紙(生成り)の下地 + 漆(うるし)色のアクセント
/// - 影ではなくヘアライン(罫線)で区切るエディトリアル調
/// - 写真が主役。UIは一歩引いた無彩色寄りの暖色でまとめる
/// - グラデーション・紫・過剰な角丸・絵文字は使わない
///   (例外: 写真の上に文字を載せるための下部スクリムのみ PhotoScrim で使う。
///    面や区切りの装飾としてのグラデーションは引き続き使わない)
///
/// 使い方:
/// - 色は必ず `Theme.of(context).colorScheme` か [KokoTokens] から取る
/// - 数字(価格/カロリー)は [KokoTokens.numeral] をmergeして等幅数字にする
/// - セクション見出しは [KokoTokens.sectionLabel]
class AppTheme {
  AppTheme._();

  // ─── ライト(紙) ───
  static const _paper = Color(0xFFF7F2EA); // 下地(生成り)
  static const _paperLow = Color(0xFFFBF8F2);
  static const _paperDim = Color(0xFFEFE8DC); // 写真プレースホルダ等
  static const _ink = Color(0xFF231D15); // 墨(純黒は使わない)
  static const _inkMuted = Color(0xFF83786A);
  static const _inkFaint = Color(0xFFA99E8E);
  static const _hairline = Color(0xFFE8DFCF);
  static const _outline = Color(0xFFC9BDA8);

  static const _lacquer = Color(0xFFB0492A); // 漆: 主アクセント
  static const _lacquerDeep = Color(0xFF5B2110);
  static const _lacquerTint = Color(0xFFF7E2D8);
  static const _matcha = Color(0xFF69793F); // 抹茶: 副アクセント
  static const _matchaDeep = Color(0xFF2F3A16);
  static const _matchaTint = Color(0xFFE6EAD6);
  static const _karashi = Color(0xFF9E7C22); // 芥子: 第三アクセント
  static const _karashiDeep = Color(0xFF4C3A08);
  static const _karashiTint = Color(0xFFF3E7C8);
  static const _errorLight = Color(0xFFAB3B27);
  static const _errorTint = Color(0xFFF6DED8);

  // ─── ダーク(夜の食卓) ───
  static const _night = Color(0xFF17130E);
  static const _nightSurface = Color(0xFF211C15);
  static const _nightLow = Color(0xFF1C1712);
  static const _nightDim = Color(0xFF322B22);
  static const _nightInk = Color(0xFFECE4D7);
  static const _nightInkMuted = Color(0xFFA79C8B);
  static const _nightInkFaint = Color(0xFF7E7364);
  static const _nightHairline = Color(0xFF3B332A);
  static const _nightOutline = Color(0xFF5C5245);

  static const _lacquerNight = Color(0xFFDE8A62);
  static const _lacquerNightDeep = Color(0xFF44190A);
  static const _lacquerNightTint = Color(0xFF6F2D15);
  static const _matchaNight = Color(0xFFB4C287);
  static const _matchaNightDeep = Color(0xFF1C2506);
  static const _matchaNightTint = Color(0xFF41511F);
  static const _karashiNight = Color(0xFFD8B45E);
  static const _karashiNightDeep = Color(0xFF2C2000);
  static const _karashiNightTint = Color(0xFF6B5310);
  static const _errorNight = Color(0xFFE29181);

  /// [fontFamily] が null なら端末既定のフォントを使う(同梱フォントなし)
  static ThemeData light(String? fontFamily) => _build(
        fontFamily: fontFamily,
        brightness: Brightness.light,
        scheme: const ColorScheme.light(
          primary: _lacquer,
          onPrimary: Colors.white,
          primaryContainer: _lacquerTint,
          onPrimaryContainer: _lacquerDeep,
          secondary: _matcha,
          onSecondary: Colors.white,
          secondaryContainer: _matchaTint,
          onSecondaryContainer: _matchaDeep,
          tertiary: _karashi,
          onTertiary: Colors.white,
          tertiaryContainer: _karashiTint,
          onTertiaryContainer: _karashiDeep,
          error: _errorLight,
          onError: Colors.white,
          errorContainer: _errorTint,
          onErrorContainer: Color(0xFF57190D),
          surface: Colors.white,
          onSurface: _ink,
          onSurfaceVariant: _inkMuted,
          surfaceContainerLowest: Colors.white,
          surfaceContainerLow: _paperLow,
          surfaceContainer: _paperLow,
          surfaceContainerHigh: _paperDim,
          surfaceContainerHighest: _paperDim,
          outline: _outline,
          outlineVariant: _hairline,
          inverseSurface: _ink,
          onInverseSurface: _paper,
          inversePrimary: _lacquerNight,
          shadow: Colors.black,
          scrim: Colors.black,
        ),
        scaffold: _paper,
        tokens: const KokoTokens(
          hairline: _hairline,
          textMuted: _inkMuted,
          textFaint: _inkFaint,
          photoPlaceholder: _paperDim,
          success: Color(0xFF5E7C46),
          warning: Color(0xFF9C6D1E),
        ),
      );

  static ThemeData dark(String? fontFamily) => _build(
        fontFamily: fontFamily,
        brightness: Brightness.dark,
        scheme: const ColorScheme.dark(
          primary: _lacquerNight,
          onPrimary: _lacquerNightDeep,
          primaryContainer: _lacquerNightTint,
          onPrimaryContainer: Color(0xFFFFDBCB),
          secondary: _matchaNight,
          onSecondary: _matchaNightDeep,
          secondaryContainer: _matchaNightTint,
          onSecondaryContainer: Color(0xFFD0DEA2),
          tertiary: _karashiNight,
          onTertiary: _karashiNightDeep,
          tertiaryContainer: _karashiNightTint,
          onTertiaryContainer: Color(0xFFF6DFA6),
          error: _errorNight,
          onError: Color(0xFF541F10),
          errorContainer: Color(0xFF742F1C),
          onErrorContainer: Color(0xFFFFDAD1),
          surface: _nightSurface,
          onSurface: _nightInk,
          onSurfaceVariant: _nightInkMuted,
          surfaceContainerLowest: _night,
          surfaceContainerLow: _nightLow,
          surfaceContainer: _nightLow,
          surfaceContainerHigh: _nightDim,
          surfaceContainerHighest: _nightDim,
          outline: _nightOutline,
          outlineVariant: _nightHairline,
          inverseSurface: _nightInk,
          onInverseSurface: _night,
          inversePrimary: _lacquer,
          shadow: Colors.black,
          scrim: Colors.black,
        ),
        scaffold: _night,
        tokens: const KokoTokens(
          hairline: _nightHairline,
          textMuted: _nightInkMuted,
          textFaint: _nightInkFaint,
          photoPlaceholder: _nightDim,
          success: Color(0xFFA9C081),
          warning: Color(0xFFD8B45E),
        ),
      );

  static ThemeData _build({
    required String? fontFamily,
    required Brightness brightness,
    required ColorScheme scheme,
    required Color scaffold,
    required KokoTokens tokens,
  }) {
    final ink = scheme.onSurface;
    final muted = tokens.textMuted;

    // コンポーネント個別のTextStyleは textTheme を経由せず、そのまま
    // DefaultTextStyle として使われる。同梱フォントを効かせるには明示指定が要る
    // (fontFamily が null なら copyWith は何もしない = 端末既定のまま)
    TextStyle f(TextStyle s) => s.copyWith(fontFamily: fontFamily);

    final textTheme = Typography.material2021(platform: TargetPlatform.android)
        .black
        .apply(bodyColor: ink, displayColor: ink)
        .copyWith(
          titleLarge: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
              color: ink),
          titleMedium: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.1,
              color: ink),
          titleSmall: TextStyle(
              fontSize: 14, fontWeight: FontWeight.w600, color: ink),
          bodyLarge: TextStyle(fontSize: 16, height: 1.5, color: ink),
          bodyMedium: TextStyle(fontSize: 14, height: 1.45, color: ink),
          bodySmall: TextStyle(fontSize: 12, height: 1.4, color: muted),
          labelLarge: TextStyle(
              fontSize: 14, fontWeight: FontWeight.w600, color: ink),
          labelMedium: TextStyle(
              fontSize: 12, fontWeight: FontWeight.w600, color: muted),
          labelSmall: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.1,
              color: muted),
        )
        // copyWith で差し替えたスタイルにも効かせるため最後にまとめて適用する
        // (TextStyle.apply は null を「変更なし」として扱う)
        .apply(fontFamily: fontFamily);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: scaffold,
      fontFamily: fontFamily,
      textTheme: textTheme,
      splashFactory: InkSparkle.splashFactory,
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
      }),
      extensions: [tokens],
      appBarTheme: AppBarTheme(
        backgroundColor: scaffold,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: f(TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
          color: ink,
        )),
        iconTheme: IconThemeData(color: ink),
        actionsIconTheme: IconThemeData(color: muted),
      ),
      cardTheme: CardThemeData(
        color: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: tokens.hairline, width: 0.8),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 68,
        indicatorColor: scheme.primaryContainer,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? scheme.onPrimaryContainer
                : muted,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => f(TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: states.contains(WidgetState.selected) ? ink : muted,
          )),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 48),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: f(const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 48),
          foregroundColor: ink,
          side: BorderSide(color: scheme.outline, width: 1),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: f(const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: scheme.primary,
          textStyle: f(const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: brightness == Brightness.light
            ? Colors.white
            : scheme.surfaceContainerHigh,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: tokens.hairline, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.primary, width: 1.4),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.error, width: 1),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.error, width: 1.4),
        ),
        hintStyle: f(TextStyle(color: tokens.textFaint, fontSize: 14)),
        labelStyle: f(TextStyle(color: muted, fontSize: 14)),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        selectedColor: scheme.primaryContainer,
        side: BorderSide(color: tokens.hairline, width: 0.8),
        labelStyle: f(TextStyle(
            fontSize: 12.5, fontWeight: FontWeight.w600, color: ink)),
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        titleTextStyle: f(TextStyle(
            fontSize: 17, fontWeight: FontWeight.w700, color: ink)),
        contentTextStyle:
            f(TextStyle(fontSize: 14, height: 1.5, color: ink)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scaffold,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: scheme.outlineVariant,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: scheme.inverseSurface,
        contentTextStyle:
            f(TextStyle(fontSize: 14, color: scheme.onInverseSurface)),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      dividerTheme: DividerThemeData(
        color: tokens.hairline,
        thickness: 0.8,
        space: 1,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: muted,
        titleTextStyle: f(TextStyle(fontSize: 15, color: ink)),
        subtitleTextStyle: f(TextStyle(fontSize: 12.5, color: muted)),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          side: BorderSide(color: tokens.hairline, width: 1),
          selectedBackgroundColor: scheme.primaryContainer,
          selectedForegroundColor: scheme.onPrimaryContainer,
          textStyle: f(const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      progressIndicatorTheme:
          ProgressIndicatorThemeData(color: scheme.primary),
      tabBarTheme: TabBarThemeData(
        labelColor: ink,
        unselectedLabelColor: muted,
        indicatorColor: scheme.primary,
        dividerColor: tokens.hairline,
      ),
    );
  }
}

/// テーマに紐づく独自トークン(colorScheme に無い意味色とテキストスタイル)。
/// `KokoTokens.of(context)` で取得する。
class KokoTokens extends ThemeExtension<KokoTokens> {
  /// 罫線(カード枠・区切り)
  final Color hairline;

  /// 二次テキスト(補足・メタ情報)
  final Color textMuted;

  /// 三次テキスト(注釈・プレースホルダ)
  final Color textFaint;

  /// 写真読み込み中のプレースホルダ
  final Color photoPlaceholder;

  final Color success;
  final Color warning;

  const KokoTokens({
    required this.hairline,
    required this.textMuted,
    required this.textFaint,
    required this.photoPlaceholder,
    required this.success,
    required this.warning,
  });

  /// 価格・カロリー等の数字用: 等幅数字で桁がそろう。
  /// 例: `KokoTokens.of(context).numeral.copyWith(fontSize: 15)`
  TextStyle get numeral => const TextStyle(
        fontWeight: FontWeight.w600,
        letterSpacing: 0.1,
        fontFeatures: [FontFeature.tabularFigures()],
      );

  /// セクション見出し(「きょうの記録」等): 小さめ+トラッキング広め
  TextStyle get sectionLabel => TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.2,
        color: textMuted,
      );

  static KokoTokens of(BuildContext context) =>
      Theme.of(context).extension<KokoTokens>()!;

  @override
  KokoTokens copyWith({
    Color? hairline,
    Color? textMuted,
    Color? textFaint,
    Color? photoPlaceholder,
    Color? success,
    Color? warning,
  }) {
    return KokoTokens(
      hairline: hairline ?? this.hairline,
      textMuted: textMuted ?? this.textMuted,
      textFaint: textFaint ?? this.textFaint,
      photoPlaceholder: photoPlaceholder ?? this.photoPlaceholder,
      success: success ?? this.success,
      warning: warning ?? this.warning,
    );
  }

  @override
  KokoTokens lerp(KokoTokens? other, double t) {
    if (other == null) return this;
    return KokoTokens(
      hairline: Color.lerp(hairline, other.hairline, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      textFaint: Color.lerp(textFaint, other.textFaint, t)!,
      photoPlaceholder:
          Color.lerp(photoPlaceholder, other.photoPlaceholder, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
    );
  }
}
