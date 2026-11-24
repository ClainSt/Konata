import 'dart:async';

import 'package:engine_playback/engine_playback.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import 'data/pip_recovery_store.dart';
import 'data/shader_discovery_service.dart';
import 'data/video_playback_preferences.dart';
import 'data/video_session_models.dart';
import 'state/active_video_session_manager.dart';
import 'state/video_playback_controller.dart';
import 'state/video_playback_state.dart';

/// `feature_player_video` 业务包显式跨包运行依赖集合（由主应用启动壳覆写注入）。
final class FeaturePlayerVideoDependencies {
  /// 构造视频播放业务包显式依赖容器。
  const FeaturePlayerVideoDependencies({
    required this.databases,
    required this.storageRoot,
    required this.diagnosticLog,
    required this.scopedPrefs,
    required this.domainEventBus,
    required this.navigator,
    required this.filePicker,
    required this.urlOpener,
    required this.gatewayFactory,
    required this.streamBridge,
    required this.platform,
    this.hostWindow = const NoopPlaybackHostWindowPort(),
    this.subtitleDirectoryIndex,
    this.playbackEngine,
    this.audiophileCoordinator,
    this.pipRecoveryStore,
    this.desktopRelayGateway,
    this.externalPlayerStore,
    this.desktopSurfaceBridge,
    this.desktopProfileDelegate,
    this.androidSurfacePort,
    this.mediaStorePublisher,
    this.cloudSubsetCoordinator,
    this.legacyCodePageDecoder,
    this.libMpvClientFactory,
    this.playerSidePanels = const <PlayerSidePanelContribution>[],
    this.pickExecutableFile,
    this.pickShaderFiles,
    this.sourceDeviceId = '',
  });

  /// 三库物理分治数据库总管。
  final KonataDatabaseBundle databases;

  /// 跨端存储根目录解析端口。
  final StorageRootPort storageRoot;

  /// 统一脱敏结构化诊断日志端口。
  final DiagnosticLogPort diagnosticLog;

  /// 分命名空间自治配置存储器。
  final ScopedPrefsStore scopedPrefs;

  /// 低频跨包领域事件总线。
  final DomainEventBus domainEventBus;

  /// 跨模块强类型导航端口。
  final AppNavigator navigator;

  /// 跨平台系统目录与外挂字幕文件选择器端口。
  final FilePickerPort filePicker;

  /// 跨平台系统浏览器链接打开端口。
  final UrlOpenerPort urlOpener;

  /// 只读媒体源网关工厂端口。
  final MediaSourceGatewayFactoryPort gatewayFactory;

  /// 本地安全回环流网桥端口。
  final LocalStreamBridgePort streamBridge;

  /// 当前运行宿主平台类型。
  final KonataPlatform platform;

  /// 宿主窗口全屏、置顶、迷你窗、常亮及横屏方向控制端口。
  final PlaybackHostWindowPort hostWindow;

  /// 可选同级外挂字幕目录预热索引端口。
  final SubtitleDirectoryWarmupPort? subtitleDirectoryIndex;

  /// 可选全局共享四维代数播放协调内核。
  final UnifiedPlaybackEngine? playbackEngine;

  /// 可选全局共享发烧音频安全链协调器。
  final AudiophileSafetyCoordinator? audiophileCoordinator;

  /// 可选画中画恢复状态持久化仓储。
  final PipRecoveryStore? pipRecoveryStore;

  /// 可选桌面外置播放器接力网关。
  final DesktopRelayGateway? desktopRelayGateway;

  /// 可选桌面外置播放器配置存取端口。
  final DesktopExternalPlayerStore? externalPlayerStore;

  /// 可选桌面硬件纹理共享桥接端口。
  final KonataVideoTextureBridge? desktopSurfaceBridge;

  /// 可选桌面驱动参数策略委托。
  final MpvPlatformProfileDelegate? desktopProfileDelegate;

  /// 可选移动平台视频硬件表面控制端口。
  final AndroidVideoSurfacePort? androidSurfacePort;

  /// 可选移动平台相册发布端口。
  final MediaStorePublisherPort? mediaStorePublisher;

  /// 可选云端字幕字体子集化按域协调器。
  final CloudSubsetCoordinator? cloudSubsetCoordinator;

  /// 可选桌面传统编码页字节解码器回调。
  final LegacyCodePageDecoder? legacyCodePageDecoder;

  /// 可选底层原生播放器实例工厂。
  final LibMpvClient Function()? libMpvClientFactory;

  /// 外部模块声明并汇入的播放器扩展侧栏贡献清单。
  final List<PlayerSidePanelContribution> playerSidePanels;

  /// 可选宿主注入的可执行程序选择回调（桌面端选择外部播放器路径时使用）。
  final Future<String?> Function({String? dialogTitle})? pickExecutableFile;

  /// 可选宿主注入的着色器文件批量选择回调。
  final Future<List<ShaderImportSource>> Function()? pickShaderFiles;

  /// 当前设备同步身份标识。
  final String sourceDeviceId;
}

