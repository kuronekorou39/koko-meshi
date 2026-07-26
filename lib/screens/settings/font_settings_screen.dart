import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/app_settings_providers.dart';
import '../../services/app_settings_service.dart';
import '../../theme/app_theme.dart';

/// 本文フォントの選択画面。
/// 選ぶと即座にアプリ全体のテーマへ反映されるので、この画面自体が
/// そのままプレビューになる。
class FontSettingsScreen extends ConsumerWidget {
  const FontSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(appFontProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('フォント')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          _sectionLabel(context, 'プレビュー'),
          const _FontPreviewCard(),
          _sectionLabel(context, '書体'),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (final font in AppFont.values) ...[
                  if (font != AppFont.values.first) const Divider(height: 1),
                  _FontTile(
                    font: font,
                    selected: font == current,
                    onTap: () => _select(ref, font),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _select(WidgetRef ref, AppFont font) async {
    await AppSettings.setFont(font);
    ref.read(appFontProvider.notifier).state = font;
  }

  Widget _sectionLabel(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
      child: Text(text, style: KokoTokens.of(context).sectionLabel),
    );
  }
}

/// 実際の画面に近い組みでプレビューする。数字を2行並べているのは、
/// 等幅数字(tabularFigures)が効かない書体だと桁がずれるのを見つけるため。
class _FontPreviewCard extends StatelessWidget {
  const _FontPreviewCard();

  @override
  Widget build(BuildContext context) {
    final tokens = KokoTokens.of(context);
    final textTheme = Theme.of(context).textTheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '鮭の塩焼き定食',
              style: textTheme.titleLarge
                  ?.copyWith(fontSize: 19, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              'ご飯・味噌汁・小鉢つき。あぶらの乗った銀鮭を炭火で焼いています。',
              style: textTheme.bodyMedium?.copyWith(color: tokens.textMuted),
            ),
            Container(
              margin: const EdgeInsets.only(top: 12),
              padding: const EdgeInsets.only(top: 12),
              decoration: BoxDecoration(
                border:
                    Border(top: BorderSide(color: tokens.hairline, width: 0.8)),
              ),
              child: Row(
                children: [
                  // 桁数を揃えた2行にしてある。等幅数字が効かない書体では
                  // 上下の幅が食い違ってすぐ分かる
                  Expanded(
                    child: _numeralColumn(context, '価格', ['¥1,280', '¥1,980']),
                  ),
                  Expanded(
                    child: _numeralColumn(
                        context, 'カロリー', ['650 kcal', '980 kcal']),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _numeralColumn(
      BuildContext context, String label, List<String> values) {
    final tokens = KokoTokens.of(context);
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
        for (final v in values)
          Text(v, style: tokens.numeral.copyWith(fontSize: 17, height: 1.5)),
      ],
    );
  }
}

class _FontTile extends StatelessWidget {
  const _FontTile({
    required this.font,
    required this.selected,
    required this.onTap,
  });

  final AppFont font;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = KokoTokens.of(context);
    final scheme = Theme.of(context).colorScheme;

    return ListTile(
      // 各行をその書体で描いて、切り替えなくても見比べられるようにする
      title: Text(
        font.label,
        style: TextStyle(
          fontFamily: font.family,
          fontSize: 15,
          fontWeight: FontWeight.w700,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 3),
          Text(
            '鮭の塩焼き定食　¥1,280 / 650kcal',
            style: TextStyle(
              fontFamily: font.family,
              fontSize: 14,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            font.description,
            style: TextStyle(fontSize: 11.5, color: tokens.textFaint),
          ),
        ],
      ),
      isThreeLine: true,
      trailing: selected ? Icon(Icons.check, color: scheme.primary) : null,
      onTap: onTap,
    );
  }
}
