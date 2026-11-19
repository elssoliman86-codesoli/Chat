import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/services.dart';
import '../net/proxy_config.dart';
import '../net/proxy_service.dart';
import '../tools/termux_service.dart';
import 'kit.dart';
import 'theme.dart';

/// One line for the Settings list: where the traffic goes right now.
String proxySummary() {
  final c = ProxyConfig.fromSettings(store.settings);
  if (store.settings.proxyMode == 'custom' && c == null) return 'Proxy: fill in the address and port';
  return c == null ? 'Off — direct connection' : c.label;
}

/// Settings → Proxy & Tor: send all of the app's traffic through an HTTP/SOCKS5 proxy or through Tor.
class ProxyScreen extends StatefulWidget {
  const ProxyScreen({super.key});

  @override
  State<ProxyScreen> createState() => _ProxyScreenState();
}

class _ProxyScreenState extends State<ProxyScreen> {
  late final TextEditingController _host = TextEditingController(text: store.settings.proxyHost);
  late final TextEditingController _port =
      TextEditingController(text: store.settings.proxyPort > 0 ? '${store.settings.proxyPort}' : '');
  late final TextEditingController _user = TextEditingController(text: store.settings.proxyUser);
  late final TextEditingController _pass = TextEditingController(text: store.settings.proxyPass);
  late final TextEditingController _torHost = TextEditingController(text: store.settings.torHost);
  late final TextEditingController _torPort = TextEditingController(text: '${store.settings.torPort}');

  bool _checking = false;
  String? _reach; // null = reachable (or not checked), otherwise why not
  bool _reachChecked = false;
  bool _testing = false;
  bool _starting = false;
  ProxyTestResult? _result;
  String? _torNote;

