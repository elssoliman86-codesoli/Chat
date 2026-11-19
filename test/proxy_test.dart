import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_chat/core/models.dart';
import 'package:omni_chat/net/proxy_bridge.dart';
import 'package:omni_chat/net/proxy_config.dart';
import 'package:omni_chat/net/proxy_service.dart';

/// Buffers a socket so a test server can read exact byte counts.
class _Buf {
  _Buf(Socket s) {
    s.listen((d) {
      _data.addAll(d);
      _wake();
    }, onDone: () {
      _done = true;
      _wake();
    }, onError: (Object _) {
      _done = true;
      _wake();
    });
  }

  final List<int> _data = [];
  bool _done = false;
  Completer<void>? _wait;

  void _wake() {
    final w = _wait;
    _wait = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<List<int>> take(int n) async {
    while (_data.length < n) {
      if (_done) throw StateError('closed');
      _wait = Completer<void>();
      await _wait!.future;
    }
    final out = _data.sublist(0, n);
    _data.removeRange(0, n);
    return out;
  }

  Future<String> takeUntil(String end) async {
    while (true) {
      final text = latin1.decode(_data);
      final i = text.indexOf(end);
      if (i >= 0) {
        final out = text.substring(0, i + end.length);
        _data.removeRange(0, out.length);
        return out;
      }
      if (_done) throw StateError('closed');
      _wait = Completer<void>();
      await _wait!.future;
    }
  }

  List<int> rest() {
    final r = List<int>.from(_data);
    _data.clear();
    return r;
  }
}

/// A tiny SOCKS5 server: records what it was asked to reach and forwards to [targetPort] on this machine.
class _FakeSocks {
  _FakeSocks({this.user, this.pass});

  final String? user;
  final String? pass;
  late ServerSocket server;
  final List<String> requestedHosts = [];
  String? gotUser;
  String? gotPass;
  int targetPort = 0;

