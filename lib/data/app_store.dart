import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/models.dart';
import '../plugins/plugin.dart';
import '../agent/agent_models.dart';
import '../tools/tool_registry.dart';

String _encodeChat(Map<String, dynamic> json) => jsonEncode(json);

/// Everything the app remembers, kept on this phone.
class AppStore extends ChangeNotifier {
  SharedPreferences? _prefs;
  Directory? _chatDir;
  Timer? _saveTimer;
  final Set<String> _dirty = <String>{};

  List<ProviderConfig> providers = <ProviderConfig>[];
  List<Skill> skills = <Skill>[];
  List<MemoryFact> memory = <MemoryFact>[];
  List<Plugin> plugins = <Plugin>[];
  AppSettings settings = AppSettings();
  List<Conversation> conversations = <Conversation>[];
  Conversation? current;
  bool loaded = false;

  /// Persisted agent state is kept separate from conversation JSON for backwards compatibility.
  AgentTask? agentTask;
  ToolRegistry toolRegistry = ToolRegistry();

  /// The theme page only needs to rebuild when this changes, not on every chat update.
  final ValueNotifier<String> themeMode = ValueNotifier<String>('dark');

  /// Public wrapper so other classes can refresh listeners.
  void changed() => notifyListeners();

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    final rawAgentTask = prefs.getString('agent_task');
    if (rawAgentTask != null) {
      try {
        agentTask = AgentTask.fromJson((jsonDecode(rawAgentTask) as Map).cast<String, dynamic>());
      } catch (_) {
        agentTask = null;
      }
    }
    final rawToolRegistry = prefs.getString('agent_tool_registry');
    if (rawToolRegistry != null) {
      try {
        toolRegistry = ToolRegistry.fromJson((jsonDecode(rawToolRegistry) as Map).cast<String, dynamic>());
      } catch (_) {
        toolRegistry = ToolRegistry();
      }
    }
    providers = _decodeList(prefs.getString('providers'), ProviderConfig.fromJson);
    skills = _decodeList(prefs.getString('skills'), Skill.fromJson);
    memory = _decodeList(prefs.getString('memory'), MemoryFact.fromJson);
    plugins = _decodeList(prefs.getString('plugins'), Plugin.fromJson);
    final rawSettings = prefs.getString('settings');
    if (rawSettings != null) {
      try {
        settings = AppSettings.fromJson((jsonDecode(rawSettings) as Map).cast<String, dynamic>());
      } catch (_) {}
    }
    if (!(prefs.getBool('seeded') ?? false)) {
      skills = _defaultSkills();
      await prefs.setBool('seeded', true);
      await saveSkills();
    }
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/chats');
    if (!await dir.exists()) await dir.create(recursive: true);
    _chatDir = dir;
    final loadedChats = <Conversation>[];
    for (final f in dir.listSync()) {
      if (f is File && f.path.endsWith('.json')) {
        try {
          final j = jsonDecode(await f.readAsString()) as Map;
          loadedChats.add(Conversation.fromJson(j.cast<String, dynamic>()));
        } catch (_) {}
      }
    }
    loadedChats.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    conversations = loadedChats;
    themeMode.value = settings.themeMode;
    loaded = true;
    notifyListeners();
  }

  List<T> _decodeList<T>(String? raw, T Function(Map<String, dynamic>) make) {
    if (raw == null) return <T>[];
    try {
      final list = jsonDecode(raw) as List;
      return list.whereType<Map>().map((m) => make(m.cast<String, dynamic>())).toList();
    } catch (_) {
      return <T>[];
    }
  }

  List<Skill> _defaultSkills() => <Skill>[
        Skill(
          id: newId(),
          name: 'Researcher',
          description: 'Answer questions that need fresh facts, prices or news by searching the web.',
          instructions: 'Search the web with web_search, then open two to four different sources with fetch_page. '
              'Compare the figures, ignore outliers and spam, and give a clear answer with the sources named. '
              'Say when sources disagree. If something essential is missing, ask one short question first.',
          tools: <String>['web_search', 'fetch_page'],
        ),
        Skill(
          id: newId(),
          name: 'Document analyst',
          description: 'Summarize, compare or extract facts from the files and images the user attached.',
          instructions: 'Work only from the attached files and images. Quote short passages when it helps, '
              'name the file each fact comes from, and say clearly when the files do not contain the answer. '
              'For several files, compare them in a table.',
        ),
        Skill(
          id: newId(),
          name: 'Trilingual translator',
          description: 'Translate between Arabic, English and Russian.',
          instructions: 'Translate the user\'s text between Arabic (Egyptian dialect when informal), English and Russian. '
              'Keep names, numbers and formatting. Give only the translation unless asked to explain.',
          autoUse: true,
        ),
      ];

  // ------------------------------------------------------------ saving

  Future<void> _saveJson(String key, List<Map<String, dynamic>> value) async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    _prefs = prefs;
    await prefs.setString(key, jsonEncode(value));
  }

  Future<void> saveProviders() async {
    await _saveJson('providers', providers.map((p) => p.toJson()).toList());
    notifyListeners();
  }

  Future<void> saveSkills() async {
    await _saveJson('skills', skills.map((s) => s.toJson()).toList());
    notifyListeners();
  }

  Future<void> savePlugins() async {
    await _saveJson('plugins', plugins.map((p) => p.toJson()).toList());
    notifyListeners();
  }

  Future<void> saveMemory() async {
    await _saveJson('memory', memory.map((m) => m.toJson()).toList());
    notifyListeners();
  }

  Future<void> saveAgentState() async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    _prefs = prefs;
    if (agentTask == null) {
      await prefs.remove('agent_task');
    } else {
      await prefs.setString('agent_task', jsonEncode(agentTask!.toJson()));
    }
    await prefs.setString('agent_tool_registry', jsonEncode(toolRegistry.toJson()));
  }

  Future<void> saveSettings() async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    _prefs = prefs;
    await prefs.setString('settings', jsonEncode(settings.toJson()));
    themeMode.value = settings.themeMode;
    notifyListeners();
  }

  void addMemory(String text) {
    final clean = text.trim();
    if (clean.isEmpty) return;
    if (memory.any((m) => m.text.toLowerCase() == clean.toLowerCase())) return;
    memory.add(MemoryFact(id: newId(), text: clean));
    saveMemory();
  }

  // ------------------------------------------------------ providers

  ProviderConfig? providerById(String id) {
    for (final p in providers) {
      if (p.id == id) return p;
    }
    return null;
  }

  ProviderConfig? get defaultProvider {
    final byId = providerById(settings.defaultProviderId);
    if (byId != null) return byId;
    return providers.isEmpty ? null : providers.first;
  }

  // -------------------------------------------------- conversations

  Conversation newConversation({bool temporary = false}) {
    final p = defaultProvider;
    final c = Conversation(
      id: newId(),
      providerId: p?.id ?? '',
      model: p?.model ?? '',
      temporary: temporary,
      web: settings.webAlways,
    );
    current = c;
    notifyListeners();
    return c;
  }

  void openConversation(Conversation c) {
    current = c;
    notifyListeners();
  }

  /// Saves soon; a burst of changes becomes one write.
  void scheduleSave(Conversation c) {
    if (c.temporary || c.messages.isEmpty) return;
    c.updatedAt = DateTime.now().millisecondsSinceEpoch;
    if (!conversations.contains(c)) conversations.insert(0, c);
    _dirty.add(c.id);
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), flush);
  }

  Future<void> flush() async {
    final dir = _chatDir;
    if (dir == null) return;
    final ids = _dirty.toList();
    _dirty.clear();
    for (final id in ids) {
      Conversation? c;
      for (final x in conversations) {
        if (x.id == id) c = x;
      }
      if (c == null) continue;
      try {
        final text = await compute(_encodeChat, c.toJson());
        await File('${dir.path}/$id.json').writeAsString(text);
      } catch (_) {}
    }
    conversations.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    notifyListeners();
  }

  Future<void> deleteConversation(Conversation c) async {
    conversations.remove(c);
    if (identical(current, c)) current = null;
    final dir = _chatDir;
    if (dir != null) {
      try {
        final f = File('${dir.path}/${c.id}.json');
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    for (final m in c.messages) {
      for (final a in m.attachments) {
        if (a.path.isNotEmpty) {
          try {
            final f = File(a.path);
            if (await f.exists()) await f.delete();
          } catch (_) {}
        }
      }
    }
    notifyListeners();
  }
}
