import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../../config/env.dart';
import '../../models/saved_place.dart';
import '../../services/location_service.dart';
import '../../theme/app_theme.dart';

/// マイプレイス編集画面
///
/// ユーザーが自宅やお気に入り場所を地図上で設定・編集するための画面。
/// マップ中央に十字アイコンを表示し、カメラ移動で位置を指定する。
class PlaceEditorScreen extends StatefulWidget {
  /// マーカーの初期位置（null の場合は現在地 or 東京駅）
  final LatLng? initialPosition;

  /// 名前の初期値
  final String? initialName;

  /// アイコン種別（'home' または 'favorite'）
  final String iconType;

  /// 既存のマイプレイスID（編集時に指定）
  final String? existingId;

  const PlaceEditorScreen({
    super.key,
    this.initialPosition,
    this.initialName,
    this.iconType = 'favorite',
    this.existingId,
  });

  @override
  State<PlaceEditorScreen> createState() => _PlaceEditorScreenState();
}

class _PlaceEditorScreenState extends State<PlaceEditorScreen> {
  static const _defaultPosition = LatLng(35.6812, 139.7671); // 東京駅

  GoogleMapController? _mapController;
  late LatLng _centerPosition;
  bool _loadingPosition = true;
  bool _saving = false;

  // 住所表示
  String? _address;
  bool _loadingAddress = false;
  Timer? _addressDebounce;

  // 名前入力
  late final TextEditingController _nameController;

