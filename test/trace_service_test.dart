import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:koko_meshi/services/trace_service.dart';

TracePoint pt(DateTime at, double lat, double lng) =>
    TracePoint(at: at, end: at, latitude: lat, longitude: lng);

void main() {
  group('mergePoints', () {
    test('同じ場所・近い時間はまとめて件数を数える', () {
      final base = DateTime(2026, 8, 1, 12);
      final merged = TraceService.mergePoints([
        pt(base, 35.68120, 139.76710),
        pt(base.add(const Duration(minutes: 5)), 35.68125, 139.76715),
        pt(base.add(const Duration(minutes: 30)), 35.68118, 139.76705),
      ]);

      expect(merged.length, 1);
      expect(merged.first.count, 3);
      expect(merged.first.at, base);
      expect(merged.first.end, base.add(const Duration(minutes: 30)));
      // まとめた点の座標は重心に寄る
      expect(merged.first.latitude, closeTo(35.68121, 0.0001));
    });

    test('離れた場所は時間が近くても分ける', () {
      final base = DateTime(2026, 8, 1, 12);
      final merged = TraceService.mergePoints([
        pt(base, 35.6812, 139.7671),
        pt(base.add(const Duration(minutes: 10)), 35.6900, 139.7000),
      ]);
      expect(merged.length, 2);
    });

    test('同じ場所でも時間が空けば分ける', () {
      final base = DateTime(2026, 8, 1, 12);
      final merged = TraceService.mergePoints([
        pt(base, 35.6812, 139.7671),
        pt(base.add(const Duration(hours: 5)), 35.6812, 139.7671),
      ]);
      expect(merged.length, 2);
    });

    test('入力が順不同でも時刻順にまとまる', () {
      final base = DateTime(2026, 8, 1, 12);
      final merged = TraceService.mergePoints([
        pt(base.add(const Duration(hours: 6)), 35.0, 135.0),
        pt(base, 35.6812, 139.7671),
        pt(base.add(const Duration(minutes: 20)), 35.6812, 139.7671),
      ]);
      expect(merged.length, 2);
      expect(merged.first.at, base);
      expect(merged.first.count, 2);
      expect(merged.last.at, base.add(const Duration(hours: 6)));
    });

    test('まとめの条件は呼び出し側で変えられる', () {
      final base = DateTime(2026, 8, 1, 12);
      final points = [
        pt(base, 35.6812, 139.7671),
        // 既定の50mより遠く、200mより近い
        pt(base.add(const Duration(minutes: 10)), 35.6825, 139.7671),
      ];
      expect(TraceService.mergePoints(points).length, 2);
      expect(
        TraceService.mergePoints(points, radiusM: 200).length,
        1,
      );
    });

    test('空の入力は空を返す', () {
      expect(TraceService.mergePoints([]), isEmpty);
    });
  });

  group('cursorAt', () {
    final base = DateTime(2026, 8, 1, 12);
    // 12:00に(35,139)を出て、13:00に(36,140)へ着く2地点
    final points = [
      TracePoint(at: base, end: base, latitude: 35, longitude: 139),
      TracePoint(
        at: base.add(const Duration(hours: 1)),
        end: base.add(const Duration(hours: 1)),
        latitude: 36,
        longitude: 140,
      ),
    ];

    test('始まった直後は最初の地点にいて、動いていない', () {
      final c = TraceService.cursorAt(points, base);
      expect(c.visitedCount, 1);
      expect(c.head.latitude, 35);
      expect(c.moving, isFalse);
      expect(c.path.length, 1, reason: 'まだ線は伸びていない');
    });

    test('区間の途中では座標が補間され、移動中になる', () {
      final c = TraceService.cursorAt(
        points,
        base.add(const Duration(minutes: 30)),
      );
      // 半分まで来ているので緯度経度も中間
      expect(c.head.latitude, closeTo(35.5, 0.001));
      expect(c.head.longitude, closeTo(139.5, 0.001));
      expect(c.moving, isTrue);
      expect(c.visitedCount, 1, reason: 'まだ次の地点には着いていない');
      expect(c.path.last.latitude, closeTo(35.5, 0.001));
    });

    test('次の地点に着いたら移動が止まり、線が繋がる', () {
      final c = TraceService.cursorAt(
        points,
        base.add(const Duration(hours: 1)),
      );
      expect(c.visitedCount, 2);
      expect(c.head.latitude, 36);
      expect(c.moving, isFalse);
      expect(c.path.length, 2);
    });

    test('滞在している間は先頭が動かない', () {
      final staying = [
        TracePoint(
          at: base,
          end: base.add(const Duration(minutes: 40)),
          latitude: 35,
          longitude: 139,
          count: 3,
        ),
        TracePoint(
          at: base.add(const Duration(hours: 1)),
          end: base.add(const Duration(hours: 1)),
          latitude: 36,
          longitude: 140,
        ),
      ];
      // 滞在の終わり(12:40)より前なので、まだ出発していない
      final c = TraceService.cursorAt(
        staying,
        base.add(const Duration(minutes: 20)),
      );
      expect(c.head.latitude, 35);
      expect(c.moving, isFalse);
    });

    test('最後の地点を過ぎても、そこから先へは進まない', () {
      final c = TraceService.cursorAt(
        points,
        base.add(const Duration(days: 1)),
      );
      expect(c.visitedCount, 2);
      expect(c.head.latitude, 36);
      expect(c.moving, isFalse);
    });

    test('1地点しかなければ、その場に留まる', () {
      final c = TraceService.cursorAt([points.first], base);
      expect(c.visitedCount, 1);
      expect(c.moving, isFalse);
      expect(c.path.length, 1);
    });

    test('空の入力は例外', () {
      expect(
        () => TraceService.cursorAt([], base),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('distanceM', () {
    test('緯度1度は約111km', () {
      final d = TraceService.distanceM(35.0, 139.0, 36.0, 139.0);
      expect(d, closeTo(111000, 1000));
    });

    test('同じ点は0', () {
      expect(TraceService.distanceM(35.5, 139.5, 35.5, 139.5), 0);
    });
  });

  group('parseTraceJson', () {
    String json(Object value) => jsonEncode(value);

    test('抽出ページの形式を読める', () {
      final points = TraceService.parseTraceJson(json({
        'format': 'meshi-trace',
        'version': 1,
        'points': [
          {
            't': '2026-08-15T13:25:07',
            'end': '2026-08-15T13:55:00',
            'lat': 35.515205,
            'lng': 139.68713,
            'count': 3,
            'label': '鶴見',
          },
        ],
      }));

      expect(points.length, 1);
      final p = points.first;
      expect(p.at, DateTime(2026, 8, 15, 13, 25, 7));
      expect(p.end, DateTime(2026, 8, 15, 13, 55));
      expect(p.latitude, closeTo(35.515205, 1e-6));
      expect(p.count, 3);
      expect(p.label, '鶴見');
      expect(p.fromApp, isFalse, reason: '読み込んだものはアプリ由来と区別する');
    });

    test('配列だけのJSONも読める', () {
      final points = TraceService.parseTraceJson(json([
        {'t': '2026-08-15T13:25:07', 'lat': 35.5, 'lng': 139.6},
      ]));
      expect(points.length, 1);
      expect(points.first.end, points.first.at, reason: 'endが無ければtと同じ');
    });

    test('日時がミリ秒の数値でも読める', () {
      final ms = DateTime(2026, 8, 15, 13).millisecondsSinceEpoch;
      final points = TraceService.parseTraceJson(json([
        {'t': ms, 'lat': 35.5, 'lng': 139.6},
      ]));
      expect(points.first.at, DateTime(2026, 8, 15, 13));
    });

    test('壊れた要素は飛ばして、読めたものだけ返す', () {
      final points = TraceService.parseTraceJson(json([
        {'t': 'not-a-date', 'lat': 35.5, 'lng': 139.6},
        {'t': '2026-08-15T13:00:00', 'lat': null, 'lng': 139.6},
        {'t': '2026-08-15T14:00:00', 'lat': 35.5, 'lng': 139.6},
      ]));
      expect(points.length, 1);
      expect(points.first.at, DateTime(2026, 8, 15, 14));
    });

    test('時刻順に並べて返す', () {
      final points = TraceService.parseTraceJson(json([
        {'t': '2026-08-15T18:00:00', 'lat': 35.5, 'lng': 139.6},
        {'t': '2026-08-15T09:00:00', 'lat': 35.4, 'lng': 139.5},
      ]));
      expect(points.first.at.hour, 9);
      expect(points.last.at.hour, 18);
    });

    test('pointsが無い形式は弾く', () {
      expect(
        () => TraceService.parseTraceJson(json({'foo': 'bar'})),
        throwsA(isA<FormatException>()),
      );
    });

    test('読める地点が1つも無ければ弾く', () {
      expect(
        () => TraceService.parseTraceJson(json([
          {'t': 'x', 'lat': 'y', 'lng': 'z'},
        ])),
        throwsA(isA<FormatException>()),
      );
    });

    test('JSONとして壊れていれば例外', () {
      expect(
        () => TraceService.parseTraceJson('{ broken'),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
