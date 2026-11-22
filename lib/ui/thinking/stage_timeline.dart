import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../agents/trace.dart';
import '../glass/neon_timeline.dart' show formatClock;
import '../glass/tokens.dart';
import '../theme.dart';
import 'thinking_style.dart';

/// The vertical Thinking Timeline: one connected node per stage of the task, each with its icon, name, a
/// short factual description, time, status and — opened — the real events filed under it.
class StageTimeline extends StatefulWidget {
  const StageTimeline({
    super.key,
    required this.trace,
    required this.selectedStage,
    required this.selectedEvent,
    required this.onSelectStage,
    required this.onSelectEvent,
    this.autoScroll = true,
  });

  final ExecutionTrace trace;
  final Stage? selectedStage;
  final TraceEvent? selectedEvent;
  final void Function(Stage stage) onSelectStage;
  final void Function(TraceEvent event) onSelectEvent;
  final bool autoScroll;

  @override
  State<StageTimeline> createState() => _StageTimelineState();
}

class _StageTimelineState extends State<StageTimeline> {
  final Set<Stage> _open = <Stage>{};
  final Map<Stage, GlobalKey> _keys = <Stage, GlobalKey>{};
  final ScrollController _scroll = ScrollController();
  Stage? _lastCurrent;
  Timer? _tick;

  GlobalKey _key(Stage s) => _keys.putIfAbsent(s, GlobalKey.new);

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
    _scroll.dispose();
    super.dispose();
  }

  void _follow(Stage? current) {
    if (!widget.autoScroll || current == null || current == _lastCurrent) return;
    _lastCurrent = current;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _keys[current]?.currentContext;
      if (!mounted || ctx == null) return;
      Scrollable.ensureVisible(ctx, duration: GlassTokens.base, curve: Curves.easeOutCubic, alignment: 0.15);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.trace;
    return ListenableBuilder(
      listenable: t,
      builder: (context, _) {
        final stages = t.visibleStages;
        _follow(t.running ? t.current : null);
        return ListView.builder(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(6, 4, 6, 12),
          itemCount: stages.length,
          itemBuilder: (context, i) => _StageRow(
            key: _key(stages[i]),
            trace: t,
            stage: stages[i],
            first: i == 0,
            last: i == stages.length - 1,
            open: _open.contains(stages[i]),
            selected: widget.selectedStage == stages[i] && widget.selectedEvent == null,
            selectedEvent: widget.selectedEvent,
            onToggle: () => setState(() => _open.contains(stages[i]) ? _open.remove(stages[i]) : _open.add(stages[i])),
            onSelect: () => widget.onSelectStage(stages[i]),
            onSelectEvent: widget.onSelectEvent,
          ),
        );
      },
    );
  }
}

class _StageRow extends StatelessWidget {
  const _StageRow({
    super.key,
    required this.trace,
    required this.stage,
    required this.first,
    required this.last,
    required this.open,
    required this.selected,
    required this.selectedEvent,
    required this.onToggle,
    required this.onSelect,
    required this.onSelectEvent,
  });

