import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
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
import '../../providers/app_settings_providers.dart';
import '../../providers/map_focus_providers.dart';
import '../../providers/meal_providers.dart';
import '../../services/app_settings_service.dart';
import '../../services/location_service.dart';
import '../../services/map_style.dart';
import '../../services/places_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_logo.dart';
import '../../widgets/cached_photo_image.dart';
import '../../widgets/meal_grid_tile.dart';
import '../trace/trace_screen.dart';
import 'home_rail.dart';
import 'place_editor_screen.dart';
import 'place_search_sheet.dart';

/// 検索前に範囲を示すプレビュー円の既定値。検索条件を変えると追従する
const double _defaultSearchRadiusMeters = 500;

/// 記録のシートを開いた直後の高さと、引き上げきったときの高さ(画面に対する割合)
const double _sheetPeekSize = 0.36;
const double _sheetFullSize = 0.92;

/// 横向きで記録を出す左の欄の幅
const double _sidePanelWidth = 340;

class MapTab extends ConsumerStatefulWidget {
  const MapTab({super.key, this.nav, this.isActive = true});

  /// 横向きのときのタブ切り替え。渡されたらヘッダを出さず、操作を左の列に並べる
  final HomeNav? nav;

  /// このタブが表に出ているか。裏に回っている間は現在地の取得を止める
  final bool isActive;

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

  /// 開いているシートの中身。null なら閉じている
  _SheetContent? _sheetContent;

  /// 記録のシート(キー→中身)。記録を読み直したあと、開いているシートを
  /// 新しい中身に差し替えるために持つ
  Map<String, _SheetContent> _sheets = {};

  /// 場所ごとの記録を、写真のタイルで並べるか(false なら行の一覧)
  bool _sheetAsGrid = false;

  final _sheetController = DraggableScrollableController();

  /// 自分で地図を動かしたか。現在地が遅れて取れたときに連れ戻さないため
  bool _userMovedMap = false;

  /// 地図ができる前に現在地が取れたときの控え
  LatLng? _pendingCenter;

  // フィルタ
  _MapFilter _filter = const _MapFilter();

  @override
  void initState() {
    super.initState();
    _initStartPosition();
  }

