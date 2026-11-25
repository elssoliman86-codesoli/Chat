import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/models.dart';
import '../tools/web_chat_bridge.dart';
import 'glass/glass.dart';
import 'theme.dart';

/// Tries one chat link for real and shows what happened, step by step, so a failure can be understood:
/// a text chat is asked to repeat a code word; the image chat gets a small picture with a number written on it.
Future<void> showWebChatTest(BuildContext context, ChatSlot slot, String url) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _TestDialog(slot: slot, url: url),
  );
}

class _TestDialog extends StatefulWidget {
  const _TestDialog({required this.slot, required this.url});
  final ChatSlot slot;
  final String url;

  @override
  State<_TestDialog> createState() => _TestDialogState();
}

class _TestDialogState extends State<_TestDialog> {
  final WebChatBridge bridge = WebChatBridge.instance;
  bool _closed = false;
  bool _running = true;
  String _verdict = 'Testing…';
  bool? _ok;
  String _page = '';
  late final int _from;

  @override
  void initState() {
    super.initState();
    _from = bridge.log.length;
    bridge.logTick.addListener(_refresh);
    unawaited(_run());
  }

  @override
  void dispose() {
    _closed = true;
    bridge.logTick.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<Attachment> _testImage() async {
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    canvas.drawRect(const Rect.fromLTWH(0, 0, 640, 220), Paint()..color = Colors.white);
    final tp = TextPainter(
      text: const TextSpan(text: 'OMNI TEST 4821', style: TextStyle(color: Colors.black, fontSize: 60, fontWeight: FontWeight.bold)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, const Offset(40, 70));
    final img = await rec.endRecording().toImage(640, 220);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    final file = File('${Directory.systemTemp.path}/omni_chat_test.png');
    await file.writeAsBytes(data!.buffer.asUint8List());
    return Attachment(id: newId(), name: 'omni_chat_test.png', mime: 'image/png', kind: AttachmentKind.image, path: file.path, size: await file.length());
  }

  Future<void> _run() async {
    final clock = Stopwatch()..start();
    try {
      if (widget.slot == ChatSlot.image) {
        final a = await _testImage();
        final text = await bridge.readImage(widget.url, a, cancelled: () => _closed);
        final ok = text.contains('4821');
        _finish(ok, ok ? 'Works: the chat read the number from the picture (${clock.elapsed.inSeconds}s).' : 'The chat answered, but did not read the number 4821 from the picture:\n${_clip(text)}');
      } else {
        const code = 'OMNI-OK 7391';
        final text = await bridge.ask(widget.slot, widget.url, 'Reply with exactly this and nothing else: $code',
            sessionKey: 'test', newThread: true, timeout: const Duration(minutes: 3), cancelled: () => _closed);
        final ok = text.contains('7391');
        _finish(ok, ok ? 'Works: the chat answered in ${clock.elapsed.inSeconds}s.' : 'The chat answered, but not as asked:\n${_clip(text)}');
      }
    } catch (e) {
      _finish(false, 'Did not work: ${e is ChatBridgeError ? e.message : e}');
    }
    final info = await bridge.pageInfo(widget.slot);
    if (mounted) setState(() => _page = info);
  }

  String _clip(String t) => t.length > 400 ? '${t.substring(0, 400)}…' : t;

  void _finish(bool ok, String verdict) {
    if (!mounted) return;
    setState(() {
      _running = false;
      _ok = ok;
      _verdict = verdict;
    });
  }

  String get _logText => bridge.log.sublist(_from.clamp(0, bridge.log.length)).join('\n');

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final name = switch (widget.slot) {
      ChatSlot.primary => 'primary chat',
      ChatSlot.secondary => 'secondary chat',
      ChatSlot.image => 'image chat',
    };
    return GlassDialog(
      title: Text('Test the $name'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            if (_running)
              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            else
              Icon(_ok == true ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.xmark_circle_fill, color: _ok == true ? iosGreen : iosRed, size: 20),
            const SizedBox(width: 10),
            Expanded(child: Text(_verdict, style: const TextStyle(fontSize: 14.5))),
          ]),
          const SizedBox(height: 12),
          Text('What happened', style: TextStyle(fontSize: 12.5, color: p.secondary)),
          const SizedBox(height: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 190),
            child: SingleChildScrollView(
              reverse: true,
              child: SelectableText(_logText.isEmpty ? '…' : _logText, style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, height: 1.35)),
            ),
          ),
          if (_page.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text('What the chat page shows', style: TextStyle(fontSize: 12.5, color: p.secondary)),
            const SizedBox(height: 4),
            SelectableText(_page, style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, height: 1.35)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: '$_verdict\n\n$_logText${_page.isEmpty ? '' : '\n\n$_page'}'));
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
          },
          child: const Text('Copy'),
        ),
        TextButton(onPressed: () => Navigator.pop(context), child: Text(_running ? 'Cancel' : 'Close')),
      ],
    );
  }
}
