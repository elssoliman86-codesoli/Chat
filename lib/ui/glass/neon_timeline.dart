import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import 'tokens.dart';

/// Where one step of a workflow is, as reported by the code that is actually running it.
enum StepStatus { pending, running, completed, failed, cancelled }

/// One step of a [NeonProgressTimeline]. Every field comes from real execution state: the timeline only
/// draws what it is given and never advances on its own.
class TimelineStep {
  const TimelineStep({
    required this.id,
    required this.title,
    required this.status,
    this.description = '',
    this.startedAt,
    this.duration,
    this.details,
    this.icon,
  });

  final String id;
  final String title;
  final StepStatus status;
  final String description;

  /// When the step really started (null while it is still waiting).
  final DateTime? startedAt;

  /// How long it really took (null until it has finished).
  final Duration? duration;

  /// Optional output shown when the step is expanded (a tool's result, an error message…).
  final String? details;
  final IconData? icon;

  bool get started => status != StepStatus.pending;
}

String formatClock(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

String formatDuration(Duration d) {
  if (d.inMilliseconds < 1000) return '${d.inMilliseconds} ms';
  if (d.inSeconds < 60) return '${(d.inMilliseconds / 1000).toStringAsFixed(1)} s';
  return '${d.inMinutes} min ${d.inSeconds % 60} s';
}

String stepStatusLabel(StepStatus s) => switch (s) {
      StepStatus.pending => 'waiting',
      StepStatus.running => 'running',
      StepStatus.completed => 'completed',
      StepStatus.failed => 'failed',
      StepStatus.cancelled => 'cancelled',
    };

Color stepColor(StepStatus s, Palette p) => switch (s) {
      StepStatus.pending => p.secondary,
      StepStatus.running => p.accent,
      StepStatus.completed => const Color(0xFF30D158),
      StepStatus.failed => const Color(0xFFFF453A),
      StepStatus.cancelled => p.secondary,
    };

/// A vertical connected timeline: a circular indicator per step, a thin luminous line between steps that
/// lights up (animated) as each step finishes, and a glowing electric-blue ring on the active step.
class NeonProgressTimeline extends StatefulWidget {
  const NeonProgressTimeline({super.key, required this.steps, this.initiallyOpen = const <String>{}});

  final List<TimelineStep> steps;

  /// Ids of steps whose details start expanded.
  final Set<String> initiallyOpen;

  @override
  State<NeonProgressTimeline> createState() => _NeonProgressTimelineState();
}

class _NeonProgressTimelineState extends State<NeonProgressTimeline> {
  late final Set<String> _open = {...widget.initiallyOpen};

  static const double _rail = 30;

  @override
  Widget build(BuildContext context) {
    final steps = widget.steps;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (var i = 0; i < steps.length; i++)
        _row(context, steps[i], isFirst: i == 0, isLast: i == steps.length - 1),
    ]);
  }

  Widget _row(BuildContext context, TimelineStep s, {required bool isFirst, required bool isLast}) {
    final p = paletteOf(context);
    final color = stepColor(s.status, p);
    final dim = s.status == StepStatus.pending || s.status == StepStatus.cancelled;
    final open = _open.contains(s.id);
    final hasDetails = s.details != null && s.details!.trim().isNotEmpty;
    final meta = <String>[
      if (s.startedAt != null) formatClock(s.startedAt!),
      if (s.duration != null) formatDuration(s.duration!),
      if (s.status == StepStatus.running) 'running…',
      if (s.status == StepStatus.failed) 'failed',
      if (s.status == StepStatus.cancelled) 'cancelled',
    ];
    // The segment above this step is lit once the step has started; the segment below it is lit once
    // the step is over (finished, failed or cancelled), so the line fills in as execution advances.
    final litAbove = s.started;
    final litBelow = s.status == StepStatus.completed || s.status == StepStatus.failed;
    return Semantics(
      container: true,
      label: '${s.title}, ${stepStatusLabel(s.status)}',
      child: Stack(children: [
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: _rail,
          child: _Rail(
            isFirst: isFirst,
            isLast: isLast,
            litAbove: litAbove,
            litBelow: litBelow,
            baseColor: p.separator.withValues(alpha: (p.separator.a * 2.2).clamp(0.0, 1.0)),
            litColor: p.accent,
            glowColor: p.glow,
            nodeCenterY: 17,
          ),
        ),
        Positioned(left: 0, top: 6, width: _rail, child: Center(child: _Node(status: s.status, accent: p.accent, secondary: p.secondary, icon: s.icon))),
        Padding(
          padding: const EdgeInsets.only(left: _rail + 8),
          child: InkWell(
            onTap: hasDetails ? () => setState(() => open ? _open.remove(s.id) : _open.add(s.id)) : null,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.only(top: 5, bottom: 9),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: Text(
                      s.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: dim ? p.secondary : null, height: 1.25),
                    ),
                  ),
                  if (hasDetails) Padding(padding: const EdgeInsets.only(left: 6, top: 2), child: Icon(open ? CupertinoIcons.chevron_up : CupertinoIcons.chevron_down, size: 13, color: p.secondary)),
                ]),
                if (s.description.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(s.description, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: p.secondary, height: 1.25)),
                  ),
                if (meta.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(meta.join('  ·  '), style: TextStyle(fontSize: 11.5, color: s.status == StepStatus.failed ? color : p.secondary, fontFeatures: const [FontFeature.tabularFigures()])),
                  ),
                if (open && hasDetails) _Details(text: s.details!),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

