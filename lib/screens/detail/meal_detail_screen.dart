import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../database/local_database.dart';
import '../../models/meal_log.dart';
import '../../models/meal_photo.dart';
import '../../providers/meal_providers.dart';
import '../../services/ai_analysis_service.dart';
import '../../services/ai_rate_limit_service.dart';
import '../../services/app_settings_service.dart';
import '../../services/photo_service.dart';
import '../../theme/app_theme.dart';
import '../../theme/meal_type_style.dart';
import '../../widgets/cached_photo_image.dart';
import '../capture/crop_screen.dart';
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

    final tokens = KokoTokens.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('食事の詳細'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '記録を削除',
            onPressed: () => _confirmDelete(context),
          ),
        ],
      ),
      body: mealLogAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Text('エラー: $e', style: TextStyle(color: tokens.textMuted)),
        ),
        data: (mealLog) {
          if (mealLog == null) {
            return Center(
              child: Text(
                '記録が見つかりません',
                style: TextStyle(color: tokens.textMuted),
              ),
            );
          }

          final dateFormat = DateFormat('yyyy年M月d日 (E) HH:mm', 'ja');

          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
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
                    child: Center(
                      child: Text(
                        '写真の読み込みに失敗: $e',
                        style: TextStyle(color: tokens.textMuted),
                      ),
                    ),
                  ),
                  data: (photos) => _buildPhotoSection(photos),
                ),
                const SizedBox(height: 16),
                _buildMetaRow(mealLog, dateFormat),
                const SizedBox(height: 16),
                photosAsync.when(
                  loading: () => const SizedBox.shrink(),
                  error: (_, _) => const SizedBox.shrink(),
                  data: (photos) => photos.isEmpty
                      ? const SizedBox.shrink()
                      : _buildPhotoAiResult(photos[_selectedPhotoIndex]),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// メタ情報: 食事種別チップ・自宅タグ・日時
  Widget _buildMetaRow(MealLog mealLog, DateFormat dateFormat) {
    final tokens = KokoTokens.of(context);
    final scheme = Theme.of(context).colorScheme;

    return Row(
      children: [
        MealTypeChip(mealType: mealLog.mealType, compact: false),
        if (mealLog.locationTag == 'home') ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.home_outlined, size: 16, color: tokens.textMuted),
                const SizedBox(width: 6),
                Text(
                  '自宅',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: tokens.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            dateFormat.format(mealLog.eatenAt),
            textAlign: TextAlign.end,
            style: tokens.numeral.copyWith(
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              color: tokens.textMuted,
            ),
          ),
        ),
      ],
    );
  }

  /// 写真セクション: 選択写真 + サムネ一覧
  Widget _buildPhotoSection(List<MealPhoto> photos) {
    final tokens = KokoTokens.of(context);

    if (photos.isEmpty) {
      return Container(
        height: 200,
        width: double.infinity,
        decoration: BoxDecoration(
          color: tokens.photoPlaceholder,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.image_outlined, size: 32, color: tokens.textFaint),
            const SizedBox(height: 8),
            Text(
              '写真がありません',
              style: TextStyle(fontSize: 13, color: tokens.textMuted),
            ),
          ],
        ),
      );
    }

    final selectedPhoto = photos[_selectedPhotoIndex];

    return Column(
      children: [
        // 選択中の写真を大きく表示
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
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
                right: 12,
                bottom: 12,
                child: Material(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(999),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: () => _editPhoto(selectedPhoto),
                    child: const Padding(
                      padding: EdgeInsets.all(10),
                      child: Icon(Icons.tune, color: Colors.white, size: 18),
                    ),
                  ),
                ),
              ),
              // 枚数表示
              if (photos.length > 1)
                Positioned(
                  left: 12,
                  bottom: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '${_selectedPhotoIndex + 1} / ${photos.length}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),

        // サムネイル一覧（2枚以上の場合）
        if (photos.length > 1) ...[
          const SizedBox(height: 12),
          SizedBox(
            height: 56,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: photos.length,
              itemBuilder: (context, index) {
                final photo = photos[index];
                final isSelected = index == _selectedPhotoIndex;
                return GestureDetector(
                  onTap: () => setState(() => _selectedPhotoIndex = index),
                  child: Container(
                    width: 56,
                    margin: EdgeInsets.only(
                        right: index == photos.length - 1 ? 0 : 8),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isSelected
                            ? Theme.of(context).colorScheme.primary
                            : tokens.hairline,
                        width: isSelected ? 2 : 1,
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
        ],
      ],
    );
  }

  /// 個別写真のAI解析結果
  Widget _buildPhotoAiResult(MealPhoto photo) {
    // AI解析がオフのときは、未解析の写真に「AIオフ + 設定へ」を表示
    if (AppSettings.aiMode == AiAnalysisMode.off &&
        photo.aiStatus != 'completed') {
      return _buildAiOffNotice();
    }
    switch (photo.aiStatus) {
      case 'completed':
        return _buildCompletedResult(photo);
      case 'pending':
      case 'processing':
        return _buildStatusCard(
          leading: const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          message: 'AI解析中です',
        );
      case 'failed':
        {
          final scheme = Theme.of(context).colorScheme;
          return _buildStatusCard(
            leading: Icon(Icons.error_outline, size: 18, color: scheme.error),
            message: '解析に失敗しました',
            messageColor: scheme.error,
            action: TextButton.icon(
              onPressed: () => _retryForPhoto(photo),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('再解析'),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
            ),
          );
        }
      case 'skipped':
        return _buildSkippedCard(photo);
      default:
        // skipAiがtrueでstatusがcompletedでない場合
        if (photo.skipAi) {
          return _buildSkippedCard(photo);
        }
        return _buildStatusCard(
          leading: Icon(
            Icons.smart_toy_outlined,
            size: 18,
            color: KokoTokens.of(context).textFaint,
          ),
          message: 'AI解析は未実行です',
        );
    }
  }

  /// AI解析スキップ時の表示
  Widget _buildSkippedCard(MealPhoto photo) {
    return _buildStatusCard(
      leading: Icon(
        Icons.visibility_off_outlined,
        size: 18,
        color: KokoTokens.of(context).textFaint,
      ),
      message: 'AI解析をスキップしました',
      action: TextButton.icon(
        onPressed: () => _retryForPhoto(photo),
        icon: const Icon(Icons.auto_awesome_outlined, size: 16),
        label: const Text('解析する'),
        style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
      ),
    );
  }

  /// AI解析オフ時の表示（設定画面へのリンク付き）
  Widget _buildAiOffNotice() {
    return _buildStatusCard(
      leading: Icon(
        Icons.smart_toy_outlined,
        size: 18,
        color: KokoTokens.of(context).textFaint,
      ),
      message: 'AI解析はオフです',
      action: TextButton.icon(
        onPressed: () => context.push('/settings'),
        icon: const Icon(Icons.settings_outlined, size: 16),
        label: const Text('設定'),
        style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
      ),
    );
  }

  /// 解析中/失敗/スキップ/オフの共通カード
  Widget _buildStatusCard({
    required Widget leading,
    required String message,
    Color? messageColor,
    Widget? action,
  }) {
    final tokens = KokoTokens.of(context);
    return Card(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 10, action != null ? 8 : 16, 10),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  fontSize: 13.5,
                  color: messageColor ?? tokens.textMuted,
                ),
              ),
            ),
            ?action,
          ],
        ),
      ),
    );
  }

  /// 解析完了時の結果表示
  Widget _buildCompletedResult(MealPhoto photo) {
    final tokens = KokoTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final isUserCorrected = photo.userCorrectedName != null ||
        photo.userCorrectedPrice != null ||
        photo.userCorrectedCalories != null;
    final hasPrice = photo.displayPrice != null;
    final hasCalories = photo.displayCalories != null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(photo.displayName ?? '不明',
                          style: textTheme.titleMedium),
                      if (hasPrice || hasCalories)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Row(
                            children: [
                              if (hasPrice)
                                Text(
                                  '¥${NumberFormat('#,###').format(photo.displayPrice)}',
                                  style: tokens.numeral.copyWith(fontSize: 15),
                                ),
                              if (hasPrice && hasCalories)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8),
                                  child: Text(
                                    '/',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: tokens.textFaint,
                                    ),
                                  ),
                                ),
                              if (hasCalories)
                                Text(
                                  '${photo.displayCalories} kcal',
                                  style: tokens.numeral.copyWith(
                                    fontSize: 15,
                                    color: tokens.textMuted,
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.tonalIcon(
                  onPressed: () => _showEditDialog(context, photo),
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: const Text('編集'),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    textStyle: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            if (isUserCorrected || photo.aiModel != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Row(
                  children: [
                    if (isUserCorrected)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: scheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          'ユーザー修正済',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: scheme.onSecondaryContainer,
                          ),
                        ),
                      ),
                    const Spacer(),
                    if (photo.aiModel != null)
                      Text(
                        photo.aiModel!,
                        style:
                            TextStyle(fontSize: 11, color: tokens.textFaint),
                      ),
                  ],
                ),
              ),
          ],
        ),
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
    // 編集可能なファイルを探す
    final editSource = _findEditableFile(photo);
    if (editSource == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('写真ファイルが見つかりません')),
        );
      }
      return;
    }

    // 保存済み編集パラメータを復元
    CropEditParams? savedParams;
    if (photo.editParamsJson != null) {
      try {
        savedParams = CropEditParams.fromJson(
          jsonDecode(photo.editParamsJson!) as Map<String, dynamic>,
        );
      } catch (_) {}
    }

    // オリジナルが別途存在するか
    final hasOriginal = photo.originalLocalPath != null &&
        File(photo.originalLocalPath!).existsSync() &&
        photo.originalLocalPath != photo.localPath;

    // 直接CropScreenを開く
    final result = await Navigator.push<CropResult>(
      context,
      MaterialPageRoute(
        builder: (_) => CropScreen(
          filePath: editSource,
          initialParams: savedParams,
          hasOriginal: hasOriginal,
        ),
      ),
    );

    if (result == null || !mounted) return;

    // オリジナル復元のシグナル
    if (result.croppedPath == '_restore_original_') {
      await _resetToOriginal(photo);
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('写真を処理中...')),
    );

    final newLocalPath = await PhotoService.saveToLocalFromPath(result.croppedPath);
    final newThumbPath = await PhotoService.generateThumbnail(newLocalPath);

    final updated = photo.copyWith(
      localPath: newLocalPath,
      originalLocalPath: editSource,
      thumbnailUrl: newThumbPath,
      editParamsJson: jsonEncode(result.editParams.toJson()),
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
      clearEditParams: true,
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
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('削除'),
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
