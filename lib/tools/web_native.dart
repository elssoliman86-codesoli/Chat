import 'dart:async';

import 'package:flutter/services.dart';

/// A download the web view handed over (a link the page wants to save rather than show).
class WebDownloadRequest {
  const WebDownloadRequest({
    required this.url,
    this.userAgent = '',
    this.disposition = '',
    this.mime = '',
    this.length = -1,
    this.cookie = '',
    this.referer = '',
  });

  final String url;
  final String userAgent;
  final String disposition;
  final String mime;
  final int length;
  final String cookie;
  final String referer;
}

/// Native helpers for the built-in browser's web view (Android only; every call is safe elsewhere).
class WebNative {
  static const MethodChannel _channel = MethodChannel('omni/webview');
  static final StreamController<WebDownloadRequest> _downloads = StreamController<WebDownloadRequest>.broadcast();
  static bool _wired = false;

  /// Downloads the web view starts (a file link, an attachment…).
  static Stream<WebDownloadRequest> get downloads {
    _wire();
    return _downloads.stream;
  }

  /// Hands a download to the same place the web view's own downloads go (used when the app itself spots a file link).
  static void emit(WebDownloadRequest r) {
    _wire();
    _downloads.add(r);
  }

  static const Set<String> _fileTypes = <String>{
    'apk', 'apks', 'xapk', 'aab', 'zip', 'rar', '7z', 'tar', 'gz', 'tgz', 'bz2', 'xz', 'exe', 'msi', 'dmg', 'iso', 'img', 'pkg', 'deb', 'rpm',
    'jar', 'bin', 'pdf', 'mp3', 'm4a', 'flac', 'wav', 'ogg', 'mp4', 'mkv', 'avi', 'mov', 'webm', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx',
    'epub', 'torrent',
  };

  /// True for an address that points at a file the browser cannot show, judged by the end of its path.
  static bool looksLikeDownload(String url) {
    final u = Uri.tryParse(url);
    if (u == null || (u.scheme != 'http' && u.scheme != 'https') || u.pathSegments.isEmpty) return false;
    final last = u.pathSegments.last.toLowerCase();
    final dot = last.lastIndexOf('.');
    if (dot < 0 || dot == last.length - 1) return false;
    return _fileTypes.contains(last.substring(dot + 1));
  }

  static void _wire() {
    if (_wired) return;
    _wired = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'download') return null;
      final a = call.arguments;
      if (a is! Map) return null;
      _downloads.add(WebDownloadRequest(
        url: (a['url'] ?? '').toString(),
        userAgent: (a['ua'] ?? '').toString(),
        disposition: (a['disposition'] ?? '').toString(),
        mime: (a['mime'] ?? '').toString(),
        length: (a['length'] is num) ? (a['length'] as num).toInt() : -1,
        cookie: (a['cookie'] ?? '').toString(),
        referer: (a['referer'] ?? '').toString(),
      ));
      return null;
    });
  }

  /// Finds the browser's web view and sets it up: no "X-Requested-With" header (sites that block embedded
  /// browsers look for it), third-party cookies on (sign-in flows need them) and downloads handed to the app.
  /// Returns what was done, or null when nothing could be reached.
  static Future<Map<String, dynamic>?> prepare({bool downloads = true, String userAgent = '', bool desktop = true}) async {
    _wire();
    try {
      final r = await _channel.invokeMethod<Map<dynamic, dynamic>>('prepare', <String, dynamic>{'downloads': downloads, 'ua': userAgent, 'desktop': desktop});
      return r?.map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {
      return null;
    }
  }
}
