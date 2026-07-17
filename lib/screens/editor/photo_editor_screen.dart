import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';
import 'photo_edit_core.dart';

/// 統合フォトエディタ（切り抜き / フィルター / 調整）。
///
/// - 座標系は常に「EXIF正規化後の元画像ピクセル寸法」基準で、
///   変換は [PhotoEditGeometry] に委譲する（プレビュー縮小率は表示にのみ影響）
/// - 焼き込みは行わず、[PhotoEditOutcome] を Navigator.pop で返すだけ
/// - 操作モデルはGoogleフォト型:
///   枠ハンドルはリサイズのみ・画像はパン/焦点基準ズーム・離すと枠が再フィット

// ---------------------------------------------------------------------------
// 定数
// ---------------------------------------------------------------------------

/// プレビュー用デコードの長辺上限
const int _kPreviewMaxDimension = 2048;

/// クロップ枠の最小辺長
const double _kFrameMinSize = 64;

/// 角ハンドルのヒット半径（角優先）
const double _kCornerHitRadius = 28;

/// 辺ハンドルのヒット幅
const double _kEdgeHitRadius = 24;

/// クロップ枠が動けるビューポート内の余白
const EdgeInsets _kViewportPadding = EdgeInsets.all(16);

/// 枠再フィット等のアニメーション時間
const Duration _kSettleDuration = Duration(milliseconds: 250);

/// 90度回転アニメーションの時間
const Duration _kRotate90Duration = Duration(milliseconds: 300);

/// グリッドのフェード時間
const Duration _kGridFadeDuration = Duration(milliseconds: 200);

/// タブ切替のフェード時間
const Duration _kTabSwitchDuration = Duration(milliseconds: 200);

/// ルーラーの1度あたりピクセル数
const double _kRulerPixelsPerDegree = 10;

/// 自由回転の範囲（±度）
const double _kRulerMaxDegrees = 45;

/// 離したとき0度へスナップする範囲（±度）
const double _kRotationSnapDegrees = 2;

/// ピンチズームの上限（cover下限の倍数。ただし等倍までは常に許可）
const double _kMaxZoomOverCover = 8;

/// 下部タブコンテンツの高さ
const double _kBottomContentHeight = 180;

// ---------------------------------------------------------------------------
// 列挙・小さな状態クラス
// ---------------------------------------------------------------------------

enum _EditorTab {
  crop('切り抜き', Icons.crop),
  filter('フィルター', Icons.auto_awesome_outlined),
  adjust('調整', Icons.tune);

  const _EditorTab(this.label, this.icon);

  final String label;
  final IconData icon;
}

enum _AspectPreset {
  free('フリー', null),
  square('1:1', 1),
  fourThree('4:3', 4 / 3),
  threeTwo('3:2', 3 / 2),
  sixteenNine('16:9', 16 / 9);

  const _AspectPreset(this.label, this.ratio);

  final String label;

  /// null = 自由比率
  final double? ratio;
}

enum _FrameHandle {
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
  top,
  bottom,
  left,
  right;

  bool get isCorner => index < 4;
}

enum _MenuAction { restoreOriginal }

/// 画像の表示変換。view = viewportCenter + offset + scale · R(θ) · (src − srcCenter)
class _ViewTransform {
  double scale;
  Offset offset;
  double rotationDeg;

  _ViewTransform({
    required this.scale,
    required this.offset,
    required this.rotationDeg,
  });
}

/// アニメーション補間用のスナップショット（枠 + 表示変換）
class _EditorSnapshot {
  final Rect frame;
  final double scale;
  final Offset offset;
  final double rotationDeg;

  const _EditorSnapshot({
    required this.frame,
    required this.scale,
    required this.offset,
    required this.rotationDeg,
  });

  static _EditorSnapshot lerp(_EditorSnapshot a, _EditorSnapshot b, double t) {
    return _EditorSnapshot(
      frame: Rect.lerp(a.frame, b.frame, t)!,
      scale: ui.lerpDouble(a.scale, b.scale, t)!,
      offset: Offset.lerp(a.offset, b.offset, t)!,
      rotationDeg: ui.lerpDouble(a.rotationDeg, b.rotationDeg, t)!,
    );
  }
}

/// キャンバス上のジェスチャ1回分の状態
class _GestureSession {
  /// null = パン/ズーム、非null = ハンドルドラッグ
  final _FrameHandle? handle;

  /// 2本→1本指切替のrebaseline用
  int pointerCount;

  /// 前回updateのdetails.scale（増分ズーム計算用）
  double lastGestureScale = 1.0;

  /// ハンドルドラッグの基準枠
  final Rect startFrame;

  /// カバレッジを満たしている直近の枠
  Rect lastValidFrame;

  _GestureSession({
    required this.handle,
    required this.pointerCount,
    required this.startFrame,
  }) : lastValidFrame = startFrame;
}

/// ルーラードラッグ1回分の状態
class _RulerSession {
  final double startRotationDeg;
  final double startFineDeg;
  final double startScale;

  /// 枠中心に固定する元画像上の点
  final Offset srcAnchor;

  double accumDx = 0;

  _RulerSession({
    required this.startRotationDeg,
    required this.startFineDeg,
    required this.startScale,
    required this.srcAnchor,
  });
}

// ---------------------------------------------------------------------------
// PhotoEditorScreen
// ---------------------------------------------------------------------------

/// 統合フォトエディタ画面。
///
/// [imagePath] の画像（EXIF正規化後基準）に対する編集パラメータを作り、
/// Navigator.pop で [PhotoEditOutcome] を返す（キャンセル時は null）。
/// 焼き込みは呼び出し側が [bakePhotoEdit] で行う。
class PhotoEditorScreen extends StatefulWidget {
  final String imagePath;
  final PhotoEditParams? initialParams;
  final bool canRestoreOriginal;

  const PhotoEditorScreen({
    super.key,
    required this.imagePath,
    this.initialParams,
    this.canRestoreOriginal = false,
  });

  @override
  State<PhotoEditorScreen> createState() => _PhotoEditorScreenState();
}

