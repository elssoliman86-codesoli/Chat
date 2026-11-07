import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../llm/llm.dart';
import '../plugins/plugin.dart';
import '../tools/browser_service.dart';
import '../tools/image_reader.dart';
import '../tools/tools.dart';
import '../tools/registry.dart';
import '../tools/web_tools.dart';
import 'app_store.dart';
import 'keep_alive.dart';
import 'services.dart' show navigatorKey;

/// Prevent automatic web enrichment from hijacking local-device commands or short follow-ups.
bool shouldSkipAutomaticWebSearchForLocalAction(String query, {String recentContext = ''}) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return false;
  final terminalPattern = RegExp(r'\btermux\b|ترمكس|تيرمكس|طرفية|terminal|shell');
  final localActionPattern = RegExp(
    r'\b(open|run|execute|list|show|read|write|create|delete|install|check|find|print|display|pwd|ls)\b|افتح|شغل|شغّل|نفذ|نفّذ|اعرض|هات|جيب|اقرأ|اقرا|اكتب|انشئ|أنشئ|احذف|ثبت|ثبّت|اعرف|أسماء|اسامي|ملفات|مجلدات|مسار',
  );
  final hasTerminalContext = terminalPattern.hasMatch(q) || terminalPattern.hasMatch(recentContext.toLowerCase());
  if (hasTerminalContext && localActionPattern.hasMatch(q)) return true;
  if (q.length <= 90 && RegExp(
    r'\b(it|this|that|same|continue|failed|failure|error|fix it|build failed)\b|ده|دي|دا|كدا|كذا|نفسه|نفسها|فشل|فشلت|المشكلة|الخطأ|صلح|كمل|تابع',
  ).hasMatch(q)) return true;
  return false;
}

/// A message typed while the assistant was busy, waiting to be sent to the same chat.
class QueuedMessage {
  QueuedMessage(this.text, this.attachments);
  final String text;
  final List<Attachment> attachments;
}

/// Runs a conversation turn: builds the prompt, streams the answer, runs tools and repeats.
class ChatEngine implements ToolHost {
  ChatEngine(this.store);

  final AppStore store;
  AbortHandle? _abort;
  Timer? _notifyTimer;
  Conversation? _running;
  final Map<String, List<QueuedMessage>> _queues = <String, List<QueuedMessage>>{};

  bool get busy => _running != null;
  Conversation? get running => _running;

  /// Messages typed for [c] while the assistant was busy, waiting their turn.
  List<QueuedMessage> queued(Conversation c) => _queues[c.id] ?? const <QueuedMessage>[];

  /// Holds a message for [c] instead of sending it now; it is sent by itself, in order,
  /// once the conversation is free.
  void enqueue(Conversation c, String text, List<Attachment> attachments) {
    final clean = text.trim();
    if (clean.isEmpty && attachments.isEmpty) return;
    (_queues[c.id] ??= <QueuedMessage>[]).add(QueuedMessage(clean, List<Attachment>.of(attachments)));
    store.changed();
  }

  /// Removes a held message without sending it.
  void removeQueued(Conversation c, int index) {
    final q = _queues[c.id];
    if (q == null || index < 0 || index >= q.length) return;
    q.removeAt(index);
    store.changed();
  }

  /// Sends the next held message for [c], if there is one and the engine is free.
  Future<void> _drainQueue(Conversation c) async {
    if (busy) return;
    final q = _queues[c.id];
    if (q == null || q.isEmpty) return;
    final next = q.removeAt(0);
    store.changed();
    await send(c, next.text, next.attachments);
  }

  // ToolHost
  @override
  List<Skill> get skills => store.skills;

  @override
  void addMemory(String text) => store.addMemory(text);

  @override
  void loadSkill(Skill skill) {
    // A skill the assistant has found worth loading once is kept on for every future message and
    // conversation too, instead of needing use_skill again every time (toggle it off in Skills if not
    // wanted).
    skill.alwaysOn = true;
    unawaited(store.saveSkills());
    store.changed();
  }

  @override
  String get githubToken => store.settings.githubToken;

  @override
  void installSkill(Skill skill) {
    final i = store.skills.indexWhere((k) => k.name.trim().toLowerCase() == skill.name.trim().toLowerCase());
    if (i >= 0) {
      final old = store.skills[i];
      old.description = skill.description;
      old.instructions = skill.instructions;
      old.tools = skill.tools;
    } else {
      store.skills.add(skill);
    }
    store.saveSkills();
  }

