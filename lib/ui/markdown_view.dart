import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

import '../files/code_export.dart';
import 'code_preview.dart';
import 'theme.dart';

/// Markdown that only rebuilds when its text or theme changes.
class MarkdownText extends StatefulWidget {
  const MarkdownText({super.key, required this.text, required this.onLink});

  final String text;
  final void Function(String url) onLink;

  @override
  State<MarkdownText> createState() => _MarkdownTextState();
}

class _MarkdownTextState extends State<MarkdownText> {
  String? _lastText;
  Brightness? _lastBrightness;
  Palette? _lastPalette;
  Widget? _built;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pal = paletteOf(context);
    if (_built == null || _lastText != widget.text || _lastBrightness != theme.brightness || !identical(_lastPalette, pal)) {
      _lastText = widget.text;
      _lastBrightness = theme.brightness;
      _lastPalette = pal;
      _built = MarkdownBody(
        data: widget.text,
        builders: {'pre': CodeBlockBuilder()},
        onTapLink: (text, href, title) {
          if (href != null && href.startsWith('http')) widget.onLink(href);
        },
        styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
          p: const TextStyle(fontSize: 17, height: 1.5),
          a: TextStyle(color: pal.accent),
          h1: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
          h2: const TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
          h3: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          code: TextStyle(fontFamily: 'monospace', fontSize: 14.5, backgroundColor: pal.bubble),
          blockquoteDecoration: BoxDecoration(border: Border(left: BorderSide(color: pal.separator, width: 3))),
          tableBorder: TableBorder.all(color: pal.separator, width: 0.5),
        ),
      );
    }
    return _built!;
  }
}

/// Fenced code blocks with a header: language, Preview (HTML / SVG), Copy and Download.
class CodeBlockBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(BuildContext context, md.Element element, TextStyle? preferredStyle, TextStyle? parentStyle) {
    var lang = '';
    var code = element.textContent;
    if (element.children != null && element.children!.isNotEmpty) {
      final first = element.children!.first;
      if (first is md.Element) {
        final cls = first.attributes['class'] ?? '';
        if (cls.startsWith('language-')) lang = cls.substring(9);
        code = first.textContent;
      }
    }
    if (code.endsWith('\n')) code = code.substring(0, code.length - 1);
    return CodeBlock(code: code, language: lang);
  }
}

class CodeBlock extends StatelessWidget {
  const CodeBlock({super.key, required this.code, required this.language});

  final String code;
  final String language;

  @override
  Widget build(BuildContext context) {
    final pal = paletteOf(context);
    final canPreview = isPreviewable(language, code);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(color: pal.field, borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          color: pal.bubble,
          padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
          child: Row(children: [
            Expanded(
              child: Text(language.isEmpty ? 'code' : language,
                  style: TextStyle(fontSize: 12.5, color: pal.secondary, fontWeight: FontWeight.w600)),
            ),
            if (canPreview) _btn(context, CupertinoIcons.play_rectangle, 'Preview', () => openPreview(context, language, code)),
            _btn(context, CupertinoIcons.doc_on_doc, 'Copy', () {
              Clipboard.setData(ClipboardData(text: code));
              ScaffoldMessenger.of(context)
                ..hideCurrentSnackBar()
                ..showSnackBar(const SnackBar(content: Text('Code copied'), duration: Duration(seconds: 1)));
            }),
            _btn(context, CupertinoIcons.arrow_down_to_line, 'Download', () => saveCode(context, language, code)),
          ]),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.all(12),
          child: Text(code, style: const TextStyle(fontFamily: 'monospace', fontSize: 13.5, height: 1.4)),
        ),
      ]),
    );
  }

  Widget _btn(BuildContext context, IconData icon, String label, VoidCallback tap) {
    final pal = paletteOf(context);
    return TextButton.icon(
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        foregroundColor: pal.secondary,
        textStyle: const TextStyle(fontSize: 12.5),
      ),
      onPressed: tap,
      icon: Icon(icon, size: 15),
      label: Text(label),
    );
  }
}
