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
            ctx.arguments['onDetailVisibilityChanged'] as ValueChanged<bool>?,
      ),
    ),
  ],
  settingsSections: <SettingsSectionContribution>[
    SettingsSectionContribution(
      id: 'appearance',
      title: '外观',
      subtitle: '主题模式与视觉偏好',
      iconKey: 'appearance',
      order: 10,
      viewBuilder: (_) => const SettingsAppearancePanel(),
    ),
    SettingsSectionContribution(
      id: displaySettingsSectionId,
      title: '显示与存储',
      subtitle: '作品展示与图片缓存',
      iconKey: 'display',
      order: 15,
      viewBuilder: (_) => const SettingsPhotosStorageCard(),
    ),
    SettingsSectionContribution(
      id: 'network',
      title: '刮削与网络',
      subtitle: '元数据服务与网络连接',
      iconKey: 'network',
      order: 20,
      viewBuilder: (_) => const SettingsNetworkPanel(),
    ),
    SettingsSectionContribution(
      id: 'about',
      title: '关于',
      subtitle: '版本、诊断日志与项目资料',
      iconKey: 'about',
      order: 90,
      viewBuilder: (_) => const SettingsAboutPanel(),
    ),
  ],
);
