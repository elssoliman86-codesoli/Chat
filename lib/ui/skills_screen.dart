import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';

import '../core/models.dart';
import '../core/skill_import.dart';
import '../data/services.dart';
import '../tools/tools.dart';

class SkillsScreen extends StatelessWidget {
  const SkillsScreen({super.key});

  void _edit(BuildContext context, Skill skill, {bool isNew = false}) {
    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => SkillEditScreen(skill: skill, isNew: isNew)));
  }

  Future<void> _import(BuildContext context) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.content_paste_rounded),
            title: const Text('Paste SKILL.md text'),
            onTap: () => Navigator.pop(sheet, 'paste'),
          ),
          ListTile(
            leading: const Icon(Icons.file_open_outlined),
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
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Skills'), actions: [
          IconButton(tooltip: 'Import', icon: const Icon(Icons.download_rounded), onPressed: () => _import(context)),
        ]),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _edit(context, Skill(id: newId(), name: ''), isNew: true),
          icon: const Icon(Icons.add_rounded),
          label: const Text('New skill'),
        ),
        body: ListView(children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text(
              'A skill is a set of instructions plus the tools it may use. '
              'Switch one on inside a chat (⚡), or let the assistant load it by itself when it fits.',
              style: TextStyle(fontSize: 13),
            ),
          ),
          for (final s in store.skills)
            ListTile(
              title: Text(s.name),
              subtitle: Text(
                '${s.description}${s.tools.isEmpty ? '' : '\nTools: ${s.tools.join(', ')}'}',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              isThreeLine: s.tools.isNotEmpty,
              trailing: Switch(
                value: s.enabled,
                onChanged: (v) {
                  s.enabled = v;
                  store.saveSkills();
                },
              ),
              onTap: () => _edit(context, s),
            ),
          const SizedBox(height: 90),
        ]),
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
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isNew ? 'New skill' : _s.name),
        actions: [
          if (!widget.isNew)
            IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline_rounded), onPressed: _delete),
          TextButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name')),
        const SizedBox(height: 14),
        TextField(
          controller: _desc,
          maxLines: 2,
          decoration: const InputDecoration(
            labelText: 'When to use it',
            helperText: 'One line. The assistant reads this to decide whether to load the skill.',
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _instr,
          minLines: 8,
          maxLines: 20,
          decoration: const InputDecoration(labelText: 'Instructions', alignLabelWithHint: true),
        ),
        const SizedBox(height: 14),
        const Text('Tools this skill may use', style: TextStyle(fontWeight: FontWeight.w600)),
        for (final t in builtinTools.where((t) => t.id != 'current_time'))
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t.title),
            subtitle: Text(t.spec.name),
            value: _tools.contains(t.id),
            onChanged: (v) => setState(() {
              if (v == true) {
                _tools.add(t.id);
              } else {
                _tools.remove(t.id);
              }
            }),
          ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Let the assistant load it automatically'),
          value: _auto,
          onChanged: (v) => setState(() => _auto = v),
        ),
        const SizedBox(height: 40),
      ]),
    );
  }
}
