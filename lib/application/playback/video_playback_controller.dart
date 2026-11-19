import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../composition/platform_composition.dart';
import '../../domain/matching/episode_title_formatter.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/external_player_config.dart';
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
import '../../domain/repositories/external_player_launcher.dart';
import '../../infrastructure/players/android/android_video_surface_controller.dart';
import '../../infrastructure/players/embedded_mpv_session.dart';
import '../../infrastructure/players/libmpv_ffi.dart';
import '../../infrastructure/players/mpv_quality_profile.dart';
import '../../infrastructure/players/mpv_thumbnail_service.dart';
import '../../infrastructure/storage/storage_root_provider.dart';
import '../providers/diagnostics_providers.dart';
import '../providers/library_providers.dart';
import '../providers/platform_capability.dart';
import '../providers/playback_providers.dart';
import 'audio_playback_notifier.dart';
import 'playback_preferences_provider.dart';
import 'subtitle_memory_engine.dart';
import 'unified_playback_coordinator.dart';
import 'unified_playback_engine.dart';

/// 启动内置视频播放页面的强类型不可变请求键。
class VideoLaunchRequest {
  /// 创建视频播放请求。
  const VideoLaunchRequest({
    required this.work,
    required this.episode,
    required this.variant,
    required this.bundle,
    this.source,
    this.startSeconds = 0,
  });

  final Work work;
  final Episode episode;
  final MediaVariant variant;
  final WorkDetailBundle bundle;
  final MediaSource? source;
  final int startSeconds;

  @override
  bool operator ==(Object other) {
    return other is VideoLaunchRequest &&
        other.work.id == work.id &&
        other.episode.id == episode.id &&
        other.variant.id == variant.id &&
        other.startSeconds == startSeconds;
  }

  @override
  int get hashCode =>
      Object.hash(work.id, episode.id, variant.id, startSeconds);
}

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
    this.trackMemory = const CrossEpisodeTrackMemory(),
    this.activeSkipWindow,
    this.transientBanner,
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
  final CrossEpisodeTrackMemory trackMemory;
  final DetectedSkipWindow? activeSkipWindow;
  final String? transientBanner;
  final String? errorMessage;

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
    CrossEpisodeTrackMemory? trackMemory,
    DetectedSkipWindow? activeSkipWindow,
    bool clearSkipWindow = false,
    String? transientBanner,
    bool clearTransientBanner = false,
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
      trackMemory: trackMemory ?? this.trackMemory,
      activeSkipWindow: clearSkipWindow
          ? null
          : (activeSkipWindow ?? this.activeSkipWindow),
      transientBanner: clearTransientBanner
          ? null
          : (transientBanner ?? this.transientBanner),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

/// 内置 `libmpv` 视频播放控制器（串联互斥锁生命周期、`WatchedTracker` DB 持久化、
/// 跨集轨道记忆连播、OP/ED 4s 跳过胶囊、外部播放器热接力与 1Hz 探针采集中枢）。
class VideoPlaybackController extends StateNotifier<VideoPlaybackState> {
  /// 创建视频播放控制器。
  VideoPlaybackController(
    this._ref,
    this.request, {
    this.sessionFactory,
    this.deferBootstrap = false,
  }) : _sessionMutex = _ref.read(embeddedSessionMutexProvider),
       super(
         VideoPlaybackState(
           currentWork: request.work,
           currentBundle: request.bundle,
           currentEpisode: request.episode,
           currentVariant: request.variant,
           volume: _ref.read(playbackPreferencesProvider).defaultVolume,
           speed: _ref
               .read(playbackPreferencesProvider)
               .qualityConfig
               .defaultSpeed,
         ),
       ) {
    _bundleCacheByWorkId[request.work.id] = request.bundle;
    if (!deferBootstrap) {
      _bootstrap();
    }
  }

  final Ref _ref;
  final VideoLaunchRequest request;
  final EmbeddedMpvSession Function()? sessionFactory;
  final bool deferBootstrap;
  final EmbeddedSessionMutex _sessionMutex;

  final WatchedTracker _watchedTracker = WatchedTracker();
  final Completer<AndroidVideoSurfaceController>? _androidSurfaceCompleter =
      Platform.isAndroid ? Completer<AndroidVideoSurfaceController>() : null;

  final Map<String, WorkDetailBundle> _bundleCacheByWorkId = {};
  final Map<String, CrossEpisodeTrackMemory> _trackMemoryByWorkId = {};

  EmbeddedMpvSession? _session;
  SubtitleMemoryEngine? _subtitleMemoryEngine;
  MpvThumbnailService? _thumbnailService;
  final ValueNotifier<int> _thumbnailRevision = ValueNotifier<int>(0);
  Timer? _persistTimer;
  Timer? _probeTimer;
  Timer? _skipFadeTimer;
  Timer? _chapterSkipWakeTimer;
  Timer? _bannerTimer;
  Timer? _thumbnailWarmupTimer;

  ChapterSkipPlan _skipPlan = const ChapterSkipPlan();
  DetectedSkipWindow? _dismissedSkipWindow;
  bool _hudProgressActive = true;
  double _latestPositionSeconds = 0.0;
  bool _persistDirty = false;
  bool _closedCleanly = false;
  bool _alreadyPersistedCompleted = false;
  double? _speedBeforeBoost;
  double? _volumeBeforeDuck;
  int _thumbnailGeneration = 0;
  String? _activeExternalSubtitleSourcePath;
  int? _activeOriginalSubtitleTrackId;
  String? _activeExternalSubtitleTitle;

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

  /// 当前真实播放秒数（即使 OSD 隐藏静默期未刷新 `state.positionSeconds` 亦保持精确）。
  double get currentPositionSeconds =>
      _hudProgressActive ? state.positionSeconds : _latestPositionSeconds;

  /// 控制 OSD 隐藏稳态期是否挂起高频进度订阅与 Riverpod 状态派发。
  ///
  /// 当 `active == false` 时退订底层 `time-pos` 监听，改由单次章节唤醒定时器与低频持久化按需采样，
  /// 保障纯视频播放稳态期 Flutter UI / Raster 线程 0% 无谓唤醒。
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

  /// 通知后台 `thumbfast` 会话预取目标时间点缩略图（传 `null` 表示离开进度条）。
  void requestThumbnailPreview(double? seconds) {
    _thumbnailService?.requestPreview(seconds);
  }

  /// 读取或按需拉取并缓存同系列其他成员的完整详情包（供选集浏览与跨季连播复用）。
  Future<WorkDetailBundle?> loadSeriesWorkBundle(String workId) async {
    final cached = _bundleCacheByWorkId[workId];
    if (cached != null) return cached;
    try {
      final fetched = await _ref.read(workDetailBundleProvider(workId).future);
      if (fetched != null) {
        _bundleCacheByWorkId[workId] = fetched;
      }
      return fetched;
    } catch (_) {
      return null;
    }
  }