class _PhotoEditorScreenState extends State<PhotoEditorScreen>
    with TickerProviderStateMixin {
  // ---- 画像 ----
  ui.Image? _preview;
  int _srcW = 0;
  int _srcH = 0;
  bool _loadFailed = false;

  // ---- 表示状態 ----
  bool _initialized = false;
  Size _viewportSize = Size.zero;
  late _ViewTransform _transform;
  late Rect _frame;
  _AspectPreset _aspect = _AspectPreset.free;

  // ---- フィルター ----
  PhotoEditFilter _filter = kFilterPresets.first;

  // ---- UI状態 ----
  _EditorTab _tab = _EditorTab.crop;
  _GestureSession? _gesture;
  _RulerSession? _ruler;

  /// 変更検知の基準（初期化直後の表示状態から作る）
  PhotoEditParams? _baseline;

  // ---- アニメーション ----
  late final AnimationController _gridController = AnimationController(
    vsync: this,
    duration: _kGridFadeDuration,
  )..addListener(() => setState(() {}));

  late final AnimationController _settleController = AnimationController(
    vsync: this,
    duration: _kSettleDuration,
  )..addListener(_onSettleTick);

  _EditorSnapshot? _settleFrom;
  _EditorSnapshot? _settleTo;
  bool _settleClampDuring = false;

  Size get _srcSize => Size(_srcW.toDouble(), _srcH.toDouble());

  Rect get _frameBounds => _kViewportPadding.deflateRect(
        Rect.fromLTWH(0, 0, _viewportSize.width, _viewportSize.height),
      );

  /// 直近の90度単位からの相対角（-45〜45）
  double get _fineAngle {
    final norm = _normalizeDeg(_transform.rotationDeg);
    return norm - (norm / 90).round() * 90;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _gridController.dispose();
    _settleController.dispose();
    _preview?.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // 画像読み込み（プレビューは1回だけデコードして ui.Image で保持）
  // -------------------------------------------------------------------------

  Future<void> _load() async {
    try {
      final bytes = await File(widget.imagePath).readAsBytes();
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final encodedW = descriptor.width;
      final encodedH = descriptor.height;
      final ui.Codec codec;
      if (math.max(encodedW, encodedH) > _kPreviewMaxDimension) {
        codec = await descriptor.instantiateCodec(
          targetWidth: encodedW >= encodedH ? _kPreviewMaxDimension : null,
          targetHeight: encodedW >= encodedH ? null : _kPreviewMaxDimension,
        );
      } else {
        codec = await descriptor.instantiateCodec();
      }
      final frame = await codec.getNextFrame();
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
      final image = frame.image;

      // EXIF正規化後の元画像寸法を求める。デコード結果はEXIF適用済みなので、
      // アスペクト比がエンコード寸法と縦横逆なら90度系のEXIF回転が入っている。
      var srcW = encodedW;
      var srcH = encodedH;
      if (encodedW != encodedH) {
        final decodedAspect = image.width / image.height;
        final straight = (decodedAspect - encodedW / encodedH).abs();
        final swapped = (decodedAspect - encodedH / encodedW).abs();
        if (swapped < straight) {
          srcW = encodedH;
          srcH = encodedW;
        }
      }

      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() {
        _preview = image;
        _srcW = srcW;
        _srcH = srcH;
      });
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
    }
  }

  // -------------------------------------------------------------------------
  // 幾何ヘルパ（coreへの委譲 + 現在状態の束ね）
  // -------------------------------------------------------------------------

  static double _normalizeDeg(double deg) {
    var d = deg % 360;
    if (d > 180) d -= 360;
    if (d <= -180) d += 360;
    return d;
  }

  /// aspect（w/h）の矩形を bounds 内へ最大サイズ・中央でフィット
  static Rect _fitRect(double aspect, Rect bounds) {
    var w = bounds.width;
    var h = w / aspect;
    if (h > bounds.height) {
      h = bounds.height;
      w = h * aspect;
    }
    return Rect.fromCenter(center: bounds.center, width: w, height: h);
  }

  static Rect _clampCropToBounds(Rect crop, Size bounds) {
    final w = crop.width.clamp(1.0, bounds.width);
    final h = crop.height.clamp(1.0, bounds.height);
    return Rect.fromLTWH(
      crop.left.clamp(0.0, bounds.width - w),
      crop.top.clamp(0.0, bounds.height - h),
      w,
      h,
    );
  }

  Offset _viewToSource(Offset point) => PhotoEditGeometry.viewToSource(
        point: point,
        viewportSize: _viewportSize,
        srcSize: _srcSize,
        rotationDeg: _transform.rotationDeg,
        scale: _transform.scale,
        offset: _transform.offset,
      );

  /// 元画像上の点 [srcAnchor] がビュー上の [viewPoint] に来る offset を求める
  Offset _anchorOffset({
    required Offset srcAnchor,
    required Offset viewPoint,
    required double rotationDeg,
    required double scale,
  }) {
    final rad = rotationDeg * math.pi / 180;
    final c = math.cos(rad);
    final s = math.sin(rad);
    final vc = _viewportSize.center(Offset.zero);
    final px = srcAnchor.dx - _srcW / 2;
    final py = srcAnchor.dy - _srcH / 2;
    return Offset(
      viewPoint.dx - vc.dx - scale * (px * c - py * s),
      viewPoint.dy - vc.dy - scale * (px * s + py * c),
    );
  }

  double _minCoverScale({Rect? frame, double? rotationDeg}) =>
      PhotoEditGeometry.minCoverScale(
        frameRect: frame ?? _frame,
        srcSize: _srcSize,
        rotationDeg: rotationDeg ?? _transform.rotationDeg,
      );

  Offset _clampOffset(Offset offset, {Rect? frame, double? rotationDeg, double? scale}) =>
      PhotoEditGeometry.clampOffsetToCover(
        viewportSize: _viewportSize,
        frameRect: frame ?? _frame,
        srcSize: _srcSize,
        rotationDeg: rotationDeg ?? _transform.rotationDeg,
        scale: scale ?? _transform.scale,
        offset: offset,
      );

  /// scale下限とoffsetのcover制約を現在状態へ適用（ハードクランプ）
  void _applyCoverClamp() {
    final minScale = _minCoverScale();
    if (_transform.scale < minScale) _transform.scale = minScale;
    _transform.offset = _clampOffset(_transform.offset);
  }

  /// 現在の表示状態から cropRect（回転後バウンディングボックス座標）を得る
  Rect _currentCropRect() {
    final crop = PhotoEditGeometry.displayToCropRect(
      viewportSize: _viewportSize,
      frameRect: _frame,
      srcSize: _srcSize,
      rotationDeg: _transform.rotationDeg,
      scale: _transform.scale,
      offset: _transform.offset,
    );
    final bounds =
        PhotoEditGeometry.rotatedBoundsSize(_srcSize, _transform.rotationDeg);
    return _clampCropToBounds(crop, bounds);
  }

  PhotoEditParams _buildCurrentParams() {
    return PhotoEditParams(
      rotationDeg: _normalizeDeg(_transform.rotationDeg),
      cropRect: _currentCropRect(),
      srcW: _srcW,
      srcH: _srcH,
      filter: _filter,
    );
  }

  static bool _paramsAlmostEqual(PhotoEditParams a, PhotoEditParams b) {
    final rotDiff = _normalizeDeg(a.rotationDeg - b.rotationDeg).abs();
    return rotDiff < 0.05 &&
        (a.cropRect.left - b.cropRect.left).abs() < 0.5 &&
        (a.cropRect.top - b.cropRect.top).abs() < 0.5 &&
        (a.cropRect.width - b.cropRect.width).abs() < 0.5 &&
        (a.cropRect.height - b.cropRect.height).abs() < 0.5 &&
        a.srcW == b.srcW &&
        a.srcH == b.srcH &&
        _filterValuesAlmostEqual(a.filter, b.filter);
  }

  /// 変更検知用のフィルター比較。presetラベルは無視し、数値5項目のみを
  /// 許容誤差つきで比べる。（スライダーを動かして元の値へ戻すとpresetが
  /// 空文字になるため、operator== では見た目が同じでも変更ありと誤検知する）
  static bool _filterValuesAlmostEqual(PhotoEditFilter a, PhotoEditFilter b) {
    const eps = 0.01;
    return (a.brightness - b.brightness).abs() < eps &&
        (a.contrast - b.contrast).abs() < eps &&
        (a.saturation - b.saturation).abs() < eps &&
        (a.temperature - b.temperature).abs() < eps &&
        (a.vignette - b.vignette).abs() < eps;
  }

  bool _hasChanges() {
    final baseline = _baseline;
    if (!_initialized || baseline == null) return false;
    return !_paramsAlmostEqual(_buildCurrentParams(), baseline);
  }

  // -------------------------------------------------------------------------
  // 初期化・ビューポート追従（buildのLayoutBuilder内から同期的に呼ぶ）
  // -------------------------------------------------------------------------

  void _ensureInitialized(Size viewport) {
    if (_preview == null) return;
    if (_initialized && viewport == _viewportSize) return;

    final firstInit = !_initialized;
    Rect crop;
    double rotationDeg;
    if (!firstInit) {
      // ビューポートサイズ変更: 見えている内容を維持して再フィット
      crop = _currentCropRect();
      rotationDeg = _transform.rotationDeg;
      _stopSettle();
    } else {
      final p = _validatedInitialParams();
      if (p != null) {
        rotationDeg = p.rotationDeg;
        crop = p.cropRect;
      } else {
        rotationDeg = 0;
        crop = Rect.fromLTWH(0, 0, _srcW.toDouble(), _srcH.toDouble());
      }
    }

    _viewportSize = viewport;
    _frame = _fitRect(crop.width / crop.height, _frameBounds);
    final d = PhotoEditGeometry.cropRectToDisplay(
      viewportSize: viewport,
      frameRect: _frame,
      srcSize: _srcSize,
      rotationDeg: rotationDeg,
      cropRect: crop,
    );
    _transform = _ViewTransform(
      scale: d.scale,
      offset: d.offset,
      rotationDeg: rotationDeg,
    );
    _applyCoverClamp();

    if (firstInit) {
      _initialized = true;
      _aspect = _detectAspectPreset(crop);
      _filter = _validatedInitialParams()?.filter ?? kFilterPresets.first;
      // 復元roundtrip後の表示状態を変更検知の基準にする
      _baseline = _buildCurrentParams();
      // ここはレイアウトフェーズ中でsetStateできないため、初期化完了後の状態
      // （完了/リセットボタンの活性・下部クロップUI）を反映する再描画を
      // 次フレームで1度だけ予約する
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
  }

  /// initialParams を検証し、寸法不一致ならcropを比例スケールして返す
  PhotoEditParams? _validatedInitialParams() {
    final p = widget.initialParams;
    if (p == null) return null;
    var crop = p.cropRect;
    final bounds =
        PhotoEditGeometry.rotatedBoundsSize(_srcSize, p.rotationDeg);
    if (p.srcW != _srcW || p.srcH != _srcH) {
      final expected = PhotoEditGeometry.rotatedBoundsSize(
        Size(p.srcW.toDouble(), p.srcH.toDouble()),
        p.rotationDeg,
      );
      if (expected.width <= 0 || expected.height <= 0) return null;
      final sx = bounds.width / expected.width;
      final sy = bounds.height / expected.height;
      crop = Rect.fromLTWH(
          crop.left * sx, crop.top * sy, crop.width * sx, crop.height * sy);
    }
    if (crop.width < 1 || crop.height < 1) return null;
    return p.copyWith(cropRect: _clampCropToBounds(crop, bounds));
  }

  _AspectPreset _detectAspectPreset(Rect crop) {
    final aspect = crop.width / crop.height;
    for (final preset in _AspectPreset.values) {
      final ratio = preset.ratio;
      if (ratio != null && (aspect / ratio - 1).abs() < 0.01) return preset;
    }
    return _AspectPreset.free;
  }

  // -------------------------------------------------------------------------
  // 設定アニメーション（枠再フィット・回転スナップ・プリセット変形の共通機構）
  // -------------------------------------------------------------------------

  _EditorSnapshot _currentSnapshot() => _EditorSnapshot(
        frame: _frame,
        scale: _transform.scale,
        offset: _transform.offset,
        rotationDeg: _transform.rotationDeg,
      );

  void _animateTo(
    _EditorSnapshot target, {
    Duration duration = _kSettleDuration,
    bool clampDuring = false,
  }) {
    _settleFrom = _currentSnapshot();
    _settleTo = target;
    _settleClampDuring = clampDuring;
    _settleController.duration = duration;
    _settleController.forward(from: 0);
  }

  void _onSettleTick() {
    final from = _settleFrom;
    final to = _settleTo;
    if (from == null || to == null) return;
    final t = Curves.easeOut.transform(_settleController.value);
    final s = _EditorSnapshot.lerp(from, to, t);
    setState(() {
      _frame = s.frame;
      _transform
        ..scale = s.scale
        ..offset = s.offset
        ..rotationDeg = s.rotationDeg;
      // 中間フレームで枠内に空白が見えないよう保険のクランプ
      if (_settleClampDuring) _applyCoverClamp();
    });
  }

  void _stopSettle() {
    if (_settleController.isAnimating) _settleController.stop();
    _settleFrom = null;
    _settleTo = null;
  }

  /// 枠をviewportいっぱいへ再フィット（枠内に見えている内容は不変）
  void _settleFrameToViewport() {
    final target = _fitRect(_frame.width / _frame.height, _frameBounds);
    if ((target.left - _frame.left).abs() < 0.5 &&
        (target.top - _frame.top).abs() < 0.5 &&
        (target.width - _frame.width).abs() < 0.5) {
      return;
    }
    final crop = _currentCropRect();
    final d = PhotoEditGeometry.cropRectToDisplay(
      viewportSize: _viewportSize,
      frameRect: target,
      srcSize: _srcSize,
      rotationDeg: _transform.rotationDeg,
      cropRect: crop,
    );
    _animateTo(_EditorSnapshot(
      frame: target,
      scale: d.scale,
      offset: d.offset,
      rotationDeg: _transform.rotationDeg,
    ));
  }

  /// 枠はそのまま回転角だけ変える目標状態（枠中心の内容を維持し、cover再計算）
  _EditorSnapshot _rotationTarget(double targetRotationDeg, {Rect? frame}) {
    final targetFrame = frame ?? _frame;
    final srcAnchor = _viewToSource(_frame.center);
    final scale = math.max(
      _transform.scale,
      _minCoverScale(frame: targetFrame, rotationDeg: targetRotationDeg),
    );
    var offset = _anchorOffset(
      srcAnchor: srcAnchor,
      viewPoint: targetFrame.center,
      rotationDeg: targetRotationDeg,
      scale: scale,
    );
    offset = _clampOffset(offset,
        frame: targetFrame, rotationDeg: targetRotationDeg, scale: scale);
    return _EditorSnapshot(
      frame: targetFrame,
      scale: scale,
      offset: offset,
      rotationDeg: targetRotationDeg,
    );
  }

  // -------------------------------------------------------------------------
  // キャンバスのジェスチャ（切り抜きタブ）
  // -------------------------------------------------------------------------

  void _onScaleStart(ScaleStartDetails details) {
    if (!_initialized) return;
    _stopSettle();
    final handle = details.pointerCount == 1
        ? _hitTestHandle(details.localFocalPoint)
        : null;
    if (handle != null) HapticFeedback.selectionClick();
    _gesture = _GestureSession(
      handle: handle,
      pointerCount: details.pointerCount,
      startFrame: _frame,
    );
    _gridController.forward();
    setState(() {});
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final session = _gesture;
    if (session == null) return;
    // 指の本数が変わったらrebaseline（画像が飛ばない）
    if (details.pointerCount != session.pointerCount) {
      session.pointerCount = details.pointerCount;
      session.lastGestureScale = 1.0;
    }
    setState(() {
      if (session.handle != null) {
        _updateHandleDrag(session, details.localFocalPoint);
      } else {
        _updatePanZoom(session, details);
      }
    });
  }

  void _onScaleEnd(ScaleEndDetails details) {
    final session = _gesture;
    if (session == null) return;
    _gesture = null;
    _gridController.reverse();
    if (session.handle != null) {
      // 指を離すと枠をviewportいっぱいへアニメーション再フィット
      _settleFrameToViewport();
    }
    setState(() {});
  }

  /// タブ切替などでジェスチャUI（GestureDetector）が破棄される直前に、
  /// 進行中の操作を後始末する。onScaleEnd/onHorizontalDragEnd が発火しない
  /// ケースで _gesture/_ruler やグリッド、枠の再フィットが取り残されるのを防ぐ。
  void _cancelActiveInteraction() {
    final gesture = _gesture;
    final ruler = _ruler;
    if (gesture == null && ruler == null) return;
    _gesture = null;
    _ruler = null;
    _gridController.reverse();
    // ハンドルリサイズ中だった場合は枠をviewportいっぱいへ再フィット
    if (gesture?.handle != null) {
      _settleFrameToViewport();
    }
  }

  /// 1本指ドラッグ=パン、2本指ピンチ=焦点基準ズーム（twist回転はしない）
  void _updatePanZoom(_GestureSession session, ScaleUpdateDetails details) {
    final t = _transform;
    final ratioRaw = session.lastGestureScale <= 0
        ? 1.0
        : details.scale / session.lastGestureScale;
    session.lastGestureScale = details.scale;

    if (ratioRaw != 1.0) {
      final minScale = _minCoverScale();
      final maxScale = math.max(minScale * _kMaxZoomOverCover, 1.0);
      final newScale = (t.scale * ratioRaw).clamp(minScale, maxScale);
      final ratio = newScale / t.scale;
      if (ratio != 1.0) {
        // 焦点直下の画像点を固定: offset' = (1−r)(focal−vc) + r·offset
        final vc = _viewportSize.center(Offset.zero);
        final f = details.localFocalPoint;
        t.offset = Offset(
          (1 - ratio) * (f.dx - vc.dx) + ratio * t.offset.dx,
          (1 - ratio) * (f.dy - vc.dy) + ratio * t.offset.dy,
        );
        t.scale = newScale;
      }
    }
    t.offset += details.focalPointDelta;
    t.offset = _clampOffset(t.offset);
  }

  void _updateHandleDrag(_GestureSession session, Offset pointer) {
    final desired = _resizeFrameTo(
      start: session.startFrame,
      handle: session.handle!,
      pointer: pointer,
      aspect: _aspect.ratio,
    );
    final valid = _maxCoveredFrame(session.lastValidFrame, desired);
    session.lastValidFrame = valid;
    _frame = valid;
  }

  /// 角優先ヒットテスト（枠が小さいときは角が辺・パンに奪われない）
  _FrameHandle? _hitTestHandle(Offset p) {
    const corners = [
      _FrameHandle.topLeft,
      _FrameHandle.topRight,
      _FrameHandle.bottomLeft,
      _FrameHandle.bottomRight,
    ];
    _FrameHandle? best;
    var bestDist = _kCornerHitRadius;
    for (final handle in corners) {
      final d = (p - _handlePosition(handle)).distance;
      if (d <= bestDist) {
        bestDist = d;
        best = handle;
      }
    }
    if (best != null) return best;

    // 辺: 角のヒット領域を除いた帯で判定
    final f = _frame;
    bool inSpanX(double y) =>
        (p.dy - y).abs() <= _kEdgeHitRadius &&
        p.dx >= f.left + _kCornerHitRadius &&
        p.dx <= f.right - _kCornerHitRadius;
    bool inSpanY(double x) =>
        (p.dx - x).abs() <= _kEdgeHitRadius &&
        p.dy >= f.top + _kCornerHitRadius &&
        p.dy <= f.bottom - _kCornerHitRadius;
    if (inSpanX(f.top)) return _FrameHandle.top;
    if (inSpanX(f.bottom)) return _FrameHandle.bottom;
    if (inSpanY(f.left)) return _FrameHandle.left;
    if (inSpanY(f.right)) return _FrameHandle.right;
    return null;
  }

  Offset _handlePosition(_FrameHandle handle) {
    final f = _frame;
    return switch (handle) {
      _FrameHandle.topLeft => f.topLeft,
      _FrameHandle.topRight => f.topRight,
      _FrameHandle.bottomLeft => f.bottomLeft,
      _FrameHandle.bottomRight => f.bottomRight,
      _FrameHandle.top => f.topCenter,
      _FrameHandle.bottom => f.bottomCenter,
      _FrameHandle.left => f.centerLeft,
      _FrameHandle.right => f.centerRight,
    };
  }

  /// ハンドルドラッグによる枠リサイズ（最小サイズ・viewport境界・アスペクト固定）
  Rect _resizeFrameTo({
    required Rect start,
    required _FrameHandle handle,
    required Offset pointer,
    required double? aspect,
  }) {
    final b = _frameBounds;
    final p = Offset(
      pointer.dx.clamp(b.left, b.right),
      pointer.dy.clamp(b.top, b.bottom),
    );
    const minSize = _kFrameMinSize;

    if (aspect == null) {
      var left = start.left;
      var top = start.top;
      var right = start.right;
      var bottom = start.bottom;
      switch (handle) {
        case _FrameHandle.topLeft:
          left = math.min(p.dx, right - minSize);
          top = math.min(p.dy, bottom - minSize);
        case _FrameHandle.topRight:
          right = math.max(p.dx, left + minSize);
          top = math.min(p.dy, bottom - minSize);
        case _FrameHandle.bottomLeft:
          left = math.min(p.dx, right - minSize);
          bottom = math.max(p.dy, top + minSize);
        case _FrameHandle.bottomRight:
          right = math.max(p.dx, left + minSize);
          bottom = math.max(p.dy, top + minSize);
        case _FrameHandle.top:
          top = math.min(p.dy, bottom - minSize);
        case _FrameHandle.bottom:
          bottom = math.max(p.dy, top + minSize);
        case _FrameHandle.left:
          left = math.min(p.dx, right - minSize);
        case _FrameHandle.right:
          right = math.max(p.dx, left + minSize);
      }
      return Rect.fromLTRB(left, top, right, bottom);
    }

    // アスペクト固定
    final a = aspect;
    if (handle.isCorner) {
      final (anchor, sx, sy) = switch (handle) {
        _FrameHandle.topLeft => (start.bottomRight, -1.0, -1.0),
        _FrameHandle.topRight => (start.bottomLeft, 1.0, -1.0),
        _FrameHandle.bottomLeft => (start.topRight, -1.0, 1.0),
        _ => (start.topLeft, 1.0, 1.0),
      };
      final maxW = math.min(
        sx > 0 ? b.right - anchor.dx : anchor.dx - b.left,
        (sy > 0 ? b.bottom - anchor.dy : anchor.dy - b.top) * a,
      );
      final minW = math.min(minSize * math.max(1, a), maxW);
      final w = math
          .max((p.dx - anchor.dx) * sx, (p.dy - anchor.dy) * sy * a)
          .clamp(minW, maxW);
      final h = w / a;
      return Rect.fromLTWH(
        sx > 0 ? anchor.dx : anchor.dx - w,
        sy > 0 ? anchor.dy : anchor.dy - h,
        w,
        h,
      );
    }

    if (handle == _FrameHandle.left || handle == _FrameHandle.right) {
      final sx = handle == _FrameHandle.right ? 1.0 : -1.0;
      final anchorX = sx > 0 ? start.left : start.right;
      final cy = start.center.dy;
      final maxH = 2 * math.min(cy - b.top, b.bottom - cy);
      final maxW = math.min(
          sx > 0 ? b.right - anchorX : anchorX - b.left, maxH * a);
      final minW = math.min(minSize * math.max(1, a), maxW);
      final w = ((p.dx - anchorX) * sx).clamp(minW, maxW);
      final h = w / a;
      return Rect.fromLTWH(sx > 0 ? anchorX : anchorX - w, cy - h / 2, w, h);
    }

    final sy = handle == _FrameHandle.bottom ? 1.0 : -1.0;
    final anchorY = sy > 0 ? start.top : start.bottom;
    final cx = start.center.dx;
    final maxWc = 2 * math.min(cx - b.left, b.right - cx);
    final maxH = math.min(
        sy > 0 ? b.bottom - anchorY : anchorY - b.top, maxWc / a);
    final minH = math.min(minSize * math.max(1, 1 / a), maxH);
    final h = ((p.dy - anchorY) * sy).clamp(minH, maxH);
    final w = h * a;
    return Rect.fromLTWH(cx - w / 2, sy > 0 ? anchorY : anchorY - h, w, h);
  }

  /// 枠が画像の実体に完全に覆われているか（4隅を元画像座標で判定）
  bool _frameCoveredByImage(Rect frame) {
    const eps = 1.0; // 元画像ピクセル換算の許容誤差
    for (final corner in [
      frame.topLeft,
      frame.topRight,
      frame.bottomLeft,
      frame.bottomRight,
    ]) {
      final s = _viewToSource(corner);
      if (s.dx < -eps ||
          s.dy < -eps ||
          s.dx > _srcW + eps ||
          s.dy > _srcH + eps) {
        return false;
      }
    }
    return true;
  }

  /// from（有効）→ to の間でカバレッジを満たす最大の枠を二分探索で求める
  Rect _maxCoveredFrame(Rect from, Rect to) {
    if (_frameCoveredByImage(to)) return to;
    if (!_frameCoveredByImage(from)) return from;
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 10; i++) {
      final mid = (lo + hi) / 2;
      if (_frameCoveredByImage(Rect.lerp(from, to, mid)!)) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return Rect.lerp(from, to, lo)!;
  }

  // -------------------------------------------------------------------------
  // 回転（ルーラー + 90度ボタン）
  // -------------------------------------------------------------------------

  void _onRulerDragStart(DragStartDetails details) {
    if (!_initialized) return;
    _stopSettle();
    _ruler = _RulerSession(
      startRotationDeg: _transform.rotationDeg,
      startFineDeg: _fineAngle,
      startScale: _transform.scale,
      srcAnchor: _viewToSource(_frame.center),
    );
    _gridController.forward();
  }

  void _onRulerDragUpdate(DragUpdateDetails details) {
    final session = _ruler;
    if (session == null) return;
    session.accumDx += details.delta.dx;
    final fine = (session.startFineDeg -
            session.accumDx / _kRulerPixelsPerDegree)
        .clamp(-_kRulerMaxDegrees, _kRulerMaxDegrees);
    final rotation =
        session.startRotationDeg + (fine - session.startFineDeg);
    setState(() {
      final t = _transform;
      t.rotationDeg = rotation;
      // cover維持のための自動ズーム（縮められる場合はドラッグ開始時まで戻す）
      t.scale = math.max(session.startScale, _minCoverScale());
      // 枠中心の内容を維持して回転
      t.offset = _anchorOffset(
        srcAnchor: session.srcAnchor,
        viewPoint: _frame.center,
        rotationDeg: rotation,
        scale: t.scale,
      );
      t.offset = _clampOffset(t.offset);
    });
  }

  void _onRulerDragEnd(DragEndDetails details) {
    if (_ruler == null) return;
    _ruler = null;
    _gridController.reverse();
    // 離した角度で確定。ただし0度±2度以内は0度へスナップ
    final fine = _fineAngle;
    if (fine != 0 && fine.abs() <= _kRotationSnapDegrees) {
      HapticFeedback.lightImpact();
      _animateTo(
        _rotationTarget(_transform.rotationDeg - fine),
        clampDuring: true,
      );
    }
    setState(() {});
  }

  /// 現在角+90へアニメーション（枠アスペクトは維持、cover再計算）
  void _rotate90() {
    if (!_initialized) return;
    // アニメーション中の連打は進行中の目標角を基準にする（中間角に着地しない）
    final baseRotation = _settleTo?.rotationDeg ?? _transform.rotationDeg;
    _stopSettle();
    HapticFeedback.selectionClick();
    _animateTo(
      _rotationTarget(baseRotation + 90),
      duration: _kRotate90Duration,
      clampDuring: true,
    );
  }

  // -------------------------------------------------------------------------
  // アスペクト比プリセット・リセット
  // -------------------------------------------------------------------------

  void _changeAspect(_AspectPreset preset) {
    if (!_initialized || preset == _aspect) return;
    HapticFeedback.selectionClick();
    _stopSettle();
    setState(() => _aspect = preset);
    final ratio = preset.ratio;
    if (ratio == null) return; // フリーは枠を変えずロック解除のみ
    final target = _fitRect(ratio, _frameBounds);
    _animateTo(
      _rotationTarget(_transform.rotationDeg, frame: target),
      clampDuring: true,
    );
  }

  bool _isCropIdentity() {
    if (!_initialized) return true;
    return _buildCurrentParams()
        .copyWith(filter: const PhotoEditFilter())
        .isIdentity;
  }

  /// 切り抜き・回転を初期状態へアニメーションで戻す
  void _resetCrop() {
    _stopSettle();
    setState(() => _aspect = _AspectPreset.free);
    final targetFrame = _fitRect(_srcW / _srcH, _frameBounds);
    // 最短方向で0度（mod 360）へ
    final targetRotation =
        _transform.rotationDeg - _normalizeDeg(_transform.rotationDeg);
    final d = PhotoEditGeometry.cropRectToDisplay(
      viewportSize: _viewportSize,
      frameRect: targetFrame,
      srcSize: _srcSize,
      rotationDeg: targetRotation,
      cropRect: Rect.fromLTWH(0, 0, _srcW.toDouble(), _srcH.toDouble()),
    );
    _animateTo(
      _EditorSnapshot(
        frame: targetFrame,
        scale: d.scale,
        offset: d.offset,
        rotationDeg: targetRotation,
      ),
      clampDuring: true,
    );
  }

  // -------------------------------------------------------------------------
  // フィルター
  // -------------------------------------------------------------------------

  int _matchedPresetIndex() {
    for (var i = 0; i < kFilterPresets.length; i++) {
      final p = kFilterPresets[i];
      if (p.brightness == _filter.brightness &&
          p.contrast == _filter.contrast &&
          p.saturation == _filter.saturation &&
          p.temperature == _filter.temperature &&
          p.vignette == _filter.vignette) {
        return i;
      }
    }
    return -1;
  }

  void _applyPreset(int index) {
    HapticFeedback.selectionClick();
    setState(() => _filter = kFilterPresets[index]);
  }

  void _updateFilter(PhotoEditFilter filter) {
    setState(() => _filter = filter);
  }

  // -------------------------------------------------------------------------
  // 上部バーのアクション
  // -------------------------------------------------------------------------

  Future<bool> _confirm({
    required String title,
    String? message,
    required String confirmLabel,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF222222),
        title: Text(
          title,
          style: const TextStyle(
            color: EditorColors.text,
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: message == null
            ? null
            : Text(
                message,
                style: const TextStyle(
                  color: EditorColors.textMuted,
                  fontSize: 14,
                ),
              ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text(
              'キャンセル',
              style: TextStyle(color: EditorColors.textMuted),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              confirmLabel,
              style: const TextStyle(
                color: EditorColors.accent,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _handleClose() async {
    if (!_hasChanges()) {
      Navigator.pop(context);
      return;
    }
    final ok = await _confirm(
      title: '編集を破棄しますか？',
      message: '変更内容は保存されません',
      confirmLabel: '破棄',
    );
    if (ok && mounted) Navigator.pop(context);
  }

  Future<void> _handleReset() async {
    if (!_initialized) return;
    if (_tab == _EditorTab.crop) {
      if (_isCropIdentity()) return;
      final ok = await _confirm(
        title: '切り抜きをリセットしますか？',
        message: '回転と切り抜きが元に戻ります',
        confirmLabel: 'リセット',
      );
      if (ok && mounted) _resetCrop();
    } else {
      if (_filter.isIdentity) return;
      final ok = await _confirm(
        title: 'フィルターをリセットしますか？',
        message: '色の調整がすべて元に戻ります',
        confirmLabel: 'リセット',
      );
      if (ok && mounted) {
        setState(() => _filter = kFilterPresets.first);
      }
    }
  }

  void _handleDone() {
    if (!_initialized) return;
    Navigator.pop(context, PhotoEditApplied(_buildCurrentParams()));
  }

  Future<void> _confirmRestoreOriginal() async {
    final ok = await _confirm(
      title: 'オリジナルに戻しますか？',
      message: '適用済みの編集をすべて破棄して元の写真に戻します',
      confirmLabel: '戻す',
    );
    if (ok && mounted) {
      Navigator.pop(context, const PhotoEditRestoreOriginal());
    }
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleClose();
      },
      child: Scaffold(
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
            tooltip: '閉じる',
            onPressed: _handleClose,
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'リセット',
              onPressed: _initialized ? _handleReset : null,
            ),
            IconButton(
              icon: const Icon(Icons.check),
              tooltip: '完了',
              onPressed: _initialized ? _handleDone : null,
            ),
            if (widget.canRestoreOriginal)
              PopupMenuButton<_MenuAction>(
                icon: const Icon(Icons.more_vert),
                color: const Color(0xFF222222),
                onSelected: (action) {
                  if (action == _MenuAction.restoreOriginal) {
                    _confirmRestoreOriginal();
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: _MenuAction.restoreOriginal,
                    child: Text(
                      'オリジナルに戻す',
                      style: TextStyle(color: EditorColors.text),
                    ),
                  ),
                ],
              ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(child: _buildViewport()),
              _buildBottomPanel(),
            ],
          ),
        ),
      ),
    );
  }

  // ---- 中央: 画像キャンバス ----

  Widget _buildViewport() {
    if (_loadFailed) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '画像を読み込めませんでした',
              style: TextStyle(color: EditorColors.textMuted, fontSize: 14),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                '閉じる',
                style: TextStyle(color: EditorColors.accent),
              ),
            ),
          ],
        ),
      );
    }
    if (_preview == null) {
      return const Center(
        child: CircularProgressIndicator(color: EditorColors.text),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        if (size.width <= 0 || size.height <= 0) {
          return const SizedBox.shrink();
        }
        _ensureInitialized(size);
        final isCrop = _tab == _EditorTab.crop;
        return AnimatedSwitcher(
          duration: _kTabSwitchDuration,
          child: KeyedSubtree(
            key: ValueKey(isCrop),
            child: isCrop ? _buildCropCanvas() : _buildPreviewCanvas(),
          ),
        );
      },
    );
  }

  Widget _buildCropCanvas() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onScaleStart: _onScaleStart,
      onScaleUpdate: _onScaleUpdate,
      onScaleEnd: _onScaleEnd,
      child: ClipRect(
        child: CustomPaint(
          size: Size.infinite,
          painter: _EditorCanvasPainter(
            image: _preview!,
            srcSize: _srcSize,
            rotationDeg: _transform.rotationDeg,
            scale: _transform.scale,
            offset: _transform.offset,
            filter: _filter,
            frame: _frame,
            gridOpacity: _gridController.value,
            activeHandle: _gesture?.handle,
          ),
        ),
      ),
    );
  }

  /// 非クロップタブ: 現在の切り抜き結果でプレビュー（ビネット込み）
  Widget _buildPreviewCanvas() {
    final crop = _currentCropRect();
    final fitted = _fitRect(crop.width / crop.height, _frameBounds);
    final d = PhotoEditGeometry.cropRectToDisplay(
      viewportSize: _viewportSize,
      frameRect: fitted,
      srcSize: _srcSize,
      rotationDeg: _transform.rotationDeg,
      cropRect: crop,
    );
    return ClipRect(
      child: CustomPaint(
        size: Size.infinite,
        painter: _EditorCanvasPainter(
          image: _preview!,
          srcSize: _srcSize,
          rotationDeg: _transform.rotationDeg,
          scale: d.scale,
          offset: d.offset,
          filter: _filter,
          clipRect: fitted,
        ),
      ),
    );
  }

  // ---- 下部: タブコンテンツ + タブバー ----

  Widget _buildBottomPanel() {
    return Container(
      color: EditorColors.background,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: _kBottomContentHeight,
            child: AnimatedSwitcher(
              duration: _kTabSwitchDuration,
              child: KeyedSubtree(
                key: ValueKey(_tab),
                child: switch (_tab) {
                  _EditorTab.crop => _buildCropControls(),
                  _EditorTab.filter => _buildFilterTab(),
                  _EditorTab.adjust => _buildAdjustTab(),
                },
              ),
            ),
          ),
          _buildTabBar(),
        ],
      ),
    );
  }

  Widget _buildTabBar() {
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: EditorColors.hairline)),
      ),
      child: Row(
        children: _EditorTab.values.map((tab) {
          final selected = tab == _tab;
          return Expanded(
            child: InkWell(
              onTap: () {
                if (_tab != tab) {
                  // 進行中のドラッグ（ジェスチャUIがこの切替で消える）を後始末
                  _cancelActiveInteraction();
                  setState(() => _tab = tab);
                }
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      tab.icon,
                      size: 22,
                      color: selected
                          ? EditorColors.accent
                          : EditorColors.textMuted,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      tab.label,
                      style: TextStyle(
                        fontSize: 11,
                        color: selected
                            ? EditorColors.accent
                            : EditorColors.textMuted,
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  // ---- 切り抜きタブ: ルーラー + 90度回転 + アスペクト比 ----

  Widget _buildCropControls() {
    if (!_initialized) return const SizedBox.shrink();
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          height: 56,
          width: double.infinity,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: _onRulerDragStart,
            onHorizontalDragUpdate: _onRulerDragUpdate,
            onHorizontalDragEnd: _onRulerDragEnd,
            child: CustomPaint(
              painter: _RulerPainter(degrees: _fineAngle),
              child: Center(
                child: Text(
                  '${_fineAngle.toStringAsFixed(1)}°',
                  style: KokoTokens.of(context).numeral.copyWith(
                        fontSize: 12,
                        color: EditorColors.accent,
                      ),
                ),
              ),
            ),
          ),
        ),
        SizedBox(
          height: 48,
          child: Row(
            children: [
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.rotate_90_degrees_cw_outlined),
                color: EditorColors.text,
                tooltip: '90度回転',
                onPressed: _rotate90,
              ),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: _AspectPreset.values.map((preset) {
                      final isSelected = _aspect == preset;
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: GestureDetector(
                          onTap: () => _changeAspect(preset),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? EditorColors.accent
                                      .withValues(alpha: 0.16)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: isSelected
                                    ? EditorColors.accent
                                    : Colors.transparent,
                              ),
                            ),
                            child: Text(
                              preset.label,
                              style: TextStyle(
                                color: isSelected
                                    ? EditorColors.accent
                                    : EditorColors.textMuted,
                                fontSize: 13,
                                fontWeight: isSelected
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ---- フィルタータブ: プリセット円形サムネ ----

  Widget _buildFilterTab() {
    final preview = _preview;
    if (preview == null) return const SizedBox.shrink();
    final selectedIndex = _matchedPresetIndex();
    return Center(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          children: List.generate(kFilterPresets.length, (index) {
            final preset = kFilterPresets[index];
            final isSelected = index == selectedIndex;
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
                            buildEditColorMatrix(preset),
                          ),
                          child: RawImage(
                            image: preview,
                            fit: BoxFit.cover,
                            width: 72,
                            height: 72,
                            filterQuality: FilterQuality.low,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      preset.preset,
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

  // ---- 調整タブ: スライダー5本 ----

  Widget _buildAdjustTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: [
          _buildSlider(
            label: '明るさ',
            icon: Icons.brightness_6_outlined,
            value: _filter.brightness,
            range: FilterAdjustmentRanges.brightness,
            onChanged: (v) =>
                _updateFilter(_filter.copyWith(brightness: v, preset: '')),
          ),
          _buildSlider(
            label: 'コントラスト',
            icon: Icons.contrast_outlined,
            value: _filter.contrast,
            range: FilterAdjustmentRanges.contrast,
            onChanged: (v) =>
                _updateFilter(_filter.copyWith(contrast: v, preset: '')),
          ),
          _buildSlider(
            label: '彩度',
            icon: Icons.palette_outlined,
            value: _filter.saturation,
            range: FilterAdjustmentRanges.saturation,
            onChanged: (v) =>
                _updateFilter(_filter.copyWith(saturation: v, preset: '')),
          ),
          _buildSlider(
            label: '色温度',
            icon: Icons.thermostat_outlined,
            value: _filter.temperature,
            range: FilterAdjustmentRanges.temperature,
            onChanged: (v) =>
                _updateFilter(_filter.copyWith(temperature: v, preset: '')),
          ),
          _buildSlider(
            label: 'ビネット',
            icon: Icons.vignette_outlined,
            value: _filter.vignette,
            range: FilterAdjustmentRanges.vignette,
            onChanged: (v) =>
                _updateFilter(_filter.copyWith(vignette: v, preset: '')),
          ),
        ],
      ),
    );
  }

  Widget _buildSlider({
    required String label,
    required IconData icon,
    required double value,
    required FilterAdjustmentRange range,
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
              min: range.min,
              max: range.max,
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
// キャンバス描画
//
// クロップモード（frame != null）: 画像 + scrim + 枠 + グリッド + 8ハンドル
// プレビューモード（clipRect != null）: 切り抜き範囲にクリップした画像 + ビネット
// 色調整はGPU（Paint.colorFilter）で適用し、焼き込みと同じ行列を使う。
// ---------------------------------------------------------------------------

class _EditorCanvasPainter extends CustomPainter {
  final ui.Image image;
  final Size srcSize;
  final double rotationDeg;
  final double scale;
  final Offset offset;
  final PhotoEditFilter filter;
  final Rect? frame;
  final double gridOpacity;
  final _FrameHandle? activeHandle;
  final Rect? clipRect;

  _EditorCanvasPainter({
    required this.image,
    required this.srcSize,
    required this.rotationDeg,
    required this.scale,
    required this.offset,
    required this.filter,
    this.frame,
    this.gridOpacity = 0,
    this.activeHandle,
    this.clipRect,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final clip = clipRect;
    if (clip != null) {
      canvas.save();
      canvas.clipRect(clip);
    }
    _paintImage(canvas, size);
    if (clip != null) {
      if (filter.vignette > 0) _paintVignette(canvas, clip);
      canvas.restore();
    }
    final f = frame;
    if (f != null) {
      _paintScrim(canvas, size, f);
      if (gridOpacity > 0) _paintGrid(canvas, f);
      _paintFrameBorder(canvas, f);
      _paintHandles(canvas, f);
    }
  }

  void _paintImage(Canvas canvas, Size size) {
    final vc = size.center(Offset.zero);
    canvas.save();
    canvas.translate(vc.dx + offset.dx, vc.dy + offset.dy);
    canvas.rotate(rotationDeg * math.pi / 180);
    canvas.scale(scale);
    final paint = Paint()..filterQuality = FilterQuality.medium;
    final hasMatrix = filter.brightness != 0 ||
        filter.contrast != 0 ||
        filter.saturation != 0 ||
        filter.temperature != 0;
    if (hasMatrix) {
      paint.colorFilter = ColorFilter.matrix(buildEditColorMatrix(filter));
    }
    // プレビュー縮小率は描画先の寸法（EXIF正規化後の元画像寸法）が吸収する
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromCenter(
        center: Offset.zero,
        width: srcSize.width,
        height: srcSize.height,
      ),
      paint,
    );
    canvas.restore();
  }

  /// 焼き込み（_applyFilterBaked）と同じ減光カーブの放射グラデーション
  void _paintVignette(Canvas canvas, Rect rect) {
    final radius = math.sqrt(rect.width * rect.width / 4 +
        rect.height * rect.height / 4);
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [
          Colors.transparent,
          Colors.black.withValues(
              alpha: kVignetteStrength * filter.vignette / 100),
        ],
        stops: const [0.5, 1.0],
      ).createShader(Rect.fromCircle(center: rect.center, radius: radius));
    canvas.drawRect(rect, paint);
  }

  void _paintScrim(Canvas canvas, Size size, Rect f) {
    final path = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRect(f)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(
        path, Paint()..color = Colors.black.withValues(alpha: 0.6));
  }

  void _paintGrid(Canvas canvas, Rect f) {
    final paint = Paint()
      ..color = EditorColors.text.withValues(alpha: 0.35 * gridOpacity)
      ..strokeWidth = 0.5;
    for (var i = 1; i < 3; i++) {
      final x = f.left + f.width * i / 3;
      canvas.drawLine(Offset(x, f.top), Offset(x, f.bottom), paint);
      final y = f.top + f.height * i / 3;
      canvas.drawLine(Offset(f.left, y), Offset(f.right, y), paint);
    }
  }

  void _paintFrameBorder(Canvas canvas, Rect f) {
    canvas.drawRect(
      f,
      Paint()
        ..color = EditorColors.text
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  void _paintHandles(Canvas canvas, Rect f) {
    final len = math.min(20.0, math.min(f.width, f.height) / 3);

    Paint handlePaint(_FrameHandle handle) => Paint()
      ..color =
          handle == activeHandle ? EditorColors.accent : EditorColors.text
      ..strokeWidth = handle == activeHandle ? 4.5 : 3
      ..strokeCap = StrokeCap.round;

    // 角: L字
    void corner(_FrameHandle handle, Offset pos, double dx, double dy) {
      final paint = handlePaint(handle);
      canvas.drawLine(pos, pos + Offset(dx * len, 0), paint);
      canvas.drawLine(pos, pos + Offset(0, dy * len), paint);
    }

    corner(_FrameHandle.topLeft, f.topLeft, 1, 1);
    corner(_FrameHandle.topRight, f.topRight, -1, 1);
    corner(_FrameHandle.bottomLeft, f.bottomLeft, 1, -1);
    corner(_FrameHandle.bottomRight, f.bottomRight, -1, -1);

    // 辺: 中点の短い線分
    void edge(_FrameHandle handle, Offset center, bool horizontal) {
      final paint = handlePaint(handle);
      final half = Offset(
          horizontal ? len / 2 : 0, horizontal ? 0 : len / 2);
      canvas.drawLine(center - half, center + half, paint);
    }

    edge(_FrameHandle.top, f.topCenter, true);
    edge(_FrameHandle.bottom, f.bottomCenter, true);
    edge(_FrameHandle.left, f.centerLeft, false);
    edge(_FrameHandle.right, f.centerRight, false);
  }

  @override
  bool shouldRepaint(_EditorCanvasPainter oldDelegate) =>
      oldDelegate.image != image ||
      oldDelegate.srcSize != srcSize ||
      oldDelegate.rotationDeg != rotationDeg ||
      oldDelegate.scale != scale ||
      oldDelegate.offset != offset ||
      oldDelegate.filter != filter ||
      oldDelegate.frame != frame ||
      oldDelegate.gridOpacity != gridOpacity ||
      oldDelegate.activeHandle != activeHandle ||
      oldDelegate.clipRect != clipRect;
}

// ---------------------------------------------------------------------------
// 回転ルーラー描画（見た目は旧crop_screenのルーラーを移植。
// 表示は直近の90度単位からの相対角で、±45度の範囲のみ目盛りを描く）
// ---------------------------------------------------------------------------

class _RulerPainter extends CustomPainter {
  final double degrees;

  _RulerPainter({required this.degrees});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.width / 2;
    final tickPaint = Paint()
      ..color = EditorColors.textFaint
      ..strokeWidth = 1;

    final majorTickPaint = Paint()
      ..color = EditorColors.textMuted
      ..strokeWidth = 1.5;

    final zeroTickPaint = Paint()
      ..color = EditorColors.accent.withValues(alpha: 0.5)
      ..strokeWidth = 2;

    // 画面に表示される度数の範囲を計算
    final halfRange =
        (size.width / 2 / _kRulerPixelsPerDegree).ceil() + 1;
    final degFloor = degrees.floor();

    for (var i = -halfRange; i <= halfRange; i++) {
      final d = degFloor + i;
      if (d.abs() > _kRulerMaxDegrees) continue;
      final x = center + (d - degrees) * _kRulerPixelsPerDegree;
      if (x < 0 || x > size.width) continue;

      final isMajor = d % 5 == 0;
      final isZero = d == 0;
      final tickH = isZero
          ? 20.0
          : isMajor
              ? 16.0
              : 8.0;
      final paint = isZero
          ? zeroTickPaint
          : isMajor
              ? majorTickPaint
              : tickPaint;

      canvas.drawLine(
        Offset(x, size.height - tickH - 4),
        Offset(x, size.height - 4),
        paint,
      );
    }

    // 中央インジケーター
    final indicatorPaint = Paint()
      ..color = EditorColors.accent
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
