import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'proxy_config.dart';

const List<int> _crlf2 = <int>[13, 10, 13, 10];

/// Reads a socket through ONE subscription (a Dart socket can only be listened to once): bytes are buffered
/// for the protocol steps that need them, and afterwards everything is forwarded to a callback.
class _Reader {
  _Reader(Socket socket) {
    _sub = socket.listen(_onData, onError: _onError, onDone: _onDone, cancelOnError: true);
  }

  late final StreamSubscription<Uint8List> _sub;
  final List<int> _buf = <int>[];
  void Function(List<int>)? _forward;
  void Function()? _onClose;
  bool closed = false;
  Completer<void>? _wait;

  void _wake() {
    final w = _wait;
    _wait = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  void _onData(Uint8List d) {
    final f = _forward;
    if (f != null) {
      f(d);
    } else {
      _buf.addAll(d);
      _wake();
    }
  }

  void _onError(Object e) => _onDone();

  void _onDone() {
    closed = true;
    _wake();
    _onClose?.call();
  }

  Future<void> _more() {
    if (closed) throw const SocketException('Connection closed');
    final c = _wait ??= Completer<void>();
    return c.future;
  }

  Future<List<int>> readExact(int n) async {
    while (_buf.length < n) {
      await _more();
    }
    final out = _buf.sublist(0, n);
    _buf.removeRange(0, n);
    return out;
  }

  /// Everything up to and including [marker]; bytes after it stay buffered.
  Future<List<int>> readUntil(List<int> marker, {int max = 65536}) async {
    var from = 0;
    while (true) {
      final at = _indexOf(_buf, marker, from);
      if (at >= 0) {
        final end = at + marker.length;
        final out = _buf.sublist(0, end);
        _buf.removeRange(0, end);
        return out;
      }
      if (_buf.length > max) throw const FormatException('Header too large');
      from = _buf.length - marker.length + 1 < 0 ? 0 : _buf.length - marker.length + 1;
      await _more();
    }
  }

  static int _indexOf(List<int> data, List<int> pat, int from) {
    for (var i = from; i + pat.length <= data.length; i++) {
      var ok = true;
      for (var j = 0; j < pat.length; j++) {
        if (data[i + j] != pat[j]) {
          ok = false;
          break;
        }
      }
      if (ok) return i;
    }
    return -1;
  }

  /// From now on hand every byte (first the ones already buffered) to [onData].
  void forwardTo(void Function(List<int>) onData, void Function() onClose) {
    _onClose = onClose;
    if (_buf.isNotEmpty) {
      onData(List<int>.of(_buf));
      _buf.clear();
    }
    _forward = onData;
    if (closed) onClose();
  }

  void cancel() => _sub.cancel();
}

class _Upstream {
  _Upstream(this.socket, this.reader);
  final Socket socket;
  final _Reader reader;
}

String socksErrorText(int code) {
  switch (code) {
    case 1:
      return 'general SOCKS server failure';
    case 2:
      return 'connection not allowed by the proxy';
    case 3:
      return 'network unreachable';
    case 4:
      return 'host unreachable';
    case 5:
      return 'connection refused';
    case 6:
      return 'TTL expired';
    case 7:
      return 'command not supported';
    case 8:
      return 'address type not supported';
    default:
      return 'SOCKS error $code';
  }
}

/// A tiny proxy that only listens on this phone (127.0.0.1). The app and the browser speak ordinary HTTP
/// proxy to it (so TLS and everything else work as usual), and it carries each connection on through the
/// real upstream: a SOCKS5 server (Tor, SSH -D, ...) or an HTTP proxy, with login when needed. Names are
/// sent to a SOCKS5 upstream as names, so the proxy — Tor — resolves them and nothing leaks through local DNS.
class LocalProxyBridge {
  ServerSocket? _server;
  ProxyConfig? _upstream;
  final Set<Socket> _open = <Socket>{};

