import '../models/meal_log.dart';
import '../models/meal_photo.dart';
import '../models/meal_type.dart';

/// 記録の集計。表示から切り離した純関数にしてある(テストしやすいように)。
class MealStats {
  MealStats._();

  /// 記録1件の金額。
  ///
  /// `MealLog.totalPrice` は手入力用だが実データでは全件 null で、金額は
  /// 写真側の推定にしか存在しない。手入力があればそれを優先し、無ければ
  /// 写真の推定を積む。
  static int? priceOf(MealLog log, List<MealPhoto> photos) {
    if (log.totalPrice != null) return log.totalPrice;
    var sum = 0;
    var found = false;
    for (final photo in photos) {
      final price = photo.displayPrice;
      if (price != null) {
        sum += price;
        found = true;
      }
    }
    return found ? sum : null;
  }

  /// 記録1件のカロリー。写真ごとの推定を積む。
  static int? caloriesOf(List<MealPhoto> photos) {
    var sum = 0;
    var found = false;
    for (final photo in photos) {
      final kcal = photo.displayCalories;
      if (kcal != null) {
        sum += kcal;
        found = true;
      }
    }
    return found ? sum : null;
  }

  /// [month] と同じ年月の記録だけを集計する。
  /// [photosByLog] は記録ID→その記録の写真。
  static MonthlySummary forMonth(
    DateTime month,
    List<MealLog> logs,
    Map<String, List<MealPhoto>> photosByLog,
  ) {
    var calories = 0;
    var price = 0;
    var eatingOut = 0;
    var logCount = 0;
    final days = <DateTime>{};
    final caloriesByDay = <DateTime, int>{};
    final priceByDay = <DateTime, int>{};

    for (final log in logs) {
      final at = log.eatenAt;
      if (at.year != month.year || at.month != month.month) continue;

      logCount++;
      days.add(DateTime(at.year, at.month, at.day));
      if (log.mealType == MealType.eatingOut) eatingOut++;

      final day = DateTime(at.year, at.month, at.day);
      final photos = photosByLog[log.id] ?? const <MealPhoto>[];
      final kcal = caloriesOf(photos);
      if (kcal != null) {
        calories += kcal;
        caloriesByDay[day] = (caloriesByDay[day] ?? 0) + kcal;
      }
      final p = priceOf(log, photos);
      if (p != null) {
        price += p;
        priceByDay[day] = (priceByDay[day] ?? 0) + p;
      }
    }

    return MonthlySummary(
      month: DateTime(month.year, month.month),
      totalCalories: calories,
      totalPrice: price,
      logCount: logCount,
      recordedDays: days.length,
      eatingOutCount: eatingOut,
      caloriesByDay: caloriesByDay,
      priceByDay: priceByDay,
    );
  }

  /// 記録IDごとに写真をまとめる。
  static Map<String, List<MealPhoto>> groupPhotos(List<MealPhoto> photos) {
    final map = <String, List<MealPhoto>>{};
    for (final photo in photos) {
      (map[photo.mealLogId] ??= <MealPhoto>[]).add(photo);
    }
    return map;
  }
}

/// 1か月ぶんの集計結果。
class MonthlySummary {
  const MonthlySummary({
    required this.month,
    required this.totalCalories,
    required this.totalPrice,
    required this.logCount,
    required this.recordedDays,
    required this.eatingOutCount,
    required this.caloriesByDay,
    required this.priceByDay,
  });

  final DateTime month;
  final int totalCalories;
  final int totalPrice;

  /// 記録の件数(食事の回数)
  final int logCount;

  /// 記録がある日数(同じ日に何度食べても1)
  final int recordedDays;
  final int eatingOutCount;

  /// 日付(時刻なし) → その日のカロリー合計
  final Map<DateTime, int> caloriesByDay;

  /// 日付(時刻なし) → その日の金額合計
  final Map<DateTime, int> priceByDay;

  bool get isEmpty => logCount == 0;

  /// 記録がある日の平均カロリー。記録が無ければ null。
  int? get dailyAverageCalories =>
      recordedDays == 0 ? null : (totalCalories / recordedDays).round();
}
