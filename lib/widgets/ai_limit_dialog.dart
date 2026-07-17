import 'package:flutter/material.dart';

import '../services/ai_rate_limit_service.dart';
import '../theme/app_theme.dart';

/// AI解析の上限到達時に表示するダイアログ
/// 戻り値: true = 広告を見て回復した, false/null = キャンセル
Future<bool?> showAiLimitDialog(
  BuildContext context,
  AiRateLimitStatus status,
) {
  final limit = status.mostLimiting;

  return showDialog<bool>(
    context: context,
    builder: (context) {
      final tokens = KokoTokens.of(context);
      return AlertDialog(
        title: Row(
          children: [
            Icon(Icons.hourglass_empty, color: tokens.warning),
            const SizedBox(width: 8),
            const Expanded(child: Text('AI解析の上限に達しました')),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${limit.label}あたりの上限（${limit.limit}回）に達しています。',
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 16),
            _buildUsageBar(context, '1時間', status.hourly),
            const SizedBox(height: 8),
            _buildUsageBar(context, '1日', status.daily),
            const SizedBox(height: 8),
            _buildUsageBar(context, '1ヶ月', status.monthly),
            const SizedBox(height: 16),
            Text(
              '写真は保存されます。上限回復後にAI解析が自動で実行されます。',
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: tokens.textMuted,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('OK'),
          ),
          // 広告ボタン（将来実装）
          FilledButton.icon(
            onPressed: () async {
              // TODO: 実際の広告SDKを統合
              // 今はプレースホルダー: 即座に回復
              await AiRateLimitService.applyAdBonus();
              if (context.mounted) {
                Navigator.pop(context, true);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('${AiRateLimitService.bonusPerAd}回分のAI解析枠が回復しました'),
                  ),
                );
              }
            },
            icon: const Icon(Icons.play_circle_outline, size: 18),
            label: const Text('広告を見て回復'),
          ),
        ],
      );
    },
  );
}

Widget _buildUsageBar(BuildContext context, String label, AiRateLimit limit) {
  final scheme = Theme.of(context).colorScheme;
  final tokens = KokoTokens.of(context);
  // 通常時の色はAI使用状況シート(ai_usage_sheet)と同じprimaryに揃える
  final color = limit.exceeded
      ? scheme.error
      : limit.ratio > 0.8
          ? tokens.warning
          : scheme.primary;

  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 12, color: tokens.textMuted),
          ),
          Text(
            '${limit.used} / ${limit.limit}',
            style: tokens.numeral.copyWith(
              fontSize: 12,
              color: limit.exceeded ? scheme.error : null,
            ),
          ),
        ],
      ),
      const SizedBox(height: 4),
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: limit.ratio.clamp(0.0, 1.0),
          backgroundColor: scheme.surfaceContainerHighest,
          color: color,
          minHeight: 6,
        ),
      ),
    ],
  );
}
