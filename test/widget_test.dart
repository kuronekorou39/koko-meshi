import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:koko_meshi/app.dart';

void main() {
  testWidgets('アプリが起動してヘッダにアプリ名が出る', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: KokoMeshiApp()),
    );

    // ヘッダは文字ではなくロゴ画像なので、読み上げ用のラベルで確かめる。
    // 見た目を画像に替えてもアプリ名が伝わることが要件なので、ここを見る
    expect(find.bySemanticsLabel('ココメシ'), findsOneWidget);
  });
}
