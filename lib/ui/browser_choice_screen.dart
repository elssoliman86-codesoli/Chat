import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../data/services.dart';
import '../tools/browser_identity.dart';
import '../tools/browser_service.dart';
import 'kit.dart';
import 'proxy_screen.dart';
import 'theme.dart';

/// One line for the Settings list: which browser the built-in browser presents itself as.
String localBrowserSummary() {
  final s = store.settings;
  return s.localBrowser.isEmpty ? 'Built-in browser (default)' : (s.localBrowserName.isEmpty ? s.localBrowser : s.localBrowserName);
}

/// Settings → Change local browser: pick which browser the in-app browser acts as.
class BrowserChoiceScreen extends StatefulWidget {
  const BrowserChoiceScreen({super.key, this.loader});

  /// Lets a test supply the list instead of asking the phone.
  final Future<List<InstalledBrowser>> Function()? loader;

  @override
  State<BrowserChoiceScreen> createState() => _BrowserChoiceScreenState();
}

class _BrowserChoiceScreenState extends State<BrowserChoiceScreen> {
  List<InstalledBrowser>? _browsers;

  @override
  void initState() {
    super.initState();
    (widget.loader ?? BrowserList.installed)().then((l) {
      if (mounted) setState(() => _browsers = l);
    });
  }

  Future<void> _choose({required String package, String label = '', String version = ''}) async {
    final s = store.settings;
    setState(() {
      s.localBrowser = package;
      s.localBrowserName = label;
      s.localBrowserVersion = version;
    });
    await store.saveSettings();
    await BrowserService.instance.useIdentity(package: package, label: label, version: version);
  }

  IconData _icon(InstalledBrowser b) => switch (b.family) {
        BrowserFamily.tor => CupertinoIcons.lock_shield,
        BrowserFamily.firefox => CupertinoIcons.flame,
        BrowserFamily.chrome => CupertinoIcons.compass,
        BrowserFamily.edge => CupertinoIcons.compass,
        BrowserFamily.opera => CupertinoIcons.compass,
        BrowserFamily.other => CupertinoIcons.globe,
      };

  Color _color(InstalledBrowser b) => switch (b.family) {
        BrowserFamily.tor => iosPurple,
        BrowserFamily.firefox => iosOrange,
        BrowserFamily.chrome => iosBlue,
        BrowserFamily.edge => iosTeal,
        BrowserFamily.opera => iosRed,
        BrowserFamily.other => iosBlue,
      };

  Widget _check(bool on) => on ? const Icon(CupertinoIcons.checkmark_alt, color: iosGreen) : const SizedBox.shrink();

  @override
  Widget build(BuildContext context) {
    final s = store.settings;
    final list = _browsers;
    final pal = paletteOf(context);
    final selected = list?.where((b) => b.package == s.localBrowser).toList() ?? const <InstalledBrowser>[];
    final missing = s.localBrowser.isNotEmpty && list != null && selected.isEmpty;
    final torChosen = s.localBrowser.isNotEmpty && browserFamily(s.localBrowser, s.localBrowserName) == BrowserFamily.tor;
    return GroupedPage(title: 'Change local browser', children: [
      Group(
        header: 'Browser for plugin tasks',
        footer: 'Pages the assistant opens always stay inside Omni Chat, where it can read and drive them. The browser you pick '
            'only decides which one the sites think they are talking to (its name and version). The other apps are not opened or controlled.',
        children: [
          Cell(
            title: 'Built-in browser',
            subtitle: 'The default — go back to this any time',
            icon: CupertinoIcons.app,
            color: iosGreen,
            trailing: _check(s.localBrowser.isEmpty),
            onTap: () => _choose(package: ''),
          ),
          if (list == null)
            const Padding(padding: EdgeInsets.all(16), child: Center(child: CupertinoActivityIndicator()))
          else if (list.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('No other browsers were found on this phone.', style: TextStyle(color: pal.secondary)),
            )
          else
            for (final b in list)
              Cell(
                title: b.label,
                subtitle: b.version.isEmpty ? b.package : 'Version ${b.version}',
                icon: _icon(b),
                color: _color(b),
                trailing: _check(s.localBrowser == b.package),
                onTap: () => _choose(package: b.package, label: b.label, version: b.version),
              ),
        ],
      ),
      if (missing)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Text(
            '"${s.localBrowserName.isEmpty ? s.localBrowser : s.localBrowserName}" is no longer installed on this phone. '
            'Its identity is still used; pick the built-in browser to go back.',
            style: const TextStyle(color: iosOrange, fontSize: 13),
          ),
        ),
      if (torChosen)
        Group(
          header: 'Tor',
          footer: 'The identity alone does not hide your address. Turn on Tor under Proxy & Tor so the pages really go through it.',
          children: [
            Cell(
              title: 'Proxy & Tor',
              subtitle: proxySummary(),
              icon: CupertinoIcons.lock_shield,
              color: iosPurple,
              chevron: true,
              onTap: () async {
                await Navigator.push(context, CupertinoPageRoute<void>(builder: (_) => const ProxyScreen()));
                if (mounted) setState(() {});
              },
            ),
          ],
        ),
      Group(
        header: 'Current identity',
        children: [
          Padding(
            padding: const EdgeInsets.all(14),
            child: SelectableText(
              BrowserService.instance.currentUserAgent,
              style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: pal.secondary),
            ),
          ),
        ],
      ),
    ]);
  }
}
