import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../../theme/app_theme.dart';
import 'crop_screen.dart';

// ---------------------------------------------------------------------------
// 編集結果（処理は後で行う。エディタは即座にこれを返す）
// ---------------------------------------------------------------------------

class PhotoEditResult {
  final double brightness;
  final double contrast;
  final double saturation;
  final double warmth;
  final double vignette;
  final String? croppedPath; // null = クロップなし

  const PhotoEditResult({
    this.brightness = 0,
    this.contrast = 0,
    this.saturation = 0,
    this.warmth = 0,
    this.vignette = 0,
    this.croppedPath,
  });

  bool get hasEdits =>
      brightness != 0 ||
      contrast != 0 ||
      saturation != 0 ||
      warmth != 0 ||
      vignette != 0 ||
      croppedPath != null;
}

// ---------------------------------------------------------------------------
// 画像処理パラメータ（isolate用）
// ---------------------------------------------------------------------------

class ImageProcessParams {
  final String inputPath;
  final String outputPath;
  final double brightness;
  final double contrast;
  final double saturation;
  final double warmth;
  final double vignette;

  const ImageProcessParams({
    required this.inputPath,
    required this.outputPath,
    required this.brightness,
    required this.contrast,
    required this.saturation,
    required this.warmth,
    required this.vignette,
  });
}

