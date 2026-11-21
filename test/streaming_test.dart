import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_chat/core/models.dart';
import 'package:omni_chat/llm/anthropic.dart';
import 'package:omni_chat/llm/gemini.dart';
import 'package:omni_chat/llm/llm.dart';
import 'package:omni_chat/llm/openai_compat.dart';
import 'package:omni_chat/llm/resilient.dart';
import 'package:omni_chat/llm/stream_metrics.dart';

// ── a scripted client ────────────────────────────────────────────────────────────────────────────

class _Attempt {
  _Attempt(this.events, {this.fail, this.hang = false});
  final List<LlmEvent> events;
  final Object? fail;

  /// Stays silent after the events, like a connection that went quiet.
  final bool hang;
}

class _Fake implements LlmClient {
  _Fake(this.attempts);
  final List<_Attempt> attempts;
  final List<LlmRequest> requests = <LlmRequest>[];

  @override
  Stream<LlmEvent> stream(LlmRequest request, AbortHandle abort) async* {
    requests.add(request);
    if (requests.length > attempts.length) throw StateError('unexpected extra request');
    final a = attempts[requests.length - 1];
    for (final e in a.events) {
      yield e;
    }
    if (a.hang) await Completer<void>().future;
    if (a.fail != null) throw a.fail!;
    yield const LlmDone();
  }

  @override
  Future<List<String>> listModels() async => <String>[];

  @override
  Future<PingResult> ping(String model) async => const PingResult(200, '', 1);
}

LlmRequest _req() => LlmRequest(
      system: 'be brief',
      messages: <ChatMessage>[ChatMessage(role: 'user', text: 'hi')],
      model: 'm',
    );

Future<List<LlmEvent>> _collect(Stream<LlmEvent> s) async => s.toList();

String _text(List<LlmEvent> events) => events.whereType<TextDelta>().map((e) => e.text).join();

// ── a tiny SSE server ────────────────────────────────────────────────────────────────────────────

typedef _Handler = Future<void> Function(int n, Map<String, dynamic> body, HttpRequest req);

class _Sse {
  _Sse(this.handler);
  final _Handler handler;
  late HttpServer server;
  final List<Map<String, dynamic>> bodies = <Map<String, dynamic>>[];

  String get base => 'http://127.0.0.1:${server.port}';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final raw = await utf8.decoder.bind(req).join();
      Map<String, dynamic> body = <String, dynamic>{};
      try {
        body = jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {}
      bodies.add(body);
      try {
        await handler(bodies.length, body, req);
      } catch (_) {}
    });
  }

  Future<void> stop() => server.close(force: true);
}

