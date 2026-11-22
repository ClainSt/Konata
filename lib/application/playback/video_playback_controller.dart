import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../composition/platform_composition.dart';
import '../../domain/matching/episode_title_formatter.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/media_extensions.dart';
import '../../domain/models/media_source.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/models/playback_record.dart';
import '../../domain/models/series_group.dart';
import '../../domain/models/work.dart';
import '../../domain/playback/chapter_skip_analyzer.dart';
import '../../domain/playback/playback_probe_stats.dart';
import '../../domain/playback/subtitle_and_audio_choices.dart';
import '../../domain/playback/subtitle_content_processor.dart';
import '../../domain/playback/subtitle_timeline_remapper.dart';
import '../../domain/playback/track_preferences.dart';
import '../../domain/playback/video_aspect_mode.dart';
import '../../domain/playback/watched_tracker.dart';
import '../../domain/repositories/desktop_relay_service.dart';
import '../../infrastructure/logging/diagnostics_log_store.dart';
import '../../infrastructure/players/android/android_video_surface_controller.dart';
import '../../infrastructure/players/embedded_mpv_session.dart';
import '../../infrastructure/players/libmpv_ffi.dart';
import '../../infrastructure/players/mpv_quality_profile.dart';
import '../../infrastructure/players/mpv_thumbnail_service.dart';
import '../../infrastructure/storage/storage_root_provider.dart';
import '../../infrastructure/storage/temp_cache_pruner.dart';
import '../../infrastructure/sources/byte_stream_source_gateway.dart';
import '../../infrastructure/stream_bridge/local_stream_bridge.dart';
import '../../infrastructure/subtitles/fontinass_cloud_client.dart';
import '../providers/diagnostics_providers.dart';
import '../providers/library_providers.dart';
import '../providers/memory_coordinator.dart';
import '../providers/platform_capability.dart';
import '../providers/playback_providers.dart';
import 'audio_playback_notifier.dart';
import 'audiophile_safety_coordinator.dart';
import 'playback_preferences_provider.dart';
import 'subtitle_memory_engine.dart';
import 'unified_playback_coordinator.dart';
import 'unified_playback_engine.dart';

part 'video_playback_controller_episodes.dart';
part 'video_playback_controller_subtitles.dart';

/// 启动内置视频播放页面的强类型不可变请求键。
class VideoLaunchRequest {
  /// 创建视频播放请求。
  const VideoLaunchRequest({
    required this.work,
    required this.episode,
    required this.variant,
    required this.bundle,
    this.source,
    this.startSeconds = 0.0,
  });

  final Work work;
  final Episode episode;
  final MediaVariant variant;
  final WorkDetailBundle bundle;
  final MediaSource? source;
  final double startSeconds;

  @override
  bool operator ==(Object other) {
    return other is VideoLaunchRequest &&
        other.work.id == work.id &&
        other.episode.id == episode.id &&
        other.variant.id == variant.id &&
        (other.startSeconds - startSeconds).abs() < 0.0005;
  }

  @override
  int get hashCode => Object.hash(
    work.id,
    episode.id,
    variant.id,
    (startSeconds * 1000).round(),
  );
}

/// 视频播放器发往全站统一居中悬浮胶囊的瞬态提示载荷（递增序号确保同文案可重复触发）。
typedef VideoTransientNotice = ({
  int seq,
  String message,
  bool isError,
  Duration duration,
});

/// 内置视频播放页面完整不可变视图状态。
class VideoPlaybackState {
  /// 创建内置视频播放状态。
  const VideoPlaybackState({
    this.isInitializing = true,
    this.isBuffering = true,
    this.hasFirstFrame = false,
    this.isPlaying = false,
    this.isClosing = false,
    this.currentWork,
    this.currentBundle,
    required this.currentEpisode,
    required this.currentVariant,
    this.textureId,
    this.windowsUnderlayActive = false,
    this.renderBackend = '',
    this.adapterName = '',
    this.positionSeconds = 0.0,
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
    this.chapters = const [],
    this.subtitles = const [],
    this.audioTracks = const [],
    this.availableAudioDevices = const [],
    this.availableShaders = const [],
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
  });

  final bool isInitializing;
  final bool isBuffering;
  final bool hasFirstFrame;
  final bool isPlaying;
  final bool isClosing;
  final Work? currentWork;
  final WorkDetailBundle? currentBundle;
  final Episode currentEpisode;
  final MediaVariant currentVariant;
  final int? textureId;
  final bool windowsUnderlayActive;
  final String renderBackend;
  final String adapterName;
  final double positionSeconds;
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
  final List<File> availableShaders;
  final double subtitleDelaySeconds;
  final double audioDelaySeconds;

  /// 当前主字幕的内存直注 OpenCC 繁简转换模式。
  final SubtitleOpenCcMode subtitleOpenCcMode;

  /// 当前激活的副字幕轨道 ID（双语对照模式，`null` 表示关闭）。
  final int? secondarySubtitleTrackId;

  /// 当前外挂字幕探测到的字体子集三态分类（用于界面展示混淆子集防乱码保护徽标）。
  final SubtitleSubsetState? activeSubtitleSubsetState;

