import 'dart:async';

import 'package:engine_playback/engine_playback.dart';
import 'package:engine_sources/engine_sources.dart';
import 'package:feature_detail/feature_detail.dart';
import 'package:feature_history/feature_history.dart';
import 'package:feature_library/feature_library.dart';
import 'package:feature_lyrics/feature_lyrics.dart';
import 'package:feature_player_audio/feature_player_audio.dart';
import 'package:feature_player_video/feature_player_video.dart';
import 'package:feature_scan_viewer/feature_scan_viewer.dart';
import 'package:feature_settings/feature_settings.dart';
import 'package:feature_sources/feature_sources.dart';
import 'package:feature_sync/feature_sync.dart';
import 'package:feature_tracker_sync/feature_tracker_sync.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';
import 'package:konata_storage/konata_storage.dart';

/// 宿主向业务模块装配层传递的运行时底座与引擎句柄集合。
///
/// 所有可选业务模块的包级导入与依赖覆写均集中收口于本文件，
/// 移除任意非核心业务包及其对应注册条目即可在不改动 `app_bootstrap.dart` 的前提下零报错编译。
final class FeatureRuntimeWiring {
  /// 创建业务模块装配句柄集合。
  const FeatureRuntimeWiring({
    required this.platform,
    required this.databases,
    required this.storageRoot,
    required this.secureStorage,
    required this.diagnosticLog,
    required this.scopedPrefs,
    required this.domainEventBus,
    required this.featureRegistry,
    required this.navigator,
    required this.filePicker,
    required this.backupFilePort,
    required this.urlOpener,
    required this.httpClient,
    required this.webDavPool,
    required this.gatewayFactory,
    required this.streamBridge,
    required this.subtitleDirectoryIndex,
    required this.warmupService,
    required this.photosStorage,
    required this.artworkCache,
    required this.playbackEngine,
    required this.audiophileCoordinator,
    required this.hostWindow,
    required this.autoStartDetailWarmupAndBackfill,
    this.desktopSurfaceBridge,
    this.androidSurfacePort,
    this.androidMediaSessionPort,
    this.mediaStorePublisher,
    this.customScanStreamOpener,
    this.onThemeModeChanged,
    this.onAmbientBackdropChanged,
    this.onAudioSeekRequested,
  });

  /// 当前运行平台形态。
  final KonataPlatform platform;

  /// 三库物理分治数据库总管。
  final KonataDatabaseBundle databases;

  /// 跨端存储根目录端口。
  final StorageRootPort storageRoot;

  /// 敏感凭据安全存储端口。
  final SecureStoragePort secureStorage;

  /// 脱敏结构化诊断日志端口。
  final DiagnosticLogPort diagnosticLog;

  /// 分命名空间自治配置存储器。
  final ScopedPrefsStore scopedPrefs;

  /// 低频领域事件总线。
  final DomainEventBus domainEventBus;

  /// 声明式扩展点注册表。
  final FeatureRegistry featureRegistry;

  /// 强类型跨模块导航路由端口。
  final AppNavigator navigator;

  /// 系统文件与目录选择器端口。
  final FilePickerPort filePicker;

  /// 备份与诊断报告文件存取端口。
  final BackupFilePort backupFilePort;

  /// 外部链接打开端口。
  final UrlOpenerPort urlOpener;

  /// 统一网络客户端端口。
  final KonataHttpClientPort httpClient;

  /// 共享 WebDAV 连接池。
  final WebDavConnectionPool webDavPool;

  /// 只读媒体源网关工厂。
  final MediaSourceGatewayFactory gatewayFactory;

  /// 本地安全回环流网桥。
  final LocalStreamBridge streamBridge;

  /// 同级字幕目录预热索引。
  final SubtitleDirectoryIndex subtitleDirectoryIndex;

  /// 详情页静默预热服务。
  final WorkDetailWarmupService warmupService;

  /// 分作品目录图片存储管理器。
  final PhotosStorage photosStorage;

  /// 有界图片磁盘与内存缓存。
  final ArtworkDiskCache artworkCache;

  /// 统一四维代数播放协调内核。
  final UnifiedPlaybackEngine playbackEngine;

  /// 发烧音频安全链协调器。
  final AudiophileSafetyCoordinator audiophileCoordinator;

  /// 宿主窗口全屏与置顶控制端口。
  final PlaybackHostWindowPort hostWindow;

  /// 进入详情页后是否自动触发静默预热与正片补图。
  final bool autoStartDetailWarmupAndBackfill;

