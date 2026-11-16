import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../domain/matching/episode_title_formatter.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/external_player_config.dart';
import '../../domain/models/media_source.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/models/playback_record.dart';
import '../../domain/models/work.dart';
import '../../domain/playback/chapter_skip_analyzer.dart';
import '../../domain/playback/playback_probe_stats.dart';
import '../../domain/playback/subtitle_and_audio_choices.dart';
import '../../domain/playback/track_preferences.dart';
import '../../domain/playback/watched_tracker.dart';
import '../../domain/repositories/external_player_launcher.dart';
import '../../infrastructure/players/android/android_video_surface_controller.dart';
import '../../infrastructure/players/embedded_mpv_session.dart';
import '../../infrastructure/players/libmpv_ffi.dart';
import '../../infrastructure/players/mpv_quality_profile.dart';
import '../../infrastructure/storage/storage_root_provider.dart';
import '../providers/diagnostics_providers.dart';
import '../providers/library_providers.dart';
import '../providers/playback_providers.dart';
import 'audio_playback_notifier.dart';
import 'playback_preferences_provider.dart';

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
      trackMemory: trackMemory ?? this.trackMemory,
      activeSkipWindow:
          clearSkipWindow ? null : (activeSkipWindow ?? this.activeSkipWindow),
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
  VideoPlaybackController(this._ref, this.request)
    : super(
        VideoPlaybackState(
          currentEpisode: request.episode,
          currentVariant: request.variant,
          volume: _ref.read(playbackPreferencesProvider).defaultVolume,
          speed: _ref
              .read(playbackPreferencesProvider)
              .qualityConfig
              .defaultSpeed,
        ),
      ) {
    _bootstrap();
  }

  final Ref _ref;
  final VideoLaunchRequest request;

  final WatchedTracker _watchedTracker = WatchedTracker();
  final Completer<AndroidVideoSurfaceController>? _androidSurfaceCompleter =
      Platform.isAndroid ? Completer<AndroidVideoSurfaceController>() : null;

  EmbeddedMpvSession? _session;
  Timer? _persistTimer;
  Timer? _probeTimer;
  Timer? _skipFadeTimer;
  Timer? _bannerTimer;

  ChapterSkipPlan _skipPlan = const ChapterSkipPlan();
  DetectedSkipWindow? _dismissedSkipWindow;
  bool _persistDirty = false;
  bool _closedCleanly = false;
  bool _alreadyPersistedCompleted = false;
  double? _speedBeforeBoost;

  /// 有序同作品可连播正片剧集列表（严格正片集号升序，特典置于正片之后）。
  List<Episode> get orderedMainEpisodes => Episode.sortMainFirst(
    request.bundle.episodes.where((e) => e.category == EpisodeCategory.main),
  );

  /// 当前分集的展示标题。
  String get currentEpisodeTitle {
    return EpisodeTitleFormatter.formatCardTitle(
      episode: state.currentEpisode,
      workTitle: request.work.title,
      workMediaType: request.work.tmdbMediaType,
      mainEpisodeCount: orderedMainEpisodes.length,
    );
  }

  /// 查找当前集的下一集（若已到末尾则返回 null）。
  Episode? findNextEpisode() {
    final ep = state.currentEpisode;
    final list = ep.category == EpisodeCategory.main
        ? orderedMainEpisodes
        : Episode.sortMainFirst(
            request.bundle.episodes.where((e) => e.category == ep.category),
          );
    final idx = list.indexWhere((e) => e.id == ep.id);
    if (idx < 0 || idx + 1 >= list.length) return null;
    for (var i = idx + 1; i < list.length; i++) {
      final candidate = list[i];
      if (request.bundle.variantsForEpisode(candidate.id).isNotEmpty) {
        return candidate;
      }
    }
    return null;
  }

  /// 查找当前集的上一集（若已到首集则返回 null）。
  Episode? findPreviousEpisode() {
    final ep = state.currentEpisode;
    final list = ep.category == EpisodeCategory.main
        ? orderedMainEpisodes
        : Episode.sortMainFirst(
            request.bundle.episodes.where((e) => e.category == ep.category),
          );
    final idx = list.indexWhere((e) => e.id == ep.id);
    if (idx <= 0) return null;
    for (var i = idx - 1; i >= 0; i--) {
      final candidate = list[i];
      if (request.bundle.variantsForEpisode(candidate.id).isNotEmpty) {
        return candidate;
      }
    }
    return null;
  }

  /// Android `PlatformView` 创建后向控制器交付硬件表面通道。
  void attachAndroidSurface(AndroidVideoSurfaceController ctrl) {
    if (_androidSurfaceCompleter != null &&
        !_androidSurfaceCompleter.isCompleted) {
      _androidSurfaceCompleter.complete(ctrl);
    }
  }

  Future<void> _bootstrap() async {
    Future.microtask(() async {
      if (!mounted) return;
      _ref.read(videoPlaybackActiveProvider.notifier).state = true;
      await _ref.read(audioPlaybackProvider.notifier).pauseForVideoSession();
    });

    final mutex = _ref.read(embeddedSessionMutexProvider);
    await mutex.runExclusive(() async {
      if (!mounted || state.isClosing || _closedCleanly) return;

      final saved = request.bundle.playbackByEpisodeId[state.currentEpisode.id];
      _alreadyPersistedCompleted = saved?.isCompleted ?? false;

      final storageRoot = _ref.read(storageRootProvider);
      final shadersDir = await storageRoot.ensureShadersDir();
      final shaders = await MpvQualityProfile.discoverShaderFiles(shadersDir);

      final session = EmbeddedMpvSession(
        storageRoot: storageRoot,
        streamBridge: _ref.read(localStreamBridgeProvider),
        gatewayFactory: _ref.read(mediaSourceGatewayFactoryProvider),
        logStore: _ref.read(diagnosticsLogStoreProvider),
      );
      _session = session;

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
          state = state.copyWith(adapterName: session.adapterNameListenable.value);
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
        if (mounted) {
          state = state.copyWith(
            hasFirstFrame: true,
            probeStats: session.collectProbeStats(),
          );
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
          state = state.copyWith(
            isInitializing: false,
            isBuffering: false,
            errorMessage: msg,
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
          if (_persistDirty) {
            _persistDirty = false;
            unawaited(_persistProgress(isFinal: false));
          }
        });
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
    _persistDirty = true;
    _watchedTracker.sample(
      positionSeconds: posSeconds,
      durationSeconds: state.durationSeconds,
      isPlaying: state.isPlaying,
      speed: state.speed,
    );
    state = state.copyWith(positionSeconds: posSeconds);
    _evaluateChapterSkipWindow(posSeconds);
  }

  void _handleDurationChanged(double durSeconds) {
    if (!mounted) return;
    state = state.copyWith(durationSeconds: durSeconds);
    _recomputeChapterSkipPlan();
  }

  void _handlePlayingChanged(bool playing) {
    if (!mounted) return;
    state = state.copyWith(isPlaying: playing);
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
    state = state.copyWith(
      subtitles: subtitles,
      audioTracks: audioTracks,
      chapters: chapters,
      availableAudioDevices: audioDevices,
      probeStats: _session?.collectProbeStats() ?? state.probeStats,
    );
    _recomputeChapterSkipPlan();
  }

  void _recomputeChapterSkipPlan() {
    if (state.durationSeconds <= 0 || state.chapters.isEmpty) {
      _skipPlan = const ChapterSkipPlan();
      return;
    }
    _skipPlan = ChapterSkipAnalyzer.analyze(
      rawChapters: state.chapters,
      totalDurationSeconds: state.durationSeconds,
      hasNextEpisode: findNextEpisode() != null,
    );
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

    if (prefs.autoSkipChapter) {
      _dismissedSkipWindow = active;
      unawaited(executeSkipWindow(active));
      showTransientBanner('已自动${active.label}');
      return;
    }

    if (prefs.promptChapterSkip && state.activeSkipWindow != active) {
      state = state.copyWith(activeSkipWindow: active);
      _skipFadeTimer?.cancel();
      _skipFadeTimer = Timer(PlaybackQualityConfig.skipPillAutoFadeDuration, () {
        if (!mounted) return;
        _dismissedSkipWindow = active;
        state = state.copyWith(clearSkipWindow: true);
      });
    }
  }

  /// 执行智能跳过动作（OP / ED 跳 C-Part / ED 直接跳下一话）。
  Future<void> executeSkipWindow(DetectedSkipWindow window) async {
    _dismissedSkipWindow = window;
    _skipFadeTimer?.cancel();
    state = state.copyWith(clearSkipWindow: true);
    if (window.kind == SkipActionKind.skipEdToNextEpisode) {
      final nextEp = findNextEpisode();
      if (nextEp != null) {
        await switchToEpisode(nextEp, startSeconds: 0);
        return;
      }
    }
    seekAbsolute(window.endSeconds);
  }

  void _handleEndOfFile(int reason, int errorCode) {
    if (!mounted || state.isClosing) return;
    if (reason == MpvEndFileReason.eof) {
      unawaited(_persistProgress(isFinal: true));
      final prefs = _ref.read(playbackPreferencesProvider);
      if (prefs.autoNextEpisode) {
        final nextEp = findNextEpisode();
        if (nextEp != null) {
          unawaited(switchToEpisode(nextEp, startSeconds: 0, isAutoAdvance: true));
        }
      }
    } else if (reason == MpvEndFileReason.error) {
      state = state.copyWith(
        isBuffering: false,
        isPlaying: false,
        errorMessage: '播放意外中断 (code: $errorCode)',
      );
    }
  }

  /// 无缝切换当前作品的其他分集或变体（自动继承跨集音轨/字幕偏好）。
  Future<void> switchToEpisode(
    Episode episode, {
    MediaVariant? specificVariant,
    int? startSeconds,
    bool isAutoAdvance = false,
  }) async {
    final session = _session;
    if (session == null || !mounted || state.isClosing) return;

    await _persistProgress(isFinal: true);

    final variants = request.bundle.variantsForEpisode(episode.id);
    if (variants.isEmpty) return;
    final nextVariant = specificVariant ?? variants.first;
    final nextSource = request.bundle.sourcesById[nextVariant.sourceId];

    final saved = request.bundle.playbackByEpisodeId[episode.id];
    _alreadyPersistedCompleted = saved?.isCompleted ?? false;
    _watchedTracker.reset();
    _skipPlan = const ChapterSkipPlan();
    _dismissedSkipWindow = null;

    final resumePos = startSeconds ??
        ((saved != null && !saved.isCompleted && saved.positionSeconds > 5)
            ? saved.positionSeconds
            : 0);

    state = state.copyWith(
      currentEpisode: episode,
      currentVariant: nextVariant,
      isBuffering: true,
      hasFirstFrame: false,
      positionSeconds: resumePos.toDouble(),
      durationSeconds: 0.0,
      chapters: const [],
      clearSkipWindow: true,
      clearError: true,
    );

    await session.loadMediaVariant(
      EmbeddedVideoLoadRequest(
        workId: request.work.id,
        variant: nextVariant,
        source: nextSource,
        startSeconds: resumePos,
      ),
      trackMemory: state.trackMemory,
    );

    if (isAutoAdvance && mounted) {
      final label = EpisodeTitleFormatter.formatCardTitle(
        episode: episode,
        workTitle: request.work.title,
        workMediaType: request.work.tmdbMediaType,
        mainEpisodeCount: orderedMainEpisodes.length,
      );
      showTransientBanner(
        '已自动连播：$label',
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
    _session?.setPlaying(next);
    state = state.copyWith(isPlaying: next);
  }

  void seekAbsolute(double seconds) {
    _watchedTracker.notifySeek();
    final clamped = state.durationSeconds > 0
        ? seconds.clamp(0.0, state.durationSeconds)
        : (seconds < 0 ? 0.0 : seconds);
    _session?.seekAbsolute(clamped);
    state = state.copyWith(positionSeconds: clamped);
  }

  void seekRelative(double deltaSeconds) {
    seekAbsolute(state.positionSeconds + deltaSeconds);
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
    final pos = state.positionSeconds;
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
    final prevEp = findPreviousEpisode();
    if (prevEp != null) {
      unawaited(switchToEpisode(prevEp, startSeconds: 0));
    } else {
      seekAbsolute(0);
    }
  }

  void nextChapterOrEpisode() {
    final chapters = state.chapters;
    final pos = state.positionSeconds;
    if (chapters.isNotEmpty) {
      for (final ch in chapters) {
        if (ch.startSeconds > pos + 1.0) {
          seekAbsolute(ch.startSeconds);
          showTransientBanner(
            ch.title.isNotEmpty ? '章节：${ch.title}' : '下一章节',
          );
          return;
        }
      }
    }
    final nextEp = findNextEpisode();
    if (nextEp != null) {
      unawaited(switchToEpisode(nextEp, startSeconds: 0));
    }
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

  void selectSubtitle(SubtitleChoice? choice) {
    _session?.selectSubtitle(choice);
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
    state = state.copyWith(trackMemory: nextMemory);
  }

  void addExternalSubtitleFile(String path) {
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
    final clamped = double.parse(delaySeconds.clamp(-60.0, 60.0).toStringAsFixed(2));
    _session?.setSubtitleDelay(clamped);
    state = state.copyWith(subtitleDelaySeconds: clamped);
  }

  void setAudioDelay(double delaySeconds) {
    final clamped = double.parse(delaySeconds.clamp(-60.0, 60.0).toStringAsFixed(2));
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

  /// 切换桌面全屏（绝不触碰 `flutter_acrylic` 窗体材质，防止 DWM 黑闪）。
  Future<void> toggleFullscreen() async {
    if (!(!kIsWeb && defaultTargetPlatform == TargetPlatform.windows)) return;
    final next = !state.isFullscreen;
    await windowManager.setFullScreen(next);
    await Window.hideWindowControls();
    if (mounted) {
      state = state.copyWith(isFullscreen: next);
    }
  }

  /// 一键截取纯净原画 PNG 视频帧并写入 `<Root>/photos/<作品目录>/`。
  Future<File?> captureCleanScreenshot() async {
    final session = _session;
    if (session == null) return null;
    final photos = _ref.read(photosStorageProvider);
    final workDir = await photos.resolveWorkDirectory(
      request.work.id,
      title: request.work.title,
    );
    final epTag = state.currentEpisode.episodeNumber != null
        ? 'EP${state.currentEpisode.episodeNumber.toString().padLeft(2, '0')}'
        : null;
    final file = await session.captureCleanScreenshot(
      workPhotoDir: workDir,
      episodeTag: epTag,
    );
    if (file != null) {
      showTransientBanner('已保存纯净原画截图：${file.path}');
    }
    return file;
  }

  /// 一键热接力至外部播放器：携带精确当前秒数退出内置播放页并在外部播放器续播回写。
  Future<LaunchPlaybackResult> relayToExternalPlayer([
    ExternalPlayerConfig? targetPlayer,
  ]) async {
    final relayPos = state.positionSeconds.round();
    final ep = state.currentEpisode;
    final variant = state.currentVariant;
    final src = request.bundle.sourcesById[variant.sourceId];

    await closeAndRelease();

    return _ref
        .read(playbackCoordinatorProvider)
        .playVariant(
          work: request.work,
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
    final ep = state.currentEpisode;
    final variant = state.currentVariant;
    final durDouble = state.durationSeconds;
    final posDouble = state.positionSeconds;
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
    final src = request.bundle.sourcesById[variant.sourceId];
    final recordId = '${request.work.id}::${ep.id}';

    await repo.recordPlayback(
      PlaybackRecord(
        id: recordId,
        workId: request.work.id,
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
                      : request.work.title)),
        sourceType: src?.kind ?? MediaSourceKind.local,
        playedAt: DateTime.now(),
        positionSeconds: persistedPos,
        durationSeconds: durSeconds,
        isCompleted: completed,
      ),
    );
    _alreadyPersistedCompleted = completed;

    try {
      _ref.invalidate(playbackHistoryProvider);
      _ref.invalidate(workDetailBundleProvider(request.work.id));
    } catch (_) {}
  }

  /// 安全保存进度、退出全屏并在串行互斥锁内彻底释放底层硬件资源（允许多次幂等调用）。
  Future<void> closeAndRelease() async {
    if (_closedCleanly) return;
    _closedCleanly = true;

    _persistTimer?.cancel();
    _probeTimer?.cancel();
    _skipFadeTimer?.cancel();
    _bannerTimer?.cancel();

    if (mounted) {
      state = state.copyWith(isClosing: true);
    }

    if (state.isFullscreen &&
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.windows) {
      await windowManager.setFullScreen(false);
      await Window.hideWindowControls();
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
    _bannerTimer?.cancel();

    if (!_closedCleanly) {
      _closedCleanly = true;
      final sessionToDispose = _session;
      _session = null;
      if (sessionToDispose != null) {
        final mutex = _ref.read(embeddedSessionMutexProvider);
        unawaited(mutex.runExclusive(() => sessionToDispose.dispose()));
      }
      Future.microtask(() {
        try {
          _ref.read(videoPlaybackActiveProvider.notifier).state = false;
        } catch (_) {}
      });
    }
    super.dispose();
  }
}

/// 内置视频播放控制器 Family Provider（按单次播放请求自动挂载与释放）。
final videoPlaybackProvider = StateNotifierProvider.autoDispose
    .family<VideoPlaybackController, VideoPlaybackState, VideoLaunchRequest>(
      (ref, req) => VideoPlaybackController(ref, req),
    );
