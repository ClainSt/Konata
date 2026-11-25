import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:engine_playback/engine_playback.dart';
import 'package:engine_scraping/engine_scraping.dart';
import 'package:engine_sources/engine_sources.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';
import 'package:path/path.dart' as p;

import '../data/media_display_formatter.dart';
import 'detail_artwork_view.dart';

String _stripAssetExtension(String fileName) {
  final trimmed = fileName.trim();
  final dot = trimmed.lastIndexOf('.');
  return dot > 0 ? trimmed.substring(0, dot) : trimmed;
}

/// 详情页底部抽屉与完整列表共用的音乐 CD 专辑卡片（`1:1` 方正封面 + 光学唱片缺省态）。
///
/// 严格防风控策略：仅对本地磁盘媒体源按需读取同目录/内嵌封面字节，绝不向远程 `WebDAV`/`SMB` 发起额外探测风暴；
/// 无独立封面时采用柔焦压暗作品海报与极简几何唱片缺省态保持货架韵律。
class CdDrawerCard extends StatefulWidget {
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
    this.directSubdirLabel,
    this.displayTitleOverride,
    this.showRawFileName = true,
    this.onDarkBackdrop = true,
    this.cardWidth = 148.0,
  });

  /// 目标 CD 物理音轨或清单变体。
  final MediaVariant variant;

  /// 所属媒体源（用于判断是否为安全本地磁盘探测）。
  final MediaSource? source;

  /// 所属作品主键。
  final String? workId;

  /// 所属作品竖版封面路径。
  final String? workPosterPath;

  /// 受管图片加载器。
  final ManagedImageLoader? imageLoader;

  /// 是否展示「系列共用」角标。
  final bool showSeriesSharedBadge;

  /// 点击起播全屏流光音频舞台回调。
  final VoidCallback onTap;

  /// 多子目录共存时展示的直接子目录短名。
  final String? directSubdirLabel;

  /// 可选标题覆写文案。
  final String? displayTitleOverride;

  /// 是否在下方展示原始文件名。
  final bool showRawFileName;

  /// 是否处于暗色背景舞台。
  final bool onDarkBackdrop;

  /// 卡片逻辑宽度。
  final double cardWidth;

  @override
  State<CdDrawerCard> createState() => _CdDrawerCardState();
}

class _CdDrawerCardState extends State<CdDrawerCard> {
  static final Map<String, Uint8List> _localCoverCache = <String, Uint8List>{};

  bool _hovered = false;
  Uint8List? _coverBytes;
  int _loadEpoch = 0;

  @override
  void initState() {
    super.initState();
    _loadLocalCoverIfSafe();
  }

