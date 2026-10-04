import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koko_meshi/theme/app_theme.dart';
import 'package:koko_meshi/widgets/coach_mark.dart';

void main() {
  final targetKey = GlobalKey();

  Widget app({required Alignment alignment, bool withTarget = true}) {
    return MaterialApp(
      theme: AppTheme.light(null),
      home: Scaffold(
        body: Align(
          alignment: alignment,
          child: withTarget
              ? SizedBox(key: targetKey, width: 40, height: 40)
              : const SizedBox(),
        ),
      ),
    );
  }

  group('操作の案内', () {
    testWidgets('説明が出て、どこを押しても閉じる', (tester) async {
      await tester.pumpWidget(app(alignment: Alignment.bottomCenter));
      final context = tester.element(find.byType(Scaffold));

      var closed = false;
      showCoachMark(context, targetKey: targetKey, message: 'ここから撮影してね！')
          .then((_) => closed = true);
      await tester.pumpAndSettle();
      expect(find.text('ここから撮影してね！'), findsOneWidget);
      expect(closed, isFalse);

      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text('ここから撮影してね！'), findsNothing);
      expect(closed, isTrue);
    });

    testWidgets('相手が下にあれば上に、上にあれば下に説明を置く', (tester) async {
      for (final (alignment, above) in [
        (Alignment.bottomCenter, true),
        (Alignment.topRight, false),
      ]) {
        await tester.pumpWidget(app(alignment: alignment));
        final context = tester.element(find.byType(Scaffold));
        showCoachMark(context, targetKey: targetKey, message: '説明');
        await tester.pumpAndSettle();

        final bubble = tester.getRect(find.text('説明'));
        final target = tester.getRect(find.byKey(targetKey));
        expect(bubble.bottom < target.top, above);
        expect(bubble.top > target.bottom, !above);
        // 画面からはみ出さない
        final screen = tester.getRect(find.byType(MaterialApp));
        expect(bubble.left >= 0 && bubble.right <= screen.width, isTrue);

        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
      }
    });

    testWidgets('相手が画面に無ければ何も出さない', (tester) async {
      await tester.pumpWidget(
          app(alignment: Alignment.center, withTarget: false));
      final context = tester.element(find.byType(Scaffold));
      expect(
        await showCoachMark(context, targetKey: targetKey, message: '説明'),
        isFalse,
      );
    });
  });
}
