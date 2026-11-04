import 'package:flutter/material.dart';

import '../core/models.dart';
import '../data/services.dart';
import 'skills_screen.dart';

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
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
        child: ListView(shrinkWrap: true, children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Text('Skills for this chat', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('Switched-on skills are always followed. Others marked "auto" are loaded when they fit.',
                style: TextStyle(fontSize: 12)),
          ),
          if (skills.isEmpty) const Padding(padding: EdgeInsets.all(20), child: Text('No skills yet.')),
          for (final s in skills)
            SwitchListTile(
              title: Text(s.name),
              subtitle: Text(s.description, maxLines: 2, overflow: TextOverflow.ellipsis),
              value: widget.chat.activeSkillIds.contains(s.id),
              onChanged: (on) {
                setState(() {
                  if (on) {
                    widget.chat.activeSkillIds.add(s.id);
                  } else {
                    widget.chat.activeSkillIds.remove(s.id);
                  }
                });
                store.scheduleSave(widget.chat);
                store.changed();
              },
            ),
          ListTile(
            leading: const Icon(Icons.tune_rounded),
            title: const Text('Manage skills'),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const SkillsScreen()));
            },
          ),
        ]),
      ),
    );
  }
}
