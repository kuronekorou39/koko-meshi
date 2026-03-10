import '../database/local_database.dart';

class AiRateLimit {
  final String label;
  final Duration window;
  final int limit;
  final int used;

  AiRateLimit({
    required this.label,
    required this.window,
    required this.limit,
    required this.used,
  });

  int get remaining => (limit - used).clamp(0, limit);
  bool get exceeded => used >= limit;
  double get ratio => used / limit;
}

class AiRateLimitStatus {
  final AiRateLimit hourly;
  final AiRateLimit daily;
  final AiRateLimit monthly;

  AiRateLimitStatus({
    required this.hourly,
    required this.daily,
    required this.monthly,
  });

  bool get canUse => !hourly.exceeded && !daily.exceeded && !monthly.exceeded;

  /// 最も制限に近い（または超えている）区分を返す
  AiRateLimit get mostLimiting {
    if (hourly.exceeded) return hourly;
    if (daily.exceeded) return daily;
    if (monthly.exceeded) return monthly;
    // 超えてなければ残り比率が小さいものを返す
    final sorted = [hourly, daily, monthly]
      ..sort((a, b) => a.remaining.compareTo(b.remaining));
    return sorted.first;
  }
}

class AiRateLimitService {
  AiRateLimitService._();

  // 上限設定
  static const int hourlyLimit = 5;
  static const int dailyLimit = 12;
  static const int monthlyLimit = 90;

  // 広告視聴で回復する回数
  static const int bonusPerAd = 5;
  // 1日あたりの広告視聴上限
  static const int maxAdsPerDay = 3;

  /// 現在のレート制限状況を取得
  static Future<AiRateLimitStatus> getStatus() async {
    final hourlyUsed = await LocalDatabase.getAiUsageCount(
      const Duration(hours: 1),
    );
    final dailyUsed = await LocalDatabase.getAiUsageCount(
      const Duration(hours: 24),
    );
    final monthlyUsed = await LocalDatabase.getAiUsageCount(
      const Duration(days: 30),
    );

    return AiRateLimitStatus(
      hourly: AiRateLimit(
        label: '1時間',
        window: const Duration(hours: 1),
        limit: hourlyLimit,
        used: hourlyUsed,
      ),
      daily: AiRateLimit(
        label: '1日',
        window: const Duration(hours: 24),
        limit: dailyLimit,
        used: dailyUsed,
      ),
      monthly: AiRateLimit(
        label: '1ヶ月',
        window: const Duration(days: 30),
        limit: monthlyLimit,
        used: monthlyUsed,
      ),
    );
  }

  /// AI解析が可能か確認
  static Future<bool> canAnalyze() async {
    final status = await getStatus();
    return status.canUse;
  }

  /// 使用を記録
  static Future<void> recordUsage() async {
    await LocalDatabase.insertAiUsage();
  }

  /// 広告視聴で枠を回復
  static Future<void> applyAdBonus() async {
    await LocalDatabase.addBonusAiUsage(bonusPerAd);
  }
}
