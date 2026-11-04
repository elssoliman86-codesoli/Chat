import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../data/services.dart';
import 'browser_screen.dart';
import 'kit.dart';
import 'theme.dart';

class PluginsScreen extends StatefulWidget {
  const PluginsScreen({super.key});

  @override
  State<PluginsScreen> createState() => _PluginsScreenState();
}

class _PluginsScreenState extends State<PluginsScreen> {
  late final TextEditingController _token = TextEditingController(text: store.settings.githubToken);
  bool _show = false;

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = store.settings;
    void set(VoidCallback f) {
      setState(f);
      store.saveSettings();
    }

    return GroupedPage(title: 'Plugins', children: [
      Group(
        header: 'Web',
        footer: 'With "Search before answering" on, every question first gets fresh web results with today\'s date, '
            'so prices and news are not taken from the model\'s old memory.',
        children: [
          SwitchCell(
            title: 'Web search and pages',
            subtitle: 'web_search, fetch_page',
            icon: CupertinoIcons.globe,
            value: s.webTools,
            onChanged: (v) => set(() => s.webTools = v),
          ),
          SwitchCell(
            title: 'Search before answering',
            subtitle: 'New chats start with the Search switch on',
            icon: CupertinoIcons.search,
            color: iosTeal,
            value: s.webAlways,
            onChanged: (v) => set(() => s.webAlways = v),
          ),
        ],
      ),
      Group(
        header: 'Browser',
        footer: 'The assistant can open pages in a real browser that runs JavaScript, which works for live prices.',
        children: [
          SwitchCell(
            title: 'Built-in browser',
            subtitle: 'browse_page',
            icon: CupertinoIcons.compass,
            color: iosIndigo,
            value: s.pluginBrowser,
            onChanged: (v) => set(() => s.pluginBrowser = v),
          ),
          Cell(
            title: 'Open browser',
            icon: CupertinoIcons.arrow_up_right_square,
            color: iosGray,
            chevron: true,
            onTap: () => Navigator.push(context, CupertinoPageRoute<void>(fullscreenDialog: true, builder: (_) => const BrowserScreen())),
          ),
        ],
      ),
      Group(
        header: 'GitHub',
        footer: 'Search repositories, read files and README, list issues and pull requests. '
            'A token is optional: it raises the rate limit and opens your private repositories (read-only is enough).',
        children: [
          SwitchCell(
            title: 'GitHub',
            subtitle: 'github_search, github_repo, github_file, github_issues',
            icon: CupertinoIcons.chevron_left_slash_chevron_right,
            color: const Color(0xFF3A3A3C),
            value: s.pluginGithub,
            onChanged: (v) => set(() => s.pluginGithub = v),
          ),
          FieldCell(
            controller: _token,
            label: 'Personal access token (optional)',
            obscure: !_show,
            hint: 'github_pat_…',
            onChanged: (v) {
              s.githubToken = v.trim();
              store.saveSettings();
            },
            suffix: IconButton(
              icon: Icon(_show ? CupertinoIcons.eye_slash : CupertinoIcons.eye, size: 20),
              onPressed: () => setState(() => _show = !_show),
            ),
          ),
        ],
      ),
    ]);
  }
}
