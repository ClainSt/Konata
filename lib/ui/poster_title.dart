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
    final style = Theme.of(context).textTheme.titleMedium!.copyWith(
      fontSize: 16,
      fontWeight: FontWeight.w600,
      height: 1.5,
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .7),
    );
    return Tooltip(
      message: title,
      child: Text(
        title,
        key: const ValueKey('poster-title-text'),
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.left,
        textDirection: TextDirection.ltr,
        locale: const Locale('zh', 'Hans'),
        strutStyle: StrutStyle.fromTextStyle(style, forceStrutHeight: true),
        textHeightBehavior: const TextHeightBehavior(
          leadingDistribution: TextLeadingDistribution.even,
        ),
        style: style,
      ),
    );
  }
}
