import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Handles wheel signals even while the playback controls are hidden.
class PlayerScrollVolume extends StatelessWidget {
  const PlayerScrollVolume({
    super.key,
    required this.child,
    required this.volume,
    required this.onChanged,
    this.enabled = true,
  });

  final Widget child;
  final double Function() volume;
  final Future<void> Function(double) onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.opaque,
    onPointerSignal: !enabled
        ? null
        : (event) {
            if (event is! PointerScrollEvent || event.scrollDelta.dy == 0) {
              return;
            }
            GestureBinding.instance.pointerSignalResolver.register(event, (_) {
              onChanged(
                (volume() + (event.scrollDelta.dy < 0 ? 5 : -5)).clamp(
                  0.0,
                  100.0,
                ),
              );
            });
          },
    child: child,
  );
}
