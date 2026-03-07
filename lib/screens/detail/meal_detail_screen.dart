import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../providers/meal_providers.dart';
import '../../models/meal_photo.dart';

class MealDetailScreen extends ConsumerWidget {
  final String mealLogId;

  const MealDetailScreen({super.key, required this.mealLogId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mealLogAsync = ref.watch(mealLogProvider(mealLogId));
    final photosAsync = ref.watch(mealPhotosProvider(mealLogId));

    return Scaffold(
      appBar: AppBar(
        title: const Text('食事の詳細'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _confirmDelete(context, ref),
          ),
        ],
      ),
      body: mealLogAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('エラー: $e')),
        data: (mealLog) {
          if (mealLog == null) {
            return const Center(child: Text('記録が見つかりません'));
          }

          final dateFormat = DateFormat('yyyy年M月d日 (E) HH:mm', 'ja');

          return SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 写真ギャラリー
                photosAsync.when(
                  loading: () => const SizedBox(
                    height: 300,
                    child: Center(child: CircularProgressIndicator()),
                  ),
                  error: (e, _) => SizedBox(
                    height: 300,
                    child: Center(child: Text('写真の読み込みに失敗: $e')),
                  ),
                  data: (photos) => _buildPhotoGallery(photos),
                ),

                // 基本情報
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 食事種別 + 日時
                      Row(
                        children: [
                          Chip(label: Text(mealLog.mealType.label)),
                          const Spacer(),
                          Text(
                            dateFormat.format(mealLog.eatenAt),
                            style: TextStyle(
                              color: Colors.grey[600],
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // AI解析結果
                      photosAsync.when(
                        loading: () => const SizedBox.shrink(),
                        error: (_, _) => const SizedBox.shrink(),
                        data: (photos) => _buildAiResults(photos),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildPhotoGallery(List<MealPhoto> photos) {
    if (photos.isEmpty) {
      return const SizedBox(
        height: 200,
        child: Center(child: Text('写真がありません')),
      );
    }

    if (photos.length == 1) {
      return _buildFullPhoto(photos.first);
    }

    return SizedBox(
      height: 300,
      child: PageView.builder(
        itemCount: photos.length,
        itemBuilder: (context, index) {
          return _buildFullPhoto(photos[index]);
        },
      ),
    );
  }

  Widget _buildFullPhoto(MealPhoto photo) {
    final file = File(photo.localPath);
    if (!file.existsSync()) {
      return Container(
        height: 300,
        color: Colors.grey[300],
        child: const Center(
          child: Icon(Icons.broken_image, size: 48, color: Colors.grey),
        ),
      );
    }

    return Image.file(
      file,
      height: 300,
      width: double.infinity,
      fit: BoxFit.cover,
    );
  }

  Widget _buildAiResults(List<MealPhoto> photos) {
    final analyzed = photos.where((p) => p.aiStatus == 'completed').toList();
    final pending = photos.where((p) => p.aiStatus == 'pending').toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (analyzed.isNotEmpty) ...[
          const Text(
            'メニュー',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          ...analyzed.map((photo) => ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(photo.displayName ?? '不明'),
                subtitle: Row(
                  children: [
                    if (photo.displayPrice != null)
                      Text('¥${NumberFormat('#,###').format(photo.displayPrice)}'),
                    if (photo.displayPrice != null && photo.displayCalories != null)
                      const Text(' / '),
                    if (photo.displayCalories != null)
                      Text('${photo.displayCalories} kcal'),
                  ],
                ),
                trailing: const Icon(Icons.edit, size: 18, color: Colors.grey),
              )),
        ],
        if (pending.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '${pending.length}枚の写真を解析待ち...',
              style: TextStyle(color: Colors.grey[500], fontSize: 14),
            ),
          ),
        if (analyzed.isEmpty && pending.isEmpty)
          Text(
            'AI解析はまだ実行されていません',
            style: TextStyle(color: Colors.grey[500], fontSize: 14),
          ),
      ],
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('記録を削除'),
        content: const Text('この食事記録を削除しますか？\n写真も一緒に削除されます。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('削除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      await ref.read(mealLogsProvider.notifier).deleteMealLog(mealLogId);
      if (context.mounted) Navigator.pop(context);
    }
  }
}
