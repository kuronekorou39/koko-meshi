import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../database/local_database.dart';
import '../../models/diet_advice.dart';
import '../../services/diet_advice_service.dart';
import '../../services/meal_stats.dart';
import '../../theme/app_theme.dart';
import '../../widgets/stat_charts.dart';

/// 週/月の振り返り。集計とグラフを出し、そのうえで端末内AIのアドバイスを作る。
///
/// 対象は「終わった期間」だけ。途中の週や月を評価しても意味が無く、
/// 生成し直すたびに内容が変わって混乱するため。
class DietAdviceScreen extends StatefulWidget {
  const DietAdviceScreen({super.key, required this.initialDay});

  /// この日を含む期間から始める(未完了ならひとつ前へ下げる)
  final DateTime initialDay;

  @override
  State<DietAdviceScreen> createState() => _DietAdviceScreenState();
}

class _DietAdviceScreenState extends State<DietAdviceScreen> {
  AdvicePeriod _period = AdvicePeriod.week;
  late DateTime _start;

  DietAdvice? _advice;
  PeriodSummary? _summary;
  PeriodSummary? _previous;
  bool _loading = true;
  bool _generating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _start = _latestCompleted(_period, widget.initialDay);
    _load();
  }

  /// [day] を含む期間。まだ終わっていなければひとつ前の期間を返す。
  static DateTime _latestCompleted(AdvicePeriod period, DateTime day) {
    final start = DietAdvice.startOf(period, day);
    return _isComplete(period, start) ? start : _shifted(period, start, -1);
  }

  static bool _isComplete(AdvicePeriod period, DateTime start) =>
      !DateTime.now().isBefore(DietAdvice.endOf(period, start));

  static DateTime _shifted(AdvicePeriod period, DateTime start, int delta) =>
      period == AdvicePeriod.week
          ? start.add(Duration(days: 7 * delta))
          : DateTime(start.year, start.month + delta);

  bool get _complete => _isComplete(_period, _start);

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final advice = await LocalDatabase.getDietAdvice(_period, _start);
    final logs = await LocalDatabase.getMealLogs();
    final photos = MealStats.groupPhotos(await LocalDatabase.getAllMealPhotos());

    final end = DietAdvice.endOf(_period, _start);
    final prevStart = _shifted(_period, _start, -1);
    if (!mounted) return;
    setState(() {
      _advice = advice;
      _summary = MealStats.forRange(_start, end, logs, photos);
      _previous = MealStats.forRange(
          prevStart, DietAdvice.endOf(_period, prevStart), logs, photos);
      _loading = false;
    });
  }

  void _shift(int delta) {
    final next = _shifted(_period, _start, delta);
    // 未来と、まだ終わっていない期間へは進ませない
    if (delta > 0 && !_isComplete(_period, next)) return;
    setState(() => _start = next);
    _load();
  }

  void _switchPeriod(AdvicePeriod period) {
    setState(() {
      _period = period;
      _start = _latestCompleted(period, _start);
    });
    _load();
  }

  Future<void> _generate() async {
    setState(() {
      _generating = true;
      _error = null;
    });
    try {
      final advice = await DietAdviceService.generateForPeriod(
        period: _period,
        start: _start,
      );
      if (mounted) setState(() => _advice = advice);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is StateError ? e.message : e.toString());
      }
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  String get _periodLabel {
    if (_period == AdvicePeriod.week) {
      final end = _start.add(const Duration(days: 6));
      return '${DateFormat('M月d日', 'ja').format(_start)} 〜 '
          '${DateFormat('M月d日', 'ja').format(end)}';
    }
    return DateFormat('yyyy年M月', 'ja').format(_start);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = KokoTokens.of(context);
    final summary = _summary;
    final canForward = _isComplete(_period, _shifted(_period, _start, 1));

    return Scaffold(
      appBar: AppBar(title: const Text('食事の振り返り')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 32 + context.systemBottomInset),
        children: [
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<AdvicePeriod>(
              segments: const [
                ButtonSegment(value: AdvicePeriod.week, label: Text('週')),
                ButtonSegment(value: AdvicePeriod.month, label: Text('月')),
              ],
              selected: {_period},
              onSelectionChanged:
                  _generating ? null : (s) => _switchPeriod(s.first),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              IconButton(
                onPressed: _generating ? null : () => _shift(-1),
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: Text(
                  _periodLabel,
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                onPressed: _generating || !canForward ? null : () => _shift(1),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 60),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (summary == null)
            const SizedBox.shrink()
          else if (summary.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text('この期間の記録はありません。',
                    style: TextStyle(fontSize: 13, color: tokens.textMuted)),
              ),
            )
          else ...[
            _totalsCard(summary, tokens),
            const SizedBox(height: 16),
            _sectionLabel('日ごとのカロリー', tokens),
            _caloriesCard(summary, tokens),
            const SizedBox(height: 16),
            _sectionLabel('ジャンルの偏り', tokens),
            _genreCard(summary, tokens),
            const SizedBox(height: 16),
            _sectionLabel('AIのコメント', tokens),
            _adviceSection(tokens),
          ],
        ],
      ),
    );
  }

  Widget _sectionLabel(String text, KokoTokens tokens) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
        child: Text(text, style: tokens.sectionLabel),
      );

  // ─── 合計と前期間との差 ───

  Widget _totalsCard(PeriodSummary s, KokoTokens tokens) {
    final prev = _previous;
    final delta = prev == null ? null : PeriodDelta(current: s, previous: prev);
    final fmt = NumberFormat('#,###');

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            IntrinsicHeight(
              child: Row(
                children: [
                  Expanded(
                    child: _metric(
                      'カロリー',
                      '${fmt.format(s.totalCalories)} kcal',
                      delta?.calories,
                      delta?.caloriesRate,
                      tokens,
                      unit: 'kcal',
                    ),
                  ),
                  VerticalDivider(
                      width: 20, thickness: 0.8, color: tokens.hairline),
                  Expanded(
                    child: _metric(
                      '金額',
                      '¥${fmt.format(s.totalPrice)}',
                      delta?.price,
                      delta?.priceRate,
                      tokens,
                      unit: '円',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '記録 ${s.recordedDays}日・${s.logCount}回'
              '${s.dailyAverageCalories == null ? '' : '　1日平均 ${fmt.format(s.dailyAverageCalories)}kcal'}',
              style: TextStyle(fontSize: 11.5, color: tokens.textMuted),
            ),
          ],
        ),
      ),
    );
  }

  /// 合計と、前の期間からの増減。
  Widget _metric(
    String label,
    String value,
    int? delta,
    double? rate,
    KokoTokens tokens, {
    required String unit,
  }) {
    final fmt = NumberFormat('#,###');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
            color: tokens.textFaint,
          ),
        ),
        const SizedBox(height: 3),
        Text(value, style: tokens.numeral.copyWith(fontSize: 18)),
        const SizedBox(height: 4),
        if (delta == null || delta == 0)
          Text(
            delta == 0 ? '前${_period.label}と同じ' : '前${_period.label}の記録なし',
            style: TextStyle(fontSize: 10.5, color: tokens.textFaint),
          )
        else
          Row(
            children: [
              Icon(
                delta > 0 ? Icons.arrow_upward : Icons.arrow_downward,
                size: 11,
                // 増減はどちらが良いとも言えないので、色で善し悪しを示さない
                color: tokens.textMuted,
              ),
              const SizedBox(width: 2),
              Text(
                '${fmt.format(delta.abs())}$unit'
                '${rate == null ? '' : ' (${rate.abs().round()}%)'}',
                style: TextStyle(fontSize: 10.5, color: tokens.textMuted),
              ),
            ],
          ),
      ],
    );
  }

  // ─── 日ごとのカロリー ───

  Widget _caloriesCard(PeriodSummary s, KokoTokens tokens) {
    final days = s.days;
    final avg = s.dailyAverageCalories;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 14, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DailyBarChart(
              days: days,
              values: s.caloriesByDay,
              averageLine: avg,
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(DateFormat('M/d', 'ja').format(days.first),
                    style: TextStyle(fontSize: 10, color: tokens.textFaint)),
                if (avg != null)
                  Text('破線 = 1日平均 ${avg}kcal',
                      style:
                          TextStyle(fontSize: 10, color: tokens.textFaint)),
                Text(DateFormat('M/d', 'ja').format(days.last),
                    style: TextStyle(fontSize: 10, color: tokens.textFaint)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ─── ジャンル ───

  Widget _genreCard(PeriodSummary s, KokoTokens tokens) {
    final axes = GenreGroup.axes;
    final values = axes.map((g) => s.genreCounts[g] ?? 0).toList();
    final total = s.genreTotal;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: total == 0
            ? Text('ジャンルを判定できた記録がありません。',
                style: TextStyle(fontSize: 13, color: tokens.textMuted))
            : Column(
                children: [
                  GenreRadarChart(
                    labels: axes.map((g) => g.label).toList(),
                    values: values,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 12,
                    runSpacing: 4,
                    alignment: WrapAlignment.center,
                    children: [
                      for (var i = 0; i < axes.length; i++)
                        if (values[i] > 0)
                          Text(
                            '${axes[i].label} ${values[i]}',
                            style: TextStyle(
                                fontSize: 11, color: tokens.textMuted),
                          ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }

  // ─── AIコメント ───

  Widget _adviceSection(KokoTokens tokens) {
    final advice = _advice;
    final summary = _summary;
    final stale = advice != null &&
        summary != null &&
        advice.logCount != summary.logCount;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (advice != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(advice.body,
                      style: const TextStyle(fontSize: 14, height: 1.7)),
                  const SizedBox(height: 14),
                  Divider(color: tokens.hairline, height: 1),
                  const SizedBox(height: 10),
                  Text(
                    '${DateFormat('M月d日 HH:mm', 'ja').format(advice.createdAt)}に生成'
                    '（記録${advice.logCount}件）',
                    style: TextStyle(fontSize: 11, color: tokens.textFaint),
                  ),
                  if (stale)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        'そのあと記録が${summary.logCount}件に変わっています。'
                        '作り直すと反映されます。',
                        style:
                            TextStyle(fontSize: 11.5, color: tokens.warning),
                      ),
                    ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _generating || !_complete ? null : _generate,
            icon: _generating
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_awesome_outlined, size: 18),
            label: Text(_generating
                ? '生成中… 1分ほどかかります'
                : advice == null
                    ? 'AIにコメントしてもらう'
                    : 'もう一度作る'),
          ),
        ),
        if (!_complete)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'この${_period.label}はまだ終わっていません。'
              '終わってから振り返ってください。',
              style: TextStyle(fontSize: 11.5, color: tokens.textFaint),
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_error!,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.error, fontSize: 13)),
          ),
        const SizedBox(height: 10),
        Text(
          '端末内のAIが生成しています。医学的な助言ではありません。',
          style: TextStyle(fontSize: 11.5, color: tokens.textFaint),
        ),
      ],
    );
  }
}
