import 'package:flutter/material.dart';

import '../models/meal_type.dart';
import '../theme/app_theme.dart';
import '../theme/meal_type_style.dart';

/// 食事種別を選び直すボトムシート(全種別を色/アイコン付きで一覧、現在値にチェック)。
/// 記録画面と詳細画面で同じものを使う。
Future<MealType?> showMealTypePicker(
  BuildContext context,
  MealType current,
) {
  return showModalBottomSheet<MealType>(
    context: context,
    // 既定の高さ上限(画面の9/16)だと種別7件+見出し+ハンドル+下端の
    // システムバー分が収まらずオーバーフローする
    isScrollControlled: true,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Text(
                  '食事種別を選ぶ',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              for (final type in MealType.values)
                ListTile(
                  leading: Icon(type.icon, color: type.fg(context)),
                  title: Text(
                    type.label,
                    style: TextStyle(
                      fontWeight:
                          type == current ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                  trailing: type == current
                      ? Icon(Icons.check, color: scheme.primary)
                      : null,
                  onTap: () => Navigator.pop(context, type),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    },
  );
}

/// タップで [showMealTypePicker] を開くチップ。
/// 未設定のときは控えめな「種別を設定」の促し表示にする。
class MealTypeField extends StatelessWidget {
  const MealTypeField({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final MealType value;
  final ValueChanged<MealType> onChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = KokoTokens.of(context);
    final isUnset = value == MealType.unset;

    final Widget child = isUnset
        ? Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: tokens.hairline, width: 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add, size: 16, color: tokens.textMuted),
                const SizedBox(width: 6),
                Text(
                  '種別を設定',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: tokens.textMuted,
                  ),
                ),
              ],
            ),
          )
        : MealTypeChip(mealType: value, compact: false);

    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () async {
        final selected = await showMealTypePicker(context, value);
        if (selected != null && selected != value) onChanged(selected);
      },
      child: child,
    );
  }
}
