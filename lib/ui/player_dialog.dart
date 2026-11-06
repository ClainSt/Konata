import 'package:flutter/material.dart';

Future<void> showPlayerDialog(
  BuildContext context,
  Widget child,
) => showDialog<void>(
  context: context,
  builder: (_) => Theme(
    data: Theme.of(context).copyWith(
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
        selectedColor: Theme.of(context).colorScheme.onSurface,
        selectedTileColor: Theme.of(
          context,
        ).colorScheme.primary.withValues(alpha: .12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    child: Dialog(
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: Theme.of(context).dividerColor.withValues(alpha: .15),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      insetPadding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        key: const ValueKey('player-popup-panel'),
        constraints: BoxConstraints(
          maxWidth: 460,
          maxHeight: MediaQuery.sizeOf(context).height * .65,
        ),
        child: Padding(padding: const EdgeInsets.all(8), child: child),
      ),
    ),
  ),
);
