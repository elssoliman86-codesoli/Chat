import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../agents/orchestrator.dart';
import '../../agents/trace.dart';
import '../glass/neon_timeline.dart' show formatClock;
import '../glass/tokens.dart';
import '../theme.dart';
import 'thinking_style.dart';

Color workerColor(WorkerState s, Palette p) => switch (s) {
      WorkerState.active => p.accent,
      WorkerState.waiting => kWaiting,
      WorkerState.completed => kDone,
      WorkerState.failed => kFailed,
      WorkerState.stopped => p.secondary,
      WorkerState.idle => p.secondary,
    };

/// The Multi-Agent Monitor: one glass card per worker, with its task, model, state, time, tokens, last event
/// and result, plus the orchestrator's own progress. Drawn from the orchestrator's live state.
class AgentMonitor extends StatefulWidget {
  const AgentMonitor({super.key, required this.trace});

  final ExecutionTrace trace;

  @override
  State<AgentMonitor> createState() => _AgentMonitorState();
}

class _AgentMonitorState extends State<AgentMonitor> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      final o = widget.trace.orchestrator;
      if (mounted && o != null && o.running) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.trace.orchestrator;
    if (o == null) return const SizedBox.shrink();
    final p = paletteOf(context);
    return ListenableBuilder(
      listenable: o,
      builder: (context, _) {
        final done = o.tasks.where((t) => t.state == TaskState.done).length;
        final failed = o.tasks.where((t) => t.state == TaskState.failed).length;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: Row(children: [
              const Icon(CupertinoIcons.person_2_fill, size: 15, color: kAgentPurple),
              const SizedBox(width: 6),
              const Text('Multi-Agent Monitor', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
              const Spacer(),
              Text(
                '${o.workers.length} worker${o.workers.length == 1 ? '' : 's'}  ·  $done/${o.tasks.length} tasks${failed > 0 ? '  ·  $failed failed' : ''}',
                style: TextStyle(fontSize: 11.5, color: p.secondary, fontFeatures: const [FontFeature.tabularFigures()]),
              ),
              if (o.running)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Stop all workers',
                  icon: const Icon(CupertinoIcons.stop_circle, size: 20, color: kFailed),
                  onPressed: o.cancel,
                ),
            ]),
          ),
          SizedBox(
            height: 172,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              children: [
                _OrchestratorCard(orchestrator: o),
                for (final w in o.workers) _WorkerCard(worker: w),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ]);
      },
    );
  }
}

class _GlassBox extends StatelessWidget {
  const _GlassBox({required this.color, required this.child, this.glow = false});

  final Color color;
  final Widget child;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Container(
      width: 232,
      margin: const EdgeInsets.only(right: 8),
      decoration: BoxDecoration(
        color: p.fill,
        borderRadius: BorderRadius.circular(GlassTokens.radiusSm),
        border: Border.all(color: color.withValues(alpha: 0.45), width: GlassTokens.stroke),
        boxShadow: glow ? [BoxShadow(color: color.withValues(alpha: 0.22), blurRadius: 14)] : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(height: 2.5, color: color.withValues(alpha: 0.85)),
        Expanded(child: Padding(padding: const EdgeInsets.fromLTRB(10, 8, 10, 8), child: child)),
      ]),
    );
  }
}

class _OrchestratorCard extends StatelessWidget {
  const _OrchestratorCard({required this.orchestrator});

  final Orchestrator orchestrator;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final o = orchestrator;
    int n(TaskState s) => o.tasks.where((t) => t.state == s).length;
    final running = o.running;
    return _GlassBox(
      color: kAgentPurple,
      glow: running,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(CupertinoIcons.slider_horizontal_3, size: 14, color: kAgentPurple),
          const SizedBox(width: 6),
          const Expanded(child: Text('Orchestrator', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5))),
          _Pill(label: o.cancelled ? 'Stopped' : (running ? 'Active' : 'Finished'), color: o.cancelled ? p.secondary : (running ? kAgentPurple : kDone)),
        ]),
        const SizedBox(height: 6),
        Text('Mode: ${o.config.mode}  ·  up to ${o.concurrencyFor(o.tasks.length)} at once', style: TextStyle(fontSize: 11.5, color: p.secondary)),
        const Spacer(),
        _Line('Waiting', '${n(TaskState.queued)}', p),
        _Line('Running', '${n(TaskState.running)}', p),
        _Line('Done', '${n(TaskState.done)}', p),
        _Line('Failed / skipped', '${n(TaskState.failed)} / ${n(TaskState.cancelled)}', p),
        if (o.locks.conflicts.isNotEmpty) Text('⚠ ${o.locks.conflicts.length} file conflict${o.locks.conflicts.length == 1 ? '' : 's'}', style: const TextStyle(fontSize: 11.5, color: kWaiting)),
      ]),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.k, this.v, this.p);

  final String k;
  final String v;
  final Palette p;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(children: [
          Expanded(child: Text(k, style: TextStyle(fontSize: 11.5, color: p.secondary))),
          Text(v, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()])),
        ]),
      );
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(7)),
        child: Text(label, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: color)),
      );
}

class _WorkerCard extends StatelessWidget {
  const _WorkerCard({required this.worker});

  final WorkerInfo worker;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return ListenableBuilder(
      listenable: worker,
      builder: (context, _) {
        final w = worker;
        final color = workerColor(w.state, p);
        final active = w.state == WorkerState.active;
        return GestureDetector(
          onTap: w.result.isEmpty ? null : () => _showResult(context, w),
          child: _GlassBox(
            color: active ? p.accent : (w.state == WorkerState.idle ? p.rim : color),
            glow: active,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(CupertinoIcons.person_crop_circle, size: 15, color: color),
                const SizedBox(width: 6),
                Expanded(child: Text(w.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5))),
                _Pill(label: workerStateLabel(w.state), color: color),
              ]),
              const SizedBox(height: 4),
              Text(w.taskTitle.isEmpty ? 'No task yet' : w.taskTitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, height: 1.2)),
              Text(w.model, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: p.secondary, fontFamily: 'monospace')),
              const Spacer(),
              if (w.startedAt != null)
                Text(
                  'Started ${formatClock(w.startedAt!)}  ·  ${durLabel(w.elapsed)}  ·  ${w.tokens} tok',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: p.secondary, fontFeatures: const [FontFeature.tabularFigures()]),
                ),
              const SizedBox(height: 2),
              Text(
                w.state == WorkerState.completed && w.result.isNotEmpty ? w.result.replaceAll(RegExp(r'\s+'), ' ') : w.lastEvent,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: w.state == WorkerState.failed ? kFailed : p.secondary, height: 1.25),
              ),
            ]),
          ),
        );
      },
    );
  }

  void _showResult(BuildContext context, WorkerInfo w) {
    showDialog<void>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('${w.name} — ${w.taskTitle}'),
        content: SingleChildScrollView(child: SelectableText(w.result)),
        actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('Close'))],
      ),
    );
  }
}
