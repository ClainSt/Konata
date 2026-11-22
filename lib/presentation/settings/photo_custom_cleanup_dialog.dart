import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/artwork_provider.dart';
import '../../application/providers/library_providers.dart';
import '../../application/providers/scraping_providers.dart';
import '../../domain/formatting/media_display_formatter.dart';
import '../../infrastructure/cache/photos_storage.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_playback_tokens.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/adaptive_responsive_row.dart';
import '../widgets/design_system/ellipsis_text_with_tooltip.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_glass_dialog.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_soft_text_field.dart';
import '../widgets/design_system/konata_toast.dart';
import '../widgets/managed_image.dart';

/// 以居中宽幅 0 延迟可拖拽毛玻璃弹窗打开「本地图片自定义清理」。
Future<void> showPhotoCustomCleanupDialog(BuildContext context) {
  return showKonataGlassDialog<void>(
    context: context,
    builder: (_) => const PhotoCustomCleanupDialog(),
  );
}

/// 居中宽幅 0 延迟可拖拽的 `photos/` 本地图片自定义精准清理弹窗。
class PhotoCustomCleanupDialog extends ConsumerStatefulWidget {
  /// 创建本地图片自定义清理弹窗。
  const PhotoCustomCleanupDialog({super.key});

  @override
  ConsumerState<PhotoCustomCleanupDialog> createState() =>
      _PhotoCustomCleanupDialogState();
}

