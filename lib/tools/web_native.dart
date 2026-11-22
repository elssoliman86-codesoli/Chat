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
}
