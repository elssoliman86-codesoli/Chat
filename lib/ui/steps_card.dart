import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/models.dart';
import '../data/services.dart';
import 'glass/glass.dart';
import 'glass/neon_timeline.dart';
import 'theme.dart';

/// Tool calls that are bookkeeping for other UI (the plan banner) rather than a real step the user
/// did something with — keep these out of the Steps card so it only shows real work.
const Set<String> _nonStepTools = {'set_plan'};

List<ToolCall> stepsOnly(List<ToolCall> calls) => calls.where((c) => !_nonStepTools.contains(c.name)).toList();

/// A plain-words title and detail for one tool call.
({String title, String detail}) describeCall(ToolCall c, String? result) {
  String arg(String k) => (c.args[k] ?? '').toString();
  String host(String u) => Uri.tryParse(u.startsWith('http') ? u : 'https://$u')?.host.replaceFirst('www.', '') ?? u;
  switch (c.name) {
    case 'web_search':
      return (title: 'Searched the web', detail: arg('query'));
    case 'image_search':
      return (title: 'Searched for pictures', detail: arg('query'));
    case 'fetch_page':
    case 'browse_page':
      return (title: 'Read a web page', detail: arg('url'));
    case 'browser_open':
      return (title: 'Opened ${host(arg('url'))}', detail: arg('url'));
    case 'browser_devtools':
      return (title: 'Checked the browser DevTools', detail: arg('filter').isNotEmpty ? arg('filter') : arg('kind'));
    case 'browser_read':
      return (title: 'Read the page', detail: '');
    case 'browser_click':
      var what = 'element ${arg('id')}';
      if (result != null && result.startsWith('Clicked: ')) {
        what = '“${result.substring(9).split('\n').first.trim()}”';
      }
      return (title: 'Clicked $what', detail: '');
    case 'browser_type':
      return (title: 'Typed into element ${arg('id')}', detail: arg('text'));
    case 'browser_drag':
      return (title: 'Dragged element ${arg('id')}', detail: '(${arg('dx')}, ${arg('dy')})');
    case 'browser_scroll':
      return (title: 'Scrolled ${arg('direction') == 'up' ? 'up' : 'down'}', detail: '');
    case 'browser_back':
      return (title: 'Went back', detail: '');
    case 'ask_user':
      return (title: 'Asked you', detail: arg('question'));
    case 'ask_advisor':
      return (title: 'Asked the assistant model', detail: arg('question'));
    case 'apply_chat_files':
      return (title: 'Saved the chat\'s files into the project', detail: arg('chat'));
    case 'ask_web_chat':
      return (title: 'Asked the ${arg('chat') == 'secondary' ? 'secondary' : 'primary'} chat', detail: arg('message'));
    case 'use_skill':
      return (title: 'Loaded skill ${arg('name')}', detail: '');
    case 'remember':
      return (title: 'Saved to memory', detail: arg('fact'));
    case 'forget':
      return (title: 'Removed from memory', detail: arg('fact'));
    case 'project_create':
      return (title: 'Created project ${arg('name')}', detail: '');
    case 'project_write':
      final files = (c.args['files'] as List?) ?? <dynamic>[];
      final names = files.map((f) => f is Map ? (f['path'] ?? '').toString() : '').where((s) => s.isNotEmpty).toList();
      return (title: 'Wrote ${names.length} file${names.length == 1 ? '' : 's'}', detail: names.take(8).join(', ') + (names.length > 8 ? ', …' : ''));
    case 'project_edit':
      return (title: 'Edited ${arg('path')}', detail: '');
    case 'project_read':
      return (title: 'Read ${arg('path')}', detail: '');
    case 'project_list':
      return (title: 'Listed project files', detail: arg('path'));
    case 'project_search':
      return (title: 'Searched the project', detail: arg('query'));
    case 'project_delete':
      return (title: 'Deleted files', detail: ((c.args['paths'] as List?) ?? <dynamic>[]).join(', '));
    case 'project_move':
      return (title: 'Moved ${arg('from')}', detail: '→ ${arg('to')}');
    case 'project_download':
      return (title: 'Downloaded a file', detail: '${arg('url')} → ${arg('path')}');
    case 'project_import_github':
      return (title: 'Downloaded repo ${arg('repo')}', detail: '');
    case 'project_serve':
      return (title: 'Started the local server', detail: '');
    case 'project_check':
      return (title: 'Opened the project and checked it', detail: arg('page'));
    case 'project_export':
      return (title: 'Packed the project into a ZIP', detail: '');
    case 'project_push_github':
      return (title: 'Pushed the project to GitHub', detail: '${arg('repo')} ${arg('branch')}');
    case 'python_run':
      final code = arg('code');
      return (title: 'Ran Python', detail: code.length > 80 ? '${code.substring(0, 80)}…' : code);
    default:
      if (c.name.startsWith('github_')) {
        return (title: c.name.substring(7).replaceAll('_', ' '), detail: arg('repo'));
      }
      return (title: c.name.replaceAll('_', ' '), detail: c.args.values.map((v) => v.toString()).join(' · '));
  }
}

