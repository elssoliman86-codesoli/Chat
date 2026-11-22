import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'download_task.dart';

/// Joins finished part files into the file the person chose. Android's save picker hands out content://
/// addresses that only the native side can write, so that implementation lives behind this interface.
abstract class DownloadSaver {
  /// Asks where to save the file. Null when the person cancels.
  Future<String?> pickTarget(String name, String mime);

  /// Writes [parts], in order, to [target] and removes them.
  Future<void> merge(String target, List<String> parts);

  Future<void> open(String target, String mime);
}

/// Appends [parts], in order, to the file at [path] (replacing what was there) and deletes the parts.
Future<void> mergeFiles(String path, List<String> parts) async {
  final out = File(path);
  await out.parent.create(recursive: true);
  final sink = out.openWrite();
  try {
    for (final p in parts) {
      await sink.addStream(File(p).openRead());
    }
  } finally {
    await sink.close();
  }
  for (final p in parts) {
    try {
      await File(p).delete();
    } catch (_) {}
  }
}

/// A header value the HTTP client will accept: it refuses anything outside printable ASCII (a cookie or
/// referer with Arabic text in it would otherwise make every request fail), so other characters are
/// percent-encoded and control characters dropped.
String sanitizeHeaderValue(String v) {
  final b = StringBuffer();
  for (final r in v.runes) {
    if ((r > 31 && r < 127) || r == 9) {
      b.writeCharCode(r);
    } else if (r >= 127) {
      for (final byte in _utf8(r)) {
        b.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
  }
  return b.toString().trim();
}

List<int> _utf8(int rune) => const Utf8Encoder().convert(String.fromCharCode(rune));

class _RangeIgnored implements Exception {
  const _RangeIgnored();
}

class _Fatal implements Exception {
  _Fatal(this.message);
  final String message;
  @override
  String toString() => message;
}

class _Run {
  _Run(this.task);

  final DownloadTask task;
  HttpClient? client;
  bool stopped = false;

  /// Set when the server turned out not to support ranges: the download restarts as one plain stream.
  bool restart = false;
  final Set<int> busy = <int>{};
  int windowBytes = 0;
  Object? error;
  Timer? ticker;

  bool get halted => stopped || restart || error != null;

  Chunk? next() {
    for (final c in task.chunks) {
      if (!c.complete && !busy.contains(c.index)) {
        busy.add(c.index);
        return c;
      }
    }
    return null;
  }
}

/// Downloads a file in many slices over several connections at once, like a download accelerator, and can
/// be stopped and continued at any time without starting over.
class DownloadEngine {
  DownloadEngine({required this.saver, this.maxRetries = 5, this.stallTimeout = const Duration(seconds: 30), HttpClient Function()? clientFactory}) : _factory = clientFactory ?? HttpClient.new;

  final DownloadSaver saver;
  final int maxRetries;

  /// A connection that delivers nothing for this long is treated as dropped and retried.
  final Duration stallTimeout;
  final HttpClient Function() _factory;
  final Map<String, _Run> _runs = <String, _Run>{};

  /// Called whenever a task's state changes, so the list can be saved.
  void Function(DownloadTask task)? onState;

  bool isRunning(String id) => _runs.containsKey(id);

  HttpClient _newClient() {
    final c = _factory();
    c.connectionTimeout = const Duration(seconds: 20);
    c.idleTimeout = const Duration(seconds: 30);
    c.autoUncompress = false; // bytes on the wire are the bytes of the file
    return c;
  }

  void _apply(HttpClientRequest req, DownloadTask t) {
    t.headers.forEach((k, v) {
      final value = sanitizeHeaderValue(v);
      if (value.isNotEmpty) req.headers.set(k, value);
    });
    req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
  }

  /// Asks the server about the link with a one-byte ranged request: name, size, and whether the file can be
  /// fetched in parts.
  Future<DownloadProbe> probe(String url, {Map<String, String> headers = const <String, String>{}, String nameHint = ''}) async {
    final c = _newClient();
    try {
      final req = await c.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 30));
      headers.forEach((k, v) {
        final value = sanitizeHeaderValue(v);
        if (value.isNotEmpty) req.headers.set(k, value);
      });
      req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      final res = await req.close().timeout(const Duration(seconds: 30));
      var total = -1;
      var resumable = false;
      if (res.statusCode == 206) {
        final cr = res.headers.value(HttpHeaders.contentRangeHeader) ?? '';
        final m = RegExp(r'/(\d+)\s*$').firstMatch(cr);
        if (m != null) {
          total = int.parse(m.group(1)!);
          resumable = true;
        }
      } else if (res.statusCode == 200) {
        total = res.contentLength;
      } else {
        throw HttpException('HTTP ${res.statusCode}');
      }
      final mime = res.headers.contentType?.mimeType ?? '';
      final name = nameHint.isNotEmpty
          ? nameHint
          : fileNameFrom(disposition: res.headers.value('content-disposition') ?? '', url: url, mime: mime);
      final probe = DownloadProbe(
        url: url,
        fileName: name,
        total: total,
        resumable: resumable,
        mime: mime,
        etag: res.headers.value(HttpHeaders.etagHeader) ?? '',
        lastModified: res.headers.value(HttpHeaders.lastModifiedHeader) ?? '',
      );
      // Do not read the body: with a server that ignores ranges that would be the whole file.
      c.close(force: true);
      return probe;
    } finally {
      c.close(force: true);
    }
  }

  /// Starts (or continues) a download. Resolves when it has finished, failed or been stopped.
  Future<void> run(DownloadTask t) async {
    if (_runs.containsKey(t.id)) return;
    final r = _Run(t);
    _runs[t.id] = r;
    try {
      await _execute(r, restarts: 0);
    } finally {
      r.ticker?.cancel();
      r.client?.close(force: true);
      _runs.remove(t.id);
      t.speed = 0;
      t.changed();
      onState?.call(t);
    }
  }

  /// Stops the download but keeps every byte received. [run] returns soon after.
  void pause(DownloadTask t) {
    final r = _runs[t.id];
    if (r == null) return;
    r.stopped = true;
    r.client?.close(force: true);
  }

  void _state(DownloadTask t, DownloadState s, {String error = ''}) {
    t.state = s;
    t.error = error;
    if (s == DownloadState.completed || s == DownloadState.failed) t.finishedAt = DateTime.now();
    t.changed();
    onState?.call(t);
  }

  String partPath(DownloadTask t, Chunk c) => '${t.partsDir}${Platform.pathSeparator}part_${c.index.toString().padLeft(6, '0')}';

  Future<void> _execute(_Run r, {required int restarts}) async {
    final t = r.task;
    if (t.partsDir.isEmpty) throw StateError('The download has no folder for its parts');
    await Directory(t.partsDir).create(recursive: true);
    try {
      if (t.chunks.isEmpty) {
        _state(t, DownloadState.probing);
        t.chunks = t.resumable ? planChunks(t.total, t.connections) : <Chunk>[Chunk(0, 0, -1)];
      }
      // What is already on disk counts, whatever was recorded.
      for (final c in t.chunks) {
        final f = File(partPath(t, c));
        var have = await f.exists() ? await f.length() : 0;
        if (c.bounded && have > c.length) {
          await f.delete();
          have = 0;
        }
        c.done = have;
        if (!c.bounded && !t.resumable) {
          c.finished = false;
        }
      }
      if (r.stopped) {
        _state(t, DownloadState.paused);
        return;
      }
      _state(t, DownloadState.downloading);

      var last = t.received;
      r.ticker = Timer.periodic(const Duration(milliseconds: 400), (_) {
        final now = t.received;
        final inst = (now - last) / 0.4;
        last = now;
        t.speed = t.speed == 0 ? inst : t.speed * 0.6 + inst * 0.4;
        t.changed();
      });

      final client = _newClient();
      r.client = client;
      final workers = t.resumable ? t.connections.clamp(1, 32) : 1;
      await Future.wait(List<Future<void>>.generate(workers, (_) => _worker(r)));
      if (r.restart && !r.stopped) {
        // The server answered the whole file to a ranged request, or the file changed since it was started.
        r.ticker?.cancel();
        await _wipeParts(t);
        if (restarts >= 1) throw _Fatal('The server does not support partial downloads');
        t
          ..resumable = false
          ..chunks = <Chunk>[Chunk(0, 0, -1)];
        r.client?.close(force: true);
        r.client = null;
        r.busy.clear();
        r.restart = false;
        await _execute(r, restarts: restarts + 1);
        return;
      }
      r.ticker?.cancel();

      if (r.error != null && !r.stopped && restarts < 1 && t.resumable && t.received == 0) {
        // Nothing got through using ranges and several connections, which some servers refuse outright.
        // Try again as one plain connection before giving up.
        await _wipeParts(t);
        t
          ..resumable = false
          ..chunks = <Chunk>[Chunk(0, 0, -1)];
        r.client?.close(force: true);
        r.client = null;
        r.busy.clear();
        r.error = null;
        await _execute(r, restarts: restarts + 1);
        return;
      }
      if (r.stopped) {
        _state(t, DownloadState.paused);
        return;
      }
      if (r.error != null) {
        _state(t, DownloadState.failed, error: r.error.toString());
        return;
      }
      if (t.chunks.any((c) => !c.complete)) {
        _state(t, DownloadState.failed, error: 'The download ended before the file was complete');
        return;
      }
      if (t.total <= 0) t.total = t.received;

      _state(t, DownloadState.merging);
      final parts = t.chunks.map((c) => partPath(t, c)).toList();
      if (t.target.isEmpty) throw _Fatal('No save location was chosen');
      try {
        await saver.merge(t.target, parts);
      } catch (e) {
        _state(t, DownloadState.failed, error: 'Could not save the file: $e');
        return;
      }
      try {
        await Directory(t.partsDir).delete(recursive: true);
      } catch (_) {}
      t.speed = 0;
      _state(t, DownloadState.completed);
    } on _Fatal catch (e) {
      _state(t, DownloadState.failed, error: e.message);
    } catch (e) {
      if (r.stopped) {
        _state(t, DownloadState.paused);
      } else {
        _state(t, DownloadState.failed, error: e.toString());
      }
    }
  }

  Future<void> _wipeParts(DownloadTask t) async {
    try {
      final d = Directory(t.partsDir);
      if (await d.exists()) await d.delete(recursive: true);
      await d.create(recursive: true);
    } catch (_) {}
  }

  Future<void> _worker(_Run r) async {
    while (!r.halted) {
      final c = r.next();
      if (c == null) return;
      try {
        await _fetch(r, c);
      } on _RangeIgnored {
        r.restart = true;
        r.client?.close(force: true);
        return;
      } catch (e) {
        if (r.stopped || r.restart) return;
        r.error ??= e;
        // A slice that used up its retries ends the download; the other connections are cut loose.
        r.client?.close(force: true);
        return;
      } finally {
        r.busy.remove(c.index);
      }
    }
  }

  Future<void> _fetch(_Run r, Chunk c) async {
    for (var attempt = 0;; attempt++) {
      try {
        await _once(r, c);
        return;
      } on _RangeIgnored {
        rethrow;
      } on _Fatal {
        rethrow;
      } catch (e) {
        if (r.halted) return;
        if (attempt >= maxRetries) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 600 * (1 << (attempt > 4 ? 4 : attempt))));
        if (r.halted) return;
      }
    }
  }

  Future<void> _once(_Run r, Chunk c) async {
    final t = r.task;
    final file = File(partPath(t, c));
    var have = await file.exists() ? await file.length() : 0;
    if (!t.resumable && have > 0) {
      // A plain stream cannot continue from the middle: it starts again.
      await file.delete();
      have = 0;
    }
    if (c.bounded && have > c.length) {
      await file.delete();
      have = 0;
    }
    c.done = have;
    if (c.complete) return;
    final client = r.client;
    if (client == null) throw const HttpException('Connection closed');
    final req = await client.getUrl(Uri.parse(t.url));
    _apply(req, t);
    if (t.resumable) {
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=${c.start + c.done}-${c.end}');
      if (t.etag.isNotEmpty && !t.etag.startsWith('W/')) req.headers.set(HttpHeaders.ifRangeHeader, t.etag);
    }
    final res = await req.close().timeout(stallTimeout);
    if (t.resumable) {
      if (res.statusCode == 200) throw const _RangeIgnored();
      if (res.statusCode != 206) throw HttpException('HTTP ${res.statusCode}');
    } else if (res.statusCode != 200) {
      throw HttpException('HTTP ${res.statusCode}');
    }
    final sink = file.openWrite(mode: FileMode.append);
    var unflushed = 0;
    try {
      await for (final data in res.timeout(stallTimeout)) {
        if (r.halted) break;
        var bytes = data;
        if (c.bounded) {
          final room = c.length - c.done;
          if (room <= 0) break;
          if (bytes.length > room) bytes = bytes.sublist(0, room);
        }
        sink.add(bytes);
        c.done += bytes.length;
        unflushed += bytes.length;
        if (unflushed >= (1 << 19)) {
          unflushed = 0;
          await sink.flush(); // keeps memory flat when the network is faster than the disk
        }
      }
    } finally {
      try {
        await sink.flush();
        await sink.close();
      } catch (_) {}
    }
    if (r.halted) return;
    if (c.bounded) {
      if (c.done < c.length) throw const HttpException('Connection closed early');
    } else {
      c.finished = true;
    }
  }

  /// Removes a download's part files.
  Future<void> discard(DownloadTask t) async {
    pause(t);
    try {
      final d = Directory(t.partsDir);
      if (t.partsDir.isNotEmpty && await d.exists()) await d.delete(recursive: true);
    } catch (_) {}
  }
}
