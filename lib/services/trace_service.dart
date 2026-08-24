import 'dart:convert';
import 'dart:math' as math;

import '../database/local_database.dart';

/// 軌跡アニメーションの一点。
///
/// 近い場所・近い時間の記録はまとめて1点にするので、[end] と [count] を持つ。
class TracePoint {
  const TracePoint({
    required this.at,
    required this.end,
    required this.latitude,
    required this.longitude,
    this.count = 1,
    this.label,
    this.fromApp = true,
  });

  final DateTime at;

  /// まとめた区間の終わり。1件だけなら [at] と同じ
  final DateTime end;
  final double latitude;
  final double longitude;

  /// まとめた件数
  final int count;

  /// 地点の名前(店名やマイプレイス名)。無ければ null
  final String? label;

  /// アプリの記録から来たか(false は読み込んだJSON由来)
  final bool fromApp;
}

/// まとめの既定値。アプリ内のグルーピング(同じ場所・近い時間)と揃えてある
const _defaultRadiusM = 50.0;
const _defaultGap = Duration(hours: 2);

class TraceService {
  TraceService._();

  /// 食事の記録から軌跡を組み立てる。位置を持たない記録は落とす。
  static Future<List<TracePoint>> fromMealLogs() async {
    final logs = await LocalDatabase.getMealLogs();
    final points = <TracePoint>[];
    for (final log in logs) {
      final lat = log.latitude;
      final lng = log.longitude;
      if (lat == null || lng == null) continue;
      points.add(TracePoint(
        at: log.eatenAt,
        end: log.eatenAt,
        latitude: lat,
        longitude: lng,
      ));
    }
    return mergePoints(points);
  }

  /// 近い場所・近い時間の点をまとめる。入力の順序は問わない。
  static List<TracePoint> mergePoints(
    List<TracePoint> points, {
    double radiusM = _defaultRadiusM,
    Duration gap = _defaultGap,
  }) {
    final sorted = [...points]..sort((a, b) => a.at.compareTo(b.at));
    final out = <TracePoint>[];
    for (final p in sorted) {
      final c = out.isEmpty ? null : out.last;
      if (c != null &&
          p.at.difference(c.end) <= gap &&
          distanceM(c.latitude, c.longitude, p.latitude, p.longitude) <=
              radiusM) {
        // 重心を逐次更新する(全部持ってから平均を取らずに済む)
        final n = c.count + 1;
        out[out.length - 1] = TracePoint(
          at: c.at,
          end: p.at,
          latitude: c.latitude + (p.latitude - c.latitude) / n,
          longitude: c.longitude + (p.longitude - c.longitude) / n,
          count: n,
          label: c.label ?? p.label,
          fromApp: c.fromApp,
        );
      } else {
        out.add(p);
      }
    }
    return out;
  }

  /// 2点間の距離(m)。数十km程度の範囲で使うので平面近似で足りる
  static double distanceM(
      double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0;
    const rad = math.pi / 180;
    final x = (lng2 - lng1) * rad * math.cos((lat1 + lat2) / 2 * rad);
    final y = (lat2 - lat1) * rad;
    return math.sqrt(x * x + y * y) * r;
  }

  /// tools/trace-extract.html が書き出すJSON(meshi-trace v1)を読む。
  ///
  /// 形式が違うときは [FormatException] を投げる。
  static List<TracePoint> parseTraceJson(String source) {
    final dynamic decoded = jsonDecode(source);
    final list = decoded is List
        ? decoded
        : (decoded is Map<String, dynamic> ? decoded['points'] : null);
    if (list is! List) {
      throw const FormatException('points がありません');
    }

    final points = <TracePoint>[];
    for (final dynamic item in list) {
      if (item is! Map) continue;
      final at = _parseTime(item['t']);
      final lat = _parseNum(item['lat']);
      final lng = _parseNum(item['lng']);
      if (at == null || lat == null || lng == null) continue;
      points.add(TracePoint(
        at: at,
        end: _parseTime(item['end']) ?? at,
        latitude: lat,
        longitude: lng,
        count: (item['count'] as num?)?.toInt() ?? 1,
        label: item['label'] as String?,
        fromApp: false,
      ));
    }
    if (points.isEmpty) {
      throw const FormatException('日時と位置のそろった地点がありません');
    }
    points.sort((a, b) => a.at.compareTo(b.at));
    return points;
  }

  static DateTime? _parseTime(dynamic value) {
    if (value is num) {
      return DateTime.fromMillisecondsSinceEpoch(value.toInt());
    }
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  static double? _parseNum(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }
}