  /// 当前是否正在执行云端字幕字体子集化请求（防止重复触发并驱动按钮加载反馈）。
  final bool isApplyingCloudSubset;
  final CrossEpisodeTrackMemory trackMemory;
  final DetectedSkipWindow? activeSkipWindow;
  final VideoTransientNotice? transientNotice;
  final String? errorMessage;

  /// 最近一次瞬态提示文案（供外部轻量读取或日志检查）。
  String? get transientBanner => transientNotice?.message;

  VideoPlaybackState copyWith({
    bool? isInitializing,
    bool? isBuffering,
    bool? hasFirstFrame,
    bool? isPlaying,
    bool? isClosing,
    Work? currentWork,
    WorkDetailBundle? currentBundle,
    Episode? currentEpisode,
    MediaVariant? currentVariant,
    int? textureId,
    bool? windowsUnderlayActive,
    String? renderBackend,
    String? adapterName,
    double? positionSeconds,
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
    List<File>? availableShaders,
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
  }) {
    return VideoPlaybackState(
      isInitializing: isInitializing ?? this.isInitializing,
      isBuffering: isBuffering ?? this.isBuffering,
      hasFirstFrame: hasFirstFrame ?? this.hasFirstFrame,
      isPlaying: isPlaying ?? this.isPlaying,
      isClosing: isClosing ?? this.isClosing,
      currentWork: currentWork ?? this.currentWork,
      currentBundle: currentBundle ?? this.currentBundle,
      currentEpisode: currentEpisode ?? this.currentEpisode,
      currentVariant: currentVariant ?? this.currentVariant,
      textureId: textureId ?? this.textureId,
      windowsUnderlayActive:
          windowsUnderlayActive ?? this.windowsUnderlayActive,
      renderBackend: renderBackend ?? this.renderBackend,
      adapterName: adapterName ?? this.adapterName,
      positionSeconds: positionSeconds ?? this.positionSeconds,
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
    );
  }
}

/// 内置 `libmpv` 视频播放控制器（收敛于 `UnifiedPlaybackEngine` 四维代数与熔断器、
/// 音视频共享发烧音频安全链路、`WatchedTracker` 持久化、跨季连播与 1Hz 探针采集中枢）。
class VideoPlaybackController extends Notifier<VideoPlaybackState> {
  /// 创建视频播放控制器。
  VideoPlaybackController(
    this.request, {
    this.sessionFactory,
    this.deferBootstrap = false,
    this.initialState,
  });

  final VideoLaunchRequest request;
  final EmbeddedMpvSession Function()? sessionFactory;
  final bool deferBootstrap;
  final VideoPlaybackState? initialState;
  late final EmbeddedSessionMutex _sessionMutex;
  late final UnifiedPlaybackEngine _engine;
  late final AudiophileSafetyCoordinator _safetyCoordinator;
  late final LocalStreamBridge _streamBridge;
  late final DiagnosticsLogStore _logStore;

  Ref get _ref => ref;
  bool get mounted => ref.mounted;
  VideoPlaybackState get _state => state;
  set _state(VideoPlaybackState value) => state = value;

  @override
  set state(VideoPlaybackState value) {
    final prev = stateOrNull;
    final positionChanged =
        prev == null ||
        (prev.positionSeconds - value.positionSeconds).abs() > 0.0005;
    super.state = value;
    if (positionChanged &&
        (_positionListenable.value - value.positionSeconds).abs() > 0.0005) {
      _positionListenable.value = value.positionSeconds;
    }
  }

  @override
  VideoPlaybackState build() {
    _sessionMutex = ref.read(embeddedSessionMutexProvider);
    _engine = ref.read(unifiedPlaybackEngineProvider);
    _safetyCoordinator = ref.read(audiophileSafetyCoordinatorProvider);
    _streamBridge = ref.read(localStreamBridgeProvider);
    _logStore = ref.read(diagnosticsLogStoreProvider);
    _bundleCacheByWorkId[request.work.id] = request.bundle;
    ref.onDispose(_disposeResources);
    final prefs = ref.read(playbackPreferencesProvider);
    if (!deferBootstrap) {
      unawaited(_bootstrap());
    }
    final seed =
        initialState ??
        VideoPlaybackState(
          currentWork: request.work,
          currentBundle: request.bundle,
          currentEpisode: request.episode,
          currentVariant: request.variant,
          volume: prefs.defaultVolume,
          speed: prefs.qualityConfig.defaultSpeed,
        );
    _positionListenable.value = seed.positionSeconds;
    _latestPositionSeconds = seed.positionSeconds;
    return seed;
  }

  /// 是否存在可切换的下一集（含跨季正片连播越过本季特典）。
  bool get hasNextEpisodeAny => _hasNextEpisodeAnyImpl();

  /// 是否存在可切换的上一集（含跨季回退至上一季末集正片）。
  bool get hasPreviousEpisodeAny => _hasPreviousEpisodeAnyImpl();

  /// 跳转并原地播放下一集（支持跨季无缝切换并显示描边连播提示）。
  Future<bool> goToNextEpisode({bool isAutoAdvance = false}) =>
      _goToNextEpisodeImpl(isAutoAdvance: isAutoAdvance);

  /// 跳转并原地回退上一集（支持上一季末集正片对称回退）。
  Future<bool> goToPreviousEpisode() => _goToPreviousEpisodeImpl();

