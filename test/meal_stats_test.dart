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
}) =>
    MealPhoto(
      id: id,
      mealLogId: logId,
      localPath: '/tmp/$id.jpg',
      aiEstimatedPrice: aiPrice,
      aiEstimatedCalories: aiCalories,
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
}
