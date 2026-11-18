import 'package:flutter_test/flutter_test.dart';
import 'package:omni_chat/core/models.dart';
import 'package:omni_chat/data/auto_health.dart';
import 'package:omni_chat/data/model_fallback.dart';

ProviderConfig prov(String id, List<String> models, Map<String, int> health, {String model = ''}) =>
    ProviderConfig(id: id, name: id, kind: ProviderKind.openai, baseUrl: 'https://x', models: models, model: model, health: health);

void main() {
  group('isModelFailure', () {
    test('out of tokens, rate limits, bad key, missing model and server errors switch', () {
      expect(isModelFailure('HTTP 429: Rate limit reached'), isTrue);
      expect(isModelFailure('HTTP 402: Insufficient credits'), isTrue);
      expect(isModelFailure('HTTP 401: Invalid API key'), isTrue);
      expect(isModelFailure('HTTP 404: The model does not exist'), isTrue);
      expect(isModelFailure('HTTP 503: upstream down'), isTrue);
      expect(isModelFailure('HTTP 400: You exceeded your current quota'), isTrue);
      expect(isModelFailure('You have run out of tokens'), isTrue);
    });

    test('dropped connections and timeouts never switch', () {
      expect(isModelFailure('SocketException: Failed host lookup: api.x.com'), isFalse);
      expect(isModelFailure('ClientException: Connection closed before full header was received'), isFalse);
      expect(isModelFailure('TimeoutException after 0:10:00.000000'), isFalse);
      expect(isModelFailure('Connection reset by peer'), isFalse);
    });

    test('an ordinary 400 about the request itself does not switch', () {
      expect(isModelFailure('HTTP 400: messages must not be empty'), isFalse);
    });
  });

  test('failureStatus and isAccountFailure', () {
    expect(failureStatus('HTTP 429: slow down'), 429);
    expect(failureStatus('something else'), isNull);
    expect(isAccountFailure('HTTP 402: pay up'), isTrue);
    expect(isAccountFailure('HTTP 429: slow down'), isFalse);
    expect(isAccountFailure('HTTP 400: billing hard limit reached'), isTrue);
  });

  group('fallbackCandidates', () {
    final a = prov('a', ['a1', 'a2', 'a3'], {'a1': 200, 'a2': 200, 'a3': 429});
    final b = prov('b', ['b1', 'b2'], {'b1': 200, 'b2': 0}, model: 'b1');
    final c = prov('c', ['c1'], {});

    test('only models that passed the health check, same provider first', () {
      final r = fallbackCandidates([a, b, c], a, {candidateKey(a, 'a1')});
      expect(r.map((e) => e.$2), ['a2', 'b1']);
    });

    test('after an account failure other providers come first', () {
      final r = fallbackCandidates([a, b, c], a, {candidateKey(a, 'a1')}, otherProviderFirst: true);
      expect(r.map((e) => e.$2), ['b1', 'a2']);
    });

    test('tried models are skipped and nothing healthy gives an empty list', () {
      expect(fallbackCandidates([c], c, <String>{}), isEmpty);
      final r = fallbackCandidates([a, b], a, {candidateKey(a, 'a1'), candidateKey(a, 'a2'), candidateKey(b, 'b1')});
      expect(r, isEmpty);
    });
  });

  test('autoHealthJobs covers tested models, selected models and the current chat model without duplicates', () {
    final a = prov('a', ['a1', 'a2'], {'a1': 200}, model: 'a2');
    final b = prov('b', ['b1'], {}, model: 'b1');
    final jobs = autoHealthJobs([a, b], currentProvider: b, currentModel: 'b1');
    expect(jobs.map((j) => '${j.$1.id}:${j.$2}'), ['b:b1', 'a:a2', 'a:a1']);
    expect(autoHealthJobs([a, b], limit: 2).length, 2);
  });
}
