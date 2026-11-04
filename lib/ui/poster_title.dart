import 'package:flutter/material.dart';

/// Compact media-library title, following a poster-first visual hierarchy.
///
/// Keep a consistent, moderate font size for every work. Long titles use a
/// single-line ellipsis; the full name is available on hover or long press.
class PosterTitle extends StatelessWidget {
  const PosterTitle({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: title,
      child: Text(
        title,
        key: const ValueKey('poster-title-text'),
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          fontSize: 18,
          fontWeight: FontWeight.w500,
          height: 1.2,
        ),
      ),
    );
  }
}
