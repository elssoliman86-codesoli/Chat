import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_chat/core/models.dart';
import 'package:omni_chat/core/skill_import.dart';
import 'package:omni_chat/files/attachment_service.dart';
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
}
