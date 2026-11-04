import 'package:flutter/material.dart';

import '../core/models.dart';
import '../data/services.dart';

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
          FilledButton(onPressed: () => Navigator.pop(d, controller.text), child: const Text('Add')),
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
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Memory'), actions: [
          if (store.memory.isNotEmpty)
            IconButton(
              tooltip: 'Clear all',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: () {
                store.memory.clear();
                store.saveMemory();
              },
            ),
        ]),
        floatingActionButton: FloatingActionButton(
          onPressed: () => _add(context),
          child: const Icon(Icons.add_rounded),
        ),
        body: store.memory.isEmpty
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(28),
                  child: Text(
                    'Nothing remembered yet.\nSay "remember that…" in a chat, or add facts here. Temporary chats never use memory.',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : ListView(children: [
                for (final MemoryFact m in store.memory)
                  ListTile(
                    title: Text(m.text),
                    trailing: IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () {
                        store.memory.remove(m);
                        store.saveMemory();
                      },
                    ),
                  ),
              ]),
      ),
    );
  }
}
