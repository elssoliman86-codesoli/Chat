import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/models.dart';
import '../data/services.dart';
import 'kit.dart';
import 'model_list.dart';
import 'providers_screen.dart';

Future<void> showModelPicker(BuildContext context, Conversation c) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (sheet) {
      if (store.providers.isEmpty) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('No providers yet', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 14),
            PillButton(
              label: 'Add provider',
              filled: true,
              icon: CupertinoIcons.plus,
              onPressed: () {
                Navigator.pop(sheet);
                Navigator.push(context, CupertinoPageRoute<void>(builder: (_) => const ProvidersScreen()));
              },
            ),
          ]),
        );
      }
      return DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (context, scroll) => ModelList(
          providers: store.providers,
          controller: scroll,
          selectedProviderId: c.providerId,
          selectedModel: c.model,
          onPick: (p, m) {
            c.providerId = p.id;
            c.model = m;
            store.scheduleSave(c);
            store.changed();
            Navigator.pop(sheet);
          },
        ),
      );
    },
  );
}
