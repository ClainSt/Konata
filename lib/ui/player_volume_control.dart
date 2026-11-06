import 'package:flutter/material.dart';

/// Always-visible slider while the playback controls are displayed.
class PlayerVolumeControl extends StatefulWidget {
  const PlayerVolumeControl({
    super.key,
    required this.volume,
    required this.initialVolume,
    required this.onChanged,
  });
  final Stream<double> volume;
  final double initialVolume;
  final Future<void> Function(double) onChanged;

  @override
  State<PlayerVolumeControl> createState() => _PlayerVolumeControlState();
}

class _PlayerVolumeControlState extends State<PlayerVolumeControl> {
  double lastAudible = 100;

  @override
  Widget build(BuildContext context) => StreamBuilder<double>(
    stream: widget.volume,
    initialData: widget.initialVolume,
    builder: (context, snapshot) {
      final value = (snapshot.data ?? 100).clamp(0.0, 100.0);
      if (value > 0) lastAudible = value;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            color: Colors.white,
            tooltip: '${value.round()}%',
            icon: Icon(value == 0 ? Icons.volume_off : Icons.volume_up),
            onPressed: () => widget.onChanged(value == 0 ? lastAudible : 0),
          ),
          SizedBox(
            width: MediaQuery.sizeOf(context).width < 520 ? 64 : 100,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                activeTrackColor: Colors.white,
                inactiveTrackColor: Colors.white38,
                thumbColor: Colors.white,
              ),
              child: Slider(
                value: value,
                max: 100,
                label: '${value.round()}%',
                onChanged: widget.onChanged,
              ),
            ),
          ),
        ],
      );
    },
  );
}
