import 'dart:io';

import 'package:engine_playback/engine_playback.dart';
import 'package:flutter/foundation.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import '../data/mpv_thumbnail_service.dart';
import '../data/pip_recovery_store.dart';
import '../data/shader_discovery_service.dart';
import '../data/video_playback_preferences.dart';
import '../data/video_session_models.dart';

/// 视频播放器发往全站统一居中胶囊的瞬态提示载荷（递增序号确保重复文案可再次弹出）。
typedef VideoTransientNotice = ({
  int seq,
  String message,
  bool isError,
  Duration duration,
});

/// 内置视频播放控制器显式注入运行环境（完全隔离状态管理容器，便于无宿主单元测试）。
final class VideoPlaybackEnvironment {
  /// 构造内置视频播放控制器运行环境。
  const VideoPlaybackEnvironment({
    required this.databases,
    required this.storageRoot,
    required this.domainEventBus,
    required this.hostWindow,
    required this.filePicker,
    required this.streamBridge,
    required this.preferencesStore,
    required this.shaderDiscoveryService,
    required this.pipRecoveryStore,
    required this.playbackEngine,
    required this.audiophileCoordinator,
    required this.platform,
    this.navigator,
    this.microFadeDriver,
    this.gatewayFactory,
    this.subtitleDirectoryIndex,
    this.fontPoolManager,
    this.cloudSubsetCoordinator,
    this.legacyCodePageDecoder,
    this.desktopRelayGateway,
    this.desktopSurfaceBridge,
    this.desktopProfileDelegate,
    this.androidSurfacePort,
    this.mediaStorePublisher,
    this.diagnosticLog,
    this.libMpvClientFactory,
    this.thumbnailService,
    this.sourceDeviceId = '',
    this.nowMs,
    this.enablePeriodicTimers = true,
  });

  /// 三库物理分治数据库总管。
  final KonataDatabaseBundle databases;

  /// 跨端存储根目录解析端口。
  final StorageRootPort storageRoot;

  /// 低频跨包领域事件总线。
  final DomainEventBus domainEventBus;

  /// 宿主窗口与屏幕控制端口（全屏、置顶、迷你窗、常亮与横屏方向锁）。
  final PlaybackHostWindowPort hostWindow;

  /// 可选跨模块路由导航端口。
  final AppNavigator? navigator;

  /// 跨平台系统文件与外挂字幕选择器端口。
  final FilePickerPort filePicker;

  /// 本地回环流网桥端口。
  final LocalStreamBridgePort streamBridge;

  /// 视频播放偏好自治存储仓储。
  final VideoPlaybackPreferencesStore preferencesStore;

  /// 着色器目录异步扫描与导入服务。
  final ShaderDiscoveryService shaderDiscoveryService;

  /// 画中画与迷你窗恢复状态持久化仓储。
  final PipRecoveryStore pipRecoveryStore;

  /// 音视频统一四维代数隔离播放协调内核。
  final UnifiedPlaybackEngine playbackEngine;

  /// 跨端发烧音频路由防爆音安全协调器。
  final AudiophileSafetyCoordinator audiophileCoordinator;

  /// 当前运行宿主平台分类。
  final KonataPlatform platform;

  /// 音频微淡入软斜坡驱动器。
  final AudiophileMicroFadeDriver? microFadeDriver;

  /// 可选只读媒体源网关工厂端口。
  final MediaSourceGatewayFactoryPort? gatewayFactory;

  /// 可选详情页同级字幕目录预热索引端口。
  final SubtitleDirectoryWarmupPort? subtitleDirectoryIndex;

  /// 可选字幕解压字体哈希池管理器。
  final SubtitleFontPoolManager? fontPoolManager;

  /// 可选云端字幕字体子集化按域协调器。
  final CloudSubsetCoordinator? cloudSubsetCoordinator;

  /// 可选桌面传统编码页字节解码回调。
  final LegacyCodePageDecoder? legacyCodePageDecoder;

  /// 可选桌面外置播放器接力网关。
  final DesktopRelayGateway? desktopRelayGateway;

