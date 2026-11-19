import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
    this.fill = const Color(0x14FFFFFF),
    this.rim = const Color(0x26FFFFFF),
    this.sheen = const Color(0x1FFFFFFF),
    this.glow = const Color(0xFF22D3EE),
    this.surface = const Color(0xEB0E1830),
    this.shadow = const Color(0x66000000),
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

  /// Frosted-glass tokens shared by every glass component: the translucent fill, the thin bright border
  /// (rim), the soft top-left highlight (sheen), the restrained cyan glow, the stronger fill used for
  /// dialogs/sheets (surface) and the soft drop shadow.
  final Color fill;
  final Color rim;
  final Color sheen;
  final Color glow;
  final Color surface;
  final Color shadow;

  // Opaque, not translucent: on a scrolling list every bubble/cell used to be alpha-blended over the
  // gradient backdrop on every frame, which is far more GPU work than an opaque fill and is what made
  // this theme feel noticeably heavier than the others while messages streamed in. These are the same
  // colors pre-blended once (flattened over the gradient's tone) instead of blended live each frame.
  static const Palette emerald = Palette(
    bubble: Color(0xFF105A43),
    field: Color(0xFF345F53),
    grouped: Color(0x00000000),
    cell: Color(0xFF2A574A),
    separator: Color(0x2EFFFFFF),
    secondary: Color(0xFF9FD8C3),
    accent: Color(0xFF34D399),
    glass: true,
  );

  /// Midnight glass: deep navy, translucent frosted surfaces, restrained electric blue and cyan.
  static const Palette dark = Palette(
    bubble: Color(0xFF172647),
    field: Color(0x1AFFFFFF),
    grouped: Color(0x00000000),
    cell: Color(0x14FFFFFF),
    separator: Color(0x1FFFFFFF),
    secondary: Color(0xFF93A4C6),
    accent: Color(0xFF4A8DFF),
    glass: true,
    fill: Color(0x14FFFFFF),
    rim: Color(0x2EFFFFFF),
    sheen: Color(0x24FFFFFF),
    glow: Color(0xFF22D3EE),
    surface: Color(0xEB0D172E),
    shadow: Color(0x73000000),
  );

  /// Frosted light: pale blue-white glass with a crisp white rim.
  static const Palette light = Palette(
    bubble: Color(0xFFDDE8FB),
    field: Color(0xA6FFFFFF),
    grouped: Color(0x00000000),
    cell: Color(0xB3FFFFFF),
    separator: Color(0x1F0B1B3A),
    secondary: Color(0xFF55658A),
    accent: Color(0xFF1F63F0),
    glass: true,
    fill: Color(0xA6FFFFFF),
    rim: Color(0xE6FFFFFF),
    sheen: Color(0xB3FFFFFF),
    glow: Color(0xFF0EA5C6),
    surface: Color(0xF2F4F8FF),
    shadow: Color(0x330B1B3A),
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

/// The scene behind every page. Static, so it is painted once and kept in its own layer: a deep gradient
/// with two soft light pools (blue top-left, cyan bottom-right) that give the glass something to refract.
class AppBackdrop extends StatelessWidget {
  const AppBackdrop({super.key, required this.emerald, required this.child});

  final bool emerald;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final Widget scene;
    if (emerald) {
      scene = const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF03281E), Color(0xFF065F46), Color(0xFF022C22)],
            stops: [0.0, 0.55, 1.0],
          ),
        ),
        child: SizedBox.expand(),
      );
    } else if (dark) {
      scene = const _Scene(
        top: Color(0xFF060B1A),
        bottom: Color(0xFF0A1530),
        poolA: Color(0x332F6BFF),
        poolB: Color(0x1F22D3EE),
      );
    } else {
      scene = const _Scene(
        top: Color(0xFFEFF4FD),
        bottom: Color(0xFFDDE8FA),
        poolA: Color(0x402F6BFF),
        poolB: Color(0x3322D3EE),
      );
    }
    return Stack(children: [
      Positioned.fill(child: RepaintBoundary(child: scene)),
      Positioned.fill(child: child),
    ]);
  }
}

