import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

import '../tokens/konata_adaptive_tokens.dart';
import '../tokens/konata_palette.dart';
import '../tokens/konata_playback_tokens.dart';
import '../tokens/konata_theme.dart';
import 'ellipsis_text_with_tooltip.dart';
import 'konata_adaptive_blur.dart';

/// 横向二级筛选条，共享胶囊视觉、数量文案、触控热区和滚轮滚动行为。
class KonataSecondaryFilterBar<T> extends StatefulWidget {
  const KonataSecondaryFilterBar({
    super.key,
    required this.items,
    required this.selected,
    required this.onSelected,
    this.onDarkBackdrop = false,
    this.compact = false,
  });

  final List<({T value, String label})> items;
  final T selected;
  final ValueChanged<T> onSelected;
  final bool onDarkBackdrop;
  final bool compact;

  @override
  State<KonataSecondaryFilterBar<T>> createState() =>
      _KonataSecondaryFilterBarState<T>();
}

class _KonataSecondaryFilterBarState<T>
    extends State<KonataSecondaryFilterBar<T>> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();
    final touch = KonataAdaptiveTokens.isAndroid;
    final compact =
        widget.compact ||
        (touch &&
            MediaQuery.sizeOf(context).shortestSide <
                KonataAdaptiveTokens.tabletBreakpoint);
    final palette = widget.onDarkBackdrop
        ? KonataPalette.dark
        : context.palette;
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.15,
      child: SizedBox(
        height: touch ? KonataAdaptiveTokens.touchTarget : (compact ? 30 : 32),
        child: Listener(
          onPointerSignal: (event) {
            if (event is! PointerScrollEvent || !_scrollController.hasClients) {
              return;
            }
            final position = _scrollController.position;
            final delta = event.scrollDelta.dy != 0
                ? event.scrollDelta.dy
                : event.scrollDelta.dx;
            GestureBinding.instance.pointerSignalResolver.register(event, (_) {
              if (!_scrollController.hasClients) return;
              final target = (position.pixels + delta).clamp(
                position.minScrollExtent,
                position.maxScrollExtent,
              );
              _scrollController.jumpTo(target);
            });
          },
          child: SingleChildScrollView(
            controller: _scrollController,
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < widget.items.length; i++) ...[
                  if (i > 0) SizedBox(width: compact ? 6 : 8),
                  _FilterPill(
                    label: widget.items[i].label,
                    selected: widget.selected == widget.items[i].value,
                    compact: compact,
                    touch: touch,
                    palette: palette,
                    onTap: () => widget.onSelected(widget.items[i].value),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FilterPill extends StatefulWidget {
  const _FilterPill({
    required this.label,
    required this.selected,
    required this.compact,
    required this.touch,
    required this.palette,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool compact;
  final bool touch;
  final KonataPalette palette;
  final VoidCallback onTap;

  @override
  State<_FilterPill> createState() => _FilterPillState();
}

class _FilterPillState extends State<_FilterPill> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final pill = ClipRRect(
      borderRadius: KonataTheme.borderRadiusPill,
      child: KonataAdaptiveBackdropBlur(
        filter: KonataTheme.blurFilterMedium,
        child: AnimatedContainer(
          duration: KonataTheme.motionStandard,
          curve: Curves.easeOutCubic,
          constraints: BoxConstraints(
            minWidth: widget.touch ? KonataAdaptiveTokens.touchTarget : 0,
            maxWidth: widget.compact ? 210 : 280,
          ),
          padding: EdgeInsets.symmetric(
            horizontal: widget.compact ? 11 : 13,
            vertical: widget.compact ? 5.5 : 6,
          ),
          decoration: BoxDecoration(
            color: KonataPlaybackTokens.secondaryFilterPillBg(
              p,
              selected: widget.selected,
              hovered: _hovered,
            ),
            borderRadius: KonataTheme.borderRadiusPill,
            border: Border.all(
              color: KonataPlaybackTokens.secondaryFilterPillBorder(
                p,
                selected: widget.selected,
              ),
              width: widget.selected ? 1 : 0.85,
            ),
          ),
          child: EllipsisTextWithTooltip(
            text: widget.label,
            maxLines: 1,
            style: KonataTheme.detailTextStyle(
              palette: p,
              color: KonataPlaybackTokens.secondaryFilterPillText(
                p,
                selected: widget.selected,
                hovered: _hovered,
              ),
              fontSize: widget.compact
                  ? KonataTheme.fontSizeCaptionSm
                  : KonataTheme.fontSizeCaption,
              fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
    return Semantics(
      button: true,
      selected: widget.selected,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: widget.touch
              ? ConstrainedBox(
                  constraints: const BoxConstraints(
                    minWidth: KonataAdaptiveTokens.touchTarget,
                    minHeight: KonataAdaptiveTokens.touchTarget,
                  ),
                  child: Center(widthFactor: 1, heightFactor: 1, child: pill),
                )
              : pill,
        ),
      ),
    );
  }
}
