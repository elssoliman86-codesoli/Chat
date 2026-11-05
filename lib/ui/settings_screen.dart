import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../data/services.dart';
import 'kit.dart';
import 'plugins_screen.dart';
import 'theme.dart';

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
    final pal = paletteOf(context);
    return GroupedPage(title: 'Settings', children: [
      Group(header: 'Appearance', children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: SizedBox(
            width: double.infinity,
            child: CupertinoSlidingSegmentedControl<String>(
              groupValue: s.themeMode,
              children: const {
                'dark': Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Text('Dark')),
                'light': Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Text('Light')),
                'system': Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Text('System')),
                'emerald': Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Text('Emerald')),
              },
              onValueChanged: (v) => setState(() {
                s.themeMode = v ?? 'dark';
                _save();
              }),
            ),
          ),
        ),
      ]),
      Group(
        header: 'Personalization',
        footer: 'Sent with every chat. Example: "Answer briefly. I speak Arabic and English."',
        children: [
          FieldCell(
            controller: _instructions,
            label: 'Custom instructions',
            lines: 3,
            onChanged: (v) {
              s.customInstructions = v;
              _save();
            },
          ),
          SwitchCell(
            title: 'Memory',
            subtitle: 'Remember lasting facts you share',
            icon: CupertinoIcons.lightbulb,
            color: iosOrange,
            value: s.memoryEnabled,
            onChanged: (v) => setState(() {
              s.memoryEnabled = v;
              _save();
            }),
          ),
          Cell(
            title: 'Plugins',
            subtitle: 'Web search, browser, GitHub',
            icon: CupertinoIcons.square_grid_2x2,
            color: iosIndigo,
            chevron: true,
            onTap: () => Navigator.push(context, CupertinoPageRoute<void>(builder: (_) => const PluginsScreen())),
          ),
        ],
      ),
      if (store.providers.isNotEmpty)
        Group(header: 'Default provider', children: [
          for (final p in store.providers)
            Cell(
              title: p.name,
              subtitle: p.model.isEmpty ? null : p.model,
              onTap: () => setState(() {
                s.defaultProviderId = p.id;
                _save();
              }),
              trailing: store.defaultProvider?.id == p.id
                  ? Icon(CupertinoIcons.checkmark_alt, color: pal.accent, size: 22)
                  : null,
            ),
        ]),
      Group(header: 'Model', children: [
        SwitchCell(
          title: 'Custom temperature',
          subtitle: s.temperature == null ? 'Provider default' : s.temperature!.toStringAsFixed(1),
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
      ]),
      Group(header: 'Limits', children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text('Files per message: ${s.maxAttachments}', style: const TextStyle(fontSize: 16.5)),
        ),
        Slider(
          value: s.maxAttachments.toDouble(),
          min: 1,
          max: 50,
          divisions: 49,
          label: '${s.maxAttachments}',
          onChanged: (v) => setState(() => s.maxAttachments = v.round()),
          onChangeEnd: (_) => _save(),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Text('Tool steps per reply: ${s.maxToolSteps}', style: const TextStyle(fontSize: 16.5)),
        ),
        Slider(
          value: s.maxToolSteps.toDouble(),
          min: 1,
          max: 100,
          divisions: 99,
          label: '${s.maxToolSteps}',
          onChanged: (v) => setState(() => s.maxToolSteps = v.round()),
          onChangeEnd: (_) => _save(),
        ),
      ]),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          'Your keys and chats stay on this phone. Each message goes straight to the provider you chose.',
          style: TextStyle(fontSize: 13, color: pal.secondary),
        ),
      ),
    ]);
  }
}
