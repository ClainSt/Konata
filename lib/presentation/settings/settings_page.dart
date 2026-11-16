import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio/mini_audio_bar.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_page_header.dart';
import '../widgets/design_system/konata_segmented_capsule.dart';
import 'settings_about_panel.dart';
import 'settings_appearance_panel.dart';
import 'settings_display_panel.dart';
import 'settings_external_tools_panel.dart';
import 'settings_network_panel.dart';
import 'settings_players_panel.dart';

/// 设置页左侧分类标签。
enum SettingsCategory {
  appearance('外观', Icons.palette_outlined),
  display('显示', Icons.tune_rounded),
  network('刮削与网络', Icons.public_rounded),
  player('播放器', Icons.play_circle_outline_rounded),
  externalTools('外部调用', Icons.open_in_new_rounded),
  about('关于', Icons.info_outline_rounded);

  const SettingsCategory(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// 双栏布局设置页面（统一一级页头 + 左侧无框分类导航 + 右侧自适应全宽铺展面板）。
class SettingsPage extends ConsumerStatefulWidget {
  /// 创建设置页面。
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final ScrollController _contentCtrl = ScrollController();
  SettingsCategory _selected = SettingsCategory.appearance;

  @override
  void dispose() {
    _contentCtrl.dispose();
    super.dispose();
  }

  void _selectCategory(SettingsCategory category) {
    if (_selected == category) return;
    setState(() => _selected = category);
    if (_contentCtrl.hasClients) {
      _contentCtrl.jumpTo(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomClearance = KonataBottomClearanceScope.resolve(context, ref);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const KonataPageHeader(title: '设置'),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(
                  left: KonataTheme.pageHorizontalPadding,
                  bottom: 24,
                ),
                child: SizedBox(
                  width: 220,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final category in SettingsCategory.values) ...[
                        _CategoryNavItem(
                          label: category.label,
                          icon: category.icon,
                          selected: _selected == category,
                          onTap: () => _selectCategory(category),
                        ),
                        const SizedBox(height: 4),
                      ],
                    ],
                  ),
                ),
              ),
              Expanded(
                child: KonataDraggableScrollbar(
                  controller: _contentCtrl,
                  builder: (_, ctrl) => SingleChildScrollView(
                    controller: ctrl,
                    padding: EdgeInsets.fromLTRB(
                      40,
                      0,
                      KonataTheme.pageHorizontalPadding,
                      32 + bottomClearance,
                    ),
                    child: KonataSmoothSectionSwitcher(
                      switchKey: _selected,
                      alignment: Alignment.topLeft,
                      child: switch (_selected) {
                        SettingsCategory.appearance =>
                          const SettingsAppearancePanel(),
                        SettingsCategory.display =>
                          const SettingsDisplayPanel(),
                        SettingsCategory.network =>
                          const SettingsNetworkPanel(),
                        SettingsCategory.player =>
                          const SettingsPlayersPanel(),
                        SettingsCategory.externalTools =>
                          const SettingsExternalToolsPanel(),
                        SettingsCategory.about => const SettingsAboutPanel(),
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CategoryNavItem extends StatefulWidget {
  const _CategoryNavItem({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_CategoryNavItem> createState() => _CategoryNavItemState();
}

class _CategoryNavItemState extends State<_CategoryNavItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final bgColor = widget.selected
        ? p.softFill
        : (_hovered ? p.softFill.withValues(alpha: 0.45) : Colors.transparent);
    final fgColor = widget.selected
        ? p.textPrimary
        : (_hovered ? p.textPrimary.withValues(alpha: 0.85) : p.textSecondary);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: KonataTheme.standardTransition,
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 20, color: fgColor),
              const SizedBox(width: 12),
              Text(
                widget.label,
                style: KonataTheme.textStyle(
                  color: fgColor,
                  fontSize: 14.5,
                  weight: widget.selected
                      ? KonataTheme.weightActive
                      : KonataTheme.weightRegularLabel,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