IconData _iconFor(String name) {
  if (name == 'python_run') return CupertinoIcons.chevron_left_slash_chevron_right;
  if (name.startsWith('project_')) return CupertinoIcons.folder;
  if (name.startsWith('browser') || name == 'browse_page') return CupertinoIcons.compass;
  if (name == 'web_search') return CupertinoIcons.search;
  if (name == 'image_search') return CupertinoIcons.photo_on_rectangle;
  if (name == 'fetch_page') return CupertinoIcons.globe;
  if (name.startsWith('github')) return CupertinoIcons.chevron_left_slash_chevron_right;
  if (name == 'ask_user') return CupertinoIcons.hand_raised;
  if (name == 'ask_advisor' || name == 'ask_web_chat') return CupertinoIcons.person_2;
  return CupertinoIcons.wrench;
}

/// Turns the assistant's tool calls into timeline steps using only real execution state:
/// a call with a result is completed (or failed, when the tool reported a failure); the call the engine is
/// executing right now is running; calls still waiting their turn are pending; and calls that never got a
/// result once the turn is over were cancelled.
List<TimelineStep> timelineStepsFor({
  required List<ToolCall> calls,
  required String? Function(String callId) resultOf,
  required ChatMessage? Function(String callId) msgOf,
  required bool live,
  required String? runningId,
}) {
  final out = <TimelineStep>[];
  int prevEnd = 0;
  for (final c in calls) {
    final result = resultOf(c.id);
    final msg = msgOf(c.id);
    final info = describeCall(c, result);
    final StepStatus status;
    if (result != null) {
      status = (msg?.failed ?? false) ? StepStatus.failed : StepStatus.completed;
    } else if (runningId == c.id) {
      status = StepStatus.running;
    } else if (live) {
      status = StepStatus.pending;
    } else {
      status = StepStatus.cancelled;
    }
    DateTime? started;
    Duration? took;
    if (status != StepStatus.pending && status != StepStatus.cancelled) {
      final startMs = c.startedAt > prevEnd ? c.startedAt : prevEnd;
      started = DateTime.fromMillisecondsSinceEpoch(startMs);
      if (msg != null) {
        final d = msg.at - startMs;
        took = Duration(milliseconds: d < 0 ? 0 : d);
        prevEnd = msg.at;
      }
    }
    out.add(TimelineStep(
      id: c.id,
      title: info.title,
      description: info.detail,
      status: status,
      startedAt: started,
      duration: took,
      details: result,
      icon: _iconFor(c.name),
    ));
  }
  return out;
}

/// The wrench: one line that opens into every step the assistant took, as a neon timeline.
class StepsCard extends StatefulWidget {
  const StepsCard({super.key, required this.calls, required this.resultOf, required this.live, this.msgOf});

  final List<ToolCall> calls;
  final String? Function(String callId) resultOf;

  /// The tool-result message of a call (its time and whether the tool failed).
  final ChatMessage? Function(String callId)? msgOf;

  /// True while the assistant is still working.
  final bool live;

  @override
  State<StepsCard> createState() => _StepsCardState();
}

class _StepsCardState extends State<StepsCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final pal = paletteOf(context);
    final calls = widget.calls;
    // Rebuilds when the engine starts or finishes a call (it calls store.changed()), so the running ring
    // follows the engine's real state.
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final steps = timelineStepsFor(
          calls: calls,
          resultOf: widget.resultOf,
          msgOf: widget.msgOf ?? (_) => null,
          live: widget.live,
          runningId: widget.live ? engine.runningCallId : null,
        );
        final running = steps.where((s) => s.status == StepStatus.running).toList();
        final failed = steps.where((s) => s.status == StepStatus.failed).length;
        final doneCount = steps.where((s) => s.status == StepStatus.completed || s.status == StepStatus.failed).length;
        final n = steps.length;
        final String summary;
        if (running.isNotEmpty) {
          summary = running.first.title;
        } else if (_open) {
          summary = '$n step${n == 1 ? '' : 's'}';
        } else {
          summary = '$n step${n == 1 ? '' : 's'}${failed > 0 ? ' · $failed failed' : ''}';
        }
        final GlassStatus headStatus = running.isNotEmpty
            ? GlassStatus.running
            : (failed > 0 ? GlassStatus.error : (widget.live ? GlassStatus.running : (doneCount == n ? GlassStatus.success : GlassStatus.cancelled)));
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: FrostedGlassCard(
            padding: EdgeInsets.zero,
            radius: GlassTokens.radiusMd,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              InkWell(
                borderRadius: BorderRadius.circular(GlassTokens.radiusMd),
                onTap: () => setState(() => _open = !_open),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                  child: Row(children: [
                    GlassStatusIndicator(status: headStatus, size: 9),
                    const SizedBox(width: 10),
                    Expanded(child: Text(summary, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600))),
                    Text('$doneCount/$n', style: TextStyle(fontSize: 12, color: pal.secondary)),
                    const SizedBox(width: 8),
                    Icon(_open ? CupertinoIcons.chevron_up : CupertinoIcons.chevron_down, size: 15, color: pal.secondary),
                  ]),
                ),
              ),
              if (_open)
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
                  child: ConstrainedBox(
                    // A long run of steps scrolls inside the card instead of pushing the chat off-screen.
                    constraints: BoxConstraints(maxHeight: n <= 4 ? double.infinity : 360),
                    child: n <= 4
                        ? NeonProgressTimeline(steps: steps)
                        : Scrollbar(child: SingleChildScrollView(child: NeonProgressTimeline(steps: steps))),
                  ),
                ),
            ]),
          ),
        );
      },
    );
  }
}
