import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../database/local_database.dart';
import '../../models/diet_advice.dart';
import '../../services/diet_advice_service.dart';
import '../../theme/app_theme.dart';

/// 週/月の食事アドバイス。端末内AIで生成するので時間がかかる。
/// 生成した結果は保存して、次に開いたときはすぐ出す。
class DietAdviceScreen extends StatefulWidget {
  const DietAdviceScreen({super.key, required this.initialDay});

  /// この日を含む期間から始める
  final DateTime initialDay;

  @override
  State<DietAdviceScreen> createState() => _DietAdviceScreenState();
}

class _DietAdviceScreenState extends State<DietAdviceScreen> {
  AdvicePeriod _period = AdvicePeriod.week;
  late DateTime _start;

  DietAdvice? _advice;
  bool _loading = true;
  bool _generating = false;
  String? _error;

  /// この期間の記録件数(0なら生成させない)
  int _logCount = 0;

  @override
  void initState() {
    super.initState();
    _start = DietAdvice.startOf(_period, widget.initialDay);
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final advice = await LocalDatabase.getDietAdvice(_period, _start);
    final logs = await LocalDatabase.getMealLogs();
    final end = DietAdvice.endOf(_period, _start);
    final count = logs
        .where((l) => !l.eatenAt.isBefore(_start) && l.eatenAt.isBefore(end))
        .length;
    if (!mounted) return;
    setState(() {
      _advice = advice;
      _logCount = count;
      _loading = false;
    });
  }

  void _shift(int delta) {
    setState(() {
      _start = _period == AdvicePeriod.week
          ? _start.add(Duration(days: 7 * delta))
          : DateTime(_start.year, _start.month + delta);
    });
    _load();
  }

  void _switchPeriod(AdvicePeriod period) {
    setState(() {
      _period = period;
      _start = DietAdvice.startOf(period, _start);
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
    final advice = _advice;

    return Scaffold(
      appBar: AppBar(title: const Text('食事のアドバイス')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
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
          const SizedBox(height: 12),
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
                onPressed: _generating ? null : () => _shift(1),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            if (advice != null) _adviceCard(advice, tokens),
            if (advice == null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    _logCount == 0
                        ? 'この期間の記録がありません。'
                        : 'この期間の記録は$_logCount件です。'
                            '下のボタンでアドバイスを作れます。',
                    style: TextStyle(
                        fontSize: 13, height: 1.6, color: tokens.textMuted),
                  ),
                ),
              ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed:
                    _generating || _logCount == 0 ? null : _generate,
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
                        ? 'アドバイスを作る'
                        : 'もう一度作る'),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.error, fontSize: 13),
                ),
              ),
            const SizedBox(height: 12),
            Text(
              '端末内のAIが生成しています。医学的な助言ではありません。',
              style: TextStyle(fontSize: 11.5, color: tokens.textFaint),
            ),
          ],
        ],
      ),
    );
  }

  Widget _adviceCard(DietAdvice advice, KokoTokens tokens) {
    final stale = _logCount != advice.logCount;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              advice.body,
              style: const TextStyle(fontSize: 14, height: 1.7),
            ),
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
                  'このあと記録が$_logCount件に変わっています。作り直すと反映されます。',
                  style: TextStyle(fontSize: 11.5, color: tokens.warning),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
