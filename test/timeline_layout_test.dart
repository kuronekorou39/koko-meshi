import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:koko_meshi/models/meal_log.dart';
import 'package:koko_meshi/models/meal_type.dart';
import 'package:koko_meshi/providers/meal_providers.dart';
import 'package:koko_meshi/screens/home/home_rail.dart';
import 'package:koko_meshi/screens/home/timeline_tab.dart';
import 'package:koko_meshi/services/app_settings_service.dart';
import 'package:koko_meshi/theme/app_theme.dart';
import 'package:koko_meshi/widgets/meal_card.dart';
import 'package:koko_meshi/widgets/meal_grid_tile.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table_calendar/table_calendar.dart';

class _FixedMealLogs extends MealLogsNotifier {
  _FixedMealLogs(this.logs);

  final List<MealLog> logs;

  @override
  Future<List<MealLog>> build() async => logs;
}

void main() {
  // 同じ日に5件、前の日に2件
  final today = DateTime.now();
  final logs = [
    for (var i = 0; i < 7; i++)
      MealLog(
        id: 'log$i',
        mealType: MealType.unset,
        eatenAt: DateTime(today.year, today.month, today.day, 12)
            .subtract(Duration(days: i < 5 ? 0 : 1, minutes: i)),
        createdAt: today,
      ),
  ];

  setUpAll(() async {
    await initializeDateFormatting('ja');
    await initializeDateFormatting('ja_JP');
    // 操作の案内は別のテストで見る。ここでは出さない
    SharedPreferences.setMockInitialValues({
      for (final tip in CoachTip.values) tip.prefsKey: true,
    });
    await AppSettings.init();
  });

  Future<void> pumpTimeline(
    WidgetTester tester,
    Size size, {
    required bool landscape,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mealLogsProvider.overrideWith(() => _FixedMealLogs(logs)),
          mealPhotosByLogProvider.overrideWith((ref) async => {}),
        ],
        child: MaterialApp(
          theme: AppTheme.light(null),
          home: TimelineTab(
            nav: landscape
                ? HomeNav(
                    tabIndex: 0,
                    onSelectTab: (_) {},
                    onCamera: () {},
                  )
                : null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('縦向きのリストは1列で、カードが横幅いっぱいに出る', (tester) async {
    await pumpTimeline(tester, const Size(400, 800), landscape: false);

    expect(find.byType(HomeRail), findsNothing);
    expect(tester.getSize(find.byType(MealCard).first).width, 400 - 32);
  });

  testWidgets('横向きのリストは2列になり、左の列のぶんだけ狭まる', (tester) async {
    await pumpTimeline(tester, const Size(900, 420), landscape: true);

    final contentWidth = 900 - HomeRail.width;
    expect(
      tester.getSize(find.byType(MealCard).first).width,
      (contentWidth - 32 - 12) / 2,
    );
    // 1行目に2枚が横に並ぶ
    final first = tester.getTopLeft(find.byType(MealCard).at(0));
    final second = tester.getTopLeft(find.byType(MealCard).at(1));
    expect(second.dy, first.dy);
    expect(second.dx, greaterThan(first.dx));
  });

  testWidgets('横向きでもグリッドとカレンダーがはみ出さずに出る', (tester) async {
    await pumpTimeline(tester, const Size(900, 420), landscape: true);

    // リスト → グリッド
    await tester.tap(find.byTooltip('リスト表示'));
    await tester.pumpAndSettle();
    expect(find.byType(MealGridTile), findsWidgets);
    // 836px に 190px のタイルなので4列
    final tiles = find.byType(MealGridTile);
    expect(
      tester.getTopLeft(tiles.at(3)).dy,
      tester.getTopLeft(tiles.at(0)).dy,
    );

    // グリッド → カレンダー。カレンダーと選んだ日の一覧が左右に並ぶ
    await tester.tap(find.byTooltip('グリッド表示'));
    await tester.pumpAndSettle();
    expect(find.byType(TableCalendar<MealLog>), findsOneWidget);
    expect(find.byType(MealGridTile), findsWidgets);
    expect(
      tester.getTopLeft(find.byType(MealGridTile).first).dx,
      greaterThan(tester.getTopRight(find.byType(TableCalendar<MealLog>)).dx),
    );
    expect(tester.takeException(), isNull);
  });
}
