import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_chat/core/models.dart';
import 'package:omni_chat/tools/browser_cursor.dart';

void main() {
  test('the cursor script is plain DOM code that a strict page policy cannot block', () {
    expect(omniCursorScript, contains('window.__omniCursor'));
    expect(omniCursorScript, isNot(contains('innerHTML')));
    expect(omniCursorScript, isNot(contains('eval(')));
    for (final fn in ['go:', 'press:', 'typeInto:', 'move:']) {
      expect(omniCursorScript, contains(fn));
    }
  });

  test('the cursor script is balanced and safe to run twice', () {
    final s = omniCursorScript.replaceAll(RegExp(r"'(?:\\.|[^'\\\n])*'"), "''");
    expect('('.allMatches(s).length, ')'.allMatches(s).length);
    expect('{'.allMatches(s).length, '}'.allMatches(s).length);
    expect('['.allMatches(s).length, ']'.allMatches(s).length);
    expect(omniCursorScript, contains("document.getElementById('__omni_cursor')"));
  });

  test('the cursor is on by default and the choice is saved', () {
    expect(AppSettings().browserCursor, isTrue);
    final s = AppSettings()..browserCursor = false;
    final r = AppSettings.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
    expect(r.browserCursor, isFalse);
    // Settings saved before the cursor existed keep it on.
    expect(AppSettings.fromJson(<String, dynamic>{}).browserCursor, isTrue);
  });
}
