import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/history_timeline_models.dart';

/// 按作品主键加载封面字节的异步回调类型。
typedef HistoryArtworkLoader = Future<Uint8List?> Function(WorkId workId);

/// 按媒体文件/剧照相对路径加载图像字节的异步回调类型。
typedef HistoryPathArtworkLoader =
    Future<Uint8List?> Function(String path, {int targetWidth});

/// 播放记录时间轴共用的海报/16:9 剧照/1:1 专辑圆角缩略图组件。
class HistoryThumbnail extends StatefulWidget {
  /// 创建播放记录缩略图组件。
  const HistoryThumbnail({
    super.key,
    required this.workId,
    required this.isAudio,
    required this.imageLoader,
    required this.width,
    required this.height,
    this.artworkPath,
    this.pathArtworkLoader,
    this.hovered = false,
  });

  /// 作品唯一主键。
  final WorkId workId;

  /// 是否为音频或光盘专辑条目（未加载出封面时展示黑胶圆盘占位）。
  final bool isAudio;

  /// 作品级封面图像字节加载回调。
  final HistoryArtworkLoader? imageLoader;

  /// 可选具体路径（如分集 16:9 剧照路径）。
  final String? artworkPath;

  /// 可选按路径加载剧照字节的回调。
  final HistoryPathArtworkLoader? pathArtworkLoader;

  /// 缩略图逻辑宽度。
  final double width;

  /// 缩略图逻辑高度。
  final double height;

  /// 外层卡片是否正处于桌面端悬停激活态。
  final bool hovered;

  @override
  State<HistoryThumbnail> createState() => _HistoryThumbnailState();
}

class _HistoryThumbnailState extends State<HistoryThumbnail> {
  Uint8List? _bytes;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _loadCover();
  }

  @override
  void didUpdateWidget(covariant HistoryThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workId != widget.workId ||
        oldWidget.artworkPath != widget.artworkPath ||
        oldWidget.imageLoader != widget.imageLoader ||
        oldWidget.pathArtworkLoader != widget.pathArtworkLoader) {
      _loadCover();
    }
  }

  Future<void> _loadCover() async {
    final gen = ++_generation;
    Uint8List? loaded;
    final path = widget.artworkPath?.trim() ?? '';
    final pathLoader = widget.pathArtworkLoader;
    if (path.isNotEmpty && pathLoader != null) {
      try {
        loaded = await pathLoader(path, targetWidth: (widget.width * 2).round());
      } catch (_) {
        loaded = null;
      }
    }
    if (loaded == null && widget.imageLoader != null) {
      try {
        loaded = await widget.imageLoader!(widget.workId);
      } catch (_) {
        loaded = null;
      }
    }
    if (!mounted || gen != _generation) return;
    setState(() => _bytes = loaded);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final bytes = _bytes;

    final Widget inner;
    if (bytes != null && bytes.isNotEmpty) {
      inner = Image.memory(
        bytes,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, _, _) => _PlaceholderPoster(
          palette: p,
          isAudio: widget.isAudio,
          hovered: widget.hovered,
        ),
      );
    } else if (widget.isAudio) {
      inner = KonataCdDiscPlaceholder(hovered: widget.hovered);
    } else {
      inner = _PlaceholderPoster(
        palette: p,
        isAudio: false,
        hovered: widget.hovered,
      );
    }

    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: ClipRRect(
        borderRadius: KonataTheme.borderRadiusSm,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            inner,
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: KonataTheme.borderRadiusSm,
                    border: Border.all(color: p.posterBorder),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaceholderPoster extends StatelessWidget {
  const _PlaceholderPoster({
    required this.palette,
    required this.isAudio,
    required this.hovered,
  });

  final KonataPalette palette;
  final bool isAudio;
  final bool hovered;

  @override
  Widget build(BuildContext context) {
    if (isAudio) {
      return KonataCdDiscPlaceholder(hovered: hovered);
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[palette.elevatedSurface, palette.surface],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.movie_outlined,
          size: 20,
          color: palette.textMuted,
        ),
      ),
    );
  }
}

/// 播放记录进度细条（3.2 像素圆角轨道）、进度摘要文案与 24 小时制时间戳组合行。
class HistoryProgressMetaRow extends StatelessWidget {
  /// 创建播放进度元信息行。
  const HistoryProgressMetaRow({
    super.key,
    required this.item,
    this.showProgressBar = true,
  });

  /// 当前展示的播放记录条目视图。
  final HistoryEntryView item;

