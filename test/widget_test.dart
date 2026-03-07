import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:koko_meshi/app.dart';

void main() {
  testWidgets('アプリが起動する', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: KokoMeshiApp()),
    );

    expect(find.text('ココメシ'), findsOneWidget);
  });
}
