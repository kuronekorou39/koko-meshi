import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 画面の一か所だけを明るく残して、そこが何かを一言で伝える。
///
/// どこを押しても閉じる。説明を読ませるためのもので、操作を強制しない
/// (囲んだ先を押しても、その機能は動かさずに閉じるだけ)。
///
/// 画面が出た直後には出さない。まず画面そのものを見てもらい、[delay] だけ
/// 置いてからゆっくり浮かび上がらせる。
///
/// 待っている間に別の画面が上に載ったときや、[targetKey] の相手が画面に
/// 無いときは、何もせず false を返す。
Future<bool> showCoachMark(
  BuildContext context, {
  required GlobalKey targetKey,
  required String message,
  Duration delay = const Duration(seconds: 2),
}) async {
  if (delay > Duration.zero) await Future<void>.delayed(delay);
  if (!context.mounted || ModalRoute.of(context)?.isCurrent != true) {
    return false;
  }

  final box = targetKey.currentContext?.findRenderObject() as RenderBox?;
  if (box == null || !box.attached || !box.hasSize) return false;
  final target = box.localToGlobal(Offset.zero) & box.size;

  await Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      opaque: false,
      transitionDuration: const Duration(milliseconds: 500),
      reverseTransitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (context, animation, secondaryAnimation) => FadeTransition(
        opacity: animation,
        child: _CoachMarkOverlay(target: target, message: message),
      ),
    ),
  );
  return true;
}

class _CoachMarkOverlay extends StatelessWidget {
  const _CoachMarkOverlay({required this.target, required this.message});

  final Rect target;
  final String message;

  /// 相手のまわりに空ける余白
  static const double _holePadding = 8;

  /// 相手と吹き出しの間
  static const double _gap = 12;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = KokoTokens.of(context);
    final hole = target.inflate(_holePadding);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).pop(),
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _SpotlightPainter(
                  hole: hole,
                  scrim: scheme.scrim.withValues(alpha: 0.6),
                  ring: scheme.primary,
                ),
              ),
            ),
            Positioned.fill(
              child: CustomSingleChildLayout(
                delegate: _BubbleLayout(
                  hole: hole,
                  gap: _gap,
                  safeArea: MediaQuery.paddingOf(context),
                ),
                child: Container(
                    constraints: const BoxConstraints(maxWidth: 280),
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                    decoration: BoxDecoration(
                      color: scheme.surface,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: tokens.hairline),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            message,
                            style: TextStyle(
                              fontSize: 14,
                              height: 1.6,
                              color: scheme.onSurface,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('OK'),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 全面を暗くして、相手のところだけくり抜く
class _SpotlightPainter extends CustomPainter {
  _SpotlightPainter({
    required this.hole,
    required this.scrim,
    required this.ring,
  });

  final Rect hole;
  final Color scrim;
  final Color ring;

  @override
  void paint(Canvas canvas, Size size) {
    // 丸いボタンは丸く、横長のものは角丸で囲む
    final shape = RRect.fromRectAndRadius(
      hole,
      Radius.circular(hole.shortestSide / 2),
    );
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & size),
        Path()..addRRect(shape),
      ),
      Paint()..color = scrim,
    );
    canvas.drawRRect(
      shape,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = ring,
    );
  }

  @override
  bool shouldRepaint(_SpotlightPainter old) =>
      old.hole != hole || old.scrim != scrim || old.ring != ring;
}

/// 吹き出しを相手の上か下の、広く空いているほうに置く。
/// 横は相手の中心に合わせ、画面からはみ出すぶんだけ内側へ寄せる。
class _BubbleLayout extends SingleChildLayoutDelegate {
  _BubbleLayout({
    required this.hole,
    required this.gap,
    required this.safeArea,
  });

  final Rect hole;
  final double gap;

  /// ノッチやホームバーの分。吹き出しがここに掛からないようにする
  final EdgeInsets safeArea;

  static const double _screenMargin = 16;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(maxWidth: constraints.maxWidth - _screenMargin * 2);

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final maxX = size.width - childSize.width - _screenMargin;
    final x = (hole.center.dx - childSize.width / 2)
        .clamp(_screenMargin, maxX < _screenMargin ? _screenMargin : maxX);
    final below = hole.center.dy < size.height / 2;
    final y = below ? hole.bottom + gap : hole.top - gap - childSize.height;
    final maxY = size.height - safeArea.bottom - childSize.height;
    return Offset(x, y.clamp(safeArea.top, maxY < safeArea.top ? safeArea.top : maxY));
  }

  @override
  bool shouldRelayout(_BubbleLayout old) =>
      old.hole != hole || old.gap != gap || old.safeArea != safeArea;
}