/// 外部业务注入的视频播放模块全局依赖提供器（未覆写时在读取阶段明确报错）。
final featurePlayerVideoDependenciesProvider =
    Provider<FeaturePlayerVideoDependencies>((ref) {
      throw UnimplementedError(
        'featurePlayerVideoDependenciesProvider 必须由应用启动组装根覆盖注入',
      );
    });

/// 视频播放自治偏好设置仓储提供器。
final videoPlaybackPreferencesStoreProvider =
    Provider<VideoPlaybackPreferencesStore>((ref) {
      final deps = ref.watch(featurePlayerVideoDependenciesProvider);
      return VideoPlaybackPreferencesStore(
        deps.scopedPrefs,
        eventBus: deps.domainEventBus,
        sourceDeviceId: deps.sourceDeviceId,
      );
    });

/// 着色器目录异步扫描与导入服务提供器。
final videoShaderDiscoveryServiceProvider = Provider<ShaderDiscoveryService>((
  ref,
) {
  final deps = ref.watch(featurePlayerVideoDependenciesProvider);
  final prefsStore = ref.watch(videoPlaybackPreferencesStoreProvider);
  final service = ShaderDiscoveryService(
    storageRoot: deps.storageRoot,
    preferencesStore: prefsStore,
    logStore: deps.diagnosticLog,
  );
  ref.onDispose(service.dispose);
  return service;
});

/// 画中画断点恢复存储仓储提供器。
final videoPipRecoveryStoreProvider = Provider<PipRecoveryStore>((ref) {
  final deps = ref.watch(featurePlayerVideoDependenciesProvider);
  return deps.pipRecoveryStore ?? ScopedPrefsPipRecoveryStore(deps.scopedPrefs);
});

VideoPlaybackController _createVideoPlaybackController(Ref ref) {
  final deps = ref.read(featurePlayerVideoDependenciesProvider);
  final prefsStore = ref.read(videoPlaybackPreferencesStoreProvider);
  final shaderService = ref.read(videoShaderDiscoveryServiceProvider);
  final pipStore = ref.read(videoPipRecoveryStoreProvider);

  final engine = deps.playbackEngine ?? UnifiedPlaybackEngine();
  final safetyCoordinator =
      deps.audiophileCoordinator ??
      AudiophileSafetyCoordinator(
        engine: engine,
        logStore: deps.diagnosticLog,
        isWindowsOverride: deps.platform == KonataPlatform.windows,
        isAndroidOverride: deps.platform != KonataPlatform.windows,
      );

  return VideoPlaybackController(
    env: VideoPlaybackEnvironment(
      databases: deps.databases,
      storageRoot: deps.storageRoot,
      domainEventBus: deps.domainEventBus,
      hostWindow: deps.hostWindow,
      filePicker: deps.filePicker,
      streamBridge: deps.streamBridge,
      preferencesStore: prefsStore,
      shaderDiscoveryService: shaderService,
      pipRecoveryStore: pipStore,
      playbackEngine: engine,
      audiophileCoordinator: safetyCoordinator,
      platform: deps.platform,
      navigator: deps.navigator,
      gatewayFactory: deps.gatewayFactory,
      subtitleDirectoryIndex: deps.subtitleDirectoryIndex,
      cloudSubsetCoordinator: deps.cloudSubsetCoordinator,
      legacyCodePageDecoder: deps.legacyCodePageDecoder,
      desktopRelayGateway: deps.desktopRelayGateway,
      desktopSurfaceBridge: deps.desktopSurfaceBridge,
      desktopProfileDelegate: deps.desktopProfileDelegate,
      androidSurfacePort: deps.androidSurfacePort,
      mediaStorePublisher: deps.mediaStorePublisher,
      diagnosticLog: deps.diagnosticLog,
      libMpvClientFactory: deps.libMpvClientFactory,
      sourceDeviceId: deps.sourceDeviceId,
    ),
  );
}

/// 跨路由常驻活跃视频会话总管（脱离路由局部 `autoDispose`，支撑跨页 16:9 悬浮视频小窗零重建解码）。
final activeVideoSessionManagerProvider = Provider<ActiveVideoSessionManager>((
  ref,
) {
  ref.watch(featurePlayerVideoDependenciesProvider);
  ref.watch(videoPlaybackPreferencesStoreProvider);
  ref.watch(videoShaderDiscoveryServiceProvider);
  ref.watch(videoPipRecoveryStoreProvider);
  final manager = ActiveVideoSessionManager(
    controllerFactory: () => _createVideoPlaybackController(ref),
  );
  ref.onDispose(manager.dispose);
  return manager;
});

/// 内置全屏视频播放核心状态控制器按需族提供器（与请求键绑定，关闭舞台自动销毁）。
final videoPlaybackControllerProvider = Provider.autoDispose
    .family<VideoPlaybackController, VideoLaunchRequest>((ref, request) {
      ref.watch(featurePlayerVideoDependenciesProvider);
      ref.watch(videoPlaybackPreferencesStoreProvider);
      ref.watch(videoShaderDiscoveryServiceProvider);
      ref.watch(videoPipRecoveryStoreProvider);

      final controller = _createVideoPlaybackController(ref);
      unawaited(controller.initialize(request));
      ref.onDispose(controller.dispose);
      return controller;
    });
