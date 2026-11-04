import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../core/models.dart';
import 'theme.dart';

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
        onLongPress: () => _menu(context, user: true),
        child: Container(
          margin: const EdgeInsets.fromLTRB(48, 6, 12, 6),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(color: userBubble(context), borderRadius: BorderRadius.circular(20)),
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
              if (message.text.isNotEmpty) SelectableText(message.text, style: const TextStyle(fontSize: 16, height: 1.4)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _thumb(Attachment a) {
    final f = File(a.path);
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: f.existsSync()
          ? Image.file(f, width: 96, height: 96, fit: BoxFit.cover, cacheWidth: 288,
              errorBuilder: (_, __, ___) => const SizedBox(width: 96, height: 96, child: Icon(Icons.broken_image_outlined)))
          : const SizedBox(width: 96, height: 96, child: Icon(Icons.image_not_supported_outlined)),
    );
  }

  Widget _fileChip(BuildContext context, Attachment a) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(a.kind == AttachmentKind.pdf ? Icons.picture_as_pdf_outlined : Icons.description_outlined, size: 18),
        const SizedBox(width: 6),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 180),
          child: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
        ),
      ]),
    );
  }

  Widget _assistant(BuildContext context) {
    final theme = Theme.of(context);
    final empty = message.text.trim().isEmpty;
    return GestureDetector(
      onLongPress: empty ? null : () => _menu(context, user: false),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final c in message.toolCalls) _toolChip(context, c),
            if (empty && streaming && message.toolCalls.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            if (!empty)
              message.error
                  ? Text(message.text, style: TextStyle(color: theme.colorScheme.error, fontSize: 15, height: 1.4))
                  : MarkdownBody(
                      data: message.text,
                      selectable: true,
                      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                        p: const TextStyle(fontSize: 16, height: 1.5),
                        code: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 14,
                          backgroundColor: theme.colorScheme.surfaceContainerHighest,
                        ),
                        codeblockDecoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
            if (!empty && !streaming)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(children: [
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    iconSize: 18,
                    tooltip: 'Copy',
                    icon: const Icon(Icons.copy_rounded),
                    onPressed: () => _copy(context),
                  ),
                  if (onRegenerate != null)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      iconSize: 18,
                      tooltip: 'Regenerate',
                      icon: const Icon(Icons.refresh_rounded),
                      onPressed: onRegenerate,
                    ),
                  if (message.model.isNotEmpty)
                    Flexible(
                      child: Text(message.model,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: theme.hintColor)),
                    ),
                ]),
              ),
          ],
        ),
      ),
    );
  }

  Widget _toolChip(BuildContext context, ToolCall c) {
    final detail = c.args.values.map((v) => v.toString()).join(' · ');
    final icon = switch (c.name) {
      'web_search' => Icons.search_rounded,
      'fetch_page' => Icons.public_rounded,
      'use_skill' => Icons.bolt_rounded,
      'remember' => Icons.bookmark_added_outlined,
      _ => Icons.build_circle_outlined,
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 16),
        const SizedBox(width: 6),
        Flexible(
          child: Text(detail.isEmpty ? c.name : detail,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
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

  void _menu(BuildContext context, {required bool user}) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.copy_rounded),
            title: const Text('Copy'),
            onTap: () {
              Navigator.pop(sheet);
              _copy(context);
            },
          ),
          if (user && onEdit != null)
            ListTile(
              leading: const Icon(Icons.edit_outlined),
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
