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
      builder: (context, _) => GroupedPage(
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
              'A skill is a set of instructions plus the tools it may use. '
              'Switch one on inside a chat (the bolt), or let the assistant load it by itself when it fits.',
              style: TextStyle(fontSize: 13.5, color: paletteOf(context).secondary),
            ),
          ),
          Group(children: [
            for (final s in store.skills)
              Cell(
                title: s.name,
                subtitle: '${s.description}${s.tools.isEmpty ? '' : '\nTools: ${s.tools.join(', ')}'}',
                onTap: () => _edit(context, s),
                trailing: Switch(
                  value: s.enabled,
                  onChanged: (v) {
                    s.enabled = v;
                    store.saveSkills();
                  },
                ),
              ),
          ]),
        ],
      ),
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
      ..autoUse = _auto;
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
        Group(children: [
          SwitchCell(
            title: 'Load automatically when it fits',
            value: _auto,
            onChanged: (v) => setState(() => _auto = v),
          ),
        ]),
      ],
    );
  }
}
