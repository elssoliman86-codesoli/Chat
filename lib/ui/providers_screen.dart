import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/models.dart';
import '../data/services.dart';
import '../llm/llm.dart';
import 'kit.dart';
import 'model_list.dart';
import 'theme.dart';

class ProvidersScreen extends StatelessWidget {
  const ProvidersScreen({super.key});

  Future<void> _add(BuildContext context) async {
    final preset = await showModalBottomSheet<ProviderPreset>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(sheet).size.height * 0.8),
          child: ListView(shrinkWrap: true, children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('Pick a provider', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18)),
            ),
            for (final p in providerPresets)
              ListTile(
                title: Text(p.name),
                subtitle: Text(p.note.isEmpty ? p.baseUrl : '${p.note}\n${p.baseUrl}'),
                isThreeLine: p.note.isNotEmpty,
                onTap: () => Navigator.pop(sheet, p),
              ),
          ]),
        ),
      ),
    );
    if (preset == null || !context.mounted) return;
    final p = ProviderConfig(
      id: newId(),
      name: preset.name,
      kind: preset.kind,
      baseUrl: preset.baseUrl,
      model: preset.model,
      pdfNative: preset.pdfNative,
    );
    await Navigator.push(context, CupertinoPageRoute<void>(builder: (_) => ProviderEditScreen(provider: p, isNew: true)));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => GroupedPage(
        title: 'Providers',
        actions: [IconButton(icon: const Icon(CupertinoIcons.plus), onPressed: () => _add(context))],
        children: [
          if (store.providers.isEmpty)
            Padding(
              padding: const EdgeInsets.all(28),
              child: Text(
                'No providers yet.\nTap + , pick one and paste your own API key. Keys stay on this phone.',
                textAlign: TextAlign.center,
                style: TextStyle(color: paletteOf(context).secondary),
              ),
            )
          else
            Group(children: [
              for (final p in store.providers)
                Cell(
                  title: p.name,
                  subtitle: '${p.model.isEmpty ? 'no model' : shortModelName(p.model)} · ${p.models.length} models',
                  icon: CupertinoIcons.cloud_fill,
                  color: p.apiKey.isEmpty && !p.baseUrl.startsWith('http://') ? iosOrange : null,
                  chevron: true,
                  trailing: store.defaultProvider?.id == p.id
                      ? const Padding(padding: EdgeInsets.only(right: 6), child: Icon(CupertinoIcons.star_fill, size: 16, color: iosOrange))
                      : null,
                  onTap: () => Navigator.push(
                      context, CupertinoPageRoute<void>(builder: (_) => ProviderEditScreen(provider: p))),
                ),
            ]),
        ],
      ),
    );
  }
}

class ProviderEditScreen extends StatefulWidget {
  const ProviderEditScreen({super.key, required this.provider, this.isNew = false});

  final ProviderConfig provider;
  final bool isNew;

  @override
  State<ProviderEditScreen> createState() => _ProviderEditScreenState();
}

