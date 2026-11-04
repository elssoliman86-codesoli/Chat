import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/models.dart';
import '../data/services.dart';
import 'browser_screen.dart';
import 'memory_screen.dart';
import 'plugins_screen.dart';
import 'providers_screen.dart';
import 'settings_screen.dart';
import 'skills_screen.dart';
import 'theme.dart';

class HistoryDrawer extends StatefulWidget {
  const HistoryDrawer({super.key, required this.onNewChat});

  final VoidCallback onNewChat;

  @override
  State<HistoryDrawer> createState() => _HistoryDrawerState();
}

class _HistoryDrawerState extends State<HistoryDrawer> {
  String _query = '';

  void _open(Widget screen, {bool full = false}) {
    Navigator.pop(context);
    Navigator.push(context, CupertinoPageRoute<void>(fullscreenDialog: full, builder: (_) => screen));
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
          TextButton(onPressed: () => Navigator.pop(d, controller.text.trim()), child: const Text('Save')),
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

  String _bucket(Conversation c) {
    final now = DateTime.now();
    final day = DateTime(now.year, now.month, now.day);
    final t = DateTime.fromMillisecondsSinceEpoch(c.updatedAt);
    final d = DateTime(t.year, t.month, t.day);
    final diff = day.difference(d).inDays;
    if (diff <= 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    if (diff <= 7) return 'Previous 7 days';
    if (diff <= 30) return 'Previous 30 days';
    return 'Older';
  }

  @override
  Widget build(BuildContext context) {
    final pal = paletteOf(context);
    final q = _query.trim().toLowerCase();
    final list = store.conversations.where((c) {
      if (q.isEmpty) return true;
      if (c.title.toLowerCase().contains(q)) return true;
      return c.messages.any((m) => m.role != 'tool' && m.text.toLowerCase().contains(q));
    }).toList();
    final rows = <Object>[];
    String? last;
    for (final c in list) {
      final b = _bucket(c);
      if (b != last) {
        rows.add(b);
        last = b;
      }
      rows.add(c);
    }
    return Drawer(
      child: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
            child: TextField(
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: 'Search',
                isDense: true,
                filled: true,
                fillColor: pal.bubble,
                prefixIcon: const Icon(CupertinoIcons.search, size: 18),
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
          _nav(CupertinoIcons.square_pencil, 'New chat', () {
            Navigator.pop(context);
            widget.onNewChat();
          }),
          _nav(CupertinoIcons.bolt, 'Skills', () => _open(const SkillsScreen())),
          _nav(CupertinoIcons.square_grid_2x2, 'Plugins', () => _open(const PluginsScreen())),
          _nav(CupertinoIcons.compass, 'Browser', () => _open(const BrowserScreen(), full: true)),
          const SizedBox(height: 6),
          Expanded(
            child: rows.isEmpty
                ? Center(child: Text(q.isEmpty ? 'No chats yet' : 'Nothing found', style: TextStyle(color: pal.secondary)))
                : ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (context, i) {
                      final r = rows[i];
                      if (r is String) {
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
                          child: Text(r, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: pal.secondary)),
                        );
                      }
                      final c = r as Conversation;
                      final selected = identical(store.current, c);
                      return Dismissible(
                        key: ValueKey(c.id),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          color: iosRed,
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20),
                          child: const Icon(CupertinoIcons.trash, color: Colors.white),
                        ),
                        onDismissed: (_) => store.deleteConversation(c),
                        child: InkWell(
                          onTap: () {
                            Navigator.pop(context);
                            if (engine.busy) engine.stop();
                            store.openConversation(c);
                          },
                          onLongPress: () => _rename(c),
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 8),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                            decoration: BoxDecoration(
                              color: selected ? pal.bubble : Colors.transparent,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16)),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          Divider(height: 0.5, color: pal.separator),
          _nav(CupertinoIcons.cloud, 'Providers', () => _open(const ProvidersScreen())),
          _nav(CupertinoIcons.lightbulb, 'Memory', () => _open(const MemoryScreen())),
          _nav(CupertinoIcons.gear, 'Settings', () => _open(const SettingsScreen())),
          const SizedBox(height: 6),
        ]),
      ),
    );
  }

  Widget _nav(IconData icon, String title, VoidCallback tap) {
    return InkWell(
      onTap: tap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
        child: Row(children: [
          Icon(icon, size: 21),
          const SizedBox(width: 14),
          Text(title, style: const TextStyle(fontSize: 16.5)),
        ]),
      ),
    );
  }
}
