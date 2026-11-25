import 'dart:async';

import 'package:engine_cloud_drives/engine_cloud_drives.dart';
import 'package:engine_playback/engine_playback.dart';
import 'package:engine_scraping/engine_scraping.dart'
    show BangumiTmdbIndex, ReleaseGroups;
import 'package:engine_sources/engine_sources.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';
import 'package:konata_storage/konata_storage.dart';

import 'diagnostics_runtime_bridge.dart';
import 'feature_registry.dart';
import 'host_storage_adapters.dart';
import 'window_host_port.dart';

/// 全局应用运行形态提供器（Windows 桌面 / Android 手机 / Android 平板）。
final konataPlatformProvider = Provider<KonataPlatform>((ref) {
  throw UnimplementedError('konataPlatformProvider 必须由宿主启动壳覆盖注入');
});

/// 全局跨端存储根目录端口提供器。
final storageRootPortProvider = Provider<StorageRootPort>((ref) {
  throw UnimplementedError('storageRootPortProvider 必须由宿主启动壳覆盖注入');
});

/// 全局敏感凭据安全存储端口提供器。
final secureStoragePortProvider = Provider<SecureStoragePort>((ref) {
  throw UnimplementedError('secureStoragePortProvider 必须由宿主启动壳覆盖注入');
});

/// 全局只读内置资产字节读取端口提供器。
final assetDataLoaderPortProvider = Provider<AssetDataLoaderPort>((ref) {
  return const HostAssetDataLoader();
});

/// 全局统一脱敏诊断日志端口提供器。
final diagnosticLogPortProvider = Provider<DiagnosticLogPort>((ref) {
  throw UnimplementedError('diagnosticLogPortProvider 必须由宿主启动壳覆盖注入');
});

/// 全局三库物理分治总管提供器。
final databaseBundleProvider = Provider<KonataDatabaseBundle>((ref) {
  throw UnimplementedError('databaseBundleProvider 必须由宿主启动壳覆盖注入');
});

/// 全局媒体库只读查询端口提供器。
final libraryReadPortProvider = Provider<LibraryReadPort>((ref) {
  return ref.watch(databaseBundleProvider).library.createReadPort();
});

/// 全局播放进度只读查询端口提供器。
final playbackReadPortProvider = Provider<PlaybackReadPort>((ref) {
  return ref.watch(databaseBundleProvider).userState.createPlaybackReadPort();
});

/// 全局分命名空间自治配置存储器提供器。
final scopedPrefsStoreProvider = Provider<ScopedPrefsStore>((ref) {
  return ScopedPrefsStore(ref.watch(databaseBundleProvider).userState);
});

/// 全局配置只读查询端口提供器。
final prefsReadPortProvider = Provider<PrefsReadPort>((ref) {
  return ref.watch(scopedPrefsStoreProvider);
});

/// 全局低频跨包领域事件总线提供器（严禁发送高频信号）。
final domainEventBusProvider = Provider<DomainEventBus>((ref) {
  throw UnimplementedError('domainEventBusProvider 必须由宿主启动壳覆盖注入');
});

/// 全局声明式扩展点聚合器提供器。
final featureRegistryProvider = Provider<FeatureRegistry>((ref) {
  return FeatureRegistry.defaults();
});

/// 全局跨 Feature 强类型导航路由端口提供器。
final appNavigatorProvider = Provider<AppNavigator>((ref) {
  throw UnimplementedError('appNavigatorProvider 必须由宿主启动壳覆盖注入');
});

/// 全局悬浮轻提示控制器提供器（桥接至无状态管理设计系统作用域）。
final toastControllerProvider = Provider<KonataToastController>((ref) {
  final controller = KonataToastController();
  ref.onDispose(controller.dispose);
  return controller;
});

/// 全局模态路由层级注册表提供器（驱动悬浮小窗严守弹窗遮罩之下）。
final modalLayerRegistryProvider = Provider<KonataModalLayerRegistry>((ref) {
  final registry = KonataModalLayerRegistry();
  ref.onDispose(registry.dispose);
  return registry;
});

/// 宿主原生路由导航适配器（实现 [AppNavigator]，跨业务包仅传递强类型标识）。
final class HostAppNavigator implements AppNavigator {
  /// 创建宿主导航适配器。
  HostAppNavigator({
    required this.navigatorKey,
    required this.onSwitchNavSection,
    this.onOpenSettingsSection,
    this.onVideoStageVisibilityChanged,
    this.onAudioStageVisibilityChanged,
    this.onShowMessage,
    this.hasVideoFeature = true,
    this.hasAudioFeature = true,
  });

  /// 顶层原生路由导航键。
  final GlobalKey<NavigatorState> navigatorKey;

  /// 切换顶层主导航分区回调。
  final void Function(String sectionId) onSwitchNavSection;

  /// 透传目标设置子面板定位回调（供 `openSettings(sectionId: ...)` 精确定位）。
  final void Function(String? sectionId)? onOpenSettingsSection;

  /// 全屏视频舞台显隐变化回调（用于全屏覆盖时隐藏悬浮小窗并接管返回键）。
  final ValueChanged<bool>? onVideoStageVisibilityChanged;

  /// 全屏音频舞台显隐变化回调（用于全屏展示时隐藏悬浮迷你唱片并接管返回键）。
  final ValueChanged<bool>? onAudioStageVisibilityChanged;

  /// 宿主轻提示回调。
  final void Function(String message)? onShowMessage;

  /// 宿主是否已注册视频播放模块。
  final bool hasVideoFeature;

  /// 宿主是否已注册音频播放模块。
  final bool hasAudioFeature;

  @override
  Future<void> switchNavSection(String sectionId) async {
    final nav = navigatorKey.currentState;
    if (nav != null && nav.canPop()) {
      nav.popUntil((route) => route.isFirst);
    }
    onSwitchNavSection(sectionId);
  }

  @override
  Future<void> openWorkDetail(WorkId workId, {String? initialTabId}) async {
    final nav = navigatorKey.currentState;
    if (nav == null) return;
    await nav.push<void>(
      CupertinoPageRoute<void>(
        settings: RouteSettings(name: 'work_detail/${workId.value}'),
        builder: (_) => Material(
          type: MaterialType.transparency,
          child: buildWorkDetailRoutePage(
            workId: workId,
            initialTabId: initialTabId,
          ),
        ),
      ),
    );
  }

