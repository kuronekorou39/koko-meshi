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

  group('移動距離', () {
    final base = DateTime(2026, 8, 1, 12);
    // 緯度1度ぶん(約111km)動く2地点
    final points = [
      TracePoint(at: base, end: base, latitude: 35, longitude: 139),
      TracePoint(
        at: base.add(const Duration(hours: 1)),
        end: base.add(const Duration(hours: 1)),
        latitude: 36,
        longitude: 139,
      ),
    ];

    test('着いた時点で全区間ぶんの距離になる', () {
      final c = TraceService.cursorAt(
        points,
        base.add(const Duration(hours: 1)),
      );
      expect(c.traveledMeters, closeTo(111000, 1000));
    });

    test('移動の途中では距離も途中まで積まれる', () {
      final c = TraceService.cursorAt(
        points,
        base.add(const Duration(minutes: 30)),
      );
      expect(c.traveledMeters, closeTo(55500, 1000));
    });

    test('出発前は0', () {
      final c = TraceService.cursorAt(points, base);
      expect(c.traveledMeters, 0);
    });

    test('totalDistanceMは全区間の合計', () {
      expect(TraceService.totalDistanceM(points), closeTo(111000, 1000));
      expect(TraceService.totalDistanceM([points.first]), 0);
      expect(TraceService.totalDistanceM([]), 0);
    });

    test('表示は桁に応じて単位が変わる', () {
      expect(TraceService.formatDistance(320), '320 m');
      expect(TraceService.formatDistance(1500), '1.5 km');
      expect(TraceService.formatDistance(111000), '111 km');
    });

    test('向かっている区間の番号が取れる', () {
      final c = TraceService.cursorAt(
        points,
        base.add(const Duration(minutes: 30)),
      );
      expect(c.legIndex, 0);
      // 最後の地点に着いたら、もう向かう先はない
      final done = TraceService.cursorAt(
        points,
        base.add(const Duration(hours: 2)),
      );
      expect(done.legIndex, -1);
    });
  });

  group('TraceTimeline', () {
    final base = DateTime(2026, 8, 1, 12);

    /// 12:00に着いて12:10までいる → 10分で次へ移動 → そこに8時間居座る
    final points = [
      TracePoint(
        at: base,
        end: base.add(const Duration(minutes: 10)),
        latitude: 35,
        longitude: 139,
      ),
      TracePoint(
        at: base.add(const Duration(minutes: 20)),
        end: base.add(const Duration(hours: 8, minutes: 20)),
        latitude: 36,
        longitude: 140,
      ),
    ];

    test('先頭と末尾の時刻は実際の範囲に一致する', () {
      final t = TraceTimeline.build(points);
      expect(t.timeAt(0), base);
      expect(t.timeAt(1), base.add(const Duration(hours: 8, minutes: 20)));
    });

    test('長い停滞は詰められ、動きのある区間に時間が回る', () {
      final t = TraceTimeline.build(points, cap: const Duration(minutes: 20));
      // 重みは 10分(滞在) + 10分(移動) + 20分(8時間の滞在を詰めたもの) = 40分
      // 前半半分(20分ぶん)で、移動を終えて次の地点に着いているはず
      expect(t.timeAt(0.5), base.add(const Duration(minutes: 20)));
    });

    test('capがnullなら実時間のまま進む', () {
      final t = TraceTimeline.build(points, cap: null);
      // 全体8時間20分の半分 → 16:10。長い停滞の途中で止まっている
      expect(t.timeAt(0.5), base.add(const Duration(hours: 4, minutes: 10)));
    });

    test('詰めても時刻が巻き戻ったり飛び越えたりしない', () {
      final t = TraceTimeline.build(points);
      var prev = t.timeAt(0);
      for (var i = 1; i <= 50; i++) {
        final now = t.timeAt(i / 50);
        expect(now.isBefore(prev), isFalse, reason: '$i 番目で巻き戻った');
        expect(now.isAfter(t.end), isFalse, reason: '$i 番目で範囲を超えた');
        prev = now;
      }
    });

    test('範囲の外を渡しても端で止まる', () {
      final t = TraceTimeline.build(points);
      expect(t.timeAt(-1), base);
      expect(t.timeAt(5), t.end);
    });

    test('1地点だけ・時間の幅が無くても落ちない', () {
      final single = [
        TracePoint(at: base, end: base, latitude: 35, longitude: 139),
      ];
      final t = TraceTimeline.build(single);
      expect(t.timeAt(0), base);
      expect(t.timeAt(1), base);
    });

    test('空の入力は例外', () {
      expect(
        () => TraceTimeline.build([]),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('weightOfRangeは再生時間に占める割合を返す', () {
      final t = TraceTimeline.build(points, cap: const Duration(minutes: 20));
      // 重みは 10分 + 10分(移動) + 20分(詰めた滞在) = 40分ぶん
      final moving = t.weightOfRange(
        base.add(const Duration(minutes: 10)),
        base.add(const Duration(minutes: 20)),
      );
      expect(moving, closeTo(0.25, 0.001), reason: '移動の10分は全体の1/4');

      // 全体を渡せば1になる
      expect(t.weightOfRange(t.start, t.end), closeTo(1.0, 0.001));
      // 逆向きや同時刻は0
      expect(t.weightOfRange(t.end, t.start), 0);
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
