import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/konata_value_notifier.dart';
import '../../composition/platform_composition.dart';
import '../audio/mini_audio_bar.dart';
import '../shell/adaptive_capsule_layout.dart';
import '../widgets/design_system/adaptive_settings_container.dart';
import 'settings_about_panel.dart';
import 'settings_appearance_panel.dart';
import 'settings_backup_sync_panel.dart';
import 'settings_bangumi_sync_card.dart';
import 'settings_display_panel.dart';
import 'settings_network_panel.dart';
import 'settings_players_panel.dart';

/// 设置页左侧分类标签。
enum SettingsCategory {
  appearance('外观', Icons.palette_outlined),
  display('显示', Icons.tune_rounded),
  network('刮削与网络', Icons.public_rounded),
  player('播放器', Icons.play_circle_outline_rounded),
  sync('备份与同步', Icons.sync_rounded),
  externalTools('外部调用', Icons.open_in_new_rounded),
  about('关于', Icons.info_outline_rounded);

  const SettingsCategory(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// 当前激活的设置二级分类 Provider（支持从外部提醒弹窗一键直达「刮削与网络」等面板）。
final selectedSettingsCategoryProvider =
    NotifierProvider<KonataValueNotifier<SettingsCategory>, SettingsCategory>(
      () => KonataValueNotifier<SettingsCategory>.value(
        SettingsCategory.appearance,
      ),
    );

/// 外部深链直达设置子页的脉冲计数器（确保手机端即使目标分类已选中也能主动推入二级页面）。
final settingsDeepLinkPulseProvider =
    NotifierProvider<KonataValueNotifier<int>, int>(
      () => KonataValueNotifier<int>.value(0),
    );

/// 双栏布局设置页面（统一一级页头 + 左侧无框分类导航 + 右侧自适应全宽铺展面板）。
class SettingsPage extends ConsumerStatefulWidget {
  /// 创建设置页面。
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  @override
  Widget build(BuildContext context) {
    final selected = ref.watch(selectedSettingsCategoryProvider);
    final deepLinkPulse = ref.watch(settingsDeepLinkPulseProvider);
    final externalToolsBuilder = ref.watch(
      desktopExternalToolsPanelBuilderProvider,
    );
    final navigation = ref.read(capsuleNavigationHiddenProvider.notifier);
    return AdaptiveSettingsContainer<SettingsCategory>(
      selected: selected,
      deepLinkPulse: deepLinkPulse,
      onSelected: (value) =>
          ref.read(selectedSettingsCategoryProvider.notifier).state = value,
      onDetailVisibilityChanged: (value) => navigation.state = value,
      bottomClearance: KonataBottomClearanceScope.resolve(context, ref),
      categories: [
        for (final category in SettingsCategory.values)
          AdaptiveSettingsCategory(
            value: category,
            icon: category.icon,
            title: category.label,
            summary: switch (category) {
              SettingsCategory.appearance => '主题模式与视觉偏好',
              SettingsCategory.display => '作品展示与图片缓存',
              SettingsCategory.network => '元数据服务与网络连接',
              SettingsCategory.player => '播放与音画参数',
              SettingsCategory.sync => '本地备份、多设备同步与 Bangumi 进度',
              SettingsCategory.externalTools => '桌面外部程序与路径',
              SettingsCategory.about => '版本、诊断日志与项目资料',
            },
            desktopOnly: category == SettingsCategory.externalTools,
            panel: (ctx) => switch (category) {
              SettingsCategory.appearance => const SettingsAppearancePanel(),
              SettingsCategory.display => const SettingsDisplayPanel(),
              SettingsCategory.network => const SettingsNetworkPanel(),
              SettingsCategory.player => const SettingsPlayersPanel(),
              SettingsCategory.sync => const SettingsBackupSyncPanel(
                extraSection: SettingsBangumiSyncCard(),
              ),
              SettingsCategory.externalTools =>
                externalToolsBuilder?.call(ctx) ?? const SizedBox.shrink(),
              SettingsCategory.about => const SettingsAboutPanel(),
            },
          ),
      ],
    );
  }
}
