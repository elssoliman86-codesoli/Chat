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
        imageBuilder: (uri, title, alt) => _MarkdownImage(uri: uri, alt: alt),
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
          // Columns share the available width equally and wrap their text, instead of each being
          // sized toward its own content — a phone-width bubble can't grow to fit a wide table, and
          // an unbounded/near-fixed column width used to push text off-screen or clip it.
          tableColumnWidth: const FlexColumnWidth(),
          tableCellsPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          tableHead: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          tableBody: const TextStyle(fontSize: 15, height: 1.35),
        ),
      );
    }
    return _built!;
  }
}

/// An image inside a reply. Kept to a bounded size so a missing or slow image never grows into
/// a large empty box: while it loads, and if it fails, it stays a small fixed tile.
class _MarkdownImage extends StatelessWidget {
  const _MarkdownImage({required this.uri, this.alt});

  final Uri uri;
  final String? alt;

  @override
  Widget build(BuildContext context) {
    if (uri.scheme != 'http' && uri.scheme != 'https') return _tile(context, CupertinoIcons.photo, alt ?? uri.toString());
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 320),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.network(
          uri.toString(),
          fit: BoxFit.contain,
          alignment: Alignment.centerLeft,
          loadingBuilder: (context, child, progress) => progress == null ? child : _tile(context, null, null, progress: progress),
          errorBuilder: (context, error, stack) => _tile(context, CupertinoIcons.exclamationmark_triangle, alt?.isNotEmpty == true ? alt : 'Image could not load'),
        ),
      ),
    );
  }

  Widget _tile(BuildContext context, IconData? icon, String? label, {ImageChunkEvent? progress}) {
    final pal = paletteOf(context);
    return Container(
      width: 180,
      height: 120,
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(color: pal.field, borderRadius: BorderRadius.circular(12)),
      alignment: Alignment.center,
      child: progress != null
          ? const SizedBox(width: 20, height: 20, child: CupertinoActivityIndicator())
          : Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 22, color: pal.secondary),
              if (label != null && label.isNotEmpty) ...[
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: TextStyle(fontSize: 11.5, color: pal.secondary)),
                ),
              ],
            ]),
    );
  }
}

/// Fenced code blocks with a header: language, Preview when the language can be shown or run, Copy and Download.
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
