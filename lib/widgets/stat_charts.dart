import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 期間の日別カロリーを並べた棒グラフ。
///
/// チャート用のパッケージを入れず自前で描いている。必要なのは棒とレーダーの
/// 2種だけで、既製品の見た目(影・グラデーション・彩度の高い配色)は
/// デザインの方針と合わないため。
class DailyBarChart extends StatelessWidget {
  const DailyBarChart({
    super.key,
    required this.days,
    required this.values,
    this.height = 120,
    this.averageLine,
  });

  /// 横軸(古い順)
  final List<DateTime> days;

  /// 日付→値。無い日は0として描く
  final Map<DateTime, int> values;
  final double height;

  /// 目安として引く水平線(1日平均など)
  final int? averageLine;

  @override
  Widget build(BuildContext context) {
    final tokens = KokoTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final data = days.map((d) => values[d] ?? 0).toList();
    final maxValue = data.isEmpty ? 0 : data.reduce(math.max);

    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: _BarPainter(
          values: data,
          maxValue: maxValue,
          barColor: scheme.primary,
          emptyColor: tokens.hairline,
          lineColor: tokens.textFaint,
          averageLine: averageLine,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter({
    required this.values,
    required this.maxValue,
    required this.barColor,
    required this.emptyColor,
    required this.lineColor,
    this.averageLine,
  });

  final List<int> values;
  final int maxValue;
  final Color barColor;
  final Color emptyColor;
  final Color lineColor;
  final int? averageLine;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    // 目盛りが無いと高さの意味が読めないので、最大値は少し余裕を持たせる
    final top = (maxValue == 0 ? 1 : maxValue) * 1.15;
    final slot = size.width / values.length;
    final barWidth = math.min(slot * 0.62, 18.0);

    final avg = averageLine;
    if (avg != null && avg > 0 && avg <= top) {
      final y = size.height - size.height * (avg / top);
      final paint = Paint()
        ..color = lineColor
        ..strokeWidth = 0.8;
      // 破線で「目安」であることを示す
      for (var x = 0.0; x < size.width; x += 6) {
        canvas.drawLine(Offset(x, y), Offset(x + 3, y), paint);
      }
    }

    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      final cx = slot * i + slot / 2;
      final h = v == 0 ? 2.0 : size.height * (v / top);
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(cx - barWidth / 2, size.height - h, barWidth, h),
        const Radius.circular(2),
      );
      canvas.drawRRect(rect, Paint()..color = v == 0 ? emptyColor : barColor);
    }
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.values != values || old.maxValue != maxValue;
}

/// ジャンル構成のレーダーチャート。
class GenreRadarChart extends StatelessWidget {
  const GenreRadarChart({
    super.key,
    required this.labels,
    required this.values,
    this.size = 200,
  });

  final List<String> labels;

  /// [labels] と同じ並びの値。最大値を外周に合わせて正規化する
  final List<int> values;
  final double size;

  @override
  Widget build(BuildContext context) {
    final tokens = KokoTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: size,
      child: CustomPaint(
        painter: _RadarPainter(
          labels: labels,
          values: values,
          gridColor: tokens.hairline,
          fillColor: scheme.primary.withValues(alpha: 0.22),
          lineColor: scheme.primary,
          labelColor: tokens.textMuted,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter({
    required this.labels,
    required this.values,
    required this.gridColor,
    required this.fillColor,
    required this.lineColor,
    required this.labelColor,
  });

  final List<String> labels;
  final List<int> values;
  final Color gridColor;
  final Color fillColor;
  final Color lineColor;
  final Color labelColor;

  @override
  void paint(Canvas canvas, Size size) {
    final n = labels.length;
    if (n < 3) return;
    final center = Offset(size.width / 2, size.height / 2);
    // ラベルを外側に置くぶん、多角形は小さめに取る
    final radius = math.min(size.width, size.height) / 2 - 30;
    final maxValue = values.isEmpty ? 0 : values.reduce(math.max);
    final top = maxValue == 0 ? 1 : maxValue;

    Offset pointAt(int i, double ratio) {
      // 頂点が真上から始まるように-90度回す
      final angle = -math.pi / 2 + 2 * math.pi * i / n;
      return center +
          Offset(math.cos(angle), math.sin(angle)) * (radius * ratio);
    }

    final grid = Paint()
      ..color = gridColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;

    // 同心の多角形(4段)と軸
    for (final step in [0.25, 0.5, 0.75, 1.0]) {
      final path = Path();
      for (var i = 0; i < n; i++) {
        final p = pointAt(i, step);
        i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      path.close();
      canvas.drawPath(path, grid);
    }
    for (var i = 0; i < n; i++) {
      canvas.drawLine(center, pointAt(i, 1), grid);
    }

    // 値
    final path = Path();
    for (var i = 0; i < n; i++) {
      final ratio = (values.length > i ? values[i] : 0) / top;
      final p = pointAt(i, ratio.clamp(0.0, 1.0).toDouble());
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    path.close();
    canvas.drawPath(path, Paint()..color = fillColor);
    canvas.drawPath(
      path,
      Paint()
        ..color = lineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );

    // ラベル
    for (var i = 0; i < n; i++) {
      final tp = TextPainter(
        text: TextSpan(
          text: labels[i],
          style: TextStyle(fontSize: 10, color: labelColor),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final p = pointAt(i, 1.0);
      // 中心から見て外側へ、ラベルの大きさぶん押し出す
      final dir = (p - center);
      final len = dir.distance == 0 ? 1 : dir.distance;
      final offset = p + dir * (14 / len);
      tp.paint(
        canvas,
        Offset(offset.dx - tp.width / 2, offset.dy - tp.height / 2),
      );
    }
  }

  @override
  bool shouldRepaint(_RadarPainter old) =>
      old.values != values || old.labels != labels;
}
