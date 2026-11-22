import 'dart:ui' show FontFeature;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../agents/trace.dart';
import '../glass/neon_timeline.dart' show formatClock;
import '../glass/tokens.dart';
import '../theme.dart';
import 'thinking_style.dart';

/// The Live Step Inspector: the details behind the timeline — the task, the real events, the tools used,
/// terminal commands and their output, results, changed files, and problems. It shows what was recorded;
/// it never claims to show the model's hidden reasoning.
class StepInspector extends StatelessWidget {
  const StepInspector({super.key, required this.trace, this.stage, this.event});

  final ExecutionTrace trace;
  final Stage? stage;
  final TraceEvent? event;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: trace,
      builder: (context, _) {
        final p = paletteOf(context);
        final sel = event;
        final st = sel?.stage ?? stage ?? trace.current;
        final shown = sel != null ? <TraceEvent>[sel] : (st != null ? trace.eventsOf(st) : trace.events);
        final tools = trace.toolsUsed;
        final commands = trace.commands.where((e) => sel == null || identical(e, sel) || st == null || e.stage == st).toList();
        final files = trace.modifiedFiles;
        final problems = trace.problems;
        return ListView(
          padding: const EdgeInsets.fromLTRB(10, 4, 10, 14),
          children: [
            _Card(
              title: 'Task',
              icon: CupertinoIcons.doc_plaintext,
              children: [
                Text(trace.request.trim().isEmpty ? '(no text)' : trace.request.trim(), maxLines: 5, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, height: 1.3)),
                const SizedBox(height: 6),
                _kv(p, 'Model', trace.model.isEmpty ? '–' : trace.model),
                _kv(p, 'Started', formatClock(trace.startedAt)),
                _kv(p, 'Model passes', '${trace.passes}'),
                _kv(p, 'Status', trace.statusText),
              ],
            ),
            if (sel != null)
              _Card(
                title: 'Selected step',
                icon: kindIcon(sel.kind),
                color: sel.failed ? kFailed : null,
                children: [
                  Text(sel.title, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                  if (sel.detail.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 2), child: Text(sel.detail, style: TextStyle(fontSize: 12.5, color: p.secondary))),
                  const SizedBox(height: 6),
                  if (sel.tool.isNotEmpty) _kv(p, 'Tool', sel.tool),
                  _kv(p, 'Stage', sel.stage.title),
                  _kv(p, 'Started', '${formatClock(sel.at)}  (${offsetLabel(sel.at.difference(trace.startedAt))})'),
                  _kv(p, 'Took', sel.running ? 'running…' : (sel.took == null ? '–' : durLabel(sel.took!))),
                  if (sel.agent.isNotEmpty) _kv(p, 'Worker', sel.agent),
                  if (sel.output.isNotEmpty) ...[const SizedBox(height: 8), const _Label('Result'), _Terminal(text: sel.output, failed: sel.failed)],
                ],
              )
            else if (st != null)
              _Card(
                title: st.title,
                icon: stageIcon(st),
                children: [
                  Text(trace.summaryOf(st), style: const TextStyle(fontSize: 13, height: 1.3)),
                  const SizedBox(height: 4),
                  Text(st.blurb, style: TextStyle(fontSize: 12, color: p.secondary)),
                ],
              ),
            _Card(
              title: sel != null ? 'Event' : 'Events${st != null ? ' · ${st.title}' : ''}',
              icon: CupertinoIcons.list_bullet,
              children: shown.isEmpty
                  ? [Text('Nothing recorded for this stage yet.', style: TextStyle(fontSize: 12.5, color: p.secondary))]
                  : [for (final e in shown.reversed.take(14)) _EventLine(event: e, trace: trace)],
            ),
            if (tools.isNotEmpty)
              _Card(
                title: 'Tools used',
                icon: CupertinoIcons.wrench,
                children: [
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    for (final e in tools.entries)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: (e.value.failed > 0 ? kFailed : p.accent).withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: (e.value.failed > 0 ? kFailed : p.accent).withValues(alpha: 0.35), width: GlassTokens.stroke),
                        ),
                        child: Text('${e.key}${e.value.count > 1 ? ' ×${e.value.count}' : ''}${e.value.failed > 0 ? ' · ${e.value.failed} failed' : ''}', style: const TextStyle(fontSize: 11.5, fontFamily: 'monospace')),
                      ),
                  ]),
                ],
              ),
            if (commands.isNotEmpty)
              _Card(
                title: 'Terminal',
                icon: CupertinoIcons.chevron_left_slash_chevron_right,
                children: [
                  for (final e in commands.reversed.take(6)) ...[
                    _Terminal(text: '\$ ${e.command.trim()}${e.running ? '\n…running' : (e.output.isEmpty ? '' : '\n${e.output.trim()}')}', failed: e.failed),
                    const SizedBox(height: 6),
                  ],
                ],
              ),
            if (files.isNotEmpty)
              _Card(
                title: 'Modified files',
                icon: CupertinoIcons.doc_on_doc,
                children: [
                  for (final f in files)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(color: (f.failed ? kFailed : kDone).withValues(alpha: 0.15), borderRadius: BorderRadius.circular(6)),
                          child: Text(f.op, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: f.failed ? kFailed : kDone)),
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: Text(f.path, maxLines: 1, overflow: TextOverflow.ellipsis, style: kMono)),
                      ]),
                    ),
                ],
              ),
            if (problems.isNotEmpty)
              _Card(
                title: 'Errors & warnings',
                icon: CupertinoIcons.exclamationmark_triangle,
                color: kFailed,
                children: [
                  for (final e in problems.reversed.take(8))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(e.title, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: e.failed ? kFailed : kWaiting)),
                        if (e.detail.isNotEmpty || e.output.isNotEmpty)
                          Text((e.output.isNotEmpty ? e.output : e.detail).trim(), maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: p.secondary)),
                      ]),
                    ),
                ],
              ),
          ],
        );
      },
    );
  }

  static Widget _kv(Palette p, String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1.5),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 84, child: Text(k, style: TextStyle(fontSize: 12, color: p.secondary))),
          Expanded(child: Text(v, style: const TextStyle(fontSize: 12.5, fontFeatures: [FontFeature.tabularFigures()]))),
        ]),
      );
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(text.toUpperCase(), style: TextStyle(fontSize: 10, letterSpacing: 0.6, fontWeight: FontWeight.w700, color: paletteOf(context).secondary)),
      );
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.icon, required this.children, this.color});

  final String title;
  final IconData icon;
  final List<Widget> children;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final c = color ?? p.accent;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: p.fill,
          borderRadius: BorderRadius.circular(GlassTokens.radiusSm),
          border: Border.all(color: color != null ? c.withValues(alpha: 0.4) : p.rim, width: GlassTokens.stroke),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 14, color: c),
            const SizedBox(width: 6),
            Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: c))),
          ]),
          const SizedBox(height: 8),
          ...children,
        ]),
      ),
    );
  }
}

