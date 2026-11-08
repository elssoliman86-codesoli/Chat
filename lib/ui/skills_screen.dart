import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/models.dart';
import '../core/skill_import.dart';
import '../data/services.dart';
import '../tools/tools.dart';
import 'kit.dart';
import 'theme.dart';

/// Groups skills into folders: "Built-in" first, then one folder per GitHub repo (or site) a skill
/// was installed from, then a single "Manual" folder last for anything written or pasted by hand.
/// Shared by the Skills management screen and the per-chat skill picker so both show the same folders.
Map<String, List<Skill>> groupSkillsByFolder(List<Skill> skills) {
  final folders = <String, List<Skill>>{};
  for (final s in skills) {
    final key = s.source.trim().isEmpty ? 'Manual' : s.source.trim();
    folders.putIfAbsent(key, () => <Skill>[]).add(s);
  }
  int rank(String key) => key == 'Built-in' ? 0 : (key == 'Manual' ? 2 : 1);
  return Map.fromEntries(folders.entries.toList()
    ..sort((a, b) {
      final r = rank(a.key).compareTo(rank(b.key));
      if (r != 0) return r;
      return a.key.toLowerCase().compareTo(b.key.toLowerCase());
    }));
}

/// One collapsible folder: a tappable header (name, count, chevron) that drops down to reveal its
/// cells, closed by default — used for both the Skills screen and the per-chat skill picker so a
/// folder with many skills in it does not take over the whole list.
class FolderGroup extends StatefulWidget {
  const FolderGroup({super.key, required this.title, required this.count, required this.children, this.dense = false});

  final String title;
  final int count;
  final List<Widget> children;

  /// A lighter header (used in the chat skill-picker sheet) without the rounded card background.
  final bool dense;

  @override
  State<FolderGroup> createState() => _FolderGroupState();
}

class _FolderGroupState extends State<FolderGroup> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final rows = <Widget>[];
    for (var i = 0; i < widget.children.length; i++) {
      rows.add(widget.children[i]);
      if (i < widget.children.length - 1) {
        rows.add(Divider(height: 0.5, thickness: 0.5, indent: 16, color: p.separator));
      }
    }
    final header = InkWell(
      onTap: () => setState(() => _open = !_open),
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, widget.dense ? 8 : 0, 16, 6),
        child: Row(children: [
          Icon(_open ? CupertinoIcons.chevron_down : CupertinoIcons.chevron_right, size: 13, color: p.secondary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(widget.title.toUpperCase(),
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.secondary)),
          ),
          Text('${widget.count}', style: TextStyle(fontSize: 12, color: p.secondary)),
        ]),
      ),
    );
    if (!_open) return Padding(padding: const EdgeInsets.only(bottom: 4), child: header);
    final body = widget.dense
        ? Column(children: widget.children)
        : ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Container(color: p.cell, child: Column(children: rows)),
          );
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [header, body]),
    );
  }
}

class SkillsScreen extends StatelessWidget {
  const SkillsScreen({super.key});

  void _edit(BuildContext context, Skill skill, {bool isNew = false}) {
    Navigator.push(context, CupertinoPageRoute<void>(builder: (_) => SkillEditScreen(skill: skill, isNew: isNew)));
  }

  Future<void> _import(BuildContext context) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(CupertinoIcons.doc_on_clipboard),
            title: const Text('Paste SKILL.md text'),
            onTap: () => Navigator.pop(sheet, 'paste'),
          ),
          ListTile(
            leading: const Icon(CupertinoIcons.folder),
            title: const Text('Pick a .md file'),
            onTap: () => Navigator.pop(sheet, 'file'),
          ),
        ]),
      ),
    );
    if (choice == null || !context.mounted) return;
    String? source;
    String fallback = 'Imported skill';
    if (choice == 'paste') {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      source = data?.text;
    } else {
      final r = await FilePicker.platform.pickFiles(type: FileType.any);
      final f = r?.files.single;
      if (f?.path != null) {
        source = await File(f!.path!).readAsString();
        fallback = f.name.replaceAll(RegExp(r'\.\w+$'), '');
      }
    }
    if (source == null || source.trim().isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Nothing to import')));
      }
      return;
    }
    final skill = parseSkillMarkdown(source, fallbackName: fallback);
    if (skill == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not read that as a skill')));
      }
      return;
    }
    if (context.mounted) _edit(context, skill, isNew: true);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final folders = groupSkillsByFolder(store.skills);
        return GroupedPage(
          title: 'Skills',
          actions: [
            IconButton(tooltip: 'Import', icon: const Icon(CupertinoIcons.arrow_down_doc), onPressed: () => _import(context)),
            IconButton(
              tooltip: 'New skill',
              icon: const Icon(CupertinoIcons.plus),
              onPressed: () => _edit(context, Skill(id: newId(), name: ''), isNew: true),
            ),
          ],
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 14),
              child: Text(
                'A skill is a set of instructions plus the tools it may use. "Always active" skills are included with '
                'every message. Others only apply when switched on inside a chat (the bolt) or loaded by the '
                'assistant itself when it decides one fits. Skills are grouped into a folder per repo they came '
                'from, plus a Manual folder for the ones written or pasted by hand — tap a folder to open it.',
                style: TextStyle(fontSize: 13.5, color: paletteOf(context).secondary),
              ),
            ),
            for (final folder in folders.keys)
              FolderGroup(
                title: folder,
                count: folders[folder]!.length,
                children: [
                  for (final s in folders[folder]!)
                    Cell(
                      title: s.name,
                      subtitle: '${s.alwaysOn ? 'Always active in every conversation · ' : (s.autoUse ? 'Available for automatic activation · ' : '')}${s.description}${s.tools.isEmpty ? '' : '\nTools: ${s.tools.join(', ')}'}',
                      onTap: () => _edit(context, s),
                      trailing: Switch(
                        value: s.enabled,
                        onChanged: (v) {
                          s.enabled = v;
                          store.saveSkills();
                        },
                      ),
                    ),
                ],
              ),
          ],
        );
      },
    );
  }
}

