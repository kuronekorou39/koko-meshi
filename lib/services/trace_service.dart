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

/// 緯度経度の組。地図パッケージに依存せずに扱うための最小の型
class TraceLatLng {
  const TraceLatLng(this.latitude, this.longitude);
  final double latitude;
  final double longitude;
}

/// 緯度経度の矩形
class TraceBounds {
  const TraceBounds({
    required this.south,
    required this.west,
    required this.north,
    required this.east,
  });

  final double south;
  final double west;
  final double north;
  final double east;

  bool contains(TraceBounds other) =>
      south <= other.south &&
      north >= other.north &&
      west <= other.west &&
      east >= other.east;
}

/// ある時刻における、通過済みの経路と先頭の位置。
class TraceCursor {
  const TraceCursor({
    required this.path,
    required this.head,
    required this.visitedCount,
    required this.moving,
    required this.traveledMeters,
    required this.legIndex,
  });

  /// 出発点から先頭までの線
  final List<TraceLatLng> path;

  /// いまいる位置。地点の間なら補間された座標
  final TraceLatLng head;

  /// 着いた地点の数
  final int visitedCount;

  /// 地点の間を移動している最中か
  final bool moving;

  /// ここまでに動いた距離(m)
  final double traveledMeters;

  /// いま向かっている区間の番号(点[legIndex] → 点[legIndex+1])。
  /// どこにも向かっていなければ -1
  final int legIndex;
}

/// まとめの既定値。アプリ内のグルーピング(同じ場所・近い時間)と揃えてある
const _defaultRadiusM = 50.0;
const _defaultGap = Duration(hours: 2);

/// 動きのない時間をどこまで見せるか。これを超えた分は再生上で詰める
const _defaultStillCap = Duration(minutes: 20);

/// 再生の進み具合を実際の時刻に対応させる時間軸。
///
/// 実時間のまま流すと、寝ている時間や職場にいる時間で何も動かない絵が延々と
/// 続く。動きの無い区間は頭打ちにして、動いているところに時間を回す。
class TraceTimeline {
  TraceTimeline._(this._spans, this._totalWeight, this.start, this.end);

  final List<_TimeSpan> _spans;
  final double _totalWeight;
  final DateTime start;
  final DateTime end;

  /// [cap] を渡すと、それより長い停滞は再生上 [cap] の長さに詰める。
  /// null なら実時間のまま流す。
  factory TraceTimeline.build(
    List<TracePoint> points, {
    Duration? cap = _defaultStillCap,
  }) {
    if (points.isEmpty) throw ArgumentError('points が空です');

    final spans = <_TimeSpan>[];
    var total = 0.0;

    void add(DateTime from, DateTime to) {
      final real = to.difference(from).inMilliseconds;
      if (real <= 0) return;
      // 動きの無い区間だけを詰める。移動そのものは実時間の比を保つ
      final weight = cap == null
          ? real.toDouble()
          : real.clamp(0, cap.inMilliseconds).toDouble();
      spans.add(_TimeSpan(from: from, to: to, weight: weight));
      total += weight;
    }

    for (var i = 0; i < points.length; i++) {
      final p = points[i];
      add(p.at, p.end); // その場に留まっている間
      if (i + 1 < points.length) {
        add(p.end, points[i + 1].at); // 次の地点へ向かう間
      }
    }

    return TraceTimeline._(
      spans,
      total,
      points.first.at,
      points.last.end.isAfter(points.last.at) ? points.last.end : points.last.at,
    );
  }

  /// 実時間の [from]〜[to] が、再生時間全体のどれだけを占めるか(0..1)。
  ///
  /// カメラの動きを再生に合わせるために使う。詰められた停滞は短く出る。
  double weightOfRange(DateTime from, DateTime to) {
    if (_totalWeight <= 0 || !to.isAfter(from)) return 0;
    var sum = 0.0;
    for (final span in _spans) {
      final start = span.from.isAfter(from) ? span.from : from;
      final endAt = span.to.isBefore(to) ? span.to : to;
      if (!endAt.isAfter(start)) continue;
      final realMs = span.to.difference(span.from).inMilliseconds;
      if (realMs <= 0) continue;
      // 区間の一部だけが重なる場合は、その割合ぶんの重みを取る
      sum += span.weight * (endAt.difference(start).inMilliseconds / realMs);
    }
    return sum / _totalWeight;
  }

  /// 再生位置(0..1)に対応する実際の時刻
  DateTime timeAt(double progress) {
    if (_spans.isEmpty || _totalWeight <= 0) return start;
    final target = (progress.clamp(0.0, 1.0)) * _totalWeight;

    var acc = 0.0;
    for (final span in _spans) {
      if (target <= acc + span.weight) {
        final f = span.weight <= 0 ? 0.0 : (target - acc) / span.weight;
        final realMs = span.to.difference(span.from).inMilliseconds;
        return span.from.add(Duration(milliseconds: (realMs * f).round()));
      }
      acc += span.weight;
    }
    return end;
  }
}

