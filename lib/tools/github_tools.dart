import 'dart:convert';

import 'package:http/http.dart' as http;

/// Read-only access to GitHub through its public REST API. A token is optional and unlocks private repos.
class GithubTools {
  static Future<dynamic> _get(String path, String token) async {
    final headers = <String, String>{
      'Accept': 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'User-Agent': 'omni-chat',
      if (token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
    final res = await http.get(Uri.parse('https://api.github.com$path'), headers: headers).timeout(const Duration(seconds: 20));
    final body = utf8.decode(res.bodyBytes, allowMalformed: true);
    if (res.statusCode == 403 || res.statusCode == 429) {
      throw Exception('GitHub rate limit reached. Add a token in Settings > Plugins.');
    }
    if (res.statusCode == 404) throw Exception('Not found (private repos need a token).');
    if (res.statusCode < 200 || res.statusCode >= 300) throw Exception('GitHub HTTP ${res.statusCode}');
    return jsonDecode(body);
  }

  static String _repoName(String raw) {
    var r = raw.trim();
    r = r.replaceAll(RegExp(r'^https?://github\.com/'), '').replaceAll(RegExp(r'\.git$'), '');
    final parts = r.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.length < 2) throw Exception('Use the form owner/name.');
    return '${parts[0]}/${parts[1]}';
  }

  static String _decode(dynamic file) {
    final c = (file['content'] ?? '').toString().replaceAll('\n', '');
    return utf8.decode(base64.decode(c), allowMalformed: true);
  }

  static String _clip(String s, int max) => s.length > max ? '${s.substring(0, max)}\n…(cut)' : s;

  static Future<String> search(String query, String type, String token) async {
    final kind = <String>{'repositories', 'code', 'issues'}.contains(type) ? type : 'repositories';
    final data = await _get('/search/$kind?q=${Uri.encodeQueryComponent(query)}&per_page=8', token);
    final items = (data['items'] as List?) ?? <dynamic>[];
    if (items.isEmpty) return 'No results.';
    final b = StringBuffer();
    for (final i in items) {
      if (kind == 'repositories') {
        b.writeln('${i['full_name']}  ★${i['stargazers_count']}  ${i['language'] ?? ''}\n  ${i['description'] ?? ''}\n  ${i['html_url']}');
      } else if (kind == 'code') {
        b.writeln('${i['repository']?['full_name']}  ${i['path']}\n  ${i['html_url']}');
      } else {
        b.writeln('#${i['number']} ${i['title']}  [${i['state']}]\n  ${i['html_url']}');
      }
    }
    return b.toString().trim();
  }

  static Future<String> repo(String name, String token) async {
    final r = _repoName(name);
    final info = await _get('/repos/$r', token);
    final b = StringBuffer();
    b.writeln('${info['full_name']}  ★${info['stargazers_count']}  forks ${info['forks_count']}  open issues ${info['open_issues_count']}');
    b.writeln('${info['description'] ?? ''}');
    b.writeln('Language: ${info['language']}  Default branch: ${info['default_branch']}  Updated: ${info['pushed_at']}');
    try {
      final tree = await _get('/repos/$r/contents', token);
      if (tree is List) {
        b.writeln('\nFiles:');
        for (final f in tree.take(60)) {
          b.writeln('${f['type'] == 'dir' ? '[dir] ' : ''}${f['name']}');
        }
      }
    } catch (_) {}
    try {
      final readme = await _get('/repos/$r/readme', token);
      b.writeln('\nREADME:\n${_clip(_decode(readme), 5000)}');
    } catch (_) {}
    return b.toString().trim();
  }

  static Future<String> file(String name, String path, String ref, String token) async {
    final r = _repoName(name);
    final p = path.trim().replaceAll(RegExp(r'^/+'), '');
    final q = ref.trim().isEmpty ? '' : '?ref=${Uri.encodeQueryComponent(ref.trim())}';
    final data = await _get('/repos/$r/contents/$p$q', token);
    if (data is List) {
      return data.map((f) => '${f['type'] == 'dir' ? '[dir] ' : ''}${f['path']}').join('\n');
    }
    if (data['encoding'] != 'base64') return 'This file cannot be shown as text.';
    return _clip(_decode(data), 14000);
  }

  static Future<String> issues(String name, String state, int number, String token) async {
    final r = _repoName(name);
    final b = StringBuffer();
    if (number > 0) {
      final i = await _get('/repos/$r/issues/$number', token);
      b.writeln('#${i['number']} ${i['title']}  [${i['state']}] by ${i['user']?['login']}');
      b.writeln(_clip((i['body'] ?? '').toString(), 3000));
      final comments = await _get('/repos/$r/issues/$number/comments?per_page=8', token);
      if (comments is List) {
        for (final c in comments) {
          b.writeln('\n— ${c['user']?['login']}: ${_clip((c['body'] ?? '').toString(), 1200)}');
        }
      }
      return b.toString().trim();
    }
    final st = <String>{'open', 'closed', 'all'}.contains(state) ? state : 'open';
    final list = await _get('/repos/$r/issues?state=$st&per_page=15', token);
    if (list is! List || list.isEmpty) return 'No issues.';
    for (final i in list) {
      b.writeln('#${i['number']} ${i['title']}  [${i['state']}]${i['pull_request'] != null ? ' (PR)' : ''}');
    }
    return b.toString().trim();
  }

  // ------------------------------------------------------------ writing

  static Future<dynamic> _send(String method, String path, String token, Object? body) async {
    if (token.isEmpty) throw Exception('This needs a GitHub token. Add one in Plugins.');
    final req = http.Request(method, Uri.parse('https://api.github.com$path'));
    req.headers.addAll(<String, String>{
      'Accept': 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'User-Agent': 'omni-chat',
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    });
    if (body != null) req.body = jsonEncode(body);
    final streamed = await req.send().timeout(const Duration(seconds: 40));
    final text = await streamed.stream.bytesToString();
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      var detail = text;
      try {
        final j = jsonDecode(text);
        if (j is Map && j['message'] is String) detail = j['message'] as String;
        if (j is Map && j['errors'] != null) detail += ' ${jsonEncode(j['errors'])}';
      } catch (_) {}
      throw Exception('GitHub HTTP ${streamed.statusCode}: ${_clip(detail, 400)}');
    }
    return text.isEmpty ? <String, dynamic>{} : jsonDecode(text);
  }

