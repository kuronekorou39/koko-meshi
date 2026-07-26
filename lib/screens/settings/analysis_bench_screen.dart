import 'package:flutter/material.dart';

import '../../models/meal_photo.dart';
import '../../services/analysis_bench.dart';
import '../../theme/app_theme.dart';

/// 解析ベンチ(開発用)。プロンプトや推論パラメータを変えたときに、
/// 保存済みの結果(変更前)と再解析(変更後)を突き合わせて効果を見る画面。
class AnalysisBenchScreen extends StatefulWidget {
  const AnalysisBenchScreen({super.key});

  @override
  State<AnalysisBenchScreen> createState() => _AnalysisBenchScreenState();
}

class _AnalysisBenchScreenState extends State<AnalysisBenchScreen> {
  List<MealPhoto>? _targets;
  BenchReport? _report;
  bool _running = false;
  int _done = 0;
  int _limit = 20;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadTargets();
  }

  Future<void> _loadTargets() async {
    final photos = await AnalysisBench.targets();
    if (mounted) setState(() => _targets = photos);
  }

  Future<void> _run() async {
    final all = _targets;
    if (all == null || all.isEmpty) return;
    // 全件回すと時間がかかるので、新しい順に上限を切る
    final photos = all.reversed.take(_limit).toList();
    setState(() {
      _running = true;
      _done = 0;
      _error = null;
      _report = null;
    });
    try {
      final report = await AnalysisBench.run(
        photos,
        onProgress: (done, _) {
          if (mounted) setState(() => _done = done);
        },
      );
      if (mounted) setState(() => _report = report);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = KokoTokens.of(context);
    final targets = _targets;
    final runCount = targets == null ? 0 : _limit.clamp(0, targets.length);

    return Scaffold(
      appBar: AppBar(title: const Text('解析ベンチ')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 24 + context.systemBottomInset),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '保存済みの結果と再解析を比べます',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'プロンプトや推論パラメータを変えた前後で同じ写真を回して、'
                    '断定できているか・数値がばらけているかを見ます。'
                    'DBには書き戻しません。'
                    'センシティブ写真はモデルの素の出力が出ます'
                    '（アプリ本体の雰囲気タイトル生成は通りません）。',
                    style: TextStyle(
                        fontSize: 12.5, height: 1.5, color: tokens.textMuted),
                  ),
                  const SizedBox(height: 14),
                  if (targets == null)
                    const Center(child: CircularProgressIndicator())
                  else ...[
                    Text('解析可能: ${targets.length}枚',
                        style: tokens.numeral.copyWith(fontSize: 15)),
                    Text(
                      '解析済み かつ 原本が端末に残っている写真が対象',
                      style:
                          TextStyle(fontSize: 11.5, color: tokens.textFaint),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Text('今回まわす枚数',
                            style: TextStyle(
                                fontSize: 13, color: tokens.textMuted)),
                        const Spacer(),
                        SegmentedButton<int>(
                          segments: const [
                            ButtonSegment(value: 5, label: Text('5')),
                            ButtonSegment(value: 20, label: Text('20')),
                            ButtonSegment(value: 9999, label: Text('全部')),
                          ],
                          selected: {_limit},
                          onSelectionChanged: _running
                              ? null
                              : (s) => setState(() => _limit = s.first),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed:
                            _running || targets.isEmpty ? null : _run,
                        icon: _running
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.play_arrow, size: 18),
                        label: Text(_running
                            ? '解析中… $_done/$runCount'
                            : '$runCount枚を再解析して比較'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 13)),
            ),
          if (_report != null) ...[
            const SizedBox(height: 20),
            _summary(_report!),
            const SizedBox(height: 20),
            Text('個別比較（変更前 → 変更後）', style: tokens.sectionLabel),
            const SizedBox(height: 8),
            for (final c in _report!.cases) _caseCard(c),
          ],
        ],
      ),
    );
  }

  Widget _summary(BenchReport r) {
    final tokens = KokoTokens.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('結果',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            _row('併記・推測が残る', r.hedged.label, hint: '少ないほど良い'),
            _row('価格の散らばり', r.priceSpread.label, hint: '最頻%が低いほど良い'),
            _row('カロリーの散らばり', r.caloriesSpread.label),
            if (r.truthNameMatch.total > 0)
              _row('正解と一致(料理名)',
                  '${r.truthNameMatch.after}/${r.truthNameMatch.total}'),
            const Divider(height: 24),
            _row('料理名が変わった', '${r.nameChangedCount}/${r.succeeded.length}'),
            _row('1枚あたり', '${r.avgInferenceMs}ms'),
            _row('モデルロード', '${r.loadMs}ms'),
            if (r.parseFailedCount > 0)
              _row('JSON解釈失敗', '${r.parseFailedCount}枚'),
            if (r.errorCount > 0) _row('その他エラー', '${r.errorCount}枚'),
            const SizedBox(height: 8),
            Text(
              '件数が少ないうちは数字を鵜呑みにせず、下の個別比較を見てください。',
              style: TextStyle(fontSize: 11.5, color: tokens.textFaint),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value, {String? hint}) {
    final tokens = KokoTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(fontSize: 13, color: tokens.textMuted)),
                if (hint != null)
                  Text(hint,
                      style:
                          TextStyle(fontSize: 10.5, color: tokens.textFaint)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(value, style: tokens.numeral.copyWith(fontSize: 13.5)),
        ],
      ),
    );
  }

  Widget _caseCard(BenchCase c) {
    final tokens = KokoTokens.of(context);
    final scheme = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!c.ok) ...[
              Text(c.beforeName ?? '(名前なし)',
                  style: TextStyle(fontSize: 13, color: tokens.textMuted)),
              const SizedBox(height: 4),
              Text(c.error!,
                  style: TextStyle(fontSize: 12.5, color: scheme.error)),
            ] else ...[
              // 料理名: 併記が残っていれば警告色にする
              _beforeAfter(
                '料理名',
                c.beforeName,
                c.name,
                beforeBad: c.beforeHedged,
                afterBad: c.afterHedged,
                changed: c.nameChanged,
              ),
              _beforeAfter('価格', _yen(c.beforePrice), _yen(c.price)),
              _beforeAfter(
                  'カロリー', _kcal(c.beforeCalories), _kcal(c.calories)),
              const SizedBox(height: 6),
              Text(
                '${c.beforeGenre ?? '—'} → ${c.genre ?? '—'} ・ ${c.inferenceMs}ms'
                '${c.truthName != null ? ' ・ 正解: ${c.truthName}' : ''}',
                style: TextStyle(fontSize: 11, color: tokens.textFaint),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String? _yen(int? v) => v == null ? null : '¥$v';
  static String? _kcal(int? v) => v == null ? null : '$v kcal';

  Widget _beforeAfter(
    String label,
    String? before,
    String? after, {
    bool beforeBad = false,
    bool afterBad = false,
    bool changed = true,
  }) {
    final tokens = KokoTokens.of(context);
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 52,
            child: Text(label,
                style: TextStyle(fontSize: 11.5, color: tokens.textFaint)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  before ?? '—',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: beforeBad ? scheme.error : tokens.textMuted,
                    decoration: changed ? TextDecoration.lineThrough : null,
                    decorationColor: tokens.textFaint,
                  ),
                ),
                Text(
                  after ?? '—',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: afterBad ? scheme.error : null,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
