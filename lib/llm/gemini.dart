import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/models.dart';
import '../files/attachment_io.dart';
import 'llm.dart';

/// Google Gemini generateContent API (streaming).
class GeminiClient implements LlmClient {
  GeminiClient(this.config);

  final ProviderConfig config;

  Map<String, String> get _headers => <String, String>{'x-goog-api-key': config.apiKey};

  String _model(String model) => model.startsWith('models/') ? model.substring(7) : model;

  Future<List<Map<String, dynamic>>> encodeContents(LlmRequest r) async {
    final out = <Map<String, dynamic>>[];
    List<Map<String, dynamic>>? responses;
    for (final m in r.messages) {
      if (m.error) continue;
      if (m.role == 'tool') {
        responses ??= <Map<String, dynamic>>[];
        responses.add(<String, dynamic>{
          'functionResponse': <String, dynamic>{
            'name': m.toolName,
            'response': <String, dynamic>{'result': m.text},
          },
        });
        continue;
      }
      if (responses != null) {
        out.add(<String, dynamic>{'role': 'user', 'parts': responses});
        responses = null;
      }
      if (m.role == 'user') {
        final parts = <Map<String, dynamic>>[];
        for (final a in m.attachments) {
          if (a.kind == AttachmentKind.text) {
            parts.add(<String, dynamic>{'text': documentBlock(a)});
          } else {
            parts.add(<String, dynamic>{
              'inlineData': <String, dynamic>{
                'mimeType': a.kind == AttachmentKind.pdf ? 'application/pdf' : a.mime,
                'data': await base64Of(a),
              },
            });
          }
        }
        if (m.text.isNotEmpty || parts.isEmpty) {
          parts.add(<String, dynamic>{'text': m.text.isEmpty ? ' ' : m.text});
        }
        out.add(<String, dynamic>{'role': 'user', 'parts': parts});
      } else if (m.role == 'assistant') {
        final parts = <Map<String, dynamic>>[];
        if (m.text.isNotEmpty) parts.add(<String, dynamic>{'text': m.text});
        for (final c in m.toolCalls) {
          parts.add(<String, dynamic>{
            'functionCall': <String, dynamic>{'name': c.name, 'args': c.args},
          });
        }
        if (parts.isEmpty) continue;
        out.add(<String, dynamic>{'role': 'model', 'parts': parts});
      }
    }
    if (responses != null) {
      out.add(<String, dynamic>{'role': 'user', 'parts': responses});
    }
    return out;
  }

  @override
  Stream<LlmEvent> stream(LlmRequest request, AbortHandle abort) async* {
    final client = http.Client();
    abort.client = client;
    try {
      final body = <String, dynamic>{
        'contents': await encodeContents(request),
        if (request.system.trim().isNotEmpty)
          'systemInstruction': <String, dynamic>{
            'parts': <Map<String, dynamic>>[
              <String, dynamic>{'text': request.system},
            ],
          },
        if (request.temperature != null)
          'generationConfig': <String, dynamic>{'temperature': request.temperature},
      };
      if (request.tools.isNotEmpty && config.supportsTools) {
        body['tools'] = <Map<String, dynamic>>[
          <String, dynamic>{
            'functionDeclarations': request.tools
                .map((t) => <String, dynamic>{
                      'name': t.name,
                      'description': t.description,
                      'parameters': t.parameters,
                    })
                .toList(),
          },
        ];
      }
      final url = Uri.parse(joinUrl(
          config.baseUrl, '/v1beta/models/${_model(request.model)}:streamGenerateContent?alt=sse'));
      final res = await postStream(client, url, _headers, body);
      await for (final data in sseData(res)) {
        if (data.isEmpty || data == '[DONE]') continue;
        Map<String, dynamic> j;
        try {
          j = jsonDecode(data) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }
        if (j['error'] is Map) {
          throw LlmException((j['error'] as Map)['message']?.toString() ?? 'Provider error');
        }
        final candidates = j['candidates'];
        if (candidates is! List || candidates.isEmpty) continue;
        final content = (candidates.first as Map)['content'];
        if (content is! Map) continue;
        final parts = content['parts'];
        if (parts is! List) continue;
        for (final part in parts) {
          if (part is! Map) continue;
          if (part['thought'] == true) continue;
          if (part['text'] is String) {
            yield TextDelta(part['text'] as String);
          } else if (part['functionCall'] is Map) {
            final fc = part['functionCall'] as Map;
            yield ToolCallDone(ToolCall(
              id: newId(),
              name: fc['name']?.toString() ?? '',
              args: (fc['args'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{},
            ));
          }
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
    final j = await getJson(Uri.parse(joinUrl(config.baseUrl, '/v1beta/models?pageSize=200')), _headers);
    final ids = <String>[];
    if (j is Map && j['models'] is List) {
      for (final m in j['models'] as List) {
        if (m is! Map) continue;
        final methods = m['supportedGenerationMethods'];
        if (methods is List && !methods.contains('generateContent')) continue;
        final name = m['name']?.toString() ?? '';
        if (name.isNotEmpty) ids.add(_model(name));
      }
    }
    return ids;
  }

  @override
  Future<PingResult> ping(String model) {
    return postForStatus(
      Uri.parse(joinUrl(config.baseUrl, '/v1beta/models/${_model(model)}:generateContent')),
      _headers,
      <String, dynamic>{
        'contents': <Map<String, dynamic>>[
          <String, dynamic>{
            'role': 'user',
            'parts': <Map<String, String>>[
              <String, String>{'text': 'Hi'},
            ],
          },
        ],
        'generationConfig': <String, dynamic>{'maxOutputTokens': 16},
      },
    );
  }
}
