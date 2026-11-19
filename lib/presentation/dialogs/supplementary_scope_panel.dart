import 'package:flutter/material.dart';

import '../../application/providers/library_providers.dart';
import '../../application/providers/work_split_and_series_actions.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/models/series_group.dart';
import '../../domain/models/work.dart';
import '../theme/konata_palette.dart';
import '../widgets/design_system/adaptive_responsive_row.dart';
import '../widgets/design_system/ellipsis_text_with_tooltip.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_dropdown.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_segmented_capsule.dart';
import '../widgets/design_system/konata_soft_text_field.dart';
import '../theme/konata_theme.dart';

/// 附属资源（特典 / CD / Scan）作用域草稿行状态。
class SupplementaryScopeDraft {
  /// 创建附属资源共享范围草稿。
  SupplementaryScopeDraft({required this.item})
    : scope = item.variant.assetScope,
      ownerWorkId = item.ownerWorkId;

  /// 原始附属资源项。
  final SupplementaryEditableItem item;

  /// 编辑中的系列共享范围。
  SupplementaryAssetScope scope;

  /// 编辑中的归属目标作品 ID。
  String ownerWorkId;

  /// 是否相对数据库原始记录产生变更。
  bool get isModified =>
      scope != item.variant.assetScope || ownerWorkId != item.ownerWorkId;

  /// 转换为持久化的编辑提交请求。
  SupplementaryScopeEdit toEdit() => SupplementaryScopeEdit(
    variantId: item.variant.id,
    scope: scope,
    targetWorkId: ownerWorkId,
  );
}

enum _SuppFilterKind { all, extra, cd, scan }

/// 「手动编辑 -> 附属共享」分类筛选 + 叶子子目录默认折叠批量控制面板。
class SupplementaryScopePanel extends StatefulWidget {
  /// 创建附属共享面板。
  const SupplementaryScopePanel({
    super.key,
    required this.drafts,
    required this.seriesMembers,
    required this.saving,
    required this.onChanged,
    required this.onOpenSeriesManage,
  });

  /// 全部可编辑的附属资源草稿列表。
  final List<SupplementaryScopeDraft> drafts;

  /// 同系列全部作品成员列表。
  final List<Work> seriesMembers;

  /// 外部弹窗是否正在提交保存。
  final bool saving;

  /// 任意条目或整夹作用域变更通知。
  final VoidCallback onChanged;

  /// 系列成员不足 2 部时跳转「管理系列编组」回调。
  final VoidCallback onOpenSeriesManage;

  @override
  State<SupplementaryScopePanel> createState() =>
      _SupplementaryScopePanelState();
}

class _SupplementaryScopePanelState extends State<SupplementaryScopePanel> {
  final ScrollController _listCtrl = ScrollController();
  final TextEditingController _searchCtrl = TextEditingController();
  final Set<String> _expandedGroups = <String>{};
  _SuppFilterKind _filterKind = _SuppFilterKind.all;
  String _query = '';

