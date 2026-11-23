import 'package:flutter_test/flutter_test.dart';
import 'package:omni_chat/tools/password_script.dart';
import 'package:omni_chat/tools/saved_logins.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('www. and m. versions of a site share one login', () {
    expect(SavedLogins.normalizeHost('WWW.Example.com'), 'example.com');
    expect(SavedLogins.normalizeHost('m.example.com'), 'example.com');
    expect(SavedLogins.normalizeHost('accounts.google.com'), 'accounts.google.com');
  });

  test('origins are built from web addresses only', () {
    expect(SavedLogins.originOf('https://a.example.com/x?y=1'), 'https://a.example.com');
    expect(SavedLogins.originOf('http://localhost:8080/a'), 'http://localhost:8080');
    expect(SavedLogins.originOf('about:blank'), '');
    expect(SavedLogins.originOf('file:///a'), '');
  });

  test('a login is added once, a new password for the same user replaces the old one', () {
    final s = SavedLogins();
    expect(s.remember('www.site.com', 'ahmed', 'one'), isTrue);
    expect(s.remember('site.com', 'ahmed', 'one'), isFalse);
    expect(s.remember('site.com', 'ahmed', 'two'), isTrue);
    expect(s.remember('site.com', 'sara', 'x'), isTrue);
    expect(s.items.length, 2);
    expect(s.forHost('m.site.com').map((l) => l.user).toSet(), {'ahmed', 'sara'});
    expect(s.forHost('site.com').firstWhere((l) => l.user == 'ahmed').pass, 'two');
    expect(s.forHost('other.com'), isEmpty);
  });

  test('nothing is saved when saving is switched off or the password is empty', () {
    final s = SavedLogins();
    expect(s.remember('site.com', 'a', ''), isFalse);
    s.setEnabled(false);
    expect(s.remember('site.com', 'a', 'p'), isFalse);
    expect(s.items, isEmpty);
  });

  test('logins and cookies survive a restart', () async {
    final a = SavedLogins();
    a.remember('site.com', 'ahmed', 'pw');
    a.rememberCookies('https://site.com', 'sid=1; theme=dark');
    await a.save();
    final b = SavedLogins();
    await b.load();
    expect(b.items.single.user, 'ahmed');
    expect(b.items.single.pass, 'pw');
    expect(b.cookies['https://site.com'], 'sid=1; theme=dark');
  });

  test('a site with no cookies left is forgotten, and the list is capped', () {
    final s = SavedLogins();
    s.rememberCookies('https://a.com', 'x=1');
    s.rememberCookies('https://a.com', '');
    expect(s.cookies, isEmpty);
    for (var i = 0; i < SavedLogins.maxCookieOrigins + 20; i++) {
      s.rememberCookies('https://s$i.com', 'k=$i');
    }
    expect(s.cookies.length, SavedLogins.maxCookieOrigins);
    expect(s.cookies.containsKey('https://s${SavedLogins.maxCookieOrigins + 19}.com'), isTrue);
    expect(s.cookies.containsKey('https://s0.com'), isFalse);
  });

  test('the fill script carries the login as data and is balanced', () {
    final js = passwordFillScript('{"u":"a@b.c","p":"x\\"y"}');
    expect(js, contains('{"u":"a@b.c","p":"x\\"y"}'));
    for (final script in [js, passwordWatchScript, passwordVisibleScript]) {
      expect('{'.allMatches(script).length, '}'.allMatches(script).length);
      expect('('.allMatches(script).length, ')'.allMatches(script).length);
    }
  });
}