  @override
  Future<void> openVideoPlayer({
    required WorkId workId,
    EpisodeId? episodeId,
    VariantId? variantId,
  }) async {
    final nav = navigatorKey.currentState;
    if (nav == null) return;
    onVideoStageVisibilityChanged?.call(true);
    try {
      await nav.push<void>(
        CupertinoPageRoute<void>(
          settings: RouteSettings(name: 'video_player/${workId.value}'),
          builder: (_) => Material(
            type: MaterialType.transparency,
            child: buildVideoPlayerRoutePage(
              workId: workId,
              episodeId: episodeId,
              variantId: variantId,
              hasAudioFeature: hasAudioFeature,
              onClosePage: () {
                unawaited(pop());
              },
            ),
          ),
        ),
      );
    } finally {
      onVideoStageVisibilityChanged?.call(false);
    }
  }

  @override
  Future<void> openAudioPlayer({
    required WorkId workId,
    VariantId? variantId,
  }) async {
    await _pushAudioStage(workId: workId, variantId: variantId);
  }

  /// 从悬浮迷你唱片回弹展开当前已激活的音频全屏舞台（不重建既有解码会话）。
  Future<void> expandActiveAudioStage() async {
    await _pushAudioStage();
  }

  Future<void> _pushAudioStage({WorkId? workId, VariantId? variantId}) async {
    final nav = navigatorKey.currentState;
    if (nav == null) return;
    onAudioStageVisibilityChanged?.call(true);
    try {
      await nav.push<void>(
        CupertinoPageRoute<void>(
          settings: RouteSettings(
            name: workId == null
                ? 'audio_player/active'
                : 'audio_player/${workId.value}',
          ),
          builder: (_) => Material(
            type: MaterialType.transparency,
            child: buildAudioPlayerRoutePage(
              workId: workId,
              variantId: variantId,
              hasVideoFeature: hasVideoFeature,
              onClosePage: () {
                unawaited(pop());
              },
            ),
          ),
        ),
      );
    } finally {
      onAudioStageVisibilityChanged?.call(false);
    }
  }

  @override
  Future<void> openSettings({String? sectionId}) async {
    onOpenSettingsSection?.call(sectionId);
    await switchNavSection('settings');
  }

  @override
  Future<bool> pop() async {
    final nav = navigatorKey.currentState;
    if (nav == null || !nav.canPop()) return false;
    nav.pop();
    return true;
  }
}

/// 云端子集化已授权 Origin 持久化配置切片（设备本地保留，严禁跨设备同步）。
final TypedPrefsSlice<List<String>> _cloudSubsetOriginsSlice =
    TypedPrefsSlice<List<String>>(
      namespace: 'engine_playback.cloud_subset_origins',
      schemaVersion: 1,
      syncPolicy: SyncPolicy.deviceLocal,
      defaultValue: const <String>[],
      decode: (json, _) {
        final raw = json['origins'];
        if (raw is! List) return const <String>[];
        return List<String>.unmodifiable(<String>[
          for (final item in raw)
            if (item is String && item.trim().isNotEmpty) item.trim(),
        ]);
      },
      encode: (origins) => <String, Object?>{'origins': origins},
    );

/// 桌面外部播放器仓储延迟构建器签名（仅由 Windows 启动壳注入）。
typedef ExternalPlayerStoreBuilder =
    DesktopExternalPlayerStore Function(KonataDatabaseBundle databases);

/// 桌面外部播放器接力网关延迟构建器签名（仅由 Windows 启动壳注入）。
typedef DesktopRelayGatewayBuilder =
    DesktopRelayGateway Function({
      required DesktopExternalPlayerStore store,
      required LocalStreamBridgePort streamBridge,
      required MediaSourceGatewayFactoryPort gatewayFactory,
      required StorageRootPort storageRoot,
    });

/// 应用启动完成后的极薄底座与引擎装配上下文（供桌面端与移动端双入口共用）。
final class KonataBootstrapContext {
  /// 创建启动装配上下文。
  const KonataBootstrapContext({
    required this.platform,
    required this.storageRoot,
    required this.secureStorage,
    required this.diagnosticLog,
    required this.databases,
    required this.scopedPrefs,
    required this.domainEventBus,
    required this.featureRegistry,
    required this.filePicker,
    required this.backupFilePort,
    required this.urlOpener,
    required this.httpClient,
    required this.webDavPool,
    required this.cloudDriveSessions,
    required this.cloudTransport,
    this.cloudClientId = '',
    required this.gatewayFactory,
    required this.streamBridge,
    required this.subtitleDirectoryIndex,
    required this.warmupService,
    required this.photosStorage,
    required this.artworkCache,
    required this.playbackEngine,
    required this.audiophileCoordinator,
    required this.hostWindow,
    required this.cloudSubsetCoordinator,
    this.desktopSurfaceBridge,
    this.desktopRelayGateway,
    this.externalPlayerStore,
    this.desktopProfileDelegate,
    this.legacyCodePageDecoder,
    this.androidSurfacePort,
    this.androidAudioRoutePort,
    this.androidMediaSessionPort,
    this.androidAudioFocusPort,
    this.androidPipPort,
    this.mediaStorePublisher,
    this.pickExecutableFile,
    this.pickShaderFiles,
    this.autoStartDetailWarmupAndBackfill = true,
    this.customScanStreamOpener,
  });

  /// 当前宿主运行平台。
  final KonataPlatform platform;

  /// 存储根目录端口。
  final StorageRootPort storageRoot;

  /// 敏感凭据安全存储端口。
  final SecureStoragePort secureStorage;

  /// 统一脱敏诊断日志端口。
  final DiagnosticLogPort diagnosticLog;

  /// 三库物理分治生命周期总管（缓存库冷启动保持惰性未打开）。
  final KonataDatabaseBundle databases;

  /// 分命名空间自治配置存储器。
  final ScopedPrefsStore scopedPrefs;

  /// 低频领域事件总线。
  final DomainEventBus domainEventBus;

  /// 声明式扩展点注册表。
  final FeatureRegistry featureRegistry;

  /// 跨端系统文件与目录选择器端口。
  final FilePickerPort filePicker;

  /// 跨端备份与诊断报告文件存取端口。
  final BackupFilePort backupFilePort;

  /// 跨端外部链接打开端口。
  final UrlOpenerPort urlOpener;

