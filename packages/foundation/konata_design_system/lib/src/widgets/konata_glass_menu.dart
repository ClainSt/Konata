import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../shell/konata_modal_layer_registry.dart';
import '../tokens/konata_adaptive_tokens.dart';
import '../tokens/konata_palette.dart';
import '../tokens/konata_playback_tokens.dart';
import '../tokens/konata_theme.dart';
import 'konata_popover_option_tile.dart';

/// 全站统一毛玻璃弹出菜单项描述。
@immutable
class KonataGlassMenuItem<T> {
  /// 创建毛玻璃菜单项。
  const KonataGlassMenuItem({
    this.key,
    required this.value,
    required this.label,
    this.icon,
    this.isDanger = false,
  });

  /// 可选测试与组件定位键。
  final Key? key;

  /// 选中后返回的值。
  final T value;

  /// 菜单项简体中文文案。
  final String label;

  /// 可选前置图标。
  final IconData? icon;

  /// 是否以危险告警语义高亮显示。
  final bool isDanger;
}

/// 在指定锚点附近弹出全站唯一毛玻璃菜单（内置安全区防溢出定位与模态层级隔离，严禁使用实心原生 `showMenu`）。
Future<T?> showKonataGlassMenu<T>({
  required BuildContext anchorContext,
  required List<KonataGlassMenuItem<T>> items,
  double minWidth = 176.0,
}) async {
  if (items.isEmpty) return null;
  final renderBox = anchorContext.findRenderObject();
  final overlayBox = Overlay.maybeOf(
    anchorContext,
    rootOverlay: true,
  )?.context.findRenderObject();
  if (renderBox is! RenderBox ||
      !renderBox.hasSize ||
      overlayBox is! RenderBox ||
      !overlayBox.hasSize) {
    return null;
  }
  final topLeft = renderBox.localToGlobal(Offset.zero, ancestor: overlayBox);
  final anchorRect = topLeft & renderBox.size;

  return Navigator.of(anchorContext, rootNavigator: true).push<T>(
    RawDialogRoute<T>(
      barrierDismissible: true,
      barrierColor: Colors.transparent,
      transitionDuration: KonataTheme.standardTransition,
      pageBuilder: (routeCtx, _, _) => KonataModalRouteScope(
        child: _KonataGlassMenuOverlay<T>(
          anchorRect: anchorRect,
          items: items,
          minWidth: minWidth,
        ),
      ),
      transitionBuilder: (ctx, animation, _, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );
        return FadeTransition(opacity: curved, child: child);
      },
    ),
  );
}

class _KonataGlassMenuOverlay<T> extends StatefulWidget {
  const _KonataGlassMenuOverlay({
    required this.anchorRect,
    required this.items,
    required this.minWidth,
  });

  final Rect anchorRect;
  final List<KonataGlassMenuItem<T>> items;
  final double minWidth;

  @override
  State<_KonataGlassMenuOverlay<T>> createState() =>
      _KonataGlassMenuOverlayState<T>();
}

