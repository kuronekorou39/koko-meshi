import 'package:flutter/material.dart';

/// 横向きのとき、画面の左右に余白を取る(アプリ全体に1つだけ置く)。
///
/// 横向きの端末は、左右のどちらかにナビゲーションバーやカメラの切り欠きが
/// 来る。各画面に任せると、どこかで中身がそこへ潜り込んだり、左の操作列と
/// 中身が重なったりするので、アプリの外枠でまとめて避ける。そのうえで少し
/// ゆとりを足す。
///
/// 余白の色はふだんは画面の地の色。黒地で全面に写真を出す画面は
/// [SideGutterColor] で色を合わせる(生成りの帯が出ないように)。
class SideGutter extends StatelessWidget {
  const SideGutter({super.key, required this.child});

  final Widget child;

  /// システムの領域の外側に足すゆとり
  static const double extra = 8;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    if (media.orientation != Orientation.landscape) return child;

    final left = media.padding.left + extra;
    final right = media.padding.right + extra;

    return ValueListenableBuilder<List<Color>>(
      valueListenable: SideGutterColor._stack,
      builder: (context, stack, _) => ColoredBox(
        color: stack.isNotEmpty
            ? stack.last
            : Theme.of(context).scaffoldBackgroundColor,
        child: Padding(
          padding: EdgeInsets.only(left: left, right: right),
          // 避けたぶんは中の画面に二重に避けさせない
          child: MediaQuery.removePadding(
            context: context,
            removeLeft: true,
            removeRight: true,
            child: child,
          ),
        ),
      ),
    );
  }
}

/// この画面が出ている間、横向きの左右の余白をこの色にする
class SideGutterColor extends StatefulWidget {
  const SideGutterColor({super.key, required this.color, required this.child});

  final Color color;
  final Widget child;

  /// 出ている画面の色。後から出た画面が上に積まれる
  static final ValueNotifier<List<Color>> _stack = ValueNotifier(const []);

  @override
  State<SideGutterColor> createState() => _SideGutterColorState();
}

class _SideGutterColorState extends State<SideGutterColor> {
  @override
  void initState() {
    super.initState();
    // 描画の途中で外枠を描き直させないよう、次のフレームで積む
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      SideGutterColor._stack.value = [
        ...SideGutterColor._stack.value,
        widget.color,
      ];
    });
  }

  @override
  void dispose() {
    final color = widget.color;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final next = [...SideGutterColor._stack.value];
      final i = next.lastIndexOf(color);
      if (i >= 0) next.removeAt(i);
      SideGutterColor._stack.value = next;
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
