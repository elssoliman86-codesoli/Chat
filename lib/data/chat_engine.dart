import 'dart:async';

import '../core/models.dart';
import '../llm/llm.dart';
import '../tools/tools.dart';
import 'app_store.dart';

/// Runs a conversation turn: builds the prompt, streams the answer, runs tools and repeats.
class ChatEngine implements ToolHost {
  ChatEngine(this.store);

  final AppStore store;
  AbortHandle? _abort;
  Timer? _notifyTimer;
  Conversation? _running;
  final Set<String> _loadedSkills = <String>{};

  bool get busy => _running != null;
  Conversation? get running => _running;

  // ToolHost
  @override
  List<Skill> get skills => store.skills;

  @override
  void addMemory(String text) => store.addMemory(text);

  @override
  void loadSkill(Skill skill) => _loadedSkills.add(skill.id);

  @override
  bool get memoryAllowed => store.settings.memoryEnabled && !(_running?.temporary ?? false);

  void _notifySoon() {
    if (_notifyTimer?.isActive ?? false) return;
    _notifyTimer = Timer(const Duration(milliseconds: 60), store.changed);
  }

  String buildSystem(Conversation c) {
    final s = store.settings;
    final b = StringBuffer();
    b.writeln('You are a helpful assistant inside a personal chat app on an Android phone. '
        'Reply in the language the user writes in. Use Markdown. Be accurate and say when you are not sure.');
    b.writeln('Current local time: ${DateTime.now().toIso8601String()}');
    if (s.customInstructions.trim().isNotEmpty) {
      b.writeln('\nInstructions from the user:\n${s.customInstructions.trim()}');
    }
    if (s.memoryEnabled && !c.temporary && store.memory.isNotEmpty) {
      b.writeln('\nThings you know about the user:');
      for (final m in store.memory) {
        b.writeln('- ${m.text}');
      }
    }
    final active = _activeSkills(c);
    for (final sk in active) {
      b.writeln('\n## Skill: ${sk.name}\n${sk.instructions}');
    }
    final auto = store.skills.where((k) => k.enabled && k.autoUse && !active.contains(k)).toList();
    if (auto.isNotEmpty) {
      b.writeln('\nSkills you can load with the use_skill tool when one fits the request:');
      for (final k in auto) {
        b.writeln('- ${k.name}: ${k.description}');
      }
    }
    return b.toString();
  }

  List<Skill> _activeSkills(Conversation c) =>
      store.skills.where((k) => k.enabled && (c.activeSkillIds.contains(k.id) || _loadedSkills.contains(k.id))).toList();

  List<ToolSpec> buildTools(Conversation c, ProviderConfig provider) {
    if (!provider.supportsTools) return const <ToolSpec>[];
    final ids = <String>{'current_time'};
    if (store.settings.webTools) ids.addAll(<String>['web_search', 'fetch_page']);
    if (store.settings.memoryEnabled && !c.temporary) ids.add('remember');
    for (final k in _activeSkills(c)) {
      ids.addAll(k.tools);
    }
    final specs = <ToolSpec>[];
    for (final id in ids) {
      final def = toolById(id);
      if (def != null) specs.add(def.spec);
    }
    final hasAuto = store.skills.any((k) => k.enabled && k.autoUse);
    if (hasAuto) specs.add(useSkillSpec);
    return specs;
  }

  Future<void> send(Conversation c, String text, List<Attachment> attachments) async {
    if (busy) return;
    final clean = text.trim();
    if (clean.isEmpty && attachments.isEmpty) return;
    c.messages.add(ChatMessage(role: 'user', text: clean, attachments: List<Attachment>.of(attachments)));
    if (c.title == 'New chat') {
      final basis = clean.isNotEmpty ? clean : attachments.first.name;
      final oneLine = basis.replaceAll(RegExp(r'\s+'), ' ');
      c.title = oneLine.length > 42 ? '${oneLine.substring(0, 42)}…' : oneLine;
    }
    store.scheduleSave(c);
    store.changed();
    await _run(c);
  }

  Future<void> regenerate(Conversation c) async {
    if (busy) return;
    var last = -1;
    for (var i = 0; i < c.messages.length; i++) {
      if (c.messages[i].role == 'user') last = i;
    }
    if (last < 0) return;
    c.messages.removeRange(last + 1, c.messages.length);
    store.scheduleSave(c);
    store.changed();
    await _run(c);
  }

  /// Removes [messageId] and everything after it. Returns the removed user message.
  ChatMessage? truncateFrom(Conversation c, String messageId) {
    if (busy) return null;
    final i = c.messages.indexWhere((m) => m.id == messageId);
    if (i < 0) return null;
    final removed = c.messages[i];
    c.messages.removeRange(i, c.messages.length);
    store.scheduleSave(c);
    store.changed();
    return removed;
  }

  void stop() => _abort?.abort();

  Future<void> _run(Conversation c) async {
    final provider = store.providerById(c.providerId) ?? store.defaultProvider;
    _running = c;
    _loadedSkills.clear();
    store.changed();
    try {
      if (provider == null) {
        throw LlmException('Add a provider first: menu > Providers.');
      }
      if (c.model.isEmpty) c.model = provider.model;
      if (c.model.isEmpty) throw LlmException('Pick a model for ${provider.name}.');
      final client = createClient(provider);
      final maxSteps = store.settings.maxToolSteps.clamp(1, 20);
      for (var step = 0; step < maxSteps; step++) {
        final reply = ChatMessage(role: 'assistant', model: c.model);
        final history = List<ChatMessage>.of(c.messages);
        c.messages.add(reply);
        store.changed();
        final request = LlmRequest(
          system: buildSystem(c),
          messages: history,
          model: c.model,
          tools: buildTools(c, provider),
          temperature: store.settings.temperature,
          pdfNative: provider.pdfNative,
        );
        final abort = AbortHandle();
        _abort = abort;
        try {
          await for (final event in client.stream(request, abort)) {
            if (event is TextDelta) {
              reply.text += event.text;
              _notifySoon();
            } else if (event is ToolCallDone) {
              reply.toolCalls.add(event.call);
              store.changed();
            }
          }
        } catch (e) {
          if (!abort.aborted) {
            reply.error = true;
            reply.text = reply.text.isEmpty ? e.toString() : '${reply.text}\n\n⚠️ $e';
          }
        }
        if (abort.aborted || reply.error) break;
        if (reply.toolCalls.isEmpty) {
          if (reply.text.trim().isEmpty) c.messages.remove(reply);
          break;
        }
        for (final call in reply.toolCalls) {
          final result = await runTool(call, this);
          c.messages.add(ChatMessage(role: 'tool', text: result, toolCallId: call.id, toolName: call.name));
          store.changed();
          if (_abort?.aborted ?? false) break;
        }
        if (_abort?.aborted ?? false) break;
        if (step == maxSteps - 1) {
          c.messages.add(ChatMessage(
              role: 'assistant', error: true, text: 'Stopped after $maxSteps tool steps. Ask me to continue.'));
        }
      }
    } catch (e) {
      c.messages.add(ChatMessage(role: 'assistant', error: true, text: e.toString()));
    } finally {
      _running = null;
      _abort = null;
      _notifyTimer?.cancel();
      store.scheduleSave(c);
      store.changed();
    }
  }
}
