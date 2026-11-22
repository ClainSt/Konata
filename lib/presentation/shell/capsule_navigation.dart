import 'package:material_ui/material_ui.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/konata_glass_capsule.dart';
import '../widgets/playback/konata_playback_capsule.dart';

/// 四主页面的紧凑悬浮导航，横竖排共用同一组触控入口。
class CapsuleNavigation extends StatelessWidget {
  const CapsuleNavigation({
    super.key,
    required this.vertical,
    required this.selectedIndex,
    required this.onSelected,
  });
  final bool vertical;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  @override
  Widget build(BuildContext context) {
    const items = [
      (Icons.video_library_outlined, '媒体库'),
      (Icons.folder_open_rounded, '媒体源'),
      (Icons.history_rounded, '播放记录'),
      (Icons.settings_outlined, '设置'),
    ];
    final p = context.palette;
    final canvasColor = p.isDark
        ? KonataTheme.cinemaObsidian
        : KonataTheme.themePreviewLightCanvas;
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.15,
      child: KonataGlassCapsule(
        // 平板左侧纵排胶囊处于独立纯色避让带采用像素等价预混；
        // 手机底部横排胶囊保持跨端同源实时毛玻璃，由紧贴胶囊尺寸的 ClipRRect
        // 将离屏模糊采样严格约束在胶囊局部包围盒内，并由外层 RepaintBoundary 与内容区隔离。
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
            children: [
              for (var i = 0; i < items.length; i++) ...[
                if (vertical && i > 0)
                  const SizedBox(height: KonataAdaptiveTokens.tabletNavItemGap),
                Semantics(
                  selected: selectedIndex == i,
                  button: true,
                  label: items[i].$2,
                  child: KonataCapsuleIconButton(
                    icon: items[i].$1,
                    tooltip: items[i].$2,
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
