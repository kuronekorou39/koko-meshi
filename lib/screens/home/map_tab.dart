import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../../database/local_database.dart';
import '../../models/meal_log.dart';
import '../../models/meal_photo.dart';
import '../../models/meal_type.dart';
import '../../models/saved_place.dart';
import '../../providers/meal_providers.dart';
import '../../services/location_service.dart';
import '../../services/places_service.dart';

const double _searchRadiusMeters = 500;

class MapTab extends ConsumerStatefulWidget {
  const MapTab({super.key});

  @override
  ConsumerState<MapTab> createState() => _MapTabState();
}

class _MapTabState extends ConsumerState<MapTab> {
  GoogleMapController? _mapController;
  LatLng _initialPosition = const LatLng(35.6812, 139.7671);
  LatLng _currentCenter = const LatLng(35.6812, 139.7671);
  bool _loadingPosition = true;
  String? _mapStyleBase;
  bool _isTilted = true;

  // マーカー
  Set<Marker> _mealMarkers = {};
  // 蓄積型: placeId → Marker
  final Map<String, Marker> _placeMarkersMap = {};
  // 蓄積型: placeId → PlaceInfo（タップ用）
  final Map<String, PlaceInfo> _placeInfoMap = {};

  // 検索ボタン表示フラグ
  bool _showSearchButton = false;
  bool _isSearching = false;

  // ボトムシート
  _SheetContent? _sheetContent;
  bool _sheetVisible = false;

  @override
  void initState() {
    super.initState();
    _loadMapStyle();
    _initCurrentPosition();
  }

  @override
  void dispose() {
    _mapController?.dispose();
    super.dispose();
  }

  Future<void> _loadMapStyle() async {
    final style = await rootBundle.loadString('assets/map_style.json');
    setState(() => _mapStyleBase = style);
  }

  Future<void> _initCurrentPosition() async {
    final pos = await LocationService.getCurrentPosition();
    if (mounted && pos != null) {
      final latLng = LatLng(pos.latitude, pos.longitude);
      setState(() {
        _initialPosition = latLng;
        _currentCenter = latLng;
        _loadingPosition = false;
      });
      _mapController?.animateCamera(CameraUpdate.newLatLng(latLng));
    } else if (mounted) {
      setState(() => _loadingPosition = false);
    }
  }

  Future<void> _loadMealMarkers() async {
    final mealLogs = await LocalDatabase.getMealLogs();
    final savedPlaces = await LocalDatabase.getSavedPlaces();
    final markers = <Marker>{};

    for (final log in mealLogs) {
      final photos = await LocalDatabase.getPhotosForMealLog(log.id);
      final photoWithLocation = photos.cast<MealPhoto?>().firstWhere(
        (p) => p!.latitude != null && p.longitude != null,
        orElse: () => null,
      );
      if (photoWithLocation == null) continue;

      final hue = switch (log.mealType) {
        MealType.eatingOut => BitmapDescriptor.hueOrange,
        MealType.homeCooking => BitmapDescriptor.hueGreen,
        MealType.delivery => BitmapDescriptor.hueBlue,
      };

      markers.add(
        Marker(
          markerId: MarkerId('meal_${log.id}'),
          position: LatLng(photoWithLocation.latitude!, photoWithLocation.longitude!),
          icon: BitmapDescriptor.defaultMarkerWithHue(hue),
          zIndexInt: 2,
          onTap: () => _showMealSheet(log, photos),
        ),
      );
    }

    for (final place in savedPlaces) {
      markers.add(
        Marker(
          markerId: MarkerId('saved_${place.id}'),
          position: LatLng(place.latitude, place.longitude),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueViolet),
          zIndexInt: 3,
          infoWindow: InfoWindow(title: place.name),
        ),
      );
    }

