import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/playback/audio_playback_notifier.dart';
import '../../application/providers/artwork_provider.dart';
import '../../domain/formatting/media_display_formatter.dart';
import '../../domain/models/media_source.dart';
import '../../domain/models/media_variant.dart';
import '../../infrastructure/cache/scan_thumbnail_scheduler.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_playback_tokens.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/ellipsis_text_with_tooltip.dart';
import '../widgets/managed_image.dart';
import '../widgets/playback/konata_stage_morph_frame.dart';

export 'scan_lightbox_dialog.dart';

String _stripAssetExtension(String fileName) {
  final trimmed = fileName.trim();
  final dot = trimmed.lastIndexOf('.');
  return dot > 0 ? trimmed.substring(0, dot) : trimmed;
}

/// 详情页底部抽屉与完整列表共用的音乐 CD 专辑卡片（`1:1` 方正封面 + 光学唱片缺省态 + 正在播放流光高亮）。
///
/// 封面策略严格防风控：
/// - 优先命中内存专辑封面缓存，本地源按需读取目录/内嵌封面，绝不向 WebDAV/SMB 发起额外探测风暴；
/// - 无独立封面时采用柔焦压暗作品海报 + 极简通透几何唱片纹理，保持专辑货架韵律。
class CdDrawerCard extends ConsumerStatefulWidget {
  /// 创建 `1:1` 音乐 CD 卡片。
  const CdDrawerCard({
    super.key,
    required this.variant,
    required this.showSeriesSharedBadge,
    required this.onTap,
    this.source,
    this.workId,
    this.workPosterPath,
    this.imageLoader,
    this.onPlayImmersive,
    this.onPlayExternal,
    this.directSubdirLabel,
    this.displayTitleOverride,
    this.showRawFileName = true,
    this.onDarkBackdrop = true,
    this.cardWidth = 148.0,
  });

  final MediaVariant variant;
  final MediaSource? source;
  final String? workId;
  final String? workPosterPath;
  final ManagedImageLoader? imageLoader;
  final bool showSeriesSharedBadge;
  final VoidCallback onTap;

  /// 右键在全屏流光倒影页中播放回调。
  final VoidCallback? onPlayImmersive;

  /// 右键使用外部播放器播放回调。
  final VoidCallback? onPlayExternal;

  /// 仅当位于「全部」筛选且多子目录共存时展示直接子目录短名，切入特定子筛选项时传 `null`。
  final String? directSubdirLabel;

  /// 可选外部覆写展示标题（缺省时展示去扩展名后的曲目标题）。
  final String? displayTitleOverride;

  /// 是否在卡片下方展示原始音频文件名。
  final bool showRawFileName;
  final bool onDarkBackdrop;

  /// 卡片展示宽度（默认 `148dp`，`1:1` 正方形封面使高度与底部抽屉轨道严密契合）。
  final double cardWidth;

  @override
  ConsumerState<CdDrawerCard> createState() => _CdDrawerCardState();
}

class _CdDrawerCardState extends ConsumerState<CdDrawerCard> {
  bool _hovered = false;

