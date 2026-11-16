import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/meal_log.dart';
import '../../models/meal_photo.dart';
import '../../providers/meal_providers.dart';
import '../../theme/app_theme.dart';
import '../../services/app_settings_service.dart';
import '../../services/meal_stats.dart';
import '../../services/update_service.dart';
import '../../services/photo_service.dart';
import '../../widgets/app_logo.dart';
import '../../widgets/coach_mark.dart';
import '../../widgets/meal_card.dart';
import '../../widgets/meal_grid_tile.dart';
import 'diet_advice_screen.dart';
import 'home_rail.dart';

enum ViewMode { list, grid, calendar }

/// カレンダーの日付セルに何を出すか。
/// 既定は記録の有無だけ(点)。数字を常に出すと読み取りづらいので、
/// 合計の「カロリー」「金額」をタップしたときだけその値に切り替える。
enum CalendarMetric { none, calories, price }

class TimelineTab extends ConsumerStatefulWidget {
  final VoidCallback? onLibraryPressed;

  /// 横向きのときのタブ切り替え。渡されたらヘッダを出さず、操作を左の列に並べる
  final HomeNav? nav;

  /// このタブが表に出ているか。裏に回っている間は案内を出さない
  final bool isActive;

  const TimelineTab({
    super.key,
    this.onLibraryPressed,
    this.nav,
    this.isActive = true,
  });

  @override
  ConsumerState<TimelineTab> createState() => _TimelineTabState();
}

class _TimelineTabState extends ConsumerState<TimelineTab> {
  ViewMode _viewMode = ViewMode.list;

  // カレンダー用
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay = DateTime.now();

  CalendarMetric _calendarMetric = CalendarMetric.none;

  /// カレンダーで選んでいた日。表示を切り替えたときに、その日のあたりから
  /// 見えるようにするために持ち越す(先頭へ飛ばされると、どこを見ていたのか
  /// 分からなくなるため)。
  DateTime? _pendingScrollDay;

  final _listController = ScrollController();
  final _gridController = ScrollController();

  /// 日付見出しの高さ。スクロール位置を数えるのに使うので、見出し側も
  /// この値で高さを固定して、計算と実際のレイアウトがずれないようにする。
  static const double _dateHeaderHeight = 44;

  /// 出ている新しいバージョン(無ければ null)
  AppUpdate? _update;

  /// 表示切替のボタン。案内で囲む相手
  final _viewModeKey = GlobalKey();

  /// 表示切替の案内を、いま出そうとしているか(二重に出さないため)
  bool _viewModeTipPending = false;

  @override
  void initState() {
    super.initState();
    _checkUpdate();
  }

