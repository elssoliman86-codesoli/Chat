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
    Map<String, String>? reasoningEffort,
  })  : models = models ?? <String>[],
        noVision = noVision ?? <String>[],
        health = health ?? <String, int>{},
        reasoningEffort = reasoningEffort ?? <String, String>{};

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

  /// Extra "thinking"/reasoning effort per model name: '' (off/default), 'low', 'high' or 'max'.
  /// Only models that support it use it; sent as the provider's own equivalent (reasoning_effort for
  /// OpenAI-compatible, a thinking token budget for Anthropic and Gemini).
  Map<String, String> reasoningEffort;

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
        'reasoningEffort': reasoningEffort,
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
        reasoningEffort: (j['reasoningEffort'] as Map?)?.map((k, v) => MapEntry(k.toString(), v.toString())),
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
    this.thinking = '',
    this.thinkingSignature = '',
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

  /// Anthropic extended-thinking block for this reply (its text and signature), kept so it can be
  /// replayed verbatim if the conversation continues with thinking still enabled — required for the
  /// next request to that model to stay valid when the earlier turn used a tool.
  String thinking;
  String thinkingSignature;

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
        'thinking': thinking,
        'thinkingSignature': thinkingSignature,
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
        thinking: j['thinking'] as String? ?? '',
        thinkingSignature: j['thinkingSignature'] as String? ?? '',
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
    this.turnInProgress = false,
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

  /// True from the moment a turn starts running until it genuinely concludes (an answer, an error, or
  /// a manual stop) — saved to disk as the turn runs, not just at the end. If this is still true the
  /// next time the conversation loads, the app process was killed mid-turn (backgrounded and reclaimed,
  /// force-closed, crashed): whatever the model was doing is really there in messages, not lost, but
  /// never got to finish. continueReply() is what resumes it correctly from here.
  bool turnInProgress;

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
        'turnInProgress': turnInProgress,
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
        turnInProgress: j['turnInProgress'] as bool? ?? false,
      );
}

/// A reusable capability: instructions the assistant follows, plus the tools it may use.
class Skill {
  Skill({
    required this.id,
    required this.name,
    this.description = '',
    this.instructions = '',
    List<String>? tools,
    this.autoUse = true,
    this.enabled = true,
    this.alwaysOn = false,
    this.source = '',
  }) : tools = tools ?? <String>[];

  final String id;
  String name;
  String description;
  String instructions;

  /// Where this skill came from, for grouping the Skills list into folders: a GitHub "owner/repo"
  /// (or a site's host for a direct SKILL.md link) when installed with install_skills/install_plugin,
  /// or empty for a skill written or pasted by hand (create_skill, pasted text, a ZIP), which is
  /// grouped under a single "Manual" folder.
  String source;

  /// Tool ids from the built-in tool list.
  List<String> tools;

  /// When alwaysOn is off, let the assistant load it by itself (with the use_skill tool) when it fits.
  bool autoUse;
  bool enabled;

  /// Always put the full instructions in every conversation's prompt, instead of waiting for the
  /// assistant to decide to load it that turn. Set once by the person, or automatically the first
  /// time the assistant loads this skill with use_skill (see ChatEngine.loadSkill), so a skill the
  /// assistant has actually found useful once becomes a fixed part of how it behaves from then on.
  bool alwaysOn;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'description': description,
        'instructions': instructions,
        'tools': tools,
        'autoUse': autoUse,
        'enabled': enabled,
        'alwaysOn': alwaysOn,
        'source': source,
      };

  factory Skill.fromJson(Map<String, dynamic> j) => Skill(
        id: j['id'] as String? ?? newId(),
        name: j['name'] as String? ?? 'Skill',
        description: j['description'] as String? ?? '',
        instructions: j['instructions'] as String? ?? '',
        tools: (j['tools'] as List?)?.whereType<String>().toList(),
        autoUse: j['autoUse'] as bool? ?? true,
        enabled: j['enabled'] as bool? ?? true,
        alwaysOn: j['alwaysOn'] as bool? ?? false,
        source: j['source'] as String? ?? '',
      );
}

class MemoryFact {
  MemoryFact({required this.id, required this.text});

  final String id;
  final String text;

  Map<String, dynamic> toJson() => <String, dynamic>{'id': id, 'text': text};

  factory MemoryFact.fromJson(Map<String, dynamic> j) =>
      MemoryFact(id: j['id'] as String? ?? newId(), text: j['text'] as String? ?? '');
}

/// App-wide preferences.
class AppSettings {
  AppSettings({
    this.themeMode = 'dark',
    this.customInstructions = '',
    this.temperature,
    this.webTools = true,
    this.memoryEnabled = true,
    this.selfImprove = true,
    this.maxAttachments = 20,
    this.maxToolSteps = 100,
    this.defaultProviderId = '',
    this.webAlways = true,
    this.pluginGithub = true,
    this.pluginBrowser = true,
    this.githubWrite = true,
    this.githubToken = '',
    this.pluginGmail = false,
    this.pluginCanva = false,
    this.pluginFacebook = false,
    this.pluginInstagram = false,
    this.pluginYoutube = false,
    this.imageReader = 'helper',
    this.helperProviderId = '',
    this.helperModel = '',
    this.browserVisible = false,
    this.keepAlive = true,
    this.termuxTools = false,
    List<String>? favorites,
  }) : favorites = favorites ?? <String>[];

