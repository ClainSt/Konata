import 'package:engine_playback/engine_playback.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import 'data/data.dart';
import 'state/state.dart';
import 'ui/ui.dart';

/// `feature_player_audio` 从宿主组装根获取全部底层端口与可选扩展依赖的不可变装配契约。
///
/// 通过可选 [lyricPort]、[lyricsViewportBuilder] 与 [extraSidePanels] 实现与歌词等横向功能的彻底隔离。
class FeaturePlayerAudioDependencies {
  /// 构造垂直音频业务包外部依赖契约。
  const FeaturePlayerAudioDependencies({
    required this.engine,
    required this.safetyCoordinator,
    required this.prefsStore,
    required this.gatewayFactory,
    required this.streamBridge,
    this.windowPort = const NoopPlaybackHostWindowPort(),
    this.lyricPort,
    this.lyricsViewportBuilder,
    this.extraSidePanels = const [],
    this.database,
    this.playbackRecordDao,
    this.photosStorage,
    this.artworkCacheStore,
    this.storageRoot,
    this.domainEventBus,
    this.desktopRelayGateway,
    this.desktopMpvDelegate,
    this.androidMediaSessionPort,
    this.logPort,
    this.platform = KonataPlatform.windows,
    this.mpvClientFactoryOverride,
    this.isWindowsOverride,
  });

  /// 四维播放代数调度引擎。
  final UnifiedPlaybackEngine engine;

  /// 发烧音频 `-12 dBFS` 安全限幅与热插拔协调器。
  final AudiophileSafetyCoordinator safetyCoordinator;

  /// 强类型偏好存储切片接口。
  final ScopedPrefsStore prefsStore;

  /// 媒体源只读网关创建工厂。
  final MediaSourceGatewayFactoryPort gatewayFactory;

  /// 本地 HTTP Range 流代理网桥。
  final LocalStreamBridgePort streamBridge;

  /// 宿主桌面置顶迷你窗口与全屏控制端口。
  final PlaybackHostWindowPort windowPort;

  /// 可选歌词业务协同端口（切歌低频触发解析与预取；为空时静默降级）。
  final LyricDisplayPort? lyricPort;

  /// 可选沉浸式歌词滚屏视口构建器（为空时展示独立纯音频舞台信息）。
  final AudioLyricsViewportBuilder? lyricsViewportBuilder;

  /// 从各 Feature 收集注入的播放器侧栏面板列表（运行时自动过滤 `PlayerMediaMode.audio`）。
  final List<PlayerSidePanelContribution> extraSidePanels;

  /// 数据库聚合句柄（未传 [playbackRecordDao] 时从中读取播放历史表）。
  final KonataDatabaseBundle? database;

  /// 可选单独注入的播放记录持久化 DAO。
  final PlaybackRecordDao? playbackRecordDao;

  /// 可选本地图片与封面缓存仓储。
  final PhotosStorage? photosStorage;

  /// 可选统一艺术图缓存接口。
  final ArtworkCacheStore? artworkCacheStore;

  /// 便携路径根目录解析端口。
  final StorageRootPort? storageRoot;

  /// 跨包领域事件总线（仅发送设置更新等低频事件）。
  final DomainEventBus? domainEventBus;

  /// 桌面端可选外部音频播放器接力服务。
  final DesktopRelayGateway? desktopRelayGateway;

  /// 桌面端可选 `libmpv` 专属驱动与独占音频委托。
  final MpvPlatformProfileDelegate? desktopMpvDelegate;

  /// Android 可选媒体会话通知栏双向控制器。
  final AndroidMediaSessionPort? androidMediaSessionPort;

  /// 脱敏结构化诊断日志端口。
  final DiagnosticLogPort? logPort;

  /// 当前运行平台枚举。
  final KonataPlatform platform;

  /// 可选底层 `libmpv` 实例工厂覆盖（供自动化测试注入受控替身）。
  final LibMpvClient Function()? mpvClientFactoryOverride;

  /// 可选跨平台测试用桌面平台标识覆盖。
  final bool? isWindowsOverride;
}

/// 音频垂直业务包核心外部依赖 Provider（由宿主应用组装根 `overrideWithValue` 注入）。
final Provider<FeaturePlayerAudioDependencies>
featurePlayerAudioDependenciesProvider = Provider<FeaturePlayerAudioDependencies>((
  ref,
) {
  throw UnimplementedError(
    'featurePlayerAudioDependenciesProvider 必须在根 ProviderScope 覆盖注入后再读取。',
  );
});

/// 音频垂直设置仓库 Provider（隔离在 `playback_audio` 切片）。
final Provider<AudioPlaybackPreferences> audioPlaybackPrefsRepoProvider =
    Provider<AudioPlaybackPreferences>((ref) {
      final deps = ref.watch(featurePlayerAudioDependenciesProvider);
      return AudioPlaybackPreferences(
        store: deps.prefsStore,
        eventBus: deps.domainEventBus,
      );
    });

/// 音频内嵌与专辑封面资源缓存 Provider。
final Provider<AudioPlaybackAssets> audioPlaybackAssetsProvider =
    Provider<AudioPlaybackAssets>((ref) => AudioPlaybackAssets());

/// 音频流光色板聚簇缓存 Provider。
final Provider<ArtworkPaletteCache> artworkPaletteCacheProvider =
    Provider<ArtworkPaletteCache>((ref) => ArtworkPaletteCache());

/// 封面智能构图对齐重心缓存 Provider。
final Provider<SmartCoverAlignmentCache> smartCoverAlignmentCacheProvider =
    Provider<SmartCoverAlignmentCache>((ref) => SmartCoverAlignmentCache());

/// 全站唯一音频核心控制器 Provider（销毁时自动释放原生实例与计时器）。
final Provider<AudioPlaybackController> audioPlaybackControllerProvider =
    Provider<AudioPlaybackController>((ref) {
      final deps = ref.watch(featurePlayerAudioDependenciesProvider);
      final prefsRepo = ref.watch(audioPlaybackPrefsRepoProvider);
      final assets = ref.watch(audioPlaybackAssetsProvider);

      final controller = AudioPlaybackController(
        preferences: prefsRepo,
        assets: assets,
        engine: deps.engine,
        safetyCoordinator: deps.safetyCoordinator,
        gatewayFactory: deps.gatewayFactory,
        streamBridge: deps.streamBridge,
        windowPort: deps.windowPort,
        lyricPort: deps.lyricPort,
        database: deps.database,
        playbackRecordDao: deps.playbackRecordDao,
        photosStorage: deps.photosStorage,
        artworkCacheStore: deps.artworkCacheStore,
        storageRoot: deps.storageRoot,
        desktopRelayGateway: deps.desktopRelayGateway,
        desktopMpvDelegate: deps.desktopMpvDelegate,
        androidMediaSessionPort: deps.androidMediaSessionPort,
        logPort: deps.logPort,
        mpvClientFactoryOverride: deps.mpvClientFactoryOverride,
        isWindowsOverride: deps.isWindowsOverride,
      );
      ref.onDispose(controller.dispose);
      return controller;
    });
