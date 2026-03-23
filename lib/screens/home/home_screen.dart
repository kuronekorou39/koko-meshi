import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../../database/local_database.dart';
import '../../models/meal_log.dart';
import '../../models/meal_photo.dart';
import '../../models/meal_type.dart';
import '../../providers/meal_providers.dart';
import '../../services/ai_analysis_service.dart';
import '../../services/ai_rate_limit_service.dart';
import '../../services/auth_service.dart';
import 'package:geolocator/geolocator.dart';
import '../../services/location_service.dart';
import '../../services/photo_service.dart';
import '../../services/sync_service.dart';
import '../../widgets/ai_limit_dialog.dart';
import '../../app.dart';
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

  late final _tabs = [
    TimelineTab(onLibraryPressed: _onLibraryPressed),
    const MapTab(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _tabs[_currentIndex],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex == 0 ? 0 : 2,
        onDestinationSelected: _onDestinationSelected,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.restaurant),
            label: '記録',
          ),
          NavigationDestination(
            icon: Icon(Icons.camera_alt),
            label: '撮影',
          ),
          NavigationDestination(
            icon: Icon(Icons.map),
            label: 'マップ',
          ),
        ],
      ),
    );
  }

  /// NavigationBar のタップ処理
  /// 真ん中（index=1）はカメラ起動、タブ切り替えしない
  void _onDestinationSelected(int index) {
    if (index == 1) {
      _onCameraPressed();
      return;
    }
    setState(() {
      _currentIndex = index == 0 ? 0 : 1;
    });
  }

  /// カメラ直接起動 → 確認ダイアログ → 保存
  Future<void> _onCameraPressed() async {
    final photo = await PhotoService.takePhoto();
    if (photo == null || !mounted) return;

    // 確認ダイアログでAI解析ON/OFF選択
    final result = await _showSaveConfirmDialog(photo);
    if (result == null || !mounted) return;

    await _quickSavePhoto(photo, aiEnabled: result);
  }

  /// ライブラリから選択 → CaptureScreen へ
  Future<void> _onLibraryPressed() async {
    final photos = await PhotoService.pickPhotos();
    if (photos.isEmpty || !mounted) return;
    await _handleLibraryPhotos(photos);
  }

  /// 撮影後確認ダイアログ: プレビュー + AIトグル
  /// 戻り値: AI解析ON→true, OFF→false, キャンセル→null
  Future<bool?> _showSaveConfirmDialog(XFile photo) async {
    bool aiEnabled = true;
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => Dialog(
          insetPadding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // プレビュー画像
              ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                child: AspectRatio(
                  aspectRatio: 3 / 4,
                  child: Image.file(
                    File(photo.path),
                    fit: BoxFit.cover,
                  ),
                ),
              ),
              // 下部: AIトグル + ボタン
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Row(
                  children: [
                    // AIトグル
                    GestureDetector(
                      onTap: () => setDialogState(() => aiEnabled = !aiEnabled),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: aiEnabled
                              ? Theme.of(context).colorScheme.primaryContainer
                              : Theme.of(context).colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              aiEnabled ? Icons.auto_awesome : Icons.auto_awesome_outlined,
                              size: 18,
                              color: aiEnabled
                                  ? Theme.of(context).colorScheme.primary
                                  : Colors.grey,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              aiEnabled ? 'AI解析ON' : 'AI解析OFF',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: aiEnabled
                                    ? Theme.of(context).colorScheme.primary
                                    : Colors.grey,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const Spacer(),
                    // キャンセル
                    TextButton(
                      onPressed: () => Navigator.pop(context, null),
                      child: const Text('やめる'),
                    ),
                    const SizedBox(width: 8),
                    // 保存
                    FilledButton.icon(
                      onPressed: () => Navigator.pop(context, aiEnabled),
                      icon: const Icon(Icons.check, size: 20),
                      label: const Text('保存'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// カメラ撮影 → 即保存（マージ判定あり）
  Future<void> _quickSavePhoto(XFile xfile, {bool aiEnabled = true}) async {
    final mealLogs = ref.read(mealLogsProvider).valueOrNull ?? [];
    final recentMeal = mealLogs.isNotEmpty ? mealLogs.first : null;

    // マージ判定
    if (recentMeal != null && mounted) {
      final timeDiff = DateTime.now().difference(recentMeal.eatenAt);
      if (timeDiff.inMinutes <= 30) {
        final action = await _showMergeDialog(recentMeal);
        if (!mounted) return;
        if (action == 'merge') {
          await _mergePhotos(recentMeal.id, [xfile]);
          return;
        }
        if (action == null) return;
      }
    }

    // 新規記録として即保存
    final mealLogId = _uuid.v4();
    final pos = await LocationService.getCurrentPosition();
    double? lat = pos?.latitude;
    double? lng = pos?.longitude;
    String? locationTag;

    if (lat != null && lng != null) {
      final savedPlaces = await LocalDatabase.getSavedPlaces();
      for (final place in savedPlaces) {
        final distance = Geolocator.distanceBetween(
          lat, lng, place.latitude, place.longitude,
        );
        if (distance <= 100) {
          locationTag = place.iconType == 'home' ? 'home' : place.id;
          break;
        }
      }
    }

    final mealLog = MealLog(
      id: mealLogId,
      mealType: MealType.unset,
      eatenAt: DateTime.now(),
      latitude: lat,
      longitude: lng,
      locationTag: locationTag,
      createdAt: DateTime.now(),
    );
    await LocalDatabase.insertMealLog(mealLog);

    final localPath = await PhotoService.saveToLocal(xfile);
    final thumbnailPath = await PhotoService.generateThumbnail(localPath);

    final mealPhoto = MealPhoto(
      id: _uuid.v4(),
      mealLogId: mealLogId,
      localPath: localPath,
      originalLocalPath: localPath,
      thumbnailUrl: thumbnailPath,
      skipAi: !aiEnabled,
      aiStatus: aiEnabled ? 'pending' : 'skipped',
      shotAt: DateTime.now(),
      latitude: lat,
      longitude: lng,
      createdAt: DateTime.now(),
    );
    await LocalDatabase.insertMealPhoto(mealPhoto);

    ref.read(mealLogsProvider.notifier).refresh();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('写真を保存しました'), duration: Duration(seconds: 1)),
      );
    }

    // バックグラウンドAI解析
    _runBackgroundAiAndSync();
  }

  /// ライブラリ写真 → マージ判定 → CaptureScreen
  Future<void> _handleLibraryPhotos(List<XFile> photos) async {
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
        if (action == null) return;
      }
    }

    if (mounted) {
      context.push('/capture', extra: {
        'photos': photos,
        'fromLibrary': true,
      });
    }
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
    ref.invalidate(mealPhotosProvider(mealLogId));

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${xfiles.length}枚の写真を追加しました')),
      );
    }

    _runBackgroundAiAndSync();
  }

  /// バックグラウンドAI解析 + 同期
  Future<void> _runBackgroundAiAndSync() async {
    final rateLimitStatus = await AiRateLimitService.getStatus();
    if (rateLimitStatus.canUse) {
      AiAnalysisService.anonymousLimitReached = false;
      AiAnalysisService.processPendingPhotos().then((_) {
        if (mounted) ref.read(mealLogsProvider.notifier).refresh();

        if (AiAnalysisService.anonymousLimitReached) {
          final ctx = navigatorKey.currentContext;
          if (ctx != null) {
            showDialog(
              context: ctx,
              builder: (dialogCtx) => AlertDialog(
                title: const Text('AI解析の上限に達しました'),
                content: const Text(
                  'お試し3回分のAI解析を使い切りました。\n'
                  'ログインすると月90回までAI解析が使えます。',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogCtx),
                    child: const Text('後で'),
                  ),
                  FilledButton(
                    onPressed: () {
                      Navigator.pop(dialogCtx);
                      GoRouter.of(ctx).push('/login');
                    },
                    child: const Text('ログイン'),
                  ),
                ],
              ),
            );
          }
        }

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
