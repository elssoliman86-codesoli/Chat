import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

import '../core/models.dart';
import 'browser_dock.dart';
import 'markdown_view.dart';
import 'steps_card.dart';
import 'theme.dart';

void openLink(BuildContext context, String url) {
  showBrowser(context, address: url, full: false);
}

class MessageView extends StatefulWidget {
  const MessageView({
    super.key,
    required this.message,
    required this.streaming,
    this.onRegenerate,
    this.onContinue,
    this.onEditUser,
    this.onEditReply,
    this.resultOf,
  });

  final ChatMessage message;

  /// What a tool call returned, by call id, for the steps list.
  final String? Function(String callId)? resultOf;
  final bool streaming;
  final VoidCallback? onRegenerate;

  /// Shown instead of a cut-off reply: resumes it rather than starting over.
  final VoidCallback? onContinue;

  /// Called with the new text when the person edits their own message and sends it again.
  final void Function(String text)? onEditUser;

  /// Called with the new text when the person corrects the assistant's reply.
  final void Function(String text)? onEditReply;

  @override
  State<MessageView> createState() => _MessageViewState();
}

class _MessageViewState extends State<MessageView> {
  bool _editing = false;
  TextEditingController? _controller;

  ChatMessage get message => widget.message;
  bool get streaming => widget.streaming;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Only this message redraws while its text streams in, and RepaintBoundary keeps that repaint from
    // spilling into the rest of the scrolling list (most noticeable on the emerald theme, whose bubbles
    // are no longer plain opaque fills).
    return RepaintBoundary(
      child: ListenableBuilder(
        listenable: message,
        builder: (context, _) => message.role == 'user' ? _user(context) : _assistant(context),
      ),
    );
  }

  void _startEdit() {
    _controller?.dispose();
    _controller = TextEditingController(text: message.text);
    setState(() => _editing = true);
  }

  Widget _editor(BuildContext context) {
    final pal = paletteOf(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(24, 6, 14, 6),
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 8),
      decoration: BoxDecoration(color: pal.bubble, borderRadius: BorderRadius.circular(22)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        TextField(
          controller: _controller,
          autofocus: true,
          minLines: 1,
          maxLines: 10,
          style: const TextStyle(fontSize: 17),
          decoration: const InputDecoration(
            filled: false,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            isDense: true,
          ),
        ),
        Row(mainAxisSize: MainAxisSize.min, children: [
          TextButton(onPressed: () => setState(() => _editing = false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final t = _controller?.text.trim() ?? '';
              if (t.isEmpty && message.attachments.isEmpty) return;
              setState(() => _editing = false);
              widget.onEditUser?.call(t);
            },
            child: const Text('Send'),
          ),
        ]),
      ]),
    );
  }

  Future<void> _editReply(BuildContext context) async {
    final controller = TextEditingController(text: message.text);
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheet) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(sheet).viewInsets.bottom),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.of(sheet).size.height * 0.55),
                child: TextField(
                  controller: controller,
                  autofocus: true,
                  minLines: 4,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  decoration: const InputDecoration(hintText: 'Edit the reply'),
                ),
              ),
              const SizedBox(height: 10),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(onPressed: () => Navigator.pop(sheet), child: const Text('Cancel')),
                FilledButton(onPressed: () => Navigator.pop(sheet, controller.text), child: const Text('Save')),
              ]),
            ]),
          ),
        ),
      ),
    );
    controller.dispose();
    if (result != null && result.trim().isNotEmpty) widget.onEditReply?.call(result);
  }

  Widget _user(BuildContext context) {
    if (_editing) return _editor(context);
    final images = message.attachments.where((a) => a.kind == AttachmentKind.image).toList();
    final files = message.attachments.where((a) => a.kind != AttachmentKind.image).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Container(
          margin: const EdgeInsets.fromLTRB(56, 6, 14, 2),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(color: paletteOf(context).bubble, borderRadius: BorderRadius.circular(22)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (images.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    alignment: WrapAlignment.end,
                    children: [for (final a in images) _thumb(a)],
                  ),
                ),
              if (files.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    alignment: WrapAlignment.end,
                    children: [for (final a in files) _fileChip(context, a)],
                  ),
                ),
              if (message.text.isNotEmpty) SelectableText(message.text, style: const TextStyle(fontSize: 17, height: 1.35)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            _action(context, CupertinoIcons.doc_on_doc, () => _copy(context)),
            if (widget.onEditUser != null) _action(context, CupertinoIcons.pencil, _startEdit),
          ]),
        ),
      ],
    );
  }

  Widget _thumb(Attachment a) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Image.file(File(a.path),
          width: 104,
          height: 104,
          fit: BoxFit.cover,
          cacheWidth: 312,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => const SizedBox(width: 104, height: 104, child: Icon(CupertinoIcons.photo))),
    );
  }

  Widget _fileChip(BuildContext context, Attachment a) {
    final pal = paletteOf(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: pal.separator, width: 0.8),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(a.kind == AttachmentKind.pdf ? CupertinoIcons.doc_richtext : CupertinoIcons.doc_text, size: 18, color: pal.accent),
        const SizedBox(width: 6),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 190),
          child: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5)),
        ),
      ]),
    );
  }

  Widget _assistant(BuildContext context) {
    final pal = paletteOf(context);
    final empty = message.text.trim().isEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (stepsOnly(message.toolCalls).isNotEmpty)
            StepsCard(calls: stepsOnly(message.toolCalls), resultOf: widget.resultOf ?? (_) => null, live: streaming),
          for (final o in message.outputs) _OutputCard(entry: o),
          if (message.note.isNotEmpty) _NoteCard(note: message.note),
          if (message.sources.isNotEmpty) _sources(context),
          if (empty && streaming && message.toolCalls.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: SizedBox(width: 14, height: 14, child: CupertinoActivityIndicator(radius: 7)),
            ),
          if (!empty)
            message.error
                ? Text(message.text, style: const TextStyle(color: iosRed, fontSize: 15.5, height: 1.4))
                : streaming
                    ? MarkdownText(text: message.text, onLink: (u) => openLink(context, u))
                    : SelectionArea(child: MarkdownText(text: message.text, onLink: (u) => openLink(context, u))),
          if (message.error && widget.onContinue != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: FilledButton.icon(
                onPressed: widget.onContinue,
                icon: const Icon(CupertinoIcons.arrow_turn_down_right, size: 16),
                label: const Text('Continue'),
              ),
            ),
          if (!empty && !streaming)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(children: [
                _action(context, CupertinoIcons.doc_on_doc, () => _copy(context)),
                if (widget.onEditReply != null) _action(context, CupertinoIcons.pencil, () => _editReply(context)),
                if (widget.onRegenerate != null) _action(context, CupertinoIcons.arrow_clockwise, widget.onRegenerate!),
                if (message.model.isNotEmpty)
                  Flexible(
                    child: Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Text(message.model.split('/').last,
                          overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: pal.secondary)),
                    ),
                  ),
              ]),
            ),
        ],
      ),
    );
  }

  Widget _action(BuildContext context, IconData icon, VoidCallback tap) {
    return IconButton(
      visualDensity: VisualDensity.compact,
      iconSize: 18,
      color: paletteOf(context).secondary,
      icon: Icon(icon),
      onPressed: tap,
    );
  }

  Widget _sources(BuildContext context) {
    final pal = paletteOf(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: SizedBox(
        height: 34,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            for (final s in message.sources)
              Builder(builder: (context) {
                final parts = s.split('\t');
                final url = parts.length > 1 ? parts[1] : parts[0];
                final host = Uri.tryParse(url)?.host.replaceFirst('www.', '') ?? url;
                return GestureDetector(
                  onTap: () => openLink(context, url),
                  child: Container(
                    margin: const EdgeInsets.only(right: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(color: pal.bubble, borderRadius: BorderRadius.circular(17)),
                    alignment: Alignment.center,
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(CupertinoIcons.globe, size: 14, color: pal.accent),
                      const SizedBox(width: 6),
                      Text(host, style: const TextStyle(fontSize: 13)),
                    ]),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  void _copy(BuildContext context) {
    Clipboard.setData(ClipboardData(text: message.text));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Copied'), duration: Duration(seconds: 1)));
  }
}

/// A file the assistant made (a project ZIP): shows its name and lets the person save it.
class _OutputCard extends StatelessWidget {
  const _OutputCard({required this.entry});

  final String entry;

  Future<void> _save(BuildContext context, String name, String path) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final bytes = await File(path).readAsBytes();
      final saved = await FilePicker.platform.saveFile(dialogTitle: 'Save $name', fileName: name, bytes: Uint8List.fromList(bytes));
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(saved == null ? 'Not saved' : 'Saved $name')));
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('Could not save the file')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = paletteOf(context);
    final i = entry.indexOf('\t');
    final name = i < 0 ? entry : entry.substring(0, i);
    final path = i < 0 ? '' : entry.substring(i + 1);
    var size = '';
    try {
      final n = File(path).lengthSync();
      size = n < 1048576 ? '${(n / 1024).toStringAsFixed(0)} KB' : '${(n / 1048576).toStringAsFixed(1)} MB';
    } catch (_) {}
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(color: pal.bubble, borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        Icon(CupertinoIcons.archivebox, size: 22, color: pal.accent),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
            if (size.isNotEmpty) Text(size, style: TextStyle(fontSize: 12.5, color: pal.secondary)),
          ]),
        ),
        FilledButton.icon(
          onPressed: path.isEmpty ? null : () => _save(context, name, path),
          icon: const Icon(CupertinoIcons.arrow_down_to_line, size: 16),
          label: const Text('Save'),
        ),
      ]),
    );
  }
}

/// Text read from an image, shown above the reply. It can be opened and copied.
class _NoteCard extends StatefulWidget {
  const _NoteCard({required this.note});

  final String note;

  @override
  State<_NoteCard> createState() => _NoteCardState();
}

class _NoteCardState extends State<_NoteCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final pal = paletteOf(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(color: pal.bubble, borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(children: [
              Icon(CupertinoIcons.doc_text_viewfinder, size: 18, color: pal.accent),
              const SizedBox(width: 8),
              const Expanded(child: Text('Text read from the image', style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600))),
              Icon(_open ? CupertinoIcons.chevron_up : CupertinoIcons.chevron_down, size: 16, color: pal.secondary),
            ]),
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SelectableText(widget.note, style: const TextStyle(fontSize: 15, height: 1.4)),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: widget.note));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied'), duration: Duration(seconds: 1)));
                  },
                  icon: const Icon(CupertinoIcons.doc_on_doc, size: 16),
                  label: const Text('Copy'),
                ),
              ),
            ]),
          ),
      ]),
    );
  }
}
