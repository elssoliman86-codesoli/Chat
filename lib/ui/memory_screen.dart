import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/models.dart';
import '../data/services.dart';
import 'kit.dart';
import 'theme.dart';

class MemoryScreen extends StatelessWidget {
  const MemoryScreen({super.key});

  Future<void> _add(BuildContext context) async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Add to memory'),
        content: TextField(controller: controller, autofocus: true, maxLines: 3),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(d, controller.text), child: const Text('Add')),
        ],
      ),
    );
    controller.dispose();
    if (text != null) store.addMemory(text);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => GroupedPage(
        title: 'Memory',
        actions: [
          IconButton(icon: const Icon(CupertinoIcons.plus), onPressed: () => _add(context)),
          if (store.memory.isNotEmpty)
            IconButton(
              tooltip: 'Clear all',
              icon: const Icon(CupertinoIcons.trash),
              onPressed: () {
                store.memory.clear();
                store.saveMemory();
              },
            ),
        ],
        children: [
          if (store.memory.isEmpty)
            Padding(
              padding: const EdgeInsets.all(28),
              child: Text(
                'Nothing remembered yet.\nSay "remember that…" in a chat, or add facts with +. Temporary chats never use memory.',
                textAlign: TextAlign.center,
                style: TextStyle(color: paletteOf(context).secondary),
              ),
            )
          else
            Group(children: [
              for (final MemoryFact m in store.memory)
                Cell(
                  title: m.text,
                  trailing: IconButton(
                    icon: const Icon(CupertinoIcons.xmark_circle_fill, color: iosGray),
                    onPressed: () {
                      store.memory.remove(m);
                      store.saveMemory();
                    },
                  ),
                ),
            ]),
        ],
      ),
    );
  }
}
