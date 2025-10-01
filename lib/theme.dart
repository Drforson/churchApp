import 'package:flutter/material.dart';

class AppThemes {
  static final ThemeData _base = ThemeData.light(useMaterial3: true);

  // Shared neutrals
  static const Color _bgNeutral = Color(0xFFF7F8FA);
  static const Color _cardNeutral = Colors.white;
  static const Color _textStrong = Color(0xFF1F2937); // slate-800
  static const Color _textMedium = Color(0xFF4B5563); // slate-600

  /// Admin Theme – warm neutral with golden accent
  static final ThemeData adminTheme = _base.copyWith(
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFFDAA520), // goldenrod
      brightness: Brightness.light,
      primary: const Color(0xFFDAA520),
      secondary: const Color(0xFF6D4C41), // earthy brown
      surface: _cardNeutral,
      onSurface: _textStrong,
    ),
    scaffoldBackgroundColor: _bgNeutral,
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFFDAA520),
      foregroundColor: Colors.white,
      elevation: 1,
      centerTitle: true,
      titleTextStyle: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        color: Colors.white,
      ),
    ),
    textTheme: _base.textTheme.copyWith(
      headlineSmall: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: _textStrong),
      titleMedium: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: _textStrong),
      titleSmall: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _textStrong),
      bodyLarge: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: _textMedium),
      bodyMedium: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: _textMedium),
      labelLarge: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white),
    ),
    cardTheme: CardThemeData(
      color: _cardNeutral,
      elevation: 4,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      shadowColor: Colors.black12,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        foregroundColor: Colors.white,
        backgroundColor: const Color(0xFFDAA520),
        elevation: 3,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: _cardNeutral,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFF60A5FA)), // solid Color, not swatch
      ),
      labelStyle: const TextStyle(color: _textStrong),
    ),
  );

  /// Member Theme – cool neutral with soft accent
  static final ThemeData memberTheme = _base.copyWith(
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF607D8B), // BlueGrey seed
      brightness: Brightness.light,
      primary: const Color(0xFF607D8B),
      secondary: const Color(0xFFFFB74D), // warm peach
      surface: _cardNeutral,
      onSurface: _textStrong,
    ),
    scaffoldBackgroundColor: const Color(0xFFEEF1F5), // neutral cool gray
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFF607D8B),
      foregroundColor: Colors.white,
      elevation: 1,
      centerTitle: true,
      titleTextStyle: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        color: Colors.white,
      ),
    ),
    textTheme: _base.textTheme.copyWith(
      headlineSmall: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: _textStrong),
      titleMedium: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: _textStrong),
      titleSmall: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _textStrong),
      bodyLarge: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: _textMedium),
      bodyMedium: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: _textMedium),
      labelLarge: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white),
    ),
    cardTheme: CardThemeData(
      color: _cardNeutral,
      elevation: 4,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      shadowColor: Colors.black12,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        foregroundColor: Colors.white,
        backgroundColor: const Color(0xFF607D8B),
        elevation: 3,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: _cardNeutral,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFF6366F1)), // indigo focus
      ),
      labelStyle: const TextStyle(color: _textStrong),
    ),
  );
}
