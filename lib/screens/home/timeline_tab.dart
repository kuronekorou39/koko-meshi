import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../database/local_database.dart';
import '../../models/meal_log.dart';
import '../../models/meal_photo.dart';
import '../../providers/meal_providers.dart';
import '../../widgets/meal_card.dart';

class TimelineTab extends ConsumerWidget {
  const TimelineTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mealLogsAsync = ref.watch(mealLogsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('ココメシ'),
        actions: [
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
          if (mealLogs.isEmpty) {
            return _buildEmptyState();
          }
          return RefreshIndicator(
            onRefresh: () => ref.read(mealLogsProvider.notifier).refresh(),
            child: ListView.builder(
              padding: const EdgeInsets.only(top: 8, bottom: 100),
              itemCount: mealLogs.length,
              itemBuilder: (context, index) {
                return _MealLogItem(
                  mealLog: mealLogs[index],
                  onTap: () => context.push('/meal/${mealLogs[index].id}'),
                );
              },
            ),
          );
        },
      ),
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

/// 各食事記録の写真を非同期で取得して表示
class _MealLogItem extends StatefulWidget {
  final MealLog mealLog;
  final VoidCallback onTap;

  const _MealLogItem({required this.mealLog, required this.onTap});

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
