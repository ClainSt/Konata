import 'package:flutter/widgets.dart';
import 'package:konata_contracts/konata_contracts.dart';

import 'ui/settings_external_tools_panel.dart';
import 'ui/settings_players_panel.dart';

/// 视频播放器业务包声明式模块清单。
///
/// 注册跨平台播放器设置分区、Windows 桌面专属外部工具设置分区。
final FeatureManifest featurePlayerVideoManifest = FeatureManifest(
  id: 'feature_player_video',
  displayName: '视频播放与悬浮小窗',
  settingsSections: <SettingsSectionContribution>[
    SettingsSectionContribution(
      id: 'playback_settings',
      title: '播放与解码',
      subtitle: '画质滤镜、硬件解码、着色器与音画输出策略',
      iconKey: 'player',
      order: 30,
      supportedPlatforms: allKonataPlatforms,
      viewBuilder: (slot) => const SettingsPlayersPanel(
        key: ValueKey('manifest_settings_players_panel'),
      ),
    ),
    SettingsSectionContribution(
      id: 'external_tools',
      title: '外部调用',
      subtitle: '配置桌面端外部播放器路径与远程进度同步服务',
      iconKey: 'tune',
      order: 40,
      supportedPlatforms: <KonataPlatform>{KonataPlatform.windows},
      viewBuilder: (slot) => const SettingsExternalToolsPanel(
        key: ValueKey('manifest_settings_external_tools_panel'),
      ),
    ),
  ],
);
