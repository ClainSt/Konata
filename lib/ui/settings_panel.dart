import 'package:flutter/material.dart';

/// Common surface for all cards in the settings content column.
class SettingsPanel extends StatelessWidget {
  const SettingsPanel({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: Card(
      margin: EdgeInsets.zero,
      child: Padding(padding: padding, child: child),
    ),
  );
}
