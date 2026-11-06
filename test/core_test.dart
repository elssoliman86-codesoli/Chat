import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_chat/projects/project_store.dart';
import 'package:omni_chat/core/models.dart';
import 'package:omni_chat/core/skill_import.dart';
import 'package:omni_chat/data/app_store.dart';
import 'package:omni_chat/data/chat_engine.dart';
import 'package:omni_chat/files/attachment_service.dart';
import 'package:omni_chat/files/code_export.dart';
import 'package:omni_chat/llm/llm.dart';

List<int> _zip(Map<String, String> files) {
  final a = Archive();
  files.forEach((name, body) {
    final bytes = body.codeUnits;
    a.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return ZipEncoder().encode(a)!;
}

void main() {
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

  test('a new skill defaults to always active, and that survives a JSON round trip', () {
    final s = Skill(id: 's1', name: 'Test');
    expect(s.alwaysOn, true);
    final back = Skill.fromJson(s.toJson());
    expect(back.alwaysOn, true);
    final off = Skill.fromJson(<String, dynamic>{'id': 's2', 'name': 'T2', 'alwaysOn': false});
    expect(off.alwaysOn, false);
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
