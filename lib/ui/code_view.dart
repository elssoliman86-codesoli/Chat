import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'syntax.dart';

/// A TextEditingController that colors what it shows by language as the person types — the
/// project file editor uses it so editing looks the same as reading.
class HighlightingController extends TextEditingController {
  HighlightingController({super.text, this.language = ''});

  String language;

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final base = style ?? codeTextStyle();
    return TextSpan(style: base, children: highlightSpans(text, language, base));
  }
}

/// Line numbers 1..[lines], one per line, drawn with the same fixed line height as the code beside
/// them and excluded from text selection (so copying code never copies the numbers).
class LineNumbers extends StatelessWidget {
  const LineNumbers({super.key, required this.lines, required this.size, this.height = 1.45, this.padding = const EdgeInsets.fromLTRB(10, 12, 8, 12)});

  final int lines;
  final double size;
  final double height;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final text = List<String>.generate(lines, (i) => '${i + 1}').join('\n');
    return SelectionContainer.disabled(
      child: Padding(
        padding: padding,
        child: Text(
          text,
          textAlign: TextAlign.right,
          softWrap: false,
          strutStyle: codeStrut(size: size, height: height),
          style: codeTextStyle(size: size, height: height).copyWith(color: CodeTheme.dark.gutter),
        ),
      ),
    );
  }
}

int lineCount(String code) => '\n'.allMatches(code).length + 1;

/// Read-only colored code with line numbers: the numbers stay put on the left while the code scrolls
/// sideways, and nothing wraps so each number stays beside its own line.
class HighlightedCode extends StatelessWidget {
  const HighlightedCode({super.key, required this.code, required this.language, this.size = 13});

  final String code;
  final String language;
  final double size;

  @override
  Widget build(BuildContext context) {
    final style = codeTextStyle(size: size);
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      LineNumbers(lines: lineCount(code), size: size),
      Expanded(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(4, 12, 14, 12),
          child: Text.rich(
            TextSpan(style: style, children: highlightSpans(code, language, style)),
            softWrap: false,
            strutStyle: codeStrut(size: size),
          ),
        ),
      ),
    ]);
  }
}

/// An editable colored code field with line numbers, for the project file screen. [controller] must be a
/// [HighlightingController]. The field is as wide as its longest line (never wrapping) so line numbers
/// always line up, and scrolls sideways inside the page's own vertical scroll.
class CodeEditor extends StatelessWidget {
  const CodeEditor({super.key, required this.controller, this.onChanged, this.size = 13});

  final HighlightingController controller;
  final VoidCallback? onChanged;
  final double size;

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final text = controller.text;
        var longest = 0;
        for (final line in text.split('\n')) {
          longest = math.max(longest, line.length);
        }
        final charWidth = size * 0.602; // DejaVu Sans Mono advance width
        final digits = lineCount(text).toString().length;
        final gutterWidth = digits * charWidth + 18;
        final fieldWidth = math.max(screenWidth - gutterWidth, (longest + 8) * charWidth);
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          LineNumbers(lines: lineCount(text), size: size),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: fieldWidth,
                child: TextField(
                  controller: controller,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  autocorrect: false,
                  enableSuggestions: false,
                  cursorColor: const Color(0xFFAEAFAD),
                  onChanged: (_) => onChanged?.call(),
                  strutStyle: codeStrut(size: size),
                  style: codeTextStyle(size: size),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    filled: false,
                    contentPadding: EdgeInsets.fromLTRB(4, 12, 14, 12),
                  ),
                ),
              ),
            ),
          ),
        ]);
      },
    );
  }
}