class _PhotoCustomCleanupDialogState
    extends ConsumerState<PhotoCustomCleanupDialog> {
  static const Set<PhotoStorageCategory> _defaultRegenerable = {
    PhotoStorageCategory.thumbnails,
    PhotoStorageCategory.scans,
  };

  final TextEditingController _filterCtrl = TextEditingController();
  final ScrollController _workListCtrl = ScrollController();

  final Set<PhotoStorageCategory> _selectedCategories =
      Set<PhotoStorageCategory>.from(_defaultRegenerable);
  final Set<String> _selectedWorkDirKeys = <String>{};
  bool _initializedWorkSelection = false;
  bool _cleaning = false;
  String _query = '';

  @override
  void dispose() {
    _filterCtrl.dispose();
    _workListCtrl.dispose();
    super.dispose();
  }

  void _syncInitialSelection(List<WorkPhotoStorageEntry> entries) {
    if (_initializedWorkSelection) return;
    _initializedWorkSelection = true;
    _selectedWorkDirKeys
      ..clear()
      ..addAll(entries.map((e) => e.workDirKey));
  }

  List<WorkPhotoStorageEntry> _filterEntries(
    List<WorkPhotoStorageEntry> entries,
  ) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return entries;
    return entries
        .where(
          (e) =>
              e.displayTitle.toLowerCase().contains(q) ||
              e.workDirKey.toLowerCase().contains(q),
        )
        .toList(growable: false);
  }

  Future<void> _executeCleanup(
    int estimatedFiles,
  ) async {
    if (_cleaning || estimatedFiles <= 0) return;
    setState(() => _cleaning = true);
    try {
      final storage = ref.read(photosStorageProvider);
      final res = await storage.cleanCustomPhotos(
        workDirKeys: Set<String>.from(_selectedWorkDirKeys),
        categories: Set<PhotoStorageCategory>.from(_selectedCategories),
      );
      ref.invalidate(photosStorageSnapshotProvider);
      ref.invalidate(artworkCacheProvider);
      if (!mounted) return;
      final formatted = MediaDisplayFormatter.formatBytes(
        res.deletedBytes,
        emptyFallback: '0 B',
      );
      showKonataToast(
        context,
        '已清理 ${res.deletedFiles} 张图片，释放 $formatted',
      );
      Navigator.of(context).pop();
    } catch (err) {
      if (!mounted) return;
      setState(() => _cleaning = false);
      showKonataToast(context, '自定义清理失败: $err', isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final snapshotAsync = ref.watch(photosStorageSnapshotProvider);
    final imageLoader = ref.watch(tmdbImageLoaderProvider);
    final viewport = MediaQuery.sizeOf(context);
    final maxSafeWidth = math.max(
      220.0,
      viewport.width - KonataTheme.dialogViewportMargin * 2,
    );
    final dialogWidth = math.min(
      maxSafeWidth,
      (viewport.width * 0.68).clamp(680.0, 860.0),
    );
    final dialogHeight = math.min(
      680.0,
      math.max(260.0, viewport.height * 0.82),
    );

    final includesMetadataArt =
        _selectedCategories.contains(PhotoStorageCategory.posters) ||
        _selectedCategories.contains(PhotoStorageCategory.backdrops) ||
        _selectedCategories.contains(PhotoStorageCategory.logos);

    return KonataGlassDialog(
      title: '自定义图片清理',
      width: dialogWidth,
      height: dialogHeight,
      child: snapshotAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(
          child: Text(
            '读取本地图片目录失败: $err',
            style: TextStyle(color: p.danger, fontSize: KonataTheme.fontSizeBodySm),
          ),
        ),
        data: (snapshot) {
          final entries = snapshot.workEntries;
          _syncInitialSelection(entries);
          final filtered = _filterEntries(entries);

          final selectedEntries = entries
              .where((e) => _selectedWorkDirKeys.contains(e.workDirKey))
              .toList(growable: false);
          final perCategoryStats = <PhotoStorageCategory, PhotoCategoryStat>{
            for (final cat in PhotoStorageCategory.values)
              cat: PhotoCategoryStat(
                bytes: selectedEntries.fold<int>(
                  0,
                  (sum, e) => sum + (e.byCategory[cat]?.bytes ?? 0),
                ),
                files: selectedEntries.fold<int>(
                  0,
                  (sum, e) => sum + (e.byCategory[cat]?.files ?? 0),
                ),
              ),
          };

          var estimatedBytes = 0;
          var estimatedFiles = 0;
          for (final entry in selectedEntries) {
            final hit = entry.statForCategories(_selectedCategories);
            estimatedBytes += hit.bytes;
            estimatedFiles += hit.files;
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 区块一：清理图片类别多选
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 6,
                children: [
                  Text(
                    '1. 选择要清理的图片类别',
                    style: TextStyle(
                      color: p.textPrimary,
                      fontSize: KonataTheme.fontSizeBody,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      KonataPillButton.ghost(
                        label: '仅微缩图',
                        compact: true,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        onPressed: _cleaning
                            ? null
                            : () => setState(() {
                                _selectedCategories
                                  ..clear()
                                  ..addAll(_defaultRegenerable);
                              }),
                      ),
                      KonataPillButton.ghost(
                        label: '全选类别',
                        compact: true,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        onPressed: _cleaning
                            ? null
                            : () => setState(() {
                                _selectedCategories.addAll(
                                  PhotoStorageCategory.values,
                                );
                              }),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              LayoutBuilder(
                builder: (context, chipBox) {
                  if (chipBox.maxWidth >= 520) {
                    return Row(
                      children: [
                        for (
                          var i = 0;
                          i < PhotoStorageCategory.values.length;
                          i++
                        ) ...[
                          if (i > 0) const SizedBox(width: 8),
                          Expanded(
                            child: _CleanupCategoryChip(
                              category: PhotoStorageCategory.values[i],
                              stat:
                                  perCategoryStats[PhotoStorageCategory
                                      .values[i]] ??
                                  PhotoCategoryStat.zero,
                              selected: _selectedCategories.contains(
                                PhotoStorageCategory.values[i],
                              ),
                              onTap: _cleaning
                                  ? null
                                  : () {
                                      final cat =
                                          PhotoStorageCategory.values[i];
                                      setState(() {
                                        if (!_selectedCategories.remove(cat)) {
                                          _selectedCategories.add(cat);
                                        }
                                      });
                                    },
                            ),
                          ),
                        ],
                      ],
                    );
                  }
                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final cat in PhotoStorageCategory.values)
                        SizedBox(
                          width: math.max(
                            112.0,
                            (chipBox.maxWidth - 8) / 2,
                          ),
                          child: _CleanupCategoryChip(
                            category: cat,
                            stat:
                                perCategoryStats[cat] ??
                                PhotoCategoryStat.zero,
                            selected: _selectedCategories.contains(cat),
                            onTap: _cleaning
                                ? null
                                : () => setState(() {
                                    if (!_selectedCategories.remove(cat)) {
                                      _selectedCategories.add(cat);
                                    }
                                  }),
                          ),
                        ),
                    ],
                  );
                },
              ),
              if (includesMetadataArt) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: p.warningBadge.bg,
                    borderRadius: KonataTheme.borderRadiusControl,
                    border: Border.all(color: p.warningBadge.border, width: 1),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline_rounded,
                        size: 15,
                        color: p.warningBadge.fg,
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          '已包含海报/背景/徽标：清理后对应作品需刷新元数据或重新刮削方可恢复本地缓存',
                          style: TextStyle(
                            color: p.warningBadge.fg,
                            fontSize: KonataTheme.fontSizeCaption,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 14),

              // 区块二：媒体库作品列表（单选 / 多选 / 全选 / 取消全选）
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 6,
                children: [
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 10,
                    runSpacing: 4,
                    children: [
                      Text(
                        '2. 选择目标作品',
                        style: TextStyle(
                          color: p.textPrimary,
                          fontSize: KonataTheme.fontSizeBody,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        '已选 ${_selectedWorkDirKeys.length} / ${entries.length} 部作品',
                        style: TextStyle(
                          color: p.textSecondary,
                          fontSize: KonataTheme.fontSizeBodyXs,
                          fontFeatures: KonataPlaybackTokens.tabularNumbers,
                        ),
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      KonataPillButton.ghost(
                        label: '全选',
                        compact: true,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        onPressed: _cleaning || filtered.isEmpty
                            ? null
                            : () => setState(() {
                                _selectedWorkDirKeys.addAll(
                                  filtered.map((e) => e.workDirKey),
                                );
                              }),
                      ),
                      KonataPillButton.ghost(
                        label: '取消全选',
                        compact: true,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        onPressed: _cleaning || _selectedWorkDirKeys.isEmpty
                            ? null
                            : () => setState(() {
                                if (_query.trim().isEmpty) {
                                  _selectedWorkDirKeys.clear();
                                } else {
                                  _selectedWorkDirKeys.removeAll(
                                    filtered.map((e) => e.workDirKey),
                                  );
                                }
                              }),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              KonataSoftTextField(
                controller: _filterCtrl,
                dense: true,
                prefixIcon: Icons.search_rounded,
                hintText: '按作品名称或目录筛选...',
                suffix: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close_rounded, size: 16),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 24,
                          minHeight: 24,
                        ),
                        onPressed: () {
                          _filterCtrl.clear();
                          setState(() => _query = '');
                        },
                      ),
                onChanged: (v) => setState(() => _query = v),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: filtered.isEmpty
                    ? Center(
                        child: Text(
                          entries.isEmpty ? '当前媒体库与磁盘目录均暂无记录' : '没有匹配的作品',
                          style: TextStyle(color: p.textMuted, fontSize: KonataTheme.fontSizeBodySm),
                        ),
                      )
                    : Container(
                        decoration: BoxDecoration(
                          color: p.surface,
                          borderRadius: KonataTheme.borderRadiusCard,
                          border: Border.all(color: p.hairline, width: 1),
                        ),
                        child: KonataDraggableScrollbar(
                          controller: _workListCtrl,
                          padding: const EdgeInsets.only(right: 4),
                          builder: (_, ctrl) => ListView.separated(
                            controller: ctrl,
                            padding: const EdgeInsets.fromLTRB(10, 8, 16, 8),
                            itemCount: filtered.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 6),
                            itemBuilder: (_, idx) {
                              final entry = filtered[idx];
                              final checked = _selectedWorkDirKeys.contains(
                                entry.workDirKey,
                              );
                              final hit = entry.statForCategories(
                                _selectedCategories,
                              );
                              return _WorkPhotoCleanupRow(
                                entry: entry,
                                checked: checked,
                                hitStat: hit,
                                imageLoader: imageLoader,
                                onToggle: _cleaning
                                    ? null
                                    : () => setState(() {
                                        if (!_selectedWorkDirKeys.remove(
                                          entry.workDirKey,
                                        )) {
                                          _selectedWorkDirKeys.add(
                                            entry.workDirKey,
                                          );
                                        }
                                      }),
                              );
                            },
                          ),
                        ),
                      ),
              ),
              const SizedBox(height: 16),

              // 底部结算动作栏
              AdaptiveResponsiveRow(
                minLeadingWidth: 160,
                estimatedTrailingWidth: 170,
                leading: Text(
                  '预计释放：'
                  '${MediaDisplayFormatter.formatBytes(estimatedBytes, emptyFallback: '0 B')}'
                  '（共 $estimatedFiles 张图片）',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: estimatedFiles > 0 ? p.textPrimary : p.textSecondary,
                    fontSize: KonataTheme.fontSizeBodySm,
                    fontWeight: FontWeight.w600,
                    fontFeatures: KonataPlaybackTokens.tabularNumbers,
                  ),
                ),
                trailing: Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    KonataPillButton.secondary(
                      label: '取消',
                      compact: true,
                      onPressed: _cleaning
                          ? null
                          : () => Navigator.of(context).maybePop(),
                    ),
                    KonataPillButton.danger(
                      label: _cleaning ? '清理中...' : '清理所选',
                      icon: Icons.delete_sweep_outlined,
                      compact: true,
                      onPressed: (!_cleaning && estimatedFiles > 0)
                          ? () => _executeCleanup(estimatedFiles)
                          : null,
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _CleanupCategoryChip extends StatefulWidget {
  const _CleanupCategoryChip({
    required this.category,
    required this.stat,
    required this.selected,
    required this.onTap,
  });

  final PhotoStorageCategory category;
  final PhotoCategoryStat stat;
  final bool selected;
  final VoidCallback? onTap;

  @override
  State<_CleanupCategoryChip> createState() => _CleanupCategoryChipState();
}

class _CleanupCategoryChipState extends State<_CleanupCategoryChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final selected = widget.selected;
    final accentColors = p.accentBadge;
    final bg = selected
        ? accentColors.bg
        : (_hovered ? p.surfaceHover : p.softFill);
    final border = selected
        ? accentColors.border
        : (_hovered ? p.hoverBorder : p.hairline);
    final titleColor = selected ? accentColors.fg : p.textPrimary;
    final subColor = selected
        ? accentColors.fg.withValues(alpha: 0.85)
        : p.textSecondary;

    return MouseRegion(
      cursor: widget.onTap == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: KonataTheme.motionFast,
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: KonataTheme.borderRadiusControl,
            border: Border.all(color: border, width: 1),
          ),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.check_box_rounded
                    : Icons.check_box_outline_blank_rounded,
                size: 15,
                color: selected ? accentColors.fg : p.textMuted,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.category.displayLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: titleColor,
                        fontSize: KonataTheme.fontSizeCaption,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      '${MediaDisplayFormatter.formatBytes(widget.stat.bytes, emptyFallback: '0 B')} · ${widget.stat.files} 张',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: subColor,
                        fontSize: KonataTheme.fontSizeBadge,
                        fontFeatures: KonataPlaybackTokens.tabularNumbers,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WorkPhotoCleanupRow extends StatefulWidget {
  const _WorkPhotoCleanupRow({
    required this.entry,
    required this.checked,
    required this.hitStat,
    required this.imageLoader,
    required this.onToggle,
  });

  final WorkPhotoStorageEntry entry;
  final bool checked;
  final PhotoCategoryStat hitStat;
  final ManagedImageLoader imageLoader;
  final VoidCallback? onToggle;

  @override
  State<_WorkPhotoCleanupRow> createState() => _WorkPhotoCleanupRowState();
}

class _WorkPhotoCleanupRowState extends State<_WorkPhotoCleanupRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final entry = widget.entry;
    final checked = widget.checked;
    final poster = entry.posterPath?.trim() ?? '';

    final bg = checked
        ? p.softFill
        : (_hovered ? p.surfaceHover : Colors.transparent);

    return MouseRegion(
      cursor: widget.onToggle == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onToggle,
        child: AnimatedContainer(
          duration: KonataTheme.motionMicro,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: KonataTheme.borderRadiusControl,
            border: Border.all(
              color: checked ? p.hairline : Colors.transparent,
              width: 1,
            ),
          ),
          child: Row(
            children: [
              IgnorePointer(
                child: Checkbox(
                  value: checked,
                  onChanged: (_) {},
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const SizedBox(width: 8),
              ClipRRect(
                borderRadius: KonataTheme.borderRadiusChip,
                child: SizedBox(
                  width: 34,
                  height: 51,
                  child: poster.isNotEmpty
                      ? ManagedImage(
                          poster,
                          owner: entry.workId,
                          artwork: ManagedArtwork.poster,
                          decodeWidth: 96,
                          loader: widget.imageLoader,
                          fit: BoxFit.cover,
                        )
                      : DecoratedBox(
                          decoration: BoxDecoration(
                            color: p.softFill,
                            border: Border.all(color: p.hairline, width: 1),
                          ),
                          child: Icon(
                            entry.isOrphan
                                ? Icons.folder_delete_outlined
                                : Icons.photo_library_outlined,
                            size: 16,
                            color: p.textMuted,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: EllipsisTextWithTooltip(
                            text: entry.displayTitle,
                            maxLines: 1,
                            style: TextStyle(
                              color: p.textPrimary,
                              fontSize: KonataTheme.fontSizeBody,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (entry.isOrphan) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: p.warningBadge.bg,
                              borderRadius: KonataTheme.borderRadiusPill,
                              border: Border.all(
                                color: p.warningBadge.border,
                                width: 1,
                              ),
                            ),
                            child: Text(
                              '残留目录',
                              style: TextStyle(
                                color: p.warningBadge.fg,
                                fontSize: KonataTheme.fontSizeBadge,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    EllipsisTextWithTooltip(
                      text: entry.workDirKey,
                      maxLines: 1,
                      style: TextStyle(
                        color: p.textMuted,
                        fontSize: KonataTheme.fontSizeCaptionSm,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    MediaDisplayFormatter.formatBytes(
                      widget.hitStat.bytes,
                      emptyFallback: '0 B',
                    ),
                    style: TextStyle(
                      color: widget.hitStat.files > 0
                          ? p.textPrimary
                          : p.textMuted,
                      fontSize: KonataTheme.fontSizeBodyXs,
                      fontWeight: FontWeight.w600,
                      fontFeatures: KonataPlaybackTokens.tabularNumbers,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    '${widget.hitStat.files} 张',
                    style: TextStyle(
                      color: p.textSecondary,
                      fontSize: KonataTheme.fontSizeCaptionXs,
                      fontFeatures: KonataPlaybackTokens.tabularNumbers,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
