import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../agents/trace.dart';
import '../../data/services.dart';
import '../theme.dart';

/// The live view under the chat: just the model's thinking and whatever it is writing right now (a file, a
/// command), as plain streaming text. Nothing else. While the assistant works it shows one status line and the
/// stream; when it is done it shrinks to "Thought for 12s", which opens the text again. It can be hidden from
/// Settings, the chat menu, or its own close button.
class ThinkingPanel extends StatefulWidget {
  const ThinkingPanel({super.key, required this.conversationId});

  final String conversationId;

  @override
  State<ThinkingPanel> createState() => _ThinkingPanelState();
}

class _ThinkingPanelState extends State<ThinkingPanel> {
  /// What the person chose by tapping; null follows the default (open while text is streaming in).
  bool? _expanded;
  bool _dismissed = false;
  ExecutionTrace? _seen;

  static const TextStyle _mono = TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.4);

  String _clock(Duration d) {
    final s = d.inSeconds;
    return s >= 60 ? '${s ~/ 60}m ${(s % 60).toString().padLeft(2, '0')}s' : '${s}s';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[store, engine.traces]),
      builder: (context, _) {
        if (!store.settings.thinkingPanel) return const SizedBox.shrink();
        final trace = engine.traces.of(widget.conversationId);
        if (trace == null) return const SizedBox.shrink();
        if (!identical(trace, _seen)) {
          _seen = trace;
          _expanded = null;
          _dismissed = false;
        }
        if (_dismissed) return const SizedBox.shrink();
        return ListenableBuilder(listenable: trace, builder: (context, _) => _body(context, trace));
      },
    );
  }

  Widget _body(BuildContext context, ExecutionTrace trace) {
    // Something being written right now (a file, a command) comes first, then the model's own thinking.
    TraceEvent? writing;
    TraceEvent? thought;
    for (final e in trace.events.reversed) {
      if (writing == null && e.preview) writing = e;
      if (thought == null && e.reasoningLength > 0) thought = e;
    }
    final running = trace.running;
    final text = writing != null && writing.output.isNotEmpty ? writing.output : (thought?.reasoning ?? '');
    // Nothing to read and nothing happening: stay out of the way.
    if (!running && text.isEmpty) return const SizedBox.shrink();

    final p = paletteOf(context);
    final media = MediaQuery.of(context);
    final room = (media.size.height - media.viewInsets.bottom) * 0.33;
    final open = _expanded ?? (running && text.isNotEmpty);

    String label;
    if (writing != null) {
      label = writing.title;
    } else if (running && thought != null && thought.running) {
      label = 'Thinking…';
    } else if (running) {
      label = trace.statusText;
    } else {
      label = 'Thought for ${_clock(trace.elapsed)}';
    }
    if (running && trace.activeWorkers > 0) label = '$label · ${trace.activeWorkers} workers';

    final shown = text.length > 9000 ? '…${text.substring(text.length - 9000)}' : text;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
      child: Container(
        decoration: BoxDecoration(
          color: p.fill,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: p.rim.withValues(alpha: 0.5), width: 0.6),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: text.isEmpty ? null : () => setState(() => _expanded = !open),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
              child: Row(children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: running ? p.accent : p.secondary),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: p.secondary)),
                ),
                if (running) Text(_clock(trace.elapsed), style: TextStyle(fontSize: 12, color: p.secondary)),
                if (text.isNotEmpty) Icon(open ? CupertinoIcons.chevron_down : CupertinoIcons.chevron_up, size: 14, color: p.secondary),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 16,
                  color: p.secondary,
                  tooltip: 'Hide',
                  icon: const Icon(CupertinoIcons.xmark),
                  onPressed: () => setState(() => _dismissed = true),
                ),
              ]),
            ),
          ),
          if (open && text.isNotEmpty)
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: room.clamp(90.0, 260.0)),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                // Anchored to the bottom, so the newest text is always in view while it streams.
                child: SingleChildScrollView(
                  reverse: running,
                  child: SelectableText(shown, style: _mono.copyWith(color: p.secondary)),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}