  /// 一键截取原画 PNG 视频帧（支持纯净视频帧与含字幕帧；Windows 存作品目录，Android 事务写入系统相册）。
  Future<File?> captureCleanScreenshot({
    ScreenshotCaptureMode mode = ScreenshotCaptureMode.pureVideo,
  }) async {
    final res = await captureScreenshot(mode: mode);
    return res?.file;
  }

  /// 双模原画截图（返回桌面文件或 Android `MediaStore` 相册 URI）。
  Future<ScreenshotCaptureResult?> captureScreenshot({
    ScreenshotCaptureMode mode = ScreenshotCaptureMode.pureVideo,
  }) => _captureScreenshotImpl(mode: mode);

  final WatchedTracker _watchedTracker = WatchedTracker();
  final AudiophileMicroFadeDriver _microFadeDriver =
      AudiophileMicroFadeDriver();
  final Completer<AndroidVideoSurfaceController>? _androidSurfaceCompleter =
      Platform.isAndroid ? Completer<AndroidVideoSurfaceController>() : null;

  final Map<String, WorkDetailBundle> _bundleCacheByWorkId = {};
  final Map<String, CrossEpisodeTrackMemory> _trackMemoryByWorkId = {};

  EmbeddedMpvSession? _session;
  SubtitleMemoryEngine? _subtitleMemoryEngine;
  MpvThumbnailService? _thumbnailService;
  final ValueNotifier<int> _thumbnailRevision = ValueNotifier<int>(0);
  final ValueNotifier<double> _positionListenable = ValueNotifier<double>(0.0);
  Timer? _persistTimer;
  Timer? _probeTimer;
  Timer? _skipFadeTimer;
  Timer? _chapterSkipWakeTimer;
  int _transientNoticeSeq = 0;

  ChapterSkipPlan _skipPlan = const ChapterSkipPlan();
  DetectedSkipWindow? _dismissedSkipWindow;
  bool _hudProgressActive = true;
  bool _pendingThumbnailRevisionFlush = false;
  bool _pendingMetadataUiRefresh = false;
  String? _pendingPersistedBundleWorkId;
  double _latestPositionSeconds = 0.0;
  bool _persistDirty = false;
  bool _closedCleanly = false;
  bool _alreadyPersistedCompleted = false;
  double? _speedBeforeBoost;
  double? _volumeBeforeDuck;
  int _thumbnailGeneration = 0;
  int _boundNativeInstanceId = 0;
  int _boundPhysicalEpoch = 0;
  String? _activeExternalSubtitleSourcePath;
  int? _activeOriginalSubtitleTrackId;
  String? _activeExternalSubtitleTitle;
  String? _lastIngestedCloudSubsetFontsDir;
  ({
    String episodeId,
    String variantId,
    String streamToken,
    String mediaTarget,
  })?
  _prewarmedNextEpisode;
  String? _prewarmAttemptedForEpisodeId;
  int _prewarmGeneration = 0;

  /// 当前已完成后台静默预热的下一分集 ID（供自动化回归测试验证预热与接管生命周期）。
  String? get prewarmedNextEpisodeId => _prewarmedNextEpisode?.episodeId;

  /// 当前正在播放的活跃作品实体（支持同系列跨季原地热切换）。
  Work get activeWork => state.currentWork ?? request.work;

  /// 当前正在播放作品的完整详情包。
  WorkDetailBundle get activeBundle => state.currentBundle ?? request.bundle;

  /// 同系列按时间线排布的成员列表（至少包含当前活跃作品）。
  List<Work> get orderedSeriesMembers {
    final members = activeBundle.seriesMembers;
    if (members.length < 2) return [activeWork];
    return SeriesSeasonFormatter.sortSeriesMembers(members);
  }

  /// 当前是否开启高频播放进度向 UI 派发（OSD 隐藏或画中画静默期为 `false`，保持 0 重绘唤醒）。
  bool get isHudProgressActive => _hudProgressActive;

  /// 当前底层 `libmpv` 是否仍保持 `time-pos` 属性订阅（供集成测试与诊断核验静默退订）。
  bool get isPositionObservationEnabled =>
      _session?.isPositionObservationEnabled ?? false;

  /// 高频播放进度独立监听通道（仅 OSD 展开期推送至进度条叶子，免除 Riverpod 完整状态扇出）。
  ValueListenable<double> get positionListenable => _positionListenable;

  /// 当前真实播放秒数（即使 OSD 隐藏静默期未刷新 `state.positionSeconds` 亦保持精确）。
  double get currentPositionSeconds =>
      _hudProgressActive ? _positionListenable.value : _latestPositionSeconds;

  /// 当前视频会话微淡入斜坡是否活跃（供回归测试验证终态即停钟）。
  bool get isMicroFadeActive => _microFadeDriver.isActive;

