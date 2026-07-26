/// アドバイスの対象期間。
enum AdvicePeriod {
  week('週'),
  month('月');

  const AdvicePeriod(this.label);
  final String label;
}

/// 期間ごとの食事アドバイス。生成に時間がかかるので保存して使い回す。
class DietAdvice {
  const DietAdvice({
    required this.periodType,
    required this.periodStart,
    required this.body,
    required this.logCount,
    required this.createdAt,
  });

  final AdvicePeriod periodType;

  /// 期間の開始日(週なら月曜、月なら1日)。時刻は持たない
  final DateTime periodStart;
  final String body;

  /// 生成した時点の記録件数。あとから記録が増えたかの判定に使う
  final int logCount;
  final DateTime createdAt;

  /// 期間で一意になるID。同じ期間を作り直したら上書きする
  String get id => idFor(periodType, periodStart);

  static String idFor(AdvicePeriod type, DateTime start) =>
      '${type.name}:${start.toIso8601String().split('T').first}';

  Map<String, dynamic> toMap() => {
        'id': id,
        'period_type': periodType.name,
        'period_start': periodStart.toIso8601String(),
        'body': body,
        'log_count': logCount,
        'created_at': createdAt.toIso8601String(),
      };

  factory DietAdvice.fromMap(Map<String, dynamic> map) => DietAdvice(
        periodType: AdvicePeriod.values.firstWhere(
          (p) => p.name == map['period_type'],
          orElse: () => AdvicePeriod.week,
        ),
        periodStart: DateTime.parse(map['period_start'] as String),
        body: map['body'] as String,
        logCount: map['log_count'] as int? ?? 0,
        createdAt: DateTime.parse(map['created_at'] as String),
      );

  /// [day] を含む週の始まり(月曜)。
  static DateTime weekStart(DateTime day) {
    final d = DateTime(day.year, day.month, day.day);
    return d.subtract(Duration(days: d.weekday - DateTime.monday));
  }

  /// [day] を含む月の始まり。
  static DateTime monthStart(DateTime day) => DateTime(day.year, day.month);

  static DateTime startOf(AdvicePeriod period, DateTime day) =>
      period == AdvicePeriod.week ? weekStart(day) : monthStart(day);

  /// [start] から始まる期間の終わり(含まない)。
  static DateTime endOf(AdvicePeriod period, DateTime start) =>
      period == AdvicePeriod.week
          ? start.add(const Duration(days: 7))
          : DateTime(start.year, start.month + 1);
}
