import 'dart:async';
import 'dart:typed_data';

import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/scan_display_formatter.dart';
import '../data/scan_thumbnail_scheduler.dart';

/// 扫图画廊单张微缩图卡片：
/// - 通过 [ScanThumbnailScheduler] 按源分级调度加载轻量化 `.webp` 微缩图；
/// - 卡片划出视口或销毁时自动调用 `ticket.cancel()` 抢占取消在途传输；
/// - 采用 `BoxFit.contain` 无裁切画框呈现，并支持左下极简页码与悬停短名浮层。
class ScanThumbnailCard extends StatefulWidget {
  /// 创建扫图微缩图卡片。
  const ScanThumbnailCard({
    super.key,
    required this.variant,
    required this.source,
    required this.scheduler,
    required this.showSeriesSharedBadge,
    required this.onTap,
    this.workId,
    this.workTitle,
    this.directSubdirLabel,
    this.displayTitleOverride,
    this.onDarkBackdrop = false,
    this.cardWidth = 176.0,
    this.frameAspectRatio = 3 / 4,
    this.fillAvailableWidth = true,
    this.galleryOverlayCaption = true,
    this.pageIndex,
    this.onLongPressInfo,
  });

  /// 扫图物理变体记录。
  final MediaVariant variant;

  /// 所属媒体源只读视图。
  final MediaSourceView? source;

  /// 三级并发微缩图调度器。
  final ScanThumbnailScheduler scheduler;

  /// 是否显示「系列共用」角标。
  final bool showSeriesSharedBadge;

  /// 点击卡片打开灯箱回调。
  final VoidCallback onTap;

  /// 所属作品标识（缺省回退使用 `variant.workId`）。
  final String? workId;

  /// 所属作品标题（用于构建人类可读的 `photos/<作品>/scans/` 目录）。
  final String? workTitle;

  /// 位于「全部」筛选且存在多目录分层时展示的直接子目录短名。
  final String? directSubdirLabel;

  /// 可选外部覆写标题。
  final String? displayTitleOverride;

  /// 是否运行在深色抽屉背景上。
  final bool onDarkBackdrop;

  /// 未撑满父约束时的固定卡片宽度。
  final double cardWidth;

  /// 画框宽高比。
  final double frameAspectRatio;

  /// 是否横向撑满父级列宽。
  final bool fillAvailableWidth;

  /// 是否采用画面主角化叠加标题与页码浮层。
  final bool galleryOverlayCaption;

  /// 可选顺序页码（从 1 开始）。
  final int? pageIndex;

  /// 长按查看文件详情提示回调。
  final VoidCallback? onLongPressInfo;

  @override
  State<ScanThumbnailCard> createState() => _ScanThumbnailCardState();
}

class _ScanThumbnailCardState extends State<ScanThumbnailCard> {
  bool _hovered = false;
  Uint8List? _thumbBytes;
  ScanThumbnailTicket? _ticket;
  int _loadEpoch = 0;

  @override
  void initState() {
    super.initState();
    _scheduleThumbnail();
  }

