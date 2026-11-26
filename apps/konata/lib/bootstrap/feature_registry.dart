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

import 'host_storage_adapters.dart';
import 'host_work_manage_dialogs.dart';

/// 注册媒体库词表入口，保留首次排序时的延迟读取。
void configureFeatureDataAssets(AssetDataLoaderPort loader) {
  ChinesePinyinCollator.configure(loader);
}

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
    this.listCloudAccountLocations,
    this.removeCloudAccountLocation,
    this.createCloudSignIn,
    this.desktopSurfaceBridge,
    this.desktopRelayGateway,
    this.externalPlayerStore,
    this.desktopProfileDelegate,
    this.legacyCodePageDecoder,
    this.cloudSubsetCoordinator,
    this.androidSurfacePort,
    this.androidMediaSessionPort,
    this.mediaStorePublisher,
    this.customScanStreamOpener,
    this.pickExecutableFile,
    this.pickShaderFiles,
    this.onThemeModeChanged,
    this.onAmbientBackdropChanged,
    this.onWindowMaterialChanged,
    this.onAudioSeekRequested,
  });

  /// 当前运行平台形态。
  final KonataPlatform platform;

  /// 本机已授权云盘的无凭据根地址入口。
  final Future<List<({String location, String? maskedPhone})>> Function()?
  listCloudAccountLocations;

  /// 清除指定账号的本机授权，不删除媒体源及索引。
  final Future<void> Function(String location)? removeCloudAccountLocation;

  /// 可选已配置客户端的用户主动授权事务。
  final CloudAccountSignInPort Function(String? expectedLocation)?
  createCloudSignIn;

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

  /// 桌面端外部播放器接力网关（仅 Windows 注入）。
  final DesktopRelayGateway? desktopRelayGateway;

  /// 桌面端外部播放器持久化配置仓储（仅 Windows 注入）。
  final DesktopExternalPlayerStore? externalPlayerStore;

  /// 桌面端 `libmpv` 专属驱动与独占音频策略委托（仅 Windows 注入）。
  final MpvPlatformProfileDelegate? desktopProfileDelegate;

  /// 桌面端传统代码页字幕字节解码回调（仅 Windows 注入）。
  final LegacyCodePageDecoder? legacyCodePageDecoder;

  /// 跨端按域隔离的云端字幕字体子集化协调器。
  final CloudSubsetCoordinator? cloudSubsetCoordinator;

  /// 移动端底层视频表面控制器（仅 Android 注入）。
  final AndroidVideoSurfacePort? androidSurfacePort;

  /// 移动端系统通知栏媒体会话桥接器（仅 Android 注入）。
  final AndroidMediaSessionPort? androidMediaSessionPort;

  /// 移动端相册发布端口（仅 Android 注入）。
  final MediaStorePublisherPort? mediaStorePublisher;

  /// 可选自定义扫图原图流读取器（供离线端到端集成测试注入）。
  final Object? customScanStreamOpener;

  /// 可选桌面外部播放器可执行文件选择回调。
  final Future<String?> Function({String? dialogTitle})? pickExecutableFile;

  /// 可选自定义渲染着色器脚本多选回调。
  final Future<List<HostPickedFile>> Function()? pickShaderFiles;

  /// 主题模式变更通知宿主根壳回调。
  final ValueChanged<ThemeMode>? onThemeModeChanged;

  /// 流光氛围背景开关变更回调。
  final ValueChanged<bool>? onAmbientBackdropChanged;

  /// Windows 桌面窗口 DWM 材质变更回调。
  final ValueChanged<KonataWindowMaterial>? onWindowMaterialChanged;

  /// 歌词点选跳转回传至音频播放控制器的桥接回调。
  final void Function(double targetSeconds, {bool resumePlayback})?
  onAudioSeekRequested;
}

