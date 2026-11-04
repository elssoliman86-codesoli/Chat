import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../core/models.dart';
import '../data/services.dart';
import '../files/attachment_service.dart';

/// The message box: text, attachments, send and stop.
class Composer extends StatefulWidget {
  const Composer({super.key, required this.onSend, required this.busy, required this.onStop});

  final Future<void> Function(String text, List<Attachment> files) onSend;
  final bool busy;
  final VoidCallback onStop;

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
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Camera'),
            onTap: () {
              Navigator.pop(sheet);
              _camera();
            },
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Photos (several)'),
            onTap: () {
              Navigator.pop(sheet);
              _photos();
            },
          ),
          ListTile(
            leading: const Icon(Icons.attach_file_rounded),
            title: const Text('Files (PDF, Word, Excel, PowerPoint, text, code)'),
            onTap: () {
              Navigator.pop(sheet);
              _pickFiles();
            },
          ),
        ]),
      ),
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
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
        child: Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(26),
          ),
          padding: const EdgeInsets.fromLTRB(6, 6, 6, 4),
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
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              IconButton(
                tooltip: 'Attach',
                icon: const Icon(Icons.add_circle_outline_rounded),
                onPressed: _attachMenu,
              ),
              Expanded(
                child: TextField(
                  controller: _text,
                  minLines: 1,
                  maxLines: 8,
                  textInputAction: TextInputAction.newline,
                  keyboardType: TextInputType.multiline,
                  decoration: const InputDecoration(
                    hintText: 'Message',
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
              widget.busy
                  ? IconButton.filled(
                      tooltip: 'Stop',
                      icon: const Icon(Icons.stop_rounded),
                      onPressed: widget.onStop,
                    )
                  : IconButton.filled(
                      tooltip: 'Send',
                      icon: const Icon(Icons.arrow_upward_rounded),
                      onPressed: _send,
                    ),
            ]),
          ]),
        ),
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
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(a.kind == AttachmentKind.pdf ? Icons.picture_as_pdf_outlined : Icons.description_outlined, size: 22),
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
              child: Icon(Icons.close_rounded, size: 14, color: theme.colorScheme.onInverseSurface),
            ),
          ),
        ),
      ]),
    );
  }
}
