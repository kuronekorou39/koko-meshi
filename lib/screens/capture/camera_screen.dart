import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../../database/local_database.dart';
import '../../models/saved_place.dart';
import '../../services/location_service.dart';

/// カメラ画面の撮影結果
class CameraCaptureResult {
  final XFile photo;
  final bool aiEnabled;
  final Position? position;
  final String? address;
  final String? locationTag; // 'home' or placeId or null

  CameraCaptureResult({
    required this.photo,
    required this.aiEnabled,
    this.position,
    this.address,
    this.locationTag,
  });
}

/// 独自カメラ画面: 撮影 → 同画面で確認 → 保存 or 撮り直し
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  bool _isInitialized = false;
  bool _isCapturing = false;
  int _currentCameraIndex = 0;
  FlashMode _flashMode = FlashMode.auto;

  // 撮影後の確認モード
  XFile? _capturedPhoto;
  bool get _isReviewMode => _capturedPhoto != null;

  // 手動回転 (0, 90, 180, 270)
  int _rotationDegrees = 0;

  // フラッシュ演出
  late AnimationController _flashAnimController;
  late Animation<double> _flashAnimation;

  // AI解析トグル
  bool _aiEnabled = true;

  // GPS
  Position? _position;
  String? _address;
  bool _loadingLocation = true;

  // マイプレイス
  List<SavedPlace> _savedPlaces = [];
  String? _selectedLocationTag; // 'home', placeId, or null
  String? _autoMatchedTag; // GPS自動マッチ結果

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _flashAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
    _flashAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _flashAnimController, curve: Curves.easeOut),
    );
    _flashAnimController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _flashAnimController.reverse();
      }
    });
    _initCamera();
    _fetchLocation();
    _loadSavedPlaces();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    _flashAnimController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      _controller?.dispose();
    } else if (state == AppLifecycleState.resumed) {
      if (!_isReviewMode) _initCamera();
    }
  }

  // ── カメラ初期化 ──

  Future<void> _initCamera() async {
    _cameras = await availableCameras();
    if (_cameras.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('カメラが見つかりません')),
        );
        Navigator.pop(context);
      }
      return;
    }
    await _setupController(_cameras[_currentCameraIndex]);
  }

  Future<void> _setupController(CameraDescription camera) async {
    final prev = _controller;
    final controller = CameraController(
      camera,
      ResolutionPreset.max,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    _controller = controller;
    await prev?.dispose();

    try {
      await controller.initialize();
      await controller.setFlashMode(_flashMode);
      if (mounted) setState(() => _isInitialized = true);
    } catch (e) {
      debugPrint('Camera init error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('カメラ初期化エラー: $e')),
        );
        Navigator.pop(context);
      }
    }
  }

  Future<void> _switchCamera() async {
    if (_cameras.length < 2) return;
    _currentCameraIndex = (_currentCameraIndex + 1) % _cameras.length;
    setState(() => _isInitialized = false);
    await _setupController(_cameras[_currentCameraIndex]);
  }

  void _cycleFlash() {
    const modes = [FlashMode.auto, FlashMode.always, FlashMode.off];
    final nextIndex = (modes.indexOf(_flashMode) + 1) % modes.length;
    _flashMode = modes[nextIndex];
    _controller?.setFlashMode(_flashMode);
    setState(() {});
  }

  IconData get _flashIcon {
    switch (_flashMode) {
      case FlashMode.auto:
        return Icons.flash_auto;
      case FlashMode.always:
        return Icons.flash_on;
      case FlashMode.off:
        return Icons.flash_off;
      default:
        return Icons.flash_auto;
    }
  }

  String get _flashLabel {
    switch (_flashMode) {
      case FlashMode.auto:
        return '自動';
      case FlashMode.always:
        return 'ON';
      case FlashMode.off:
        return 'OFF';
      default:
        return '自動';
    }
  }

  // ── GPS ──

  Future<void> _fetchLocation() async {
    final pos = await LocationService.getCurrentPosition();
    if (!mounted) return;

    setState(() {
      _position = pos;
      _loadingLocation = pos != null; // 住所取得中
    });

    if (pos != null) {
      final addr = await LocationService.getAddressFromPosition(pos);
      if (mounted) {
        setState(() {
          _address = addr;
          _loadingLocation = false;
        });
        _autoMatchPlace();
      }
    } else {
      if (mounted) setState(() => _loadingLocation = false);
    }
  }

  // ── マイプレイス ──

  Future<void> _loadSavedPlaces() async {
    final places = await LocalDatabase.getSavedPlaces();
    if (mounted) setState(() => _savedPlaces = places);
  }

  void _autoMatchPlace() {
    if (_position == null || _savedPlaces.isEmpty) return;
    for (final place in _savedPlaces) {
      final distance = Geolocator.distanceBetween(
        _position!.latitude,
        _position!.longitude,
        place.latitude,
        place.longitude,
      );
      if (distance <= 100) {
        final tag = place.iconType == 'home' ? 'home' : place.id;
        setState(() {
          _autoMatchedTag = tag;
          _selectedLocationTag = tag;
        });
        return;
      }
    }
  }

  // ── 撮影 ──

  Future<void> _takePicture() async {
    if (_isCapturing || _controller == null || !_controller!.value.isInitialized) {
      return;
    }

    setState(() => _isCapturing = true);

    // フラッシュ演出（シャッター感）
    _flashAnimController.forward();

    try {
      final xfile = await _controller!.takePicture();

      // 回転が必要なら適用、不要ならそのまま使用
      String photoPath = xfile.path;
      if (_rotationDegrees != 0) {
        final tempDir = await getTemporaryDirectory();
        final rotatedPath = p.join(tempDir.path, 'rotated_${DateTime.now().millisecondsSinceEpoch}.jpg');
        await _saveRotated(xfile.path, rotatedPath);
        photoPath = rotatedPath;
      }

      if (mounted) {
        setState(() {
          _capturedPhoto = XFile(photoPath);
          _isCapturing = false;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('撮影エラー: $e'), duration: const Duration(seconds: 5)),
        );
        setState(() => _isCapturing = false);
      }
    }
  }

  /// 回転を適用して保存
  Future<void> _saveRotated(String srcPath, String destPath) async {
    final bytes = await File(srcPath).readAsBytes();
    var image = img.decodeImage(bytes);
    if (image == null) {
      await File(srcPath).copy(destPath);
      return;
    }
    image = img.copyRotate(image, angle: _rotationDegrees);
    final encoded = img.encodeJpg(image, quality: 95);
    await File(destPath).writeAsBytes(encoded);
  }

  /// 撮り直し
  void _retake() {
    setState(() => _capturedPhoto = null);
  }

  /// 手動回転 (90°ずつ)
  void _rotate() {
    setState(() {
      _rotationDegrees = (_rotationDegrees + 90) % 360;
    });
  }

  /// 保存確定
  void _confirm() {
    if (_capturedPhoto == null) return;
    final result = CameraCaptureResult(
      photo: _capturedPhoto!,
      aiEnabled: _aiEnabled,
      position: _position,
      address: _address,
      locationTag: _selectedLocationTag,
    );
    Navigator.pop(context, result);
  }

  // ── UI ──

  @override
  Widget build(BuildContext context) {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.manual,
          overlays: SystemUiOverlay.values,
        );
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            // メイン表示
            if (_isReviewMode)
              // 撮影済み写真（回転適用済み）
              Center(
                child: Image.file(
                  File(_capturedPhoto!.path),
                  fit: BoxFit.contain,
                ),
              )
            else if (_isInitialized)
              // カメラプレビュー（回転付き）
              Center(
                child: RotatedBox(
                  quarterTurns: _rotationDegrees ~/ 90,
                  child: CameraPreview(_controller!),
                ),
              )
            else
              const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),

            // フラッシュ演出
            AnimatedBuilder(
              animation: _flashAnimation,
              builder: (context, _) => _flashAnimation.value > 0
                  ? Container(
                      color: Colors.white.withValues(alpha: _flashAnimation.value),
                    )
                  : const SizedBox.shrink(),
            ),

            // 上部コントロール
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              left: 16,
              right: 16,
              child: _buildTopBar(),
            ),

            // 下部コントロール
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: _isReviewMode ? _buildReviewControls() : _buildCaptureControls(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    if (_isReviewMode) {
      return const SizedBox.shrink();
    }
    return Row(
      children: [
        _circleButton(
          icon: Icons.close,
          onTap: () => Navigator.pop(context),
        ),
        const Spacer(),
        // 回転ボタン
        _circleButton(
          icon: Icons.rotate_right,
          label: _rotationDegrees == 0 ? null : '$_rotationDegrees°',
          onTap: _rotate,
        ),
        const SizedBox(width: 12),
        _circleButton(
          icon: _flashIcon,
          label: _flashLabel,
          onTap: _cycleFlash,
        ),
        if (_cameras.length >= 2) ...[
          const SizedBox(width: 12),
          _circleButton(
            icon: Icons.flip_camera_android,
            onTap: _switchCamera,
          ),
        ],
      ],
    );
  }

  /// 撮影モード: シャッターボタン
  Widget _buildCaptureControls() {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).padding.bottom + 32,
      ),
      child: Center(
        child: GestureDetector(
          onTap: _isCapturing ? null : _takePicture,
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 4),
            ),
            child: Center(
              child: _isCapturing
                  ? const CircularProgressIndicator(color: Colors.white, strokeWidth: 3)
                  : Container(
                      width: 58,
                      height: 58,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  /// 確認モード: 撮り直し / 保存 / AI / GPS / マイプレイス
  Widget _buildReviewControls() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
      padding: EdgeInsets.fromLTRB(
        16,
        24,
        16,
        MediaQuery.of(context).padding.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // GPS + マイプレイス
          _buildLocationRow(),
          const SizedBox(height: 12),

          // ボタン行: [撮り直し] [✓保存] [AIトグル]
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // 撮り直し
              _actionButton(
                icon: Icons.arrow_back,
                label: '撮り直し',
                onTap: _retake,
              ),
              const SizedBox(width: 24),
              // 保存ボタン（大きめ）
              GestureDetector(
                onTap: _confirm,
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  child: Icon(
                    Icons.check,
                    color: Theme.of(context).colorScheme.onPrimary,
                    size: 32,
                  ),
                ),
              ),
              const SizedBox(width: 24),
              // AIトグル
              _actionButton(
                icon: _aiEnabled ? Icons.auto_awesome : Icons.auto_awesome_outlined,
                label: _aiEnabled ? 'AI ON' : 'AI OFF',
                onTap: () => setState(() => _aiEnabled = !_aiEnabled),
                active: _aiEnabled,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLocationRow() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // GPS情報
        Row(
          children: [
            Icon(
              Icons.location_on_outlined,
              size: 16,
              color: _position != null ? Colors.white70 : Colors.white30,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: _loadingLocation
                  ? const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: Colors.white54,
                      ),
                    )
                  : Text(
                      _position != null
                          ? (_address ?? '${_position!.latitude.toStringAsFixed(4)}, ${_position!.longitude.toStringAsFixed(4)}')
                          : '位置情報なし',
                      style: TextStyle(
                        fontSize: 12,
                        color: _position != null ? Colors.white70 : Colors.white38,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
            ),
          ],
        ),

        // マイプレイス
        if (_savedPlaces.isNotEmpty) ...[
          const SizedBox(height: 8),
          SizedBox(
            height: 32,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _savedPlaces.length + 1, // +1 for "なし"
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                if (index == 0) {
                  final isSelected = _selectedLocationTag == null;
                  return _placeChip(
                    label: '指定なし',
                    icon: Icons.location_off_outlined,
                    isSelected: isSelected,
                    onTap: () => setState(() => _selectedLocationTag = null),
                  );
                }
                final place = _savedPlaces[index - 1];
                final tag = place.iconType == 'home' ? 'home' : place.id;
                final isSelected = _selectedLocationTag == tag;
                final isAutoMatched = _autoMatchedTag == tag;
                return _placeChip(
                  label: place.name + (isAutoMatched ? ' (近く)' : ''),
                  icon: place.iconType == 'home'
                      ? Icons.home_outlined
                      : place.iconType == 'friend'
                          ? Icons.person_outlined
                          : Icons.place_outlined,
                  isSelected: isSelected,
                  onTap: () => setState(() => _selectedLocationTag = tag),
                );
              },
            ),
          ),
        ],
      ],
    );
  }

  Widget _placeChip({
    required String label,
    required IconData icon,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected ? Colors.white24 : Colors.white10,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: isSelected ? Colors.white70 : Colors.white24,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: isSelected ? Colors.white : Colors.white54),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: isSelected ? Colors.white : Colors.white54,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _actionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool active = true,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active ? Colors.white24 : Colors.white10,
            ),
            child: Icon(
              icon,
              color: active ? Colors.white : Colors.white54,
              size: 22,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color: active ? Colors.white : Colors.white54,
            ),
          ),
        ],
      ),
    );
  }

  Widget _circleButton({
    required IconData icon,
    String? label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 22),
            if (label != null) ...[
              const SizedBox(width: 4),
              Text(label, style: const TextStyle(color: Colors.white, fontSize: 12)),
            ],
          ],
        ),
      ),
    );
  }
}
