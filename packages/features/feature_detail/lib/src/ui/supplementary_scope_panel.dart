import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/detail_edit_models.dart';

/// 附属资源（特典 / CD / 扫图）可见作用域可变草稿条目。
class SupplementaryScopeDraft {
  /// 创建附属资源作用域草稿条目。
  SupplementaryScopeDraft({required this.item})
    : initialScope = item.variant.assetScope,
      initialOwnerWorkId = item.variant.workId,
      scope = item.variant.assetScope,
      ownerWorkId = item.variant.workId;

  /// 原始附属条目上下文。
  final SupplementaryEditableItem item;

  /// 初始作用域。
  final SupplementaryAssetScope initialScope;

  /// 初始归属作品主键。
  final String initialOwnerWorkId;

  /// 当前编辑态作用域。
  SupplementaryAssetScope scope;

  /// 当前编辑态独享归属作品主键。
  String ownerWorkId;

  /// 相对初始状态是否已发生变更。
  bool get isModified =>
      scope != initialScope ||
      (scope == SupplementaryAssetScope.workExclusive &&
          ownerWorkId != initialOwnerWorkId);
}

enum _SuppFilterKind { all, extra, cd, scan }

/// 附属资源（特典 / CD / Scan）按目录或单条设置「全系列共享 / 指定季度独享」面板。
class SupplementaryScopePanel extends StatefulWidget {
  /// 创建附属资源共享范围管理面板。
  const SupplementaryScopePanel({
    super.key,
    required this.drafts,
    required this.seriesMembers,
    required this.saving,
    required this.onChanged,
    required this.onOpenSeriesManage,
  });

  /// 全部可编辑附属条目草稿列表。
  final List<SupplementaryScopeDraft> drafts;

  /// 同系列成员列表。
  final List<Work> seriesMembers;

  /// 是否处于异步保存中。
  final bool saving;

  /// 任一条目范围变更回调。
  final VoidCallback onChanged;

  /// 打开「管理系列编组」弹窗回调。
  final VoidCallback onOpenSeriesManage;

  @override
  State<SupplementaryScopePanel> createState() =>
      _SupplementaryScopePanelState();
}

class _SupplementaryScopePanelState extends State<SupplementaryScopePanel> {
  final TextEditingController _searchCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  _SuppFilterKind _filterKind = _SuppFilterKind.all;
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  _SuppFilterKind _kindOf(SupplementaryScopeDraft d) =>
      switch (d.item.variant.assetKind) {
        AssetKind.video => _SuppFilterKind.extra,
        AssetKind.cdAlbum => _SuppFilterKind.cd,
        AssetKind.scanGallery => _SuppFilterKind.scan,
      };

  String _kindBadgeLabel(AssetKind kind) => switch (kind) {
    AssetKind.video => '特典',
    AssetKind.cdAlbum => 'CD',
    AssetKind.scanGallery => '扫图',
  };

  String _memberLabel(Work w, int fallbackOrder) {
    return SeriesSeasonFormatter.formatMemberLabel(
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

  void _applyValue(SupplementaryScopeDraft d, String value) {
    if (value == 'shared') {
      d.scope = SupplementaryAssetScope.seriesShared;
    } else if (value.startsWith('exclusive::')) {
      d.scope = SupplementaryAssetScope.workExclusive;
      d.ownerWorkId = value.substring('exclusive::'.length);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    if (widget.drafts.isEmpty) {
      return Center(
        child: Text(
          '当前作品暂未检测到特典、CD 或扫图附属条目。',
          textAlign: TextAlign.center,
          style: KonataTheme.bodyLabelStyle(p, color: p.textSecondary),
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
              textAlign: TextAlign.center,
              style: KonataTheme.bodyLabelStyle(p, color: p.textSecondary),
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

    final q = _query.trim().toLowerCase();
    final filtered = widget.drafts
        .where((d) {
          if (_filterKind != _SuppFilterKind.all && _kindOf(d) != _filterKind) {
            return false;
          }
          if (q.isEmpty) return true;
          return d.item.variant.relativePath.toLowerCase().contains(q) ||
              d.item.variant.fileName.toLowerCase().contains(q);
        })
        .toList(growable: false);

    final options = <KonataDropdownOption<String>>[
      const KonataDropdownOption<String>(
        value: 'shared',
        label: '全系列共享（所有季度可见）',
      ),
      for (var i = 0; i < widget.seriesMembers.length; i++)
        KonataDropdownOption<String>(
          value: 'exclusive::${widget.seriesMembers[i].id}',
          label: '仅归属 · ${_memberLabel(widget.seriesMembers[i], i + 1)}',
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: KonataSoftTextField(
                controller: _searchCtrl,
                dense: true,
                prefixIcon: Icons.search_rounded,
                hintText: '筛选特典、CD 或扫图目录路径...',
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            const SizedBox(width: 8),
            KonataSegmentedCapsule<_SuppFilterKind>(
              compact: true,
              selected: _filterKind,
              onChanged: (next) => setState(() => _filterKind = next),
              options: const [
                KonataSegmentOption(value: _SuppFilterKind.all, label: '全部'),
                KonataSegmentOption(
                  value: _SuppFilterKind.extra,
                  label: '特典',
                ),
                KonataSegmentOption(value: _SuppFilterKind.cd, label: 'CD'),
                KonataSegmentOption(value: _SuppFilterKind.scan, label: '扫图'),
              ],
            ),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Text(
                    '暂无符合条件的附属条目',
                    style: KonataTheme.bodyLabelStyle(
                      p,
                      color: p.textSecondary,
                    ),
                  ),
                )
              : KonataDraggableScrollbar(
                  controller: _scrollCtrl,
                  builder: (_, ctrl) => ListView.separated(
                    controller: ctrl,
                    itemCount: filtered.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (_, index) {
                      final draft = filtered[index];
                      final variant = draft.item.variant;
                      return KonataSurfaceCard(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        borderColor: draft.isModified ? p.accent : null,
                        child: Row(
                          children: [
                            KonataSpecBadge(
                              label: _kindBadgeLabel(variant.assetKind),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    variant.fileName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: KonataTheme.bodyLabelStyle(
                                      p,
                                      fontSize: KonataTheme.fontSizeCaption,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    variant.relativePath,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: KonataTheme.captionStyle(p).copyWith(
                                      color: p.textMuted,
                                      fontSize: KonataTheme.fontSizeCaptionXs,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 10),
                            SizedBox(
                              width: 210,
                              child: KonataDropdown<String>(
                                value: _draftValue(draft),
                                dense: true,
                                enabled: !widget.saving,
                                options: options,
                                onChanged: (next) {
                                  setState(() => _applyValue(draft, next));
                                  widget.onChanged();
                                },
                              ),
                            ),
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
}
