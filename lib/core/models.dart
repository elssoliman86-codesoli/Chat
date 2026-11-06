import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Which wire protocol a provider speaks.
enum ProviderKind { openai, anthropic, gemini }

ProviderKind kindFromName(String? name) {
  for (final k in ProviderKind.values) {
    if (k.name == name) return k;
  }
  return ProviderKind.openai;
}

/// A ready-made provider the user can add with one tap.
class ProviderPreset {
  const ProviderPreset({
    required this.name,
    required this.kind,
    required this.baseUrl,
    required this.model,
    this.pdfNative = false,
    this.needsKey = true,
    this.note = '',
  });

  final String name;
  final ProviderKind kind;
  final String baseUrl;
  final String model;
  final bool pdfNative;
  final bool needsKey;
  final String note;
}

const List<ProviderPreset> providerPresets = [
  ProviderPreset(
      name: 'OpenAI',
      kind: ProviderKind.openai,
      baseUrl: 'https://api.openai.com/v1',
      model: 'gpt-4o',
      pdfNative: true),
  ProviderPreset(
      name: 'Anthropic',
      kind: ProviderKind.anthropic,
      baseUrl: 'https://api.anthropic.com',
      model: 'claude-sonnet-4-5',
      pdfNative: true),
  ProviderPreset(
      name: 'Google Gemini',
      kind: ProviderKind.gemini,
      baseUrl: 'https://generativelanguage.googleapis.com',
      model: 'gemini-2.5-flash',
      pdfNative: true),
  ProviderPreset(
      name: 'OpenRouter',
      kind: ProviderKind.openai,
      baseUrl: 'https://openrouter.ai/api/v1',
      model: 'openai/gpt-4o',
      pdfNative: true,
      note: 'One key for hundreds of models'),
  ProviderPreset(
      name: 'Groq',
      kind: ProviderKind.openai,
      baseUrl: 'https://api.groq.com/openai/v1',
      model: 'llama-3.3-70b-versatile'),
  ProviderPreset(
      name: 'DeepSeek',
      kind: ProviderKind.openai,
      baseUrl: 'https://api.deepseek.com/v1',
      model: 'deepseek-chat'),
  ProviderPreset(
      name: 'Mistral',
      kind: ProviderKind.openai,
      baseUrl: 'https://api.mistral.ai/v1',
      model: 'mistral-large-latest'),
  ProviderPreset(
      name: 'Together AI',
      kind: ProviderKind.openai,
      baseUrl: 'https://api.together.xyz/v1',
      model: 'meta-llama/Llama-3.3-70B-Instruct-Turbo'),
  ProviderPreset(
      name: 'NVIDIA',
      kind: ProviderKind.openai,
      baseUrl: 'https://integrate.api.nvidia.com/v1',
      model: 'meta/llama-3.3-70b-instruct'),
  ProviderPreset(
      name: 'xAI',
      kind: ProviderKind.openai,
      baseUrl: 'https://api.x.ai/v1',
      model: 'grok-4'),
  ProviderPreset(
      name: 'Perplexity',
      kind: ProviderKind.openai,
      baseUrl: 'https://api.perplexity.ai',
      model: 'sonar'),
  ProviderPreset(
      name: 'Ollama (local)',
      kind: ProviderKind.openai,
      baseUrl: 'http://localhost:11434/v1',
      model: 'llama3.2',
      needsKey: false,
      note: 'Use your computer\'s IP instead of localhost'),
  ProviderPreset(
      name: 'LM Studio (local)',
      kind: ProviderKind.openai,
      baseUrl: 'http://localhost:1234/v1',
      model: '',
      needsKey: false,
      note: 'Use your computer\'s IP instead of localhost'),
  ProviderPreset(
      name: 'Custom (OpenAI compatible)',
      kind: ProviderKind.openai,
      baseUrl: 'https://',
      model: ''),
];