  /// 桌面端 D3D11 视频纹理共享桥接器（仅 Windows 注入）。
  final KonataVideoTextureBridge? desktopSurfaceBridge;

  /// 移动端底层视频表面控制器（仅 Android 注入）。
  final AndroidVideoSurfacePort? androidSurfacePort;

  /// 移动端系统通知栏媒体会话桥接器（仅 Android 注入）。
  final AndroidMediaSessionPort? androidMediaSessionPort;

  /// 移动端相册发布端口（仅 Android 注入）。
  final MediaStorePublisherPort? mediaStorePublisher;

  /// 可选自定义扫图原图流读取器（供离线端到端集成测试注入）。
  final Object? customScanStreamOpener;

  /// 主题模式变更通知宿主根壳回调。
  final ValueChanged<ThemeMode>? onThemeModeChanged;

  /// 流光氛围背景开关变更回调。
  final ValueChanged<bool>? onAmbientBackdropChanged;

  /// 歌词点选跳转回传至音频播放控制器的桥接回调。
  final void Function(double targetSeconds, {bool resumePlayback})?
  onAudioSeekRequested;
}

/// Konata v3 全仓按字母序显式注册的 11 大业务模块清单。
final List<FeatureManifest> registeredFeatureManifests = <FeatureManifest>[
  featureDetailManifest,
  featureHistoryManifest,
  featureLibraryManifest,
  featureLyricsManifest,
  featurePlayerAudioManifest,
  featurePlayerVideoManifest,
  featureScanViewerManifest,
  featureSettingsManifest,
  featureSourcesManifest,
  featureSyncManifest,
  featureTrackerSyncManifest,
];

/// 按运行期数据库、配置与网络实例构造完整全仓业务模块清单（严格保持字母序）。
List<FeatureManifest> buildRegisteredFeatureManifests({
  required KonataDatabaseBundle databases,
  ScopedPrefsStore? scopedPrefs,
  KonataHttpClientPort? httpClient,
}) {
  return <FeatureManifest>[
    featureDetailManifest,
    featureHistoryManifest,
    featureLibraryManifest,
    createFeatureLyricsManifest(databases: databases, httpClient: httpClient),
    featurePlayerAudioManifest,
    featurePlayerVideoManifest,
    createFeatureScanViewerManifest(databases: databases),
    featureSettingsManifest,
    featureSourcesManifest,
    scopedPrefs == null
        ? featureSyncManifest
        : createFeatureSyncManifest(
            databases: databases,
            scopedPrefs: scopedPrefs,
          ),
    featureTrackerSyncManifest,
  ];
}

