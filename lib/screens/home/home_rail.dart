import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// 横向きのときの、タブ切り替えの受け渡し。
///
/// 縦向きでは画面の下に並べるタブと撮影ボタンを、横向きでは各タブが
/// 自分の操作と一緒に左の1列([HomeRail])へ並べる。
class HomeNav {
  const HomeNav({
    required this.tabIndex,
    required this.onSelectTab,
    required this.onCamera,
    this.cameraKey,
  });

  /// いま出しているタブ(0: 記録 / 1: マップ)
  final int tabIndex;
  final ValueChanged<int> onSelectTab;
  final VoidCallback onCamera;

  /// 撮影ボタンに付けるキー(初回の案内で囲む相手)。
  /// 同じキーを2か所に付けられないので、表に出ているタブにだけ渡す
  final Key? cameraKey;
}

/// 画面ごとの操作。縦向きではヘッダに、横向きでは [HomeRail] に並ぶ
class RailAction {
  const RailAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.key,
    this.badge = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Key? key;

  /// 点を付けて、何かが効いていることを示す(フィルタ中など)
  final bool badge;

  Widget toIconButton() => IconButton(
        key: key,
        icon: Badge(isLabelVisible: badge, child: Icon(icon)),
        tooltip: tooltip,
        onPressed: onTap,
      );
}

/// 横向き用の左の列。上にタブと撮影、下にその画面の操作を置く。
///
/// 横向きは縦が足りないので、ヘッダと下のタブで上下を削らず、写真や地図に
/// 高さを残す。
class HomeRail extends StatelessWidget {
  const HomeRail({super.key, required this.nav, this.actions = const []});

  final HomeNav nav;
  final List<RailAction> actions;

  static const double width = 64;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = KokoTokens.of(context);

    return Container(
      // 罫線も含めてこの幅に収める
      width: width,
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(
          right: BorderSide(color: tokens.hairline, width: 0.8),
        ),
      ),
      child: SafeArea(
        right: false,
        child: SizedBox(
          child: LayoutBuilder(
            // 背の低い端末では下の操作が入りきらないので、全体を送れるようにする
            builder: (context, constraints) => SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(height: 8),
                        _tab(context, 0, Icons.receipt_long_outlined,
                            Icons.receipt_long, '記録'),
                        const SizedBox(height: 4),
                        _cameraButton(scheme),
                        const SizedBox(height: 4),
                        _tab(context, 1, Icons.map_outlined, Icons.map, 'マップ'),
                      ],
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(height: 8),
                        for (final action in actions) action.toIconButton(),
                        const SizedBox(height: 8),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _tab(BuildContext context, int index, IconData icon,
      IconData selectedIcon, String label) {
    final scheme = Theme.of(context).colorScheme;
    final selected = nav.tabIndex == index;
    return IconButton(
      isSelected: selected,
      icon: Icon(icon),
      selectedIcon: Icon(selectedIcon),
      tooltip: label,
      style: IconButton.styleFrom(
        backgroundColor: selected
            ? (NavigationBarTheme.of(context).indicatorColor ??
                scheme.secondaryContainer)
            : null,
      ),
      onPressed: () => nav.onSelectTab(index),
    );
  }

  Widget _cameraButton(ColorScheme scheme) {
    return IconButton.filled(
      key: nav.cameraKey,
      icon: const Icon(Icons.photo_camera),
      tooltip: '撮影',
      onPressed: nav.onCamera,
    );
  }
}
