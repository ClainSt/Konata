import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// One lazy horizontal strip for touch, trackpad, mouse drag and arrow keys.
class HorizontalRail extends StatefulWidget {
  const HorizontalRail({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    required this.itemWidth,
    this.height = 190,
    this.spacing = 12,
    this.controller,
  });
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final double itemWidth, height, spacing;
  final ScrollController? controller;

  @override
  State<HorizontalRail> createState() => _HorizontalRailState();
}

class _HorizontalRailState extends State<HorizontalRail> {
  final _owned = ScrollController();
  ScrollController get controller => widget.controller ?? _owned;
  @override
  void dispose() {
    _owned.dispose();
    super.dispose();
  }

  void move(int direction) {
    if (!controller.hasClients) return;
    final target =
        (controller.offset + direction * (widget.itemWidth + widget.spacing))
            .clamp(0.0, controller.position.maxScrollExtent);
    if (MediaQuery.disableAnimationsOf(context)) {
      controller.jumpTo(target);
    } else {
      controller.animateTo(
        target,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.arrowLeft): () => move(-1),
      const SingleActivator(LogicalKeyboardKey.arrowRight): () => move(1),
    },
    child: Focus(
      child: ScrollConfiguration(
        behavior: const MaterialScrollBehavior().copyWith(
          scrollbars: false,
          dragDevices: {
            PointerDeviceKind.touch,
            PointerDeviceKind.mouse,
            PointerDeviceKind.trackpad,
            PointerDeviceKind.stylus,
            PointerDeviceKind.invertedStylus,
          },
        ),
        child: SizedBox(
          height: widget.height,
          child: ListView.separated(
            controller: controller,
            scrollDirection: Axis.horizontal,
            itemCount: widget.itemCount,
            separatorBuilder: (_, _) => SizedBox(width: widget.spacing),
            itemBuilder: (context, index) => SizedBox(
              width: widget.itemWidth,
              child: widget.itemBuilder(context, index),
            ),
          ),
        ),
      ),
    ),
  );
}
