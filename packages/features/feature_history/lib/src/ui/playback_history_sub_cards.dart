import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/history_timeline_models.dart';

/// 播放记录可选自定义封面加载器（保持 `feature_history` 与图片刮削实现解耦）。
typedef HistoryArtworkLoader = Future<Uint8List?> Function(WorkId workId);

/// 播放记录封面或 CD 光盘缩略图视图。
class HistoryThumbnail extends StatefulWidget {
  /// 创建播放记录缩略图组件。
  const HistoryThumbnail({
    super.key,
    required this.workId,
    required this.isAudio,
    this.imageLoader,
    this.width = 58,
    this.height = 82,
  });

  /// 关联作品主键。
  final WorkId workId;

  /// 是否为音频/CD 记录。
  final bool isAudio;

  /// 可选封面字节异步加载器。
  final HistoryArtworkLoader? imageLoader;

  /// 缩略图宽度。
  final double width;

  /// 缩略图高度。
  final double height;

  @override
  State<HistoryThumbnail> createState() => _HistoryThumbnailState();
}

class _HistoryThumbnailState extends State<HistoryThumbnail> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _loadCover();
  }

  @override
  void didUpdateWidget(covariant HistoryThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workId != widget.workId ||
        oldWidget.imageLoader != widget.imageLoader) {
      _bytes = null;
      _loadCover();
    }
  }

  Future<void> _loadCover() async {
    final loader = widget.imageLoader;
    if (loader == null) {
      return;
    }
    try {
      final loaded = await loader(widget.workId);
      if (mounted && loaded != null && loaded.isNotEmpty) {
        setState(() {
          _bytes = loaded;
        });
      }
    } catch (_) {
      // 忽略封面读取失败，回退至占位图标。
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<KonataPalette>()!;
    final bytes = _bytes;

    if (widget.isAudio) {
      final discSize = widget.width < widget.height ? widget.width : widget.height;
      return SizedBox(
        width: widget.width,
        height: widget.height,
        child: Center(
          child: SizedBox(
            width: discSize,
            height: discSize,
            child: const KonataCdDiscPlaceholder(),
          ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: tokens.softFill,
          border: Border.all(color: tokens.posterBorder, width: 0.8),
          borderRadius: BorderRadius.circular(10),
        ),
        child: bytes != null
            ? Image.memory(
                bytes,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _PlaceholderPoster(tokens: tokens),
              )
            : _PlaceholderPoster(tokens: tokens),
      ),
    );
  }
}

class _PlaceholderPoster extends StatelessWidget {
  const _PlaceholderPoster({required this.tokens});

  final KonataPalette tokens;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Icon(
        Icons.movie_filter_outlined,
        size: 24,
        color: tokens.textMuted,
      ),
    );
  }
}

/// 精简进度条与时间戳摘要行。
class HistoryProgressMetaRow extends StatelessWidget {
  /// 创建进度条与时间展示行。
  const HistoryProgressMetaRow({
    super.key,
    required this.item,
    this.showProgressBar = true,
  });

  /// 单条历史视图。
  final HistoryEntryView item;

  /// 是否显示横向进度条。
  final bool showProgressBar;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<KonataPalette>()!;
    final ratio = item.progressRatio;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                item.progressLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: item.record.isCompleted
                      ? tokens.success
                      : tokens.textSecondary,
                  fontWeight: item.record.isCompleted
                      ? FontWeight.w600
                      : FontWeight.w400,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              item.playedTimeLabel,
              style: TextStyle(
                fontSize: 11.5,
                color: tokens.textMuted,
              ),
            ),
          ],
        ),
        if (showProgressBar && (item.record.durationSeconds > 0 || item.record.isCompleted)) ...[
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: Container(
              height: 4,
              width: double.infinity,
              color: tokens.progressTrack,
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: ratio.clamp(0.0, 1.0),
                child: Container(
                  decoration: BoxDecoration(
                    color: item.record.isCompleted
                        ? tokens.success
                        : tokens.progressFill,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// 聚合作品卡片展开后的单集（或单曲）子行组件。
class HistoryExpandedEpisodeRow extends StatelessWidget {
  /// 创建展开子行组件。
  const HistoryExpandedEpisodeRow({
    super.key,
    required this.item,
    required this.isSelectionMode,
    required this.isSelected,
    required this.onResume,
    required this.onDelete,
    required this.onToggleSelect,
  });

  /// 关联单条记录。
  final HistoryEntryView item;

  /// 是否处于多选模式。
  final bool isSelectionMode;

  /// 是否已被勾选。
  final bool isSelected;

  /// 点击续播回调。
  final VoidCallback onResume;

  /// 删除单条记录回调。
  final VoidCallback onDelete;

  /// 切换勾选回调。
  final VoidCallback onToggleSelect;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<KonataPalette>()!;

    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        color: isSelected
            ? tokens.accent.withValues(alpha: 0.12)
            : tokens.softFill,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isSelected ? tokens.accent : tokens.hairline,
          width: 0.8,
        ),
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: isSelectionMode ? onToggleSelect : onResume,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              if (isSelectionMode) ...[
                Checkbox(
                  value: isSelected,
                  onChanged: (_) => onToggleSelect(),
                ),
                const SizedBox(width: 4),
              ] else ...[
                Icon(
                  item.isAudio
                      ? Icons.audiotrack_rounded
                      : Icons.play_arrow_rounded,
                  size: 18,
                  color: tokens.accent,
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.episodeSubtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: tokens.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    HistoryProgressMetaRow(item: item, showProgressBar: true),
                  ],
                ),
              ),
              if (!isSelectionMode) ...[
                const SizedBox(width: 6),
                Builder(
                  builder: (menuAnchorCtx) => GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _showRowMenu(menuAnchorCtx),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(
                        Icons.more_horiz_rounded,
                        size: 18,
                        color: tokens.textSecondary,
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
  }

  Future<void> _showRowMenu(BuildContext anchorContext) async {
    final chosen = await showKonataGlassMenu<String>(
      anchorContext: anchorContext,
      items: const [
        KonataGlassMenuItem(
          value: 'resume',
          label: '继续播放',
          icon: Icons.play_arrow_rounded,
        ),
        KonataGlassMenuItem(
          value: 'delete',
          label: '删除此条记录',
          icon: Icons.delete_outline_rounded,
          isDanger: true,
        ),
      ],
    );
    if (chosen == 'resume') {
      onResume();
    } else if (chosen == 'delete') {
      onDelete();
    }
  }
}