/// isolateで画像を処理する（CaptureScreenからも呼ばれる）
String? processEditedImage(ImageProcessParams params) {
  try {
    final bytes = File(params.inputPath).readAsBytesSync();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;

    var image = decoded;

    if (params.brightness != 0) {
      final offset = (params.brightness / 100 * 150).round();
      image = _adjustBrightness(image, offset);
    }
    if (params.contrast != 0) {
      final factor = 1.0 + params.contrast / 100;
      image = _adjustContrast(image, factor);
    }
    if (params.saturation != 0) {
      final factor = 1.0 + params.saturation / 100;
      image = _adjustSaturation(image, factor);
    }
    if (params.warmth != 0) {
      final offset = (params.warmth / 100 * 40).round();
      image = _adjustWarmth(image, offset);
    }
    if (params.vignette > 0) {
      image = _applyVignette(image, params.vignette / 100);
    }

    final ext = p.extension(params.outputPath).toLowerCase();
    Uint8List output;
    if (ext == '.png') {
      output = Uint8List.fromList(img.encodePng(image));
    } else {
      output = Uint8List.fromList(img.encodeJpg(image, quality: 95));
    }

    File(params.outputPath).writeAsBytesSync(output);
    return params.outputPath;
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------------------
// 編集パラメータからColorFilterマトリクスを生成（他画面でプレビュー用）
// ---------------------------------------------------------------------------

List<double> buildEditColorMatrix(PhotoEditResult params) {
  List<double> m = _identityMatrix();
  m = _multiplyMatrix(m, _brightnessMatrix(params.brightness));
  m = _multiplyMatrix(m, _contrastMatrix(params.contrast));
  m = _multiplyMatrix(m, _saturationMatrix(params.saturation));
  m = _multiplyMatrix(m, _warmthMatrix(params.warmth));
  return m;
}

List<double> _identityMatrix() => <double>[
  1, 0, 0, 0, 0,
  0, 1, 0, 0, 0,
  0, 0, 1, 0, 0,
  0, 0, 0, 1, 0,
];

List<double> _multiplyMatrix(List<double> a, List<double> b) {
  final result = List<double>.filled(20, 0);
  for (int y = 0; y < 4; y++) {
    for (int x = 0; x < 5; x++) {
      double sum = 0;
      for (int k = 0; k < 4; k++) {
        sum += a[y * 5 + k] * b[k * 5 + x];
      }
      if (x == 4) sum += a[y * 5 + 4];
      result[y * 5 + x] = sum;
    }
  }
  return result;
}

List<double> _brightnessMatrix(double value) {
  final v = value / 100 * 150;
  return <double>[1, 0, 0, 0, v, 0, 1, 0, 0, v, 0, 0, 1, 0, v, 0, 0, 0, 1, 0];
}

List<double> _contrastMatrix(double value) {
  final factor = 1.0 + value / 100;
  final offset = 128 * (1 - factor);
  return <double>[
    factor, 0, 0, 0, offset,
    0, factor, 0, 0, offset,
    0, 0, factor, 0, offset,
    0, 0, 0, 1, 0,
  ];
}

List<double> _saturationMatrix(double value) {
  final s = 1.0 + value / 100;
  const lr = 0.2126, lg = 0.7152, lb = 0.0722;
  final sr = (1 - s) * lr, sg = (1 - s) * lg, sb = (1 - s) * lb;
  return <double>[
    sr + s, sg, sb, 0, 0,
    sr, sg + s, sb, 0, 0,
    sr, sg, sb + s, 0, 0,
    0, 0, 0, 1, 0,
  ];
}

List<double> _warmthMatrix(double value) {
  final v = value / 100 * 40;
  return <double>[1, 0, 0, 0, v, 0, 1, 0, 0, 0, 0, 0, 1, 0, -v, 0, 0, 0, 1, 0];
}

// ---------------------------------------------------------------------------
// PhotoEditorScreen
// ---------------------------------------------------------------------------

/// 食事写真の編集画面。
///
/// [filePath] を受け取り、編集パラメータ [PhotoEditResult] を即座に返す。
/// 重い画像処理は呼び出し元で行う。
class PhotoEditorScreen extends StatefulWidget {
  final String filePath;
  final PhotoEditResult? initialParams;

  const PhotoEditorScreen({
    super.key,
    required this.filePath,
    this.initialParams,
  });

  @override
  State<PhotoEditorScreen> createState() => _PhotoEditorScreenState();
}

// ---------------------------------------------------------------------------
// Filter preset definitions
// ---------------------------------------------------------------------------

class _FilterPreset {
  final String name;
  final double brightness;
  final double contrast;
  final double saturation;
  final double warmth;
  final double vignette;

  const _FilterPreset({
    required this.name,
    this.brightness = 0,
    this.contrast = 0,
    this.saturation = 0,
    this.warmth = 0,
    this.vignette = 0,
  });
}

const _presets = <_FilterPreset>[
  _FilterPreset(name: 'オリジナル'),
  _FilterPreset(
    name: 'おいしい',
    warmth: 25,
    saturation: 20,
    contrast: 10,
    brightness: 5,
  ),
  _FilterPreset(
    name: 'カフェ',
    warmth: 20,
    saturation: -15,
    contrast: -10,
    brightness: 10,
  ),
  _FilterPreset(
    name: '鮮やか',
    saturation: 50,
    contrast: 30,
  ),
  _FilterPreset(
    name: 'ナチュラル',
    warmth: 10,
    saturation: 8,
    contrast: 5,
    brightness: 5,
  ),
  _FilterPreset(
    name: 'レトロ',
    warmth: 35,
    saturation: -30,
    contrast: 10,
    brightness: -5,
    vignette: 30,
  ),
];

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

class _PhotoEditorScreenState extends State<PhotoEditorScreen>
    with SingleTickerProviderStateMixin {
  late String _currentPath;
  late TabController _tabController;

  double _brightness = 0;
  double _contrast = 0;
  double _saturation = 0;
  double _warmth = 0;
  double _vignette = 0;

  int _selectedPresetIndex = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);

    final p = widget.initialParams;
    if (p != null) {
      _currentPath = p.croppedPath ?? widget.filePath;
      _brightness = p.brightness;
      _contrast = p.contrast;
      _saturation = p.saturation;
      _warmth = p.warmth;
      _vignette = p.vignette;
      _selectedPresetIndex = _findMatchingPreset();
    } else {
      _currentPath = widget.filePath;
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  /// 現在の値に一致するプリセットを探す（なければ-1）
  int _findMatchingPreset() {
    for (int i = 0; i < _presets.length; i++) {
      final preset = _presets[i];
      if (preset.brightness == _brightness &&
          preset.contrast == _contrast &&
          preset.saturation == _saturation &&
          preset.warmth == _warmth &&
          preset.vignette == _vignette) {
        return i;
      }
    }
    return -1;
  }

  // -----------------------------------------------------------------------
  // Color matrix helpers
  // -----------------------------------------------------------------------

  List<double> _buildColorMatrix() {
    return buildEditColorMatrix(PhotoEditResult(
      brightness: _brightness,
      contrast: _contrast,
      saturation: _saturation,
      warmth: _warmth,
    ));
  }

  // -----------------------------------------------------------------------
  // Presets
  // -----------------------------------------------------------------------

  void _applyPreset(int index) {
    final preset = _presets[index];
    setState(() {
      _selectedPresetIndex = index;
      _brightness = preset.brightness;
      _contrast = preset.contrast;
      _saturation = preset.saturation;
      _warmth = preset.warmth;
      _vignette = preset.vignette;
    });
  }

  void _resetAll() {
    setState(() {
      _currentPath = widget.filePath;
    });
    _applyPreset(0);
  }

  // -----------------------------------------------------------------------
  // Crop
  // -----------------------------------------------------------------------

  Future<void> _crop() async {
    final result = await Navigator.push<CropResult>(
      context,
      MaterialPageRoute(
        builder: (_) => CropScreen(filePath: _currentPath),
      ),
    );

    if (result != null && mounted) {
      setState(() => _currentPath = result.croppedPath);
    }
  }

  // -----------------------------------------------------------------------
  // 完了 → パラメータを即座に返す（画像処理なし）
  // -----------------------------------------------------------------------

  void _done() {
    Navigator.pop(
      context,
      PhotoEditResult(
        brightness: _brightness,
        contrast: _contrast,
        saturation: _saturation,
        warmth: _warmth,
        vignette: _vignette,
        croppedPath: _currentPath != widget.filePath ? _currentPath : null,
      ),
    );
  }

  // -----------------------------------------------------------------------
  // Build
  // -----------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: EditorColors.background,
      appBar: AppBar(
        backgroundColor: EditorColors.background,
        foregroundColor: EditorColors.text,
        iconTheme: const IconThemeData(color: EditorColors.text),
        actionsIconTheme: const IconThemeData(color: EditorColors.text),
        titleTextStyle: const TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
          color: EditorColors.text,
        ),
        title: const Text('写真を編集'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.crop),
            tooltip: '切り取り',
            onPressed: _crop,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'リセット',
            onPressed: _resetAll,
          ),
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: '適用',
            onPressed: _done,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: _buildPreview()),
            Container(
              color: EditorColors.background,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TabBar(
                    controller: _tabController,
                    indicatorColor: EditorColors.accent,
                    labelColor: EditorColors.text,
                    unselectedLabelColor: EditorColors.textMuted,
                    dividerColor: EditorColors.hairline,
                    labelStyle: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w700),
                    unselectedLabelStyle: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w500),
                    tabs: const [
                      Tab(text: 'フィルター'),
                      Tab(text: '調整'),
                    ],
                  ),
                  SizedBox(
                    height: 180,
                    child: TabBarView(
                      controller: _tabController,
                      children: [
                        _buildFiltersTab(),
                        _buildAdjustmentsTab(),
                      ],
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

  Widget _buildPreview() {
    final matrix = _buildColorMatrix();

    Widget image = ColorFiltered(
      colorFilter: ColorFilter.matrix(matrix),
      child: Image.file(
        File(_currentPath),
        fit: BoxFit.contain,
        gaplessPlayback: true,
      ),
    );

    if (_vignette > 0) {
      image = Stack(
        fit: StackFit.passthrough,
        children: [
          image,
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _VignettePainter(intensity: _vignette / 100),
              ),
            ),
          ),
        ],
      );
    }

    return Container(
      color: EditorColors.background,
      alignment: Alignment.center,
      child: image,
    );
  }

  Widget _buildFiltersTab() {
    return Center(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          children: List.generate(_presets.length, (index) {
            final preset = _presets[index];
            final isSelected = index == _selectedPresetIndex;

            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: GestureDetector(
                onTap: () => _applyPreset(index),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isSelected
                              ? EditorColors.accent
                              : EditorColors.outline,
                          width: isSelected ? 2 : 1,
                        ),
                      ),
                      child: ClipOval(
                        child: ColorFiltered(
                          colorFilter: ColorFilter.matrix(
                            _buildPresetMatrix(preset),
                          ),
                          child: Image.file(
                            File(_currentPath),
                            fit: BoxFit.cover,
                            width: 72,
                            height: 72,
                            cacheWidth: 150,
                            gaplessPlayback: true,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      preset.name,
                      style: TextStyle(
                        fontSize: 12,
                        color: isSelected
                            ? EditorColors.accent
                            : EditorColors.textMuted,
                        fontWeight:
                            isSelected ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        ),
      ),
    );
  }

  static List<double> _buildPresetMatrix(_FilterPreset preset) {
    return buildEditColorMatrix(PhotoEditResult(
      brightness: preset.brightness,
      contrast: preset.contrast,
      saturation: preset.saturation,
      warmth: preset.warmth,
    ));
  }

  Widget _buildAdjustmentsTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: [
          _buildSlider(
            label: '明るさ',
            icon: Icons.brightness_6_outlined,
            value: _brightness,
            min: -100,
            max: 100,
            onChanged: (v) => setState(() {
              _brightness = v;
              _selectedPresetIndex = -1;
            }),
          ),
          _buildSlider(
            label: 'コントラスト',
            icon: Icons.contrast_outlined,
            value: _contrast,
            min: -80,
            max: 100,
            onChanged: (v) => setState(() {
              _contrast = v;
              _selectedPresetIndex = -1;
            }),
          ),
          _buildSlider(
            label: '彩度',
            icon: Icons.palette_outlined,
            value: _saturation,
            min: -100,
            max: 100,
            onChanged: (v) => setState(() {
              _saturation = v;
              _selectedPresetIndex = -1;
            }),
          ),
          _buildSlider(
            label: '色温度',
            icon: Icons.thermostat_outlined,
            value: _warmth,
            min: -100,
            max: 100,
            onChanged: (v) => setState(() {
              _warmth = v;
              _selectedPresetIndex = -1;
            }),
          ),
          _buildSlider(
            label: 'ビネット',
            icon: Icons.vignette_outlined,
            value: _vignette,
            min: 0,
            max: 100,
            onChanged: (v) => setState(() {
              _vignette = v;
              _selectedPresetIndex = -1;
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildSlider({
    required String label,
    required IconData icon,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
  }) {
    return Row(
      children: [
        const SizedBox(width: 4),
        Icon(icon, size: 20, color: EditorColors.textMuted),
        const SizedBox(width: 8),
        SizedBox(
          width: 52,
          child: Text(
            label,
            style:
                const TextStyle(fontSize: 11, color: EditorColors.textMuted),
            maxLines: 1,
            overflow: TextOverflow.visible,
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              activeTrackColor: EditorColors.accent,
              thumbColor: EditorColors.text,
              inactiveTrackColor: EditorColors.outline,
              overlayColor: EditorColors.accent.withValues(alpha: 0.12),
            ),
            child: Slider(
              value: value,
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
        ),
        SizedBox(
          width: 36,
          child: Text(
            value.round().toString(),
            textAlign: TextAlign.right,
            style: KokoTokens.of(context).numeral.copyWith(
                  fontSize: 12,
                  color: EditorColors.textMuted,
                ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Vignette painter
// ---------------------------------------------------------------------------

class _VignettePainter extends CustomPainter {
  final double intensity;

  _VignettePainter({required this.intensity});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.max(size.width, size.height) / 2;

    final paint = Paint()
      ..shader = RadialGradient(
        center: Alignment.center,
        radius: 1.0,
        colors: [
          Colors.transparent,
          Colors.black.withValues(alpha: 0.7 * intensity),
        ],
        stops: const [0.5, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: radius));

    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), paint);
  }

  @override
  bool shouldRepaint(_VignettePainter oldDelegate) =>
      oldDelegate.intensity != intensity;
}

// ---------------------------------------------------------------------------
// Pixel-level image processing helpers (for isolate)
// ---------------------------------------------------------------------------

img.Image _adjustBrightness(img.Image src, int offset) {
  for (int y = 0; y < src.height; y++) {
    for (int x = 0; x < src.width; x++) {
      final pixel = src.getPixel(x, y);
      src.setPixel(x, y, img.ColorUint8.rgba(
        _clamp(pixel.r.toInt() + offset),
        _clamp(pixel.g.toInt() + offset),
        _clamp(pixel.b.toInt() + offset),
        pixel.a.toInt(),
      ));
    }
  }
  return src;
}

img.Image _adjustContrast(img.Image src, double factor) {
  for (int y = 0; y < src.height; y++) {
    for (int x = 0; x < src.width; x++) {
      final pixel = src.getPixel(x, y);
      src.setPixel(x, y, img.ColorUint8.rgba(
        _clamp(((pixel.r.toInt() - 128) * factor + 128).round()),
        _clamp(((pixel.g.toInt() - 128) * factor + 128).round()),
        _clamp(((pixel.b.toInt() - 128) * factor + 128).round()),
        pixel.a.toInt(),
      ));
    }
  }
  return src;
}

img.Image _adjustSaturation(img.Image src, double factor) {
  const lr = 0.2126, lg = 0.7152, lb = 0.0722;
  for (int y = 0; y < src.height; y++) {
    for (int x = 0; x < src.width; x++) {
      final pixel = src.getPixel(x, y);
      final r = pixel.r.toInt(), g = pixel.g.toInt(), b = pixel.b.toInt();
      final gray = (lr * r + lg * g + lb * b).round();
      src.setPixel(x, y, img.ColorUint8.rgba(
        _clamp((gray + (r - gray) * factor).round()),
        _clamp((gray + (g - gray) * factor).round()),
        _clamp((gray + (b - gray) * factor).round()),
        pixel.a.toInt(),
      ));
    }
  }
  return src;
}

img.Image _adjustWarmth(img.Image src, int offset) {
  for (int y = 0; y < src.height; y++) {
    for (int x = 0; x < src.width; x++) {
      final pixel = src.getPixel(x, y);
      src.setPixel(x, y, img.ColorUint8.rgba(
        _clamp(pixel.r.toInt() + offset),
        pixel.g.toInt(),
        _clamp(pixel.b.toInt() - offset),
        pixel.a.toInt(),
      ));
    }
  }
  return src;
}

img.Image _applyVignette(img.Image src, double intensity) {
  final cx = src.width / 2;
  final cy = src.height / 2;
  final maxDist = math.sqrt(cx * cx + cy * cy);
  for (int y = 0; y < src.height; y++) {
    for (int x = 0; x < src.width; x++) {
      final dx = x - cx;
      final dy = y - cy;
      final dist = math.sqrt(dx * dx + dy * dy);
      final normalized = dist / maxDist;
      final vignetteAmount = ((normalized - 0.5) / 0.5).clamp(0.0, 1.0);
      final darken = 1.0 - vignetteAmount * 0.7 * intensity;
      final pixel = src.getPixel(x, y);
      src.setPixel(x, y, img.ColorUint8.rgba(
        _clamp((pixel.r.toInt() * darken).round()),
        _clamp((pixel.g.toInt() * darken).round()),
        _clamp((pixel.b.toInt() * darken).round()),
        pixel.a.toInt(),
      ));
    }
  }
  return src;
}

int _clamp(int value) => value.clamp(0, 255);
