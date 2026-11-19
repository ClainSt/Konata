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
    this.enableBackdropBlur = true,
  });

  /// 子内容。
  final Widget child;

  /// 可选圆角半径覆写（默认使用 `KonataAdaptiveTokens.capsuleRadius`）。
  final double? radius;

  /// 可选内部边距。
  final EdgeInsetsGeometry? padding;

  /// 是否启用底层高斯模糊采样（在硬件视频层前景可关闭以避免透明覆盖层帧缓冲重影）。
  final bool enableBackdropBlur;

  static final ImageFilter _capsuleBlurFilter = ImageFilter.blur(
    sigmaX: KonataPlaybackTokens.capsuleBlurSigma,
    sigmaY: KonataPlaybackTokens.capsuleBlurSigma,
  );

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final effectiveRadius = radius ?? KonataAdaptiveTokens.capsuleRadius;
    final borderRadius = BorderRadius.circular(effectiveRadius);
    final body = padding != null
        ? Padding(padding: padding!, child: child)
        : child;
    final decorated = DecoratedBox(
      decoration: BoxDecoration(
        color: enableBackdropBlur
            ? KonataPlaybackTokens.glassSurface(p)
            : (p.isDark ? const Color(0xCC161618) : p.surface),
        borderRadius: borderRadius,
        border: Border.all(
          color: KonataPlaybackTokens.glassBorder(p),
          width: KonataAdaptiveTokens.borderWidth,
        ),
      ),
      child: body,
    );
    return ClipRRect(
      borderRadius: borderRadius,
      child: enableBackdropBlur
          ? BackdropFilter(filter: _capsuleBlurFilter, child: decorated)
          : decorated,
    );
  }
}