  /// 控制 OSD 隐藏稳态期是否挂起高频进度订阅与 Riverpod 状态派发。
  void setHudProgressActive(bool active) {
    if (!mounted || _hudProgressActive == active) return;
    _hudProgressActive = active;
    _session?.setPositionObservationEnabled(active);
    if (active) {
      _chapterSkipWakeTimer?.cancel();
      _chapterSkipWakeTimer = null;
      final latest =
          _session?.readCurrentPositionSeconds() ?? _latestPositionSeconds;
      _latestPositionSeconds = latest;
      if ((latest - state.positionSeconds).abs() > 0.01) {
        state = state.copyWith(positionSeconds: latest);
      }
      if (_pendingThumbnailRevisionFlush) {
        _pendingThumbnailRevisionFlush = false;
        _thumbnailRevision.value += 1;
      }
      if (_pendingMetadataUiRefresh) {
        _pendingMetadataUiRefresh = false;
        _session?.refreshMetadata();
      }
      final pendingWorkId = _pendingPersistedBundleWorkId;
      if (pendingWorkId != null) {
        _pendingPersistedBundleWorkId = null;
        final cached = _bundleCacheByWorkId[pendingWorkId];
        if (cached != null && activeWork.id == pendingWorkId) {
          state = state.copyWith(currentBundle: cached);
        }
        _ref.invalidate(playbackHistoryProvider);
        _ref.invalidate(workDetailBundleProvider(pendingWorkId));
      }
      _evaluateChapterSkipWindow(latest);
    } else {
      final latest =
          _session?.readCurrentPositionSeconds() ?? state.positionSeconds;
      _latestPositionSeconds = latest;
      _scheduleNextChapterSkipWake();
    }
  }

  /// 缩略图缓存变更版本号（仅通知进度条悬停气泡局部刷新，零全页重建）。
  ValueListenable<int> get thumbnailRevisionListenable => _thumbnailRevision;

  /// 查询悬停时间点的精确或邻近缓存缩略图帧字节。
  Uint8List? resolveThumbnailPreview(double seconds) {
    return _thumbnailService?.resolvePreviewFrame(seconds);
  }

  /// 通知后台 `thumbfast` 会话按需预取目标时间点缩略图（首次悬停才惰性建联，传 `null` 表示离开进度条）。
  void requestThumbnailPreview(double? seconds) {
    _requestThumbnailPreviewLazy(seconds);
  }

  /// Android `PlatformView` / Underlay 表面创建后向控制器交付通道（支持热重绑）。
  void attachAndroidSurface(AndroidVideoSurfaceController ctrl) {
    if (_androidSurfaceCompleter != null &&
        !_androidSurfaceCompleter.isCompleted) {
      _androidSurfaceCompleter.complete(ctrl);
      return;
    }
    final session = _session;
    if (session != null && !session.isDisposed) {
      unawaited(session.attachOrRebindAndroidSurface(ctrl));
    }
  }

  /// Android 画中画返回或切回前台时重绑当前底层硬件表面（引擎存活路径，绝不重建解码会话）。
  Future<void> rebindAndroidSurfaceIfNeeded() async {
    final session = _session;
    if (!mounted || state.isClosing || session == null || session.isDisposed) {
      return;
    }
    await session.rebindCurrentAndroidSurface();
  }

  /// 向 Android 系统请求 `AUDIOFOCUS_GAIN` 并挂载失焦暂停 / 闪避降音监听。
  Future<void> ensureAudioFocus() async {
    if (!KonataPlatform.isAndroid) return;
    await _ref
        .read(androidAudioFocusServiceProvider)
        .requestAudioFocus(
          onLoss: () {
            if (!mounted || state.isClosing) return;
            _volumeBeforeDuck = null;
            if (state.isPlaying) {
              _session?.setPlaying(false);
              state = state.copyWith(isPlaying: false);
            }
          },
          onDuck: () {
            if (!mounted || state.isClosing || !state.isPlaying) return;
            _volumeBeforeDuck ??= state.volume;
            final ducked = (_volumeBeforeDuck! * 0.25).clamp(0.0, 100.0);
            _session?.setVolume(ducked);
          },
          onGain: () {
            if (!mounted || state.isClosing) return;
            final restore = _volumeBeforeDuck;
            _volumeBeforeDuck = null;
            if (restore != null) {
              _session?.setVolume(restore);
            }
          },
        );
  }

  /// 系统后台或关闭画中画时由生命周期协调器触发的精确暂停。
  void setPlayingPausedByLifecycle() {
    _volumeBeforeDuck = null;
    if (state.isPlaying) {
      _session?.setPlaying(false);
      state = state.copyWith(isPlaying: false);
    }
  }