class _Scene extends StatelessWidget {
  const _Scene({required this.top, required this.bottom, required this.poolA, required this.poolB});

  final Color top;
  final Color bottom;
  final Color poolA;
  final Color poolB;

  @override
  Widget build(BuildContext context) {
    return Stack(fit: StackFit.expand, children: [
      DecoratedBox(
        decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [top, bottom])),
      ),
      DecoratedBox(
        decoration: BoxDecoration(gradient: RadialGradient(center: const Alignment(-0.9, -0.85), radius: 0.9, colors: [poolA, poolA.withValues(alpha: 0)])),
      ),
      DecoratedBox(
        decoration: BoxDecoration(gradient: RadialGradient(center: const Alignment(0.95, 0.9), radius: 0.85, colors: [poolB, poolB.withValues(alpha: 0)])),
      ),
    ]);
  }
}

ThemeData buildTheme(Brightness b, {bool emerald = false}) {
  final dark = b == Brightness.dark;
  final p = emerald ? Palette.emerald : (dark ? Palette.dark : Palette.light);
  // Every page sits on the AppBackdrop scene, so scaffolds are transparent and glass shows through.
  const bg = Colors.transparent;
  final solid = emerald ? const Color(0xFF06281F) : (dark ? const Color(0xFF070D1F) : const Color(0xFFEAF1FC));
  final fg = emerald ? const Color(0xFFFFFFFF) : (dark ? const Color(0xFFF2F6FF) : const Color(0xFF0B1426));
  final radius14 = RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));
  final rimSide = BorderSide(color: p.rim, width: 0.8);
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
    onInverseSurface: solid,
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
    iconTheme: IconThemeData(size: 22, color: fg),
    appBarTheme: AppBarTheme(
      backgroundColor: bg,
      foregroundColor: fg,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 0,
      centerTitle: true,
      systemOverlayStyle: dark || emerald ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      titleTextStyle: TextStyle(color: fg, fontSize: 17, fontWeight: FontWeight.w600),
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: emerald ? const Color(0xF2052A20) : p.surface,
      surfaceTintColor: Colors.transparent,
      width: 316,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: emerald ? const Color(0xF2052A20) : p.surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: emerald ? const Color(0xFF06281F) : p.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: rimSide),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: emerald ? const Color(0xFF0B3A2D) : p.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: rimSide),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: dark || emerald ? const Color(0xF2152445) : const Color(0xF20E1B36),
      contentTextStyle: const TextStyle(color: Colors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: p.rim, width: 0.8)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.field,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: p.rim, width: 0.8)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: p.rim, width: 0.8)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: p.accent, width: 1.2)),
      errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: iosRed, width: 1)),
      focusedErrorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: iosRed, width: 1.2)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Color.lerp(p.accent, Colors.black, emerald ? 0.35 : 0.18),
        foregroundColor: Colors.white,
        minimumSize: const Size(44, 44),
        shape: radius14,
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: p.accent, shape: radius14, textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(foregroundColor: p.accent, side: rimSide, shape: radius14, minimumSize: const Size(44, 44)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: const WidgetStatePropertyAll<Color>(Colors.white),
      trackColor: WidgetStateProperty.resolveWith<Color>(
          (s) => s.contains(WidgetState.selected) ? p.accent : (dark ? const Color(0xFF26355A) : const Color(0xFFC9D6EE))),
      trackOutlineColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
    ),
    sliderTheme: SliderThemeData(activeTrackColor: p.accent, thumbColor: Colors.white),
    textTheme: ThemeData(brightness: b).textTheme.apply(bodyColor: fg, displayColor: fg),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: p.accent),
    dividerTheme: DividerThemeData(color: p.separator, thickness: 0.5, space: 0.5),
  );
}

/// Backwards-compatible helper: the user bubble color.
Color userBubble(BuildContext context) => paletteOf(context).bubble;