class _KonataGlassMenuOverlayState<T>
    extends State<_KonataGlassMenuOverlay<T>> {
  int? _hoveredIndex;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final media = MediaQuery.of(context);
    final viewport = media.size;
    final safe = media.viewPadding;
    final itemHeight = KonataAdaptiveTokens.isAndroid
        ? KonataAdaptiveTokens.touchTarget
        : 36.0;
    final estimatedHeight = widget.items.length * itemHeight + 12.0;
    final labelStyle = KonataTheme.bodyLabelStyle(
      p,
      fontSize: KonataTheme.fontSizeBodySm,
    );
    double contentWidth = 0;
    for (final item in widget.items) {
      final painter = TextPainter(
        text: TextSpan(text: item.label, style: labelStyle),
        textDirection: Directionality.of(context),
        textScaler: media.textScaler,
        maxLines: 1,
      )..layout();
      contentWidth = math.max(
        contentWidth,
        painter.width + 32 + (item.icon == null ? 0 : 26),
      );
      painter.dispose();
    }
    final menuWidth = math.min(
      math.max(
        math.max(widget.minWidth, widget.anchorRect.width),
        contentWidth.ceilToDouble(),
      ),
      math.max(160.0, viewport.width - safe.horizontal - 24.0),
    );

    final minLeft = safe.left + 12.0;
    final maxLeft = math.max(
      minLeft,
      viewport.width - safe.right - menuWidth - 12.0,
    );
    final preferredLeft = (widget.anchorRect.right - menuWidth).clamp(
      minLeft,
      maxLeft,
    );

    // 优先在锚点上下完整容纳菜单；空间不足时只缩短滚动视口。
    const gap = 8.0;
    final minTop = safe.top + 12.0;
    final maxBottom = viewport.height - safe.bottom - 12.0;
    final spaceAbove = math.max(0.0, widget.anchorRect.top - gap - minTop);
    final spaceBelow = math.max(
      0.0,
      maxBottom - widget.anchorRect.bottom - gap,
    );
    final openDown =
        spaceBelow >= estimatedHeight ||
        (spaceAbove < estimatedHeight && spaceBelow >= spaceAbove);
    final menuHeight = math.min(
      estimatedHeight,
      openDown ? spaceBelow : spaceAbove,
    );
    final top = openDown
        ? widget.anchorRect.bottom + gap
        : widget.anchorRect.top - gap - menuHeight;

    final radius = BorderRadius.circular(
      KonataPlaybackTokens.floatingMiniRadius,
    );

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => Navigator.of(context).pop(),
          ),
        ),
        Positioned(
          left: preferredLeft,
          top: top,
          width: menuWidth,
          height: menuHeight,
          child: Material(
            color: Colors.transparent,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: radius,
                boxShadow: [
                  BoxShadow(
                    color: KonataPlaybackTokens.shadowColor(p),
                    blurRadius: KonataPlaybackTokens.floatingMiniShadowBlur,
                    offset: KonataPlaybackTokens.floatingMiniShadowOffset,
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: radius,
                child: BackdropFilter(
                  filter: KonataTheme.blurFilterCapsule,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: KonataPlaybackTokens.popoverSurface(p),
                      borderRadius: radius,
                      border: Border.all(
                        color: KonataPlaybackTokens.glassBorder(p),
                      ),
                    ),
                    child: MouseRegion(
                      onExit: (_) {
                        if (_hoveredIndex != null) {
                          setState(() => _hoveredIndex = null);
                        }
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 6,
                          horizontal: 6,
                        ),
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (var i = 0; i < widget.items.length; i++)
                                _KonataGlassMenuTile<T>(
                                  item: widget.items[i],
                                  height: itemHeight,
                                  hovered: _hoveredIndex == i,
                                  onHoverEnter: () {
                                    if (_hoveredIndex != i) {
                                      setState(() => _hoveredIndex = i);
                                    }
                                  },
                                  onHoverExit: () {
                                    if (_hoveredIndex == i) {
                                      setState(() => _hoveredIndex = null);
                                    }
                                  },
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _KonataGlassMenuTile<T> extends StatelessWidget {
  const _KonataGlassMenuTile({
    required this.item,
    required this.height,
    required this.hovered,
    required this.onHoverEnter,
    required this.onHoverExit,
  });

  final KonataGlassMenuItem<T> item;
  final double height;
  final bool hovered;
  final VoidCallback onHoverEnter;
  final VoidCallback onHoverExit;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final fg = item.isDanger ? p.danger : p.textPrimary;

    return KonataPopoverOptionTile(
      key: item.key,
      hovered: hovered,
      onHoverEnter: onHoverEnter,
      onHoverExit: onHoverExit,
      onTap: () => Navigator.of(context).pop(item.value),
      borderRadius: KonataTheme.borderRadiusControl,
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      minHeight: height,
      child: Row(
        children: [
          if (item.icon != null) ...[
            Icon(item.icon, size: 18, color: fg),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(
              item.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: KonataTheme.bodyLabelStyle(
                p,
                fontSize: KonataTheme.fontSizeBodySm,
                color: fg,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
