import 'package:flutter/services.dart';

import '../core/models.dart';
import '../llm/llm.dart';
import '../plugins/installer.dart';
import '../plugins/plugin.dart';
import '../projects/project_tools.dart';
import 'browser_service.dart';
import 'github_tools.dart';
import 'python_runtime.dart';
import 'termux_service.dart';
import 'web_tools.dart';

/// Everything a tool needs from the app while it runs.
abstract class ToolHost {
  List<Skill> get skills;
  void addMemory(String text);
  /// Removes every remembered fact whose text contains [query] (case-insensitive); returns how many.
  int forgetMemory(String query);
  List<MemoryFact> get memory;
  /// Records a lasting operational lesson (not a fact about the user) that persists across every
  /// future chat regardless of which model answers it.
  void addLesson(String text);
  /// Removes every learned lesson whose text contains [query] (case-insensitive); returns how many.
  int forgetLesson(String query);
  List<MemoryFact> get lessons;
  bool get selfImproveAllowed;
  void loadSkill(Skill skill);
  bool get memoryAllowed;
  String get githubToken;
  void installSkill(Skill skill);
  void registerPlugin(Plugin plugin);

  /// Asks the person to approve a risky action.
  Future<bool> confirm(String message);

  /// Pauses the task and asks the person to do something or answer; returns what they said.
  Future<String> askUser(String question);

  /// True once Settings > Plugins > Assistant model has a provider/model configured.
  bool get advisorConfigured;

  /// Sends [question] to the configured second-opinion model and returns its full plain-text answer.
  Future<String> askAdvisor(String question);

  /// Runs a tool that belongs to an installed plugin, or returns null when [name] is not one.
  Future<String?> runPluginTool(String name, Map<String, dynamic> args);

  /// The project (folder of files) of the running chat, or empty.
  String get projectId;

  /// Makes [id] the project of the running chat.
  void useProject(String id);

  /// Attaches a file made by a tool to the assistant's reply so the person can save it.
  void deliver(String name, String path);
}

Map<String, dynamic> _obj(Map<String, dynamic> props, [List<String> required = const <String>[]]) =>
    <String, dynamic>{'type': 'object', 'properties': props, 'required': required};

Map<String, dynamic> _str(String description) => <String, dynamic>{'type': 'string', 'description': description};

String _s(Map<String, dynamic> a, String k) => (a[k] ?? '').toString();
int _i(Map<String, dynamic> a, String k) => int.tryParse((a[k] ?? '0').toString()) ?? 0;


String _shellQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";