  @override
  void registerPlugin(Plugin plugin) {
    store.plugins.removeWhere((p) => p.name.toLowerCase() == plugin.name.toLowerCase());
    store.plugins.add(plugin);
    store.savePlugins();
  }

  @override
  Future<bool> confirm(String message) async {
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return false;
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (d) => AlertDialog(
        title: const Text('Approve?'),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('No')),
          TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('Yes')),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  Future<String> askUser(String question) async {
    if (BrowserService.instance.needed.value && BrowserService.instance.url.value.isNotEmpty) {
      return BrowserService.instance.askInPanel(question);
    }
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return 'The person is not available.';
    final controller = TextEditingController();
    final answer = await showDialog<String>(
      context: ctx,
      barrierDismissible: false,
      builder: (d) => AlertDialog(
        title: const Text('Needs you'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(question),
          const SizedBox(height: 12),
          TextField(controller: controller, decoration: const InputDecoration(hintText: 'Answer (optional)'), minLines: 1, maxLines: 4),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, null), child: const Text('Cancel task')),
          TextButton(
            onPressed: () => Navigator.pop(d, controller.text.trim().isEmpty ? 'Done.' : controller.text.trim()),
            child: const Text('Done'),
          ),
        ],
      ),
    );
    controller.dispose();
    return answer ?? 'The person cancelled. Stop the task.';
  }

  (Plugin, PluginTool)? _findPluginTool(String name) {
    for (final p in store.plugins) {
      if (!p.enabled) continue;
      for (final t in p.tools) {
        if (p.specName(t) == name) return (p, t);
      }
    }
    return null;
  }

  @override
  Future<String?> runPluginTool(String name, Map<String, dynamic> args) async {
    final found = _findPluginTool(name);
    if (found == null) return null;
    final (plugin, tool) = found;
    try {
      if (plugin.kind == 'mcp') {
        final client = McpClient(plugin.url, token: plugin.token);
        await client.connect();
        return await client.call(tool.name, args);
      }
      return await runHttpTool(plugin, tool, args);
    } catch (e) {
      return 'Plugin failed: $e';
    }
  }

  @override
  String get projectId => _running?.projectId ?? '';

  @override
  void useProject(String id) {
    _running?.projectId = id;
    store.changed();
  }

  @override
  void deliver(String name, String path) {
    _currentReply?.outputs.add('$name\t$path');
    _currentReply?.touch();
  }

  @override
  bool get memoryAllowed => store.settings.memoryEnabled && !(_running?.temporary ?? false);

  ChatMessage? _streaming;
  ChatMessage? _currentReply;

  /// Redraws only the message that is being written, at most ten times a second.
  void _notifySoon(ChatMessage m) {
    _streaming = m;
    if (_notifyTimer?.isActive ?? false) return;
    _notifyTimer = Timer(const Duration(milliseconds: 100), () {
      _streaming?.touch();
    });
  }

  String buildSystem(Conversation c) {
    final s = store.settings;
    final b = StringBuffer();
    b.writeln('You are a helpful assistant inside a personal chat app on an Android phone. '
        'Reply in the language the user writes in. Use Markdown. Be accurate and say when you are not sure.');
    b.writeln('Conversation continuity is mandatory: treat every new user message as part of this same ongoing conversation unless the user clearly starts a new topic. '
        'Use the full preceding conversation, including the latest task, files, code changes, errors, tool results and decisions, to resolve short follow-ups. '
        'For example, after discussing an app or code project, "the build failed", "fix it", "what about this error?" or a single short phrase usually refers to that active project/task, not an unrelated dictionary meaning. '
        'Do not discard the active task context or answer a context-dependent follow-up as a standalone question. If two interpretations remain genuinely plausible, ask one concise clarification. '
        'Do not invent prior actions or claim a build/test succeeded unless tool results confirm it.');
    final recentMessages = c.messages.where((m) => m.text.trim().isNotEmpty).toList();
    if (recentMessages.isNotEmpty) {
      b.writeln('\nRecent conversation continuity (newest last; use this to interpret short follow-ups):');
      for (final m in recentMessages.skip(recentMessages.length > 8 ? recentMessages.length - 8 : 0)) {
        final role = m.role == 'user' ? 'USER' : m.role == 'tool' ? 'TOOL RESULT ${m.toolName}' : 'ASSISTANT';
        final body = m.text.trim();
        final excerpt = body.length > 1200 ? '${body.substring(0, 1200)}…' : body;
        b.writeln('[$role] $excerpt');
      }
    }
    b.writeln('Skill selection is conservative: load a skill only when the current request clearly and directly matches its purpose. '
        'Never invoke a dictionary, translation or language-learning skill merely because the user typed one word, a short phrase, a name, code, an error message or a follow-up. '
        'A short message is not automatically a translation request. Keep the current task context and answer normally unless the user explicitly asks to translate, define or analyze language.');
    final now = DateTime.now();
    const days = <String>['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    const months = <String>[
      'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'
    ];
    b.writeln('Today is ${days[now.weekday - 1]}, ${now.day} ${months[now.month - 1]} ${now.year} '
        '(local time ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}, '
        'UTC${now.timeZoneOffset.isNegative ? '-' : '+'}${now.timeZoneOffset.inHours.abs()}).');
    b.writeln('Your training data is out of date. For prices, news, versions, scores, releases and anything else that '
        'changes, use the web results or tools you are given, say the date of the information, and never present '
        'remembered figures as current. If you could not check, say so.');
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
    final auto = store.skills.where((k) => k.enabled && k.autoUse && !k.alwaysOn && !active.contains(k)).toList();
    if (auto.isNotEmpty) {
      b.writeln('\nSkills you can load with the use_skill tool when one fits the request:');
      for (final k in auto) {
        b.writeln('- ${k.name}: ${k.description}');
      }
    }
    final st = store.settings;
    if (st.pluginGithub && st.githubWrite && st.githubToken.isNotEmpty) {
      b.writeln('\nGitHub: you have the person\'s GitHub token with write access through tools. When asked to change, fix, '
          'add or refactor something in a repository, DO IT yourself: read it with github_tree and github_file, then call '
          'github_commit with the complete new content of every file you change. Work on a new branch (for example '
          '"assistant/<short-topic>") unless the person says to commit to the main branch, and open a pull request when '
          'it makes sense. Never paste code into the chat as a replacement for editing. Report what you changed with the '
          'commit or PR link. Ask first only when the request is ambiguous or destructive.');
    }
    if (st.pluginBrowser) {
      b.writeln('\nBrowser: for tasks on websites use browser_open, then browser_read, browser_click and browser_type, and keep '
          'going until the whole task is done without asking the person to do steps you can do. The browser works in the background and '
          'does not cover the chat. When you need a login, a captcha, a payment, a permission or a decision, call ask_user: the browser '
          'comes up so they can act, then continue. Never type passwords or card numbers yourself. '
          'Ask for confirmation before irreversible actions (sending, buying, deleting, publishing).');
    }
    if (st.pluginGmail && st.pluginBrowser) {
      b.writeln('\nGmail: work in https://mail.google.com with the browser tools. Search with the search box, open threads to '
          'read them, use Compose to write. Before sending any email, show the recipient, subject and body with ask_user '
          'and send only after approval. Never delete or archive without approval. If Gmail shows a sign-in page, '
          'call ask_user so the person signs in in the panel.');
    }
    if (st.pluginCanva && st.pluginBrowser) {
      b.writeln('\nCanva: work in https://www.canva.com with the browser tools. Search templates, create the design, edit '
          'text, and use Share or Download only after the person approves. If Canva shows a sign-in page, call ask_user '
          'so they sign in in the panel.');
    }
    b.writeln('\nProjects: you have a workspace of real files on the phone. For anything bigger than one small file (websites, apps, '
        'scripts, multi-file code) do NOT paste code in the chat: call project_create, then project_write with SEVERAL complete files per call '
        '(no placeholders), linked by real relative paths (index.html uses css/style.css and js/app.js, and so on). Create every file the project needs '
        'plus a README. Before project work, inspect the available auto-use skill descriptions and call use_skill for every skill that materially applies; do not wait for the user to activate project skills manually. Work in the background and keep going until the project is complete. For a web project, call project_check after writing: it '
        'runs the project on the local server in a hidden phone-sized browser and reports the text, layout, overflow, broken images and script errors. '
        'Read the report, judge whether the page is right (is the content there, is it readable, does it fit the screen, any errors), fix problems '
        'with project_edit or project_write and check again (at most 3 rounds) before saying it works. When finished call project_export so the person '
        'gets a ZIP. If the person attached a ZIP it is already unpacked into the current project: use project_list, project_search and project_read '
        'to analyze it (big projects: one folder at a time) and project_edit or project_write to change it. For a GitHub link call project_import_github, '
        'work on the files, and push the result with project_push_github when asked. The person can preview the whole project from the bar above the '
        'message box. Never repeat a tool call with the same arguments when nothing changed: use the result you already have, change approach, or answer.');
    b.writeln('\nPython: python_run runs Python in a sandbox on the phone (no shell, no file or app access) so you can work out logic, '
        'test a function or try an algorithm before writing the finished script to the project. Variables stay between calls like a notebook; '
        'use reset to start clean. It cannot control the device, install packages that need a compiler, or automate anything outside itself. '
        'A ```python code block in a reply also gets a Preview button that runs it the same way. A ```jsx or ```tsx code block with a component '
        'named App gets a Preview that renders it with React. There is no runtime for compiled languages (Go, Java, Swift, C, and so on): say so '
        'and offer the source file instead when one of those is asked for.');
    if (st.termuxTools) {
      b.writeln('\nTermux is the user\'s connected local Linux shell. LOCAL DEVICE ACTION ROUTING IS MANDATORY: '
          'when the user asks to open Termux, list/show file names, inspect folders, read a local file, check installed packages, run a command, or manage files on this phone, call termux_list_files or termux_run. '
          'For "list files" use termux_list_files with an empty path; it returns the actual current directory and its entries, including hidden files. '
          'For a named directory pass its exact path. For commands use termux_run and wait for the real stdout, stderr and exit code. '
          'Never replace execution with instructions for the user to copy, and never use web_search, fetch_page, browse_page or browser tools for local Termux/device files. '
          'Do not claim a command ran unless a Termux tool result confirms it. If a Termux tool returns a permission or connection error, report that exact blocker and stop; do not silently switch to a website or invent output. '
          'Keep the current project, working directory and previous command results in context across follow-up messages. '
          'Termux is a real device shell: use read-only commands freely for inspection; ask before destructive file changes or package installation. '
          'For security work, use only explicitly authorized targets and obey the reviewed scope and program restrictions; never attack unrelated systems.');
    } else {
      b.writeln('\nTermux integration is currently disabled in Settings > Plugins > Shell (Termux). '
          'If the user asks for local Termux actions, do not use web search or a browser and do not pretend to execute commands. '
          'Tell them the Termux switch must be enabled before the local shell tool becomes available.');
    }
    b.writeln('\nTo add skills or plugins to this app when the person gives you a link or text, use install_skills, '
        'install_plugin or create_skill. When you need permission, a login, a captcha or a decision from the person, '
        'call ask_user instead of guessing.');
    for (final p in store.plugins.where((p) => p.enabled && p.instructions.trim().isNotEmpty)) {
      b.writeln('\n## Plugin: ${p.name}\n${p.instructions.trim()}');
    }
    return b.toString();
  }

  List<Skill> _activeSkills(Conversation c) =>
      store.skills.where((k) => k.enabled && (k.alwaysOn || c.activeSkillIds.contains(k.id))).toList();

  List<ToolSpec> buildTools(Conversation c, ProviderConfig provider) {
    return ToolRegistry.specsFor(c, store, provider);
  }

  Future<void> send(Conversation c, String text, List<Attachment> attachments) async {
    if (busy) return;
    final clean = text.trim();
    if (clean.isEmpty && attachments.isEmpty) return;
    for (final a in attachments) {
      final m = RegExp(r'^\[\[project:([^\]]+)\]\]').firstMatch(a.text);
      if (m != null) c.projectId = m.group(1)!;
    }
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

  /// Replaces one of the person's messages with new text and answers again from there.
  Future<void> editAndResend(Conversation c, String messageId, String text) async {
    if (busy) return;
    final i = c.messages.indexWhere((m) => m.id == messageId);
    if (i < 0) return;
    final old = c.messages[i];
    final files = List<Attachment>.of(old.attachments);
    c.messages.removeRange(i, c.messages.length);
    await send(c, text, files);
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

  /// Searches the web for the last question and returns text to put in front of it.
  Future<String?> _webContext(Conversation c, ChatMessage reply) async {
    if (!c.web || !store.settings.webTools) return null;
    ChatMessage? last;
    for (final m in c.messages) {
      if (m.role == 'user') last = m;
    }
    final query = (last?.text ?? '').trim();
    final recentContext = c.messages.map((m) => m.text).join('\n');
    if (shouldSkipAutomaticWebSearchForLocalAction(query, recentContext: recentContext)) return null;
    if (query.length < 8 || query.split(RegExp(r'\s+')).length < 2) return null;
    final short = query.length > 200 ? query.substring(0, 200) : query;
    final hits = await WebTools.results(short);
    if (hits.isEmpty) return null;
    final top = hits.take(3).toList();
    final pages = await Future.wait(top.map((h) => WebTools.fetchText(h['url'] ?? '', maxChars: 3500)));
    final b = StringBuffer();
    final d = DateTime.now();
    b.writeln('[Web results fetched just now, ${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}. '
        'Prefer them over your memory for anything that changes. Say which source you used and its date when known.]');
    var n = 0;
    for (final h in hits.take(7)) {
      n++;
      b.writeln('$n. ${h['title']} - ${h['url']}\n   ${h['snippet'] ?? ''}');
    }
    for (var i = 0; i < top.length; i++) {
      final text = pages[i];
      if (text.startsWith('Could not open') || text.startsWith('The page had no')) continue;
      b.writeln('\n--- ${top[i]['title']} (${top[i]['url']}) ---\n$text');
      reply.sources.add('${top[i]['title']}\t${top[i]['url']}');
    }
    for (final h in hits.skip(top.length).take(3)) {
      reply.sources.add('${h['title']}\t${h['url']}');
    }
    return b.toString();
  }

  /// A copy of [history] where the last user message carries [context] in front of the question.
  List<ChatMessage> _withContext(List<ChatMessage> history, String? context) {
    if (context == null) return history;
    final copy = List<ChatMessage>.of(history);
    for (var i = copy.length - 1; i >= 0; i--) {
      final m = copy[i];
      if (m.role == 'user') {
        copy[i] = ChatMessage(
          id: m.id,
          role: 'user',
          text: '$context\n\nUser question:\n${m.text}',
          attachments: m.attachments,
          at: m.at,
        );
        break;
      }
    }
    return copy;
  }

  /// Reads the text of images for a model that cannot see, using the helper model or Google Lens.
  Future<void> _readImages(Conversation c, ChatMessage reply, ProviderConfig provider) async {
    final mode = store.settings.imageReader;
    if (mode == 'off') return;
    final todo = <Attachment>[];
    for (final m in c.messages) {
      if (m.role != 'user') continue;
      for (final a in m.attachments) {
        if (a.kind == AttachmentKind.image && a.text.trim().isEmpty) todo.add(a);
      }
    }
    if (todo.isEmpty) return;
    final note = StringBuffer();
    for (final a in todo.take(12)) {
      String text = '';
      try {
        if (mode == 'lens') {
          text = await ImageReader.viaLens(a, this);
        }
        if (text.trim().isEmpty) {
          final hp = store.providerById(store.settings.helperProviderId);
          final hm = store.settings.helperModel;
          if (hp != null && hm.isNotEmpty && !hp.noVision.contains(hm)) {
            text = await ImageReader.viaHelper(a, hp, hm);
          }
        }
      } catch (e) {
        text = '';
      }
      if (text.trim().isEmpty) continue;
      a.text = text.length > 12000 ? text.substring(0, 12000) : text;
      note.writeln('${a.name}\n${a.text}\n');
    }
    if (note.isNotEmpty) {
      reply.note = note.toString().trim();
      reply.touch();
      store.scheduleSave(c);
    }
  }

  bool _looksLikeNoVision(Object e) {
    final t = e.toString().toLowerCase();
    return t.contains('multimodal') ||
        t.contains('image input') ||
        t.contains('does not support image') ||
        t.contains('vision') ||
        t.contains('image_url') ||
        t.contains('modalit');
  }

  final Map<String, int> _seenCalls = <String, int>{};
  int _browserEpoch = 0;

  /// Runs a tool call, but stops the model from repeating the same call when nothing changed.
  Future<String> _runOnce(ToolCall call) async {
    final name = call.name;
    final changesPage = name == 'browser_open' ||
        name == 'browser_click' ||
        name == 'browser_type' ||
        name == 'browser_scroll' ||
        name == 'browser_back';
    final repeatable = name == 'ask_user' || name == 'current_time' || name == 'browser_scroll' || name.startsWith('project_write') || name == 'project_edit';
    if (!repeatable) {
      final sig = '$name|${jsonEncode(call.args)}|$_browserEpoch';
      final n = (_seenCalls[sig] ?? 0) + 1;
      _seenCalls[sig] = n;
      if (n >= 2) {
        return 'You already made this exact call and nothing changed since. Do not repeat it. Use the earlier result, '
            'try a different approach, or finish and answer the person.';
      }
    }
    if (name == 'browser_back') {
      final backs = (_seenCalls['#back'] ?? 0) + 1;
      _seenCalls['#back'] = backs;
      if (backs > 3) return 'You went back several times already. Stop going back: open the address you need directly with browser_open, or answer.';
    }
    final out = await runTool(call, this);
    if (changesPage) _browserEpoch++;
    return out;
  }

  Future<void> _run(Conversation c) async {
    final provider = store.providerById(c.providerId) ?? store.defaultProvider;
    _running = c;
    _seenCalls.clear();
    _browserEpoch = 0;
    BrowserService.instance.showWhileWorking = store.settings.browserVisible;
    if (store.settings.keepAlive) await BackgroundWork.start();
    store.changed();
    try {
      if (provider == null) {
        throw LlmException('Add a provider first: menu > Providers.');
      }
      if (c.model.isEmpty) c.model = provider.model;
      if (c.model.isEmpty) throw LlmException('Pick a model for ${provider.name}.');
      final client = createClient(provider);
      final maxSteps = store.settings.maxToolSteps.clamp(1, 100);
      String? context;
      var contextDone = false;
      var step = 0;
      while (step < maxSteps) {
        final reply = ChatMessage(role: 'assistant', model: c.model);
        _currentReply = reply;
        final history = List<ChatMessage>.of(c.messages);
        c.messages.add(reply);
        store.changed();
        if (!contextDone) {
          contextDone = true;
          try {
            context = await _webContext(c, reply);
          } catch (_) {
            context = null;
          }
          store.changed();
        }
        if (provider.noVision.contains(c.model)) {
          try {
            await _readImages(c, reply, provider);
          } catch (_) {}
        }
        final request = LlmRequest(
          system: buildSystem(c),
          messages: _withContext(history, context),
          model: c.model,
          tools: buildTools(c, provider),
          temperature: store.settings.temperature,
          pdfNative: provider.pdfNative,
          vision: !provider.noVision.contains(c.model),
        );
        final abort = AbortHandle();
        _abort = abort;
        try {
          await for (final event in client.stream(request, abort)) {
            if (event is TextDelta) {
              reply.text += event.text;
              _notifySoon(reply);
            } else if (event is ToolCallDone) {
              reply.toolCalls.add(event.call);
              store.changed();
            }
          }
        } catch (e) {
          final hadImages = history.any((m) => m.attachments.any((a) => a.kind == AttachmentKind.image));
          if (!abort.aborted && hadImages && request.vision && reply.text.isEmpty && _looksLikeNoVision(e)) {
            // This model cannot see images: remember that and try again without them.
            provider.noVision.add(c.model);
            store.saveProviders();
            c.messages.remove(reply);
            continue;
          }
          if (!abort.aborted) {
            reply.error = true;
            reply.text = reply.text.isEmpty ? e.toString() : '${reply.text}\n\n⚠️ $e';
          }
        }
        if (abort.aborted || reply.error) break;
        if (reply.toolCalls.isEmpty) {
          if (reply.text.trim().isEmpty && reply.sources.isEmpty) c.messages.remove(reply);
          break;
        }
        for (final call in reply.toolCalls) {
          final result = await _runOnce(call);
          c.messages.add(ChatMessage(role: 'tool', text: result, toolCallId: call.id, toolName: call.name));
          store.changed();
          if (_abort?.aborted ?? false) break;
        }
        if (_abort?.aborted ?? false) break;
        step++;
        if (step == maxSteps) {
          c.messages.add(ChatMessage(
              role: 'assistant', error: true, text: 'Stopped after $maxSteps tool steps. Ask me to continue.'));
        }
      }
    } catch (e) {
      c.messages.add(ChatMessage(role: 'assistant', error: true, text: e.toString()));
    } finally {
      await BackgroundWork.stop();
      _currentReply = null;
      _running = null;
      _abort = null;
      _notifyTimer?.cancel();
      _streaming?.touch();
      _streaming = null;
      store.scheduleSave(c);
      store.changed();
      unawaited(_drainQueue(c));
    }
  }
}
