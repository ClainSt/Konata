import 'package:flutter/material.dart';
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
        // 平板左侧纵排胶囊处于独立纯色避让带，像素等价预混省去全幅离屏模糊拷贝；
        // 手机底部横排胶囊悬浮于滚动内容上方，保留实时底层毛玻璃模糊。
        enableBackdropBlur: !vertical,
        solidBackdropColor: vertical ? canvasColor : null,
        child: Padding(
          padding: const EdgeInsets.all(KonataAdaptiveTokens.navigationPadding),
          child: Flex(
            direction: vertical ? Axis.vertical : Axis.horizontal,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < items.length; i++)
                Semantics(
                  selected: selectedIndex == i,
                  button: true,
                  label: items[i].$2,
                  child: KonataCapsuleIconButton(
                    icon: items[i].$1,
                    tooltip: items[i].$2,
                    fixedSize: KonataAdaptiveTokens.touchTarget,
                    highlighted: selectedIndex == i,
                    color: p.textPrimary,
                    onTap: () => onSelected(i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