class _ProviderEditScreenState extends State<ProviderEditScreen> {
  late final ProviderConfig _p = widget.provider;
  late final TextEditingController _name = TextEditingController(text: _p.name);
  late final TextEditingController _url = TextEditingController(text: _p.baseUrl);
  late final TextEditingController _key = TextEditingController(text: _p.apiKey);
  late final TextEditingController _model = TextEditingController(text: _p.model);
  late final TextEditingController _tokens = TextEditingController(text: '${_p.maxTokens}');
  late ProviderKind _kind = _p.kind;
  late bool _pdf = _p.pdfNative;
  late bool _tools = _p.supportsTools;
  late List<String> _models = List<String>.of(_p.models);
  bool _showKey = false;
  bool _busy = false;
  String _status = '';

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _key.dispose();
    _model.dispose();
    _tokens.dispose();
    super.dispose();
  }

  ProviderConfig _draft() => ProviderConfig(
        id: _p.id,
        name: _name.text.trim().isEmpty ? 'Provider' : _name.text.trim(),
        kind: _kind,
        baseUrl: _url.text.trim(),
        apiKey: _key.text.trim(),
        models: _models,
        model: _model.text.trim(),
        pdfNative: _pdf,
        supportsTools: _tools,
        maxTokens: int.tryParse(_tokens.text.trim()) ?? 8192,
      );

  Future<void> _fetch() async {
    setState(() {
      _busy = true;
      _status = 'Fetching models…';
    });
    try {
      final list = await createClient(_draft()).listModels();
      if (!mounted) return;
      setState(() {
        _models = list;
        _status = list.isEmpty ? 'The provider returned no models.' : '${list.length} models found.';
        if (_model.text.trim().isEmpty && list.isNotEmpty) _model.text = list.first;
      });
    } catch (e) {
      if (mounted) setState(() => _status = 'Could not fetch models: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _test() async {
    final d = _draft();
    if (d.model.isEmpty) {
      setState(() => _status = 'Type or pick a model first.');
      return;
    }
    setState(() {
      _busy = true;
      _status = 'Testing…';
    });
    final abort = AbortHandle();
    try {
      final out = StringBuffer();
      final request = LlmRequest(
        system: 'Reply with the single word OK.',
        messages: [ChatMessage(role: 'user', text: 'Test')],
        model: d.model,
      );
      await for (final e in createClient(d).stream(request, abort)) {
        if (e is TextDelta) out.write(e.text);
        if (out.length > 40) break;
      }
      if (mounted) setState(() => _status = 'Works. Reply: ${out.toString().trim()}');
    } catch (e) {
      if (mounted) setState(() => _status = 'Failed: $e');
    } finally {
      abort.abort();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final d = _draft();
    _p
      ..name = d.name
      ..kind = d.kind
      ..baseUrl = d.baseUrl
      ..apiKey = d.apiKey
      ..models = d.models
      ..model = d.model
      ..pdfNative = d.pdfNative
      ..supportsTools = d.supportsTools
      ..maxTokens = d.maxTokens;
    if (!store.providers.contains(_p)) {
      store.providers.add(_p);
      if (store.settings.defaultProviderId.isEmpty) {
        store.settings.defaultProviderId = _p.id;
        await store.saveSettings();
      }
    }
    await store.saveProviders();
    final chat = store.current;
    if (chat != null && chat.messages.isEmpty && (chat.providerId.isEmpty || chat.providerId == _p.id)) {
      chat.providerId = _p.id;
      if (chat.model.isEmpty || chat.providerId == _p.id) chat.model = _p.model;
      store.changed();
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Delete ${_p.name}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    store.providers.remove(_p);
    if (store.settings.defaultProviderId == _p.id) {
      store.settings.defaultProviderId = store.providers.isEmpty ? '' : store.providers.first.id;
      await store.saveSettings();
    }
    await store.saveProviders();
    if (mounted) Navigator.pop(context);
  }

  Future<void> _chooseModel() async {
    final all = <String>{if (_model.text.trim().isNotEmpty) _model.text.trim(), ..._models}.toList();
    final temp = _draft()
      ..models = all
      ..health = _p.health
      ..noVision = _p.noVision;
    final picked = await Navigator.push<String>(
      context,
      CupertinoPageRoute<String>(builder: (_) => ModelListPage(provider: temp, selected: _model.text.trim())),
    );
    if (picked != null) setState(() => _model.text = picked);
  }

  @override
  Widget build(BuildContext context) {
    final pal = paletteOf(context);
    return GroupedPage(
      title: widget.isNew ? 'New provider' : _p.name,
      actions: [
        if (!widget.isNew && store.providers.contains(_p))
          IconButton(tooltip: 'Delete', icon: const Icon(CupertinoIcons.trash), onPressed: _delete),
        TextButton(onPressed: _save, child: const Text('Save')),
      ],
      children: [
        Group(children: [
          FieldCell(controller: _name, label: 'Name'),
          Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              width: double.infinity,
              child: CupertinoSlidingSegmentedControl<ProviderKind>(
                groupValue: _kind,
                children: const {
                  ProviderKind.openai: Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Text('OpenAI style')),
                  ProviderKind.anthropic: Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Text('Anthropic')),
                  ProviderKind.gemini: Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Text('Gemini')),
                },
                onValueChanged: (v) => setState(() => _kind = v ?? _kind),
              ),
            ),
          ),
          FieldCell(
            controller: _url,
            label: 'Base URL',
            keyboard: TextInputType.url,
            hint: 'https://api.openai.com/v1',
          ),
          FieldCell(
            controller: _key,
            label: 'API key (stored only on this phone)',
            obscure: !_showKey,
            suffix: IconButton(
              icon: Icon(_showKey ? CupertinoIcons.eye_slash : CupertinoIcons.eye, size: 20),
              onPressed: () => setState(() => _showKey = !_showKey),
            ),
          ),
        ]),
        Group(header: 'Model', children: [
          FieldCell(controller: _model, label: 'Default model'),
          Cell(
            title: _models.isEmpty ? 'Fetch models from the provider' : 'Choose from ${_models.length} models',
            icon: _models.isEmpty ? CupertinoIcons.arrow_down_circle : CupertinoIcons.list_bullet,
            chevron: _models.isNotEmpty,
            onTap: _busy ? null : (_models.isEmpty ? _fetch : _chooseModel),
          ),
          if (_models.isNotEmpty)
            Cell(
              title: 'Refresh model list',
              icon: CupertinoIcons.arrow_clockwise,
              color: iosGray,
              onTap: _busy ? null : _fetch,
            ),
          Cell(
            title: 'Test connection',
            icon: CupertinoIcons.bolt_fill,
            color: iosGreen,
            onTap: _busy ? null : _test,
          ),
        ]),
        if (_busy) const Padding(padding: EdgeInsets.only(bottom: 12), child: LinearProgressIndicator()),
        if (_status.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 18),
            child: SelectableText(_status, style: TextStyle(fontSize: 13.5, color: pal.secondary)),
          ),
        Group(header: 'Capabilities', footer: 'Turn these off if the provider returns errors about PDFs or tools.', children: [
          SwitchCell(title: 'Send PDFs as files', value: _pdf, onChanged: (v) => setState(() => _pdf = v)),
          SwitchCell(title: 'Supports tools', subtitle: 'Web search, skills, memory, GitHub', value: _tools, onChanged: (v) => setState(() => _tools = v)),
          FieldCell(controller: _tokens, label: 'Max reply tokens', keyboard: TextInputType.number),
        ]),
        if (_p.noVision.isNotEmpty)
          Group(
            header: 'Text-only models',
            footer: 'These models rejected images, so photos are replaced by a note when you use them.',
            children: [
              for (final m in _p.noVision)
                Cell(
                  title: shortModelName(m),
                  trailing: IconButton(
                    icon: const Icon(CupertinoIcons.xmark_circle_fill, color: iosGray),
                    onPressed: () => setState(() => _p.noVision.remove(m)),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}