  /// 统一网络客户端实例。
  final KonataHttpClientPort httpClient;

  /// 共享 WebDAV 连接池。
  final WebDavConnectionPool webDavPool;

  /// 宿主共享的本机云盘账号会话中心。
  final GuangYaSessionRegistry cloudDriveSessions;

  /// 云盘 API 连接池的宿主生命周期。
  final GuangYaHttpTransport cloudTransport;

  /// 获准用于既有协议的应用客户端配置；默认空值禁用真实登录。
  final String cloudClientId;

  /// 只读媒体源网关工厂。
  final MediaSourceGatewayFactory gatewayFactory;

  /// 本地安全回环流网桥。
  final LocalStreamBridge streamBridge;

  /// 同级字幕目录预热索引。
  final SubtitleDirectoryIndex subtitleDirectoryIndex;

  /// 详情页同级字幕与连接池静默预热服务。
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

  /// 云端字幕字体子集化按域协调器（持久化逐 Origin 授权）。
  final CloudSubsetCoordinator cloudSubsetCoordinator;

  /// 桌面端 D3D11 视频纹理共享桥接器（仅 Windows 注入）。
  final KonataVideoTextureBridge? desktopSurfaceBridge;

  /// 桌面端外部播放器接力网关（仅 Windows 注入）。
  final DesktopRelayGateway? desktopRelayGateway;

  /// 桌面端外部播放器持久化配置仓储（仅 Windows 注入）。
  final DesktopExternalPlayerStore? externalPlayerStore;

  /// 桌面端 `libmpv` 专属驱动与独占音频委托（仅 Windows 注入）。
  final MpvPlatformProfileDelegate? desktopProfileDelegate;

  /// 桌面端传统代码页字幕字节解码器（仅 Windows 注入）。
  final LegacyCodePageDecoder? legacyCodePageDecoder;

  /// 移动端底层视频表面控制器（仅 Android 注入）。
  final AndroidVideoSurfacePort? androidSurfacePort;

  /// 移动端音频路由与 USB DAC 直通协商端口（仅 Android 注入）。
  final AndroidAudioRoutePort? androidAudioRoutePort;

  /// 移动端系统通知栏媒体会话桥接器（仅 Android 注入）。
  final AndroidMediaSessionPort? androidMediaSessionPort;

  /// 移动端原生音频焦点管理端口（仅 Android 注入）。
  final AndroidAudioFocusPort? androidAudioFocusPort;

  /// 移动端原生画中画状态同步与控制端口（仅 Android 注入）。
  final AndroidPipPort? androidPipPort;

  /// 移动端相册发布端口（仅 Android 注入）。
  final MediaStorePublisherPort? mediaStorePublisher;

  /// 桌面端外部播放器可执行文件选择器回调（仅 Windows 注入）。
  final Future<String?> Function({String? dialogTitle})? pickExecutableFile;

  /// 跨端自定义渲染着色器脚本批量选择回调。
  final Future<List<HostPickedFile>> Function()? pickShaderFiles;

  /// 进入详情页后是否自动触发静默预热与正片缺失剧照抽帧补图。
  final bool autoStartDetailWarmupAndBackfill;

  /// 可选自定义扫图原图流读取器（供离线端到端集成测试注入）。
  final Object? customScanStreamOpener;

  /// 释放启动上下文托管的引擎、原生桥接与数据库资源。
  Future<void> dispose() async {
    cloudSubsetCoordinator.cancelAllCloudSubsetTasks();
    audiophileCoordinator.dispose();
    await desktopSurfaceBridge?.dispose();
    await androidSurfacePort?.dispose();
    androidAudioRoutePort?.dispose();
    androidMediaSessionPort?.dispose();
    androidAudioFocusPort?.dispose();
    androidPipPort?.unbindCallbacks();
    httpClient.close();
    await streamBridge.close();
    await cloudDriveSessions.close();
    cloudTransport.close();
    await domainEventBus.dispose();
    await databases.close();
  }

  /// 生成顶层依赖注入覆写列表（将宿主底座、引擎与全部已注册业务模块装配至根容器）。
  List<Override> toProviderOverrides({
    required AppNavigator navigator,
    ValueChanged<ThemeMode>? onThemeModeChanged,
    ValueChanged<bool>? onAmbientBackdropChanged,
    ValueChanged<KonataWindowMaterial>? onWindowMaterialChanged,
  }) {
    final wiring = FeatureRuntimeWiring(
      platform: platform,
      databases: databases,
      storageRoot: storageRoot,
      secureStorage: secureStorage,
      diagnosticLog: diagnosticLog,
      scopedPrefs: scopedPrefs,
      domainEventBus: domainEventBus,
      featureRegistry: featureRegistry,
      listCloudAccountLocations: () async => [
        for (final account
            in await cloudDriveSessions.credentials.listAccounts())
          Uri(scheme: 'guangyapan', host: account).toString(),
      ],
      createCloudSignIn: cloudClientId.trim().isEmpty
          ? null
          : (expectedLocation) => GuangYaAccountSignIn(
              sessions: cloudDriveSessions,
              clientId: cloudClientId.trim(),
              expectedLocation: expectedLocation,
            ),
      navigator: navigator,
      filePicker: filePicker,
      backupFilePort: backupFilePort,
      urlOpener: urlOpener,
      httpClient: httpClient,
      webDavPool: webDavPool,
      gatewayFactory: gatewayFactory,
      streamBridge: streamBridge,
      subtitleDirectoryIndex: subtitleDirectoryIndex,
      warmupService: warmupService,
      photosStorage: photosStorage,
      artworkCache: artworkCache,
      playbackEngine: playbackEngine,
      audiophileCoordinator: audiophileCoordinator,
      hostWindow: hostWindow,
      desktopSurfaceBridge: desktopSurfaceBridge,
      desktopRelayGateway: desktopRelayGateway,
      externalPlayerStore: externalPlayerStore,
      desktopProfileDelegate: desktopProfileDelegate,
      legacyCodePageDecoder: legacyCodePageDecoder,
      cloudSubsetCoordinator: cloudSubsetCoordinator,
      androidSurfacePort: androidSurfacePort,
      androidMediaSessionPort: androidMediaSessionPort,
      mediaStorePublisher: mediaStorePublisher,
      pickExecutableFile: pickExecutableFile,
      pickShaderFiles: pickShaderFiles,
      autoStartDetailWarmupAndBackfill: autoStartDetailWarmupAndBackfill,
      customScanStreamOpener: customScanStreamOpener,
      onThemeModeChanged: onThemeModeChanged,
      onAmbientBackdropChanged: onAmbientBackdropChanged,
      onWindowMaterialChanged: onWindowMaterialChanged,
    );
    return <Override>[
      konataPlatformProvider.overrideWithValue(platform),
      storageRootPortProvider.overrideWithValue(storageRoot),
      secureStoragePortProvider.overrideWithValue(secureStorage),
      diagnosticLogPortProvider.overrideWithValue(diagnosticLog),
      databaseBundleProvider.overrideWithValue(databases),
      scopedPrefsStoreProvider.overrideWithValue(scopedPrefs),
      domainEventBusProvider.overrideWithValue(domainEventBus),
      featureRegistryProvider.overrideWithValue(featureRegistry),
      appNavigatorProvider.overrideWithValue(navigator),
      ...buildFeatureProviderOverrides(wiring),
    ];
  }