  Future<void> _showCdMenu(Offset globalPos) async {
    final allowExternal =
        KonataAdaptiveTokens.isWindows && widget.onPlayExternal != null;
    if (widget.onPlayImmersive == null && !allowExternal) {
      return;
    }
    final itemHeight = KonataAdaptiveTokens.isAndroid
        ? KonataAdaptiveTokens.touchTarget
        : kMinInteractiveDimension;
    final pos = RelativeRect.fromLTRB(
      globalPos.dx,
      globalPos.dy,
      globalPos.dx,
      globalPos.dy,
    );
    final action = await showMenu<String>(
      context: context,
      position: pos,
      items: [
        PopupMenuItem<String>(
          value: 'default',
          height: itemHeight,
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.play_arrow_rounded, size: 17),
              SizedBox(width: 8),
              Text('播放（按当前默认设置）'),
            ],
          ),
        ),
        if (widget.onPlayImmersive != null)
          PopupMenuItem<String>(
            value: 'immersive',
            height: itemHeight,
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.album_rounded, size: 17),
                SizedBox(width: 8),
                Text('打开全屏流光沉浸页播放'),
              ],
            ),
          ),
        if (allowExternal)
          PopupMenuItem<String>(
            value: 'external',
            height: itemHeight,
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.open_in_new_rounded, size: 17),
                SizedBox(width: 8),
                Text('使用外部播放器播放'),
              ],
            ),
          ),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'default':
        captureStageMorphOriginRect(context);
        widget.onTap();
      case 'immersive':
        captureStageMorphOriginRect(context);
        widget.onPlayImmersive?.call();
      case 'external':
        widget.onPlayExternal?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final v = widget.variant;
    final ext = MediaDisplayFormatter.fileExtensionUpper(v.fileName);
    final dirHint = widget.directSubdirLabel?.trim() ?? '';
    final sizeText = MediaDisplayFormatter.formatBytes(v.fileSize);
    final subLine = [
      if (sizeText.isNotEmpty) sizeText,
      if (dirHint.isNotEmpty) dirHint,
    ].join(' · ');
    final displayTitle =
        (widget.displayTitleOverride != null &&
            widget.displayTitleOverride!.trim().isNotEmpty)
        ? widget.displayTitleOverride!.trim()
        : _stripAssetExtension(v.fileName);

    // 叶子精细订阅：仅在当前卡片曲目切入/切出活跃播放态时触发局部重绘
    final isActiveTrack = ref.watch(
      audioPlaybackProvider.select(
        (s) => s.isActive && s.currentItem?.variant.id == v.id,
      ),
    );
    final isPlayingTrack = ref.watch(
      audioPlaybackProvider.select(
        (s) => s.isActive && s.isPlaying && s.currentItem?.variant.id == v.id,
      ),
    );

    final src = widget.source;
    final coverBytes = src != null
        ? ref
              .watch(cdCardAlbumCoverProvider((source: src, variant: v)))
              .valueOrNull
        : null;

    final borderColor = (isActiveTrack || _hovered)
        ? KonataPlaybackTokens.activeGlassBorder(p)
        : KonataPlaybackTokens.glassBorder(p);

    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.15,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: () {
            captureStageMorphOriginRect(context);
            widget.onTap();
          },
          onSecondaryTapUp: (details) => _showCdMenu(details.globalPosition),
          onLongPressStart: (details) => _showCdMenu(details.globalPosition),
          child: SizedBox(
            width: widget.cardWidth,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AnimatedContainer(
                  duration: KonataTheme.motionFast,
                  curve: Curves.easeOutCubic,
                  decoration: BoxDecoration(
                    borderRadius: KonataTheme.borderRadiusCard,
                    border: Border.all(
                      color: borderColor,
                      width: isActiveTrack ? 1.4 : 1.0,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: isActiveTrack
                            ? p.accent.withValues(alpha: 0.24)
                            : KonataPlaybackTokens.shadowColor(p),
                        blurRadius: isActiveTrack ? 18 : 14,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: KonataTheme.borderRadiusTile,
                    child: AspectRatio(
                      aspectRatio: 1.0,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (coverBytes != null && coverBytes.isNotEmpty)
                            Image.memory(
                              coverBytes,
                              fit: BoxFit.cover,
                              gaplessPlayback: true,
                              errorBuilder: (_, _, _) =>
                                  _buildOpticalDiscFallback(p),
                            )
                          else
                            _buildOpticalDiscFallback(p),
                          if (!KonataAdaptiveTokens.isAndroid &&
                              (_hovered || isActiveTrack))
                            IgnorePointer(
                              child: AnimatedOpacity(
                                opacity: (_hovered || isActiveTrack)
                                    ? 1.0
                                    : 0.0,
                                duration: KonataTheme.motionFast,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: KonataTheme.scrimBlackLight,
                                  ),
                                ),
                              ),
                            ),
                          if (ext.isNotEmpty)
                            Positioned(
                              top: 6,
                              right: 6,
                              child: _MiniTag(label: ext),
                            ),
                          if (widget.showSeriesSharedBadge &&
                              v.assetScope ==
                                  SupplementaryAssetScope.seriesShared)
                            const Positioned(
                              top: 6,
                              left: 6,
                              child: _MiniTag(label: '系列共用'),
                            ),
                          if (isActiveTrack)
                            Positioned(
                              right: 6,
                              bottom: 6,
                              child: Container(
                                width: 26,
                                height: 26,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: KonataTheme.scrimBlackDense,
                                  border: Border.all(
                                    color: KonataTheme.overlayWhiteBorderStrong,
                                    width: 1,
                                  ),
                                ),
                                alignment: Alignment.center,
                                child: Icon(
                                  isPlayingTrack
                                      ? Icons.graphic_eq_rounded
                                      : Icons.pause_rounded,
                                  size: 14,
                                  color: KonataTheme.pureWhite,
                                ),
                              ),
                            )
                          else if (!KonataAdaptiveTokens.isAndroid && _hovered)
                            Center(
                              child: Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: KonataTheme.scrimBlackDense,
                                  border: Border.all(
                                    color: KonataTheme.overlayWhiteBorderStrong,
                                    width: 1,
                                  ),
                                ),
                                alignment: Alignment.center,
                                child: const Icon(
                                  Icons.play_arrow_rounded,
                                  size: 20,
                                  color: KonataTheme.pureWhite,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                EllipsisTextWithTooltip(
                  text: displayTitle,
                  maxLines: 1,
                  style: KonataTheme.detailTextStyle(
                    palette: p,
                    color: (widget.onDarkBackdrop || p.isDark)
                        ? (_hovered || isActiveTrack
                              ? KonataTheme.pureWhite
                              : KonataTheme.overlayWhiteTextStrong)
                        : p.textPrimary,
                    fontSize: KonataTheme.fontSizeBodyXs,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (widget.showRawFileName) ...[
                  const SizedBox(height: 1.5),
                  EllipsisTextWithTooltip(
                    text: MediaDisplayFormatter.formatWrappableFileName(
                      v.fileName,
                    ),
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
                if (subLine.isNotEmpty) ...[
                  const SizedBox(height: 1.5),
                  EllipsisTextWithTooltip(
                    text: subLine,
                    maxLines: 1,
                    style: KonataTheme.detailTextStyle(
                      palette: p,
                      color: (widget.onDarkBackdrop || p.isDark)
                          ? KonataTheme.overlayWhiteTextMuted
                          : p.textMuted,
                      fontSize: KonataTheme.fontSizeCaptionXs,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOpticalDiscFallback(KonataPalette p) {
    final poster = widget.workPosterPath?.trim() ?? '';
    final loader = widget.imageLoader;
    final hasPoster = poster.isNotEmpty && loader != null;

    return Stack(
      fit: StackFit.expand,
      children: [
        if (hasPoster) ...[
          ImageFiltered(
            imageFilter: KonataTheme.blurFilterSubtle,
            child: ManagedImage(
              poster,
              loader: loader,
              owner: widget.workId ?? widget.variant.workId,
              artwork: ManagedArtwork.poster,
              fit: BoxFit.cover,
            ),
          ),
          ColoredBox(color: KonataTheme.cinemaObsidian.withValues(alpha: 0.56)),
        ] else
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(-0.4, -0.4),
                radius: 1.25,
                colors: [
                  KonataPlaybackTokens.auroraDefaultGlowA.withValues(
                    alpha: p.isDark ? 0.50 : 0.24,
                  ),
                  KonataPlaybackTokens.auroraDefaultGlowC.withValues(
                    alpha: p.isDark ? 0.65 : 0.16,
                  ),
                  p.elevatedSurface.withValues(alpha: p.isDark ? 0.94 : 0.90),
                ],
              ),
            ),
          ),
        CustomPaint(
          painter: _OpticalVinylGeometryPainter(
            hovered: _hovered,
            ringColor: KonataTheme.pureWhite,
          ),
        ),
      ],
    );
  }
}

class _OpticalVinylGeometryPainter extends CustomPainter {
  const _OpticalVinylGeometryPainter({
    required this.hovered,
    required this.ringColor,
  });

  final bool hovered;
  final Color ringColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = math.min(size.width, size.height) * 0.36;

    final discFill = Paint()
      ..color = ringColor.withValues(alpha: hovered ? 0.12 : 0.08)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, maxR, discFill);

    final groovePaint = Paint()
      ..color = ringColor.withValues(alpha: hovered ? 0.34 : 0.22)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawCircle(center, maxR, groovePaint);

    final midGroove = Paint()
      ..color = ringColor.withValues(alpha: hovered ? 0.20 : 0.12)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;
    canvas.drawCircle(center, maxR * 0.72, midGroove);
    canvas.drawCircle(center, maxR * 0.44, midGroove);

    final hubPaint = Paint()
      ..color = ringColor.withValues(alpha: hovered ? 0.56 : 0.42)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    canvas.drawCircle(center, maxR * 0.20, hubPaint);
  }

  @override
  bool shouldRepaint(_OpticalVinylGeometryPainter oldDelegate) =>
      oldDelegate.hovered != hovered || oldDelegate.ringColor != ringColor;
}

/// 详情页底部抽屉与完整画廊共用的 Scan 扫图卡片：
/// - 经由 [ScanThumbnailScheduler] 按源分级调度加载轻量化 `.webp` 微缩图；
/// - 采用柔和光学画框 + `BoxFit.contain` 无裁切呈现，绝不截断竖版 Booklet 或宽幅跨页；
/// - 去除冗余扩展名角标，并支持画廊模式下的画面主角化极简浮层。
class ScanDrawerCard extends ConsumerStatefulWidget {
  /// 创建 Scan 画集卡片。
  const ScanDrawerCard({
    super.key,
    required this.variant,
    required this.source,
    required this.showSeriesSharedBadge,
    required this.onTap,
    this.workId,
    this.workTitle,
    this.directSubdirLabel,
    this.displayTitleOverride,
    this.onDarkBackdrop = true,
    this.cardWidth = 176.0,
    this.frameAspectRatio = 4 / 3,
    this.fillAvailableWidth = false,
    this.galleryOverlayCaption = false,
    this.pageIndex,
    this.onLongPressInfo,
  });

  final MediaVariant variant;
  final MediaSource? source;
  final bool showSeriesSharedBadge;
  final VoidCallback onTap;

  /// 所属作品 ID 与标题（缺省回退使用 `variant.workId`）。
  final String? workId;
  final String? workTitle;

  /// 仅当位于「全部」筛选且多子目录共存时展示精简直接子目录短名，切入特定分卷时传 `null`。
  final String? directSubdirLabel;

  /// 可选外部覆写展示标题（缺省时展示去扩展名后的文件名）。
  final String? displayTitleOverride;
  final bool onDarkBackdrop;

  /// 卡片展示宽度（横向轨道默认 `176dp`，网格/木桶流启用 [fillAvailableWidth] 时自适应列宽）。
  final double cardWidth;

  /// 光学画框宽高比（横向抽屉默认 `4/3`，完整画廊保序画框默认 `3/4`，木桶流可传入真实比例）。
  final double frameAspectRatio;

  /// 是否撑满父级约束宽度（用于网格与等高木桶流）。
  final bool fillAvailableWidth;

  /// 画廊「画面主角化」模式：默认弱化外部冗长文字，仅在左下呈现极简页码并于悬停时淡入短名。
  final bool galleryOverlayCaption;

  /// 可选页码序号（从 1 开始，供画廊极简角标展示）。
  final int? pageIndex;

  /// 长按或更多操作查看文件信息回调。
  final VoidCallback? onLongPressInfo;

  @override
  ConsumerState<ScanDrawerCard> createState() => _ScanDrawerCardState();
}

class _ScanDrawerCardState extends ConsumerState<ScanDrawerCard> {
  bool _hovered = false;
  Uint8List? _thumbBytes;
  ScanThumbnailTicket? _ticket;
  int _loadEpoch = 0;
  late final ScanThumbnailScheduler _scheduler;

  @override
  void initState() {
    super.initState();
    _scheduler = ref.read(scanThumbnailSchedulerProvider);
    _scheduleThumbnail();
  }

  @override
  void didUpdateWidget(covariant ScanDrawerCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.variant.id != widget.variant.id ||
        oldWidget.source?.id != widget.source?.id ||
        oldWidget.workId != widget.workId) {
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
    final scheduled = _scheduler.schedule(
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
    final sizeText = MediaDisplayFormatter.formatBytes(v.fileSize);
    final subLine = [
      if (sizeText.isNotEmpty) sizeText,
      if (dirHint.isNotEmpty) dirHint,
    ].join(' · ');
    final displayTitle =
        (widget.displayTitleOverride != null &&
            widget.displayTitleOverride!.trim().isNotEmpty)
        ? widget.displayTitleOverride!.trim()
        : _stripAssetExtension(v.fileName);

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
                                style: TextStyle(
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
        ? Tooltip(message: v.relativePath, child: frame)
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
          onTap: () {
            captureStageMorphOriginRect(context);
            widget.onTap();
          },
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
