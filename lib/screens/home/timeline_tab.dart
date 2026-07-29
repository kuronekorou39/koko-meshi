import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../database/local_database.dart';
import '../../models/meal_log.dart';
import '../../models/meal_photo.dart';
import '../../providers/meal_providers.dart';
import '../../theme/app_theme.dart';
import '../../services/ai_analysis_service.dart';
import '../../services/meal_stats.dart';
import '../../services/update_service.dart';
import '../../services/photo_service.dart';
import '../../widgets/meal_card.dart';
import '../../widgets/meal_grid_tile.dart';
import 'diet_advice_screen.dart';

enum ViewMode { list, grid, calendar }

/// カレンダーの日付セルに何を出すか。
/// 既定は記録の有無だけ(点)。数字を常に出すと読み取りづらいので、
/// 合計の「カロリー」「金額」をタップしたときだけその値に切り替える。
enum CalendarMetric { none, calories, price }

class TimelineTab extends ConsumerStatefulWidget {
  final VoidCallback? onLibraryPressed;
  const TimelineTab({super.key, this.onLibraryPressed});

  @override
  ConsumerState<TimelineTab> createState() => _TimelineTabState();
}

class _TimelineTabState extends ConsumerState<TimelineTab> {
  ViewMode _viewMode = ViewMode.list;

  // カレンダー用
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay = DateTime.now();

  /// 集計用の写真(記録ID→写真)。カロリーと金額は写真側にしか無いので、
  /// カレンダー表示に切り替えたときにまとめて読む。
  Map<String, List<MealPhoto>>? _photosByLog;

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

  @override
  void initState() {
    super.initState();
    _checkUpdate();
    // カレンダーを開いたまま解析が終わったときに、日付セルの合計が
    // 古いままにならないようにする(カード側は各アイテムが購読している)
    AiAnalysisService.resultsVersion.addListener(_loadPhotosForStats);
  }

