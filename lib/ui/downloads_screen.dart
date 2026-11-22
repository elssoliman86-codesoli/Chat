import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../data/services.dart';
import '../downloads/download_manager.dart';
import '../downloads/download_task.dart';
import 'glass/glass.dart';
import 'glass/tokens.dart';
import 'kit.dart';
import 'theme.dart';

String _clock(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

GlassStatus _statusOf(DownloadState s) => switch (s) {
      DownloadState.completed => GlassStatus.success,
      DownloadState.failed => GlassStatus.error,
      DownloadState.paused => GlassStatus.warning,
      DownloadState.cancelled => GlassStatus.cancelled,
      DownloadState.queued => GlassStatus.idle,
      _ => GlassStatus.running,
    };

String _stateLabel(DownloadState s) => switch (s) {
      DownloadState.queued => 'Waiting',
      DownloadState.probing => 'Connecting',
      DownloadState.downloading => 'Downloading',
      DownloadState.paused => 'Paused',
      DownloadState.merging => 'Saving file',
      DownloadState.completed => 'Done',
      DownloadState.failed => 'Failed',
      DownloadState.cancelled => 'Cancelled',
    };

/// Browser → Downloads: every download, with its parts, speed, and pause / resume.
class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  final DownloadManager _m = DownloadManager.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_m.load());
  }

  Future<void> _addByLink() async {
    final c = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (d) => GlassDialog(
        title: const Text('Download a link'),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.go,
          onSubmitted: (v) => Navigator.pop(d, v),
          decoration: const InputDecoration(hintText: 'https://…'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(d, c.text), child: const Text('Next')),
        ],
      ),
    );
    c.dispose();
    final u = (url ?? '').trim();
    if (u.isEmpty || !mounted) return;
    final full = u.startsWith('http') ? u : 'https://$u';
    await showDownloadPrompt(context, url: full);
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return ListenableBuilder(
      listenable: _m,
      builder: (context, _) {
        final tasks = _m.tasks;
        return GroupedPage(
          title: 'Downloads',
          actions: [
            IconButton(tooltip: 'Download a link', icon: const Icon(CupertinoIcons.add_circled), onPressed: _addByLink),
            if (tasks.any((t) => t.state == DownloadState.completed))
              IconButton(tooltip: 'Clear finished', icon: const Icon(CupertinoIcons.trash), onPressed: _m.clearFinished),
          ],
          children: [
            Group(
              header: 'Speed',
              footer: 'The app cuts a file into many small parts and fetches several at once, like a download accelerator. '
                  'More connections is usually faster; some sites limit it. Stop and resume any time — nothing starts over.',
              children: [
                _Connections(),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(children: [
                    Icon(CupertinoIcons.speedometer, size: 18, color: p.accent),
                    const SizedBox(width: 10),
                    Expanded(child: Text('${_m.activeCount} active', style: const TextStyle(fontSize: 15))),
                    Text(formatSpeed(_m.totalSpeed), style: TextStyle(fontSize: 15, fontFeatures: const [FontFeature.tabularFigures()], color: p.accent)),
                  ]),
                ),
              ],
            ),
            if (tasks.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 30),
                child: Center(
                  child: Text('No downloads yet.\nOpen a file link in the browser, or press + to paste one.',
                      textAlign: TextAlign.center, style: TextStyle(color: p.secondary, height: 1.4)),
                ),
              ),
            for (final t in tasks) _TaskCard(key: ValueKey<String>(t.id), task: t),
          ],
        );
      },
    );
  }
}

class _Connections extends StatefulWidget {
  @override
  State<_Connections> createState() => _ConnectionsState();
}

