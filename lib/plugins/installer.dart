import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/models.dart';
import '../core/skill_import.dart';
import '../tools/github_tools.dart';
import '../tools/tools.dart';
import 'plugin.dart';

/// Installs every SKILL.md found in a GitHub repo (or folder) as a skill of the app.
Future<String> installSkillsFrom(ToolHost host, String source) async {
  final token = host.githubToken;
  if (source.trim().startsWith('http') && !source.contains('github.com')) {
    // A direct link to one SKILL.md file.
    final res = await http.get(Uri.parse(source.trim())).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) return 'Could not download the file (HTTP ${res.statusCode}).';
    final skill = parseSkillMarkdown(utf8.decode(res.bodyBytes, allowMalformed: true));
    if (skill == null) return 'That file does not look like a skill.';
    host.installSkill(skill);
    return 'Installed skill "${skill.name}".';
  }
  final (branch, files) = await GithubTools.skillFiles(source, token);
  if (files.isEmpty) return 'No SKILL.md files found in $source (branch $branch).';
  final src = GithubTools.parseSource(source);
  final names = <String>[];
  for (final (folder, text) in files) {
    final fallback = folder.isEmpty ? src.repo.split('/').last : folder.split('/').last;
    final skill = parseSkillMarkdown(text, fallbackName: fallback);
    if (skill == null) continue;
    skill.tools = <String>{...skill.tools, 'github_file', 'github_tree'}.toList();
    skill.instructions = '${skill.instructions}\n\n'
        '(Installed from ${src.repo}${folder.isEmpty ? '' : ' / $folder'}, branch $branch. Other files of this skill, '
        'such as references and scripts, can be read with github_file using repo "${src.repo}" and the path starting with "${folder.isEmpty ? '' : '$folder/'}".)';
    host.installSkill(skill);
    names.add(skill.name);
  }
  if (names.isEmpty) return 'Found SKILL.md files but none could be read.';
  return 'Installed ${names.length} skill(s): ${names.join(', ')}. They are now in the Skills list and can be called with /name.';
}

/// Installs a plugin from a link: a repo with plugin.json, a plugin.json URL, or a remote MCP server.
Future<String> installPluginFrom(ToolHost host, String url, String token, String name) async {
  final u = url.trim();
  if (u.isEmpty) return 'A link is needed.';

  // 1. GitHub repo with plugin.json (or skills).
  if (u.contains('github.com') || RegExp(r'^[\w.-]+/[\w.-]+$').hasMatch(u)) {
    final src = GithubTools.parseSource(u);
    final branch = src.branch.isEmpty ? 'HEAD' : src.branch;
    final dir = src.dir.isEmpty ? '' : '${src.dir}/';
    final raw = 'https://raw.githubusercontent.com/${src.repo}/$branch/${dir}plugin.json';
    final res = await http.get(Uri.parse(raw)).timeout(const Duration(seconds: 20));
    if (res.statusCode == 200) {
      return _installHttpPlugin(host, utf8.decode(res.bodyBytes, allowMalformed: true), token, name);
    }
    final skills = await installSkillsFrom(host, u);
    return 'No plugin.json in that repo. $skills';
  }

  // 2. A plugin.json file by URL, or an MCP server.
  final probe = await http.get(Uri.parse(u), headers: <String, String>{'Accept': 'application/json'}).timeout(const Duration(seconds: 20)).catchError((_) => http.Response('', 0));
  if (probe.statusCode == 200 && u.toLowerCase().endsWith('.json')) {
    final text = utf8.decode(probe.bodyBytes, allowMalformed: true);
    try {
      final j = jsonDecode(text);
      if (j is Map && j['tools'] is List) return _installHttpPlugin(host, text, token, name);
    } catch (_) {}
  }
  final client = McpClient(u, token: token);
  try {
    await client.connect();
    final tools = await client.listTools();
    if (tools.isEmpty) return 'Connected to the server but it offers no tools.';
    final host0 = Uri.tryParse(u)?.host ?? 'plugin';
    final plugin = Plugin(
      id: newId(),
      name: name.trim().isEmpty ? host0.replaceFirst('www.', '').split('.').first : name.trim(),
      description: 'MCP server at $host0',
      kind: 'mcp',
      url: u,
      token: token,
      tools: tools,
    );
    host.registerPlugin(plugin);
    return 'Installed plugin "${plugin.name}" with ${tools.length} tools: ${tools.map((t) => t.name).take(12).join(', ')}.';
  } catch (e) {
    return 'Could not install: $e';
  }
}

String _installHttpPlugin(ToolHost host, String text, String token, String name) {
  try {
    final j = jsonDecode(text);
    if (j is! Map) return 'plugin.json must be an object.';
    final tools = (j['tools'] as List?)?.whereType<Map>().map((m) => PluginTool.fromJson(m.cast<String, dynamic>())).toList() ?? <PluginTool>[];
    if (tools.isEmpty) return 'plugin.json has no tools.';
    final plugin = Plugin(
      id: newId(),
      name: name.trim().isNotEmpty ? name.trim() : (j['name'] ?? 'Plugin').toString(),
      description: (j['description'] ?? '').toString(),
      kind: 'http',
      token: token,
      instructions: (j['instructions'] ?? '').toString(),
      tools: tools,
    );
    host.registerPlugin(plugin);
    return 'Installed plugin "${plugin.name}" with ${tools.length} tools: ${tools.map((t) => t.name).join(', ')}.';
  } catch (e) {
    return 'plugin.json is not valid: $e';
  }
}
