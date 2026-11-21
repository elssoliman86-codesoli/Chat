import 'dart:async';

import 'package:flutter/foundation.dart';

import 'llm.dart' show StreamPhase;

/// Live numbers of the reply that is streaming right now: how long the first token took, how fast text is
/// arriving, how many tokens so far, and the state of the connection. All of it comes from the real stream.
class StreamMetrics extends ChangeNotifier {
  StreamPhase phase = StreamPhase.idle;
  String model = '';
  String detail = '';
  int reconnects = 0;

  DateTime? startedAt;
  DateTime? firstTokenAt;
  DateTime? endedAt;

  int chars = 0;
  int reasoningChars = 0;
  int chunks = 0;

  /// Token counts the provider reported (null while only an estimate is available).
  int? inputTokens;
  int? outputTokens;

  Timer? _timer;
  bool _dirty = false;

  bool get running => phase == StreamPhase.connecting || phase == StreamPhase.waiting || phase == StreamPhase.streaming || phase == StreamPhase.reconnecting;

  void begin(String model) {
    _timer?.cancel();
    this.model = model;
    phase = StreamPhase.connecting;
    detail = '';
    reconnects = 0;
    startedAt = DateTime.now();
    firstTokenAt = null;
    endedAt = null;
    chars = 0;
    reasoningChars = 0;
    chunks = 0;
    inputTokens = null;
    outputTokens = null;
    _push(force: true);
  }

  void setPhase(StreamPhase p, {String detail = '', int attempt = 0}) {
    if (p == StreamPhase.reconnecting) reconnects = attempt > reconnects ? attempt : reconnects;
    phase = p;
    this.detail = detail;
    _push(force: true);
  }

  void onText(String text) {
    if (text.isEmpty) return;
    firstTokenAt ??= DateTime.now();
    chars += text.length;
    chunks++;
    if (phase != StreamPhase.streaming) phase = StreamPhase.streaming;
    _push();
  }

  void onReasoning(int n) {
    reasoningChars += n;
    if (phase == StreamPhase.connecting || phase == StreamPhase.reconnecting) phase = StreamPhase.waiting;
    _push();
  }

  void onUsage({int? input, int? output}) {
    if (input != null) inputTokens = input;
    if (output != null) outputTokens = output;
    _push();
  }

  void finish(StreamPhase end) {
    endedAt = DateTime.now();
    phase = end;
    _push(force: true);
  }

  /// Time until the first piece of the answer arrived.
  Duration? get firstTokenLatency => (startedAt == null || firstTokenAt == null) ? null : firstTokenAt!.difference(startedAt!);

  /// How long the model has been writing (first token to now, or to the end).
  Duration get generation {
    final from = firstTokenAt;
    if (from == null) return Duration.zero;
    return (endedAt ?? DateTime.now()).difference(from);
  }

  /// Tokens produced so far: what the provider reported, otherwise about one token per four characters.
  int get totalTokens => outputTokens ?? (chars / 4).ceil();
  bool get estimated => outputTokens == null;

  double get tokensPerSecond {
    final s = generation.inMilliseconds / 1000.0;
    if (s < 0.25) return 0;
    return totalTokens / s;
  }

  Duration get elapsed => startedAt == null ? Duration.zero : (endedAt ?? DateTime.now()).difference(startedAt!);

  /// Connection state in words.
  String get connection => switch (phase) {
        StreamPhase.idle => 'Not connected',
        StreamPhase.connecting => 'Connecting…',
        StreamPhase.waiting => 'Connected — model is thinking',
        StreamPhase.streaming => 'Connected',
        StreamPhase.reconnecting => 'Reconnecting ($reconnects)…',
        StreamPhase.done => 'Finished',
        StreamPhase.stopped => 'Stopped',
        StreamPhase.failed => 'Disconnected',
      };

  String get phaseLabel => switch (phase) {
        StreamPhase.idle => 'Idle',
        StreamPhase.connecting => 'Connecting',
        StreamPhase.waiting => 'Waiting for first token',
        StreamPhase.streaming => 'Streaming',
        StreamPhase.reconnecting => 'Reconnecting',
        StreamPhase.done => 'Complete',
        StreamPhase.stopped => 'Stopped',
        StreamPhase.failed => 'Failed',
      };

  /// One short line for the footer of a finished reply.
  String get summary {
    final parts = <String>[];
    final f = firstTokenLatency;
    if (f != null) parts.add('${(f.inMilliseconds / 1000).toStringAsFixed(1)}s to first token');
    if (totalTokens > 0) parts.add('${estimated ? '~' : ''}$totalTokens tokens');
    final tps = tokensPerSecond;
    if (tps > 0) parts.add('${tps.toStringAsFixed(tps >= 10 ? 0 : 1)} tok/s');
    if (generation.inMilliseconds > 0) parts.add('${(generation.inMilliseconds / 1000).toStringAsFixed(1)}s');
    return parts.join(' · ');
  }

  // At most ~7 redraws a second however fast chunks arrive.
  void _push({bool force = false}) {
    if (force) {
      _timer?.cancel();
      _timer = null;
      _dirty = false;
      notifyListeners();
      return;
    }
    _dirty = true;
    _timer ??= Timer(const Duration(milliseconds: 140), () {
      _timer = null;
      if (_dirty) {
        _dirty = false;
        notifyListeners();
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