  Future<void> _preloadAdjacentSeriesBundles() async {
    final members = orderedSeriesMembers;
    if (members.length < 2) return;
    final idx = members.indexWhere((m) => m.id == activeWork.id);
    if (idx < 0) return;
    if (idx + 1 < members.length) {
      await loadSeriesWorkBundle(members[idx + 1].id);
    }
    if (idx - 1 >= 0) {
      await loadSeriesWorkBundle(members[idx - 1].id);
    }
  }

  List<Episode> _playableMainEpisodesFor(WorkDetailBundle bundle) {
    return Episode.sortMainFirst(
      bundle.episodes.where(
        (e) =>
            e.category == EpisodeCategory.main &&
            bundle.variantsForEpisode(e.id).isNotEmpty,
      ),
    );
  }

  List<Episode> _playableExtraEpisodesFor(WorkDetailBundle bundle) {
    return Episode.sortMainFirst(
      bundle.episodes.where(
        (e) =>
            e.category == EpisodeCategory.extra &&
            bundle.variantsForEpisode(e.id).isNotEmpty,
      ),
    );
  }

  /// 有序同作品正片剧集列表（严格正片集号升序，特典置于正片之后）。
  List<Episode> get orderedMainEpisodes => Episode.sortMainFirst(
    activeBundle.episodes.where((e) => e.category == EpisodeCategory.main),
  );

  /// 当前分集的展示标题。
  String get currentEpisodeTitle {
    return EpisodeTitleFormatter.formatCardTitle(
      episode: state.currentEpisode,
      workTitle: activeWork.title,
      workMediaType: activeWork.tmdbMediaType,
      mainEpisodeCount: orderedMainEpisodes.length,
    );
  }

  /// 查找当前作品内部的下一集（正片只找正片、特典只找特典）。
  Episode? findNextEpisode() {
    final ep = state.currentEpisode;
    final list = ep.category == EpisodeCategory.main
        ? _playableMainEpisodesFor(activeBundle)
        : _playableExtraEpisodesFor(activeBundle);
    final idx = list.indexWhere((e) => e.id == ep.id);
    if (idx < 0 || idx + 1 >= list.length) return null;
    return list[idx + 1];
  }

  /// 查找当前作品内部的上一集（正片只找正片、特典只找特典）。
  Episode? findPreviousEpisode() {
    final ep = state.currentEpisode;
    final list = ep.category == EpisodeCategory.main
        ? _playableMainEpisodesFor(activeBundle)
        : _playableExtraEpisodesFor(activeBundle);
    final idx = list.indexWhere((e) => e.id == ep.id);
    if (idx <= 0) return null;
    return list[idx - 1];
  }

