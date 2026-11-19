import 'package:flutter/material.dart';

import '../../theme/konata_adaptive_tokens.dart';
import '../../theme/konata_palette.dart';
import '../../theme/konata_playback_tokens.dart';
import '../../theme/konata_theme.dart';

/// 跨端共用的圆角毛玻璃表面，保持桌面播控的材质与描边。
class KonataGlassCapsule extends StatelessWidget {
  /// 创建圆角毛玻璃胶囊表面。
  const KonataGlassCapsule({
    super.key,
    required this.child,
    this.radius,
    this.padding,
    this.enableBackdropBlur = true,
    this.solidBackdropColor,
  });

  /// 子内容。
  final Widget child;

  /// 可选圆角半径覆写（默认使用 `KonataAdaptiveTokens.capsuleRadius`）。
  final double? radius;

  /// 可选内部边距。
  final EdgeInsetsGeometry? padding;

  /// 是否启用底层高斯模糊采样（在硬件视频层前景或纯色底画布避让区可关闭以省去离屏全幅拷贝）。
  final bool enableBackdropBlur;

  /// 当底层为纯单色画布且关闭 `BackdropFilter` 时，以 `Color.alphaBlend` 预混出像素级等价毛玻璃底色。
  final Color? solidBackdropColor;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final effectiveRadius = radius ?? KonataAdaptiveTokens.capsuleRadius;
    final borderRadius = BorderRadius.circular(effectiveRadius);
    final body = padding != null
        ? Padding(padding: padding!, child: child)
        : child;
    final surfaceColor = enableBackdropBlur
        ? KonataPlaybackTokens.glassSurface(p)
        : (solidBackdropColor != null
              ? Color.alphaBlend(
                  KonataPlaybackTokens.glassSurface(p),
                  solidBackdropColor!,
                )
              : KonataTheme.capsuleDarkSurface(p));
    final decorated = DecoratedBox(
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: borderRadius,
        border: Border.all(
          color: KonataPlaybackTokens.glassBorder(p),
          width: KonataAdaptiveTokens.borderWidth,
        ),
      ),
      child: body,
    );
    if (!enableBackdropBlur) {
      return ClipRRect(borderRadius: borderRadius, child: decorated);
    }
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: KonataTheme.blurFilterCapsule,
        child: decorated,
      ),
    );
  }
}
