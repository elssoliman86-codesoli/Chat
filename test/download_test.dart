import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_chat/downloads/download_engine.dart';
import 'package:omni_chat/downloads/download_manager.dart';
import 'package:omni_chat/downloads/download_task.dart';

/// Saves to a plain file path, like the manager does when no Android picker is involved.
class _FileSaver implements DownloadSaver {
  @override
  Future<String?> pickTarget(String name, String mime) async => null;

  @override
  Future<void> merge(String target, List<String> parts) => mergeFiles(target, parts);

  @override
  Future<void> open(String target, String mime) async {}
}

/// A small file server for tests: byte ranges, optional throttling, and a few ways to misbehave.
class _Server {
  _Server(this.data, {this.ranges = true, this.delayPerPiece = Duration.zero, this.ignoreRangeAfter, this.dropFirst = 0});

  final Uint8List data;
  final bool ranges;
  final Duration delayPerPiece;
  /// After this many requests (the probe is the first) ranged requests are answered with the whole file.
  final int? ignoreRangeAfter;

  /// How many ranged requests are cut off half-way before behaving.
  int dropFirst;

  late HttpServer server;
  int served = 0;
  int open = 0;
  int maxOpen = 0;
  int requests = 0;

  /// Bytes asked for by ranged requests (what a client really wants to receive).
  int requested = 0;

  String get url => 'http://127.0.0.1:${server.port}/files/big%20file.bin';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_handle);
  }

  Future<void> stop() => server.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    requests++;
    open++;
    if (open > maxOpen) maxOpen = open;
    try {
      final range = req.headers.value('range');
      var from = 0;
      var to = data.length - 1;
      var partial = false;
      if (ranges && range != null && !(ignoreRangeAfter != null && requests > ignoreRangeAfter!)) {
        final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
        if (m != null) {
          from = int.parse(m.group(1)!);
          if (m.group(2)!.isNotEmpty) to = min(int.parse(m.group(2)!), data.length - 1);
          partial = true;
          requested += to - from + 1;
        }
      }
      final res = req.response;
      if (partial && dropFirst > 0 && to - from > 200000) {
        // Answer with the start of the body, then hang up: the way a dropped connection looks to the client.
        dropFirst--;
        final socket = await res.detachSocket(writeHeaders: false);
        final head = 'HTTP/1.1 206 Partial Content\r\n'
            'content-type: application/octet-stream\r\n'
            'etag: "v1"\r\n'
            'content-range: bytes $from-$to/${data.length}\r\n'
            'content-length: ${to - from + 1}\r\n\r\n';
        socket.add(head.codeUnits);
        socket.add(data.sublist(from, from + 100000));
        served += 100000;
        await socket.flush();
        socket.destroy();
        return;
      }
      res.headers.set('etag', '"v1"');
      res.headers.contentType = ContentType.binary;
      if (ranges) res.headers.set('accept-ranges', 'bytes');
      if (partial) {
        res.statusCode = 206;
        res.headers.set('content-range', 'bytes $from-$to/${data.length}');
      }
      res.contentLength = to - from + 1;
      var pos = from;
      while (pos <= to) {
        final end = min(pos + 65536, to + 1);
        res.add(data.sublist(pos, end));
        served += end - pos;
        pos = end;
        if (delayPerPiece > Duration.zero) {
          await res.flush();
          await Future<void>.delayed(delayPerPiece);
        }
      }
      await res.close();
    } catch (_) {
    } finally {
      open--;
    }
  }
}

Uint8List _bytes(int n) {
  final r = Random(7);
  final b = Uint8List(n);
  for (var i = 0; i < n; i++) {
    b[i] = r.nextInt(256);
  }
  return b;
}

