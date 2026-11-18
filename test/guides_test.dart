import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_chat/guides/ssh_guides.dart';
import 'package:omni_chat/ui/guides_screen.dart';

void main() {
  test('every requested system has a complete guide', () {
    final ids = sshGuides.map((g) => g.id).toSet();
    expect(ids, containsAll(<String>['powershell', 'cmd', 'macos', 'linux', 'ubuntu', 'kali']));
    for (final g in sshGuides) {
      expect(g.intro, isNotEmpty);
      final titles = g.sections.map((s) => s.title.toLowerCase()).join('|');
      expect(titles, contains('ssh server'), reason: g.id);
      expect(titles, contains('ftp'), reason: g.id);
      for (final s in g.sections) {
        expect(s.steps, isNotEmpty, reason: '${g.id}/${s.title}');
        for (final st in s.steps) {
          expect(st.text.trim(), isNotEmpty);
          if (st.command != null) expect(st.command!.trim(), isNotEmpty);
        }
      }
    }
  });

  test('key commands are present where expected', () {
    String all(String id) => sshGuides.firstWhere((g) => g.id == id).sections.expand((s) => s.steps).map((s) => s.command ?? '').join('\n');
    expect(all('powershell'), contains('Add-WindowsCapability'));
    expect(all('cmd'), contains('net start sshd'));
    expect(all('macos'), contains('setremotelogin'));
    expect(all('ubuntu'), contains('ufw allow ssh'));
    expect(all('kali'), contains('systemctl start ssh'));
  });

  testWidgets('the list opens a guide and shows copyable commands', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: GuidesScreen()));
    expect(find.text('Ubuntu'), findsOneWidget);
    await tester.tap(find.text('Ubuntu'));
    await tester.pumpAndSettle();
    expect(find.byType(GuideScreen), findsOneWidget);
    expect(find.byType(CommandBox), findsWidgets);
  });
}