/// 启动阶段预加载已保存的 TMDB / Fanart 密钥、代理模式与备用镜像至全局网络客户端。
///
/// 确保应用冷启动后无需先打开设置页即可直接执行刮削、补图与追番巡检。
Future<KonataNetworkConfig> preloadFeatureRuntimeSettings({
  required ScopedPrefsStore scopedPrefs,
  required SecureStoragePort secureStorage,
  required KonataHttpClientPort httpClient,
  DiagnosticLogPort? diagnosticLog,
}) async {
  final repo = SettingsNetworkRepository(
    scopedPrefs: scopedPrefs,
    secureStorage: secureStorage,
  );
  try {
    final config = await repo.load();
    httpClient.updateConfig(config);
    return config;
  } catch (error, stackTrace) {
    diagnosticLog?.logError(
      subsystem: DiagnosticSubsystem.network,
      code: 'STARTUP_NETWORK_PRELOAD_FAILED',
      message: '启动预加载网络与元数据凭据配置失败，已保持默认网络参数',
      error: error,
      stackTrace: stackTrace,
      severity: DiagnosticSeverity.warn,
      source:
          'apps/konata/lib/bootstrap/feature_registry.dart:preloadFeatureRuntimeSettings',
    );
    return httpClient.config;
  }
}

/// 宿主壳层共享外观状态值对象（严格隔绝 `feature_settings` 内部类型，供 `app_bootstrap.dart` 使用）。
final class HostAppearanceState {
  /// 创建宿主外观状态快照。
  const HostAppearanceState({
    this.themeMode = ThemeMode.dark,
    this.ambientBackdropEnabled = false,
    this.windowMaterial = KonataWindowMaterial.acrylic,
  });

  /// 当前应用主题模式。
  final ThemeMode themeMode;

  /// 是否启用流光氛围画布。
  final bool ambientBackdropEnabled;

  /// Windows 原生 DWM 窗口材质。
  final KonataWindowMaterial windowMaterial;

  /// 复制并修改部分外观状态字段。
  HostAppearanceState copyWith({
    ThemeMode? themeMode,
    bool? ambientBackdropEnabled,
    KonataWindowMaterial? windowMaterial,
  }) {
    return HostAppearanceState(
      themeMode: themeMode ?? this.themeMode,
      ambientBackdropEnabled:
          ambientBackdropEnabled ?? this.ambientBackdropEnabled,
      windowMaterial: windowMaterial ?? this.windowMaterial,
    );
  }
}

/// 统一经由 `feature_settings` 完整外观切片读取初始外观与桌面材质偏好（严禁在宿主重复定义不全切片）。
HostAppearanceState readInitialAppearancePrefs(ScopedPrefsStore scopedPrefs) {
  final prefs = SettingsAppearanceRepository(scopedPrefs).read();
  return HostAppearanceState(
    themeMode: prefs.themeMode,
    ambientBackdropEnabled: prefs.ambientBackdropEnabled,
    windowMaterial: prefs.windowMaterial,
  );
}

