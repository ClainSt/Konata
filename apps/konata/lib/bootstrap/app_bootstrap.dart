import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';
import 'package:konata_storage/konata_storage.dart';

import 'feature_registry.dart';

/// 全局应用运行形态 Provider（Windows / Android 手机 / Android 平板）。
final konataPlatformProvider = Provider<KonataPlatform>((ref) {
  throw UnimplementedError('konataPlatformProvider 必须由宿主启动壳覆盖注入');
});

/// 全局跨端存储根目录端口 Provider。
final storageRootPortProvider = Provider<StorageRootPort>((ref) {
  throw UnimplementedError('storageRootPortProvider 必须由宿主启动壳覆盖注入');
});

/// 全局敏感凭据安全存储端口 Provider。
final secureStoragePortProvider = Provider<SecureStoragePort>((ref) {
  throw UnimplementedError('secureStoragePortProvider 必须由宿主启动壳覆盖注入');
});

/// 全局统一脱敏诊断日志端口 Provider。
final diagnosticLogPortProvider = Provider<DiagnosticLogPort>((ref) {
  throw UnimplementedError('diagnosticLogPortProvider 必须由宿主启动壳覆盖注入');
});

/// 全局三库物理分治总管 Provider。
final databaseBundleProvider = Provider<KonataDatabaseBundle>((ref) {
  throw UnimplementedError('databaseBundleProvider 必须由宿主启动壳覆盖注入');
});

/// 全局媒体库只读查询端口 Provider。
final libraryReadPortProvider = Provider<LibraryReadPort>((ref) {
  return ref.watch(databaseBundleProvider).library.createReadPort();
});

/// 全局播放进度只读查询端口 Provider。
final playbackReadPortProvider = Provider<PlaybackReadPort>((ref) {
  return ref.watch(databaseBundleProvider).userState.createPlaybackReadPort();
});

/// 全局分命名空间自治配置存储器 Provider。
final scopedPrefsStoreProvider = Provider<ScopedPrefsStore>((ref) {
  return ScopedPrefsStore(ref.watch(databaseBundleProvider).userState);
});

/// 全局配置只读查询端口 Provider。
final prefsReadPortProvider = Provider<PrefsReadPort>((ref) {
  return ref.watch(scopedPrefsStoreProvider);
});

/// 全局低频跨包领域事件总线 Provider（严禁发送 > 5Hz 高频信号）。
final domainEventBusProvider = Provider<DomainEventBus>((ref) {
  throw UnimplementedError('domainEventBusProvider 必须由宿主启动壳覆盖注入');
});

/// 全局声明式扩展点聚合器 Provider。
final featureRegistryProvider = Provider<FeatureRegistry>((ref) {
  return FeatureRegistry.defaults();
});

/// 全局悬浮轻提示控制器 Provider（桥接至无 Riverpod 设计系统作用域）。
final toastControllerProvider = Provider<KonataToastController>((ref) {
  final controller = KonataToastController();
  ref.onDispose(controller.dispose);
  return controller;
});

/// 全局模态路由层级注册表 Provider（驱动悬浮小窗严守弹窗遮罩之下）。
final modalLayerRegistryProvider = Provider<KonataModalLayerRegistry>((ref) {
  final registry = KonataModalLayerRegistry();
  ref.onDispose(registry.dispose);
  return registry;
});

/// 应用启动完成后的极薄底座装配上下文（供 Windows 与 Android 双端入口共用）。
final class KonataBootstrapContext {
  /// 创建启动底座上下文。
  const KonataBootstrapContext({
    required this.platform,
    required this.storageRoot,
    required this.secureStorage,
    required this.diagnosticLog,
    required this.databases,
    required this.scopedPrefs,
    required this.domainEventBus,
    required this.featureRegistry,
  });

  /// 当前宿主运行平台。
  final KonataPlatform platform;

  /// 存储根目录端口。
  final StorageRootPort storageRoot;

  /// 敏感凭据安全存储端口。
  final SecureStoragePort secureStorage;

  /// 统一脱敏诊断日志端口。
  final DiagnosticLogPort diagnosticLog;

  /// 三库物理分治生命周期总管（`cache.db` 冷启动保持惰性未打开）。
  final KonataDatabaseBundle databases;

  /// 分命名空间自治配置存储器。
  final ScopedPrefsStore scopedPrefs;

  /// 低频领域事件总线。
  final DomainEventBus domainEventBus;

  /// 声明式扩展点注册表。
  final FeatureRegistry featureRegistry;

  /// 生成顶层 [ProviderScope] 依赖注入覆写列表。
  List<Override> toProviderOverrides() => <Override>[
    konataPlatformProvider.overrideWithValue(platform),
    storageRootPortProvider.overrideWithValue(storageRoot),
    secureStoragePortProvider.overrideWithValue(secureStorage),
    diagnosticLogPortProvider.overrideWithValue(diagnosticLog),
    databaseBundleProvider.overrideWithValue(databases),
    scopedPrefsStoreProvider.overrideWithValue(scopedPrefs),
    domainEventBusProvider.overrideWithValue(domainEventBus),
    featureRegistryProvider.overrideWithValue(featureRegistry),
  ];

  /// 统一初始化三库（`cache.db` 惰性不打开）、配置切片、低频事件总线与诊断日志。
  static Future<KonataBootstrapContext> initialize({
    required KonataPlatform platform,
    required StorageRootPort storageRoot,
    required SecureStoragePort secureStorage,
    FeatureRegistry? featureRegistry,
    bool useInMemoryDatabases = false,
  }) async {
    final diagnosticLog = DiagnosticLogStore();
    final databases = useInMemoryDatabases
        ? KonataDatabaseBundle.openInMemory()
        : await KonataDatabaseBundle.openFromStorageRoot(storageRoot);
    final scopedPrefs = ScopedPrefsStore(databases.userState);
    final eventBus = InMemoryDomainEventBus();
    final registry = featureRegistry ?? FeatureRegistry.defaults();
    final rootPath = await storageRoot.resolveAppRootPath();

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
      message: 'Konata v3 底座初始化完成',
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
    );
  }
}

/// Konata v3 双端极薄组装根组件（挂载三端同源主题、自适应外壳、模态层级与轻提示视口）。
final class KonataBootstrapApp extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: bootstrap.toProviderOverrides(),
      child: _KonataBootstrapRoot(platformLabel: platformLabel),
    );
  }
}

final class _KonataBootstrapRoot extends ConsumerStatefulWidget {
  const _KonataBootstrapRoot({required this.platformLabel});

  final String platformLabel;

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

  @override
  void dispose() {
    _windowLiveResizing.dispose();
    super.dispose();
  }

  void _toggleTheme() {
    setState(() {
      _themeMode = _themeMode == ThemeMode.dark
          ? ThemeMode.light
          : ThemeMode.dark;
    });
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

    return KonataWindowResizeScope(
      resizingListenable: _windowLiveResizing,
      child: KonataModalLayerScope(
        registry: modalRegistry,
        child: KonataToastScope(
          controller: toastController,
          child: MaterialApp(
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
              navItems: KonataNavItem.defaults,
              selectedIndex: _selectedIndex,
              onSelectedIndexChanged: (index) {
                setState(() => _selectedIndex = index);
              },
              onToggleTheme: _toggleTheme,
              pages: <Widget>[
                for (final item in KonataNavItem.defaults)
                  _FoundationStatusPage(
                    title: title,
                    sectionLabel: item.label,
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
