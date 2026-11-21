import 'dart:async';
import 'dart:math';

import '../core/models.dart';
import 'llm.dart';

const String kContinuePrompt = 'Your previous reply was cut off by a network interruption. Continue exactly from where it stopped: '
    'do not repeat anything you already wrote and do not add an introduction. If the reply was already complete, answer with nothing.';

/// How many characters at the start of [incoming] repeat the end of [existing] (0 when they do not overlap
/// by a meaningful amount). Used to cut a continuation that starts a little before where the text stopped.
int overlapLength(String existing, String incoming, {int minimum = 12, int maximum = 600}) {
  final top = min(min(existing.length, incoming.length), maximum);
  for (var k = top; k >= minimum; k--) {
    if (existing.endsWith(incoming.substring(0, k))) return k;
  }
  return 0;
}

/// Removes from a continuation whatever it repeats of the reply written so far, whether it re-sends the last
/// few sentences or starts the whole reply over. It holds back the first characters until it can tell.
class OverlapTrimmer {
  OverlapTrimmer(this.existing, {this.window = 160});

  final String existing;
  final int window;
  final StringBuffer _held = StringBuffer();
  bool _decided = false;

  bool get decided => _decided;

  String add(String chunk) {
    if (_decided) return chunk;
    _held.write(chunk);
    final held = _held.toString();
    final restart = existing.length > 40 && held.length >= 40 && existing.startsWith(held.substring(0, 40));
    final need = restart ? existing.length : window;
    if (held.length < need) return '';
    return _decide(held);
  }

  String finish() {
    if (_decided) return '';
    return _decide(_held.toString());
  }

  String _decide(String incoming) {
    _decided = true;
    if (incoming.length >= existing.length && existing.isNotEmpty && incoming.startsWith(existing)) {
      return incoming.substring(existing.length);
    }
    final skip = overlapLength(existing, incoming);
    return incoming.substring(skip);
  }
}

/// The request that asks the model to carry on after a dropped connection.
LlmRequest continuationRequest(LlmRequest request, String partial) {
  return request.withMessages(<ChatMessage>[
    ...request.messages,
    ChatMessage(role: 'assistant', text: partial),
    ChatMessage(role: 'user', text: kContinuePrompt, auto: true),
  ]);
}

/// Streams a reply and survives a bad connection: when the network drops (or the stream goes silent) it
/// reconnects, asks the model to continue from the text received so far, and removes any repeated text, so
/// the person sees one unbroken reply. Provider errors (bad key, rate limit…) are not retried here.
Stream<LlmEvent> resilientStream({
  required LlmClient client,
  required LlmRequest request,
  required AbortHandle abort,
  int maxReconnects = 3,
  Duration firstTokenTimeout = const Duration(minutes: 10),
  Duration idleTimeout = const Duration(seconds: 90),
  Duration Function(int attempt)? backoff,
}) async* {
  final emitted = StringBuffer();
  var toolSeen = false;
  var thinkingSeen = false;
  var attempt = 0;
  yield const StreamStatusEvent(StreamPhase.connecting);

  while (true) {
    final continuing = emitted.isNotEmpty;
    final req = continuing ? continuationRequest(request, emitted.toString()) : request;
    final trimmer = continuing ? OverlapTrimmer(emitted.toString()) : null;
    StreamIterator<LlmEvent>? it;
    var gotAny = false;
    var finished = false;
    Object? failure;
    try {
      it = StreamIterator<LlmEvent>(client.stream(req, abort));
      while (true) {
        final wait = (gotAny || emitted.isNotEmpty) ? idleTimeout : firstTokenTimeout;
        // Stop wins over everything: it must not wait for a socket that may never answer.
        final has = await Future.any<bool>(<Future<bool>>[it.moveNext(), abort.whenAborted.then((_) => false)]).timeout(wait);
        if (!has) break;
        final e = it.current;
        if (!gotAny) {
          gotAny = true;
          if (e is! UsageEvent) yield const StreamStatusEvent(StreamPhase.waiting);
        }
        if (e is TextDelta) {
          final out = trimmer == null ? e.text : trimmer.add(e.text);
          if (out.isNotEmpty) {
            emitted.write(out);
            yield TextDelta(out);
          }
        } else if (e is ToolCallDone) {
          toolSeen = true;
          yield e;
        } else if (e is ThinkingDone) {
          thinkingSeen = true;
          yield e;
        } else if (e is LlmDone) {
          finished = true;
          final rest = trimmer?.finish() ?? '';
          if (rest.isNotEmpty) {
            emitted.write(rest);
            yield TextDelta(rest);
          }
          yield e;
        } else {
          yield e;
        }
      }
    } on TimeoutException {
      abort.client?.close(); // cuts the stalled socket
      failure = StreamDropped('The connection went quiet');
    } catch (e) {
      failure = e;
    } finally {
      // Not awaited: a generator that is stuck waiting on a dead socket would never answer the cancel.
      final cancelling = it?.cancel();
      if (cancelling != null) unawaited(cancelling.catchError((Object _) {}));
    }

    if (abort.aborted) {
      if (!finished) yield const LlmDone();
      return;
    }
    if (finished) return;
    failure ??= StreamDropped('The connection closed before the reply was finished');

    final retryable = isNetworkDrop(failure) && !toolSeen && !(thinkingSeen && emitted.isNotEmpty) && attempt < maxReconnects;
    if (!retryable) {
      if (failure is Exception) throw failure;
      throw LlmException(failure.toString());
    }
    attempt++;
    yield StreamStatusEvent(StreamPhase.reconnecting, attempt: attempt, detail: failure.toString());
    final pause = backoff?.call(attempt) ?? Duration(milliseconds: 700 * (1 << min(attempt - 1, 3)));
    await Future<void>.delayed(pause);
    if (abort.aborted) {
      yield const LlmDone();
      return;
    }
  }
}
