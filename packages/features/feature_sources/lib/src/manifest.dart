import 'package:konata_contracts/konata_contracts.dart';

import 'ui/sources_page.dart';

/// `feature_sources` 向宿主外壳注册的标准化扩展清单。
///
/// 挂载顶层「媒体源」主导航分区（`id: 'sources'`，排序权重 `20`）。
final FeatureManifest featureSourcesManifest = FeatureManifest(
  id: 'feature_sources',
  displayName: '媒体源',
  navSections: <NavSectionContribution>[
    NavSectionContribution(
      id: 'sources',
      label: '媒体源',
      iconKey: 'sources',
      order: 20,
      viewBuilder: (slotContext) => const SourcesPage(),
    ),
  ],
);
