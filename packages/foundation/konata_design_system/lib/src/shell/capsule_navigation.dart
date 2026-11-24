import 'package:material_ui/material_ui.dart';

import '../tokens/konata_adaptive_tokens.dart';
import '../tokens/konata_palette.dart';
import '../tokens/konata_theme.dart';
import '../widgets/konata_capsule_icon_button.dart';
import '../widgets/konata_glass_capsule.dart';

/// 主导航项轻量描述符（桌面顶栏与移动胶囊共用，支持由扩展点动态映射）。
@immutable
class KonataNavItem {
  /// 创建主导航项描述符。
  const KonataNavItem({
    required this.id,
    required this.label,
    required this.icon,
  });

  /// 稳定导航分区标识（如 `library`、`sources`、`history`、`settings`）。
  final String id;

  /// 中文导航展示名称。
  final String label;

  /// 移动端悬浮胶囊显示的图标。
  final IconData icon;

  /// 默认四主页标准导航集合。
  static const List<KonataNavItem> defaults = <KonataNavItem>[
    KonataNavItem(
      id: 'library',
      label: '媒体库',
      icon: Icons.video_library_outlined,
    ),
    KonataNavItem(
      id: 'sources',
      label: '媒体源',
      icon: Icons.folder_open_rounded,
    ),
    KonataNavItem(
      id: 'history',
      label: '播放记录',
      icon: Icons.history_rounded,
    ),
    KonataNavItem(
      id: 'settings',
      label: '设置',
      icon: Icons.settings_outlined,
    ),
  ];
}

/// 移动端紧凑悬浮胶囊导航（平板左竖排 / 手机底横排共用同一组触控入口，热区 `>= 48dp`）。
class CapsuleNavigation extends StatelessWidget {
  /// 创建悬浮胶囊导航。
  const CapsuleNavigation({
    super.key,
    required this.vertical,
    required this.selectedIndex,
    required this.onSelected,
    this.items = KonataNavItem.defaults,
  });

  /// 是否纵向排布（平板左侧悬浮胶囊为 `true`，手机底部悬浮胶囊为 `false`）。
  final bool vertical;

  /// 当前激活项下标。
  final int selectedIndex;

  /// 点击切换回调。
  final ValueChanged<int> onSelected;

  /// 导航条目集合（缺省为标准四主页）。
  final List<KonataNavItem> items;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final canvasColor = p.isDark
        ? KonataTheme.cinemaObsidian
        : KonataTheme.themePreviewLightCanvas;
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.15,
      child: KonataGlassCapsule(
        // 平板左侧纵排胶囊处于独立纯色避让带采用像素等价预混；
        // 手机底部横排胶囊保持跨端同源实时毛玻璃并由紧贴包围盒限制离屏模糊开销。
        enableBackdropBlur: !vertical,
        solidBackdropColor: vertical ? canvasColor : null,
        showShadow: true,
        child: Padding(
          padding: EdgeInsets.all(
            vertical
                ? KonataAdaptiveTokens.tabletNavPadding
                : KonataAdaptiveTokens.navigationPadding,
          ),
          child: Flex(
            direction: vertical ? Axis.vertical : Axis.horizontal,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (var i = 0; i < items.length; i++) ...[
                if (vertical && i > 0)
                  const SizedBox(height: KonataAdaptiveTokens.tabletNavItemGap),
                Semantics(
                  selected: selectedIndex == i,
                  button: true,
                  label: items[i].label,
                  child: KonataCapsuleIconButton(
                    icon: items[i].icon,
                    tooltip: items[i].label,
                    size: vertical
                        ? KonataAdaptiveTokens.tabletNavIconSize
                        : KonataAdaptiveTokens.iconSize,
                    fixedSize: vertical
                        ? KonataAdaptiveTokens.tabletNavItemSize
                        : KonataAdaptiveTokens.touchTarget,
                    highlighted: selectedIndex == i,
                    color: p.textPrimary,
                    onTap: () => onSelected(i),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
