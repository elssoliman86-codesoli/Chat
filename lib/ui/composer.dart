import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../core/models.dart';
import '../data/services.dart';
import '../files/attachment_service.dart';
import 'browser_screen.dart';
import 'theme.dart';

/// The message box: text, attachments, send and stop.
class Composer extends StatefulWidget {
  const Composer({
    super.key,
    required this.onSend,
    required this.busy,
    required this.onStop,
    required this.webOn,
    required this.onToggleWeb,
  });

  final Future<void> Function(String text, List<Attachment> files) onSend;
  final bool busy;
  final VoidCallback onStop;
  final bool webOn;
  final VoidCallback onToggleWeb;

  @override
  State<Composer> createState() => ComposerState();
}

class ComposerState extends State<Composer> {
  final TextEditingController _text = TextEditingController();
  final List<Attachment> _files = <Attachment>[];
  int _loading = 0;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  /// Puts an old message back in the box so it can be edited and sent again.
  void load(String text, List<Attachment> files) {
    setState(() {
      _text.text = text;
      _files
        ..clear()
        ..addAll(files);
    });
  }

  /// Adds a ready attachment (for example a page from the browser).
  void addAttachment(Attachment a) {
    if (_files.length + _loading >= store.settings.maxAttachments) {
      _toast('Limit is ${store.settings.maxAttachments} files per message (Settings)');
      return;
    }
    setState(() => _files.add(a));
  }

  Future<void> openBrowser([String url = '']) async {
    final page = await Navigator.push<Attachment>(
      context,
      CupertinoPageRoute<Attachment>(fullscreenDialog: true, builder: (_) => BrowserScreen(url: url)),
    );
    if (page != null) {
      addAttachment(page);
      if (_text.text.trim().isEmpty) _text.text = 'Summarize this page.';
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _ingest(List<({String path, String name})> picked) async {
    final limit = store.settings.maxAttachments;
    final room = limit - _files.length - _loading;
    if (room <= 0) {
      _toast('Limit is $limit files per message (Settings)');
      return;
    }
    final take = picked.length > room ? picked.sublist(0, room) : picked;
    if (take.length < picked.length) _toast('Only $room more files fit in this message');
    setState(() => _loading += take.length);
    final errors = <String>[];
    await Future.wait(take.map((p) async {
      try {
        final a = await attachments.ingest(p.path, p.name);
        if (mounted) setState(() => _files.add(a));
      } on AttachmentException catch (e) {
        errors.add(e.toString());
      } catch (e) {
        errors.add('Could not add ${p.name}');
      } finally {
        if (mounted) setState(() => _loading--);
      }
    }));
    if (errors.isNotEmpty) _toast(errors.take(3).join('\n'));
  }

  Future<void> _camera() async {
    try {
      final x = await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 90);
      if (x != null) await _ingest([(path: x.path, name: x.name)]);
    } catch (e) {
      _toast('Camera is not available');
    }
  }

  Future<void> _photos() async {
    try {
      final xs = await ImagePicker().pickMultiImage(imageQuality: 92);
      if (xs.isNotEmpty) await _ingest([for (final x in xs) (path: x.path, name: x.name)]);
    } catch (e) {
      _toast('Could not open photos');
    }
  }

  Future<void> _pickFiles() async {
    try {
      final r = await FilePicker.platform.pickFiles(allowMultiple: true);
      if (r == null) return;
      await _ingest([
        for (final f in r.files)
          if (f.path != null) (path: f.path!, name: f.name)
      ]);
    } catch (e) {
      _toast('Could not open files');
    }
  }

  void _attachMenu() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _sheetRow(sheet, CupertinoIcons.camera, 'Camera', _camera),
          _sheetRow(sheet, CupertinoIcons.photo, 'Photos', _photos),
          _sheetRow(sheet, CupertinoIcons.doc, 'Files', _pickFiles),
          _sheetRow(sheet, CupertinoIcons.compass, 'Browser', openBrowser),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  Widget _sheetRow(BuildContext sheet, IconData icon, String title, VoidCallback run) {
    return ListTile(
      leading: Icon(icon, size: 24),
      title: Text(title, style: const TextStyle(fontSize: 17)),
      onTap: () {
        Navigator.pop(sheet);
        run();
      },
    );
  }

  Future<void> _send() async {
    if (widget.busy || _loading > 0) return;
    final text = _text.text;
    final files = List<Attachment>.of(_files);
    if (text.trim().isEmpty && files.isEmpty) return;
    setState(() {
      _text.clear();
      _files.clear();
    });
    await widget.onSend(text, files);
  }

  @override
  Widget build(BuildContext context) {
    final pal = paletteOf(context);
    final theme = Theme.of(context);
    final canSend = !widget.busy;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
        child: Container(
          decoration: BoxDecoration(color: pal.field, borderRadius: BorderRadius.circular(26)),
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (_files.isNotEmpty || _loading > 0)
              SizedBox(
                height: 76,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                  children: [
                    for (final a in _files) _chip(a),
                    for (var i = 0; i < _loading; i++)
                      const SizedBox(
                        width: 68,
                        child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
                      ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: TextField(
                controller: _text,
                minLines: 1,
                maxLines: 8,
                textInputAction: TextInputAction.newline,
                keyboardType: TextInputType.multiline,
                style: const TextStyle(fontSize: 17),
                decoration: InputDecoration(
                  hintText: 'Message',
                  hintStyle: TextStyle(color: pal.secondary),
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                ),
              ),
            ),
            Row(children: [
              _round(CupertinoIcons.plus, _attachMenu, pal.bubble, theme.colorScheme.onSurface),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: widget.onToggleWeb,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  height: 36,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: widget.webOn ? iosBlue.withValues(alpha: 0.18) : pal.bubble,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(CupertinoIcons.globe, size: 17, color: widget.webOn ? iosBlue : pal.secondary),
                    const SizedBox(width: 5),
                    Text('Search',
                        style: TextStyle(
                            fontSize: 14.5, fontWeight: FontWeight.w500, color: widget.webOn ? iosBlue : pal.secondary)),
                  ]),
                ),
              ),
              const Spacer(),
              _round(
                widget.busy ? CupertinoIcons.stop_fill : CupertinoIcons.arrow_up,
                canSend ? _send : widget.onStop,
                theme.colorScheme.onSurface,
                theme.colorScheme.surface,
              ),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _round(IconData icon, VoidCallback onTap, Color bg, Color fg) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
        child: Icon(icon, size: 19, color: fg),
      ),
    );
  }

  Widget _chip(Attachment a) {
    final theme = Theme.of(context);
    final f = File(a.path);
    Widget body;
    if (a.kind == AttachmentKind.image && f.existsSync()) {
      body = ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.file(f, width: 64, height: 64, fit: BoxFit.cover, cacheWidth: 192),
      );
    } else {
      body = Container(
        width: 64,
        height: 64,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: paletteOf(context).bubble,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(a.kind == AttachmentKind.pdf ? CupertinoIcons.doc_richtext : CupertinoIcons.doc_text, size: 22),
          const SizedBox(height: 2),
          Text(a.name, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: const TextStyle(fontSize: 9)),
        ]),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Stack(clipBehavior: Clip.none, children: [
        body,
        Positioned(
          right: -6,
          top: -6,
          child: GestureDetector(
            onTap: () => setState(() => _files.remove(a)),
            child: CircleAvatar(
              radius: 10,
              backgroundColor: theme.colorScheme.inverseSurface,
              child: Icon(CupertinoIcons.xmark, size: 11, color: theme.colorScheme.onInverseSurface),
            ),
          ),
        ),
      ]),
    );
  }
}