  // 場所検索
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  List<_SearchResult> _searchResults = [];
  bool _isSearching = false;
  bool _showSearchResults = false;
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    _centerPosition = widget.initialPosition ?? _defaultPosition;
    _nameController = TextEditingController(text: widget.initialName ?? '');
    _initPosition();
  }

  @override
  void dispose() {
    _mapController?.dispose();
    _nameController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _addressDebounce?.cancel();
    _searchDebounce?.cancel();
    super.dispose();
  }

  /// 初期位置の決定: initialPosition が無ければ現在地を取得
  Future<void> _initPosition() async {
    if (widget.initialPosition != null) {
      setState(() => _loadingPosition = false);
      _reverseGeocode(_centerPosition);
      return;
    }

    final pos = await LocationService.getCurrentPosition();
    if (!mounted) return;

    if (pos != null) {
      _centerPosition = LatLng(pos.latitude, pos.longitude);
      _mapController?.animateCamera(
        CameraUpdate.newLatLng(_centerPosition),
      );
    }

    setState(() => _loadingPosition = false);
    _reverseGeocode(_centerPosition);
  }

  /// 現在地に移動
  Future<void> _moveToCurrentLocation() async {
    final pos = await LocationService.getCurrentPosition();
    if (!mounted || pos == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('現在地を取得できませんでした')),
        );
      }
      return;
    }

    final target = LatLng(pos.latitude, pos.longitude);
    _mapController?.animateCamera(
      CameraUpdate.newLatLngZoom(target, 17),
    );
  }

  /// マップカメラ移動完了時
  void _onCameraIdle() {
    _addressDebounce?.cancel();
    _addressDebounce = Timer(const Duration(milliseconds: 400), () {
      _reverseGeocode(_centerPosition);
    });
  }

  /// マップカメラ移動中
  void _onCameraMove(CameraPosition position) {
    _centerPosition = position.target;
  }

  /// 逆ジオコーディングで住所を取得
  Future<void> _reverseGeocode(LatLng position) async {
    setState(() => _loadingAddress = true);

    try {
      final placemarks = await placemarkFromCoordinates(
        position.latitude,
        position.longitude,
      );

      if (!mounted) return;

      if (placemarks.isEmpty) {
        setState(() {
          _address = null;
          _loadingAddress = false;
        });
        return;
      }

      final p = placemarks.first;
      final parts = <String>[
        if (p.administrativeArea != null && p.administrativeArea!.isNotEmpty)
          p.administrativeArea!,
        if (p.locality != null && p.locality!.isNotEmpty) p.locality!,
        if (p.subLocality != null && p.subLocality!.isNotEmpty) p.subLocality!,
        if (p.thoroughfare != null && p.thoroughfare!.isNotEmpty)
          p.thoroughfare!,
        if (p.subThoroughfare != null && p.subThoroughfare!.isNotEmpty)
          p.subThoroughfare!,
      ];

      setState(() {
        _address = parts.isEmpty ? null : parts.join('');
        _loadingAddress = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _address = null;
          _loadingAddress = false;
        });
      }
    }
  }

  /// Places API (New) でテキスト検索
  Future<void> _searchPlaces(String query) async {
    if (query.trim().isEmpty) {
      setState(() {
        _searchResults = [];
        _showSearchResults = false;
        _isSearching = false;
      });
      return;
    }

    final apiKey = Env.googleMapsApiKey;
    if (apiKey.isEmpty) return;

    setState(() => _isSearching = true);

    try {
      final url =
          Uri.parse('https://places.googleapis.com/v1/places:searchText');
      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': apiKey,
          'X-Goog-FieldMask':
              'places.displayName,places.formattedAddress,places.location',
        },
        body: jsonEncode({
          'textQuery': query,
          'languageCode': 'ja',
        }),
      );

      if (!mounted) return;

      if (response.statusCode != 200) {
        setState(() {
          _searchResults = [];
          _isSearching = false;
        });
        return;
      }

      final data = jsonDecode(response.body);
      final places = data['places'] as List<dynamic>? ?? [];

      setState(() {
        _searchResults = places.map((p) {
          final location = p['location'] as Map<String, dynamic>;
          final displayName = p['displayName'] as Map<String, dynamic>?;
          return _SearchResult(
            name: displayName?['text'] as String? ?? '',
            address: p['formattedAddress'] as String? ?? '',
            position: LatLng(
              (location['latitude'] as num).toDouble(),
              (location['longitude'] as num).toDouble(),
            ),
          );
        }).toList();
        _showSearchResults = _searchResults.isNotEmpty;
        _isSearching = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _searchResults = [];
          _isSearching = false;
        });
      }
    }
  }

  /// 検索結果を選択
  void _selectSearchResult(_SearchResult result) {
    _searchController.text = result.name;
    _searchFocusNode.unfocus();

    setState(() {
      _showSearchResults = false;
      _centerPosition = result.position;
    });

    _mapController?.animateCamera(
      CameraUpdate.newLatLngZoom(result.position, 17),
    );
  }

  /// 保存処理
  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('名前を入力してください')),
      );
      return;
    }

    setState(() => _saving = true);

    final place = SavedPlace(
      id: widget.existingId ?? const Uuid().v4(),
      name: name,
      latitude: _centerPosition.latitude,
      longitude: _centerPosition.longitude,
      iconType: widget.iconType,
      createdAt: DateTime.now(),
    );

    if (mounted) {
      Navigator.pop(context, place);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isEditing = widget.existingId != null;
    final title = isEditing ? 'マイプレイスを編集' : 'マイプレイスを追加';
    final iconLabel = widget.iconType == 'home' ? '自宅' : 'お気に入り';

    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: Text(title),
      ),
      body: _loadingPosition
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // 検索バー
                _buildSearchBar(colorScheme),

                // 地図 + 十字マーカーオーバーレイ
                Expanded(
                  child: Stack(
                    children: [
                      // Google Map
                      GoogleMap(
                        initialCameraPosition: CameraPosition(
                          target: _centerPosition,
                          zoom: 16,
                        ),
                        onMapCreated: (controller) {
                          _mapController = controller;
                        },
                        onCameraMove: _onCameraMove,
                        onCameraIdle: _onCameraIdle,
                        onTap: (_) {
                          _searchFocusNode.unfocus();
                          setState(() => _showSearchResults = false);
                        },
                        myLocationEnabled: true,
                        myLocationButtonEnabled: false,
                        zoomControlsEnabled: false,
                        mapToolbarEnabled: false,
                      ),

                      // 中心の十字アイコン
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 48),
                          child: Icon(
                            Icons.location_on,
                            size: 48,
                            color: widget.iconType == 'home'
                                ? colorScheme.primary
                                : colorScheme.error,
                            shadows: [
                              Shadow(
                                blurRadius: 8,
                                color: colorScheme.shadow
                                    .withValues(alpha: 0.38),
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                        ),
                      ),

                      // 十字の影（ドロップポイント）
                      Center(
                        child: Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color:
                                colorScheme.shadow.withValues(alpha: 0.45),
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),

                      // 現在地ボタン
                      Positioned(
                        right: 16,
                        bottom: 16,
                        child: _mapButton(
                          icon: Icons.my_location,
                          tooltip: '現在地へ移動',
                          onTap: _moveToCurrentLocation,
                        ),
                      ),

                      // 検索結果ドロップダウン
                      if (_showSearchResults) _buildSearchResults(colorScheme),
                    ],
                  ),
                ),

                // 住所表示 + 名前入力 + 保存ボタン
                _buildBottomPanel(colorScheme, iconLabel),
              ],
            ),
    );
  }

  /// 検索バーウィジェット
  Widget _buildSearchBar(ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: TextField(
        controller: _searchController,
        focusNode: _searchFocusNode,
        decoration: InputDecoration(
          hintText: '場所を検索',
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: _searchController.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, size: 20),
                  onPressed: () {
                    _searchController.clear();
                    setState(() {
                      _searchResults = [];
                      _showSearchResults = false;
                    });
                  },
                )
              : (_isSearching
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : null),
        ),
        textInputAction: TextInputAction.search,
        onChanged: (value) {
          _searchDebounce?.cancel();
          _searchDebounce = Timer(const Duration(milliseconds: 500), () {
            _searchPlaces(value);
          });
        },
        onSubmitted: (value) {
          _searchDebounce?.cancel();
          _searchPlaces(value);
        },
      ),
    );
  }

  /// 検索結果ドロップダウン
  Widget _buildSearchResults(ColorScheme colorScheme) {
    final tokens = KokoTokens.of(context);
    final bg = Theme.of(context).brightness == Brightness.light
        ? colorScheme.surface
        : colorScheme.surfaceContainerHigh;
    return Positioned(
      top: 0,
      left: 16,
      right: 16,
      child: Material(
        color: bg,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius:
              const BorderRadius.vertical(bottom: Radius.circular(12)),
          side: BorderSide(color: tokens.hairline, width: 0.8),
        ),
        child: Container(
          constraints: const BoxConstraints(maxHeight: 280),
          child: ListView.separated(
            padding: EdgeInsets.zero,
            shrinkWrap: true,
            itemCount: _searchResults.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final result = _searchResults[index];
              return ListTile(
                leading: Icon(
                  Icons.place_outlined,
                  color: colorScheme.primary,
                ),
                title: Text(
                  result.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  result.address,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: tokens.textMuted,
                  ),
                ),
                dense: true,
                onTap: () => _selectSearchResult(result),
              );
            },
          ),
        ),
      ),
    );
  }

  /// マップ上のオーバーレイボタン(現在地)
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

  /// 下部パネル: 住所・名前入力・保存ボタン
  Widget _buildBottomPanel(ColorScheme colorScheme, String iconLabel) {
    final theme = Theme.of(context);
    final tokens = KokoTokens.of(context);
    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          top: BorderSide(color: tokens.hairline, width: 0.8),
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 住所表示
              Row(
                children: [
                  Icon(
                    Icons.location_on_outlined,
                    size: 18,
                    color: tokens.textMuted,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _loadingAddress
                        ? Row(
                            children: [
                              SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: tokens.textMuted,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '住所を取得中…',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: tokens.textMuted,
                                ),
                              ),
                            ],
                          )
                        : Text(
                            _address ?? '住所を取得できません',
                            style: TextStyle(
                              fontSize: 13,
                              color: _address != null
                                  ? colorScheme.onSurface
                                  : tokens.textFaint,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              // 種別ラベル
              Row(
                children: [
                  Icon(
                    widget.iconType == 'home'
                        ? Icons.home_outlined
                        : Icons.star_outline,
                    size: 16,
                    color: tokens.textMuted,
                  ),
                  const SizedBox(width: 6),
                  Text(iconLabel, style: tokens.sectionLabel),
                ],
              ),

              const SizedBox(height: 8),

              // 名前表示 + 編集ボタン
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _nameController.text.isEmpty
                          ? (widget.iconType == 'home' ? '自宅' : 'お気に入り')
                          : _nameController.text,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    color: tokens.textMuted,
                    tooltip: '名前を変更',
                    onPressed: () async {
                      final controller = TextEditingController(
                        text: _nameController.text,
                      );
                      final result = await showDialog<String>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('場所の名前'),
                          content: TextField(
                            controller: controller,
                            autofocus: true,
                            decoration: InputDecoration(
                              hintText: widget.iconType == 'home'
                                  ? '例: 自宅'
                                  : '例: よく行くカフェ',
                            ),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx),
                              child: const Text('キャンセル'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
                              child: const Text('OK'),
                            ),
                          ],
                        ),
                      );
                      if (result != null && result.isNotEmpty) {
                        setState(() => _nameController.text = result);
                      }
                    },
                  ),
                ],
              ),

              const SizedBox(height: 8),

              // 保存ボタン
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colorScheme.onPrimary,
                        ),
                      )
                    : const Icon(Icons.check),
                label: Text(widget.existingId != null ? '更新する' : '保存する'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 場所検索結果
class _SearchResult {
  final String name;
  final String address;
  final LatLng position;

  const _SearchResult({
    required this.name,
    required this.address,
    required this.position,
  });
}
