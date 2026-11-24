import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../providers.dart';
import '../state/settings_controller.dart';
import 'settings_shared_widgets.dart';

/// 外观与界面显示通用设置面板（纯设计系统组件实现）。
class SettingsAppearancePanel extends ConsumerWidget {
  /// 创建外观与显示面板。
  const SettingsAppearancePanel({super.key, this.controller});

  /// 可选直传设置控制器；为空时从 [settingsControllerProvider] 获取。
  final SettingsController? controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final direct = controller;
    final SettingsController effectiveController =
        direct ?? ref.watch(settingsControllerProvider);
    final tokens = Theme.of(context).extension<KonataPalette>()!;

    return AnimatedBuilder(
      animation: effectiveController,
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            KonataSurfaceCard(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SettingsSectionHeader(
                    icon: Icons.palette_outlined,
                    title: '主题外观',
                    subtitle: '支持纯暗黑、柔亮及跟随系统主题切换，变更会实时保存并通知界面刷新',
                  ),
                  const SizedBox(height: 16),
                  KonataSegmentedCapsule<ThemeMode>(
                    selected: effectiveController.themeMode,
                    onChanged: effectiveController.setThemeMode,
                    options: const [
                      KonataSegmentOption(
                        value: ThemeMode.dark,
                        label: '深色模式',
                        icon: Icons.dark_mode_outlined,
                      ),
                      KonataSegmentOption(
                        value: ThemeMode.light,
                        label: '浅色模式',
                        icon: Icons.light_mode_outlined,
                      ),
                      KonataSegmentOption(
                        value: ThemeMode.system,
                        label: '跟随系统',
                        icon: Icons.brightness_auto_outlined,
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Divider(height: 1, color: tokens.hairline),
                  const SizedBox(height: 16),
                  SettingsSwitchTile(
                    title: '启用柔和流光氛围背景',
                    subtitle: '在桌面与大屏容器底色叠加热门冷暖流光光晕（性能不足设备可随时关闭）',
                    value: effectiveController.ambientBackdropEnabled,
                    onChanged: effectiveController.setAmbientBackdropEnabled,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
