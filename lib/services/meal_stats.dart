import '../models/meal_log.dart';
import '../models/meal_photo.dart';
import '../models/meal_type.dart';

/// 料理ジャンルのまとめ方。
///
/// AIが返すジャンルは22種類あって、そのまま出すと1件ずつに散って傾向が読めない。
/// レーダーチャートで形が見える程度の粒度に寄せる。
enum GenreGroup {
  japanese('和食'),
  western('洋食'),
  asian('中華・アジア'),
  noodle('麺類'),
  light('軽食・パン'),
  sweets('甘味'),
  other('その他');

  const GenreGroup(this.label);
  final String label;

  /// チャートに出す軸(その他は軸にしない)
  static List<GenreGroup> get axes =>
      values.where((g) => g != GenreGroup.other).toList();

  /// AIのジャンル名からまとめ先を決める。
  static GenreGroup of(String? genre) {
    switch (genre) {
      case '和食':
      case '寿司':
      case '海鮮':
      case '丼・定食':
      case '居酒屋・鍋':
        return GenreGroup.japanese;
      case '洋食':
      case 'イタリアン':
      case 'フレンチ':
      case 'ピザ':
      case '焼肉・ステーキ':
        return GenreGroup.western;
      case '中華':
      case '韓国料理':
      case 'エスニック':
      case 'カレー':
        return GenreGroup.asian;
      case 'ラーメン':
      case 'うどん・そば':
      case 'パスタ':
        return GenreGroup.noodle;
      case 'ファストフード':
      case 'パン・サンドイッチ':
      case '弁当・惣菜':
        return GenreGroup.light;
      case 'カフェ・スイーツ':
        return GenreGroup.sweets;
      default:
        // 「写真」(料理以外)や未分類はここ
        return GenreGroup.other;
    }
  }
}

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

  /// [start] 以上 [end] 未満の記録を集計する。
  /// [photosByLog] は記録ID→その記録の写真。
  static PeriodSummary forRange(
    DateTime start,
    DateTime end,
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
    final genreCounts = <GenreGroup, int>{};

    for (final log in logs) {
      final at = log.eatenAt;
      if (at.isBefore(start) || !at.isBefore(end)) continue;

      logCount++;
      final day = DateTime(at.year, at.month, at.day);
      days.add(day);
      if (log.mealType == MealType.eatingOut) eatingOut++;

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
      for (final photo in photos) {
        final group = GenreGroup.of(photo.aiCuisineGenre);
        genreCounts[group] = (genreCounts[group] ?? 0) + 1;
      }
    }

    return PeriodSummary(
      start: start,
      end: end,
      totalCalories: calories,
      totalPrice: price,
      logCount: logCount,
      recordedDays: days.length,
      eatingOutCount: eatingOut,
      caloriesByDay: caloriesByDay,
      priceByDay: priceByDay,
      genreCounts: genreCounts,
    );
  }

  /// [month] と同じ年月を集計する。
  static PeriodSummary forMonth(
    DateTime month,
    List<MealLog> logs,
    Map<String, List<MealPhoto>> photosByLog,
  ) =>
      forRange(
        DateTime(month.year, month.month),
        DateTime(month.year, month.month + 1),
        logs,
        photosByLog,
      );

  /// 記録IDごとに写真をまとめる。
  static Map<String, List<MealPhoto>> groupPhotos(List<MealPhoto> photos) {
    final map = <String, List<MealPhoto>>{};
    for (final photo in photos) {
      (map[photo.mealLogId] ??= <MealPhoto>[]).add(photo);
    }
    return map;
  }
}

/// ある期間の集計結果。
class PeriodSummary {
  const PeriodSummary({
    required this.start,
    required this.end,
    required this.totalCalories,
    required this.totalPrice,
    required this.logCount,
    required this.recordedDays,
    required this.eatingOutCount,
    required this.caloriesByDay,
    required this.priceByDay,
    required this.genreCounts,
  });

  /// 期間の開始(含む)
  final DateTime start;

  /// 期間の終わり(含まない)
  final DateTime end;

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

  /// ジャンルのまとめ → 写真の枚数
  final Map<GenreGroup, int> genreCounts;

  bool get isEmpty => logCount == 0;

  /// 記録がある日の平均カロリー。記録が無ければ null。
  int? get dailyAverageCalories =>
      recordedDays == 0 ? null : (totalCalories / recordedDays).round();

  /// 期間の日数
  int get dayCount => end.difference(start).inDays;

  /// 期間の各日を古い順に並べる(棒グラフの横軸)
  List<DateTime> get days => List.generate(
        dayCount,
        (i) => DateTime(start.year, start.month, start.day + i),
      );

  /// 料理以外(「写真」判定)を除いた枚数。ジャンル構成の母数
  int get genreTotal => GenreGroup.axes
      .map((g) => genreCounts[g] ?? 0)
      .fold(0, (a, b) => a + b);
}

/// 前の期間との比較。
class PeriodDelta {
  const PeriodDelta({required this.current, required this.previous});

  final PeriodSummary current;
  final PeriodSummary previous;

  int get calories => current.totalCalories - previous.totalCalories;
  int get price => current.totalPrice - previous.totalPrice;
  int get logCount => current.logCount - previous.logCount;

  /// 変化率(%)。前が0なら比べようがないので null。
  double? _rate(int now, int before) =>
      before == 0 ? null : (now - before) / before * 100;

  double? get caloriesRate =>
      _rate(current.totalCalories, previous.totalCalories);
  double? get priceRate => _rate(current.totalPrice, previous.totalPrice);
}
