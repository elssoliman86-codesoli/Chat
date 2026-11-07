import 'package:flutter/services.dart';

import '../core/models.dart';
import '../llm/llm.dart';
import '../plugins/installer.dart';
import '../plugins/plugin.dart';
import '../projects/project_tools.dart';
import 'browser_service.dart';
import 'github_tools.dart';
import 'termux_service.dart';
import 'web_tools.dart';

/// Everything a tool needs from the app while it runs.
abstract class ToolHost {
  List<Skill> get skills;
  void addMemory(String text);
  void loadSkill(Skill skill);
  bool get memoryAllowed;
  String get githubToken;
  void installSkill(Skill skill);
  void registerPlugin(Plugin plugin);

  /// Asks the person to approve a risky action.
  Future<bool> confirm(String message);

  /// Pauses the task and asks the person to do something or answer; returns what they said.
  Future<String> askUser(String question);

  /// Runs a tool that belongs to an installed plugin, or returns null when [name] is not one.
  Future<String?> runPluginTool(String name, Map<String, dynamic> args);

  /// The project (folder of files) of the running chat, or empty.
  String get projectId;

  /// Makes [id] the project of the running chat.
  void useProject(String id);

  /// Attaches a file made by a tool to the assistant's reply so the person can save it.
  void deliver(String name, String path);

  /// Handles Omni Chat agent orchestration tools from the normal conversation loop.
  Future<String> agentAction(String action, Map<String, dynamic> args);

  /// Executes a Termux command only after the host applies local permission and scope checks.
  Future<String> runTermuxCommand(String command, {String? workdir, int timeoutSeconds = 60, String target = ''});
}

Map<String, dynamic> _obj(Map<String, dynamic> props, [List<String> required = const <String>[]]) =>
    <String, dynamic>{'type': 'object', 'properties': props, 'required': required};

Map<String, dynamic> _str(String description) => <String, dynamic>{'type': 'string', 'description': description};

