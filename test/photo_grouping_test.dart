import 'package:flutter_test/flutter_test.dart';
import 'package:koko_meshi/services/photo_grouping.dart';

/// 基準時刻。ここからの分ずれで並べる
final base = DateTime(2026, 7, 29, 12, 0);

GroupableShot shot({int minutes = 0, double? lat, double? lng}) => GroupableShot(
      shotAt: base.add(Duration(minutes: minutes)),
      latitude: lat,
      longitude: lng,
    );

const undated = GroupableShot();

void main() {
  test('空なら空', () {
    expect(groupShots([]), isEmpty);
  });

  test('1枚なら1組', () {
    expect(groupShots([shot()]), [[0]]);
  });

  group('時間で分ける（閾値2時間）', () {
    test('2時間以内は同じ組', () {
      final groups = groupShots([shot(), shot(minutes: 119)]);
      expect(groups, [[0, 1]]);
    });

    test('2時間を超えたら別の組', () {
      final groups = groupShots([shot(), shot(minutes: 121)]);
      expect(groups, [[0], [1]]);
    });

    test('ちょうど2時間は同じ組', () {
      expect(groupShots([shot(), shot(minutes: 120)]), [[0, 1]]);
    });

    test('隣どうしで見るので、少しずつずれた連続は1組にまとまる', () {
      // 端と端は5時間離れるが、隣は90分ずつなので同じ食事の流れとみなす
      final groups = groupShots([
        shot(),
        shot(minutes: 90),
        shot(minutes: 180),
        shot(minutes: 270),
      ]);
      expect(groups, [[0, 1, 2, 3]]);
    });

    test('選択順がばらばらでも時刻順に組む', () {
      final groups = groupShots([
        shot(minutes: 300), // 夕方
        shot(),             // 昼
        shot(minutes: 30),  // 昼
      ]);
      expect(groups, [[1, 2], [0]]);
    });
  });

  group('場所で分ける（閾値50m）', () {
    // 緯度0.001度 ≒ 111m
    test('近ければ同じ組', () {
      final groups = groupShots([
        shot(lat: 35.4658, lng: 139.6222),
        shot(minutes: 10, lat: 35.46583, lng: 139.6222), // 約3m
      ]);
      expect(groups, [[0, 1]]);
    });

    test('50mより離れていれば、時間が近くても別の組', () {
      final groups = groupShots([
        shot(lat: 35.4658, lng: 139.6222),
        shot(minutes: 10, lat: 35.4668, lng: 139.6222), // 約111m
      ]);
      expect(groups, [[0], [1]]);
    });

    test('片方にGPSが無ければ時間の判定に任せる', () {
      final groups = groupShots([
        shot(lat: 35.4658, lng: 139.6222),
        shot(minutes: 10), // GPSなし
      ]);
      expect(groups, [[0, 1]], reason: 'GPSが無い写真は多いので分けない');
    });
  });

  group('撮影日時が無い写真', () {
    test('全部日時なしなら1組', () {
      expect(groupShots([undated, undated]), [[0, 1]]);
    });

    test('日時ありと混ざったら、日時なしはまとめて別の組', () {
      final groups = groupShots([undated, shot(), shot(minutes: 10)]);
      expect(groups, [[1, 2], [0]]);
    });

    test('日時なしは末尾の組になる', () {
      final groups = groupShots([
        shot(),
        undated,
        shot(minutes: 300),
      ]);
      expect(groups, [[0], [2], [1]]);
    });
  });

  test('すべての写真がどこかの組に1度だけ入る', () {
    final shots = [
      shot(),
      shot(minutes: 30),
      shot(minutes: 400),
      undated,
      shot(minutes: 401, lat: 35.4658, lng: 139.6222),
    ];
    final flat = groupShots(shots).expand((g) => g).toList()..sort();
    expect(flat, [0, 1, 2, 3, 4]);
  });
}
