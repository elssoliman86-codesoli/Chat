import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_chat/ui/code_view.dart';
import 'package:omni_chat/ui/markdown_view.dart';
import 'package:omni_chat/ui/syntax.dart';

TokenKind? kindOf(List<CodeToken> tokens, String text) {
  for (final t in tokens) {
    if (t.text == text) return t.kind;
  }
  return null;
}

String joined(List<CodeToken> tokens) => tokens.map((t) => t.text).join();

void main() {
  group('tokenize', () {
    test('python: keywords, function names, strings, numbers and comments get their own colors', () {
      const code = 'def hello(name):\n    # say hi\n    return "x" + 42\n';
      final t = tokenize(code, 'python');
      expect(kindOf(t, 'def'), TokenKind.keyword);
      expect(kindOf(t, 'hello'), TokenKind.function);
      expect(kindOf(t, '# say hi'), TokenKind.comment);
      expect(kindOf(t, 'return'), TokenKind.keyword);
      expect(kindOf(t, '"x"'), TokenKind.string);
      expect(kindOf(t, '42'), TokenKind.number);
      expect(joined(t), code);
    });

    test('json: keys are properties, values are strings/numbers/constants', () {
      const code = '{"name": "omni", "n": 12, "ok": true, "x": null}';
      final t = tokenize(code, 'json');
      expect(kindOf(t, '"name"'), TokenKind.property);
      expect(kindOf(t, '"omni"'), TokenKind.string);
      expect(kindOf(t, '12'), TokenKind.number);
      expect(kindOf(t, 'true'), TokenKind.constant);
      expect(kindOf(t, 'null'), TokenKind.constant);
      expect(joined(t), code);
    });

    test('html: tags, attribute names and values, comments', () {
      const code = '<a href="x">hi</a><!-- note -->';
      final t = tokenize(code, 'html');
      expect(kindOf(t, '<a'), TokenKind.tag);
      expect(kindOf(t, 'href'), TokenKind.attribute);
      expect(kindOf(t, '"x"'), TokenKind.string);
      expect(kindOf(t, '</a'), TokenKind.tag);
      expect(kindOf(t, '<!-- note -->'), TokenKind.comment);
      expect(joined(t), code);
    });

    test('bash: variables, comments and commands', () {
      const code = 'echo \$HOME # note\nls -la';
      final t = tokenize(code, 'bash');
      expect(kindOf(t, 'echo'), TokenKind.keyword);
      expect(kindOf(t, '\$HOME'), TokenKind.variable);
      expect(kindOf(t, '# note'), TokenKind.comment);
      expect(joined(t), code);
    });

    test('javascript: template strings, decorators-free keywords, constants and types', () {
      const code = 'const x = `a\nb`; if (x === null) console.log(1.5e3);';
      final t = tokenize(code, 'js');
      expect(kindOf(t, 'const'), TokenKind.keyword);
      expect(kindOf(t, '`a\nb`'), TokenKind.string);
      expect(kindOf(t, 'null'), TokenKind.constant);
      expect(kindOf(t, 'console'), TokenKind.type);
      expect(kindOf(t, 'log'), TokenKind.function);
      expect(kindOf(t, '1.5e3'), TokenKind.number);
      expect(joined(t), code);
    });

    test('css: properties, hex colors and units', () {
      const code = 'a { color: #1e1e1e; margin: 4px; }';
      final t = tokenize(code, 'css');
      expect(kindOf(t, 'color'), TokenKind.property);
      expect(kindOf(t, '#1e1e1e'), TokenKind.number);
      expect(kindOf(t, '4px'), TokenKind.number);
      expect(joined(t), code);
    });

    test('an unknown language or plain text stays one uncolored block', () {
      final t = tokenize('just some words', 'text');
      expect(t, hasLength(1));
      expect(t.single.kind, TokenKind.plain);
      expect(canHighlight('python'), true);
      expect(canHighlight('PY'), true);
      expect(canHighlight('klingon'), false);
    });

    test('Arabic text inside a string stays part of the string', () {
      const code = "message: 'يرجى إدخال بريد'";
      final t = tokenize(code, 'js');
      expect(kindOf(t, "'يرجى إدخال بريد'"), TokenKind.string);
      expect(joined(t), code);
    });

    test('a block over the size cap is left uncolored', () {
      final big = 'x = 1\n' * (kMaxHighlightChars ~/ 4);
      final t = tokenize(big, 'python');
      expect(t, hasLength(1));
      expect(t.single.kind, TokenKind.plain);
    });

    test('never loses or reorders a character, whatever it is fed', () {
      const inputs = <String>[
        '',
        '"unterminated',
        "'a\\",
        '/* open',
        '<!-- open',
        '<a href="x',
        '\u0000',
        'مرحبا "عالم" 123',
        'a\r\nb\r\n',
        '```',
        '\$',
        '\${',
        '@',
        '0x',
        '1e',
        '.5',
        '1.',
        "'''triple\nstill open",
        '#fff #12 #',
        'a.b.c(d).e',
        '---\nkey: value\nlist:\n  - a\n',
      ];
      const languages = <String>['python', 'js', 'ts', 'dart', 'java', 'cpp', 'go', 'rust', 'php', 'ruby', 'bash', 'sql', 'css', 'yaml', 'toml', 'json', 'html'];
      for (final lang in languages) {
        for (final code in inputs) {
          expect(joined(tokenize(code, lang)), code, reason: 'language $lang, input ${code.replaceAll('\n', r'\n')}');
        }
      }
    });
  });

  group('languageForPath', () {
    test('picks a language by extension and leaves unknown ones uncolored', () {
      expect(languageForPath('lib/app.js'), 'js');
      expect(languageForPath('main.PY'), 'py');
      expect(languageForPath('index.htm'), 'html');
      expect(languageForPath('build.gradle'), 'java');
      expect(languageForPath('Dockerfile'), 'bash');
      expect(languageForPath('notes.txt'), '');
      expect(languageForPath('README'), '');
    });
  });

  group('code widgets', () {
    testWidgets('read-only code shows line numbers beside the colored text', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: HighlightedCode(code: 'a = 1\nb = 2\nc = 3', language: 'python')),
      ));
      expect(find.text('1\n2\n3'), findsOneWidget);
      expect(find.textContaining('b = 2'), findsOneWidget);
    });

    testWidgets('the chat code block keeps its language label and Copy button', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: CodeBlock(code: 'print(1)', language: 'python')),
      ));
      expect(find.text('python'), findsOneWidget);
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
    });

    testWidgets('the editor numbers its lines and colors what is typed', (tester) async {
      final controller = HighlightingController(text: 'def f():\n    return 1', language: 'python');
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: CodeEditor(controller: controller))),
      ));
      expect(find.text('1\n2'), findsOneWidget);

      final context = tester.element(find.byType(CodeEditor));
      final span = controller.buildTextSpan(context: context, style: null, withComposing: false);
      final def = span.children!.whereType<TextSpan>().firstWhere((s) => s.text == 'def');
      expect(def.style!.color, CodeTheme.dark.colorOf(TokenKind.keyword));

      controller.text = 'a\nb\nc';
      await tester.pump();
      expect(find.text('1\n2\n3'), findsOneWidget);
    });
  });
}
