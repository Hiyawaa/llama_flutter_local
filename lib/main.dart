import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models/app_theme.dart';
import 'models/chat_provider.dart';
import 'screens/model_picker_screen.dart';
import 'screens/chat_screen.dart';
import 'screens/huggingface_screen.dart';
import 'screens/history_screen.dart';
import 'screens/image_scanner_screen.dart';
import 'screens/rag_documents_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ChangeNotifierProvider(
      create: (_) => ChatProvider(),
      child: ChangeNotifierProvider(
        create: (_) => ThemeController()..load(),
        child: const LlamaDartApp(),
      ),
    ),
  );
}

/// Feature 6: persisted light/dark toggle, separate from the AppTheme
/// static definitions so screens can flip the mode without rebuilding
/// anything else in the provider tree.
class ThemeController extends ChangeNotifier {
  static const _prefKey = 'themeMode';

  ThemeMode _mode = ThemeMode.dark;
  ThemeMode get mode => _mode;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefKey);
    _mode = switch (saved) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      'system' => ThemeMode.system,
      _ => ThemeMode
          .dark, // default: this app started dark-only, keep that as the fallback
    };
    notifyListeners();
  }

  Future<void> setMode(ThemeMode mode) async {
    _mode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, mode.name);
  }
}

class LlamaDartApp extends StatelessWidget {
  const LlamaDartApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeController = context.watch<ThemeController>();

    // DynamicColorBuilder yields null lightDynamic/darkDynamic on
    // platforms/OS versions without Material You support (most iOS, and
    // Android <12) — AppTheme.fromDynamicScheme handles that null case by
    // falling back to this app's own seeded amber palette, so the app
    // never renders with a broken/empty theme while waiting on a platform
    // feature that may not exist.
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        return MaterialApp(
          title: 'LlamaDart',
          debugShowCheckedModeBanner: false,
          themeMode: themeController.mode,
          theme: AppTheme.fromDynamicScheme(lightDynamic, Brightness.light),
          darkTheme: AppTheme.fromDynamicScheme(darkDynamic, Brightness.dark),
          initialRoute: '/',
          routes: {
            '/': (_) => const ModelPickerScreen(),
            '/chat': (_) => const ChatScreen(),
            '/huggingface': (_) => const HuggingFaceScreen(),
            '/history': (_) => const HistoryScreen(),
            '/image-scanner': (_) => const ImageScannerScreen(),
            '/rag-documents': (_) => const RagDocumentsScreen(),
          },
        );
      },
    );
  }
}