  /// 可选桌面硬件纹理渲染桥接端口。
  final KonataVideoTextureBridge? desktopSurfaceBridge;

  /// 可选桌面底栏及驱动参数策略委托。
  final MpvPlatformProfileDelegate? desktopProfileDelegate;

  /// 可选移动平台视频硬件表面控制端口。
  final AndroidVideoSurfacePort? androidSurfacePort;

  /// 可选移动平台系统相册发布端口。
  final MediaStorePublisherPort? mediaStorePublisher;

  /// 可选统一脱敏结构化诊断日志端口。
  final DiagnosticLogPort? diagnosticLog;

  /// 可选底层原生播放器实例构造工厂。
  final LibMpvClient Function()? libMpvClientFactory;

  /// 可选缩略图后台解码服务。
  final MpvThumbnailService? thumbnailService;

  /// 当前设备同步身份标识。
  final String sourceDeviceId;

  /// 可选外部墙钟毫秒获取器（方便确定性测试）。
  final int Function()? nowMs;

  /// 是否允许启动后台定时落盘与技术探针轮询计时器。
  final bool enablePeriodicTimers;
}

/// 内置视频播放页面完整不可变视图状态（高频进度与悬浮坐标分离至叶子监听器）。
@immutable
class VideoPlaybackState {
  /// 创建内置视频播放状态快照。
  const VideoPlaybackState({
    this.isInitializing = true,
    this.isBuffering = true,
    this.hasFirstFrame = false,
    this.isPlaying = false,
    this.isClosing = false,
    this.isMiniPlayer = false,
    this.currentWork,
    this.currentBundle,
    required this.currentEpisode,
    required this.currentVariant,
    this.textureId,
    this.windowsUnderlayActive = false,
    this.renderBackend = '',
    this.adapterName = '',
    this.durationSeconds = 0.0,
    this.speed = 1.0,
    this.isSpeedBoostActive = false,
    this.volume = 100.0,
    this.isMuted = false,
    this.isFullscreen = false,
    this.audioOnlyMode = false,
    this.aspectMode = VideoAspectMode.auto,
    this.windowBrightness = 0.5,
    this.probeOverlayVisible = false,
    this.sideSheetOpen = false,
    this.probeStats = const PlaybackProbeStats(),
    this.chapters = const <PlaybackChapter>[],
    this.subtitles = const <SubtitleChoice>[],
    this.audioTracks = const <AudioTrackChoice>[],
    this.availableAudioDevices = const <MpvAudioDevice>[],
    this.availableShaders = const <ShaderFileEntry>[],
    this.subtitleDelaySeconds = 0.0,
    this.audioDelaySeconds = 0.0,
    this.subtitleOpenCcMode = SubtitleOpenCcMode.none,
    this.secondarySubtitleTrackId,
    this.activeSubtitleSubsetState,
    this.isApplyingCloudSubset = false,
    this.trackMemory = const CrossEpisodeTrackMemory(),
    this.activeSkipWindow,
    this.transientNotice,
    this.errorMessage,
    this.isCompletedCurrentEpisode = false,
    this.hwdecForcedSoftwareReason,
  });

  /// 创建尚未加载剧集前的占位状态。
  factory VideoPlaybackState.idle(WorkId workId) {
    final fallbackEp = EpisodeRecord(
      id: EpisodeId.trusted('pending:${workId.value}'),
      workId: workId,
      seasonNumber: 1,
    );
    final fallbackVar = MediaVariantRecord(
      id: VariantId.trusted('pending:${workId.value}'),
      workId: workId,
      episodeId: fallbackEp.id,
      sourceId: const SourceId.trusted('pending'),
      relativePath: '',
      fileName: '',
      fileSize: 0,
    );
    return VideoPlaybackState(
      isInitializing: false,
      isBuffering: false,
      currentEpisode: fallbackEp,
      currentVariant: fallbackVar,
    );
  }

