import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../database/local_database.dart';
import '../../models/meal_log.dart';
import '../../models/meal_photo.dart';
import '../../models/meal_type.dart';
import '../../providers/meal_providers.dart';
import '../../services/ai_analysis_service.dart';
import '../../app.dart';
import '../../services/auth_service.dart';
import '../../services/location_service.dart';
import '../../services/photo_service.dart';
import '../../services/sync_service.dart';
import '../../theme/app_theme.dart';
import '../../theme/meal_type_style.dart';
import 'photo_editor_screen.dart';

class CaptureScreen extends ConsumerStatefulWidget {
  final List<XFile>? initialPhotos;
  final bool fromLibrary;

  const CaptureScreen({super.key, this.initialPhotos, this.fromLibrary = false});

  @override
  ConsumerState<CaptureScreen> createState() => _CaptureScreenState();
}

class _SelectedPhoto {
  final XFile originalFile; // 常にオリジナルを保持
  bool skipAi = false;
  PhotoEditResult? editParams; // 編集パラメータ（nullなら未編集）
  DateTime? exifDateTime;
  double? exifLatitude;
  double? exifLongitude;
  _SelectedPhoto(this.originalFile);

  /// 表示用パス（クロップがあればクロップ済み、なければオリジナル）
  String get displayPath => editParams?.croppedPath ?? originalFile.path;

  /// 保存用のソースパス（クロップ優先）
  String get sourcePathForSave => editParams?.croppedPath ?? originalFile.path;
}

class _CaptureScreenState extends ConsumerState<CaptureScreen> {
  static const _uuid = Uuid();
  MealType _selectedType = MealType.unset;
  final List<_SelectedPhoto> _selectedPhotos = [];
  bool _saving = false;
  bool _aiEnabled = true; // AI解析ON/OFF

  // GPS・日時
  Position? _position;
  ({double lat, double lng})? _exifPosition; // EXIFからのGPS（Positionがない場合）
  String? _address;
  bool _loadingLocation = true;
  late DateTime _capturedAt;

  @override
  void initState() {
    super.initState();
    _capturedAt = DateTime.now();
    _fetchLocation();
    if (widget.initialPhotos != null && widget.initialPhotos!.isNotEmpty) {
      for (final photo in widget.initialPhotos!) {
        _selectedPhotos.add(_SelectedPhoto(photo));
      }
      _readExifForInitialPhotos();
    }
  }

