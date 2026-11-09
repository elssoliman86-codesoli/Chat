import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/models.dart';
import '../files/attachment_io.dart';
import 'llm.dart';

/// Token budget per reasoning-effort level, and the only levels extended thinking accepts.
const Map<String, int> anthropicThinkingBudgets = {'low': 4096, 'high': 16000, 'max': 32000};

/// A pending (still streaming) extended-thinking block.
class _PendingThinking {
  final StringBuffer text = StringBuffer();
  final StringBuffer signature = StringBuffer();
}

/// Anthropic Messages API.
class AnthropicClient implements LlmClient {
  AnthropicClient(this.config);

  final ProviderConfig config;

  Map<String, String> get _headers => <String, String>{
        'x-api-key': config.apiKey,
        'anthropic-version': '2023-06-01',
      };

  Future<List<Map<String, dynamic>>> encodeMessages(LlmRequest r) async {
    final out = <Map<String, dynamic>>[];
    List<Map<String, dynamic>>? toolResults;
    for (final m in r.messages) {
      if (m.error) continue;
      if (m.role == 'tool') {
        toolResults ??= <Map<String, dynamic>>[];
        toolResults.add(<String, dynamic>{
          'type': 'tool_result',
          'tool_use_id': m.toolCallId,
          'content': m.text.isEmpty ? '(empty)' : m.text,
        });
        continue;
      }
      if (toolResults != null) {
        out.add(<String, dynamic>{'role': 'user', 'content': toolResults});
        toolResults = null;
      }
      if (m.role == 'user') {
        final blocks = <Map<String, dynamic>>[];
        for (final a in m.attachments) {
          if (a.kind == AttachmentKind.image) {
            blocks.add(<String, dynamic>{
              'type': 'image',
              'source': <String, dynamic>{'type': 'base64', 'media_type': a.mime, 'data': await base64Of(a)},
            });
          } else if (a.kind == AttachmentKind.pdf) {
            blocks.add(<String, dynamic>{
              'type': 'document',
              'source': <String, dynamic>{
                'type': 'base64',
                'media_type': 'application/pdf',
                'data': await base64Of(a),
              },
            });
          } else {
            blocks.add(<String, dynamic>{'type': 'text', 'text': documentBlock(a)});
          }
        }
        if (m.text.isNotEmpty || blocks.isEmpty) {
          blocks.add(<String, dynamic>{'type': 'text', 'text': m.text.isEmpty ? ' ' : m.text});
        }
        out.add(<String, dynamic>{'role': 'user', 'content': blocks});
      } else if (m.role == 'assistant') {
        final blocks = <Map<String, dynamic>>[];
        // A thinking block must come first and be replayed exactly as received, or the API rejects the
        // next turn once thinking has been used alongside a tool call — only when thinking is still on
        // for this very request, since the API does not want it otherwise.
        if (anthropicThinkingBudgets.containsKey(r.reasoningEffort) && m.thinking.isNotEmpty) {
          blocks.add(<String, dynamic>{'type': 'thinking', 'thinking': m.thinking, 'signature': m.thinkingSignature});
        }
        if (m.text.isNotEmpty) blocks.add(<String, dynamic>{'type': 'text', 'text': m.text});
        for (final c in m.toolCalls) {
          blocks.add(<String, dynamic>{'type': 'tool_use', 'id': c.id, 'name': c.name, 'input': c.args});
        }
        if (blocks.isEmpty) continue;
        out.add(<String, dynamic>{'role': 'assistant', 'content': blocks});
      }
    }
    if (toolResults != null) {
      out.add(<String, dynamic>{'role': 'user', 'content': toolResults});
    }
    return out;
  }

  @override
  Stream<LlmEvent> stream(LlmRequest request, AbortHandle abort) async* {
    final client = http.Client();
    abort.client = client;
    try {
      // Extended thinking needs its own token budget on top of the actual reply, and the API rejects
      // temperature/top_p/top_k while it is enabled, so those two are mutually exclusive here.
      final budget = anthropicThinkingBudgets[request.reasoningEffort];
      final body = <String, dynamic>{
        'model': request.model,
        'max_tokens': budget == null ? config.maxTokens : (budget + 4096).clamp(config.maxTokens, 1 << 20),
        'stream': true,
        'messages': await encodeMessages(request),
        if (request.system.trim().isNotEmpty) 'system': request.system,
        if (budget != null)
          'thinking': <String, dynamic>{'type': 'enabled', 'budget_tokens': budget}
        else if (request.temperature != null)
          'temperature': request.temperature!.clamp(0.0, 1.0),
      };
      if (request.tools.isNotEmpty && config.supportsTools) {
        body['tools'] = request.tools
            .map((t) => <String, dynamic>{
                  'name': t.name,
                  'description': t.description,
                  'input_schema': t.parameters,
                })
            .toList();
      }
      final res = await postStream(client, Uri.parse(joinUrl(config.baseUrl, '/v1/messages')), _headers, body);
      final pending = <int, PendingToolCall>{};
      final pendingThinking = <int, _PendingThinking>{};
      await for (final data in sseData(res)) {
        if (data.isEmpty || data == '[DONE]') continue;
        Map<String, dynamic> j;
        try {
          j = jsonDecode(data) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }
        final type = j['type'];
        final index = (j['index'] as num?)?.toInt() ?? 0;
        if (type == 'content_block_start') {
          final block = j['content_block'];
          if (block is Map && block['type'] == 'tool_use') {
            pending[index] = PendingToolCall(block['id']?.toString() ?? '', block['name']?.toString() ?? '');
          } else if (block is Map && block['type'] == 'thinking') {
            pendingThinking[index] = _PendingThinking();
          }
        } else if (type == 'content_block_delta') {
          final d = j['delta'];
          if (d is Map) {
            if (d['type'] == 'text_delta' && d['text'] is String) {
              yield TextDelta(d['text'] as String);
            } else if (d['type'] == 'input_json_delta' && d['partial_json'] is String) {
              pending[index]?.args.write(d['partial_json'] as String);
            } else if (d['type'] == 'thinking_delta' && d['thinking'] is String) {
              pendingThinking[index]?.text.write(d['thinking'] as String);
            } else if (d['type'] == 'signature_delta' && d['signature'] is String) {
              pendingThinking[index]?.signature.write(d['signature'] as String);
            }
          }
        } else if (type == 'content_block_stop') {
          final p = pending.remove(index);
          if (p != null && p.name.isNotEmpty) yield ToolCallDone(p.build());
          final t = pendingThinking.remove(index);
          if (t != null) yield ThinkingDone(t.text.toString(), t.signature.toString());
        } else if (type == 'error') {
          final err = j['error'];
          throw LlmException(err is Map ? (err['message']?.toString() ?? 'Provider error') : 'Provider error');
        }
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
    final j = await getJson(Uri.parse(joinUrl(config.baseUrl, '/v1/models?limit=100')), _headers);
    final ids = <String>[];
    if (j is Map && j['data'] is List) {
      for (final m in j['data'] as List) {
        if (m is Map && m['id'] is String) ids.add(m['id'] as String);
      }
    }
    return ids;
  }

  @override
  Future<PingResult> ping(String model) {
    return postForStatus(Uri.parse(joinUrl(config.baseUrl, '/v1/messages')), _headers, <String, dynamic>{
      'model': model,
      'max_tokens': 8,
      'messages': <Map<String, String>>[
        <String, String>{'role': 'user', 'content': 'Hi'},
      ],
    });
  }
}