  /// 统一初始化三库（缓存库惰性不打开）、启动预加载网络凭据、配置切片、核心引擎、事件总线与诊断日志。
  static Future<KonataBootstrapContext> initialize({
    required KonataPlatform platform,
    required StorageRootPort storageRoot,
    required SecureStoragePort secureStorage,
    FeatureRegistry? featureRegistry,
    FilePickerPort? filePicker,
    BackupFilePort? backupFilePort,
    UrlOpenerPort? urlOpener,
    KonataHttpClientPort? httpClient,
    GuangYaRequest? cloudDriveRequest,
    String cloudClientId = const String.fromEnvironment(
      'KONATA_GUANGYA_LEGACY_CLIENT_ID',
    ),
    PlaybackHostWindowPort? hostWindow,
    KonataVideoTextureBridge? desktopSurfaceBridge,
    DesktopExternalPlayerStore? externalPlayerStore,
    ExternalPlayerStoreBuilder? externalPlayerStoreBuilder,
    DesktopRelayGateway? desktopRelayGateway,
    DesktopRelayGatewayBuilder? desktopRelayGatewayBuilder,
    MpvPlatformProfileDelegate? desktopProfileDelegate,
    LegacyCodePageDecoder? legacyCodePageDecoder,
    CloudSubsetCoordinator? cloudSubsetCoordinator,
    AndroidVideoSurfacePort? androidSurfacePort,
    AndroidAudioRoutePort? androidAudioRoutePort,
    AndroidMediaSessionPort? androidMediaSessionPort,
    AndroidAudioFocusPort? androidAudioFocusPort,
    AndroidPipPort? androidPipPort,
    MediaStorePublisherPort? mediaStorePublisher,
    Future<String?> Function({String? dialogTitle})? pickExecutableFile,
    Future<List<HostPickedFile>> Function()? pickShaderFiles,
    bool useInMemoryDatabases = false,
    bool autoStartDetailWarmupAndBackfill = true,
    Object? customScanStreamOpener,
  }) async {
    final diagnosticLog = DiagnosticLogStore();
    const assetLoader = HostAssetDataLoader();
    PlaybackTableAssets.configure(assetLoader);
    ReleaseGroups.configure(assetLoader);
    configureFeatureDataAssets(assetLoader);
    await BangumiTmdbIndex.loadBundled(assetLoader);
    final databases = useInMemoryDatabases
        ? KonataDatabaseBundle.openInMemory()
        : await KonataDatabaseBundle.openFromStorageRoot(storageRoot);
    final scopedPrefs = ScopedPrefsStore(databases.userState);
    final eventBus = InMemoryDomainEventBus();
    final rootPath = await storageRoot.resolveAppRootPath();

    final resolvedHttpClient =
        httpClient ??
        KonataHttpClient(
          config: const KonataNetworkConfig(),
          diagnosticLog: diagnosticLog,
        );
    // 启动阶段立即预加载已保存的 TMDB/Fanart 密钥、代理与镜像，避免重启后未点设置页即扫库失败。
    await preloadFeatureRuntimeSettings(
      scopedPrefs: scopedPrefs,
      secureStorage: secureStorage,
      httpClient: resolvedHttpClient,
      diagnosticLog: diagnosticLog,
    );

    final registry =
        featureRegistry ??
        FeatureRegistry.forRuntime(
          databases: databases,
          scopedPrefs: scopedPrefs,
          httpClient: resolvedHttpClient,
        );
    final credentialStore = SourceCredentialStore(storage: secureStorage);
    final webDavPool = WebDavConnectionPool();
    final cloudTransport = GuangYaHttpTransport(
      config: () => resolvedHttpClient.config,
    );
    final cloudDriveSessions = GuangYaSessionRegistry(
      credentials: GuangYaCredentialStore(secureStorage),
      request: cloudDriveRequest ?? cloudTransport.request,
      createHttpClient: cloudTransport.createClient,
    );
    final gatewayFactory = MediaSourceGatewayFactory(
      credentialStore: credentialStore,
      webDavPool: webDavPool,
      cloudDriveProviders: [cloudDriveSessions.contribution],
    );
    final streamBridge = LocalStreamBridge(storageRoot: storageRoot);
    final subtitleDirectoryIndex = SubtitleDirectoryIndex();
    final warmupService = WorkDetailWarmupService(
      gatewayFactory: gatewayFactory,
      directoryIndex: subtitleDirectoryIndex,
    );
    final photosStorage = PhotosStorage(
      storageRoot: storageRoot,
      onEvictImageFile: (file) async {
        try {
          await FileImage(file).evict();
        } catch (_) {
          // 图像绑定未初始化时静默忽略内存驱逐。
        }
      },
    );
    final artworkCache = ArtworkDiskCache(photosStorage: photosStorage);
    final playbackEngine = UnifiedPlaybackEngine();
    final audiophileCoordinator = AudiophileSafetyCoordinator(
      engine: playbackEngine,
      logStore: diagnosticLog,
      androidRouteBridge: androidAudioRoutePort,
      isWindowsOverride: platform == KonataPlatform.windows,
      isAndroidOverride: platform != KonataPlatform.windows,
    );

    final resolvedExternalStore =
        externalPlayerStore ?? externalPlayerStoreBuilder?.call(databases);
    final resolvedRelayGateway =
        desktopRelayGateway ??
        (resolvedExternalStore == null || desktopRelayGatewayBuilder == null
            ? null
            : desktopRelayGatewayBuilder(
                store: resolvedExternalStore,
                streamBridge: streamBridge,
                gatewayFactory: gatewayFactory,
                storageRoot: storageRoot,
              ));

    final resolvedCloudSubset =
        cloudSubsetCoordinator ??
        CloudSubsetCoordinator(
          playbackEngine: playbackEngine,
          cloudClient: FontInAssCloudClient(
            authorizationStore: CloudSubsetAuthorizationStore(
              onLoad: () async => scopedPrefs.read(_cloudSubsetOriginsSlice),
              onPersist: (originKeys) async {
                scopedPrefs.write(_cloudSubsetOriginsSlice, originKeys);
              },
            ),
            storageRoot: storageRoot,
          ),
        );

    const defaultPicker = HostFilePickerAdapter();

    diagnosticLog.registerSnapshotContributor(
      'bootstrap',
      () => DiagnosticSnapshotSection(
        id: 'bootstrap',
        title: '底座启动态',
        entries: <String, String>{
          'platform': platform.name,
          'rootPath': rootPath,
          'cacheDbOpen': databases.isCacheOpen.toString(),
          'registeredFeatures': registry.manifests.length.toString(),
          'desktopRelayWired': (resolvedRelayGateway != null).toString(),
        },
      ),
    );
    diagnosticLog.logEvent(
      subsystem: DiagnosticSubsystem.app,
      code: 'APP_BOOTSTRAP_READY',
      message: 'Konata v3 底座、引擎与全部业务模块初始化完成',
      source: 'apps/konata/lib/bootstrap/app_bootstrap.dart:initialize',
      context: <String, Object?>{
        'platform': platform.name,
        'cacheDbOpen': databases.isCacheOpen,
        'featureCount': registry.manifests.length,
      },
    );

    return KonataBootstrapContext(
      platform: platform,
      storageRoot: storageRoot,
      secureStorage: secureStorage,
      diagnosticLog: diagnosticLog,
      databases: databases,
      scopedPrefs: scopedPrefs,
      domainEventBus: eventBus,
      featureRegistry: registry,
      filePicker: filePicker ?? defaultPicker,
      backupFilePort: backupFilePort ?? defaultPicker,
      urlOpener: urlOpener ?? const HostUrlOpenerAdapter(),
      httpClient: resolvedHttpClient,
      webDavPool: webDavPool,
      cloudDriveSessions: cloudDriveSessions,
      cloudTransport: cloudTransport,
      cloudClientId: cloudClientId,
      gatewayFactory: gatewayFactory,
      streamBridge: streamBridge,
      subtitleDirectoryIndex: subtitleDirectoryIndex,
      warmupService: warmupService,
      photosStorage: photosStorage,
      artworkCache: artworkCache,
      playbackEngine: playbackEngine,
      audiophileCoordinator: audiophileCoordinator,
      hostWindow: hostWindow ?? const NoopPlaybackHostWindowPort(),
      cloudSubsetCoordinator: resolvedCloudSubset,
      desktopSurfaceBridge: desktopSurfaceBridge,
      desktopRelayGateway: resolvedRelayGateway,
      externalPlayerStore: resolvedExternalStore,
      desktopProfileDelegate: desktopProfileDelegate,
      legacyCodePageDecoder: legacyCodePageDecoder,
      androidSurfacePort: androidSurfacePort,
      androidAudioRoutePort: androidAudioRoutePort,
      androidMediaSessionPort: androidMediaSessionPort,
      androidAudioFocusPort: androidAudioFocusPort,
      androidPipPort: androidPipPort,
      mediaStorePublisher: mediaStorePublisher,
      pickExecutableFile: pickExecutableFile,
      pickShaderFiles: pickShaderFiles,
      autoStartDetailWarmupAndBackfill: autoStartDetailWarmupAndBackfill,
      customScanStreamOpener: customScanStreamOpener,
    );
  }
}

