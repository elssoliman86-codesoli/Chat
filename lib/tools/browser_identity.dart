import 'package:flutter/services.dart';

/// A browser app found on the phone.
class InstalledBrowser {
  const InstalledBrowser({required this.package, required this.label, this.version = ''});

  final String package;
  final String label;
  final String version;

  BrowserFamily get family => browserFamily(package, label);
}

enum BrowserFamily { chrome, firefox, tor, edge, opera, other }

/// Which kind of browser an installed app is, from its package name and label.
BrowserFamily browserFamily(String package, String label) {
  final p = package.toLowerCase();
  final l = label.toLowerCase();
  if (p.startsWith('org.torproject') || l.contains('tor browser') || l == 'tor') return BrowserFamily.tor;
  if (p.startsWith('org.mozilla') || p.contains('firefox') || p.contains('fenix') || l.contains('firefox')) return BrowserFamily.firefox;
  if (p == 'com.microsoft.emmx' || p.contains('edge') || l.contains('edge')) return BrowserFamily.edge;
  if (p.startsWith('com.opera') || l.contains('opera')) return BrowserFamily.opera;
  if (p == 'com.android.chrome' || p.startsWith('com.chrome') || p.contains('apps.chrome') || l == 'chrome') return BrowserFamily.chrome;
  return BrowserFamily.other;
}

/// The first number of a version like "131.0.2" — 0 when there is none.
int majorVersion(String version) => int.tryParse(RegExp(r'\d+').firstMatch(version)?.group(0) ?? '') ?? 0;

const int _defaultChrome = 124;

/// The desktop (computer) user agent of the chosen browser. The built-in browser always asks for the full
/// computer version of sites, so this is the desktop one of that browser. [package] empty means the
/// built-in default.
String identityUserAgent({required String package, String label = '', String version = ''}) {
  if (package.isEmpty) return _chrome(_defaultChrome);
  final major = majorVersion(version);
  switch (browserFamily(package, label)) {
    case BrowserFamily.firefox:
      final v = major > 0 ? major : 128;
      return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:$v.0) Gecko/20100101 Firefox/$v.0';
    case BrowserFamily.tor:
      // Tor Browser reports a fixed Firefox (ESR) identity on purpose; its own version number is not Firefox's.
      return 'Mozilla/5.0 (Windows NT 10.0; rv:140.0) Gecko/20100101 Firefox/140.0';
    case BrowserFamily.edge:
      final v = major > 0 ? major : _defaultChrome;
      return '${_chrome(v)} Edg/$v.0.0.0';
    case BrowserFamily.opera:
      return '${_chrome(_defaultChrome)} OPR/${major > 0 ? major : 110}.0.0.0';
    case BrowserFamily.chrome:
      return _chrome(major > 0 ? major : _defaultChrome);
    case BrowserFamily.other:
      return _chrome(_defaultChrome);
  }
}

String _chrome(int v) => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$v.0.0.0 Safari/537.36';

/// Finds the browsers installed on this phone (Android only).
class BrowserList {
  static const MethodChannel _channel = MethodChannel('omni/browsers');

  static Future<List<InstalledBrowser>> installed() async {
    try {
      final r = await _channel.invokeMethod<List<Object?>>('list');
      final out = <InstalledBrowser>[];
      for (final e in r ?? const <Object?>[]) {
        if (e is! Map) continue;
        final p = (e['package'] ?? '').toString();
        if (p.isEmpty) continue;
        out.add(InstalledBrowser(package: p, label: (e['label'] ?? p).toString(), version: (e['version'] ?? '').toString()));
      }
      out.sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
      return out;
    } on MissingPluginException {
      return const <InstalledBrowser>[];
    } catch (_) {
      return const <InstalledBrowser>[];
    }
  }
}