/// 按当前注册清单构造全部业务模块的 Riverpod 依赖注入覆写列表。
List<Override> buildFeatureProviderOverrides(FeatureRuntimeWiring wiring) {
  final registry = wiring.featureRegistry;
  final platform = wiring.platform;
  final detailTabs = registry.detailTabsFor(platform);
  final detailActions = registry.detailActionsFor(platform);
  final settingsSections = registry.settingsSectionsFor(platform);
  final videoSidePanels = registry.playerSidePanelsFor(
    platform,
    PlayerMediaMode.video,
  );
  final audioSidePanels = registry.playerSidePanelsFor(
    platform,
    PlayerMediaMode.audio,
  );
  final builtInSyncSliceIds = <String>{
    for (final slice in featureSyncManifest.syncSlices) slice.sliceId,
  };
  final externalSyncSlices = <SyncSliceContributor<Object?>>[
    for (final slice in registry.syncSlicesFor(platform))
      if (!builtInSyncSliceIds.contains(slice.sliceId)) slice,
  ];
  final hasLyrics = registry.containsFeature('feature_lyrics');

  return <Override>[
    featureDetailDependenciesProvider.overrideWithValue(
      FeatureDetailDependencies(
        databases: wiring.databases,
        storageRoot: wiring.storageRoot,
        diagnosticLog: wiring.diagnosticLog,
        scopedPrefs: wiring.scopedPrefs,
        domainEventBus: wiring.domainEventBus,
        navigator: wiring.navigator,
        filePicker: wiring.filePicker,
        urlOpener: wiring.urlOpener,
        httpClient: wiring.httpClient,
        gatewayFactory: wiring.gatewayFactory,
        streamBridge: wiring.streamBridge,
        warmupService: wiring.warmupService,
        photosStorage: wiring.photosStorage,
        artworkCache: wiring.artworkCache,
        platform: platform,
        detailTabs: detailTabs,
        detailActions: detailActions,
        autoStartWarmupAndBackfill: wiring.autoStartDetailWarmupAndBackfill,
      ),
    ),
    featureHistoryDependenciesProvider.overrideWithValue(
      FeatureHistoryDependencies(
        databases: wiring.databases,
        navigator: wiring.navigator,
        diagnosticLog: wiring.diagnosticLog,
        platform: platform,
      ),
    ),
    featureLibraryDependenciesProvider.overrideWithValue(
      FeatureLibraryDependencies(
        databases: wiring.databases,
        storageRoot: wiring.storageRoot,
        diagnosticLog: wiring.diagnosticLog,
        scopedPrefs: wiring.scopedPrefs,
        domainEventBus: wiring.domainEventBus,
        navigator: wiring.navigator,
        httpClient: wiring.httpClient,
        photosStorage: wiring.photosStorage,
        artworkCache: wiring.artworkCache,
        platform: platform,
      ),
    ),
    featureLyricsDependenciesProvider.overrideWithValue(
      FeatureLyricsDependencies(
        databases: wiring.databases,
        scopedPrefs: wiring.scopedPrefs,
        httpClient: wiring.httpClient,
        diagnosticLog: wiring.diagnosticLog,
        domainEventBus: wiring.domainEventBus,
        playbackEngine: wiring.playbackEngine,
        onSeekRequested: wiring.onAudioSeekRequested,
      ),
    ),
    featurePlayerAudioDependenciesProvider.overrideWith((ref) {
      final lyricPort = hasLyrics ? ref.watch(lyricDisplayPortProvider) : null;
      final lyricController = hasLyrics
          ? ref.watch(lyricDisplayControllerProvider)
          : null;
      return FeaturePlayerAudioDependencies(
        engine: wiring.playbackEngine,
        safetyCoordinator: wiring.audiophileCoordinator,
        prefsStore: wiring.scopedPrefs,
        gatewayFactory: wiring.gatewayFactory,
        streamBridge: wiring.streamBridge,
        windowPort: wiring.hostWindow,
        lyricPort: lyricPort,
        lyricsViewportBuilder: lyricController == null
            ? null
            : (context, viewport) => ImmersiveLyricsViewport(
                itemId: viewport.trackKey,
                controller: lyricController,
                positionListenable: viewport.positionListenable,
                isPlayingListenable: viewport.isPlayingListenable,
                compact: viewport.compact,
                centerAligned: viewport.centerAligned,
                onTapEmptyArea: viewport.onTapEmptyArea,
              ),
        extraSidePanels: audioSidePanels,
        database: wiring.databases,
        photosStorage: wiring.photosStorage,
        artworkCacheStore: wiring.artworkCache,
        storageRoot: wiring.storageRoot,
        domainEventBus: wiring.domainEventBus,
        androidMediaSessionPort: wiring.androidMediaSessionPort,
        logPort: wiring.diagnosticLog,
        platform: platform,
      );
    }),
    featurePlayerVideoDependenciesProvider.overrideWithValue(
      FeaturePlayerVideoDependencies(
        databases: wiring.databases,
        storageRoot: wiring.storageRoot,
        diagnosticLog: wiring.diagnosticLog,
        scopedPrefs: wiring.scopedPrefs,
        domainEventBus: wiring.domainEventBus,
        navigator: wiring.navigator,
        filePicker: wiring.filePicker,
        urlOpener: wiring.urlOpener,
        gatewayFactory: wiring.gatewayFactory,
        streamBridge: wiring.streamBridge,
        platform: platform,
        hostWindow: wiring.hostWindow,
        subtitleDirectoryIndex: wiring.warmupService,
        playbackEngine: wiring.playbackEngine,
        audiophileCoordinator: wiring.audiophileCoordinator,
        desktopSurfaceBridge: wiring.desktopSurfaceBridge,
        androidSurfacePort: wiring.androidSurfacePort,
        mediaStorePublisher: wiring.mediaStorePublisher,
        playerSidePanels: videoSidePanels,
      ),
    ),
    featureScanViewerDependenciesProvider.overrideWithValue(
      FeatureScanViewerDependencies(
        databases: wiring.databases,
        storageRoot: wiring.storageRoot,
        diagnosticLog: wiring.diagnosticLog,
        scopedPrefs: wiring.scopedPrefs,
        gatewayFactory: wiring.gatewayFactory,
        photosStorage: wiring.photosStorage,
        platform: platform,
        customStreamOpener:
            wiring.customScanStreamOpener is ScanSourceStreamOpener
            ? wiring.customScanStreamOpener! as ScanSourceStreamOpener
            : null,
        urlOpener: wiring.urlOpener,
      ),
    ),
    featureSettingsDependenciesProvider.overrideWithValue(
      FeatureSettingsDependencies(
        databases: wiring.databases,
        scopedPrefs: wiring.scopedPrefs,
        secureStorage: wiring.secureStorage,
        httpClient: wiring.httpClient,
        photosStorage: wiring.photosStorage,
        backupFilePort: wiring.backupFilePort,
        urlOpener: wiring.urlOpener,
        diagnosticLog: wiring.diagnosticLog,
        navigator: wiring.navigator,
        currentPlatform: platform,
        sections: settingsSections,
        onThemeModeChanged: wiring.onThemeModeChanged,
        onAmbientBackdropChanged: wiring.onAmbientBackdropChanged,
      ),
    ),
    featureSourcesDependenciesProvider.overrideWithValue(
      FeatureSourcesDependencies(
        databases: wiring.databases,
        storageRoot: wiring.storageRoot,
        secureStorage: wiring.secureStorage,
        diagnosticLog: wiring.diagnosticLog,
        scopedPrefs: wiring.scopedPrefs,
        domainEventBus: wiring.domainEventBus,
        navigator: wiring.navigator,
        filePicker: wiring.filePicker,
        httpClient: wiring.httpClient,
        gatewayFactory: wiring.gatewayFactory,
        photosStorage: wiring.photosStorage,
        platform: platform,
      ),
    ),
    featureSyncDependenciesProvider.overrideWithValue(
      FeatureSyncDependencies(
        databases: wiring.databases,
        scopedPrefs: wiring.scopedPrefs,
        secureStorage: wiring.secureStorage,
        backupFilePort: wiring.backupFilePort,
        eventBus: wiring.domainEventBus,
        diagnosticLog: wiring.diagnosticLog,
        extraSlices: externalSyncSlices,
        connectionPool: wiring.webDavPool,
      ),
    ),
    featureTrackerSyncDependenciesProvider.overrideWithValue(
      FeatureTrackerSyncDependencies(
        databases: wiring.databases,
        secureStorage: wiring.secureStorage,
        scopedPrefs: wiring.scopedPrefs,
        domainEventBus: wiring.domainEventBus,
        diagnosticLog: wiring.diagnosticLog,
        httpClient: wiring.httpClient,
        urlOpener: wiring.urlOpener,
        platform: platform,
      ),
    ),
  ];
}

