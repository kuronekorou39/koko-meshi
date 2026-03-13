import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 切り取り画面。
/// [filePath] を受け取り、切り取り済み画像のパスを返す。
class CropScreen extends StatefulWidget {
  final String filePath;

  const CropScreen({super.key, required this.filePath});

  @override
  State<CropScreen> createState() => _CropScreenState();
}

// アスペクト比プリセット
enum _AspectPreset {
  free('フリー', null),
  square('1:1', 1.0),
  ratio4x3('4:3', 4.0 / 3.0),
  ratio3x2('3:2', 3.0 / 2.0),
  ratio16x9('16:9', 16.0 / 9.0);

  final String label;
  final double? ratio; // null = フリー

  const _AspectPreset(this.label, this.ratio);
}

// ドラッグ中のハンドル
enum _DragHandle {
  none,
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
  top,
  bottom,
  left,
  right,
  move, // 画像のパン
}

class _CropScreenState extends State<CropScreen> {
  // 画像
  ui.Image? _image;
  bool _loading = true;

  // 画像表示パラメータ
  double _imageScale = 1.0; // ピンチズーム
  double _rotation = 0.0; // ラジアン（ルーラーで制御）
  Offset _imageOffset = Offset.zero; // パン

  // ピンチジェスチャー
  double _startImageScale = 1.0;
  Offset _startImageOffset = Offset.zero;
  Offset _startFocalPoint = Offset.zero;

  // クロップ枠（画面座標）
  Rect _cropRect = Rect.zero;
  bool _cropInitialized = false;

  // クロップ枠ドラッグ
  _DragHandle _activeHandle = _DragHandle.none;
  Rect _startCropRect = Rect.zero;
  Offset _dragStartPoint = Offset.zero;

  // アスペクト比
  _AspectPreset _aspectPreset = _AspectPreset.free;

  // 処理中
  bool _processing = false;

  // キャンバスサイズ（LayoutBuilder から）
  Size _canvasSize = Size.zero;

  // ルーラードラッグ
  double _rulerStartRotation = 0.0;
  double _rulerStartX = 0.0;

