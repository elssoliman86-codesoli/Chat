import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/models.dart';
import '../data/services.dart';
import 'skills_screen.dart';
import 'theme.dart';

Future<void> showSkillPicker(BuildContext context, Conversation c) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheet) => _SkillSheet(chat: c),
  );
}

class _SkillSheet extends StatefulWidget {
  const _SkillSheet({required this.chat});
  final Conversation chat;

  @override
  State<_SkillSheet> createState() => _SkillSheetState();
}

class _SkillSheetState extends State<_SkillSheet> {
  @override
  Widget build(BuildContext context) {
    final skills = store.skills.where((s) => s.enabled).toList();
    final folders = groupSkillsByFolder(skills);
    final pal = paletteOf(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
        child: ListView(shrinkWrap: true, children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Text('Skills for this chat', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('Switched-on skills are always followed. Others marked "auto" are loaded when they fit.',
                style: TextStyle(fontSize: 13, color: pal.secondary)),
          ),
          if (skills.isEmpty) const Padding(padding: EdgeInsets.all(20), child: Text('No skills yet.')),
          for (final folder in folders.keys) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 2),
              child: Text(folder, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: pal.secondary)),
            ),
            for (final s in folders[folder]!)
              SwitchListTile(
                title: Text(s.name),
                subtitle: Text(
                  s.alwaysOn ? 'Always active in every conversation · ${s.description}' : s.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                value: s.alwaysOn || widget.chat.activeSkillIds.contains(s.id),
                onChanged: (on) async {
                  setState(() {
                    s.alwaysOn = on;
                    widget.chat.activeSkillIds.remove(s.id);
                  });
                  await store.saveSkills();
                  store.scheduleSave(widget.chat);
                  store.changed();
                },
              ),
          ],
          ListTile(
            leading: const Icon(CupertinoIcons.slider_horizontal_3),
            title: const Text('Manage skills'),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(context, CupertinoPageRoute<void>(builder: (_) => const SkillsScreen()));
            },
          ),
        ]),
      ),
    );
  }
}
