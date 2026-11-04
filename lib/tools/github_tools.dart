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
}
