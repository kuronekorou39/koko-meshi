import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../config/features.dart';
import '../../database/local_database.dart';
import '../../models/meal_log.dart';
import '../../models/meal_photo.dart';
import '../../models/meal_type.dart';
import '../../models/saved_place.dart';
import '../../providers/map_focus_providers.dart';
import '../../providers/meal_providers.dart';
import '../../services/app_settings_service.dart';
import '../../services/location_service.dart';
import '../../services/map_style.dart';
import '../../services/places_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/cached_photo_image.dart';
import 'place_editor_screen.dart';
import 'place_search_sheet.dart';

/// 検索前に範囲を示すプレビュー円の既定値。検索条件を変えると追従する
const double _defaultSearchRadiusMeters = 500;

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
  /// 地図に出すラベルの種類。設定に保存され、次に開いたときも保たれる
  Set<MapLabelLayer> _mapLabels = AppSettings.mapLabelLayers;
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

  /// 検索条件。シートで変えるとプレビュー円の大きさにも反映される
  PlaceSearchOptions _searchOptions = const PlaceSearchOptions(
    radiusMeters: _defaultSearchRadiusMeters,
  );

  /// 直近の検索結果(一覧表示用)。null なら一覧を出さない。
  /// 地図のピンは蓄積型なので、こちらとは寿命が違う
  List<PlaceInfo>? _searchResults;
  LatLng? _searchCenter;

  // ボトムシート
  _SheetContent? _sheetContent;
  bool _sheetVisible = false;

  // フィルタ
  _MapFilter _filter = const _MapFilter();

  @override
  void initState() {
    super.initState();
    _initCurrentPosition();
  }

  @override
  void dispose() {
    _mapController?.dispose();
    super.dispose();
  }

  /// ラベルの表示を切り替えるシート。
  ///
  /// 効果がその場で見えないと選べないので、設定画面ではなくマップに置く。
  /// どれをオンにしても費用は増えない([MapLabelLayer] のコメント参照)。
  Future<void> _showLayerSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (context, setSheetState) {
          final tokens = KokoTokens.of(context);
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
                  child: Row(
                    children: [
                      Text('地図に出すもの',
                          style: Theme.of(context).textTheme.titleMedium),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.close),
                        color: tokens.textMuted,
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                ),
                const Divider(),
                for (final layer in MapLabelLayer.values)
                  SwitchListTile(
                    dense: true,
                    title: Text(layer.label),
                    value: _mapLabels.contains(layer),
                    onChanged: (on) {
                      final next = {..._mapLabels};
                      if (on) {
                        next.add(layer);
                      } else {
                        next.remove(layer);
                      }
                      // シートと地図の両方を更新する
                      setSheetState(() {});
                      _applyMapLabels(next);
                    },
                  ),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _applyMapLabels(Set<MapLabelLayer> layers) async {
    setState(() => _mapLabels = layers);
    await AppSettings.setMapLabelLayers(layers);
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

    // SavedPlaceごとに紐づく食事記録を集計
    final placeLogMap = <String, List<_MealLogWithPhotos>>{}; // placeId → logs
    final ungroupedLogs = <_MealLogWithPhotos>[];

    for (final log in mealLogs) {
      final photos = await LocalDatabase.getPhotosForMealLog(log.id);

      // フィルタ適用
      if (!_filter.matches(log, photos)) continue;

      // MealLog自体にlocationTagがあればそれを使う
      if (log.locationTag != null) {
        placeLogMap
            .putIfAbsent(log.locationTag!, () => [])
            .add(_MealLogWithPhotos(log, photos));
        continue;
      }

      // GPS座標がある場合、SavedPlaceとの距離で判定
      final lat = log.latitude;
      final lng = log.longitude;
      if (lat != null && lng != null) {
        bool grouped = false;
        for (final place in savedPlaces) {
          final distance = _distanceBetween(
            lat,
            lng,
            place.latitude,
            place.longitude,
          );
          if (distance <= 100) {
            final key = place.iconType == 'home' ? 'home' : place.id;
            placeLogMap
                .putIfAbsent(key, () => [])
                .add(_MealLogWithPhotos(log, photos));
            grouped = true;
            break;
          }
        }
        if (!grouped) {
          ungroupedLogs.add(_MealLogWithPhotos(log, photos));
        }
      } else {
        // GPSがない場合、写真のGPSを確認
        final photoWithLocation = photos.cast<MealPhoto?>().firstWhere(
          (p) => p!.latitude != null && p.longitude != null,
          orElse: () => null,
        );
        if (photoWithLocation != null) {
          bool grouped = false;
          for (final place in savedPlaces) {
            final distance = _distanceBetween(
              photoWithLocation.latitude!,
              photoWithLocation.longitude!,
              place.latitude,
              place.longitude,
            );
            if (distance <= 100) {
              final key = place.iconType == 'home' ? 'home' : place.id;
              placeLogMap
                  .putIfAbsent(key, () => [])
                  .add(_MealLogWithPhotos(log, photos));
              grouped = true;
              break;
            }
          }
          if (!grouped) {
            ungroupedLogs.add(_MealLogWithPhotos(log, photos));
          }
        }
      }
    }

    // SavedPlaceマーカー（食事件数バッジ付き）
    for (final place in savedPlaces) {
      final key = place.iconType == 'home' ? 'home' : place.id;
      final logs = placeLogMap[key] ?? [];
      final count = logs.length;

      final icon = count > 0
          ? await _createCountBadgeMarker(
              place.iconType == 'home' ? Icons.home : Icons.star,
              count,
            )
          : BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueViolet);

      markers.add(
        Marker(
          markerId: MarkerId('saved_${place.id}'),
          position: LatLng(place.latitude, place.longitude),
          icon: icon,
          zIndexInt: 3,
          onTap: count > 0
              ? () => _showGroupedMealSheet(place.name, logs)
              : null,
          infoWindow: count == 0
              ? InfoWindow(title: place.name)
              : InfoWindow.noText,
        ),
      );
    }

    // グルーピングされなかった食事記録を個別マーカーで表示
    for (final item in ungroupedLogs) {
      final lat = item.log.latitude;
      final lng = item.log.longitude;
      final photoWithLocation = item.photos.cast<MealPhoto?>().firstWhere(
        (p) => p!.latitude != null && p.longitude != null,
        orElse: () => null,
      );
      final pos = lat != null && lng != null
          ? LatLng(lat, lng)
          : photoWithLocation != null
          ? LatLng(photoWithLocation.latitude!, photoWithLocation.longitude!)
          : null;
      if (pos == null) continue;

      final hue = switch (item.log.mealType) {
        MealType.unset => BitmapDescriptor.hueViolet,
        MealType.eatingOut => BitmapDescriptor.hueOrange,
        MealType.homeCooking => BitmapDescriptor.hueGreen,
        MealType.takeout => BitmapDescriptor.hueYellow,
        MealType.delivery => BitmapDescriptor.hueBlue,
        MealType.snack => BitmapDescriptor.hueMagenta,
        MealType.other => BitmapDescriptor.hueRose,
      };

      markers.add(
        Marker(
          markerId: MarkerId('meal_${item.log.id}'),
          position: pos,
          icon: BitmapDescriptor.defaultMarkerWithHue(hue),
          zIndexInt: 2,
          onTap: () => _showMealSheet(item.log, item.photos),
        ),
      );
    }

    if (mounted) setState(() => _mealMarkers = markers);
  }

  static double _distanceBetween(
    double lat1,
    double lng1,
    double lat2,
    double lng2,
  ) {
    const p = 0.017453292519943295; // pi / 180
    final a =
        0.5 -
        math.cos((lat2 - lat1) * p) / 2 +
        math.cos(lat1 * p) *
            math.cos(lat2 * p) *
            (1 - math.cos((lng2 - lng1) * p)) /
            2;
    return 12742000 * math.asin(math.sqrt(a)); // 2 * R * asin (meters)
  }

  /// 件数バッジ付きマーカーを生成
  Future<BitmapDescriptor> _createCountBadgeMarker(
    IconData icon,
    int count,
  ) async {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final scheme = Theme.of(context).colorScheme;
    final size = 48.0 * dpr;
    final badgeSize = 18.0 * dpr;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, size, size));

    // 背景円
    canvas.drawCircle(
      Offset(size / 2, size / 2),
      size / 2 - 2 * dpr,
      Paint()..color = scheme.primary,
    );
    canvas.drawCircle(
      Offset(size / 2, size / 2),
      size / 2 - 2 * dpr,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 * dpr,
    );

    // アイコン
    final iconPainter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontSize: 20 * dpr,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          color: Colors.white,
        ),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    iconPainter.paint(
      canvas,
      Offset((size - iconPainter.width) / 2, (size - iconPainter.height) / 2),
    );

    // バッジ（右上）
    if (count > 0) {
      final badgeCenter = Offset(size - badgeSize / 2, badgeSize / 2);
      canvas.drawCircle(
        badgeCenter,
        badgeSize / 2,
        Paint()..color = scheme.error,
      );
      canvas.drawCircle(
        badgeCenter,
        badgeSize / 2,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5 * dpr,
      );

      final badgeText = TextPainter(
        text: TextSpan(
          text: count > 99 ? '99+' : '$count',
          style: TextStyle(
            fontSize: (count > 99 ? 7 : 9) * dpr,
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: ui.TextDirection.ltr,
      )..layout();
      badgeText.paint(
        canvas,
        Offset(
          badgeCenter.dx - badgeText.width / 2,
          badgeCenter.dy - badgeText.height / 2,
        ),
      );
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(size.ceil(), size.ceil());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);

    return BitmapDescriptor.bytes(
      bytes!.buffer.asUint8List(),
      imagePixelRatio: dpr,
    );
  }

  void _showGroupedMealSheet(String placeName, List<_MealLogWithPhotos> items) {
    setState(() {
      _sheetContent = _SheetContent(groupName: placeName, groupedMeals: items);
      _sheetVisible = true;
    });
  }

  /// カスタムラベル付きマーカーを生成
  Future<BitmapDescriptor> _createLabeledMarker(String label) async {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final scheme = Theme.of(context).colorScheme;
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
      Paint()..color = scheme.primary,
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

  /// 条件シートを開いてから検索する。条件を決めずに閉じたら何もしない
  Future<void> _openSearchOptions() async {
    final options = await showPlaceSearchOptions(context, _searchOptions);
    if (options == null || !mounted) return;
    setState(() => _searchOptions = options);
    await _searchNearbyRestaurants();
  }

  Future<void> _searchNearbyRestaurants() async {
    setState(() => _isSearching = true);

    final searchCenter = _currentCenter;
    final result = await PlacesService.searchNearbyRestaurants(
      latitude: searchCenter.latitude,
      longitude: searchCenter.longitude,
      options: _searchOptions,
    );

    if (!mounted) return;

    // 失敗を0件として黙って返すと「この辺に店が無い」と読めてしまう
    if (!result.ok) {
      setState(() => _isSearching = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(result.error!.message)));
      return;
    }
    if (result.places.isEmpty) {
      setState(() => _isSearching = false);
      // 条件で絞った結果の0件は「店が無い」ではないので、言い分けて出す
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_searchOptions.hasNarrowing
              ? '条件に合うお店は見つかりませんでした'
              : 'この辺りにお店は見つかりませんでした'),
        ),
      );
      return;
    }

    // 結果を蓄積（重複はplaceIdで除外）
    for (final place in result.places) {
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
      // 並び順を指定できてもピンだけでは順序が見えないので一覧を出す
      _searchResults = result.places;
      _searchCenter = searchCenter;
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
      _PlaceSlot(
        label: '自宅',
        icon: home != null ? Icons.home : Icons.home_outlined,
        iconType: 'home',
        place: home,
      ),
      for (var i = 0; i < 3; i++)
        _PlaceSlot(
          label: 'お気に入り${i + 1}',
          icon: i < favorites.length ? Icons.star : Icons.star_outline,
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
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
              child: Row(
                children: [
                  Text(
                    'マイプレイス',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    color: KokoTokens.of(context).textMuted,
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
    final tokens = KokoTokens.of(context);
    final isSet = slot.place != null;

    return ListTile(
      leading: Icon(
        slot.icon,
        color: isSet ? Theme.of(context).colorScheme.primary : tokens.textFaint,
      ),
      title: Text(isSet ? slot.place!.name : slot.label),
      subtitle: isSet
          ? Text(
              '${slot.place!.latitude.toStringAsFixed(4)}, ${slot.place!.longitude.toStringAsFixed(4)}',
              style: tokens.numeral.copyWith(
                fontSize: 12,
                fontWeight: FontWeight.w400,
                color: tokens.textMuted,
              ),
            )
          : Text(
              '未設定',
              style: TextStyle(fontSize: 12.5, color: tokens.textFaint),
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // その場所に移動
          if (isSet)
            IconButton(
              icon: const Icon(Icons.near_me_outlined, size: 22),
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
          // 場所編集画面を開く
          IconButton(
            icon: Icon(
              isSet
                  ? Icons.edit_location_alt_outlined
                  : Icons.add_location_alt_outlined,
              size: 22,
            ),
            tooltip: isSet ? '場所を編集' : '場所を追加',
            onPressed: () async {
              Navigator.pop(sheetContext);
              final result = await Navigator.push<SavedPlace>(
                context,
                MaterialPageRoute(
                  builder: (_) => PlaceEditorScreen(
                    initialPosition: isSet
                        ? LatLng(slot.place!.latitude, slot.place!.longitude)
                        : null,
                    initialName: isSet ? slot.place!.name : slot.label,
                    iconType: slot.iconType,
                    existingId: slot.place?.id,
                  ),
                ),
              );
              if (result == null) return;

              // 既存を削除して新規保存
              if (slot.place != null) {
                await LocalDatabase.deleteSavedPlace(slot.place!.id);
              }
              await LocalDatabase.insertSavedPlace(result);
              _loadMealMarkers();

              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('「${result.name}」を保存しました')),
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
      _searchResults = null;
    });
  }

  /// 詳細画面から渡された場所へ寄る。読んだら消して、次に開いたときに
  /// また寄ってしまわないようにする。
  Future<void> _consumeMapFocus() async {
    final focus = ref.read(mapFocusProvider);
    if (focus == null) return;
    ref.read(mapFocusProvider.notifier).state = null;

    final target = LatLng(focus.latitude, focus.longitude);
    setState(() => _currentCenter = target);
    await _mapController?.animateCamera(
      CameraUpdate.newLatLngZoom(target, 17),
    );
    final label = focus.label;
    if (label != null && label.isNotEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(label), duration: const Duration(seconds: 2)),
      );
    }
  }

  /// 一覧から店を選んだとき: 地図をそこへ寄せて詳細シートに切り替える
  Future<void> _focusPlace(PlaceInfo place) async {
    setState(() => _searchResults = null);
    await _mapController?.animateCamera(
      CameraUpdate.newLatLngZoom(LatLng(place.latitude, place.longitude), 17),
    );
    if (mounted) _showPlaceSheet(place);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(mealLogsProvider, (_, _) => _loadMealMarkers());
    // マップを開いたままで場所を指定された場合(タブが既にマップのとき)
    ref.listen(mapFocusProvider, (_, next) {
      if (next != null) _consumeMapFocus();
    });

    final allMarkers = {..._mealMarkers, ..._placeMarkersMap.values};
    final scheme = Theme.of(context).colorScheme;

    // プレビュー円（検索前に範囲を示す）
    final previewCircle = Circle(
      circleId: const CircleId('preview'),
      center: _currentCenter,
      radius: _searchOptions.radiusMeters,
      fillColor: scheme.primary.withValues(alpha: 0.06),
      strokeColor: scheme.primary.withValues(alpha: 0.4),
      strokeWidth: 2,
    );

    final allCircles = {
      if (_showSearchButton && AppFeatures.placeSearch) previewCircle,
    };

    return Scaffold(
      appBar: AppBar(
        title: const Text('グルメマップ'),
        actions: [
          IconButton(
            icon: Badge(
              isLabelVisible: _filter.isActive,
              child: const Icon(Icons.filter_list),
            ),
            tooltip: 'フィルタ',
            onPressed: _showFilterSheet,
          ),
        ],
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
                  style: buildMapStyle(_mapLabels),
                  onMapCreated: (controller) {
                    _mapController = controller;
                    _loadMealMarkers();
                    // 詳細画面から場所を指定されて開かれた場合。地図が
                    // できるまでカメラを動かせないのでここで消化する
                    _consumeMapFocus();
                    // 費用対策: 自動検索は廃止。マップを開くたびに課金APIが飛ぶのを防ぐ。
                    // 店舗検索は「このエリアで検索」ボタンの明示タップ時のみ実行する。
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

                // 視点切り替え・ラベル表示の切り替え
                Positioned(
                  top: 16,
                  left: 16,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _mapButton(
                        icon: _isTilted
                            ? Icons.map_outlined
                            : Icons.view_in_ar_outlined,
                        tooltip: _isTilted ? '真上から表示' : '立体表示',
                        onTap: _toggleTilt,
                      ),
                      const SizedBox(height: 8),
                      _mapButton(
                        icon: _mapLabels.isEmpty
                            ? Icons.layers_outlined
                            : Icons.layers,
                        tooltip: '地図に出すもの',
                        onTap: _showLayerSheet,
                      ),
                    ],
                  ),
                ),

                // 検索結果クリアボタン
                if (_placeMarkersMap.isNotEmpty)
                  Positioned(
                    top: 16,
                    right: 16,
                    child: _mapButton(
                      icon: Icons.layers_clear_outlined,
                      tooltip: '検索結果をクリア',
                      onTap: _clearSearchResults,
                    ),
                  ),

                // 「このエリアで検索」ボタン
                if (_showSearchButton)
                  Positioned(
                    top: 16,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: AppFeatures.placeSearch
                          ? _buildSearchButton()
                          : _buildSearchComingSoon(),
                    ),
                  ),

                // 検索結果の一覧
                if (_searchResults != null && _searchCenter != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Material(
                      color: Theme.of(context).colorScheme.surface,
                      elevation: 8,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: MediaQuery.of(context).size.height * 0.5,
                        ),
                        child: SafeArea(
                          top: false,
                          child: PlaceSearchResultList(
                            places: _searchResults!,
                            centerLat: _searchCenter!.latitude,
                            centerLng: _searchCenter!.longitude,
                            options: _searchOptions,
                            onTapPlace: _focusPlace,
                            onClose: () =>
                                setState(() => _searchResults = null),
                          ),
                        ),
                      ),
                    ),
                  ),

                // マイプレイス・現在地ボタン
                Positioned(
                  bottom: _sheetVisible ? 260 : 16,
                  right: 16,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _mapButton(
                        icon: Icons.bookmark_outline,
                        tooltip: 'マイプレイス',
                        onTap: _showPlacesManager,
                      ),
                      const SizedBox(height: 8),
                      _mapButton(
                        icon: Icons.my_location,
                        tooltip: '現在地へ移動',
                        onTap: _initCurrentPosition,
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
    final theme = Theme.of(context);
    final tokens = KokoTokens.of(context);
    return Material(
      color: theme.brightness == Brightness.light
          ? theme.colorScheme.surface
          : theme.colorScheme.surfaceContainerHigh,
      shape: StadiumBorder(
        side: BorderSide(color: tokens.hairline, width: 0.8),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: _isSearching ? null : _openSearchOptions,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_isSearching)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(Icons.search, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                _isSearching ? '検索中…' : 'このエリアで検索',
                style: theme.textTheme.labelLarge,
              ),
              // 条件を絞っているときは、それが効いていることを見せる
              if (!_isSearching && _searchOptions.hasNarrowing) ...[
                const SizedBox(width: 6),
                Icon(Icons.filter_alt,
                    size: 15, color: theme.colorScheme.primary),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 配布ビルドでの表示。Places は従量課金なので、費用を誰が持つかが
  /// 決まるまで出せない([AppFeatures.placeSearch])。押せないボタンを黙って
  /// 置くと壊れて見えるので、準備中だと分かる形にする
  Widget _buildSearchComingSoon() {
    final theme = Theme.of(context);
    final tokens = KokoTokens.of(context);
    return Material(
      color: theme.brightness == Brightness.light
          ? theme.colorScheme.surface
          : theme.colorScheme.surfaceContainerHigh,
      shape: StadiumBorder(
        side: BorderSide(color: tokens.hairline, width: 0.8),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: () => ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('お店の検索は準備中です。記録の保存と地図の表示はそのままお使いいただけます'),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.storefront_outlined, size: 18, color: tokens.textFaint),
              const SizedBox(width: 8),
              Text(
                'お店の検索（準備中）',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: tokens.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// マップ上のオーバーレイボタン(視点切替・クリア・マイプレイス・現在地)
  Widget _mapButton({
    required IconData icon,
    required VoidCallback onTap,
    String? tooltip,
  }) {
    final theme = Theme.of(context);
    final tokens = KokoTokens.of(context);
    final button = Material(
      color: theme.brightness == Brightness.light
          ? theme.colorScheme.surface
          : theme.colorScheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: tokens.hairline, width: 0.8),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(icon, size: 22, color: theme.colorScheme.onSurface),
        ),
      ),
    );
    if (tooltip == null) return button;
    return Tooltip(message: tooltip, child: button);
  }

  Widget _buildSheet() {
    final theme = Theme.of(context);
    final tokens = KokoTokens.of(context);
    final content = _sheetContent;

    return GestureDetector(
      onVerticalDragEnd: (details) {
        if (details.primaryVelocity != null && details.primaryVelocity! > 200) {
          _closeSheet();
        }
      },
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          border: Border.all(color: tokens.hairline, width: 0.8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ドラッグハンドル + 閉じるボタン
            Padding(
              padding: const EdgeInsets.only(top: 8, right: 8, bottom: 4),
              child: Row(
                children: [
                  const Spacer(),
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    color: tokens.textMuted,
                    onPressed: _closeSheet,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),
            if (content == null)
              const SizedBox.shrink()
            else if (content.groupName != null)
              _buildGroupedMealContent(content.groupName!, content.groupedMeals)
            else if (content.mealLog != null)
              _buildMealContent(content.mealLog!, content.photos)
            else if (content.place != null)
              _buildPlaceContent(content.place!),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupedMealContent(
    String placeName,
    List<_MealLogWithPhotos> items,
  ) {
    final theme = Theme.of(context);
    final tokens = KokoTokens.of(context);
    final dateFormat = DateFormat('M/d (E) HH:mm', 'ja');

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: Text(
                  placeName,
                  style: theme.textTheme.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${items.length}件',
                style: tokens.numeral.copyWith(
                  fontSize: 13,
                  color: tokens.textMuted,
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 180,
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              final firstPhoto = item.photos.isNotEmpty
                  ? item.photos.first
                  : null;
              final menuName = item.photos
                  .where((p) => p.displayName != null)
                  .map((p) => p.displayName!)
                  .join('、');

              return ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: firstPhoto != null
                      ? CachedPhotoImage(
                          localPath: firstPhoto.localPath,
                          thumbnailPath: firstPhoto.thumbnailUrl,
                          originalUrl: firstPhoto.originalUrl,
                          width: 48,
                          height: 48,
                        )
                      : Container(
                          width: 48,
                          height: 48,
                          color: tokens.photoPlaceholder,
                          child: Icon(
                            Icons.restaurant_outlined,
                            size: 24,
                            color: tokens.textFaint,
                          ),
                        ),
                ),
                title: Text(
                  menuName.isNotEmpty ? menuName : item.log.mealType.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
                subtitle: Text(
                  dateFormat.format(item.log.eatenAt),
                  style: theme.textTheme.bodySmall,
                ),
                trailing: Icon(
                  Icons.chevron_right,
                  size: 20,
                  color: tokens.textFaint,
                ),
                onTap: () {
                  _closeSheet();
                  context.push('/meal/${item.log.id}');
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildMealContent(MealLog log, List<MealPhoto> photos) {
    final theme = Theme.of(context);
    final tokens = KokoTokens.of(context);
    final dateFormat = DateFormat('M/d (E) HH:mm', 'ja');

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (photos.isNotEmpty)
          SizedBox(
            height: 120,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: photos.length,
              itemBuilder: (context, index) {
                final photo = photos[index];
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: CachedPhotoImage(
                      localPath: photo.localPath,
                      thumbnailPath: photo.thumbnailUrl,
                      originalUrl: photo.originalUrl,
                      width: 120,
                      height: 120,
                    ),
                  ),
                );
              },
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (photos.any((p) => p.displayName != null))
                      Text(
                        photos
                            .where((p) => p.displayName != null)
                            .map((p) => p.displayName!)
                            .join('、'),
                        style: theme.textTheme.titleSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      )
                    else
                      Text(
                        log.mealType.label,
                        style: theme.textTheme.titleSmall,
                      ),
                    const SizedBox(height: 4),
                    Text(
                      dateFormat.format(log.eatenAt),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: tokens.textMuted,
                      ),
                    ),
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
    final theme = Theme.of(context);
    final tokens = KokoTokens.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // サムネ画像
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
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
                  style: theme.textTheme.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                if (place.rating != null)
                  Row(
                    children: [
                      Icon(
                        Icons.star,
                        size: 16,
                        color: theme.colorScheme.tertiary,
                      ),
                      const SizedBox(width: 2),
                      Text(
                        place.rating!.toStringAsFixed(1),
                        style: tokens.numeral.copyWith(fontSize: 13),
                      ),
                      if (place.userRatingCount != null)
                        Text(
                          ' (${place.userRatingCount}件)',
                          style: tokens.numeral.copyWith(
                            fontSize: 12,
                            fontWeight: FontWeight.w400,
                            color: tokens.textMuted,
                          ),
                        ),
                    ],
                  ),
                const SizedBox(height: 4),
                if (place.address != null)
                  Text(
                    place.address!,
                    style: theme.textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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

  Future<void> _showFilterSheet() async {
    var tempFilter = _filter;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (context, setSheetState) {
          final tokens = KokoTokens.of(context);
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'フィルタ',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const Spacer(),
                      if (tempFilter.isActive)
                        TextButton(
                          onPressed: () {
                            setSheetState(
                              () => tempFilter = const _MapFilter(),
                            );
                          },
                          child: const Text('リセット'),
                        ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        color: tokens.textMuted,
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  const Divider(),
                  const SizedBox(height: 16),

                  // 期間
                  Text('期間', style: tokens.sectionLabel),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      _filterChip('全期間', tempFilter.dateRange == null, () {
                        setSheetState(
                          () => tempFilter = tempFilter.copyWith(
                            clearDateRange: true,
                          ),
                        );
                      }),
                      _filterChip('1週間', tempFilter.dateRangeLabel == '1w', () {
                        final now = DateTime.now();
                        setSheetState(
                          () => tempFilter = tempFilter.copyWith(
                            dateFrom: now.subtract(const Duration(days: 7)),
                            dateTo: now,
                            dateRangeLabel: '1w',
                          ),
                        );
                      }),
                      _filterChip('1ヶ月', tempFilter.dateRangeLabel == '1m', () {
                        final now = DateTime.now();
                        setSheetState(
                          () => tempFilter = tempFilter.copyWith(
                            dateFrom: DateTime(
                              now.year,
                              now.month - 1,
                              now.day,
                            ),
                            dateTo: now,
                            dateRangeLabel: '1m',
                          ),
                        );
                      }),
                      _filterChip('3ヶ月', tempFilter.dateRangeLabel == '3m', () {
                        final now = DateTime.now();
                        setSheetState(
                          () => tempFilter = tempFilter.copyWith(
                            dateFrom: DateTime(
                              now.year,
                              now.month - 3,
                              now.day,
                            ),
                            dateTo: now,
                            dateRangeLabel: '3m',
                          ),
                        );
                      }),
                      ActionChip(
                        label: Text(
                          tempFilter.dateRangeLabel == 'custom'
                              ? '${DateFormat('M/d').format(tempFilter.dateFrom!)}〜${DateFormat('M/d').format(tempFilter.dateTo!)}'
                              : 'カスタム',
                        ),
                        avatar: Icon(
                          Icons.calendar_today_outlined,
                          size: 16,
                          color: tokens.textMuted,
                        ),
                        onPressed: () async {
                          final range = await showDateRangePicker(
                            context: context,
                            firstDate: DateTime(2020),
                            lastDate: DateTime.now(),
                            locale: const Locale('ja'),
                          );
                          if (range != null) {
                            setSheetState(
                              () => tempFilter = tempFilter.copyWith(
                                dateFrom: range.start,
                                dateTo: range.end,
                                dateRangeLabel: 'custom',
                              ),
                            );
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // テキスト検索
                  Text('キーワード', style: tokens.sectionLabel),
                  const SizedBox(height: 8),
                  TextField(
                    controller: TextEditingController(text: tempFilter.keyword),
                    decoration: const InputDecoration(
                      hintText: 'メニュー名で検索',
                      prefixIcon: Icon(Icons.search, size: 20),
                    ),
                    onChanged: (v) {
                      tempFilter = tempFilter.copyWith(keyword: v);
                    },
                  ),
                  const SizedBox(height: 16),

                  // 適用ボタン
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () {
                        Navigator.pop(context);
                        setState(() => _filter = tempFilter);
                        _loadMealMarkers();
                      },
                      child: const Text('適用'),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _filterChip(String label, bool selected, VoidCallback onTap) {
    return FilterChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
    );
  }

  Widget _placeholderImage() {
    final tokens = KokoTokens.of(context);
    return Container(
      width: 80,
      height: 80,
      color: tokens.photoPlaceholder,
      child: Icon(Icons.restaurant_outlined, color: tokens.textFaint),
    );
  }
}

class _SheetContent {
  final MealLog? mealLog;
  final List<MealPhoto> photos;
  final PlaceInfo? place;
  final String? groupName;
  final List<_MealLogWithPhotos> groupedMeals;

  _SheetContent({
    this.mealLog,
    this.photos = const [],
    this.place,
    this.groupName,
    this.groupedMeals = const [],
  });
}

class _MealLogWithPhotos {
  final MealLog log;
  final List<MealPhoto> photos;

  _MealLogWithPhotos(this.log, this.photos);
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

class _MapFilter {
  final DateTime? dateFrom;
  final DateTime? dateTo;
  final String? dateRangeLabel;
  final String? keyword;

  const _MapFilter({
    this.dateFrom,
    this.dateTo,
    this.dateRangeLabel,
    this.keyword,
  });

  bool get isActive =>
      dateFrom != null || (keyword != null && keyword!.isNotEmpty);

  DateTimeRange? get dateRange => dateFrom != null && dateTo != null
      ? DateTimeRange(start: dateFrom!, end: dateTo!)
      : null;

  bool matches(MealLog log, List<MealPhoto> photos) {
    // 日付フィルタ
    if (dateFrom != null && log.eatenAt.isBefore(dateFrom!)) return false;
    if (dateTo != null &&
        log.eatenAt.isAfter(dateTo!.add(const Duration(days: 1)))) {
      return false;
    }

    // キーワード
    if (keyword != null && keyword!.isNotEmpty) {
      final kw = keyword!.toLowerCase();
      final menuNames = photos
          .where((p) => p.displayName != null)
          .map((p) => p.displayName!.toLowerCase());
      final genres = photos
          .where((p) => p.aiCuisineGenre != null)
          .map((p) => p.aiCuisineGenre!.toLowerCase());
      final note = log.note?.toLowerCase() ?? '';

      final matched =
          menuNames.any((n) => n.contains(kw)) ||
          genres.any((g) => g.contains(kw)) ||
          note.contains(kw);
      if (!matched) return false;
    }

    return true;
  }

  _MapFilter copyWith({
    DateTime? dateFrom,
    DateTime? dateTo,
    String? dateRangeLabel,
    String? keyword,
    bool clearDateRange = false,
  }) {
    return _MapFilter(
      dateFrom: clearDateRange ? null : (dateFrom ?? this.dateFrom),
      dateTo: clearDateRange ? null : (dateTo ?? this.dateTo),
      dateRangeLabel: clearDateRange
          ? null
          : (dateRangeLabel ?? this.dateRangeLabel),
      keyword: keyword ?? this.keyword,
    );
  }
}
