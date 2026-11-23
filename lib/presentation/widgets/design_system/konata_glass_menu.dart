import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../shell/adaptive_capsule_layout.dart';
import '../../theme/konata_adaptive_tokens.dart';
import '../../theme/konata_palette.dart';
import '../../theme/konata_playback_tokens.dart';
import '../../theme/konata_theme.dart';
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
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.94, end: 1.0).animate(curved),
            child: child,
          ),
        );
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
    final safe = media.padding;
    final itemHeight = KonataAdaptiveTokens.isAndroid
        ? KonataAdaptiveTokens.touchTarget
        : kMinInteractiveDimension;
    final estimatedHeight = widget.items.length * itemHeight + 12.0;
    final menuWidth = math.min(
      math.max(widget.minWidth, widget.anchorRect.width),
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

    final spaceBelow =
        viewport.height - safe.bottom - widget.anchorRect.bottom - 12.0;
    final openDown =
        spaceBelow >= estimatedHeight || widget.anchorRect.top < estimatedHeight;
    final minTop = safe.top + 12.0;
    final maxTop = math.max(
      minTop,
      viewport.height - safe.bottom - estimatedHeight - 12.0,
    );
    final rawTop = openDown
        ? widget.anchorRect.bottom + 6.0
        : widget.anchorRect.top - estimatedHeight - 6.0;
    final top = rawTop.clamp(minTop, maxTop);

    final radius = BorderRadius.circular(KonataPlaybackTokens.floatingMiniRadius);

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