  /// 是否在元信息上方渲染 3.2px 圆角进度细条。
  final bool showProgressBar;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final ratio = item.progressRatio.clamp(0.0, 1.0);
    final fillColor = item.isCompleted ? p.success : p.progressFill;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (showProgressBar) ...<Widget>[
          ClipRRect(
            borderRadius: KonataTheme.borderRadiusPill,
            child: SizedBox(
              height: 3.2,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  ColoredBox(color: p.progressTrack),
                  FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: ratio,
                    child: ColoredBox(color: fillColor),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 5),
        ],
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                item.progressLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: KonataTheme.textStyle(
                  color: item.isCompleted ? p.success : p.textSecondary,
                  fontSize: KonataTheme.fontSizeCaptionXs,
                  weight: item.isCompleted
                      ? KonataTheme.weightActive
                      : KonataTheme.weightRegularLabel,
                  tabularFigures: true,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.schedule_rounded, size: 11, color: p.textMuted),
            const SizedBox(width: 3),
            Text(
              item.playedTimeLabel,
              style: KonataTheme.textStyle(
                color: p.textMuted,
                fontSize: KonataTheme.fontSizeCaptionXs,
                tabularFigures: true,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 展开抽屉中的单集 16:9 剧照卡或 1:1 音频专辑子卡片组件。
class HistoryExpandedEpisodeRow extends StatefulWidget {
  /// 创建展开抽屉中的单条子卡片。
  const HistoryExpandedEpisodeRow({
    super.key,
    required this.item,
    required this.isSelectionMode,
    required this.isSelected,
    required this.onResume,
    required this.onDelete,
    required this.onToggleSelect,
    this.onMarkCompleted,
    this.imageLoader,
    this.pathArtworkLoader,
    this.compact = false,
    this.cardWidth,
  });

  /// 单条播放记录视图模型。
  final HistoryEntryView item;

  /// 当前页面是否处于批量多选态。
  final bool isSelectionMode;

  /// 当前条目是否已被多选勾选。
  final bool isSelected;

  /// 点击续播该分集或音轨的回调。
  final VoidCallback onResume;

  /// 删除该单条播放记录回调。
  final VoidCallback onDelete;

  /// 切换该条记录选中态回调。
  final VoidCallback onToggleSelect;

  /// 可选标记单条已完播回调。
  final VoidCallback? onMarkCompleted;

  /// 作品封面加载器。
  final HistoryArtworkLoader? imageLoader;

  /// 剧照路径加载器。
  final HistoryPathArtworkLoader? pathArtworkLoader;

  /// 是否使用紧凑移动端尺寸。
  final bool compact;

  /// 可选固定卡片宽度（置于水平滑动托盘中时防止无界膨胀）。
  final double? cardWidth;

  @override
  State<HistoryExpandedEpisodeRow> createState() =>
      _HistoryExpandedEpisodeRowState();
}

class _HistoryExpandedEpisodeRowState extends State<HistoryExpandedEpisodeRow> {
  bool _hovered = false;

  Future<void> _showRowMenu(BuildContext anchorContext) async {
    final action = await showKonataGlassMenu<String>(
      anchorContext: anchorContext,
      items: <KonataGlassMenuItem<String>>[
        const KonataGlassMenuItem<String>(
          value: 'resume',
          label: '继续播放',
          icon: Icons.play_arrow_rounded,
        ),
        if (widget.onMarkCompleted != null && !widget.item.isCompleted)
          KonataGlassMenuItem<String>(
            value: 'complete',
            label: widget.item.isAudio ? '标为已听完' : '标为已看完',
            icon: Icons.done_rounded,
          ),
        const KonataGlassMenuItem<String>(
          value: 'delete',
          label: '删除此条记录',
          icon: Icons.delete_outline_rounded,
          isDanger: true,
        ),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'resume':
        widget.onResume();
      case 'complete':
        widget.onMarkCompleted?.call();
      case 'delete':
        widget.onDelete();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final item = widget.item;
    final audio = item.isAudio;
    final subdir = item.audioSubdirLabel;
    final thumbW = audio
        ? (widget.compact ? 56.0 : 64.0)
        : (widget.compact ? 104.0 : 116.0);
    final thumbH = audio
        ? (widget.compact ? 56.0 : 64.0)
        : (widget.compact ? 58.0 : 65.0);

    return SizedBox(
      width: widget.cardWidth,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.isSelectionMode
              ? widget.onToggleSelect
              : widget.onResume,
          onSecondaryTap: () => _showRowMenu(context),
          onLongPress: () => _showRowMenu(context),
          child: AnimatedContainer(
            duration: KonataTheme.motionMicro,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: widget.isSelected
                  ? p.accentBadge.bg
                  : (_hovered ? p.surfaceHover : p.surface),
              borderRadius: KonataTheme.borderRadiusControl,
              border: Border.all(
                color: widget.isSelected
                    ? KonataTheme.activeControlBorder(p)
                    : (_hovered ? p.hoverBorder : p.hairline),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                if (widget.isSelectionMode) ...<Widget>[
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: Checkbox(
                      value: widget.isSelected,
                      activeColor: p.accent,
                      onChanged: (_) => widget.onToggleSelect(),
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                HistoryThumbnail(
                  workId: item.record.workId,
                  artworkPath: audio ? null : item.stillPath,
                  isAudio: audio,
                  imageLoader: widget.imageLoader,
                  pathArtworkLoader: widget.pathArtworkLoader,
                  width: thumbW,
                  height: thumbH,
                  hovered: _hovered,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              item.episodeSubtitle,
                              maxLines: subdir != null ? 1 : 2,
                              overflow: TextOverflow.ellipsis,
                              style: KonataTheme.textStyle(
                                color: p.textPrimary,
                                fontSize: KonataTheme.fontSizeCaption,
                                weight: KonataTheme.weightActive,
                                height: 1.25,
                              ),
                            ),
                          ),
                          if (!widget.isSelectionMode)
                            Builder(
                              builder: (menuCtx) => KonataCapsuleIconButton(
                                icon: Icons.more_horiz_rounded,
                                tooltip: '操作菜单',
                                color: p.textMuted,
                                size: 14,
                                fixedSize: 22,
                                onTap: () => _showRowMenu(menuCtx),
                              ),
                            ),
                        ],
                      ),
                      if (subdir != null) ...<Widget>[
                        const SizedBox(height: 2),
                        Text(
                          subdir,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: KonataTheme.captionStyle(
                            p,
                            fontSize: KonataTheme.fontSizeMicro,
                          ),
                        ),
                      ],
                      const SizedBox(height: 5),
                      HistoryProgressMetaRow(item: item, showProgressBar: true),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
