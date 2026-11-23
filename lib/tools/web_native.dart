import 'package:flutter/services.dart';

/// Native helpers for the built-in browser's web view (Android only; every call is safe elsewhere).
class WebNative {
  static const MethodChannel _channel = MethodChannel('omni/webview');

  /// Finds the browser's web view and sets it up: no "X-Requested-With" header (sites that block embedded
  /// browsers look for it), third-party cookies on (sign-in flows need them) and client hints that match the
  /// user agent. Returns what was done, or null when nothing could be reached.
  static Future<Map<String, dynamic>?> prepare({String userAgent = '', bool desktop = true}) async {
    try {
      final r = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'prepare',
        <String, dynamic>{'downloads': false, 'ua': userAgent, 'desktop': desktop},
      );
      return r?.map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {
      return null;
    }
  }

  /// The cookies the web view would send to [url] (every one it holds for that site, name=value; …).
  static Future<String> cookies(String url) async {
    try {
      return (await _channel.invokeMethod<String>('cookies', <String, dynamic>{'url': url})) ?? '';
    } catch (_) {
      return '';
    }
  }

  /// Puts back saved cookies the web view no longer has (it drops those without an expiry date when the app closes).
  /// Each item is {url, cookie}. Returns how many were set.
  static Future<int> restoreCookies(List<Map<String, String>> items) async {
    try {
      return (await _channel.invokeMethod<int>('restore', <String, dynamic>{'items': items})) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Writes the web view's cookies to disk now, so a closed or killed app does not lose them.
  static Future<void> flushCookies() async {
    try {
      await _channel.invokeMethod<void>('flush');
    } catch (_) {}
  }
}
