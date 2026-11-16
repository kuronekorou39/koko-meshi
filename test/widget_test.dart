import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:koko_meshi/app.dart';
import 'package:koko_meshi/screens/home/home_rail.dart';
import 'package:koko_meshi/widgets/side_gutter.dart';

void main() {
  /// 画面の大きさを決めてアプリを起こす(テストの既定は横長の 800x600)
  Future<void> pumpApp(WidgetTester tester, Size size) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const ProviderScope(child: KokoMeshiApp()),
    );
  }

  testWidgets('アプリが起動してヘッダにアプリ名が出る', (WidgetTester tester) async {
    await pumpApp(tester, const Size(400, 800));

    // ヘッダは文字ではなくロゴ画像なので、読み上げ用のラベルで確かめる。
    // 見た目を画像に替えてもアプリ名が伝わることが要件なので、ここを見る
    expect(find.bySemanticsLabel('ココメシ'), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(HomeRail), findsNothing);
  });

  testWidgets('横向きでナビゲーションバーが左に来ても、左の列はその外に出る',
      (WidgetTester tester) async {
    tester.view.padding = const FakeViewPadding(left: 48);
    await pumpApp(tester, const Size(800, 400));

    // バーの幅 + ゆとりのぶん右へずれ、列の中身がはみ出さない
    final rail = tester.getRect(find.byType(HomeRail));
    expect(rail.left, 48 + SideGutter.extra);
    expect(rail.width, HomeRail.width);
    final camera = tester.getRect(find.byTooltip('撮影'));
    expect(camera.left, greaterThanOrEqualTo(rail.left));
    expect(camera.right, lessThanOrEqualTo(rail.right));
    expect(tester.takeException(), isNull);
  });

  testWidgets('横向きではヘッダと下のタブをやめて、左の列に操作を並べる',
      (WidgetTester tester) async {
    await pumpApp(tester, const Size(800, 400));

    expect(find.byType(HomeRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byType(AppBar), findsNothing);
    // タブと撮影、その画面の操作が1列に入っている
    final rail = find.byType(HomeRail);
    for (final tooltip in ['記録', '撮影', 'マップ', 'ライブラリから追加', '設定']) {
      expect(
        find.descendant(of: rail, matching: find.byTooltip(tooltip)),
        findsOneWidget,
      );
    }
  });
}
