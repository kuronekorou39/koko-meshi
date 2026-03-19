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
  int _selectedPhotoIndex = 0;

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
    photosAsync.whenData((photos) {
      _startAutoRefresh(photos);
      // indexが範囲外にならないように
      if (_selectedPhotoIndex >= photos.length && photos.isNotEmpty) {
        _selectedPhotoIndex = photos.length - 1;
      }
    });

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
                  data: (photos) => _buildPhotoSection(photos),
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

  /// 写真セクション: 選択写真 + サムネ一覧 + AI結果
  Widget _buildPhotoSection(List<MealPhoto> photos) {
    if (photos.isEmpty) {
      return const SizedBox(
        height: 200,
        child: Center(child: Text('写真がありません')),
      );
    }

    final selectedPhoto = photos[_selectedPhotoIndex];

    return Column(
      children: [
        // 選択中の写真を大きく表示
        Stack(
          children: [
            GestureDetector(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => PhotoViewerScreen(
                    photos: photos,
                    initialIndex: _selectedPhotoIndex,
                  ),
                ),
              ),
              child: CachedPhotoImage(
                localPath: selectedPhoto.localPath,
                thumbnailPath: selectedPhoto.thumbnailUrl,
                originalUrl: selectedPhoto.originalUrl,
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
                  onTap: () => _editPhoto(selectedPhoto),
                  child: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Icon(Icons.tune, color: Colors.white, size: 20),
                  ),
                ),
              ),
            ),
            // 枚数表示
            if (photos.length > 1)
              Positioned(
                left: 8,
                bottom: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${_selectedPhotoIndex + 1} / ${photos.length}',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ),
          ],
        ),

        // サムネイル一覧（2枚以上の場合）
        if (photos.length > 1)
          Container(
            height: 72,
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: photos.length,
              itemBuilder: (context, index) {
                final photo = photos[index];
                final isSelected = index == _selectedPhotoIndex;
                return GestureDetector(
                  onTap: () => setState(() => _selectedPhotoIndex = index),
                  child: Container(
                    width: 56,
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isSelected
                            ? Theme.of(context).colorScheme.primary
                            : Colors.transparent,
                        width: 2,
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: CachedPhotoImage(
                        localPath: photo.localPath,
                        thumbnailPath: photo.thumbnailUrl,
                        originalUrl: photo.originalUrl,
                        height: 56,
                        width: 56,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),

        // 選択中の写真のAI解析結果
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _buildPhotoAiResult(selectedPhoto),
        ),
      ],
    );
  }

  /// 個別写真のAI解析結果
  Widget _buildPhotoAiResult(MealPhoto photo) {
    switch (photo.aiStatus) {
      case 'completed':
        return _buildCompletedResult(photo);
      case 'pending':
      case 'processing':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Text(
                'AI解析中...',
                style: TextStyle(color: Colors.grey[500], fontSize: 14),
              ),
            ],
          ),
        );
      case 'failed':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Icon(Icons.error_outline, size: 16, color: Colors.red[300]),
              const SizedBox(width: 6),
              Text(
                '解析に失敗',
                style: TextStyle(color: Colors.red[300], fontSize: 14),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () => _retryForPhoto(photo),
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('再解析'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
        );
      case 'skipped':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Icon(Icons.visibility_off, size: 16, color: Colors.grey[400]),
              const SizedBox(width: 6),
              Text(
                'AI解析スキップ',
                style: TextStyle(color: Colors.grey[500], fontSize: 14),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () => _retryForPhoto(photo),
                icon: const Icon(Icons.auto_awesome, size: 16),
                label: const Text('解析する'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
        );
      default:
        // skipAiがtrueでstatusがcompletedでない場合
        if (photo.skipAi) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Icon(Icons.visibility_off, size: 16, color: Colors.grey[400]),
                const SizedBox(width: 6),
                Text(
                  'AI解析スキップ',
                  style: TextStyle(color: Colors.grey[500], fontSize: 14),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => _retryForPhoto(photo),
                  icon: const Icon(Icons.auto_awesome, size: 16),
                  label: const Text('解析する'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            'AI解析未実行',
            style: TextStyle(color: Colors.grey[500], fontSize: 14),
          ),
        );
    }
  }

  /// 解析完了時の結果表示
  Widget _buildCompletedResult(MealPhoto photo) {
    final isUserCorrected = photo.userCorrectedName != null ||
        photo.userCorrectedPrice != null ||
        photo.userCorrectedCalories != null;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        photo.displayName ?? '不明',
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
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

  /// 個別写真のAI解析リトライ
  Future<void> _retryForPhoto(MealPhoto photo) async {
    final status = await AiRateLimitService.getStatus();
    if (!status.canUse) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('AI解析の回数上限に達しています')),
        );
      }
      return;
    }

    final updated = photo.copyWith(aiStatus: 'pending', skipAi: false);
    await LocalDatabase.updateMealPhoto(updated);
    ref.invalidate(mealPhotosProvider(widget.mealLogId));

    AiAnalysisService.processPendingPhotos().then((_) {
      if (mounted) {
        ref.invalidate(mealPhotosProvider(widget.mealLogId));
        ref.read(mealLogsProvider.notifier).refresh();
      }
    });
  }

  /// 編集用のファイルパスを取得（localPath → originalLocalPath → thumbnailUrl の順で試行）
  String? _findEditableFile(MealPhoto photo) {
    if (File(photo.localPath).existsSync()) return photo.localPath;
    if (photo.originalLocalPath != null && File(photo.originalLocalPath!).existsSync()) {
      return photo.originalLocalPath!;
    }
    if (photo.thumbnailUrl != null && File(photo.thumbnailUrl!).existsSync()) {
      return photo.thumbnailUrl!;
    }
    return null;
  }

  Future<void> _editPhoto(MealPhoto photo) async {
    final filePath = _findEditableFile(photo);
    if (filePath == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('写真ファイルが見つかりません')),
        );
      }
      return;
    }

    // オリジナルが存在する場合、リセットオプション付きのダイアログを表示
    final hasOriginal = photo.originalLocalPath != null &&
        File(photo.originalLocalPath!).existsSync() &&
        photo.originalLocalPath != photo.localPath;

    if (hasOriginal) {
      final action = await showModalBottomSheet<String>(
        context: context,
        builder: (_) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.tune),
                title: const Text('写真を編集'),
                onTap: () => Navigator.pop(context, 'edit'),
              ),
              ListTile(
                leading: const Icon(Icons.restore),
                title: const Text('オリジナルに戻す'),
                subtitle: const Text('撮影時の元画像に復元します'),
                onTap: () => Navigator.pop(context, 'reset'),
              ),
            ],
          ),
        ),
      );

      if (action == null || !mounted) return;

      if (action == 'reset') {
        await _resetToOriginal(photo);
        return;
      }
    }

    final result = await Navigator.push<PhotoEditResult>(
      context,
      MaterialPageRoute(
        builder: (_) => PhotoEditorScreen(filePath: filePath),
      ),
    );

    if (result == null || !result.hasEdits || !mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('写真を処理中...')),
    );

    final dir = await getTemporaryDirectory();
    final outputPath = path.join(
      dir.path,
      'edit_${DateTime.now().millisecondsSinceEpoch}.jpg',
    );

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
      finalPath = sourcePath;
    }

    if (finalPath == null || !mounted) return;

    final newLocalPath = await PhotoService.saveToLocalFromPath(finalPath);
    final newThumbPath = await PhotoService.generateThumbnail(newLocalPath);

    // originalLocalPathが未設定なら現在のlocalPathをオリジナルとして保存
    final originalPath = photo.originalLocalPath ?? photo.localPath;

    final updated = photo.copyWith(
      localPath: newLocalPath,
      originalLocalPath: originalPath,
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

  /// オリジナル画像に復元
  Future<void> _resetToOriginal(MealPhoto photo) async {
    final originalPath = photo.originalLocalPath!;
    final newThumbPath = await PhotoService.generateThumbnail(originalPath);

    final updated = photo.copyWith(
      localPath: originalPath,
      thumbnailUrl: newThumbPath,
    );
    await LocalDatabase.updateMealPhoto(updated);
    ref.invalidate(mealPhotosProvider(widget.mealLogId));

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('オリジナル画像に復元しました')),
      );
    }
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
