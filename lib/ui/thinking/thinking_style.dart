import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../agents/trace.dart';
import '../theme.dart';

/// Colors of the AI-execution views: cyan/blue = working, purple = agents, green = done, red = failed.
const Color kAgentPurple = Color(0xFFBF5AF2);
const Color kDone = Color(0xFF30D158);
const Color kFailed = Color(0xFFFF453A);
const Color kWaiting = Color(0xFFFF9F0A);

Color stageColor(StageStatus s, Palette p) => switch (s) {
      StageStatus.running => p.accent,
      StageStatus.completed => kDone,
      StageStatus.failed => kFailed,
      StageStatus.waiting => kWaiting,
      StageStatus.cancelled => p.secondary,
      StageStatus.pending => p.secondary.withValues(alpha: 0.7),
    };

IconData stageIcon(Stage s) => switch (s) {
      Stage.analyzing => CupertinoIcons.doc_text_search,
      Stage.understanding => CupertinoIcons.lightbulb,
      Stage.planning => CupertinoIcons.list_number,
      Stage.researching => CupertinoIcons.globe,
      Stage.files => CupertinoIcons.folder,
      Stage.delegating => CupertinoIcons.person_2,
      Stage.executing => CupertinoIcons.chevron_left_slash_chevron_right,
      Stage.reviewing => CupertinoIcons.eye,
      Stage.testing => CupertinoIcons.checkmark_shield,
      Stage.finalizing => CupertinoIcons.text_bubble,
    };

IconData kindIcon(TraceKind k) => switch (k) {
      TraceKind.model => CupertinoIcons.sparkles,
      TraceKind.tool => CupertinoIcons.wrench,
      TraceKind.command => CupertinoIcons.square_line_vertical_square,
      TraceKind.file => CupertinoIcons.doc,
      TraceKind.delegate => CupertinoIcons.person_2,
      TraceKind.plan => CupertinoIcons.list_number,
      TraceKind.warning => CupertinoIcons.exclamationmark_triangle,
      TraceKind.error => CupertinoIcons.xmark_octagon,
      TraceKind.status => CupertinoIcons.circle,
    };

/// A time like +12.4s measured from the start of the task.
String offsetLabel(Duration d) {
  final s = d.inMilliseconds / 1000;
  if (s < 60) return '+${s.toStringAsFixed(1)}s';
  final m = d.inMinutes;
  return '+${m}m${(d.inSeconds % 60).toString().padLeft(2, '0')}s';
}

String durLabel(Duration d) {
  final ms = d.inMilliseconds;
  if (ms < 1000) return '${ms}ms';
  final s = ms / 1000;
  if (s < 60) return '${s.toStringAsFixed(1)}s';
  return '${d.inMinutes}m ${(d.inSeconds % 60).toString().padLeft(2, '0')}s';
}

const TextStyle kMono = TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.35);
