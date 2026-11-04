import 'dart:io';
import 'package:flutter/material.dart';

/// CCPlayer temporarily follows the existing NipaPlay Personal desktop/tablet
/// Material visual language, with its original rose accent and Han font.
class NipaPlayStyle {
  static const Color accent = Color.fromARGB(255, 255, 46, 85);

  static ThemeData theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final foreground = dark ? Colors.white : Colors.black87;
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      fontFamily: Platform.isWindows ? 'Microsoft YaHei' : null,
      colorScheme: ColorScheme(
        brightness: brightness,
        primary: accent,
        onPrimary: Colors.white,
        secondary: accent,
        onSecondary: Colors.white,
        surface: dark ? const Color(0xff1f1f1f) : Colors.white,
        onSurface: foreground,
        error: Colors.red,
        onError: Colors.white,
      ),
      scaffoldBackgroundColor: dark ? const Color(0xff1f1f1f) : Colors.white,
      appBarTheme: AppBarTheme(
        backgroundColor: dark ? const Color(0xff1f1f1f) : Colors.white,
        foregroundColor: foreground,
        scrolledUnderElevation: 0,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: dark ? const Color(0xff292929) : const Color(0xfff9f9f9),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: foreground.withValues(alpha: .09)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: accent),
      ),
    );
    TextStyle? zh(TextStyle? s) =>
        s?.copyWith(locale: const Locale('zh', 'Hans'));
    final t = base.textTheme;
    return base.copyWith(
      textTheme: t.copyWith(
        displayLarge: zh(t.displayLarge),
        displayMedium: zh(t.displayMedium),
        headlineLarge: zh(t.headlineLarge),
        headlineMedium: zh(t.headlineMedium),
        headlineSmall: zh(t.headlineSmall),
        titleLarge: zh(t.titleLarge),
        titleMedium: zh(t.titleMedium),
        bodyLarge: zh(t.bodyLarge),
        bodyMedium: zh(t.bodyMedium),
        bodySmall: zh(t.bodySmall),
        labelLarge: zh(t.labelLarge),
        labelMedium: zh(t.labelMedium),
        labelSmall: zh(t.labelSmall),
      ),
    );
  }
}
