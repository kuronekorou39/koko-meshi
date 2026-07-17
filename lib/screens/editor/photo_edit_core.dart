import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

/// フォトエディタのコアモジュール（UI非依存）。
///
/// - [PhotoEditParams]: 編集パラメータ v2（EXIF正規化後の元画像基準）
/// - [PhotoEditOutcome]: エディタ画面の返り値（型付き）
/// - [buildEditColorMatrix]: プレビューと焼き込みで共有する4x5色行列
/// - [bakePhotoEdit]: compute() 用の焼き込み処理（パス渡し）
/// - [PhotoEditGeometry]: 表示状態⇔cropRect の座標変換（純関数）

// ---------------------------------------------------------------------------
// 写真編集系画面（黒背景固定）の共通配色。
// 編集画面はテーマのライト/ダークに関わらず純黒下地とするため、
// colorScheme ではなくここで統一する。アクセントは黒地で成立する漆（夜）色。
// ---------------------------------------------------------------------------

class EditorColors {
  EditorColors._();

  static const Color background = Colors.black;
  static const Color accent = Color(0xFFDE8A62); // 漆（夜）
  static const Color text = Colors.white;
  static const Color textMuted = Colors.white70;
  static const Color textFaint = Colors.white38;
  static const Color outline = Colors.white24;
  static const Color hairline = Colors.white12;
}

// ---------------------------------------------------------------------------
// フィルター（色調整）
// ---------------------------------------------------------------------------

/// ビネットの最大減光率（プレビューの放射グラデーションと焼き込みで共有）
const double kVignetteStrength = 0.7;

/// 色調整パラメータ。値域は [FilterAdjustmentRanges] を参照。
class PhotoEditFilter {
  /// プリセット名（手動調整で崩れた場合は空文字）
  final String preset;
  final double brightness;
  final double contrast;
  final double saturation;
  final double temperature;
  final double vignette;

  const PhotoEditFilter({
    this.preset = '',
    this.brightness = 0,
    this.contrast = 0,
    this.saturation = 0,
    this.temperature = 0,
    this.vignette = 0,
  });

  /// すべての調整値がゼロ（見た目に影響しない）か
  bool get isIdentity =>
      brightness == 0 &&
      contrast == 0 &&
      saturation == 0 &&
      temperature == 0 &&
      vignette == 0;

  PhotoEditFilter copyWith({
    String? preset,
    double? brightness,
    double? contrast,
    double? saturation,
    double? temperature,
    double? vignette,
  }) {
    return PhotoEditFilter(
      preset: preset ?? this.preset,
      brightness: brightness ?? this.brightness,
      contrast: contrast ?? this.contrast,
      saturation: saturation ?? this.saturation,
      temperature: temperature ?? this.temperature,
      vignette: vignette ?? this.vignette,
    );
  }

  Map<String, dynamic> toJson() => {
        'preset': preset,
        'brightness': brightness,
        'contrast': contrast,
        'saturation': saturation,
        'temperature': temperature,
        'vignette': vignette,
      };