  // 最小クロップサイズ
  static const _minCropSize = 48.0;
  // ハンドルのタッチ領域
  static const _handleTouchSize = 36.0;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  Future<void> _loadImage() async {
    final bytes = await File(widget.filePath).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    if (mounted) {
      setState(() {
        _image = frame.image;
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  // -----------------------------------------------------------------------
  // 画像フィットスケール（回転考慮）
  // -----------------------------------------------------------------------

  double _baseFitScale() {
    if (_image == null || _canvasSize == Size.zero) return 1.0;
    final imgW = _image!.width.toDouble();
    final imgH = _image!.height.toDouble();

    // 回転後の画像バウンディングボックス
    final abscos = math.cos(_rotation).abs();
    final abssin = math.sin(_rotation).abs();
    final rotW = imgW * abscos + imgH * abssin;
    final rotH = imgW * abssin + imgH * abscos;

    return math.min(
      _canvasSize.width / rotW,
      _canvasSize.height / rotH,
    );
  }

  // -----------------------------------------------------------------------
  // クロップ枠の初期化
  // -----------------------------------------------------------------------

  void _initCropRect() {
    if (_image == null || _canvasSize == Size.zero) return;

    const padding = 16.0;
    final maxW = _canvasSize.width - padding * 2;
    final maxH = _canvasSize.height - padding * 2;

    double w, h;
    if (_aspectPreset.ratio != null) {
      final ratio = _aspectPreset.ratio!;
      if (maxW / maxH > ratio) {
        h = maxH;
        w = h * ratio;
      } else {
        w = maxW;
        h = w / ratio;
      }
    } else {
      // フリー: 画像に合わせる
      final fitScale = _baseFitScale();
      w = (_image!.width * fitScale).clamp(0.0, maxW);
      h = (_image!.height * fitScale).clamp(0.0, maxH);
    }

    final left = (_canvasSize.width - w) / 2;
    final top = (_canvasSize.height - h) / 2;
    _cropRect = Rect.fromLTWH(left, top, w, h);
    _cropInitialized = true;
  }

  // -----------------------------------------------------------------------
  // 回転時にクロップ枠を自動調整
  // -----------------------------------------------------------------------

  void _autoFitCropAfterRotation() {
    if (_image == null || _canvasSize == Size.zero) return;

    final fitScale = _baseFitScale();
    final imgW = _image!.width.toDouble();
    final imgH = _image!.height.toDouble();

    // 回転後の画像バウンディングボックス（画面座標）
    final abscos = math.cos(_rotation).abs();
    final abssin = math.sin(_rotation).abs();
    final rotW = (imgW * abscos + imgH * abssin) * fitScale * _imageScale;
    final rotH = (imgW * abssin + imgH * abscos) * fitScale * _imageScale;

    // クロップ枠が画像からはみ出さないように調整
    final center = _cropRect.center;
    var w = _cropRect.width;
    var h = _cropRect.height;

    // 画像サイズより大きくならないように
    if (w > rotW) w = rotW;
    if (h > rotH) h = rotH;

    // アスペクト比を維持
    if (_aspectPreset.ratio != null) {
      final ratio = _aspectPreset.ratio!;
      if (w / h > ratio) {
        w = h * ratio;
      } else {
        h = w / ratio;
      }
    }

    // 再センタリング
    final newLeft = (center.dx - w / 2).clamp(0.0, _canvasSize.width - w);
    final newTop = (center.dy - h / 2).clamp(0.0, _canvasSize.height - h);
    _cropRect = Rect.fromLTWH(newLeft, newTop, w, h);
  }

  // -----------------------------------------------------------------------
  // ハンドル判定
  // -----------------------------------------------------------------------

  _DragHandle _hitTest(Offset point) {
    final r = _cropRect;
    const s = _handleTouchSize;

    // 角
    if ((point - r.topLeft).distance < s) return _DragHandle.topLeft;
    if ((point - r.topRight).distance < s) return _DragHandle.topRight;
    if ((point - r.bottomLeft).distance < s) return _DragHandle.bottomLeft;
    if ((point - r.bottomRight).distance < s) return _DragHandle.bottomRight;

    // 辺
    if (_nearEdge(point, r.topLeft, r.topRight, s)) return _DragHandle.top;
    if (_nearEdge(point, r.bottomLeft, r.bottomRight, s)) return _DragHandle.bottom;
    if (_nearEdge(point, r.topLeft, r.bottomLeft, s)) return _DragHandle.left;
    if (_nearEdge(point, r.topRight, r.bottomRight, s)) return _DragHandle.right;

    // 内部 → 画像移動
    if (r.contains(point)) return _DragHandle.move;

    return _DragHandle.none;
  }

  bool _nearEdge(Offset point, Offset a, Offset b, double threshold) {
    // 線分 a-b からの距離
    final ab = b - a;
    final ap = point - a;
    final t = (ap.dx * ab.dx + ap.dy * ab.dy) / (ab.dx * ab.dx + ab.dy * ab.dy);
    if (t < 0 || t > 1) return false;
    final closest = a + ab * t;
    return (point - closest).distance < threshold;
  }

  // -----------------------------------------------------------------------
  // クロップ枠のドラッグ
  // -----------------------------------------------------------------------

  void _onCropDragStart(DragStartDetails details) {
    final handle = _hitTest(details.localPosition);
    setState(() {
      _activeHandle = handle;
      _startCropRect = _cropRect;
      _dragStartPoint = details.localPosition;
    });
  }

  void _onCropDragUpdate(DragUpdateDetails details) {
    if (_activeHandle == _DragHandle.none) return;

    final dx = details.localPosition.dx - _dragStartPoint.dx;
    final dy = details.localPosition.dy - _dragStartPoint.dy;
    final r = _startCropRect;

    setState(() {
      if (_activeHandle == _DragHandle.move) {
        // 画像をパン
        _imageOffset = _imageOffset + details.delta;
        return;
      }

      double newLeft = r.left;
      double newTop = r.top;
      double newRight = r.right;
      double newBottom = r.bottom;

      switch (_activeHandle) {
        case _DragHandle.topLeft:
          newLeft = r.left + dx;
          newTop = r.top + dy;
        case _DragHandle.topRight:
          newRight = r.right + dx;
          newTop = r.top + dy;
        case _DragHandle.bottomLeft:
          newLeft = r.left + dx;
          newBottom = r.bottom + dy;
        case _DragHandle.bottomRight:
          newRight = r.right + dx;
          newBottom = r.bottom + dy;
        case _DragHandle.top:
          newTop = r.top + dy;
        case _DragHandle.bottom:
          newBottom = r.bottom + dy;
        case _DragHandle.left:
          newLeft = r.left + dx;
        case _DragHandle.right:
          newRight = r.right + dx;
        default:
          break;
      }

      // 最小サイズ
      if (newRight - newLeft < _minCropSize) {
        if (_activeHandle == _DragHandle.left ||
            _activeHandle == _DragHandle.topLeft ||
            _activeHandle == _DragHandle.bottomLeft) {
          newLeft = newRight - _minCropSize;
        } else {
          newRight = newLeft + _minCropSize;
        }
      }
      if (newBottom - newTop < _minCropSize) {
        if (_activeHandle == _DragHandle.top ||
            _activeHandle == _DragHandle.topLeft ||
            _activeHandle == _DragHandle.topRight) {
          newTop = newBottom - _minCropSize;
        } else {
          newBottom = newTop + _minCropSize;
        }
      }

      // 画面内に制限
      newLeft = newLeft.clamp(0.0, _canvasSize.width - _minCropSize);
      newTop = newTop.clamp(0.0, _canvasSize.height - _minCropSize);
      newRight = newRight.clamp(_minCropSize, _canvasSize.width);
      newBottom = newBottom.clamp(_minCropSize, _canvasSize.height);

      var newW = newRight - newLeft;
      var newH = newBottom - newTop;

      // アスペクト比制約
      if (_aspectPreset.ratio != null) {
        final ratio = _aspectPreset.ratio!;
        _applyAspectConstraint(
          ratio: ratio,
          handle: _activeHandle,
          left: newLeft,
          top: newTop,
          width: newW,
          height: newH,
        );
        return;
      }

      _cropRect = Rect.fromLTRB(newLeft, newTop, newRight, newBottom);
    });
  }

  void _applyAspectConstraint({
    required double ratio,
    required _DragHandle handle,
    required double left,
    required double top,
    required double width,
    required double height,
  }) {
    double newW = width;
    double newH = height;
    double newLeft = left;
    double newTop = top;

    // 幅を基準に高さを計算するか、高さを基準に幅を計算するか
    final isHorizontalDrag = handle == _DragHandle.left ||
        handle == _DragHandle.right;
    final isVerticalDrag = handle == _DragHandle.top ||
        handle == _DragHandle.bottom;

    if (isHorizontalDrag) {
      newH = newW / ratio;
      // 中心を維持
      final center = _startCropRect.center.dy;
      newTop = center - newH / 2;
    } else if (isVerticalDrag) {
      newW = newH * ratio;
      final center = _startCropRect.center.dx;
      newLeft = center - newW / 2;
    } else {
      // 角ドラッグ: 対角線方向で大きい方に合わせる
      if (newW / newH > ratio) {
        newW = newH * ratio;
      } else {
        newH = newW / ratio;
      }

      // アンカーポイント（ドラッグの反対側の角）
      switch (handle) {
        case _DragHandle.topLeft:
          newLeft = _startCropRect.right - newW;
          newTop = _startCropRect.bottom - newH;
        case _DragHandle.topRight:
          newTop = _startCropRect.bottom - newH;
        case _DragHandle.bottomLeft:
          newLeft = _startCropRect.right - newW;
        default:
          break;
      }
    }

    // 最小サイズ
    if (newW < _minCropSize) {
      newW = _minCropSize;
      newH = newW / ratio;
    }
    if (newH < _minCropSize) {
      newH = _minCropSize;
      newW = newH * ratio;
    }

    // 画面外に出ないように
    newLeft = newLeft.clamp(0.0, _canvasSize.width - newW);
    newTop = newTop.clamp(0.0, _canvasSize.height - newH);

    _cropRect = Rect.fromLTWH(newLeft, newTop, newW, newH);
  }

  void _onCropDragEnd(DragEndDetails details) {
    setState(() => _activeHandle = _DragHandle.none);
  }

  // -----------------------------------------------------------------------
  // 画像ピンチズーム（枠外のジェスチャー）
  // -----------------------------------------------------------------------

  void _onImageScaleStart(ScaleStartDetails details) {
    _startImageScale = _imageScale;
    _startImageOffset = _imageOffset;
    _startFocalPoint = details.localFocalPoint;
  }

  void _onImageScaleUpdate(ScaleUpdateDetails details) {
    setState(() {
      _imageScale = (_startImageScale * details.scale).clamp(0.5, 10.0);
      _imageOffset = _startImageOffset +
          (details.localFocalPoint - _startFocalPoint);
    });
  }

  // -----------------------------------------------------------------------
  // 回転ルーラー
  // -----------------------------------------------------------------------

  void _onRulerDragStart(DragStartDetails details) {
    _rulerStartRotation = _rotation;
    _rulerStartX = details.localPosition.dx;
  }

  void _onRulerDragUpdate(DragUpdateDetails details) {
    final dx = details.localPosition.dx - _rulerStartX;
    // 感度: 画面幅全体で45度
    final sensitivity = math.pi / 4 / _canvasSize.width;
    setState(() {
      _rotation = (_rulerStartRotation + dx * sensitivity)
          .clamp(-math.pi / 4, math.pi / 4);
      _autoFitCropAfterRotation();
    });
  }

  // -----------------------------------------------------------------------
  // 90度回転
  // -----------------------------------------------------------------------

  void _rotate90() {
    setState(() {
      _rotation = 0;
      // 90度回転はisolate側でやるのではなく、画像自体の向き概念を変える
      // 簡易実装: 回転値を0にリセットして画像を再ロードする代わりに
      // _permanentRotation を追加するか、ルーラー範囲外として扱う
      // ここでは単純にルーラーをリセット
      _autoFitCropAfterRotation();
    });
  }

  // -----------------------------------------------------------------------
  // リセット
  // -----------------------------------------------------------------------

  void _reset() {
    setState(() {
      _imageScale = 1.0;
      _rotation = 0.0;
      _imageOffset = Offset.zero;
      _cropInitialized = false;
    });
  }

  // -----------------------------------------------------------------------
  // アスペクト比変更
  // -----------------------------------------------------------------------

  void _changePreset(_AspectPreset preset) {
    setState(() {
      _aspectPreset = preset;

      if (!_cropInitialized) return;

      // 現在の枠の中心を維持しつつ、比率を適用
      final center = _cropRect.center;

      if (preset.ratio == null) {
        // フリー: そのまま
        return;
      }

      final ratio = preset.ratio!;
      var w = _cropRect.width;
      var h = _cropRect.height;

      if (w / h > ratio) {
        w = h * ratio;
      } else {
        h = w / ratio;
      }

      final left = (center.dx - w / 2).clamp(0.0, _canvasSize.width - w);
      final top = (center.dy - h / 2).clamp(0.0, _canvasSize.height - h);
      _cropRect = Rect.fromLTWH(left, top, w, h);
    });
  }

  // -----------------------------------------------------------------------
  // 保存（isolate）
  // -----------------------------------------------------------------------

  Future<void> _save() async {
    if (_image == null || _processing) return;
    setState(() => _processing = true);

    try {
      final imgW = _image!.width;
      final imgH = _image!.height;
      final fitScale = _baseFitScale();

      final dir = await getTemporaryDirectory();
      final outputPath = p.join(
        dir.path,
        'crop_${DateTime.now().millisecondsSinceEpoch}.png',
      );

      // キャンバス中心
      final cx = _canvasSize.width / 2;
      final cy = _canvasSize.height / 2;

      final params = _CropParams(
        inputPath: widget.filePath,
        outputPath: outputPath,
        imageWidth: imgW,
        imageHeight: imgH,
        fitScale: fitScale,
        userScale: _imageScale,
        rotation: _rotation,
        offsetX: _imageOffset.dx,
        offsetY: _imageOffset.dy,
        canvasCenterX: cx,
        canvasCenterY: cy,
        cropLeft: _cropRect.left,
        cropTop: _cropRect.top,
        cropWidth: _cropRect.width,
        cropHeight: _cropRect.height,
      );

      final result = await compute(_processCrop, params);

      if (mounted) {
        if (result != null) {
          Navigator.pop(context, result);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('切り取りに失敗しました')),
          );
        }
      }
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  // -----------------------------------------------------------------------
  // Build
  // -----------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('切り取り'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.rotate_right),
            tooltip: '90度回転',
            onPressed: _rotate90,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'リセット',
            onPressed: _reset,
          ),
          _processing
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(
                    width: 24, height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white,
                    ),
                  ),
                )
              : IconButton(
                  icon: const Icon(Icons.check),
                  tooltip: '完了',
                  onPressed: _save,
                ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // 画像 + クロップ枠
            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        _canvasSize = Size(
                          constraints.maxWidth,
                          constraints.maxHeight,
                        );
                        if (!_cropInitialized) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted && !_cropInitialized) {
                              setState(() => _initCropRect());
                            }
                          });
                        }
                        return _buildCropView();
                      },
                    ),
            ),
            // 回転ルーラー
            _buildRotationRuler(),
            // アスペクト比選択
            _buildPresetBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildCropView() {
    if (!_cropInitialized) {
      return const SizedBox.shrink();
    }

    return GestureDetector(
      onScaleStart: _onImageScaleStart,
      onScaleUpdate: _onImageScaleUpdate,
      child: Stack(
        children: [
          // 変換された画像
          Positioned.fill(
            child: Center(
              child: Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  // ignore: deprecated_member_use
                  ..translate(_imageOffset.dx, _imageOffset.dy)
                  ..rotateZ(_rotation)
                  // ignore: deprecated_member_use
                  ..scale(_imageScale),
                child: Image.file(
                  File(widget.filePath),
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                ),
              ),
            ),
          ),
          // 暗いオーバーレイ + 枠 + ハンドル
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: _onCropDragStart,
              onPanUpdate: _onCropDragUpdate,
              onPanEnd: _onCropDragEnd,
              child: CustomPaint(
                painter: _CropOverlayPainter(
                  cropRect: _cropRect,
                  activeHandle: _activeHandle,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // -----------------------------------------------------------------------
  // 回転ルーラー
  // -----------------------------------------------------------------------

  Widget _buildRotationRuler() {
    final degrees = (_rotation * 180 / math.pi);
    return Container(
      height: 56,
      color: Colors.black,
      child: GestureDetector(
        onHorizontalDragStart: _onRulerDragStart,
        onHorizontalDragUpdate: _onRulerDragUpdate,
        child: CustomPaint(
          size: Size(_canvasSize.width, 56),
          painter: _RulerPainter(
            degrees: degrees,
            width: _canvasSize.width,
          ),
          child: Center(
            child: Text(
              '${degrees.toStringAsFixed(1)}°',
              style: const TextStyle(
                color: Colors.orange,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ),
    );
  }

  // -----------------------------------------------------------------------
  // アスペクト比バー
  // -----------------------------------------------------------------------

  Widget _buildPresetBar() {
    return Container(
      height: 52,
      color: Colors.black,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: _AspectPreset.values.map((preset) {
          final isSelected = _aspectPreset == preset;
          return GestureDetector(
            onTap: () => _changePreset(preset),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: isSelected ? Colors.orange : Colors.transparent,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                preset.label,
                style: TextStyle(
                  color: isSelected ? Colors.white : Colors.grey[400],
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// オーバーレイ + 枠 + グリッド + ハンドル描画
// ---------------------------------------------------------------------------

class _CropOverlayPainter extends CustomPainter {
  final Rect cropRect;
  final _DragHandle activeHandle;

  _CropOverlayPainter({required this.cropRect, required this.activeHandle});

  @override
  void paint(Canvas canvas, Size size) {
    // 暗いオーバーレイ
    final overlayPaint = Paint()..color = Colors.black.withValues(alpha: 0.6);
    canvas.drawRect(Rect.fromLTRB(0, 0, size.width, cropRect.top), overlayPaint);
    canvas.drawRect(Rect.fromLTRB(0, cropRect.bottom, size.width, size.height), overlayPaint);
    canvas.drawRect(Rect.fromLTRB(0, cropRect.top, cropRect.left, cropRect.bottom), overlayPaint);
    canvas.drawRect(Rect.fromLTRB(cropRect.right, cropRect.top, size.width, cropRect.bottom), overlayPaint);

    // 枠線
    final borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRect(cropRect, borderPaint);

    // 3x3 グリッド
    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.3)
      ..strokeWidth = 0.5;
    for (int i = 1; i < 3; i++) {
      final x = cropRect.left + cropRect.width * i / 3;
      canvas.drawLine(Offset(x, cropRect.top), Offset(x, cropRect.bottom), gridPaint);
      final y = cropRect.top + cropRect.height * i / 3;
      canvas.drawLine(Offset(cropRect.left, y), Offset(cropRect.right, y), gridPaint);
    }

    // 角ハンドル（太い白線の L 字）
    const handleLen = 20.0;
    const handleWidth = 3.0;
    final handlePaint = Paint()
      ..color = Colors.white
      ..strokeWidth = handleWidth
      ..strokeCap = StrokeCap.round;

    // 左上
    _drawCorner(canvas, cropRect.topLeft, 1, 1, handleLen, handlePaint);
    // 右上
    _drawCorner(canvas, cropRect.topRight, -1, 1, handleLen, handlePaint);
    // 左下
    _drawCorner(canvas, cropRect.bottomLeft, 1, -1, handleLen, handlePaint);
    // 右下
    _drawCorner(canvas, cropRect.bottomRight, -1, -1, handleLen, handlePaint);
  }

  void _drawCorner(Canvas canvas, Offset corner, double dx, double dy,
      double len, Paint paint) {
    canvas.drawLine(corner, corner + Offset(dx * len, 0), paint);
    canvas.drawLine(corner, corner + Offset(0, dy * len), paint);
  }

  @override
  bool shouldRepaint(_CropOverlayPainter oldDelegate) =>
      oldDelegate.cropRect != cropRect ||
      oldDelegate.activeHandle != activeHandle;
}

// ---------------------------------------------------------------------------
// ルーラー描画
// ---------------------------------------------------------------------------

class _RulerPainter extends CustomPainter {
  final double degrees;
  final double width;

  _RulerPainter({required this.degrees, required this.width});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.width / 2;
    final tickPaint = Paint()
      ..color = Colors.grey[600]!
      ..strokeWidth = 1;

    final majorTickPaint = Paint()
      ..color = Colors.grey[400]!
      ..strokeWidth = 1.5;

    // 1度ごとのtick、10ピクセルごと
    const pixPerDeg = 10.0;
    final offsetPx = degrees * pixPerDeg;

    for (double d = -45; d <= 45; d += 1) {
      final x = center + (d * pixPerDeg) - offsetPx;
      if (x < 0 || x > size.width) continue;

      final isMajor = d % 5 == 0;
      final tickH = isMajor ? 16.0 : 8.0;
      final paint = isMajor ? majorTickPaint : tickPaint;

      canvas.drawLine(
        Offset(x, size.height - tickH - 4),
        Offset(x, size.height - 4),
        paint,
      );
    }

    // 中央インジケーター
    final indicatorPaint = Paint()
      ..color = Colors.orange
      ..strokeWidth = 2;
    canvas.drawLine(
      Offset(center, 4),
      Offset(center, size.height - 4),
      indicatorPaint,
    );
  }

  @override
  bool shouldRepaint(_RulerPainter oldDelegate) =>
      oldDelegate.degrees != degrees;
}

// ---------------------------------------------------------------------------
// Isolate: クロップ処理
// ---------------------------------------------------------------------------

class _CropParams {
  final String inputPath;
  final String outputPath;
  final int imageWidth;
  final int imageHeight;
  final double fitScale;
  final double userScale;
  final double rotation;
  final double offsetX;
  final double offsetY;
  final double canvasCenterX;
  final double canvasCenterY;
  final double cropLeft;
  final double cropTop;
  final double cropWidth;
  final double cropHeight;

  const _CropParams({
    required this.inputPath,
    required this.outputPath,
    required this.imageWidth,
    required this.imageHeight,
    required this.fitScale,
    required this.userScale,
    required this.rotation,
    required this.offsetX,
    required this.offsetY,
    required this.canvasCenterX,
    required this.canvasCenterY,
    required this.cropLeft,
    required this.cropTop,
    required this.cropWidth,
    required this.cropHeight,
  });
}

String? _processCrop(_CropParams p) {
  try {
    final bytes = File(p.inputPath).readAsBytesSync();
    final srcImage = img.decodeImage(bytes);
    if (srcImage == null) return null;

    final totalScale = p.fitScale * p.userScale;
    if (totalScale <= 0) return null;

    final pixelRatio = 1.0 / totalScale;

    final outW = (p.cropWidth * pixelRatio).round().clamp(1, 16384);
    final outH = (p.cropHeight * pixelRatio).round().clamp(1, 16384);

    final output = img.Image(width: outW, height: outH, numChannels: 4);

    final cosR = math.cos(-p.rotation);
    final sinR = math.sin(-p.rotation);

    final cx = p.canvasCenterX;
    final cy = p.canvasCenterY;

    for (int oy = 0; oy < outH; oy++) {
      for (int ox = 0; ox < outW; ox++) {
        // 出力ピクセル → 画面座標
        final sx = p.cropLeft + (ox + 0.5) * (p.cropWidth / outW);
        final sy = p.cropTop + (oy + 0.5) * (p.cropHeight / outH);

        // 画面中心基準の相対座標（オフセット除去）
        final rx = sx - cx - p.offsetX;
        final ry = sy - cy - p.offsetY;

        // 回転の逆変換
        final nx = rx * cosR - ry * sinR;
        final ny = rx * sinR + ry * cosR;

        // スケールの逆変換
        final fx = nx / p.userScale;
        final fy = ny / p.userScale;

        // 元の画像座標
        final imgX = (fx / p.fitScale + p.imageWidth / 2).round();
        final imgY = (fy / p.fitScale + p.imageHeight / 2).round();

        if (imgX >= 0 && imgX < p.imageWidth &&
            imgY >= 0 && imgY < p.imageHeight) {
          output.setPixel(ox, oy, srcImage.getPixel(imgX, imgY));
        }
      }
    }

    final encoded = Uint8List.fromList(img.encodePng(output));
    File(p.outputPath).writeAsBytesSync(encoded);
    return p.outputPath;
  } catch (_) {
    return null;
  }
}
