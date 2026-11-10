import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/models.dart';
import '../data/services.dart';
import 'kit.dart';
import 'theme.dart';

/// Operational lessons the model has recorded about itself — not facts about the user (that is
/// MemoryScreen). Kept on this phone and fed into every future chat under any model, so a mistake
/// fixed once, or a correction given once, is not lost when a new conversation or a new model starts.
class LessonsScreen extends StatelessWidget {
  const LessonsScreen({super.key});

  Future<void> _add(BuildContext context) async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Add a lesson'),
        content: TextField(controller: controller, autofocus: true, maxLines: 3),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(d, controller.text), child: const Text('Add')),
        ],
      ),
    );
    controller.dispose();
    if (text != null) store.addLesson(text);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => GroupedPage(
        title: 'Lessons',
        actions: [
          IconButton(icon: const Icon(CupertinoIcons.plus), onPressed: () => _add(context)),
          if (store.lessons.isNotEmpty)
            IconButton(
              tooltip: 'Clear all',
              icon: const Icon(CupertinoIcons.trash),
              onPressed: () {
                store.lessons.clear();
                store.saveLessons();
              },
            ),
        ],
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 14),
            child: Text(
              store.lessons.isEmpty
                  ? 'Nothing learned yet. These are operational lessons the assistant records about itself — a mistake '
                      'and its real fix, a constraint of this app or a device it discovered, an approach that worked, a '
                      'correction you gave about how it should work — not facts about you (see Memory for those). It saves '
                      'these on its own as it works, and every one here is fed into every future chat, under any model, '
                      'until you remove it.'
                  : 'Operational lessons the assistant has learned, sent with every future chat (never a temporary one), '
                      'regardless of which model answers it. Remove one with the X.',
              style: TextStyle(fontSize: 13.5, color: paletteOf(context).secondary),
            ),
          ),
          if (store.lessons.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: Icon(CupertinoIcons.graph_circle, size: 36, color: paletteOf(context).secondary.withValues(alpha: 0.5)),
              ),
            )
          else
            Group(children: [
              for (final MemoryFact m in store.lessons)
                Cell(
                  title: m.text,
                  trailing: IconButton(
                    icon: const Icon(CupertinoIcons.xmark_circle_fill, color: iosGray),
                    onPressed: () {
                      store.lessons.remove(m);
                      store.saveLessons();
                    },
                  ),
                ),
            ]),
        ],
      ),
    );
  }
}
