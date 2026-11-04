import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/models.dart';

/// One tool a plugin offers to the model.
class PluginTool {
  PluginTool({required this.name, this.description = '', Map<String, dynamic>? parameters, this.request})
      : parameters = parameters ?? <String, dynamic>{'type': 'object', 'properties': <String, dynamic>{}};

  final String name;
  final String description;
  final Map<String, dynamic> parameters;

  /// For simple web plugins: method, url, headers and body templates with {placeholders}.
  final Map<String, dynamic>? request;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'description': description,
        'parameters': parameters,
        if (request != null) 'request': request,
      };

  factory PluginTool.fromJson(Map<String, dynamic> j) => PluginTool(
        name: j['name'] as String? ?? 'tool',
        description: j['description'] as String? ?? '',
        parameters: (j['parameters'] as Map?)?.cast<String, dynamic>() ??
            (j['inputSchema'] as Map?)?.cast<String, dynamic>(),
        request: (j['request'] as Map?)?.cast<String, dynamic>(),
      );
}

/// An installed plugin: a remote MCP server or a simple web API described by a plugin.json file.
class Plugin {
  Plugin({
    required this.id,
    required this.name,
    this.description = '',
    this.kind = 'mcp',
    this.url = '',
    this.token = '',
    this.instructions = '',
    List<PluginTool>? tools,
    this.enabled = true,
  }) : tools = tools ?? <PluginTool>[];

  final String id;
  String name;
  String description;

  /// mcp or http.
  String kind;
  String url;
  String token;
  String instructions;
  List<PluginTool> tools;
  bool enabled;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'description': description,
        'kind': kind,
        'url': url,
        'token': token,
        'instructions': instructions,
        'tools': tools.map((t) => t.toJson()).toList(),
        'enabled': enabled,
      };

  factory Plugin.fromJson(Map<String, dynamic> j) => Plugin(
        id: j['id'] as String? ?? newId(),
        name: j['name'] as String? ?? 'Plugin',
        description: j['description'] as String? ?? '',
        kind: j['kind'] as String? ?? 'mcp',
        url: j['url'] as String? ?? '',
        token: j['token'] as String? ?? '',
        instructions: j['instructions'] as String? ?? '',
        tools: (j['tools'] as List?)?.whereType<Map>().map((m) => PluginTool.fromJson(m.cast<String, dynamic>())).toList(),
        enabled: j['enabled'] as bool? ?? true,
      );

  /// Name the model sees: unique per plugin and valid for every provider.
  String specName(PluginTool t) {
    final p = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    final full = '${p.isEmpty ? 'plugin' : p}__${t.name.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}';
    return full.length > 64 ? full.substring(0, 64) : full;
  }
}

/// A small client for MCP servers that speak JSON-RPC over HTTP.
class McpClient {
  McpClient(this.url, {this.token = ''});

  final String url;
  final String token;
  String? _session;
  int _id = 0;