  int get port => _server?.port ?? 0;
  bool get running => _server != null;

  Future<int> start(ProxyConfig upstream) async {
    await stop();
    _upstream = upstream;
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((client) => _handle(client, upstream), onError: (Object _) {});
    return server.port;
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    _upstream = null;
    await s?.close();
    for (final sock in _open.toList()) {
      sock.destroy();
    }
    _open.clear();
  }

  Future<void> _handle(Socket client, ProxyConfig up) async {
    _open.add(client);
    client.done.catchError((Object _) {}).whenComplete(() => _open.remove(client));
    final cr = _Reader(client);
    _Upstream? upstream;
    try {
      final head = await cr.readUntil(_crlf2).timeout(const Duration(seconds: 30));
      final lines = latin1.decode(head).split('\r\n');
      final first = lines.first.split(' ');
      if (first.length < 3) throw const FormatException('Bad proxy request');
      final method = first[0];
      final target = first[1];
      if (method.toUpperCase() == 'CONNECT') {
        final (host, port) = _hostPort(target, 443);
        upstream = await _openTunnel(up, host, port);
        client.add(latin1.encode('HTTP/1.1 200 Connection Established\r\n\r\n'));
      } else {
        final uri = Uri.tryParse(target);
        if (uri == null || !uri.hasAuthority || uri.host.isEmpty) throw const FormatException('Not a proxy request');
        final host = uri.host;
        final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
        final headerLines = lines.skip(1).where((l) => l.isNotEmpty).where((l) {
          final k = l.split(':').first.toLowerCase();
          return k != 'proxy-connection' && k != 'proxy-authorization' && k != 'connection';
        }).toList();
        final String requestLine;
        final extra = StringBuffer();
        if (up.kind == ProxyKind.http) {
          upstream = await _connectPlain(up);
          requestLine = '$method $target ${first[2]}';
          if (up.user.isNotEmpty) extra.write('Proxy-Authorization: Basic ${base64.encode(utf8.encode('${up.user}:${up.pass}'))}\r\n');
        } else {
          upstream = await _openTunnel(up, host, port);
          final path = '${uri.path.isEmpty ? '/' : uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
          requestLine = '$method $path ${first[2]}';
        }
        final out = StringBuffer('$requestLine\r\n')
          ..writeAll(headerLines.map((l) => '$l\r\n'))
          ..write(extra)
          ..write('Connection: close\r\n\r\n');
        upstream.socket.add(latin1.encode(out.toString()));
      }
      _pipe(client, cr, upstream);
    } catch (e) {
      try {
        final msg = 'Proxy error: $e';
        client.add(latin1.encode('HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/plain\r\nContent-Length: ${utf8.encode(msg).length}\r\nConnection: close\r\n\r\n$msg'));
        await client.flush();
      } catch (_) {}
      upstream?.socket.destroy();
      cr.cancel();
      client.destroy();
    }
  }

  (String, int) _hostPort(String target, int defaultPort) {
    var t = target;
    if (t.startsWith('[')) {
      final end = t.indexOf(']');
      final host = t.substring(1, end);
      final rest = t.substring(end + 1);
      return (host, rest.startsWith(':') ? int.parse(rest.substring(1)) : defaultPort);
    }
    final i = t.lastIndexOf(':');
    if (i < 0) return (t, defaultPort);
    return (t.substring(0, i), int.parse(t.substring(i + 1)));
  }

  Future<_Upstream> _connectPlain(ProxyConfig up) async {
    final s = await Socket.connect(up.host, up.port, timeout: const Duration(seconds: 20));
    s.setOption(SocketOption.tcpNoDelay, true);
    return _Upstream(s, _Reader(s));
  }

  Future<_Upstream> _openTunnel(ProxyConfig up, String host, int port) async {
    final u = await _connectPlain(up);
    try {
      await (up.kind == ProxyKind.socks5 ? _socks5(u, up, host, port) : _httpConnect(u, up, host, port)).timeout(const Duration(seconds: 30));
      return u;
    } catch (_) {
      u.reader.cancel();
      u.socket.destroy();
      rethrow;
    }
  }