  @override
  void didUpdateWidget(covariant ScanThumbnailCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.variant.id != widget.variant.id ||
        oldWidget.source?.id != widget.source?.id ||
        oldWidget.workId != widget.workId ||
        !identical(oldWidget.scheduler, widget.scheduler)) {
      _cancelActiveTicket();
      _thumbBytes = null;
      _scheduleThumbnail();
    }
  }

  @override
  void dispose() {
    _cancelActiveTicket();
    _thumbBytes = null;
    super.dispose();
  }

  void _cancelActiveTicket() {
    _loadEpoch++;
    _ticket?.cancel();
    _ticket = null;
  }

  void _scheduleThumbnail() {
    final source = widget.source;
    if (source == null) {
      _thumbBytes = null;
      return;
    }
    final epoch = ++_loadEpoch;
    final scheduled = widget.scheduler.schedule(
      workId: widget.workId ?? widget.variant.workId,
      workTitle: widget.workTitle,
      variant: widget.variant,
      source: source,
    );
    _ticket = scheduled.ticket;
    unawaited(
      scheduled.future.then(
        (bytes) {
          if (!mounted || epoch != _loadEpoch) return;
          setState(() {
            _thumbBytes = bytes.isEmpty ? null : bytes;
          });
        },
        onError: (_) {
          if (!mounted || epoch != _loadEpoch) return;
          setState(() {
            _thumbBytes = null;
          });
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final v = widget.variant;
    final thumbBytes = _thumbBytes;
    final dirHint = widget.directSubdirLabel?.trim() ?? '';
    final sizeText = ScanDisplayFormatter.formatBytes(v.fileSize);
    final subLine = [
      if (sizeText.isNotEmpty) sizeText,
      if (dirHint.isNotEmpty) dirHint,
    ].join(' · ');
    final displayTitle =
        (widget.displayTitleOverride != null &&
            widget.displayTitleOverride!.trim().isNotEmpty)
        ? widget.displayTitleOverride!.trim()
        : ScanDisplayFormatter.stripExtension(v.fileName);

    final matColor = (widget.onDarkBackdrop || p.isDark)
        ? KonataTheme.cinemaObsidian.withValues(alpha: 0.62)
        : p.softFill;

    final frame = AnimatedContainer(
      duration: KonataTheme.motionFast,
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        borderRadius: KonataTheme.borderRadiusCard,
        border: Border.all(
          color: _hovered
              ? KonataPlaybackTokens.activeGlassBorder(p)
              : KonataPlaybackTokens.glassBorder(p),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: KonataPlaybackTokens.shadowColor(p),
            blurRadius: 12,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: KonataTheme.borderRadiusTile,
        child: AspectRatio(
          aspectRatio: widget.frameAspectRatio,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(
                color: matColor,
                child: Padding(
                  padding: EdgeInsets.all(widget.galleryOverlayCaption ? 3 : 4),
                  child: (thumbBytes != null && thumbBytes.isNotEmpty)
                      ? Image.memory(
                          thumbBytes,
                          fit: BoxFit.contain,
                          filterQuality: FilterQuality.medium,
                          gaplessPlayback: true,
                          errorBuilder: (_, _, _) => const _ScanPlaceholder(),
                        )
                      : const _ScanPlaceholder(),
                ),
              ),
              if (widget.showSeriesSharedBadge &&
                  v.assetScope == SupplementaryAssetScope.seriesShared)
                const Positioned(
                  top: 6,
                  left: 6,
                  child: _MiniTag(label: '系列共用'),
                ),
              if (widget.galleryOverlayCaption) ...[
                if (widget.pageIndex != null)
                  Positioned(
                    left: 6,
                    bottom: 6,
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: _hovered ? 0.0 : 0.92,
                        duration: KonataTheme.motionFast,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: KonataTheme.scrimBlackDense,
                            borderRadius: KonataTheme.borderRadiusChipSm,
                            border: Border.all(
                              color: KonataTheme.overlayWhiteBorder,
                              width: 0.7,
                            ),
                          ),
                          child: Text(
                            '#${widget.pageIndex.toString().padLeft(2, '0')}',
                            style: const TextStyle(
                              color: KonataTheme.pureWhite,
                              fontSize: KonataTheme.fontSizeMicro,
                              fontWeight: FontWeight.w600,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: AnimatedOpacity(
                      opacity: _hovered ? 1.0 : 0.0,
                      duration: KonataTheme.motionFast,
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(8, 16, 8, 6),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              KonataTheme.cinemaObsidian.withValues(
                                alpha: 0.88,
                              ),
                            ],
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              displayTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: KonataTheme.pureWhite,
                                fontSize: KonataTheme.fontSizeCaptionSm,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (subLine.isNotEmpty)
                              Text(
                                subLine,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: KonataTheme.overlayWhiteTextSub,
                                  fontSize: KonataTheme.fontSizeMicro,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );

    final Widget content = widget.galleryOverlayCaption
        ? KonataTooltip(message: v.relativePath, child: frame)
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              frame,
              const SizedBox(height: 6),
              EllipsisTextWithTooltip(
                text: displayTitle,
                maxLines: 2,
                style: KonataTheme.detailTextStyle(
                  palette: p,
                  color: (widget.onDarkBackdrop || p.isDark)
                      ? (_hovered
                            ? KonataTheme.pureWhite
                            : KonataTheme.overlayWhiteTextStrong)
                      : p.textPrimary,
                  fontSize: KonataTheme.fontSizeBodyXs,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (subLine.isNotEmpty) ...[
                const SizedBox(height: 1.5),
                EllipsisTextWithTooltip(
                  text: subLine,
                  maxLines: 1,
                  style: KonataTheme.detailTextStyle(
                    palette: p,
                    color: (widget.onDarkBackdrop || p.isDark)
                        ? KonataTheme.overlayWhiteTextSub
                        : p.textSecondary,
                    fontSize: KonataTheme.fontSizeCaptionXs,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ],
          );

    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.15,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onLongPress: widget.onLongPressInfo,
          child: widget.fillAvailableWidth
              ? content
              : SizedBox(width: widget.cardWidth, child: content),
        ),
      ),
    );
  }
}

class _ScanPlaceholder extends StatelessWidget {
  const _ScanPlaceholder();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Center(
      child: Icon(
        Icons.collections_outlined,
        size: 30,
        color: p.textMuted.withValues(alpha: 0.72),
      ),
    );
  }
}

class _MiniTag extends StatelessWidget {
  const _MiniTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6.5, vertical: 2),
      decoration: BoxDecoration(
        color: KonataPlaybackTokens.glassSurface(p),
        border: Border.all(
          color: KonataPlaybackTokens.glassBorder(p),
          width: 0.8,
        ),
        borderRadius: KonataTheme.borderRadiusChip,
      ),
      child: Text(
        label,
        style: TextStyle(
          color: p.textPrimary,
          fontSize: KonataTheme.fontSizeBadge,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