String _s(Map<String, dynamic> a, String k) => (a[k] ?? '').toString();
int _i(Map<String, dynamic> a, String k) => int.tryParse((a[k] ?? '0').toString()) ?? 0;

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
    id: 'agent_start',
    title: 'Start an agent task',
    spec: ToolSpec(name: 'agent_start', description: 'Start a structured Omni Chat Agent task for a multi-step workflow. Provide a clear goal and optional target.',
      parameters: _obj(<String, dynamic>{'goal': _str('The complete task goal'), 'target': _str('Optional exact target hostname')}, <String>['goal'])),
    run: (a, host) => host.agentAction('start', a),
  ),
  ToolDef(
    id: 'agent_plan',
    title: 'Create agent plan',
    spec: ToolSpec(name: 'agent_plan', description: 'Record the ordered plan before executing a multi-step task. Each step has id, title, description, and optional toolIds.',
      parameters: _obj(<String, dynamic>{'steps': <String, dynamic>{'type': 'array', 'items': <String, dynamic>{'type': 'object', 'properties': <String, dynamic>{'id': _str('Stable step id'), 'title': _str('Short step title'), 'description': _str('What this step does'), 'toolIds': <String, dynamic>{'type': 'array', 'items': <String, dynamic>{'type': 'string'}}}, 'required': <String>['id', 'title']}}}, <String>['steps'])),
    run: (a, host) => host.agentAction('plan', a),
  ),
  ToolDef(
    id: 'agent_update_step',
    title: 'Update agent timeline step',
    spec: ToolSpec(name: 'agent_update_step', description: 'Update a recorded agent plan step as it starts, waits for approval, completes, fails, or is skipped. Include a concise output summary when complete.',
      parameters: _obj(<String, dynamic>{
        'step_id': _str('The id from agent_plan'),
        'status': <String, dynamic>{'type': 'string', 'enum': <String>['running', 'awaitingApproval', 'completed', 'failed', 'skipped', 'pending']},
        'output': _str('Short result or reason'),
      }, <String>['step_id', 'status'])),
    run: (a, host) => host.agentAction('step_update', a),
  ),
  ToolDef(
    id: 'agent_set_scope',
    title: 'Review target scope',
    spec: ToolSpec(name: 'agent_set_scope', description: 'Submit the program policy text and exact target. The app extracts explicit in-scope and out-of-scope hosts and asks the user to review and confirm them before active testing.',
      parameters: _obj(<String, dynamic>{'target': _str('Exact target hostname'), 'policy_text': _str('Full program policy or scope section'), 'source': _str('Policy URL or program name')}, <String>['target', 'policy_text'])),
    run: (a, host) => host.agentAction('scope', a),
  ),
  ToolDef(
    id: 'termux_discover_tools',
    title: 'Discover Termux tools',
    group: 'termux',
    spec: const ToolSpec(name: 'termux_discover_tools', description: 'Safely detect installed Termux CLI tools and their versions. Does not install anything.', parameters: <String, dynamic>{'type': 'object', 'properties': <String, dynamic>{}}),
    run: (a, host) => host.agentAction('discover', a),
  ),
  ToolDef(
    id: 'termux_install_batch',
    title: 'Install approved Termux tools',
    group: 'termux',
    spec: ToolSpec(name: 'termux_install_batch', description: 'Propose a batch of Termux package identifiers from the supported allowlist. The app shows one approval prompt for the batch before installing.',
      parameters: _obj(<String, dynamic>{'package_ids': <String, dynamic>{'type': 'array', 'items': <String, dynamic>{'type': 'string'}}}, <String>['package_ids'])),
    run: (a, host) => host.agentAction('install_batch', a),
  ),
  ToolDef(
    id: 'agent_create_python_tool',
    title: 'Create and test a Python helper',
    spec: ToolSpec(name: 'agent_create_python_tool', description: 'Create a custom Python helper. The app syntax-checks and runs its optional test code in the isolated Pyodide sandbox, then stores the script locally. This does not execute it against a target.',
      parameters: _obj(<String, dynamic>{'name': _str('Short file/tool name'), 'description': _str('What the helper does'), 'code': _str('Complete Python source code'), 'test_code': _str('Optional isolated Python tests that exercise the code')}, <String>['name', 'code'])),
    run: (a, host) => host.agentAction('create_python_tool', a),
  ),

  ToolDef(
    id: 'agent_run_python_tool',
    title: 'Run approved Python helper',
    spec: ToolSpec(name: 'agent_run_python_tool', description: 'Run a previously created and sandbox-tested custom Python helper in Termux against one exact in-scope target. The app checks scope and shows the complete script for explicit approval before transferring or executing it.',
      parameters: _obj(<String, dynamic>{'name': _str('The helper name used when it was created'), 'target': _str('Exact hostname listed in the confirmed program scope')}, <String>['name', 'target'])),
    run: (a, host) => host.agentAction('run_python_tool', a),
  ),
  ToolDef(
    id: 'termux_run',
    title: 'Run a shell command (Termux)',
    group: 'termux',
    spec: const ToolSpec(
      name: 'termux_run',
      description: 'Runs a real shell command on the user\'s own device through Termux, a separate terminal app the user has '
          'installed and connected (not a sandbox: whatever is actually installed there — python, pip, node, git, curl, '
          'compilers, and so on — is available, and it can read and write the user\'s own files). For the user\'s own automation, '
          'trying a real tool, or anything that genuinely needs a shell, not for the sandboxed python_run. Runs with bash -lc, '
          'so chain with && or ; as needed. Output over roughly 100KB is truncated. Give it a few seconds for a slow command via '
          'timeout_seconds; a truly long-running or background process is not a good fit for this tool.',
      parameters: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'command': <String, dynamic>{'type': 'string', 'description': 'Shell command to run'},
          'workdir': <String, dynamic>{
            'type': 'string',
            'description': 'Working directory (default: Termux\'s home). Use ~/ for paths under it.',
          },
          'timeout_seconds': <String, dynamic>{'type': 'integer', 'description': 'How long to wait (default 60, max 300)'},
          'target': <String, dynamic>{'type': 'string', 'description': 'Exact authorized hostname when the command contacts a target'},
        },
        'required': <String>['command'],
      },
    ),
    run: (a, host) => host.runTermuxCommand(
      _s(a, 'command'),
      workdir: a['workdir']?.toString(),
      timeoutSeconds: _i(a, 'timeout_seconds') <= 0 ? 60 : _i(a, 'timeout_seconds'),
      target: _s(a, 'target'),
    ),
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
