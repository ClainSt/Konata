import 'dart:ui';

import 'package:flutter/material.dart';

import '../../theme/konata_adaptive_tokens.dart';
import '../../theme/konata_palette.dart';
import '../../theme/konata_playback_tokens.dart';

/// 跨端共用的圆角毛玻璃表面，保持桌面播控的材质与描边。
class KonataGlassCapsule extends StatelessWidget {
  /// 创建圆角毛玻璃胶囊表面。
  const KonataGlassCapsule({
    super.key,
    required this.child,
    this.radius,
    this.padding,
  });

  /// 子内容。
  final Widget child;

  /// 可选圆角半径覆写（默认使用 `KonataAdaptiveTokens.capsuleRadius`）。
  final double? radius;

  /// 可选内部边距。
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final effectiveRadius = radius ?? KonataAdaptiveTokens.capsuleRadius;
    final body = padding != null
        ? Padding(padding: padding!, child: child)
        : child;
    return ClipRRect(
      borderRadius: BorderRadius.circular(effectiveRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: KonataPlaybackTokens.capsuleBlurSigma,
          sigmaY: KonataPlaybackTokens.capsuleBlurSigma,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: KonataPlaybackTokens.glassSurface(context.palette),
            borderRadius: BorderRadius.circular(effectiveRadius),
            border: Border.all(
              color: KonataPlaybackTokens.glassBorder(context.palette),
              width: KonataAdaptiveTokens.borderWidth,
            ),
          ),
          child: body,
        ),
      ),
    );
  }
}
