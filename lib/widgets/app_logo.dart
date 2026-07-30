import 'package:flutter/material.dart';

/// ヘッダに出すロゴ。
///
/// 元画像は白一色のシルエット(透過つき)なので、そのまま置くとライトテーマの
/// 生成りの地では見えない。形だけを使ってテーマの文字色に染める。こうすると
/// 明暗どちらでも読めるし、ロゴを2枚用意して取り違える心配も無い。
///
/// 読み上げには文字の名前を返す(画像なので何も伝わらなくなるのを防ぐ)。
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.height = 26});

  final double height;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).appBarTheme.titleTextStyle?.color ??
        Theme.of(context).colorScheme.onSurface;

    return Image.asset(
      'assets/header_logo.png',
      height: height,
      color: color,
      colorBlendMode: BlendMode.srcIn,
      filterQuality: FilterQuality.medium,
      semanticLabel: 'ココメシ',
    );
  }
}
