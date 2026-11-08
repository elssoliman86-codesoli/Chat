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
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 14),
            child: Text(
              store.memory.isEmpty
                  ? 'Nothing remembered yet. These are lasting facts about you (your name, job, preferences) — not '
                      'the current chat or project, which the assistant already keeps in context on its own. Say '
                      '"remember that…" in any chat and the assistant may save one, or add one yourself with +. Every '
                      'fact here is sent with every future chat (never a temporary one) until you remove it.'
                  : 'Lasting facts about you, sent with every future chat (never a temporary one). Remove one with the '
                      'X, or say "forget that…" in a chat.',
              style: TextStyle(fontSize: 13.5, color: paletteOf(context).secondary),
            ),
          ),
          if (store.memory.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: Icon(CupertinoIcons.lightbulb, size: 36, color: paletteOf(context).secondary.withValues(alpha: 0.5)),
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
