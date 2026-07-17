import 'package:flutter/material.dart';

import '../models/meal_type.dart';

/// 食事種別ごとの色とアイコン。
/// 色は「和の食材」由来のくすんだトーンで、写真の邪魔をしない濃度に抑える。
/// チップ表示は `bg` を下地、`fg` を文字・アイコンに使う。
extension MealTypeStyle on MealType {
  IconData get icon => switch (this) {
        MealType.unset => Icons.help_outline,
        MealType.eatingOut => Icons.storefront_outlined,
        MealType.homeCooking => Icons.soup_kitchen_outlined,
        MealType.takeout => Icons.takeout_dining_outlined,
        MealType.delivery => Icons.delivery_dining_outlined,
        MealType.snack => Icons.cookie_outlined,
        MealType.other => Icons.restaurant_outlined,
      };

  /// 文字・アイコン色
  Color fg(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return switch (this) {
      MealType.unset => dark ? const Color(0xFFA79C8B) : const Color(0xFF83786A),
      MealType.eatingOut =>
        dark ? const Color(0xFFDE8A62) : const Color(0xFFB0492A), // 漆
      MealType.homeCooking =>
        dark ? const Color(0xFFB4C287) : const Color(0xFF66783D), // 抹茶
      MealType.takeout =>
        dark ? const Color(0xFFD8B45E) : const Color(0xFF96761F), // 芥子
      MealType.delivery =>
        dark ? const Color(0xFF9DB0D4) : const Color(0xFF4E5F80), // 藍
      MealType.snack =>
        dark ? const Color(0xFFD3A0B4) : const Color(0xFF95566C), // 小豆
      MealType.other =>
        dark ? const Color(0xFFA79C8B) : const Color(0xFF7D7264),
    };
  }

  /// チップの下地色(薄いトーン)
  Color bg(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return switch (this) {
      MealType.unset => dark ? const Color(0xFF322B22) : const Color(0xFFEFE8DC),
      MealType.eatingOut =>
        dark ? const Color(0xFF4A2413) : const Color(0xFFF7E2D8),
      MealType.homeCooking =>
        dark ? const Color(0xFF32401A) : const Color(0xFFE6EAD6),
      MealType.takeout =>
        dark ? const Color(0xFF4A3B0E) : const Color(0xFFF3E7C8),
      MealType.delivery =>
        dark ? const Color(0xFF2E3A50) : const Color(0xFFE2E7F0),
      MealType.snack =>
        dark ? const Color(0xFF4A2C38) : const Color(0xFFF2E1E8),
      MealType.other =>
        dark ? const Color(0xFF322B22) : const Color(0xFFEDE7DC),
    };
  }
}

/// 食事種別チップ(タイムライン・詳細で共通で使う)
class MealTypeChip extends StatelessWidget {
  final MealType mealType;

  /// 小: カード内メタ表示用 / 大: 詳細画面用
  final bool compact;

  const MealTypeChip({super.key, required this.mealType, this.compact = true});

  @override
  Widget build(BuildContext context) {
    final fg = mealType.fg(context);
    final bg = mealType.bg(context);
    return Container(
      padding: compact
          ? const EdgeInsets.symmetric(horizontal: 8, vertical: 3)
          : const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(mealType.icon, size: compact ? 13 : 16, color: fg),
          SizedBox(width: compact ? 4 : 6),
          Text(
            mealType.label,
            style: TextStyle(
              fontSize: compact ? 11.5 : 13,
              fontWeight: FontWeight.w700,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}
