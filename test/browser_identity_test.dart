import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_chat/core/models.dart';
import 'package:omni_chat/data/services.dart';
import 'package:omni_chat/tools/browser_identity.dart';
import 'package:omni_chat/ui/browser_choice_screen.dart';
import 'package:omni_chat/ui/theme.dart';

void main() {
  test('browsers are told apart by package name and label', () {
    expect(browserFamily('org.mozilla.firefox', 'Firefox'), BrowserFamily.firefox);
    expect(browserFamily('org.mozilla.fenix', 'Firefox Nightly'), BrowserFamily.firefox);
    expect(browserFamily('org.torproject.torbrowser', 'Tor Browser'), BrowserFamily.tor);
    expect(browserFamily('com.android.chrome', 'Chrome'), BrowserFamily.chrome);
    expect(browserFamily('com.microsoft.emmx', 'Edge'), BrowserFamily.edge);
    expect(browserFamily('com.opera.browser', 'Opera'), BrowserFamily.opera);
    expect(browserFamily('com.brave.browser', 'Brave'), BrowserFamily.other);
  });

  test('the version number is read from the first digits', () {
    expect(majorVersion('131.0.2'), 131);
    expect(majorVersion('v14.0.1-beta'), 14);
    expect(majorVersion(''), 0);
  });

  test('every identity is a desktop browser user agent', () {
    final ff = identityUserAgent(package: 'org.mozilla.firefox', label: 'Firefox', version: '131.0.2');
    expect(ff, contains('Firefox/131.0'));
    expect(ff, contains('Gecko/20100101'));
    expect(ff, isNot(contains('Chrome')));
    expect(ff, isNot(contains('Mobile')));

    final tor = identityUserAgent(package: 'org.torproject.torbrowser', label: 'Tor Browser', version: '14.0.1');
    expect(tor, contains('Firefox/'));
    expect(tor, isNot(contains('Tor')));

    final chrome = identityUserAgent(package: 'com.android.chrome', label: 'Chrome', version: '131.0.6778.39');
    expect(chrome, contains('Chrome/131.0.0.0'));
    expect(chrome, isNot(contains('Mobile')));

    expect(identityUserAgent(package: 'com.microsoft.emmx', label: 'Edge', version: '131.0.1'), contains('Edg/131.0.0.0'));
    expect(identityUserAgent(package: 'com.brave.browser', label: 'Brave'), contains('Chrome/124'));
    expect(identityUserAgent(package: ''), contains('Chrome/124'));
  });

  test('the choice survives a JSON round trip and defaults to the built-in browser', () {
    expect(AppSettings().localBrowser, '');
    final s = AppSettings()
      ..localBrowser = 'org.mozilla.firefox'
      ..localBrowserName = 'Firefox'
      ..localBrowserVersion = '131.0';
    final r = AppSettings.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
    expect(r.localBrowser, 'org.mozilla.firefox');
    expect(r.localBrowserName, 'Firefox');
    expect(r.localBrowserVersion, '131.0');
  });

  testWidgets('the list shows the built-in browser first and then the installed ones', (tester) async {
    store.settings.localBrowser = '';
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(extensions: const [Palette.dark]),
      home: BrowserChoiceScreen(
        loader: () async => const [
          InstalledBrowser(package: 'com.android.chrome', label: 'Chrome', version: '131.0.1'),
          InstalledBrowser(package: 'org.mozilla.firefox', label: 'Firefox', version: '131.0'),
          InstalledBrowser(package: 'org.torproject.torbrowser', label: 'Tor Browser', version: '14.0'),
        ],
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Built-in browser'), findsOneWidget);
    expect(find.text('Chrome'), findsOneWidget);
    expect(find.text('Firefox'), findsOneWidget);
    expect(find.text('Tor Browser'), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.checkmark_alt), findsOneWidget);
  });
}