  @override
  void dispose() {
    AiAnalysisService.resultsVersion.removeListener(_loadPhotosForStats);
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

  /// 全写真を読むので、集計を使うカレンダー表示のときだけ走らせる
  Future<void> _loadPhotosForStats() async {
    if (_viewMode != ViewMode.calendar) return;
    final photos = await LocalDatabase.getAllMealPhotos();
    if (mounted) setState(() => _photosByLog = MealStats.groupPhotos(photos));
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

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'ココメシ',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
              ),
        ),
        actions: [
          // ライブラリから追加
          IconButton(
            icon: const Icon(Icons.photo_library_outlined),
            tooltip: 'ライブラリから追加',
            onPressed: widget.onLibraryPressed ?? _defaultLibraryPressed,
          ),
          // 表示モード切替
          IconButton(
            icon: Icon(_viewModeIcon),
            onPressed: _cycleViewMode,
            tooltip: _viewModeLabel,
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildUpdateBanner(),
          Expanded(
            child: mealLogsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('エラー: $e')),
              data: (mealLogs) {
                if (mealLogs.isEmpty) return _buildEmptyState();

                return switch (_viewMode) {
                  ViewMode.list => _buildListView(mealLogs),
                  ViewMode.grid => _buildGridView(mealLogs),
                  ViewMode.calendar => _buildCalendarView(mealLogs),
                };
              },
            ),
          ),
        ],
      ),
    );
  }

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
    final leavingCalendar = _viewMode == ViewMode.calendar;
    setState(() {
      _viewMode = ViewMode.values[(_viewMode.index + 1) % ViewMode.values.length];
    });
    // カレンダーの集計は写真が要る。切り替えるたびに読み直して、
    // 直前の解析結果も反映されるようにする
    if (_viewMode == ViewMode.calendar) {
      _loadPhotosForStats();
    } else if (leavingCalendar && _selectedDay != null) {
      _pendingScrollDay = _selectedDay;
    }
  }

  // ─── リスト表示（日付でグルーピング） ───

  Widget _buildListView(List<MealLog> mealLogs) {
    // 日付見出し(DateTime)と記録(MealLog)を順に並べたフラットなリストを作る
    final items = <Object>[];
    DateTime? lastDay;
    for (final log in mealLogs) {
      final day =
          DateTime(log.eatenAt.year, log.eatenAt.month, log.eatenAt.day);
      if (lastDay == null || day != lastDay) {
        items.add(day);
        lastDay = day;
      }
      items.add(log);
    }

    _scrollToPendingDay(
      _listController,
      (day) => _listOffsetFor(day, items, MediaQuery.sizeOf(context).width),
    );

    return RefreshIndicator(
      onRefresh: () => ref.read(mealLogsProvider.notifier).refresh(),
      child: ListView.builder(
        controller: _listController,
        padding: const EdgeInsets.only(bottom: 100),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          if (item is DateTime) return _buildDateHeader(item);
          final log = item as MealLog;
          return _MealLogItem(
            key: ValueKey(log.id),
            mealLog: log,
            onTap: () => context.push('/meal/${log.id}'),
          );
        },
      ),
    );
  }

  /// [day] の見出しが先頭に来るスクロール量。
  /// 一覧は新しい順なので、その日以前で最初に現れる見出しで止める
  /// (選んだ日に記録が無くても近いところに着地する)。
  ///
  /// カードの高さは幅から縦横比(4:3)で決まり、見出しは高さを固定してあるので
  /// 積み上げれば正確に出せる。
  double _listOffsetFor(DateTime day, List<Object> items, double width) {
    final target = DateTime(day.year, day.month, day.day);
    final cardHeight = (width - 32) * 3 / 4 + 12; // 上下のPadding6ぶんを足す
    var offset = 0.0;
    for (final item in items) {
      if (item is DateTime) {
        if (!item.isAfter(target)) return offset;
        offset += _dateHeaderHeight;
      } else {
        offset += cardHeight;
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

  Widget _buildGridView(List<MealLog> mealLogs) {
    _scrollToPendingDay(
      _gridController,
      (day) => _gridOffsetFor(day, mealLogs, MediaQuery.sizeOf(context).width),
    );

    return RefreshIndicator(
      onRefresh: () => ref.read(mealLogsProvider.notifier).refresh(),
      child: GridView.builder(
        controller: _gridController,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          // テキストを写真の中(下部スクリム)へ入れたので正方形タイルにする
          childAspectRatio: 1,
        ),
        itemCount: mealLogs.length,
        itemBuilder: (context, index) {
          return _MealLogGridItem(
            key: ValueKey(mealLogs[index].id),
            mealLog: mealLogs[index],
            onTap: () => context.push('/meal/${mealLogs[index].id}'),
          );
        },
      ),
    );
  }

  /// [day] 以前で最初に現れる記録の行が先頭に来るスクロール量。
  /// タイルは正方形2列なので、行数から直接出せる。
  double _gridOffsetFor(DateTime day, List<MealLog> logs, double width) {
    final target = DateTime(day.year, day.month, day.day);
    final index = logs.indexWhere((log) {
      final d =
          DateTime(log.eatenAt.year, log.eatenAt.month, log.eatenAt.day);
      return !d.isAfter(target);
    });
    if (index < 0) return 0;
    const spacing = 12.0;
    final tile = (width - 32 - spacing) / 2; // 左右padding16x2 + 列間
    return 8 + (index ~/ 2) * (tile + spacing); // 上padding8
  }

  // ─── カレンダー表示 ───

  Widget _buildCalendarView(List<MealLog> mealLogs) {
    // 日付ごとにグルーピング
    final grouped = <DateTime, List<MealLog>>{};
    for (final log in mealLogs) {
      final day = DateTime(log.eatenAt.year, log.eatenAt.month, log.eatenAt.day);
      grouped.putIfAbsent(day, () => []).add(log);
    }

    final selectedLogs = _selectedDay != null
        ? (grouped[DateTime(_selectedDay!.year, _selectedDay!.month, _selectedDay!.day)] ?? [])
        : <MealLog>[];

    final summary = MealStats.forMonth(
      _focusedDay,
      mealLogs,
      _photosByLog ?? const {},
    );

    return Column(
      children: [
        _buildPeriodSummary(summary),
        TableCalendar<MealLog>(
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
        ),
        const Divider(height: 1),
        // 選択した日の食事一覧
        Expanded(
          child: selectedLogs.isEmpty
              ? Center(
                  child: Text(
                    _selectedDay != null
                        ? '${DateFormat('M月d日', 'ja').format(_selectedDay!)}の記録はありません'
                        : '日付をタップして記録を表示',
                    style: TextStyle(color: KokoTokens.of(context).textFaint),
                  ),
                )
              // カレンダーの下は縦が狭いので、1件でも2列で並べて写真を大きく見せる
              : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: 1,
                  ),
                  itemCount: selectedLogs.length,
                  itemBuilder: (context, index) {
                    return _MealLogGridItem(
                      key: ValueKey(selectedLogs[index].id),
                      mealLog: selectedLogs[index],
                      onTap: () =>
                          context.push('/meal/${selectedLogs[index].id}'),
                    );
                  },
                ),
        ),
      ],
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

    final loading = _photosByLog == null;
    final hasData = !loading && !s.isEmpty;
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
                loading
                    ? '集計中…'
                    : hasData
                        ? _summaryFooter(s, fmt)
                        : 'この月の記録はありません',
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

/// リスト表示用: 各食事記録の写真を非同期で取得して表示
class _MealLogItem extends StatefulWidget {
  final MealLog mealLog;
  final VoidCallback onTap;

  const _MealLogItem({super.key, required this.mealLog, required this.onTap});

  @override
  State<_MealLogItem> createState() => _MealLogItemState();
}

class _MealLogItemState extends State<_MealLogItem> {
  List<MealPhoto>? _photos;

  @override
  void initState() {
    super.initState();
    _loadPhotos();
    // AI解析結果の書き込みを購読し、表示中カードを自動更新する
    // (「AI解析中」が結果に切り替わらないまま残るのを防ぐ)
    AiAnalysisService.resultsVersion.addListener(_loadPhotos);
  }

  @override
  void dispose() {
    AiAnalysisService.resultsVersion.removeListener(_loadPhotos);
    super.dispose();
  }

  Future<void> _loadPhotos() async {
    final photos = await LocalDatabase.getPhotosForMealLog(widget.mealLog.id);
    if (mounted) setState(() => _photos = photos);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: MealCard(
        mealLog: widget.mealLog,
        photos: _photos ?? [],
        onTap: widget.onTap,
      ),
    );
  }
}

/// グリッド表示用
class _MealLogGridItem extends StatefulWidget {
  final MealLog mealLog;
  final VoidCallback onTap;

  const _MealLogGridItem({super.key, required this.mealLog, required this.onTap});

  @override
  State<_MealLogGridItem> createState() => _MealLogGridItemState();
}

class _MealLogGridItemState extends State<_MealLogGridItem> {
  List<MealPhoto>? _photos;

  @override
  void initState() {
    super.initState();
    _loadPhotos();
    AiAnalysisService.resultsVersion.addListener(_loadPhotos);
  }

  @override
  void dispose() {
    AiAnalysisService.resultsVersion.removeListener(_loadPhotos);
    super.dispose();
  }

  Future<void> _loadPhotos() async {
    final photos = await LocalDatabase.getPhotosForMealLog(widget.mealLog.id);
    if (mounted) setState(() => _photos = photos);
  }

  @override
  Widget build(BuildContext context) {
    return MealGridTile(
      mealLog: widget.mealLog,
      photos: _photos ?? [],
      onTap: widget.onTap,
    );
  }
}