Future<void> _sse(HttpRequest req, List<String> lines, {bool end = true}) async {
  final res = req.response;
  res.headers.contentType = ContentType('text', 'event-stream');
  for (final l in lines) {
    res.write('data: $l\n\n');
    await res.flush();
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  if (end) await res.close();
}

/// Sends [lines] and then hangs up without finishing the response: a dropped connection.
Future<void> _cut(HttpRequest req, List<String> lines) async {
  final socket = await req.response.detachSocket(writeHeaders: false);
  final body = lines.map((l) => 'data: $l\n\n').join();
  socket.add(('HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncontent-length: ${body.length + 5000}\r\n\r\n$body').codeUnits);
  await socket.flush();
  await Future<void>.delayed(const Duration(milliseconds: 30));
  socket.destroy();
}

String _oa(String text) => jsonEncode({
      'choices': [
        {'delta': {'content': text}}
      ]
    });

ProviderConfig _cfg(ProviderKind k, String base) => ProviderConfig(id: 'p', name: 'p', kind: k, baseUrl: base, apiKey: 'k', model: 'm');

void main() {
  group('overlap trimming', () {
    test('repeated tail of the earlier text is removed', () {
      const before = 'The quick brown fox jumps';
      expect(overlapLength(before, 'quick brown fox jumps over the lazy dog'), 'quick brown fox jumps'.length);
      expect(overlapLength(before, ' over the lazy dog'), 0);
    });

    test('short coincidences are not treated as overlap', () {
      expect(overlapLength('hello a', 'a b c d'), 0);
    });

    test('a continuation that starts the whole reply over is cut to the new part', () {
      const before = 'Here is a long answer that was cut off in the mid';
      final t = OverlapTrimmer(before);
      final out = StringBuffer()
        ..write(t.add('Here is a long answer that was cut off in the mid'))
        ..write(t.add('dle and here is the rest.'))
        ..write(t.finish());
      expect(out.toString(), 'dle and here is the rest.');
    });

    test('a clean continuation passes through unchanged, even in tiny chunks', () {
      final t = OverlapTrimmer('abc def ghi');
      final out = StringBuffer();
      for (final ch in 'jkl mno pqr stu vwx'.split('')) {
        out.write(t.add(ch));
      }
      out.write(t.finish());
      expect(out.toString(), 'jkl mno pqr stu vwx');
    });
  });

  group('resilient stream', () {
    test('a healthy stream passes straight through, in order', () async {
      final c = _Fake([
        _Attempt([const TextDelta('one '), const TextDelta('two '), const TextDelta('three')]),
      ]);
      final ev = await _collect(resilientStream(client: c, request: _req(), abort: AbortHandle()));
      expect(_text(ev), 'one two three');
      expect(ev.last, isA<LlmDone>());
      expect(c.requests.length, 1);
    });

    test('a drop before any text retries the same request', () async {
      final c = _Fake([
        _Attempt([], fail: StreamDropped('hung up')),
        _Attempt([const TextDelta('answer')]),
      ]);
      final ev = await _collect(resilientStream(client: c, request: _req(), abort: AbortHandle(), backoff: (_) => Duration.zero));
      expect(_text(ev), 'answer');
      expect(c.requests.length, 2);
      expect(c.requests[1].messages.length, 1, reason: 'nothing to continue from');
      expect(ev.whereType<StreamStatusEvent>().any((e) => e.phase == StreamPhase.reconnecting), isTrue);
    });

    test('a drop mid-reply reconnects, asks to continue, and the text is not duplicated', () async {
      const first = 'The quick brown fox jumps';
      final c = _Fake([
        _Attempt([const TextDelta(first)], fail: SocketException('Connection reset by peer')),
        _Attempt([const TextDelta('quick brown fox jumps'), const TextDelta(' over the lazy dog.')]),
      ]);
      final ev = await _collect(resilientStream(client: c, request: _req(), abort: AbortHandle(), backoff: (_) => Duration.zero));
      expect(_text(ev), 'The quick brown fox jumps over the lazy dog.');
      final second = c.requests[1].messages;
      expect(second[second.length - 2].role, 'assistant');
      expect(second[second.length - 2].text, first);
      expect(second.last.role, 'user');
      expect(second.last.text, kContinuePrompt);
    });

    test('text that arrived before the drop is never lost or re-sent to the screen', () async {
      final c = _Fake([
        _Attempt([const TextDelta('Part one, '), const TextDelta('part two, ')], fail: StreamDropped('x')),
        _Attempt([const TextDelta('part three.')]),
        ]);
      final ev = await _collect(resilientStream(client: c, request: _req(), abort: AbortHandle(), backoff: (_) => Duration.zero));
      expect(_text(ev), 'Part one, part two, part three.');
    });

    test('an error from the provider is not retried', () async {
      final c = _Fake([
        _Attempt([], fail: LlmException('HTTP 401: bad key')),
      ]);
      await expectLater(
        _collect(resilientStream(client: c, request: _req(), abort: AbortHandle(), backoff: (_) => Duration.zero)),
        throwsA(isA<LlmException>()),
      );
      expect(c.requests.length, 1);
    });

    test('after a tool call the request is not repeated', () async {
      final c = _Fake([
        _Attempt([ToolCallDone(ToolCall(id: '1', name: 'x', args: const <String, dynamic>{}))], fail: StreamDropped('x')),
        _Attempt([const TextDelta('should never be asked')]),
      ]);
      await expectLater(
        _collect(resilientStream(client: c, request: _req(), abort: AbortHandle(), backoff: (_) => Duration.zero)),
        throwsA(isA<StreamDropped>()),
      );
      expect(c.requests.length, 1);
    });

    test('gives up after the allowed number of reconnects', () async {
      final c = _Fake(List.generate(5, (_) => _Attempt([], fail: StreamDropped('x'))));
      await expectLater(
        _collect(resilientStream(client: c, request: _req(), abort: AbortHandle(), maxReconnects: 2, backoff: (_) => Duration.zero)),
        throwsA(isA<StreamDropped>()),
      );
      expect(c.requests.length, 3);
    });

    test('a connection that goes silent is cut and continued', () async {
      final c = _Fake([
        _Attempt([const TextDelta('Hello, this is the start of ')], hang: true),
        _Attempt([const TextDelta('a longer reply.')]),
      ]);
      final ev = await _collect(resilientStream(
        client: c,
        request: _req(),
        abort: AbortHandle(),
        idleTimeout: const Duration(milliseconds: 150),
        backoff: (_) => Duration.zero,
      ));
      expect(_text(ev), 'Hello, this is the start of a longer reply.');
    });

    test('Stop ends the stream at once without reconnecting', () async {
      final abort = AbortHandle();
      final c = _Fake([
        _Attempt([const TextDelta('partial')], hang: true),
      ]);
      final got = <LlmEvent>[];
      final done = Completer<void>();
      resilientStream(client: c, request: _req(), abort: abort).listen(got.add, onDone: done.complete);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      abort.abort();
      // The fake never answers again; Stop must end the stream anyway.
      await done.future.timeout(const Duration(seconds: 2));
      expect(c.requests.length, 1);
      expect(got.last, isA<LlmDone>());
    });

    test('classifies failures: connection problems retry, provider answers do not', () {
      expect(isNetworkDrop(SocketException('Connection reset by peer')), isTrue);
      expect(isNetworkDrop(LlmException('ClientException: Connection closed while receiving data')), isTrue);
      expect(isNetworkDrop(TimeoutException('x')), isTrue);
      expect(isNetworkDrop(StreamDropped('x')), isTrue);
      expect(isNetworkDrop(LlmException('HTTP 429: rate limit')), isFalse);
      expect(isNetworkDrop(LlmException('HTTP 401: Incorrect API key')), isFalse);
      expect(isNetworkDrop(LlmException('model not found')), isFalse);
    });
  });

  group('OpenAI-compatible (including NVIDIA) streaming', () {
    test('text arrives piece by piece, with usage and reasoning counted', () async {
      final s = _Sse((n, body, req) => _sse(req, [
            jsonEncode({'choices': [{'delta': {'reasoning_content': 'thinking about it'}}]}),
            _oa('Hel'),
            _oa('lo'),
            jsonEncode({'choices': [{'delta': {}, 'finish_reason': 'stop'}], 'usage': {'prompt_tokens': 11, 'completion_tokens': 5}}),
            '[DONE]',
          ]));
      await s.start();
      addTearDown(s.stop);
      final c = OpenAiCompatClient(_cfg(ProviderKind.openai, s.base));
      final ev = await _collect(c.stream(_req(), AbortHandle()));
      expect(ev.whereType<TextDelta>().map((e) => e.text).toList(), <String>['Hel', 'lo']);
      expect(ev.whereType<ReasoningDelta>().length, 1);
      final u = ev.whereType<UsageEvent>().single;
      expect(u.inputTokens, 11);
      expect(u.outputTokens, 5);
      expect(s.bodies.single['stream'], true);
    });

    test('a server that hangs up mid-reply raises a drop, which the wrapper continues', () async {
      final s = _Sse((n, body, req) async {
        if (n == 1) {
          await _cut(req, [_oa('The quick brown fox jumps')]);
        } else {
          await _sse(req, [_oa(' over the lazy dog.'), jsonEncode({'choices': [{'delta': {}, 'finish_reason': 'stop'}]}), '[DONE]']);
        }
      });
      await s.start();
      addTearDown(s.stop);
      final c = OpenAiCompatClient(_cfg(ProviderKind.openai, s.base));
      final ev = await _collect(resilientStream(client: c, request: _req(), abort: AbortHandle(), backoff: (_) => Duration.zero));
      expect(_text(ev), 'The quick brown fox jumps over the lazy dog.');
      expect(s.bodies.length, 2);
      final msgs = (s.bodies[1]['messages'] as List).cast<Map>();
      expect(msgs[msgs.length - 2]['role'], 'assistant');
      expect(msgs.last['content'], kContinuePrompt);
    });

    test('a stream that just ends without a finish marker is treated as cut off', () async {
      final s = _Sse((n, body, req) => _sse(req, [_oa('half an ans')]));
      await s.start();
      addTearDown(s.stop);
      final c = OpenAiCompatClient(_cfg(ProviderKind.openai, s.base));
      await expectLater(_collect(c.stream(_req(), AbortHandle())), throwsA(isA<StreamDropped>()));
    });

    test('a server that refuses streaming is asked again for the whole reply', () async {
      final s = _Sse((n, body, req) async {
        final res = req.response;
        if (body['stream'] == true) {
          res.statusCode = 400;
          res.write(jsonEncode({'error': {'message': 'stream is not supported for this model'}}));
        } else {
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode({
            'choices': [
              {'message': {'content': 'whole reply'}}
            ],
            'usage': {'prompt_tokens': 3, 'completion_tokens': 2},
          }));
        }
        await res.close();
      });
      await s.start();
      addTearDown(s.stop);
      final c = OpenAiCompatClient(_cfg(ProviderKind.openai, s.base));
      final ev = await _collect(c.stream(_req(), AbortHandle()));
      expect(_text(ev), 'whole reply');
      expect(s.bodies.length, 2);
      expect(s.bodies[1]['stream'], false);
    });

    test('a streamed tool call is assembled from its pieces', () async {
      final s = _Sse((n, body, req) => _sse(req, [
            jsonEncode({'choices': [{'delta': {'tool_calls': [{'index': 0, 'id': 'c1', 'function': {'name': 'web_search', 'arguments': '{"q":'}}]}}]}),
            jsonEncode({'choices': [{'delta': {'tool_calls': [{'index': 0, 'function': {'arguments': '"dart"}'}}]}, 'finish_reason': 'tool_calls'}]}),
            '[DONE]',
          ]));
      await s.start();
      addTearDown(s.stop);
      final c = OpenAiCompatClient(_cfg(ProviderKind.openai, s.base));
      final ev = await _collect(c.stream(_req(), AbortHandle()));
      final call = ev.whereType<ToolCallDone>().single.call;
      expect(call.name, 'web_search');
      expect(call.args['q'], 'dart');
    });

    test('Stop closes the connection and ends the stream', () async {
      final s = _Sse((n, body, req) async {
        final res = req.response;
        res.headers.contentType = ContentType('text', 'event-stream');
        for (var i = 0; i < 200; i++) {
          res.write('data: ${_oa('word$i ')}\n\n');
          await res.flush();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await res.close();
      });
      await s.start();
      addTearDown(s.stop);
      final c = OpenAiCompatClient(_cfg(ProviderKind.openai, s.base));
      final abort = AbortHandle();
      var chars = 0;
      final watch = Stopwatch()..start();
      await for (final e in resilientStream(client: c, request: _req(), abort: abort)) {
        if (e is TextDelta) {
          chars += e.text.length;
          if (chars > 30) abort.abort();
        }
      }
      expect(watch.elapsedMilliseconds, lessThan(2500), reason: 'it must not wait for the rest of the 4 seconds of text');
    });
  });

  group('other providers keep working', () {
    test('Anthropic: text, usage and the end marker', () async {
      final s = _Sse((n, body, req) => _sse(req, [
            jsonEncode({'type': 'message_start', 'message': {'usage': {'input_tokens': 21, 'output_tokens': 1}}}),
            jsonEncode({'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': ''}}),
            jsonEncode({'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': 'Hi '}}),
            jsonEncode({'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': 'there'}}),
            jsonEncode({'type': 'content_block_stop', 'index': 0}),
            jsonEncode({'type': 'message_delta', 'usage': {'output_tokens': 9}}),
            jsonEncode({'type': 'message_stop'}),
          ]));
      await s.start();
      addTearDown(s.stop);
      final c = AnthropicClient(_cfg(ProviderKind.anthropic, s.base));
      final ev = await _collect(c.stream(_req(), AbortHandle()));
      expect(_text(ev), 'Hi there');
      expect(ev.whereType<UsageEvent>().map((u) => u.outputTokens).whereType<int>().last, 9);
      expect(s.bodies.single['stream'], true);
    });

    test('Anthropic: a stream with no message_stop is a drop', () async {
      final s = _Sse((n, body, req) => _sse(req, [
            jsonEncode({'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': 'x'}}),
          ]));
      await s.start();
      addTearDown(s.stop);
      final c = AnthropicClient(_cfg(ProviderKind.anthropic, s.base));
      await expectLater(_collect(c.stream(_req(), AbortHandle())), throwsA(isA<StreamDropped>()));
    });

    test('Gemini: text, usage and the finish reason', () async {
      final s = _Sse((n, body, req) => _sse(req, [
            jsonEncode({'candidates': [{'content': {'parts': [{'text': 'Bon'}]}}]}),
            jsonEncode({
              'candidates': [
                {'content': {'parts': [{'text': 'jour'}]}, 'finishReason': 'STOP'}
              ],
              'usageMetadata': {'promptTokenCount': 4, 'candidatesTokenCount': 2}
            }),
          ]));
      await s.start();
      addTearDown(s.stop);
      final c = GeminiClient(_cfg(ProviderKind.gemini, s.base));
      final ev = await _collect(c.stream(_req(), AbortHandle()));
      expect(_text(ev), 'Bonjour');
      expect(ev.whereType<UsageEvent>().last.outputTokens, 2);
    });
  });

  group('stream metrics', () {
    test('first token latency, speed and the connection state come from the real stream', () async {
      final m = StreamMetrics();
      addTearDown(m.dispose);
      expect(m.phase, StreamPhase.idle);
      m.begin('model-x');
      expect(m.phase, StreamPhase.connecting);
      expect(m.connection, contains('Connecting'));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      m.onText('a' * 40);
      expect(m.phase, StreamPhase.streaming);
      expect(m.firstTokenLatency!.inMilliseconds, greaterThanOrEqualTo(100));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      m.onText('b' * 400);
      expect(m.totalTokens, 110);
      expect(m.estimated, isTrue);
      expect(m.tokensPerSecond, greaterThan(50));
      m.onUsage(output: 123);
      expect(m.totalTokens, 123);
      expect(m.estimated, isFalse);
      m.setPhase(StreamPhase.reconnecting, attempt: 2);
      expect(m.connection, contains('Reconnecting (2)'));
      m.finish(StreamPhase.done);
      expect(m.summary, contains('tok/s'));
      expect(m.summary, contains('123 tokens'));
      final frozen = m.generation;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(m.generation, frozen, reason: 'the clock stops when the reply ends');
    });

    test('redraws are batched: many chunks cause far fewer notifications', () async {
      final m = StreamMetrics();
      addTearDown(m.dispose);
      m.begin('x');
      var n = 0;
      m.addListener(() => n++);
      for (var i = 0; i < 500; i++) {
        m.onText('chunk ');
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(n, lessThan(5));
      expect(m.chars, 3000);
    });
  });
}