  @override
  void dispose() {
    _sheetController.dispose();
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

  /// 地図を最初に出す場所を決める。
  ///
  /// 現在地は取れるまで数秒かかることがあるので、待たずに前回の現在地
  /// (無ければ自宅)で地図を出し、取れたらそこへ寄る。
  Future<void> _initStartPosition() async {
    final last = AppSettings.lastMapPosition;
    var start = last == null ? null : LatLng(last.$1, last.$2);
    if (start == null) {
      final places = await LocalDatabase.getSavedPlaces();
      final home = places.where((p) => p.iconType == 'home').firstOrNull;
      if (home != null) start = LatLng(home.latitude, home.longitude);
    }
    if (!mounted) return;
    setState(() {
      if (start != null) {
        _initialPosition = start;
        _currentCenter = start;
      }
      _loadingPosition = false;
    });
    _moveToCurrentPosition(onlyIfUntouched: true);
  }

  /// 現在地へ寄る。[onlyIfUntouched] なら、待っている間に自分で地図を
  /// 動かしていた場合は何もしない(見ていた場所から勝手に連れ戻さない)。
  Future<void> _moveToCurrentPosition({bool onlyIfUntouched = false}) async {
    final Position? pos;
    try {
      pos = await LocationService.getCurrentPosition();
    } catch (e) {
      // 時間切れなど。地図はすでに出ているので、そのままにする
      debugPrint('[Map] current position failed: $e');
      return;
    }
    if (!mounted || pos == null) return;
    final latLng = LatLng(pos.latitude, pos.longitude);
    await AppSettings.setLastMapPosition(latLng.latitude, latLng.longitude);
    if (!mounted || (onlyIfUntouched && _userMovedMap)) return;

    _currentCenter = latLng;
    final controller = _mapController;
    if (controller == null) {
      _pendingCenter = latLng;
    } else {
      controller.animateCamera(CameraUpdate.newLatLng(latLng));
    }
  }

  Future<void> _loadMealMarkers() async {
    final mealLogs = await LocalDatabase.getMealLogs();
    final savedPlaces = await LocalDatabase.getSavedPlaces();
    // 写真は記録ごとに問い合わせず、まとめて受け取る
    final photosByLog = await ref.read(mealPhotosByLogProvider.future);
    if (!mounted) return;
    final markers = <Marker>{};
    final sheets = <String, _SheetContent>{};

    // SavedPlaceごとに紐づく食事記録を集計
    final placeLogMap = <String, List<_MealLogWithPhotos>>{}; // placeId → logs
    final ungroupedLogs = <_MealLogWithPhotos>[];

    for (final log in mealLogs) {
      final photos = photosByLog[log.id] ?? const <MealPhoto>[];

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
      if (!mounted) return;

      final sheetKey = 'group_$key';
      if (count > 0) {
        sheets[sheetKey] = _SheetContent(
          key: sheetKey,
          groupName: place.name,
          groupedMeals: logs,
        );
      }

      markers.add(
        Marker(
          markerId: MarkerId('saved_${place.id}'),
          position: LatLng(place.latitude, place.longitude),
          icon: icon,
          zIndexInt: 3,
          onTap: count > 0 ? () => _openSheet(sheetKey) : null,
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

      final sheetKey = 'meal_${item.log.id}';
      sheets[sheetKey] = _SheetContent(
        key: sheetKey,
        mealLog: item.log,
        photos: item.photos,
      );

      markers.add(
        Marker(
          markerId: MarkerId('meal_${item.log.id}'),
          position: pos,
          icon: BitmapDescriptor.defaultMarkerWithHue(hue),
          zIndexInt: 2,
          onTap: () => _openSheet(sheetKey),
        ),
      );
    }

    if (!mounted) return;
    setState(() {
      _mealMarkers = markers;
      _sheets = sheets;
      // 開いているシートは新しい中身に差し替える。詳細で直した名前が
      // 反映され、消した記録は残らない
      final openKey = _sheetContent?.key;
      if (openKey != null) _sheetContent = sheets[openKey];
    });
  }

  void _openSheet(String key) {
    final content = _sheets[key];
    if (content != null) setState(() => _sheetContent = content);
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

  void _showPlaceSheet(PlaceInfo place) {
    setState(() => _sheetContent = _SheetContent(place: place));
  }

  void _closeSheet() {
    if (_sheetContent == null) return;
    setState(() => _sheetContent = null);
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
    // 遅れて取れた現在地で、指定された場所から離れてしまわないように
    _userMovedMap = true;
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
    // 記録か写真が変わったらピンを作り直す(写真の側は記録の変更も拾う)
    ref.listen(mealPhotosByLogProvider, (_, next) {
      if (next.hasValue && !next.isLoading) _loadMealMarkers();
    });
    // マップを開いたままで場所を指定された場合(タブが既にマップのとき)
    ref.listen(mapFocusProvider, (_, next) {
      if (next != null) _consumeMapFocus();
    });

    final nav = widget.nav;
    final actions = [
      // 記録に必要な機能ではないので、設定で足した人にだけ出す
      if (ref.watch(funFeaturesProvider).contains(FunFeature.trace))
        RailAction(
          icon: Icons.play_circle_outline,
          tooltip: '軌跡を再生',
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const TraceScreen()),
          ),
        ),
      RailAction(
        icon: Icons.filter_list,
        tooltip: 'フィルタ',
        badge: _filter.isActive,
        onTap: _showFilterSheet,
      ),
    ];

    return Scaffold(
      // 横向きは縦が足りないので、ヘッダを出さず操作を左の列へ移す
      appBar: nav != null
          ? null
          : AppBar(
              title: const AppLogo(),
              actions: [for (final a in actions) a.toIconButton()],
            ),
      body: Row(
        children: [
          if (nav != null) HomeRail(nav: nav, actions: actions),
          Expanded(
            child: SafeArea(
              left: false,
              bottom: false,
              child: _loadingPosition
                  ? const Center(child: CircularProgressIndicator())
                  : LayoutBuilder(
                      builder: (context, constraints) =>
                          _buildMapStack(constraints, sidePanel: nav != null),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  /// 地図と、その上に重ねる操作・シート。
  /// [sidePanel] なら記録を下からのシートではなく左の欄に出す(横向き)。
  Widget _buildMapStack(BoxConstraints constraints, {required bool sidePanel}) {
    final allMarkers = {..._mealMarkers, ..._placeMarkersMap.values};
    final scheme = Theme.of(context).colorScheme;
    final content = _sheetContent;

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

    // シートや欄に隠れないように、重ねるボタンを逃がす
    final panelInset = sidePanel && content != null ? _sidePanelWidth : 0.0;
    final sheetInset = !sidePanel && content != null
        ? constraints.maxHeight * _sheetPeekSize
        : 0.0;

    return Stack(
      children: [
        // 指で地図に触れたことを覚えておく(現在地へ連れ戻さないため)
        Listener(
          onPointerDown: (_) => _userMovedMap = true,
          child: GoogleMap(
            initialCameraPosition: CameraPosition(
              target: _initialPosition,
              zoom: 16,
              tilt: 45,
            ),
            markers: allMarkers,
            circles: allCircles,
            // 裏に回っている間は現在地を追わない(電池のため)
            myLocationEnabled: widget.isActive,
            myLocationButtonEnabled: false,
            zoomControlsEnabled: false,
            mapToolbarEnabled: false,
            compassEnabled: false,
            buildingsEnabled: true,
            style: buildMapStyle(_mapLabels),
            onMapCreated: (controller) {
              _mapController = controller;
              final pending = _pendingCenter;
              if (pending != null) {
                _pendingCenter = null;
                controller.moveCamera(CameraUpdate.newLatLng(pending));
              }
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
        ),

        // 視点切り替え・ラベル表示の切り替え
        Positioned(
          top: 16,
          left: 16 + panelInset,
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
                icon: _mapLabels.isEmpty ? Icons.layers_outlined : Icons.layers,
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

        // 「このエリアで検索」ボタン。
        // 配布ビルドでは丸ごと出さない([AppFeatures.placeSearch])。
        // 以前は「準備中」と分かる形のボタンを置いていたが、App Review
        // ガイドライン2.1 が coming soon 表示を差し戻し対象にしている
        if (_showSearchButton && AppFeatures.placeSearch)
          Positioned(
            top: 16,
            left: panelInset,
            right: 0,
            child: Center(child: _buildSearchButton()),
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
                  maxHeight: constraints.maxHeight * 0.5,
                ),
                child: SafeArea(
                  top: false,
                  child: PlaceSearchResultList(
                    places: _searchResults!,
                    centerLat: _searchCenter!.latitude,
                    centerLng: _searchCenter!.longitude,
                    options: _searchOptions,
                    onTapPlace: _focusPlace,
                    onClose: () => setState(() => _searchResults = null),
                  ),
                ),
              ),
            ),
          ),

        // マイプレイス・現在地ボタン
        Positioned(
          bottom: 16 + sheetInset,
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
                onTap: _moveToCurrentPosition,
              ),
            ],
          ),
        ),

        if (content != null && sidePanel)
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: _sidePanelWidth,
            child: _buildSidePanel(content),
          ),
        if (content != null && !sidePanel) _buildBottomSheet(content),
      ],
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

  /// 縦向き: 下から出るシート。上へ引くと広がり、下へ引ききると閉じる
  Widget _buildBottomSheet(_SheetContent content) {
    final theme = Theme.of(context);
    final tokens = KokoTokens.of(context);

    return NotificationListener<DraggableScrollableNotification>(
      onNotification: (notification) {
        if (notification.extent <= 0.02) {
          // 通知はレイアウトの途中で届くので、閉じるのは次のフレームに回す
          WidgetsBinding.instance.addPostFrameCallback((_) => _closeSheet());
        }
        return false;
      },
      child: DraggableScrollableSheet(
        controller: _sheetController,
        initialChildSize: _sheetPeekSize,
        minChildSize: 0,
        maxChildSize: _sheetFullSize,
        snap: true,
        snapSizes: const [_sheetPeekSize],
        builder: (context, scrollController) => Material(
          color: theme.colorScheme.surface,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            side: BorderSide(color: tokens.hairline, width: 0.8),
          ),
          child: CustomScrollView(
            controller: scrollController,
            slivers: _buildSheetSlivers(content, showHandle: true),
          ),
        ),
      ),
    );
  }

  /// 横向き: 左の欄。地図の高さを削らずに、記録を縦いっぱいに並べる
  Widget _buildSidePanel(_SheetContent content) {
    final theme = Theme.of(context);
    final tokens = KokoTokens.of(context);

    return Material(
      color: theme.colorScheme.surface,
      shape: Border(right: BorderSide(color: tokens.hairline, width: 0.8)),
      child: CustomScrollView(
        slivers: _buildSheetSlivers(content, showHandle: false),
      ),
    );
  }

  /// シートの中身。見出しは上に留め、その下が送れる。
  /// 見出しも送りの一部なので、縦向きではここを掴んでシートを引ける。
  List<Widget> _buildSheetSlivers(
    _SheetContent content, {
    required bool showHandle,
  }) {
    final theme = Theme.of(context);
    final tokens = KokoTokens.of(context);
    final grouped = content.groupName != null;

    return [
      PinnedHeaderSliver(
        child: Material(
          color: theme.colorScheme.surface,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showHandle)
                Container(
                  margin: const EdgeInsets.only(top: 8),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(left: 16, right: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: grouped
                          ? Text(
                              content.groupName!,
                              style: theme.textTheme.titleMedium,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            )
                          : const SizedBox.shrink(),
                    ),
                    if (grouped) ...[
                      Text(
                        '${content.groupedMeals.length}件',
                        style: tokens.numeral.copyWith(
                          fontSize: 13,
                          color: tokens.textMuted,
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          _sheetAsGrid
                              ? Icons.view_list_outlined
                              : Icons.grid_view_outlined,
                          size: 20,
                        ),
                        color: tokens.textMuted,
                        tooltip: _sheetAsGrid ? '一覧で表示' : '写真で表示',
                        onPressed: () =>
                            setState(() => _sheetAsGrid = !_sheetAsGrid),
                      ),
                    ],
                    IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      color: tokens.textMuted,
                      tooltip: '閉じる',
                      onPressed: _closeSheet,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      if (grouped)
        _buildGroupedMealSliver(content.groupedMeals)
      else if (content.mealLog != null)
        SliverToBoxAdapter(
          child: _buildMealContent(content.mealLog!, content.photos),
        )
      else if (content.place != null)
        SliverToBoxAdapter(child: _buildPlaceContent(content.place!)),
      SliverToBoxAdapter(
        child: SizedBox(height: 8 + context.systemBottomInset),
      ),
    ];
  }

  /// 同じ場所の記録。行の一覧か、写真のタイルで並べる。
  /// 詳細を開いてもシートは閉じない(戻ってきて続きを選べるように)。
  Widget _buildGroupedMealSliver(List<_MealLogWithPhotos> items) {
    final theme = Theme.of(context);
    final tokens = KokoTokens.of(context);

    if (_sheetAsGrid) {
      return SliverPadding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
        sliver: SliverGrid.builder(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 180,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            return MealGridTile(
              key: ValueKey(item.log.id),
              mealLog: item.log,
              photos: item.photos,
              onTap: () => context.push('/meal/${item.log.id}'),
            );
          },
        ),
      );
    }

    final dateFormat = DateFormat('M/d (E) HH:mm', 'ja');
    return SliverList.builder(
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        final firstPhoto = item.photos.isNotEmpty ? item.photos.first : null;
        final menuName = item.photos
            .where((p) => p.displayName != null)
            .map((p) => p.displayName!)
            .join('、');

        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: firstPhoto != null
                ? CachedPhotoImage(
                    localPath: firstPhoto.localPath,
                    thumbnailPath: firstPhoto.thumbnailUrl,
                    originalUrl: firstPhoto.originalUrl,
                    width: 48,
                    height: 48,
                    fullQuality: false,
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
          onTap: () => context.push('/meal/${item.log.id}'),
        );
      },
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
                      fullQuality: false,
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
                onPressed: () => context.push('/meal/${log.id}'),
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
    // 入力欄の中身はシートの描き直しをまたいで持つ(描き直すたびに作ると
    // カーソルが先頭へ飛ぶ)
    final keywordController = TextEditingController(text: _filter.keyword);

    void apply(BuildContext sheetContext) {
      Navigator.pop(sheetContext);
      setState(() => _filter = tempFilter);
      _loadMealMarkers();
    }

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (context, setSheetState) {
          final tokens = KokoTokens.of(context);
          return SafeArea(
            child: SingleChildScrollView(
              // キーボードが出たぶん持ち上げて、入力欄が隠れないようにする
              padding: EdgeInsets.fromLTRB(
                  16, 4, 16, 8 + MediaQuery.viewInsetsOf(context).bottom),
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
                            keywordController.clear();
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
                    controller: keywordController,
                    textInputAction: TextInputAction.search,
                    decoration: const InputDecoration(
                      hintText: 'メニュー名で検索',
                      prefixIcon: Icon(Icons.search, size: 20),
                    ),
                    onChanged: (v) {
                      tempFilter = tempFilter.copyWith(keyword: v);
                    },
                    onSubmitted: (_) => apply(context),
                  ),
                  const SizedBox(height: 16),

                  // 適用ボタン
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => apply(context),
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
    keywordController.dispose();
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
  /// 記録のシートを見分けるキー。検索した店のシートには無い
  final String? key;
  final MealLog? mealLog;
  final List<MealPhoto> photos;
  final PlaceInfo? place;
  final String? groupName;
  final List<_MealLogWithPhotos> groupedMeals;

  _SheetContent({
    this.key,
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
