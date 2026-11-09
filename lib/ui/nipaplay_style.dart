import 'dart:io';
import 'package:flutter/material.dart';
import '../core/app_theme.dart';
import 'konata_motion.dart';

/// The approved Konata archive palette, shared by pages and dialogs.
class NipaPlayStyle {
  static Color get accent => AppTheme.instance.accent.color;
  static Color get onAccent => AppTheme.instance.accent.foreground;

  static ThemeData theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final foreground = dark ? const Color(0xffe4e9e5) : const Color(0xff202923);
    final surface = dark ? const Color(0xff171d1b) : const Color(0xfff6f7f2);
    final primary = dark && AppTheme.instance.accent == ThemeAccent.sage
        ? const Color(0xff9bc5b5)
        : accent;
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      fontFamily: Platform.isWindows ? 'Microsoft YaHei' : null,
      colorScheme: ColorScheme(
        brightness: brightness,
        primary: primary,
        onPrimary: primary == accent ? onAccent : const Color(0xff17392b),
        secondary: accent,
        onSecondary: onAccent,
        surface: surface,
        surfaceContainerLow: dark
            ? const Color(0xff202724)
            : const Color(0xffedf0eb),
        surfaceContainerHighest: dark
            ? const Color(0xff303a34)
            : const Color(0xffe2e8e1),
        onSurfaceVariant: dark
            ? const Color(0xffa6b1aa)
            : const Color(0xff66736a),
        outlineVariant: dark
            ? const Color(0xff46524b)
            : const Color(0xffced7cf),
        onSurface: foreground,
        error: Colors.red,
        onError: Colors.white,
      ),
      scaffoldBackgroundColor: surface,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.windows: KonataPageTransitions(),
          TargetPlatform.linux: KonataPageTransitions(),
          TargetPlatform.macOS: KonataPageTransitions(),
          TargetPlatform.android: KonataPageTransitions(),
        },
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: surface,
        foregroundColor: foreground,
        scrolledUnderElevation: 0,
        elevation: 0,
        titleTextStyle: TextStyle(
          color: foreground,
          fontSize: 22,
          fontWeight: FontWeight.w600,
          fontFamily: Platform.isWindows ? 'Microsoft YaHei' : null,
        ),
      ),
      cardTheme: CardThemeData(
        color: dark ? const Color(0xff202724) : const Color(0xfff1f3ee),
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
        backgroundColor: surface,
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
        color: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
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
          textStyle: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            fontFamily: Platform.isWindows ? 'Microsoft YaHei' : null,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: foreground.withValues(alpha: .75),
          minimumSize: const Size(48, 48),
          textStyle: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            fontFamily: Platform.isWindows ? 'Microsoft YaHei' : null,
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: foreground,
          minimumSize: const Size(48, 48),
          textStyle: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            fontFamily: Platform.isWindows ? 'Microsoft YaHei' : null,
          ),
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
          textStyle: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            fontFamily: Platform.isWindows ? 'Microsoft YaHei' : null,
          ),
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
