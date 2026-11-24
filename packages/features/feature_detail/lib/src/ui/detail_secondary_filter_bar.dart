import 'package:flutter/widgets.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

/// 详情页底部抽屉内置稳定标签标识常量。
abstract final class DetailDrawerTabIds {
  /// 正片选集标签页标识。
  static const String episodes = 'episodes';

  /// 特典与附加映像标签页标识。
  static const String extras = 'extras';

  /// 音乐 CD 专辑标签页标识。
  static const String cd = 'cd';
}

/// 详情页分集、特典、CD 与动态扩展标签页聚合胶囊切换栏（严格使用设计系统原语）。
class DetailSecondaryFilterBar extends StatelessWidget {
  /// 创建详情页次级标签与筛选胶囊栏。
  const DetailSecondaryFilterBar({
    super.key,
    required this.activeTabId,
    required this.mainEpisodeCount,
    required this.extraEpisodeCount,
    required this.cdCount,
    required this.externalTabs,
    required this.onSelectTab,
    this.subFilterChips = const <({String id, String label, int count})>[],
    this.activeSubFilterId,
    this.onSelectSubFilter,
    this.trailing,
    this.compact = false,
  });

  /// 当前选中的标签页唯一标识。
  final String activeTabId;

  /// 正片剧集数量。
  final int mainEpisodeCount;

  /// 特典数量。
  final int extraEpisodeCount;

  /// 音乐 CD 数量。
  final int cdCount;

  /// 由其他功能包通过 `DetailTabContribution` 注入的可见扩展标签页清单。
  final List<DetailTabContribution> externalTabs;

  /// 切换标签页回调。
  final ValueChanged<String> onSelectTab;

  /// 当前标签下的二级细分筛选筹码列表。
  final List<({String id, String label, int count})> subFilterChips;

  /// 当前选中的二级细分筛选项标识。
  final String? activeSubFilterId;

  /// 二级细分筛选切换回调。
  final ValueChanged<String>? onSelectSubFilter;

  /// 右侧可选追加按钮（如「查看全部」）。
  final Widget? trailing;

  /// 是否紧凑排布。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final options = <({String id, String label, IconData icon, int? count})>[
      if (mainEpisodeCount > 0 || (extraEpisodeCount == 0 && cdCount == 0))
        (
          id: DetailDrawerTabIds.episodes,
          label: '正片',
          icon: KonataIconRegistry.resolve('episodes'),
          count: mainEpisodeCount,
        ),
      if (extraEpisodeCount > 0)
        (
          id: DetailDrawerTabIds.extras,
          label: '特典',
          icon: KonataIconRegistry.resolve('extras'),
          count: extraEpisodeCount,
        ),
      if (cdCount > 0)
        (
          id: DetailDrawerTabIds.cd,
          label: 'CD',
          icon: KonataIconRegistry.resolve('cd'),
          count: cdCount,
        ),
      for (final ext in externalTabs)
        (
          id: ext.id,
          label: ext.label,
          icon: KonataIconRegistry.resolve(ext.iconKey),
          count: null,
        ),
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < options.length; i++) ...[
                      if (i > 0) const SizedBox(width: 8),
                      _TabCapsuleChip(
                        key: ValueKey<String>(
                          'detail_tab_${options[i].id}',
                        ),
                        label: options[i].count != null
                            ? '${options[i].label} ${options[i].count}'
                            : options[i].label,
                        icon: options[i].icon,
                        selected: activeTabId == options[i].id,
                        compact: compact,
                        onTap: () => onSelectTab(options[i].id),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 10),
              trailing!,
            ],
          ],
        ),
        if (subFilterChips.length > 1 && onSelectSubFilter != null) ...[
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < subFilterChips.length; i++) ...[
                  if (i > 0) const SizedBox(width: 6),
                  _SubFilterChip(
                    label:
                        '${subFilterChips[i].label} (${subFilterChips[i].count})',
                    selected: activeSubFilterId == subFilterChips[i].id,
                    palette: p,
                    onTap: () => onSelectSubFilter!(subFilterChips[i].id),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _TabCapsuleChip extends StatefulWidget {
  const _TabCapsuleChip({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.compact,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;

  @override
  State<_TabCapsuleChip> createState() => _TabCapsuleChipState();
}

class _TabCapsuleChipState extends State<_TabCapsuleChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final selected = widget.selected;
    final bg = selected
        ? KonataPlaybackTokens.activePillBg(p)
        : (_hovered
              ? KonataPlaybackTokens.hoverFill(p)
              : KonataPlaybackTokens.glassSurface(p));
    final borderColor = selected
        ? KonataPlaybackTokens.activeGlassBorder(p)
        : KonataPlaybackTokens.glassBorder(p);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: KonataTheme.motionFast,
          height: widget.compact ? 32 : 34,
          padding: EdgeInsets.symmetric(horizontal: widget.compact ? 11 : 13),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: KonataTheme.borderRadiusPill,
            border: Border.all(color: borderColor, width: selected ? 1.2 : 0.9),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                widget.icon,
                size: 14,
                color: selected ? p.accent : p.textSecondary,
              ),
              const SizedBox(width: 6),
              Text(
                widget.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected ? p.textPrimary : p.textSecondary,
                  fontSize: widget.compact
                      ? KonataTheme.fontSizeCaptionSm
                      : KonataTheme.fontSizeCaption,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SubFilterChip extends StatelessWidget {
  const _SubFilterChip({
    required this.label,
    required this.selected,
    required this.palette,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final KonataPalette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: KonataTheme.motionFast,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected
              ? palette.accent.withValues(alpha: 0.18)
              : palette.softFill,
          borderRadius: KonataTheme.borderRadiusPill,
          border: Border.all(
            color: selected
                ? palette.accent.withValues(alpha: 0.6)
                : palette.hairline,
            width: 0.9,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? palette.accent : palette.textSecondary,
            fontSize: KonataTheme.fontSizeBadge,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