class _ConnectionsState extends State<_Connections> {
  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final n = store.settings.downloadConnections;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 2),
      child: Row(children: [
        Icon(CupertinoIcons.arrow_branch, size: 18, color: p.accent),
        const SizedBox(width: 10),
        const Text('Connections per file', style: TextStyle(fontSize: 15)),
        Expanded(
          child: Slider(
            value: n.toDouble(),
            min: 1,
            max: 32,
            divisions: 31,
            onChanged: (v) => setState(() => store.settings.downloadConnections = v.round()),
            onChangeEnd: (_) => store.saveSettings(),
          ),
        ),
        SizedBox(width: 26, child: Text('$n', textAlign: TextAlign.end, style: const TextStyle(fontWeight: FontWeight.w700))),
      ]),
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({super.key, required this.task});

  final DownloadTask task;

  @override
  Widget build(BuildContext context) {
    final m = DownloadManager.instance;
    final p = paletteOf(context);
    return ListenableBuilder(
      listenable: task,
      builder: (context, _) {
        final t = task;
        final status = _statusOf(t.state);
        final color = glassStatusColor(status, p.accent, p.secondary);
        final prog = t.progress;
        final eta = t.eta;
        final sizeText = t.total > 0 ? '${formatBytes(t.received)} of ${formatBytes(t.total)}' : formatBytes(t.received);
        final info = <String>[
          sizeText,
          if (t.state == DownloadState.downloading) formatSpeed(t.speed),
          if (t.state == DownloadState.downloading && eta != null) '${_clock(eta)} left',
          if (t.state == DownloadState.downloading && t.resumable) '${t.connections} connections',
        ];
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: FrostedGlassCard(
            glow: t.state == DownloadState.downloading,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(t.state == DownloadState.completed ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.arrow_down_doc, size: 22, color: color),
                const SizedBox(width: 10),
                Expanded(child: Text(t.fileName, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5))),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: color.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(8)),
                  child: Text(t.handedOff && t.state == DownloadState.cancelled ? 'Sent to Android' : _stateLabel(t.state), style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: color)),
                ),
              ]),
              const SizedBox(height: 10),
              if (t.chunks.length > 1)
                SizedBox(height: 10, child: CustomPaint(painter: _PartsPainter(t.chunks, color, p.rim), size: const Size(double.infinity, 10)))
              else
                ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: LinearProgressIndicator(value: t.state == DownloadState.completed ? 1 : prog, minHeight: 8, color: color, backgroundColor: p.rim),
                ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: Text(info.join('  ·  '), style: TextStyle(fontSize: 12.5, color: p.secondary, fontFeatures: const [FontFeature.tabularFigures()])),
                ),
                if (prog != null && t.state != DownloadState.completed)
                  Text('${(prog * 100).toStringAsFixed(prog >= 0.995 || prog == 0 ? 0 : 1)}%', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: color)),
              ]),
              if (t.error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: SelectableText(t.error, maxLines: 6, style: TextStyle(fontSize: 12.5, color: t.handedOff ? p.secondary : const Color(0xFFFF453A))),
                ),
              const SizedBox(height: 6),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                if (t.state == DownloadState.downloading || t.state == DownloadState.probing || t.state == DownloadState.queued)
                  GlassButton(label: 'Pause', icon: CupertinoIcons.pause_fill, compact: true, onPressed: () => m.pause(t)),
                if (t.state == DownloadState.failed)
                  GlassButton(label: 'Use Android', icon: CupertinoIcons.arrow_down_circle, compact: true, onPressed: () => m.handOff(t)),
                if (t.canResume)
                  GlassButton(label: 'Resume', icon: CupertinoIcons.play_fill, compact: true, style: GlassButtonStyle.primary, onPressed: () => m.resume(t)),
                if (t.state == DownloadState.completed && t.target.startsWith('content://'))
                  GlassButton(label: 'Open', icon: CupertinoIcons.doc_text_search, compact: true, onPressed: () => m.open(t)),
                const SizedBox(width: 8),
                GlassButton(
                  label: t.state == DownloadState.completed ? 'Remove' : 'Cancel',
                  icon: CupertinoIcons.xmark,
                  compact: true,
                  style: GlassButtonStyle.ghost,
                  onPressed: t.state == DownloadState.merging ? null : () => m.remove(t),
                ),
              ]),
            ]),
          ),
        );
      },
    );
  }
}

/// A strip of cells, one per group of parts, filled as the parts arrive — the parts are visibly fetched in
/// parallel and out of order.
class _PartsPainter extends CustomPainter {
  _PartsPainter(this.chunks, this.color, this.rim);

  final List<Chunk> chunks;
  final Color color;
  final Color rim;

