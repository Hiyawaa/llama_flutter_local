import 'package:flutter/material.dart';

/// Feature 6: Material 3 dynamicColor + light/dark toggle.
///
/// The static color constants below remain the app's default ("baked-in")
/// palette and are still used directly by widgets that were written
/// against fixed colors (ChatBubble, RamIndicator, screens, etc.) — this
/// keeps the visual refactor scoped rather than forcing every widget to
/// migrate to Theme.of(context) in one pass.
///
/// [dark] and [light] below are the app's own seeded fallback themes, used
/// whenever the platform doesn't support Material You dynamic color (most
/// non-Android platforms, or older Android versions). When a dynamic
/// ColorScheme IS available, `main.dart`'s DynamicColorBuilder passes it
/// straight through via [fromDynamicScheme] instead of these.
class AppTheme {
  static const Color bgBase = Color(0xFF0F0F11);
  static const Color bgSurface = Color(0xFF1A1A1E);
  static const Color bgBubbleAI = Color(0xFF1E1E24);
  static const Color bgBubbleUser = Color(0xFF1E2A1E);
  static const Color borderColor = Color(0xFF2E2E36);
  static const Color accentAmber = Color(0xFFF59E0B);
  static const Color accentGreen = Color(0xFF4ADE80);
  static const Color accentRed = Color(0xFFEF4444);
  static const Color accentBlue = Color(0xFF60A5FA);
  static const Color textPrimary = Color(0xFFF1F1F3);
  static const Color textSecondary = Color(0xFF8B8B9B);
  static const Color textMuted = Color(0xFF4B4B5B);

  // Light-mode counterparts. Chosen to preserve the same amber-accent
  // identity while inverting the base surfaces for daylight legibility.
  static const Color lightBgBase = Color(0xFFFAFAFA);
  static const Color lightBgSurface = Color(0xFFFFFFFF);
  static const Color lightBorderColor = Color(0xFFE0E0E0);
  static const Color lightTextPrimary = Color(0xFF1A1A1E);
  static const Color lightTextSecondary = Color(0xFF5A5A66);
  static const Color lightTextMuted = Color(0xFF9A9AA6);

  static ThemeData get dark => _buildTheme(
        brightness: Brightness.dark,
        scheme: const ColorScheme.dark(
          primary: accentAmber,
          secondary: accentGreen,
          surface: bgSurface,
          error: accentRed,
        ),
        scaffoldBg: bgBase,
        textPrimaryColor: textPrimary,
        textSecondaryColor: textSecondary,
      );

  static ThemeData get light => _buildTheme(
        brightness: Brightness.light,
        scheme: ColorScheme.fromSeed(
          seedColor: accentAmber,
          brightness: Brightness.light,
        ),
        scaffoldBg: lightBgBase,
        textPrimaryColor: lightTextPrimary,
        textSecondaryColor: lightTextSecondary,
      );

  /// Builds a theme from a platform-provided dynamic ColorScheme (Material
  /// You / Monet, Android 12+). Falls back to this app's own seeded
  /// [light]/[dark] themes if [dynamicScheme] is null, which
  /// DynamicColorBuilder in main.dart passes on unsupported platforms.
  static ThemeData fromDynamicScheme(
      ColorScheme? dynamicScheme, Brightness brightness) {
    if (dynamicScheme == null) {
      return brightness == Brightness.dark ? dark : light;
    }
    final isDark = brightness == Brightness.dark;
    return _buildTheme(
      brightness: brightness,
      scheme: dynamicScheme,
      scaffoldBg: isDark ? bgBase : lightBgBase,
      textPrimaryColor: isDark ? textPrimary : lightTextPrimary,
      textSecondaryColor: isDark ? textSecondary : lightTextSecondary,
    );
  }

  static ThemeData _buildTheme({
    required Brightness brightness,
    required ColorScheme scheme,
    required Color scaffoldBg,
    required Color textPrimaryColor,
    required Color textSecondaryColor,
  }) {
    return ThemeData(
      brightness: brightness,
      scaffoldBackgroundColor: scaffoldBg,
      colorScheme: scheme,
      appBarTheme: AppBarTheme(
        backgroundColor: scaffoldBg,
        elevation: 0,
        titleTextStyle: TextStyle(
          color: textPrimaryColor,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
        iconTheme: IconThemeData(color: textSecondaryColor),
      ),
      cardColor: brightness == Brightness.dark ? bgSurface : lightBgSurface,
      dividerColor:
          brightness == Brightness.dark ? borderColor : lightBorderColor,
      useMaterial3: true,
    );
  }
}
