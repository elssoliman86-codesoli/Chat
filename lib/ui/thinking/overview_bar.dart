import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../agents/trace.dart';
import '../../data/services.dart';
import '../../llm/llm.dart' show StreamPhase;
import '../glass/glass.dart';
import '../glass/tokens.dart';
import '../theme.dart';
import 'thinking_style.dart';

/// The top bar of the Thinking panel: elapsed time, steps, agents, workers, tokens, speed and the status of
/// the task. Every number is read from the trace and the live stream.
class ExecutionOverview extends StatefulWidget {
  const ExecutionOverview({super.key, required this.trace, this.compact = false});

  final ExecutionTrace trace;

  /// One line instead of the full grid.
  final bool compact;

  @override
  State<ExecutionOverview> createState() => _ExecutionOverviewState();
}

class _ExecutionOverviewState extends State<ExecutionOverview> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && widget.trace.running) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  static String _clock(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}' : '${two(d.inMinutes)}:${two(d.inSeconds % 60)}';
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final t = widget.trace;
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[t, engine.metrics]),
      builder: (context, _) {
        final m = engine.metrics;
        final live = t.running && m.running;
        final tokens = t.tokens + (live ? m.totalTokens : 0);
        final tps = live ? m.tokensPerSecond : (t.generating.inMilliseconds > 500 ? t.tokens / (t.generating.inMilliseconds / 1000) : 0.0);
        final color = switch (t.outcome) {
          TraceOutcome.running => t.waiting ? kWaiting : p.accent,
          TraceOutcome.completed => kDone,
          TraceOutcome.failed => kFailed,
          TraceOutcome.cancelled => p.secondary,
        };
        final stats = <_Stat>[
          _Stat(CupertinoIcons.clock, 'Elapsed', _clock(t.elapsed), p.accent),
          _Stat(CupertinoIcons.checkmark_circle, 'Steps', '${t.stepsCompleted}/${t.stepsTotal}', kDone),
          _Stat(CupertinoIcons.play_circle, 'Running', '${t.stepsRunning}', p.accent),
          _Stat(CupertinoIcons.person_2, 'Agents', '${t.activeAgents}', kAgentPurple),
          _Stat(CupertinoIcons.square_stack_3d_up, 'Workers', '${t.activeWorkers}', kAgentPurple),
          _Stat(CupertinoIcons.number, 'Tokens', '${live && m.estimated ? '~' : ''}$tokens', p.accent),
          _Stat(CupertinoIcons.speedometer, 'Tokens/s', tps > 0 ? tps.toStringAsFixed(tps >= 10 ? 0 : 1) : '–', p.accent),
        ];
        final status = Row(mainAxisSize: MainAxisSize.min, children: [
          GlassStatusIndicator(
            status: switch (t.outcome) {
              TraceOutcome.running => t.waiting ? GlassStatus.warning : GlassStatus.running,
              TraceOutcome.completed => GlassStatus.success,
              TraceOutcome.failed => GlassStatus.error,
              TraceOutcome.cancelled => GlassStatus.cancelled,
            },
          ),
          const SizedBox(width: 8),
          Flexible(child: Text(t.statusText, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5, color: color))),
        ]);
        if (widget.compact) {
          return Row(children: [
            Expanded(child: status),
            const SizedBox(width: 10),
            Text(_clock(t.elapsed), style: TextStyle(fontSize: 12.5, color: p.secondary, fontFeatures: const [FontFeature.tabularFigures()])),
            const SizedBox(width: 10),
            Text('${t.stepsCompleted}/${t.stepsTotal} steps', style: TextStyle(fontSize: 12.5, color: p.secondary)),
            if (tps > 0) ...[
              const SizedBox(width: 10),
              Text('${tps.toStringAsFixed(tps >= 10 ? 0 : 1)} tok/s', style: TextStyle(fontSize: 12.5, color: p.accent)),
            ],
          ]);
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          status,
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [for (final s in stats) _Chip(stat: s)]),
          if (m.phase != StreamPhase.idle && (t.running || m.phase == StreamPhase.failed)) ...[
            const SizedBox(height: 8),
            Text('Connection: ${m.connection}${m.firstTokenLatency != null ? '  ·  first token ${(m.firstTokenLatency!.inMilliseconds / 1000).toStringAsFixed(1)}s' : ''}',
                style: TextStyle(fontSize: 11.5, color: p.secondary)),
          ],
        ]);
      },
    );
  }
}

class _Stat {
  const _Stat(this.icon, this.label, this.value, this.color);
  final IconData icon;
  final String label;
  final String value;
  final Color color;
}

class _Chip extends StatelessWidget {
  const _Chip({required this.stat});

  final _Stat stat;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: stat.color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(GlassTokens.radiusSm),
        border: Border.all(color: stat.color.withValues(alpha: 0.28), width: GlassTokens.stroke),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(stat.icon, size: 14, color: stat.color),
        const SizedBox(width: 6),
        Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(stat.label, style: TextStyle(fontSize: 10, letterSpacing: 0.3, color: p.secondary, height: 1.1)),
          Text(stat.value, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, height: 1.15, fontFeatures: [FontFeature.tabularFigures()])),
        ]),
      ]),
    );
  }
}
