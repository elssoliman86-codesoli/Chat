import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/models.dart';
import '../files/attachment_io.dart';
import 'llm.dart';

/// OpenAI chat completions, also used by OpenRouter, Groq, DeepSeek, Ollama and many others.
class OpenAiCompatClient implements LlmClient {
  OpenAiCompatClient(this.config);

  final ProviderConfig config;

  Map<String, String> get _headers => <String, String>{
        if (config.apiKey.isNotEmpty) 'Authorization': 'Bearer ${config.apiKey}',
      };

  Future<List<Map<String, dynamic>>> encodeMessages(LlmRequest r) async {
    final out = <Map<String, dynamic>>[];
    if (r.system.trim().isNotEmpty) {
      out.add(<String, dynamic>{'role': 'system', 'content': r.system});
    }
    for (final m in r.messages) {
      if (m.error) continue;
      if (m.role == 'user') {
        final parts = <Map<String, dynamic>>[];
        final buffer = StringBuffer();
        for (final a in m.attachments) {
          if (a.kind == AttachmentKind.text) {
            buffer.writeln(documentBlock(a));
            buffer.writeln();
          } else if (a.kind == AttachmentKind.image && !r.vision) {
            if (a.text.trim().isNotEmpty) {
              buffer.writeln('[Image "${a.name}" cannot be shown to you. Text and description read from it by another tool:\n${a.text}\n[End of image]]');
            } else {
              buffer.writeln('[Image "${a.name}" was attached, but this model cannot see images.]');
            }
          } else if (a.kind == AttachmentKind.image) {
            parts.add(<String, dynamic>{
              'type': 'image_url',
              'image_url': <String, dynamic>{'url': 'data:${a.mime};base64,${await base64Of(a)}'},
            });
          } else if (a.kind == AttachmentKind.pdf) {
            if (r.pdfNative) {
              parts.add(<String, dynamic>{
                'type': 'file',
                'file': <String, dynamic>{
                  'filename': a.name,
                  'file_data': 'data:application/pdf;base64,${await base64Of(a)}',
                },
              });
            } else {
              buffer.writeln('[PDF "${a.name}" was attached, but this provider cannot read PDFs.]');
            }
          }
        }
        buffer.write(m.text);
        final text = buffer.toString();
        if (parts.isEmpty) {
          out.add(<String, dynamic>{'role': 'user', 'content': text});
        } else {
          out.add(<String, dynamic>{
            'role': 'user',
            'content': <Map<String, dynamic>>[
              <String, dynamic>{'type': 'text', 'text': text.isEmpty ? ' ' : text},
              ...parts,
            ],
          });
        }
      } else if (m.role == 'assistant') {
        if (m.text.isEmpty && m.toolCalls.isEmpty) continue;
        final msg = <String, dynamic>{'role': 'assistant', 'content': m.text.isEmpty ? null : m.text};
        if (m.toolCalls.isNotEmpty) {
          msg['tool_calls'] = m.toolCalls
              .map((c) => <String, dynamic>{
                    'id': c.id,
                    'type': 'function',
                    'function': <String, dynamic>{'name': c.name, 'arguments': jsonEncode(c.args)},
                  })
              .toList();
        }
        out.add(msg);
      } else if (m.role == 'tool') {
        out.add(<String, dynamic>{'role': 'tool', 'tool_call_id': m.toolCallId, 'content': m.text});
      }
    }
    return out;
  }

  @override
  Stream<LlmEvent> stream(LlmRequest request, AbortHandle abort) async* {
    final client = http.Client();
    abort.client = client;
    try {
      final body = <String, dynamic>{
        'model': request.model,
        'messages': await encodeMessages(request),
        'stream': true,
        if (request.temperature != null) 'temperature': request.temperature,
        if (request.reasoningEffort.isNotEmpty) 'reasoning_effort': request.reasoningEffort,
      };
      if (request.tools.isNotEmpty && config.supportsTools) {
        body['tools'] = request.tools
            .map((t) => <String, dynamic>{
                  'type': 'function',
                  'function': <String, dynamic>{
                    'name': t.name,
                    'description': t.description,
                    'parameters': t.parameters,
                  },
                })
            .toList();
      }
      final res = await postStream(client, Uri.parse(joinUrl(config.baseUrl, '/chat/completions')), _headers, body);
      final pending = <int, PendingToolCall>{};
      await for (final data in sseData(res)) {
        if (data.isEmpty) continue;
        if (data == '[DONE]') break;
        Map<String, dynamic> j;
        try {
          j = jsonDecode(data) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }
        if (j['error'] is Map) {
          throw LlmException((j['error'] as Map)['message']?.toString() ?? 'Provider error');
        }
        final choices = j['choices'];
        if (choices is! List || choices.isEmpty) continue;
        final choice = choices.first;
        if (choice is! Map) continue;
        final delta = choice['delta'];
        if (delta is Map) {
          final content = delta['content'];
          if (content is String && content.isNotEmpty) yield TextDelta(content);
          final calls = delta['tool_calls'];
          if (calls is List) {
            for (final raw in calls) {
              if (raw is! Map) continue;
              final index = (raw['index'] as num?)?.toInt() ?? 0;
              final fn = raw['function'];
              final p = pending.putIfAbsent(index, () => PendingToolCall('', ''));
              if (raw['id'] is String && (raw['id'] as String).isNotEmpty) p.id = raw['id'] as String;
              if (fn is Map) {
                if (fn['name'] is String && (fn['name'] as String).isNotEmpty) p.name = fn['name'] as String;
                if (fn['arguments'] is String) p.args.write(fn['arguments'] as String);
              }
            }
          }
        }
      }
      final order = pending.keys.toList()..sort();
      for (final i in order) {
        final p = pending[i]!;
        if (p.name.isNotEmpty) yield ToolCallDone(p.build());
      }
      yield const LlmDone();
    } catch (e) {
      if (abort.aborted) {
        yield const LlmDone();
        return;
      }
      if (e is LlmException) rethrow;
      throw LlmException(e.toString());
    } finally {
      client.close();
    }
  }

  @override
  Future<List<String>> listModels() async {
    final j = await getJson(Uri.parse(joinUrl(config.baseUrl, '/models')), _headers);
    final data = j is Map ? j['data'] : j;
    final ids = <String>[];
    if (data is List) {
      for (final m in data) {
        if (m is Map && m['id'] is String) ids.add(m['id'] as String);
      }
    }
    ids.sort();
    return ids;
  }

  @override
  Future<PingResult> ping(String model) async {
    final url = Uri.parse(joinUrl(config.baseUrl, '/chat/completions'));
    Map<String, dynamic> body(String key) => <String, dynamic>{
          'model': model,
          'messages': <Map<String, String>>[
            <String, String>{'role': 'user', 'content': 'Hi'},
          ],
          key: 8,
          'stream': false,
        };
    var r = await postForStatus(url, _headers, body('max_tokens'));
    if (r.status == 400 && r.detail.contains('max_completion_tokens')) {
      r = await postForStatus(url, _headers, body('max_completion_tokens'));
    }
    return r;
  }
}
