import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/models.dart';
import 'theme.dart';

/// A plain-words title and detail for one tool call.
({String title, String detail}) describeCall(ToolCall c, String? result) {
  String arg(String k) => (c.args[k] ?? '').toString();
  String host(String u) => Uri.tryParse(u.startsWith('http') ? u : 'https://$u')?.host.replaceFirst('www.', '') ?? u;
  switch (c.name) {
    case 'web_search':
      return (title: 'Searched the web', detail: arg('query'));
    case 'fetch_page':
    case 'browse_page':
      return (title: 'Read a web page', detail: arg('url'));
    case 'browser_open':
      return (title: 'Opened ${host(arg('url'))}', detail: arg('url'));
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
    case 'browser_scroll':
      return (title: 'Scrolled ${arg('direction') == 'up' ? 'up' : 'down'}', detail: '');
    case 'browser_back':
      return (title: 'Went back', detail: '');
    case 'ask_user':
      return (title: 'Asked you', detail: arg('question'));
    case 'use_skill':
      return (title: 'Loaded skill ${arg('name')}', detail: '');
    case 'remember':
      return (title: 'Saved to memory', detail: arg('fact'));
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
  if (name == 'fetch_page') return CupertinoIcons.globe;
  if (name.startsWith('github')) return CupertinoIcons.chevron_left_slash_chevron_right;
  if (name == 'ask_user') return CupertinoIcons.hand_raised;
  return CupertinoIcons.wrench;
}

/// The wrench: one line that opens into every step the assistant took, with what each step returned.
class StepsCard extends StatefulWidget {
  const StepsCard({super.key, required this.calls, required this.resultOf, required this.live});

  final List<ToolCall> calls;
  final String? Function(String callId) resultOf;

  /// True while the assistant is still working, so the last step shows a spinner.
  final bool live;

  @override
  State<StepsCard> createState() => _StepsCardState();
}

class _StepsCardState extends State<StepsCard> {
  bool _open = false;
  final Set<String> _expanded = <String>{};

  @override
  Widget build(BuildContext context) {
    final pal = paletteOf(context);
    final calls = widget.calls;
    final last = calls.last;
    final lastDone = widget.resultOf(last.id) != null;
    final working = widget.live && !lastDone;
    final lastInfo = describeCall(last, widget.resultOf(last.id));
    final summary = _open
        ? '${calls.length} step${calls.length == 1 ? '' : 's'}'
        : (working ? lastInfo.title : '${calls.length} step${calls.length == 1 ? '' : 's'}');
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(color: pal.bubble, borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(children: [
              if (working)
                const SizedBox(width: 16, height: 16, child: CupertinoActivityIndicator(radius: 7))
              else
                Icon(CupertinoIcons.wrench, size: 16, color: pal.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(summary, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
              ),
              Icon(_open ? CupertinoIcons.chevron_up : CupertinoIcons.chevron_down, size: 15, color: pal.secondary),
            ]),
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (var i = 0; i < calls.length; i++) _step(context, i, calls[i]),
            ]),
          ),
      ]),
    );
  }

  Widget _step(BuildContext context, int i, ToolCall c) {
    final pal = paletteOf(context);
    final result = widget.resultOf(c.id);
    final info = describeCall(c, result);
    final open = _expanded.contains(c.id);
    final running = widget.live && result == null;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      InkWell(
        onTap: result == null ? null : () => setState(() => open ? _expanded.remove(c.id) : _expanded.add(c.id)),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 22, child: Text('${i + 1}', style: TextStyle(fontSize: 12.5, color: pal.secondary))),
            Padding(
              padding: const EdgeInsets.only(top: 1, right: 8),
              child: running
                  ? const SizedBox(width: 14, height: 14, child: CupertinoActivityIndicator(radius: 6))
                  : Icon(_iconFor(c.name), size: 15, color: pal.secondary),
            ),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(info.title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                if (info.detail.isNotEmpty)
                  Text(info.detail, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: pal.secondary)),
              ]),
            ),
            if (result != null) Icon(open ? CupertinoIcons.chevron_up : CupertinoIcons.chevron_down, size: 13, color: pal.secondary),
          ]),
        ),
      ),
      if (open && result != null)
        Container(
          width: double.infinity,
          margin: const EdgeInsets.only(left: 22, bottom: 6),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: pal.field, borderRadius: BorderRadius.circular(8)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: SingleChildScrollView(
                child: SelectableText(
                  result.length > 3000 ? '${result.substring(0, 3000)}\n…(${result.length - 3000} more characters)' : result,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, height: 1.35),
                ),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: GestureDetector(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: result));
                  ScaffoldMessenger.of(context)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(const SnackBar(content: Text('Copied'), duration: Duration(seconds: 1)));
                },
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('Copy', style: TextStyle(fontSize: 12.5, color: pal.accent)),
                ),
              ),
            ),
          ]),
        ),
    ]);
  }
}
