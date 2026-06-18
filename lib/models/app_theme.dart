import 'package:flutter/material.dart';

class AppTheme {
  static const Color bgBase      = Color(0xFF0F0F11);
  static const Color bgSurface   = Color(0xFF1A1A1E);
  static const Color bgBubbleAI  = Color(0xFF1E1E24);
  static const Color bgBubbleUser= Color(0xFF1E2A1E);
  static const Color borderColor = Color(0xFF2E2E36);
  static const Color accentAmber = Color(0xFFF59E0B);
  static const Color accentGreen = Color(0xFF4ADE80);
  static const Color accentRed   = Color(0xFFEF4444);
  static const Color accentBlue  = Color(0xFF60A5FA);
  static const Color textPrimary  = Color(0xFFF1F1F3);
  static const Color textSecondary= Color(0xFF8B8B9B);
  static const Color textMuted    = Color(0xFF4B4B5B);

  static ThemeData get dark => ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: bgBase,
    colorScheme: const ColorScheme.dark(
      primary: accentAmber,
      secondary: accentGreen,
      surface: bgSurface,
      error: accentRed,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: bgBase,
      elevation: 0,
      titleTextStyle: TextStyle(
        color: textPrimary, fontSize: 16, fontWeight: FontWeight.w600,
      ),
      iconTheme: IconThemeData(color: textSecondary),
    ),
    cardColor: bgSurface,
    dividerColor: borderColor,
  );
}
