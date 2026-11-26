import 'package:flutter_test/flutter_test.dart';
import 'package:omni_chat/tools/chat_files.dart';

void main() {
  test('parses whole files with headers and code blocks', () {
    const reply = '''
Here you go.

=== FILE: src/app.py ===
```python
import os

def main():
    print("hi")
```

=== FILE: README.md ===
````markdown
# Title

```bash
run it
```
````
=== MORE: tests/test_app.py, setup.cfg ===
''';
    final r = parseChatFiles(reply);
    expect(r.items.map((e) => e.path), <String>['src/app.py', 'README.md']);
    expect(r.items[0].content, 'import os\n\ndef main():\n    print("hi")\n');
    expect(r.items[1].content, contains('```bash'));
    expect(r.items[1].content, endsWith('run it\n```\n'));
    expect(r.items.every((e) => !e.truncated), isTrue);
    expect(r.more, <String>['tests/test_app.py', 'setup.cfg']);
  });

  test('headers wrapped in markdown still count', () {
    const reply = '**=== FILE: a/b.txt ===**\n```\nx\n```\n';
    final r = parseChatFiles(reply);
    expect(r.items.single.path, 'a/b.txt');
    expect(r.items.single.content, 'x\n');
  });

  test('an unclosed code block is marked as cut off', () {
    final r = parseChatFiles('=== FILE: big.py ===\n```python\nprint(1)\nprint(2)\n');
    expect(r.items.single.truncated, isTrue);
  });

  test('parses edit blocks', () {
    const reply = '''
=== EDIT: app.py ===
```
<<<<<<< SEARCH
x = 1
=======
x = 2
>>>>>>> REPLACE
<<<<<<< SEARCH
def f():
    pass
=======
def f():
    return 3
>>>>>>> REPLACE
```
''';
    final r = parseChatFiles(reply);
    expect(r.items.single.isEdit, isTrue);
    expect(r.items.single.edits.length, 2);
    expect(r.items.single.edits[0].search, 'x = 1');
    expect(r.items.single.edits[1].replace, 'def f():\n    return 3');
    expect(r.items.single.truncated, isFalse);
  });

  test('without headers a file name line before a code block is used', () {
    final r = parseChatFiles('Sure.\n\n**main.dart**\n```dart\nvoid main() {}\n```\n\nfile: lib/a.dart\n```dart\nclass A {}\n```\n');
    expect(r.items.map((e) => e.path), <String>['main.dart', 'lib/a.dart']);
    expect(r.items[1].content, 'class A {}\n');
  });

  test('plain prose gives no files', () {
    expect(parseChatFiles('I think you should use a loop.\n\n```python\nfor i in x: pass\n```').items, isEmpty);
  });

  test('edits apply exactly once, or are refused', () {
    const text = 'a\nx = 1\nb\nx = 1\n';
    final amb = applyChatEdits(text, const <ChatEdit>[ChatEdit('x = 1', 'x = 2')]);
    expect(amb.applied, 0);
    expect(amb.results.single.note, contains('2 times'));
    final ok = applyChatEdits(text, const <ChatEdit>[ChatEdit('a\nx = 1', 'a\nx = 9')]);
    expect(ok.applied, 1);
    expect(ok.text, 'a\nx = 9\nb\nx = 1\n');
    final none = applyChatEdits(text, const <ChatEdit>[ChatEdit('nothing here', 'q')]);
    expect(none.applied, 0);
    expect(none.text, text);
  });

  test('edits tolerate changed indentation and keep the file indentation', () {
    const text = 'class A:\n    def f(self):\n        return 1\n';
    final r = applyChatEdits(text, const <ChatEdit>[ChatEdit('def f(self):\n    return 1', 'def f(self):\n    return 2')]);
    expect(r.applied, 1);
    expect(r.text, 'class A:\n    def f(self):\n        return 2\n');
  });

  test('before/after summary names the changed lines', () {
    final s = briefChange('a\nb\nc\n', 'a\nB\nc\n');
    expect(s, contains('- b'));
    expect(s, contains('+ B'));
    expect(briefChange('x', 'x'), 'no change');
  });

  test('format instructions mention the markers the parser reads', () {
    expect(kFilesFormat, contains('=== FILE:'));
    expect(kEditsFormat, contains('<<<<<<< SEARCH'));
    expect(kEditsFormat, contains('>>>>>>> REPLACE'));
  });
}
