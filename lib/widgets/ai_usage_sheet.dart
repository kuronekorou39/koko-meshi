import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../database/local_database.dart';
import '../services/ai_rate_limit_service.dart';
import '../theme/app_theme.dart';

/// AI使用状況ボトムシートを表示
void showAiUsageSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    builder: (_) => const _AiUsageSheetContent(),
  );
}

class _AiUsageSheetContent extends StatefulWidget {
  const _AiUsageSheetContent();

  @override
  State<_AiUsageSheetContent> createState() => _AiUsageSheetContentState();
}

class _AiUsageSheetContentState extends State<_AiUsageSheetContent> {
  AiRateLimitStatus? _status;
  // 各ウィンドウのリセット時刻
  DateTime? _hourlyReset;
  DateTime? _dailyReset;
  DateTime? _monthlyReset;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final status = await AiRateLimitService.getStatus();

    // 各ウィンドウの最も古いログからリセット時刻を計算
    final hourlyOldest = await LocalDatabase.getOldestAiUsageInWindow(
      const Duration(hours: 1),
    );
    final dailyOldest = await LocalDatabase.getOldestAiUsageInWindow(
      const Duration(hours: 24),
    );
    final monthlyOldest = await LocalDatabase.getOldestAiUsageInWindow(
      const Duration(days: 30),
    );

    if (mounted) {
      setState(() {
        _status = status;
        _hourlyReset = hourlyOldest?.add(const Duration(hours: 1));
        _dailyReset = dailyOldest?.add(const Duration(hours: 24));
        _monthlyReset = monthlyOldest?.add(const Duration(days: 30));
      });
    }
  }

  /// リセットまでの残り時間を表示用文字列に変換
  String _formatResetTime(DateTime? resetAt, AiRateLimit limit) {
    if (resetAt == null || limit.used == 0) return '';
    final now = DateTime.now();
    if (resetAt.isBefore(now)) return '';

    final diff = resetAt.difference(now);

    // 1時間ウィンドウ: 分単位
    if (limit.window.inHours <= 1) {
      final mins = diff.inMinutes;
      if (mins <= 0) return 'まもなくリセット';
      return 'あと$mins分でリセット';
    }

    // 1日ウィンドウ: 時間単位
    if (limit.window.inDays <= 1) {
      final hours = diff.inHours;
      if (hours <= 0) return 'まもなくリセット';
      return 'あと$hours時間でリセット';
    }

    // 1ヶ月ウィンドウ: 日付表示
    return '${DateFormat('M月d日').format(resetAt)}にリセット';
  }

  Future<void> _handleAdBonus() async {
    await AiRateLimitService.applyAdBonus();
    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('AI解析の枠を回復しました')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_status == null) {
      return const SizedBox(
        height: 200,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final status = _status!;
    final anyExceeded =
        status.hourly.exceeded || status.daily.exceeded || status.monthly.exceeded;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'AI解析の使用状況',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 16),
          _buildUsageRow('1時間', status.hourly, _hourlyReset),
          const SizedBox(height: 12),
          _buildUsageRow('1日', status.daily, _dailyReset),
          const SizedBox(height: 12),
          _buildUsageRow('1ヶ月', status.monthly, _monthlyReset),
          // 上限到達時に広告回復ボタンを表示
          if (anyExceeded) ...[
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _handleAdBonus,
                icon: const Icon(Icons.play_circle_outline),
                label: const Text('広告を見て回復'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildUsageRow(String label, AiRateLimit limit, DateTime? resetAt) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = KokoTokens.of(context);
    final color = limit.exceeded
        ? scheme.error
        : limit.ratio > 0.8
            ? tokens.warning
            : scheme.primary;

    final resetText = _formatResetTime(resetAt, limit);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              width: 50,
              child: Text(label, style: const TextStyle(fontSize: 13)),
            ),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: limit.ratio.clamp(0.0, 1.0),
                  backgroundColor: scheme.surfaceContainerHighest,
                  color: color,
                  minHeight: 8,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${limit.used}/${limit.limit}',
              style: tokens.numeral.copyWith(
                fontSize: 12,
                color: limit.exceeded ? scheme.error : tokens.textMuted,
              ),
            ),
          ],
        ),
        if (resetText.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 50, top: 4),
            child: Text(
              resetText,
              style: TextStyle(
                fontSize: 11,
                color: limit.exceeded ? scheme.error : tokens.textFaint,
              ),
            ),
          ),
      ],
    );
  }
}