Future<String> _runTermuxCommand(String command, {String? workdir, int timeoutSeconds = 60}) async {
  if (command.trim().isEmpty) return 'No command was given.';
  if (!await TermuxService.instance.isInstalled()) {
    return 'Termux is not installed or the Android Termux bridge is unavailable.';
  }
  if (!await TermuxService.instance.hasPermission()) {
    final granted = await TermuxService.instance.requestPermission();
    if (!granted) {
      return 'Termux permission was not granted. Enable "Run commands in Termux environment" for this app and set allow-external-apps = true in ~/.termux/termux.properties inside Termux.';
    }
  }
  final seconds = timeoutSeconds < 1 ? 1 : (timeoutSeconds > 300 ? 300 : timeoutSeconds);
  try {
    final result = await TermuxService.instance.run(
      command,
      workdir: workdir,
      timeout: Duration(seconds: seconds),
    );
    final stdout = (result['stdout'] ?? '').toString();
    final stderr = (result['stderr'] ?? '').toString();
    final exitCode = result['exitCode'];
    final error = (result['errmsg'] ?? '').toString();
    final err = result['err'] is int ? result['err'] as int : int.tryParse('${result['err']}') ?? 0;
    if (err != 0 && exitCode == -1) {
      // Termux itself failed to run the command at all (not installed/permitted/set up), rather than
      // the command running and returning a non-zero exit — don't report a fake exit code for that.
      return 'Termux could not run the command${error.isNotEmpty ? ': $error' : ' (no further detail given).'}'
          '\n\nThis usually means `allow-external-apps = true` is missing from ~/.termux/termux.properties inside '
          'Termux (a one-time setup only the user can do there).';
    }
    final out = StringBuffer('exit code: $exitCode');
    if (error.isNotEmpty) out.write('\nTermux error: $error');
    if (stdout.trim().isNotEmpty) out.write('\n\nstdout:\n${stdout.trim()}');
    if (stderr.trim().isNotEmpty) out.write('\n\nstderr:\n${stderr.trim()}');
    return out.toString();
  } on PlatformException catch (e) {
    return e.code == 'timeout'
        ? 'Termux command timed out after ${seconds}s.'
        : 'Could not run the command in Termux: ${e.message ?? e.code}';
  } catch (e) {
    return 'Could not reach Termux: $e';
  }
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
    id: 'github_tree',
    title: 'GitHub file tree',
    group: 'github',
    spec: ToolSpec(
      name: 'github_tree',
      description: 'List every file of a repository (path and size). Use it first to understand and analyze a project.',
      parameters: _obj(<String, dynamic>{'repo': _str('owner/name'), 'ref': _str('Branch or tag (optional)')}, <String>['repo']),
    ),
    run: (a, host) => GithubTools.tree(_s(a, 'repo'), _s(a, 'ref'), host.githubToken),
  ),
  ToolDef(
    id: 'github_commits',
    title: 'GitHub commit history',
    group: 'github',
    spec: ToolSpec(
      name: 'github_commits',
      description: 'Recent commits of a repository, optionally for one branch or file path.',
      parameters: _obj(<String, dynamic>{'repo': _str('owner/name'), 'branch': _str('Branch (optional)'), 'path': _str('File path (optional)')}, <String>['repo']),
    ),
    run: (a, host) => GithubTools.commits(_s(a, 'repo'), _s(a, 'branch'), _s(a, 'path'), host.githubToken),
  ),
  ToolDef(
    id: 'github_branches',
    title: 'GitHub branches',
    group: 'github',
    spec: ToolSpec(
      name: 'github_branches',
      description: 'List the branches of a repository.',
      parameters: _obj(<String, dynamic>{'repo': _str('owner/name')}, <String>['repo']),
    ),
    run: (a, host) => GithubTools.branches(_s(a, 'repo'), host.githubToken),
  ),
  ToolDef(
    id: 'github_runs',
    title: 'GitHub Actions runs',
    group: 'github',
    spec: ToolSpec(
      name: 'github_runs',
      description: 'Latest GitHub Actions workflow runs with their status.',
      parameters: _obj(<String, dynamic>{'repo': _str('owner/name')}, <String>['repo']),
    ),
    run: (a, host) => GithubTools.runs(_s(a, 'repo'), host.githubToken),
  ),
  ToolDef(
    id: 'github_commit',
    title: 'GitHub commit (edit files)',
    group: 'github_write',
    spec: ToolSpec(
      name: 'github_commit',
      description: 'Edit a repository: create, change or delete several files in ONE commit. Give the COMPLETE new content '
          'of every file in files (never a fragment). The branch is created from base_branch (default branch) when it does not exist.',
      parameters: _obj(<String, dynamic>{
        'repo': _str('owner/name'),
        'branch': _str('Branch to commit to'),
        'message': _str('Commit message'),
        'files': <String, dynamic>{
          'type': 'array',
          'description': 'Files to create or overwrite',
          'items': _obj(<String, dynamic>{'path': _str('Path in the repo'), 'content': _str('Complete file content')}, <String>['path', 'content']),
        },
        'deletes': <String, dynamic>{
          'type': 'array',
          'description': 'Paths to delete',
          'items': <String, dynamic>{'type': 'string'},
        },
        'base_branch': _str('Branch to start from when creating a new branch (optional)'),
      }, <String>['repo', 'branch', 'message']),
    ),
    run: (a, host) => GithubTools.commit(
      _s(a, 'repo'),
      _s(a, 'branch'),
      _s(a, 'message'),
      (a['files'] as List?) ?? <dynamic>[],
      (a['deletes'] as List?) ?? <dynamic>[],
      _s(a, 'base_branch'),
      host.githubToken,
    ),
  ),
  ToolDef(
    id: 'github_create_pr',
    title: 'GitHub pull request',
    group: 'github_write',
    spec: ToolSpec(
      name: 'github_create_pr',
      description: 'Open a pull request from a branch.',
      parameters: _obj(<String, dynamic>{
        'repo': _str('owner/name'),
        'title': _str('PR title'),
        'head': _str('Branch with the changes'),
        'base': _str('Target branch (default branch if empty)'),
        'body': _str('Description'),
      }, <String>['repo', 'title', 'head']),
    ),
    run: (a, host) => GithubTools.createPr(_s(a, 'repo'), _s(a, 'title'), _s(a, 'head'), _s(a, 'base'), _s(a, 'body'), host.githubToken),
  ),
  ToolDef(
    id: 'github_merge_pr',
    title: 'GitHub merge pull request',
    group: 'github_write',
    spec: ToolSpec(
      name: 'github_merge_pr',
      description: 'Merge a pull request. The person is asked to approve first.',
      parameters: _obj(<String, dynamic>{
        'repo': _str('owner/name'),
        'number': <String, dynamic>{'type': 'integer', 'description': 'PR number'},
        'method': <String, dynamic>{'type': 'string', 'enum': <String>['squash', 'merge', 'rebase']},
      }, <String>['repo', 'number']),
    ),
    run: (a, host) async {
      final ok = await host.confirm('Merge pull request #${_i(a, 'number')} in ${_s(a, 'repo')}?');
      if (!ok) return 'The person declined the merge.';
      return GithubTools.mergePr(_s(a, 'repo'), _i(a, 'number'), _s(a, 'method'), host.githubToken);
    },
  ),
  ToolDef(
    id: 'github_create_issue',
    title: 'GitHub new issue',
    group: 'github_write',
    spec: ToolSpec(
      name: 'github_create_issue',
      description: 'Create an issue.',
      parameters: _obj(<String, dynamic>{
        'repo': _str('owner/name'),
        'title': _str('Title'),
        'body': _str('Description'),
        'labels': <String, dynamic>{'type': 'array', 'items': <String, dynamic>{'type': 'string'}},
      }, <String>['repo', 'title']),
    ),
    run: (a, host) => GithubTools.createIssue(
        _s(a, 'repo'), _s(a, 'title'), _s(a, 'body'), (a['labels'] as List?) ?? <dynamic>[], host.githubToken),
  ),
  ToolDef(
    id: 'github_comment',
    title: 'GitHub comment',
    group: 'github_write',
    spec: ToolSpec(
      name: 'github_comment',
      description: 'Comment on an issue or pull request.',
      parameters: _obj(<String, dynamic>{
        'repo': _str('owner/name'),
        'number': <String, dynamic>{'type': 'integer', 'description': 'Issue or PR number'},
        'body': _str('Comment text'),
      }, <String>['repo', 'number', 'body']),
    ),
    run: (a, host) => GithubTools.comment(_s(a, 'repo'), _i(a, 'number'), _s(a, 'body'), host.githubToken),
  ),
  ToolDef(
    id: 'github_create_repo',
    title: 'GitHub new repository',
    group: 'github_write',
    spec: ToolSpec(
      name: 'github_create_repo',
      description: 'Create a new repository for the token owner. The person is asked to approve first.',
      parameters: _obj(<String, dynamic>{
        'name': _str('Repository name'),
        'description': _str('Short description'),
        'private': <String, dynamic>{'type': 'boolean'},
      }, <String>['name']),
    ),
    run: (a, host) async {
      final ok = await host.confirm('Create repository "${_s(a, 'name')}" on GitHub?');
      if (!ok) return 'The person declined.';
      return GithubTools.createRepo(_s(a, 'name'), _s(a, 'description'), a['private'] == true, host.githubToken);
    },
  ),
  ToolDef(
    id: 'install_skills',
    title: 'Install skills from a repo',
    group: 'install',
    spec: ToolSpec(
      name: 'install_skills',
      description: 'Install skills into this app. source is a GitHub repo (owner/name or link, a /tree/branch/folder link works) '
          'or a link to one SKILL.md file. Every SKILL.md found becomes a skill the person can call with /name.',
      parameters: _obj(<String, dynamic>{'source': _str('GitHub repo or SKILL.md link')}, <String>['source']),
    ),
    run: (a, host) => installSkillsFrom(host, _s(a, 'source')),
  ),
  ToolDef(
    id: 'create_skill',
    title: 'Create a skill',
    group: 'install',
    spec: ToolSpec(
      name: 'create_skill',
      description: 'Create or update a skill in this app from text the person gave you.',
      parameters: _obj(<String, dynamic>{
        'name': _str('Short name'),
        'description': _str('One line: when to use it'),
        'instructions': _str('Full instructions'),
        'tools': <String, dynamic>{'type': 'array', 'items': <String, dynamic>{'type': 'string'}, 'description': 'Tool ids it may use (optional)'},
      }, <String>['name', 'instructions']),
    ),
    run: (a, host) async {
      final skill = Skill(
        id: newId(),
        name: _s(a, 'name'),
        description: _s(a, 'description'),
        instructions: _s(a, 'instructions'),
        tools: ((a['tools'] as List?) ?? <dynamic>[]).map((e) => e.toString()).toList(),
      );
      host.installSkill(skill);
      return 'Skill "${skill.name}" saved. The person can call it with /name.';
    },
  ),
  ToolDef(
    id: 'install_plugin',
    title: 'Install a plugin',
    group: 'install',
    spec: ToolSpec(
      name: 'install_plugin',
      description: 'Install a plugin into this app from a link: a remote MCP server URL, a plugin.json link, or a GitHub repo '
          'that contains plugin.json or SKILL.md files. token is an optional access token for the plugin.',
      parameters: _obj(<String, dynamic>{
        'url': _str('MCP server URL, plugin.json URL or GitHub repo'),
        'token': _str('Access token if the plugin needs one (optional)'),
        'name': _str('Name to show (optional)'),
      }, <String>['url']),
    ),
    run: (a, host) => installPluginFrom(host, _s(a, 'url'), _s(a, 'token'), _s(a, 'name')),
  ),
  ToolDef(
    id: 'ask_user',
    title: 'Ask the person',
    group: 'core',
    spec: ToolSpec(
      name: 'ask_user',
      description: 'Stop and ask the person. Use it when you need their permission, a login or captcha done by hand, '
          'a choice, or missing information. Returns what they answered.',
      parameters: _obj(<String, dynamic>{'question': _str('What you need from them, short and clear')}, <String>['question']),
    ),
    run: (a, host) => host.askUser(_s(a, 'question')),
  ),
  ToolDef(
    id: 'ask_advisor',
    title: 'Ask the assistant model',
    group: 'advisor',
    spec: ToolSpec(
      name: 'ask_advisor',
      description: 'Ask a second, separately-configured AI model (the person\'s own "assistant model", set up in Settings > '
          'Plugins) for a second opinion — use this when your own judgement on something real feels weak or you are genuinely '
          'stuck (a command keeps failing and you are not sure why, an error is confusing, you are unsure which of two real '
          'approaches to take), not for ordinary questions you can already answer yourself. Give it the real, specific context '
          'it needs to actually help — the exact command, its full real output, the error, what you already tried — not a vague '
          'summary. Its answer comes back as plain text; if it lays out more than one step, carry them out for real yourself, '
          'one at a time, the same way you would with your own plan — do not just relay its words back to the person as if that '
          'were the work done.',
      parameters: _obj(<String, dynamic>{
        'question': _str('The real context and question — specific enough that a second model with no other context could act on it'),
      }, <String>['question']),
    ),
    run: (a, host) async {
      if (!host.advisorConfigured) return 'No assistant model is configured. Tell the person to set one in Settings > Plugins > Assistant model.';
      return host.askAdvisor(_s(a, 'question'));
    },
  ),
  ToolDef(
    id: 'set_plan',
    title: 'Show the plan',
    group: 'core',
    spec: ToolSpec(
      name: 'set_plan',
      description: 'Show the person a short structured plan for this task: a card above the chat listing the real steps, with a '
          'checkmark on finished ones, a spinner on the one in progress, and the rest shown ahead — tap to open it. Call it once near '
          'the start of a multi-step task with the full ordered list of steps and current set to 0, then call it again with the same '
          'steps and an updated current every time a step actually finishes (current equal to the number of steps once everything is '
          'done). Never use it for a single quick action, and never also narrate the plan in your reply text — this replaces that.',
      parameters: _obj(<String, dynamic>{
        'steps': <String, dynamic>{
          'type': 'array',
          'description': 'The ordered, real steps for this task, short (a few words each)',
          'items': <String, dynamic>{'type': 'string'},
        },
        'current': <String, dynamic>{
          'type': 'integer',
          'description': '0-based index of the step actively in progress; steps before it are done, after it are still ahead. '
              'Equal to the number of steps once every step is actually finished.',
        },
      }, <String>['steps', 'current']),
    ),
    run: (a, host) async {
      final steps = (a['steps'] as List?)?.length ?? 0;
      return steps == 0 ? 'No steps given.' : 'Plan shown to the person ($steps step${steps == 1 ? '' : 's'}).';
    },
  ),
  ToolDef(
    id: 'browser_open',
    title: 'Browser: open a page',
    group: 'browser',
    spec: ToolSpec(
      name: 'browser_open',
      description: 'Open a web address in the visible built-in browser (the person can watch) and return what is on the page: '
          'text plus numbered clickable elements. Use the browser tools to do tasks on websites end to end.',
      parameters: _obj(<String, dynamic>{'url': _str('Address, for example https://mail.google.com')}, <String>['url']),
    ),
    run: (a, host) => BrowserService.instance.open(_s(a, 'url')),
  ),
  ToolDef(
    id: 'browser_read',
    title: 'Browser: read the page',
    group: 'browser',
    spec: ToolSpec(
      name: 'browser_read',
      description: 'Describe the page the browser shows now: text and numbered clickable elements.',
      parameters: _obj(<String, dynamic>{}),
    ),
    run: (a, host) => BrowserService.instance.read(),
  ),
  ToolDef(
    id: 'browser_click',
    title: 'Browser: click',
    group: 'browser',
    spec: ToolSpec(
      name: 'browser_click',
      description: 'Click the element with this number from the latest page description. Returns the new page description.',
      parameters: _obj(<String, dynamic>{'id': <String, dynamic>{'type': 'integer', 'description': 'Element number'}}, <String>['id']),
    ),
    run: (a, host) => BrowserService.instance.click(_i(a, 'id')),
  ),
  ToolDef(
    id: 'browser_type',
    title: 'Browser: type',
    group: 'browser',
    spec: ToolSpec(
      name: 'browser_type',
      description: 'Type text into the input element with this number. submit=true presses Enter afterwards. '
          'Never type passwords or payment details: use ask_user so the person does it.',
      parameters: _obj(<String, dynamic>{
        'id': <String, dynamic>{'type': 'integer', 'description': 'Element number'},
        'text': _str('Text to type'),
        'submit': <String, dynamic>{'type': 'boolean', 'description': 'Press Enter after typing'},
      }, <String>['id', 'text']),
    ),
    run: (a, host) => BrowserService.instance.type(_i(a, 'id'), _s(a, 'text'), a['submit'] == true),
  ),
  ToolDef(
    id: 'browser_drag',
    title: 'Browser: drag',
    group: 'browser',
    spec: ToolSpec(
      name: 'browser_drag',
      description: 'Drag the element with this number by dx, dy screen pixels (right/down positive). Use this to move '
          'an object on a visual canvas (a design tool, a slider, a reorderable list) — click/type alone cannot '
          'reposition anything. Read the element\'s position first (from browser_read\'s "@x,y wxh") to judge the '
          'distance. May not work on pages that specifically reject script-driven drags; if the page looks unchanged '
          'afterwards, say so instead of claiming it moved.',
      parameters: _obj(<String, dynamic>{
        'id': <String, dynamic>{'type': 'integer', 'description': 'Element number'},
        'dx': <String, dynamic>{'type': 'integer', 'description': 'Horizontal distance in pixels, right is positive'},
        'dy': <String, dynamic>{'type': 'integer', 'description': 'Vertical distance in pixels, down is positive'},
      }, <String>['id', 'dx', 'dy']),
    ),
    run: (a, host) => BrowserService.instance.drag(_i(a, 'id'), _i(a, 'dx'), _i(a, 'dy')),
  ),
  ToolDef(
    id: 'browser_scroll',
    title: 'Browser: scroll',
    group: 'browser',
    spec: ToolSpec(
      name: 'browser_scroll',
      description: 'Scroll the page down (default) or up and describe what is now visible.',
      parameters: _obj(<String, dynamic>{
        'direction': <String, dynamic>{'type': 'string', 'enum': <String>['down', 'up']},
      }),
    ),
    run: (a, host) => BrowserService.instance.scroll(_s(a, 'direction') != 'up'),
  ),
  ToolDef(
    id: 'browser_back',
    title: 'Browser: back',
    group: 'browser',
    spec: ToolSpec(
      name: 'browser_back',
      description: 'Go back one page.',
      parameters: _obj(<String, dynamic>{}),
    ),
    run: (a, host) => BrowserService.instance.back(),
  ),
  ToolDef(
    id: 'termux_list_files',
    title: 'List files in Termux',
    group: 'termux',
    spec: const ToolSpec(
      name: 'termux_list_files',
      description: 'Read-only file listing from the connected Termux environment on the user phone. MUST use this when the user asks to open Termux, show/list file or folder names, inspect a directory, or see hidden files. Do not use web search or a browser for local device files. Empty path means the current Termux directory. Set include_hidden=true to include dotfiles; recursive=true lists a limited directory tree.',
      parameters: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'path': <String, dynamic>{'type': 'string', 'description': 'Optional path; defaults to the current Termux directory.'},
          'include_hidden': <String, dynamic>{'type': 'boolean', 'description': 'Include hidden files; default true.'},
          'recursive': <String, dynamic>{'type': 'boolean', 'description': 'List a directory tree instead of one directory.'},
          'max_depth': <String, dynamic>{'type': 'integer', 'description': 'Maximum recursion depth, 1 to 4; default 2.'},
        },
      },
    ),
    run: (a, host) async {
      final path = _s(a, 'path').trim();
      final target = path.isEmpty ? '.' : _shellQuote(path);
      final recursive = a['recursive'] == true;
      final includeHidden = a['include_hidden'] != false;
      final requestedDepth = _i(a, 'max_depth');
      final depth = requestedDepth <= 0 ? 2 : (requestedDepth > 4 ? 4 : requestedDepth);
      final hiddenFilter = includeHidden ? '' : " -not -name '.*'";
      final listFlags = includeHidden ? '-la' : '-l';
      final command = recursive
          ? 'printf "Termux directory: "; pwd; find $target -maxdepth $depth$hiddenFilter -print 2>&1 | head -n 300'
          : 'printf "Termux directory: "; pwd; ls $listFlags -- $target 2>&1';
      return _runTermuxCommand(command, timeoutSeconds: 45);
    },
  ),
  ToolDef(
    id: 'termux_run',
    title: 'Run a shell command (Termux)',
    group: 'termux',
    spec: const ToolSpec(
      name: 'termux_run',
      description: 'Runs a real shell command on the user phone through the connected Termux app. This is the real phone filesystem and Linux environment, not a web browser or sandbox. For local file listing prefer termux_list_files. When the user asks you to execute a command, execute it here instead of merely printing a command for the user. Do not use web_search or browser tools for local device operations.',
      parameters: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'command': <String, dynamic>{'type': 'string', 'description': 'Shell command to execute on the user phone.'},
          'workdir': <String, dynamic>{'type': 'string', 'description': 'Working directory; defaults to Termux home.'},
          'timeout_seconds': <String, dynamic>{'type': 'integer', 'description': 'Timeout from 1 to 300 seconds; default 60.'},
        },
        'required': <String>['command'],
      },
    ),
    run: (a, host) => _runTermuxCommand(
      _s(a, 'command'),
      workdir: a['workdir']?.toString(),
      timeoutSeconds: _i(a, 'timeout_seconds') <= 0 ? 60 : _i(a, 'timeout_seconds'),
    ),
  ),
  ToolDef(
    id: 'python_run',
    title: 'Run Python (sandboxed)',
    group: 'python',
    spec: const ToolSpec(
      name: 'python_run',
      description: 'Runs Python in a sandbox on the phone (Pyodide, a full Python compiled to WebAssembly). '
          'It is a sandbox: no shell, no access to the phone\'s files or apps, nothing installed — '
          'good for the model to write and test a script before handing it over, or to compute something, '
          'not for controlling the device or other programs. Variables and imports from earlier calls stay '
          'available, like a notebook, until reset is called.',
      parameters: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'code': <String, dynamic>{'type': 'string', 'description': 'Python code to run'},
          'reset': <String, dynamic>{'type': 'boolean', 'description': 'Clear earlier variables and imports first'},
        },
        'required': <String>['code'],
      },
    ),
    run: (args, host) async {
      final code = _s(args, 'code');
      if (code.trim().isEmpty) return 'No code was given.';
      final reset = args['reset'] == true;
      if (reset) await PythonRuntime.instance.reset();
      return PythonRuntime.instance.run(code);
    },
  ),
  ...projectToolDefs,
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
  ToolDef(
    id: 'forget',
    title: 'Forget a remembered fact',
    spec: ToolSpec(
      name: 'forget',
      description: 'Remove a previously remembered fact about the user. Only when the user asks to forget, '
          'delete or correct something that was saved with remember. Give a short phrase matching the fact '
          '(or part of it) as it was saved — check the "Things you know about the user" list in your own '
          'instructions for the exact wording first.',
      parameters: _schema(<String, Map<String, String>>{
        'fact': <String, String>{'type': 'string', 'description': 'Text matching the fact to remove (or part of it)'},
      }, <String>['fact']),
    ),
    run: (args, host) async {
      if (!host.memoryAllowed) return 'Memory is off for this chat.';
      final query = (args['fact'] ?? '').toString().trim();
      if (query.isEmpty) return 'Nothing to forget.';
      final removed = host.forgetMemory(query);
      if (removed == 0) return 'Nothing saved matched "$query". Saved facts: ${host.memory.map((m) => m.text).join(' | ')}';
      return 'Removed $removed fact${removed == 1 ? '' : 's'}.';
    },
  ),
  ToolDef(
    id: 'learn',
    title: 'Learn for next time',
    group: 'core',
    spec: ToolSpec(
      name: 'learn',
      description: 'Record one short, lasting operational lesson for your future self — not a fact about the user (use remember for that), but '
          'something about how to do this job better: a mistake you just made and its real fix, a real constraint of this app, a device or a tool '
          'you discovered the hard way, an approach that actually worked for a recurring kind of request, or a correction the user gave about how '
          'you should work going forward ("always do X", "never do Y here"). This is saved by the app itself and fed into every future chat from '
          'now on, even a brand-new conversation and even if the underlying model changes — so write it as self-contained advice to a future version '
          'of yourself that remembers nothing about this conversation, not a note about what just happened. Call it the moment you learn something '
          'like this, even mid-task. Do not save something that only applied to this one message, and do not save a fact about the user here.',
      parameters: _schema(<String, Map<String, String>>{
        'lesson': <String, String>{'type': 'string', 'description': 'One short, self-contained sentence of advice for your future self'},
      }, <String>['lesson']),
    ),
    run: (args, host) async {
      if (!host.selfImproveAllowed) return 'Self-improvement is off for this chat.';
      final lesson = (args['lesson'] ?? '').toString().trim();
      if (lesson.isEmpty) return 'Nothing to learn.';
      host.addLesson(lesson);
      return 'Learned.';
    },
  ),
  ToolDef(
    id: 'forget_lesson',
    title: 'Forget a learned lesson',
    group: 'core',
    spec: ToolSpec(
      name: 'forget_lesson',
      description: 'Remove a previously learned lesson (saved with learn) that turned out wrong or no longer applies. Give a short phrase '
          'matching it (or part of it) as it was saved — check the "Lessons you have learned" list in your own instructions for the exact wording first.',
      parameters: _schema(<String, Map<String, String>>{
        'lesson': <String, String>{'type': 'string', 'description': 'Text matching the lesson to remove (or part of it)'},
      }, <String>['lesson']),
    ),
    run: (args, host) async {
      if (!host.selfImproveAllowed) return 'Self-improvement is off for this chat.';
      final query = (args['lesson'] ?? '').toString().trim();
      if (query.isEmpty) return 'Nothing to forget.';
      final removed = host.forgetLesson(query);
      if (removed == 0) return 'Nothing learned matched "$query". Learned lessons: ${host.lessons.map((m) => m.text).join(' | ')}';
      return 'Removed $removed lesson${removed == 1 ? '' : 's'}.';
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
    final pluginResult = await host.runPluginTool(call.name, call.args);
    if (pluginResult != null) {
      return pluginResult.length > 12000 ? pluginResult.substring(0, 12000) : pluginResult;
    }
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
