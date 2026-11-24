import 'package:konata_contracts/konata_contracts.dart';

import 'ui/playback_history_page.dart';

/// 日记式播放记录时间轴模块的声明式注册清单。
final FeatureManifest featureHistoryManifest = FeatureManifest(
  id: 'feature_history',
  displayName: '播放记录',
  navSections: <NavSectionContribution>[
    NavSectionContribution(
      id: 'history',
      label: '播放记录',
      iconKey: 'history',
      order: 30,
      viewBuilder: (_) => const PlaybackHistoryPage(),
    ),
  ],
);