  /// Every file path of a repository (up to a limit), for analysis.
  static Future<String> tree(String name, String ref, String token) async {
    final r = _repoName(name);
    var branch = ref.trim();
    if (branch.isEmpty) {
      final info = await _get('/repos/$r', token);
      branch = (info['default_branch'] ?? 'main').toString();
    }
    final data = await _get('/repos/$r/git/trees/${Uri.encodeComponent(branch)}?recursive=1', token);
    final items = ((data['tree'] as List?) ?? <dynamic>[]).where((i) => i['type'] == 'blob').toList();
    final b = StringBuffer('Branch $branch, ${items.length} files${data['truncated'] == true ? ' (list truncated by GitHub)' : ''}\n');
    for (final i in items.take(900)) {
      b.writeln('${i['path']}  (${i['size'] ?? '?'} B)');
    }
    if (items.length > 900) b.writeln('…and ${items.length - 900} more');
    return b.toString().trim();
  }

  /// One commit with several files created, changed or deleted. Creates the branch when it does not exist.
  static Future<String> commit(String name, String branch, String message, List<dynamic> files, List<dynamic> deletes,
      String baseBranch, String token) async {
    final r = _repoName(name);
    if (branch.trim().isEmpty) throw Exception('Say which branch to commit to.');
    if (message.trim().isEmpty) throw Exception('A commit message is needed.');
    if (files.isEmpty && deletes.isEmpty) throw Exception('Nothing to commit.');
    final br = branch.trim();
    String? headSha;
    try {
      final ref = await _get('/repos/$r/git/ref/heads/${br.split('/').map(Uri.encodeComponent).join('/')}', token);
      headSha = ref['object']['sha'] as String;
    } catch (_) {
      headSha = null;
    }
    if (headSha == null) {
      var base = baseBranch.trim();
      if (base.isEmpty) {
        final info = await _get('/repos/$r', token);
        base = (info['default_branch'] ?? 'main').toString();
      }
      final baseRef = await _get('/repos/$r/git/ref/heads/${base.split('/').map(Uri.encodeComponent).join('/')}', token);
      final baseSha = baseRef['object']['sha'] as String;
      await _send('POST', '/repos/$r/git/refs', token, <String, dynamic>{'ref': 'refs/heads/$br', 'sha': baseSha});
      headSha = baseSha;
    }
    final commitInfo = await _get('/repos/$r/git/commits/$headSha', token);
    final baseTree = commitInfo['tree']['sha'] as String;
    final entries = <Map<String, dynamic>>[];
    for (final f in files) {
      if (f is! Map) continue;
      final path = (f['path'] ?? '').toString().replaceAll(RegExp(r'^/+'), '');
      if (path.isEmpty) continue;
      entries.add(<String, dynamic>{'path': path, 'mode': '100644', 'type': 'blob', 'content': (f['content'] ?? '').toString()});
    }
    for (final d in deletes) {
      final path = d.toString().replaceAll(RegExp(r'^/+'), '');
      if (path.isNotEmpty) entries.add(<String, dynamic>{'path': path, 'mode': '100644', 'type': 'blob', 'sha': null});
    }
    final tree = await _send('POST', '/repos/$r/git/trees', token, <String, dynamic>{'base_tree': baseTree, 'tree': entries});
    final created = await _send('POST', '/repos/$r/git/commits', token, <String, dynamic>{
      'message': message,
      'tree': tree['sha'],
      'parents': <String>[headSha],
    });
    await _send('PATCH', '/repos/$r/git/refs/heads/${br.split('/').map(Uri.encodeComponent).join('/')}', token,
        <String, dynamic>{'sha': created['sha']});
    return 'Committed ${entries.length} change(s) to $r@$br: https://github.com/$r/commit/${created['sha']}';
  }

