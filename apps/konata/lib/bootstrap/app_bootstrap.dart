import 'dart:async';

import 'package:engine_sources/engine_sources.dart';
import 'package:feature_detail/feature_detail.dart';
import 'package:feature_library/feature_library.dart';
import 'package:feature_scan_viewer/feature_scan_viewer.dart';
import 'package:feature_sources/feature_sources.dart';
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
    this.onOpenPlaybackPlaceholder,
  });

  /// 顶层原生路由导航键。
  final GlobalKey<NavigatorState> navigatorKey;

  /// 切换顶层主导航分区回调。
  final void Function(String sectionId) onSwitchNavSection;

  /// 音视频舞台未就绪时的友好提示回调（Phase 4 接入全屏音视频舞台时替换）。
  final void Function(String message)? onOpenPlaybackPlaceholder;

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
        builder: (_) => WorkDetailPage(
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
    onOpenPlaybackPlaceholder?.call('视频播放舞台将在下一阶段接入');
  }

  @override
  Future<void> openAudioPlayer({
    required WorkId workId,
    VariantId? variantId,
  }) async {
    onOpenPlaybackPlaceholder?.call('音频播放舞台将在下一阶段接入');
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
    required this.urlOpener,
    required this.httpClient,
    required this.gatewayFactory,
    required this.streamBridge,
    required this.warmupService,
    required this.photosStorage,
    required this.artworkCache,
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

  /// 跨端外部链接打开端口。
  final UrlOpenerPort urlOpener;

  /// 统一网络客户端实例。
  final KonataHttpClientPort httpClient;

  /// 只读媒体源网关工厂。
  final MediaSourceGatewayFactory gatewayFactory;

  /// 本地安全回环流网桥。
  final LocalStreamBridge streamBridge;

  /// 详情页同级字幕与连接池静默预热服务。
  final WorkDetailWarmupService warmupService;

  /// 分作品目录图片存储管理器。
  final PhotosStorage photosStorage;

  /// 有界图片磁盘与内存缓存。
  final ArtworkDiskCache artworkCache;

  /// 进入详情页后是否自动触发静默预热与正片缺失剧照抽帧补图。
  final bool autoStartDetailWarmupAndBackfill;

  /// 可选自定义扫图原图流读取器（供离线端到端集成测试注入）。
  final ScanSourceStreamOpener? customScanStreamOpener;

  /// 释放启动上下文托管的引擎与数据库资源。
  Future<void> dispose() async {
    httpClient.close();
    await streamBridge.close();
    await domainEventBus.dispose();
    await databases.close();
  }

  /// 生成顶层依赖注入覆写列表（将宿主导航、引擎与扩展点按包注入各业务模块）。
  List<Override> toProviderOverrides({
    required AppNavigator navigator,
  }) {
    final detailTabs = featureRegistry.detailTabsFor(platform);
    final detailActions = featureRegistry.detailActionsFor(platform);
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
      featureSourcesDependenciesProvider.overrideWithValue(
        FeatureSourcesDependencies(
          databases: databases,
          storageRoot: storageRoot,
          secureStorage: secureStorage,
          diagnosticLog: diagnosticLog,
          scopedPrefs: scopedPrefs,
          domainEventBus: domainEventBus,
          navigator: navigator,
          filePicker: filePicker,
          httpClient: httpClient,
          gatewayFactory: gatewayFactory,
          photosStorage: photosStorage,
          platform: platform,
        ),
      ),
      featureLibraryDependenciesProvider.overrideWithValue(
        FeatureLibraryDependencies(
          databases: databases,
          storageRoot: storageRoot,
          diagnosticLog: diagnosticLog,
          scopedPrefs: scopedPrefs,
          domainEventBus: domainEventBus,
          navigator: navigator,
          httpClient: httpClient,
          photosStorage: photosStorage,
          artworkCache: artworkCache,
          platform: platform,
        ),
      ),
      featureDetailDependenciesProvider.overrideWithValue(
        FeatureDetailDependencies(
          databases: databases,
          storageRoot: storageRoot,
          diagnosticLog: diagnosticLog,
          scopedPrefs: scopedPrefs,
          domainEventBus: domainEventBus,
          navigator: navigator,
          filePicker: filePicker,
          urlOpener: urlOpener,
          httpClient: httpClient,
          gatewayFactory: gatewayFactory,
          streamBridge: streamBridge,
          warmupService: warmupService,
          photosStorage: photosStorage,
          artworkCache: artworkCache,
          platform: platform,
          detailTabs: detailTabs,
          detailActions: detailActions,
          autoStartWarmupAndBackfill: autoStartDetailWarmupAndBackfill,
        ),
      ),
      featureScanViewerDependenciesProvider.overrideWithValue(
        FeatureScanViewerDependencies(
          databases: databases,
          storageRoot: storageRoot,
          diagnosticLog: diagnosticLog,
          scopedPrefs: scopedPrefs,
          gatewayFactory: gatewayFactory,
          photosStorage: photosStorage,
          platform: platform,
          customStreamOpener: customScanStreamOpener,
          urlOpener: urlOpener,
        ),
      ),
    ];
  }

  /// 统一初始化三库（缓存库惰性不打开）、配置切片、核心引擎、事件总线与诊断日志。
  static Future<KonataBootstrapContext> initialize({
    required KonataPlatform platform,
    required StorageRootPort storageRoot,
    required SecureStoragePort secureStorage,
    FeatureRegistry? featureRegistry,
    FilePickerPort? filePicker,
    UrlOpenerPort? urlOpener,
    KonataHttpClientPort? httpClient,
    bool useInMemoryDatabases = false,
    bool autoStartDetailWarmupAndBackfill = true,
    ScanSourceStreamOpener? customScanStreamOpener,
  }) async {
    final diagnosticLog = DiagnosticLogStore();
    final databases = useInMemoryDatabases
        ? KonataDatabaseBundle.openInMemory()
        : await KonataDatabaseBundle.openFromStorageRoot(storageRoot);
    final scopedPrefs = ScopedPrefsStore(databases.userState);
    final eventBus = InMemoryDomainEventBus();
    final registry = featureRegistry ?? FeatureRegistry.forDatabases(databases);
    final rootPath = await storageRoot.resolveAppRootPath();

    final resolvedHttpClient =
        httpClient ??
        KonataHttpClient(
          config: const KonataNetworkConfig(),
          diagnosticLog: diagnosticLog,
        );
    final credentialStore = SourceCredentialStore(storage: secureStorage);
    final webDavPool = WebDavConnectionPool();
    final gatewayFactory = MediaSourceGatewayFactory(
      credentialStore: credentialStore,
      webDavPool: webDavPool,
    );
    final streamBridge = LocalStreamBridge(storageRoot: storageRoot);
    final warmupService = WorkDetailWarmupService(
      gatewayFactory: gatewayFactory,
      directoryIndex: SubtitleDirectoryIndex(),
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
      message: 'Konata v3 底座与核心引擎初始化完成',
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
      filePicker: filePicker ?? const HostFilePickerAdapter(),
      urlOpener: urlOpener ?? const HostUrlOpenerAdapter(),
      httpClient: resolvedHttpClient,
      gatewayFactory: gatewayFactory,
      streamBridge: streamBridge,
      warmupService: warmupService,
      photosStorage: photosStorage,
      artworkCache: artworkCache,
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
  late final HostAppNavigator _navigator;

  @override
  void initState() {
    super.initState();
    _navigator = HostAppNavigator(
      navigatorKey: _navigatorKey,
      onSwitchNavSection: (sectionId) {
        _requestedSectionId.value = sectionId;
      },
      onOpenPlaybackPlaceholder: (message) {
        _pendingToast.value = message;
      },
    );
  }

  @override
  void dispose() {
    _requestedSectionId.dispose();
    _pendingToast.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: widget.bootstrap.toProviderOverrides(navigator: _navigator),
      child: _KonataBootstrapRoot(
        platformLabel: widget.platformLabel,
        navigatorKey: _navigatorKey,
        requestedSectionId: _requestedSectionId,
        pendingToast: _pendingToast,
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
  });

  final String platformLabel;
  final GlobalKey<NavigatorState> navigatorKey;
  final ValueNotifier<String> requestedSectionId;
  final ValueNotifier<String> pendingToast;

  @override
  ConsumerState<_KonataBootstrapRoot> createState() =>
      _KonataBootstrapRootState();
}

final class _KonataBootstrapRootState
    extends ConsumerState<_KonataBootstrapRoot> {
  final ValueNotifier<bool> _windowLiveResizing = ValueNotifier<bool>(false);
  late final ThemeData _darkTheme = KonataTheme.darkTheme();
  late final ThemeData _lightTheme = KonataTheme.lightTheme();
  ThemeMode _themeMode = ThemeMode.dark;
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
    setState(() {
      _themeMode = _themeMode == ThemeMode.dark
          ? ThemeMode.light
          : ThemeMode.dark;
    });
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
    final databases = ref.watch(databaseBundleProvider);
    final lane = KonataLaneConfig.resolveLane();
    final title = lane.isEmpty
        ? 'Konata v3 (${widget.platformLabel})'
        : 'Konata v3 (${widget.platformLabel}) [${lane.toUpperCase()}]';

    final navEntries = _resolveNavEntries();
    final safeIndex = navEntries.isEmpty
        ? 0
        : _selectedIndex.clamp(0, navEntries.length - 1);
    final libraryIndex = navEntries.indexWhere((e) => e.id == 'library');

    return KonataWindowResizeScope(
      resizingListenable: _windowLiveResizing,
      child: KonataModalLayerScope(
        registry: modalRegistry,
        child: KonataToastScope(
          controller: toastController,
          child: MaterialApp(
            navigatorKey: widget.navigatorKey,
            debugShowCheckedModeBanner: false,
            title: KonataLaneConfig.resolveDesktopWindowTitle(),
            locale: const Locale('zh', 'CN'),
            supportedLocales: const <Locale>[Locale('zh', 'CN')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            theme: _lightTheme,
            darkTheme: _darkTheme,
            themeMode: _themeMode,
            builder: (context, child) => Stack(
              children: <Widget>[
                ?child,
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