  Future<void> _socks5(_Upstream u, ProxyConfig up, String host, int port) async {
    final s = u.socket;
    final r = u.reader;
    final useAuth = up.user.isNotEmpty;
    s.add(useAuth ? <int>[5, 2, 0, 2] : <int>[5, 1, 0]);
    final choice = await r.readExact(2);
    if (choice[0] != 5) throw const FormatException('Not a SOCKS5 server');
    if (choice[1] == 2) {
      final user = utf8.encode(up.user);
      final pass = utf8.encode(up.pass);
      if (user.length > 255 || pass.length > 255) throw const FormatException('SOCKS login too long');
      s.add(<int>[1, user.length, ...user, pass.length, ...pass]);
      final ok = await r.readExact(2);
      if (ok[1] != 0) throw const FormatException('SOCKS login was refused');
    } else if (choice[1] != 0) {
      throw const FormatException('The SOCKS server needs a login method this app does not support');
    }
    final ip = InternetAddress.tryParse(host);
    final List<int> addr;
    if (ip != null && ip.type == InternetAddressType.IPv4) {
      addr = <int>[1, ...ip.rawAddress];
    } else if (ip != null && ip.type == InternetAddressType.IPv6) {
      addr = <int>[4, ...ip.rawAddress];
    } else {
      final name = utf8.encode(host);
      if (name.length > 255) throw const FormatException('Host name too long');
      addr = <int>[3, name.length, ...name];
    }
    s.add(<int>[5, 1, 0, ...addr, (port >> 8) & 0xFF, port & 0xFF]);
    final reply = await r.readExact(4);
    if (reply[1] != 0) throw FormatException('SOCKS proxy: ${socksErrorText(reply[1])}');
    switch (reply[3]) {
      case 1:
        await r.readExact(6);
        break;
      case 4:
        await r.readExact(18);
        break;
      case 3:
        final n = (await r.readExact(1))[0];
        await r.readExact(n + 2);
        break;
      default:
        throw const FormatException('Bad SOCKS reply');
    }
  }

  Future<void> _httpConnect(_Upstream u, ProxyConfig up, String host, int port) async {
    final auth = up.user.isEmpty ? '' : 'Proxy-Authorization: Basic ${base64.encode(utf8.encode('${up.user}:${up.pass}'))}\r\n';
    u.socket.add(latin1.encode('CONNECT $host:$port HTTP/1.1\r\nHost: $host:$port\r\n$auth\r\n'));
    final head = latin1.decode(await u.reader.readUntil(_crlf2));
    final status = int.tryParse(RegExp(r'^HTTP/\d(?:\.\d)? (\d{3})').firstMatch(head)?.group(1) ?? '');
    if (status == 407) throw const FormatException('The proxy needs a username and password (or they are wrong)');
    if (status != 200) throw FormatException('The proxy answered ${status ?? 'something unexpected'} to CONNECT');
  }

  void _pipe(Socket client, _Reader cr, _Upstream up) {
    var finished = false;
    void closeBoth() {
      if (finished) return;
      finished = true;
      Future<void>.delayed(const Duration(milliseconds: 50), () {
        try {
          client.destroy();
        } catch (_) {}
        try {
          up.socket.destroy();
        } catch (_) {}
      });
    }

    // When one side finishes sending, let what is already queued for the other side flush, then close.
    cr.forwardTo((d) {
      try {
        up.socket.add(d);
      } catch (_) {
        closeBoth();
      }
    }, () {
      up.socket.flush().whenComplete(closeBoth);
    });
    up.reader.forwardTo((d) {
      try {
        client.add(d);
      } catch (_) {
        closeBoth();
      }
    }, () {
      client.flush().whenComplete(closeBoth);
    });
  }
}