class SkillEditScreen extends StatefulWidget {
  const SkillEditScreen({super.key, required this.skill, this.isNew = false});

  final Skill skill;
  final bool isNew;

  @override
  State<SkillEditScreen> createState() => _SkillEditScreenState();
}

class _SkillEditScreenState extends State<SkillEditScreen> {
  late final Skill _s = widget.skill;
  late final TextEditingController _name = TextEditingController(text: _s.name);
  late final TextEditingController _desc = TextEditingController(text: _s.description);
  late final TextEditingController _instr = TextEditingController(text: _s.instructions);
  late final Set<String> _tools = _s.tools.toSet();
  late bool _auto = _s.autoUse;
  late bool _always = _s.alwaysOn;

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    _instr.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Give the skill a name')));
      return;
    }
    _s
      ..name = _name.text.trim()
      ..description = _desc.text.trim()
      ..instructions = _instr.text.trim()
      ..tools = _tools.toList()
      ..autoUse = _auto
      ..alwaysOn = _always;
    if (!store.skills.contains(_s)) store.skills.add(_s);
    await store.saveSkills();
    if (mounted) Navigator.pop(context);
  }

  Future<void> _delete() async {
    store.skills.remove(_s);
    for (final c in store.conversations) {
      c.activeSkillIds.remove(_s.id);
    }
    await store.saveSkills();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return GroupedPage(
      title: widget.isNew ? 'New skill' : _s.name,
      actions: [
        if (!widget.isNew) IconButton(tooltip: 'Delete', icon: const Icon(CupertinoIcons.trash), onPressed: _delete),
        TextButton(onPressed: _save, child: const Text('Save')),
      ],
      children: [
        Group(children: [
          FieldCell(controller: _name, label: 'Name'),
          FieldCell(
            controller: _desc,
            label: 'When to use it (the assistant reads this to decide)',
            lines: 2,
          ),
          if (_s.source.trim().isNotEmpty)
            Cell(title: 'Folder', subtitle: _s.source.trim(), icon: CupertinoIcons.folder),
        ]),
        Group(header: 'Instructions', children: [
          FieldCell(controller: _instr, label: 'What the assistant should do', lines: 8),
        ]),
        Group(header: 'Tools this skill may use', children: [
          for (final t in builtinTools.where((t) => t.id != 'current_time'))
            SwitchCell(
              title: t.title,
              subtitle: t.spec.name,
              value: _tools.contains(t.id),
              onChanged: (v) => setState(() {
                if (v) {
                  _tools.add(t.id);
                } else {
                  _tools.remove(t.id);
                }
              }),
            ),
        ]),
        Group(
          footer: _always
              ? 'Always active: the full instructions go to the assistant with every message in every conversation, '
                  'so this behaves like a fixed part of it instead of something it has to decide to use.'
              : 'Not always active: the assistant only sees the name and description unless it decides to load the '
                  'full instructions itself (if "load automatically" is on below) — which also switches this on '
                  'for good, from then on — or you switch it on in a chat (the bolt).',
          children: [
            SwitchCell(
              title: 'Always active',
              value: _always,
              onChanged: (v) => setState(() => _always = v),
            ),
            if (!_always)
              SwitchCell(
                title: 'Load automatically when it fits',
                value: _auto,
                onChanged: (v) => setState(() => _auto = v),
              ),
          ],
        ),
      ],
    );
  }
}
