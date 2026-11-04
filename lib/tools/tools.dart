import '../core/models.dart';
import '../llm/llm.dart';
import 'web_tools.dart';

/// Everything a tool needs from the app while it runs.
abstract class ToolHost {
  List<Skill> get skills;
  void addMemory(String text);
  void loadSkill(Skill skill);
  bool get memoryAllowed;
}

class ToolDef {
  const ToolDef({required this.id, required this.title, required this.spec, required this.run, this.web = false});

  final String id;
  final String title;
  final ToolSpec spec;
  final bool web;
  final Future<String> Function(Map<String, dynamic> args, ToolHost host) run;
}

Map<String, dynamic> _schema(Map<String, Map<String, String>> props, List<String> required) => <String, dynamic>{
      'type': 'object',
      'properties': props,
      'required': required,
    };

final List<ToolDef> builtinTools = <ToolDef>[
  ToolDef(
    id: 'web_search',
    title: 'Web search',
    web: true,
    spec: ToolSpec(
      name: 'web_search',
      description: 'Search the web. Returns numbered results with title, URL and a snippet.',
      parameters: _schema(<String, Map<String, String>>{
        'query': <String, String>{'type': 'string', 'description': 'What to search for'},
      }, <String>['query']),
    ),
    run: (args, host) => WebTools.search((args['query'] ?? '').toString()),
  ),
  ToolDef(
    id: 'fetch_page',
    title: 'Read a web page',
    web: true,
    spec: ToolSpec(
      name: 'fetch_page',
      description: 'Open a web page and return its readable text.',
      parameters: _schema(<String, Map<String, String>>{
        'url': <String, String>{'type': 'string', 'description': 'Full https URL'},
      }, <String>['url']),
    ),
    run: (args, host) => WebTools.fetchText((args['url'] ?? '').toString()),
  ),
  ToolDef(
    id: 'current_time',
    title: 'Current date and time',
    spec: const ToolSpec(
      name: 'current_time',
      description: 'The current local date, time and time zone of the user.',
      parameters: <String, dynamic>{'type': 'object', 'properties': <String, dynamic>{}},
    ),
    run: (args, host) async {
      final now = DateTime.now();
      return '${now.toIso8601String()} (UTC offset ${now.timeZoneOffset.inHours}h, ${now.timeZoneName})';
    },
  ),
  ToolDef(
    id: 'remember',
    title: 'Remember facts about you',
    spec: ToolSpec(
      name: 'remember',
      description: 'Save one short durable fact about the user (name, job, preferences). '
          'Only when the user asks to remember something or shares a lasting personal fact.',
      parameters: _schema(<String, Map<String, String>>{
        'fact': <String, String>{'type': 'string', 'description': 'One short sentence'},
      }, <String>['fact']),
    ),
    run: (args, host) async {
      if (!host.memoryAllowed) return 'Memory is off for this chat.';
      final fact = (args['fact'] ?? '').toString().trim();
      if (fact.isEmpty) return 'Nothing to save.';
      host.addMemory(fact);
      return 'Saved.';
    },
  ),
];

ToolDef? toolById(String id) {
  for (final t in builtinTools) {
    if (t.id == id) return t;
  }
  return null;
}

const ToolSpec useSkillSpec = ToolSpec(
  name: 'use_skill',
  description: 'Load the full instructions of one of the listed skills when it fits the request.',
  parameters: <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'name': <String, dynamic>{'type': 'string', 'description': 'Exact skill name from the list'},
    },
    'required': <String>['name'],
  },
);

/// Runs one tool call and returns text for the model. Never throws.
Future<String> runTool(ToolCall call, ToolHost host) async {
  try {
    if (call.name == 'use_skill') {
      final wanted = (call.args['name'] ?? '').toString().trim().toLowerCase();
      for (final s in host.skills) {
        if (s.enabled && s.name.trim().toLowerCase() == wanted) {
          host.loadSkill(s);
          return 'Skill "${s.name}" loaded. Follow these instructions now:\n\n${s.instructions}';
        }
      }
      return 'No skill named "${call.args['name']}".';
    }
    final def = toolById(call.name);
    if (def == null) return 'Unknown tool: ${call.name}';
    final out = await def.run(call.args, host);
    return out.length > 12000 ? out.substring(0, 12000) : out;
  } catch (e) {
    return 'Tool failed: $e';
  }
}
