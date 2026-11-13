import 'package:flutter/material.dart';
import '../l10n/strings.dart';

/// State belongs to WatchPage so hiding controls never clears the lock.
class PlayerOrientationButton extends StatelessWidget {
  const PlayerOrientationButton({
    super.key,
    required this.locked,
    required this.busy,
    required this.onPressed,
  });

  final bool locked;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    key: const ValueKey('playback-orientation'),
    tooltip: locked
        ? context.l10n.unlockOrientation
        : context.l10n.lockOrientation,
    color: Colors.white,
    isSelected: locked,
    icon: Icon(locked ? Icons.screen_lock_landscape : Icons.screen_rotation),
    onPressed: busy ? null : onPressed,
  );
}