/// Konata v3 双端极薄组装根组件（挂载三端同源主题、自适应外壳、声明式扩展点与原生导航）。
final class KonataBootstrapApp extends StatefulWidget {
  /// 创建挂载指定启动上下文的根组件。
  const KonataBootstrapApp({
    super.key,
    required this.bootstrap,
    required this.platformLabel,
    this.windowHost,
  });

  /// 已初始化的底座上下文。
  final KonataBootstrapContext bootstrap;

  /// 当前宿主平台显示名称。
  final String platformLabel;

  /// 可选桌面无框窗口宿主端口（仅 Windows 入口传入，Android 端保持为 `null`）。
  final KonataDesktopWindowHostPort? windowHost;

  @override
  State<KonataBootstrapApp> createState() => _KonataBootstrapAppState();
}

final class _KonataBootstrapAppState extends State<KonataBootstrapApp> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final ValueNotifier<String> _requestedSectionId = ValueNotifier<String>('');
  final ValueNotifier<String?> _requestedSettingsSectionId =
      ValueNotifier<String?>(null);
  final ValueNotifier<int> _settingsDeepLinkPulse = ValueNotifier<int>(0);
  final ValueNotifier<String> _pendingToast = ValueNotifier<String>('');
  final ValueNotifier<bool> _videoStageOpen = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _audioStageOpen = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _fullscreenMediaActive = ValueNotifier<bool>(false);
  late final ValueNotifier<HostAppearanceState> _appearanceNotifier;
  late final HostAppNavigator _navigator;

  @override
  void initState() {
    super.initState();
    _appearanceNotifier = ValueNotifier<HostAppearanceState>(
      readInitialAppearancePrefs(widget.bootstrap.scopedPrefs),
    );
    _navigator = HostAppNavigator(
      navigatorKey: _navigatorKey,
      hasVideoFeature: widget.bootstrap.featureRegistry.containsFeature(
        'feature_player_video',
      ),
      hasAudioFeature: widget.bootstrap.featureRegistry.containsFeature(
        'feature_player_audio',
      ),
      onSwitchNavSection: (sectionId) {
        _requestedSectionId.value = sectionId;
      },
      onOpenSettingsSection: (sectionId) {
        _requestedSettingsSectionId.value = sectionId;
        _settingsDeepLinkPulse.value += 1;
      },
      onVideoStageVisibilityChanged: (opened) {
        _videoStageOpen.value = opened;
        _syncFullscreenMediaFlag();
      },
      onAudioStageVisibilityChanged: (opened) {
        _audioStageOpen.value = opened;
        _syncFullscreenMediaFlag();
      },
      onShowMessage: (message) {
        _pendingToast.value = message;
      },
    );
  }

  void _syncFullscreenMediaFlag() {
    _fullscreenMediaActive.value =
        _videoStageOpen.value || _audioStageOpen.value;
  }

  void _updateAppearance(HostAppearanceState next, {bool persist = false}) {
    _appearanceNotifier.value = next;
    if (persist) {
      saveAppearancePrefs(widget.bootstrap.scopedPrefs, next);
    }
    final host = widget.windowHost;
    if (host != null) {
      unawaited(
        host.applyMaterial(
          themeMode: next.themeMode,
          platformBrightness:
              WidgetsBinding.instance.platformDispatcher.platformBrightness,
          material: next.windowMaterial,
        ),
      );
    }
  }

  @override
  void dispose() {
    _requestedSectionId.dispose();
    _requestedSettingsSectionId.dispose();
    _settingsDeepLinkPulse.dispose();
    _pendingToast.dispose();
    _videoStageOpen.dispose();
    _audioStageOpen.dispose();
    _fullscreenMediaActive.dispose();
    _appearanceNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: widget.bootstrap.toProviderOverrides(
        navigator: _navigator,
        onThemeModeChanged: (mode) {
          _updateAppearance(
            _appearanceNotifier.value.copyWith(themeMode: mode),
          );
        },
        onAmbientBackdropChanged: (enabled) {
          _updateAppearance(
            _appearanceNotifier.value.copyWith(ambientBackdropEnabled: enabled),
          );
        },
        onWindowMaterialChanged: (material) {
          _updateAppearance(
            _appearanceNotifier.value.copyWith(windowMaterial: material),
          );
        },
      ),
      child: _KonataBootstrapRoot(
        bootstrap: widget.bootstrap,
        platformLabel: widget.platformLabel,
        navigatorKey: _navigatorKey,
        hostNavigator: _navigator,
        windowHost: widget.windowHost,
        requestedSectionId: _requestedSectionId,
        requestedSettingsSectionId: _requestedSettingsSectionId,
        settingsDeepLinkPulse: _settingsDeepLinkPulse,
        pendingToast: _pendingToast,
        videoStageOpen: _videoStageOpen,
        audioStageOpen: _audioStageOpen,
        fullscreenMediaActive: _fullscreenMediaActive,
        appearanceNotifier: _appearanceNotifier,
        onToggleTheme: () {
          final current = _appearanceNotifier.value;
          final nextMode = current.themeMode == ThemeMode.dark
              ? ThemeMode.light
              : ThemeMode.dark;
          _updateAppearance(
            current.copyWith(themeMode: nextMode),
            persist: true,
          );
        },
      ),
    );
  }
}

