import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

/// 仅在真实播放且可见时驱动的三柱律动，队列与小窗共享。
class AudioPlayingBars extends StatefulWidget {
  const AudioPlayingBars({
    super.key,
    required this.playing,
    required this.color,
  });

  final ValueListenable<bool> playing;
  final Color color;

  @override
  State<AudioPlayingBars> createState() => _AudioPlayingBarsState();
}

class _AudioPlayingBarsState extends State<AudioPlayingBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _phase;
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    _phase = AnimationController(
      vsync: this,
      duration: KonataPlaybackTokens.equalizerCycleDuration,
    );
    widget.playing.addListener(_sync);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled;
    _sync();
  }

  @override
  void didUpdateWidget(covariant AudioPlayingBars oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playing != widget.playing) {
      oldWidget.playing.removeListener(_sync);
      widget.playing.addListener(_sync);
    }
    _sync();
  }

  void _sync() {
    if (_visible && widget.playing.value) {
      if (!_phase.isAnimating) _phase.repeat();
    } else {
      _phase.stop();
    }
  }

  @override
  void dispose() {
    widget.playing.removeListener(_sync);
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: SizedBox(
      key: const ValueKey('audio_playing_bars'),
      width: 12,
      height: 12,
      child: CustomPaint(painter: _BarsPainter(_phase, widget.color)),
    ),
  );
}

class _BarsPainter extends CustomPainter {
  _BarsPainter(this.phase, this.color) : super(repaint: phase);

  final Animation<double> phase;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    for (var i = 0; i < 3; i++) {
      final height =
          4 + 7 * (0.5 + 0.5 * math.sin(phase.value * math.pi * 2 + i * 1.4));
      final rect = Rect.fromLTWH(i * 4.0, size.height - height, 2.5, height);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(1)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BarsPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.phase != phase;
}
