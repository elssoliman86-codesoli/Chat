import 'package:flutter/material.dart';

import '../data/services.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _instructions =
      TextEditingController(text: store.settings.customInstructions);

  @override
  void dispose() {
    _instructions.dispose();
    super.dispose();
  }

  void _save() => store.saveSettings();

  @override
  Widget build(BuildContext context) {
    final s = store.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('Theme', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'dark', label: Text('Dark')),
            ButtonSegment(value: 'light', label: Text('Light')),
            ButtonSegment(value: 'system', label: Text('System')),
          ],
          selected: {s.themeMode},
          onSelectionChanged: (v) => setState(() {
            s.themeMode = v.first;
            _save();
          }),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _instructions,
          minLines: 3,
          maxLines: 8,
          onChanged: (v) {
            s.customInstructions = v;
            _save();
          },
          decoration: const InputDecoration(
            labelText: 'Custom instructions',
            helperText: 'Sent with every chat. Example: "Answer briefly. I speak Arabic and English."',
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: 12),
        if (store.providers.isNotEmpty) ...[
          const Text('Default provider', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Wrap(spacing: 8, children: [
            for (final p in store.providers)
              ChoiceChip(
                label: Text(p.name),
                selected: store.defaultProvider?.id == p.id,
                onSelected: (_) => setState(() {
                  s.defaultProviderId = p.id;
                  _save();
                }),
              ),
          ]),
          const SizedBox(height: 12),
        ],
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Web search and page reading'),
          subtitle: const Text('Lets the assistant look things up (needs a model with tool support).'),
          value: s.webTools,
          onChanged: (v) => setState(() {
            s.webTools = v;
            _save();
          }),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Memory'),
          subtitle: const Text('Remember lasting facts you share.'),
          value: s.memoryEnabled,
          onChanged: (v) => setState(() {
            s.memoryEnabled = v;
            _save();
          }),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Custom temperature'),
          subtitle: Text(s.temperature == null ? 'Provider default' : s.temperature!.toStringAsFixed(1)),
          value: s.temperature != null,
          onChanged: (v) => setState(() {
            s.temperature = v ? 0.7 : null;
            _save();
          }),
        ),
        if (s.temperature != null)
          Slider(
            value: s.temperature!,
            min: 0,
            max: 2,
            divisions: 20,
            label: s.temperature!.toStringAsFixed(1),
            onChanged: (v) => setState(() => s.temperature = v),
            onChangeEnd: (_) => _save(),
          ),
        const SizedBox(height: 8),
        Text('Files per message: ${s.maxAttachments}', style: const TextStyle(fontWeight: FontWeight.w600)),
        Slider(
          value: s.maxAttachments.toDouble(),
          min: 1,
          max: 50,
          divisions: 49,
          label: '${s.maxAttachments}',
          onChanged: (v) => setState(() => s.maxAttachments = v.round()),
          onChangeEnd: (_) => _save(),
        ),
        Text('Tool steps per reply: ${s.maxToolSteps}', style: const TextStyle(fontWeight: FontWeight.w600)),
        Slider(
          value: s.maxToolSteps.toDouble(),
          min: 1,
          max: 20,
          divisions: 19,
          label: '${s.maxToolSteps}',
          onChanged: (v) => setState(() => s.maxToolSteps = v.round()),
          onChangeEnd: (_) => _save(),
        ),
        const SizedBox(height: 12),
        const Text(
          'Your keys and chats stay on this phone. Each message goes straight to the provider you chose.',
          style: TextStyle(fontSize: 12),
        ),
      ]),
    );
  }
}
