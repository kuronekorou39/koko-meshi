import 'package:flutter_test/flutter_test.dart';
import 'package:koko_meshi/models/meal_log.dart';
import 'package:koko_meshi/models/meal_photo.dart';
import 'package:koko_meshi/models/meal_type.dart';
import 'package:koko_meshi/services/meal_stats.dart';

MealLog _log(
  String id,
  DateTime eatenAt, {
  MealType type = MealType.unset,
  int? totalPrice,
}) =>
    MealLog(
      id: id,
      mealType: type,
      eatenAt: eatenAt,
      totalPrice: totalPrice,
      createdAt: eatenAt,
    );

MealPhoto _photo(
  String id,
  String logId, {
  int? aiPrice,
  int? aiCalories,
  int? userPrice,
  int? userCalories,
  String? genre,
}) =>
    MealPhoto(
      id: id,
      mealLogId: logId,
      localPath: '/tmp/$id.jpg',
      aiEstimatedPrice: aiPrice,
      aiEstimatedCalories: aiCalories,
      aiCuisineGenre: genre,
      userCorrectedPrice: userPrice,
      userCorrectedCalories: userCalories,
      shotAt: DateTime(2026, 7, 1),
      createdAt: DateTime(2026, 7, 1),
    );

void main() {
  group('MealStats.priceOf', () {
    test('手入力の合計があればそれを使う', () {
      final log = _log('l1', DateTime(2026, 7, 1), totalPrice: 1500);
      final photos = [_photo('p1', 'l1', aiPrice: 800)];
      expect(MealStats.priceOf(log, photos), 1500);
    });

    test('手入力が無ければ写真の推定を積む', () {
      final log = _log('l1', DateTime(2026, 7, 1));
      final photos = [
        _photo('p1', 'l1', aiPrice: 800),
        _photo('p2', 'l1', aiPrice: 250),
      ];
      expect(MealStats.priceOf(log, photos), 1050);
    });

    test('ユーザー修正値が写真の推定より優先される', () {
      final log = _log('l1', DateTime(2026, 7, 1));
      final photos = [_photo('p1', 'l1', aiPrice: 800, userPrice: 600)];
      expect(MealStats.priceOf(log, photos), 600);
    });

    test('どこにも金額が無ければ null(0円として数えない)', () {
      final log = _log('l1', DateTime(2026, 7, 1));
      expect(MealStats.priceOf(log, [_photo('p1', 'l1')]), isNull);
      expect(MealStats.priceOf(log, const []), isNull);
    });
  });

  group('MealStats.caloriesOf', () {
    test('写真ごとの推定を積む', () {
      final photos = [
        _photo('p1', 'l1', aiCalories: 500),
        _photo('p2', 'l1', aiCalories: 250),
      ];
      expect(MealStats.caloriesOf(photos), 750);
    });

    test('ユーザー修正値を優先する', () {
      final photos = [_photo('p1', 'l1', aiCalories: 500, userCalories: 400)];
      expect(MealStats.caloriesOf(photos), 400);
    });

    test('値が無ければ null', () {
      expect(MealStats.caloriesOf([_photo('p1', 'l1')]), isNull);
    });
  });

  group('MealStats.forMonth', () {
    final logs = [
      _log('l1', DateTime(2026, 7, 3, 12), type: MealType.eatingOut),
      _log('l2', DateTime(2026, 7, 3, 19), type: MealType.homeCooking),
      _log('l3', DateTime(2026, 7, 10, 12), type: MealType.eatingOut),
      // 別の月。集計に混ざってはいけない
      _log('l4', DateTime(2026, 8, 1, 12), type: MealType.eatingOut),
    ];
    final photos = MealStats.groupPhotos([
      _photo('p1', 'l1', aiPrice: 900, aiCalories: 600),
      _photo('p2', 'l2', aiPrice: 300, aiCalories: 400),
      _photo('p3', 'l3', aiPrice: 1200, aiCalories: 800),
      _photo('p4', 'l4', aiPrice: 9999, aiCalories: 9999),
    ]);

    test('その月だけを合計する', () {
      final s = MealStats.forMonth(DateTime(2026, 7), logs, photos);
      expect(s.totalCalories, 1800);
      expect(s.totalPrice, 2400);
      expect(s.logCount, 3);
    });

    test('同じ日に複数回食べても記録日数は1', () {
      final s = MealStats.forMonth(DateTime(2026, 7), logs, photos);
      expect(s.recordedDays, 2); // 7/3 と 7/10
    });

    test('外食の回数を数える', () {
      final s = MealStats.forMonth(DateTime(2026, 7), logs, photos);
      expect(s.eatingOutCount, 2);
    });

    test('日別カロリーは同じ日ぶんを足し合わせる', () {
      final s = MealStats.forMonth(DateTime(2026, 7), logs, photos);
      expect(s.caloriesByDay[DateTime(2026, 7, 3)], 1000);
      expect(s.caloriesByDay[DateTime(2026, 7, 10)], 800);
      expect(s.caloriesByDay[DateTime(2026, 7, 4)], isNull);
    });

    test('記録がある日の平均カロリー', () {
      final s = MealStats.forMonth(DateTime(2026, 7), logs, photos);
      expect(s.dailyAverageCalories, 900); // 1800 / 2日
    });

    test('記録が無い月は空になる', () {
      final s = MealStats.forMonth(DateTime(2026, 1), logs, photos);
      expect(s.isEmpty, isTrue);
      expect(s.totalCalories, 0);
      expect(s.dailyAverageCalories, isNull);
    });
  });

  group('GenreGroup', () {
    test('AIの細かいジャンルをまとめ先へ振り分ける', () {
      expect(GenreGroup.of('寿司'), GenreGroup.japanese);
      expect(GenreGroup.of('丼・定食'), GenreGroup.japanese);
      expect(GenreGroup.of('イタリアン'), GenreGroup.western);
      expect(GenreGroup.of('韓国料理'), GenreGroup.asian);
      expect(GenreGroup.of('ラーメン'), GenreGroup.noodle);
      expect(GenreGroup.of('パン・サンドイッチ'), GenreGroup.light);
      expect(GenreGroup.of('カフェ・スイーツ'), GenreGroup.sweets);
    });

    test('料理以外(「写真」)と未知の値はその他', () {
      expect(GenreGroup.of('写真'), GenreGroup.other);
      expect(GenreGroup.of(null), GenreGroup.other);
      expect(GenreGroup.of('存在しないジャンル'), GenreGroup.other);
    });

    test('チャートの軸に「その他」は含めない', () {
      expect(GenreGroup.axes.contains(GenreGroup.other), isFalse);
      expect(GenreGroup.axes.length, GenreGroup.values.length - 1);
    });
  });

  group('forRange', () {
    test('期間の境界は開始を含み終わりを含まない', () {
      final logs = [
        _log('a', DateTime(2026, 7, 20, 0, 0)), // 開始ちょうど
        _log('b', DateTime(2026, 7, 26, 23, 59)), // 期間内の最後
        _log('c', DateTime(2026, 7, 27, 0, 0)), // 終わりちょうど(含まない)
      ];
      final s = MealStats.forRange(
          DateTime(2026, 7, 20), DateTime(2026, 7, 27), logs, const {});
      expect(s.logCount, 2);
    });

    test('日数と横軸の日付を出せる', () {
      final s = MealStats.forRange(
          DateTime(2026, 7, 20), DateTime(2026, 7, 27), const [], const {});
      expect(s.dayCount, 7);
      expect(s.days.first, DateTime(2026, 7, 20));
      expect(s.days.last, DateTime(2026, 7, 26));
    });

    test('ジャンルを数える。料理以外は母数から外す', () {
      final logs = [_log('l1', DateTime(2026, 7, 20))];
      final photos = MealStats.groupPhotos([
        _photo('p1', 'l1', genre: '寿司'),
        _photo('p2', 'l1', genre: '和食'),
        _photo('p3', 'l1', genre: 'ラーメン'),
        _photo('p4', 'l1', genre: '写真'),
      ]);
      final s = MealStats.forRange(
          DateTime(2026, 7, 20), DateTime(2026, 7, 27), logs, photos);
      expect(s.genreCounts[GenreGroup.japanese], 2);
      expect(s.genreCounts[GenreGroup.noodle], 1);
      expect(s.genreCounts[GenreGroup.other], 1);
      expect(s.genreTotal, 3); // 「写真」は含まない
    });
  });

  group('PeriodDelta', () {
    PeriodSummary summary(int kcal, int price, int count) => PeriodSummary(
          start: DateTime(2026, 7, 20),
          end: DateTime(2026, 7, 27),
          totalCalories: kcal,
          totalPrice: price,
          logCount: count,
          recordedDays: count,
          eatingOutCount: 0,
          caloriesByDay: const {},
          priceByDay: const {},
          genreCounts: const {},
        );

    test('増減と変化率を出す', () {
      final d = PeriodDelta(
          current: summary(1200, 3000, 6), previous: summary(1000, 2000, 4));
      expect(d.calories, 200);
      expect(d.price, 1000);
      expect(d.logCount, 2);
      expect(d.caloriesRate, closeTo(20, 0.01));
      expect(d.priceRate, closeTo(50, 0.01));
    });

    test('前が0なら変化率は出せない(0除算を避ける)', () {
      final d = PeriodDelta(
          current: summary(1200, 3000, 6), previous: summary(0, 0, 0));
      expect(d.caloriesRate, isNull);
      expect(d.priceRate, isNull);
      expect(d.calories, 1200);
    });
  });
}