class ProviderConfig {
  ProviderConfig({
    required this.id,
    required this.name,
    required this.kind,
    required this.baseUrl,
    this.apiKey = '',
    List<String>? models,
    this.model = '',
    this.pdfNative = false,
    this.supportsTools = true,
    this.maxTokens = 8192,
    List<String>? noVision,
    Map<String, int>? health,
  })  : models = models ?? <String>[],
        noVision = noVision ?? <String>[],
        health = health ?? <String, int>{};

  final String id;
  String name;
  ProviderKind kind;
  String baseUrl;
  String apiKey;
  List<String> models;
  String model;
  bool pdfNative;
  bool supportsTools;
  int maxTokens;

  /// Models that answered an image with a "no multimodal" error.
  List<String> noVision;

  /// Last test result per model: the HTTP status, or 0 for no answer.
  Map<String, int> health;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'kind': kind.name,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'models': models,
        'model': model,
        'pdfNative': pdfNative,
        'supportsTools': supportsTools,
        'maxTokens': maxTokens,
        'noVision': noVision,
        'health': health,
      };

  factory ProviderConfig.fromJson(Map<String, dynamic> j) => ProviderConfig(
        id: j['id'] as String? ?? newId(),
        name: j['name'] as String? ?? 'Provider',
        kind: kindFromName(j['kind'] as String?),
        baseUrl: j['baseUrl'] as String? ?? '',
        apiKey: j['apiKey'] as String? ?? '',
        models: (j['models'] as List?)?.whereType<String>().toList(),
        model: j['model'] as String? ?? '',
        pdfNative: j['pdfNative'] as bool? ?? false,
        supportsTools: j['supportsTools'] as bool? ?? true,
        maxTokens: (j['maxTokens'] as num?)?.toInt() ?? 8192,
        noVision: (j['noVision'] as List?)?.whereType<String>().toList(),
        health: (j['health'] as Map?)?.map((k, v) => MapEntry(k.toString(), (v as num).toInt())),
      );
}

int _idCounter = 0;

/// Short unique id, good enough for local data.
String newId() {
  _idCounter++;
  return '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}$_idCounter';
}

enum AttachmentKind { image, pdf, text }

class Attachment {
  Attachment({
    required this.id,
    required this.name,
    required this.mime,
    required this.kind,
    this.path = '',
    this.size = 0,
    this.text = '',
  });

  final String id;
  final String name;
  final String mime;
  final AttachmentKind kind;

  /// Stored copy for images and PDFs.
  final String path;
  final int size;

  /// Extracted text for documents, or the text read from an image for models that cannot see.
  String text;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'mime': mime,
        'kind': kind.name,
        'path': path,
        'size': size,
        'text': text,
      };

  factory Attachment.fromJson(Map<String, dynamic> j) => Attachment(
        id: j['id'] as String? ?? newId(),
        name: j['name'] as String? ?? 'file',
        mime: j['mime'] as String? ?? 'application/octet-stream',
        kind: AttachmentKind.values.firstWhere(
          (k) => k.name == j['kind'],
          orElse: () => AttachmentKind.text,
        ),
        path: j['path'] as String? ?? '',
        size: (j['size'] as num?)?.toInt() ?? 0,
        text: j['text'] as String? ?? '',
      );
}

class ToolCall {
  ToolCall({required this.id, required this.name, required this.args});

  final String id;
  final String name;
  final Map<String, dynamic> args;

  Map<String, dynamic> toJson() => <String, dynamic>{'id': id, 'name': name, 'args': args};

