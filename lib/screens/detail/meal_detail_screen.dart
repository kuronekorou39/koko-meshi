import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../database/local_database.dart';
import '../../providers/meal_providers.dart';
import '../../models/meal_photo.dart';
import '../../services/ai_analysis_service.dart';
import '../../services/ai_rate_limit_service.dart';
import '../../services/photo_service.dart';
import '../../widgets/cached_photo_image.dart';
import '../capture/photo_editor_screen.dart';
import 'photo_viewer_screen.dart';

class MealDetailScreen extends ConsumerStatefulWidget {
  final String mealLogId;

  const MealDetailScreen({super.key, required this.mealLogId});

  @override
  ConsumerState<MealDetailScreen> createState() => _MealDetailScreenState();
}

class _MealDetailScreenState extends ConsumerState<MealDetailScreen> {
  Timer? _refreshTimer;

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  void _startAutoRefresh(List<MealPhoto> photos) {
    _refreshTimer?.cancel();
    final hasPending = photos.any(
      (p) => p.aiStatus == 'pending' || p.aiStatus == 'processing',
    );
    if (hasPending) {
      _refreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        ref.invalidate(mealPhotosProvider(widget.mealLogId));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final mealLogAsync = ref.watch(mealLogProvider(widget.mealLogId));
    final photosAsync = ref.watch(mealPhotosProvider(widget.mealLogId));

    // pending写真がある場合、自動リフレッシュ
    photosAsync.whenData(_startAutoRefresh);

    return Scaffold(
      appBar: AppBar(
        title: const Text('食事の詳細'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _confirmDelete(context),
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

                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Chip(label: Text(mealLog.mealType.label)),
                          if (mealLog.locationTag == 'home')
                            Padding(
                              padding: const EdgeInsets.only(left: 8),
                              child: Chip(
                                avatar: const Icon(Icons.home, size: 16),
                                label: const Text('自宅'),
                              ),
                            ),
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

                      photosAsync.when(
                        loading: () => const SizedBox.shrink(),
                        error: (_, _) => const SizedBox.shrink(),
                        data: (photos) => _buildAiResults(context, photos),
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
      return _buildFullPhoto(photos, 0);
    }

    return SizedBox(
      height: 300,
      child: PageView.builder(
        itemCount: photos.length,
        itemBuilder: (context, index) {
          return _buildFullPhoto(photos, index);
        },
      ),
    );
  }

  Widget _buildFullPhoto(List<MealPhoto> photos, int index) {
    final photo = photos[index];
    return Stack(
      children: [
        GestureDetector(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => PhotoViewerScreen(
                photos: photos,
                initialIndex: index,
              ),
            ),
          ),
          child: CachedPhotoImage(
            localPath: photo.localPath,
            thumbnailPath: photo.thumbnailUrl,
            originalUrl: photo.originalUrl,
            height: 300,
            width: double.infinity,
            fullQuality: true,
          ),
        ),
        // 編集ボタン
        Positioned(
          right: 8,
          bottom: 8,
          child: Material(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(20),
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => _editPhoto(photo),
              child: const Padding(
                padding: EdgeInsets.all(8),
                child: Icon(Icons.tune, color: Colors.white, size: 20),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _editPhoto(MealPhoto photo) async {
    final filePath = photo.localPath;
    if (!File(filePath).existsSync()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('写真ファイルが見つかりません')),
        );
      }
      return;
    }

    final result = await Navigator.push<PhotoEditResult>(
      context,
      MaterialPageRoute(
        builder: (_) => PhotoEditorScreen(filePath: filePath),
      ),
    );

    if (result == null || !result.hasEdits || !mounted) return;

    // 編集を適用してファイルを上書き
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('写真を処理中...')),
    );

    final dir = await getTemporaryDirectory();
    final outputPath = path.join(
      dir.path,
      'edit_${DateTime.now().millisecondsSinceEpoch}.jpg',
    );

    // ソースパス（クロップがあればクロップ済み、なければオリジナル）
    final sourcePath = result.croppedPath ?? filePath;

    final hasFilters = result.brightness != 0 ||
        result.contrast != 0 ||
        result.saturation != 0 ||
        result.warmth != 0 ||
        result.vignette != 0;

    String? finalPath;
    if (hasFilters) {
      finalPath = await compute(processEditedImage, ImageProcessParams(
        inputPath: sourcePath,
        outputPath: outputPath,
        brightness: result.brightness,
        contrast: result.contrast,
        saturation: result.saturation,
        warmth: result.warmth,
        vignette: result.vignette,
      ));
    } else {
      // クロップのみ
      finalPath = sourcePath;
    }

    if (finalPath == null || !mounted) return;

    // ローカルパスを更新
    final newLocalPath = await PhotoService.saveToLocalFromPath(finalPath);
    final newThumbPath = await PhotoService.generateThumbnail(newLocalPath);

    final updated = photo.copyWith(
      localPath: newLocalPath,
      thumbnailUrl: newThumbPath,
    );
    await LocalDatabase.updateMealPhoto(updated);
    ref.invalidate(mealPhotosProvider(widget.mealLogId));

    if (mounted) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('写真を更新しました')),
      );
    }
  }