  Future<void> _readExifForInitialPhotos() async {
    for (final item in _selectedPhotos) {
      final exif = await PhotoService.readExifData(item.originalFile.path);
      if (exif.hasDateTime) item.exifDateTime = exif.dateTime;
      if (exif.hasLocation) {
        item.exifLatitude = exif.latitude;
        item.exifLongitude = exif.longitude;
      }
    }

    final firstWithDate = _selectedPhotos.where((i) => i.exifDateTime != null).firstOrNull;
    final firstWithGps = _selectedPhotos.where((i) => i.exifLatitude != null).firstOrNull;

    if (mounted) {
      setState(() {
        if (firstWithDate != null && firstWithDate.exifDateTime!.isBefore(DateTime.now())) {
          _capturedAt = firstWithDate.exifDateTime!;
        }
        if (_position == null && firstWithGps != null) {
          _exifPosition = (lat: firstWithGps.exifLatitude!, lng: firstWithGps.exifLongitude!);
          _loadingLocation = true;
        }
      });
      if (firstWithGps != null && _position == null) {
        _fetchAddressFromCoords(firstWithGps.exifLatitude!, firstWithGps.exifLongitude!);
      }
    }
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

  Future<void> _fetchAddressFromCoords(double lat, double lng) async {
    final pos = Position(
      latitude: lat,
      longitude: lng,
      timestamp: DateTime.now(),
      accuracy: 0,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );
    final addr = await LocationService.getAddressFromPosition(pos);
    if (mounted) {
      setState(() {
        _address = addr;
        _loadingLocation = false;
      });
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

              // 写真追加ボタン（入り方で出し分け）
              OutlinedButton.icon(
                onPressed: widget.fromLibrary ? _pickFromLibrary : _takePhoto,
                icon: Icon(widget.fromLibrary
                    ? Icons.photo_library_outlined
                    : Icons.add_a_photo_outlined),
                label: Text(widget.fromLibrary ? 'ライブラリから追加' : '追加撮影'),
              ),
              const SizedBox(height: 16),

              // 食事種別選択
              Text('食事の種類', style: KokoTokens.of(context).sectionLabel),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: MealType.values
                    .map((type) => _mealTypeChoice(type, type == _selectedType))
                    .toList(),
              ),
              const SizedBox(height: 12),

              // 日時・位置情報
              _buildMetadataBar(dateFormat),
              const SizedBox(height: 12),

              // 保存ボタン + AI解析トグル
              Row(
                children: [
                  // AI解析ON/OFFトグル
                  Material(
                    color: _aiEnabled
                        ? Theme.of(context).colorScheme.primaryContainer
                        : Theme.of(context).colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => setState(() => _aiEnabled = !_aiEnabled),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _aiEnabled ? Icons.auto_awesome : Icons.auto_awesome_outlined,
                              size: 20,
                              color: _aiEnabled
                                  ? Theme.of(context).colorScheme.onPrimaryContainer
                                  : KokoTokens.of(context).textMuted,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'AI',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: _aiEnabled
                                    ? Theme.of(context).colorScheme.onPrimaryContainer
                                    : KokoTokens.of(context).textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 保存ボタン
                  Expanded(
                    child: FilledButton.icon(
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
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool _locationCleared = false;

  void _clearLocation() {
    setState(() {
      _position = null;
      _exifPosition = null;
      _address = null;
      _loadingLocation = false;
      _locationCleared = true;
    });
  }

  void _refetchLocation() {
    setState(() {
      _loadingLocation = true;
      _locationCleared = false;
    });
    _fetchLocation();
  }

  Widget _buildMetadataBar(DateFormat dateFormat) {
    final hasLocation = _position != null || _exifPosition != null;
    final tokens = KokoTokens.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tokens.hairline, width: 0.8),
      ),
      child: Row(
        children: [
          // 日時
          Icon(Icons.schedule_outlined, size: 16, color: tokens.textMuted),
          const SizedBox(width: 4),
          Text(
            dateFormat.format(_capturedAt),
            style: tokens.numeral
                .copyWith(fontSize: 12, color: tokens.textMuted),
          ),
          const SizedBox(width: 12),
          // 位置情報
          Icon(Icons.location_on_outlined, size: 16,
            color: hasLocation ? tokens.textMuted : tokens.textFaint),
          const SizedBox(width: 4),
          Expanded(
            child: _loadingLocation
                ? const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  )
                : hasLocation
                    ? Text(
                        _address ??
                            '${(_position?.latitude ?? _exifPosition?.lat)?.toStringAsFixed(4)}, '
                            '${(_position?.longitude ?? _exifPosition?.lng)?.toStringAsFixed(4)}',
                        style: TextStyle(fontSize: 12, color: tokens.textMuted),
                        overflow: TextOverflow.ellipsis,
                      )
                    : GestureDetector(
                        onTap: _locationCleared ? _refetchLocation : () {
                          setState(() => _loadingLocation = true);
                          _fetchLocation();
                        },
                        child: Text(
                          _locationCleared ? '位置情報なし (タップで再取得)' : '取得できません (タップで再取得)',
                          style: TextStyle(fontSize: 12, color: tokens.textFaint),
                        ),
                      ),
          ),
          // 位置情報クリア/再取得
          if (hasLocation && !_loadingLocation)
            GestureDetector(
              onTap: _clearLocation,
              child: Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Icon(Icons.close, size: 16, color: tokens.textFaint),
              ),
            ),
        ],
      ),
    );
  }

  /// 食事種別の選択チップ(MealTypeStyleの色/アイコンを使用)
  Widget _mealTypeChoice(MealType type, bool selected) {
    final tokens = KokoTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final fg = selected ? type.fg(context) : tokens.textMuted;
    return Material(
      color: selected ? type.bg(context) : scheme.surfaceContainerHigh,
      shape: StadiumBorder(
        side: BorderSide(
          color: selected
              ? type.fg(context).withValues(alpha: 0.4)
              : tokens.hairline,
          width: 0.8,
        ),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: () => setState(() => _selectedType = type),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(type.icon, size: 15, color: fg),
              const SizedBox(width: 4),
              Text(
                type.label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPhotoPlaceholder() {
    final tokens = KokoTokens.of(context);
    return GestureDetector(
      onTap: _showPickerChoice,
      child: Container(
        decoration: BoxDecoration(
          color: tokens.photoPlaceholder,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: tokens.hairline, width: 0.8),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_a_photo_outlined, size: 56, color: tokens.textFaint),
            const SizedBox(height: 16),
            Text(
              'タップして写真を撮影・選択',
              style: TextStyle(fontSize: 14, color: tokens.textMuted),
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
        final scheme = Theme.of(context).colorScheme;
        return Stack(
          fit: StackFit.expand,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: _buildPhotoThumbnail(item),
            ),
            // EXIF日時（ライブラリ写真で日時がある場合）
            if (item.exifDateTime != null)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Colors.black54, Colors.transparent],
                    ),
                    borderRadius:
                        BorderRadius.vertical(bottom: Radius.circular(12)),
                  ),
                  padding: const EdgeInsets.fromLTRB(6, 16, 6, 4),
                  child: Text(
                    DateFormat('M/d HH:mm').format(item.exifDateTime!),
                    style: const TextStyle(color: Colors.white, fontSize: 10),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            // 編集済みバッジ
            if (item.editParams?.hasEdits == true)
              Positioned(
                bottom: item.exifDateTime != null ? 20 : 4,
                right: 4,
                child: Container(
                  decoration: BoxDecoration(
                    color: scheme.tertiary,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Icon(Icons.tune, size: 12, color: scheme.onTertiary),
                ),
              ),
            // AI解析スキップ表示
            if (item.skipAi)
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black26,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Center(
                    child: Icon(Icons.visibility_off_outlined,
                        color: Colors.white70, size: 28),
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
            // 編集ボタン
            Positioned(
              top: 4,
              left: 4,
              child: GestureDetector(
                onTap: () => _editPhoto(index),
                child: Container(
                  decoration: const BoxDecoration(
                    color: Colors.black54,
                    shape: BoxShape.circle,
                  ),
                  padding: const EdgeInsets.all(4),
                  child: const Icon(Icons.tune, size: 16, color: Colors.white),
                ),
              ),
            ),
            // AI解析スキップ切り替え
            Positioned(
              bottom: item.exifDateTime != null ? 20 : 4,
              left: 4,
              child: GestureDetector(
                onTap: () {
                  setState(() => item.skipAi = !item.skipAi);
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: item.skipAi ? scheme.tertiary : Colors.black54,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        item.skipAi
                            ? Icons.visibility_off_outlined
                            : Icons.auto_awesome,
                        size: 12,
                        color: item.skipAi ? scheme.onTertiary : Colors.white,
                      ),
                      const SizedBox(width: 2),
                      Text(
                        item.skipAi ? 'AI OFF' : 'AI',
                        style: TextStyle(
                          fontSize: 10,
                          color: item.skipAi ? scheme.onTertiary : Colors.white,
                        ),
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

  Widget _buildPhotoThumbnail(_SelectedPhoto item) {
    final image = Image.file(
      File(item.displayPath),
      fit: BoxFit.cover,
      gaplessPlayback: true,
    );

    final params = item.editParams;
    if (params == null || !params.hasEdits) return image;

    // フィルター調整があればColorFilteredで反映
    final hasFilterEdits = params.brightness != 0 ||
        params.contrast != 0 ||
        params.saturation != 0 ||
        params.warmth != 0;

    if (!hasFilterEdits) return image;

    return ColorFiltered(
      colorFilter: ColorFilter.matrix(buildEditColorMatrix(params)),
      child: image,
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
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('カメラで撮影'),
              onTap: () {
                Navigator.pop(context);
                _takePhoto();
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
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
    if (photos.isEmpty) return;

    final items = <_SelectedPhoto>[];
    for (final photo in photos) {
      final item = _SelectedPhoto(photo);
      // EXIFからメタデータを読み取る
      final exif = await PhotoService.readExifData(photo.path);
      item.exifDateTime = exif.dateTime;
      item.exifLatitude = exif.latitude;
      item.exifLongitude = exif.longitude;
      items.add(item);
    }

    // 最初のEXIF情報でメタデータを補完（GPSや日時が未取得の場合）
    final firstWithDate = items.where((i) => i.exifDateTime != null).firstOrNull;
    final firstWithGps = items.where((i) => i.exifLatitude != null).firstOrNull;

    setState(() {
      _selectedPhotos.addAll(items);

      // ライブラリ画像のEXIF日時を使用（現在の日時より過去なら採用）
      if (firstWithDate != null && firstWithDate.exifDateTime!.isBefore(DateTime.now())) {
        _capturedAt = firstWithDate.exifDateTime!;
      }

      // GPS未取得時にEXIFのGPSを使用
      if (_position == null && firstWithGps != null) {
        _exifPosition = (lat: firstWithGps.exifLatitude!, lng: firstWithGps.exifLongitude!);
        _loadingLocation = true;
        _fetchAddressFromCoords(firstWithGps.exifLatitude!, firstWithGps.exifLongitude!);
      }
    });
  }

  Future<void> _editPhoto(int index) async {
    final item = _selectedPhotos[index];
    final result = await Navigator.push<PhotoEditResult>(
      context,
      MaterialPageRoute(
        builder: (_) => PhotoEditorScreen(
          filePath: item.originalFile.path,
          initialParams: item.editParams,
        ),
      ),
    );
    if (result != null && mounted) {
      setState(() {
        item.editParams = result;
      });
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);

    try {
      final mealLogId = _uuid.v4();

      // 位置情報: GPS > EXIF の優先順
      final lat = _position?.latitude ?? _exifPosition?.lat;
      final lng = _position?.longitude ?? _exifPosition?.lng;

      // 自宅判定: GPSと保存済み場所を比較
      String? locationTag;
      if (lat != null && lng != null) {
        final savedPlaces = await LocalDatabase.getSavedPlaces();
        for (final place in savedPlaces) {
          final distance = Geolocator.distanceBetween(
            lat, lng,
            place.latitude,
            place.longitude,
          );
          if (distance <= 100) {
            locationTag = place.iconType == 'home' ? 'home' : place.id;
            break;
          }
        }
      }

      // 食事記録を作成
      final mealLog = MealLog(
        id: mealLogId,
        mealType: _selectedType,
        eatenAt: _capturedAt,
        latitude: lat,
        longitude: lng,
        locationTag: locationTag,
        createdAt: DateTime.now(),
      );
      await LocalDatabase.insertMealLog(mealLog);

      // 写真を保存（編集がある場合は先にisolateで処理してから保存）
      for (final item in _selectedPhotos) {
        // まずオリジナル（未編集）画像を保存
        final originalPath = await PhotoService.saveToLocalFromPath(
          item.originalFile.path,
        );

        String fileToSave = item.sourcePathForSave;
        final hasEdits = item.editParams != null && item.editParams!.hasEdits == true;

        // フィルター編集がある場合、先にisolateで処理
        if (hasEdits) {
          final params = item.editParams!;
          final hasFilterEdits = params.brightness != 0 ||
              params.contrast != 0 ||
              params.saturation != 0 ||
              params.warmth != 0 ||
              params.vignette != 0;

          if (hasFilterEdits) {
            final tmpDir = await getTemporaryDirectory();
            final outputPath = '${tmpDir.path}/edit_${DateTime.now().millisecondsSinceEpoch}_${_selectedPhotos.indexOf(item)}.jpg';
            final processed = await compute(processEditedImage, ImageProcessParams(
              inputPath: fileToSave,
              outputPath: outputPath,
              brightness: params.brightness,
              contrast: params.contrast,
              saturation: params.saturation,
              warmth: params.warmth,
              vignette: params.vignette,
            ));
            if (processed != null) {
              fileToSave = processed;
            }
          }
        }

        // 編集済み（or 未編集）ファイルを保存
        final String localPath;
        if (hasEdits) {
          localPath = await PhotoService.saveToLocalFromPath(fileToSave);
        } else {
          // 編集なし: オリジナルと同じパス
          localPath = originalPath;
        }
        final thumbnailPath = await PhotoService.generateThumbnail(localPath);

        final photoLat = item.exifLatitude ?? lat;
        final photoLng = item.exifLongitude ?? lng;
        final photoShotAt = item.exifDateTime ?? _capturedAt;

        final photo = MealPhoto(
          id: _uuid.v4(),
          mealLogId: mealLogId,
          localPath: localPath,
          originalLocalPath: originalPath,
          thumbnailUrl: thumbnailPath,
          skipAi: item.skipAi || !_aiEnabled,
          aiStatus: (item.skipAi || !_aiEnabled) ? 'skipped' : 'pending',
          shotAt: photoShotAt,
          latitude: photoLat,
          longitude: photoLng,
          createdAt: DateTime.now(),
        );
        await LocalDatabase.insertMealPhoto(photo);
      }

      // 一覧を更新して画面を閉じる
      ref.read(mealLogsProvider.notifier).refresh();
      if (mounted) context.pop();

      // --- 以下バックグラウンド処理（画面はすでに閉じている） ---

      // AI解析（Edge Function経由）
      AiAnalysisService.anonymousLimitReached = false;
      await AiAnalysisService.processPendingPhotos();

      // 匿名ユーザーのAI解析上限に達した場合、ログイン促進ダイアログを表示
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

      // ログイン中ならクラウドに同期
      if (AuthService.isLoggedIn) {
        SyncService.syncAll();
      }
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