  static Future<String> createPr(String name, String title, String head, String base, String body, String token) async {
    final r = _repoName(name);
    var b = base.trim();
    if (b.isEmpty) {
      final info = await _get('/repos/$r', token);
      b = (info['default_branch'] ?? 'main').toString();
    }
    final pr = await _send('POST', '/repos/$r/pulls', token,
        <String, dynamic>{'title': title, 'head': head, 'base': b, 'body': body});
    return 'Pull request #${pr['number']} opened: ${pr['html_url']}';
  }

  static Future<String> mergePr(String name, int number, String method, String token) async {
    final r = _repoName(name);
    final m = <String>{'merge', 'squash', 'rebase'}.contains(method) ? method : 'squash';
    final res = await _send('PUT', '/repos/$r/pulls/$number/merge', token, <String, dynamic>{'merge_method': m});
    return (res['message'] ?? 'Merged').toString();
  }

  static Future<String> createIssue(String name, String title, String body, List<dynamic> labels, String token) async {
    final r = _repoName(name);
    final i = await _send('POST', '/repos/$r/issues', token, <String, dynamic>{
      'title': title,
      'body': body,
      if (labels.isNotEmpty) 'labels': labels.map((e) => e.toString()).toList(),
    });
    return 'Issue #${i['number']} created: ${i['html_url']}';
  }

  static Future<String> comment(String name, int number, String body, String token) async {
    final r = _repoName(name);
    final c = await _send('POST', '/repos/$r/issues/$number/comments', token, <String, dynamic>{'body': body});
    return 'Comment added: ${c['html_url']}';
  }