final class _KonataBootstrapRoot extends ConsumerStatefulWidget {
  const _KonataBootstrapRoot({
    required this.bootstrap,
    required this.platformLabel,
    required this.navigatorKey,
    required this.hostNavigator,
    required this.requestedSectionId,
    required this.requestedSettingsSectionId,
    required this.settingsDeepLinkPulse,
    required this.pendingToast,
    required this.videoStageOpen,
    required this.audioStageOpen,
    required this.fullscreenMediaActive,
    required this.appearanceNotifier,
    required this.onToggleTheme,
    this.windowHost,
  });

  final KonataBootstrapContext bootstrap;
  final String platformLabel;
  final GlobalKey<NavigatorState> navigatorKey;
  final HostAppNavigator hostNavigator;
  final KonataDesktopWindowHostPort? windowHost;
  final ValueNotifier<String> requestedSectionId;
  final ValueNotifier<String?> requestedSettingsSectionId;
  final ValueNotifier<int> settingsDeepLinkPulse;
  final ValueNotifier<String> pendingToast;
  final ValueNotifier<bool> videoStageOpen;
  final ValueNotifier<bool> audioStageOpen;
  final ValueNotifier<bool> fullscreenMediaActive;
  final ValueNotifier<HostAppearanceState> appearanceNotifier;
  final VoidCallback onToggleTheme;

  @override
  ConsumerState<_KonataBootstrapRoot> createState() =>
      _KonataBootstrapRootState();
}

