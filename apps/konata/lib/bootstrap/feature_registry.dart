import 'package:konata_contracts/konata_contracts.dart';

/// Konata v3 全仓按字母序显式注册的业务 Feature 清单。
///
/// Phase 0 底座阶段保持空清单骨架；Phase 3 ~ Phase 4 各业务切片落地后
/// 按包名字母序逐一加入此处（删除某 Feature 目录与对应 1 行注册即可 0 报错编译）。
const List<FeatureManifest> registeredFeatureManifests = <FeatureManifest>[];

/// 声明式扩展点聚合器（统一按当前平台过滤并按权重排序汇总 7 大扩展点）。
final class FeatureRegistry {
  /// 基于显式清单列表构造扩展点聚合器，并校验清单按 `id` 严格字母序且无重名。
  FeatureRegistry(List<FeatureManifest> manifests)
    : manifests = List<FeatureManifest>.unmodifiable(manifests) {
    _assertSortedAndUnique(this.manifests);
  }

  /// 创建默认主应用清单聚合器。
  factory FeatureRegistry.defaults() =>
      FeatureRegistry(registeredFeatureManifests);

  /// 已注册的全部业务模块清单（严格字母序）。
  final List<FeatureManifest> manifests;

  /// 收集指定运行平台支持的顶层主导航分区（按 `order` 升序）。
  List<NavSectionContribution> navSectionsFor(KonataPlatform platform) {
    final items = <NavSectionContribution>[
      for (final manifest in manifests)
        if (manifest.isSupportedOn(platform))
          for (final section in manifest.navSections)
            if (section.isSupportedOn(platform)) section,
    ]..sort((a, b) => a.order.compareTo(b.order));
    return List<NavSectionContribution>.unmodifiable(items);
  }

  /// 收集指定运行平台支持的设置分区（按 `order` 升序）。
  List<SettingsSectionContribution> settingsSectionsFor(
    KonataPlatform platform,
  ) {
    final items = <SettingsSectionContribution>[
      for (final manifest in manifests)
        if (manifest.isSupportedOn(platform))
          for (final section in manifest.settingsSections)
            if (section.isSupportedOn(platform)) section,
    ]..sort((a, b) => a.order.compareTo(b.order));
    return List<SettingsSectionContribution>.unmodifiable(items);
  }

  /// 收集指定运行平台支持的作品详情页标签页（按 `order` 升序）。
  List<DetailTabContribution> detailTabsFor(KonataPlatform platform) {
    final items = <DetailTabContribution>[
      for (final manifest in manifests)
        if (manifest.isSupportedOn(platform))
          for (final tab in manifest.detailTabs)
            if (tab.isSupportedOn(platform)) tab,
    ]..sort((a, b) => a.order.compareTo(b.order));
    return List<DetailTabContribution>.unmodifiable(items);
  }

  /// 收集指定运行平台支持的作品详情页动作（按 `order` 升序）。
  List<DetailActionContribution> detailActionsFor(KonataPlatform platform) {
    final items = <DetailActionContribution>[
      for (final manifest in manifests)
        if (manifest.isSupportedOn(platform))
          for (final action in manifest.detailActions)
            if (action.isSupportedOn(platform)) action,
    ]..sort((a, b) => a.order.compareTo(b.order));
    return List<DetailActionContribution>.unmodifiable(items);
  }

  /// 收集指定运行平台与媒体模式支持的播放器侧栏面板（按 `order` 升序）。
  List<PlayerSidePanelContribution> playerSidePanelsFor(
    KonataPlatform platform,
    PlayerMediaMode mode,
  ) {
    final items = <PlayerSidePanelContribution>[
      for (final manifest in manifests)
        if (manifest.isSupportedOn(platform))
          for (final panel in manifest.playerSidePanels)
            if (panel.isSupportedOn(platform, mode)) panel,
    ]..sort((a, b) => a.order.compareTo(b.order));
    return List<PlayerSidePanelContribution>.unmodifiable(items);
  }

  /// 收集指定运行平台注册的全部外部数据提供者（按 `priority` 升序）。
  List<DataProviderContribution> dataProvidersFor(KonataPlatform platform) {
    final items = <DataProviderContribution>[
      for (final manifest in manifests)
        if (manifest.isSupportedOn(platform)) ...manifest.dataProviders,
    ]..sort((a, b) => a.priority.compareTo(b.priority));
    return List<DataProviderContribution>.unmodifiable(items);
  }

  /// 收集指定运行平台注册的第三方追番进度同步提供者。
  List<ProgressTrackerProvider> progressTrackersFor(KonataPlatform platform) {
    final providers = dataProvidersFor(platform);
    return List<ProgressTrackerProvider>.unmodifiable(<ProgressTrackerProvider>[
      for (final item in providers)
        if (item is ProgressTrackerProviderContribution) item.provider,
    ]);
  }

  /// 收集指定运行平台注册的同步与备份切片贡献者。
  List<SyncSliceContributor<Object?>> syncSlicesFor(KonataPlatform platform) {
    final items = <SyncSliceContributor<Object?>>[
      for (final manifest in manifests)
        if (manifest.isSupportedOn(platform)) ...manifest.syncSlices,
    ];
    return List<SyncSliceContributor<Object?>>.unmodifiable(items);
  }

  static void _assertSortedAndUnique(List<FeatureManifest> list) {
    String? previousId;
    for (final manifest in list) {
      final currentId = manifest.id.trim();
      if (currentId.isEmpty) {
        throw ArgumentError('FeatureManifest.id 不能为空');
      }
      if (previousId != null) {
        final cmp = previousId.compareTo(currentId);
        if (cmp == 0) {
          throw ArgumentError('存在重复注册的 FeatureManifest.id: `$currentId`');
        }
        if (cmp > 0) {
          throw ArgumentError(
            'FeatureManifest 清单必须按字母序注册：`$previousId` 不得排在 `$currentId` 之前',
          );
        }
      }
      previousId = currentId;
    }
  }
}
