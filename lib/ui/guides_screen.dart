import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../guides/ssh_guides.dart';
import 'kit.dart';
import 'syntax.dart';
import 'theme.dart';

/// The list of systems; tapping one opens its step-by-step SSH and FTP guide.
class GuidesScreen extends StatelessWidget {
  const GuidesScreen({super.key});

  static IconData _icon(String id) {
    switch (id) {
      case 'powershell':
      case 'cmd':
        return CupertinoIcons.rectangle_on_rectangle;
      case 'macos':
        return CupertinoIcons.device_laptop;
      default:
        return CupertinoIcons.chevron_left_slash_chevron_right;
    }
  }

  @override
  Widget build(BuildContext context) {
    return GroupedPage(
      title: 'SSH & FTP guides',
      children: [
        Group(
          header: 'Pick the system you want to connect to',
          footer: 'Each guide goes from turning the server on, to finding the address to type on your phone, to logging in with a key, '
              'to moving files. Every command can be copied with one tap.',
          children: [
            for (final g in sshGuides)
              Cell(
                title: g.title,
                subtitle: g.subtitle,
                icon: _icon(g.id),
                color: iosIndigo,
                chevron: true,
                onTap: () => Navigator.of(context).push(CupertinoPageRoute<void>(builder: (_) => GuideScreen(guide: g))),
              ),
          ],
        ),
      ],
    );
  }
}

class GuideScreen extends StatelessWidget {
  const GuideScreen({super.key, required this.guide});

  final Guide guide;

  @override
  Widget build(BuildContext context) {
    final pal = paletteOf(context);
    return GroupedPage(
      title: guide.title,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 18),
          child: Text(guide.intro, style: TextStyle(fontSize: 15, height: 1.45, color: pal.secondary)),
        ),
        for (final section in guide.sections) _Section(section: section),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.section});

  final GuideSection section;

  @override
  Widget build(BuildContext context) {
    final pal = paletteOf(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Text(section.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        ),
        Container(
          decoration: BoxDecoration(color: pal.cell, borderRadius: BorderRadius.circular(14)),
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (var i = 0; i < section.steps.length; i++) _Step(number: i + 1, step: section.steps[i]),
          ]),
        ),
      ]),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.number, required this.step});

  final int number;
  final GuideStep step;

  @override
  Widget build(BuildContext context) {
    final pal = paletteOf(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: pal.accent.withValues(alpha: 0.18), shape: BoxShape.circle),
          child: Text('$number', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: pal.accent)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(step.text, style: const TextStyle(fontSize: 15, height: 1.4)),
            if (step.command != null) CommandBox(command: step.command!),
          ]),
        ),
      ]),
    );
  }
}

/// A command to type, in the code font, with a button that copies it.
class CommandBox extends StatelessWidget {
  const CommandBox({super.key, required this.command});

  final String command;

  @override
  Widget build(BuildContext context) {
    const theme = CodeTheme.dark;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(color: theme.background, borderRadius: BorderRadius.circular(10)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
            child: SelectableText(command, style: codeTextStyle(size: 13)),
          ),
        ),
        IconButton(
          tooltip: 'Copy',
          visualDensity: VisualDensity.compact,
          icon: Icon(CupertinoIcons.doc_on_doc, size: 17, color: theme.headerText),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: command));
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(const SnackBar(content: Text('Command copied'), duration: Duration(seconds: 1)));
          },
        ),
      ]),
    );
  }
}
