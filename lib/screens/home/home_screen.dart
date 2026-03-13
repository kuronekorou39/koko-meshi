import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../../database/local_database.dart';
import '../../models/meal_log.dart';
import '../../models/meal_photo.dart';
import '../../providers/meal_providers.dart';
import '../../services/ai_analysis_service.dart';
import '../../services/ai_rate_limit_service.dart';
import '../../services/auth_service.dart';
import '../../services/photo_service.dart';
import '../../services/sync_service.dart';
import '../../widgets/ai_limit_dialog.dart';
import 'timeline_tab.dart';
import 'map_tab.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  static const _uuid = Uuid();
  int _currentIndex = 0;

  final _tabs = const [
    TimelineTab(),
    MapTab(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _tabs[_currentIndex],
      floatingActionButton: _currentIndex == 0
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ライブラリボタン
                FloatingActionButton.small(
                  heroTag: 'library',
                  onPressed: _onLibraryPressed,
                  child: const Icon(Icons.photo_library),
                ),
                const SizedBox(height: 8),
                // カメラボタン（メイン）
                FloatingActionButton(
                  heroTag: 'camera',
                  onPressed: _onCameraPressed,
                  child: const Icon(Icons.camera_alt),
                ),
              ],
            )
          : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          setState(() => _currentIndex = index);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.restaurant),
            label: '記録',
          ),
          NavigationDestination(
            icon: Icon(Icons.map),
            label: 'マップ',
          ),
        ],
      ),
    );
  }

  /// カメラ直接起動
  Future<void> _onCameraPressed() async {
    final photo = await PhotoService.takePhoto();
    if (photo == null || !mounted) return;
    await _handleNewPhotos([photo]);
  }

  /// ライブラリから選択
  Future<void> _onLibraryPressed() async {
    final photos = await PhotoService.pickPhotos();
    if (photos.isEmpty || !mounted) return;
    await _handleNewPhotos(photos);
  }

  /// 新しい写真を処理: マージ判定 → マージ or 新規記録
  Future<void> _handleNewPhotos(List<XFile> photos) async {
    final mealLogs = ref.read(mealLogsProvider).valueOrNull ?? [];
    final recentMeal = mealLogs.isNotEmpty ? mealLogs.first : null;

    if (recentMeal != null && mounted) {
      final timeDiff = DateTime.now().difference(recentMeal.eatenAt);
      if (timeDiff.inMinutes <= 30) {
        final action = await _showMergeDialog(recentMeal);
        if (!mounted) return;
        if (action == 'merge') {
          await _mergePhotos(recentMeal.id, photos);
          return;
        }
        if (action == null) return; // キャンセル
        // action == 'new' → 新規記録へ
      }
    }

    if (mounted) context.push('/capture', extra: photos);
  }

  /// マージダイアログ
  Future<String?> _showMergeDialog(MealLog mealLog) async {
    final timeStr = DateFormat('HH:mm', 'ja').format(mealLog.eatenAt);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('直前の記録に追加'),
        content: Text('$timeStr の${mealLog.mealType.label}に写真を追加しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'new'),
            child: const Text('新しく記録'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'merge'),
            child: const Text('追加する'),
          ),
        ],
      ),
    );
  }

  /// 既存の食事記録に写真を追加
  Future<void> _mergePhotos(String mealLogId, List<XFile> xfiles) async {
    for (final xfile in xfiles) {
      final localPath = await PhotoService.saveToLocal(xfile);
      final thumbnailPath = await PhotoService.generateThumbnail(localPath);

      // EXIFからメタデータを読み取る
      final exif = await PhotoService.readExifData(xfile.path);

      final photo = MealPhoto(
        id: _uuid.v4(),
        mealLogId: mealLogId,
        localPath: localPath,
        thumbnailUrl: thumbnailPath,
        aiStatus: 'pending',
        shotAt: exif.dateTime ?? DateTime.now(),
        latitude: exif.latitude,
        longitude: exif.longitude,
        createdAt: DateTime.now(),
      );
      await LocalDatabase.insertMealPhoto(photo);
    }

    ref.read(mealLogsProvider.notifier).refresh();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${xfiles.length}枚の写真を追加しました')),
      );
    }

    // AI解析
    final rateLimitStatus = await AiRateLimitService.getStatus();
    if (rateLimitStatus.canUse) {
      AiAnalysisService.processPendingPhotos().then((_) {
        if (mounted) ref.read(mealLogsProvider.notifier).refresh();
        if (AuthService.isLoggedIn) SyncService.syncAll();
      });
    } else if (mounted) {
      final recovered = await showAiLimitDialog(context, rateLimitStatus);
      if (recovered == true) {
        AiAnalysisService.processPendingPhotos().then((_) {
          if (mounted) ref.read(mealLogsProvider.notifier).refresh();
          if (AuthService.isLoggedIn) SyncService.syncAll();
        });
      }
    }

    if (AuthService.isLoggedIn) {
      SyncService.syncAll();
    }
  }
}