/// 激活需要随应用生命周期常驻事件订阅的已注册后台业务协调器。
void activateRegisteredFeatureServices(WidgetRef ref, FeatureRegistry registry) {
  if (registry.containsFeature('feature_tracker_sync')) {
    ref.watch(trackerSyncCoordinatorProvider);
  }
}

/// 构建作品详情页路由组件。
Widget buildWorkDetailRoutePage({
  required WorkId workId,
  String? initialTabId,
}) {
  return WorkDetailPage(workId: workId, initialTabId: initialTabId);
}

/// 构建全屏视频播放舞台路由组件（桌面端注入共享纹理视图，无纹理时由舞台自身优雅兜底）。
Widget buildVideoPlayerRoutePage({
  required WorkId workId,
  EpisodeId? episodeId,
  VariantId? variantId,
}) {
  return EmbeddedVideoPage(
    request: VideoLaunchRequest(
      workId: workId,
      episodeId: episodeId,
      variantId: variantId,
    ),
    videoSurfaceBuilder: (context, textureId) {
      if (textureId != null && textureId >= 0) {
        return Texture(textureId: textureId);
      }
      return const SizedBox.expand();
    },
  );
}

/// 构建全屏流光音频播放舞台路由组件，并按需启动指定作品的音频队列会话。
Widget buildAudioPlayerRoutePage({
  required WorkId workId,
  VariantId? variantId,
  required VoidCallback onClosePage,
}) {
  return _HostAudioStageRoute(
    workId: workId,
    variantId: variantId,
    onClosePage: onClosePage,
  );
}

/// 构建常驻应用根层的可拖拽迷你悬浮音频条（全屏音频舞台覆盖时自动隐藏）。
Widget buildFloatingAudioMiniBar({
  required bool hidden,
  required KonataPlatform platform,
  required VoidCallback onExpandFullStage,
}) {
  return _HostFloatingAudioMiniBar(
    hidden: hidden,
    platform: platform,
    onExpandFullStage: onExpandFullStage,
  );
}

final class _HostAudioStageRoute extends ConsumerStatefulWidget {
  const _HostAudioStageRoute({
    required this.workId,
    this.variantId,
    required this.onClosePage,
  });