  factory ToolCall.fromJson(Map<String, dynamic> j) => ToolCall(
        id: j['id'] as String? ?? newId(),
        name: j['name'] as String? ?? '',
        args: (j['args'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{},
      );
}

class ChatMessage extends ChangeNotifier {
  ChatMessage({
    String? id,
    required this.role,
    this.text = '',
    List<Attachment>? attachments,
    List<ToolCall>? toolCalls,
    this.toolCallId = '',
    this.toolName = '',
    int? at,
    this.error = false,
    this.model = '',
    List<String>? sources,
    this.note = '',
    List<String>? outputs,
  })  : id = id ?? newId(),
        sources = sources ?? <String>[],
        outputs = outputs ?? <String>[],
        attachments = attachments ?? <Attachment>[],
        toolCalls = toolCalls ?? <ToolCall>[],
        at = at ?? DateTime.now().millisecondsSinceEpoch;

  final String id;

  /// Tells the one message view that shows this message to redraw.
  void touch() => notifyListeners();

  /// user, assistant or tool.
  final String role;
  String text;
  final List<Attachment> attachments;
  final List<ToolCall> toolCalls;
  final String toolCallId;
  final String toolName;
  final int at;
  bool error;
  String model;

  /// Web pages used for this answer, each as "title<TAB>url".
  final List<String> sources;

  /// Shown above the reply but never sent to the model, for example the text read from an image.
  String note;

  /// Files the assistant made for the person (a project ZIP, say), each as "name<TAB>path".
  final List<String> outputs;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'role': role,
        'text': text,
        'attachments': attachments.map((a) => a.toJson()).toList(),
        'toolCalls': toolCalls.map((c) => c.toJson()).toList(),
        'toolCallId': toolCallId,
        'toolName': toolName,
        'at': at,
        'error': error,
        'model': model,
        'sources': sources,
        'note': note,
        'outputs': outputs,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        id: j['id'] as String?,
        role: j['role'] as String? ?? 'user',
        text: j['text'] as String? ?? '',
        attachments: (j['attachments'] as List?)
            ?.whereType<Map>()
            .map((m) => Attachment.fromJson(m.cast<String, dynamic>()))
            .toList(),
        toolCalls: (j['toolCalls'] as List?)
            ?.whereType<Map>()
            .map((m) => ToolCall.fromJson(m.cast<String, dynamic>()))
            .toList(),
        toolCallId: j['toolCallId'] as String? ?? '',
        toolName: j['toolName'] as String? ?? '',
        at: (j['at'] as num?)?.toInt(),
        error: j['error'] as bool? ?? false,
        model: j['model'] as String? ?? '',
        sources: (j['sources'] as List?)?.whereType<String>().toList(),
        note: j['note'] as String? ?? '',
        outputs: (j['outputs'] as List?)?.whereType<String>().toList(),
      );
}

class Conversation {
  Conversation({
    required this.id,
    this.title = 'New chat',
    this.providerId = '',
    this.model = '',
    int? createdAt,
    int? updatedAt,
    List<ChatMessage>? messages,
    List<String>? activeSkillIds,
    this.temporary = false,
    this.web = true,
    this.projectId = '',
  })  : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch,
        updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch,
        messages = messages ?? <ChatMessage>[],
        activeSkillIds = activeSkillIds ?? <String>[];

  final String id;
  String title;
  String providerId;
  String model;
  final int createdAt;
  int updatedAt;
  final List<ChatMessage> messages;
  final List<String> activeSkillIds;

  /// A temporary chat does not use or write memory and is not kept on disk.
  bool temporary;

  /// Search the web before answering.
  bool web;

  /// The project (folder of files) this chat works on, or empty.
  String projectId;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'title': title,
        'providerId': providerId,
        'model': model,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'messages': messages.map((m) => m.toJson()).toList(),
        'activeSkillIds': activeSkillIds,
        'temporary': temporary,
        'web': web,
        'projectId': projectId,
      };

