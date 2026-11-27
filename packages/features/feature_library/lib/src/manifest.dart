import 'package:konata_contracts/konata_contracts.dart';

import 'ui/library_page.dart';

/// `feature_library` 向宿主外壳注册的标准化扩展清单。
///
/// 挂载顶层「媒体库」主导航分区（`id: 'library'`，排序权重 `10`），并透传 `ViewSlotContext`
/// 以便桌面顶栏实时搜索词平滑同步进海报墙。
final FeatureManifest featureLibraryManifest = FeatureManifest(
  id: 'feature_library',
  displayName: '媒体库',
  navSections: <NavSectionContribution>[
    NavSectionContribution(
      id: 'library',
      label: '媒体库',
      iconKey: 'library',
      order: 10,
      supportsSearch: true,
      viewBuilder: (slotContext) => LibraryPage(slotContext: slotContext),
    ),
  ],
);
