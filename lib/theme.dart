import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppThemes {
  static final ThemeData _base = ThemeData.light(useMaterial3: true);

  // Shared neutrals
  static const Color _bgNeutral = Color(0xFFF5F7F6);
  static const Color _cardNeutral = Color(0xFFFFFFFF);
  static const Color _surfaceTint = Color(0xFFE9ECEF);
  static const Color _textStrong = Color(0xFF111827); // slate-900
  static const Color _textMedium = Color(0xFF475569); // slate-600
  static const Color _outline = Color(0xFFE2E8F0);

  static TextTheme _baseText(ThemeData base) {
    final body = GoogleFonts.manropeTextTheme(base.textTheme);
    final display = GoogleFonts.spaceGroteskTextTheme(base.textTheme);
    return body.copyWith(
      displayLarge: display.displayLarge?.copyWith(fontWeight: FontWeight.w700, color: _textStrong),
      displayMedium: display.displayMedium?.copyWith(fontWeight: FontWeight.w700, color: _textStrong),
      displaySmall: display.displaySmall?.copyWith(fontWeight: FontWeight.w700, color: _textStrong),
      headlineLarge: display.headlineLarge?.copyWith(fontWeight: FontWeight.w700, color: _textStrong),
      headlineMedium: display.headlineMedium?.copyWith(fontWeight: FontWeight.w700, color: _textStrong),
      headlineSmall: display.headlineSmall?.copyWith(fontWeight: FontWeight.w700, color: _textStrong),
      titleLarge: display.titleLarge?.copyWith(fontWeight: FontWeight.w700, color: _textStrong),
      titleMedium: display.titleMedium?.copyWith(fontWeight: FontWeight.w700, color: _textStrong),
      titleSmall: display.titleSmall?.copyWith(fontWeight: FontWeight.w700, color: _textStrong),
      bodyLarge: body.bodyLarge?.copyWith(fontWeight: FontWeight.w500, color: _textMedium),
      bodyMedium: body.bodyMedium?.copyWith(fontWeight: FontWeight.w500, color: _textMedium),
      labelLarge: body.labelLarge?.copyWith(fontWeight: FontWeight.w700),
    );
  }

  static ThemeData _themeFor({
    required Color primary,
    required Color secondary,
    required Color appBarBg,
    required Color chipBg,
  }) {
    final scheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: Brightness.light,
      primary: primary,
      secondary: secondary,
      surface: _cardNeutral,
      surfaceVariant: _surfaceTint,
      outline: _outline,
      onSurface: _textStrong,
      onPrimary: Colors.white,
      onSecondary: Colors.white,
    );

    final textTheme = _baseText(_base);

    return _base.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: _bgNeutral,
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: appBarBg,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: textTheme.titleLarge?.copyWith(color: Colors.white),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      cardTheme: CardThemeData(
        color: _cardNeutral,
        elevation: 1,
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        shadowColor: Colors.black12,
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        iconColor: scheme.primary,
        textColor: _textStrong,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: chipBg,
        selectedColor: scheme.primary.withOpacity(0.12),
        labelStyle: textTheme.labelMedium?.copyWith(color: _textStrong),
        secondaryLabelStyle: textTheme.labelMedium?.copyWith(color: _textStrong),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      ),
      dividerTheme: const DividerThemeData(color: _outline, thickness: 1, space: 1),
      dialogTheme: DialogThemeData(
        backgroundColor: _cardNeutral,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: _cardNeutral,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          foregroundColor: Colors.white,
          backgroundColor: primary,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          textStyle: textTheme.labelLarge?.copyWith(color: Colors.white),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          foregroundColor: Colors.white,
          backgroundColor: primary,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: textTheme.labelLarge?.copyWith(color: Colors.white),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primary,
          side: BorderSide(color: scheme.outline),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: textTheme.labelLarge?.copyWith(color: primary),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primary,
          textStyle: textTheme.labelLarge?.copyWith(color: primary),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: primary,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: _cardNeutral,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
        labelStyle: textTheme.bodyMedium?.copyWith(color: _textMedium),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: _textStrong,
        contentTextStyle: textTheme.bodyMedium?.copyWith(color: Colors.white),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }

  /// Admin Theme – warm neutral with golden accent
  static final ThemeData adminTheme = _themeFor(
    primary: const Color(0xFF14532D), // deep forest
    secondary: const Color(0xFFB45309), // brass
    appBarBg: const Color(0xFF14532D),
    chipBg: const Color(0xFFF3E8D2),
  );

  /// Member Theme – cool neutral with soft accent
  static final ThemeData memberTheme = _themeFor(
    primary: const Color(0xFF0F766E), // deep teal
    secondary: const Color(0xFF0284C7), // ocean blue
    appBarBg: const Color(0xFF0F766E),
    chipBg: const Color(0xFFE0F2F1),
  );
}