class _TimeSpan {
  const _TimeSpan({required this.from, required this.to, required this.weight});
  final DateTime from;
  final DateTime to;

  /// 再生時間の取り分
  final double weight;
}

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

  /// [now] の時点で、どこまで進んでいるかを求める。
  ///
  /// 地点の間は時間で補間する。着いた順に点を出すだけだと瞬間移動に見えて
  /// 動きとして読めないので、線も先頭も少しずつ伸びるようにしている。
  /// 滞在中(その地点の [TracePoint.at] から [TracePoint.end] の間)は動かない。
  static TraceCursor cursorAt(List<TracePoint> points, DateTime now) {
    if (points.isEmpty) {
      throw ArgumentError('points が空です');
    }

    final first = TraceLatLng(points.first.latitude, points.first.longitude);
    final path = <TraceLatLng>[first];
    var head = first;
    var visited = 0;
    var moving = false;
    var traveled = 0.0;
    var leg = -1;

    for (var i = 0; i < points.length; i++) {
      final p = points[i];
      if (p.at.isAfter(now)) break;
      visited = i + 1;
      final here = TraceLatLng(p.latitude, p.longitude);
      if (i > 0) {
        traveled += distanceM(
          path.last.latitude,
          path.last.longitude,
          here.latitude,
          here.longitude,
        );
        path.add(here);
      }
      head = here;

      final next = i + 1 < points.length ? points[i + 1] : null;
      if (next != null && !next.at.isAfter(now)) continue;

      // ここが最後に着いた地点。次へ発つ時刻を過ぎていれば移動の途中
      if (next != null) {
        leg = i;
        if (now.isAfter(p.end)) {
          final legMs = next.at.difference(p.end).inMilliseconds;
          final f = legMs <= 0
              ? 1.0
              : (now.difference(p.end).inMilliseconds / legMs).clamp(0.0, 1.0);
          if (f > 0) {
            head = TraceLatLng(
              p.latitude + (next.latitude - p.latitude) * f,
              p.longitude + (next.longitude - p.longitude) * f,
            );
            traveled += distanceM(
              path.last.latitude,
              path.last.longitude,
              head.latitude,
              head.longitude,
            );
            path.add(head);
            moving = true;
          }
        }
      }
      break;
    }

    return TraceCursor(
      path: path,
      head: head,
      visitedCount: visited,
      moving: moving,
      traveledMeters: traveled,
      legIndex: leg,
    );
  }

  /// いまいる場所と、[until] までに通る地点が収まる範囲。
  ///
  /// 目の前の一区間だけを映すと、動くたびに地図が追いかけることになって
  /// 落ち着かないうえ、カメラが追いつかず先頭が画面から出てしまう。
  /// 少し先まで含めて引いておけば、しばらく動かさずに済む。
  ///
  /// [minSpan] は最低限確保する緯度経度の幅。近所だけのときに寄りすぎない。
  static TraceBounds boundsAhead(
    List<TracePoint> points,
    TraceLatLng head,
    DateTime from,
    DateTime until, {
    int maxPoints = 24,
    double minSpan = 0.014,
  }) {
    var south = head.latitude, north = head.latitude;
    var west = head.longitude, east = head.longitude;

    var taken = 0;
    for (final p in points) {
      if (p.at.isAfter(until)) break;
      // 通り過ぎた地点には引っぱられない。これから行く先だけを入れる
      if (p.at.isBefore(from)) continue;
      if (taken >= maxPoints) break;
      taken++;
      if (p.latitude < south) south = p.latitude;
      if (p.latitude > north) north = p.latitude;
      if (p.longitude < west) west = p.longitude;
      if (p.longitude > east) east = p.longitude;
    }

    final padLat = ((minSpan - (north - south)) / 2).clamp(0.0, minSpan);
    final padLng = ((minSpan - (east - west)) / 2).clamp(0.0, minSpan);
    return TraceBounds(
      south: south - padLat,
      west: west - padLng,
      north: north + padLat,
      east: east + padLng,
    );
  }

  /// 全区間を足した移動距離(m)
  static double totalDistanceM(List<TracePoint> points) {
    var total = 0.0;
    for (var i = 1; i < points.length; i++) {
      total += distanceM(
        points[i - 1].latitude,
        points[i - 1].longitude,
        points[i].latitude,
        points[i].longitude,
      );
    }
    return total;
  }

  /// 距離の表示文字列。1km未満はm、それ以上はkm
  static String formatDistance(double meters) {
    if (meters < 1000) return '${meters.round()} m';
    if (meters < 10000) return '${(meters / 1000).toStringAsFixed(1)} km';
    return '${(meters / 1000).round()} km';
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