  /// 是否存在可切换的下一集（含跨季正片连播越过本季特典）。
  bool get hasNextEpisodeAny {
    if (findNextEpisode() != null) return true;
    if (state.currentEpisode.category != EpisodeCategory.main) return false;
    final members = orderedSeriesMembers;
    final currentIdx = members.indexWhere((m) => m.id == activeWork.id);
    if (currentIdx < 0 || currentIdx + 1 >= members.length) return false;
    for (var i = currentIdx + 1; i < members.length; i++) {
      final cached = _bundleCacheByWorkId[members[i].id];
      if (cached == null || _playableMainEpisodesFor(cached).isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  /// 是否存在可切换的上一集（含跨季回退至上一季末集正片）。
  bool get hasPreviousEpisodeAny {
    if (findPreviousEpisode() != null) return true;
    if (state.currentEpisode.category != EpisodeCategory.main) return false;
    final members = orderedSeriesMembers;
    final currentIdx = members.indexWhere((m) => m.id == activeWork.id);
    if (currentIdx <= 0) return false;
    for (var i = currentIdx - 1; i >= 0; i--) {
      final cached = _bundleCacheByWorkId[members[i].id];
      if (cached == null || _playableMainEpisodesFor(cached).isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  /// 跨季越过特典状态机解析下一目标集：
  /// - 主动点播 `特典` 时仅在本季 `特典` 内部顺序连播；
  /// - 播放 `正片` 到达本季末集 `正片` 时，自动越过本季末尾 `NCOP/NCED/PV/MENU` 等特典，
  ///   若存在下一季则直连下一季第 01 集 `正片`，否则停在全系列片尾。
  Future<({WorkDetailBundle bundle, Episode episode, bool isCrossSeason})?>
  resolveNextEpisodeTarget() async {
    final intraNext = findNextEpisode();
    if (intraNext != null) {
      return (bundle: activeBundle, episode: intraNext, isCrossSeason: false);
    }
    if (state.currentEpisode.category != EpisodeCategory.main) {
      return null;
    }

    final members = orderedSeriesMembers;
    final currentIdx = members.indexWhere((m) => m.id == activeWork.id);
    if (currentIdx < 0 || currentIdx + 1 >= members.length) {
      return null;
    }

    for (var i = currentIdx + 1; i < members.length; i++) {
      final nextBundle = await loadSeriesWorkBundle(members[i].id);
      if (nextBundle == null) continue;
      final mains = _playableMainEpisodesFor(nextBundle);
      if (mains.isNotEmpty) {
        return (bundle: nextBundle, episode: mains.first, isCrossSeason: true);
      }
    }
    return null;
  }

  /// 对称跨季解析上一目标集（下一季第 01 集 `正片` 对称回退至上一季末集 `正片`）。
  Future<({WorkDetailBundle bundle, Episode episode, bool isCrossSeason})?>
  resolvePreviousEpisodeTarget() async {
    final intraPrev = findPreviousEpisode();
    if (intraPrev != null) {
      return (bundle: activeBundle, episode: intraPrev, isCrossSeason: false);
    }
    if (state.currentEpisode.category != EpisodeCategory.main) {
      return null;
    }

    final members = orderedSeriesMembers;
    final currentIdx = members.indexWhere((m) => m.id == activeWork.id);
    if (currentIdx <= 0) {
      return null;
    }

    for (var i = currentIdx - 1; i >= 0; i--) {
      final prevBundle = await loadSeriesWorkBundle(members[i].id);
      if (prevBundle == null) continue;
      final mains = _playableMainEpisodesFor(prevBundle);
      if (mains.isNotEmpty) {
        return (bundle: prevBundle, episode: mains.last, isCrossSeason: true);
      }
    }
    return null;
  }

  /// 跳转并原地播放下一集（支持跨季无缝切换并显示描边连播提示）。
  Future<bool> goToNextEpisode({bool isAutoAdvance = false}) async {
    final target = await resolveNextEpisodeTarget();
    if (target == null || !mounted || state.isClosing) return false;
    await switchToEpisode(
      target.episode,
      targetBundle: target.bundle,
      startSeconds: 0,
      isAutoAdvance: isAutoAdvance,
      isCrossSeason: target.isCrossSeason,
    );
    return true;
  }

  /// 跳转并原地回退上一集（支持上一季末集正片对称回退）。
  Future<bool> goToPreviousEpisode() async {
    final target = await resolvePreviousEpisodeTarget();
    if (target == null || !mounted || state.isClosing) return false;
    await switchToEpisode(
      target.episode,
      targetBundle: target.bundle,
      startSeconds: 0,
      isAutoAdvance: false,
      isCrossSeason: target.isCrossSeason,
    );
    return true;
  }

  /// Android `PlatformView` 创建后向控制器交付硬件表面通道（支持路由重建时动态热重绑）。
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
    await AndroidPlaybackWindowBridge.requestAudioFocus(
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

    final mutex = _ref.read(embeddedSessionMutexProvider);
    await mutex.runExclusive(() async {
      if (!mounted || state.isClosing || _closedCleanly) return;

      final saved = request.bundle.playbackByEpisodeId[state.currentEpisode.id];
      _alreadyPersistedCompleted = saved?.isCompleted ?? false;

      final storageRoot = _ref.read(storageRootProvider);
      final shadersDir = await storageRoot.ensureShadersDir();
      final shaders = await MpvQualityProfile.discoverShaderFiles(shadersDir);

      final engine = _ref.read(unifiedPlaybackEngineProvider);
      engine.attachNativeInstance();
      engine.beginPhysicalMedia();
      engine.recordManualSelection();
      final session = sessionFactory != null
          ? sessionFactory!()
          : EmbeddedMpvSession(
              storageRoot: storageRoot,
              streamBridge: _ref.read(localStreamBridgeProvider),
              d3d11Bridge: _ref.read(konataVideoBridgeFactoryProvider)(),
              gatewayFactory: _ref.read(mediaSourceGatewayFactoryProvider),
              logStore: _ref.read(diagnosticsLogStoreProvider),
              subtitleDirectoryIndex: _ref.read(subtitleDirectoryIndexProvider),
            );
      _session = session;
      unawaited(_preloadAdjacentSeriesBundles());

      session.textureIdListenable.addListener(() {
        if (mounted) {
          state = state.copyWith(textureId: session.textureIdListenable.value);
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
        if (mounted) state = state.copyWith(isBuffering: buf);
      };
      session.onSpeedChanged = (spd) {
        if (mounted) state = state.copyWith(speed: spd);
      };
      session.onFirstFrameRendered = () {
        _ref
            .read(unifiedPlaybackEngineProvider)
            .recordEffectiveProgress(firstFrameRendered: true);
        if (mounted) {
          final isInitialFrame = !state.hasFirstFrame;
          state = state.copyWith(
            hasFirstFrame: true,
            probeStats: session.collectProbeStats(),
          );
          if (isInitialFrame) {
            _scheduleThumbnailWarmup();
          }
        }
      };
      session.onHwdecChanged = (_) {
        if (mounted) {
          state = state.copyWith(probeStats: session.collectProbeStats());
        }
      };
      session.onMediaMetadataUpdated = _handleMetadataUpdated;
      session.onEndOfFile = _handleEndOfFile;
      session.onNotice = showTransientBanner;
      session.onFatalError = (msg) {
        if (mounted) {
          final bridgeDiag = _ref
              .read(localStreamBridgeProvider)
              .describeLastError(relativePath: request.variant.relativePath);
          var effectiveMsg = bridgeDiag ?? msg;
          if (bridgeDiag == null &&
              request.source != null &&
              request.source!.kind == MediaSourceKind.local) {
            final rootClean = request.source!.location.replaceAll(
              RegExp(r'[\\/]+$'),
              '',
            );
            final relClean = request.variant.relativePath
                .replaceAll('\\', '/')
                .replaceAll(RegExp(r'^/+'), '')
                .split('/')
                .join(Platform.pathSeparator);
            final localPath = relClean.isEmpty
                ? request.source!.location
                : '$rootClean${Platform.pathSeparator}$relClean';
            if (!File(localPath).existsSync()) {
              effectiveMsg =
                  '本地视频文件不存在或路径已变更（${request.variant.relativePath}），请检查磁盘挂载或重新扫描媒体源';
            }
          }
          state = state.copyWith(
            isInitializing: false,
            isBuffering: false,
            errorMessage: effectiveMsg,
          );
        }
      };

      if (mounted) {
        state = state.copyWith(availableShaders: shaders);
      }

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
        state = state.copyWith(
          isInitializing: false,
          textureId: session.textureIdListenable.value,
          renderBackend: session.renderBackendListenable.value,
          adapterName: session.adapterNameListenable.value,
          probeStats: session.collectProbeStats(),
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
      state = state.copyWith(positionSeconds: posSeconds);
    }
    _evaluateChapterSkipWindow(posSeconds);
  }

  void _handleDurationChanged(double durSeconds) {
    if (!mounted) return;
    state = state.copyWith(durationSeconds: durSeconds);
    _recomputeChapterSkipPlan();
    _thumbnailService?.updateChapters(
      state.chapters,
      durationSeconds: durSeconds > 0 ? durSeconds : null,
    );
  }

  void _handlePlayingChanged(bool playing) {
    if (!mounted) return;
    state = state.copyWith(isPlaying: playing);
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

  void _handleMetadataUpdated({
    required List<SubtitleChoice> subtitles,
    required List<AudioTrackChoice> audioTracks,
    required List<PlaybackChapter> chapters,
    required List<MpvAudioDevice> audioDevices,
  }) {
    if (!mounted) return;
    final stats = _session?.collectProbeStats() ?? state.probeStats;
    state = state.copyWith(
      subtitles: subtitles,
      audioTracks: audioTracks,
      chapters: chapters,
      availableAudioDevices: audioDevices,
      probeStats: stats,
    );
    if (KonataPlatform.isAndroid &&
        !state.audioOnlyMode &&
        (stats.videoWidth ?? 0) > 0 &&
        _ref.read(activeVideoSessionProvider).isExpanded) {
      unawaited(
        AndroidPlaybackWindowBridge.applyVideoOrientationAndWindow(
          landscape: true,
          hideSystemBars: true,
        ),
      );
    }
    _recomputeChapterSkipPlan();
    _thumbnailService?.updateChapters(
      chapters,
      durationSeconds: state.durationSeconds > 0 ? state.durationSeconds : null,
    );
  }

  void _scheduleThumbnailWarmup() {
    _thumbnailWarmupTimer?.cancel();
    final gen = ++_thumbnailGeneration;
    _thumbnailWarmupTimer = Timer(MpvThumbnailService.defaultWarmupDelay, () {
      if (!mounted ||
          state.isClosing ||
          _closedCleanly ||
          gen != _thumbnailGeneration) {
        return;
      }
      final variant = state.currentVariant;
      final source =
          activeBundle.sourcesById[variant.sourceId] ?? request.source;
      var svc = _thumbnailService;
      if (svc == null) {
        svc = MpvThumbnailService(
          streamBridge: _ref.read(localStreamBridgeProvider),
          gatewayFactory: _ref.read(mediaSourceGatewayFactoryProvider),
          logStore: _ref.read(diagnosticsLogStoreProvider),
        );
        svc.addListener(_onThumbnailUpdated);
        _thumbnailService = svc;
      }
      unawaited(
        svc.warmUp(
          variant: variant,
          source: source,
          chapters: state.chapters,
          durationSeconds: state.durationSeconds > 0
              ? state.durationSeconds
              : null,
        ),
      );
    });
  }

  void _onThumbnailUpdated() {
    if (mounted) {
      _thumbnailRevision.value += 1;
    }
  }

  Future<void> _releaseThumbnailService({required bool disposeNotifier}) async {
    ++_thumbnailGeneration;
    _thumbnailWarmupTimer?.cancel();
    _thumbnailWarmupTimer = null;
    final svc = _thumbnailService;
    if (svc != null) {
      svc.removeListener(_onThumbnailUpdated);
      if (disposeNotifier) {
        _thumbnailService = null;
        await svc.release();
        svc.dispose();
      } else {
        await svc.release();
        _thumbnailService = null;
      }
    }
  }

  void _recomputeChapterSkipPlan() {
    if (state.durationSeconds <= 0 || state.chapters.isEmpty) {
      _skipPlan = const ChapterSkipPlan();
      _chapterSkipWakeTimer?.cancel();
      _chapterSkipWakeTimer = null;
      if (state.activeSkipWindow != null) {
        _skipFadeTimer?.cancel();
        state = state.copyWith(clearSkipWindow: true);
      }
      return;
    }
    _skipPlan = ChapterSkipAnalyzer.analyze(
      rawChapters: state.chapters,
      totalDurationSeconds: state.durationSeconds,
      hasNextEpisode: hasNextEpisodeAny,
    );
    final active = _skipPlan.activeWindowAt(currentPositionSeconds);
    if (active == null && state.activeSkipWindow != null) {
      _skipFadeTimer?.cancel();
      state = state.copyWith(clearSkipWindow: true);
    }
    if (!_hudProgressActive) {
      _scheduleNextChapterSkipWake();
    }
  }

  /// OSD 静默期使用单次精确计时器按需唤醒 OP/ED 跳过判定，彻底避免高频轮询。
  void _scheduleNextChapterSkipWake() {
    _chapterSkipWakeTimer?.cancel();
    _chapterSkipWakeTimer = null;
    if (!mounted || _hudProgressActive || !state.isPlaying) return;
    final pos = _latestPositionSeconds;
    final candidates = <DetectedSkipWindow>[
      if (_skipPlan.opening != null) _skipPlan.opening!,
      if (_skipPlan.ending != null) _skipPlan.ending!,
    ];
    if (candidates.isEmpty) return;

    double? nextDeltaSeconds;
    for (final w in candidates) {
      if (w.containsPosition(pos)) {
        nextDeltaSeconds = 0.0;
        break;
      }
      if (w.startSeconds > pos) {
        final delta = w.startSeconds - pos;
        if (nextDeltaSeconds == null || delta < nextDeltaSeconds) {
          nextDeltaSeconds = delta;
        }
      }
    }
    if (nextDeltaSeconds == null) return;
    final effectiveSpeed = state.speed > 0.1 ? state.speed : 1.0;
    final waitMs = ((nextDeltaSeconds / effectiveSpeed) * 1000).ceil().clamp(
      50,
      3600 * 1000,
    );
    _chapterSkipWakeTimer = Timer(Duration(milliseconds: waitMs), () {
      if (!mounted || _hudProgressActive) return;
      final sampled = _session?.readCurrentPositionSeconds();
      if (sampled != null && sampled.isFinite) {
        _latestPositionSeconds = sampled;
        _evaluateChapterSkipWindow(sampled);
      }
      _scheduleNextChapterSkipWake();
    });
  }

  void _evaluateChapterSkipWindow(double posSeconds) {
    final prefs = _ref.read(playbackPreferencesProvider);
    final active = _skipPlan.activeWindowAt(posSeconds);
    if (active == null) {
      _dismissedSkipWindow = null;
      if (state.activeSkipWindow != null) {
        _skipFadeTimer?.cancel();
        state = state.copyWith(clearSkipWindow: true);
      }
      return;
    }

    if (_dismissedSkipWindow == active) return;

    // 严格遵守防误判红线：无名 ~90s 层级二启发式候选（allowsAutoSkip == false）绝不自动跳过，仅展示手动胶囊。
    if (prefs.autoSkipChapter && active.allowsAutoSkip) {
      _dismissedSkipWindow = active;
      unawaited(executeSkipWindow(active));
      showTransientBanner('已自动${active.label}');
      return;
    }

    if ((prefs.promptChapterSkip ||
            (prefs.autoSkipChapter && !active.allowsAutoSkip)) &&
        state.activeSkipWindow != active) {
      state = state.copyWith(activeSkipWindow: active);
      _skipFadeTimer?.cancel();
      _skipFadeTimer = Timer(
        PlaybackQualityConfig.skipPillAutoFadeDuration,
        () {
          if (!mounted) return;
          _dismissedSkipWindow = active;
          state = state.copyWith(clearSkipWindow: true);
        },
      );
    }
  }

  /// 执行智能跳过动作（OP / ED 跳 C-Part / ED 直接跳下一话或下一季第 01 话正片）。
  Future<void> executeSkipWindow(DetectedSkipWindow window) async {
    _dismissedSkipWindow = window;
    _skipFadeTimer?.cancel();
    state = state.copyWith(clearSkipWindow: true);
    if (window.kind == SkipActionKind.skipEdToNextEpisode) {
      final advanced = await goToNextEpisode();
      if (advanced) return;
    }
    seekAbsolute(window.endSeconds);
  }

  void _handleEndOfFile(int reason, int errorCode) {
    if (!mounted || state.isClosing) return;
    if (reason == MpvEndFileReason.eof) {
      final prefs = _ref.read(playbackPreferencesProvider);
      if (prefs.autoNextEpisode) {
        unawaited(goToNextEpisode(isAutoAdvance: true));
      } else {
        unawaited(_persistProgress(isFinal: true));
      }
    } else if (reason == MpvEndFileReason.error) {
      state = state.copyWith(
        isBuffering: false,
        isPlaying: false,
        errorMessage: '播放意外中断 (code: $errorCode)',
      );
    }
  }

  /// 无缝切换同作品或同系列下一季剧集/变体（先保存旧作品/分集进度，再原子热替换流与上下文）。
  Future<void> switchToEpisode(
    Episode episode, {
    WorkDetailBundle? targetBundle,
    MediaVariant? specificVariant,
    int? startSeconds,
    bool isAutoAdvance = false,
    bool isCrossSeason = false,
  }) async {
    final session = _session;
    if (session == null || !mounted || state.isClosing) return;

    await _releaseThumbnailService(disposeNotifier: true);
    if (mounted) {
      _thumbnailRevision.value += 1;
    }

    // 关键交接顺序：切换上下文前先以旧 workId / episodeId 完成进度与完播态持久化。
    await _persistProgress(isFinal: true);
    if (!mounted || state.isClosing) return;

    final resolvedBundle =
        targetBundle ??
        (episode.workId == activeWork.id
            ? activeBundle
            : await loadSeriesWorkBundle(episode.workId)) ??
        activeBundle;
    if (!mounted || state.isClosing) return;

    final variants = resolvedBundle.variantsForEpisode(episode.id);
    if (variants.isEmpty) return;

    final oldWorkId = activeWork.id;
    final switchingWork = resolvedBundle.work.id != oldWorkId;
    _trackMemoryByWorkId[oldWorkId] = state.trackMemory;
    final nextTrackMemory = switchingWork
        ? (_trackMemoryByWorkId[resolvedBundle.work.id] ??
              const CrossEpisodeTrackMemory())
        : state.trackMemory;

    final nextVariant = specificVariant ?? variants.first;
    final nextSource = resolvedBundle.sourcesById[nextVariant.sourceId];

    final saved = resolvedBundle.playbackByEpisodeId[episode.id];
    _alreadyPersistedCompleted = saved?.isCompleted ?? false;
    _watchedTracker.reset();
    _skipPlan = const ChapterSkipPlan();
    _dismissedSkipWindow = null;

    final resumePos =
        startSeconds ??
        ((saved != null && !saved.isCompleted && saved.positionSeconds > 5)
            ? saved.positionSeconds
            : 0);

    _latestPositionSeconds = resumePos.toDouble();
    _activeExternalSubtitleSourcePath = null;
    _activeOriginalSubtitleTrackId = null;
    _activeExternalSubtitleTitle = null;
    state = state.copyWith(
      currentWork: resolvedBundle.work,
      currentBundle: resolvedBundle,
      currentEpisode: episode,
      currentVariant: nextVariant,
      trackMemory: nextTrackMemory,
      isBuffering: true,
      hasFirstFrame: false,
      positionSeconds: resumePos.toDouble(),
      durationSeconds: 0.0,
      subtitleDelaySeconds: 0.0,
      audioDelaySeconds: 0.0,
      subtitleOpenCcMode: SubtitleOpenCcMode.none,
      clearSecondarySubtitleTrackId: true,
      clearActiveSubtitleSubsetState: true,
      chapters: const [],
      clearSkipWindow: true,
      clearError: true,
    );

    if (switchingWork) {
      unawaited(_preloadAdjacentSeriesBundles());
    }

    unawaited(ensureAudioFocus());
    _subtitleMemoryEngine?.resetForPhysicalMediaEpoch();
    await session.loadMediaVariant(
      EmbeddedVideoLoadRequest(
        workId: resolvedBundle.work.id,
        variant: nextVariant,
        source: nextSource,
        startSeconds: resumePos,
      ),
      trackMemory: nextTrackMemory,
      trackPreferences: const TrackPreferences(),
    );

    if ((isAutoAdvance || isCrossSeason) && mounted) {
      final epLabel = EpisodeTitleFormatter.formatCardTitle(
        episode: episode,
        workTitle: resolvedBundle.work.title,
        workMediaType: resolvedBundle.work.tmdbMediaType,
        mainEpisodeCount: orderedMainEpisodes.length,
      );
      final notice = isCrossSeason
          ? '已跨季连播：${SeriesSeasonFormatter.formatMemberLabel(resolvedBundle.work, orderedSeriesMembers, seriesGroup: resolvedBundle.seriesGroup)} · $epLabel'
          : '已自动连播：$epLabel';
      showTransientBanner(
        notice,
        duration: PlaybackQualityConfig.autoNextEpisodeToastDuration,
      );
    }
  }

  /// 显示顶部轻提示并在指定时长后自动消退。
  void showTransientBanner(
    String message, {
    Duration duration = const Duration(milliseconds: 2400),
  }) {
    if (!mounted) return;
    _bannerTimer?.cancel();
    state = state.copyWith(transientBanner: message);
    _bannerTimer = Timer(duration, () {
      if (mounted) state = state.copyWith(clearTransientBanner: true);
    });
  }

  /// 通知 D3D11 桥接同步视频目标渲染分辨率（Windows）。
  void notifySurfaceViewportSize(
    double logicalWidth,
    double logicalHeight,
    double devicePixelRatio,
  ) {
    final session = _session;
    if (session == null || !Platform.isWindows) return;
    final pw = (logicalWidth * devicePixelRatio).round().clamp(64, 7680);
    final ph = (logicalHeight * devicePixelRatio).round().clamp(64, 4320);
    unawaited(session.resizeD3D11Target(pw, ph));
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

  void previousChapterOrEpisode() {
    final chapters = state.chapters;
    final pos =
        _session?.readCurrentPositionSeconds() ?? currentPositionSeconds;
    if (chapters.isNotEmpty) {
      PlaybackChapter? prev;
      for (final ch in chapters) {
        if (ch.startSeconds < pos - 2.0) {
          prev = ch;
        }
      }
      if (prev != null) {
        seekAbsolute(prev.startSeconds);
        showTransientBanner(
          prev.title.isNotEmpty ? '章节：${prev.title}' : '上一章节',
        );
        return;
      }
    }
    unawaited(() async {
      final moved = await goToPreviousEpisode();
      if (!moved) {
        seekAbsolute(0);
      }
    }());
  }

  void nextChapterOrEpisode() {
    final chapters = state.chapters;
    final pos =
        _session?.readCurrentPositionSeconds() ?? currentPositionSeconds;
    if (chapters.isNotEmpty) {
      for (final ch in chapters) {
        if (ch.startSeconds > pos + 1.0) {
          seekAbsolute(ch.startSeconds);
          showTransientBanner(ch.title.isNotEmpty ? '章节：${ch.title}' : '下一章节');
          return;
        }
      }
    }
    unawaited(goToNextEpisode());
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

  SubtitleMemoryEngine _ensureSubtitleMemoryEngine() {
    return _subtitleMemoryEngine ??= SubtitleMemoryEngine(
      clientSupplier: () => _session?.activeClient,
      playbackEngine: _ref.read(unifiedPlaybackEngineProvider),
      legacyCodePageDecoder: _ref.read(legacyCodePageDecoderProvider),
      onTrackStateChanged: () => _session?.refreshMetadata(),
    );
  }

  /// 经单一串行权威通道执行内存级无副作用字幕挂载（多编码归一 / OpenCC / 离线调轴）。
  Future<SubtitleMemoryApplyResult> applyMemorySubtitleIntent(
    AuthoritativeSubtitleIntent intent,
  ) async {
    final result = await _ensureSubtitleMemoryEngine().applyIntent(intent);
    if (mounted && result.applied && result.zeroedInstantSubDelay) {
      state = state.copyWith(subtitleDelaySeconds: 0.0);
    }
    return result;
  }

  static bool _isTextSubtitlePath(String? rawPath) {
    if (rawPath == null) return false;
    final trimmed = rawPath.trim();
    if (trimmed.isEmpty || trimmed.startsWith('memory://')) return false;
    final ext = p.extension(trimmed.split('?').first).toLowerCase();
    return ext == '.ass' || ext == '.ssa' || ext == '.srt' || ext == '.vtt';
  }

  SubtitleChoice? get _selectedSubtitleChoice {
    for (final s in state.subtitles) {
      if (s.selected) return s;
    }
    return null;
  }

  String? _resolveActiveExternalTextSubtitlePath() {
    final cached = _activeExternalSubtitleSourcePath;
    if (_isTextSubtitlePath(cached)) {
      return cached!.trim();
    }
    final active = _selectedSubtitleChoice;
    if (active != null && _isTextSubtitlePath(active.externalPath)) {
      return active.externalPath!.trim();
    }
    return null;
  }

  /// 当前激活主字幕是否具备可进行内存直注繁简转换或离线时间轴固化的外挂文本源。
  bool get hasExternalTextSubtitleSource =>
      _resolveActiveExternalTextSubtitlePath() != null;

  String _buildMemoryTrackTitle(
    String sourcePath, {
    required SubtitleOpenCcMode mode,
    bool remapped = false,
  }) {
    final base = (_activeExternalSubtitleTitle ?? p.basename(sourcePath)).trim();
    final suffix = <String>[
      if (mode == SubtitleOpenCcMode.toSimplified) '简',
      if (mode == SubtitleOpenCcMode.toTraditional) '繁',
      if (remapped) '调轴',
    ];
    return suffix.isEmpty ? base : '$base [${suffix.join('·')}]';
  }

  /// 通过内存直注无副作用字幕引擎切换主字幕 OpenCC 繁简模式（受三态子集保护门禁约束）。
  Future<SubtitleMemoryApplyResult?> setSubtitleOpenCcMode(
    SubtitleOpenCcMode mode,
  ) async {
    final sourcePath = _resolveActiveExternalTextSubtitlePath();
    if (sourcePath == null || !File(sourcePath).existsSync()) {
      if (mode == SubtitleOpenCcMode.none &&
          _activeOriginalSubtitleTrackId != null) {
        final restored = await applyMemorySubtitleIntent(
          AuthoritativeSubtitleIntent(
            primary: SubtitleSlotRequest.existingTrack(
              _activeOriginalSubtitleTrackId!,
            ),
            instantSubDelaySeconds: state.subtitleDelaySeconds,
          ),
        );
        if (mounted && restored.applied) {
          state = state.copyWith(
            subtitleOpenCcMode: SubtitleOpenCcMode.none,
            clearActiveSubtitleSubsetState: true,
          );
        }
        return restored;
      }
      showTransientBanner('当前内封或图形字幕暂不支持内存繁简转换，请选择外挂文本字幕');
      return null;
    }

    _activeExternalSubtitleSourcePath = sourcePath;
    final result = await applyMemorySubtitleIntent(
      AuthoritativeSubtitleIntent(
        primary: SubtitleSlotRequest.memory(
          localFilePath: sourcePath,
          fileName: p.basename(sourcePath),
          displayTitle: _buildMemoryTrackTitle(sourcePath, mode: mode),
          openCcMode: mode,
        ),
        instantSubDelaySeconds: state.subtitleDelaySeconds,
      ),
    );
    if (!mounted || !result.applied) return result;

    state = state.copyWith(
      subtitleOpenCcMode: mode,
      activeSubtitleSubsetState: result.primarySubsetState,
      clearActiveSubtitleSubsetState: result.primarySubsetState == null,
    );
    if (result.primaryOpenCcSkipReason == 'opaque_obfuscated_subset_protected') {
      showTransientBanner('检测到混淆子集字体，已自动保护原文防乱码');
    } else if (mode == SubtitleOpenCcMode.toSimplified) {
      showTransientBanner('已通过内存直注切换为简体字幕');
    } else if (mode == SubtitleOpenCcMode.toTraditional) {
      showTransientBanner('已通过内存直注切换为繁体字幕');
    } else {
      showTransientBanner('已恢复字幕原文');
    }
    return result;
  }

  /// 将当前字幕延迟或倍率偏移离线重映射至内存直注轨道，并原子归零瞬时 `sub-delay`。
  Future<SubtitleMemoryApplyResult?> bakeSubtitleTimelineOffset({
    double rateScale = 1.0,
  }) async {
    final transform = SubtitleTimelineTransform(
      rateScale: rateScale,
      offsetSeconds: state.subtitleDelaySeconds,
      isPausedAlignment: !state.isPlaying,
    );
    if (transform.isIdentity) {
      showTransientBanner('当前字幕延迟为 0，无需固化时间轴');
      return null;
    }
    final sourcePath = _resolveActiveExternalTextSubtitlePath();
    if (sourcePath == null || !File(sourcePath).existsSync()) {
      showTransientBanner('仅外挂文本字幕支持离线时间轴固化');
      return null;
    }

    _activeExternalSubtitleSourcePath = sourcePath;
    final result = await applyMemorySubtitleIntent(
      AuthoritativeSubtitleIntent(
        primary: SubtitleSlotRequest.memory(
          localFilePath: sourcePath,
          fileName: p.basename(sourcePath),
          displayTitle: _buildMemoryTrackTitle(
            sourcePath,
            mode: state.subtitleOpenCcMode,
            remapped: true,
          ),
          openCcMode: state.subtitleOpenCcMode,
          timelineTransform: transform,
        ),
      ),
    );
    if (mounted && result.applied) {
      state = state.copyWith(
        activeSubtitleSubsetState: result.primarySubsetState,
        clearActiveSubtitleSubsetState: result.primarySubsetState == null,
      );
      showTransientBanner('已通过内存直注固化字幕时间轴并归零延迟');
    }
    return result;
  }

  /// 经单一串行权威通道独立挂载或关闭双语副字幕（`secondary-sid`），绝不干扰当前主字幕槽位。
  Future<SubtitleMemoryApplyResult> selectSecondarySubtitle(
    SubtitleChoice? choice,
  ) async {
    final currentPrimary = _selectedSubtitleChoice;
    final primarySlot = currentPrimary?.mpvTrackId != null
        ? SubtitleSlotRequest.existingTrack(currentPrimary!.mpvTrackId!)
        : null;

    SubtitleSlotRequest? secondarySlot;
    if (choice != null) {
      if (choice.mpvTrackId != null) {
        secondarySlot = SubtitleSlotRequest.existingTrack(
          choice.mpvTrackId!,
          displayTitle: choice.primaryTitle,
        );
      } else if (_isTextSubtitlePath(choice.externalPath) &&
          File(choice.externalPath!.trim()).existsSync()) {
        final filePath = choice.externalPath!.trim();
        secondarySlot = SubtitleSlotRequest.memory(
          localFilePath: filePath,
          fileName: p.basename(filePath),
          displayTitle: choice.primaryTitle,
        );
      }
    }

    final result = await applyMemorySubtitleIntent(
      AuthoritativeSubtitleIntent(
        primary: primarySlot,
        secondary: secondarySlot,
        updateSecondary: true,
      ),
    );
    if (mounted && result.applied) {
      state = state.copyWith(
        secondarySubtitleTrackId: result.secondaryTrackId,
        clearSecondarySubtitleTrackId: result.secondaryTrackId == null,
      );
      showTransientBanner(
        result.secondaryTrackId == null
            ? '已关闭双语副字幕'
            : '已启用双语副字幕：${choice?.primaryTitle ?? ''}',
      );
    }
    return result;
  }

  void selectSubtitle(SubtitleChoice? choice) {
    _subtitleMemoryEngine?.invalidatePendingIntents();
    _session?.selectSubtitle(choice);
    if (choice == null) {
      _activeExternalSubtitleSourcePath = null;
      _activeOriginalSubtitleTrackId = null;
      _activeExternalSubtitleTitle = null;
    } else if (_isTextSubtitlePath(choice.externalPath)) {
      _activeExternalSubtitleSourcePath = choice.externalPath!.trim();
      _activeOriginalSubtitleTrackId = choice.mpvTrackId;
      _activeExternalSubtitleTitle = choice.primaryTitle;
    } else {
      _activeExternalSubtitleSourcePath = null;
      _activeOriginalSubtitleTrackId = choice.mpvTrackId;
      _activeExternalSubtitleTitle = null;
    }
    final nextMemory = state.trackMemory.rememberSubtitle(
      choice == null || choice.mpvTrackId == null
          ? (choice == null
                ? null
                : MpvTrackInfo(
                    id: -1,
                    type: MpvTrackType.subtitle,
                    title: choice.title,
                    lang: choice.language,
                    codec: choice.codec,
                    isExternal: true,
                    externalFilename: choice.externalPath,
                  ))
          : MpvTrackInfo(
              id: choice.mpvTrackId!,
              type: MpvTrackType.subtitle,
              title: choice.title,
              lang: choice.language,
              codec: choice.codec,
              isExternal: choice.isExternal,
              externalFilename: choice.externalPath,
            ),
    );
    state = state.copyWith(
      trackMemory: nextMemory,
      subtitleOpenCcMode: SubtitleOpenCcMode.none,
      clearActiveSubtitleSubsetState: true,
    );
  }

  void addExternalSubtitleFile(String path) {
    _subtitleMemoryEngine?.invalidatePendingIntents();
    _session?.addExternalSubtitleFile(path);
    showTransientBanner('已加载外挂字幕');
  }

  void selectAudioTrack(AudioTrackChoice choice) {
    _session?.selectAudioTrack(choice);
    final nextMemory = state.trackMemory.rememberAudio(
      MpvTrackInfo(
        id: choice.mpvTrackId ?? -1,
        type: MpvTrackType.audio,
        title: choice.title,
        lang: choice.language,
        codec: choice.codec,
        isExternal: choice.isExternal,
        externalFilename: choice.externalPath,
      ),
    );
    state = state.copyWith(trackMemory: nextMemory);
  }

  void setSubtitleDelay(double delaySeconds) {
    _subtitleMemoryEngine?.invalidatePendingIntents();
    final clamped = double.parse(
      delaySeconds.clamp(-60.0, 60.0).toStringAsFixed(2),
    );
    _session?.setSubtitleDelay(clamped);
    state = state.copyWith(subtitleDelaySeconds: clamped);
  }

  void setAudioDelay(double delaySeconds) {
    final clamped = double.parse(
      delaySeconds.clamp(-60.0, 60.0).toStringAsFixed(2),
    );
    _session?.setAudioDelay(clamped);
    state = state.copyWith(audioDelaySeconds: clamped);
  }

  Future<void> updateLiveQuality(
    PlaybackQualityConfig Function(PlaybackQualityConfig) updater,
  ) async {
    await _ref
        .read(playbackPreferencesProvider.notifier)
        .updateQualityConfig(updater);
    final nextConfig = _ref.read(playbackPreferencesProvider).qualityConfig;
    _session?.applyLiveQualityConfig(nextConfig);
  }

  /// 一键重置字幕延迟、OpenCC 繁简模式、字号、底部边距与 ASS 样式覆写模式为标准默认值。
  Future<void> resetSubtitleAdjustments() async {
    setSubtitleDelay(0);
    if (state.subtitleOpenCcMode != SubtitleOpenCcMode.none) {
      await setSubtitleOpenCcMode(SubtitleOpenCcMode.none);
    }
    await updateLiveQuality(
      (c) => c.copyWith(
        subFontSize: PlaybackQualityConfig.defaultSubFontSize,
        subBottomMargin: PlaybackQualityConfig.defaultSubBottomMargin,
        subOverrideMode: SubtitleAssOverrideMode.preserveAss,
      ),
    );
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

  void setSideSheetOpen(bool open) {
    if (state.sideSheetOpen == open) return;
    if (open) {
      _session?.refreshMetadata();
    }
    state = state.copyWith(sideSheetOpen: open);
  }

  /// 切换全屏或 Android 横屏全屏模式（Windows 绝不触碰 `flutter_acrylic` 窗体材质防 DWM 黑闪）。
  Future<void> toggleFullscreen() async {
    final next = !state.isFullscreen;
    if (KonataPlatform.isWindows) {
      await _ref.read(konataWindowHostProvider).setFullScreen(next);
      if (mounted) {
        state = state.copyWith(isFullscreen: next);
      }
      return;
    }
    if (KonataPlatform.isAndroid) {
      await AndroidPlaybackWindowBridge.setLandscapePreferred(next);
      await AndroidPlaybackWindowBridge.setSystemBarsHidden(next);
      if (mounted) {
        state = state.copyWith(isFullscreen: next);
      }
    }
  }

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
  }) async {
    final session = _session;
    if (session == null) return null;
    final work = activeWork;
    final photos = _ref.read(photosStorageProvider);
    final workDir = await photos.resolveWorkDirectory(
      work.id,
      title: work.title,
    );
    final epTag = state.currentEpisode.episodeNumber != null
        ? 'EP${state.currentEpisode.episodeNumber.toString().padLeft(2, '0')}'
        : null;
    final res = await session.captureScreenshot(
      workPhotoDir: workDir,
      episodeTag: epTag,
      mode: mode,
      albumName: 'Konata',
    );
    if (res != null) {
      showTransientBanner('已保存${res.mode.label}截图：${res.displayLabel}');
    }
    return res;
  }

  /// 一键热接力至外部播放器：携带精确当前秒数退出内置播放页并在外部播放器续播回写。
  Future<LaunchPlaybackResult> relayToExternalPlayer([
    ExternalPlayerConfig? targetPlayer,
  ]) async {
    final relayPos =
        (_session?.readCurrentPositionSeconds() ?? currentPositionSeconds)
            .round();
    final work = activeWork;
    final bundle = activeBundle;
    final ep = state.currentEpisode;
    final variant = state.currentVariant;
    final src = bundle.sourcesById[variant.sourceId];

    await closeAndRelease();

    return _ref
        .read(playbackCoordinatorProvider)
        .playVariant(
          work: work,
          episode: ep,
          variant: variant,
          sourceType: src?.kind ?? MediaSourceKind.local,
          source: src,
          player: targetPlayer,
          startSeconds: relayPos,
          mainEpisodeCount: orderedMainEpisodes.length,
        );
  }

  Future<void> _persistProgress({required bool isFinal}) async {
    final work = activeWork;
    final bundle = activeBundle;
    final ep = state.currentEpisode;
    final variant = state.currentVariant;
    final durDouble = state.durationSeconds;
    final posDouble = _hudProgressActive
        ? currentPositionSeconds
        : (_session?.readCurrentPositionSeconds() ?? currentPositionSeconds);
    _latestPositionSeconds = posDouble;
    final durSeconds = durDouble > 0 ? durDouble.round() : 0;
    final persistedPos = _watchedTracker.resolvePersistedPositionSeconds(
      positionSeconds: posDouble,
      durationSeconds: durDouble,
    );
    final completed =
        _alreadyPersistedCompleted ||
        (durDouble > 0 && _watchedTracker.isCompleted(durDouble)) ||
        PlaybackRecord.computeCompleted(
          positionSeconds: persistedPos,
          durationSeconds: durSeconds,
        );

    if (posDouble < 1.0 && !completed && !isFinal) return;

    final repo = _ref.read(libraryRepositoryProvider);
    final src = bundle.sourcesById[variant.sourceId];
    final recordId = '${work.id}::${ep.id}';
    final record = PlaybackRecord(
      id: recordId,
      workId: work.id,
      episodeId: ep.id,
      variantId: variant.id,
      seasonNumber: ep.seasonNumber,
      episodeNumber: ep.episodeNumber,
      episodeTitle:
          ep.title ??
          (ep.episodeNumber != null
              ? '第 ${ep.episodeNumber} 话'
              : (ep.category == EpisodeCategory.extra
                    ? (ep.extraType?.name.toUpperCase() ?? '特典')
                    : work.title)),
      sourceType: src?.kind ?? MediaSourceKind.local,
      playedAt: DateTime.now(),
      positionSeconds: persistedPos,
      durationSeconds: durSeconds,
      isCompleted: completed,
    );

    await repo.recordPlayback(record);
    _alreadyPersistedCompleted = completed;

    final cachedBundle = _bundleCacheByWorkId[work.id] ?? bundle;
    final updatedPlaybackMap = Map<String, PlaybackRecord>.of(
      cachedBundle.playbackByEpisodeId,
    )..[ep.id] = record;
    final updatedBundle = WorkDetailBundle(
      work: cachedBundle.work,
      episodes: cachedBundle.episodes,
      variants: cachedBundle.variants,
      sourcesById: cachedBundle.sourcesById,
      latestPlayback: record,
      playbackByEpisodeId: updatedPlaybackMap,
      seriesGroup: cachedBundle.seriesGroup,
      seriesMembers: cachedBundle.seriesMembers,
      cdVariants: cachedBundle.cdVariants,
      scanVariants: cachedBundle.scanVariants,
      editableSupplementaryItems: cachedBundle.editableSupplementaryItems,
    );
    _bundleCacheByWorkId[work.id] = updatedBundle;
    if (mounted && activeWork.id == work.id) {
      state = state.copyWith(currentBundle: updatedBundle);
    }

    try {
      _ref.invalidate(playbackHistoryProvider);
      _ref.invalidate(workDetailBundleProvider(work.id));
    } catch (_) {}
  }

  /// 安全保存进度、退出全屏并在串行互斥锁内彻底释放底层硬件资源（允许多次幂等调用）。
  Future<void> closeAndRelease() async {
    if (_closedCleanly) return;
    _closedCleanly = true;

    _persistTimer?.cancel();
    _probeTimer?.cancel();
    _skipFadeTimer?.cancel();
    _chapterSkipWakeTimer?.cancel();
    _bannerTimer?.cancel();
    _subtitleMemoryEngine?.dispose();
    _subtitleMemoryEngine = null;
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
      await AndroidPlaybackWindowBridge.abandonAudioFocus();
    }

    await _persistProgress(isFinal: true);

    final sessionToDispose = _session;
    _session = null;
    if (sessionToDispose != null) {
      final mutex = _ref.read(embeddedSessionMutexProvider);
      await mutex.runExclusive(() => sessionToDispose.dispose());
    }

    try {
      _ref.read(videoPlaybackActiveProvider.notifier).state = false;
    } catch (_) {}
  }

  @override
  void dispose() {
    _persistTimer?.cancel();
    _probeTimer?.cancel();
    _skipFadeTimer?.cancel();
    _chapterSkipWakeTimer?.cancel();
    _bannerTimer?.cancel();
    _thumbnailWarmupTimer?.cancel();
    _subtitleMemoryEngine?.dispose();
    _subtitleMemoryEngine = null;

    if (!_closedCleanly) {
      _closedCleanly = true;
      unawaited(_releaseThumbnailService(disposeNotifier: true));
      final sessionToDispose = _session;
      _session = null;
      if (sessionToDispose != null) {
        unawaited(_sessionMutex.runExclusive(() => sessionToDispose.dispose()));
      }
      Future.microtask(() {
        try {
          _ref.read(videoPlaybackActiveProvider.notifier).state = false;
        } catch (_) {}
      });
    }
    _thumbnailRevision.dispose();
    super.dispose();
  }
}

/// 内置视频播放控制器 Family Provider（按单次播放请求自动挂载与释放）。
final videoPlaybackProvider = StateNotifierProvider.autoDispose
    .family<VideoPlaybackController, VideoPlaybackState, VideoLaunchRequest>(
      (ref, req) => VideoPlaybackController(ref, req),
    );
