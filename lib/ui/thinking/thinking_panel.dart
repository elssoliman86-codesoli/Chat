import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../agents/trace.dart';
import '../../data/services.dart';
import '../glass/tokens.dart';
import '../theme.dart';
import 'agent_monitor.dart';
import 'overview_bar.dart';
import 'stage_timeline.dart';
import 'step_inspector.dart';

/// The Thinking panel under the chat: an execution overview, the stage timeline, and the step inspector.
/// It is drawn from the real trace of the conversation's latest task. Collapsed it is one line; opened it
/// has two panes (timeline and inspector) that can be resized by dragging, and it can be hidden entirely
/// from Settings, the chat menu, or its own close button.
class ThinkingPanel extends StatefulWidget {
  const ThinkingPanel({super.key, required this.conversationId});

  final String conversationId;

  @override
  State<ThinkingPanel> createState() => _ThinkingPanelState();
}

class _ThinkingPanelState extends State<ThinkingPanel> {
  bool _open = false;
  double _height = 0.5; // share of the screen height when open
  double _split = 0.5; // share of the panel given to the timeline
  Stage? _stage;
  TraceEvent? _event;
  ExecutionTrace? _seen;
  ExecutionTrace? _autoOpened;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[store, engine.traces]),
      builder: (context, _) {
        if (!store.settings.thinkingPanel) return const SizedBox.shrink();
        final trace = engine.traces.of(widget.conversationId);
        if (trace == null) return const SizedBox.shrink();
        if (!identical(trace, _seen)) {
          // A new task started: forget the old selection, and open the panel for a task that is running.
          _seen = trace;
          _stage = null;
          _event = null;
        }
        final p = paletteOf(context);
        final media = MediaQuery.of(context);
        // With the keyboard up there is little room: the panel shrinks to what is left instead of covering the chat.
        final screen = Size(media.size.width, (media.size.height - media.viewInsets.bottom).clamp(240.0, media.size.height));
        final panelHeight = (screen.height * _height).clamp(160.0, screen.height * 0.78);
        return ListenableBuilder(
          listenable: trace,
          builder: (context, _) {
            // The first time something is being written or reasoned live, open the panel so it can be watched.
            if (trace.running && !identical(_autoOpened, trace) && trace.events.any((e) => e.preview || e.reasoningLength > 0)) {
              _autoOpened = trace;
              _open = true;
              _split = 0.3;
            }
            return _shell(context, trace, p, screen, panelHeight);
          },
        );
      },
    );
  }

  Widget _shell(BuildContext context, ExecutionTrace trace, Palette p, Size screen, double panelHeight) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          child: Container(
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(GlassTokens.radiusMd),
              border: Border.all(color: p.rim, width: GlassTokens.stroke),
              boxShadow: [BoxShadow(color: p.shadow, blurRadius: 18, offset: const Offset(0, 6))],
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (_open)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragUpdate: (d) => setState(() => _height = (_height - d.delta.dy / screen.height).clamp(0.25, 0.78)),
                  child: SizedBox(
                    height: 16,
                    child: Center(child: Container(width: 38, height: 4, decoration: BoxDecoration(color: p.secondary.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(2)))),
                  ),
                ),
              _Header(
                trace: trace,
                open: _open,
                onToggle: () => setState(() => _open = !_open),
                onHide: () {
                  store.settings.thinkingPanel = false;
                  store.saveSettings();
                  store.changed();
                },
              ),
              if (_open) ...[
                Padding(padding: const EdgeInsets.fromLTRB(12, 2, 12, 10), child: ExecutionOverview(trace: trace)),
                AgentMonitor(trace: trace),
                SizedBox(
                  height: panelHeight,
                  child: LayoutBuilder(builder: (context, box) {
                    final wide = box.maxWidth >= 640;
                    final timeline = StageTimeline(
                      trace: trace,
                      autoScroll: store.settings.thinkingAutoScroll,
                      selectedStage: _stage,
                      selectedEvent: _event,
                      onSelectStage: (s) => setState(() {
                        _stage = s;
                        _event = null;
                      }),
                      onSelectEvent: (e) => setState(() {
                        _event = e;
                        _stage = e.stage;
                      }),
                    );
                    final inspector = StepInspector(trace: trace, stage: _stage, event: _event);
                    if (wide) {
                      final w = box.maxWidth;
                      return Row(children: [
                        SizedBox(width: w * _split - 5, child: timeline),
                        _Divider(
                          vertical: true,
                          onDrag: (d) => setState(() => _split = (_split + d / w).clamp(0.28, 0.72)),
                        ),
                        Expanded(child: inspector),
                      ]);
                    }
                    final h = box.maxHeight;
                    return Column(children: [
                      SizedBox(height: h * _split - 5, child: timeline),
                      _Divider(
                        vertical: false,
                        onDrag: (d) => setState(() => _split = (_split + d / h).clamp(0.25, 0.75)),
                      ),
                      Expanded(child: inspector),
                    ]);
                  }),
                ),
              ],
            ]),
          ),
        );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.trace, required this.open, required this.onToggle, required this.onHide});

  final ExecutionTrace trace;
  final bool open;
  final VoidCallback onToggle;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Row(children: [
          Icon(CupertinoIcons.waveform_path_ecg, size: 16, color: p.accent),
          const SizedBox(width: 8),
          Expanded(child: open ? const Text('Thinking', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)) : ExecutionOverview(trace: trace, compact: true)),
          if (open)
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: store.settings.thinkingAutoScroll ? 'Auto-scroll is on' : 'Auto-scroll is off',
              icon: Icon(CupertinoIcons.arrow_down_to_line, size: 18, color: store.settings.thinkingAutoScroll ? p.accent : p.secondary),
              onPressed: () {
                store.settings.thinkingAutoScroll = !store.settings.thinkingAutoScroll;
                store.saveSettings();
                store.changed();
              },
            ),
          Icon(open ? CupertinoIcons.chevron_down : CupertinoIcons.chevron_up, size: 15, color: p.secondary),
          IconButton(visualDensity: VisualDensity.compact, tooltip: 'Hide the Thinking panel', icon: Icon(CupertinoIcons.xmark, size: 16, color: p.secondary), onPressed: onHide),
        ]),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider({required this.vertical, required this.onDrag});

  final bool vertical;
  final void Function(double delta) onDrag;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: vertical ? null : (d) => onDrag(d.delta.dy),
      onHorizontalDragUpdate: vertical ? (d) => onDrag(d.delta.dx) : null,
      child: MouseRegion(
        cursor: vertical ? SystemMouseCursors.resizeColumn : SystemMouseCursors.resizeRow,
        child: SizedBox(
          width: vertical ? 10 : double.infinity,
          height: vertical ? double.infinity : 10,
          child: Center(
            child: Container(
              width: vertical ? 3 : 36,
              height: vertical ? 36 : 3,
              decoration: BoxDecoration(color: p.accent.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(2)),
            ),
          ),
        ),
      ),
    );
  }
}