  Future<void> _bootstrap() async {
    Future.microtask(() async {
      if (!mounted) return;
      _ref.read(konataMemoryCoordinatorProvider).cancelPostPlaybackTrim();
      _ref.read(videoPlaybackActiveProvider.notifier).state = true;
      await _ref.read(audioPlaybackProvider.notifier).pauseForVideoSession();
      await AndroidPlaybackWindowBridge.beginWindow();
      await ensureAudioFocus();
      if (!state.audioOnlyMode &&
          _ref.read(activeVideoSessionProvider).isExpanded) {
        await AndroidPlaybackWindowBridge.applyVideoOrientationAndWindow(
          landscape: true,
          hideSystemBars: true,
        );
      }
    });

    await _sessionMutex.runExclusive(() async {
      if (!mounted || state.isClosing || _closedCleanly) return;

      final saved = request.bundle.playbackByEpisodeId[state.currentEpisode.id];
      _alreadyPersistedCompleted = saved?.isCompleted ?? false;

      final storageRoot = _ref.read(storageRootProvider);
      unawaited(_ref.read(tempCachePrunerProvider).pruneIfDue());
      // 着色器扫描不阻塞视频首帧起播，后台并行异步发现后回填侧栏列表。
      unawaited(_discoverAvailableShadersInBackground(storageRoot));
      _engine.recordManualSelection();

      final session = sessionFactory != null
          ? sessionFactory!()
          : EmbeddedMpvSession(
              storageRoot: storageRoot,
              streamBridge: _streamBridge,
              nativeClientAcquirer: ({onEvicted}) async {
                final acquired = await _engine.acquireExclusiveNativeClient(
                  stage: PlaybackStageKind.video,
                  onEvicted: onEvicted,
                );
                _boundNativeInstanceId = acquired.nativeInstanceId;
                _boundPhysicalEpoch = _engine.beginPhysicalMedia(
                  nativeInstanceId: _boundNativeInstanceId,
                  stage: PlaybackStageKind.video,
                );
                return acquired.client;
              },
              nativeClientReleaser: _engine.releaseNativeClient,
              desktopSurfaceBridge: _ref.read(
                konataVideoBridgeFactoryProvider,
              )(),
              desktopProfileDelegate: _ref.read(
                mpvPlatformProfileDelegateProvider,
              ),
              gatewayFactory: _ref.read(mediaSourceGatewayFactoryProvider),
              logStore: _logStore,
              subtitleDirectoryIndex: _ref.read(subtitleDirectoryIndexProvider),
              fontPoolManager: _ref.read(subtitleFontPoolManagerProvider),
            );
      if (sessionFactory != null && session.nativeClientAcquirer == null) {
        _boundNativeInstanceId = _engine.attachNativeInstance(
          stage: PlaybackStageKind.video,
        );
        _boundPhysicalEpoch = _engine.beginPhysicalMedia(
          nativeInstanceId: _boundNativeInstanceId,
          stage: PlaybackStageKind.video,
        );
      }
      _session = session;
      unawaited(_preloadAdjacentSeriesBundles());

      _bindSessionCallbacks(session);
      _safetyCoordinator.attachSession(
        owner: this,
        clientProvider: () => _session?.activeClient,
        prefsProvider: () => _ref.read(playbackPreferencesProvider),
        onTransientMuteAndPause: (_) {
          _microFadeDriver.cancel();
          if (!mounted || state.isClosing) return;
          state = state.copyWith(isMuted: true, isPlaying: false);
          showTransientBanner('检测到音频外设拔出，已瞬态静音并暂停防爆音', isError: true);
        },
      );

      try {
        final prefs = _ref.read(playbackPreferencesProvider);
        await session.initializeAndLoad(
          request: EmbeddedVideoLoadRequest(
            workId: request.work.id,
            variant: request.variant,
            source: request.source,
            startSeconds: request.startSeconds,
          ),
          qualityConfig: prefs.qualityConfig,
          trackMemory: state.trackMemory,
          initialVolume: state.volume,
          androidSurfaceSupplier: _androidSurfaceCompleter != null
              ? () => _androidSurfaceCompleter.future
              : null,
        );
        if (!mounted) return;
        _engine.bindActiveNativeClient(
          session.activeClient,
          stage: PlaybackStageKind.video,
        );
        state = state.copyWith(
          isInitializing: false,
          textureId: session.textureIdListenable.value,
          windowsUnderlayActive: session.underlayActiveListenable.value,
          renderBackend: session.renderBackendListenable.value,
          adapterName: session.adapterNameListenable.value,
          probeStats: _collectAppropriateProbeStats(session),
        );

        _persistTimer?.cancel();
        _persistTimer = Timer.periodic(const Duration(seconds: 5), (_) {
          if (!_hudProgressActive && state.isPlaying) {
            final sampled = _session?.readCurrentPositionSeconds();
            if (sampled != null && sampled.isFinite) {
              _latestPositionSeconds = sampled;
              _persistDirty = true;
              _watchedTracker.sample(
                positionSeconds: sampled,
                durationSeconds: state.durationSeconds,
                isPlaying: state.isPlaying,
                speed: state.speed,
              );
              _evaluateChapterSkipWindow(sampled);
            }
          }
          if (_persistDirty) {
            _persistDirty = false;
            unawaited(_persistProgress(isFinal: false));
          }
        });
        if (!_hudProgressActive) {
          session.setPositionObservationEnabled(false);
          _scheduleNextChapterSkipWake();
        }
      } catch (e) {
        _logStore.record('VIDEO', '内置视频启动失败：$e', isError: true);
        _engine.recordPhysicalMediaFailure();
        if (mounted) {
          state = state.copyWith(
            isInitializing: false,
            isBuffering: false,
            errorMessage: '内置视频启动失败: $e',
          );
        }
      }
    });
  }

