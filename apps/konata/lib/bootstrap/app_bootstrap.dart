import 'dart:async';

import 'package:engine_playback/engine_playback.dart';
import 'package:engine_sources/engine_sources.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';
import 'package:konata_storage/konata_storage.dart';

import 'feature_registry.dart';
import 'host_storage_adapters.dart';

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
    this.onAudioStageVisibilityChanged,
    this.onShowMessage,
  });

  /// 顶层原生路由导航键。
  final GlobalKey<NavigatorState> navigatorKey;

  /// 切换顶层主导航分区回调。
  final void Function(String sectionId) onSwitchNavSection;

  /// 全屏音频舞台显隐变化回调（用于全屏展示时隐藏悬浮迷你唱片）。
  final ValueChanged<bool>? onAudioStageVisibilityChanged;

  /// 宿主轻提示回调。
  final void Function(String message)? onShowMessage;

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
        builder: (_) => buildWorkDetailRoutePage(
          workId: workId,
          initialTabId: initialTabId,
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
    await nav.push<void>(
      CupertinoPageRoute<void>(
        builder: (_) => buildVideoPlayerRoutePage(
          workId: workId,
          episodeId: episodeId,
          variantId: variantId,
        ),
      ),
    );
  }

  @override
  Future<void> openAudioPlayer({
    required WorkId workId,
    VariantId? variantId,
  }) async {
    final nav = navigatorKey.currentState;
    if (nav == null) return;
    onAudioStageVisibilityChanged?.call(true);
    try {
      await nav.push<void>(
        CupertinoPageRoute<void>(
          builder: (_) => buildAudioPlayerRoutePage(
            workId: workId,
            variantId: variantId,
            onClosePage: () {
              unawaited(pop());
            },
          ),
        ),
      );
    } finally {
      onAudioStageVisibilityChanged?.call(false);
    }
  }

  @override
  Future<void> openSettings({String? sectionId}) async {
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
    required this.gatewayFactory,
    required this.streamBridge,
    required this.subtitleDirectoryIndex,
    required this.warmupService,
    required this.photosStorage,
    required this.artworkCache,
    required this.playbackEngine,
    required this.audiophileCoordinator,
    required this.hostWindow,
    this.desktopSurfaceBridge,
    this.androidSurfacePort,
    this.androidAudioRoutePort,
    this.androidMediaSessionPort,
    this.mediaStorePublisher,
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

  /// 桌面端 D3D11 视频纹理共享桥接器（仅 Windows 注入）。
  final KonataVideoTextureBridge? desktopSurfaceBridge;

  /// 移动端底层视频表面控制器（仅 Android 注入）。
  final AndroidVideoSurfacePort? androidSurfacePort;

  /// 移动端音频路由与 USB DAC 直通协商端口（仅 Android 注入）。
  final AndroidAudioRoutePort? androidAudioRoutePort;

  /// 移动端系统通知栏媒体会话桥接器（仅 Android 注入）。
  final AndroidMediaSessionPort? androidMediaSessionPort;

  /// 移动端相册发布端口（仅 Android 注入）。
  final MediaStorePublisherPort? mediaStorePublisher;

  /// 进入详情页后是否自动触发静默预热与正片缺失剧照抽帧补图。
  final bool autoStartDetailWarmupAndBackfill;

  /// 可选自定义扫图原图流读取器（供离线端到端集成测试注入）。
  final Object? customScanStreamOpener;

  /// 释放启动上下文托管的引擎、原生桥接与数据库资源。
  Future<void> dispose() async {
    audiophileCoordinator.dispose();
    await desktopSurfaceBridge?.dispose();
    await androidSurfacePort?.dispose();
    androidAudioRoutePort?.dispose();
    androidMediaSessionPort?.dispose();
    httpClient.close();
    await streamBridge.close();
    await domainEventBus.dispose();
    await databases.close();
  }

  /// 生成顶层依赖注入覆写列表（将宿主底座、引擎与全部已注册业务模块装配至根容器）。
  List<Override> toProviderOverrides({
    required AppNavigator navigator,
    ValueChanged<ThemeMode>? onThemeModeChanged,
    ValueChanged<bool>? onAmbientBackdropChanged,
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
      androidSurfacePort: androidSurfacePort,
      androidMediaSessionPort: androidMediaSessionPort,
      mediaStorePublisher: mediaStorePublisher,
      autoStartDetailWarmupAndBackfill: autoStartDetailWarmupAndBackfill,
      customScanStreamOpener: customScanStreamOpener,
      onThemeModeChanged: onThemeModeChanged,
      onAmbientBackdropChanged: onAmbientBackdropChanged,
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

  /// 统一初始化三库（缓存库惰性不打开）、配置切片、核心引擎、事件总线与诊断日志。
  static Future<KonataBootstrapContext> initialize({
    required KonataPlatform platform,
    required StorageRootPort storageRoot,
    required SecureStoragePort secureStorage,
    FeatureRegistry? featureRegistry,
    FilePickerPort? filePicker,
    BackupFilePort? backupFilePort,
    UrlOpenerPort? urlOpener,
    KonataHttpClientPort? httpClient,
    PlaybackHostWindowPort? hostWindow,
    KonataVideoTextureBridge? desktopSurfaceBridge,
    AndroidVideoSurfacePort? androidSurfacePort,
    AndroidAudioRoutePort? androidAudioRoutePort,
    AndroidMediaSessionPort? androidMediaSessionPort,
    MediaStorePublisherPort? mediaStorePublisher,
    bool useInMemoryDatabases = false,
    bool autoStartDetailWarmupAndBackfill = true,
    Object? customScanStreamOpener,
  }) async {
    final diagnosticLog = DiagnosticLogStore();
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
    final registry =
        featureRegistry ??
        FeatureRegistry.forRuntime(
          databases: databases,
          scopedPrefs: scopedPrefs,
          httpClient: resolvedHttpClient,
        );
    final credentialStore = SourceCredentialStore(storage: secureStorage);
    final webDavPool = WebDavConnectionPool();
    final gatewayFactory = MediaSourceGatewayFactory(
      credentialStore: credentialStore,
      webDavPool: webDavPool,
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
      gatewayFactory: gatewayFactory,
      streamBridge: streamBridge,
      subtitleDirectoryIndex: subtitleDirectoryIndex,
      warmupService: warmupService,
      photosStorage: photosStorage,
      artworkCache: artworkCache,
      playbackEngine: playbackEngine,
      audiophileCoordinator: audiophileCoordinator,
      hostWindow: hostWindow ?? const NoopPlaybackHostWindowPort(),
      desktopSurfaceBridge: desktopSurfaceBridge,
      androidSurfacePort: androidSurfacePort,
      androidAudioRoutePort: androidAudioRoutePort,
      androidMediaSessionPort: androidMediaSessionPort,
      mediaStorePublisher: mediaStorePublisher,
      autoStartDetailWarmupAndBackfill: autoStartDetailWarmupAndBackfill,
      customScanStreamOpener: customScanStreamOpener,
    );
  }
}

final TypedPrefsSlice<ThemeMode> _hostThemeModeSlice =
    TypedPrefsSlice<ThemeMode>(
      namespace: 'feature_settings.appearance',
      schemaVersion: 1,
      syncPolicy: SyncPolicy.portable,
      defaultValue: ThemeMode.dark,
      decode: (json, _) {
        final raw = (json['themeMode'] ?? '').toString().trim();
        return ThemeMode.values.firstWhere(
          (mode) => mode.name == raw,
          orElse: () => ThemeMode.dark,
        );
      },
      encode: (mode) => <String, Object?>{'themeMode': mode.name},
    );

/// Konata v3 双端极薄组装根组件（挂载三端同源主题、自适应外壳、声明式扩展点与原生导航）。
final class KonataBootstrapApp extends StatefulWidget {
  /// 创建挂载指定启动上下文的根组件。
  const KonataBootstrapApp({
    super.key,
    required this.bootstrap,
    required this.platformLabel,
  });

  /// 已初始化的底座上下文。
  final KonataBootstrapContext bootstrap;

  /// 当前宿主平台显示名称。
  final String platformLabel;

  @override
  State<KonataBootstrapApp> createState() => _KonataBootstrapAppState();
}

final class _KonataBootstrapAppState extends State<KonataBootstrapApp> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final ValueNotifier<String> _requestedSectionId = ValueNotifier<String>('');
  final ValueNotifier<String> _pendingToast = ValueNotifier<String>('');
  final ValueNotifier<bool> _audioStageOpen = ValueNotifier<bool>(false);
  late final ValueNotifier<ThemeMode> _themeModeNotifier;
  late final HostAppNavigator _navigator;

  @override
  void initState() {
    super.initState();
    _themeModeNotifier = ValueNotifier<ThemeMode>(
      widget.bootstrap.scopedPrefs.read(_hostThemeModeSlice),
    );
    _navigator = HostAppNavigator(
      navigatorKey: _navigatorKey,
      onSwitchNavSection: (sectionId) {
        _requestedSectionId.value = sectionId;
      },
      onAudioStageVisibilityChanged: (opened) {
        _audioStageOpen.value = opened;
      },
      onShowMessage: (message) {
        _pendingToast.value = message;
      },
    );
  }

  @override
  void dispose() {
    _requestedSectionId.dispose();
    _pendingToast.dispose();
    _audioStageOpen.dispose();
    _themeModeNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: widget.bootstrap.toProviderOverrides(
        navigator: _navigator,
        onThemeModeChanged: (mode) {
          _themeModeNotifier.value = mode;
        },
      ),
      child: _KonataBootstrapRoot(
        platformLabel: widget.platformLabel,
        navigatorKey: _navigatorKey,
        requestedSectionId: _requestedSectionId,
        pendingToast: _pendingToast,
        audioStageOpen: _audioStageOpen,
        themeModeNotifier: _themeModeNotifier,
      ),
    );
  }
}

