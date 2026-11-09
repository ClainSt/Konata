import 'package:flutter/material.dart';

/// Finite, framework-owned transitions. No idle tickers or image copies.
class KonataMotion {
  // One shared image moves; the destination page remains spatially anchored.
  static Duration coverDuration(BuildContext context, {bool reverse = false}) =>
      MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : Duration(milliseconds: reverse ? 320 : 360);

  static Widget coverTransition(Animation<double> animation, Widget child) =>
      FadeTransition(
        opacity: animation.drive(CurveTween(curve: Curves.easeOutCubic)),
        child: child,
      );

  static Duration duration(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : const Duration(milliseconds: 240);

  static Widget transition(Animation<double> animation, Widget child) {
    final curve = animation.drive(CurveTween(curve: Curves.easeOutCubic));
    return SlideTransition(
      position: Tween(
        begin: const Offset(.025, 0),
        end: Offset.zero,
      ).animate(curve),
      child: child,
    );
  }

  /// Sections enter over a clean surface, not over the previous folder list.
  /// Only the incoming page is mounted by sectionLayout, even on rapid changes.
  static Widget sectionTransition(Animation<double> animation, Widget child) {
    final progress = animation.drive(CurveTween(curve: Curves.easeOutCubic));
    return FadeTransition(
      opacity: progress,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, .025),
          end: Offset.zero,
        ).animate(progress),
        child: child,
      ),
    );
  }

  static Widget sectionLayout(Widget? current, List<Widget> previous) =>
      ClipRect(child: current ?? const SizedBox.shrink());
}

/// Both endpoints and the flight use the same clipping/cropping model. Keeping
/// the frame inside Hero prevents a square shuttle snapping to a rounded cover.
class KonataPoster extends StatelessWidget {
  const KonataPoster({
    super.key,
    required this.tag,
    required this.image,
    this.alignment = Alignment.center,
    this.radius = 4,
    this.gradient,
  });

  final Object tag;
  final Widget Function(Alignment alignment) image;
  final Alignment alignment;
  final double radius;
  final Gradient? gradient;
  static const _curve = Cubic(.2, 0, .2, 1);

  @override
  Widget build(BuildContext context) => Hero(
    tag: tag,
    curve: _curve,
    reverseCurve: _curve.flipped,
    createRectTween: (begin, end) => RectTween(begin: begin, end: end),
    flightShuttleBuilder: (_, animation, direction, from, to) {
      final start = (from.widget as Hero).child as _PosterFrame;
      final end = (to.widget as Hero).child as _PosterFrame;
      return AnimatedBuilder(
        animation: animation,
        builder: (_, _) {
          final t = direction == HeroFlightDirection.push
              ? animation.value
              : 1 - animation.value;
          return _PosterFrame(
            key: const ValueKey('poster-flight'),
            image: start.image,
            alignment: Alignment.lerp(start.alignment, end.alignment, t)!,
            radius: start.radius + (end.radius - start.radius) * t,
            gradient: Gradient.lerp(start.gradient, end.gradient, t),
          );
        },
      );
    },
    child: _PosterFrame(
      image: image,
      alignment: alignment,
      radius: radius,
      gradient: gradient,
    ),
  );
}

class _PosterFrame extends StatelessWidget {
  const _PosterFrame({
    super.key,
    required this.image,
    required this.alignment,
    required this.radius,
    required this.gradient,
  });
  final Widget Function(Alignment alignment) image;
  final Alignment alignment;
  final double radius;
  final Gradient? gradient;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(gradient: gradient),
      child: image(alignment),
    ),
  );
}

class KonataPageTransitions extends PageTransitionsBuilder {
  const KonataPageTransitions();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => MediaQuery.disableAnimationsOf(context)
      ? child
      : KonataMotion.transition(animation, child);
}
