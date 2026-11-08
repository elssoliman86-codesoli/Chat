import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/models.dart';
import 'anthropic.dart';
import 'gemini.dart';
import 'openai_compat.dart';

class ToolSpec {
  const ToolSpec({required this.name, required this.description, required this.parameters});

  final String name;
  final String description;

  /// JSON schema of the arguments.
  final Map<String, dynamic> parameters;
}

abstract class LlmEvent {
  const LlmEvent();
}

class TextDelta extends LlmEvent {
  const TextDelta(this.text);
  final String text;
}

class ToolCallDone extends LlmEvent {
  const ToolCallDone(this.call);
  final ToolCall call;
}

class LlmDone extends LlmEvent {
  const LlmDone();
}

class LlmRequest {
  const LlmRequest({
    required this.system,
    required this.messages,
    required this.model,
    this.tools = const <ToolSpec>[],
    this.temperature,
    this.pdfNative = false,
    this.vision = true,
    this.reasoningEffort = '',
  });

  final String system;
  final List<ChatMessage> messages;
  final String model;
  final List<ToolSpec> tools;
  final double? temperature;
  final bool pdfNative;

  /// '', 'low', 'high' or 'max' — extra thinking/reasoning effort for this model, if it supports one.
  final String reasoningEffort;

  /// False when the model cannot read images: they are replaced by a short note.
  final bool vision;
}

class LlmException implements Exception {
  LlmException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Lets the Stop button cut a running request.
class AbortHandle {
  bool aborted = false;
  http.Client? client;

  void abort() {
    aborted = true;
    client?.close();
  }
}

/// Result of a one-token test request to a model.
class PingResult {
  const PingResult(this.status, this.detail, this.ms);

  /// HTTP status, or 0 when the request timed out or the network failed.
  final int status;
  final String detail;
  final int ms;

  bool get ok => status >= 200 && status < 300;
}

abstract class LlmClient {
  Stream<LlmEvent> stream(LlmRequest request, AbortHandle abort);
  Future<List<String>> listModels();

  /// Sends a tiny request and reports the HTTP status, to see which models really answer.
  Future<PingResult> ping(String model);
}

/// POSTs [body] and returns status and a short error text, never throws.
Future<PingResult> postForStatus(Uri url, Map<String, String> headers, Object body,
    {Duration timeout = const Duration(seconds: 25)}) async {
  final watch = Stopwatch()..start();
  try {
    final res = await http
        .post(url, headers: <String, String>{...headers, 'Content-Type': 'application/json'}, body: jsonEncode(body))
        .timeout(timeout);
    final text = utf8.decode(res.bodyBytes, allowMalformed: true);
    final ok = res.statusCode >= 200 && res.statusCode < 300;
    return PingResult(res.statusCode, ok ? '' : errorMessage(res.statusCode, text), watch.elapsedMilliseconds);
  } on TimeoutException {
    return PingResult(0, 'Timed out', watch.elapsedMilliseconds);
  } catch (e) {
    return PingResult(0, e.toString(), watch.elapsedMilliseconds);
  }
}

LlmClient createClient(ProviderConfig config) {
  switch (config.kind) {
    case ProviderKind.anthropic:
      return AnthropicClient(config);
    case ProviderKind.gemini:
      return GeminiClient(config);
    case ProviderKind.openai:
      return OpenAiCompatClient(config);
  }
}

String joinUrl(String base, String path) {
  final trimmed = base.trim().replaceAll(RegExp(r'/+$'), '');
  return '$trimmed$path';
}

/// Pulls a readable message out of a provider error body.
String errorMessage(int status, String body) {
  String detail = '';
  try {
    final j = jsonDecode(body);
    if (j is Map) {
      final err = j['error'];
      if (err is Map && err['message'] is String) {
        detail = err['message'] as String;
      } else if (err is String) {
        detail = err;
      } else if (j['message'] is String) {
        detail = j['message'] as String;
      } else if (j['detail'] is String) {
        detail = j['detail'] as String;
      }
    } else if (j is List && j.isNotEmpty && j.first is Map) {
      final err = (j.first as Map)['error'];
      if (err is Map && err['message'] is String) detail = err['message'] as String;
    }
  } catch (_) {
    detail = body;
  }
  if (detail.isEmpty) detail = body;
  if (detail.length > 400) detail = detail.substring(0, 400);
  return 'HTTP $status: $detail'.trim();
}

String _encodeBody(Object body) => jsonEncode(body);

Future<http.StreamedResponse> postStream(
  http.Client client,
  Uri url,
  Map<String, String> headers,
  Object body,
) async {
  final req = http.Request('POST', url);
  req.headers.addAll(headers);
  req.headers['Content-Type'] = 'application/json';
  req.body = await compute(_encodeBody, body);
  // Only covers getting the response headers/first byte, not reading the rest of the stream — a slow
  // "thinking"/reasoning model can sit silently for minutes before its first token, so this has to be
  // generous rather than a normal request timeout.
  final res = await client.send(req).timeout(const Duration(minutes: 10));
  if (res.statusCode < 200 || res.statusCode >= 300) {
    final text = await res.stream.bytesToString();
    throw LlmException(errorMessage(res.statusCode, text));
  }
  return res;
}

/// The data payloads of a server-sent-events response.
Stream<String> sseData(http.StreamedResponse res) async* {
  final lines = res.stream.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    if (line.startsWith('data:')) {
      yield line.substring(5).trim();
    }
  }
}

Future<dynamic> getJson(Uri url, Map<String, String> headers) async {
  final res = await http.get(url, headers: headers).timeout(const Duration(seconds: 30));
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw LlmException(errorMessage(res.statusCode, utf8.decode(res.bodyBytes, allowMalformed: true)));
  }
  return jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true));
}

class PendingToolCall {
  PendingToolCall(this.id, this.name);
  String id;
  String name;
  final StringBuffer args = StringBuffer();

  ToolCall build() {
    Map<String, dynamic> parsed = <String, dynamic>{};
    final raw = args.toString().trim();
    if (raw.isNotEmpty) {
      try {
        final j = jsonDecode(raw);
        if (j is Map) parsed = j.cast<String, dynamic>();
      } catch (_) {
        parsed = <String, dynamic>{'_raw': raw};
      }
    }
    return ToolCall(id: id.isEmpty ? newId() : id, name: name, args: parsed);
  }
}