  void _bindSessionCallbacks(EmbeddedMpvSession session) {
    session.onNativeClientBound = (client) {
      if (identical(_engine.activeNativeClient, client) &&
          _engine.activeStage == PlaybackStageKind.video &&
          _boundNativeInstanceId != _engine.nativeInstanceId) {
        _boundNativeInstanceId = _engine.nativeInstanceId;
        _boundPhysicalEpoch = _engine.beginPhysicalMedia(
          nativeInstanceId: _boundNativeInstanceId,
          stage: PlaybackStageKind.video,
        );
      }
    };
    session.onBindMainStreamLease = (token) =>
        _engine.bindMainStreamLease(token);
    session.onPlaylistEntryStarted = (entryId) =>
        _engine.bindPlaylistEntryId(entryId);
    session.onValidatePhysicalEvent = ({int? playlistEntryId}) =>
        _engine.matchesPhysicalEvent(
          physicalMediaEpoch: _boundPhysicalEpoch,
          nativeInstanceId: _boundNativeInstanceId,
          playlistEntryId: playlistEntryId,
        );
    session.onFileLoaded = _engine.recordFileLoaded;
    session.onApplyAudiophileSafetyChain = (client) {
      if (!mounted) return;
      _safetyCoordinator.applyToClient(
        client,
        prefs: _ref.read(playbackPreferencesProvider),
      );
    };
    session.onTriggerMicroFadeIn =
        (client, {required targetVolume, required isMuted}) {
          _microFadeDriver.start(
            client: client,
            plan: _safetyCoordinator.activePlan,
            targetVolume: targetVolume,
            isMuted: isMuted,
            isAlive: () => mounted && !state.isClosing && !_closedCleanly,
          );
        };
    session.onAudioDeviceListChanged = (devices, currentDevice) {
      _safetyCoordinator.handleWindowsAudioDevicesChanged(
        devices: devices,
        currentAudioDevice: currentDevice,
      );
    };
    session.onMountExternalTextSubtitles =
        _mountDiscoveredExternalTextSubtitles;
    session.mountedSubtitleSourcePathsReader = _readMountedSubtitleSourcePaths;
    session.mountedCloudSubsetTrackIdsReader = _readMountedCloudSubsetTrackIds;

    session.textureIdListenable.addListener(() {
      if (mounted) {
        state = state.copyWith(textureId: session.textureIdListenable.value);
      }
    });
    session.underlayActiveListenable.addListener(() {
      if (mounted) {
        state = state.copyWith(
          windowsUnderlayActive: session.underlayActiveListenable.value,
        );
      }
    });
    session.renderBackendListenable.addListener(() {
      if (mounted) {
        state = state.copyWith(
          renderBackend: session.renderBackendListenable.value,
        );
      }
    });
    session.adapterNameListenable.addListener(() {
      if (mounted) {
        state = state.copyWith(
          adapterName: session.adapterNameListenable.value,
        );
      }
    });

    session.onPositionChanged = _handlePositionChanged;
    session.onDurationChanged = _handleDurationChanged;
    session.onPlayingChanged = _handlePlayingChanged;
    session.onBufferingChanged = (buf) {
      if (mounted && state.isBuffering != buf) {
        state = state.copyWith(isBuffering: buf);
      }
    };
    session.onSpeedChanged = (spd) {
      if (mounted && (state.speed - spd).abs() > 0.0001) {
        state = state.copyWith(speed: spd);
      }
    };
    session.onFirstFrameRendered = () {
      _engine.recordEffectiveProgress(firstFrameRendered: true);
      if (!mounted) return;
      final isInitialFrame = !state.hasFirstFrame;
      if (isInitialFrame || _hudProgressActive || state.probeOverlayVisible) {
        state = state.copyWith(
          hasFirstFrame: true,
          probeStats: _collectAppropriateProbeStats(session),
        );
      }
    };
    session.onHwdecChanged = (hw) {
      if (!mounted) return;
      if (!_hudProgressActive &&
          !state.probeOverlayVisible &&
          state.probeStats.hwdecCurrent == hw) {
        return;
      }
      state = state.copyWith(probeStats: _collectAppropriateProbeStats(session));
    };
    session.onMediaMetadataUpdated = _handleMetadataUpdated;
    session.onEndOfFile = _handleEndOfFile;
    session.onNotice = (msg) =>
        showTransientBanner(msg, isError: msg != '桌面视频渲染表面已重建');
    session.onFatalError = (msg) => unawaited(_handleFatalSessionError(msg));
  }

  void _handlePositionChanged(double posSeconds) {
    if (!mounted) return;
    _latestPositionSeconds = posSeconds;
    _persistDirty = true;
    _watchedTracker.sample(
      positionSeconds: posSeconds,
      durationSeconds: state.durationSeconds,
      isPlaying: state.isPlaying,
      speed: state.speed,
    );
    if (_hudProgressActive) {
      _positionListenable.value = posSeconds;
      if (posSeconds.floor() != state.positionSeconds.floor() ||
          (posSeconds - state.positionSeconds).abs() >= 1.0) {
        state = state.copyWith(positionSeconds: posSeconds);
      }
    }
    _evaluateChapterSkipWindow(posSeconds);
    _maybeScheduleNextEpisodePrewarm(posSeconds);
  }

  void _handleDurationChanged(double durSeconds) {
    if (!mounted) return;
    if ((state.durationSeconds - durSeconds).abs() < 0.01) return;
    state = state.copyWith(durationSeconds: durSeconds);
    _recomputeChapterSkipPlan();
    _thumbnailService?.updateChapters(
      state.chapters,
      durationSeconds: durSeconds > 0 ? durSeconds : null,
    );
  }

  void _handlePlayingChanged(bool playing) {
    if (!mounted) return;
    if (state.isPlaying != playing) {
      state = state.copyWith(isPlaying: playing);
    }
    if (!_hudProgressActive) {
      if (playing) {
        _scheduleNextChapterSkipWake();
      } else {
        _chapterSkipWakeTimer?.cancel();
        _chapterSkipWakeTimer = null;
      }
    }
    if (!playing && _persistDirty) {
      _persistDirty = false;
      unawaited(_persistProgress(isFinal: false));
    }
  }

