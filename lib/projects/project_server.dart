import 'dart:async';
import 'dart:io';

import 'project_store.dart';

const Map<String, String> _mime = {
  'html': 'text/html; charset=utf-8',
  'htm': 'text/html; charset=utf-8',
  'css': 'text/css; charset=utf-8',
  'js': 'text/javascript; charset=utf-8',
  'mjs': 'text/javascript; charset=utf-8',
  'json': 'application/json; charset=utf-8',
  'map': 'application/json; charset=utf-8',
  'svg': 'image/svg+xml',
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'ico': 'image/x-icon',
  'txt': 'text/plain; charset=utf-8',
  'md': 'text/plain; charset=utf-8',
  'xml': 'application/xml; charset=utf-8',
  'woff': 'font/woff',
  'woff2': 'font/woff2',
  'ttf': 'font/ttf',
  'otf': 'font/otf',
  'mp3': 'audio/mpeg',
  'wav': 'audio/wav',
  'mp4': 'video/mp4',
  'webm': 'video/webm',
  'pdf': 'application/pdf',
  'wasm': 'application/wasm',
};

/// A small static web server on this phone only (127.0.0.1) that serves every project folder,
/// so a web project runs with real linked files: /<projectId>/index.html.
class ProjectServer {
  ProjectServer(this.store);

  final ProjectStore store;
  HttpServer? _server;

  bool get running => _server != null;
  int get port => _server?.port ?? 0;

  Future<int> start() async {
    final existing = _server;
    if (existing != null) return existing.port;
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = s;
    s.listen(_handle, onError: (_) {});
    return s.port;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  /// The address of a project's page, starting the server when needed.
  Future<String> urlFor(String projectId, [String page = '']) async {
    final p = await start();
    final rel = safeRel(page) ?? '';
    return 'http://127.0.0.1:$p/$projectId/$rel';
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final segs = req.uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segs.isEmpty || segs.any((s) => s == '..')) {
        res.statusCode = HttpStatus.notFound;
        await res.close();
        return;
      }
      final id = segs.first;
      final dir = await store.dirOf(id);
      var rel = segs.skip(1).join('/');
      var file = File('$dir/$rel');
      if (rel.isEmpty || await FileSystemEntity.isDirectory(file.path)) {
        final idx = File('${rel.isEmpty ? dir : file.path}/index.html');
        file = idx;
      }
      if (!await file.exists()) {
        // Single page apps: a path without extension falls back to index.html.
        final last = segs.last;
        final fallback = File('$dir/index.html');
        if (!last.contains('.') && await fallback.exists()) {
          file = fallback;
        } else {
          res.statusCode = HttpStatus.notFound;
          res.headers.contentType = ContentType.text;
          res.write('Not found: /${segs.join('/')}');
          await res.close();
          return;
        }
      }
      final name = file.path.split('/').last;
      final dot = name.lastIndexOf('.');
      final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
      res.headers.set('Content-Type', _mime[ext] ?? 'application/octet-stream');
      res.headers.set('Cache-Control', 'no-store');
      res.headers.set('Access-Control-Allow-Origin', '*');
      res.contentLength = await file.length();
      if (req.method == 'HEAD') {
        await res.close();
        return;
      }
      await res.addStream(file.openRead());
      await res.close();
    } catch (_) {
      try {
        res.statusCode = HttpStatus.internalServerError;
        await res.close();
      } catch (_) {}
    }
  }
}
