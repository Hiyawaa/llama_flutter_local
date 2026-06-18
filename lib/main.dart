import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'models/app_theme.dart';
import 'models/chat_provider.dart';
import 'screens/model_picker_screen.dart';
import 'screens/chat_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ChangeNotifierProvider(
      create: (_) => ChatProvider(),
      child: const LlamaDartApp(),
    ),
  );
}

class LlamaDartApp extends StatelessWidget {
  const LlamaDartApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LlamaDart',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      initialRoute: '/',
      routes: {
        '/':     (_) => const ModelPickerScreen(),
        '/chat': (_) => const ChatScreen(),
      },
    );
  }
}