  /// 記録ができたのに表示を切り替えたことが無い人へ、切り替えられることを
  /// 一度だけ教える。撮影や確認の画面が上に載っている間は出さず、一覧に
  /// 戻ってきてから出す(一覧を描き直すたびに呼ばれるので、次の機会に出る)。
  void _maybeShowViewModeTip() {
    if (!widget.isActive ||
        _viewModeTipPending ||
        AppSettings.isCoachTipSeen(CoachTip.viewMode)) {
      return;
    }
    _viewModeTipPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        if (!mounted || !widget.isActive) return;
        final shown = await showCoachMark(
          context,
          targetKey: _viewModeKey,
          message: '表示を切り替えられます。\nリスト・グリッド・カレンダーの3つから選べます。',
        );
        if (shown) await AppSettings.markCoachTipSeen(CoachTip.viewMode);
      } finally {
        _viewModeTipPending = false;
      }
    });
  }

  @override
  void dispose() {
    _listController.dispose();
    _gridController.dispose();
    super.dispose();
  }

  /// 切り替え直後にスクロール位置を合わせる。
  /// ビルド後でないとスクロール量が確定しないので1フレーム待つ。
  void _scrollToPendingDay(
      ScrollController controller, double Function(DateTime day) offsetFor) {
    final day = _pendingScrollDay;
    if (day == null) return;
    _pendingScrollDay = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!controller.hasClients) return;
      final max = controller.position.maxScrollExtent;
      controller.jumpTo(offsetFor(day).clamp(0.0, max));
    });
  }

  /// 新しいバージョンの知らせ。
  ///
  /// ストア配布ではないので、更新に気づく手段がアプリの中にしか無い。
  /// ただし記録の邪魔をしたいわけではないので、閉じたらその版では出さない。
  Future<void> _checkUpdate() async {
    final update = await UpdateService.check();
    if (mounted) setState(() => _update = update);
  }

  Widget _buildUpdateBanner() {
    final update = _update;
    if (update == null || update.dismissed) return const SizedBox.shrink();

    final tokens = KokoTokens.of(context);
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: scheme.primaryContainer,
      child: InkWell(
        onTap: () => launchUrl(
          Uri.parse(update.url),
          mode: LaunchMode.externalApplication,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
          child: Row(
            children: [
              Icon(Icons.system_update_alt,
                  size: 18, color: scheme.onPrimaryContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '新しいバージョン v${update.version} があります',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                color: tokens.textMuted,
                tooltip: '閉じる',
                onPressed: () async {
                  await UpdateService.dismiss(update.version);
                  if (mounted) setState(() => _update = null);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mealLogsAsync = ref.watch(mealLogsProvider);
    // 写真は記録ごとに問い合わせず、まとめて受け取る。読み直しの間も
    // 前の値を出し続けるので、解析が終わるたびに一覧が消えることはない
    final photosByLog = ref.watch(mealPhotosByLogProvider).valueOrNull;
    final nav = widget.nav;

    final actions = [
      RailAction(
        icon: Icons.photo_library_outlined,
        tooltip: 'ライブラリから追加',
        onTap: widget.onLibraryPressed ?? _defaultLibraryPressed,
      ),
      RailAction(
        key: _viewModeKey,
        icon: _viewModeIcon,
        tooltip: _viewModeLabel,
        onTap: _cycleViewMode,
      ),
      RailAction(
        icon: Icons.settings_outlined,
        tooltip: '設定',
        onTap: () => context.push('/settings'),
      ),
    ];

    return Scaffold(
      // 横向きは縦が足りないので、ヘッダを出さず操作を左の列へ移す
      appBar: nav != null
          ? null
          : AppBar(
              title: const AppLogo(),
              actions: [for (final a in actions) a.toIconButton()],
            ),
      body: Row(
        children: [
          if (nav != null) HomeRail(nav: nav, actions: actions),
          Expanded(
            child: SafeArea(
              left: false,
              bottom: false,
              child: Column(
                children: [
                  _buildUpdateBanner(),
                  Expanded(
                    child: mealLogsAsync.when(
                      skipLoadingOnReload: true,
                      loading: () =>
                          const Center(child: CircularProgressIndicator()),
                      error: (e, _) => Center(child: Text('エラー: $e')),
                      data: (mealLogs) {
                        if (mealLogs.isEmpty) return _buildEmptyState();
                        // 写真が揃う前に並べると、空のカードが一度出てしまう
                        if (photosByLog == null) {
                          return const Center(
                              child: CircularProgressIndicator());
                        }
                        _maybeShowViewModeTip();

                        return switch (_viewMode) {
                          ViewMode.list =>
                            _buildListView(mealLogs, photosByLog),
                          ViewMode.grid =>
                            _buildGridView(mealLogs, photosByLog),
                          ViewMode.calendar =>
                            _buildCalendarView(mealLogs, photosByLog),
                        };
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 横幅に入る列数。リストは写真を大きく見せたいので、広い画面でだけ並べる
  static int _listColumnsFor(double width) =>
      width < 600 ? 1 : (width / 340).floor().clamp(2, 4);

  static int _gridColumnsFor(double width) =>
      (width / 190).floor().clamp(2, 8);

  static const double _pagePadding = 16;
  static const double _tileSpacing = 12;

  IconData get _viewModeIcon => switch (_viewMode) {
    ViewMode.list => Icons.view_list_outlined,
    ViewMode.grid => Icons.grid_view_outlined,
    ViewMode.calendar => Icons.calendar_month_outlined,
  };

  String get _viewModeLabel => switch (_viewMode) {
    ViewMode.list => 'リスト表示',
    ViewMode.grid => 'グリッド表示',
    ViewMode.calendar => 'カレンダー表示',
  };

  Future<void> _defaultLibraryPressed() async {
    final photos = await PhotoService.pickPhotos();
    if (photos.isEmpty || !mounted) return;
    context.push('/capture', extra: {
      'photos': photos,
      'fromLibrary': true,
    });
  }

  void _cycleViewMode() {
    // 自分で切り替えられた人に、あとから案内を出さない
    AppSettings.markCoachTipSeen(CoachTip.viewMode);
    final leavingCalendar = _viewMode == ViewMode.calendar;
    setState(() {
      _viewMode = ViewMode.values[(_viewMode.index + 1) % ViewMode.values.length];
    });
    if (leavingCalendar && _selectedDay != null) {
      _pendingScrollDay = _selectedDay;
    }
  }

  // ─── リスト表示（日付でグルーピング） ───

  Widget _buildListView(
      List<MealLog> mealLogs, Map<String, List<MealPhoto>> photosByLog) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns = _listColumnsFor(width);

        // 日付見出し(DateTime)と、記録を列数ぶん束ねた行(List<MealLog>)を
        // 順に並べる。行ごとに作るので、何年ぶん溜まっても見えている分しか
        // 組み立てない
        final rows = <Object>[];
        DateTime? lastDay;
        for (final log in mealLogs) {
          final day =
              DateTime(log.eatenAt.year, log.eatenAt.month, log.eatenAt.day);
          final last = rows.isEmpty ? null : rows.last;
          if (lastDay == null || day != lastDay) {
            rows.add(day);
            rows.add(<MealLog>[log]);
            lastDay = day;
          } else if (last is List<MealLog> && last.length < columns) {
            last.add(log);
          } else {
            rows.add(<MealLog>[log]);
          }
        }

        _scrollToPendingDay(
          _listController,
          (day) => _listOffsetFor(day, rows, width, columns),
        );

        return RefreshIndicator(
          onRefresh: () => ref.read(mealLogsProvider.notifier).refresh(),
          child: ListView.builder(
            controller: _listController,
            padding: const EdgeInsets.only(bottom: 100),
            itemCount: rows.length,
            itemBuilder: (context, index) {
              final row = rows[index];
              if (row is DateTime) return _buildDateHeader(row);
              final logs = row as List<MealLog>;
              return Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: _pagePadding,
                  vertical: _tileSpacing / 2,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < columns; i++) ...[
                      if (i > 0) const SizedBox(width: _tileSpacing),
                      Expanded(
                        child: i < logs.length
                            ? MealCard(
                                key: ValueKey(logs[i].id),
                                mealLog: logs[i],
                                photos: photosByLog[logs[i].id] ?? const [],
                                onTap: () =>
                                    context.push('/meal/${logs[i].id}'),
                              )
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  /// [day] の見出しが先頭に来るスクロール量。
  /// 一覧は新しい順なので、その日以前で最初に現れる見出しで止める
  /// (選んだ日に記録が無くても近いところに着地する)。
  ///
  /// カードの高さは幅から縦横比(4:3)で決まり、見出しは高さを固定してあるので
  /// 積み上げれば正確に出せる。
  double _listOffsetFor(
      DateTime day, List<Object> rows, double width, int columns) {
    final target = DateTime(day.year, day.month, day.day);
    final cardWidth =
        (width - _pagePadding * 2 - _tileSpacing * (columns - 1)) / columns;
    final rowHeight = cardWidth * 3 / 4 + _tileSpacing;
    var offset = 0.0;
    for (final row in rows) {
      if (row is DateTime) {
        if (!row.isAfter(target)) return offset;
        offset += _dateHeaderHeight;
      } else {
        offset += rowHeight;
      }
    }
    return offset;
  }

  /// 「7月17日 木曜日」形式のセクション見出し。
  /// 高さは [_dateHeaderHeight] に固定する(スクロール位置の計算とずらさないため)。
  Widget _buildDateHeader(DateTime day) {
    return SizedBox(
      height: _dateHeaderHeight,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
        child: Text(
          DateFormat('M月d日 EEEE', 'ja').format(day),
          style: KokoTokens.of(context).sectionLabel,
        ),
      ),
    );
  }

  // ─── グリッド表示 ───

  Widget _buildGridView(
      List<MealLog> mealLogs, Map<String, List<MealPhoto>> photosByLog) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns = _gridColumnsFor(width);

        _scrollToPendingDay(
          _gridController,
          (day) => _gridOffsetFor(day, mealLogs, width, columns),
        );

        return RefreshIndicator(
          onRefresh: () => ref.read(mealLogsProvider.notifier).refresh(),
          child: _buildMealGrid(
            mealLogs,
            photosByLog,
            columns: columns,
            controller: _gridController,
          ),
        );
      },
    );
  }

  /// 正方形タイルのグリッド(グリッド表示と、カレンダーの下の一覧で使う)。
  /// テキストは写真の中(下部スクリム)に入れてあるので正方形でよい
  Widget _buildMealGrid(
    List<MealLog> logs,
    Map<String, List<MealPhoto>> photosByLog, {
    required int columns,
    ScrollController? controller,
  }) {
    return GridView.builder(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(_pagePadding, 8, _pagePadding, 100),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        crossAxisSpacing: _tileSpacing,
        mainAxisSpacing: _tileSpacing,
        childAspectRatio: 1,
      ),
      itemCount: logs.length,
      itemBuilder: (context, index) {
        final log = logs[index];
        return MealGridTile(
          key: ValueKey(log.id),
          mealLog: log,
          photos: photosByLog[log.id] ?? const [],
          onTap: () => context.push('/meal/${log.id}'),
        );
      },
    );
  }

  /// [day] 以前で最初に現れる記録の行が先頭に来るスクロール量。
  /// タイルは正方形なので、行数から直接出せる。
  double _gridOffsetFor(
      DateTime day, List<MealLog> logs, double width, int columns) {
    final target = DateTime(day.year, day.month, day.day);
    final index = logs.indexWhere((log) {
      final d =
          DateTime(log.eatenAt.year, log.eatenAt.month, log.eatenAt.day);
      return !d.isAfter(target);
    });
    if (index < 0) return 0;
    final tile =
        (width - _pagePadding * 2 - _tileSpacing * (columns - 1)) / columns;
    return 8 + (index ~/ columns) * (tile + _tileSpacing); // 上padding8
  }

  // ─── カレンダー表示 ───

  Widget _buildCalendarView(
      List<MealLog> mealLogs, Map<String, List<MealPhoto>> photosByLog) {
    // 日付ごとにグルーピング
    final grouped = <DateTime, List<MealLog>>{};
    for (final log in mealLogs) {
      final day = DateTime(log.eatenAt.year, log.eatenAt.month, log.eatenAt.day);
      grouped.putIfAbsent(day, () => []).add(log);
    }

    final selectedLogs = _selectedDay != null
        ? (grouped[DateTime(_selectedDay!.year, _selectedDay!.month, _selectedDay!.day)] ?? [])
        : <MealLog>[];

    final summary = MealStats.forMonth(_focusedDay, mealLogs, photosByLog);

    final calendar = TableCalendar<MealLog>(
          locale: 'ja_JP',
          firstDay: DateTime(2020),
          lastDay: DateTime(2030),
          focusedDay: _focusedDay,
          selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
          eventLoader: (day) {
            final key = DateTime(day.year, day.month, day.day);
            return grouped[key] ?? [];
          },
          onDaySelected: (selected, focused) {
            setState(() {
              _selectedDay = selected;
              _focusedDay = focused;
            });
          },
          onPageChanged: (focused) {
            // 上の月合計を切り替えるので setState が要る
            setState(() => _focusedDay = focused);
          },
          // 常に同じ高さの枠を返してセルの高さを一定に保つ(中身が
          // 点だったり数字だったりで行の高さが動かないように)
          calendarBuilders: CalendarBuilders<MealLog>(
            markerBuilder: (context, day, events) =>
                _buildDayMarker(day, events, summary),
          ),
          // table_calendarの既定文字色はテーマ非連動(ライトで白文字等)なので
          // 明示的にトークンから指定する
          calendarStyle: CalendarStyle(
            defaultTextStyle:
                TextStyle(fontSize: 14, color: Theme.of(context).colorScheme.onSurface),
            weekendTextStyle:
                TextStyle(fontSize: 14, color: Theme.of(context).colorScheme.onSurface),
            outsideTextStyle: TextStyle(
                fontSize: 14, color: KokoTokens.of(context).textFaint),
            disabledTextStyle: TextStyle(
                fontSize: 14, color: KokoTokens.of(context).textFaint),
            todayTextStyle: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.primary,
            ),
            selectedTextStyle: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.onSurface,
            ),
            markerDecoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary,
              shape: BoxShape.circle,
            ),
            markerSize: 6,
            markersMaxCount: 3,
            // 今日は文字色だけで示す(選択の輪郭と競合させない)
            todayDecoration: const BoxDecoration(shape: BoxShape.circle),
            // 選択は塗りつぶさず輪郭にする。塗ると下に出る数字が円の縁に
            // かぶって読めなくなるため
            selectedDecoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: Theme.of(context).colorScheme.primary,
                width: 2,
              ),
            ),
          ),
          daysOfWeekStyle: DaysOfWeekStyle(
            weekdayStyle: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: KokoTokens.of(context).textMuted,
            ),
            weekendStyle: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: KokoTokens.of(context).textMuted,
            ),
          ),
          headerStyle: HeaderStyle(
            formatButtonVisible: false,
            titleCentered: true,
            titleTextStyle: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.onSurface,
            ),
            leftChevronIcon: Icon(Icons.chevron_left,
                color: KokoTokens.of(context).textMuted),
            rightChevronIcon: Icon(Icons.chevron_right,
                color: KokoTokens.of(context).textMuted),
          ),
          calendarFormat: CalendarFormat.month,
          availableCalendarFormats: const {CalendarFormat.month: '月'},
    );

    // 選択した日の食事一覧。カレンダーの脇や下は狭いので、1件でも
    // 列に並べて写真を大きく見せる
    final dayList = selectedLogs.isEmpty
        ? Center(
            child: Text(
              _selectedDay != null
                  ? '${DateFormat('M月d日', 'ja').format(_selectedDay!)}の記録はありません'
                  : '日付をタップして記録を表示',
              style: TextStyle(color: KokoTokens.of(context).textFaint),
            ),
          )
        : LayoutBuilder(
            builder: (context, constraints) => _buildMealGrid(
              selectedLogs,
              photosByLog,
              columns: _gridColumnsFor(constraints.maxWidth),
            ),
          );

    return LayoutBuilder(
      builder: (context, constraints) {
        // 横長の画面では縦に積むと一覧の高さが残らないので、左右に分ける
        if (constraints.maxWidth > constraints.maxHeight) {
          return Row(
            children: [
              SizedBox(
                width: (constraints.maxWidth * 0.5).clamp(0.0, 420.0),
                child: SingleChildScrollView(
                  child: Column(
                    children: [_buildPeriodSummary(summary), calendar],
                  ),
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(child: dayList),
            ],
          );
        }
        return Column(
          children: [
            _buildPeriodSummary(summary),
            calendar,
            const Divider(height: 1),
            Expanded(child: dayList),
          ],
        );
      },
    );
  }

  /// 日付セルの下に出す表示。高さは常に固定。
  Widget _buildDayMarker(
      DateTime day, List<MealLog> events, PeriodSummary summary) {
    final tokens = KokoTokens.of(context);
    const height = 14.0;
    if (events.isEmpty) return const SizedBox(height: height);

    // 既定は「記録があるか」だけを点で示す
    if (_calendarMetric == CalendarMetric.none) {
      return SizedBox(
        height: height,
        child: Center(
          child: Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary,
              shape: BoxShape.circle,
            ),
          ),
        ),
      );
    }

    // 数字を出すモードでは点を混ぜない(点と数字が並ぶと読みづらいため)。
    // 0は0のまま出し、値が取れない日(前後の月の日など)は何も出さない
    final key = DateTime(day.year, day.month, day.day);
    final value = _calendarMetric == CalendarMetric.calories
        ? summary.caloriesByDay[key]
        : summary.priceByDay[key];
    if (value == null) return const SizedBox(height: height);

    final text = _calendarMetric == CalendarMetric.price
        ? '¥${NumberFormat('#,###').format(value)}'
        : NumberFormat('#,###').format(value);
    return SizedBox(
      height: height,
      child: Center(
        child: Text(
          text,
          style: tokens.numeral.copyWith(fontSize: 9, color: tokens.textMuted),
          maxLines: 1,
          overflow: TextOverflow.visible,
        ),
      ),
    );
  }

  /// 表示中の月の合計。カロリーと金額は写真側の推定を積んだもので、
  /// 記録側に手入力の合計があればそちらが優先される。
  ///
  /// 記録が無い月でも集計中でも**高さを変えない**。ここが伸縮すると下の
  /// カレンダーが上下にずれ、月を送るたびに日付の位置が動いてしまう。
  /// 高さを数値で固定するのではなく、常に同じ構造(2セル+補足1行+ボタン)を
  /// 組んで値だけを差し替える。こうすると文字サイズの設定にも追従する。
  Widget _buildPeriodSummary(PeriodSummary s) {
    final tokens = KokoTokens.of(context);
    final fmt = NumberFormat('#,###');

    final hasData = !s.isEmpty;
    const noValue = '—';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${s.start.month}月の合計', style: tokens.sectionLabel),
              const SizedBox(height: 10),
              IntrinsicHeight(
                child: Row(
                  children: [
                    Expanded(
                      child: _summaryCell(
                        label: 'カロリー',
                        value: hasData
                            ? '${fmt.format(s.totalCalories)} kcal'
                            : noValue,
                        metric: CalendarMetric.calories,
                        enabled: hasData,
                      ),
                    ),
                    VerticalDivider(
                        width: 12, thickness: 0.8, color: tokens.hairline),
                    Expanded(
                      child: _summaryCell(
                        label: '金額',
                        value:
                            hasData ? '¥${fmt.format(s.totalPrice)}' : noValue,
                        metric: CalendarMetric.price,
                        enabled: hasData,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Text(
                hasData ? _summaryFooter(s, fmt) : 'この月の記録はありません',
                style: TextStyle(
                  fontSize: 11.5,
                  color: hasData ? tokens.textMuted : tokens.textFaint,
                ),
                // 2行に折り返すと枠の高さが変わってしまうので1行に収める
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  // 記録が無い月は助言のもとが無いので押せなくする。
                  // ボタン自体は残す(消すと枠の高さが変わる)
                  onPressed: hasData
                      ? () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => DietAdviceScreen(
                                initialDay: _selectedDay ?? _focusedDay,
                              ),
                            ),
                          )
                      : null,
                  icon: const Icon(Icons.auto_awesome_outlined, size: 16),
                  label: const Text('食事のアドバイス'),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    minimumSize: const Size(0, 36),
                    textStyle: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 合計の下に出す補足行。値が無い項目は出さない
  /// (食事種別は未設定のまま使われることが多く、「外食0回」を常に出しても
  /// 意味が無いため)。
  String _summaryFooter(PeriodSummary s, NumberFormat fmt) {
    final parts = <String>['記録 ${s.recordedDays}日・${s.logCount}回'];
    if (s.eatingOutCount > 0) parts.add('外食 ${s.eatingOutCount}回');
    if (s.dailyAverageCalories != null) {
      parts.add('1日平均 ${fmt.format(s.dailyAverageCalories)}kcal');
    }
    if (s.totalPrice > 0 && s.logCount > 0) {
      parts.add('1食平均 ¥${fmt.format((s.totalPrice / s.logCount).round())}');
    }
    return parts.join('　');
  }

  /// 合計の1項目。タップするとカレンダーの日付セルがその値の表示に切り替わる
  /// (もう一度押すと解除)。[enabled] が false なら値が無いので押せない。
  Widget _summaryCell({
    required String label,
    required String value,
    required CalendarMetric metric,
    bool enabled = true,
  }) {
    final tokens = KokoTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final selected = enabled && _calendarMetric == metric;

    return Material(
      color: selected ? scheme.primaryContainer : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: enabled
            ? () => setState(() =>
                _calendarMetric = selected ? CalendarMetric.none : metric)
            : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  color:
                      selected ? scheme.onPrimaryContainer : tokens.textFaint,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                value,
                style: tokens.numeral.copyWith(
                  fontSize: 18,
                  color: selected
                      ? scheme.onPrimaryContainer
                      : enabled
                          ? null
                          : tokens.textFaint,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    final theme = Theme.of(context);
    final tokens = KokoTokens.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.restaurant_outlined, size: 56, color: tokens.textFaint),
            const SizedBox(height: 24),
            Text(
              'まだ記録がありません',
              style: theme.textTheme.titleMedium
                  ?.copyWith(color: tokens.textMuted),
            ),
            const SizedBox(height: 12),
            Text(
              '下の撮影ボタンから、最初の食事を記録できます。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: tokens.textFaint, height: 1.6),
            ),
          ],
        ),
      ),
    );
  }
}