final class _KonataBootstrapRoot extends ConsumerStatefulWidget {
  const _KonataBootstrapRoot({
    required this.platformLabel,
    required this.navigatorKey,
    required this.requestedSectionId,
    required this.pendingToast,
    required this.audioStageOpen,
    required this.themeModeNotifier,
  });

  final String platformLabel;
  final GlobalKey<NavigatorState> navigatorKey;
  final ValueNotifier<String> requestedSectionId;
  final ValueNotifier<String> pendingToast;
  final ValueNotifier<bool> audioStageOpen;
  final ValueNotifier<ThemeMode> themeModeNotifier;

  @override
  ConsumerState<_KonataBootstrapRoot> createState() =>
      _KonataBootstrapRootState();
}

final class _KonataBootstrapRootState
    extends ConsumerState<_KonataBootstrapRoot> {
  final ValueNotifier<bool> _windowLiveResizing = ValueNotifier<bool>(false);
  late final ThemeData _darkTheme = KonataTheme.darkTheme();
  late final ThemeData _lightTheme = KonataTheme.lightTheme();
  int _selectedIndex = 0;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    widget.requestedSectionId.addListener(_handleExternalNavRequest);
    widget.pendingToast.addListener(_handlePendingToast);
  }

  @override
  void dispose() {
    widget.requestedSectionId.removeListener(_handleExternalNavRequest);
    widget.pendingToast.removeListener(_handlePendingToast);
    _windowLiveResizing.dispose();
    super.dispose();
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

  void _handlePendingToast() {
    final msg = widget.pendingToast.value.trim();
    if (msg.isEmpty) return;
    ref.read(toastControllerProvider).show(msg);
    widget.pendingToast.value = '';
  }

  void _toggleTheme() {
    final nextMode = widget.themeModeNotifier.value == ThemeMode.dark
        ? ThemeMode.light
        : ThemeMode.dark;
    widget.themeModeNotifier.value = nextMode;
    ref.read(scopedPrefsStoreProvider).write(_hostThemeModeSlice, nextMode);
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
    final hasAudioFeature = registry.containsFeature('feature_player_audio');

    return KonataWindowResizeScope(
      resizingListenable: _windowLiveResizing,
      child: KonataModalLayerScope(
        registry: modalRegistry,
        child: KonataToastScope(
          controller: toastController,
          child: ValueListenableBuilder<ThemeMode>(
            valueListenable: widget.themeModeNotifier,
            builder: (context, themeMode, _) {
              return MaterialApp(
                navigatorKey: widget.navigatorKey,
                debugShowCheckedModeBanner: false,
                title: KonataLaneConfig.resolveDesktopWindowTitle(),
                locale: const Locale('zh', 'CN'),
                supportedLocales: const <Locale>[Locale('zh', 'CN')],
                localizationsDelegates: GlobalMaterialLocalizations.delegates,
                theme: _lightTheme,
                darkTheme: _darkTheme,
                themeMode: themeMode,
                builder: (context, child) => Stack(
                  children: <Widget>[
                    ?child,
                    if (hasAudioFeature)
                      ValueListenableBuilder<bool>(
                        valueListenable: widget.audioStageOpen,
                        builder: (context, audioOpened, _) {
                          return buildFloatingAudioMiniBar(
                            hidden: audioOpened,
                            platform: platform,
                            onExpandFullStage: () {
                              final nav = widget.navigatorKey.currentState;
                              if (nav == null) return;
                              widget.audioStageOpen.value = true;
                              unawaited(
                                nav
                                    .push<void>(
                                      CupertinoPageRoute<void>(
                                        builder: (_) =>
                                            buildAudioPlayerRoutePage(
                                              workId: WorkId('active-audio'),
                                              onClosePage: () {
                                                if (nav.canPop()) nav.pop();
                                              },
                                            ),
                                      ),
                                    )
                                    .whenComplete(() {
                                      widget.audioStageOpen.value = false;
                                    }),
                              );
                            },
                          );
                        },
                      ),
                    const KonataToastViewport(),
                  ],
                ),
                home: KonataAdaptiveShell(
                  navItems: <KonataNavItem>[
                    for (final entry in navEntries) entry.item,
                  ],
                  selectedIndex: safeIndex,
                  onSelectedIndexChanged: (index) {
                    setState(() => _selectedIndex = index);
                  },
                  onToggleTheme: _toggleTheme,
                  searchQuery: _searchQuery,
                  searchPageIndex: libraryIndex >= 0 ? libraryIndex : 0,
                  onSearchChanged: (value) {
                    setState(() => _searchQuery = value);
                  },
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
                ),
              );
            },
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
