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
    required this.chat,
    required this.onNewChat,
    required this.onSkills,
    required this.onPlugins,
  });

  final Future<void> Function(String text, List<Attachment> files) onSend;
  final bool busy;
  final VoidCallback onStop;
  final bool webOn;
  final VoidCallback onToggleWeb;
  final Conversation chat;
  final VoidCallback onNewChat;
  final VoidCallback onSkills;
  final VoidCallback onPlugins;

  @override
  State<Composer> createState() => ComposerState();
}

class ComposerState extends State<Composer> {
  final TextEditingController _text = TextEditingController();
  final List<Attachment> _files = <Attachment>[];
  int _loading = 0;

  @override
  void initState() {
    super.initState();
    _text.addListener(() {
      if (mounted) setState(() {});
    });
  }

  static String slug(String name) =>
      name.toLowerCase().trim().replaceAll(RegExp(r'[^a-z0-9\u0600-\u06FF]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');

  /// Commands and skills matching what was typed after the slash.
  List<({String label, String hint, IconData icon, VoidCallback run})> _slashItems() {
    final t = _text.text;
    if (!t.startsWith('/') || t.contains(' ') || t.contains('\n')) return const [];
    final q = t.substring(1).toLowerCase();
    final items = <({String label, String hint, IconData icon, VoidCallback run})>[];
    void clear() => _text.clear();
    final commands = <({String label, String hint, IconData icon, VoidCallback run})>[
      (label: 'skills', hint: 'Pick skills for this chat', icon: CupertinoIcons.bolt, run: () { clear(); widget.onSkills(); }),
      (label: 'new', hint: 'Start a new chat', icon: CupertinoIcons.square_pencil, run: () { clear(); widget.onNewChat(); }),
      (label: 'web', hint: 'Turn web search on or off', icon: CupertinoIcons.globe, run: () { clear(); widget.onToggleWeb(); }),
      (label: 'browser', hint: 'Open the browser', icon: CupertinoIcons.compass, run: () { clear(); openBrowser(); }),
      (label: 'plugins', hint: 'Plugins and GitHub token', icon: CupertinoIcons.square_grid_2x2, run: () { clear(); widget.onPlugins(); }),
    ];
    for (final c in commands) {
      if (c.label.startsWith(q)) items.add(c);
    }
    for (final sk in store.skills.where((k) => k.enabled)) {
      final id = slug(sk.name);
      if (id.isEmpty || !id.startsWith(q)) continue;
      final on = widget.chat.activeSkillIds.contains(sk.id);
      items.add((
        label: id,
        hint: '${on ? 'Turn off' : 'Turn on'} skill: ${sk.description.isEmpty ? sk.name : sk.description}',
        icon: on ? CupertinoIcons.bolt_fill : CupertinoIcons.bolt,
        run: () {
          clear();
          _toggleSkill(sk);
        },
      ));
    }
    return items.take(7).toList();
  }

  void _toggleSkill(Skill sk) {
    final ids = widget.chat.activeSkillIds;
    final on = ids.contains(sk.id);
    if (on) {
      ids.remove(sk.id);
    } else {
      ids.add(sk.id);
    }
    store.scheduleSave(widget.chat);
    store.changed();
    _toast('${sk.name}: ${on ? 'off' : 'on'}');
  }

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
    var text = _text.text;
    final slash = RegExp(r'^/(\S+)\s+([\s\S]*)$').firstMatch(text);
    if (slash != null) {
      final id = slash.group(1)!.toLowerCase();
      for (final sk in store.skills) {
        if (sk.enabled && slug(sk.name) == id) {
          if (!widget.chat.activeSkillIds.contains(sk.id)) widget.chat.activeSkillIds.add(sk.id);
          text = slash.group(2)!;
          break;
        }
      }
    }
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
    final slashItems = _slashItems();
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (slashItems.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(color: pal.field, borderRadius: BorderRadius.circular(16)),
            child: Column(children: [
              for (final it in slashItems)
                InkWell(
                  onTap: it.run,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    child: Row(children: [
                      Icon(it.icon, size: 18, color: pal.accent),
                      const SizedBox(width: 12),
                      Text('/${it.label}', style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600)),
                      const SizedBox(width: 10),
                      Expanded(child: Text(it.hint, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: pal.secondary))),
                    ]),
                  ),
                ),
            ]),
          ),
        Container(
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
                    color: widget.webOn ? pal.accent.withValues(alpha: 0.18) : pal.bubble,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(CupertinoIcons.globe, size: 17, color: widget.webOn ? pal.accent : pal.secondary),
                    const SizedBox(width: 5),
                    Text('Search',
                        style: TextStyle(
                            fontSize: 14.5, fontWeight: FontWeight.w500, color: widget.webOn ? pal.accent : pal.secondary)),
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
        ]),
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
