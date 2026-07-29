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
import '../../providers/map_focus_providers.dart';
import '../../providers/meal_providers.dart';
import '../../services/ai_analysis_service.dart';
import 'package:geolocator/geolocator.dart';
import '../../services/photo_service.dart';
import '../capture/camera_screen.dart';
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
  void initState() {
    super.initState();
    // アプリ起動時、未解析(pending)のまま残っている写真があれば解析を回す
    // (モデルDL前に保存した写真などが「解析中」のまま止まらないように)
    _runBackgroundAi();
  }

  @override
  Widget build(BuildContext context) {
    // 詳細画面などから場所を指定されたらマップへ切り替える。
    // 寄る操作自体はマップ側が行う
    ref.listen(mapFocusProvider, (_, next) {
      if (next != null && _currentIndex != 1) {
        setState(() => _currentIndex = 1);
      }
    });

    return Scaffold(
      body: _tabs[_currentIndex],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex == 0 ? 0 : 2,
        onDestinationSelected: _onDestinationSelected,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.receipt_long_outlined),
            selectedIcon: Icon(Icons.receipt_long),
            label: '記録',
          ),
          NavigationDestination(
            icon: _CameraDestinationIcon(),
            label: '撮影',
          ),
          NavigationDestination(
            icon: Icon(Icons.map_outlined),
            selectedIcon: Icon(Icons.map),
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

  /// カメラ直接起動 → カメラ画面内で確認 → 保存
  Future<void> _onCameraPressed() async {
    final result = await Navigator.push<CameraCaptureResult>(
      context,
      MaterialPageRoute(builder: (_) => const CameraScreen()),
    );
    if (result == null || !mounted) return;

    await _quickSavePhoto(
      result.photo,
      aiEnabled: result.aiEnabled,
      position: result.position,
      address: result.address,
      locationTag: result.locationTag,
    );
  }

  /// ライブラリから選択 → CaptureScreen へ
  Future<void> _onLibraryPressed() async {
    final photos = await PhotoService.pickPhotos();
    if (photos.isEmpty || !mounted) return;
    await _handleLibraryPhotos(photos);
  }

  /// カメラ撮影 → 即保存（マージ判定あり）
  Future<void> _quickSavePhoto(
    XFile xfile, {
    bool aiEnabled = true,
    Position? position,
    String? address,
    String? locationTag,
  }) async {
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

    // 新規記録として即保存（GPS・場所はカメラ画面から受け取り済み）
    final mealLogId = _uuid.v4();
    final double? lat = position?.latitude;
    final double? lng = position?.longitude;

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
    _runBackgroundAi();
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

    _runBackgroundAi();
  }

  /// バックグラウンドAI解析。
  /// 起動時(initState)にも呼ばれるため例外は握って落とさない
  /// (テスト環境のDB未初期化や、起動直後のI/O失敗でクラッシュさせない)
  Future<void> _runBackgroundAi() async {
    try {
      await AiAnalysisService.processPendingPhotos();
      if (mounted) ref.read(mealLogsProvider.notifier).refresh();
    } catch (e) {
      debugPrint('[Home] background AI failed: $e');
    }
  }
}

/// 中央「撮影」用の主ボタン: 漆色(primary)の円形地に白のカメラアイコン
class _CameraDestinationIcon extends StatelessWidget {
  const _CameraDestinationIcon();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 38,
      height: 38,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.primary,
        shape: BoxShape.circle,
      ),
      child: Icon(Icons.photo_camera, size: 20, color: scheme.onPrimary),
    );
  }
}
