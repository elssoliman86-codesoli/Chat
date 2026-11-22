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
      final url = Uri.parse(joinUrl(config.baseUrl, '/chat/completions'));
      http.StreamedResponse res;
      try {
        res = await postStream(client, url, _headers, body);
      } on LlmException catch (e) {
        // A few OpenAI-compatible servers (some local ones, some gateways) reject stream=true: ask once for
        // the whole reply instead, so the model still answers.
        if (!abort.aborted && looksLikeNoStreaming(e.message)) {
          yield* _wholeReply(client, url, body);
          return;
        }
        rethrow;
      }
      final pending = <int, PendingToolCall>{};
      var sawFinish = false;
      var sawDone = false;
      var sawAny = false;
      await for (final data in sseData(res)) {
        if (data.isEmpty) continue;
        if (data == '[DONE]') {
          sawDone = true;
          break;
        }
        sawAny = true;
        Map<String, dynamic> j;
        try {
          j = jsonDecode(data) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }
        if (j['error'] is Map) {
          throw LlmException((j['error'] as Map)['message']?.toString() ?? 'Provider error');
        }
        final usage = j['usage'];
        if (usage is Map) {
          final pt = (usage['prompt_tokens'] as num?)?.toInt();
          final ct = (usage['completion_tokens'] as num?)?.toInt();
          if (pt != null || ct != null) yield UsageEvent(inputTokens: pt, outputTokens: ct);
        }
        final choices = j['choices'];
        if (choices is! List || choices.isEmpty) continue;
        final choice = choices.first;
        if (choice is! Map) continue;
        if (choice['finish_reason'] != null) sawFinish = true;
        final delta = choice['delta'];
        if (delta is Map) {
          final content = delta['content'];
          if (content is String && content.isNotEmpty) yield TextDelta(content);
          // Reasoning models (DeepSeek, NVIDIA, OpenRouter…) stream their reasoning in a separate field.
          // The text is passed on so the Thinking panel can show it.
          final reasoning = delta['reasoning_content'] ?? delta['reasoning'];
          if (reasoning is String && reasoning.isNotEmpty) yield ReasoningDelta(reasoning.length, text: reasoning);
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
                if (fn['arguments'] is String) {
                  final chunk = fn['arguments'] as String;
                  p.args.write(chunk);
                  if (chunk.isNotEmpty && p.name.isNotEmpty) yield ToolArgsDelta(index, p.name, chunk);
                }
              }
            }
          }
        }
      }
      if (sawAny && !sawFinish && !sawDone) {
        // The server hung up in the middle of the reply.
        throw StreamDropped('The connection closed before the reply was finished');
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

  /// The same request without streaming; the answer arrives all at once.
  Stream<LlmEvent> _wholeReply(http.Client client, Uri url, Map<String, dynamic> body) async* {
    final plain = Map<String, dynamic>.of(body)..['stream'] = false;
    final res = await client
        .post(url, headers: <String, String>{..._headers, 'Content-Type': 'application/json'}, body: jsonEncode(plain))
        .timeout(const Duration(minutes: 10));
    final raw = utf8.decode(res.bodyBytes, allowMalformed: true);
    if (res.statusCode < 200 || res.statusCode >= 300) throw LlmException(errorMessage(res.statusCode, raw));
    final j = jsonDecode(raw);
    if (j is! Map) throw LlmException('Unexpected reply from the provider');
    final usage = j['usage'];
    if (usage is Map) {
      yield UsageEvent(inputTokens: (usage['prompt_tokens'] as num?)?.toInt(), outputTokens: (usage['completion_tokens'] as num?)?.toInt());
    }
    final choices = j['choices'];
    if (choices is List && choices.isNotEmpty && choices.first is Map) {
      final msg = (choices.first as Map)['message'];
      if (msg is Map) {
        final content = msg['content'];
        if (content is String && content.isNotEmpty) yield TextDelta(content);
        final calls = msg['tool_calls'];
        if (calls is List) {
          for (final rc in calls) {
            if (rc is! Map) continue;
            final fn = rc['function'];
            if (fn is! Map) continue;
            final p = PendingToolCall(rc['id']?.toString() ?? '', fn['name']?.toString() ?? '');
            if (fn['arguments'] is String) p.args.write(fn['arguments'] as String);
            if (p.name.isNotEmpty) yield ToolCallDone(p.build());
          }
        }
      }
    }
    yield const LlmDone();
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
