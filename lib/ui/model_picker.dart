import 'package:flutter/material.dart';

import '../core/models.dart';
import '../data/services.dart';
import 'providers_screen.dart';

Future<void> showModelPicker(BuildContext context, Conversation c) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheet) => _ModelSheet(chat: c),
  );
}

class _ModelSheet extends StatefulWidget {
  const _ModelSheet({required this.chat});
  final Conversation chat;

  @override
  State<_ModelSheet> createState() => _ModelSheetState();
}

class _ModelSheetState extends State<_ModelSheet> {
  late String _providerId = widget.chat.providerId.isNotEmpty
      ? widget.chat.providerId
      : (store.defaultProvider?.id ?? '');

  void _choose(ProviderConfig p, String model) {
    widget.chat.providerId = p.id;
    widget.chat.model = model;
    store.scheduleSave(widget.chat);
    store.changed();
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final providers = store.providers;
    final current = store.providerById(_providerId);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.75),
        child: providers.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text('No providers yet.'),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () {
                      Navigator.pop(context);
                      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const ProvidersScreen()));
                    },
                    child: const Text('Add provider'),
                  ),
                ]),
              )
            : ListView(shrinkWrap: true, children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text('Provider', style: TextStyle(fontWeight: FontWeight.w600)),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(spacing: 8, runSpacing: 4, children: [
                    for (final p in providers)
                      ChoiceChip(
                        label: Text(p.name),
                        selected: p.id == _providerId,
                        onSelected: (_) => setState(() => _providerId = p.id),
                      ),
                  ]),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 16, 20, 4),
                  child: Text('Model', style: TextStyle(fontWeight: FontWeight.w600)),
                ),
                if (current != null) ...[
                  for (final m in <String>{
                    if (current.model.isNotEmpty) current.model,
                    ...current.models,
                  })
                    ListTile(
                      dense: true,
                      title: Text(m),
                      trailing: (current.id == widget.chat.providerId && m == widget.chat.model)
                          ? const Icon(Icons.check_rounded)
                          : null,
                      onTap: () => _choose(current, m),
                    ),
                  if (current.model.isEmpty && current.models.isEmpty)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(20, 4, 20, 12),
                      child: Text('No models yet. Open the provider and tap "Fetch models" or type one.'),
                    ),
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.tune_rounded),
                    title: Text('Edit ${current.name}'),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute<void>(builder: (_) => ProviderEditScreen(provider: current)),
                      );
                    },
                  ),
                ],
              ]),
      ),
    );
  }
}
