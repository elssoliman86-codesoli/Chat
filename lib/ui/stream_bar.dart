import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';

import '../data/services.dart';
import '../llm/llm.dart' show StreamPhase;
import '../llm/stream_metrics.dart';
import 'glass/tokens.dart';
import 'theme.dart';

Color streamPhaseColor(StreamPhase p, Palette pal) => switch (p) {
      StreamPhase.streaming => pal.accent,
      StreamPhase.connecting || StreamPhase.waiting => const Color(0xFFBF5AF2),
      StreamPhase.reconnecting => const Color(0xFFFF9F0A),
      StreamPhase.done => const Color(0xFF30D158),
      StreamPhase.failed => const Color(0xFFFF453A),
      _ => pal.secondary,
    };

/// The live numbers of the reply that is arriving: connection state, time to first token, speed, tokens.
/// Reads the real stream; nothing here is simulated.
class LiveStreamBar extends StatefulWidget {
  const LiveStreamBar({super.key, this.metrics, this.compact = false});

  final StreamMetrics? metrics;
  final bool compact;

  @override
  State<LiveStreamBar> createState() => _LiveStreamBarState();
}

class _LiveStreamBarState extends State<LiveStreamBar> {
  Timer? _tick;

  StreamMetrics get _m => widget.metrics ?? engine.metrics;

  @override
  void initState() {
    super.initState();
    // Keeps the clock moving while no text has arrived yet.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _m.running) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  String _sec(Duration d) => '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';

  @override
  Widget build(BuildContext context) {
    final pal = paletteOf(context);
    return ListenableBuilder(
      listenable: _m,
      builder: (context, _) {
        final m = _m;
        if (m.phase == StreamPhase.idle) return const SizedBox.shrink();
        final color = streamPhaseColor(m.phase, pal);
        final f = m.firstTokenLatency;
        final items = <String>[
          m.phaseLabel,
          if (f != null) 'First token ${_sec(f)}',
          if (m.totalTokens > 0) '${m.estimated ? '~' : ''}${m.totalTokens} tok',
          if (m.tokensPerSecond > 0) '${m.tokensPerSecond.toStringAsFixed(m.tokensPerSecond >= 10 ? 0 : 1)} tok/s',
          _sec(m.elapsed),
          if (m.reconnects > 0) '${m.reconnects} reconnect${m.reconnects == 1 ? '' : 's'}',
        ];
        return Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(GlassTokens.radiusSm),
              border: Border.all(color: color.withValues(alpha: 0.35), width: GlassTokens.stroke),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              _Dot(color: color, pulsing: m.running),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  items.join('  ·  '),
                  maxLines: widget.compact ? 1 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: pal.secondary, fontFeatures: const [FontFeature.tabularFigures()]),
                ),
              ),
            ]),
          ),
        );
      },
    );
  }
}

class _Dot extends StatefulWidget {
  const _Dot({required this.color, required this.pulsing});

  final Color color;
  final bool pulsing;

  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void initState() {
    super.initState();
    if (widget.pulsing) _c.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _Dot old) {
    super.didUpdateWidget(old);
    if (widget.pulsing && !_c.isAnimating) {
      _c.repeat(reverse: true);
    } else if (!widget.pulsing && _c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: widget.color,
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: widget.color.withValues(alpha: 0.5 * (widget.pulsing ? _c.value : 0.4)), blurRadius: 6)],
        ),
      ),
    );
  }
}
