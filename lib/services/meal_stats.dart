import 'dart:math' as math;

import '../models/meal_log.dart';
import '../models/meal_photo.dart';
import '../models/meal_type.dart';

/// 食事の時間帯。
/// AI解析へ渡す撮影状況の文言と、振り返りのグラフで同じ区切りを使う
/// (別々に定義すると、両者の言う「夜」がずれる)。
enum TimeBand {
  morning('朝', 4, 11),
  noon('昼', 11, 16),
  evening('夜', 16, 23),
  night('深夜', 23, 4);

  const TimeBand(this.label, this.fromHour, this.toHour);

  final String label;
  final int fromHour;
  final int toHour;

  static TimeBand ofHour(int hour) {
    if (hour >= 4 && hour < 11) return TimeBand.morning;
    if (hour >= 11 && hour < 16) return TimeBand.noon;
    if (hour >= 16 && hour < 23) return TimeBand.evening;
    return TimeBand.night;
  }
}

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
    final logsByBand = <TimeBand, int>{};
    final caloriesByBand = <TimeBand, int>{};
    final caloriesByWeekday = <int, int>{};
    final daysByWeekday = <int, Set<DateTime>>{};
    final dishCounts = <String, int>{};

    for (final log in logs) {
      final at = log.eatenAt;
      if (at.isBefore(start) || !at.isBefore(end)) continue;

      logCount++;
      final day = DateTime(at.year, at.month, at.day);
      days.add(day);
      if (log.mealType == MealType.eatingOut) eatingOut++;

      final band = TimeBand.ofHour(at.hour);
      logsByBand[band] = (logsByBand[band] ?? 0) + 1;
      (daysByWeekday[at.weekday] ??= <DateTime>{}).add(day);

      final photos = photosByLog[log.id] ?? const <MealPhoto>[];
      final kcal = caloriesOf(photos);
      if (kcal != null) {
        calories += kcal;
        caloriesByDay[day] = (caloriesByDay[day] ?? 0) + kcal;
        caloriesByBand[band] = (caloriesByBand[band] ?? 0) + kcal;
        caloriesByWeekday[at.weekday] =
            (caloriesByWeekday[at.weekday] ?? 0) + kcal;
      }
      final p = priceOf(log, photos);
      if (p != null) {
        price += p;
        priceByDay[day] = (priceByDay[day] ?? 0) + p;
      }
      for (final photo in photos) {
        final group = GenreGroup.of(photo.aiCuisineGenre);
        genreCounts[group] = (genreCounts[group] ?? 0) + 1;
        // 料理以外(「写真」判定)はよく食べたものに混ぜない
        final name = photo.displayName;
        if (name != null && name.isNotEmpty && group != GenreGroup.other) {
          dishCounts[name] = (dishCounts[name] ?? 0) + 1;
        }
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
      logsByBand: logsByBand,
      caloriesByBand: caloriesByBand,
      caloriesByWeekday: caloriesByWeekday,
      daysByWeekday: {
        for (final e in daysByWeekday.entries) e.key: e.value.length
      },
      dishCounts: dishCounts,
      longestStreak: _longestStreak(days),
    );
  }

  /// 記録が途切れずに続いた最長日数。
  static int _longestStreak(Set<DateTime> days) {
    if (days.isEmpty) return 0;
    final sorted = days.toList()..sort();
    var best = 1;
    var run = 1;
    for (var i = 1; i < sorted.length; i++) {
      final gap = sorted[i].difference(sorted[i - 1]).inDays;
      run = gap == 1 ? run + 1 : 1;
      if (run > best) best = run;
    }
    return best;
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
    required this.logsByBand,
    required this.caloriesByBand,
    required this.caloriesByWeekday,
    required this.daysByWeekday,
    required this.dishCounts,
    required this.longestStreak,
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

  /// 時間帯 → 食事の回数
  final Map<TimeBand, int> logsByBand;

  /// 時間帯 → カロリー合計
  final Map<TimeBand, int> caloriesByBand;

  /// 曜日(DateTime.monday=1) → カロリー合計
  final Map<int, int> caloriesByWeekday;

  /// 曜日 → その曜日で記録があった日数(平均を出す母数)
  final Map<int, int> daysByWeekday;

  /// 料理名 → 回数
  final Map<String, int> dishCounts;

  /// 記録が途切れずに続いた最長日数
  final int longestStreak;

  bool get isEmpty => logCount == 0;

  /// 曜日ごとの1日平均カロリー(記録があった日だけで割る)
  Map<int, int> get averageCaloriesByWeekday => {
        for (final e in caloriesByWeekday.entries)
          if ((daysByWeekday[e.key] ?? 0) > 0)
            e.key: (e.value / daysByWeekday[e.key]!).round(),
      };

  /// よく食べたものを多い順に。
  List<MapEntry<String, int>> topDishes([int limit = 5]) {
    final entries = dishCounts.entries.toList()
      ..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        // 同数のときは名前順で固定して、実行のたびに並びが変わらないようにする
        return byCount != 0 ? byCount : a.key.compareTo(b.key);
      });
    return entries.take(limit).toList();
  }

  /// 期間のうち記録した日の割合(0〜1)
  double get recordRate => dayCount == 0 ? 0 : recordedDays / dayCount;

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

