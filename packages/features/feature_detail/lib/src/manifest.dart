import 'package:konata_contracts/konata_contracts.dart';

import 'ui/detail_display_settings_panel.dart';

/// 作品详情注册自身管理的显示选项。
final FeatureManifest featureDetailManifest = FeatureManifest(
  id: 'feature_detail',
  displayName: '作品详情',
  settingsSections: <SettingsSectionContribution>[
    SettingsSectionContribution(
      id: 'detail_display',
      title: '作品展示',
      iconKey: 'display',
      order: 10,
      parentSectionId: displaySettingsSectionId,
      viewBuilder: (_) => const DetailDisplaySettingsPanel(),
    ),
  ],
);
