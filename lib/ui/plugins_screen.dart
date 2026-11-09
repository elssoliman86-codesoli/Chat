import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/services.dart';
import '../tools/termux_service.dart';
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
  TermuxDiagnosis? _termux;

  @override
  void initState() {
    super.initState();
    _refreshTermux();
  }

  Future<void> _refreshTermux() async {
    final d = await TermuxService.instance.diagnose();
    if (mounted) setState(() => _termux = d);
  }

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
          SwitchCell(
            title: 'Show it while it works',
            subtitle: 'Off: it works in the background and the chat stays in view',
            icon: CupertinoIcons.eye,
            color: iosTeal,
            value: s.browserVisible,
            onChanged: (v) => set(() => s.browserVisible = v),
          ),
          SwitchCell(
            title: 'Keep working in the background',
            subtitle: 'Long tasks continue when you leave the app (shows a notification)',
            icon: CupertinoIcons.bolt_horizontal,
            color: iosOrange,
            value: s.keepAlive,
            onChanged: (v) => set(() => s.keepAlive = v),
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
        header: 'Shell (Termux)',
        footer: _termux == null
            ? 'Unlike every other tool, this reaches a real Linux shell on your own device — whatever you actually have '
                'installed there (python, git, pip, compilers, ...) — not a sandbox. Off by default on purpose.'
            : !_termux!.installed
                ? 'Termux is not installed. It is a separate, free terminal app — install it, open it once, then come back here.'
                : !_termux!.supportsAutomation
                    ? 'This exact Termux app (${_termux!.versionName.isEmpty ? 'installed' : 'version ${_termux!.versionName}'}) '
                        'does not support the connection this needs — it is missing even if you grant every permission, because '
                        'that specific build predates it. Your Termux itself and its own packages still work completely fine for '
                        'you to use by hand; this is only about this app being able to reach it automatically. Tap "How Termux '
                        'setup works" below for exactly what to do.'
                    : !_termux!.hasPermission
                        ? 'Termux is installed and supports the connection, but has not granted this app permission to run '
                            'commands in it yet.'
                        : 'Unlike every other tool, this reaches a real Linux shell on your own device — whatever you actually '
                            'have installed there (python, git, pip, compilers, ...) — not a sandbox. Off by default on purpose.',
        children: [
          SwitchCell(
            title: 'Real shell commands',
            subtitle: 'termux_run, through the Termux app',
            icon: CupertinoIcons.chevron_left_slash_chevron_right,
            color: iosRed,
            value: s.termuxTools,
            onChanged: (v) => set(() => s.termuxTools = v),
          ),
          Cell(
            title: _termux == null
                ? 'Checking Termux…'
                : !_termux!.installed
                    ? 'Termux is not installed'
                    : !_termux!.supportsAutomation
                        ? 'This Termux build is too old for this'
                        : !_termux!.hasPermission
                            ? 'Grant permission'
                            : 'Termux is ready',
            subtitle: _termux?.installed == true && _termux!.supportsAutomation && _termux!.hasPermission
                ? null
                : 'Tap to check again',
            icon: _termux?.installed == true && _termux!.supportsAutomation && _termux!.hasPermission
                ? CupertinoIcons.checkmark_circle
                : CupertinoIcons.exclamationmark_circle,
            color: _termux?.installed == true && _termux!.supportsAutomation && _termux!.hasPermission
                ? iosGreen
                : iosOrange,
            chevron: true,
            onTap: () async {
              if ((_termux?.installed ?? false) && (_termux?.supportsAutomation ?? false) && !(_termux?.hasPermission ?? false)) {
                await TermuxService.instance.requestPermission();
              }
              await _refreshTermux();
            },
          ),
          Cell(
            title: 'How Termux setup works',
            icon: CupertinoIcons.question_circle,
            color: iosGray,
            chevron: true,
            onTap: _termuxHelp,
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
        header: 'Social media',
        footer: 'Also through the built-in browser: sign in once in the panel and the sign-in stays. Useful for posting, '
            'scheduling, checking a page or channel, following up on comments, or researching a product or topic. The '
            'assistant asks before publishing, following, messaging or anything else that is not just reading.',
        children: [
          SwitchCell(
            title: 'Facebook',
            subtitle: 'Pages, posts, groups, Marketplace',
            icon: CupertinoIcons.person_2,
            color: const Color(0xFF1877F2),
            value: s.pluginFacebook,
            onChanged: (v) => set(() => s.pluginFacebook = v),
          ),
          Cell(
            title: 'Sign in to Facebook',
            icon: CupertinoIcons.arrow_up_right_square,
            color: iosGray,
            chevron: true,
            onTap: () => showBrowser(context, address: 'https://www.facebook.com'),
          ),
          SwitchCell(
            title: 'Instagram',
            subtitle: 'Posts, Stories, DMs, profiles',
            icon: CupertinoIcons.camera,
            color: const Color(0xFFE1306C),
            value: s.pluginInstagram,
            onChanged: (v) => set(() => s.pluginInstagram = v),
          ),
          Cell(
            title: 'Sign in to Instagram',
            icon: CupertinoIcons.arrow_up_right_square,
            color: iosGray,
            chevron: true,
            onTap: () => showBrowser(context, address: 'https://www.instagram.com'),
          ),
          SwitchCell(
            title: 'YouTube',
            subtitle: 'Search, watch, manage your own channel/Studio',
            icon: CupertinoIcons.play_rectangle,
            color: const Color(0xFFFF0000),
            value: s.pluginYoutube,
            onChanged: (v) => set(() => s.pluginYoutube = v),
          ),
          Cell(
            title: 'Sign in to YouTube',
            icon: CupertinoIcons.arrow_up_right_square,
            color: iosGray,
            chevron: true,
            onTap: () => showBrowser(context, address: 'https://www.youtube.com'),
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
            title: 'Add plugin or skill',
            icon: CupertinoIcons.plus,
            color: iosGreen,
            onTap: _addMenu,
          ),
          Cell(
            title: 'How to add plugins',
            icon: CupertinoIcons.question_circle,
            color: iosGray,
            onTap: _help,
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

  Future<void> _addMenu() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(CupertinoIcons.link), title: const Text('From a link'), subtitle: const Text('MCP server, plugin.json or GitHub repo'), onTap: () => Navigator.pop(sheet, 'link')),
          ListTile(leading: const Icon(CupertinoIcons.doc_on_clipboard), title: const Text('Paste text'), subtitle: const Text('plugin.json, MCP config or SKILL.md'), onTap: () => Navigator.pop(sheet, 'text')),
          ListTile(leading: const Icon(CupertinoIcons.doc), title: const Text('Choose a file'), subtitle: const Text('.json, .md or a .zip of skills'), onTap: () => Navigator.pop(sheet, 'file')),
          ListTile(leading: const Icon(CupertinoIcons.question_circle), title: const Text('How to add plugins'), onTap: () => Navigator.pop(sheet, 'help')),
        ]),
      ),
    );
    if (choice == 'link') await _addPlugin();
    if (choice == 'text') await _addText();
    if (choice == 'file') await _addFile();
    if (choice == 'help') await _help();
  }

  Future<void> _report(String label, Future<String> Function() job) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(content: Text(label), duration: const Duration(seconds: 30)));
    String result;
    try {
      result = await job();
    } catch (e) {
      result = 'Could not install: $e';
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(result), duration: const Duration(seconds: 7)));
    if (mounted) setState(() {});
  }

  Future<void> _addText() async {
    final text = TextEditingController();
    final go = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Paste plugin or skill'),
        content: TextField(
          controller: text,
          autofocus: true,
          minLines: 6,
          maxLines: 12,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
          decoration: const InputDecoration(hintText: 'plugin.json, {"mcpServers": …} or SKILL.md text'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('Install')),
        ],
      ),
    );
    final t = text.text;
    text.dispose();
    if (go != true || t.trim().isEmpty || !mounted) return;
    await _report('Installing…', () => installFromText(engine, t, '', ''));
  }

  Future<void> _addFile() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.any);
    final f = r?.files.single;
    if (f == null || f.path == null || !mounted) return;
    final name = f.name.toLowerCase();
    await _report('Installing ${f.name}…', () async {
      final bytes = await File(f.path!).readAsBytes();
      if (name.endsWith('.zip')) return installFromZip(engine, bytes);
      final fallback = f.name.replaceAll(RegExp(r'\.\w+$'), '');
      return installFromText(engine, utf8.decode(bytes, allowMalformed: true), '', '', fallbackName: fallback);
    });
  }

  Future<void> _help() async {
    await showDialog<void>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('How to add plugins'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(child: SelectableText(pluginHelp, style: const TextStyle(fontSize: 13.5, height: 1.4))),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(const ClipboardData(text: pluginHelp));
              Navigator.pop(d);
            },
            child: const Text('Copy'),
          ),
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Close')),
        ],
      ),
    );
  }

  static const String _termuxHelpText =
      'If Termux is on this phone from the Play Store: its own terminal and packages can keep working completely fine '
      'for you by hand — that is not what\'s broken. What is missing is a specific piece (the "RUN_COMMAND" permission '
      'and service) this app needs to reach Termux automatically, and the Play Store build is frozen at a version from '
      'before that existed (Termux was removed from the Play Store years ago and never updated there again), so no '
      'amount of granting permission adds it — it genuinely is not in that build. There is no way around this from this '
      'app\'s side; the only fix is installing the real, current build.\n\n'
      '0. First, back up what is already in Termux so nothing is lost: open Termux and run\n'
      '   tar -czf /sdcard/termux-backup.tar.gz -C /data/data/com.termux/files home\n'
      '   (or just "termux-backup ~/termux-backup.tar.gz" if that command exists on your version) — this saves it to '
      'your phone\'s normal storage, outside Termux, so it survives the next step.\n\n'
      'Then uninstall the Play Store Termux — it is signed differently from the real build, so the one below cannot '
      '"update" over it; they have to be fully removed first or the new install will fail or silently create a second, '
      'separate Termux with its own empty home folder.\n\n'
      '1. Install Termux from F-Droid or its GitHub releases page — that is the real, maintained, latest build.\n\n'
      '2. Open Termux once so it finishes setting itself up.\n\n'
      '3. In Termux, run:\n'
      '   echo "allow-external-apps = true" >> ~/.termux/termux.properties\n'
      '   termux-reload-settings\n\n'
      '4. Come back here, turn on "Real shell commands", and tap "Grant permission" when asked — this lets Omni Chat run '
      'commands inside Termux.\n\n'
      'Once set up, the assistant can run real shell commands on your device through Termux (python, pip, git, curl, '
      'whatever you have installed there) — this is your actual device, not a sandbox, so only turn it on if you want that.\n\n'
      'Reaching another shell over SSH works the same way for any of these, once you have set up your own access to it '
      'by hand first — run "pkg install openssh" once in Termux, then just ask the assistant to run things there and it '
      'uses that same ssh connection:\n\n'
      '• A Linux server or a Kali Linux machine: set up your key/access as usual (ssh-keygen, ssh-copy-id, or an entry '
      'in ~/.ssh/config), then "ssh your-host \'command\'" is just another Termux command.\n\n'
      '• Windows Command Prompt or PowerShell: install the "OpenSSH Server" optional Windows feature on that PC '
      '(Settings > Apps > Optional features > Add a feature > OpenSSH Server), start the "OpenSSH SSH Server" service, '
      'and add your own public key to that Windows account. "ssh user@that-pc cmd /c ..." runs a Command Prompt command; '
      '"ssh user@that-pc powershell -command \'...\'" runs a PowerShell one.\n\n'
      'In every case: it never connects to a server or PC on its own without a key or login you already set up yourself '
      '— never a guessed host, never a password.';

  Future<void> _termuxHelp() async {
    await showDialog<void>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('How Termux setup works'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(_termuxHelpText, style: const TextStyle(fontSize: 13.5, height: 1.4)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(const ClipboardData(text: _termuxHelpText));
              Navigator.pop(d);
            },
            child: const Text('Copy'),
          ),
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Close')),
        ],
      ),
    );
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
    if (go != true || u.isEmpty || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('Installing…'), duration: Duration(seconds: 30)));
    final result = await installPluginFrom(engine, u, t, '');
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(result), duration: const Duration(seconds: 6)));
    if (mounted) setState(() {});
  }
}
