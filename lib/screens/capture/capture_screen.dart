import 'dart:convert';
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
import '../../services/location_service.dart';
import '../../services/photo_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/meal_type_picker.dart';
import '../editor/photo_edit_core.dart';
import '../editor/photo_editor_screen.dart';

class CaptureScreen extends ConsumerStatefulWidget {
  final List<XFile>? initialPhotos;
  final bool fromLibrary;

  const CaptureScreen({super.key, this.initialPhotos, this.fromLibrary = false});

  @override
  ConsumerState<CaptureScreen> createState() => _CaptureScreenState();
}

class _SelectedPhoto {
  final XFile originalFile; // 常にオリジナルを保持
  PhotoEditParams? editParams; // 編集パラメータ v2（nullなら未編集）
  DateTime? exifDateTime;
  double? exifLatitude;
  double? exifLongitude;
  _SelectedPhoto(this.originalFile);

  /// 見た目に影響する編集があるか（保存時に焼き込む対象か）
  bool get hasEdits => editParams != null && !editParams!.isIdentity;
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

  /// _capturedAt が写真のEXIF由来か(falseなら記録した時刻)
  bool _capturedAtFromExif = false;

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
    if (mounted) _adoptExifMetadata();
  }

  /// 記録(MealLog)の日時と場所を、選んだ写真から決める。
  ///
  /// 記録は日時と場所をひとつしか持てない。選択順の1枚目を使うと、
  /// 並び順で結果が変わってしまうので**一番古い写真**を基準にする
  /// (食事はその最初の1枚から始まっている)。写真ごとの日時・位置は
  /// 各写真にそのまま保存するので、ここで捨てているわけではない。
  void _adoptExifMetadata() {
    final withDate = _selectedPhotos
        .where((p) =>
            p.exifDateTime != null && p.exifDateTime!.isBefore(DateTime.now()))
        .toList()
      ..sort((a, b) => a.exifDateTime!.compareTo(b.exifDateTime!));
    final oldest = withDate.firstOrNull;

    // 位置は日時を採った写真のものを優先し、無ければ位置がある一番古い写真
    final withGps = _selectedPhotos
        .where((p) => p.exifLatitude != null && p.exifLongitude != null)
        .toList()
      ..sort((a, b) => (a.exifDateTime ?? DateTime(9999))
          .compareTo(b.exifDateTime ?? DateTime(9999)));
    final gpsSource = (oldest != null && oldest.exifLatitude != null)
        ? oldest
        : withGps.firstOrNull;

    // 写真を消したときも通るので、EXIF由来の値は毎回引き直す
    setState(() {
      if (oldest != null) {
        _capturedAt = oldest.exifDateTime!;
        _capturedAtFromExif = true;
      } else if (_capturedAtFromExif) {
        _capturedAt = DateTime.now();
        _capturedAtFromExif = false;
      }
    });

    // 利用者が明示的に消したものは復活させない
    if (_locationCleared) return;

    final next = gpsSource == null
        ? null
        : (lat: gpsSource.exifLatitude!, lng: gpsSource.exifLongitude!);
    if (_exifPosition == next) return;

    setState(() => _exifPosition = next);
    _resolveAddress();
  }

  /// 記録に使う位置。**写真のEXIFを優先**する。
  ///
  /// 端末のGPSは「いま画面を開いている場所」でしかない。過去の写真を
  /// 取り込んだときに現在地を使うと、まったく違う場所の記録になる。
  ({double lat, double lng})? get _effectivePosition =>
      _exifPosition ??
      (_position == null
          ? null
          : (lat: _position!.latitude, lng: _position!.longitude));

  Future<void> _fetchLocation() async {
    final pos = await LocationService.getCurrentPosition();
    if (!mounted) return;
    setState(() => _position = pos);
    await _resolveAddress();
  }

  /// いま採用している位置の住所を引き直す。
  Future<void> _resolveAddress() async {
    final target = _effectivePosition;
    if (target == null) {
      setState(() {
        _address = null;
        _loadingLocation = false;
      });
      return;
    }
    setState(() => _loadingLocation = true);

    final addr = await LocationService.getAddressFromPosition(
      Position(
        latitude: target.lat,
        longitude: target.lng,
        timestamp: DateTime.now(),
        accuracy: 0,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
      ),
    );
    if (!mounted) return;
    // 引いている間に写真が増減して位置が変わっていたら、その結果は捨てる
    if (_effectivePosition != target) return;
    setState(() {
      _address = addr;
      _loadingLocation = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('yyyy/M/d (E) HH:mm', 'ja');

    return Scaffold(
      appBar: AppBar(
        title: const Text('食事を記録'),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 写真から下は流し込み。写真の高さは枚数で決まるので、
            // 固定の枠に押し込めず内容なりに積む
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                children: [
                  _selectedPhotos.isEmpty
                      ? _buildPhotoPlaceholder()
                      : _buildPhotoGrid(),
                  const SizedBox(height: 12),

                  // 写真追加ボタン（入り方で出し分け）
                  OutlinedButton.icon(
                    onPressed:
                        widget.fromLibrary ? _pickFromLibrary : _takePhoto,
                    icon: Icon(widget.fromLibrary
                        ? Icons.photo_library_outlined
                        : Icons.add_a_photo_outlined),
                    label: Text(widget.fromLibrary ? 'ライブラリから追加' : '追加撮影'),
                  ),
                  const SizedBox(height: 20),

                  // 食事種別選択(詳細画面と同じボトムシート)
                  Text('食事の種類', style: KokoTokens.of(context).sectionLabel),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: MealTypeField(
                      value: _selectedType,
                      onChanged: (type) =>
                          setState(() => _selectedType = type),
                    ),
                  ),
                  const SizedBox(height: 14),

                  // 日時・位置情報
                  _buildMetadataBar(dateFormat),
                  _buildMixedMetadataNotice(),
                ],
              ),
            ),

            // 保存ボタン + AI解析トグル(常に手の届く位置に置く)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
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
                      onPressed:
                          _selectedPhotos.isEmpty || _saving ? null : _save,
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
            ),
          ],
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
    final position = _effectivePosition;
    final hasLocation = position != null;
    final tokens = KokoTokens.of(context);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tokens.hairline, width: 0.8),
      ),
      child: Column(
        children: [
          // 日時
          _metaRow(
            icon: Icons.schedule_outlined,
            child: Text(
              dateFormat.format(_capturedAt),
              style:
                  tokens.numeral.copyWith(fontSize: 12, color: tokens.textMuted),
            ),
            source: _capturedAtFromExif ? '写真の日時' : '記録した時刻',
          ),
          const SizedBox(height: 8),
          // 位置情報
          _metaRow(
            icon: Icons.location_on_outlined,
            dim: !hasLocation,
            child: _loadingLocation
                ? const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  )
                : hasLocation
                    ? Text(
                        _address ??
                            '${position.lat.toStringAsFixed(4)}, '
                            '${position.lng.toStringAsFixed(4)}',
                        style: TextStyle(fontSize: 12, color: tokens.textMuted),
                        overflow: TextOverflow.ellipsis,
                      )
                    : GestureDetector(
                        onTap: _locationCleared
                            ? _refetchLocation
                            : () {
                                setState(() => _loadingLocation = true);
                                _fetchLocation();
                              },
                        child: Text(
                          _locationCleared
                              ? '位置情報なし (タップで再取得)'
                              : '取得できません (タップで再取得)',
                          style:
                              TextStyle(fontSize: 12, color: tokens.textFaint),
                        ),
                      ),
            source: _loadingLocation
                ? null
                : _exifPosition != null
                    ? '写真の位置'
                    : _position != null
                        ? '今いる場所'
                        : null,
            trailing: hasLocation && !_loadingLocation
                ? GestureDetector(
                    onTap: _clearLocation,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child:
                          Icon(Icons.close, size: 16, color: tokens.textFaint),
                    ),
                  )
                : null,
          ),
        ],
      ),
    );
  }

  /// メタデータの1行。値の右に「どこから来た値か」を出す。
  /// 写真のEXIFなのか、いま端末から取ったものなのかで意味が変わるため
  Widget _metaRow({
    required IconData icon,
    required Widget child,
    String? source,
    Widget? trailing,
    bool dim = false,
  }) {
    final tokens = KokoTokens.of(context);
    return Row(
      children: [
        Icon(icon, size: 16, color: dim ? tokens.textFaint : tokens.textMuted),
        const SizedBox(width: 6),
        Expanded(child: child),
        if (source != null) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: tokens.hairline, width: 0.8),
            ),
            child: Text(
              source,
              style: TextStyle(fontSize: 10.5, color: tokens.textFaint),
            ),
          ),
        ],
        // 右端の操作が無い行も、下の行と左右の幅をそろえる
        trailing ?? const SizedBox(width: 24, height: 24),
      ],
    );
  }

  /// 選んだ写真の撮影日時・位置がばらついているときの注意書き。
  ///
  /// 記録は1件につき日時と場所をひとつしか持てないので、離れた写真を
  /// まとめると片方が捨てられたように見える。写真ごとの日時・位置は
  /// そのまま保存しているが、記録として何が採られたかは伝える。
  Widget _buildMixedMetadataNotice() {
    final message = _mixedMetadataMessage();
    if (message == null) return const SizedBox.shrink();
    final tokens = KokoTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 14, color: tokens.warning),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                  fontSize: 11.5, height: 1.5, color: tokens.warning),
            ),
          ),
        ],
      ),
    );
  }

  /// 同じ食事とみなすには離れすぎている閾値
  static const _mixedTimeGap = Duration(hours: 2);
  static const _mixedDistanceMeters = 300.0;

  String? _mixedMetadataMessage() {
    final times = _selectedPhotos
        .map((p) => p.exifDateTime)
        .whereType<DateTime>()
        .toList();
    final reasons = <String>[];

    if (times.length > 1) {
      times.sort();
      final gap = times.last.difference(times.first);
      if (gap > _mixedTimeGap) {
        final label = gap.inHours >= 24
            ? '${(gap.inHours / 24).floor()}日'
            : '${gap.inHours}時間';
        reasons.add('撮影日時が最大$label離れています');
      }
    }

    final points = _selectedPhotos
        .where((p) => p.exifLatitude != null && p.exifLongitude != null)
        .toList();
    if (points.length > 1) {
      var maxDistance = 0.0;
      for (var i = 1; i < points.length; i++) {
        final d = Geolocator.distanceBetween(
          points.first.exifLatitude!,
          points.first.exifLongitude!,
          points[i].exifLatitude!,
          points[i].exifLongitude!,
        );
        if (d > maxDistance) maxDistance = d;
      }
      if (maxDistance > _mixedDistanceMeters) {
        reasons.add('撮影場所が最大${(maxDistance / 1000).toStringAsFixed(1)}km離れています');
      }
    }

    if (reasons.isEmpty) return null;
    return '${reasons.join('、')}。'
        'この記録には一番古い写真の日時と場所を使います。'
        '別の食事なら分けて記録してください。';
  }

  Widget _buildPhotoPlaceholder() {
    final tokens = KokoTokens.of(context);
    return GestureDetector(
      onTap: _showPickerChoice,
      child: Container(
        height: 220,
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
    // 1枚だけなら列を分けずに大きく見せる。2枚以上は2列。
    // 3列だとタイルが小さすぎて、料理も上に乗るボタンも見えなかった
    final columns = _selectedPhotos.length == 1 ? 1 : 2;
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: _selectedPhotos.length,
      itemBuilder: (context, index) => _photoTile(index),
    );
  }

  /// 写真タイル。写真の上に置くのは「その写真への操作」だけにする。
  /// 撮影日時とAIの入り切りは記録ごとの設定で、下のメタデータ欄に出ている
  Widget _photoTile(int index) {
    final item = _selectedPhotos[index];
    final scheme = Theme.of(context).colorScheme;

    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: _buildPhotoThumbnail(item),
        ),
        // 編集(編集済みならボタン自体を色で示す。別バッジは出さない)
        Positioned(
          top: 2,
          left: 2,
          child: _tileButton(
            icon: Icons.tune,
            onTap: () => _editPhoto(index),
            background: item.hasEdits ? scheme.tertiary : Colors.black54,
            foreground: item.hasEdits ? scheme.onTertiary : Colors.white,
          ),
        ),
        Positioned(
          top: 2,
          right: 2,
          child: _tileButton(
            icon: Icons.close,
            onTap: () {
              setState(() => _selectedPhotos.removeAt(index));
              // 日時や場所をその写真から採っていたかもしれないので引き直す
              _adoptExifMetadata();
            },
          ),
        ),
      ],
    );
  }

  /// タイル上の丸ボタン。指で押せる大きさ(36)を確保する
  Widget _tileButton({
    required IconData icon,
    required VoidCallback onTap,
    Color background = Colors.black54,
    Color foreground = Colors.white,
  }) {
    return Material(
      color: background,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 36,
          height: 36,
          child: Icon(icon, size: 19, color: foreground),
        ),
      ),
    );
  }

  Widget _buildPhotoThumbnail(_SelectedPhoto item) {
    final image = Image.file(
      File(item.originalFile.path),
      fit: BoxFit.cover,
      gaplessPlayback: true,
    );

    // クロップ/回転は焼き込み前なのでプレビューには反映しない（編集済みバッジで示す）。
    // フィルターのみColorFilteredで反映する
    final filter = item.editParams?.filter;
    if (filter == null || filter.isIdentity) return image;

    return ColorFiltered(
      colorFilter: ColorFilter.matrix(buildEditColorMatrix(filter)),
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

    if (!mounted) return;
    setState(() => _selectedPhotos.addAll(items));
    _adoptExifMetadata();
  }

  Future<void> _editPhoto(int index) async {
    final item = _selectedPhotos[index];
    final outcome = await Navigator.push<PhotoEditOutcome>(
      context,
      MaterialPageRoute(
        builder: (_) => PhotoEditorScreen(
          imagePath: item.originalFile.path,
          initialParams: item.editParams,
        ),
      ),
    );
    if (outcome is PhotoEditApplied && mounted) {
      setState(() {
        // 恒等（編集なし）で確定された場合は未編集扱いに戻す
        item.editParams = outcome.params.isIdentity ? null : outcome.params;
      });
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    // 画面を閉じた後に通知を出すため、アプリ直下のMessengerを先に掴んでおく
    final messenger = ScaffoldMessenger.of(context);
    var bakeFailures = 0; // 焼き込みに失敗しオリジナルで保存した枚数

    try {
      final mealLogId = _uuid.v4();

      // 位置情報: 写真のEXIF > 端末のGPS(画面に出ている値と同じ順)
      final lat = _effectivePosition?.lat;
      final lng = _effectivePosition?.lng;

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

      // 写真を保存（編集がある場合は先にisolateで焼き込んでから保存）
      for (var i = 0; i < _selectedPhotos.length; i++) {
        final item = _selectedPhotos[i];
        // まずオリジナル（未編集）画像を保存
        final originalPath = await PhotoService.saveToLocalFromPath(
          item.originalFile.path,
        );

        // 編集がある場合はオリジナルへ焼き込み、パラメータもv2 JSONで保存する
        // （詳細画面からオリジナル基準で再編集できるようにする）
        String localPath = originalPath;
        String? editParamsJson;
        if (item.hasEdits) {
          final params = item.editParams!;
          final tmpDir = await getTemporaryDirectory();
          final outputPath =
              '${tmpDir.path}/edit_${DateTime.now().millisecondsSinceEpoch}_$i.jpg';
          final baked = await compute(
            bakePhotoEdit,
            PhotoEditBakeRequest(
              inputPath: item.originalFile.path,
              outputPath: outputPath,
              params: params,
            ),
          );
          if (baked != null) {
            localPath = await PhotoService.saveToLocalFromPath(baked);
            editParamsJson = jsonEncode(params.toJson());
            // ローカルへコピー済みなので焼き込みの一時ファイルは片付ける
            try {
              await File(baked).delete();
            } catch (_) {}
          } else {
            // 焼き込み失敗（非対応の画像形式やI/O失敗）。オリジナルで保存を
            // 続行し、後でまとめて通知する
            bakeFailures++;
          }
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
          skipAi: !_aiEnabled,
          aiStatus: _aiEnabled ? 'pending' : 'skipped',
          editParamsJson: editParamsJson,
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

      // 焼き込みに失敗した写真があれば通知（オリジナルで保存済み）
      if (bakeFailures > 0) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              '$bakeFailures枚の写真は編集を反映できませんでした（非対応の画像形式の可能性）',
            ),
          ),
        );
      }

      // --- 以下バックグラウンド処理（画面はすでに閉じている） ---

      // AI解析（端末内Gemma）
      await AiAnalysisService.processPendingPhotos();
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
