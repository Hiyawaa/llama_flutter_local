import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:llama_flutter_local/main.dart';
import 'package:llama_flutter_local/models/chat_provider.dart';

void main() {
  testWidgets('App opens model picker', (WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => ChatProvider(),
        child: const LlamaDartApp(),
      ),
    );

    await tester.pump();

    expect(find.textContaining('LlamaDart'), findsOneWidget);
    expect(find.text('Vision Chat'), findsOneWidget);
  });
}
