import 'package:flutter/foundation.dart' show ValueChanged;
import 'package:konata_contracts/konata_contracts.dart';

import 'ui/settings_about_panel.dart';
import 'ui/settings_appearance_panel.dart';
import 'ui/settings_network_panel.dart';
import 'ui/settings_page.dart';
import 'ui/settings_photos_storage_card.dart';

/// 通用设置容器及四项通用设置分区的声明式注册清单。
final FeatureManifest featureSettingsManifest = FeatureManifest(
  id: 'feature_settings',
  displayName: '设置',
  navSections: <NavSectionContribution>[
    NavSectionContribution(
      id: 'settings',
      label: '设置',
      iconKey: 'settings',
      order: 40,
      viewBuilder: (ctx) => SettingsPage(
        initialSectionId: ctx.arguments['initialSectionId'] as String?,
        deepLinkPulse: (ctx.arguments['deepLinkPulse'] as int?) ?? 0,
        onDetailVisibilityChanged:
            ctx.arguments['onDetailVisibilityChanged']
                as ValueChanged<bool>?,
      ),
    ),
  ],
  settingsSections: <SettingsSectionContribution>[
    SettingsSectionContribution(
      id: 'appearance',
      title: '外观与显示',
      subtitle: '主题模式（浅色 / 深色 / 跟随系统）与流光氛围背景',
      iconKey: 'appearance',
      order: 10,
      viewBuilder: (_) => const SettingsAppearancePanel(),
    ),
    SettingsSectionContribution(
      id: 'network',
      title: '网络与元数据凭据',
      subtitle: 'TMDB / Fanart 凭据安全存取、代理与备用回退镜像',
      iconKey: 'network',
      order: 20,
      viewBuilder: (_) => const SettingsNetworkPanel(),
    ),
    SettingsSectionContribution(
      id: 'storage',
      title: '存储与图片缓存',
      subtitle: '本地图片占用分类清理与脱敏诊断报告导出',
      iconKey: 'storage',
      order: 60,
      viewBuilder: (_) => const SettingsPhotosStorageCard(),
    ),
    SettingsSectionContribution(
      id: 'about',
      title: '关于 Konata',
      subtitle: '版本信息、模块化架构与外部链接',
      iconKey: 'about',
      order: 90,
      viewBuilder: (_) => const SettingsAboutPanel(),
    ),
  ],
);