  @override
  void paint(Canvas canvas, Size size) {
    final cells = chunks.length < 80 ? chunks.length : 80;
    if (cells == 0) return;
    const gap = 1.5;
    final w = (size.width - gap * (cells - 1)) / cells;
    for (var i = 0; i < cells; i++) {
      final from = (i * chunks.length / cells).floor();
      final to = ((i + 1) * chunks.length / cells).floor();
      var have = 0;
      var all = 0;
      for (var k = from; k < to && k < chunks.length; k++) {
        final c = chunks[k];
        if (!c.bounded) continue;
        have += c.done > c.length ? c.length : c.done;
        all += c.length;
      }
      final f = all == 0 ? 0.0 : have / all;
      final x = i * (w + gap);
      final r = RRect.fromRectAndRadius(Rect.fromLTWH(x, 0, w, size.height), const Radius.circular(2));
      canvas.drawRRect(r, Paint()..color = rim);
      if (f > 0) {
        final fill = RRect.fromRectAndRadius(Rect.fromLTWH(x, 0, w * f, size.height), const Radius.circular(2));
        canvas.drawRRect(fill, Paint()..color = color);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PartsPainter old) => true;
}

/// Asks where to save a link (name, size, number of connections, and the folder through Android's own
/// picker), then starts the parallel download.
Future<void> showDownloadPrompt(
  BuildContext context, {
  required String url,
  Map<String, String> headers = const <String, String>{},
  String nameHint = '',
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (d) => _PromptDialog(url: url, headers: headers, nameHint: nameHint),
  );
}

class _PromptDialog extends StatefulWidget {
  const _PromptDialog({required this.url, required this.headers, required this.nameHint});

  final String url;
  final Map<String, String> headers;
  final String nameHint;

  @override
  State<_PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends State<_PromptDialog> {
  final TextEditingController _name = TextEditingController();
  DownloadProbe? _probe;
  String _error = '';
  bool _saving = false;
  late int _connections = store.settings.downloadConnections;

  @override
  void initState() {
    super.initState();
    _name.text = widget.nameHint;
    unawaited(_look());
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _look() async {
    setState(() {
      _error = '';
      _probe = null;
    });
    try {
      final p = await DownloadManager.instance.probe(widget.url, headers: widget.headers, nameHint: widget.nameHint);
      if (!mounted) return;
      setState(() {
        _probe = p;
        if (_name.text.trim().isEmpty) _name.text = p.fileName;
      });
    } catch (e) {
      if (!mounted) return;
      // The check failed, but the download itself may still work (some servers only refuse the test request),
      // so it can still be started: one connection, size unknown, and Android's downloader as the fallback.
      final name = widget.nameHint.isNotEmpty ? widget.nameHint : fileNameFrom(disposition: '', url: widget.url, mime: '');
      setState(() {
        _error = 'The link check failed ($e). You can still try the download.';
        _probe = DownloadProbe(url: widget.url, fileName: name, total: -1, resumable: false);
        if (_name.text.trim().isEmpty) _name.text = name;
      });
    }
  }

  /// Android's own downloader: works even when this one could not reach the link.
  Future<void> _useSystem() async {
    final name = _name.text.trim().isEmpty ? widget.nameHint : _name.text.trim();
    setState(() => _saving = true);
    final err = await PlatformSaver.systemDownload(widget.url, name: name, mime: _probe?.mime ?? '', headers: widget.headers);
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (err != null) {
      setState(() {
        _saving = false;
        _error = 'Android could not start the download: $err';
      });
      return;
    }
    Navigator.of(context).pop();
    messenger?.showSnackBar(SnackBar(content: Text('Downloading ${name.isEmpty ? 'the file' : name} with Android — see the notification and your Downloads folder')));
  }

  Future<void> _start() async {
    final p = _probe;
    if (p == null) return;
    final name = _name.text.trim().isEmpty ? p.fileName : _name.text.trim();
    setState(() => _saving = true);
    final m = DownloadManager.instance;
    final target = await m.saver.pickTarget(name, p.mime);
    if (!mounted) return;
    if (target == null) {
      setState(() => _saving = false);
      return;
    }
    await m.add(p, target: target, fileName: name, headers: widget.headers, connections: _connections);
    if (!mounted) return;
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    nav.pop();
    messenger?.showSnackBar(SnackBar(
      content: Text('Downloading $name'),
      action: SnackBarAction(
        label: 'Show',
        onPressed: () => navigatorKey.currentState?.push(CupertinoPageRoute<void>(builder: (_) => const DownloadsScreen())),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final pr = _probe;
    return GlassDialog(
      icon: CupertinoIcons.arrow_down_circle,
      title: const Text('Download file'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(controller: _name, decoration: const InputDecoration(labelText: 'File name')),
        const SizedBox(height: 10),
        Text(Uri.tryParse(widget.url)?.host ?? widget.url, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: p.secondary)),
        const SizedBox(height: 8),
        if (_error.isNotEmpty)
          Text(_error, style: const TextStyle(color: Color(0xFFFF453A), fontSize: 13))
        if (pr == null)
          Row(children: [
            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 10),
            Text('Checking the link…', style: TextStyle(color: p.secondary)),
          ])
        else ...[
          Text(
            '${pr.total > 0 ? formatBytes(pr.total) : 'Unknown size'}'
            '${pr.resumable ? '  ·  can be split and resumed' : '  ·  one connection only'}',
            style: const TextStyle(fontSize: 13.5),
          ),
          if (pr.resumable) ...[
            const SizedBox(height: 8),
            Row(children: [
              const Text('Connections', style: TextStyle(fontSize: 13.5)),
              Expanded(
                child: Slider(value: _connections.toDouble(), min: 1, max: 32, divisions: 31, onChanged: (v) => setState(() => _connections = v.round())),
              ),
              SizedBox(width: 24, child: Text('$_connections', style: const TextStyle(fontWeight: FontWeight.w700))),
            ]),
          ],
        ],
        const SizedBox(height: 4),
        Text('Next you choose the folder and name to save it in.', style: TextStyle(fontSize: 12.5, color: p.secondary)),
      ]),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        if (_error.isNotEmpty) TextButton(onPressed: _saving ? null : _look, child: const Text('Retry')),
        TextButton(onPressed: _saving ? null : _useSystem, child: const Text('Use Android')),
        TextButton(onPressed: (pr == null || _saving) ? null : _start, child: const Text('Choose location')),
      ],
    );
  }
}
