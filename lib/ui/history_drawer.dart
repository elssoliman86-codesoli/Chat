import 'package:flutter/material.dart';

import '../core/models.dart';
import '../data/services.dart';
import 'memory_screen.dart';
import 'providers_screen.dart';
import 'settings_screen.dart';
import 'skills_screen.dart';

class HistoryDrawer extends StatefulWidget {
  const HistoryDrawer({super.key, required this.onNewChat});

  final VoidCallback onNewChat;

  @override
  State<HistoryDrawer> createState() => _HistoryDrawerState();
}

class _HistoryDrawerState extends State<HistoryDrawer> {
  String _query = '';

  void _open(Widget screen) {
    Navigator.pop(context);
    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => screen));
  }

  Future<void> _rename(Conversation c) async {
    final controller = TextEditingController(text: c.title);
    final name = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Rename chat'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(d, controller.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (name != null && name.isNotEmpty) {
      c.title = name;
      store.scheduleSave(c);
      store.changed();
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final list = store.conversations.where((c) {
      if (q.isEmpty) return true;
      if (c.title.toLowerCase().contains(q)) return true;
      return c.messages.any((m) => m.role != 'tool' && m.text.toLowerCase().contains(q));
    }).toList();
    return Drawer(
      child: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: TextField(
              onChanged: (v) => setState(() => _query = v),
              decoration: const InputDecoration(
                hintText: 'Search chats',
                prefixIcon: Icon(Icons.search_rounded),
                isDense: true,
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('New chat'),
            onTap: () {
              Navigator.pop(context);
              widget.onNewChat();
            },
          ),
          const Divider(height: 1),
          Expanded(
            child: list.isEmpty
                ? Center(child: Text(q.isEmpty ? 'No chats yet' : 'Nothing found', style: TextStyle(color: Theme.of(context).hintColor)))
                : ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (context, i) {
                      final c = list[i];
                      return Dismissible(
                        key: ValueKey(c.id),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          color: Theme.of(context).colorScheme.error,
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20),
                          child: const Icon(Icons.delete_outline_rounded, color: Colors.white),
                        ),
                        onDismissed: (_) => store.deleteConversation(c),
                        child: ListTile(
                          selected: identical(store.current, c),
                          title: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: c.model.isEmpty ? null : Text(c.model, maxLines: 1, overflow: TextOverflow.ellipsis),
                          onTap: () {
                            Navigator.pop(context);
                            if (engine.busy) engine.stop();
                            store.openConversation(c);
                          },
                          onLongPress: () => _rename(c),
                        ),
                      );
                    },
                  ),
          ),
          const Divider(height: 1),
          ListTile(
            dense: true,
            leading: const Icon(Icons.cloud_outlined),
            title: const Text('Providers'),
            onTap: () => _open(const ProvidersScreen()),
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.bolt_rounded),
            title: const Text('Skills'),
            onTap: () => _open(const SkillsScreen()),
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.psychology_alt_outlined),
            title: const Text('Memory'),
            onTap: () => _open(const MemoryScreen()),
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.settings_outlined),
            title: const Text('Settings'),
            onTap: () => _open(const SettingsScreen()),
          ),
        ]),
      ),
    );
  }
}
