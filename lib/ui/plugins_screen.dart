import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/models.dart';
import '../data/services.dart';
import 'model_list.dart';
import '../plugins/installer.dart';
import 'browser_dock.dart';
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
            onTap: () => showBrowser(context),
          ),
        ],
      ),
      Group(
        header: 'Gmail and Canva',
        footer: 'They work through the built-in browser: sign in once in the panel and the sign-in stays. The assistant then '
            'reads and acts on the pages for you, and asks before sending or publishing. Google may refuse sign-in inside '
            'an embedded browser; if so, try again with another sign-in method.',
        children: [
          SwitchCell(
            title: 'Gmail',
            subtitle: 'Read, search and write mail',
            icon: CupertinoIcons.mail,
            color: iosRed,
            value: s.pluginGmail,
            onChanged: (v) => set(() => s.pluginGmail = v),
          ),
          Cell(
            title: 'Sign in to Gmail',
            icon: CupertinoIcons.arrow_up_right_square,
            color: iosGray,
            chevron: true,
            onTap: () => showBrowser(context, address: 'https://mail.google.com'),
          ),
          SwitchCell(
            title: 'Canva',
            subtitle: 'Create and edit designs',
            icon: CupertinoIcons.paintbrush,
            color: iosPurple,
            value: s.pluginCanva,
            onChanged: (v) => set(() => s.pluginCanva = v),
          ),
          Cell(
            title: 'Sign in to Canva',
            icon: CupertinoIcons.arrow_up_right_square,
            color: iosGray,
            chevron: true,
            onTap: () => showBrowser(context, address: 'https://www.canva.com'),
          ),
        ],
      ),
      Group(
        header: 'Images for text-only models',
        footer: 'Most models cannot see photos. With this on, the text and a description are read from the image first and '
            'shown in the chat, then sent to the model as text. "Helper model" uses a model that can see, such as Gemini. '
            '"Google Lens" opens Lens in the browser panel and reads its text (experimental, it falls back to the helper).',
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              width: double.infinity,
              child: CupertinoSlidingSegmentedControl<String>(
                groupValue: s.imageReader,
                children: const {
                  'off': Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Text('Off')),
                  'helper': Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Text('Helper model')),
                  'lens': Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Text('Google Lens')),
                },
                onValueChanged: (v) => set(() => s.imageReader = v ?? 'helper'),
              ),
            ),
          ),
          Cell(
            title: 'Helper provider',
            subtitle: store.providerById(s.helperProviderId)?.name ?? 'Choose',
            chevron: true,
            onTap: _chooseHelperProvider,
          ),
          Cell(
            title: 'Helper model',
            subtitle: s.helperModel.isEmpty ? 'Choose a model that can see images' : s.helperModel,
            chevron: true,
            onTap: _chooseHelperModel,
          ),
        ],
      ),
      Group(
        header: 'GitHub',
        footer: 'With a token the assistant works on your repositories directly: it reads and analyzes them, then commits '
            'the changes itself (on a branch, with a pull request if you ask) instead of pasting code in the chat. '
            'Merging and creating repositories always ask you first. Without a token it can only read public repositories.',
        children: [
          SwitchCell(
            title: 'GitHub',
            subtitle: 'github_search, github_repo, github_file, github_issues',
            icon: CupertinoIcons.chevron_left_slash_chevron_right,
            color: const Color(0xFF3A3A3C),
            value: s.pluginGithub,
            onChanged: (v) => set(() => s.pluginGithub = v),
          ),
          SwitchCell(
            title: 'Allow edits',
            subtitle: 'Commit, branches, pull requests, issues, comments',
            icon: CupertinoIcons.pencil,
            color: iosOrange,
            value: s.githubWrite,
            onChanged: (v) => set(() => s.githubWrite = v),
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
      Group(
        header: 'Installed plugins',
        footer: 'Add a remote MCP server, a plugin.json link or a GitHub repo of skills. You can also just tell the '
            'assistant in the chat: "install the skills from github.com/owner/repo".',
        children: [
          for (final p in store.plugins)
            Cell(
              title: p.name,
              subtitle: '${p.kind.toUpperCase()} · ${p.tools.length} tools',
              icon: CupertinoIcons.cube_box,
              color: iosPurple,
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                Switch(
                  value: p.enabled,
                  onChanged: (v) {
                    setState(() => p.enabled = v);
                    store.savePlugins();
                  },
                ),
                IconButton(
                  icon: const Icon(CupertinoIcons.trash, size: 19),
                  onPressed: () {
                    setState(() => store.plugins.remove(p));
                    store.savePlugins();
                  },
                ),
              ]),
            ),
          Cell(
            title: 'Add plugin',
            icon: CupertinoIcons.plus,
            color: iosGreen,
            onTap: _addPlugin,
          ),
        ],
      ),
    ]);
  }

  Future<void> _chooseHelperProvider() async {
    if (store.providers.isEmpty) return;
    final id = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final p in store.providers) ListTile(title: Text(p.name), onTap: () => Navigator.pop(sheet, p.id)),
        ]),
      ),
    );
    if (id == null) return;
    setState(() {
      store.settings.helperProviderId = id;
      store.settings.helperModel = '';
    });
    store.saveSettings();
  }

  Future<void> _chooseHelperModel() async {
    final p = store.providerById(store.settings.helperProviderId);
    if (p == null) {
      await _chooseHelperProvider();
      return;
    }
    final picked = await Navigator.push<String>(
      context,
      CupertinoPageRoute<String>(builder: (_) => ModelListPage(provider: p, selected: store.settings.helperModel)),
    );
    if (picked == null) return;
    setState(() => store.settings.helperModel = picked);
    store.saveSettings();
  }

  Future<void> _addPlugin() async {
    final url = TextEditingController();
    final token = TextEditingController();
    final go = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Add plugin'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: url, autofocus: true, keyboardType: TextInputType.url, decoration: const InputDecoration(hintText: 'MCP URL, plugin.json or GitHub repo')),
          const SizedBox(height: 10),
          TextField(controller: token, obscureText: true, decoration: const InputDecoration(hintText: 'Access token (optional)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('Install')),
        ],
      ),
    );
    final u = url.text.trim();
    final t = token.text.trim();
    url.dispose();
    token.dispose();
    if (go != true || u.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('Installing…'), duration: Duration(seconds: 30)));
    final result = await installPluginFrom(engine, u, t, '');
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(result), duration: const Duration(seconds: 6)));
    if (mounted) setState(() {});
  }
}