  Future<dynamic> _rpc(String method, Map<String, dynamic>? params, {bool notify = false}) async {
    final id = notify ? 0 : ++_id;
    final body = <String, dynamic>{
      'jsonrpc': '2.0',
      if (!notify) 'id': id,
      'method': method,
      if (params != null) 'params': params,
    };
    final res = await http
        .post(
          Uri.parse(url),
          headers: <String, String>{
            'Content-Type': 'application/json',
            'Accept': 'application/json, text/event-stream',
            'MCP-Protocol-Version': '2025-03-26',
            if (token.isNotEmpty) 'Authorization': 'Bearer $token',
            if (_session != null) 'Mcp-Session-Id': _session!,
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 45));
    final sid = res.headers['mcp-session-id'];
    if (sid != null) _session = sid;
    if (notify) return null;
    final text = utf8.decode(res.bodyBytes, allowMalformed: true);
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw Exception('The server asked for authorization (HTTP ${res.statusCode}). Provide an access token.');
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('HTTP ${res.statusCode}');
    }
    Map<String, dynamic>? message;
    if ((res.headers['content-type'] ?? '').contains('text/event-stream')) {
      for (final line in const LineSplitter().convert(text)) {
        if (!line.startsWith('data:')) continue;
        try {
          final j = jsonDecode(line.substring(5).trim());
          if (j is Map && j['id'] == id) message = j.cast<String, dynamic>();
        } catch (_) {}
      }
    } else {
      final j = jsonDecode(text);
      if (j is Map) message = j.cast<String, dynamic>();
    }
    if (message == null) throw Exception('Empty answer from the server');
    if (message['error'] is Map) throw Exception((message['error'] as Map)['message']?.toString() ?? 'Server error');
    return message['result'];
  }

  Future<void> connect() async {
    await _rpc('initialize', <String, dynamic>{
      'protocolVersion': '2025-03-26',
      'capabilities': <String, dynamic>{},
      'clientInfo': <String, dynamic>{'name': 'omni-chat', 'version': '1.0'},
    });
    await _rpc('notifications/initialized', null, notify: true);
  }

  Future<List<PluginTool>> listTools() async {
    final r = await _rpc('tools/list', <String, dynamic>{});
    final list = (r is Map ? r['tools'] : null) as List? ?? <dynamic>[];
    return list.whereType<Map>().map((m) => PluginTool.fromJson(m.cast<String, dynamic>())).toList();
  }

  Future<String> call(String tool, Map<String, dynamic> args) async {
    final r = await _rpc('tools/call', <String, dynamic>{'name': tool, 'arguments': args});
    final content = (r is Map ? r['content'] : null) as List? ?? <dynamic>[];
    final b = StringBuffer();
    for (final c in content) {
      if (c is Map && c['type'] == 'text') b.writeln(c['text']);
    }
    final out = b.toString().trim();
    if (r is Map && r['isError'] == true) return 'Plugin error: $out';
    return out.isEmpty ? jsonEncode(r) : out;
  }
}

dynamic _fill(dynamic template, Map<String, dynamic> args) {
  if (template is String) {
    final whole = RegExp(r'^\{(\w+)\}$').firstMatch(template);
    if (whole != null && args.containsKey(whole.group(1))) return args[whole.group(1)];
    return template.replaceAllMapped(RegExp(r'\{(\w+)\}'), (m) => '${args[m.group(1)] ?? ''}');
  }
  if (template is Map) return template.map((k, v) => MapEntry(k, _fill(v, args)));
  if (template is List) return template.map((v) => _fill(v, args)).toList();
  return template;
}

/// Runs one tool of a simple web plugin.
Future<String> runHttpTool(Plugin plugin, PluginTool tool, Map<String, dynamic> args) async {
  final req = tool.request;
  if (req == null) return 'This tool has no request template.';
  final method = (req['method'] ?? 'GET').toString().toUpperCase();
  var url = (req['url'] ?? '').toString();
  url = url.replaceAllMapped(RegExp(r'\{(\w+)\}'), (m) => Uri.encodeComponent('${args[m.group(1)] ?? ''}'));
  final headers = <String, String>{
    'User-Agent': 'omni-chat',
    if (plugin.token.isNotEmpty) 'Authorization': 'Bearer ${plugin.token}',
  };
  final h = req['headers'];
  if (h is Map) {
    h.forEach((k, v) => headers[k.toString()] = v.toString().replaceAll('{token}', plugin.token));
  }
  final request = http.Request(method, Uri.parse(url));
  request.headers.addAll(headers);
  if (req['body'] != null && method != 'GET') {
    request.headers.putIfAbsent('Content-Type', () => 'application/json');
    request.body = jsonEncode(_fill(req['body'], args));
  }
  final streamed = await request.send().timeout(const Duration(seconds: 40));
  final text = await streamed.stream.bytesToString();
  final out = 'HTTP ${streamed.statusCode}\n${text.length > 9000 ? text.substring(0, 9000) : text}';
  return out;
}