class _Details extends StatelessWidget {
  const _Details({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final shown = text.length > 3000 ? '${text.substring(0, 3000)}\n…(${text.length - 3000} more characters)' : text;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
      decoration: BoxDecoration(color: p.field, borderRadius: BorderRadius.circular(10), border: Border.all(color: p.rim, width: GlassTokens.stroke)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: SingleChildScrollView(child: SelectableText(shown, style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, height: 1.35))),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            style: TextButton.styleFrom(minimumSize: const Size(44, 30), padding: const EdgeInsets.symmetric(horizontal: 8), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context)
                ..hideCurrentSnackBar()
                ..showSnackBar(const SnackBar(content: Text('Copied'), duration: Duration(seconds: 1)));
            },
            child: const Text('Copy', style: TextStyle(fontSize: 12.5)),
          ),
        ),
      ]),
    );
  }
}

/// The connecting line of one row: a faint base line plus a luminous overlay that grows (animated)
/// when the segment becomes lit.
class _Rail extends StatelessWidget {
  const _Rail({
    required this.isFirst,
    required this.isLast,
    required this.litAbove,
    required this.litBelow,
    required this.baseColor,
    required this.litColor,
    required this.glowColor,
    required this.nodeCenterY,
  });

  final bool isFirst;
  final bool isLast;
  final bool litAbove;
  final bool litBelow;
  final Color baseColor;
  final Color litColor;
  final Color glowColor;
  final double nodeCenterY;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: litBelow ? 1 : 0),
      duration: const Duration(milliseconds: 550),
      curve: Curves.easeOutCubic,
      builder: (context, below, _) => TweenAnimationBuilder<double>(
        tween: Tween<double>(end: litAbove ? 1 : 0),
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOut,
        builder: (context, above, _) => CustomPaint(
          painter: _RailPainter(
            isFirst: isFirst,
            isLast: isLast,
            above: above,
            below: below,
            base: baseColor,
            lit: litColor,
            glow: glowColor,
            centerY: nodeCenterY,
          ),
        ),
      ),
    );
  }
}

class _RailPainter extends CustomPainter {
  _RailPainter({
    required this.isFirst,
    required this.isLast,
    required this.above,
    required this.below,
    required this.base,
    required this.lit,
    required this.glow,
    required this.centerY,
  });

  final bool isFirst;
  final bool isLast;
  final double above;
  final double below;
  final Color base;
  final Color lit;
  final Color glow;
  final double centerY;

  @override
  void paint(Canvas canvas, Size size) {
    final x = size.width / 2;
    final basePaint = Paint()
      ..color = base
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    final litPaint = Paint()
      ..color = lit
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    final glowPaint = Paint()
      ..color = glow.withValues(alpha: 0.45)
      ..strokeWidth = 4
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);

    void segment(double y0, double y1, double fill) {
      if (y1 <= y0) return;
      canvas.drawLine(Offset(x, y0), Offset(x, y1), basePaint);
      if (fill > 0) {
        final end = y0 + (y1 - y0) * fill;
        canvas.drawLine(Offset(x, y0), Offset(x, end), glowPaint);
        canvas.drawLine(Offset(x, y0), Offset(x, end), litPaint);
      }
    }

    if (!isFirst) segment(0, centerY, above);
    if (!isLast) segment(centerY, size.height, below);
  }

  @override
  bool shouldRepaint(_RailPainter o) =>
      o.above != above || o.below != below || o.base != base || o.lit != lit || o.glow != glow || o.isFirst != isFirst || o.isLast != isLast;
}

/// The circular indicator. Running: a glowing electric-blue ring with a sweeping arc.
class _Node extends StatelessWidget {
  const _Node({required this.status, required this.accent, required this.secondary, this.icon});

  final StepStatus status;
  final Color accent;
  final Color secondary;
  final IconData? icon;

  static const double size = 22;

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case StepStatus.running:
        return _RunningRing(color: accent);
      case StepStatus.completed:
        return _disc(const Color(0xFF30D158), CupertinoIcons.check_mark, filled: true);
      case StepStatus.failed:
        return _disc(const Color(0xFFFF453A), CupertinoIcons.xmark, filled: true);
      case StepStatus.cancelled:
        return _disc(secondary, CupertinoIcons.minus, filled: false);
      case StepStatus.pending:
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: secondary.withValues(alpha: 0.45), width: 1.4)),
          child: icon == null ? null : Icon(icon, size: 11, color: secondary.withValues(alpha: 0.6)),
        );
    }
  }

  Widget _disc(Color c, IconData i, {required bool filled}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: c.withValues(alpha: filled ? 0.18 : 0.10),
        border: Border.all(color: c.withValues(alpha: filled ? 0.9 : 0.55), width: 1.4),
        boxShadow: filled ? [BoxShadow(color: c.withValues(alpha: 0.35), blurRadius: 8)] : null,
      ),
      child: Icon(i, size: 12, color: c),
    );
  }
}

class _RunningRing extends StatefulWidget {
  const _RunningRing({required this.color});

  final Color color;

  @override
  State<_RunningRing> createState() => _RunningRingState();
}

class _RunningRingState extends State<_RunningRing> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox(
        width: 26,
        height: 26,
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) => CustomPaint(painter: _RingPainter(color: widget.color, t: _c.value)),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.color, required this.t});

  final Color color;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - 4;
    final pulse = 0.5 + 0.5 * math.sin(t * 2 * math.pi);
    // Outer glow that breathes.
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..color = color.withValues(alpha: 0.28 + 0.22 * pulse)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    // The ring itself.
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..color = color.withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );
    // A bright arc sweeping around it.
    final rect = Rect.fromCircle(center: c, radius: r);
    canvas.drawArc(
      rect,
      t * 2 * math.pi,
      math.pi * 0.7,
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawCircle(c, 2.2, Paint()..color = color.withValues(alpha: 0.7 + 0.3 * pulse));
  }

  @override
  bool shouldRepaint(_RingPainter o) => o.t != t || o.color != color;
}