class _EventLine extends StatelessWidget {
  const _EventLine({required this.event, required this.trace});

  final TraceEvent event;
  final ExecutionTrace trace;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final color = event.failed ? kFailed : (event.running ? p.accent : kDone);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(width: 7, height: 7, margin: const EdgeInsets.only(top: 5), decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Expanded(child: Text(event.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, height: 1.25))),
        const SizedBox(width: 6),
        Text(offsetLabel(event.at.difference(trace.startedAt)), style: TextStyle(fontSize: 10.5, color: p.secondary, fontFeatures: const [FontFeature.tabularFigures()])),
      ]),
    );
  }
}

/// Monospace output on a dark glass box: commands and what they printed.
class _Terminal extends StatelessWidget {
  const _Terminal({required this.text, this.failed = false});

  final String text;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final short = text.length > 2400 ? '${text.substring(0, 2400)}\n…' : text;
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 220),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xCC050B18),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: (failed ? kFailed : const Color(0xFF22D3EE)).withValues(alpha: 0.3), width: GlassTokens.stroke),
      ),
      child: SingleChildScrollView(
        child: SelectableText(short, style: kMono.copyWith(color: failed ? const Color(0xFFFF8A80) : const Color(0xFFB8F5FF))),
      ),
    );
  }
}