  final bool isInitializing;
  final bool isBuffering;
  final bool hasFirstFrame;
  final bool isPlaying;
  final bool isClosing;
  final bool isMiniPlayer;
  final WorkRecord? currentWork;
  final VideoWorkBundle? currentBundle;
  final EpisodeRecord currentEpisode;
  final MediaVariantRecord currentVariant;
  final int? textureId;
  final bool windowsUnderlayActive;
  final String renderBackend;
  final String adapterName;
  final double durationSeconds;
  final double speed;
  final bool isSpeedBoostActive;
  final double volume;
  final bool isMuted;
  final bool isFullscreen;
  final bool audioOnlyMode;
  final VideoAspectMode aspectMode;
  final double windowBrightness;
  final bool probeOverlayVisible;
  final bool sideSheetOpen;
  final PlaybackProbeStats probeStats;
  final List<PlaybackChapter> chapters;
  final List<SubtitleChoice> subtitles;
  final List<AudioTrackChoice> audioTracks;
  final List<MpvAudioDevice> availableAudioDevices;
  final List<ShaderFileEntry> availableShaders;
  final double subtitleDelaySeconds;
  final double audioDelaySeconds;

  /// 当前主字幕的内存繁简转换模式。
  final SubtitleOpenCcMode subtitleOpenCcMode;

  /// 当前激活的副字幕轨道编号。
  final int? secondarySubtitleTrackId;

  /// 当前外挂字幕字体子集化三态检测结果。
  final SubtitleSubsetState? activeSubtitleSubsetState;

  /// 是否正在请求云端字体子集化处理。
  final bool isApplyingCloudSubset;

  /// 跨剧集音轨与字幕语言偏好记忆。
  final CrossEpisodeTrackMemory trackMemory;

  /// 当前播放进度命中可跳过片头或片尾章节窗口。
  final DetectedSkipWindow? activeSkipWindow;

  /// 最近一次瞬态轻提示载荷。
  final VideoTransientNotice? transientNotice;

  /// 致命或中断错误说明文本。
  final String? errorMessage;

  /// 当前分集是否已达成完播阈值或人工标记为已看完。
  final bool isCompletedCurrentEpisode;

  /// 若触发高风险编码软解强制回退策略，记录原因说明。
  final String? hwdecForcedSoftwareReason;

  /// 最近一次瞬态提示文案。
  String? get transientBanner => transientNotice?.message;

  /// 本地是否存在有效可执行播放内容。
  bool get hasPlayableMedia => currentVariant.relativePath.trim().isNotEmpty;

