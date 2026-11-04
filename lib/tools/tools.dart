import '../core/models.dart';
import '../llm/llm.dart';
import 'browser_service.dart';
import 'github_tools.dart';
import 'web_tools.dart';

/// Everything a tool needs from the app while it runs.
abstract class ToolHost {
  List<Skill> get skills;
  void addMemory(String text);
  void loadSkill(Skill skill);
  bool get memoryAllowed;
  String get githubToken;
}

class ToolDef {
  const ToolDef({required this.id, required this.title, required this.spec, required this.run, this.group = 'core'});

  final String id;
  final String title;
  final ToolSpec spec;
  /// core, web, browser or github: decides which switch turns the tool on.
  final String group;
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
    group: 'web',
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
    group: 'web',
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
    id: 'browse_page',
    title: 'Built-in browser',
    group: 'browser',
    spec: ToolSpec(
      name: 'browse_page',
      description: 'Open a page in a real browser that runs JavaScript and return the text it shows. '
          'Use it for prices, stock, scores and other live data that fetch_page cannot see.',
      parameters: _schema(<String, Map<String, String>>{
        'url': <String, String>{'type': 'string', 'description': 'Full https URL'},
      }, <String>['url']),
    ),
    run: (args, host) async {
      final url = (args['url'] ?? '').toString();
      try {
        final text = await BrowserService.instance.render(url);
        if (text.trim().isNotEmpty) return text;
      } catch (_) {}
      return WebTools.fetchText(url, maxChars: 9000);
    },
  ),
  ToolDef(
    id: 'github_search',
    title: 'GitHub search',
    group: 'github',
    spec: ToolSpec(
      name: 'github_search',
      description: 'Search GitHub. type is repositories (default), code or issues.',
      parameters: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'query': <String, String>{'type': 'string', 'description': 'GitHub search query'},
          'type': <String, dynamic>{
            'type': 'string',
            'enum': <String>['repositories', 'code', 'issues'],
          },
        },
        'required': <String>['query'],
      },
    ),
    run: (args, host) => GithubTools.search(
        (args['query'] ?? '').toString(), (args['type'] ?? 'repositories').toString(), host.githubToken),
  ),
  ToolDef(
    id: 'github_repo',
    title: 'GitHub repository',
    group: 'github',
    spec: ToolSpec(
      name: 'github_repo',
      description: 'Overview of a GitHub repository: stats, file list and README.',
      parameters: _schema(<String, Map<String, String>>{
        'repo': <String, String>{'type': 'string', 'description': 'owner/name or a github.com URL'},
      }, <String>['repo']),
    ),
    run: (args, host) => GithubTools.repo((args['repo'] ?? '').toString(), host.githubToken),
  ),
  ToolDef(
    id: 'github_file',
    title: 'GitHub file',
    group: 'github',
    spec: ToolSpec(
      name: 'github_file',
      description: 'Read one file (or list a folder) of a GitHub repository.',
      parameters: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'repo': <String, String>{'type': 'string', 'description': 'owner/name'},
          'path': <String, String>{'type': 'string', 'description': 'File or folder path'},
          'ref': <String, String>{'type': 'string', 'description': 'Branch, tag or commit (optional)'},
        },
        'required': <String>['repo', 'path'],
      },
    ),
    run: (args, host) => GithubTools.file((args['repo'] ?? '').toString(), (args['path'] ?? '').toString(),
        (args['ref'] ?? '').toString(), host.githubToken),
  ),
  ToolDef(
    id: 'github_issues',
    title: 'GitHub issues and PRs',
    group: 'github',
    spec: ToolSpec(
      name: 'github_issues',
      description: 'List issues and pull requests of a repository, or read one with its comments by number.',
      parameters: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'repo': <String, String>{'type': 'string', 'description': 'owner/name'},
          'state': <String, dynamic>{
            'type': 'string',
            'enum': <String>['open', 'closed', 'all'],
          },
          'number': <String, String>{'type': 'integer', 'description': 'Issue or PR number (optional)'},
        },
        'required': <String>['repo'],
      },
    ),
    run: (args, host) => GithubTools.issues((args['repo'] ?? '').toString(), (args['state'] ?? 'open').toString(),
        int.tryParse((args['number'] ?? '0').toString()) ?? 0, host.githubToken),
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