final class _KonataBootstrapRootState
    extends ConsumerState<_KonataBootstrapRoot>
    with WidgetsBindingObserver {
  final ValueNotifier<bool> _windowLiveResizing = ValueNotifier<bool>(false);
  final ValueNotifier<FloatingMiniPlayerKind> _activeMiniKind =
      ValueNotifier<FloatingMiniPlayerKind>(FloatingMiniPlayerKind.none);
  late final ThemeData _darkTheme = KonataTheme.darkTheme();
  late final ThemeData _lightTheme = KonataTheme.lightTheme();
  late final KonataDiagnosticRouteObserver _routeObserver =
      KonataDiagnosticRouteObserver(widget.bootstrap.diagnosticLog);

  HostDiagnosticsRuntimeBridge? _diagnosticsBridge;
  void Function()? _unbindResizeChannel;
  Timer? _ongoingSyncStartupTimer;

  int _selectedIndex = 0;
  String _searchQuery = '';
  bool _mobileSettingsDetailOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.requestedSectionId.addListener(_handleExternalNavRequest);
    widget.settingsDeepLinkPulse.addListener(_handleSettingsDeepLinkChanged);
    widget.pendingToast.addListener(_handlePendingToast);

    _unbindResizeChannel = widget.windowHost?.bindLiveResizeChannel(
      _windowLiveResizing,
      onMinimized: _trimImageCaches,
    );
    _diagnosticsBridge = HostDiagnosticsRuntimeBridge(
      diagnosticLog: widget.bootstrap.diagnosticLog,
      databases: widget.bootstrap.databases,
      httpClient: widget.bootstrap.httpClient,
      uiSnapshotProvider: _buildUiDiagnosticSnapshot,
    );

    // 同步当前桌面 DWM 材质与系统明暗状态。
    final host = widget.windowHost;
    if (host != null) {
      final appearance = widget.appearanceNotifier.value;
      unawaited(
        host.applyMaterial(
          themeMode: appearance.themeMode,
          platformBrightness:
              WidgetsBinding.instance.platformDispatcher.platformBrightness,
          material: appearance.windowMaterial,
        ),
      );
    }

    // 启动后错峰 5 秒触发连载追更静默巡检（销毁时自动取消，避免测试悬空定时器）。
    if (widget.bootstrap.autoStartDetailWarmupAndBackfill) {
      _ongoingSyncStartupTimer = Timer(const Duration(seconds: 5), () {
        if (!mounted) return;
        triggerOngoingWorksAutoSync(ref, widget.bootstrap.featureRegistry);
      });
    }
  }

  @override
  void didChangePlatformBrightness() {
    final host = widget.windowHost;
    if (host == null) return;
    final appearance = widget.appearanceNotifier.value;
    if (appearance.themeMode == ThemeMode.system) {
      unawaited(
        host.applyMaterial(
          themeMode: appearance.themeMode,
          platformBrightness:
              WidgetsBinding.instance.platformDispatcher.platformBrightness,
          material: appearance.windowMaterial,
        ),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _trimImageCaches();
    }
    if (state == AppLifecycleState.resumed &&
        widget.bootstrap.autoStartDetailWarmupAndBackfill) {
      triggerOngoingWorksAutoSync(ref, widget.bootstrap.featureRegistry);
    }
  }

  @override
  void didHaveMemoryPressure() => _trimImageCaches();

  void _trimImageCaches() {
    konataSharedThumbnailByteLru.clear();
    PaintingBinding.instance.imageCache.clear();
  }

  @override
  void dispose() {
    _ongoingSyncStartupTimer?.cancel();
    _ongoingSyncStartupTimer = null;
    _unbindResizeChannel?.call();
    _unbindResizeChannel = null;
    _diagnosticsBridge?.dispose();
    _diagnosticsBridge = null;
    WidgetsBinding.instance.removeObserver(this);
    widget.requestedSectionId.removeListener(_handleExternalNavRequest);
    widget.settingsDeepLinkPulse.removeListener(_handleSettingsDeepLinkChanged);
    widget.pendingToast.removeListener(_handlePendingToast);
    _windowLiveResizing.dispose();
    _activeMiniKind.dispose();
    super.dispose();
  }

  Map<String, String> _buildUiDiagnosticSnapshot() {
    final appearance = widget.appearanceNotifier.value;
    return <String, String>{
      'platformLabel': widget.platformLabel,
      'selectedTabIndex': _selectedIndex.toString(),
      'themeMode': appearance.themeMode.name,
      'ambientBackdropEnabled': appearance.ambientBackdropEnabled.toString(),
      'windowMaterial': appearance.windowMaterial.name,
      'videoStageOpen': widget.videoStageOpen.value.toString(),
      'audioStageOpen': widget.audioStageOpen.value.toString(),
      'activeMiniKind': _activeMiniKind.value.name,
    };
  }

  void _handleExternalNavRequest() {
    final targetId = widget.requestedSectionId.value.trim();
    if (targetId.isEmpty) return;
    final entries = _resolveNavEntries();
    final idx = entries.indexWhere((e) => e.id == targetId);
    if (idx >= 0 && mounted) {
      setState(() => _selectedIndex = idx);
    }
    widget.requestedSectionId.value = '';
  }

  void _handleSettingsDeepLinkChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _handlePendingToast() {
    final msg = widget.pendingToast.value.trim();
    if (msg.isEmpty) return;
    ref.read(toastControllerProvider).show(msg);
    widget.pendingToast.value = '';
  }

  List<_ShellNavEntry> _resolveNavEntries() {
    final registry = ref.read(featureRegistryProvider);
    final platform = ref.read(konataPlatformProvider);
    final registered = registry.navSectionsFor(platform);
    final byId = <String, NavSectionContribution>{
      for (final section in registered) section.id: section,
    };

    final entries = <_ShellNavEntry>[
      for (final section in registered)
        _ShellNavEntry(
          id: section.id,
          item: KonataNavItem(
            id: section.id,
            label: section.label,
            icon: KonataIconRegistry.resolve(section.iconKey),
          ),
          contribution: section,
        ),
    ];

    for (final fallback in KonataNavItem.defaults) {
      if (!byId.containsKey(fallback.id)) {
        entries.add(_ShellNavEntry(id: fallback.id, item: fallback));
      }
    }
    return entries;
  }

  @override
  Widget build(BuildContext context) {
    final toastController = ref.watch(toastControllerProvider);
    final modalRegistry = ref.watch(modalLayerRegistryProvider);
    final registry = ref.watch(featureRegistryProvider);
    final platform = ref.watch(konataPlatformProvider);
    final databases = ref.watch(databaseBundleProvider);
    activateRegisteredFeatureServices(ref, registry);

    final lane = KonataLaneConfig.resolveLane();
    final title = lane.isEmpty
        ? 'Konata v3 (${widget.platformLabel})'
        : 'Konata v3 (${widget.platformLabel}) [${lane.toUpperCase()}]';

    final navEntries = _resolveNavEntries();
    final safeIndex = navEntries.isEmpty
        ? 0
        : _selectedIndex.clamp(0, navEntries.length - 1);
    final libraryIndex = navEntries.indexWhere((e) => e.id == 'library');
    final windowHost = widget.windowHost;

    return KonataDesktopWindowChromeScope(
      windowControlsBuilder: windowHost == null
          ? null
          : ({bool forceLightIcons = false, bool showGlassPill = false}) =>
                windowHost.buildWindowControls(
                  forceLightIcons: forceLightIcons,
                  showGlassPill: showGlassPill,
                ),
      dragToMoveBuilder: windowHost == null
          ? null
          : ({required Widget child}) =>
                windowHost.buildDragToMoveArea(child: child),
      child: KonataWindowResizeScope(
        resizingListenable: _windowLiveResizing,
        child: KonataModalLayerScope(
          registry: modalRegistry,
          child: KonataToastScope(
            controller: toastController,
            child: KonataRootBackGate(
              fullscreenMediaActive: widget.fullscreenMediaActive,
              canPopRootNavigator: () =>
                  widget.navigatorKey.currentState?.canPop() ?? false,
              onInterceptBack: () => handleFullscreenMediaBackIntercept(
                ref,
                registry,
                videoStageOpen: widget.videoStageOpen.value,
                audioStageOpen: widget.audioStageOpen.value,
                onPopCurrentRoute: () {
                  unawaited(widget.hostNavigator.pop());
                },
              ),
              child: ValueListenableBuilder<HostAppearanceState>(
                valueListenable: widget.appearanceNotifier,
                builder: (context, appearance, _) {
                  return MaterialApp(
                    navigatorKey: widget.navigatorKey,
                    navigatorObservers: <NavigatorObserver>[_routeObserver],
                    scrollBehavior: const KonataScrollBehavior(),
                    debugShowCheckedModeBanner: false,
                    title: KonataLaneConfig.resolveDesktopWindowTitle(),
                    locale: const Locale('zh', 'CN'),
                    supportedLocales: const <Locale>[Locale('zh', 'CN')],
                    localizationsDelegates:
                        GlobalMaterialLocalizations.delegates,
                    theme: _lightTheme,
                    darkTheme: _darkTheme,
                    themeMode: appearance.themeMode,
                    builder: (context, child) => AndroidScrollCaptureScope(
                      navigatorKey: widget.navigatorKey,
                      child: Stack(
                        children: <Widget>[
                          ?child,
                          ValueListenableBuilder<bool>(
                            valueListenable: widget.videoStageOpen,
                            builder: (context, videoOpened, _) {
                              return ValueListenableBuilder<bool>(
                                valueListenable: widget.audioStageOpen,
                                builder: (context, audioOpened, _) {
                                  return Material(
                                    type: MaterialType.transparency,
                                    child: buildHostFloatingPlaybackOverlay(
                                      registry: registry,
                                      platform: platform,
                                      videoStageOpen: videoOpened,
                                      audioStageOpen: audioOpened,
                                      androidAudioFocusPort: widget
                                          .bootstrap
                                          .androidAudioFocusPort,
                                      androidPipPort:
                                          widget.bootstrap.androidPipPort,
                                      onActiveMiniKindChanged: (kind) {
                                        if (_activeMiniKind.value != kind) {
                                          _activeMiniKind.value = kind;
                                        }
                                      },
                                      onExpandVideoStage:
                                          (workId, episodeId, variantId) {
                                            unawaited(
                                              widget.hostNavigator
                                                  .openVideoPlayer(
                                                    workId: workId,
                                                    episodeId: episodeId,
                                                    variantId: variantId,
                                                  ),
                                            );
                                          },
                                      onExpandAudioStage: () {
                                        unawaited(
                                          widget.hostNavigator
                                              .expandActiveAudioStage(),
                                        );
                                      },
                                    ),
                                  );
                                },
                              );
                            },
                          ),
                          const KonataToastViewport(),
                        ],
                      ),
                    ),
                    home: ValueListenableBuilder<FloatingMiniPlayerKind>(
                      valueListenable: _activeMiniKind,
                      builder: (context, activeMiniKind, _) {
                        return KonataAdaptiveShell(
                          navItems: <KonataNavItem>[
                            for (final entry in navEntries) entry.item,
                          ],
                          selectedIndex: safeIndex,
                          onSelectedIndexChanged: (index) {
                            setState(() {
                              _selectedIndex = index;
                              if (navEntries[index].id != 'settings') {
                                _mobileSettingsDetailOpen = false;
                              }
                            });
                          },
                          onToggleTheme: widget.onToggleTheme,
                          searchQuery: _searchQuery,
                          searchPageIndex: libraryIndex >= 0 ? libraryIndex : 0,
                          onSearchChanged: (value) {
                            setState(() => _searchQuery = value);
                          },
                          navigationHidden:
                              _mobileSettingsDetailOpen &&
                              navEntries[safeIndex].id == 'settings',
                          desktopAmbientBackdropEnabled:
                              appearance.ambientBackdropEnabled,
                          miniKind: activeMiniKind,
                          windowDragBackground: windowHost?.buildDragToMoveArea(
                            child: const SizedBox.expand(),
                          ),
                          trailingWindowControls: windowHost
                              ?.buildWindowControls(),
                          pages: <Widget>[
                            for (final entry in navEntries)
                              if (entry.contribution != null)
                                Builder(
                                  builder: (slotBuildContext) {
                                    final rendered = entry.contribution!.viewBuilder(
                                      ViewSlotContext(
                                        platformContext: slotBuildContext,
                                        arguments: <String, Object?>{
                                          if (entry.id == 'library')
                                            'searchQuery': _searchQuery,
                                          if (entry.id ==
                                              'settings') ...<String, Object?>{
                                            'initialSectionId': widget
                                                .requestedSettingsSectionId
                                                .value,
                                            'deepLinkPulse': widget
                                                .settingsDeepLinkPulse
                                                .value,
                                            'onDetailVisibilityChanged':
                                                (bool visible) {
                                                  if (_mobileSettingsDetailOpen !=
                                                          visible &&
                                                      mounted) {
                                                    setState(
                                                      () =>
                                                          _mobileSettingsDetailOpen =
                                                              visible,
                                                    );
                                                  }
                                                },
                                          },
                                        },
                                      ),
                                    );
                                    return rendered is Widget
                                        ? rendered
                                        : const SizedBox.shrink();
                                  },
                                )
                              else
                                _FoundationStatusPage(
                                  title: title,
                                  sectionLabel: entry.item.label,
                                  registeredFeatures: registry.manifests.length,
                                  cacheDbOpen: databases.isCacheOpen,
                                ),
                          ],
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _ShellNavEntry {
  const _ShellNavEntry({
    required this.id,
    required this.item,
    this.contribution,
  });

  final String id;
  final KonataNavItem item;
  final NavSectionContribution? contribution;
}

final class _FoundationStatusPage extends StatelessWidget {
  const _FoundationStatusPage({
    required this.title,
    required this.sectionLabel,
    required this.registeredFeatures,
    required this.cacheDbOpen,
  });

  final String title;
  final String sectionLabel;
  final int registeredFeatures;
  final bool cacheDbOpen;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Center(
      child: KonataSurfaceCard(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(title, style: KonataTheme.h2Style(p)),
            const SizedBox(height: 8),
            Text(
              '当前分区：$sectionLabel · 扩展模块 $registeredFeatures · '
              '缓存库惰性态=${cacheDbOpen ? '已开' : '未开'}',
              style: KonataTheme.captionStyle(p),
            ),
          ],
        ),
      ),
    );
  }
}