  /// 复制并局部替换视频播放状态字段。
  VideoPlaybackState copyWith({
    bool? isInitializing,
    bool? isBuffering,
    bool? hasFirstFrame,
    bool? isPlaying,
    bool? isClosing,
    bool? isMiniPlayer,
    WorkRecord? currentWork,
    VideoWorkBundle? currentBundle,
    EpisodeRecord? currentEpisode,
    MediaVariantRecord? currentVariant,
    int? textureId,
    bool clearTextureId = false,
    bool? windowsUnderlayActive,
    String? renderBackend,
    String? adapterName,
    double? durationSeconds,
    double? speed,
    bool? isSpeedBoostActive,
    double? volume,
    bool? isMuted,
    bool? isFullscreen,
    bool? audioOnlyMode,
    VideoAspectMode? aspectMode,
    double? windowBrightness,
    bool? probeOverlayVisible,
    bool? sideSheetOpen,
    PlaybackProbeStats? probeStats,
    List<PlaybackChapter>? chapters,
    List<SubtitleChoice>? subtitles,
    List<AudioTrackChoice>? audioTracks,
    List<MpvAudioDevice>? availableAudioDevices,
    List<ShaderFileEntry>? availableShaders,
    double? subtitleDelaySeconds,
    double? audioDelaySeconds,
    SubtitleOpenCcMode? subtitleOpenCcMode,
    int? secondarySubtitleTrackId,
    bool clearSecondarySubtitleTrackId = false,
    SubtitleSubsetState? activeSubtitleSubsetState,
    bool clearActiveSubtitleSubsetState = false,
    bool? isApplyingCloudSubset,
    CrossEpisodeTrackMemory? trackMemory,
    DetectedSkipWindow? activeSkipWindow,
    bool clearSkipWindow = false,
    VideoTransientNotice? transientNotice,
    bool clearTransientNotice = false,
    String? errorMessage,
    bool clearError = false,
    bool? isCompletedCurrentEpisode,
    String? hwdecForcedSoftwareReason,
    bool clearHwdecReason = false,
  }) {
    return VideoPlaybackState(
      isInitializing: isInitializing ?? this.isInitializing,
      isBuffering: isBuffering ?? this.isBuffering,
      hasFirstFrame: hasFirstFrame ?? this.hasFirstFrame,
      isPlaying: isPlaying ?? this.isPlaying,
      isClosing: isClosing ?? this.isClosing,
      isMiniPlayer: isMiniPlayer ?? this.isMiniPlayer,
      currentWork: currentWork ?? this.currentWork,
      currentBundle: currentBundle ?? this.currentBundle,
      currentEpisode: currentEpisode ?? this.currentEpisode,
      currentVariant: currentVariant ?? this.currentVariant,
      textureId: clearTextureId ? null : (textureId ?? this.textureId),
      windowsUnderlayActive:
          windowsUnderlayActive ?? this.windowsUnderlayActive,
      renderBackend: renderBackend ?? this.renderBackend,
      adapterName: adapterName ?? this.adapterName,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      speed: speed ?? this.speed,
      isSpeedBoostActive: isSpeedBoostActive ?? this.isSpeedBoostActive,
      volume: volume ?? this.volume,
      isMuted: isMuted ?? this.isMuted,
      isFullscreen: isFullscreen ?? this.isFullscreen,
      audioOnlyMode: audioOnlyMode ?? this.audioOnlyMode,
      aspectMode: aspectMode ?? this.aspectMode,
      windowBrightness: windowBrightness ?? this.windowBrightness,
      probeOverlayVisible: probeOverlayVisible ?? this.probeOverlayVisible,
      sideSheetOpen: sideSheetOpen ?? this.sideSheetOpen,
      probeStats: probeStats ?? this.probeStats,
      chapters: chapters ?? this.chapters,
      subtitles: subtitles ?? this.subtitles,
      audioTracks: audioTracks ?? this.audioTracks,
      availableAudioDevices:
          availableAudioDevices ?? this.availableAudioDevices,
      availableShaders: availableShaders ?? this.availableShaders,
      subtitleDelaySeconds: subtitleDelaySeconds ?? this.subtitleDelaySeconds,
      audioDelaySeconds: audioDelaySeconds ?? this.audioDelaySeconds,
      subtitleOpenCcMode: subtitleOpenCcMode ?? this.subtitleOpenCcMode,
      secondarySubtitleTrackId: clearSecondarySubtitleTrackId
          ? null
          : (secondarySubtitleTrackId ?? this.secondarySubtitleTrackId),
      activeSubtitleSubsetState: clearActiveSubtitleSubsetState
          ? null
          : (activeSubtitleSubsetState ?? this.activeSubtitleSubsetState),
      isApplyingCloudSubset:
          isApplyingCloudSubset ?? this.isApplyingCloudSubset,
      trackMemory: trackMemory ?? this.trackMemory,
      activeSkipWindow: clearSkipWindow
          ? null
          : (activeSkipWindow ?? this.activeSkipWindow),
      transientNotice: clearTransientNotice
          ? null
          : (transientNotice ?? this.transientNotice),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      isCompletedCurrentEpisode:
          isCompletedCurrentEpisode ?? this.isCompletedCurrentEpisode,
      hwdecForcedSoftwareReason: clearHwdecReason
          ? null
          : (hwdecForcedSoftwareReason ?? this.hwdecForcedSoftwareReason),
    );
  }
}

/// 跨版本或远程文件存在性检测辅助（隔离非必要的同步磁盘读取）。
abstract final class VideoPlaybackPathUtils {
  /// 根据当前工作路径判断文件是否存在且可读。
  static bool localFileExists(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return false;
    return File(trimmed).existsSync();
  }
}