  /// 通知 D3D11 桥接同步视频目标渲染分辨率（Windows 兼容共享纹理回退路径）。
  void notifySurfaceViewportSize(
    double logicalWidth,
    double logicalHeight,
    double devicePixelRatio,
  ) {
    final session = _session;
    if (session == null || !Platform.isWindows) return;
    final pw = (logicalWidth * devicePixelRatio).round().clamp(64, 7680);
    final ph = (logicalHeight * devicePixelRatio).round().clamp(64, 4320);
    unawaited(session.resizeDesktopSurfaceTarget(pw, ph));
  }

  /// 帧同步更新 Windows 底层 10-bit/HDR 渲染宿主的物理像素视口矩形、圆角裁剪与显隐状态。
  Future<void> syncWindowsUnderlayViewport({
    required int leftPx,
    required int topPx,
    required int rightPx,
    required int bottomPx,
    double cornerRadiusPx = 0.0,
    bool visible = true,
  }) async {
    final session = _session;
    if (session == null || !Platform.isWindows) return;
    await session.setWindowsUnderlayViewport(
      leftPx: leftPx,
      topPx: topPx,
      rightPx: rightPx,
      bottomPx: bottomPx,
      cornerRadiusPx: cornerRadiusPx,
      visible: visible,
    );
  }

  void togglePlayPause() {
    final next = !state.isPlaying;
    if (next) {
      _volumeBeforeDuck = null;
      _session?.setVolume(state.volume);
      unawaited(ensureAudioFocus());
    }
    _session?.setPlaying(next);
    state = state.copyWith(isPlaying: next);
  }

  void seekAbsolute(double seconds) {
    _watchedTracker.notifySeek();
    final clamped = state.durationSeconds > 0
        ? seconds.clamp(0.0, state.durationSeconds)
        : (seconds < 0 ? 0.0 : seconds);
    _latestPositionSeconds = clamped;
    final cachedHit = _session?.seekAbsolute(clamped) ?? false;
    if (_hudProgressActive) {
      state = state.copyWith(
        positionSeconds: clamped,
        isBuffering: cachedHit ? false : state.isBuffering,
      );
    } else {
      if (cachedHit && state.isBuffering) {
        state = state.copyWith(isBuffering: false);
      }
      _scheduleNextChapterSkipWake();
    }
  }

  void seekRelative(double deltaSeconds) {
    final base =
        _session?.readCurrentPositionSeconds() ?? currentPositionSeconds;
    seekAbsolute(base + deltaSeconds);
  }

  void stepFrameForward() {
    _session?.stepFrameForward();
    state = state.copyWith(isPlaying: false);
  }

  void stepFrameBackward() {
    _session?.stepFrameBackward();
    state = state.copyWith(isPlaying: false);
  }

  void startSpeedBoost() {
    if (state.isSpeedBoostActive) return;
    _speedBeforeBoost = state.speed;
    _session?.setSpeed(2.0);
    state = state.copyWith(speed: 2.0, isSpeedBoostActive: true);
  }

  void endSpeedBoost() {
    if (!state.isSpeedBoostActive) return;
    final restore = _speedBeforeBoost ?? 1.0;
    _speedBeforeBoost = null;
    _session?.setSpeed(restore);
    state = state.copyWith(speed: restore, isSpeedBoostActive: false);
  }

  void setPlaybackSpeed(double speed) {
    final clamped = speed.clamp(0.25, 4.0);
    _speedBeforeBoost = null;
    _session?.setSpeed(clamped);
    state = state.copyWith(speed: clamped, isSpeedBoostActive: false);
    unawaited(
      _ref.read(playbackPreferencesProvider.notifier).setDefaultSpeed(clamped),
    );
  }

  void setVolume(double volume) {
    final clamped = volume.clamp(0.0, 100.0);
    _microFadeDriver.cancel();
    _session?.setVolume(clamped);
    if (clamped > 0 && state.isMuted) {
      _session?.setMute(false);
      state = state.copyWith(volume: clamped, isMuted: false);
    } else {
      state = state.copyWith(volume: clamped);
    }
    unawaited(
      _ref.read(playbackPreferencesProvider.notifier).setDefaultVolume(clamped),
    );
  }

  void adjustVolume(double delta) => setVolume(state.volume + delta);

  void toggleMute() {
    final next = !state.isMuted;
    _microFadeDriver.cancel();
    _session?.setMute(next);
    state = state.copyWith(isMuted: next);
  }

  /// 在不重建解码会话的前提下切换视频后台纯音频模式（`vid=no` ↔ `vid=auto`）。
  void setAudioOnlyMode(bool enabled) {
    if (state.audioOnlyMode == enabled) return;
    _session?.setVideoTrackEnabled(!enabled);
    state = state.copyWith(audioOnlyMode: enabled);
    if (KonataPlatform.isAndroid) {
      final sessionExpanded = _ref.read(activeVideoSessionProvider).isExpanded;
      final useLandscape = !enabled && sessionExpanded;
      unawaited(
        AndroidPlaybackWindowBridge.applyVideoOrientationAndWindow(
          landscape: useLandscape,
          hideSystemBars: useLandscape,
        ),
      );
    }
    showTransientBanner(enabled ? '已切换为后台纯音频模式' : '已恢复视频画面渲染');
  }