  @override
  void didUpdateWidget(covariant CdDrawerCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.variant.id != widget.variant.id ||
        oldWidget.source?.id != widget.source?.id) {
      _coverBytes = null;
      _loadLocalCoverIfSafe();
    }
  }

  void _loadLocalCoverIfSafe() {
    final src = widget.source;
    if (src == null || src.kind != MediaSourceKind.local) return;
    final key = '${src.id}::${widget.variant.relativePath}';
    final cached = _localCoverCache[key];
    if (cached != null) {
      _coverBytes = cached.isEmpty ? null : cached;
      return;
    }
    final epoch = ++_loadEpoch;
    unawaited(
      _probeLocalAudioCover(src, widget.variant).then((bytes) {
        if (_localCoverCache.length > 96) {
          _localCoverCache.remove(_localCoverCache.keys.first);
        }
        _localCoverCache[key] = bytes ?? Uint8List(0);
        if (!mounted || epoch != _loadEpoch) return;
        if (bytes != null && bytes.isNotEmpty) {
          setState(() => _coverBytes = bytes);
        }
      }),
    );
  }

  static Future<Uint8List?> _probeLocalAudioCover(
    MediaSource source,
    MediaVariant variant,
  ) async {
    try {
      final absPath = LocalSourceGateway(
        rootPath: source.location,
      ).resolveAbsolutePath(variant.relativePath);
      final audioFile = File(absPath);
      if (!audioFile.existsSync()) return null;

      final dir = audioFile.parent;
      const coverNames = <String>[
        'cover.jpg',
        'cover.png',
        'cover.webp',
        'folder.jpg',
        'folder.png',
        'front.jpg',
        'front.png',
      ];
      for (final name in coverNames) {
        final candidate = File(p.join(dir.path, name));
        if (candidate.existsSync()) {
          final bytes = await candidate.readAsBytes();
          if (bytes.isNotEmpty) return bytes;
        }
      }

      final raf = await audioFile.open();
      try {
        final header = await raf.read(1536 * 1024);
        if (header.isEmpty) return null;
        return AudioAssetExtractor.extractEmbeddedCoverFromHeaderBytes(header);
      } finally {
        await raf.close();
      }
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final v = widget.variant;
    final ext = MediaDisplayFormatter.fileExtensionUpper(v.fileName);
    final dirHint = widget.directSubdirLabel?.trim() ?? '';
    final sizeText = MediaDisplayFormatter.formatBytes(v.fileSize);
    final subLine = <String>[
      if (sizeText.isNotEmpty) sizeText,
      if (dirHint.isNotEmpty) dirHint,
    ].join(' · ');
    final displayTitle =
        (widget.displayTitleOverride != null &&
            widget.displayTitleOverride!.trim().isNotEmpty)
        ? widget.displayTitleOverride!.trim()
        : _stripAssetExtension(v.fileName);
    final borderColor = _hovered
        ? KonataPlaybackTokens.activeGlassBorder(palette)
        : KonataPlaybackTokens.glassBorder(palette);

    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.15,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: SizedBox(
            width: widget.cardWidth,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContainer(
                  duration: KonataTheme.motionFast,
                  curve: Curves.easeOutCubic,
                  decoration: BoxDecoration(
                    borderRadius: KonataTheme.borderRadiusCard,
                    border: Border.all(color: borderColor, width: 1.0),
                    boxShadow: [
                      BoxShadow(
                        color: KonataPlaybackTokens.shadowColor(palette),
                        blurRadius: 14,
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
                          if (_coverBytes != null && _coverBytes!.isNotEmpty)
                            Image.memory(
                              _coverBytes!,
                              fit: BoxFit.cover,
                              gaplessPlayback: true,
                              errorBuilder: (_, _, _) =>
                                  _buildOpticalDiscFallback(palette),
                            )
                          else
                            _buildOpticalDiscFallback(palette),
                          if (!KonataAdaptiveTokens.isAndroid && _hovered)
                            const IgnorePointer(
                              child: ColoredBox(
                                color: KonataTheme.scrimBlackLight,
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
                          if (!KonataAdaptiveTokens.isAndroid && _hovered)
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
                    palette: palette,
                    color: (widget.onDarkBackdrop || palette.isDark)
                        ? (_hovered
                              ? KonataTheme.pureWhite
                              : KonataTheme.overlayWhiteTextStrong)
                        : palette.textPrimary,
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
                      palette: palette,
                      color: (widget.onDarkBackdrop || palette.isDark)
                          ? KonataTheme.overlayWhiteTextSub
                          : palette.textSecondary,
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
                      palette: palette,
                      color: (widget.onDarkBackdrop || palette.isDark)
                          ? KonataTheme.overlayWhiteTextMuted
                          : palette.textMuted,
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

  Widget _buildOpticalDiscFallback(KonataPalette palette) {
    final poster = widget.workPosterPath?.trim() ?? '';
    final loader = widget.imageLoader;
    if (poster.isEmpty || loader == null) {
      return KonataCdDiscPlaceholder(hovered: _hovered);
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        ImageFiltered(
          imageFilter: KonataTheme.blurFilterSubtle,
          child: DetailManagedImage(
            poster,
            loader: loader,
            owner: widget.workId ?? widget.variant.workId,
            artwork: ManagedArtwork.poster,
            fit: BoxFit.cover,
          ),
        ),
        ColoredBox(
          color:
              (palette.isDark
                      ? KonataTheme.cinemaObsidian
                      : KonataTheme.pureWhite)
                  .withValues(alpha: palette.isDark ? 0.56 : 0.42),
        ),
        KonataCdDiscPlaceholder(hovered: _hovered, transparentBackdrop: true),
      ],
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
