import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:llama_flutter_local/main.dart';
import 'package:llama_flutter_local/models/chat_provider.dart';
import 'package:llama_flutter_local/widgets/chat_bubble.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  test('uses deterministic generation defaults', () {
    final provider = ChatProvider();

    expect(provider.temperature, 0.2);
    expect(provider.topP, 0.9);
    expect(provider.repeatPenalty, 1.05);
  });

  test('migrates legacy random sampling settings', () {
    SharedPreferences.setMockInitialValues({
      'temperature': 0.7,
      'topP': 0.95,
      'repeatPenalty': 1.1,
    });

    final provider = ChatProvider();

    expect(provider.temperature, 0.2);
    expect(provider.topP, 0.9);
    expect(provider.repeatPenalty, 1.05);
  });

  test('detects common LaTeX equation lines', () {
    expect(looksLikeLatexLine(r'x = \frac{1}{2}'), isTrue);
    expect(looksLikeLatexLine(r'\int_0^1 x^2 \, dx'), isTrue);
    expect(looksLikeLatexLine('This is a normal sentence'), isFalse);
  });

  test('detects multiline display math blocks', () {
    expect(
      looksLikeDisplayMathBlock(r'\begin{bmatrix}1 & 0 \\ 0 & 1\end{bmatrix}'),
      isTrue,
    );
    expect(looksLikeDisplayMathBlock('x = y\\y = z'), isTrue);
    expect(looksLikeDisplayMathBlock('normal prose line'), isFalse);
  });

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