  /// system, dark or light.
  String themeMode;
  String customInstructions;

  /// null leaves the provider default.
  double? temperature;
  bool webTools;
  bool memoryEnabled;
  /// Whether the model can record lasting operational lessons (mistakes fixed, approaches that
  /// worked, corrections about how to work) that get fed back into every future chat regardless of
  /// which model answers it — the app's own memory of what worked, not the model's training.
  bool selfImprove;
  int maxAttachments;
  int maxToolSteps;
  String defaultProviderId;

  /// New chats search the web before answering.
  bool webAlways;
  bool pluginGithub;
  bool pluginBrowser;

  /// Let the assistant commit, open pull requests and issues with the token.
  bool githubWrite;
  String githubToken;
  bool pluginGmail;
  bool pluginCanva;

  /// Facebook, Instagram and YouTube through the built-in browser, the same pattern as Gmail/Canva.
  bool pluginFacebook;
  bool pluginInstagram;
  bool pluginYoutube;

  /// How images are read for models that cannot see: off, helper (another model) or lens (Google Lens in the browser).
  String imageReader;
  String helperProviderId;
  String helperModel;

  /// Show the browser panel while the assistant works in it. Off: it works in the background.
  bool browserVisible;

  /// Keep long tasks running when the app is in the background.
  bool keepAlive;

  /// Let the assistant run real shell commands through a separately installed Termux app (off by
  /// default: unlike the other tools, this reaches a real Linux environment on the device, not a sandbox).
  bool termuxTools;

  /// Favorite models, each as "providerId|model".
  List<String> favorites;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'themeMode': themeMode,
        'customInstructions': customInstructions,
        'temperature': temperature,
        'webTools': webTools,
        'memoryEnabled': memoryEnabled,
        'selfImprove': selfImprove,
        'maxAttachments': maxAttachments,
        'maxToolSteps': maxToolSteps,
        'defaultProviderId': defaultProviderId,
        'webAlways': webAlways,
        'pluginGithub': pluginGithub,
        'pluginBrowser': pluginBrowser,
        'githubWrite': githubWrite,
        'githubToken': githubToken,
        'pluginGmail': pluginGmail,
        'pluginCanva': pluginCanva,
        'pluginFacebook': pluginFacebook,
        'pluginInstagram': pluginInstagram,
        'pluginYoutube': pluginYoutube,
        'imageReader': imageReader,
        'helperProviderId': helperProviderId,
        'helperModel': helperModel,
        'browserVisible': browserVisible,
        'keepAlive': keepAlive,
        'termuxTools': termuxTools,
        'favorites': favorites,
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        themeMode: j['themeMode'] as String? ?? 'dark',
        customInstructions: j['customInstructions'] as String? ?? '',
        temperature: (j['temperature'] as num?)?.toDouble(),
        webTools: j['webTools'] as bool? ?? true,
        memoryEnabled: j['memoryEnabled'] as bool? ?? true,
        selfImprove: j['selfImprove'] as bool? ?? true,
        maxAttachments: (j['maxAttachments'] as num?)?.toInt() ?? 20,
        maxToolSteps: _steps((j['maxToolSteps'] as num?)?.toInt()),
        defaultProviderId: j['defaultProviderId'] as String? ?? '',
        webAlways: j['webAlways'] as bool? ?? true,
        pluginGithub: j['pluginGithub'] as bool? ?? true,
        pluginBrowser: j['pluginBrowser'] as bool? ?? true,
        githubWrite: j['githubWrite'] as bool? ?? true,
        githubToken: j['githubToken'] as String? ?? '',
        pluginGmail: j['pluginGmail'] as bool? ?? false,
        pluginCanva: j['pluginCanva'] as bool? ?? false,
        pluginFacebook: j['pluginFacebook'] as bool? ?? false,
        pluginInstagram: j['pluginInstagram'] as bool? ?? false,
        pluginYoutube: j['pluginYoutube'] as bool? ?? false,
        imageReader: j['imageReader'] as String? ?? 'helper',
        helperProviderId: j['helperProviderId'] as String? ?? '',
        helperModel: j['helperModel'] as String? ?? '',
        browserVisible: j['browserVisible'] as bool? ?? false,
        keepAlive: j['keepAlive'] as bool? ?? true,
        termuxTools: j['termuxTools'] as bool? ?? false,
        favorites: (j['favorites'] as List?)?.whereType<String>().toList(),
      );
}

/// The old defaults of 8 and 20 steps are too small for agent and project tasks, so they become 30.
int _steps(int? saved) => (saved == null || saved == 8 || saved == 20 || saved == 30) ? 100 : saved;

String prettyJson(Object? value) => const JsonEncoder.withIndent('  ').convert(value);
