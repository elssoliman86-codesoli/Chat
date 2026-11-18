import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tools/browser_service.dart';
import '../tools/devtools_log.dart';
import 'syntax.dart';
import 'theme.dart';

Color statusColor(NetEntry e) {
  if (e.error.isNotEmpty) return iosRed;
  if (!e.done) return iosGray;
  if (e.status >= 400) return iosRed;
  if (e.status >= 300) return iosOrange;
  return iosGreen;
}

Color levelColor(String level) {
  switch (level) {
    case 'error':
      return iosRed;
    case 'warn':
      return iosOrange;
    case 'info':
      return iosTeal;
    default:
      return iosGray;
  }
}

/// The browser's DevTools: network requests with headers and bodies, and the console. The same data the
/// assistant reads through browser_devtools.
class DevToolsPane extends StatefulWidget {
  const DevToolsPane({super.key, required this.log});

  final DevLog log;

  @override
  State<DevToolsPane> createState() => _DevToolsPaneState();
}

class _DevToolsPaneState extends State<DevToolsPane> {
  int _tab = 0;
  String _filter = '';
  bool _onlyFailed = false;

  void _copy(String text, String done) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(done), duration: const Duration(seconds: 1)));
  }

  void _open(NetEntry e) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        maxChildSize: 0.95,
        builder: (ctx, scroll) => Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 6),
            child: Row(children: [
              Expanded(child: Text('#${e.id}  ${e.statusLabel}', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: statusColor(e)))),
              TextButton.icon(onPressed: () => _copy(e.detail, 'Request copied'), icon: const Icon(CupertinoIcons.doc_on_doc, size: 15), label: const Text('Copy')),
            ]),
          ),
          Expanded(
            child: SingleChildScrollView(
              controller: scroll,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              child: SelectableText(e.detail, style: codeTextStyle(size: 12.5).copyWith(color: Theme.of(ctx).textTheme.bodyMedium?.color)),
            ),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pal = paletteOf(context);
    final solid = Theme.of(context).brightness == Brightness.dark ? const Color(0xFF16181D) : const Color(0xFFF4F5F7);
    return Container(
      color: solid,
      child: ValueListenableBuilder<int>(
        valueListenable: widget.log.revision,
        builder: (context, value, child) {
          final net = widget.log.filtered(_filter, onlyFailed: _onlyFailed);
          final errors = widget.log.console.where((c) => c.level == 'error').length;
          return Column(children: [
            SizedBox(
              height: 38,
              child: Row(children: [
                const SizedBox(width: 8),
                _tabButton(0, 'Network ${widget.log.net.length}', pal),
                _tabButton(1, errors > 0 ? 'Console ${widget.log.console.length} · $errors err' : 'Console ${widget.log.console.length}', pal),
                const Spacer(),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Copy all',
                  icon: const Icon(CupertinoIcons.doc_on_doc, size: 17),
                  onPressed: () => _copy(widget.log.report(maxChars: 60000), 'Log copied'),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Clear',
                  icon: const Icon(CupertinoIcons.trash, size: 17),
                  onPressed: widget.log.clear,
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Close',
                  icon: const Icon(CupertinoIcons.xmark, size: 17),
                  onPressed: () => BrowserService.instance.devToolsOpen.value = false,
                ),
              ]),
            ),
            if (_tab == 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
                child: Row(children: [
                  Expanded(
                    child: SizedBox(
                      height: 32,
                      child: TextField(
                        style: const TextStyle(fontSize: 13),
                        decoration: const InputDecoration(hintText: 'Filter by address', isDense: true, prefixIcon: Icon(CupertinoIcons.search, size: 15)),
                        onChanged: (v) => setState(() => _filter = v),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  FilterChip(
                    label: const Text('Failed', style: TextStyle(fontSize: 12)),
                    selected: _onlyFailed,
                    visualDensity: VisualDensity.compact,
                    onSelected: (v) => setState(() => _onlyFailed = v),
                  ),
                ]),
              ),
            Expanded(child: _tab == 0 ? _network(net, pal) : _console(pal)),
          ]);
        },
      ),
    );
  }

  Widget _tabButton(int i, String label, Palette pal) {
    final on = _tab == i;
    return TextButton(
      style: TextButton.styleFrom(visualDensity: VisualDensity.compact, foregroundColor: on ? pal.accent : pal.secondary),
      onPressed: () => setState(() => _tab = i),
      child: Text(label, style: TextStyle(fontSize: 13.5, fontWeight: on ? FontWeight.w700 : FontWeight.w500)),
    );
  }

  Widget _network(List<NetEntry> list, Palette pal) {
    if (list.isEmpty) {
      return Center(child: Text(widget.log.net.isEmpty ? 'No requests yet — open or reload a page' : 'No requests match', style: TextStyle(color: pal.secondary, fontSize: 13)));
    }
    return ListView.builder(
      reverse: true,
      itemCount: list.length,
      itemBuilder: (context, i) {
        final e = list[list.length - 1 - i];
        return InkWell(
          onTap: () => _open(e),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: Row(children: [
              SizedBox(width: 38, child: Text(e.statusLabel, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: statusColor(e)))),
              SizedBox(width: 44, child: Text(e.method, style: TextStyle(fontSize: 11.5, color: pal.secondary))),
              Expanded(child: Text(e.path, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5))),
              const SizedBox(width: 6),
              Text(e.done ? '${e.durationMs}ms' : '', style: TextStyle(fontSize: 11, color: pal.secondary)),
            ]),
          ),
        );
      },
    );
  }

  Widget _console(Palette pal) {
    final list = widget.log.console;
    if (list.isEmpty) {
      return Center(child: Text('Nothing logged yet', style: TextStyle(color: pal.secondary, fontSize: 13)));
    }
    return ListView.builder(
      reverse: true,
      itemCount: list.length,
      itemBuilder: (context, i) {
        final c = list[list.length - 1 - i];
        return InkWell(
          onLongPress: () => _copy(c.text, 'Copied'),
          child: Container(
            decoration: BoxDecoration(border: Border(left: BorderSide(color: levelColor(c.level), width: 3))),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: SelectableText(c.text, style: codeTextStyle(size: 12).copyWith(color: c.level == 'error' ? iosRed : Theme.of(context).textTheme.bodyMedium?.color)),
          ),
        );
      },
    );
  }
}
