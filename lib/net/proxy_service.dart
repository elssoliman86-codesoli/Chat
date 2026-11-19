import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../core/models.dart';
import 'proxy_bridge.dart';
import 'proxy_config.dart';

class ProxyTestResult {
  const ProxyTestResult({required this.ok, required this.message, this.ip = '', this.isTor});

  final bool ok;
  final String message;
  final String ip;

  /// Whether the Tor Project's checker says the connection came out of Tor; null when it could not say.
  final bool? isTor;
}

class _ProxyOverrides extends HttpOverrides {
  _ProxyOverrides(this.service);

  final ProxyService service;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = service.findProxy;
    return client;
  }
}

/// Routes the app's network traffic through the proxy or Tor chosen in the settings. Every request the app
/// makes (AI providers, web search, GitHub, downloads) goes through the one local bridge; the built-in
/// browser is pointed at it as well. Turned off, nothing changes.
class ProxyService {
  ProxyService._();
  static final ProxyService instance = ProxyService._();

  static const MethodChannel _channel = MethodChannel('omni/proxy');

  final LocalProxyBridge _bridge = LocalProxyBridge();
  ProxyConfig? _config;
  int _bridgePort = 0;
  bool _bridgeFailed = false;

  /// Whether the built-in browser is going through the proxy: true, false (this phone's WebView cannot), or
  /// null when not asked / not applicable.
  bool? browserProxied;

  ProxyConfig? get config => _config;
  bool get active => _config != null;

  /// Makes every HttpClient in the app ask [findProxy]. Safe to call more than once.
  void install() {
    HttpOverrides.global = _ProxyOverrides(this);
  }

  /// The answer for one request, in dart:io's format. While a proxy is on but its bridge is not ready,
  /// requests are sent to a dead address and fail — they never fall back to a direct connection, which
  /// would show the real address while Tor is supposed to hide it.
  String findProxy(Uri uri) {
    final c = _config;
    if (c == null || c.bypasses(uri.host)) return 'DIRECT';
    if (_bridgePort == 0 || _bridgeFailed) return 'PROXY 127.0.0.1:1';
    return 'PROXY 127.0.0.1:$_bridgePort';
  }

  /// Applies the settings: starts or stops the local bridge and points the browser at it.
  Future<void> apply(AppSettings s) async {
    final c = ProxyConfig.fromSettings(s);
    _config = c;
    if (c == null) {
      _bridgeFailed = false;
      _bridgePort = 0;
      await _bridge.stop();
      await _setBrowser(null, c);
      return;
    }
    try {
      _bridgePort = 0;
      _bridgePort = await _bridge.start(c);
      _bridgeFailed = false;
    } catch (_) {
      _bridgePort = 0;
      _bridgeFailed = true;
    }
    await _setBrowser(s.proxyBrowser && !_bridgeFailed ? _bridgePort : null, c);
  }

  Future<void> _setBrowser(int? port, ProxyConfig? c) async {
    browserProxied = null;
    try {
      if (port == null || c == null) {
        await _channel.invokeMethod<bool>('clear');
      } else {
        browserProxied = await _channel.invokeMethod<bool>('set', <String, Object>{'port': port, 'bypassLan': c.bypassLan}) ?? false;
      }
    } on MissingPluginException {
      // Not on Android (or a test): there is no browser to point.
    } catch (_) {
      if (port != null) browserProxied = false;
    }
  }

  /// Asks the Tor Project's checker which address the world sees, through the current route.
  Future<ProxyTestResult> test() async {
    final c = _config;
    try {
      final res = await http.get(Uri.parse('https://check.torproject.org/api/ip')).timeout(const Duration(seconds: 45));
      if (res.statusCode != 200) {
        return ProxyTestResult(ok: false, message: 'The check site answered HTTP ${res.statusCode}.');
      }
      final j = jsonDecode(utf8.decode(res.bodyBytes));
      final ip = j is Map ? (j['IP'] ?? '').toString() : '';
      final tor = j is Map && j['IsTor'] is bool ? j['IsTor'] as bool : null;
      if (c == null) {
        return ProxyTestResult(ok: true, message: 'No proxy: the world sees your normal address $ip.', ip: ip, isTor: tor);
      }
      if (c.isTor) {
        return tor == true
            ? ProxyTestResult(ok: true, message: 'Connected through Tor. Exit address: $ip.', ip: ip, isTor: true)
            : ProxyTestResult(ok: false, message: 'Connected, but the traffic is NOT coming out of Tor (address $ip). Check the Tor host and port.', ip: ip, isTor: false);
      }
      return ProxyTestResult(ok: true, message: 'Connected through ${c.label}. The world sees $ip.', ip: ip, isTor: tor);
    } on TimeoutException {
      return const ProxyTestResult(ok: false, message: 'Timed out. Is the proxy or Tor running and reachable? Tor can take a minute to start.');
    } catch (e) {
      final text = e.toString();
      final hint = c != null && (text.contains('Connection refused') || text.contains('502') || text.contains('SOCKS'))
          ? '\nNothing answered at ${c.host}:${c.port}${c.isTor ? ' — start Tor (Orbot, or tor in Termux) first.' : '.'}'
          : '';
      return ProxyTestResult(ok: false, message: 'Failed: $text$hint');
    }
  }
}