/// 统一经由 `feature_settings` 完整外观切片持久化外观与桌面材质偏好，避免主题切换覆盖其他字段。
void saveAppearancePrefs(
  ScopedPrefsStore scopedPrefs,
  HostAppearanceState state,
) {
  SettingsAppearanceRepository(scopedPrefs).save(
    SettingsAppearancePrefs(
      themeMode: state.themeMode,
      ambientBackdropEnabled: state.ambientBackdropEnabled,
      windowMaterial: state.windowMaterial,
    ),
  );
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
  final hasAudio = registry.containsFeature('feature_player_audio');

  Future<List<ShaderImportSource>> Function()? shaderPicker;
  if (wiring.pickShaderFiles != null) {
    final hostPicker = wiring.pickShaderFiles!;
    shaderPicker = () async {
      final picked = await hostPicker();
      return <ShaderImportSource>[
        for (final file in picked)
          ShaderImportSource(
            name: file.name,
            sourcePath: file.path,
            bytes: file.bytes,
          ),
      ];
    };
  }

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
    featureHistoryDependenciesProvider.overrideWith((ref) {
      final loader = ref.watch(libraryArtworkLoaderProvider);
      return FeatureHistoryDependencies(
        databases: wiring.databases,
        navigator: wiring.navigator,
        diagnosticLog: wiring.diagnosticLog,
        platform: platform,
        imageLoader: (id) async {
          final work = wiring.databases.library.works.findById(id);
          if (work == null) return null;
          final primary = switch (work.posterRef) {
            LocalCustomArtworkRef(:final localPath) => localPath,
            RemoteArtworkRef(:final uri) => uri,
            _ => null,
          };
          for (final path in [
            primary,
            work.posterFallback,
            work.bangumiPosterPath,
          ]) {
            if (path == null || path.trim().isEmpty) continue;
            final bytes = await loader(
              path,
              ownerWorkId: id.value,
              subfolder: PhotoSubfolder.posters,
            );
            if (bytes != null && bytes.isNotEmpty) return bytes;
          }
          return null;
        },
        entryArtworkLoader: (entry) async {
          final owner = entry.record.workId.value;
          final variant = entry.variant;
          if (entry.isAudio && variant != null) {
            final path = variant.relativePath.replaceAll(r'\', '/');
            final slash = path.lastIndexOf('/');
            final dir = slash < 0 ? '.' : path.substring(0, slash);
            final key =
                'cd_cover::${variant.sourceId.value}::$dir::${variant.id.value}';
            return wiring.photosStorage.readArtwork(
              workId: owner,
              subfolder: PhotoSubfolder.thumbnails,
              cacheKey: key,
            );
          }
          final still = entry.stillPath;
          if (still == null || still.trim().isEmpty) return null;
          return loader(
            still,
            targetWidth: 320,
            ownerWorkId: owner,
            subfolder: PhotoSubfolder.thumbnails,
          );
        },
      );
    }),
    workManageDialogPortProvider.overrideWithValue(
      const HostWorkManageDialogs(),
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
    featureLyricsDependenciesProvider.overrideWith((ref) {
      // 歌词点选跳转回调惰性读取音频控制器，彻底避免与 audioPlaybackControllerProvider 产生环形依赖。
      final seekCallback =
          wiring.onAudioSeekRequested ??
          (hasAudio
              ? (double targetSeconds, {bool resumePlayback = false}) {
                  final audioCtrl = ref.read(audioPlaybackControllerProvider);
                  unawaited(
                    audioCtrl.seekToTrackPosition(
                      Duration(milliseconds: (targetSeconds * 1000.0).round()),
                    ),
                  );
                  if (resumePlayback && !audioCtrl.playingListenable.value) {
                    unawaited(audioCtrl.setPlaying(true));
                  }
                }
              : null);
      return FeatureLyricsDependencies(
        databases: wiring.databases,
        scopedPrefs: wiring.scopedPrefs,
        httpClient: wiring.httpClient,
        diagnosticLog: wiring.diagnosticLog,
        domainEventBus: wiring.domainEventBus,
        playbackEngine: wiring.playbackEngine,
        onSeekRequested: seekCallback,
      );
    }),
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
        posterLoader: (path, workId) => ref.read(libraryArtworkLoaderProvider)(
          path,
          targetWidth: 512,
          ownerWorkId: workId,
          subfolder: PhotoSubfolder.posters,
        ),
        storageRoot: wiring.storageRoot,
        domainEventBus: wiring.domainEventBus,
        desktopRelayGateway: wiring.desktopRelayGateway,
        desktopMpvDelegate: wiring.desktopProfileDelegate,
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
        desktopRelayGateway: wiring.desktopRelayGateway,
        externalPlayerStore: wiring.externalPlayerStore,
        readAudioRelayPreferences: hasAudio
            ? () {
                final prefs = AudioPlaybackPreferences(
                  store: wiring.scopedPrefs,
                ).read();
                return (
                  port: prefs.foobarBeefwebPort,
                  skipGuide: prefs.skipFoobarBeefwebPrompt,
                );
              }
            : null,
        writeAudioRelayPreferences: hasAudio
            ? ({int? port, bool? skipGuide}) {
                AudioPlaybackPreferences(
                  store: wiring.scopedPrefs,
                  eventBus: wiring.domainEventBus,
                ).update(
                  (p) => p.copyWith(
                    foobarBeefwebPort: port,
                    skipFoobarBeefwebPrompt: skipGuide,
                  ),
                );
              }
            : null,
        desktopSurfaceBridge: wiring.desktopSurfaceBridge,
        desktopProfileDelegate: wiring.desktopProfileDelegate,
        androidSurfacePort: wiring.androidSurfacePort,
        mediaStorePublisher: wiring.mediaStorePublisher,
        cloudSubsetCoordinator: wiring.cloudSubsetCoordinator,
        legacyCodePageDecoder: wiring.legacyCodePageDecoder,
        playerSidePanels: videoSidePanels,
        pickExecutableFile: wiring.pickExecutableFile,
        pickShaderFiles: shaderPicker,
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
        onWindowMaterialChanged: wiring.onWindowMaterialChanged,
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
        listCloudAccountLocations: wiring.listCloudAccountLocations,
        removeCloudAccountLocation: wiring.removeCloudAccountLocation,
        createCloudSignIn: wiring.createCloudSignIn,
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

/// 激活需要随应用生命周期常驻事件订阅与启动自动同步的已注册后台业务协调器。
void activateRegisteredFeatureServices(
  WidgetRef ref,
  FeatureRegistry registry,
) {
  if (registry.containsFeature('feature_tracker_sync')) {
    ref.watch(trackerSyncCoordinatorProvider);
  }
  if (registry.containsFeature('feature_sync')) {
    ref.watch(syncBackupControllerProvider);
  }
}

/// 按节流策略触发连载与近期活跃作品的后台静默追更巡检。
void triggerOngoingWorksAutoSync(
  WidgetRef ref,
  FeatureRegistry registry, {
  bool force = false,
}) {
  if (!registry.containsFeature('feature_sources')) return;
  unawaited(
    ref
        .read(sourceScrapeControllerProvider)
        .runOngoingWorksAutoSyncIfDue(force: force),
  );
}

/// 尝试将当前全屏视频舞台切入跨页悬浮小窗或优雅退场（供 Android 根返回门控调用）。
Future<bool> handleFullscreenMediaBackIntercept(
  WidgetRef ref,
  FeatureRegistry registry, {
  required bool videoStageOpen,
  required bool audioStageOpen,
  required VoidCallback onPopCurrentRoute,
}) async {
  if (videoStageOpen && registry.containsFeature('feature_player_video')) {
    final manager = ref.read(activeVideoSessionManagerProvider);
    if (await manager.closeActiveSession()) onPopCurrentRoute();
    return true;
  }
  if (audioStageOpen && registry.containsFeature('feature_player_audio')) {
    onPopCurrentRoute();
    return true;
  }
  return false;
}

/// 构建作品详情页路由组件。
Widget buildWorkDetailRoutePage({
  required WorkId workId,
  String? initialTabId,
}) {
  return WorkDetailPage(workId: workId, initialTabId: initialTabId);
}

/// 构建全屏视频播放舞台路由组件（复用跨页活跃视频会话总管，收拢小窗时不销毁解码会话）。
Widget buildVideoPlayerRoutePage({
  required WorkId workId,
  EpisodeId? episodeId,
  VariantId? variantId,
  int? initialPositionSeconds,
  bool initialPlaying = true,
  bool hasAudioFeature = true,
  required VoidCallback onClosePage,
}) {
  return _HostVideoStageRoute(
    request: VideoLaunchRequest(
      workId: workId,
      episodeId: episodeId,
      variantId: variantId,
      initialPositionSeconds: initialPositionSeconds,
      initialPlaying: initialPlaying,
    ),
    hasAudioFeature: hasAudioFeature,
    onClosePage: onClosePage,
  );
}

/// 构建全屏流光音频播放舞台路由组件，并按需启动指定作品的音频队列会话。
///
/// 当 [workId] 为 `null` 时表示从悬浮迷你唱片回弹展开当前活跃音频会话，绝不重建解码流。
Widget buildAudioPlayerRoutePage({
  WorkId? workId,
  VariantId? variantId,
  bool hasVideoFeature = true,
  required VoidCallback onClosePage,
}) {
  return _HostAudioStageRoute(
    workId: workId,
    variantId: variantId,
    hasVideoFeature: hasVideoFeature,
    onClosePage: onClosePage,
  );
}

/// 从悬浮视频小窗回弹展开全屏舞台的定位回调签名。
typedef ExpandVideoStageCallback =
    void Function(WorkId workId, EpisodeId? episodeId, VariantId? variantId);

/// 冷启动仅消费有效且仍精确关联到媒体库的本机恢复快照，不回退到其他分集或版本。
Future<
  ({
    WorkId workId,
    EpisodeId episodeId,
    VariantId variantId,
    int positionSeconds,
    bool isPlaying,
  })?
>
takeAndroidVideoRecovery(
  WidgetRef ref,
  FeatureRegistry registry,
  KonataPlatform platform,
) async {
  if (platform == KonataPlatform.windows ||
      !registry.containsFeature('feature_player_video')) {
    return null;
  }
  final manager = ref.read(activeVideoSessionManagerProvider);
  if (manager.hasActiveSession) return null;
  if (registry.containsFeature('feature_player_audio') &&
      ref.read(audioPlaybackControllerProvider).activeListenable.value) {
    return null;
  }
  final deps = ref.read(featurePlayerVideoDependenciesProvider);
  final store = ref.read(videoPipRecoveryStoreProvider);
  final snapshot = await store.readFreshSnapshot();
  if (snapshot == null) return null;
  final workId = WorkId.trusted(snapshot.workId);
  final episodeId = EpisodeId.trusted(snapshot.episodeId);
  final variantId = VariantId.trusted(snapshot.variantId);
  if (!snapshot.matchesLibrary(deps.databases)) {
    await store.clear();
    return null;
  } // 单次消费，避免坏资源或主动退出引发反复冷启动播放。
  await store.clear();
  return (
    workId: workId,
    episodeId: episodeId,
    variantId: variantId,
    positionSeconds: snapshot.positionSeconds,
    isPlaying: snapshot.isPlaying,
  );
}

/// 构建常驻应用根层的音视频悬浮小窗与系统桥接层（含 16:9 跨页悬浮视频小窗、迷你音频条与 Android 音频焦点/PiP 联动）。
Widget buildHostFloatingPlaybackOverlay({
  required FeatureRegistry registry,
  required KonataPlatform platform,
  required bool videoStageOpen,
  required bool audioStageOpen,
  required ValueChanged<FloatingMiniPlayerKind> onActiveMiniKindChanged,
  required ExpandVideoStageCallback onExpandVideoStage,
  required VoidCallback onExpandAudioStage,
  AndroidAudioFocusPort? androidAudioFocusPort,
  AndroidPipPort? androidPipPort,
}) {
  return _HostFloatingPlaybackOverlay(
    registry: registry,
    platform: platform,
    videoStageOpen: videoStageOpen,
    audioStageOpen: audioStageOpen,
    onActiveMiniKindChanged: onActiveMiniKindChanged,
    onExpandVideoStage: onExpandVideoStage,
    onExpandAudioStage: onExpandAudioStage,
    androidAudioFocusPort: androidAudioFocusPort,
    androidPipPort: androidPipPort,
  );
}

Widget _buildSharedVideoTextureSurface(BuildContext context, int? textureId) {
  if (textureId != null && textureId >= 0) {
    return Texture(textureId: textureId);
  }
  return const SizedBox.expand();
}

final class _HostVideoStageRoute extends ConsumerStatefulWidget {
  const _HostVideoStageRoute({
    required this.request,
    required this.hasAudioFeature,
    required this.onClosePage,
  });

  final VideoLaunchRequest request;
  final bool hasAudioFeature;
  final VoidCallback onClosePage;

  @override
  ConsumerState<_HostVideoStageRoute> createState() =>
      _HostVideoStageRouteState();
}

final class _HostVideoStageRouteState
    extends ConsumerState<_HostVideoStageRoute> {
  late final ActiveVideoSessionManager _sessionManager;
  VideoPlaybackController? _controller;
  final Object _routeOwner = Object();

  @override
  void initState() {
    super.initState();
    _sessionManager = ref.read(activeVideoSessionManagerProvider);
    // 跨页会话会通知根层，路由首帧提交后才允许启动或恢复。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_openSession());
    });
  }

  Future<void> _openSession() async {
    try {
      if (widget.hasAudioFeature) {
        await ref.read(audioPlaybackControllerProvider).pauseForVideoSession();
      }
      if (!mounted) return;
      final controller = await _sessionManager.openOrReuseSession(
        widget.request,
        routeOwner: _routeOwner,
      );
      if (!mounted) {
        _sessionManager.handleStageRoutePopped(_routeOwner);
        return;
      }
      setState(() => _controller = controller);
    } catch (_) {
      if (mounted) {
        showKonataToast(context, '无法打开播放器，请重试', isError: true);
        widget.onClosePage();
      }
    }
  }

  @override
  void dispose() {
    // 路由卸载仍处于框架锁定期，退出通知移到卸载之后。
    scheduleMicrotask(
      () => _sessionManager.handleStageRoutePopped(_routeOwner),
    );
    super.dispose();
  }

  Future<void> _collapseToMini() async {
    await _sessionManager.collapseToFloatingMini();
    if (mounted && _controller?.state.miniMode == VideoMiniMode.floating) {
      widget.onClosePage();
    }
  }

  Future<void> _closeAndPop() async {
    final closed = await _sessionManager.closeActiveSession();
    if (mounted && closed) {
      widget.onClosePage();
    }
  }

  @override
  Widget build(BuildContext context) {
    final deps = ref.watch(featurePlayerVideoDependenciesProvider);
    final controller = _controller;
    if (controller == null) {
      return const ColoredBox(color: KonataPlaybackTokens.cinemaPureBlack);
    }
    return EmbeddedVideoPage(
      request: widget.request,
      controller: controller,
      playerSidePanels: deps.playerSidePanels,
      videoSurfaceBuilder: _buildSharedVideoTextureSurface,
      onClose: () => unawaited(_closeAndPop()),
      onEnterMiniPlayer: () => unawaited(_collapseToMini()),
    );
  }
}

final class _HostAudioStageRoute extends ConsumerStatefulWidget {
  const _HostAudioStageRoute({
    this.workId,
    this.variantId,
    required this.hasVideoFeature,
    required this.onClosePage,
  });

  final WorkId? workId;
  final VariantId? variantId;
  final bool hasVideoFeature;
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
    if (widget.workId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _launched) return;
        _launched = true;
        unawaited(_startAudioSession());
      });
    }
  }

  Future<void> _startAudioSession() async {
    final targetWorkId = widget.workId;
    if (targetWorkId == null) return;
    final deps = ref.read(featurePlayerAudioDependenciesProvider);
    final databases = deps.database;
    if (databases == null) return;
    final work = databases.library.works.findById(targetWorkId);
    if (work == null) return;
    final variants = databases.library.mediaVariants.listByWork(targetWorkId);
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
    if (widget.hasVideoFeature) {
      final videoMgr = ref.read(activeVideoSessionManagerProvider);
      if (videoMgr.hasActiveSession) {
        // 启动独立音乐会话前先有序释放既有视频会话及其桌面渲染表面，避免残留失效悬浮视频小窗。
        if (!await videoMgr.closeActiveSession()) return;
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

final class _HostFloatingPlaybackOverlay extends ConsumerStatefulWidget {
  const _HostFloatingPlaybackOverlay({
    required this.registry,
    required this.platform,
    required this.videoStageOpen,
    required this.audioStageOpen,
    required this.onActiveMiniKindChanged,
    required this.onExpandVideoStage,
    required this.onExpandAudioStage,
    this.androidAudioFocusPort,
    this.androidPipPort,
  });

  final FeatureRegistry registry;
  final KonataPlatform platform;
  final bool videoStageOpen;
  final bool audioStageOpen;
  final ValueChanged<FloatingMiniPlayerKind> onActiveMiniKindChanged;
  final ExpandVideoStageCallback onExpandVideoStage;
  final VoidCallback onExpandAudioStage;
  final AndroidAudioFocusPort? androidAudioFocusPort;
  final AndroidPipPort? androidPipPort;

  @override
  ConsumerState<_HostFloatingPlaybackOverlay> createState() =>
      _HostFloatingPlaybackOverlayState();
}

final class _HostFloatingPlaybackOverlayState
    extends ConsumerState<_HostFloatingPlaybackOverlay> {
  ActiveVideoSessionManager? _videoManager;
  AudioPlaybackController? _audioController;
  FloatingMiniPlayerKind _lastNotifiedMiniKind = FloatingMiniPlayerKind.none;

  bool _audioFocusHeld = false;
  bool _duckedAudio = false;
  bool _duckedVideo = false;
  double? _savedAudioVolume;
  double? _savedVideoVolume;

  @override
  void initState() {
    super.initState();
    _bindControllers();
  }

  @override
  void didUpdateWidget(covariant _HostFloatingPlaybackOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoStageOpen != widget.videoStageOpen ||
        oldWidget.audioStageOpen != widget.audioStageOpen) {
      _syncPlaybackSideEffects();
    }
  }

  void _bindControllers() {
    if (widget.registry.containsFeature('feature_player_video')) {
      _videoManager = ref.read(activeVideoSessionManagerProvider);
      _videoManager!.addListener(_syncPlaybackSideEffects);
    }
    if (widget.registry.containsFeature('feature_player_audio')) {
      _audioController = ref.read(audioPlaybackControllerProvider);
      _audioController!.activeListenable.addListener(_syncPlaybackSideEffects);
      _audioController!.playingListenable.addListener(_syncPlaybackSideEffects);
    }
    widget.androidPipPort?.bindCallbacks(
      onPipModeChanged: (active) {
        _videoManager?.controller?.setSystemPipActive(active);
      },
      onRemoteAction: _handleAndroidPipAction,
      onPipDismissed: () {
        final mgr = _videoManager;
        final controller = mgr?.controller;
        if (controller != null) {
          unawaited(controller.dismissSystemPip());
        }
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _syncPlaybackSideEffects();
      }
    });
  }

  @override
  void dispose() {
    _videoManager?.removeListener(_syncPlaybackSideEffects);
    _audioController?.activeListenable.removeListener(_syncPlaybackSideEffects);
    _audioController?.playingListenable.removeListener(
      _syncPlaybackSideEffects,
    );
    widget.androidPipPort?.unbindCallbacks();
    if (_audioFocusHeld) {
      unawaited(widget.androidAudioFocusPort?.abandonAudioFocus());
      _audioFocusHeld = false;
    }
    super.dispose();
  }

  void _handleAndroidPipAction(String action) {
    final videoCtrl = _videoManager?.controller;
    if (videoCtrl == null) return;
    switch (action) {
      case 'previous':
        unawaited(videoCtrl.playPreviousEpisode());
      case 'togglePlayPause':
        unawaited(videoCtrl.togglePlayPause());
      case 'next':
        unawaited(videoCtrl.playNextEpisode());
    }
  }

  void _handleAudioFocusLoss() {
    final videoCtrl = _videoManager?.controller;
    if (videoCtrl != null && videoCtrl.state.isPlaying) {
      unawaited(videoCtrl.setPlaying(false));
    }
    final audioCtrl = _audioController;
    if (audioCtrl != null && audioCtrl.playingListenable.value) {
      unawaited(audioCtrl.setPlaying(false));
    }
  }

  void _handleAudioFocusDuck() {
    final videoCtrl = _videoManager?.controller;
    if (videoCtrl != null && videoCtrl.state.isPlaying && !_duckedVideo) {
      _savedVideoVolume = videoCtrl.state.volume;
      _duckedVideo = true;
      videoCtrl.setVolume((_savedVideoVolume! * 0.3).clamp(5.0, 100.0));
    }
    final audioCtrl = _audioController;
    if (audioCtrl != null &&
        audioCtrl.playingListenable.value &&
        !_duckedAudio) {
      _savedAudioVolume = audioCtrl.snapshot.volume;
      _duckedAudio = true;
      unawaited(
        audioCtrl.setVolume((_savedAudioVolume! * 0.3).clamp(5.0, 100.0)),
      );
    }
  }

  void _handleAudioFocusGain() {
    if (_duckedVideo && _savedVideoVolume != null) {
      _videoManager?.controller?.setVolume(_savedVideoVolume!);
    }
    _duckedVideo = false;
    _savedVideoVolume = null;
    if (_duckedAudio && _savedAudioVolume != null) {
      final audioCtrl = _audioController;
      if (audioCtrl != null) {
        unawaited(audioCtrl.setVolume(_savedAudioVolume!));
      }
    }
    _duckedAudio = false;
    _savedAudioVolume = null;
  }

  void _syncPlaybackSideEffects() {
    if (!mounted) return;
    final videoMgr = _videoManager;
    final videoCtrl = videoMgr?.controller;
    final audioCtrl = _audioController;

    final showVideoMini =
        videoMgr != null &&
        videoMgr.shouldShowFloatingMiniPlayer &&
        !widget.videoStageOpen;
    final showAudioMini =
        audioCtrl != null &&
        audioCtrl.activeListenable.value &&
        !widget.audioStageOpen &&
        !widget.videoStageOpen;

    final nextMiniKind = showVideoMini
        ? FloatingMiniPlayerKind.video
        : (showAudioMini
              ? FloatingMiniPlayerKind.audio
              : FloatingMiniPlayerKind.none);
    if (nextMiniKind != _lastNotifiedMiniKind) {
      _lastNotifiedMiniKind = nextMiniKind;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          widget.onActiveMiniKindChanged(nextMiniKind);
        }
      });
    }

    final videoPlaying = videoCtrl?.state.isPlaying ?? false;
    final audioPlaying = audioCtrl?.playingListenable.value ?? false;
    final anyPlaying = videoPlaying || audioPlaying;

    final focusPort = widget.androidAudioFocusPort;
    if (focusPort != null) {
      if (anyPlaying && !_audioFocusHeld) {
        _audioFocusHeld = true;
        unawaited(
          focusPort.requestAudioFocus(
            onLoss: _handleAudioFocusLoss,
            onDuck: _handleAudioFocusDuck,
            onGain: _handleAudioFocusGain,
          ),
        );
      } else if (!anyPlaying && _audioFocusHeld) {
        _audioFocusHeld = false;
        _handleAudioFocusGain();
        unawaited(focusPort.abandonAudioFocus());
      }
    }

    final pipPort = widget.androidPipPort;
    if (pipPort != null) {
      final eligible =
          videoCtrl?.canAutoEnterSystemPip(
            stageExpanded:
                videoMgr?.isStageExpanded == true && widget.videoStageOpen,
          ) ??
          false;
      final aspect = PipAspectRatioPolicy.clampRational(
        videoCtrl?.state.probeStats.videoWidth ?? 0,
        videoCtrl?.state.probeStats.videoHeight ?? 0,
      );
      unawaited(
        pipPort.syncState(
          AndroidPipState(
            eligible: eligible,
            aspectNumerator: aspect.numerator,
            aspectDenominator: aspect.denominator,
            isPlaying: videoPlaying,
            canPrevious: videoCtrl?.hasPreviousEpisode ?? false,
            canNext: videoCtrl?.hasNextEpisode ?? false,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasVideo = widget.registry.containsFeature('feature_player_video');
    final hasAudio = widget.registry.containsFeature('feature_player_audio');
    final videoManager = hasVideo
        ? ref.watch(activeVideoSessionManagerProvider)
        : null;
    final audioController = hasAudio
        ? ref.watch(audioPlaybackControllerProvider)
        : null;

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        if (videoManager != null)
          ListenableBuilder(
            listenable: videoManager,
            builder: (context, _) {
              final ctrl = videoManager.controller;
              if (ctrl == null ||
                  widget.videoStageOpen ||
                  !videoManager.shouldShowFloatingMiniPlayer) {
                return const SizedBox.shrink();
              }
              final size = MediaQuery.sizeOf(context);
              final miniWidth = widget.platform == KonataPlatform.androidPhone
                  ? KonataPlaybackTokens.floatingMiniVideoLongSidePhone
                  : KonataPlaybackTokens.floatingMiniVideoWidth;
              final miniHeight = miniWidth * 9.0 / 16.0;
              const margin = KonataPlaybackTokens.floatingMiniEdgeMargin;
              final bottomClearance =
                  widget.platform == KonataPlatform.androidPhone ? 96.0 : 28.0;
              final defaultOffset = Offset(
                (size.width - miniWidth - margin).clamp(
                  margin,
                  double.infinity,
                ),
                (size.height - miniHeight - bottomClearance).clamp(
                  KonataPlaybackTokens.floatingMiniDesktopTopBarClearance,
                  double.infinity,
                ),
              );
              return VideoFloatingMiniPlayer(
                controller: ctrl,
                width: miniWidth,
                viewportSize: size,
                initialOffset: defaultOffset,
                videoSurfaceBuilder: _buildSharedVideoTextureSurface,
                onExpand: () {
                  final req = videoManager.activeRequest;
                  if (req != null) {
                    widget.onExpandVideoStage(
                      req.workId,
                      req.episodeId,
                      req.variantId,
                    );
                  }
                },
                onClose: () => unawaited(videoManager.closeActiveSession()),
              );
            },
          ),
        if (audioController != null)
          ValueListenableBuilder<bool>(
            valueListenable: audioController.activeListenable,
            builder: (context, isActive, _) {
              if (!isActive || widget.audioStageOpen || widget.videoStageOpen) {
                return const SizedBox.shrink();
              }
              return MiniAudioBar(
                controller: audioController,
                visible: true,
                desktopMiniWindowSupported:
                    widget.platform == KonataPlatform.windows,
                onExpandFullStage: widget.onExpandAudioStage,
              );
            },
          ),
      ],
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
