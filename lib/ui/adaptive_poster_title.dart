import 'package:flutter/material.dart';

/// Scales an anime title to the available card width instead of reserving
/// two lines at one fixed font size for every work.
///
/// The maximum title height is capped so even a long two-line title still
/// leaves room for the year/status row beneath it.
class AdaptivePosterTitle extends StatelessWidget {
  const AdaptivePosterTitle({
    super.key,
    required this.title,
    this.minFontSize = 14,
    this.maxFontSize = 28,
    this.maxTitleHeight = 48,
  });

  final String title;
  final double minFontSize;
  final double maxFontSize;
  final double maxTitleHeight;

  @override
  Widget build(BuildContext context) {
    final baseStyle = DefaultTextStyle.of(context).style
        .merge(Theme.of(context).textTheme.titleMedium)
        .copyWith(fontWeight: FontWeight.w600, height: 1.1);

    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context);
        final direction = Directionality.of(context);
        final maxWidth = constraints.maxWidth;
        var size = minFontSize;

        // Find the largest font that displays the COMPLETE title in at most
        // two lines. Ellipsis remains the fallback for extremely long titles.
        for (
          var candidate = maxFontSize;
          candidate >= minFontSize;
          candidate -= 0.5
        ) {
          final painter = TextPainter(
            text: TextSpan(
              text: title,
              style: baseStyle.copyWith(fontSize: candidate),
            ),
            maxLines: 2,
            textDirection: direction,
            textScaler: scale,
          )..layout(maxWidth: maxWidth);
          final fits =
              !painter.didExceedMaxLines &&
              painter.height <= maxTitleHeight &&
              painter.width <= maxWidth;
          painter.dispose();
          if (fits) {
            size = candidate;
            break;
          }
        }

        return Text(
          title,
          key: const ValueKey('adaptive-poster-title-text'),
          style: baseStyle.copyWith(fontSize: size),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.start,
        );
      },
    );
  }
}