  final WorkId workId;
  final VariantId? variantId;
  final VoidCallback onClosePage;

  @override
  ConsumerState<_HostAudioStageRoute> createState() =>
      _HostAudioStageRouteState();
}

final class _HostAudioStageRouteState
    extends ConsumerState<_HostAudioStageRoute> {
  bool _launched = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _launched) return;
      _launched = true;
      unawaited(_startAudioSession());
    });
  }

  Future<void> _startAudioSession() async {
    final deps = ref.read(featurePlayerAudioDependenciesProvider);
    final databases = deps.database;
    if (databases == null) return;
    final work = databases.library.works.findById(widget.workId);
    if (work == null) return;
    final variants = databases.library.mediaVariants.listByWork(widget.workId);
    final sources = await databases.library.createReadPort().listMediaSources();
    MediaVariantRecord? initialVariant;
    if (widget.variantId != null) {
      for (final variant in variants) {
        if (variant.id == widget.variantId) {
          initialVariant = variant;
          break;
        }
      }
    }
    if (!mounted) return;
    final controller = ref.read(audioPlaybackControllerProvider);
    await controller.playCdCollection(
      work: work,
      variants: variants,
      sources: sources,
      initialVariant: initialVariant,
    );
  }

  @override
  Widget build(BuildContext context) {
    final deps = ref.watch(featurePlayerAudioDependenciesProvider);
    final controller = ref.watch(audioPlaybackControllerProvider);
    final paletteCache = ref.watch(artworkPaletteCacheProvider);
    final alignmentCache = ref.watch(smartCoverAlignmentCacheProvider);
    return ImmersiveAudioPage(
      controller: controller,
      paletteCache: paletteCache,
      alignmentCache: alignmentCache,
      lyricsViewportBuilder: deps.lyricsViewportBuilder,
      extraSidePanels: deps.extraSidePanels,
      platform: deps.platform,
      desktopRelayAvailable: deps.desktopRelayGateway != null,
      desktopMiniWindowSupported: deps.platform == KonataPlatform.windows,
      onMinimizeToMiniBar: widget.onClosePage,
      onClosePage: widget.onClosePage,
    );
  }
}

final class _HostFloatingAudioMiniBar extends ConsumerWidget {
  const _HostFloatingAudioMiniBar({
    required this.hidden,
    required this.platform,
    required this.onExpandFullStage,
  });

  final bool hidden;
  final KonataPlatform platform;
  final VoidCallback onExpandFullStage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(audioPlaybackControllerProvider);
    return ValueListenableBuilder<bool>(
      valueListenable: controller.activeListenable,
      builder: (context, isActive, _) {
        if (!isActive || hidden) {
          return const SizedBox.shrink();
        }
        return MiniAudioBar(
          controller: controller,
          visible: true,
          desktopMiniWindowSupported: platform == KonataPlatform.windows,
          onExpandFullStage: onExpandFullStage,
        );
      },
    );
  }
}

/// 声明式扩展点聚合器（统一按当前平台过滤并按权重排序汇总 7 大扩展点）。
final class FeatureRegistry {
  /// 基于显式清单列表构造扩展点聚合器，并校验清单按 `id` 严格字母序且无重名。
  FeatureRegistry(List<FeatureManifest> manifests)
    : manifests = List<FeatureManifest>.unmodifiable(manifests) {
    _assertSortedAndUnique(this.manifests);
  }

  /// 创建默认主应用静态清单聚合器。
  factory FeatureRegistry.defaults() =>
      FeatureRegistry(registeredFeatureManifests);

  /// 创建绑定指定运行期上下文的动态清单聚合器（支撑详情页标签动态显隐与完整同步切片聚合）。
  factory FeatureRegistry.forRuntime({
    required KonataDatabaseBundle databases,
    ScopedPrefsStore? scopedPrefs,
    KonataHttpClientPort? httpClient,
  }) => FeatureRegistry(
    buildRegisteredFeatureManifests(
      databases: databases,
      scopedPrefs: scopedPrefs,
      httpClient: httpClient,
    ),
  );

  /// 仅传数据库实例构造运行期清单聚合器。
  factory FeatureRegistry.forDatabases(KonataDatabaseBundle databases) =>
      FeatureRegistry.forRuntime(databases: databases);

  /// 已注册的全部业务模块清单（严格字母序）。
  final List<FeatureManifest> manifests;

  /// 查询指定标识的模块是否已注册。
  bool containsFeature(String featureId) =>
      manifests.any((manifest) => manifest.id == featureId);

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
