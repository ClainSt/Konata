import 'package:flutter/material.dart';

/// Shared, equal-sized footer actions. Up to three actions stay on one row;
/// larger groups use equal columns instead of a vertical OverflowBar stack.
class UniformActionBar extends StatelessWidget {
  const UniformActionBar({super.key, required this.children});
  final List<Widget> children;
  static const height = 48.0;
  static const radius = 8.0;

  Widget normalize(BuildContext context, Widget child, double rowHeight) {
    if (child is! ButtonStyleButton) return child;
    final style = (child.style ?? const ButtonStyle()).copyWith(
      minimumSize: WidgetStatePropertyAll(Size(0, rowHeight)),
      maximumSize: WidgetStatePropertyAll(Size(double.infinity, rowHeight)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 8),
      ),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
      ),
      textStyle: WidgetStatePropertyAll(
        Theme.of(context).textTheme.labelLarge!.copyWith(
          fontSize: 14,
          height: 1.2,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
        ),
      ),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    final label = DefaultTextStyle.merge(
      textAlign: TextAlign.center,
      maxLines: 2,
      softWrap: true,
      overflow: TextOverflow.ellipsis,
      child: child.child ?? const SizedBox(),
    );
    if (child is FilledButton) {
      return FilledButton(
        key: child.key,
        style: style,
        onPressed: child.onPressed,
        onLongPress: child.onLongPress,
        child: label,
      );
    }
    if (child is OutlinedButton) {
      return OutlinedButton(
        key: child.key,
        style: style,
        onPressed: child.onPressed,
        onLongPress: child.onLongPress,
        child: label,
      );
    }
    if (child is ElevatedButton) {
      return ElevatedButton(
        key: child.key,
        style: style,
        onPressed: child.onPressed,
        onLongPress: child.onLongPress,
        child: label,
      );
    }
    return TextButton(
      key: child.key,
      style: style,
      onPressed: child.onPressed,
      onLongPress: child.onLongPress,
      child: label,
    );
  }

  @override
  Widget build(BuildContext context) {
    final rowHeight =
        (MediaQuery.textScalerOf(context).scale(14) * 2 * 1.2 + 12).clamp(
          height,
          double.infinity,
        );
    final columns = children.length > 3 ? 2 : children.length;
    if (columns == 0) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var start = 0; start < children.length; start += columns) ...[
          if (start > 0) const SizedBox(height: 8),
          Row(
            children: [
              for (var col = 0; col < columns; col++) ...[
                if (col > 0) const SizedBox(width: 8),
                Expanded(
                  child: SizedBox(
                    height: rowHeight,
                    child: start + col < children.length
                        ? normalize(context, children[start + col], rowHeight)
                        : const SizedBox.shrink(),
                  ),
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }
}