  /// 切换视频后台纯音频模式。
  void toggleAudioOnlyMode() => setAudioOnlyMode(!state.audioOnlyMode);

  /// 切换视频画面比例模式。
  void setAspectMode(VideoAspectMode mode) {
    if (state.aspectMode == mode) return;
    _session?.applyAspectMode(mode);
    state = state.copyWith(aspectMode: mode);
    showTransientBanner('画面比例：${mode.label}');
  }

  /// 调节播放窗口亮度（`0.0 ~ 1.0`）。
  void setWindowBrightness(double brightness) {
    final clamped = brightness.clamp(0.0, 1.0).toDouble();
    state = state.copyWith(windowBrightness: clamped);
    unawaited(AndroidPlaybackWindowBridge.setBrightness(clamped));
  }

  void toggleProbeOverlay() {
    final next = !state.probeOverlayVisible;
    _probeTimer?.cancel();
    if (next) {
      final snap = _session?.collectProbeStats() ?? const PlaybackProbeStats();
      state = state.copyWith(probeOverlayVisible: true, probeStats: snap);
      _probeTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted || !state.probeOverlayVisible) return;
        final stats = _session?.collectProbeStats();
        if (stats != null) {
          state = state.copyWith(probeStats: stats);
        }
      });
    } else {
      state = state.copyWith(probeOverlayVisible: false);
    }
  }

  /// 打开或收起右滑播控侧栏并在展开时刷新轨道元数据。
  void setSideSheetOpen(bool open) {
    if (state.sideSheetOpen == open) return;
    if (open) {
      _session?.refreshMetadata();
    }
    state = state.copyWith(sideSheetOpen: open);
  }

  /// 安全保存进度、退出全屏并在串行互斥锁内彻底释放底层硬件资源（允许多次幂等调用）。
  Future<void> closeAndRelease() async {
    if (_closedCleanly) return;
    _closedCleanly = true;

    _microFadeDriver.cancel();
    _safetyCoordinator.detachSession(this);
    _persistTimer?.cancel();
    _probeTimer?.cancel();
    _skipFadeTimer?.cancel();
    _chapterSkipWakeTimer?.cancel();
    _subtitleMemoryEngine?.dispose();
    _subtitleMemoryEngine = null;
    _disposePrewarmedNextEpisode();
    await _releaseThumbnailService(disposeNotifier: true);

    if (mounted) {
      state = state.copyWith(isClosing: true);
    }

    if (state.isFullscreen && KonataPlatform.isWindows) {
      await _ref.read(konataWindowHostProvider).setFullScreen(false);
    } else if (KonataPlatform.isAndroid) {
      await AndroidPlaybackWindowBridge.applyVideoOrientationAndWindow(
        landscape: false,
        hideSystemBars: false,
      );
      await AndroidPlaybackWindowBridge.endWindow();
      await _ref.read(androidAudioFocusServiceProvider).abandonAudioFocus();
    }

    await _persistProgress(isFinal: true);

    final sessionToDispose = _session;
    _session = null;
    if (sessionToDispose != null) {
      await _sessionMutex.runExclusive(() => sessionToDispose.dispose());
    }
    final leasedTokens = _engine.resetSession(stage: PlaybackStageKind.video);
    for (final token in leasedTokens) {
      unawaited(
        _streamBridge.unregisterSession(token).catchError((Object e) {
          _logStore.record('VIDEO', '释放统一引擎流租约 $token 失败：$e');
        }),
      );
    }

    if (mounted) {
      _ref.read(videoPlaybackActiveProvider.notifier).state = false;
    }
    _ref.read(konataMemoryCoordinatorProvider).schedulePostPlaybackTrim();
  }

  void _disposeResources() {
    _microFadeDriver.cancel();
    _safetyCoordinator.detachSession(this);
    _persistTimer?.cancel();
    _probeTimer?.cancel();
    _skipFadeTimer?.cancel();
    _chapterSkipWakeTimer?.cancel();
    _subtitleMemoryEngine?.dispose();
    _subtitleMemoryEngine = null;
    _disposePrewarmedNextEpisode();

    if (!_closedCleanly) {
      _closedCleanly = true;
      unawaited(_releaseThumbnailService(disposeNotifier: true));
      final sessionToDispose = _session;
      _session = null;
      if (sessionToDispose != null) {
        unawaited(_sessionMutex.runExclusive(() => sessionToDispose.dispose()));
      }
      final leasedTokens = _engine.resetSession(stage: PlaybackStageKind.video);
      for (final token in leasedTokens) {
        unawaited(
          _streamBridge.unregisterSession(token).catchError((Object e) {
            _logStore.record('VIDEO', '销毁期释放流租约 $token 失败：$e');
          }),
        );
      }
    }
    _thumbnailRevision.dispose();
    _positionListenable.dispose();
  }
}

/// 内置视频播放控制器 Family Provider（按单次播放请求自动挂载与释放）。
final videoPlaybackProvider = NotifierProvider.autoDispose
    .family<VideoPlaybackController, VideoPlaybackState, VideoLaunchRequest>(
      VideoPlaybackController.new,
    );