  factory PhotoEditFilter.fromJson(Map<String, dynamic> json) {
    return PhotoEditFilter(
      preset: json['preset'] as String? ?? '',
      brightness: (json['brightness'] as num?)?.toDouble() ?? 0,
      contrast: (json['contrast'] as num?)?.toDouble() ?? 0,
      saturation: (json['saturation'] as num?)?.toDouble() ?? 0,
      temperature: (json['temperature'] as num?)?.toDouble() ?? 0,
      vignette: (json['vignette'] as num?)?.toDouble() ?? 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PhotoEditFilter &&
      other.preset == preset &&
      other.brightness == brightness &&
      other.contrast == contrast &&
      other.saturation == saturation &&
      other.temperature == temperature &&
      other.vignette == vignette;

  @override
  int get hashCode => Object.hash(
      preset, brightness, contrast, saturation, temperature, vignette);
}

/// フィルタープリセット（旧エディタの6種をそのまま移植）
const kFilterPresets = <PhotoEditFilter>[
  PhotoEditFilter(preset: 'オリジナル'),
  PhotoEditFilter(
    preset: 'おいしい',
    temperature: 25,
    saturation: 20,
    contrast: 10,
    brightness: 5,
  ),
  PhotoEditFilter(
    preset: 'カフェ',
    temperature: 20,
    saturation: -15,
    contrast: -10,
    brightness: 10,
  ),
  PhotoEditFilter(
    preset: '鮮やか',
    saturation: 50,
    contrast: 30,
  ),
  PhotoEditFilter(
    preset: 'ナチュラル',
    temperature: 10,
    saturation: 8,
    contrast: 5,
    brightness: 5,
  ),
  PhotoEditFilter(
    preset: 'レトロ',
    temperature: 35,
    saturation: -30,
    contrast: 10,
    brightness: -5,
    vignette: 30,
  ),
];

/// 調整スライダーの値域（旧エディタのまま）
class FilterAdjustmentRange {
  final double min;
  final double max;

  const FilterAdjustmentRange(this.min, this.max);
}

class FilterAdjustmentRanges {
  FilterAdjustmentRanges._();

  static const brightness = FilterAdjustmentRange(-100, 100);
  static const contrast = FilterAdjustmentRange(-80, 100);
  static const saturation = FilterAdjustmentRange(-100, 100);
  static const temperature = FilterAdjustmentRange(-100, 100);
  static const vignette = FilterAdjustmentRange(0, 100);
}

// ---------------------------------------------------------------------------
// 4x5色行列（ColorFilter.matrix と同レイアウト）。
// プレビュー（ColorFiltered）と焼き込みが同一行列を使うことで見た目を一致させる。
// 数式は旧 photo_editor_screen.dart の buildEditColorMatrix をそのまま移植。
// ---------------------------------------------------------------------------

/// フィルターから4x5色行列（長さ20のリスト）を合成する。ビネットは含まない。
List<double> buildEditColorMatrix(PhotoEditFilter filter) {
  var m = _identityColorMatrix();
  m = _multiplyColorMatrix(m, _brightnessMatrix(filter.brightness));
  m = _multiplyColorMatrix(m, _contrastMatrix(filter.contrast));
  m = _multiplyColorMatrix(m, _saturationMatrix(filter.saturation));
  m = _multiplyColorMatrix(m, _temperatureMatrix(filter.temperature));
  return m;
}

List<double> _identityColorMatrix() => <double>[
      1, 0, 0, 0, 0,
      0, 1, 0, 0, 0,
      0, 0, 1, 0, 0,
      0, 0, 0, 1, 0,
    ];

List<double> _multiplyColorMatrix(List<double> a, List<double> b) {
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

List<double> _temperatureMatrix(double value) {
  final v = value / 100 * 40;
  return <double>[1, 0, 0, 0, v, 0, 1, 0, 0, 0, 0, 0, 1, 0, -v, 0, 0, 0, 1, 0];
}

// ---------------------------------------------------------------------------
// 編集パラメータ v2
// ---------------------------------------------------------------------------

/// 写真編集パラメータ v2。
///
/// 座標系: **EXIF正規化後の元画像**を基準とする。
/// [rotationDeg]（正 = 時計回り）で画像を中心回転した後の
/// 「回転後バウンディングボックスのピクセル座標」で [cropRect] を持つ。
/// [srcW]/[srcH] はEXIF正規化後の元画像寸法で、復元時の整合チェックに使う。
class PhotoEditParams {
  static const int formatVersion = 2;

  /// 自由回転角（度、正 = 時計回り）
  final double rotationDeg;

  /// 切り抜き範囲（回転後バウンディングボックスのピクセル座標）
  final Rect cropRect;

  /// EXIF正規化後の元画像の幅
  final int srcW;

  /// EXIF正規化後の元画像の高さ
  final int srcH;

  final PhotoEditFilter filter;

  const PhotoEditParams({
    required this.rotationDeg,
    required this.cropRect,
    required this.srcW,
    required this.srcH,
    this.filter = const PhotoEditFilter(),
  });

  /// 「編集なし」のパラメータ（回転0・全域crop・フィルターなし）
  factory PhotoEditParams.identity({required int srcW, required int srcH}) {
    return PhotoEditParams(
      rotationDeg: 0,
      cropRect: Rect.fromLTWH(0, 0, srcW.toDouble(), srcH.toDouble()),
      srcW: srcW,
      srcH: srcH,
    );
  }

  /// 見た目に影響しない「編集なし」パラメータか
  bool get isIdentity {
    if (!filter.isIdentity) return false;
    // 回転: 360の倍数なら恒等
    final r = rotationDeg % 360;
    if (r.abs() > 1e-9 && (360 - r).abs() > 1e-9) return false;
    // crop: 元画像全域（誤差0.5px未満は編集なしとみなす）
    return cropRect.left.abs() < 0.5 &&
        cropRect.top.abs() < 0.5 &&
        (cropRect.width - srcW).abs() < 0.5 &&
        (cropRect.height - srcH).abs() < 0.5;
  }

  PhotoEditParams copyWith({
    double? rotationDeg,
    Rect? cropRect,
    int? srcW,
    int? srcH,
    PhotoEditFilter? filter,
  }) {
    return PhotoEditParams(
      rotationDeg: rotationDeg ?? this.rotationDeg,
      cropRect: cropRect ?? this.cropRect,
      srcW: srcW ?? this.srcW,
      srcH: srcH ?? this.srcH,
      filter: filter ?? this.filter,
    );
  }

  Map<String, dynamic> toJson() => {
        'version': formatVersion,
        'rotationDeg': rotationDeg,
        'crop': {
          'x': cropRect.left,
          'y': cropRect.top,
          'w': cropRect.width,
          'h': cropRect.height,
        },
        'srcW': srcW,
        'srcH': srcH,
        'filter': filter.toJson(),
      };

  /// v2以外（version欠損・旧v1含む）は意味が壊れているため null を返して破棄する。
  static PhotoEditParams? fromJson(Map<String, dynamic> json) {
    final version = json['version'];
    if (version is! num || version.toInt() != formatVersion) return null;
    try {
      final crop = json['crop'] as Map<String, dynamic>;
      final filterJson = json['filter'];
      return PhotoEditParams(
        rotationDeg: (json['rotationDeg'] as num?)?.toDouble() ?? 0,
        cropRect: Rect.fromLTWH(
          (crop['x'] as num).toDouble(),
          (crop['y'] as num).toDouble(),
          (crop['w'] as num).toDouble(),
          (crop['h'] as num).toDouble(),
        ),
        srcW: (json['srcW'] as num).toInt(),
        srcH: (json['srcH'] as num).toInt(),
        filter: filterJson is Map<String, dynamic>
            ? PhotoEditFilter.fromJson(filterJson)
            : const PhotoEditFilter(),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is PhotoEditParams &&
      other.rotationDeg == rotationDeg &&
      other.cropRect == cropRect &&
      other.srcW == srcW &&
      other.srcH == srcH &&
      other.filter == filter;

  @override
  int get hashCode => Object.hash(rotationDeg, cropRect, srcW, srcH, filter);
}

// ---------------------------------------------------------------------------
// エディタ画面の返り値（型付き）
// ---------------------------------------------------------------------------

/// PhotoEditorScreen が Navigator.pop で返す結果。
/// キャンセル時は null（pop のデフォルト）を返す。
sealed class PhotoEditOutcome {
  const PhotoEditOutcome();
}

/// 編集を確定した（焼き込みは呼び出し側が [bakePhotoEdit] で行う）
class PhotoEditApplied extends PhotoEditOutcome {
  final PhotoEditParams params;

  const PhotoEditApplied(this.params);
}

/// 「オリジナルに戻す」を選択した
class PhotoEditRestoreOriginal extends PhotoEditOutcome {
  const PhotoEditRestoreOriginal();
}

// ---------------------------------------------------------------------------
// 座標変換（純関数）
//
// 表示モデル:
//   画像（EXIF正規化後）は「ビューポート中心 + offset」に画像中心が来るよう
//   配置し、rotationDeg（正 = 時計回り）回転・scale倍で描画する。
//     view = viewportCenter + offset + scale · R(θ) · (src − srcCenter)
//   回転後バウンディングボックス座標との関係:
//     rot = R(θ) · (src − srcCenter) + boundsCenter
//   よって view = viewportCenter + offset + scale · (rot − boundsCenter) となり、
//   軸平行の枠Rect ⇔ cropRect が回転なしの相似変換で対応する。
// ---------------------------------------------------------------------------

class PhotoEditGeometry {
  PhotoEditGeometry._();

  static double _rad(double deg) => deg * math.pi / 180.0;

  /// 回転後バウンディングボックスの寸法（連続値）
  static Size rotatedBoundsSize(Size srcSize, double rotationDeg) {
    final rad = _rad(rotationDeg);
    final c = math.cos(rad).abs();
    final s = math.sin(rad).abs();
    return Size(
      srcSize.width * c + srcSize.height * s,
      srcSize.width * s + srcSize.height * c,
    );
  }

  /// 表示状態 → cropRect（回転後バウンディングボックスのピクセル座標）
  static Rect displayToCropRect({
    required Size viewportSize,
    required Rect frameRect,
    required Size srcSize,
    required double rotationDeg,
    required double scale,
    required Offset offset,
  }) {
    final bounds = rotatedBoundsSize(srcSize, rotationDeg);
    final vc = viewportSize.center(Offset.zero);
    return Rect.fromLTWH(
      (frameRect.left - vc.dx - offset.dx) / scale + bounds.width / 2,
      (frameRect.top - vc.dy - offset.dy) / scale + bounds.height / 2,
      frameRect.width / scale,
      frameRect.height / scale,
    );
  }

  /// cropRect → 表示状態（scale, offset）の復元。
  /// [frameRect] は呼び出し側が cropRect と同じアスペクト比でフィット済みであること。
  static ({double scale, Offset offset}) cropRectToDisplay({
    required Size viewportSize,
    required Rect frameRect,
    required Size srcSize,
    required double rotationDeg,
    required Rect cropRect,
  }) {
    final bounds = rotatedBoundsSize(srcSize, rotationDeg);
    final vc = viewportSize.center(Offset.zero);
    final scale = frameRect.width / cropRect.width;
    return (
      scale: scale,
      offset: Offset(
        frameRect.left - vc.dx - scale * (cropRect.left - bounds.width / 2),
        frameRect.top - vc.dy - scale * (cropRect.top - bounds.height / 2),
      ),
    );
  }

  /// 枠全体が画像の実体（回転後の余白でなく元画像領域）に覆われるための scale 下限
  static double minCoverScale({
    required Rect frameRect,
    required Size srcSize,
    required double rotationDeg,
  }) {
    final rad = _rad(rotationDeg);
    final c = math.cos(rad).abs();
    final s = math.sin(rad).abs();
    // 枠を元画像座標系へ逆回転したときのAABB寸法（scale=1換算）
    final needW = frameRect.width * c + frameRect.height * s;
    final needH = frameRect.width * s + frameRect.height * c;
    return math.max(needW / srcSize.width, needH / srcSize.height);
  }

  /// 枠が画像の実体からはみ出さないよう offset をクランプする。
  /// scale が [minCoverScale] 未満で覆いきれない軸は中央に寄せる。
  static Offset clampOffsetToCover({
    required Size viewportSize,
    required Rect frameRect,
    required Size srcSize,
    required double rotationDeg,
    required double scale,
    required Offset offset,
  }) {
    final rad = _rad(rotationDeg);
    final c = math.cos(rad);
    final s = math.sin(rad);
    final ca = c.abs();
    final sa = s.abs();
    // 枠を元画像座標系へ逆回転したときのAABB寸法
    final bw = (frameRect.width * ca + frameRect.height * sa) / scale;
    final bh = (frameRect.width * sa + frameRect.height * ca) / scale;
    // 枠中心を元画像座標へ（R(-θ)·v = (v.x·c + v.y·s, −v.x·s + v.y·c)）
    final vc = viewportSize.center(Offset.zero);
    final fc = frameRect.center;
    final dx = (fc.dx - vc.dx - offset.dx) / scale;
    final dy = (fc.dy - vc.dy - offset.dy) / scale;
    final csx = srcSize.width / 2 + dx * c + dy * s;
    final csy = srcSize.height / 2 - dx * s + dy * c;
    // 枠のAABBが元画像内に収まる範囲へ枠中心をクランプ
    final clampedX = bw >= srcSize.width
        ? srcSize.width / 2
        : csx.clamp(bw / 2, srcSize.width - bw / 2);
    final clampedY = bh >= srcSize.height
        ? srcSize.height / 2
        : csy.clamp(bh / 2, srcSize.height - bh / 2);
    // クランプ後の枠中心（元画像座標）から offset を逆算
    final px = clampedX - srcSize.width / 2;
    final py = clampedY - srcSize.height / 2;
    return Offset(
      fc.dx - vc.dx - scale * (px * c - py * s),
      fc.dy - vc.dy - scale * (px * s + py * c),
    );
  }

  /// ビューポート座標 → 元画像（EXIF正規化後）ピクセル座標
  static Offset viewToSource({
    required Offset point,
    required Size viewportSize,
    required Size srcSize,
    required double rotationDeg,
    required double scale,
    required Offset offset,
  }) {
    final rad = _rad(rotationDeg);
    final c = math.cos(rad);
    final s = math.sin(rad);
    final vc = viewportSize.center(Offset.zero);
    final dx = (point.dx - vc.dx - offset.dx) / scale;
    final dy = (point.dy - vc.dy - offset.dy) / scale;
    return Offset(
      srcSize.width / 2 + dx * c + dy * s,
      srcSize.height / 2 - dx * s + dy * c,
    );
  }

  /// 元画像（EXIF正規化後）ピクセル座標 → ビューポート座標
  static Offset sourceToView({
    required Offset point,
    required Size viewportSize,
    required Size srcSize,
    required double rotationDeg,
    required double scale,
    required Offset offset,
  }) {
    final rad = _rad(rotationDeg);
    final c = math.cos(rad);
    final s = math.sin(rad);
    final vc = viewportSize.center(Offset.zero);
    final px = point.dx - srcSize.width / 2;
    final py = point.dy - srcSize.height / 2;
    return Offset(
      vc.dx + offset.dx + scale * (px * c - py * s),
      vc.dy + offset.dy + scale * (px * s + py * c),
    );
  }
}

// ---------------------------------------------------------------------------
// 焼き込み（compute() 用）
// ---------------------------------------------------------------------------

/// 焼き込み後の長辺上限（これを超える場合は縮小して保存する）
const int kBakeMaxDimension = 4096;

/// 焼き込みJPEGの品質
const int kBakeJpgQuality = 92;

/// [bakePhotoEdit] へのリクエスト（compute() でisolateに渡す）
class PhotoEditBakeRequest {
  final String inputPath;
  final String outputPath;
  final PhotoEditParams params;

  const PhotoEditBakeRequest({
    required this.inputPath,
    required this.outputPath,
    required this.params,
  });
}

/// 編集パラメータを元画像に焼き込む（compute() 用トップレベル関数）。
///
/// decode → EXIF正規化 → 回転 → crop → 色調整+ビネット（1パス）→
/// 長辺 [kBakeMaxDimension] 超なら縮小 → JPEG(quality: [kBakeJpgQuality]) 保存。
/// 成功時は出力パス、失敗時は null を返す。
String? bakePhotoEdit(PhotoEditBakeRequest request) {
  try {
    final bytes = File(request.inputPath).readAsBytesSync();
    var image = img.decodeImage(bytes);
    if (image == null) return null;
    image = img.bakeOrientation(image);

    final params = request.params;
    var crop = params.cropRect;

    // 整合チェック: 保存時の元画像寸法と実寸が異なる場合はcropを比例スケール
    final actualSrc = Size(image.width.toDouble(), image.height.toDouble());
    final actualBounds =
        PhotoEditGeometry.rotatedBoundsSize(actualSrc, params.rotationDeg);
    if (image.width != params.srcW || image.height != params.srcH) {
      final expectedBounds = PhotoEditGeometry.rotatedBoundsSize(
        Size(params.srcW.toDouble(), params.srcH.toDouble()),
        params.rotationDeg,
      );
      final sx = actualBounds.width / expectedBounds.width;
      final sy = actualBounds.height / expectedBounds.height;
      crop = Rect.fromLTWH(
          crop.left * sx, crop.top * sy, crop.width * sx, crop.height * sy);
    }

    // 回転（正 = 時計回り。copyRotateと表示側の規約は一致）
    if (params.rotationDeg % 360 != 0) {
      image = img.copyRotate(
        image,
        angle: params.rotationDeg,
        interpolation: img.Interpolation.linear,
      );
      // 任意角ではcopyRotateのキャンバス寸法が切り捨てられるため、中心ズレを補正
      crop = crop.translate(
        (image.width - actualBounds.width) / 2,
        (image.height - actualBounds.height) / 2,
      );
    }

    // crop（境界クランプ）
    final x0 = crop.left.round().clamp(0, image.width - 1).toInt();
    final y0 = crop.top.round().clamp(0, image.height - 1).toInt();
    final x1 = crop.right.round().clamp(x0 + 1, image.width).toInt();
    final y1 = crop.bottom.round().clamp(y0 + 1, image.height).toInt();
    if (x0 != 0 || y0 != 0 || x1 != image.width || y1 != image.height) {
      image = img.copyCrop(image,
          x: x0, y: y0, width: x1 - x0, height: y1 - y0);
    }

    // 色調整 + ビネット（1パス）
    if (!params.filter.isIdentity) {
      image = _applyFilterBaked(image, params.filter);
    }

    // 長辺上限
    if (math.max(image.width, image.height) > kBakeMaxDimension) {
      image = img.copyResize(
        image,
        width: image.width >= image.height ? kBakeMaxDimension : null,
        height: image.width >= image.height ? null : kBakeMaxDimension,
        interpolation: img.Interpolation.linear,
      );
    }

    final output = img.encodeJpg(image, quality: kBakeJpgQuality);
    File(request.outputPath).writeAsBytesSync(output);
    return request.outputPath;
  } catch (_) {
    return null;
  }
}

/// 色行列 + ビネットを1回のピクセル走査で適用する。
/// プレビュー（ColorFiltered + 放射グラデーション）と同じ見た目になるよう、
/// 行列適用 → クランプ → ビネット減光の順で計算する。
img.Image _applyFilterBaked(img.Image src, PhotoEditFilter filter) {
  var image = src;
  if (image.format != img.Format.uint8 || image.hasPalette) {
    image = image.convert(format: img.Format.uint8);
  }

  final m = buildEditColorMatrix(filter);
  // 合成行列でも alpha 行・alpha 列は恒等のまま（各要素行列がalphaに触れないため）
  final hasMatrix =
      filter.brightness != 0 ||
      filter.contrast != 0 ||
      filter.saturation != 0 ||
      filter.temperature != 0;
  final hasVignette = filter.vignette > 0;
  final intensity = filter.vignette / 100;
  final cx = image.width / 2;
  final cy = image.height / 2;
  final invMaxDist = 1.0 / math.sqrt(cx * cx + cy * cy);

  for (final p in image) {
    var r = p.r.toDouble();
    var g = p.g.toDouble();
    var b = p.b.toDouble();
    if (hasMatrix) {
      final nr = m[0] * r + m[1] * g + m[2] * b + m[4];
      final ng = m[5] * r + m[6] * g + m[7] * b + m[9];
      final nb = m[10] * r + m[11] * g + m[12] * b + m[14];
      r = nr.clamp(0.0, 255.0);
      g = ng.clamp(0.0, 255.0);
      b = nb.clamp(0.0, 255.0);
    }
    if (hasVignette) {
      final dx = p.x - cx;
      final dy = p.y - cy;
      final normalized = math.sqrt(dx * dx + dy * dy) * invMaxDist;
      final amount = ((normalized - 0.5) / 0.5).clamp(0.0, 1.0);
      final darken = 1.0 - amount * kVignetteStrength * intensity;
      r *= darken;
      g *= darken;
      b *= darken;
    }
    p
      ..r = r.round().clamp(0, 255)
      ..g = g.round().clamp(0, 255)
      ..b = b.round().clamp(0, 255);
  }
  return image;
}
