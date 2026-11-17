import 'package:flutter/material.dart';
import '../../theme/konata_adaptive_tokens.dart';

/// 设置表单窄列自动改为纵向排列，保留宽列原有横向弹性分配。
class KonataSettingsRow extends StatelessWidget {
  const KonataSettingsRow({
    super.key,
    required this.children,
    this.crossAxisAlignment = CrossAxisAlignment.center,
    this.mainAxisAlignment = MainAxisAlignment.start,
    this.mainAxisSize = MainAxisSize.max,
  });
  final List<Widget> children;
  final CrossAxisAlignment crossAxisAlignment;
  final MainAxisAlignment mainAxisAlignment;
  final MainAxisSize mainAxisSize;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth >= KonataAdaptiveTokens.shortViewportHeight) {
        return Row(
          crossAxisAlignment: crossAxisAlignment,
          mainAxisAlignment: mainAxisAlignment,
          mainAxisSize: mainAxisSize,
          children: children,
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final child in children)
            if (child is! Spacer)
              if (child is Flexible)
                child.child
              else if (child is SizedBox &&
                  child.width != null &&
                  child.child == null)
                const SizedBox(height: KonataAdaptiveTokens.safeGap)
              else
                child,
        ],
      );
    },
  );
}