  @override
  void dispose() {
    for (final c in [_host, _port, _user, _pass, _torHost, _torPort]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _checkReach();
  }

  Future<void> _checkReach() async {
    if (store.settings.proxyMode == 'off') {
      if (mounted) setState(() => _reachChecked = false);
      return;
    }
    setState(() => _checking = true);
    final why = await ProxyService.instance.reachability();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _reach = why;
      _reachChecked = true;
    });
  }

  Future<void> _save() async {
    await store.saveSettings();
    await ProxyService.instance.apply(store.settings);
    if (mounted) setState(() => _result = null);
    unawaited(_checkReach());
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _result = null;
    });
    final r = await ProxyService.instance.test();
    if (!mounted) return;
    setState(() {
      _testing = false;
      _result = r;
    });
  }

  Future<void> _startTor() async {
    setState(() {
      _starting = true;
      _torNote = null;
    });
    String note;
    try {
      if (!await TermuxService.instance.isInstalled()) {
        note = 'Termux is not installed. Install it (from F-Droid), or use Orbot instead.';
      } else if (!await TermuxService.instance.hasPermission()) {
        note = 'Termux access is not allowed yet. Turn it on in Plugins → Termux first.';
      } else {
        final r = await TermuxService.instance.run(
          'command -v tor >/dev/null 2>&1 || pkg install -y tor; (pgrep -x tor >/dev/null 2>&1 || nohup tor >/dev/null 2>&1 &); sleep 2; pgrep -x tor >/dev/null && echo TOR_RUNNING',
          timeout: const Duration(seconds: 180),
        );
        final out = '${r['stdout'] ?? ''}${r['stderr'] ?? ''}';
        note = out.contains('TOR_RUNNING')
            ? 'Tor is running in Termux. Give it up to a minute to connect, then tap "Test connection".'
            : 'Could not start Tor in Termux.\n${out.trim()}';
      }
    } catch (e) {
      note = 'Could not start Tor in Termux: $e';
    }
    if (!mounted) return;
    setState(() {
      _starting = false;
      _torNote = note;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = store.settings;
    final pal = paletteOf(context);
    final mode = s.proxyMode;
    final svc = ProxyService.instance;
    final browserWarning = mode != 'off' && s.proxyBrowser && svc.browserProxied == false;
    return GroupedPage(title: 'Proxy & Tor', children: [
      Group(
        header: 'Route',
        footer: mode == 'tor'
            ? 'All AI, search and download traffic goes through Tor. If Tor is not running, requests fail instead of going out directly.'
            : mode == 'custom'
                ? 'All of the app\'s traffic goes through the proxy below.'
                : 'Traffic goes out directly.',
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              width: double.infinity,
              child: CupertinoSlidingSegmentedControl<String>(
                groupValue: mode,
                children: const {
                  'off': Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Text('Off')),
                  'custom': Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Text('Proxy')),
                  'tor': Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Text('Tor')),
                },
                onValueChanged: (v) {
                  setState(() => s.proxyMode = v ?? 'off');
                  _save();
                },
              ),
            ),
          ),
        ],
      ),
      if (mode != 'off')
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: _checking
              ? Text('Checking the connection…', style: TextStyle(color: pal.secondary, fontSize: 13.5))
              : !_reachChecked
                  ? const SizedBox.shrink()
                  : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Icon(_reach == null ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.exclamationmark_triangle_fill,
                          size: 18, color: _reach == null ? iosGreen : iosOrange),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _reach ?? (mode == 'tor' ? 'Tor is answering. Tap "Test connection" to confirm it reaches the internet.' : 'The proxy is answering.'),
                          style: TextStyle(color: _reach == null ? pal.secondary : iosOrange, fontSize: 13.5, height: 1.3),
                        ),
                      ),
                      IconButton(visualDensity: VisualDensity.compact, icon: const Icon(CupertinoIcons.arrow_clockwise, size: 18), onPressed: _checkReach),
                    ]),
        ),
      if (mode == 'custom')
        Group(
          header: 'Proxy server',
          footer: 'Username and password are optional. They are stored on this phone only.',
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                child: CupertinoSlidingSegmentedControl<String>(
                  groupValue: s.proxyKind,
                  children: const {
                    'http': Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Text('HTTP')),
                    'socks5': Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Text('SOCKS5')),
                  },
                  onValueChanged: (v) {
                    setState(() => s.proxyKind = v ?? 'http');
                    _save();
                  },
                ),
              ),
            ),
            FieldCell(
              controller: _host,
              label: 'Host',
              hint: 'proxy.example.com or 192.168.1.10',
              keyboard: TextInputType.url,
              onChanged: (v) {
                s.proxyHost = v.trim();
                _save();
              },
            ),
            FieldCell(
              controller: _port,
              label: 'Port',
              hint: '8080',
              keyboard: TextInputType.number,
              onChanged: (v) {
                s.proxyPort = int.tryParse(v.trim()) ?? 0;
                _save();
              },
            ),
            FieldCell(
              controller: _user,
              label: 'Username (optional)',
              onChanged: (v) {
                s.proxyUser = v;
                _save();
              },
            ),
            FieldCell(
              controller: _pass,
              label: 'Password (optional)',
              obscure: true,
              onChanged: (v) {
                s.proxyPass = v;
                _save();
              },
            ),
          ],
        ),
      if (mode == 'tor') ...[
        Group(
          header: 'Tor on this phone',
          footer: 'Tor itself is a separate program. Start Orbot (VPN mode off, or its SOCKS port 9050), or run Tor in Termux. '
              'Use a computer\'s address instead if Tor runs there.',
          children: [
            FieldCell(
              controller: _torHost,
              label: 'Tor host',
              hint: '127.0.0.1',
              keyboard: TextInputType.url,
              onChanged: (v) {
                s.torHost = v.trim().isEmpty ? '127.0.0.1' : v.trim();
                _save();
              },
            ),
            FieldCell(
              controller: _torPort,
              label: 'Tor SOCKS port',
              hint: '9050',
              keyboard: TextInputType.number,
              onChanged: (v) {
                s.torPort = int.tryParse(v.trim()) ?? 9050;
                _save();
              },
            ),
            Cell(
              title: _starting ? 'Starting Tor…' : 'Start Tor in Termux',
              subtitle: 'Installs and runs "tor" for you (needs Termux)',
              icon: CupertinoIcons.play_circle,
              color: iosPurple,
              onTap: _starting ? null : _startTor,
            ),
          ],
        ),
        if (_torNote != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text(_torNote!, style: TextStyle(color: pal.secondary, fontSize: 13)),
          ),
        Group(
          header: 'Or run it by hand in Termux',
          children: [
            _Command(command: 'pkg install tor'),
            _Command(command: 'tor'),
          ],
        ),
      ],
      if (mode != 'off') ...[
        Group(header: 'Options', footer: 'The device itself (localhost) is never sent through the proxy.', children: [
          SwitchCell(
            title: 'Keep local network direct',
            subtitle: 'Ollama, LM Studio, a PC\'s FTP and other 192.168.x.x addresses skip the proxy',
            icon: CupertinoIcons.house,
            color: iosBlue,
            value: s.proxyBypassLan,
            onChanged: (v) {
              setState(() => s.proxyBypassLan = v);
              _save();
            },
          ),
          SwitchCell(
            title: 'Use for the built-in browser',
            subtitle: 'Pages the agent opens go through it too',
            icon: CupertinoIcons.globe,
            color: iosGreen,
            value: s.proxyBrowser,
            onChanged: (v) {
              setState(() => s.proxyBrowser = v);
              _save();
            },
          ),
        ]),
        if (browserWarning)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text(
              'This phone\'s web view cannot be pointed at a proxy, so the built-in browser connects directly. Turn the browser plugin off if that matters.',
              style: const TextStyle(color: iosOrange, fontSize: 13),
            ),
          ),
        Group(header: 'Check', children: [
          Cell(
            title: _testing ? 'Testing…' : 'Test connection',
            subtitle: 'Asks check.torproject.org which address it sees',
            icon: CupertinoIcons.checkmark_shield,
            color: iosTeal,
            onTap: _testing ? null : _test,
          ),
          if (_result != null)
            Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                _result!.message,
                style: TextStyle(color: _result!.ok ? iosGreen : iosRed, fontSize: 14),
              ),
            ),
        ]),
      ],
    ]);
  }
}

class _Command extends StatelessWidget {
  const _Command({required this.command});

  final String command;

  @override
  Widget build(BuildContext context) {
    final pal = paletteOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Row(children: [
        Expanded(child: SelectableText(command, style: TextStyle(fontFamily: 'monospace', color: pal.secondary))),
        IconButton(
          icon: const Icon(Icons.copy, size: 18),
          onPressed: () => Clipboard.setData(ClipboardData(text: command)),
        ),
      ]),
    );
  }
}