/// 期間の「食べ方の傾向」を点数にしたもの。
///
/// 健康の点数ではない。栄養素のデータを持っていないので、健康を評価することは
/// できない。ここで測れるのは、記録から見える**食べ方の傾向**だけ:
/// 続けて記録できているか / 同じものに偏っていないか / 深夜に寄っていないか /
/// 日ごとの量が安定しているか。UIでもそう伝えること。
class MealScore {
  const MealScore({
    required this.consistency,
    required this.variety,
    required this.timing,
    required this.stability,
  });

  /// 記録の継続(0-30)。期間のうち何日記録したか
  final int consistency;

  /// ジャンルの幅(0-30)。何種類のジャンルを食べたか
  final int variety;

  /// 時間の規則正しさ(0-20)。深夜の食事が少ないほど高い
  final int timing;

  /// 量の安定(0-20)。日ごとのカロリーのばらつきが小さいほど高い
  final int stability;

  int get total => consistency + variety + timing + stability;

  List<({String label, int value, int max})> get breakdown => [
        (label: '記録の継続', value: consistency, max: 30),
        (label: 'ジャンルの幅', value: variety, max: 30),
        (label: '時間の規則正しさ', value: timing, max: 20),
        (label: '量の安定', value: stability, max: 20),
      ];

  /// 記録が少なすぎると点数が意味を持たないので null を返す。
  /// (1日だけの記録で「安定している」と言っても仕方がない)
  static MealScore? of(PeriodSummary s) {
    if (s.logCount < 3 || s.recordedDays < 2) return null;

    final consistency = (s.recordRate.clamp(0.0, 1.0) * 30).round();

    final used =
        GenreGroup.axes.where((g) => (s.genreCounts[g] ?? 0) > 0).length;
    final variety = (used / GenreGroup.axes.length * 30).round();

    final nightCount = s.logsByBand[TimeBand.night] ?? 0;
    final nightRate = s.logCount == 0 ? 0.0 : nightCount / s.logCount;
    final timing = ((1 - nightRate) * 20).round();

    final stability = (_stabilityScore(s.caloriesByDay.values.toList()) * 20)
        .round();

    return MealScore(
      consistency: consistency,
      variety: variety,
      timing: timing,
      stability: stability,
    );
  }

  /// 日ごとのカロリーのばらつき。変動係数(標準偏差/平均)を0〜1へ写す。
  ///
  /// 記録は部分的(その日の全食を撮っているとは限らない)なので、実データの
  /// 変動係数は0.5前後まで普通に出る。厳しく切ると誰でも0点になって
  /// 情報量が無くなるため、0.15以下で満点・0.9以上で0点の間を線形にした。
  static double _stabilityScore(List<int> values) {
    if (values.length < 2) return 0;
    final mean = values.reduce((a, b) => a + b) / values.length;
    if (mean <= 0) return 0;
    final variance = values
            .map((v) => math.pow(v - mean, 2).toDouble())
            .reduce((a, b) => a + b) /
        values.length;
    final cv = math.sqrt(variance) / mean;
    return (1 - (cv - 0.15) / 0.75).clamp(0.0, 1.0);
  }
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
