import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
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
import '../../services/location_service.dart';
import '../../services/photo_service.dart';
import '../../services/sync_service.dart';
import '../../widgets/ai_limit_dialog.dart';

class CaptureScreen extends ConsumerStatefulWidget {
  const CaptureScreen({super.key});

  @override
  ConsumerState<CaptureScreen> createState() => _CaptureScreenState();
}

class _SelectedPhoto {
  final XFile file;
  bool skipAi;
  _SelectedPhoto(this.file, {this.skipAi = false});
}

class _CaptureScreenState extends ConsumerState<CaptureScreen> {
  static const _uuid = Uuid();
  MealType _selectedType = MealType.eatingOut;
  final List<_SelectedPhoto> _selectedPhotos = [];
  bool _saving = false;

  // GPS・日時
  Position? _position;
  String? _address;
  bool _loadingLocation = true;
  late DateTime _capturedAt;

  @override
  void initState() {
    super.initState();
    _capturedAt = DateTime.now();
    _fetchLocation();
  }

  Future<void> _fetchLocation() async {
    final pos = await LocationService.getCurrentPosition();
    if (!mounted) return;

    setState(() {
      _position = pos;
      _loadingLocation = pos != null; // 住所取得中はまだloading
    });

    if (pos != null) {
      final addr = await LocationService.getAddressFromPosition(pos);
      if (mounted) {
        setState(() {
          _address = addr;
          _loadingLocation = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('yyyy/M/d (E) HH:mm', 'ja');

    return Scaffold(
      appBar: AppBar(
        title: const Text('食事を記録'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 写真表示エリア
              Expanded(
                child: _selectedPhotos.isEmpty
                    ? _buildPhotoPlaceholder()
                    : _buildPhotoGrid(),
              ),
              const SizedBox(height: 12),

              // 写真追加ボタン
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _takePhoto,
                      icon: const Icon(Icons.camera_alt),
                      label: const Text('撮影'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickFromLibrary,
                      icon: const Icon(Icons.photo_library),
                      label: const Text('ライブラリ'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // 食事種別選択
              SegmentedButton<MealType>(
                segments: MealType.values
                    .map((type) => ButtonSegment(
                          value: type,
                          label: Text(type.label),
                        ))
                    .toList(),
                selected: {_selectedType},
                onSelectionChanged: (selected) {
                  setState(() => _selectedType = selected.first);
                },
              ),
              const SizedBox(height: 12),

              // 日時・位置情報
              _buildMetadataBar(dateFormat),
              const SizedBox(height: 12),

              // 保存ボタン
              FilledButton.icon(
                onPressed: _selectedPhotos.isEmpty || _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check),
                label: Text(_saving ? '保存中...' : '保存'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(56),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMetadataBar(DateFormat dateFormat) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          // 日時
          Icon(Icons.schedule, size: 16, color: Colors.grey[600]),
          const SizedBox(width: 4),
          Text(
            dateFormat.format(_capturedAt),
            style: TextStyle(fontSize: 12, color: Colors.grey[700]),
          ),
          const SizedBox(width: 12),
          // 位置情報
          Icon(Icons.location_on, size: 16, color: Colors.grey[600]),
          const SizedBox(width: 4),
          Expanded(
            child: _loadingLocation
                ? const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  )
                : _position != null
                    ? Text(
                        _address ?? '${_position!.latitude.toStringAsFixed(4)}, ${_position!.longitude.toStringAsFixed(4)}',
                        style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                        overflow: TextOverflow.ellipsis,
                      )
                    : GestureDetector(
                        onTap: () {
                          setState(() => _loadingLocation = true);
                          _fetchLocation();
                        },
                        child: Text(
                          '取得できません (タップで再取得)',
                          style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildPhotoPlaceholder() {
    return GestureDetector(
      onTap: _showPickerChoice,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.grey[200],
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.grey[400]!),
        ),
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_a_photo, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text(
              'タップして写真を撮影・選択',
              style: TextStyle(fontSize: 16, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPhotoGrid() {
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: _selectedPhotos.length,
      itemBuilder: (context, index) {
        final item = _selectedPhotos[index];
        return Stack(
          fit: StackFit.expand,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.file(
                File(item.file.path),
                fit: BoxFit.cover,
              ),
            ),
            // AI解析スキップ表示
            if (item.skipAi)
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black26,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Center(
                    child: Icon(Icons.visibility_off, color: Colors.white70, size: 28),
                  ),
                ),
              ),
            // 削除ボタン
            Positioned(
              top: 4,
              right: 4,
              child: GestureDetector(
                onTap: () {
                  setState(() => _selectedPhotos.removeAt(index));
                },
                child: Container(
                  decoration: const BoxDecoration(
                    color: Colors.black54,
                    shape: BoxShape.circle,
                  ),
                  padding: const EdgeInsets.all(4),
                  child: const Icon(Icons.close, size: 16, color: Colors.white),
                ),
              ),
            ),
            // AI解析スキップ切り替え
            Positioned(
              bottom: 4,
              left: 4,
              child: GestureDetector(
                onTap: () {
                  setState(() => item.skipAi = !item.skipAi);
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: item.skipAi ? Colors.orange : Colors.black54,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        item.skipAi ? Icons.visibility_off : Icons.auto_awesome,
                        size: 12,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 2),
                      Text(
                        item.skipAi ? 'AI off' : 'AI',
                        style: const TextStyle(fontSize: 10, color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _showPickerChoice() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('カメラで撮影'),
              onTap: () {
                Navigator.pop(context);
                _takePhoto();
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('ライブラリから選択'),
              onTap: () {
                Navigator.pop(context);
                _pickFromLibrary();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _takePhoto() async {
    final photo = await PhotoService.takePhoto();
    if (photo != null) {
      setState(() => _selectedPhotos.add(_SelectedPhoto(photo)));
    }
  }

  Future<void> _pickFromLibrary() async {
    final photos = await PhotoService.pickPhotos();
    if (photos.isNotEmpty) {
      setState(() => _selectedPhotos.addAll(photos.map((p) => _SelectedPhoto(p))));
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);

    try {
      final mealLogId = _uuid.v4();

      // 自宅判定: GPSと保存済み場所を比較
      String? locationTag;
      if (_position != null) {
        final savedPlaces = await LocalDatabase.getSavedPlaces();
        debugPrint('[Location] GPS: ${_position!.latitude}, ${_position!.longitude}, SavedPlaces: ${savedPlaces.length}');
        for (final place in savedPlaces) {
          final distance = Geolocator.distanceBetween(
            _position!.latitude,
            _position!.longitude,
            place.latitude,
            place.longitude,
          );
          debugPrint('[Location] ${place.name}(${place.iconType}): ${distance.toStringAsFixed(0)}m');
          if (distance <= 100) {
            locationTag = place.iconType == 'home' ? 'home' : place.id;
            break;
          }
        }
        debugPrint('[Location] Tag: $locationTag');
      } else {
        debugPrint('[Location] No GPS position available');
      }

      // 食事記録を作成
      final mealLog = MealLog(
        id: mealLogId,
        mealType: _selectedType,
        eatenAt: _capturedAt,
        latitude: _position?.latitude,
        longitude: _position?.longitude,
        locationTag: locationTag,
        createdAt: DateTime.now(),
      );
      await LocalDatabase.insertMealLog(mealLog);

      // 写真を保存
      for (final item in _selectedPhotos) {
        final localPath = await PhotoService.saveToLocal(item.file);
        final thumbnailPath = await PhotoService.generateThumbnail(localPath);

        final photo = MealPhoto(
          id: _uuid.v4(),
          mealLogId: mealLogId,
          localPath: localPath,
          thumbnailUrl: thumbnailPath,
          skipAi: item.skipAi,
          aiStatus: item.skipAi ? 'skipped' : 'pending',
          shotAt: _capturedAt,
          latitude: _position?.latitude,
          longitude: _position?.longitude,
          createdAt: DateTime.now(),
        );
        await LocalDatabase.insertMealPhoto(photo);
      }

      // 一覧を更新
      ref.read(mealLogsProvider.notifier).refresh();

      // AI解析のレート制限チェック
      final rateLimitStatus = await AiRateLimitService.getStatus();
      if (rateLimitStatus.canUse) {
        // AI解析をバックグラウンドで実行（結果を待たない）
        AiAnalysisService.processPendingPhotos().then((_) {
          if (mounted) ref.read(mealLogsProvider.notifier).refresh();
          if (AuthService.isLoggedIn) SyncService.syncAll();
        });
      } else if (mounted) {
        // 上限到達を通知
        final recovered = await showAiLimitDialog(context, rateLimitStatus);
        if (recovered == true) {
          // 広告で回復した場合、解析を実行
          AiAnalysisService.processPendingPhotos().then((_) {
            if (mounted) ref.read(mealLogsProvider.notifier).refresh();
            if (AuthService.isLoggedIn) SyncService.syncAll();
          });
        }
      }

      // ログイン中ならクラウドに同期（バックグラウンド）
      if (AuthService.isLoggedIn) {
        SyncService.syncAll();
      }

      if (mounted) context.pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存に失敗しました: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
