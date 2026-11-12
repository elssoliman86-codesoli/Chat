import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_chat/projects/project_store.dart';
import 'package:omni_chat/core/models.dart';
import 'package:omni_chat/core/skill_import.dart';
import 'package:omni_chat/data/app_store.dart';
import 'package:omni_chat/data/chat_engine.dart';
import 'package:omni_chat/tools/registry.dart';
import 'package:omni_chat/files/attachment_service.dart';
import 'package:omni_chat/files/code_export.dart';
import 'package:omni_chat/llm/anthropic.dart';
import 'package:omni_chat/llm/llm.dart';
import 'package:omni_chat/ui/plan_banner.dart';
import 'package:omni_chat/ui/skills_screen.dart';
import 'package:omni_chat/ui/steps_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

List<int> _zip(Map<String, String> files) {
  final a = Archive();
  files.forEach((name, body) {
    final bytes = body.codeUnits;
    a.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return ZipEncoder().encode(a)!;
}

void main() {
  // AppStore.saveMemory/saveLessons/etc. call SharedPreferences.getInstance(), which needs a bound
  // platform channel even in tests that never touch the UI - set that up once for the whole file.
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(<String, Object>{});

  test('skill front matter is parsed', () {
    final s = parseSkillMarkdown('---\nname: Poet\ndescription: Writes verse\n---\nWrite a poem.')!;
    expect(s.name, 'Poet');
    expect(s.description, 'Writes verse');
    expect(s.instructions, 'Write a poem.');
  });

  test('skill without front matter uses fallback name', () {
    final s = parseSkillMarkdown('Just do it.', fallbackName: 'Plain')!;
    expect(s.name, isNotEmpty);
    expect(s.instructions, contains('Just do it.'));
  });

  test('empty skill is rejected', () {
    expect(parseSkillMarkdown('   '), isNull);
  });

  test('settings survive a JSON round trip', () {
    final s = AppSettings(themeMode: 'light', temperature: 0.4, maxAttachments: 33, webTools: false);
    final back = AppSettings.fromJson(s.toJson());
    expect(back.themeMode, 'light');
    expect(back.temperature, 0.4);
    expect(back.maxAttachments, 33);
    expect(back.webTools, false);
  });

  test('conversation keeps messages, attachments and tool calls', () {
    final c = Conversation(id: 'a', title: 'Hi');
    c.messages.add(ChatMessage(
      role: 'user',
      text: 'look',
      attachments: [Attachment(id: '1', name: 'x.png', mime: 'image/png', kind: AttachmentKind.image, path: '/x')],
    ));
    c.messages.add(ChatMessage(role: 'assistant', toolCalls: [ToolCall(id: 't', name: 'web_search', args: {'query': 'q'})]));
    final back = Conversation.fromJson(c.toJson());
    expect(back.messages.length, 2);
    expect(back.messages.first.attachments.single.kind, AttachmentKind.image);
    expect(back.messages.last.toolCalls.single.args['query'], 'q');
  });

  test('provider presets are complete', () {
    expect(providerPresets.length, greaterThanOrEqualTo(10));
    for (final p in providerPresets) {
      expect(p.name, isNotEmpty);
      expect(p.baseUrl, isNotEmpty);
    }
  });

  test('docx text is extracted', () {
    final bytes = _zip({
      'word/document.xml':
          '<w:document><w:body><w:p><w:r><w:t>Hello</w:t></w:r></w:p><w:p><w:r><w:t>World</w:t></w:r></w:p></w:body></w:document>',
    });
    final text = docxText(bytes);
    expect(text, contains('Hello'));
    expect(text, contains('World'));
  });

  test('extension helper', () {
    expect(extensionOf('Report.FINAL.PDF'), 'pdf');
    expect(extensionOf('noext'), '');
  });

  test('url joining and error messages', () {
    expect(joinUrl('https://a.b/v1/', '/chat'), 'https://a.b/v1/chat');
    expect(errorMessage(401, '{"error":{"message":"bad key"}}'), contains('bad key'));
  });

  test('no-vision models and sources survive JSON', () {
    final p = ProviderConfig(id: 'p', name: 'N', kind: ProviderKind.openai, baseUrl: 'u', noVision: ['m1']);
    expect(ProviderConfig.fromJson(p.toJson()).noVision, ['m1']);
    final m = ChatMessage(role: 'assistant', text: 'x', sources: ['Title\thttps://a.b']);
    expect(ChatMessage.fromJson(m.toJson()).sources.single, 'Title\thttps://a.b');
  });

  test('new settings keep their defaults and values', () {
    final d = AppSettings.fromJson(<String, dynamic>{});
    expect(d.webAlways, true);
    expect(d.pluginGithub, true);
    final s = AppSettings(githubToken: 't', favorites: ['a|b']);
    final back = AppSettings.fromJson(s.toJson());
    expect(back.githubToken, 't');
    expect(back.favorites, ['a|b']);
  });

  test('project paths are cleaned and escapes refused', () {
    expect(safeRel('a/b/../c'), isNull);
    expect(safeRel('/css//style.css'), 'css/style.css');
    expect(safeRel('./index.html'), 'index.html');
    expect(safeRel(''), isNull);
  });

  test('conversation keeps its project and message its outputs', () {
    final c = Conversation(id: 'x', projectId: 'p1');
    c.messages.add(ChatMessage(role: 'assistant', outputs: ['a.zip\t/tmp/a.zip']));
    final back = Conversation.fromJson(c.toJson());
    expect(back.projectId, 'p1');
    expect(back.messages.first.outputs, ['a.zip\t/tmp/a.zip']);
    expect(AppSettings.fromJson(<String, dynamic>{}).browserVisible, false);
    expect(AppSettings.fromJson(<String, dynamic>{}).termuxTools, false);
    expect(AppSettings.fromJson(AppSettings(termuxTools: true).toJson()).termuxTools, true);
  });

  test('preview covers the web-renderable languages and runs them', () {
    expect(isPreviewable('markdown', '# Hi'), true);
    expect(isPreviewable('json', '{}'), true);
    expect(isPreviewable('csv', 'a,b'), true);
    expect(isPreviewable('css', 'body{}'), true);
    expect(isPreviewable('javascript', 'console.log(1)'), true);
    expect(isPreviewable('python', 'print(1)'), true);
    expect(isPreviewable('jsx', 'function App(){return null}'), true);
    expect(isPreviewable('go', 'func main(){}'), false);
    expect(previewDocument('markdown', '# Hi\n\n| a | b |\n|---|---|\n| 1 | 2 |'), contains('<table>'));
    expect(previewDocument('json', '{"a":1}'), contains('"a": 1'));
    expect(previewDocument('css', 'body{color:red}'), contains('<style>body{color:red}</style>'));
  });

  test('a skill is on-demand by default, and alwaysOn survives a JSON round trip', () {
    final s = Skill(id: 's1', name: 'Test');
    expect(s.alwaysOn, false);
    s.alwaysOn = true; // what ChatEngine.loadSkill flips once the assistant has loaded a skill
    final back = Skill.fromJson(s.toJson());
    expect(back.alwaysOn, true);
    final onByDefault = Skill.fromJson(<String, dynamic>{'id': 's2', 'name': 'T2'});
    expect(onByDefault.alwaysOn, false);
  });

  test('local Termux requests and contextual follow-ups skip automatic web search', () {
    expect(shouldSkipAutomaticWebSearchForLocalAction('Open Termux and list files'), true);
    expect(shouldSkipAutomaticWebSearchForLocalAction('هات أسماء الملفات', recentContext: 'We are working in Termux'), true);
    expect(shouldSkipAutomaticWebSearchForLocalAction('البناء فشل تاني'), true);
    expect(shouldSkipAutomaticWebSearchForLocalAction('What is the latest Flutter release?'), false);
  });

  test('Termux file listing tool is exposed only when the shell setting is enabled', () {
    final store = AppStore();
    final conversation = Conversation(id: 'termux-test');
    final provider = ProviderConfig(
      id: 'p',
      name: 'Test',
      kind: ProviderKind.openai,
      baseUrl: 'https://example.invalid/v1',
      model: 'test-model',
    );
    expect(ToolRegistry.specsFor(conversation, store, provider).map((tool) => tool.name),
        isNot(contains('termux_list_files')));
    store.settings.termuxTools = true;
    final names = ToolRegistry.specsFor(conversation, store, provider).map((tool) => tool.name);
    expect(names, contains('termux_list_files'));
    expect(names, contains('termux_run'));
  });

  test('browser_drag follows the same on/off switch as the other browser tools', () {
    final store = AppStore();
    final conversation = Conversation(id: 'browser-drag-test');
    final provider = ProviderConfig(id: 'p', name: 'Test', kind: ProviderKind.openai, baseUrl: 'https://example.invalid/v1');
    // pluginBrowser defaults to on, same as the rest of the browser_* tools.
    expect(ToolRegistry.specsFor(conversation, store, provider).map((t) => t.name), contains('browser_drag'));
    store.settings.pluginBrowser = false;
    expect(ToolRegistry.specsFor(conversation, store, provider).map((t) => t.name), isNot(contains('browser_drag')));
  });

  test('set_plan is always available, unlike the plugin-gated tools', () {
    final store = AppStore();
    final conversation = Conversation(id: 'set-plan-test');
    final provider = ProviderConfig(id: 'p', name: 'Test', kind: ProviderKind.openai, baseUrl: 'https://example.invalid/v1');
    final names = ToolRegistry.specsFor(conversation, store, provider).map((t) => t.name);
    expect(names, contains('set_plan'));
    store.settings.pluginBrowser = false;
    store.settings.termuxTools = false;
    store.settings.webTools = false;
    expect(ToolRegistry.specsFor(conversation, store, provider).map((t) => t.name), contains('set_plan'));
  });

  test('stepsOnly keeps real steps for the Steps card but drops set_plan bookkeeping calls', () {
    final calls = [
      ToolCall(id: '1', name: 'web_search', args: {'query': 'x'}),
      ToolCall(id: '2', name: 'set_plan', args: {
        'steps': ['a', 'b'],
        'current': 0,
      }),
      ToolCall(id: '3', name: 'use_skill', args: {'name': 'demo'}),
    ];
    final kept = stepsOnly(calls).map((c) => c.name);
    expect(kept, containsAll(['web_search', 'use_skill']));
    expect(kept, isNot(contains('set_plan')));
  });

  test('latestPlanAndSkill picks the most recent set_plan and use_skill calls across the turn', () {
    final older = ChatMessage(role: 'assistant', text: '', toolCalls: [
      ToolCall(id: '1', name: 'set_plan', args: {
        'steps': ['a', 'b'],
        'current': 0,
      }),
      ToolCall(id: '2', name: 'use_skill', args: {'name': 'first'}),
    ]);
    final newer = ChatMessage(role: 'assistant', text: '', toolCalls: [
      ToolCall(id: '3', name: 'set_plan', args: {
        'steps': ['a', 'b'],
        'current': 1,
      }),
    ]);
    final result = latestPlanAndSkill([older, newer]);
    expect(result.plan!.id, '3');
    expect(result.skill!.id, '2');
  });

  test('a skill installed from GitHub keeps its repo as a folder; a manual one has none', () {
    final fromRepo = Skill(id: 's3', name: 'From repo', source: 'octocat/hello-world');
    expect(Skill.fromJson(fromRepo.toJson()).source, 'octocat/hello-world');
    final manual = Skill(id: 's4', name: 'Manual');
    expect(manual.source, '');
    expect(Skill.fromJson(<String, dynamic>{'id': 's5', 'name': 'T5'}).source, '');
  });

  test('skills are grouped into one folder per repo, Built-in first and Manual last', () {
    final skills = [
      Skill(id: '1', name: 'Researcher', source: 'Built-in'),
      Skill(id: '2', name: 'Manual one'),
      Skill(id: '3', name: 'From zeta repo', source: 'zeta/repo'),
      Skill(id: '4', name: 'From alpha repo', source: 'alpha/repo'),
      Skill(id: '5', name: 'Also from alpha', source: 'alpha/repo'),
    ];
    final folders = groupSkillsByFolder(skills);
    expect(folders.keys.toList(), ['Built-in', 'alpha/repo', 'zeta/repo', 'Manual']);
    expect(folders['alpha/repo']!.map((s) => s.name), ['From alpha repo', 'Also from alpha']);
    expect(folders['Manual']!.single.name, 'Manual one');
  });

  test('Termux guidance defaults to acting without the word "Termux" and keeps looping until done', () {
    final engine = ChatEngine(AppStore());
    final c = Conversation(id: 'termux-prompt-test');
    engine.store.settings.termuxTools = true;
    final prompt = engine.buildSystem(c);
    expect(prompt, contains('DEFAULT'));
    expect(prompt, contains('Never wait for the word "Termux"'));
    expect(prompt, contains('Work in a loop, not one shot'));
    expect(prompt, contains('pkg install openssh'));
    expect(prompt, contains('never try a password, guess a host'));
  });

  test('Termux guidance never offers project_write (the sandboxed Projects tool) for real on-device scripts', () {
    final engine = ChatEngine(AppStore());
    final c = Conversation(id: 'termux-projects-prompt-test');
    engine.store.settings.termuxTools = true;
    final prompt = engine.buildSystem(c);
    final termuxSection = prompt.substring(prompt.indexOf('Termux is the user'));
    // The old wording offered project_write as an interchangeable option for a real on-device
    // script; it must now only appear as an explicit warning not to use it here.
    expect(termuxSection, isNot(contains('(project_write or a Termux heredoc')));
    expect(termuxSection, contains('never project_write'));
    expect(prompt, contains('a script meant to run against real files/folders that already exist on the phone'));
    expect(prompt, contains('Termux job below'));
  });

  test('the system prompt tells the model to call set_plan before multi-step tool work and keep it updated', () {
    final prompt = ChatEngine(AppStore()).buildSystem(Conversation(id: 'plan-prompt-test'));
    expect(prompt, contains('call set_plan first, before any other tool call'));
    expect(prompt, contains('call it again with the same steps and an updated current every time a step actually finishes'));
  });

  test('the system prompt tells the model to resume an unfinished plan rather than restart it on "continue"', () {
    final prompt = ChatEngine(AppStore()).buildSystem(Conversation(id: 'plan-resume-prompt-test'));
    expect(prompt, contains('Do not invent a new, different, or shorter list of steps for the same task'));
    expect(prompt, contains('كمل'));
  });

  test('the system prompt asks for plain replies without emoji, decoration or re-pasted code', () {
    final prompt = ChatEngine(AppStore()).buildSystem(Conversation(id: 'tone-prompt-test'));
    expect(prompt, contains('no emoji and no decorative symbols'));
    expect(prompt, contains('do not also paste the full code again'));
  });

  test('the system prompt tells the model to save lasting facts on its own, not just when asked', () {
    final prompt = ChatEngine(AppStore()).buildSystem(Conversation(id: 'memory-prompt-test'));
    expect(prompt, contains('Keep building that list yourself as you go, without being asked'));
    expect(prompt, contains('call remember right then'));
  });

  test('the system prompt tells the model to record lessons for itself, independent of the model in use', () {
    final store = AppStore();
    store.addLesson('Termux Play Store builds cannot run RUN_COMMAND; use F-Droid instead.');
    final prompt = ChatEngine(store).buildSystem(Conversation(id: 'lessons-prompt-test'));
    expect(prompt, contains('Lessons you have learned, from real mistakes and real successes in this app'));
    expect(prompt, contains('Termux Play Store builds cannot run RUN_COMMAND'));
    expect(prompt, contains('call learn right then'));
    expect(prompt, contains('this app keeps them regardless of'));
  });

  test('self-improvement is skipped for a temporary conversation and when the setting is off', () {
    final store = AppStore();
    store.addLesson('Some hard-won lesson.');
    final engine = ChatEngine(store);
    expect(engine.buildSystem(Conversation(id: 'normal', temporary: false)), contains('Some hard-won lesson.'));
    expect(engine.buildSystem(Conversation(id: 'temp', temporary: true)), isNot(contains('Some hard-won lesson.')));
    store.settings.selfImprove = false;
    expect(engine.buildSystem(Conversation(id: 'normal2', temporary: false)), isNot(contains('Some hard-won lesson.')));
  });

  test('learn and forget_lesson follow the selfImprove setting and temporary chats, like remember/forget do', () {
    final store = AppStore();
    final provider = ProviderConfig(id: 'p', name: 'Test', kind: ProviderKind.openai, baseUrl: 'https://example.invalid/v1');
    final normal = Conversation(id: 'learn-tools-test');
    expect(ToolRegistry.specsFor(normal, store, provider).map((t) => t.name), containsAll(['learn', 'forget_lesson']));

    final temp = Conversation(id: 'learn-tools-temp', temporary: true);
    expect(ToolRegistry.specsFor(temp, store, provider).map((t) => t.name), isNot(contains('learn')));

    store.settings.selfImprove = false;
    expect(ToolRegistry.specsFor(normal, store, provider).map((t) => t.name), isNot(contains('learn')));
    store.settings.selfImprove = true;

    store.addLesson('Always ask before a destructive Termux command.');
    expect(store.lessons, hasLength(1));
    // Same text saved twice is a no-op, exactly like addMemory.
    store.addLesson('Always ask before a destructive Termux command.');
    expect(store.lessons, hasLength(1));

    final removed = store.forgetLesson('destructive termux');
    expect(removed, 1);
    expect(store.lessons, isEmpty);
  });

  test('memoryMatching finds facts by a case-insensitive substring, forgetMemory\'s rule', () {
    final facts = [
      MemoryFact(id: '1', text: 'Lives in Cairo'),
      MemoryFact(id: '2', text: 'Likes strong coffee'),
      MemoryFact(id: '3', text: 'Works as a teacher'),
    ];
    expect(memoryMatching(facts, 'COFFEE').map((m) => m.id), ['2']);
    expect(memoryMatching(facts, 'nothing like this'), isEmpty);
    expect(memoryMatching(facts, '   '), isEmpty);
  });

  test('a provider keeps its per-model reasoning effort across a JSON round trip', () {
    final p = ProviderConfig(id: 'p1', name: 'N', kind: ProviderKind.openai, baseUrl: 'u');
    expect(p.reasoningEffort, isEmpty);
    p.reasoningEffort['gpt-5'] = 'high';
    final back = ProviderConfig.fromJson(p.toJson());
    expect(back.reasoningEffort['gpt-5'], 'high');
    expect(LlmRequest(system: '', messages: const [], model: 'm').reasoningEffort, '');
  });

  test('Anthropic replays a reply\'s thinking block only while thinking is still enabled for the request', () async {
    final client = AnthropicClient(ProviderConfig(id: 'p', name: 'N', kind: ProviderKind.anthropic, baseUrl: 'https://example.invalid'));
    final reply = ChatMessage(role: 'assistant', text: 'The answer is 4.');
    reply.thinking = '2+2 is 4 because...';
    reply.thinkingSignature = 'sig123';
    final history = [ChatMessage(role: 'user', text: 'What is 2+2?'), reply];

    final on = await client.encodeMessages(LlmRequest(system: '', messages: history, model: 'claude', reasoningEffort: 'high'));
    final onBlocks = (on.last['content'] as List).cast<Map<String, dynamic>>();
    expect(onBlocks.first['type'], 'thinking');
    expect(onBlocks.first['thinking'], '2+2 is 4 because...');
    expect(onBlocks.first['signature'], 'sig123');
    expect(onBlocks.last['type'], 'text');

    final off = await client.encodeMessages(LlmRequest(system: '', messages: history, model: 'claude'));
    final offBlocks = (off.last['content'] as List).cast<Map<String, dynamic>>();
    expect(offBlocks.any((b) => b['type'] == 'thinking'), false);
  });

  test('continueReply resumes a cut-off answer in place instead of discarding it', () async {
    final engine = ChatEngine(AppStore());
    final c = Conversation(id: 'continue-test');
    c.messages.add(ChatMessage(role: 'user', text: 'hi'));
    c.messages.add(ChatMessage(role: 'assistant', text: 'Here is part of the answer...\n\n⚠️ Connection lost', error: true));
    await engine.continueReply(c);
    expect(c.messages[1].text, 'Here is part of the answer...');
    expect(c.messages[1].error, false);
    expect(c.messages[2].role, 'user');
    expect(c.messages[2].text, contains('Continue your previous answer'));
  });

  test('continueReply drops the bubble instead of resuming when nothing real was produced', () async {
    final engine = ChatEngine(AppStore());
    final c = Conversation(id: 'continue-empty-test');
    c.messages.add(ChatMessage(role: 'user', text: 'hi'));
    c.messages.add(ChatMessage(role: 'assistant', text: 'Exception: timed out', error: true));
    await engine.continueReply(c);
    // The empty failed bubble is dropped; only the continue nudge (and whatever the retry itself adds) follows.
    expect(c.messages[1].role, 'user');
    expect(c.messages[1].text, contains('Continue your previous answer'));
  });

  test('a conversation keeps turnInProgress through a JSON round trip', () {
    final c = Conversation(id: 'turn-in-progress-test');
    expect(c.turnInProgress, false);
    c.turnInProgress = true;
    expect(Conversation.fromJson(c.toJson()).turnInProgress, true);
  });

  test('continueReply finishes a tool call the app never got to run before a silent interruption', () async {
    final engine = ChatEngine(AppStore());
    final c = Conversation(id: 'interrupted-tool-test');
    c.messages.add(ChatMessage(role: 'user', text: 'what time is it'));
    final call = ToolCall(id: 'tc1', name: 'current_time', args: const {});
    c.messages.add(ChatMessage(role: 'assistant', text: '', toolCalls: [call]));
    // Simulates the app process being killed right after the model decided to call current_time but
    // before the tool actually ran and before _run()'s finally block ever cleared this flag.
    c.turnInProgress = true;
    await engine.continueReply(c);
    expect(c.turnInProgress, false);
    final toolResults = c.messages.where((m) => m.role == 'tool' && m.toolCallId == 'tc1');
    expect(toolResults, hasLength(1));
    // A genuinely fresh AppStore has no provider configured, so _run() fails right after with "Add a
    // provider first" — that failure is expected here and irrelevant to what this test checks: that
    // the dangling tool call from the interrupted turn got a real result instead of being skipped.
  });

  test('continueReply does not re-run a tool call that already has a result', () async {
    final engine = ChatEngine(AppStore());
    final c = Conversation(id: 'interrupted-tool-resolved-test');
    c.messages.add(ChatMessage(role: 'user', text: 'what time is it'));
    final call = ToolCall(id: 'tc1', name: 'current_time', args: const {});
    c.messages.add(ChatMessage(role: 'assistant', text: '', toolCalls: [call]));
    c.messages.add(ChatMessage(role: 'tool', text: 'already answered', toolCallId: 'tc1', toolName: 'current_time'));
    c.turnInProgress = true;
    await engine.continueReply(c);
    final toolResults = c.messages.where((m) => m.role == 'tool' && m.toolCallId == 'tc1');
    expect(toolResults, hasLength(1));
    expect(toolResults.single.text, 'already answered');
  });

  test('continueReply nudges a silently cut-off partial reply instead of answering from scratch', () async {
    final engine = ChatEngine(AppStore());
    final c = Conversation(id: 'interrupted-text-test');
    c.messages.add(ChatMessage(role: 'user', text: 'tell me a long story'));
    c.messages.add(ChatMessage(role: 'assistant', text: 'Once upon a time, something was cut off mid'));
    c.turnInProgress = true;
    await engine.continueReply(c);
    expect(c.messages[1].text, 'Once upon a time, something was cut off mid');
    expect(c.messages[2].role, 'user');
    expect(c.messages[2].text, contains('Continue your previous answer'));
  });

  test('continueReply does nothing when the turn was not actually interrupted', () async {
    final engine = ChatEngine(AppStore());
    final c = Conversation(id: 'not-interrupted-test');
    c.messages.add(ChatMessage(role: 'user', text: 'hi'));
    c.messages.add(ChatMessage(role: 'assistant', text: 'A normal, fully finished reply.'));
    c.turnInProgress = false;
    await engine.continueReply(c);
    // Nothing added or changed: this reply concluded normally, there is nothing to resume.
    expect(c.messages, hasLength(2));
    expect(c.messages[1].text, 'A normal, fully finished reply.');
  });

  test('messages typed while busy are held in order and are not lost on a stop', () {
    final engine = ChatEngine(AppStore());
    final c = Conversation(id: 'c1');
    expect(engine.queued(c), isEmpty);
    engine.enqueue(c, 'first', <Attachment>[]);
    engine.enqueue(c, 'second', <Attachment>[]);
    expect(engine.queued(c).map((q) => q.text), ['first', 'second']);
    engine.removeQueued(c, 0);
    expect(engine.queued(c).map((q) => q.text), ['second']);
    engine.enqueue(c, '  ', <Attachment>[]);
    expect(engine.queued(c).map((q) => q.text), ['second']);
  });
}