  Future<void> start() async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_serve);
  }

  int get port => server.port;

  Future<void> _serve(Socket c) async {
    try {
      final b = _Buf(c);
      final head = await b.take(2);
      final methods = await b.take(head[1]);
      if (user != null) {
        if (!methods.contains(2)) {
          c.add([5, 0xFF]);
          await c.close();
          return;
        }
        c.add([5, 2]);
        final v = await b.take(2);
        final u = utf8.decode(await b.take(v[1]));
        final pl = (await b.take(1))[0];
        final p = utf8.decode(await b.take(pl));
        gotUser = u;
        gotPass = p;
        if (u != user || p != pass) {
          c.add([1, 1]);
          await c.close();
          return;
        }
        c.add([1, 0]);
      } else {
        c.add([5, 0]);
      }
      final req = await b.take(4);
      String host;
      if (req[3] == 3) {
        final n = (await b.take(1))[0];
        host = utf8.decode(await b.take(n));
      } else if (req[3] == 1) {
        host = (await b.take(4)).join('.');
      } else {
        host = '?';
      }
      await b.take(2);
      requestedHosts.add(host);
      final out = await Socket.connect(InternetAddress.loopbackIPv4, targetPort);
      c.add([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
      final pending = b.rest();
      if (pending.isNotEmpty) out.add(pending);
      c.listen(out.add, onDone: out.close, onError: (Object _) => out.destroy());
      out.listen(c.add, onDone: c.close, onError: (Object _) => c.destroy());
    } catch (_) {
      c.destroy();
    }
  }

  Future<void> stop() => server.close();
}

void main() {
  group('address classification', () {
    test('loopback hosts', () {
      for (final h in ['localhost', '127.0.0.1', '::1', 'foo.localhost']) {
        expect(isLoopbackHost(h), isTrue, reason: h);
      }
      expect(isLoopbackHost('example.com'), isFalse);
      expect(isLoopbackHost('8.8.8.8'), isFalse);
    });

    test('local network hosts', () {
      for (final h in ['10.1.2.3', '172.16.0.1', '172.31.255.1', '192.168.1.20', '169.254.1.1', 'nas', 'printer.local', 'x.lan', 'fd00::1', 'fe80::1']) {
        expect(isLanHost(h), isTrue, reason: h);
      }
      for (final h in ['8.8.8.8', '172.32.0.1', '172.15.0.1', '11.0.0.1', 'example.com', '2606:4700::1111']) {
        expect(isLanHost(h), isFalse, reason: h);
      }
    });

    test('bypass respects the switch', () {
      const on = ProxyConfig(kind: ProxyKind.http, host: 'p', port: 1, bypassLan: true);
      const off = ProxyConfig(kind: ProxyKind.http, host: 'p', port: 1, bypassLan: false);
      expect(on.bypasses('192.168.1.5'), isTrue);
      expect(off.bypasses('192.168.1.5'), isFalse);
      expect(on.bypasses('127.0.0.1'), isTrue);
      expect(off.bypasses('127.0.0.1'), isTrue);
      expect(on.bypasses('api.openai.com'), isFalse);
    });
  });

  group('settings', () {
    test('off by default', () {
      final s = AppSettings();
      expect(s.proxyMode, 'off');
      expect(ProxyConfig.fromSettings(s), isNull);
    });

    test('Tor uses SOCKS5 on 9050 by default and is marked as Tor', () {
      final s = AppSettings()..proxyMode = 'tor';
      final c = ProxyConfig.fromSettings(s)!;
      expect(c.isTor, isTrue);
      expect(c.kind, ProxyKind.socks5);
      expect(c.host, '127.0.0.1');
      expect(c.port, 9050);
    });

    test('a custom proxy needs host and port', () {
      final s = AppSettings()
        ..proxyMode = 'custom'
        ..proxyKind = 'socks5';
      expect(ProxyConfig.fromSettings(s), isNull);
      s
        ..proxyHost = ' proxy.test '
        ..proxyPort = 1080
        ..proxyUser = 'u'
        ..proxyPass = 'p';
      final c = ProxyConfig.fromSettings(s)!;
      expect(c.kind, ProxyKind.socks5);
      expect(c.host, 'proxy.test');
      expect(c.port, 1080);
      expect(c.user, 'u');
      expect(c.isTor, isFalse);
    });

    test('survives a JSON round trip', () {
      final s = AppSettings()
        ..proxyMode = 'custom'
        ..proxyKind = 'socks5'
        ..proxyHost = 'h'
        ..proxyPort = 9
        ..proxyUser = 'a'
        ..proxyPass = 'b'
        ..torHost = '10.0.0.2'
        ..torPort = 9150
        ..proxyBypassLan = false
        ..proxyBrowser = false;
      final r = AppSettings.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
      expect(r.proxyMode, 'custom');
      expect(r.proxyKind, 'socks5');
      expect(r.proxyHost, 'h');
      expect(r.proxyPort, 9);
      expect(r.proxyUser, 'a');
      expect(r.proxyPass, 'b');
      expect(r.torHost, '10.0.0.2');
      expect(r.torPort, 9150);
      expect(r.proxyBypassLan, isFalse);
      expect(r.proxyBrowser, isFalse);
    });
  });

  group('routing decisions', () {
    test('off means direct', () async {
      await ProxyService.instance.apply(AppSettings());
      expect(ProxyService.instance.findProxy(Uri.parse('https://example.com/')), 'DIRECT');
    });

    test('Tor is never direct for public hosts, but loopback and LAN stay direct', () async {
      final s = AppSettings()
        ..proxyMode = 'tor'
        ..torPort = 1; // nothing listens there; the bridge itself still starts
      await ProxyService.instance.apply(s);
      final svc = ProxyService.instance;
      final routed = svc.findProxy(Uri.parse('https://example.com/'));
      expect(routed.startsWith('PROXY 127.0.0.1:'), isTrue);
      expect(routed, isNot('DIRECT'));
      expect(svc.findProxy(Uri.parse('http://127.0.0.1:11434/')), 'DIRECT');
      expect(svc.findProxy(Uri.parse('http://192.168.1.9:1234/')), 'DIRECT');
      s.proxyBypassLan = false;
      await svc.apply(s);
      expect(svc.findProxy(Uri.parse('http://192.168.1.9:1234/')), startsWith('PROXY'));
      await svc.apply(AppSettings());
    });
  });

  group('bridge', () {
    late HttpServer web;
    late List<String> seenHosts;

    setUp(() async {
      seenHosts = [];
      web = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      web.listen((req) {
        seenHosts.add(req.headers.host ?? '');
        req.response
          ..write('hello from target ${req.uri.path}')
          ..close();
      });
    });

    tearDown(() => web.close(force: true));

    Future<String> fetch(int bridgePort, String url) async {
      final client = HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:$bridgePort';
      try {
        final req = await client.getUrl(Uri.parse(url));
        final res = await req.close();
        return await res.transform(utf8.decoder).join();
      } finally {
        client.close(force: true);
      }
    }

    test('plain HTTP through SOCKS5 sends the name, not an IP (so Tor can resolve it)', () async {
      final socks = _FakeSocks();
      await socks.start();
      socks.targetPort = web.port;
      final bridge = LocalProxyBridge();
      final port = await bridge.start(ProxyConfig(kind: ProxyKind.socks5, host: '127.0.0.1', port: socks.port));
      final body = await fetch(port, 'http://onion-like.example:${web.port}/page');
      expect(body, 'hello from target /page');
      expect(socks.requestedHosts, ['onion-like.example']);
      await bridge.stop();
      await socks.stop();
    });

    test('SOCKS5 username and password are sent', () async {
      final socks = _FakeSocks(user: 'alice', pass: 's3cret');
      await socks.start();
      socks.targetPort = web.port;
      final bridge = LocalProxyBridge();
      final port = await bridge.start(ProxyConfig(kind: ProxyKind.socks5, host: '127.0.0.1', port: socks.port, user: 'alice', pass: 's3cret'));
      expect(await fetch(port, 'http://a.example:${web.port}/x'), 'hello from target /x');
      expect(socks.gotUser, 'alice');
      expect(socks.gotPass, 's3cret');
      await bridge.stop();
      await socks.stop();
    });

    test('a CONNECT tunnel carries raw bytes both ways', () async {
      final socks = _FakeSocks();
      await socks.start();
      final echo = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      echo.listen((c) => c.listen(c.add, onDone: c.close));
      socks.targetPort = echo.port;
      final bridge = LocalProxyBridge();
      final port = await bridge.start(ProxyConfig(kind: ProxyKind.socks5, host: '127.0.0.1', port: socks.port));

      final c = await Socket.connect(InternetAddress.loopbackIPv4, port);
      final buf = _Buf(c);
      c.add(latin1.encode('CONNECT secure.example:443 HTTP/1.1\r\nHost: secure.example:443\r\n\r\n'));
      final head = await buf.takeUntil('\r\n\r\n').timeout(const Duration(seconds: 10));
      expect(head, startsWith('HTTP/1.1 200'));
      c.add(utf8.encode('ping'));
      expect(utf8.decode(await buf.take(4).timeout(const Duration(seconds: 10))), 'ping');
      expect(socks.requestedHosts, ['secure.example']);
      await c.close();
      await bridge.stop();
      await socks.stop();
      await echo.close();
    });

    test('an HTTP upstream receives CONNECT with Proxy-Authorization', () async {
      String? auth;
      String? first;
      final echo = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      echo.listen((c) => c.listen(c.add, onDone: c.close));
      final upstream = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((c) async {
        final b = _Buf(c);
        final head = await b.takeUntil('\r\n\r\n');
        first = head.split('\r\n').first;
        for (final l in head.split('\r\n')) {
          if (l.toLowerCase().startsWith('proxy-authorization:')) auth = l.substring(l.indexOf(':') + 1).trim();
        }
        final out = await Socket.connect(InternetAddress.loopbackIPv4, echo.port);
        c.add(latin1.encode('HTTP/1.1 200 Connection established\r\n\r\n'));
        c.listen(out.add, onDone: out.close);
        out.listen(c.add, onDone: c.close);
      });
      final bridge = LocalProxyBridge();
      final port = await bridge.start(ProxyConfig(kind: ProxyKind.http, host: '127.0.0.1', port: upstream.port, user: 'bob', pass: 'pw'));

      final c = await Socket.connect(InternetAddress.loopbackIPv4, port);
      final buf = _Buf(c);
      c.add(latin1.encode('CONNECT h.example:443 HTTP/1.1\r\n\r\n'));
      expect(await buf.takeUntil('\r\n\r\n').timeout(const Duration(seconds: 10)), startsWith('HTTP/1.1 200'));
      c.add(utf8.encode('abc'));
      expect(utf8.decode(await buf.take(3).timeout(const Duration(seconds: 10))), 'abc');
      expect(first, 'CONNECT h.example:443 HTTP/1.1');
      expect(auth, 'Basic ${base64.encode(utf8.encode('bob:pw'))}');
      await c.close();
      await bridge.stop();
      await upstream.close();
      await echo.close();
    });

    test('a dead upstream gives an error instead of a direct connection', () async {
      final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = dead.port;
      await dead.close();
      final bridge = LocalProxyBridge();
      final port = await bridge.start(ProxyConfig(kind: ProxyKind.socks5, host: '127.0.0.1', port: deadPort));
      final body = await fetch(port, 'http://leak.example:${web.port}/').timeout(const Duration(seconds: 20), onTimeout: () => 'timeout');
      expect(body, isNot(contains('hello from target')));
      expect(seenHosts, isEmpty);
      await bridge.stop();
    });
  });
}
