import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// iOS system colors.
const Color iosBlue = Color(0xFF0A84FF);
const Color iosGreen = Color(0xFF30D158);
const Color iosOrange = Color(0xFFFF9F0A);
const Color iosRed = Color(0xFFFF453A);
const Color iosPurple = Color(0xFFBF5AF2);
const Color iosTeal = Color(0xFF64D2FF);
const Color iosIndigo = Color(0xFF5E5CE6);
const Color iosGray = Color(0xFF8E8E93);

/// Extra colors the chat uses on top of the color scheme.
class Palette extends ThemeExtension<Palette> {
  const Palette({
    required this.bubble,
    required this.field,
    required this.grouped,
    required this.cell,
    required this.separator,
    required this.secondary,
    this.accent = iosBlue,
    this.glass = false,
  });

  final Color bubble;
  final Color field;
  final Color grouped;
  final Color cell;
  final Color separator;
  final Color secondary;
  final Color accent;

  /// Glass look: translucent surfaces over a gradient, glossy icon tiles.
  final bool glass;

  static const Palette emerald = Palette(
    bubble: Color(0x3334D399),
    field: Color(0x2EFFFFFF),
    grouped: Color(0x00000000),
    cell: Color(0x24FFFFFF),
    separator: Color(0x2EFFFFFF),
    secondary: Color(0xFF9FD8C3),
    accent: Color(0xFF34D399),
    glass: true,
  );

  static const Palette dark = Palette(
    bubble: Color(0xFF2C2C2E),
    field: Color(0xFF1C1C1E),
    grouped: Color(0xFF000000),
    cell: Color(0xFF1C1C1E),
    separator: Color(0xFF38383A),
    secondary: Color(0xFF8E8E93),
  );

  static const Palette light = Palette(
    bubble: Color(0xFFF2F2F7),
    field: Color(0xFFF2F2F7),
    grouped: Color(0xFFF2F2F7),
    cell: Color(0xFFFFFFFF),
    separator: Color(0xFFC6C6C8),
    secondary: Color(0xFF8E8E93),
  );

  @override
  Palette copyWith() => this;

  @override
  Palette lerp(ThemeExtension<Palette>? other, double t) => this;
}

Palette paletteOf(BuildContext context) => Theme.of(context).extension<Palette>() ?? Palette.dark;

ThemeMode themeModeFor(String mode) => switch (mode) {
      'light' => ThemeMode.light,
      'system' => ThemeMode.system,
      _ => ThemeMode.dark,
    };

/// Gradient behind every page in the emerald theme.
class AppBackdrop extends StatelessWidget {
  const AppBackdrop({super.key, required this.emerald, required this.child});

  final bool emerald;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!emerald) return child;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF03281E), Color(0xFF065F46), Color(0xFF022C22)],
          stops: [0.0, 0.55, 1.0],
        ),
      ),
      child: child,
    );
  }
}

ThemeData buildTheme(Brightness b, {bool emerald = false}) {
  final dark = b == Brightness.dark;
  final p = emerald ? Palette.emerald : (dark ? Palette.dark : Palette.light);
  final bg = emerald ? Colors.transparent : (dark ? const Color(0xFF000000) : const Color(0xFFFFFFFF));
  final solid = emerald ? const Color(0xFF06281F) : bg;
  final fg = dark ? const Color(0xFFFFFFFF) : const Color(0xFF000000);
  final scheme = ColorScheme(
    brightness: b,
    primary: p.accent,
    onPrimary: emerald ? const Color(0xFF02150F) : Colors.white,
    secondary: p.accent,
    onSecondary: Colors.white,
    error: iosRed,
    onError: Colors.white,
    surface: solid,
    onSurface: fg,
    surfaceContainerHighest: p.bubble,
    surfaceContainerHigh: p.field,
    outline: p.separator,
    outlineVariant: p.separator,
    inverseSurface: fg,
    onInverseSurface: bg,
  );
  return ThemeData(
    useMaterial3: true,
    platform: TargetPlatform.iOS,
    brightness: b,
    colorScheme: scheme,
    scaffoldBackgroundColor: bg,
    canvasColor: bg,
    dividerColor: p.separator,
    hintColor: p.secondary,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    extensions: <ThemeExtension<dynamic>>[p],
    appBarTheme: AppBarTheme(
      backgroundColor: bg,
      foregroundColor: fg,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 0,
      centerTitle: true,
      titleTextStyle: TextStyle(color: fg, fontSize: 17, fontWeight: FontWeight.w600),
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: emerald ? const Color(0xF2052A20) : (dark ? const Color(0xFF0A0A0A) : const Color(0xFFFFFFFF)),
      surfaceTintColor: Colors.transparent,
      width: 316,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: emerald ? const Color(0xF2052A20) : (dark ? const Color(0xFF1C1C1E) : const Color(0xFFFFFFFF)),
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: emerald ? const Color(0xFF06281F) : (dark ? const Color(0xFF1C1C1E) : const Color(0xFFFFFFFF)),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: emerald ? const Color(0xFF0B3A2D) : (dark ? const Color(0xFF2C2C2E) : const Color(0xFFFFFFFF)),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: dark ? const Color(0xFF2C2C2E) : const Color(0xFF1C1C1E),
      contentTextStyle: const TextStyle(color: Colors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.cell,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: p.accent)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: const WidgetStatePropertyAll<Color>(Colors.white),
      trackColor: WidgetStateProperty.resolveWith<Color>(
          (s) => s.contains(WidgetState.selected) ? (emerald ? p.accent : iosGreen) : (dark ? const Color(0xFF39393D) : const Color(0xFFE9E9EA))),
      trackOutlineColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
    ),
    sliderTheme: SliderThemeData(activeTrackColor: p.accent, thumbColor: Colors.white),
    textTheme: ThemeData(brightness: b).textTheme.apply(bodyColor: fg, displayColor: fg),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: p.accent),
  );
}

/// Backwards-compatible helper: the user bubble color.
Color userBubble(BuildContext context) => paletteOf(context).bubble;
