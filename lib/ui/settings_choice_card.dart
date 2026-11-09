import 'settings_panel.dart';
import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Theme and language share the same typography, card and anchored menu.
class SettingsChoiceCard<T> extends StatelessWidget {
  const SettingsChoiceCard({
    super.key,
    required this.title,
    required this.description,
    required this.icon,
    required this.value,
    required this.options,
    required this.label,
    required this.onChanged,
    required this.selectorKey,
    this.enabled = true,
  });
  final String title, description;
  final IconData icon;
  final T value;
  final List<T> options;
  final String Function(T) label;
  final Future<void> Function(T) onChanged;
  final Key selectorKey;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final choiceStyle = theme.textTheme.bodyMedium!.copyWith(
      fontSize: 16,
      fontWeight: FontWeight.w600,
      height: 1.25,
      letterSpacing: 0,
      color: theme.colorScheme.onSurface,
    );
    return SettingsPanel(
      child: LayoutBuilder(
        builder: (context, bounds) {
          var width = 160.0;
          for (final option in options) {
            final painter = TextPainter(
              text: TextSpan(text: label(option), style: choiceStyle),
              textDirection: Directionality.of(context),
              textScaler: MediaQuery.textScalerOf(context),
            )..layout();
            width = math.max(width, painter.width + 68);
            painter.dispose();
          }
          width = math.min(width, math.max(0, bounds.maxWidth - 40));
          final rowHeight = math.max(
            48.0,
            MediaQuery.textScalerOf(context).scale(20) + 24,
          );
          final selector = SizedBox(
            width: width,
            child: MenuAnchor(
              consumeOutsideTap: false,
              alignmentOffset: const Offset(0, 4),
              style: MenuStyle(
                alignment: Alignment.bottomLeft,
                padding: const WidgetStatePropertyAll(EdgeInsets.zero),
                minimumSize: WidgetStatePropertyAll(Size(width, 0)),
                maximumSize: WidgetStatePropertyAll(
                  Size(width, double.infinity),
                ),
                backgroundColor: WidgetStatePropertyAll(
                  theme.colorScheme.surface,
                ),
                surfaceTintColor: const WidgetStatePropertyAll(
                  Colors.transparent,
                ),
                elevation: const WidgetStatePropertyAll(2),
                shape: WidgetStatePropertyAll(
                  RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
              menuChildren: [
                for (final option in options)
                  MenuItemButton(
                    onPressed: () => onChanged(option),
                    style: ButtonStyle(
                      minimumSize: WidgetStatePropertyAll(
                        Size(width, rowHeight),
                      ),
                      padding: const WidgetStatePropertyAll(
                        EdgeInsets.symmetric(horizontal: 16),
                      ),
                      backgroundColor: value == option
                          ? WidgetStatePropertyAll(
                              theme.colorScheme.primary.withValues(alpha: .12),
                            )
                          : null,
                    ),
                    child: Text(label(option), style: choiceStyle),
                  ),
              ],
              builder: (context, controller, child) => TextButton(
                key: selectorKey,
                onPressed: !enabled
                    ? null
                    : () {
                        if (controller.isOpen) {
                          controller.close();
                        } else {
                          controller.open();
                        }
                      },
                style: TextButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  side: BorderSide(
                    color: theme.dividerColor.withValues(alpha: .2),
                  ),
                  minimumSize: Size(0, rowHeight),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  foregroundColor: theme.colorScheme.onSurface,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 15,
                    vertical: 12,
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(child: Text(label(value), style: choiceStyle)),
                    const SizedBox(width: 12),
                    const Icon(Icons.keyboard_arrow_down, size: 24),
                  ],
                ),
              ),
            ),
          );
          final descriptionWidget = Row(
            children: [
              Icon(
                icon,
                size: 28,
                color: theme.colorScheme.onSurface.withValues(alpha: .65),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      description,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                        height: 1.5,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: .65,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
          return Padding(
            padding: const EdgeInsets.all(20),
            child: bounds.maxWidth < 470
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      descriptionWidget,
                      const SizedBox(height: 16),
                      selector,
                    ],
                  )
                : Row(
                    children: [
                      Expanded(child: descriptionWidget),
                      const SizedBox(width: 20),
                      selector,
                    ],
                  ),
          );
        },
      ),
    );
  }
}
