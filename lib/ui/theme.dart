import 'package:flutter/material.dart';

const Color accent = Color(0xFF10A37F);

ThemeData buildTheme(Brightness b) {
  final dark = b == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: b,
    surface: dark ? const Color(0xFF212121) : const Color(0xFFFFFFFF),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    drawerTheme: DrawerThemeData(backgroundColor: dark ? const Color(0xFF171717) : const Color(0xFFF7F7F8)),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
    ),
  );
}

Color userBubble(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark ? const Color(0xFF2F2F2F) : const Color(0xFFF0F0F0);