  static Future<String> commits(String name, String branch, String path, String token) async {
    final r = _repoName(name);
    final q = <String>[
      'per_page=15',
      if (branch.trim().isNotEmpty) 'sha=${Uri.encodeQueryComponent(branch.trim())}',
      if (path.trim().isNotEmpty) 'path=${Uri.encodeQueryComponent(path.trim())}',
    ].join('&');
    final list = await _get('/repos/$r/commits?$q', token);
    if (list is! List || list.isEmpty) return 'No commits.';
    return list
        .map((c) => '${(c['sha'] ?? '').toString().substring(0, 7)} ${c['commit']?['author']?['date']} '
            '${((c['commit']?['message'] ?? '') as String).split('\n').first}')
        .join('\n');
  }

  static Future<String> branches(String name, String token) async {
    final r = _repoName(name);
    final list = await _get('/repos/$r/branches?per_page=60', token);
    if (list is! List || list.isEmpty) return 'No branches.';
    return list.map((b) => b['name'].toString()).join('\n');
  }

  static Future<String> runs(String name, String token) async {
    final r = _repoName(name);
    final data = await _get('/repos/$r/actions/runs?per_page=10', token);
    final list = (data['workflow_runs'] as List?) ?? <dynamic>[];
    if (list.isEmpty) return 'No workflow runs.';
    return list
        .map((w) => '#${w['run_number']} ${w['name']} [${w['status']}/${w['conclusion']}] ${w['head_branch']} ${w['html_url']}')
        .join('\n');
  }

  static Future<String> createRepo(String name, String description, bool private, String token) async {
    final res = await _send('POST', '/user/repos', token, <String, dynamic>{
      'name': name,
      'description': description,
      'private': private,
      'auto_init': true,
    });
    return 'Repository created: ${res['html_url']}';
  }

  // ------------------------------------------------------------ skills

  /// Splits "owner/repo", a github.com URL, or a URL with /tree/branch/path.
  static ({String repo, String branch, String dir}) parseSource(String source) {
    var t = source.trim().replaceAll(RegExp(r'^https?://(www\.)?github\.com/'), '').replaceAll(RegExp(r'\.git$'), '');
    final parts = t.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.length < 2) throw Exception('Use owner/name or a github.com link.');
    var branch = '';
    var dir = '';
    if (parts.length > 3 && (parts[2] == 'tree' || parts[2] == 'blob')) {
      branch = parts[3];
      dir = parts.skip(4).join('/');
    }
    return (repo: '${parts[0]}/${parts[1]}', branch: branch, dir: dir);
  }

  /// Finds SKILL.md files in a repo and returns (folder path, text) for each.
  static Future<(String branch, List<(String, String)>)> skillFiles(String source, String token) async {
    final src = parseSource(source);
    var branch = src.branch;
    if (branch.isEmpty) {
      final info = await _get('/repos/${src.repo}', token);
      branch = (info['default_branch'] ?? 'main').toString();
    }
    final data = await _get('/repos/${src.repo}/git/trees/${Uri.encodeComponent(branch)}?recursive=1', token);
    final paths = ((data['tree'] as List?) ?? <dynamic>[])
        .where((i) => i['type'] == 'blob')
        .map((i) => i['path'].toString())
        .where((p) => p.split('/').last.toLowerCase() == 'skill.md')
        .where((p) => src.dir.isEmpty || p.startsWith('${src.dir}/') || p == '${src.dir}/SKILL.md')
        .take(80)
        .toList();
    final out = <(String, String)>[];
    for (final p in paths) {
      final raw = 'https://raw.githubusercontent.com/${src.repo}/${Uri.encodeComponent(branch)}/$p';
      try {
        final res = await http.get(Uri.parse(raw), headers: <String, String>{'User-Agent': 'omni-chat'}).timeout(const Duration(seconds: 20));
        if (res.statusCode == 200) {
          final folder = p.contains('/') ? p.substring(0, p.lastIndexOf('/')) : '';
          out.add((folder, utf8.decode(res.bodyBytes, allowMalformed: true)));
        }
      } catch (_) {}
    }
    return (branch, out);
  }
}
