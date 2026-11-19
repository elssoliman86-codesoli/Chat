import 'package:flutter/material.dart';

/// Shared measurements of the glass design system, so every component lines up.
class GlassTokens {
  const GlassTokens._();

  static const double radiusSm = 12;
  static const double radiusMd = 16;
  static const double radiusLg = 22;

  /// Thin translucent border.
  static const double stroke = 0.8;

  /// One icon scale for the whole app (outline icons, same optical weight).
  static const double iconSm = 16;
  static const double iconMd = 20;
  static const double iconLg = 24;

  static const double controlHeight = 44;
  static const double controlHeightCompact = 36;

  /// Blur strengths. Kept modest: blur is the most expensive thing on a phone GPU, so it is only used
  /// on a few large surfaces (navigation, dialogs, sheets), never per list row.
  static const double blurSoft = 14;
  static const double blurStrong = 24;

  static const Duration fast = Duration(milliseconds: 140);
  static const Duration base = Duration(milliseconds: 240);
}

/// The states a status dot, a timeline step or a badge can be in.
enum GlassStatus { idle, running, success, warning, error, cancelled }

Color glassStatusColor(GlassStatus s, Color accent, Color neutral) => switch (s) {
      GlassStatus.running => accent,
      GlassStatus.success => const Color(0xFF30D158),
      GlassStatus.warning => const Color(0xFFFF9F0A),
      GlassStatus.error => const Color(0xFFFF453A),
      GlassStatus.cancelled => neutral,
      GlassStatus.idle => neutral,
    };

String glassStatusLabel(GlassStatus s) => switch (s) {
      GlassStatus.running => 'Running',
      GlassStatus.success => 'Done',
      GlassStatus.warning => 'Warning',
      GlassStatus.error => 'Failed',
      GlassStatus.cancelled => 'Cancelled',
      GlassStatus.idle => 'Idle',
    };
