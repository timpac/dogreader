import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Shared colors also cover custom-painted surfaces and the reader's TextSpan.
const background = Color(0xFFFEFDFC);
const panel = Color(0xFFF5F4F6);
const accent = Color(0xFF655087);
const textPrimary = Color(0xFF28262D);
const textSecondary = Color(0xFF66616F);
const divider = Color(0xFFE1DDE6);

ThemeData dogreaderLightTheme() => _dogreaderTheme(Brightness.light);

ThemeData dogreaderDarkTheme() => _dogreaderTheme(Brightness.dark);

ThemeData _dogreaderTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final background = dark ? const Color(0xFF10131A) : const Color(0xFFFEFDFC);
  final panel = dark ? const Color(0xFF202638) : const Color(0xFFF5F4F6);
  final accent = dark ? const Color(0xFFB7A6F6) : const Color(0xFF655087);
  final textPrimary = dark ? const Color(0xFFF3F0F8) : const Color(0xFF28262D);
  final textSecondary = dark ? const Color(0xFFBBB7C6) : const Color(0xFF66616F);
  final divider = dark ? const Color(0xFF353D54) : const Color(0xFFE1DDE6);
  final tint = dark ? const Color(0xFF37304B) : const Color(0xFFEEE8F5);
  final onTint = dark ? const Color(0xFFEBDEF9) : const Color(0xFF433159);
  final scheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: brightness,
  ).copyWith(
    primary: accent,
    onPrimary: dark ? const Color(0xFF21182F) : Colors.white,
    primaryContainer: tint,
    onPrimaryContainer: onTint,
    secondary: textSecondary,
    onSecondary: dark ? background : Colors.white,
    secondaryContainer: tint,
    onSecondaryContainer: onTint,
    surface: background,
    onSurface: textPrimary,
    onSurfaceVariant: textSecondary,
    surfaceContainerLowest: dark ? background : Colors.white,
    surfaceContainerLow: panel,
    surfaceContainer: panel,
    surfaceContainerHigh: dark ? const Color(0xFF293047) : const Color(0xFFEEECEF),
    surfaceContainerHighest: dark ? const Color(0xFF353D54) : const Color(0xFFE8E5EC),
    outline: dark ? const Color(0xFF948B9F) : const Color(0xFF8A8293),
    outlineVariant: divider,
    error: dark ? const Color(0xFFFFB4AB) : const Color(0xFFAB3131),
    onError: dark ? const Color(0xFF690005) : Colors.white,
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
    appBarTheme: AppBarTheme(
      backgroundColor: background,
      foregroundColor: textPrimary,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      systemOverlayStyle: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
        statusBarBrightness: brightness,
        systemNavigationBarColor: background,
        systemNavigationBarIconBrightness: dark ? Brightness.light : Brightness.dark,
      ),
    ),
    cardTheme: CardThemeData(
      color: panel,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: rounded.copyWith(side: BorderSide(color: divider)),
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
        foregroundColor: scheme.onPrimary,
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
        borderSide: BorderSide(color: divider),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: accent, width: 2),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
      shape: rounded,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: background,
      surfaceTintColor: Colors.transparent,
      shape: rounded.copyWith(side: BorderSide(color: divider)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: textPrimary,
      contentTextStyle: TextStyle(color: background),
      actionTextColor: dark ? const Color(0xFF573477) : const Color(0xFFE0D2F6),
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
