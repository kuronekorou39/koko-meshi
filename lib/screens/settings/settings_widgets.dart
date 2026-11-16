import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// 設定画面の升。弁当箱の仕切りのひとつで、押せる大きなボタンでもある。
///
/// 設定は画面を送らずに全部を見せるので、升の大きさは画面しだいで決まる。
/// 升が [minContentSize] より小さくなったら、中身をはみ出させずに全体を
/// 縮めて収める(背の低い横向きや、文字を大きくしている端末のため)。
class BentoTile extends StatelessWidget {
  const BentoTile({
    super.key,
    required this.child,
    required this.minContentSize,
    this.onTap,
    this.color,
  });

  final Widget child;

  /// 中身を崩さずに組める最小の大きさ(余白を含む)
  final Size minContentSize;

  final VoidCallback? onTap;

  /// 升の地の色。null ならカードの色
  final Color? color;

  /// 升どうし・升と箱の間のすき間
  static const double gap = 8;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = KokoTokens.of(context);

    return Material(
      color: color ??
          theme.cardTheme.color ??
          theme.colorScheme.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: tokens.hairline, width: 0.8),
      ),
      child: InkWell(
        onTap: onTap,
        child: LayoutBuilder(
          builder: (context, constraints) => FittedBox(
            fit: BoxFit.scaleDown,
            child: SizedBox(
              width: math.max(constraints.maxWidth, minContentSize.width),
              height: math.max(constraints.maxHeight, minContentSize.height),
              child: Padding(padding: const EdgeInsets.all(14), child: child),
            ),
          ),
        ),
      ),
    );
  }
}
