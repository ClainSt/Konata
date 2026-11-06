import 'package:flutter/material.dart';
import '../l10n/strings.dart';

/// Shared by the normal and fullscreen mobile video controls.
class SeekIndicator extends StatelessWidget {
  const SeekIndicator({super.key, required this.offset});
  final Duration offset;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                offset.isNegative ? Icons.fast_rewind : Icons.fast_forward,
                color: Colors.white,
              ),
              const SizedBox(width: 8),
              Text(
                context.l10n.seekSeconds(offset.inSeconds.abs()),
                softWrap: false,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
