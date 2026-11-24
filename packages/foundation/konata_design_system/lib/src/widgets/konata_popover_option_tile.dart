import 'package:material_ui/material_ui.dart';

import '../tokens/konata_adaptive_tokens.dart';
import '../tokens/konata_palette.dart';
import '../tokens/konata_playback_tokens.dart';
import '../tokens/konata_theme.dart';

/// 下拉列表与毛玻璃弹出菜单全站唯一选项行交互壳层。
///
/// 采用顶层 `MouseRegion` + `GestureDetector` + 即时 `Container`（零 `InkWell` 延迟残留与
/// `AnimatedContainer` 白透黑插值闪灰），配合宿主互斥索引保证任意帧至多单行高亮，
/// 并在浅/深主题毛玻璃浮层上均提供清晰柔和的悬停对比度。
class KonataPopoverOptionTile extends StatelessWidget {
  /// 创建统一浮层菜单选项行容器。
  const KonataPopoverOptionTile({
    super.key,
    required this.hovered,
    required this.onHoverEnter,
    required this.onHoverExit,
    required this.onTap,
    required this.child,
    this.selected = false,
    this.margin = const EdgeInsets.symmetric(vertical: 1.5),
    this.padding = const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    this.borderRadius = KonataTheme.borderRadiusThumb,
    this.minHeight,
  });

  /// 当前行是否处于悬停态（由宿主互斥索引控制）。
  final bool hovered;

  /// 当前行是否处于已选中态。
  final bool selected;

  /// 指针进入或悬停于当前行时回调。
  final VoidCallback onHoverEnter;

  /// 指针离开当前行时回调。
  final VoidCallback onHoverExit;

  /// 点击当前行回调。
  final VoidCallback onTap;

  /// 行内展示内容。
  final Widget child;

  /// 外边距（位于 `MouseRegion` 内，确保相邻行热区无缝衔接）。
  final EdgeInsetsGeometry margin;

  /// 内边距。
  final EdgeInsetsGeometry padding;

  /// 高亮底块圆角。
  final BorderRadius borderRadius;

  /// 可选最小行高覆盖（默认在 Android 自动遵循触控热区下限）。
  final double? minHeight;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final bgColor = selected
        ? p.accent.withValues(alpha: 0.16)
        : (hovered ? KonataPlaybackTokens.hoverFill(p) : Colors.transparent);
    final effectiveMinHeight =
        minHeight ??
        (KonataAdaptiveTokens.isAndroid
            ? KonataAdaptiveTokens.touchTarget
            : null);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => onHoverEnter(),
      onHover: (_) => onHoverEnter(),
      onExit: (_) => onHoverExit(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          constraints: effectiveMinHeight != null
              ? BoxConstraints(minHeight: effectiveMinHeight)
              : null,
          margin: margin,
          padding: padding,
          decoration: BoxDecoration(color: bgColor, borderRadius: borderRadius),
          child: child,
        ),
      ),
    );
  }
}
