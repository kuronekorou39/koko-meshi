import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koko_meshi/screens/settings/settings_screen.dart';
import 'package:koko_meshi/screens/settings/settings_widgets.dart';
import 'package:koko_meshi/services/app_settings_service.dart';
import 'package:koko_meshi/theme/app_theme.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    // DBは用意しない。件数や場所が読めなくても升は並ぶので、配置だけを見る
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init();
    PackageInfo.setMockInitialValues(
      appName: 'ココメシ',
      packageName: 'test',
      version: '0.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  Future<void> pumpSettings(WidgetTester tester, Size size) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(null),
          home: const SettingsScreen(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }

  // 縦向きの電話 / 横向きの電話 / 小さい電話 / タブレットの縦と横
  const sizes = {
    '縦向きの電話': Size(390, 800),
    '横向きの電話': Size(800, 360),
    '小さい電話の縦': Size(320, 520),
    '小さい電話の横': Size(520, 320),
    'タブレットの縦': Size(820, 1180),
    'タブレットの横': Size(1180, 820),
  };

  for (final entry in sizes.entries) {
    testWidgets('${entry.key}でも、送らずに全部の升が画面に収まる', (tester) async {
      await pumpSettings(tester, entry.value);

      // はみ出しがあればここで例外になっている
      expect(tester.takeException(), isNull);
      // 画面そのものは送れない
      expect(find.byType(Scrollable), findsNothing);

      // AI・記録・場所・フォント・遊び要素・位置情報・バックアップ
      final tiles = find.byType(BentoTile);
      expect(tiles, findsNWidgets(6 + FunFeature.values.length));
      final screen = Offset.zero & entry.value;
      for (final element in tiles.evaluate()) {
        final box = element.renderObject! as RenderBox;
        final rect = box.localToGlobal(Offset.zero) & box.size;
        expect(screen.contains(rect.topLeft), isTrue);
        expect(screen.contains(rect.bottomRight), isTrue);
      }
      expect(find.text('バックアップ'), findsOneWidget);
      expect(find.text('ココメシ v0.0.0'), findsOneWidget);
    });
  }
}
