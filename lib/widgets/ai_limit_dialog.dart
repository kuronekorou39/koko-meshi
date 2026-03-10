import 'package:flutter/material.dart';

import '../services/ai_rate_limit_service.dart';

/// AI解析の上限到達時に表示するダイアログ
/// 戻り値: true = 広告を見て回復した, false/null = キャンセル
Future<bool?> showAiLimitDialog(
  BuildContext context,
  AiRateLimitStatus status,
) {
  final limit = status.mostLimiting;

  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.hourglass_empty, color: Colors.orange),
          SizedBox(width: 8),
          Text('AI解析の上限に達しました'),
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
          _buildUsageBar('1時間', status.hourly),
          const SizedBox(height: 8),
          _buildUsageBar('1日', status.daily),
          const SizedBox(height: 8),
          _buildUsageBar('1ヶ月', status.monthly),
          const SizedBox(height: 16),
          Text(
            '写真は保存されます。上限回復後にAI解析が自動で実行されます。',
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
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
    ),
  );
}

Widget _buildUsageBar(String label, AiRateLimit limit) {
  final color = limit.exceeded
      ? Colors.red
      : limit.ratio > 0.8
          ? Colors.orange
          : Colors.green;

  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 12)),
          Text(
            '${limit.used} / ${limit.limit}',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: limit.exceeded ? Colors.red : null,
            ),
          ),
        ],
      ),
      const SizedBox(height: 2),
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: limit.ratio.clamp(0.0, 1.0),
          backgroundColor: Colors.grey[200],
          color: color,
          minHeight: 6,
        ),
      ),
    ],
  );
}
