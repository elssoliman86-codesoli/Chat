import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;

import '../agents/orchestrator.dart';
import '../agents/windows_scan.dart';
import '../agents/windows_scan_runner.dart';
import '../agents/trace.dart';
import '../agents/worker_agent.dart';
import '../core/models.dart';
import '../llm/llm.dart';
import '../llm/resilient.dart';
import '../llm/stream_metrics.dart';
import '../plugins/plugin.dart';
import '../tools/advisor_service.dart';
import '../tools/web_chat_bridge.dart';
import '../tools/browser_service.dart';
import '../tools/image_reader.dart';
import '../tools/termux_service.dart';
import '../tools/tools.dart';
import '../tools/registry.dart';
import '../tools/web_tools.dart';
import 'app_store.dart';
import 'keep_alive.dart';
import 'model_fallback.dart';
import 'services.dart' show navigatorKey;
import '../ui/glass/glass.dart';
import '../ui/steps_card.dart' show describeCall;

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

  /// Live numbers of the reply being streamed (first-token latency, tokens/second, connection state).
  final StreamMetrics metrics = StreamMetrics();

  /// What really happened in each conversation's latest task: model passes, tools, commands, files, workers.
  final TraceHub traces = TraceHub();
  ExecutionTrace? _trace;
  ExecutionTrace? get activeTrace => _trace;
  Conversation? _running;
  final Map<String, List<QueuedMessage>> _queues = <String, List<QueuedMessage>>{};

  bool get busy => _running != null;
  Conversation? get running => _running;

  /// The tool call being executed right now (null between calls). The steps timeline reads this, so its
  /// "running" ring is the real state of the engine and not a guess.
  String? runningCallId;

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
  int forgetMemory(String query) => store.forgetMemory(query);

  @override
  List<MemoryFact> get memory => store.memory;

  @override
  void addLesson(String text) => store.addLesson(text);

  @override
  int forgetLesson(String query) => store.forgetLesson(query);

  @override
  List<MemoryFact> get lessons => store.lessons;

  @override
  bool get selfImproveAllowed => store.settings.selfImprove && !(_running?.temporary ?? false);

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
      builder: (d) => GlassDialog(
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
      builder: (d) => GlassDialog(
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

  @override
  bool get advisorConfigured => store.settings.assistantProviderId.isNotEmpty && store.settings.assistantModel.isNotEmpty;

  @override
  Future<String> askAdvisor(String question) async {
    final provider = store.providerById(store.settings.assistantProviderId);
    final model = store.settings.assistantModel;
    if (provider == null || model.isEmpty) return 'No assistant model is configured.';
    try {
      return await AdvisorService.ask(question, provider, model);
    } catch (e) {
      return 'The assistant model could not be reached: $e';
    }
  }

  @override
  Future<String> askWebChat(String chat, String message, {bool newThread = false}) async {
    final c = _running;
    final second = chat == 'secondary';
    final url = second ? store.settings.webChatSecondary : store.settings.webChatPrimary;
    if (url.trim().isEmpty) {
      return second
          ? 'No link is set for the secondary chat. Use the primary chat, or tell the person to set the link in Settings > Plugins > Web chat team.'
          : 'No link is set for the primary chat. Tell the person to set it in Settings > Plugins > Web chat team.';
    }
    try {
      return await WebChatBridge.instance.ask(
        second ? ChatSlot.secondary : ChatSlot.primary,
        url,
        message,
        sessionKey: c?.id ?? '',
        newThread: newThread,
        cancelled: () => _abort?.aborted ?? false,
      );
    } on ChatBridgeError catch (e) {
      return 'The ${second ? 'secondary' : 'primary'} chat could not be used: ${e.message}'
          '${e.needsPerson ? '\nCall ask_user so the person can fix it in the browser, then try again.' : ''}';
    } catch (e) {
      return 'The ${second ? 'secondary' : 'primary'} chat could not be used: $e';
    }
  }

  @override
  String setPlan(List<String> steps, int current) {
    final c = _running;
    if (c == null) return 'No active conversation.';
    final result = applyPlanUpdate(c, steps, current);
    store.scheduleSave(c);
    store.changed();
    return result;
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
    // Redrawing a long Markdown reply is the costly part, so the longer it gets the less often it is
    // redrawn — the text still arrives in full and in order, it is just painted in bigger steps.
    final n = m.text.length;
    final ms = n > 40000 ? 220 : (n > 12000 ? 150 : (n > 3000 ? 110 : 70));
    _notifyTimer = Timer(Duration(milliseconds: ms), () {
      _streaming?.touch();
    });
  }

  String buildSystem(Conversation c) {
    final s = store.settings;
    final b = StringBuffer();
    b.writeln('You are a helpful assistant inside a personal chat app on an Android phone. '
        'Reply in the language the user writes in. Use Markdown (fenced code blocks especially — they get '
        'syntax highlighting and a Preview/Copy/Download bar). Be accurate and say when you are not sure.');
    b.writeln('Keep replies plain and easy to read on a small phone screen: no emoji and no decorative symbols '
        '(no star/sparkle/checkmark/fire characters used as flair), and use bold and headings sparingly, only '
        'where they truly help scanning, not on most lines. Prefer short paragraphs and short plain lists over '
        'a Markdown table — a table\'s columns do not shrink to fit a phone, so only use one for genuinely '
        'tabular data with few, short columns. When a script or command was written and then actually run with '
        'a tool in this same turn, do not also paste the full code again in your reply; the user already saw it '
        'run and can open the file or the step details — summarize the real result in words instead, and only '
        'show a short snippet if a specific line needs pointing out.');
    b.writeln('Before any request that will take more than two or three tool calls, call set_plan first, before any other tool call, with the full '
        'ordered list of real steps you are about to do (not vague phases — actual steps: "open config.json", "find every TODO in src/", "rewrite '
        'auth.py", and so on) and current set to 0. The person sees this as a small badge above the chat they can open, showing which step is done, '
        'which is in progress and which is still ahead. This is enforced, not just a convention: once a plan is set, the app locks its steps until '
        'current reaches the step count (fully done) — a later set_plan call while it is still unfinished only moves current forward on that same '
        'list, and a different or shorter list sent then is silently ignored, including after the person says "continue"/"كمل" or an error '
        'interrupted you. So plan once with the real full list, then just call it again with the same steps and an updated current as steps '
        'actually finish — never resend a different list to describe the same still-unfinished task; if you do, the tool result will tell you it '
        'was ignored and what the real current progress is, so adjust and keep going rather than trying again. Keep steps short (a few words each) '
        'and real — do not call set_plan at all for a single quick lookup or an obviously one-step action, and never call it merely to describe '
        'what you are already doing in words; it replaces narrating the plan in your reply text, so do not also write out the plan again in a '
        'normal message. Only a genuinely new task — after the previous plan actually finished — gets a new plan.');
    if (c.longTask) {
      b.writeln('Long-task mode is ON for this chat: the person wants the WHOLE job finished in one go, not a sample of it. If the job is a set '
          'of items (every comment to reply to, every file to fix, every message to answer), work through every one of them — do not do one or two '
          'and then stop to report progress, and do not end your turn by asking whether to continue; the person already said yes by turning this on. '
          'Keep calling tools until nothing is left, re-checking the source for items you may have missed (scroll, paginate, reload) before declaring '
          'it finished. Only stop early for something you genuinely cannot get past on your own — a sign-in or captcha only they can do, a missing '
          'credential, or an action that needs their approval — and then say exactly what you are waiting for. When it is truly done, summarize what '
          'was done and what (if anything) was skipped and why.');
    }
    b.writeln('Showing media: when you have several pictures (for example from image_search), put their ![title](url) lines on consecutive lines of the reply — '
        'the app shows them side by side as one swipeable slideshow. A video link (YouTube and similar) on a line of its own, as a bare URL or [title](url), '
        'shows as a card with its thumbnail. Do not put pictures inside a table or a list item, and never invent image URLs — use only ones a tool returned.');
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
    if (s.memoryEnabled && !c.temporary) {
      if (store.memory.isNotEmpty) {
        b.writeln('\nThings you know about the user:');
        for (final m in store.memory) {
          b.writeln('- ${m.text}');
        }
      }
      b.writeln('\nKeep building that list yourself as you go, without being asked: the moment the user mentions a '
          'lasting fact about themselves — their name, job, timezone, a device or setup they have, a recurring '
          'project, a preference for how you work or reply — call remember right then, in the same turn, even if '
          'answering something else is the main point of the message. This is what lets you understand a vague or '
          'underspecified question later instead of asking the user to repeat context they already gave you once. '
          'Do not save one-off details that only matter for this single message, and do not ask permission first — '
          'just save it; the user can always tell you to forget something.');
    }
    if (s.selfImprove && !c.temporary) {
      if (store.lessons.isNotEmpty) {
        b.writeln('\nLessons you have learned, from real mistakes and real successes in this app, before this conversation ever started: '
            'treat these as hard-won experience to act on directly, not background color, and not something to re-derive from scratch. '
            'They were written by an earlier instance of you (possibly a different model entirely — this app keeps them regardless of '
            'which model answers) specifically so you do not repeat a solved mistake or re-discover a known constraint:');
        for (final m in store.lessons) {
          b.writeln('- ${m.text}');
        }
      }
      b.writeln('\nKeep building that list yourself, the same way you build the facts list above, without being asked: the moment you '
          'actually make a mistake and find the real fix, discover a genuine constraint of this app, this device or a tool you were given, '
          'find an approach that works well for a recurring kind of request, or the user corrects how you should work going forward ("always '
          'do X from now on", "never do Y here") — call learn right then with one short, self-contained sentence, written as advice to a '
          'future version of yourself that remembers nothing about this conversation. This is what keeps the app improving across every '
          'future chat and every future model instead of starting over from zero each time: the app itself holds what was learned, not any '
          'one model, so swapping models never loses it. Do not save something that only mattered for this one message, do not save a fact '
          'about the user here (that belongs in remember instead), and do not call it just to narrate what you are already doing.');
    }
    if (advisorConfigured) {
      b.writeln('\nAssistant model: the person has set up a second AI model (their own choice/account) you can consult with ask_advisor '
          'when you are genuinely stuck or unsure about something real — not for ordinary questions you can already answer yourself. Give it '
          'the real specific context (the exact command, its full real output, the actual error) so it can actually help. Read what it says '
          'back and act on it the same way you would act on your own plan: if it lays out steps, carry them out for real, one at a time, '
          'instead of just repeating its words to the person as if that were the work done.');
    }
    if (ToolRegistry.webChatOn(c, store.settings)) {
      final second = store.settings.webChatSecondary.trim().isNotEmpty;
      b.writeln('\nHelper chats (ON for this conversation): the person connected chat websites that work as your team, through ask_web_chat '
          '(chat="primary"${second ? ' or "secondary"' : ''}). They run in the background and answer like a person typing; each call takes from '
          'several seconds to a few minutes, and the chat sees only what you write in the message, so make every message complete. '
          'First decide what kind of request this is. A question, an explanation, an opinion, a small change or small talk: answer it yourself '
          'and do not consult anyone. Designing, building, fixing or changing something real (a project, an app, a script, a system or server '
          'change, a hard bug): work as a team, like this. '
          '(1) Send the primary chat the person\'s request with every fact it needs (the environment such as Termux or a Windows PC over SSH, the '
          'files you read, what already exists) and ask it to analyse the request and write a detailed implementation prompt: which files to create or '
          'change, the exact commands, the order, the risks, and how to check it worked. '
          '(2) Read its answer and keep only the part that matters for the request. '
          '${second ? 'If the plan means producing real content (code, a design, a document), send the relevant part to the secondary chat and ask it to '
              'build it, or to review what already exists; for a big piece send the result back to the primary chat to review, and repeat until they agree (three rounds at most). ' : ''}'
          '(3) You do the work yourself: write the files with the project or Termux tools, or run the commands directly; never tell the person to run '
          'them. After every command read its stdout and stderr. If it failed or surprised you, send the primary chat the command with its full output and '
          'ask what exactly is wrong and which file or command has to be written how; apply that and run again, and keep going until it works (six rounds '
          'at most, then tell the person what is blocking). '
          '(4) Before anything runs on Termux, over SSH or over FTP, check it yourself: the right machine, the right path, no side effect nobody asked for; '
          'for a risky command ask the primary chat to review it first. The usual confirmations for changes on a PC stay. '
          '(5) If a chat answer is cut off, asks you a question or refuses, rephrase, split the work or continue in the same thread. If a call says a sign-in '
          'or human check is needed, use ask_user so the person can do it once in the browser, then retry. '
          'Never paste the chats\' answers at the person: say in your own words what was decided, what you did and what the result is, in their language.');
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
      b.writeln('\nBrowser: for tasks on websites use browser_open, then work the page the way a person holding the phone would: '
          'look at the screen, act, look again, and keep going until the whole task is done without asking the person to do steps you can do. '
          'The browser works in the background and does not cover the chat. '
          'How to work: (1) Every browser action already returns the new screen (position on the page, a dialog on top if any, text and numbered '
          'elements with their state), so do not call browser_read in between; read the result, pick the next element, act. '
          '(2) Move fast: when a page is clear, do the next step straight away; fill several fields one after another without commentary. '
          '(3) Elements marked {below} are off screen: use browser_scroll to reach them; when a dialog is open only its elements work. '
          '(4) Typing never sends anything. After typing a message, comment, post or form you MUST send it: click the element marked [send/submit] '
          'or type with submit=true, and then check the next screen shows it was sent (the box is empty, the message or confirmation appears). '
          'Never end your turn or say it is done while text you typed is still unsent. '
          '(5) After every click read the "Result:" line: if nothing changed, the click missed or needs another step: try another element or scroll, '
          'do not repeat the same click. '
          '(6) Do NOT use browser_devtools for normal work or to check that something worked; look at the screen instead. It is only for a failure with no '
          'visible reason, or when the person asks. '
          'When you need a login, a captcha, a payment, a permission or a decision, call ask_user: the browser '
          'comes up so they can act, then continue (saved logins are filled in by the app on sign-in pages). Never type passwords or card numbers yourself. '
          'Ask for confirmation before irreversible actions (sending money, buying, deleting, publishing publicly); sending a message the person asked '
          'you to send is the task itself, so do it once they have given the text. '
          'The browser shows the desktop version of sites unless the person switched to phone mode, so use the layout you see.');
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
          'so they sign in in the panel. Canva is a visual canvas, not a plain web page, and that changes how you must '
          'work: every new text box or element lands in roughly the same default spot (usually centered), on top of '
          'whatever is already there, until it is moved — the element list gives each visible element\'s position and '
          'size (x, y, width, height) for exactly this reason, and browser_drag is what actually moves one (clicking or '
          'typing alone cannot reposition anything). After adding each piece of text or object, check its box against '
          'the ones already placed, and if two overlap, browser_drag the new one clear by roughly the overlap amount '
          'before adding the next piece — do not add everything first and hope it is not stacked. Also important: once '
          'a text box is deselected it usually stops appearing as its own numbered element (only the one actively being '
          'edited does, since Canva only turns an element interactive in the DOM while it is open) — so reposition each '
          'one right after creating it, while it is still addressable, not later. When a template already has labeled '
          'placeholder fields, edit those in place rather than adding new floating text boxes — far more reliable than '
          'positioning anything by hand. browser_drag is a simulated drag and some pages ignore script-driven drags '
          'entirely; read the element\'s position again right after dragging it, and if it genuinely did not move, say '
          'so plainly to the person instead of claiming it is fixed — do not report success you have not actually '
          'confirmed by reading the position back. Before telling the person it is done, read the page once more and '
          'confirm nothing overlaps and the layout looks like an organized '
          'invoice/poster/design, not text piled in one corner.');
      if (st.termuxTools) {
        b.writeln('If the person just needs an exact, organized document (an invoice, a flyer with precise numbers/table) '
            'and does not specifically need it inside Canva, writing it with Python (e.g. Pillow or reportlab, drawing '
            'every position yourself) through Termux and handing back the finished image/PDF is far more reliable than '
            'fighting Canva\'s canvas through browser automation — prefer that route for anything that must be exactly '
            'right, and save Canva for when the person wants to keep editing it visually themselves afterward.');
      }
    }
    if (st.pluginFacebook && st.pluginBrowser) {
      b.writeln('\nFacebook: work in https://www.facebook.com with the browser tools. Read posts, pages, groups or '
          'Marketplace listings, draft a post or comment, and search for people, pages or products when asked. Before '
          'publishing a post/comment, sending a message or friending/following anyone, show exactly what will be posted '
          'and call ask_user for approval. If it shows a sign-in or checkpoint page, call ask_user so the person handles '
          'it in the panel.');
    }
    if (st.pluginInstagram && st.pluginBrowser) {
      b.writeln('\nInstagram: work in https://www.instagram.com with the browser tools. Browse profiles, posts and '
          'reels, and draft a caption or DM when asked. Before publishing a post/Story, sending a DM or following anyone, '
          'show exactly what will happen and call ask_user for approval. If it shows a sign-in or checkpoint page, call '
          'ask_user so the person handles it in the panel.');
    }
    if (st.pluginYoutube && st.pluginBrowser) {
      b.writeln('\nYouTube: work in https://www.youtube.com (and https://studio.youtube.com for the person\'s own '
          'channel) with the browser tools. Search and watch, read comments, and check the person\'s own channel stats, '
          'videos and comments in Studio. Before uploading, publishing, deleting, replying as the channel, or changing '
          'any setting, show exactly what will happen and call ask_user for approval.');
    }
    if (st.pluginBrowser) {
      for (final site in store.customSites) {
        if (!site.enabled || site.url.trim().isEmpty) continue;
        b.writeln('\n${site.name.trim().isEmpty ? site.url : site.name}: work in ${site.url} with the browser tools.'
            '${site.purpose.trim().isEmpty ? '' : ' ${site.purpose.trim()}'} If it shows a sign-in page, call ask_user so '
            'the person signs in in the panel — once signed in there, it stays signed in for next time. Before doing '
            'anything there that is not just reading (publishing, buying, sending, deleting, changing a setting, '
            'anything with a real-world or financial effect), show exactly what will happen and call ask_user for approval.');
      }
    }
    b.writeln('\nProjects: a separate SANDBOXED workspace for building something self-contained to hand back (a website, an app, a bundle of '
        'code) that the person did not already have — it is not connected to the phone\'s real files or folders, has no real filesystem or shell '
        'access, and is exported as a ZIP/preview when done. Never reach for it just because a task is bigger than one file or "sounds like a '
        'project": a script meant to run against real files/folders that already exist on the phone (open this folder, go through these files, '
        'process this data) is a Termux job below, however many lines it is — writing and running it for real right there is simpler than '
        'scaffolding a separate sandboxed copy that cannot even see the real folder. Use Projects for anything bigger than one small file '
        '(websites, apps, scripts, multi-file code) that the person wants as a standalone deliverable: do NOT paste code in the chat, call '
        'project_create, then project_write with SEVERAL complete files per call '
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
      b.writeln('\nTermux is the user\'s connected local Linux shell, and it is your DEFAULT way to actually build and run real things — '
          'not a special mode the user has to ask for by name. Never wait for the word "Termux". Decide for yourself: whenever a request implies '
          'making a real tool, script, scraper, or automation and using it (not just reading about it), build it and run it yourself through termux_run '
          '(or python_run for quick sandboxed logic with no system/network needs, or the browser tools when the task is to watch and act on a live '
          'website page by page). Never respond to "build me X that does Y" with source code alone, a copy-paste snippet, or instructions for the user '
          'to run it themselves in some other terminal — write the files, run them for real, and report the actual output. Only hand back source '
          'instead of running it when the user explicitly only wants the code, or the task genuinely cannot run here (needs a compiler/toolchain not '
          'present, or Termux is unavailable/not permitted — say so plainly then).\n'
          'Work in a loop, not one shot: write the script for real on the device (a Termux heredoc/cat/echo under ~/ — never project_write, which only '
          'writes into the separate sandboxed Projects workspace and cannot touch real files), run it with termux_run, actually read the real '
          'stdout/stderr/exit code that comes back, and use that to decide the next step — fix a bug and rerun, filter/sort/process the data with another '
          'command or python_run, or call the next tool — continuing across as many tool calls as the task needs until it is genuinely done, instead of '
          'stopping after the first call or pasting a result for the user to act on by hand. '
          'For a task that needs to actually visit and act on a live website (not just an HTTP fetch) — browsing to pages, clicking through, reading what '
          'rendered — use browser_open/browser_read/browser_click/browser_type so the user can watch it live, and combine that with termux_run or python_run '
          'to store, filter or sort what you collect; keep looping through that cycle (visit → read → extract → decide next page or step) until the job is '
          'complete, then summarize the real results, not a plan for getting them.\n'
          'termux_list_files/termux_run also cover direct local-device requests: open Termux, list/show file names, inspect folders, read a local file, check '
          'installed packages, run a command, or manage files on this phone. For "list files" use termux_list_files with an empty path; it returns the actual '
          'current directory and its entries, including hidden files. For a named directory pass its exact path. For commands use termux_run and wait for the '
          'real stdout, stderr and exit code. Never use web_search, fetch_page, browse_page or browser tools as a substitute for local Termux/device files. '
          'Do not claim a command ran unless a Termux tool result confirms it. If a Termux tool returns a permission or connection error, report that exact '
          'blocker and stop; do not silently switch to a website or invent output. Keep the current project, working directory and previous command results '
          'in context across follow-up messages. Termux is a real device shell: use read-only commands freely for inspection; ask before destructive file '
          'changes or package installation.\n'
          'A remote machine the user has their own access to works the same way, whatever shell it runs — a Linux server, a Kali Linux box, or a Windows '
          'PC\'s Command Prompt or PowerShell (via its OpenSSH Server feature): once openssh is installed in Termux (pkg install openssh) and the user '
          'has their own key or login already set up for that host (their ~/.ssh/config, a key made with ssh-keygen/ssh-copy-id, or similar), treat '
          '"run this on my server/PC" as just another termux_run command — ssh the-host \'the command\' for Linux/Kali, or ssh user@host cmd /c \'...\' / '
          'ssh user@host powershell -command \'...\' for Windows — and keep looping on it exactly like a local command: read the real output, decide the '
          'next step, continue. Only ever use a host and login the user has already configured themselves; never try a password, guess a host, or attempt '
          'to reach any machine the user has not already given you working, pre-set-up access to. '
          'For security work, use only explicitly authorized targets and obey the reviewed scope and program restrictions; never attack unrelated systems.');
      if (store.sshHosts.isNotEmpty) {
        b.writeln('\nThe user has set up these SSH hosts in Settings > Plugins > Shell (Termux) > SSH hosts — use the exact command shown for each '
            '(through termux_run, same as any other command) instead of asking the user to configure ssh by hand or guessing at host/user/port:');
        for (final h in store.sshHosts) {
          final target = '${h.username}@${h.host}';
          final portFlag = h.port == 22 ? '' : '-p ${h.port} ';
          final cmd = h.authMethod == 'password'
              ? "sshpass -p '<stored password, see below>' ssh $portFlag-o StrictHostKeyChecking=accept-new $target 'command'"
              : 'ssh $portFlag-o StrictHostKeyChecking=accept-new -i ~/.ssh/${h.alias} $target \'command\'';
          b.writeln('- "${h.alias}": $cmd');
          if (h.authMethod == 'password') {
            b.writeln('  Password for this host (replace the placeholder above with this exact value): ${h.password}\n'
                '  This needs the sshpass package in Termux; if a command fails because sshpass is missing, run "pkg install -y sshpass" first.');
          }
        }
      }
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

  /// Resumes a turn that did not conclude cleanly, instead of throwing its progress away:
  /// - an explicit error (a dropped connection, a timeout, a provider error): strips the error notice
  ///   back off the partial reply and asks the model to pick up exactly where it stopped.
  /// - a silent interruption (c.turnInProgress still true from a previous _run() — the app process
  ///   was killed mid-turn): finishes any tool call the model had decided on but that never actually
  ///   got to run (so the next request stays valid — every tool call must have a matching result) and
  ///   nudges a cut-off partial reply the same way, before resuming.
  /// Either way, real work already on disk is reused, not discarded — unlike regenerate(), which
  /// restarts the whole answer from scratch.
  Future<void> continueReply(Conversation c) async {
    if (busy) return;
    if (c.messages.isEmpty) return;
    final wasInterrupted = c.turnInProgress;
    c.turnInProgress = false;
    final last = c.messages.last;

    if (last.role == 'assistant' && last.error) {
      // The failed attempt appends "\n\n⚠️ <error>" to whatever text it had — strip that back off so
      // the model continues from its real partial answer, not from a sentence ending in an error notice.
      final markIdx = last.text.lastIndexOf('\n\n⚠️ ');
      final partial = markIdx >= 0 ? last.text.substring(0, markIdx) : '';
      if (partial.trim().isEmpty && last.toolCalls.isEmpty) {
        // Nothing real was produced (the whole text was just the error) — drop the empty bubble instead
        // of handing the raw exception back to the model as if it were its own prior reply.
        c.messages.remove(last);
      } else {
        last.text = partial;
        last.error = false;
        last.touch();
      }
      c.messages.add(ChatMessage(
          role: 'user',
          text: 'Continue your previous answer exactly from where it was cut off. Do not repeat anything already said and do not restart.'));
      store.scheduleSave(c);
      store.changed();
      await _run(c);
      return;
    }

    if (!wasInterrupted) return;

    // A silent interruption: find the most recent assistant reply of the unfinished turn (never cross
    // back into an earlier, already-answered one) and make sure every tool call it decided on actually
    // has a result — the app may have been killed between deciding a call and running it.
    ChatMessage? lastAssistant;
    for (final m in c.messages.reversed) {
      if (m.role == 'assistant') {
        lastAssistant = m;
        break;
      }
      if (m.role == 'user') break;
    }
    if (lastAssistant != null && lastAssistant.toolCalls.isNotEmpty) {
      final resolvedIds = c.messages.where((m) => m.role == 'tool').map((m) => m.toolCallId).toSet();
      for (final call in lastAssistant.toolCalls) {
        if (resolvedIds.contains(call.id)) continue;
        final result = await runTool(call, this);
        c.messages.add(ChatMessage(role: 'tool', text: result, toolCallId: call.id, toolName: call.name));
        store.scheduleSave(c);
        store.changed();
      }
    } else if (lastAssistant != null && identical(lastAssistant, last) && lastAssistant.text.trim().isNotEmpty) {
      // The most recent reply has real partial text and nothing after it — it was cut off mid-stream
      // with no tool calls involved. Nudge it the same way an errored reply is nudged, instead of
      // silently answering the original question again from scratch.
      c.messages.add(ChatMessage(
          role: 'user',
          text: 'Continue your previous answer exactly from where it was cut off. Do not repeat anything already said and do not restart.'));
    } else if (lastAssistant != null && identical(lastAssistant, last)) {
      // Killed before a single token or tool call ever arrived for this reply — nothing real to
      // resume, so drop the empty bubble instead of leaving it stranded in the transcript.
      c.messages.remove(lastAssistant);
    }
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

  /// Why Termux cannot be used right now, or null when it can.
  Future<String?> _termuxProblem() async {
    final t = TermuxService.instance;
    try {
      if (!await t.isInstalled()) return 'Termux is not installed (or the Termux bridge is unavailable). The scan reaches your PC through an ssh session in Termux.';
      if (!await t.hasPermission() && !await t.requestPermission()) {
        return 'Termux permission was not granted. Enable "Run commands in Termux environment" for this app and set allow-external-apps = true in ~/.termux/termux.properties.';
      }
    } catch (e) {
      return 'Could not reach Termux: $e';
    }
    return null;
  }

  Future<ShellOutput> _scanShell(String command, int timeoutSec) async {
    try {
      final r = await TermuxService.instance.run(command, timeout: Duration(seconds: timeoutSec.clamp(1, 300)));
      final exit = r['exitCode'] is int ? r['exitCode'] as int : int.tryParse('${r['exitCode']}') ?? -1;
      final err = r['err'] is int ? r['err'] as int : int.tryParse('${r['err']}') ?? 0;
      final msg = (r['errmsg'] ?? '').toString();
      return ShellOutput(
        stdout: (r['stdout'] ?? '').toString(),
        stderr: (r['stderr'] ?? '').toString(),
        exitCode: exit,
        error: err != 0 && exit == -1 ? (msg.isEmpty ? 'Termux could not run the command' : msg) : '',
      );
    } on PlatformException catch (e) {
      return ShellOutput(exitCode: -1, error: e.code == 'timeout' ? 'timed out after ${timeoutSec}s' : (e.message ?? e.code));
    } catch (e) {
      return ShellOutput(exitCode: -1, error: e.toString());
    }
  }

  /// The "Full Windows scan" of the chat menu. One tap: finds the SSH connection in Termux, checks it reaches a
  /// Windows PC, runs the read-only checks with 5 or 10 workers at once, then has the assistant write the report
  /// and wait for the person's approval before any cleanup. Nothing is changed on the PC.
  Future<void> startWindowsScan(Conversation c) async {
    if (busy) return;
    final st = store.settings;
    final workers = st.winScanWorkers <= 5 ? 5 : 10;
    c.messages.add(ChatMessage(role: 'user', text: 'Full Windows scan ($workers parallel workers)'));
    if (c.title == 'New chat') c.title = 'Windows scan';
    final note = ChatMessage(role: 'assistant', text: 'Starting the scan: finding your SSH connection…');
    c.messages.add(note);
    _running = c;
    _seenCalls.clear();
    c.turnInProgress = true;
    store.scheduleSave(c);
    store.changed();
    if (st.keepAlive) await BackgroundWork.start();
    final trace = ExecutionTrace(conversationId: c.id, request: 'Full Windows scan', attachments: 0, model: c.model);
    _trace = trace;
    traces.put(trace);
    final abort = AbortHandle();
    _abort = abort;
    trace.log(Stage.analyzing, TraceKind.status, 'Full Windows scan',
        detail: '$workers parallel workers · read-only · waits for your approval before any cleanup');
    WindowsScanRunner? runner;
    Orchestrator? orch;
    void sync() {
      final o = orch;
      if (o != null) trace.setWorkers(agents: o.running ? 1 + o.activeWorkers : 0, workers: o.activeWorkers);
    }

    unawaited(abort.whenAborted.then((_) => runner?.stop()));
    var continued = false;
    try {
      final problem = await _termuxProblem();
      if (problem != null) throw ScanFailure(problem);
      final r = WindowsScanRunner(
        shell: _scanShell,
        workers: workers,
        remembered: SshTarget.fromSetting(st.winScanTarget),
        saved: <SshTarget>[
          for (final h in store.sshHosts)
            SshTarget(
              destination: '${h.username}@${h.host}',
              port: h.port,
              identity: h.authMethod == 'password' || !h.hasKey ? '' : '~/.ssh/${h.alias}',
              password: h.authMethod == 'password' ? h.password : '',
              source: 'saved host "${h.alias}"',
            ),
        ],
        askTarget: (why) async {
          trace.setWaiting(true);
          final a = await askUser(why);
          trace.setWaiting(false);
          return a == 'Done.' || a.startsWith('The person cancelled') ? null : a;
        },
        onStatus: (text, {bool failed = false}) {
          trace.log(Stage.delegating, failed ? TraceKind.warning : TraceKind.status, text, tool: 'windows_scan', failed: failed);
          if (!failed && !text.contains(': ')) {
            note.text = text;
            _notifySoon(note);
          }
        },
        onOrchestrator: (o) {
          orch = o;
          o.addListener(sync);
          trace.orchestrator = o;
          trace.log(Stage.delegating, TraceKind.plan, 'Scan plan: ${kScanChecks.length} checks, $workers at a time',
              detail: kScanChecks.map((k) => k.title).join(' · '));
        },
      );
      runner = r;
      final out = await r.run();
      orch?.removeListener(sync);
      trace.setWorkers(agents: 0, workers: 0);
      if (out.stopped || abort.aborted) {
        note.text = 'Scan stopped.';
        throw const ScanStopped();
      }
      st.winScanTarget = out.target.toSetting();
      unawaited(store.saveSettings());
      final triageText = triage(out.results);
      trace.log(Stage.reviewing, TraceKind.status, 'Scan finished in ${clockLabel(out.seconds)}',
          detail: '${out.ok} of ${out.results.length} checks ok${out.failed > 0 ? ', ${out.failed} failed' : ''}');
      note.text = 'Scan finished on ${out.machine} in ${clockLabel(out.seconds)} (${out.ok}/${out.results.length} checks). Writing the report…';
      c.messages.add(ChatMessage(
        role: 'user',
        auto: true,
        text: buildReportRequest(
          evidence: buildEvidence(out.results, budget: 60000),
          triageText: triageText,
          target: out.target,
          machine: out.machine,
          workers: out.workers,
          seconds: out.seconds,
          failed: out.failed,
        ),
      ));
      store.scheduleSave(c);
      store.changed();
      continued = true;
      await _run(c, continueTrace: trace);
    } on ScanStopped {
      trace.end(TraceOutcome.cancelled);
    } on ScanFailure catch (e) {
      note.text = 'The scan could not run.';
      c.messages.add(ChatMessage(role: 'assistant', error: true, text: e.message));
      trace.log(Stage.delegating, TraceKind.error, e.message, failed: true);
      trace.end(TraceOutcome.failed, error: e.message);
    } catch (e) {
      note.text = 'The scan stopped with an error.';
      c.messages.add(ChatMessage(role: 'assistant', error: true, text: e.toString()));
      trace.end(TraceOutcome.failed, error: e.toString());
    } finally {
      if (!continued) {
        orch?.removeListener(sync);
        c.turnInProgress = false;
        await BackgroundWork.stop();
        _running = null;
        _abort = null;
        store.scheduleSave(c);
        await store.flush();
        store.changed();
      }
    }
  }

  void stop() {
    _abort?.abort();
    _trace?.orchestrator?.cancel();
  }

  @override
  Future<String> runParallel(List<Map<String, dynamic>> raw) async {
    final c = _running;
    final trace = _trace;
    if (c == null || trace == null) return 'No active conversation.';
    if (trace.orchestrator?.running ?? false) return 'Workers are already running for this task.';
    if (raw.isEmpty) return 'Give at least one task.';
    if (raw.length > 12) return 'At most 12 tasks at a time. Group some of them.';
    final st = store.settings;
    final provider = store.providerById(c.providerId) ?? store.defaultProvider;
    if (provider == null) return 'Add a provider first.';
    final fallback = priorityFrom(st.workersPriority);
    final tasks = <SubTask>[];
    for (var i = 0; i < raw.length; i++) {
      final m = raw[i];
      List<String> strings(Object? v) => v is List ? v.map((e) => e.toString()).where((e) => e.trim().isNotEmpty).toList() : <String>[];
      final id = (m['id'] ?? '').toString().trim();
      tasks.add(SubTask(
        id: id.isEmpty ? 't${i + 1}' : id,
        title: (m['title'] ?? 'Task ${i + 1}').toString().trim(),
        prompt: (m['prompt'] ?? '').toString(),
        dependsOn: strings(m['depends_on']),
        priority: priorityFrom(m['priority'], fallback),
        files: strings(m['files']),
      ));
    }
    final client = createClient(provider);
    final specs = ToolRegistry.specsFor(c, store, provider).where((t) => kWorkerTools.contains(t.name)).toList();
    final lastUser = c.messages.lastWhere((m) => m.role == 'user' && !m.auto, orElse: () => ChatMessage(role: 'user'));
    late final Orchestrator orch;
    orch = Orchestrator(
      mainTask: lastUser.text,
      model: c.model,
      config: OrchestratorConfig(
        maxWorkers: st.workersMax,
        maxAgents: st.agentsMax,
        mode: st.workersMode,
        timeout: Duration(seconds: st.workerTimeoutSec),
        retries: st.workerRetries,
        defaultPriority: fallback,
      ),
      runner: (task, ctx) => runWorkerAgent(
        task: task,
        ctx: ctx,
        client: client,
        model: c.model,
        tools: specs,
        runTool: (call) => runTool(call, this),
      ),
    );
    void sync() => trace.setWorkers(agents: orch.running ? 1 + orch.activeWorkers : 0, workers: orch.activeWorkers);
    orch.onEvent = (worker, text, failed) {
      trace.log(
        Stage.delegating,
        failed ? TraceKind.error : TraceKind.delegate,
        text,
        agent: worker,
        failed: failed,
        tool: 'run_parallel',
      );
    };
    orch.addListener(sync);
    trace.orchestrator = orch;
    trace.log(Stage.delegating, TraceKind.plan, 'Split the job into ${tasks.length} task${tasks.length == 1 ? '' : 's'}', detail: tasks.map((t) => t.title).join(' · '));
    try {
      final outcome = await orch.run(tasks);
      for (final n in orch.notes) {
        trace.log(Stage.delegating, TraceKind.warning, n);
      }
      return outcome.report;
    } on ArgumentError catch (e) {
      return 'The task list is not valid: ${e.message}';
    } finally {
      orch.removeListener(sync);
      trace.setWorkers(agents: 0, workers: 0);
    }
  }

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
        if (mode == 'web') {
          final link = store.settings.webChatImage.trim();
          if (link.isNotEmpty && !_imageReadFailed.contains(a.id)) {
            try {
              text = await ImageReader.viaWebChat(a, link, cancelled: () => _abort?.aborted ?? false);
            } on ChatBridgeError catch (e) {
              _imageReadFailed.add(a.id);
              note.writeln('${a.name}: the image chat could not read it (${e.message})\n');
            }
          }
        }
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

  /// Images the image chat already failed on in this run, so a failing site is not retried on every message.
  final Set<String> _imageReadFailed = <String>{};
  final Map<String, int> _seenCalls = <String, int>{};
  int _browserEpoch = 0;
  int _devtoolsCalls = 0;
  bool _unsentNudged = false;

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
    if (name == 'browser_devtools') {
      _devtoolsCalls++;
      if (_devtoolsCalls > 2 && call.args['id'] == null) {
        return 'DevTools were already read twice in this task. Do not open them again for ordinary steps: look at the screen the last browser '
            'action returned, try a different element, or tell the person what failed.';
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

  Future<void> _run(Conversation c, {ExecutionTrace? continueTrace}) async {
    final initialProvider = store.providerById(c.providerId) ?? store.defaultProvider;
    _running = c;
    _seenCalls.clear();
    _browserEpoch = 0;
    _devtoolsCalls = 0;
    _unsentNudged = false;
    BrowserService.instance.showWhileWorking = store.settings.browserVisible;
    BrowserService.instance.showCursor = store.settings.browserCursor;
    if (store.settings.keepAlive) await BackgroundWork.start();
    // Marks the turn as not yet concluded, and keeps saving the real, current state of the
    // conversation to disk every ~1.5s for as long as it runs — not just once at the very end.
    // Without this, a turn that does real multi-step work (writes files, runs commands, streams a
    // long answer) existed only in memory until it fully finished: if the app process was killed in
    // the middle (backgrounded and reclaimed by Android, force-closed, crashed), everything it had
    // already done vanished on the next launch and the conversation looked like it never started.
    // If turnInProgress is still true the next time this conversation loads, that is exactly what
    // happened, and continueReply() is what picks it back up using whatever did make it to disk.
    c.turnInProgress = true;
    store.scheduleSave(c);
    final periodicSave = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      store.scheduleSave(c);
      unawaited(store.flush());
    });
    store.changed();
    final lastUser = c.messages.lastWhere((m) => m.role == 'user' && !m.auto, orElse: () => ChatMessage(role: 'user'));
    final trace = continueTrace ??
        ExecutionTrace(
          conversationId: c.id,
          request: lastUser.text,
          attachments: lastUser.attachments.length,
          model: c.model,
        );
    _trace = trace;
    if (continueTrace == null) {
      traces.put(trace);
      trace.log(
        Stage.analyzing,
        TraceKind.status,
        'Read your message',
        detail: '${lastUser.text.length} characters'
            '${lastUser.attachments.isEmpty ? '' : ', ${lastUser.attachments.length} attachment${lastUser.attachments.length == 1 ? '' : 's'}'}'
            ', ${c.messages.length} message${c.messages.length == 1 ? '' : 's'} of context',
      );
    }
    var stopped = false;
    var failedTurn = false;
    var failureText = '';
    try {
      if (initialProvider == null) {
        throw LlmException('Add a provider first: menu > Providers.');
      }
      var provider = initialProvider;
      if (c.model.isEmpty) c.model = provider.model;
      if (c.model.isEmpty) throw LlmException('Pick a model for ${provider.name}.');
      var client = createClient(provider);
      // Models already tried in this turn, so automatic switching never loops back to one that just failed.
      final triedModels = <String>{candidateKey(provider, c.model)};
      var switchNote = '';
      // Moves this turn to the next model that passed the health check; false when there is none.
      bool switchModel(String why) {
        if (!store.settings.autoSwitchModel) return false;
        final status = failureStatus(why);
        if (status != null) provider.health[c.model] = status;
        final next = fallbackCandidates(store.providers, provider, triedModels, otherProviderFirst: isAccountFailure(why));
        if (next.isEmpty) return false;
        final (p, m) = next.first;
        final from = c.model;
        provider = p;
        client = createClient(p);
        c.providerId = p.id;
        c.model = m;
        triedModels.add(candidateKey(p, m));
        switchNote = 'Switched from $from to $m — $why';
        store.saveProviders();
        return true;
      }
      // Long-task mode raises the cap well past the normal one: the whole point is not stopping early.
      final maxSteps = c.longTask ? kLongTaskSteps : store.settings.maxToolSteps.clamp(1, 100);
      var autoNudges = 0;
      var lastWasNudge = false;
      String? context;
      var contextDone = false;
      var step = 0;
      while (step < maxSteps) {
        final reply = ChatMessage(role: 'assistant', model: c.model, switched: switchNote);
        switchNote = '';
        _currentReply = reply;
        final history = List<ChatMessage>.of(c.messages);
        c.messages.add(reply);
        store.scheduleSave(c);
        store.changed();
        if (!contextDone) {
          contextDone = true;
          try {
            context = await _webContext(c, reply);
            if (context != null && context.trim().isNotEmpty) {
              trace.log(Stage.researching, TraceKind.status, 'Looked up web context for your message', detail: '${context.length} characters collected');
            }
          } catch (_) {
            context = null;
          }
          store.changed();
        }
        final viaWeb = store.settings.imageReader == 'web' && store.settings.webChatImage.trim().isNotEmpty;
        var imagesAsText = false;
        if (provider.noVision.contains(c.model) || viaWeb) {
          final imgEvent = trace.log(Stage.files, TraceKind.file, 'Read the attached images',
              detail: viaWeb ? 'Reading them with your image chat in the background' : 'This model cannot see images, so they are read by another tool',
              running: true);
          try {
            await _readImages(c, reply, provider);
            trace.finishEvent(imgEvent);
          } catch (e) {
            trace.finishEvent(imgEvent, failed: true, detail: e.toString());
          }
          if (viaWeb) {
            final all = c.messages.where((m) => m.role == 'user').expand((m) => m.attachments).where((a) => a.kind == AttachmentKind.image).toList();
            imagesAsText = all.isNotEmpty && all.every((a) => a.text.trim().isNotEmpty);
          }
        }
        final request = LlmRequest(
          system: buildSystem(c) + (provider.supportsTools
              ? ''
              : '\nThis provider has tool/function calling disabled. Do not claim to have used Termux, the browser, web search or any other tool. Do not print a command as if it was executed. Tell the user that tool calling must be enabled for this provider to perform device actions.'),
          messages: _withContext(history, context),
          model: c.model,
          tools: buildTools(c, provider),
          temperature: store.settings.temperature,
          pdfNative: provider.pdfNative,
          vision: !provider.noVision.contains(c.model) && !imagesAsText,
          reasoningEffort: provider.reasoningEffort[c.model] ?? '',
        );
        final abort = AbortHandle();
        _abort = abort;
        metrics.begin(c.model);
        trace.passStart(c.model);
        var firstReported = false;
        try {
          await for (final event in resilientStream(client: client, request: request, abort: abort)) {
            if (event is TextDelta) {
              reply.text += event.text;
              metrics.onText(event.text);
              if (!firstReported && metrics.firstTokenLatency != null) {
                firstReported = true;
                trace.passFirstToken(metrics.firstTokenLatency!);
              }
              _notifySoon(reply);
            } else if (event is ToolCallDone) {
              reply.toolCalls.add(event.call);
              store.scheduleSave(c);
              store.changed();
            } else if (event is ThinkingDone) {
              reply.thinking = event.text;
              reply.thinkingSignature = event.signature;
            } else if (event is ReasoningDelta) {
              metrics.onReasoning(event.chars);
              trace.addReasoning(event.text, chars: event.chars);
            } else if (event is ToolArgsDelta) {
              trace.previewTool(event.index, event.name, event.chunk);
            } else if (event is UsageEvent) {
              metrics.onUsage(input: event.inputTokens, output: event.outputTokens);
            } else if (event is StreamStatusEvent) {
              metrics.setPhase(event.phase, detail: event.detail, attempt: event.attempt);
              if (event.phase == StreamPhase.reconnecting) {
                trace.clearPreviews();
                trace.passReconnecting(event.attempt);
              }
            }
          }
          metrics.finish(abort.aborted ? StreamPhase.stopped : StreamPhase.done);
          if (reply.text.isNotEmpty || reply.toolCalls.isNotEmpty) {
            reply.stats = metrics.summary;
          }
          trace.clearPreviews();
          trace.passEnd(
            hadTools: reply.toolCalls.isNotEmpty,
            outputTokens: metrics.totalTokens,
            took: metrics.generation,
            summary: metrics.summary,
          );
        } catch (e) {
          metrics.finish(abort.aborted ? StreamPhase.stopped : StreamPhase.failed);
          trace.passEnd(hadTools: false, outputTokens: metrics.totalTokens, took: metrics.generation, failed: !abort.aborted, summary: abort.aborted ? 'Stopped' : e.toString());
          final hadImages = history.any((m) => m.attachments.any((a) => a.kind == AttachmentKind.image));
          if (!abort.aborted && hadImages && request.vision && reply.text.isEmpty && _looksLikeNoVision(e)) {
            // This model cannot see images: remember that and try again without them.
            provider.noVision.add(c.model);
            store.saveProviders();
            c.messages.remove(reply);
            continue;
          }
          // Out of tokens, rate limited, bad key, model gone: carry on with another healthy model. A dropped
          // connection or timeout never switches — only an answer from the provider saying it cannot serve this model.
          if (!abort.aborted && reply.text.isEmpty && reply.toolCalls.isEmpty && isModelFailure(e.toString())) {
            final reason = e.toString().replaceAll('\n', ' ');
            if (switchModel(reason.length > 140 ? '${reason.substring(0, 140)}…' : reason)) {
              trace.log(Stage.understanding, TraceKind.warning, 'Switched to ${c.model}', detail: reason.length > 140 ? '${reason.substring(0, 140)}…' : reason);
              c.messages.remove(reply);
              continue;
            }
          }
          if (!abort.aborted) {
            reply.error = true;
            reply.text = reply.text.isEmpty ? e.toString() : '${reply.text}\n\n⚠️ $e';
            trace.log(Stage.finalizing, TraceKind.error, 'The model request failed', detail: e.toString(), failed: true);
          }
        }
        if (abort.aborted) stopped = true;
        if (reply.error) {
          failedTurn = true;
          failureText = reply.text;
        }
        if (abort.aborted || reply.error) break;
        if (reply.toolCalls.isEmpty) {
          // The model typed into a page and is about to stop without sending it: tell it once, like a person would notice.
          if (!_unsentNudged && BrowserService.instance.hasUnsentText) {
            _unsentNudged = true;
            final pending = BrowserService.instance.unsentText;
            BrowserService.instance.unsentText = '';
            c.messages.add(ChatMessage(
                role: 'user',
                auto: true,
                text: 'System note: you typed "${pending.length > 80 ? '${pending.substring(0, 80)}…' : pending}" into the page but never sent it. '
                    'If the task needs it sent or saved, click the send/submit button (or type with submit=true) now and confirm on the next screen '
                    'that it went through. If sending was not wanted, just finish.'));
            store.scheduleSave(c);
            store.changed();
            step++;
            continue;
          }
          // Long-task mode: a reply that stops short of done (an unfinished plan, or "want me to
          // continue?") is nudged on automatically instead of waiting for the person to type continue.
          // Only once in a row — if it still answers with no tool use after the nudge, it is really done.
          if (c.longTask && !lastWasNudge && autoNudges < kMaxAutoNudges && looksUnfinished(c, reply.text)) {
            autoNudges++;
            lastWasNudge = true;
            c.messages.add(ChatMessage(role: 'user', auto: true, text: kLongTaskNudge));
            store.scheduleSave(c);
            store.changed();
            step++;
            continue;
          }
          if (reply.text.trim().isEmpty && reply.sources.isEmpty && reply.outputs.isEmpty) {
            // "No response": the model returned nothing at all. Try another healthy model; if there is none, say so
            // instead of leaving the person looking at a turn that silently ended.
            c.messages.remove(reply);
            if (switchModel('no response from ${c.model}')) continue;
            c.messages.add(ChatMessage(
                role: 'assistant',
                error: true,
                model: c.model,
                text: 'The model returned no response. Tap Continue to try again, or pick another model.'));
          }
          break;
        }
        lastWasNudge = false;
        for (final call in reply.toolCalls) {
          runningCallId = call.id;
          store.changed();
          final info = describeCall(call, null);
          final toolEvent = trace.toolStart(call, title: info.title, detail: info.detail);
          final String result;
          try {
            result = await _runOnce(call);
          } catch (e) {
            trace.toolEnd(toolEvent, result: e.toString(), failed: true);
            rethrow;
          } finally {
            runningCallId = null;
          }
          trace.toolEnd(toolEvent, result: result, failed: toolResultFailed(result));
          c.messages.add(ChatMessage(role: 'tool', text: result, toolCallId: call.id, toolName: call.name, failed: toolResultFailed(result)));
          store.scheduleSave(c);
          store.changed();
          if (_abort?.aborted ?? false) {
            stopped = true;
            break;
          }
        }
        if (_abort?.aborted ?? false) {
          stopped = true;
          break;
        }
        step++;
        if (step == maxSteps) {
          c.messages.add(ChatMessage(
              role: 'assistant', error: true, text: 'Stopped after $maxSteps tool steps. Ask me to continue.'));
        }
      }
    } catch (e) {
      failedTurn = true;
      failureText = e.toString();
      c.messages.add(ChatMessage(role: 'assistant', error: true, text: e.toString()));
    } finally {
      trace.end(stopped ? TraceOutcome.cancelled : (failedTurn ? TraceOutcome.failed : TraceOutcome.completed), error: failureText);
      periodicSave.cancel();
      c.turnInProgress = false;
      await BackgroundWork.stop();
      _currentReply = null;
      _running = null;
      _abort = null;
      _notifyTimer?.cancel();
      _streaming?.touch();
      _streaming = null;
      store.scheduleSave(c);
      await store.flush();
      store.changed();
      unawaited(_drainQueue(c));
    }
  }
}

/// True when a tool's result text is one of the failure messages the app itself produces (an exception
/// caught in runTool, an unknown tool, a tool that could not start). Used to mark the step as failed.
bool toolResultFailed(String result) =>
    result.startsWith('Tool failed:') || result.startsWith('Unknown tool:') || result.startsWith('Could not ');

/// The continuity rule behind set_plan, as a plain function so it can be tested without a running
/// conversation. Once a plan exists and is not finished (planCurrent < planSteps.length), its steps are
/// locked: a later call can only move planCurrent forward on them, and any different or shorter list it
/// sends is ignored — this is what actually stops a model that stopped and resumed (or just re-planned
/// out of habit) from silently swapping in a different plan mid-task. A finished plan (or no plan yet)
/// accepts a brand new one. Returns the message handed back to the model as the tool result.
String applyPlanUpdate(Conversation c, List<String> steps, int current) {
  if (steps.isEmpty) return 'No steps given.';
  final hasUnfinishedPlan = c.planSteps.isNotEmpty && c.planCurrent < c.planSteps.length;
  if (hasUnfinishedPlan) {
    c.planCurrent = current.clamp(0, c.planSteps.length);
    return 'An unfinished plan for this task is already shown to the person (${c.planSteps.length} steps) — its steps are locked '
        'until it is fully done, so the new steps you just sent were not used. Moved its progress to ${c.planCurrent}/${c.planSteps.length} '
        'instead. Keep working through the existing steps; call set_plan again only to move current further, not to resend the list.';
  }
  c.planSteps = List<String>.of(steps);
  c.planCurrent = current.clamp(0, steps.length);
  return 'Plan shown to the person (${steps.length} step${steps.length == 1 ? '' : 's'}).';
}

/// How many tool steps one reply may take in long-task mode (the normal cap is the setting, at most 100).
const int kLongTaskSteps = 400;

/// How many times one turn may be nudged on automatically before it is left alone.
const int kMaxAutoNudges = 30;

/// What the app says on the person's behalf when a long-task reply stops short.
const String kLongTaskNudge = 'Continue. Do not stop to report partial progress or ask whether to carry on — keep going through every '
    'remaining item until the whole task is actually done, then summarize what was done.';

final RegExp _askingToContinue = RegExp(
    r"(want me to|shall i|should i|would you like|do you want|let me know|continue|go on|carry on|هل تريد|هل تحب|تحب|أكمل|اكمل|كمل|تكمل|تابع)",
    caseSensitive: false);
final RegExp _itemsLeft = RegExp(
    r"(\d+\s+(more|remaining|left|other|others)\b|(more|remaining|left)\s*[:：]\s*\d+|المتبقي|الباقي|متبقي|باقي\s*\d+|\d+\s*(متبقي|باقي|أخرى|اخرى))",
    caseSensitive: false);

/// Whether a text-only reply looks like the model stopping short of finishing rather than being done:
/// the conversation's plan still has steps left, the reply ends by asking whether to continue, or it
/// says how many items remain. Deliberately narrow — a wrong "yes" costs one extra model call (and
/// is never repeated back to back), a wrong "no" is just the old behaviour.
bool looksUnfinished(Conversation c, String replyText) {
  if (c.planSteps.isNotEmpty && c.planCurrent < c.planSteps.length) return true;
  final text = replyText.trim();
  if (text.isEmpty) return false;
  final tail = text.length > 300 ? text.substring(text.length - 300) : text;
  if (_itemsLeft.hasMatch(tail)) return true;
  final endsWithQuestion = RegExp(r'[?؟]\s*$').hasMatch(tail);
  return endsWithQuestion && _askingToContinue.hasMatch(tail);
}
