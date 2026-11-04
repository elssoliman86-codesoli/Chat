import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../core/models.dart';
import 'browser_screen.dart';
import 'theme.dart';

void openLink(BuildContext context, String url) {
  Navigator.push(context, CupertinoPageRoute<void>(fullscreenDialog: true, builder: (_) => BrowserScreen(url: url)));
}

class MessageView extends StatelessWidget {
  const MessageView({
    super.key,
    required this.message,
    required this.streaming,
    this.onRegenerate,
    this.onEdit,
  });

  final ChatMessage message;
  final bool streaming;
  final VoidCallback? onRegenerate;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    return message.role == 'user' ? _user(context) : _assistant(context);
  }

  Widget _user(BuildContext context) {
    final images = message.attachments.where((a) => a.kind == AttachmentKind.image).toList();
    final files = message.attachments.where((a) => a.kind != AttachmentKind.image).toList();
    return Align(
      alignment: Alignment.centerRight,
      child: GestureDetector(
        onLongPress: () => _menu(context),
        child: Container(
          margin: const EdgeInsets.fromLTRB(56, 6, 14, 6),
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
      ),
    );
  }

  Widget _thumb(Attachment a) {
    final f = File(a.path);
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: f.existsSync()
          ? Image.file(f, width: 104, height: 104, fit: BoxFit.cover, cacheWidth: 312,
              errorBuilder: (_, __, ___) => const SizedBox(width: 104, height: 104, child: Icon(CupertinoIcons.photo)))
          : const SizedBox(width: 104, height: 104, child: Icon(CupertinoIcons.photo)),
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
        Icon(a.kind == AttachmentKind.pdf ? CupertinoIcons.doc_richtext : CupertinoIcons.doc_text, size: 18, color: iosBlue),
        const SizedBox(width: 6),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 190),
          child: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5)),
        ),
      ]),
    );
  }

  Widget _assistant(BuildContext context) {
    final theme = Theme.of(context);
    final pal = paletteOf(context);
    final empty = message.text.trim().isEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final c in message.toolCalls) _toolChip(context, c),
          if (message.sources.isNotEmpty) _sources(context),
          if (empty && streaming && message.toolCalls.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: SizedBox(width: 14, height: 14, child: CupertinoActivityIndicator(radius: 7)),
            ),
          if (!empty)
            message.error
                ? Text(message.text, style: const TextStyle(color: iosRed, fontSize: 15.5, height: 1.4))
                : MarkdownBody(
                    data: message.text,
                    selectable: true,
                    onTapLink: (text, href, title) {
                      if (href != null && href.startsWith('http')) openLink(context, href);
                    },
                    styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                      p: const TextStyle(fontSize: 17, height: 1.5),
                      a: const TextStyle(color: iosBlue),
                      h1: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
                      h2: const TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
                      h3: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                      code: TextStyle(fontFamily: 'monospace', fontSize: 14.5, backgroundColor: pal.bubble),
                      codeblockPadding: const EdgeInsets.all(12),
                      codeblockDecoration: BoxDecoration(color: pal.field, borderRadius: BorderRadius.circular(12)),
                      blockquoteDecoration: BoxDecoration(
                        border: Border(left: BorderSide(color: pal.separator, width: 3)),
                      ),
                      tableBorder: TableBorder.all(color: pal.separator, width: 0.5),
                    ),
                  ),
          if (!empty && !streaming)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(children: [
                _action(context, CupertinoIcons.doc_on_doc, () => _copy(context)),
                if (onRegenerate != null) _action(context, CupertinoIcons.arrow_clockwise, onRegenerate!),
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
                      const Icon(CupertinoIcons.globe, size: 14, color: iosBlue),
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

  Widget _toolChip(BuildContext context, ToolCall c) {
    final pal = paletteOf(context);
    final detail = c.args.values.map((v) => v.toString()).join(' · ');
    final icon = switch (c.name) {
      'web_search' => CupertinoIcons.search,
      'fetch_page' => CupertinoIcons.globe,
      'browse_page' => CupertinoIcons.compass,
      'use_skill' => CupertinoIcons.bolt,
      'remember' => CupertinoIcons.bookmark,
      _ when c.name.startsWith('github') => CupertinoIcons.chevron_left_slash_chevron_right,
      _ => CupertinoIcons.wrench,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 15, color: pal.secondary),
        const SizedBox(width: 6),
        Flexible(
          child: Text(detail.isEmpty ? c.name : detail,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.5, color: pal.secondary)),
        ),
      ]),
    );
  }

  void _copy(BuildContext context) {
    Clipboard.setData(ClipboardData(text: message.text));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Copied'), duration: Duration(seconds: 1)));
  }

  void _menu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(CupertinoIcons.doc_on_doc),
            title: const Text('Copy'),
            onTap: () {
              Navigator.pop(sheet);
              _copy(context);
            },
          ),
          if (onEdit != null)
            ListTile(
              leading: const Icon(CupertinoIcons.pencil),
              title: const Text('Edit and resend'),
              onTap: () {
                Navigator.pop(sheet);
                onEdit!();
              },
            ),
        ]),
      ),
    );
  }
}
