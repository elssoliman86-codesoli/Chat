import 'dart:io';

import '../core/models.dart';

enum ProxyKind { http, socks5 }

/// The proxy the app's traffic goes through: a custom HTTP/SOCKS5 proxy, or Tor (a SOCKS5 proxy on this
/// phone — Orbot or Termux's `tor` — which also resolves names itself, so .onion addresses work).
class ProxyConfig {
  const ProxyConfig({
    required this.kind,
    required this.host,
    required this.port,
    this.user = '',
    this.pass = '',
    this.bypassLan = true,
    this.isTor = false,
  });

  final ProxyKind kind;
  final String host;
  final int port;
  final String user;
  final String pass;

  /// Keep addresses on the local network (Ollama, LM Studio, a PC's FTP) off the proxy.
  final bool bypassLan;
  final bool isTor;

  /// The active proxy from the settings, or null when off or incomplete.
  static ProxyConfig? fromSettings(AppSettings s) {
    switch (s.proxyMode) {
      case 'tor':
        final host = s.torHost.trim().isEmpty ? '127.0.0.1' : s.torHost.trim();
        final port = s.torPort > 0 && s.torPort < 65536 ? s.torPort : 9050;
        return ProxyConfig(kind: ProxyKind.socks5, host: host, port: port, bypassLan: s.proxyBypassLan, isTor: true);
      case 'custom':
        final host = s.proxyHost.trim();
        if (host.isEmpty || s.proxyPort <= 0 || s.proxyPort >= 65536) return null;
        return ProxyConfig(
          kind: s.proxyKind == 'socks5' ? ProxyKind.socks5 : ProxyKind.http,
          host: host,
          port: s.proxyPort,
          user: s.proxyUser,
          pass: s.proxyPass,
          bypassLan: s.proxyBypassLan,
        );
      default:
        return null;
    }
  }

  String get label {
    if (isTor) return 'Tor via $host:$port';
    return '${kind == ProxyKind.socks5 ? 'SOCKS5' : 'HTTP'} proxy $host:$port';
  }

  /// Whether a request to [target] should skip the proxy. This device itself is always direct (a proxy
  /// cannot reach it); the local network only when [bypassLan] is on.
  bool bypasses(String target) {
    final h = target.toLowerCase();
    if (isLoopbackHost(h)) return true;
    return bypassLan && isLanHost(h);
  }
}

bool isLoopbackHost(String host) {
  final h = host.toLowerCase();
  if (h == 'localhost' || h.endsWith('.localhost')) return true;
  final ip = InternetAddress.tryParse(h);
  return ip != null && ip.isLoopback;
}

bool isLanHost(String host) {
  final h = host.toLowerCase();
  if (h.endsWith('.local') || h.endsWith('.lan') || h.endsWith('.home.arpa')) return true;
  final ip = InternetAddress.tryParse(h);
  if (ip == null) return !h.contains('.'); // a bare name like "nas" can only be local
  final b = ip.rawAddress;
  if (ip.type == InternetAddressType.IPv4) {
    if (b[0] == 10) return true;
    if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return true;
    if (b[0] == 192 && b[1] == 168) return true;
    if (b[0] == 169 && b[1] == 254) return true;
    return false;
  }
  if (b.length == 16) {
    if ((b[0] & 0xFE) == 0xFC) return true; // fc00::/7 unique local
    if (b[0] == 0xFE && (b[1] & 0xC0) == 0x80) return true; // fe80::/10 link local
  }
  return false;
}