  @override
  void dispose() {
    _listCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  _SuppFilterKind _kindOf(SupplementaryScopeDraft d) => switch (d.item.variant.assetKind) {
    AssetKind.video => _SuppFilterKind.extra,
    AssetKind.cdAlbum => _SuppFilterKind.cd,
    AssetKind.scanGallery => _SuppFilterKind.scan,
  };

  String _kindLabel(AssetKind kind) => switch (kind) {
    AssetKind.video => '特典',
    AssetKind.cdAlbum => 'CD',
    AssetKind.scanGallery => 'Scan',
  };

  String _leafDirPath(String relativePath) {
    final norm = relativePath.replaceAll('\\', '/');
    final idx = norm.lastIndexOf('/');
    if (idx <= 0) return '(根目录)';
    return norm.substring(0, idx);
  }

  String _shortDirLabel(String fullDir) {
    final segs = fullDir.split('/').where((s) => s.isNotEmpty).toList();
    if (segs.length <= 2) return fullDir;
    return segs.sublist(segs.length - 2).join('/');
  }

  String _memberLabel(Work w, [int? fallbackOrder]) {
    return SeriesLabelPresets.formatDisambiguatedMemberLabel(
      w,
      widget.seriesMembers,
      fallbackOrder: fallbackOrder,
    );
  }

  String _draftValue(SupplementaryScopeDraft d) {
    if (d.scope == SupplementaryAssetScope.seriesShared) {
      return 'shared';
    }
    return 'exclusive::${d.ownerWorkId}';
  }

  String _groupDropdownValue(List<SupplementaryScopeDraft> items) {
    final first = _draftValue(items.first);
    for (final item in items.skip(1)) {
      if (_draftValue(item) != first) return 'mixed';
    }
    return first;
  }

  void _applyDropdownValue(SupplementaryScopeDraft d, String val) {
    if (val == 'shared') {
      d.scope = SupplementaryAssetScope.seriesShared;
    } else if (val.startsWith('exclusive::')) {
      d.scope = SupplementaryAssetScope.workExclusive;
      d.ownerWorkId = val.substring('exclusive::'.length);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    if (widget.drafts.isEmpty) {
      return Center(
        child: Text(
          '当前作品暂未检测到特典、CD 或 Scan 附属条目。',
          textAlign: TextAlign.center,
          style: TextStyle(color: p.textSecondary, fontSize: KonataTheme.fontSizeBodySm),
        ),
      );
    }
    if (widget.seriesMembers.length < 2) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '当前作品尚未编入多部作品系列，无法区分「全系列共享」与「单作独享」。',
              style: TextStyle(color: p.textSecondary, fontSize: KonataTheme.fontSizeBodySm),
            ),
            const SizedBox(height: 12),
            KonataPillButton.secondary(
              label: '去「管理系列编组」添加关联季度',
              icon: Icons.layers_rounded,
              compact: true,
              onPressed: widget.saving ? null : widget.onOpenSeriesManage,
            ),
          ],
        ),
      );
    }

    final extraCount = widget.drafts
        .where((d) => d.item.variant.assetKind == AssetKind.video)
        .length;
    final cdCount = widget.drafts
        .where((d) => d.item.variant.assetKind == AssetKind.cdAlbum)
        .length;
    final scanCount = widget.drafts
        .where((d) => d.item.variant.assetKind == AssetKind.scanGallery)
        .length;

    final q = _query.trim().toLowerCase();
    final filtered = widget.drafts.where((d) {
      if (_filterKind != _SuppFilterKind.all && _kindOf(d) != _filterKind) {
        return false;
      }
      if (q.isEmpty) return true;
      return d.item.variant.relativePath.toLowerCase().contains(q) ||
          d.item.variant.fileName.toLowerCase().contains(q);
    }).toList(growable: false);

    // 按叶子父子目录分组（默认全折叠）
    final grouped = <String, List<SupplementaryScopeDraft>>{};
    for (final d in filtered) {
      final dir = _leafDirPath(d.item.variant.relativePath);
      final groupKey = '${d.item.variant.assetKind.name}::$dir';
      grouped.putIfAbsent(groupKey, () => <SupplementaryScopeDraft>[]).add(d);
    }
    final groupEntries = grouped.entries.toList(growable: false);

    final baseOptions = <KonataDropdownOption<String>>[
      const KonataDropdownOption(
        value: 'shared',
        label: '全系列共用',
        subtitle: '同一系列内各作品详情页均可查看',
      ),
      for (var i = 0; i < widget.seriesMembers.length; i++)
        KonataDropdownOption(
          value: 'exclusive::${widget.seriesMembers[i].id}',
          label: '仅「${_memberLabel(widget.seriesMembers[i], i + 1)}」独享',
          subtitle: '仅在指定成员详情页显示',
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: MediaQuery.withClampedTextScaling(
                maxScaleFactor: 1.15,
                child: KonataSegmentedCapsule<_SuppFilterKind>(
                  compact: true,
                  selected: _filterKind,
                  options: [
                    KonataSegmentOption(
                      value: _SuppFilterKind.all,
                      label: '全部 (${widget.drafts.length})',
                    ),
                    if (extraCount > 0)
                      KonataSegmentOption(
                        value: _SuppFilterKind.extra,
                        label: '特典 ($extraCount)',
                      ),
                    if (cdCount > 0)
                      KonataSegmentOption(
                        value: _SuppFilterKind.cd,
                        label: 'CD ($cdCount)',
                      ),
                    if (scanCount > 0)
                      KonataSegmentOption(
                        value: _SuppFilterKind.scan,
                        label: 'Scan ($scanCount)',
                      ),
                  ],
                  onChanged: (k) => setState(() => _filterKind = k),
                ),
              ),
            ),
            SizedBox(
              width: 196,
              child: KonataSoftTextField(
                controller: _searchCtrl,
                dense: true,
                hintText: '过滤目录或文件名...',
                prefixIcon: Icons.search_rounded,
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: groupEntries.isEmpty
              ? Center(
                  child: Text(
                    '暂无匹配的附属目录资源',
                    style: TextStyle(color: p.textSecondary, fontSize: KonataTheme.fontSizeBodySm),
                  ),
                )
              : KonataDraggableScrollbar(
                  controller: _listCtrl,
                  builder: (_, ctrl) => ListView.separated(
                    controller: ctrl,
                    padding: const EdgeInsets.only(right: 14),
                    itemCount: groupEntries.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (_, index) {
                      final entry = groupEntries[index];
                      final groupKey = entry.key;
                      final items = entry.value;
                      final isExpanded = _expandedGroups.contains(groupKey);
                      final firstVariant = items.first.item.variant;
                      final fullDir = _leafDirPath(firstVariant.relativePath);
                      final shortDir = _shortDirLabel(fullDir);
                      final groupVal = _groupDropdownValue(items);
                      final groupOptions = groupVal == 'mixed'
                          ? <KonataDropdownOption<String>>[
                              const KonataDropdownOption(
                                value: 'mixed',
                                label: '混合归属（点此统一）',
                              ),
                              ...baseOptions,
                            ]
                          : baseOptions;

                      return Container(
                        decoration: BoxDecoration(
                          color: p.softFill,
                          borderRadius: KonataTheme.borderRadiusControl,
                          border: Border.all(color: p.hairline),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                              child: AdaptiveResponsiveRow(
                                minLeadingWidth: 160,
                                estimatedTrailingWidth: 188,
                                expandTrailingWhenStacked: true,
                                leading: Row(
                                  children: [
                                    InkWell(
                                      borderRadius: KonataTheme.borderRadiusChip,
                                      onTap: () => setState(() {
                                        if (!_expandedGroups.remove(groupKey)) {
                                          _expandedGroups.add(groupKey);
                                        }
                                      }),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 4,
                                          vertical: 4,
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              isExpanded
                                                  ? Icons
                                                        .keyboard_arrow_down_rounded
                                                  : Icons
                                                        .keyboard_arrow_right_rounded,
                                              size: 18,
                                              color: p.textSecondary,
                                            ),
                                            const SizedBox(width: 4),
                                            _KindMiniTag(
                                              label: _kindLabel(
                                                firstVariant.assetKind,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: InkWell(
                                        borderRadius: KonataTheme.borderRadiusChip,
                                        onTap: () => setState(() {
                                          if (!_expandedGroups.remove(
                                            groupKey,
                                          )) {
                                            _expandedGroups.add(groupKey);
                                          }
                                        }),
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 2,
                                          ),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              EllipsisTextWithTooltip(
                                                text: shortDir,
                                                tooltipMessage: fullDir,
                                                maxLines: 1,
                                                style: TextStyle(
                                                  color: p.textPrimary,
                                                  fontSize: KonataTheme.fontSizeBodyXs,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                              const SizedBox(height: 1),
                                              Text(
                                                '${items.length} 个文件 · ${_scopeSummaryText(groupVal, items)}',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: p.textMuted,
                                                  fontSize: KonataTheme.fontSizeCaptionXs,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                trailing: SizedBox(
                                  width: 188,
                                  child: KonataDropdown<String>(
                                    dense: true,
                                    enabled: !widget.saving,
                                    value: groupVal,
                                    options: groupOptions,
                                    onChanged: (next) {
                                      if (next == 'mixed') return;
                                      setState(() {
                                        for (final d in items) {
                                          _applyDropdownValue(d, next);
                                        }
                                      });
                                      widget.onChanged();
                                    },
                                  ),
                                ),
                              ),
                            ),
                            if (isExpanded) ...[
                              Divider(height: 1, color: p.hairline),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  24,
                                  6,
                                  10,
                                  8,
                                ),
                                child: Column(
                                  children: [
                                    for (final d in items)
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 4,
                                        ),
                                        child: AdaptiveResponsiveRow(
                                          minLeadingWidth: 140,
                                          estimatedTrailingWidth: 180,
                                          expandTrailingWhenStacked: true,
                                          leading: EllipsisTextWithTooltip(
                                            text: d.item.variant.fileName,
                                            tooltipMessage:
                                                d.item.variant.relativePath,
                                            maxLines: 1,
                                            style: TextStyle(
                                              color: p.textSecondary,
                                              fontSize: KonataTheme.fontSizeCaption,
                                            ),
                                          ),
                                          trailing: SizedBox(
                                            width: 180,
                                            child: KonataDropdown<String>(
                                              dense: true,
                                              enabled: !widget.saving,
                                              value: _draftValue(d),
                                              options: baseOptions,
                                              onChanged: (next) {
                                                setState(
                                                  () => _applyDropdownValue(
                                                    d,
                                                    next,
                                                  ),
                                                );
                                                widget.onChanged();
                                              },
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }

  String _scopeSummaryText(
    String groupVal,
    List<SupplementaryScopeDraft> items,
  ) {
    if (groupVal == 'shared') return '当前全系列共用';
    if (groupVal == 'mixed') return '目录内含多种归属设置';
    final ownerId = groupVal.substring('exclusive::'.length);
    final ownerIdx = widget.seriesMembers.indexWhere((m) => m.id == ownerId);
    if (ownerIdx >= 0) {
      return '仅「${_memberLabel(widget.seriesMembers[ownerIdx], ownerIdx + 1)}」独享';
    }
    return '仅「${items.first.item.ownerLabel}」独享';
  }
}

class _KindMiniTag extends StatelessWidget {
  const _KindMiniTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: p.accent.withValues(alpha: 0.14),
        borderRadius: KonataTheme.borderRadiusChipSm,
        border: Border.all(color: p.accent.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: p.accent,
          fontSize: KonataTheme.fontSizeBadge,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