  final ExecutionTrace trace;
  final Stage stage;
  final bool first;
  final bool last;
  final bool open;
  final bool selected;
  final TraceEvent? selectedEvent;
  final VoidCallback onToggle;
  final VoidCallback onSelect;
  final void Function(TraceEvent) onSelectEvent;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final status = trace.statusOf(stage);
    final color = stageColor(status, p);
    final events = trace.eventsOf(stage);
    final started = trace.stageStart(stage);
    final dur = trace.stageDuration(stage);
    final dim = status == StageStatus.pending || status == StageStatus.cancelled;
    final meta = <String>[
      if (started != null) formatClock(started),
      if (dur != null && status != StageStatus.pending) durLabel(dur),
    ];
    final lit = status != StageStatus.pending;
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          width: 34,
          child: Column(children: [
            Container(width: 2, height: 6, color: first ? Colors.transparent : (lit ? p.accent.withValues(alpha: 0.7) : p.separator)),
            _Node(status: status, icon: stageIcon(stage), color: color),
            Expanded(child: Container(width: 2, color: last ? Colors.transparent : (status == StageStatus.completed || status == StageStatus.failed ? color.withValues(alpha: 0.7) : p.separator))),
          ]),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8, left: 4),
            child: AnimatedContainer(
              duration: GlassTokens.fast,
              decoration: BoxDecoration(
                color: selected ? p.accent.withValues(alpha: 0.10) : p.fill,
                borderRadius: BorderRadius.circular(GlassTokens.radiusSm),
                border: Border.all(color: selected ? p.accent.withValues(alpha: 0.55) : (status == StageStatus.running ? color.withValues(alpha: 0.45) : p.rim), width: GlassTokens.stroke),
                boxShadow: status == StageStatus.running ? [BoxShadow(color: p.glow.withValues(alpha: 0.14), blurRadius: 14)] : null,
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                InkWell(
                  borderRadius: BorderRadius.circular(GlassTokens.radiusSm),
                  onTap: onSelect,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(child: Text(stage.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: dim ? p.secondary : null))),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(7)),
                          child: Text(stageStatusLabel(status), style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: color)),
                        ),
                        if (events.isNotEmpty)
                          InkWell(
                            onTap: onToggle,
                            borderRadius: BorderRadius.circular(12),
                            child: Padding(
                              padding: const EdgeInsets.all(6),
                              child: Icon(open ? CupertinoIcons.chevron_up : CupertinoIcons.chevron_down, size: 14, color: p.secondary),
                            ),
                          )
                        else
                          const SizedBox(width: 8),
                      ]),
                      const SizedBox(height: 2),
                      Text(events.isEmpty && stage != Stage.analyzing ? stage.blurb : trace.summaryOf(stage), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: p.secondary, height: 1.25)),
                      if (meta.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text(meta.join('  ·  '), style: TextStyle(fontSize: 11.5, color: p.secondary, fontFeatures: const [FontFeature.tabularFigures()])),
                        ),
                    ]),
                  ),
                ),
                if (open)
                  for (final e in events)
                    _EventTile(event: e, trace: trace, selected: identical(e, selectedEvent), onTap: () => onSelectEvent(e)),
                if (open) const SizedBox(height: 4),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.event, required this.trace, required this.selected, required this.onTap});

  final TraceEvent event;
  final ExecutionTrace trace;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final color = event.failed ? kFailed : (event.running ? p.accent : (event.kind == TraceKind.warning ? kWaiting : kDone));
    final took = event.running ? DateTime.now().difference(event.at) : event.took;
    return InkWell(
      onTap: onTap,
      child: Container(
        color: selected ? p.accent.withValues(alpha: 0.12) : null,
        padding: const EdgeInsets.fromLTRB(12, 6, 10, 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 2), child: Icon(kindIcon(event.kind), size: 13, color: color)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(event.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, height: 1.25)),
              if (event.detail.isNotEmpty) Text(event.detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: p.secondary)),
            ]),
          ),
          const SizedBox(width: 6),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(offsetLabel(event.at.difference(trace.startedAt)), style: TextStyle(fontSize: 10.5, color: p.secondary, fontFeatures: const [FontFeature.tabularFigures()])),
            if (took != null) Text(durLabel(took), style: TextStyle(fontSize: 10.5, color: event.running ? p.accent : p.secondary, fontFeatures: const [FontFeature.tabularFigures()])),
          ]),
        ]),
      ),
    );
  }
}

/// The circle of a stage: an icon, and a soft pulsing ring while the stage is working or waiting.
class _Node extends StatefulWidget {
  const _Node({required this.status, required this.icon, required this.color});

  final StageStatus status;
  final IconData icon;
  final Color color;

  @override
  State<_Node> createState() => _NodeState();
}

class _NodeState extends State<_Node> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));

  bool get _animated => widget.status == StageStatus.running || widget.status == StageStatus.waiting;

  @override
  void initState() {
    super.initState();
    if (_animated) _c.repeat();
  }

  @override
  void didUpdateWidget(covariant _Node old) {
    super.didUpdateWidget(old);
    if (_animated && !_c.isAnimating) {
      _c.repeat();
    } else if (!_animated && _c.isAnimating) {
      _c.stop();
      _c.value = 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final done = widget.status == StageStatus.completed;
    final failed = widget.status == StageStatus.failed;
    return SizedBox(
      width: 30,
      height: 30,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final v = _c.value;
          return Stack(alignment: Alignment.center, children: [
            if (_animated)
              Container(
                width: 22 + 8 * v,
                height: 22 + 8 * v,
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: widget.color.withValues(alpha: 0.55 * (1 - v)), width: 1.6)),
              ),
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.color.withValues(alpha: done || failed ? 0.9 : 0.14),
                border: Border.all(color: widget.color, width: 1.4),
                boxShadow: _animated ? [BoxShadow(color: p.glow.withValues(alpha: 0.4), blurRadius: 10)] : null,
              ),
              child: Icon(
                failed ? CupertinoIcons.xmark : (done ? CupertinoIcons.checkmark_alt : widget.icon),
                size: 13,
                color: done || failed ? Colors.black.withValues(alpha: 0.8) : widget.color,
              ),
            ),
          ]);
        },
      ),
    );
  }
}
