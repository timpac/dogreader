import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Shared colors also cover custom-painted surfaces and the reader's TextSpan.
const background = Color(0xFFFEFDFC);
const panel = Color(0xFFF5F4F6);
const accent = Color(0xFF655087);
const textPrimary = Color(0xFF28262D);
const textSecondary = Color(0xFF66616F);
const divider = Color(0xFFE1DDE6);

ThemeData dogreaderLightTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: Brightness.light,
  ).copyWith(
    primary: accent,
    onPrimary: Colors.white,
    primaryContainer: const Color(0xFFEEE8F5),
    onPrimaryContainer: const Color(0xFF433159),
    secondary: textSecondary,
    onSecondary: Colors.white,
    secondaryContainer: const Color(0xFFEEE8F5),
    onSecondaryContainer: const Color(0xFF433159),
    surface: background,
    onSurface: textPrimary,
    onSurfaceVariant: textSecondary,
    surfaceContainerLowest: Colors.white,
    surfaceContainerLow: panel,
    surfaceContainer: panel,
    surfaceContainerHigh: const Color(0xFFEEECEF),
    surfaceContainerHighest: const Color(0xFFE8E5EC),
    outline: const Color(0xFF8A8293),
    outlineVariant: divider,
    error: const Color(0xFFAB3131),
    onError: Colors.white,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme);
  final rounded = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(16),
  );
  return base.copyWith(
    scaffoldBackgroundColor: background,
    textTheme: base.textTheme.apply(
      bodyColor: textPrimary,
      displayColor: textPrimary,
    ),
    dividerColor: divider,
    appBarTheme: const AppBarTheme(
      backgroundColor: background,
      foregroundColor: textPrimary,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      systemOverlayStyle: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
        systemNavigationBarColor: background,
        systemNavigationBarIconBrightness: Brightness.dark,
      ),
    ),
    cardTheme: CardThemeData(
      color: panel,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: rounded.copyWith(side: const BorderSide(color: divider)),
      clipBehavior: Clip.antiAlias,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      indicatorColor: scheme.primaryContainer,
      labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
        color: states.contains(WidgetState.selected) ? accent : textSecondary,
        fontSize: 12,
        fontWeight: states.contains(WidgetState.selected)
            ? FontWeight.w700 : FontWeight.w500,
      )),
      iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
        color: states.contains(WidgetState.selected) ? accent : textSecondary,
      )),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: Colors.white,
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        shape: rounded,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: accent,
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        side: BorderSide(color: scheme.outline),
        shape: rounded,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: accent,
        minimumSize: const Size(48, 48),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: panel,
      contentPadding: const EdgeInsets.all(16),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: divider),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: accent, width: 2),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
      shape: rounded,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: background,
      surfaceTintColor: Colors.transparent,
      shape: rounded.copyWith(side: const BorderSide(color: divider)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: textPrimary,
      contentTextStyle: const TextStyle(color: Colors.white),
      actionTextColor: const Color(0xFFE0D2F6),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: accent,
      linearTrackColor: scheme.surfaceContainerHighest,
    ),
    sliderTheme: base.sliderTheme.copyWith(
      activeTrackColor: accent,
      thumbColor: accent,
      inactiveTrackColor: scheme.surfaceContainerHighest,
    ),
  );
}
