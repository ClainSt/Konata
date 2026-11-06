import 'dart:io';
import 'package:flutter/material.dart';
import '../core/app_theme.dart';

/// Shared NipaPlay Personal visual baseline for every CCPlayer screen.
class NipaPlayStyle {
  static Color get accent => AppTheme.instance.accent.color;
  static Color get onAccent => AppTheme.instance.accent.foreground;

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
        onPrimary: onAccent,
        secondary: accent,
        onSecondary: onAccent,
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
        helperMaxLines: 3,
        errorMaxLines: 3,
        helperStyle: TextStyle(
          fontSize: 13,
          height: 1.5,
          color: foreground.withValues(alpha: .65),
        ),
        filled: true,
        fillColor: foreground.withValues(alpha: .035),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: dark ? const Color(0xff252525) : Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        titleTextStyle: TextStyle(
          fontSize: 21,
          fontWeight: FontWeight.w600,
          color: foreground,
        ),
      ),
      dividerTheme: DividerThemeData(
        color: foreground.withValues(alpha: .09),
        thickness: 1,
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
        iconColor: foreground.withValues(alpha: .65),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: foreground.withValues(alpha: .055),
        selectedColor: accent.withValues(alpha: .12),
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: dark ? const Color(0xff292929) : Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: dark ? const Color(0xff252525) : Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: accent),
      sliderTheme: SliderThemeData(
        activeTrackColor: accent,
        thumbColor: accent,
        inactiveTrackColor: foreground.withValues(alpha: .12),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: onAccent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          minimumSize: const Size(48, 48),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: foreground.withValues(alpha: .75),
          minimumSize: const Size(48, 48),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: foreground,
          minimumSize: const Size(48, 48),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          side: BorderSide(color: foreground.withValues(alpha: .18)),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          foregroundColor: onAccent,
          backgroundColor: accent,
          elevation: 0,
          minimumSize: const Size(48, 48),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(44, 44),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
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
