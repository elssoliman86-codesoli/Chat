import 'package:http/http.dart' as http;

import '../llm/llm.dart';
import '../tools/browser_service.dart';
import '../tools/python_runtime.dart';
import '../tools/github_tools.dart';
import '../tools/tools.dart';
import 'project_store.dart';
import 'projects.dart';

Map<String, dynamic> _obj(Map<String, dynamic> props, [List<String> required = const <String>[]]) =>
    <String, dynamic>{'type': 'object', 'properties': props, 'required': required};

Map<String, dynamic> _str(String description) => <String, dynamic>{'type': 'string', 'description': description};

String _s(Map<String, dynamic> a, String k) => (a[k] ?? '').toString();
int _i(Map<String, dynamic> a, String k, int fallback) => int.tryParse((a[k] ?? '').toString()) ?? fallback;

String _kb(int bytes) => bytes < 1024 ? '$bytes B' : (bytes < 1048576 ? '${(bytes / 1024).toStringAsFixed(1)} KB' : '${(bytes / 1048576).toStringAsFixed(1)} MB');

/// The project of this chat. One is created when the model starts writing without creating one first.
Future<String> _pid(ToolHost host, [String name = 'Project']) async {
  await projects.load();
  final current = host.projectId;
  if (current.isNotEmpty && projects.byId(current) != null) return current;
  final p = await projects.create(name);
  host.useProject(p.id);
  return p.id;
}

Future<String> _list(Map<String, dynamic> a, ToolHost host) async {
  final id = await _pid(host);
  final files = await projects.list(id);
  final p = projects.byId(id);
  final head = StringBuffer('Project "${p?.name}"${(p?.repo ?? '').isEmpty ? '' : ' (from GitHub ${p!.repo})'}: ${files.length} files');
  if (files.isEmpty) return '$head. It is empty.';
  var total = 0;
  final byExt = <String, int>{};
  for (final f in files) {
    total += f.size;
    final dot = f.path.lastIndexOf('.');
    final ext = dot < 0 || dot < f.path.lastIndexOf('/') ? '(none)' : f.path.substring(dot).toLowerCase();
    byExt[ext] = (byExt[ext] ?? 0) + 1;
  }
  final top = byExt.entries.toList()..sort((x, y) => y.value.compareTo(x.value));
  head.write(', ${_kb(total)}. Types: ${top.take(8).map((e) => '${e.key} ${e.value}').join(', ')}.');
  final prefix = safeRel(_s(a, 'path')) ?? '';
  final under = prefix.isEmpty ? files : files.where((f) => f.path.startsWith('$prefix/')).toList();
  if (under.isEmpty) return '$head\nNothing under "$prefix".';
  final out = StringBuffer('$head\n');
  if (under.length <= 160) {
    for (final f in under) {
      out.writeln('${f.path}  ${_kb(f.size)}');
    }
    return out.toString();
  }
  // Big folder: show one level, ask to drill down.
  final cut = prefix.isEmpty ? 0 : prefix.length + 1;
  final dirs = <String, (int, int)>{};
  final here = <ProjectFile>[];
  for (final f in under) {
    final rest = f.path.substring(cut);
    final slash = rest.indexOf('/');
    if (slash < 0) {
      here.add(f);
    } else {
      final d = rest.substring(0, slash);
      final cur = dirs[d] ?? (0, 0);
      dirs[d] = (cur.$1 + 1, cur.$2 + f.size);
    }
  }
  out.writeln('Too many files to list at once. Folders here (use path to open one):');
  for (final e in dirs.entries) {
    out.writeln('${prefix.isEmpty ? '' : '$prefix/'}${e.key}/  ${e.value.$1} files, ${_kb(e.value.$2)}');
  }
  for (final f in here.take(100)) {
    out.writeln('${f.path}  ${_kb(f.size)}');
  }
  return out.toString();
}