void main() {
  late Directory tmp;
  late DownloadManager manager;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('omni_dl_');
    manager = DownloadManager.forTest(saver: _FileSaver(), root: Directory('${tmp.path}/state'));
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<DownloadTask> begin(_Server s, {int connections = 8, String? out}) async {
    final p = await manager.probe(s.url);
    return manager.add(p, target: out ?? '${tmp.path}/out.bin', connections: connections);
  }

  group('planning', () {
    test('chunks cover the file exactly, with no gaps or overlaps', () {
      for (final total in <int>[1, 1000, (1 << 20) + 1, 50 << 20, 1 << 30]) {
        final chunks = planChunks(total, 8);
        expect(chunks.first.start, 0);
        expect(chunks.last.end, total - 1);
        for (var i = 1; i < chunks.length; i++) {
          expect(chunks[i].start, chunks[i - 1].end + 1);
        }
        expect(chunks.fold<int>(0, (a, c) => a + c.length), total);
      }
    });

    test('a 1 GB file is cut into many parts, an unknown size into one stream', () {
      expect(planChunks(1 << 30, 8).length, greaterThan(32));
      final one = planChunks(-1, 8);
      expect(one.length, 1);
      expect(one.single.bounded, isFalse);
    });

    test('file names come from the header first, then the address', () {
      expect(fileNameFrom(disposition: 'attachment; filename="a b.zip"', url: 'https://x/y'), 'a b.zip');
      expect(fileNameFrom(disposition: "attachment; filename*=UTF-8''%D9%85%D9%84%D9%81.pdf", url: 'https://x/y'), 'ملف.pdf');
      expect(fileNameFrom(url: 'https://x.com/dir/video%20one.mp4?token=1'), 'video one.mp4');
      expect(fileNameFrom(url: 'https://x.com/', mime: 'application/pdf'), 'download.pdf');
      expect(fileNameFrom(disposition: 'attachment; filename="../../etc/passwd"', url: 'https://x/'), isNot(contains('/')));
    });

    test('sizes are readable', () {
      expect(formatBytes(512), '512 B');
      expect(formatBytes(1536), '1.50 KB');
      expect(formatBytes(5 * 1024 * 1024 * 1024), '5.00 GB');
    });
  });

  group('parallel download', () {
    test('fetches the parts over several connections and joins them in order', () async {
      final data = _bytes(24 << 20);
      final s = _Server(data, delayPerPiece: const Duration(milliseconds: 2));
      await s.start();
      addTearDown(s.stop);
      final t = await begin(s);
      expect(t.resumable, isTrue);
      expect(t.total, data.length);
      await manager.settle(t);
      expect(t.state, DownloadState.completed, reason: t.error);
      expect(await File(t.target).readAsBytes(), data);
      expect(s.maxOpen, greaterThan(2), reason: 'parts must be fetched at the same time');
      expect(Directory(t.partsDir).existsSync(), isFalse, reason: 'part files are removed after joining');
    });

    test('one connection also works and the file is identical', () async {
      final data = _bytes(3 << 20);
      final s = _Server(data);
      await s.start();
      addTearDown(s.stop);
      final t = await begin(s, connections: 1);
      await manager.settle(t);
      expect(t.state, DownloadState.completed, reason: t.error);
      expect(await File(t.target).readAsBytes(), data);
      expect(s.maxOpen, lessThanOrEqualTo(2)); // the probe may overlap the first part
    });

    test('a server without byte ranges is downloaded as one plain stream', () async {
      final data = _bytes(2 << 20);
      final s = _Server(data, ranges: false);
      await s.start();
      addTearDown(s.stop);
      final t = await begin(s);
      expect(t.resumable, isFalse);
      await manager.settle(t);
      expect(t.state, DownloadState.completed, reason: t.error);
      expect(await File(t.target).readAsBytes(), data);
    });

    test('a server that promises ranges but then ignores them still delivers the file', () async {
      final data = _bytes(6 << 20);
      final s = _Server(data, ignoreRangeAfter: 1);
      await s.start();
      addTearDown(s.stop);
      final t = await begin(s);
      expect(t.resumable, isTrue, reason: 'the probe was answered with a range');
      await manager.settle(t);
      expect(t.resumable, isFalse, reason: 'it fell back to one plain stream');
      expect(t.state, DownloadState.completed, reason: t.error);
      expect(await File(t.target).readAsBytes(), data);
    });

    test('a connection cut half-way is retried and the file is still exact', () async {
      final data = _bytes(10 << 20);
      final s = _Server(data, dropFirst: 3);
      await s.start();
      addTearDown(s.stop);
      final t = await begin(s);
      await manager.settle(t);
      expect(t.state, DownloadState.completed, reason: t.error);
      expect(await File(t.target).readAsBytes(), data);
    });

    test('a missing file fails with a clear error instead of hanging', () async {
      final s = _Server(_bytes(10));
      await s.start();
      final dead = s.url;
      await s.stop(); // nothing listens on that port any more
      await expectLater(manager.probe(dead), throwsA(anything));
    });
  });

  group('stop and resume', () {
    test('pausing keeps the bytes and resuming continues without starting over', () async {
      final data = _bytes(30 << 20);
      final s = _Server(data, delayPerPiece: const Duration(milliseconds: 15));
      await s.start();
      addTearDown(s.stop);
      final t = await begin(s);

      // Let it get part of the way.
      final end = DateTime.now().add(const Duration(seconds: 20));
      while (t.received < data.length ~/ 4 && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      manager.pause(t);
      await manager.settle(t);
      expect(t.state, DownloadState.paused);
      final kept = t.received;
      expect(kept, greaterThan(0));
      expect(kept, lessThan(data.length));
      expect(Directory(t.partsDir).existsSync(), isTrue);
      final requestedBefore = s.requested;

      manager.resume(t);
      await manager.settle(t);
      expect(t.state, DownloadState.completed, reason: t.error);
      expect(await File(t.target).readAsBytes(), data);
      // Only what was still missing was asked for again; the bytes already on disk were not.
      expect(s.requested - requestedBefore, lessThanOrEqualTo(data.length - kept + (1 << 20)));
    });

    test('the list is saved and a half-done download comes back paused', () async {
      final data = _bytes(20 << 20);
      final s = _Server(data, delayPerPiece: const Duration(milliseconds: 15));
      await s.start();
      addTearDown(s.stop);
      final t = await begin(s);
      while (t.received < (2 << 20)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      manager.pause(t);
      await manager.settle(t);
      await manager.flush();

      final again = DownloadManager.forTest(saver: _FileSaver(), root: Directory('${tmp.path}/state'));
      await again.load();
      expect(again.tasks.length, 1);
      final back = again.tasks.single;
      expect(back.state, DownloadState.paused);
      expect(back.url, t.url);
      expect(back.chunks.length, t.chunks.length);
      again.resume(back);
      await again.settle(back);
      expect(back.state, DownloadState.completed, reason: back.error);
      expect(await File(back.target).readAsBytes(), data);
    });

    test('removing a download deletes its parts', () async {
      final data = _bytes(20 << 20);
      final s = _Server(data, delayPerPiece: const Duration(milliseconds: 15));
      await s.start();
      addTearDown(s.stop);
      final t = await begin(s);
      while (t.received < (1 << 20)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await manager.remove(t);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(Directory(t.partsDir).existsSync(), isFalse);
      expect(manager.tasks, isEmpty);
    });
  });

  group('scheduling', () {
    test('only a few downloads run at once, the rest wait their turn', () async {
      final data = _bytes(8 << 20);
      final s = _Server(data, delayPerPiece: const Duration(milliseconds: 3));
      await s.start();
      addTearDown(s.stop);
      manager.maxActive = 2;
      final ts = <DownloadTask>[];
      for (var i = 0; i < 4; i++) {
        ts.add(await begin(s, connections: 2, out: '${tmp.path}/o$i.bin'));
      }
      expect(manager.activeCount, lessThanOrEqualTo(2));
      for (final t in ts) {
        await manager.settle(t, timeout: const Duration(seconds: 60));
      }
      for (final t in ts) {
        expect(t.state, DownloadState.completed, reason: t.error);
      }
    });
  });
}