    if (mounted) setState(() => _mealMarkers = markers);
  }

  /// カスタムラベル付きマーカーを生成
  Future<BitmapDescriptor> _createLabeledMarker(String label) async {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final truncated = label.length > 5 ? '${label.substring(0, 5)}…' : label;

    final textPainter = TextPainter(
      text: TextSpan(
        text: truncated,
        style: TextStyle(
          fontSize: 9 * dpr,
          color: const Color(0xFF333333),
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();

    final padding = 2.0 * dpr;
    final pinR = 5.0 * dpr;
    final gap = 1.0 * dpr;
    final bgW = textPainter.width + padding * 2;
    final bgH = textPainter.height + padding;
    final w = math.max(bgW, pinR * 2);
    final h = pinR * 2 + gap + bgH;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w, h));

    // ピン
    canvas.drawCircle(
      Offset(w / 2, pinR),
      pinR,
      Paint()..color = const Color(0xFFE53935),
    );
    canvas.drawCircle(
      Offset(w / 2, pinR),
      pinR,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2 * dpr,
    );

    // ラベル背景
    final bgRect = RRect.fromRectAndRadius(
      Rect.fromLTWH((w - bgW) / 2, pinR * 2 + gap, bgW, bgH),
      Radius.circular(2 * dpr),
    );
    canvas.drawRRect(bgRect, Paint()..color = const Color(0xDDFFFFFF));

    // ラベルテキスト
    textPainter.paint(
      canvas,
      Offset((w - textPainter.width) / 2, pinR * 2 + gap + padding / 2),
    );

    final picture = recorder.endRecording();
    final image = await picture.toImage(w.ceil(), h.ceil());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);

    return BitmapDescriptor.bytes(
      bytes!.buffer.asUint8List(),
      imagePixelRatio: dpr,
    );
  }

  Future<void> _searchNearbyRestaurants() async {
    setState(() => _isSearching = true);

    final searchCenter = _currentCenter;
    final places = await PlacesService.searchNearbyRestaurants(
      latitude: searchCenter.latitude,
      longitude: searchCenter.longitude,
      radiusMeters: _searchRadiusMeters,
    );

    if (!mounted) return;

    // 結果を蓄積（重複はplaceIdで除外）
    for (final place in places) {
      if (_placeInfoMap.containsKey(place.id)) continue;

      _placeInfoMap[place.id] = place;
      final icon = await _createLabeledMarker(place.name);
      if (!mounted) return;

      _placeMarkersMap[place.id] = Marker(
        markerId: MarkerId('place_${place.id}'),
        position: LatLng(place.latitude, place.longitude),
        icon: icon,
        anchor: const Offset(0.5, 0.3),
        zIndexInt: 1,
        alpha: 0.9,
        onTap: () => _showPlaceSheet(_placeInfoMap[place.id]!),
      );
    }

    setState(() {
      _showSearchButton = false;
      _isSearching = false;
    });
  }

  void _showMealSheet(MealLog log, List<MealPhoto> photos) {
    setState(() {
      _sheetContent = _SheetContent(mealLog: log, photos: photos);
      _sheetVisible = true;
    });
  }

  void _showPlaceSheet(PlaceInfo place) {
    setState(() {
      _sheetContent = _SheetContent(place: place);
      _sheetVisible = true;
    });
  }

  void _closeSheet() {
    if (!_sheetVisible) return;
    setState(() => _sheetVisible = false);
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted && !_sheetVisible) {
        setState(() => _sheetContent = null);
      }
    });
  }

  Future<void> _toggleTilt() async {
    final newTilt = _isTilted ? 0.0 : 45.0;
    setState(() => _isTilted = !_isTilted);
    _mapController?.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: _currentCenter,
          zoom: 16,
          tilt: newTilt,
          bearing: 0,
        ),
      ),
    );
  }

  Future<void> _openInGoogleMaps(PlaceInfo place) async {
    final url = Uri.parse(
      'https://www.google.com/maps/search/?api=1'
      '&query=${Uri.encodeComponent(place.name)}'
      '&query_place_id=${place.id}',
    );
    await launchUrl(url, mode: LaunchMode.externalApplication);
  }

  /// お気に入り場所管理のボトムシートを表示
  Future<void> _showPlacesManager() async {
    final places = await LocalDatabase.getSavedPlaces();
    if (!mounted) return;

    final home = places.where((p) => p.iconType == 'home').firstOrNull;
    final favorites = places.where((p) => p.iconType == 'favorite').toList();

    // スロット定義: 自宅1つ + お気に入り3つ
    final slots = <_PlaceSlot>[
      _PlaceSlot(label: '自宅', icon: Icons.home, iconType: 'home', place: home),
      for (var i = 0; i < 3; i++)
        _PlaceSlot(
          label: 'お気に入り${i + 1}',
          icon: Icons.star,
          iconType: 'favorite',
          place: i < favorites.length ? favorites[i] : null,
        ),
    ];

    await showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  const Text('マイプレイス',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            ...slots.map((slot) => _buildPlaceSlotTile(context, slot)),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaceSlotTile(BuildContext sheetContext, _PlaceSlot slot) {
    final isSet = slot.place != null;

    return ListTile(
      leading: Icon(
        slot.icon,
        color: isSet ? Theme.of(context).colorScheme.primary : Colors.grey,
      ),
      title: Text(isSet ? slot.place!.name : slot.label),
      subtitle: isSet
          ? Text(
              '${slot.place!.latitude.toStringAsFixed(4)}, ${slot.place!.longitude.toStringAsFixed(4)}',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            )
          : Text('未設定', style: TextStyle(color: Colors.grey[500])),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // その場所に移動
          if (isSet)
            IconButton(
              icon: const Icon(Icons.near_me, size: 22),
              tooltip: 'この場所に移動',
              onPressed: () {
                Navigator.pop(sheetContext);
                final pos = LatLng(slot.place!.latitude, slot.place!.longitude);
                _mapController?.animateCamera(
                  CameraUpdate.newCameraPosition(
                    CameraPosition(
                      target: pos,
                      zoom: 16,
                      tilt: _isTilted ? 45 : 0,
                    ),
                  ),
                );
              },
            ),
          // 現在のマップ中心を設定
          IconButton(
            icon: Icon(
              isSet ? Icons.edit_location_alt : Icons.add_location_alt,
              size: 22,
            ),
            tooltip: 'マップ中央を設定',
            onPressed: () async {
              // 上書き確認
              if (isSet) {
                final confirmed = await showDialog<bool>(
                  context: sheetContext,
                  builder: (context) => AlertDialog(
                    title: const Text('場所を更新'),
                    content: Text('「${slot.place!.name}」を現在のマップ位置に更新しますか？'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('キャンセル'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('更新'),
                      ),
                    ],
                  ),
                );
                if (confirmed != true) return;
              }

              // 名前入力（新規の場合）
              String name = slot.place?.name ?? slot.label;
              if (!isSet) {
                if (!sheetContext.mounted) return;
                final inputName = await showDialog<String>(
                  context: sheetContext,
                  builder: (context) {
                    final controller = TextEditingController(text: slot.label);
                    return AlertDialog(
                      title: const Text('場所の名前'),
                      content: TextField(
                        controller: controller,
                        autofocus: true,
                        decoration: const InputDecoration(
                          hintText: '例: 自宅、よく行くカフェ',
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('キャンセル'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(
                            context,
                            controller.text.trim().isEmpty
                                ? slot.label
                                : controller.text.trim(),
                          ),
                          child: const Text('OK'),
                        ),
                      ],
                    );
                  },
                );
                if (inputName == null) return;
                name = inputName;
              }

              // 保存
              if (slot.place != null) {
                await LocalDatabase.deleteSavedPlace(slot.place!.id);
              }
              final newPlace = SavedPlace(
                id: slot.place?.id ?? const Uuid().v4(),
                name: name,
                latitude: _currentCenter.latitude,
                longitude: _currentCenter.longitude,
                iconType: slot.iconType,
                createdAt: DateTime.now(),
              );
              await LocalDatabase.insertSavedPlace(newPlace);
              _loadMealMarkers();

              if (sheetContext.mounted) Navigator.pop(sheetContext);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('「${newPlace.name}」を保存しました')),
                );
              }
            },
          ),
        ],
      ),
    );
  }

  void _clearSearchResults() {
    setState(() {
      _placeMarkersMap.clear();
      _placeInfoMap.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(mealLogsProvider, (_, _) => _loadMealMarkers());

    final allMarkers = {..._mealMarkers, ..._placeMarkersMap.values};

    // プレビュー円（検索前に範囲を示す）
    final previewCircle = Circle(
      circleId: const CircleId('preview'),
      center: _currentCenter,
      radius: _searchRadiusMeters,
      fillColor: Colors.orange.withValues(alpha: 0.06),
      strokeColor: Colors.orange.withValues(alpha: 0.4),
      strokeWidth: 2,
    );

    final allCircles = {
      if (_showSearchButton) previewCircle,
    };

    return Scaffold(
      appBar: AppBar(
        title: const Text('グルメマップ'),
      ),
      body: _loadingPosition
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                GoogleMap(
                  initialCameraPosition: CameraPosition(
                    target: _initialPosition,
                    zoom: 16,
                    tilt: 45,
                  ),
                  markers: allMarkers,
                  circles: allCircles,
                  myLocationEnabled: true,
                  myLocationButtonEnabled: false,
                  zoomControlsEnabled: false,
                  mapToolbarEnabled: false,
                  compassEnabled: false,
                  buildingsEnabled: true,
                  style: _mapStyleBase,
                  onMapCreated: (controller) {
                    _mapController = controller;
                    _loadMealMarkers();
                    // 初回表示時に現在地周辺を自動検索
                    _searchNearbyRestaurants();
                  },
                  onCameraMove: (position) {
                    _currentCenter = position.target;
                    final tilted = position.tilt > 10;
                    if (tilted != _isTilted || _showSearchButton) {
                      setState(() {
                        _isTilted = tilted;
                        _showSearchButton = false;
                      });
                    }
                  },
                  onCameraIdle: () {
                    setState(() => _showSearchButton = true);
                  },
                  onTap: (_) => _closeSheet(),
                ),

                // 視点切り替えボタン
                Positioned(
                  top: 12,
                  left: 12,
                  child: _buildTiltButton(),
                ),

                // 検索結果クリアボタン
                if (_placeMarkersMap.isNotEmpty)
                  Positioned(
                    top: 12,
                    right: 12,
                    child: _buildClearButton(),
                  ),

                // 「このエリアで検索」ボタン
                if (_showSearchButton)
                  Positioned(
                    top: 12,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: _buildSearchButton(),
                    ),
                  ),

                // マイプレイスボタン
                Positioned(
                  bottom: _sheetVisible ? 260 : 16,
                  right: 12,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FloatingActionButton.small(
                        heroTag: 'myPlaces',
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.black87,
                        onPressed: _showPlacesManager,
                        child: const Icon(Icons.bookmark),
                      ),
                      const SizedBox(height: 8),
                      FloatingActionButton.small(
                        heroTag: 'myLocation',
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.black87,
                        onPressed: _initCurrentPosition,
                        child: const Icon(Icons.my_location),
                      ),
                    ],
                  ),
                ),

                // ボトムシート
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutCubic,
                  bottom: _sheetVisible ? 0 : -280,
                  left: 0,
                  right: 0,
                  child: _buildSheet(),
                ),
              ],
            ),
    );
  }

  Widget _buildSearchButton() {
    return Material(
      elevation: 3,
      borderRadius: BorderRadius.circular(20),
      color: Colors.white,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: _isSearching ? null : _searchNearbyRestaurants,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_isSearching)
                const SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                const Icon(Icons.search, size: 18),
              const SizedBox(width: 6),
              Text(
                _isSearching ? '検索中...' : 'このエリアで検索',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildClearButton() {
    return GestureDetector(
      onTap: _clearSearchResults,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: const Icon(Icons.layers_clear, color: Colors.black87, size: 22),
      ),
    );
  }

  Widget _buildTiltButton() {
    return GestureDetector(
      onTap: _toggleTilt,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Icon(
          _isTilted ? Icons.map : Icons.view_in_ar,
          color: Colors.black87,
          size: 24,
        ),
      ),
    );
  }

  Widget _buildSheet() {
    final content = _sheetContent;

    return GestureDetector(
      onVerticalDragEnd: (details) {
        if (details.primaryVelocity != null && details.primaryVelocity! > 200) {
          _closeSheet();
        }
      },
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 8,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ドラッグハンドル + 閉じるボタン
            Padding(
              padding: const EdgeInsets.only(top: 8, right: 4, bottom: 4),
              child: Row(
                children: [
                  const Spacer(),
                  Container(
                    width: 40, height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey[400],
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: _closeSheet,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),
            if (content == null)
              const SizedBox.shrink()
            else if (content.mealLog != null)
              _buildMealContent(content.mealLog!, content.photos)
            else if (content.place != null)
              _buildPlaceContent(content.place!),
          ],
        ),
      ),
    );
  }

  Widget _buildMealContent(MealLog log, List<MealPhoto> photos) {
    final dateFormat = DateFormat('M/d (E) HH:mm', 'ja');

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (photos.isNotEmpty)
          SizedBox(
            height: 120,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: photos.length,
              itemBuilder: (context, index) {
                final file = File(photos[index].localPath);
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: file.existsSync()
                        ? Image.file(file, width: 120, height: 120, fit: BoxFit.cover)
                        : Container(
                            width: 120, color: Colors.grey[300],
                            child: const Icon(Icons.broken_image),
                          ),
                  ),
                );
              },
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (photos.any((p) => p.displayName != null))
                      Text(
                        photos.where((p) => p.displayName != null).map((p) => p.displayName!).join('、'),
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                      )
                    else
                      Text(log.mealType.label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text(dateFormat.format(log.eatenAt), style: TextStyle(fontSize: 13, color: Colors.grey[600])),
                  ],
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: () {
                  _closeSheet();
                  context.push('/meal/${log.id}');
                },
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('詳細'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPlaceContent(PlaceInfo place) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // サムネ画像
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: place.photoUrl != null
                ? Image.network(
                    place.photoUrl!,
                    width: 80,
                    height: 80,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => _placeholderImage(),
                  )
                : _placeholderImage(),
          ),
          const SizedBox(width: 12),
          // 店舗情報 + 詳細ボタン
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  place.name,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                if (place.rating != null)
                  Row(
                    children: [
                      Icon(Icons.star, size: 16, color: Colors.amber[700]),
                      const SizedBox(width: 2),
                      Text(
                        place.rating!.toStringAsFixed(1),
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                      if (place.userRatingCount != null)
                        Text(
                          ' (${place.userRatingCount}件)',
                          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                        ),
                    ],
                  ),
                const SizedBox(height: 4),
                if (place.address != null)
                  Text(
                    place.address!,
                    style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                  ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.tonalIcon(
                    onPressed: () => _openInGoogleMaps(place),
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('詳細'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _placeholderImage() {
    return Container(
      width: 80, height: 80,
      color: Colors.grey[200],
      child: Icon(Icons.restaurant, color: Colors.grey[400]),
    );
  }
}

class _SheetContent {
  final MealLog? mealLog;
  final List<MealPhoto> photos;
  final PlaceInfo? place;

  _SheetContent({this.mealLog, this.photos = const [], this.place});
}

class _PlaceSlot {
  final String label;
  final IconData icon;
  final String iconType;
  final SavedPlace? place;

  _PlaceSlot({
    required this.label,
    required this.icon,
    required this.iconType,
    this.place,
  });
}
