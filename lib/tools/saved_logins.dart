import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'web_native.dart';

/// A user name and password the built-in browser saved for a site.
class SavedLogin {
  SavedLogin({required this.host, required this.user, required this.pass, DateTime? saved, DateTime? used})
      : saved = saved ?? DateTime.now(),
        used = used ?? DateTime.now();

  final String host;
  String user;
  String pass;
  DateTime saved;
  DateTime used;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'host': host,
        'user': user,
        'pass': pass,
        'saved': saved.millisecondsSinceEpoch,
        'used': used.millisecondsSinceEpoch,
      };

  static SavedLogin? fromJson(Object? j) {
    if (j is! Map) return null;
    final host = (j['host'] ?? '').toString();
    final pass = (j['pass'] ?? '').toString();
    if (host.isEmpty || pass.isEmpty) return null;
    DateTime when(Object? v) => DateTime.fromMillisecondsSinceEpoch(v is num ? v.toInt() : 0);
    return SavedLogin(host: host, user: (j['user'] ?? '').toString(), pass: pass, saved: when(j['saved']), used: when(j['used']));
  }
}

/// What the built-in browser remembers between runs: the logins (user name + password) and the cookies of the sites
/// the person signed in to. The web view forgets cookies that have no expiry date every time the app is closed, which
/// is why a site could ask for the sign-in again on every start; keeping them here and putting them back fixes that.
class SavedLogins extends ChangeNotifier {
  SavedLogins();

  static final SavedLogins instance = SavedLogins();

  static const String _kLogins = 'omni.web.logins';
  static const String _kCookies = 'omni.web.cookies';
  static const String _kEnabled = 'omni.web.savelogins';
  static const int maxCookieOrigins = 150;
  static const int maxLogins = 500;

  /// Save passwords automatically after a sign-in. Cookies are always kept.
  bool enabled = true;
  final List<SavedLogin> items = <SavedLogin>[];

  /// Cookie header text by origin (https://host).
  final Map<String, String> cookies = <String, String>{};
  Timer? _timer;
  bool _loaded = false;

  /// The host without a leading "www." / "m." so a site's versions share one login.
  static String normalizeHost(String host) {
    var h = host.trim().toLowerCase();
    for (final p in const ['www.', 'm.']) {
      if (h.startsWith(p) && h.length > p.length + 3) h = h.substring(p.length);
    }
    return h;
  }

  /// The origin ("https://host") of an address, or '' when it is not a web page.
  static String originOf(String url) {
    final u = Uri.tryParse(url);
    if (u == null || (u.scheme != 'http' && u.scheme != 'https') || u.host.isEmpty) return '';
    return '${u.scheme}://${u.host}${u.hasPort && u.port != 80 && u.port != 443 ? ':${u.port}' : ''}';
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      enabled = prefs.getBool(_kEnabled) ?? true;
      final raw = prefs.getString(_kLogins);
      if (raw != null && raw.isNotEmpty) {
        for (final e in (jsonDecode(raw) as List<dynamic>)) {
          final l = SavedLogin.fromJson(e);
          if (l != null) items.add(l);
        }
      }
      final c = prefs.getString(_kCookies);
      if (c != null && c.isNotEmpty) {
        (jsonDecode(c) as Map<String, dynamic>).forEach((k, v) {
          if (v is String && v.isNotEmpty) cookies[k] = v;
        });
      }
    } catch (_) {}
  }

  void _later() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 800), () => unawaited(save()));
  }

  Future<void> save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kEnabled, enabled);
      await prefs.setString(_kLogins, jsonEncode(items.map((e) => e.toJson()).toList()));
      await prefs.setString(_kCookies, jsonEncode(cookies));
    } catch (_) {}
  }

  void setEnabled(bool v) {
    enabled = v;
    notifyListeners();
    _later();
  }

  /// Logins for a site, the most recently used first.
  List<SavedLogin> forHost(String host) {
    final n = normalizeHost(host);
    final out = items.where((l) => normalizeHost(l.host) == n).toList()..sort((a, b) => b.used.compareTo(a.used));
    return out;
  }

  /// Saves a login. Returns true when something was added or changed.
  bool remember(String host, String user, String pass) {
    if (!enabled || host.isEmpty || pass.isEmpty) return false;
    final n = normalizeHost(host);
    for (final l in items) {
      if (normalizeHost(l.host) == n && l.user == user) {
        l.used = DateTime.now();
        if (l.pass == pass) {
          _later();
          return false;
        }
        l.pass = pass;
        l.saved = DateTime.now();
        notifyListeners();
        _later();
        return true;
      }
    }
    items.add(SavedLogin(host: n, user: user, pass: pass));
    if (items.length > maxLogins) {
      items.sort((a, b) => b.used.compareTo(a.used));
      items.removeRange(maxLogins, items.length);
    }
    notifyListeners();
    _later();
    return true;
  }

  void touch(SavedLogin l) {
    l.used = DateTime.now();
    _later();
  }

  void remove(SavedLogin l) {
    items.remove(l);
    notifyListeners();
    _later();
  }

  void clearLogins() {
    items.clear();
    notifyListeners();
    _later();
  }

  /// Keeps what the web view holds for a site so it can be put back after the app was closed.
  void rememberCookies(String origin, String cookie) {
    if (origin.isEmpty) return;
    final c = cookie.trim();
    if (c.isEmpty) {
      if (cookies.remove(origin) != null) _later();
      return;
    }
    if (cookies[origin] == c) return;
    cookies.remove(origin);
    cookies[origin] = c; // newest last
    while (cookies.length > maxCookieOrigins) {
      cookies.remove(cookies.keys.first);
    }
    _later();
  }

  void clearCookies() {
    cookies.clear();
    notifyListeners();
    _later();
  }

  /// Puts the saved cookies back into the web view (those it no longer has). Returns how many were restored.
  Future<int> restoreCookies() async {
    await load();
    if (cookies.isEmpty) return 0;
    return WebNative.restoreCookies(<Map<String, String>>[
      for (final e in cookies.entries) <String, String>{'url': e.key, 'cookie': e.value},
    ]);
  }
}
