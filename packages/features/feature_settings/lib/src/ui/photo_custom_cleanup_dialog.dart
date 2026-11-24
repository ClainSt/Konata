import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';
import 'package:konata_storage/konata_storage.dart';

import '../data/photos_cleanup_scanner.dart';

/// 自定义分类清理结果载荷。
final class PhotoCustomCleanupSelection {
  /// 创建清理选择结果。
  const PhotoCustomCleanupSelection({
    required this.categories,
    this.workId,
  });

  /// 需要清理的图片分类集合。
  final Set<PhotoStorageCategory> categories;

  /// 限定清理的作品主键；为空时表示全站所有作品。
  final String? workId;
}

/// 打开图片缓存自定义分类精确清理毛玻璃弹窗。
Future<PhotoCustomCleanupSelection?> showPhotoCustomCleanupDialog(
  BuildContext context, {
  required PhotosCleanupSnapshot snapshot,
}) {
  return showKonataGlassDialog<PhotoCustomCleanupSelection>(
    context: context,
    builder: (_) => _PhotoCustomCleanupDialog(snapshot: snapshot),
  );
}

class _PhotoCustomCleanupDialog extends StatefulWidget {
  const _PhotoCustomCleanupDialog({required this.snapshot});

  final PhotosCleanupSnapshot snapshot;

  @override
  State<_PhotoCustomCleanupDialog> createState() =>
      _PhotoCustomCleanupDialogState();
}

class _PhotoCustomCleanupDialogState extends State<_PhotoCustomCleanupDialog> {
  String? _selectedWorkId;
  final Set<PhotoStorageCategory> _selectedCategories = <PhotoStorageCategory>{
    PhotoStorageCategory.thumbnails,
    PhotoStorageCategory.scans,
  };

  int _computeSelectedBytes() {
    if (_selectedCategories.isEmpty) {
      return 0;
    }
    var sum = 0;
    if (_selectedWorkId == null) {
      for (final cat in _selectedCategories) {
        sum += widget.snapshot.globalStats.byCategory[cat.toSubfolder()]?.bytes ??
            0;
      }
      return sum;
    }
    final match = widget.snapshot.workEntries
        .where((e) => e.workId == _selectedWorkId)
        .firstOrNull;
    if (match == null) {
      return 0;
    }
    for (final cat in _selectedCategories) {
      sum += match.byCategory[cat]?.bytes ?? 0;
    }
    return sum;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<KonataPalette>()!;
    final workEntries = widget.snapshot.workEntries;
    final estimateBytes = _computeSelectedBytes();

    return KonataGlassDialog(
      title: '自定义精确清理图片缓存',
      width: 500,
      actions: [
        KonataPillButton.ghost(
          label: '取消',
          compact: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
        KonataPillButton.danger(
          label: '确认清理 (${PhotosCleanupScanner.formatBytes(estimateBytes)})',
          compact: true,
          onPressed: _selectedCategories.isEmpty
              ? null
              : () => Navigator.of(context).pop(
                  PhotoCustomCleanupSelection(
                    categories: Set<PhotoStorageCategory>.of(
                      _selectedCategories,
                    ),
                    workId: _selectedWorkId,
                  ),
                ),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '清理范围',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: tokens.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 120,
            child: ListView(
              shrinkWrap: true,
              children: [
                _ScopeOptionRow(
                  label: '全站所有作品目录 (${workEntries.length} 个作品目录)',
                  selected: _selectedWorkId == null,
                  tokens: tokens,
                  onTap: () => setState(() => _selectedWorkId = null),
                ),
                for (final entry in workEntries)
                  _ScopeOptionRow(
                    label:
                        '${entry.displayTitle}${entry.isOrphan ? ' [孤儿目录]' : ''} · ${PhotosCleanupScanner.formatBytes(entry.totalBytes)}',
                    selected: _selectedWorkId == entry.workId,
                    tokens: tokens,
                    onTap: () => setState(() => _selectedWorkId = entry.workId),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Divider(height: 1, color: tokens.hairline),
          const SizedBox(height: 12),
          Text(
            '勾选需要清理的图片类别',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: tokens.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          for (final category in PhotoStorageCategory.values)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                setState(() {
                  if (!_selectedCategories.add(category)) {
                    _selectedCategories.remove(category);
                  }
                });
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Checkbox(
                      value: _selectedCategories.contains(category),
                      onChanged: (_) {
                        setState(() {
                          if (!_selectedCategories.add(category)) {
                            _selectedCategories.remove(category);
                          }
                        });
                      },
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        category.displayLabel,
                        style: TextStyle(
                          fontSize: 13,
                          color: tokens.textPrimary,
                        ),
                      ),
                    ),
                    Text(
                      category.isRegenerable ? '可再生' : '刮削核心图',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: category.isRegenerable
                            ? tokens.accent
                            : tokens.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ScopeOptionRow extends StatelessWidget {
  const _ScopeOptionRow({
    required this.label,
    required this.selected,
    required this.tokens,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final KonataPalette tokens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? tokens.accent.withValues(alpha: 0.14)
              : tokens.softFill,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? tokens.accent : tokens.hairline,
            width: 0.8,
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_off_rounded,
              size: 16,
              color: selected ? tokens.accent : tokens.textMuted,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: tokens.textPrimary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