  Widget _buildAiResults(BuildContext context, List<MealPhoto> photos) {
    final analyzed = photos.where((p) => p.aiStatus == 'completed').toList();
    final pending = photos.where((p) => p.aiStatus == 'pending' || p.aiStatus == 'processing').toList();
    final failed = photos.where((p) => p.aiStatus == 'failed').toList();
    final skipped = photos.where((p) => p.skipAi || p.aiStatus == 'skipped').toList();

    // リトライ可能な写真（スキップ・失敗・未実行）
    final retryable = photos.where((p) =>
      p.aiStatus == 'skipped' || p.aiStatus == 'failed' || (p.skipAi && p.aiStatus != 'completed'),
    ).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (analyzed.isNotEmpty) ...[
          const Text(
            'メニュー',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          ...analyzed.map((photo) => _buildMenuTile(context, photo)),
        ],
        if (pending.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text(
                  '${pending.length}枚の写真を解析中...',
                  style: TextStyle(color: Colors.grey[500], fontSize: 14),
                ),
              ],
            ),
          ),
        if (failed.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '${failed.length}枚の写真は解析に失敗',
              style: TextStyle(color: Colors.red[300], fontSize: 14),
            ),
          ),
        if (skipped.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '${skipped.length}枚の写真はAI解析をスキップ',
              style: TextStyle(color: Colors.grey[500], fontSize: 14),
            ),
          ),
        if (analyzed.isEmpty && pending.isEmpty && failed.isEmpty && skipped.isEmpty)
          Text(
            'AI解析はまだ実行されていません',
            style: TextStyle(color: Colors.grey[500], fontSize: 14),
          ),
        // リトライボタン
        if (retryable.isNotEmpty && pending.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: OutlinedButton.icon(
              onPressed: () => _retryAiAnalysis(retryable),
              icon: const Icon(Icons.auto_awesome, size: 18),
              label: Text('${retryable.length}枚をAI解析する'),
            ),
          ),
      ],
    );
  }

  Future<void> _retryAiAnalysis(List<MealPhoto> photos) async {
    // レート制限チェック
    final status = await AiRateLimitService.getStatus();
    if (!status.canUse) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('AI解析の回数上限に達しています')),
        );
      }
      return;
    }

    // 対象写真のステータスをpendingに変更
    for (final photo in photos) {
      final updated = photo.copyWith(aiStatus: 'pending', skipAi: false);
      await LocalDatabase.updateMealPhoto(updated);
    }
    ref.invalidate(mealPhotosProvider(widget.mealLogId));

    // バックグラウンドで解析実行
    AiAnalysisService.processPendingPhotos().then((_) {
      if (mounted) {
        ref.invalidate(mealPhotosProvider(widget.mealLogId));
        ref.read(mealLogsProvider.notifier).refresh();
      }
    });
  }

  Widget _buildMenuTile(BuildContext context, MealPhoto photo) {
    final isUserCorrected = photo.userCorrectedName != null ||
        photo.userCorrectedPrice != null ||
        photo.userCorrectedCalories != null;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(photo.displayName ?? '不明'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (photo.displayPrice != null)
                Text('¥${NumberFormat('#,###').format(photo.displayPrice)}'),
              if (photo.displayPrice != null && photo.displayCalories != null)
                const Text(' / '),
              if (photo.displayCalories != null)
                Text('${photo.displayCalories} kcal'),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              if (photo.aiModel != null)
                Text(
                  photo.aiModel!,
                  style: TextStyle(fontSize: 11, color: Colors.grey[400]),
                ),
              if (isUserCorrected) ...[
                if (photo.aiModel != null)
                  Text(' · ', style: TextStyle(fontSize: 11, color: Colors.grey[400])),
                Text(
                  'ユーザー修正済',
                  style: TextStyle(fontSize: 11, color: Colors.blue[300]),
                ),
              ],
            ],
          ),
        ],
      ),
      trailing: IconButton(
        icon: const Icon(Icons.edit, size: 18, color: Colors.grey),
        onPressed: () => _showEditDialog(context, photo),
      ),
    );
  }

  Future<void> _showEditDialog(BuildContext context, MealPhoto photo) async {
    final nameCtrl = TextEditingController(text: photo.displayName ?? '');
    final priceCtrl = TextEditingController(
      text: photo.displayPrice?.toString() ?? '',
    );
    final caloriesCtrl = TextEditingController(
      text: photo.displayCalories?.toString() ?? '',
    );

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('メニュー情報を編集'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                labelText: 'メニュー名',
                hintText: '例: 味噌ラーメン',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: priceCtrl,
              decoration: const InputDecoration(
                labelText: '価格 (円)',
                hintText: '例: 800',
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: caloriesCtrl,
              decoration: const InputDecoration(
                labelText: 'カロリー (kcal)',
                hintText: '例: 500',
              ),
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    if (result == true) {
      final updated = photo.copyWith(
        userCorrectedName: nameCtrl.text.trim().isEmpty ? null : nameCtrl.text.trim(),
        userCorrectedPrice: int.tryParse(priceCtrl.text.trim()),
        userCorrectedCalories: int.tryParse(caloriesCtrl.text.trim()),
      );
      await LocalDatabase.updateMealPhoto(updated);
      ref.invalidate(mealPhotosProvider(widget.mealLogId));
    }

    nameCtrl.dispose();
    priceCtrl.dispose();
    caloriesCtrl.dispose();
  }

  Future<void> _confirmDelete(BuildContext context) async {
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
      await ref.read(mealLogsProvider.notifier).deleteMealLog(widget.mealLogId);
      if (context.mounted) Navigator.pop(context);
    }
  }
}
