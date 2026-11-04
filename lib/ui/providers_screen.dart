import 'package:flutter/material.dart';

import '../core/models.dart';
import '../data/services.dart';
import '../llm/llm.dart';

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
              child: Text('Pick a provider', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
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
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => ProviderEditScreen(provider: p, isNew: true)));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Providers')),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _add(context),
          icon: const Icon(Icons.add_rounded),
          label: const Text('Add'),
        ),
        body: store.providers.isEmpty
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(28),
                  child: Text(
                    'No providers yet.\nTap Add, pick one and paste your own API key. Keys stay on this phone.',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : ListView(children: [
                for (final p in store.providers)
                  ListTile(
                    leading: Icon(store.defaultProvider?.id == p.id ? Icons.star_rounded : Icons.cloud_outlined),
                    title: Text(p.name),
                    subtitle: Text('${p.model.isEmpty ? 'no model' : p.model} · ${p.baseUrl}',
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: p.apiKey.isEmpty ? const Icon(Icons.key_off_outlined, size: 18) : null,
                    onTap: () => Navigator.push(
                        context, MaterialPageRoute<void>(builder: (_) => ProviderEditScreen(provider: p))),
                  ),
                const SizedBox(height: 90),
              ]),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isNew ? 'New provider' : _p.name),
        actions: [
          if (!widget.isNew && store.providers.contains(_p))
            IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline_rounded), onPressed: _delete),
          TextButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name')),
        const SizedBox(height: 14),
        SegmentedButton<ProviderKind>(
          segments: const [
            ButtonSegment(value: ProviderKind.openai, label: Text('OpenAI style')),
            ButtonSegment(value: ProviderKind.anthropic, label: Text('Anthropic')),
            ButtonSegment(value: ProviderKind.gemini, label: Text('Gemini')),
          ],
          selected: {_kind},
          onSelectionChanged: (s) => setState(() => _kind = s.first),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _url,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'Base URL', helperText: 'Example: https://api.openai.com/v1'),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _key,
          obscureText: !_showKey,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: 'API key',
            helperText: 'Stored only on this phone.',
            suffixIcon: IconButton(
              icon: Icon(_showKey ? Icons.visibility_off_outlined : Icons.visibility_outlined),
              onPressed: () => setState(() => _showKey = !_showKey),
            ),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _model,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'Default model'),
        ),
        const SizedBox(height: 10),
        Row(children: [
          OutlinedButton.icon(
            onPressed: _busy ? null : _fetch,
            icon: const Icon(Icons.download_rounded),
            label: const Text('Fetch models'),
          ),
          const SizedBox(width: 10),
          OutlinedButton.icon(
            onPressed: _busy ? null : _test,
            icon: const Icon(Icons.bolt_rounded),
            label: const Text('Test'),
          ),
        ]),
        if (_busy) const Padding(padding: EdgeInsets.only(top: 10), child: LinearProgressIndicator()),
        if (_status.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 10), child: SelectableText(_status)),
        if (_models.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text('${_models.length} models (tap to use)', style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 0, children: [
            for (final m in _models.take(60))
              ActionChip(label: Text(m, style: const TextStyle(fontSize: 12)), onPressed: () => setState(() => _model.text = m)),
          ]),
        ],
        const SizedBox(height: 10),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Send PDFs as files'),
          subtitle: const Text('Turn off if the provider rejects PDFs; the model is then told it cannot read them.'),
          value: _pdf,
          onChanged: (v) => setState(() => _pdf = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Supports tools'),
          subtitle: const Text('Web search, skills and memory. Turn off if you get errors about tools.'),
          value: _tools,
          onChanged: (v) => setState(() => _tools = v),
        ),
        TextField(
          controller: _tokens,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Max reply tokens'),
        ),
        const SizedBox(height: 40),
      ]),
    );
  }
}