final List<ToolDef> projectToolDefs = <ToolDef>[
  ToolDef(
    id: 'project_create',
    title: 'Project: create',
    group: 'project',
    spec: ToolSpec(
      name: 'project_create',
      description: 'Start a new project: a folder of real files on the phone that you fill with project_write. '
          'Use it for anything bigger than one small file (websites, apps, scripts, multi-file code).',
      parameters: _obj(<String, dynamic>{'name': _str('Project name')}, <String>['name']),
    ),
    run: (a, host) async {
      await projects.load();
      final p = await projects.create(_s(a, 'name'));
      host.useProject(p.id);
      return 'Project "${p.name}" created and selected. Add files with project_write (many files per call, complete content).';
    },
  ),
  ToolDef(
    id: 'project_write',
    title: 'Project: write files',
    group: 'project',
    spec: ToolSpec(
      name: 'project_write',
      description: 'Create or overwrite files in the project. Send SEVERAL files per call, each with its COMPLETE content '
          '(no placeholders, no "rest of the code"). Folders are created automatically. Link files with real relative paths.',
      parameters: _obj(<String, dynamic>{
        'files': <String, dynamic>{
          'type': 'array',
          'description': 'Files to write',
          'items': _obj(<String, dynamic>{'path': _str('Relative path, for example css/style.css'), 'content': _str('Complete file content')},
              <String>['path', 'content']),
        },
      }, <String>['files']),
    ),
    run: (a, host) async {
      final id = await _pid(host);
      final raw = (a['files'] as List?) ?? <dynamic>[];
      final items = <(String, String)>[];
      for (final f in raw) {
        if (f is Map) items.add(((f['path'] ?? '').toString(), (f['content'] ?? '').toString()));
      }
      if (items.isEmpty) return 'No files were given. Send files as a list of {path, content}.';
      final n = await projects.write(id, items);
      final names = items.map((e) => e.$1).take(25).join(', ');
      final all = await projects.list(id);
      return 'Wrote $n file(s): $names${items.length > 25 ? ', …' : ''}. The project now has ${all.length} files.';
    },
  ),
  ToolDef(
    id: 'project_edit',
    title: 'Project: edit a file',
    group: 'project',
    spec: ToolSpec(
      name: 'project_edit',
      description: 'Change part of one file without rewriting it: replaces the exact text find with replace. '
          'find must match exactly once unless all is true. Prefer this over project_write for small fixes.',
      parameters: _obj(<String, dynamic>{
        'path': _str('File path'),
        'find': _str('Exact text to replace'),
        'replace': _str('New text'),
        'all': <String, dynamic>{'type': 'boolean', 'description': 'Replace every occurrence'},
      }, <String>['path', 'find', 'replace']),
    ),
    run: (a, host) async {
      final id = await _pid(host);
      final path = _s(a, 'path');
      final text = await projects.readText(id, path);
      if (text == null) return 'No file "$path" in the project.';
      final find = _s(a, 'find');
      if (find.isEmpty) return 'find is empty.';
      final count = find.allMatches(text).length;
      if (count == 0) return 'The text was not found in $path. Read the file again with project_read and copy the exact text.';
      if (count > 1 && a['all'] != true) return 'The text appears $count times in $path. Add more surrounding text to make it unique, or set all=true.';
      final next = a['all'] == true ? text.replaceAll(find, _s(a, 'replace')) : text.replaceFirst(find, _s(a, 'replace'));
      await projects.write(id, <(String, String)>[(path, next)]);
      return 'Edited $path ($count replacement${count > 1 ? 's' : ''}).';
    },
  ),
  ToolDef(
    id: 'project_read',
    title: 'Project: read a file',
    group: 'project',
    spec: ToolSpec(
      name: 'project_read',
      description: 'Read a project file with line numbers. Long files: use start_line and end_line to read a part (about 400 lines at a time).',
      parameters: _obj(<String, dynamic>{
        'path': _str('File path'),
        'start_line': <String, dynamic>{'type': 'integer', 'description': 'First line (default 1)'},
        'end_line': <String, dynamic>{'type': 'integer', 'description': 'Last line (default start+399)'},
      }, <String>['path']),
    ),
    run: (a, host) async {
      final id = await _pid(host);
      final path = _s(a, 'path');
      final text = await projects.readText(id, path);
      if (text == null) return 'No file "$path" in the project. Use project_list to see the files.';
      final lines = text.split('\n');
      final start = _i(a, 'start_line', 1).clamp(1, lines.length).toInt();
      final end = _i(a, 'end_line', start + 399).clamp(start, lines.length).toInt();
      final out = StringBuffer('$path  (lines $start-$end of ${lines.length})\n');
      for (var n = start; n <= end; n++) {
        out.writeln('$n: ${lines[n - 1]}');
      }
      if (end < lines.length) out.writeln('… ${lines.length - end} more lines. Call again with start_line=${end + 1}.');
      return out.toString();
    },
  ),
  ToolDef(
    id: 'project_list',
    title: 'Project: list files',
    group: 'project',
    spec: ToolSpec(
      name: 'project_list',
      description: 'List the files of the project with sizes and a summary by file type. For big projects it shows one folder level at a time: pass path to open a folder.',
      parameters: _obj(<String, dynamic>{'path': _str('Folder to open (optional)')}),
    ),
    run: _list,
  ),
  ToolDef(
    id: 'project_search',
    title: 'Project: search',
    group: 'project',
    spec: ToolSpec(
      name: 'project_search',
      description: 'Search inside all text files of the project (like grep). Returns file:line: text. Use it to find code in big projects before reading.',
      parameters: _obj(<String, dynamic>{
        'query': _str('Text to find (case-insensitive), or a regular expression when regex is true'),
        'regex': <String, dynamic>{'type': 'boolean'},
        'path': _str('Only files under this folder (optional)'),
      }, <String>['query']),
    ),
    run: (a, host) async {
      final id = await _pid(host);
      final hits = await projects.search(id, _s(a, 'query'), regex: a['regex'] == true, prefix: _s(a, 'path'));
      if (hits.isEmpty) return 'No matches.';
      return '${hits.length}${hits.length >= 80 ? '+' : ''} match(es):\n${hits.join('\n')}';
    },
  ),
  ToolDef(
    id: 'project_delete',
    title: 'Project: delete files',
    group: 'project',
    spec: ToolSpec(
      name: 'project_delete',
      description: 'Delete files or folders from the project.',
      parameters: _obj(<String, dynamic>{
        'paths': <String, dynamic>{'type': 'array', 'items': <String, dynamic>{'type': 'string'}},
      }, <String>['paths']),
    ),
    run: (a, host) async {
      final id = await _pid(host);
      var n = 0;
      for (final p in (a['paths'] as List?) ?? <dynamic>[]) {
        if (await projects.remove(id, p.toString())) n++;
      }
      return 'Deleted $n item(s).';
    },
  ),
  ToolDef(
    id: 'project_move',
    title: 'Project: move or rename',
    group: 'project',
    spec: ToolSpec(
      name: 'project_move',
      description: 'Move or rename a file or folder inside the project.',
      parameters: _obj(<String, dynamic>{'from': _str('Current path'), 'to': _str('New path')}, <String>['from', 'to']),
    ),
    run: (a, host) async {
      final id = await _pid(host);
      final ok = await projects.move(id, _s(a, 'from'), _s(a, 'to'));
      return ok ? 'Moved.' : 'Could not move: "${_s(a, 'from')}" was not found.';
    },
  ),
  ToolDef(
    id: 'project_download',
    title: 'Project: download a file',
    group: 'project',
    spec: ToolSpec(
      name: 'project_download',
      description: 'Download a file from a web address into the project (images, fonts, libraries, data). Up to 25 MB.',
      parameters: _obj(<String, dynamic>{'url': _str('https:// address'), 'path': _str('Where to save it in the project')}, <String>['url', 'path']),
    ),
    run: (a, host) async {
      final id = await _pid(host);
      final res = await http.get(Uri.parse(_s(a, 'url')), headers: <String, String>{'User-Agent': 'omni-chat'}).timeout(const Duration(seconds: 60));
      if (res.statusCode != 200) return 'Download failed: HTTP ${res.statusCode}.';
      if (res.bodyBytes.length > 25 * 1024 * 1024) return 'The file is larger than 25 MB.';
      await projects.writeBytes(id, _s(a, 'path'), res.bodyBytes);
      return 'Saved ${_s(a, 'path')} (${_kb(res.bodyBytes.length)}).';
    },
  ),
  ToolDef(
    id: 'project_import_github',
    title: 'Project: download a GitHub repo',
    group: 'project',
    spec: ToolSpec(
      name: 'project_import_github',
      description: 'Download a whole GitHub repository (the person\'s token is used for private ones) into a new project so you can analyze it, '
          'edit files and add files in the background. repo is owner/name or a github.com link.',
      parameters: _obj(<String, dynamic>{'repo': _str('owner/name or link'), 'ref': _str('Branch or tag (optional)')}, <String>['repo']),
    ),
    run: (a, host) async {
      await projects.load();
      final (p, summary) = await projects.importGithub(_s(a, 'repo'), _s(a, 'ref'), host.githubToken);
      host.useProject(p.id);
      final listing = await _list(<String, dynamic>{}, host);
      return '$summary\n$listing';
    },
  ),
  ToolDef(
    id: 'project_serve',
    title: 'Project: run on the local server',
    group: 'project',
    spec: ToolSpec(
      name: 'project_serve',
      description: 'Start the built-in local web server for the project and return the address. The person can open it with the Preview button.',
      parameters: _obj(<String, dynamic>{'page': _str('Page to open, default index.html')}),
    ),
    run: (a, host) async {
      final id = await _pid(host);
      final page = _s(a, 'page').isEmpty ? 'index.html' : _s(a, 'page');
      final url = await projectServer.urlFor(id, page);
      final files = await projects.list(id);
      final pages = files.where((f) => f.path.toLowerCase().endsWith('.html')).map((f) => f.path).take(20).toList();
      return 'Server running (this phone only): $url\nHTML pages: ${pages.isEmpty ? 'none' : pages.join(', ')}\n'
          'The person can open the live preview from the project bar above the message box.';
    },
  ),
  ToolDef(
    id: 'project_check',
    title: 'Project: open and check the page',
    group: 'project',
    spec: ToolSpec(
      name: 'project_check',
      description: 'Run the project on the local server, open the page in a background browser the size of a phone and report what a person would see: '
          'the visible text, the layout, horizontal overflow, broken images, missing viewport tag, and every script error or failed request. '
          'Use it after writing a web project and fix what it reports. Repeat until clean (at most 3 rounds).',
      parameters: _obj(<String, dynamic>{'page': _str('Page to check, default index.html')}),
    ),
    run: (a, host) async {
      final id = await _pid(host);
      final files = await projects.list(id);
      var page = _s(a, 'page').isEmpty ? 'index.html' : _s(a, 'page');
      if (!files.any((f) => f.path == page)) {
        final html = files.where((f) => f.path.toLowerCase().endsWith('.html')).toList();
        if (html.isEmpty) return 'The project has no HTML page to open.';
        if (_s(a, 'page').isNotEmpty) return 'No file "$page". HTML pages: ${html.map((f) => f.path).take(15).join(', ')}.';
        page = html.first.path;
      }
      final url = await projectServer.urlFor(id, page);
      return BrowserService.instance.check(url);
    },
  ),
  ToolDef(
    id: 'project_export',
    title: 'Project: make the ZIP',
    group: 'project',
    spec: ToolSpec(
      name: 'project_export',
      description: 'Pack the whole project into a ZIP file and hand it to the person in the chat (they can save it). Call it when the project is finished.',
      parameters: _obj(<String, dynamic>{}),
    ),
    run: (a, host) async {
      final id = await _pid(host);
      final files = await projects.list(id);
      if (files.isEmpty) return 'The project is empty, nothing to export.';
      final path = await projects.exportZip(id);
      final name = path.split('/').last;
      host.deliver(name, path);
      return 'ZIP ready: $name with ${files.length} files. It is attached to this reply and the person can save it from the chat.';
    },
  ),
  ToolDef(
    id: 'python_run',
    title: 'Run Python',
    group: 'project',
    spec: ToolSpec(
      name: 'python_run',
      description: 'Runs a Python snippet in a sandbox on the phone (no shell, no access to the device\'s files or apps; the '
          'project\'s files are not visible to it either). Variables and imports from earlier calls stay available, like a notebook, '
          'until reset is used. Use it to work out logic, test a function, process some text or numbers, or try an algorithm '
          'before writing the finished script to the project with project_write. Print what you want to see; the value of the '
          'last expression is also shown. The first call downloads the Python runtime and takes longer.',
      parameters: _obj(<String, dynamic>{
        'code': _str('Python code to run'),
        'reset': <String, dynamic>{'type': 'boolean', 'description': 'Clear earlier variables and imports first'},
      }, <String>['code']),
    ),
    run: (a, host) async {
      if (a['reset'] == true) await PythonRuntime.instance.reset();
      final code = _s(a, 'code');
      if (code.trim().isEmpty) return 'No code was given.';
      return PythonRuntime.instance.run(code);
    },
  ),
  ToolDef(
    id: 'project_push_github',
    title: 'Project: push to GitHub',
    group: 'project_push',
    spec: ToolSpec(
      name: 'project_push_github',
      description: 'Commit every file that was added, changed or deleted in the project since it was imported (or last pushed) to a GitHub branch, in one commit. '
          'For a project that did not come from GitHub, create the repository first with github_create_repo.',
      parameters: _obj(<String, dynamic>{
        'repo': _str('owner/name (default: the repo the project came from)'),
        'branch': _str('Branch to commit to, for example assistant/update'),
        'message': _str('Commit message'),
        'base_branch': _str('Branch to start from when creating the branch (optional)'),
      }, <String>['branch', 'message']),
    ),
    run: (a, host) async {
      final id = await _pid(host);
      final p = projects.byId(id);
      final repo = _s(a, 'repo').isEmpty ? (p?.repo ?? '') : _s(a, 'repo');
      if (repo.isEmpty) return 'Which repository? Pass repo as owner/name.';
      final c = await projects.changes(id);
      if (c.changed.isEmpty && c.deleted.isEmpty) return 'Nothing changed since the project was imported or last pushed.';
      final out = await GithubTools.commit(repo, _s(a, 'branch'), _s(a, 'message'), c.changed, c.deleted, _s(a, 'base_branch'), host.githubToken);
      await projects.setRepo(id, repo.replaceAll(RegExp(r'^https?://github\.com/'), ''), _s(a, 'branch'));
      await projects.saveBaseline(id);
      return '$out\n${c.changed.length} file(s) added or changed, ${c.deleted.length} deleted'
          '${c.binary.isEmpty ? '' : '. Binary files not pushed: ${c.binary.take(10).join(', ')}'}.';
    },
  ),
];