  factory Conversation.fromJson(Map<String, dynamic> j) => Conversation(
        id: j['id'] as String? ?? newId(),
        title: j['title'] as String? ?? 'New chat',
        providerId: j['providerId'] as String? ?? '',
        model: j['model'] as String? ?? '',
        createdAt: (j['createdAt'] as num?)?.toInt(),
        updatedAt: (j['updatedAt'] as num?)?.toInt(),
        messages: (j['messages'] as List?)
            ?.whereType<Map>()
            .map((m) => ChatMessage.fromJson(m.cast<String, dynamic>()))
            .toList(),
        activeSkillIds: (j['activeSkillIds'] as List?)?.whereType<String>().toList(),
        temporary: j['temporary'] as bool? ?? false,
        web: j['web'] as bool? ?? true,
        projectId: j['projectId'] as String? ?? '',
      );
}

/// A skill is a set of instructions plus the tools it may use.
/// Switch one on inside a chat (the bolt), or let the assistant load it by itself when it fits.
class Skill {
  Skill({
    required this.id,
    required this.name,
    this.description = '',
    this.instructions = '',
    List<String>? tools,
    this.enabled = true,
    this.autoUse = false,
  }) : tools = tools ?? <String>[];

  final String id;
  String name;
  String description;
  String instructions;
  List<String> tools;
  bool enabled;
  bool autoUse;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'description': description,
        'instructions': instructions,
        'tools': tools,
        'enabled': enabled,
        'autoUse': autoUse,
      };

  factory Skill.fromJson(Map<String, dynamic> j) => Skill(
        id: j['id'] as String? ?? newId(),
        name: j['name'] as String? ?? '',
        description: j['description'] as String? ?? '',
        instructions: j['instructions'] as String? ?? '',
        tools: (j['tools'] as List?)?.whereType<String>().toList() ?? <String>[],
        enabled: j['enabled'] as bool? ?? true,
        autoUse: j['autoUse'] as bool? ?? false,
      );
}

class MemoryFact {
  MemoryFact({required this.id, required this.text});
  final String id;
  String text;
  Map<String, dynamic> toJson() => <String, dynamic>{'id': id, 'text': text};
  factory MemoryFact.fromJson(Map<String, dynamic> j) =>
      MemoryFact(id: j['id'] as String? ?? newId(), text: j['text'] as String? ?? '');
}

class AppSettings {
  AppSettings({
    this.customInstructions = '',
    this.memoryEnabled = true,
    this.webAlways = true,
    this.themeMode = 'dark',
    this.defaultProviderId = '',
    this.githubToken = '',
    this.githubWrite = false,
    this.pluginGithub = false,
    this.pluginBrowser = false,
    this.pluginGmail = false,
    this.pluginCanva = false,
  });

  String customInstructions;
  bool memoryEnabled;
  bool webAlways;
  String themeMode;
  String defaultProviderId;
  String githubToken;
  bool githubWrite;
  bool pluginGithub;
  bool pluginBrowser;
  bool pluginGmail;
  bool pluginCanva;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'customInstructions': customInstructions,
        'memoryEnabled': memoryEnabled,
        'webAlways': webAlways,
        'themeMode': themeMode,
        'defaultProviderId': defaultProviderId,
        'githubToken': githubToken,
        'githubWrite': githubWrite,
        'pluginGithub': pluginGithub,
        'pluginBrowser': pluginBrowser,
        'pluginGmail': pluginGmail,
        'pluginCanva': pluginCanva,
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        customInstructions: j['customInstructions'] as String? ?? '',
        memoryEnabled: j['memoryEnabled'] as bool? ?? true,
        webAlways: j['webAlways'] as bool? ?? true,
        themeMode: j['themeMode'] as String? ?? 'dark',
        defaultProviderId: j['defaultProviderId'] as String? ?? '',
        githubToken: j['githubToken'] as String? ?? '',
        githubWrite: j['githubWrite'] as bool? ?? false,
        pluginGithub: j['pluginGithub'] as bool? ?? false,
        pluginBrowser: j['pluginBrowser'] as bool? ?? false,
        pluginGmail: j['pluginGmail'] as bool? ?? false,
        pluginCanva: j['pluginCanva'] as bool? ?? false,
      );
}
