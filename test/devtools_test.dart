import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_chat/tools/browser_service.dart';
import 'package:omni_chat/tools/devtools_log.dart';
import 'package:omni_chat/ui/devtools_pane.dart';

String msg(Map<String, dynamic> m) => jsonEncode(m);

void main() {
  test('the browser identifies as desktop Chrome by default', () {
    expect(desktopUserAgent, contains('Windows NT 10.0'));
    expect(desktopUserAgent, isNot(contains('Mobile')));
    expect(phoneUserAgent, contains('Mobile'));
    expect(browserUserAgent, desktopUserAgent);
    expect(desktopViewportScript, contains('W=1280'));
    expect(desktopViewportScript, contains("'width='+W"));
    // The 1280 px layout is scaled to the screen so the page fits instead of sliding off to the right.
    expect(desktopViewportScript, contains('initial-scale='));
    expect(desktopViewportScript, contains('minimum-scale='));
  });

  test('a fetch request is tracked from start to end', () {
    final log = DevLog();
    log.handle(msg({'t': 'n', 'id': 1, 's': 'start', 'k': 'fetch', 'm': 'POST', 'u': 'https://api.x.com/v1/comments', 'rh': 'content-type: application/json', 'rb': '{"a":1}'}));
    expect(log.net.single.done, isFalse);
    expect(log.net.single.statusLabel, '…');
    log.handle(msg({'t': 'n', 'id': 1, 's': 'end', 'st': 200, 'ct': 'application/json', 'd': 42, 'h': 'x-a: b', 'b': '{"ok":true}'}));
    final e = log.net.single;
    expect(e.done, isTrue);
    expect(e.status, 200);
    expect(e.durationMs, 42);
    expect(e.failed, isFalse);
    expect(e.detail, contains('POST https://api.x.com/v1/comments'));
    expect(e.detail, contains('{"a":1}'));
    expect(e.detail, contains('{"ok":true}'));
    expect(e.path, 'api.x.com/v1/comments');
  });

  test('errors and 4xx are failures and are listed first in the model report', () {
    final log = DevLog();
    log.handle(msg({'t': 'n', 'id': 1, 's': 'start', 'k': 'xhr', 'm': 'GET', 'u': 'https://a.com/ok'}));
    log.handle(msg({'t': 'n', 'id': 1, 's': 'end', 'st': 200, 'd': 5}));
    log.handle(msg({'t': 'n', 'id': 2, 's': 'start', 'k': 'xhr', 'm': 'GET', 'u': 'https://a.com/missing'}));
    log.handle(msg({'t': 'n', 'id': 2, 's': 'end', 'st': 404, 'd': 9}));
    log.handle(msg({'t': 'n', 'id': 3, 's': 'start', 'k': 'fetch', 'm': 'GET', 'u': 'https://a.com/down'}));
    log.handle(msg({'t': 'n', 'id': 3, 's': 'err', 'd': 3, 'e': 'TypeError: Failed to fetch'}));
    expect(log.net.where((e) => e.failed).length, 2);
    final report = log.report(kind: 'network');
    expect(report.indexOf('/missing'), lessThan(report.indexOf('/ok')));
    expect(report, contains('#3'));
    expect(log.report(id: 3), contains('TypeError: Failed to fetch'));
    expect(log.report(id: 99), contains('No request #99'));
    expect(log.report(kind: 'network', filter: 'missing'), isNot(contains('/down')));
  });

  test('console messages, resources and clearing', () {
    final log = DevLog();
    log.handle(msg({'t': 'c', 'l': 'error', 'm': 'Uncaught TypeError at app.js:3'}));
    log.handle(msg({'t': 'c', 'l': 'log', 'm': 'hello'}));
    log.handle(msg({'t': 'r', 'u': 'https://cdn.x.com/a.js', 'k': 'script', 'd': 80}));
    expect(log.console.length, 2);
    expect(log.net.single.kind, 'script');
    expect(log.report(kind: 'console'), contains('[error] Uncaught TypeError at app.js:3'));
    log.newPage();
    expect(log.net, isEmpty);
    expect(log.console, isEmpty);
  });

  test('garbage and unknown messages are ignored; the log is bounded', () {
    final log = DevLog();
    log.handle('not json');
    log.handle('[1,2]');
    log.handle(msg({'t': 'zzz'}));
    expect(log.net, isEmpty);
    for (var i = 0; i < DevLog.maxEntries + 50; i++) {
      log.handle(msg({'t': 'c', 'l': 'log', 'm': 'm$i'}));
    }
    expect(log.console.length, DevLog.maxEntries);
  });

  testWidgets('the pane lists requests and switches to the console', (tester) async {
    final log = DevLog();
    log.handle(msg({'t': 'n', 'id': 1, 's': 'start', 'k': 'fetch', 'm': 'GET', 'u': 'https://api.x.com/items'}));
    log.handle(msg({'t': 'n', 'id': 1, 's': 'end', 'st': 500, 'd': 12}));
    log.handle(msg({'t': 'c', 'l': 'error', 'm': 'boom happened'}));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(height: 400, child: DevToolsPane(log: log)))));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('api.x.com/items'), findsOneWidget);
    expect(find.text('500'), findsOneWidget);
    await tester.tap(find.textContaining('Console'));
    await tester.pump();
    expect(find.text('boom happened'), findsOneWidget);
  });
}
