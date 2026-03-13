import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:table_calendar/table_calendar.dart';

import '../../database/local_database.dart';
import '../../models/meal_log.dart';
import '../../models/meal_photo.dart';
import '../../providers/meal_providers.dart';
import '../../widgets/meal_card.dart';
import '../../widgets/meal_grid_tile.dart';

enum ViewMode { list, grid, calendar }

class TimelineTab extends ConsumerStatefulWidget {
  const TimelineTab({super.key});

  @override
  ConsumerState<TimelineTab> createState() => _TimelineTabState();
}

class _TimelineTabState extends ConsumerState<TimelineTab> {
  ViewMode _viewMode = ViewMode.list;

  // カレンダー用
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay = DateTime.now();

  @override
  Widget build(BuildContext context) {
    final mealLogsAsync = ref.watch(mealLogsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('ココメシ'),
        actions: [
          // 表示モード切替
          IconButton(
            icon: Icon(_viewModeIcon),
            onPressed: _cycleViewMode,
            tooltip: _viewModeLabel,
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      body: mealLogsAsync.when(
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
    );
  }

  IconData get _viewModeIcon => switch (_viewMode) {
    ViewMode.list => Icons.view_list,
    ViewMode.grid => Icons.grid_view,
    ViewMode.calendar => Icons.calendar_month,
  };

  String get _viewModeLabel => switch (_viewMode) {
    ViewMode.list => 'リスト表示',
    ViewMode.grid => 'グリッド表示',
    ViewMode.calendar => 'カレンダー表示',
  };

  void _cycleViewMode() {
    setState(() {
      _viewMode = ViewMode.values[(_viewMode.index + 1) % ViewMode.values.length];
    });
  }

  // ─── リスト表示（従来） ───

  Widget _buildListView(List<MealLog> mealLogs) {
    return RefreshIndicator(
      onRefresh: () => ref.read(mealLogsProvider.notifier).refresh(),
      child: ListView.builder(
        padding: const EdgeInsets.only(top: 8, bottom: 100),
        itemCount: mealLogs.length,
        itemBuilder: (context, index) {
          return _MealLogItem(
            key: ValueKey(mealLogs[index].id),
            mealLog: mealLogs[index],
            onTap: () => context.push('/meal/${mealLogs[index].id}'),
          );
        },
      ),
    );
  }

  // ─── グリッド表示 ───

  Widget _buildGridView(List<MealLog> mealLogs) {
    return RefreshIndicator(
      onRefresh: () => ref.read(mealLogsProvider.notifier).refresh(),
      child: GridView.builder(
        padding: const EdgeInsets.all(8),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          childAspectRatio: 0.85,
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

    return Column(
      children: [
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
            _focusedDay = focused;
          },
          calendarStyle: CalendarStyle(
            markerDecoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary,
              shape: BoxShape.circle,
            ),
            markerSize: 6,
            markersMaxCount: 3,
            todayDecoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
              shape: BoxShape.circle,
            ),
            selectedDecoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary,
              shape: BoxShape.circle,
            ),
          ),
          headerStyle: const HeaderStyle(
            formatButtonVisible: false,
            titleCentered: true,
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
                    style: TextStyle(color: Colors.grey[500]),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(top: 4, bottom: 100),
                  itemCount: selectedLogs.length,
                  itemBuilder: (context, index) {
                    return _MealLogItem(
                      key: ValueKey(selectedLogs[index].id),
                      mealLog: selectedLogs[index],
                      onTap: () => context.push('/meal/${selectedLogs[index].id}'),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.restaurant_menu, size: 64, color: Colors.grey),
          SizedBox(height: 16),
          Text(
            'まだ記録がありません',
            style: TextStyle(fontSize: 18, color: Colors.grey),
          ),
          SizedBox(height: 8),
          Text(
            'カメラボタンを押して\n最初の食事を記録しましょう',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ],
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
  }

  Future<void> _loadPhotos() async {
    final photos = await LocalDatabase.getPhotosForMealLog(widget.mealLog.id);
    if (mounted) setState(() => _photos = photos);
  }

  @override
  Widget build(BuildContext context) {
    return MealCard(
      mealLog: widget.mealLog,
      photos: _photos ?? [],
      onTap: widget.onTap,
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
