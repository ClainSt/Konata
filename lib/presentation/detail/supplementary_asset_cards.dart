import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/formatting/media_display_formatter.dart';
import '../../domain/models/media_source.dart';
import '../../domain/models/media_variant.dart';
import '../../infrastructure/cache/scan_thumbnail_scheduler.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_playback_tokens.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/ellipsis_text_with_tooltip.dart';
import '../widgets/playback/konata_stage_morph_frame.dart';

export 'scan_lightbox_dialog.dart';

String _stripAssetExtension(String fileName) {
  final trimmed = fileName.trim();
  final dot = trimmed.lastIndexOf('.');
  return dot > 0 ? trimmed.substring(0, dot) : trimmed;
}

/// 详情页底部抽屉：音乐 CD 音轨卡片（点击遵循全局音频偏好，右键支持底栏/全屏/外部播放切换）。
class CdDrawerCard extends StatefulWidget {
  /// 创建 CD 音轨卡片。
  const CdDrawerCard({
    super.key,
    required this.variant,
    required this.showSeriesSharedBadge,
    required this.onTap,
    this.onPlayImmersive,
    this.onPlayExternal,
    this.directSubdirLabel,
    this.displayTitleOverride,
    this.showRawFileName = true,
    this.onDarkBackdrop = true,
    this.cardWidth = 244.0,
  });

  final MediaVariant variant;
  final bool showSeriesSharedBadge;
  final VoidCallback onTap;

  /// 右键在全屏流光倒影页中播放回调。
  final VoidCallback? onPlayImmersive;

  /// 右键使用外部播放器播放回调。
  final VoidCallback? onPlayExternal;

  /// 仅当位于「全部」筛选且多子目录共存时展示直接子目录短名，切入特定子筛选项时传 `null`。
  final String? directSubdirLabel;

  /// 可选外部覆写展示标题（缺省时展示原文件名）。
  final String? displayTitleOverride;

  /// 是否在卡片下方展示原始音频文件名。
  final bool showRawFileName;
  final bool onDarkBackdrop;

  /// 卡片展示宽度（默认 `244dp`，手机横/竖屏可按可用高度适配）。
  final double cardWidth;

  @override
  State<CdDrawerCard> createState() => _CdDrawerCardState();
}

class _CdDrawerCardState extends State<CdDrawerCard> {
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
                    color: _hovered
                        ? KonataPlaybackTokens.activeGlassBorder(p)
                        : KonataPlaybackTokens.glassBorder(p),
                    width: 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: KonataPlaybackTokens.shadowColor(p),
                      blurRadius: 14,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: KonataTheme.borderRadiusTile,
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                p.accent.withValues(
                                  alpha: p.isDark ? 0.28 : 0.16,
                                ),
                                p.elevatedSurface.withValues(
                                  alpha: p.isDark ? 0.90 : 0.85,
                                ),
                              ],
                            ),
                          ),
                          child: Center(
                            child: Icon(
                              Icons.album_rounded,
                              size: 42,
                              color: p.textPrimary.withValues(
                                alpha: _hovered ? 0.92 : 0.72,
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
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 7),
              EllipsisTextWithTooltip(
                text: displayTitle,
                maxLines: 1,
                style: KonataTheme.detailTextStyle(
                  palette: p,
                  color: (widget.onDarkBackdrop || p.isDark)
                      ? (_hovered
                            ? Colors.white
                            : KonataTheme.overlayWhiteTextStrong)
                      : p.textPrimary,
                  fontSize: KonataTheme.fontSizeBodyXs,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (widget.showRawFileName) ...[
                const SizedBox(height: 2),
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
                const SizedBox(height: 2),
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
}

/// 详情页底部抽屉：Scan 画集卡片（经由 [ScanThumbnailScheduler] 串口 LIFO 加载轻量化 `.webp` 缩略图）。
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
    this.cardWidth = 244.0,
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

  /// 可选外部覆写展示标题（缺省时展示原文件名）。
  final String? displayTitleOverride;
  final bool onDarkBackdrop;

  /// 卡片展示宽度（默认 `244dp`，手机横/竖屏可按可用高度适配）。
  final double cardWidth;

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
                    color: _hovered
                        ? KonataPlaybackTokens.activeGlassBorder(p)
                        : KonataPlaybackTokens.glassBorder(p),
                    width: 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: KonataPlaybackTokens.shadowColor(p),
                      blurRadius: 14,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: KonataTheme.borderRadiusTile,
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Container(
                          color: KonataTheme.scrimBlackModerate,
                          child: (thumbBytes != null && thumbBytes.isNotEmpty)
                              ? Image.memory(
                                  thumbBytes,
                                  fit: BoxFit.cover,
                                  gaplessPlayback: true,
                                  errorBuilder: (_, _, _) =>
                                      const _ScanPlaceholder(),
                                )
                              : const _ScanPlaceholder(),
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
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 7),
              EllipsisTextWithTooltip(
                text: displayTitle,
                maxLines: 2,
                style: KonataTheme.detailTextStyle(
                  palette: p,
                  color: (widget.onDarkBackdrop || p.isDark)
                      ? (_hovered
                            ? Colors.white
                            : KonataTheme.overlayWhiteTextStrong)
                      : p.textPrimary,
                  fontSize: KonataTheme.fontSizeBodyXs,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (subLine.isNotEmpty) ...[
                const SizedBox(height: 2),
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
          ),
        ),
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
        size: 34,
        color: p.textMuted.withValues(alpha: 0.82),
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
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
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
