import 'dart:async';
import 'dart:io';
import 'dart:ui' show Offset;

import 'package:engine_playback/engine_playback.dart';
import 'package:flutter/foundation.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';
import 'package:path/path.dart' as p;

import '../data/mpv_thumbnail_service.dart';
import '../data/pip_recovery_store.dart';
import '../data/video_playback_preferences.dart';
import '../data/video_session_models.dart';
import 'video_playback_state.dart';

part 'video_playback_controller_episodes.dart';
part 'video_playback_controller_subtitles.dart';
part 'video_playback_controller_window.dart';

/// 内置全屏视频播放核心状态控制器（零状态管理框架耦合，直连叶子进度监听器）。
///
/// 核心并发与性能守则：
/// - 进度秒数、总时长、缓冲时长与小窗坐标均由叶子 `ValueNotifier` 承载，杜绝高频重绘整棵页面树；
/// - 暂停、隐藏界面控制条或隐藏探针浮层时立即停止周期定时器；
/// - 四维代数边界由 `UnifiedPlaybackEngine` 统一托管，防止跨集残留事件与陈旧流回写；
/// - 仅当观看进度跨过完播阈值或人工点击标记看完时向 `DomainEventBus` 发布 `EpisodeCompletionChangedEvent`。
class VideoPlaybackController extends ChangeNotifier {
  /// 创建内置视频播放控制器。
  VideoPlaybackController({required this.env})
    : thumbnailService =
          env.thumbnailService ??
          MpvThumbnailService(
            streamBridge: env.streamBridge,
            gatewayFactory: env.gatewayFactory,
            logStore: env.diagnosticLog,
            clientFactory: env.libMpvClientFactory != null
                ? env.libMpvClientFactory!
                : () => env.playbackEngine.createAuxiliaryNativeClient(),
          ),
      _microFadeDriver = env.microFadeDriver ?? AudiophileMicroFadeDriver(),
      _state = VideoPlaybackState.idle(const WorkId.trusted('idle')) {
    _bindEnvironmentListeners();
  }

  /// 控制器显式注入的外部能力环境。
  final VideoPlaybackEnvironment env;

  /// 按需惰性后台缩略图解码服务。
  final MpvThumbnailService thumbnailService;

  final AudiophileMicroFadeDriver _microFadeDriver;

  /// 高频视频当前播放时间叶子监听器（不触发控制器全树刷新）。
  final ValueNotifier<Duration> positionNotifier = ValueNotifier<Duration>(
    Duration.zero,
  );

  /// 高频视频总时长叶子监听器。
  final ValueNotifier<Duration> durationNotifier = ValueNotifier<Duration>(
    Duration.zero,
  );

  /// 高频解复用预缓存可用前瞻时长叶子监听器。
  final ValueNotifier<Duration> bufferedNotifier = ValueNotifier<Duration>(
    Duration.zero,
  );

  /// 悬浮小窗相对安全边界的拖拽坐标叶子监听器。
  final ValueNotifier<Offset> miniPlayerOffsetNotifier = ValueNotifier<Offset>(
    Offset.zero,
  );

  VideoPlaybackState _state;

  /// 当前视频播放器结构化状态不可变快照。
  VideoPlaybackState get state => _state;

  EmbeddedMpvSession? _session;
  SubtitleMemoryEngine? _subtitleMemoryEngine;
  SubtitleFontPoolManager? _ownedFontPoolManager;
  WatchedTracker? _watchedTracker;

  Timer? _persistTimer;
  Timer? _probeTimer;
  Timer? _autoNextTimer;
  Timer? _noticeTimer;

  StreamSubscription<int?>? _textureIdSub;
  StreamSubscription<bool>? _underlayActiveSub;
  StreamSubscription<String>? _renderBackendSub;
  StreamSubscription<String>? _adapterNameSub;
  StreamSubscription<VideoPlaybackPreferences>? _prefsSub;
  VideoPlaybackPreferences? _lastCloudPrefs;

  bool _disposed = false;
  bool _closing = false;
  bool _miniModeTransition = false;
  Object? _hardwareViewportOwner;
  bool _hudVisible = true;
  bool _systemPipActive = false;

  /// 原生系统画中画使用系统控制层，不再绘制完整应用播控。
  bool get systemPipActive => _systemPipActive;

  /// 仅有效的展开视频舞台自动进入系统画中画，避免把媒体库整个缩入系统小窗。
  bool canAutoEnterSystemPip({required bool stageExpanded}) =>
      env.preferencesStore.read().autoEnterPip &&
      (stageExpanded || systemPipActive) &&
      state.isPlaying &&
      state.hasFirstFrame &&
      !state.audioOnlyMode &&
      !state.isInitializing &&
      !state.isClosing &&
      state.errorMessage == null;

  /// 由宿主原生画中画回调更新，保留原解码会话。
  void setSystemPipActive(bool active) {
    if (_disposed || _closing || _systemPipActive == active) return;
    _systemPipActive = active;
    if (active) {
      unawaited(persistPipRecoverySnapshot());
      setHudVisible(false);
      updateHudSubtitleLift(
        hudVisible: false,
        bottomCapsuleOccupiedHeight: 0,
        viewportHeight: 0,
      );
    } else {
      unawaited(env.pipRecoveryStore.clear());
    }
    notifyListeners();
  }

  /// 用户关闭系统画中画时暂停原会话，不销毁播放器或留下冷恢复快照。
  Future<void> dismissSystemPip() async {
    final position = _session?.readCurrentPositionSeconds();
    if (position != null) handlePositionUpdate(position);
    setSystemPipActive(false);
    await setPlaying(false);
    await env.pipRecoveryStore.clear();
  }

  double _currentSubtitleHudLiftPercent = 0.0;
  bool _hasCompletedCurrentEpisode = false;
  double _lastSavedPosSeconds = -1;
  double _speedBeforeBoost = 1.0;
  int _noticeSeq = 0;
  int _initEpoch = 0;
  ChapterSkipPlan? _skipPlan;
  bool _autoSkippedOpeningForEpisode = false;
  bool _autoSkippedEndingForEpisode = false;
  String? _lastIngestedCloudSubsetFontsDir;
  final Set<String> _emittedCompletedEpisodes = <String>{};

  /// 当前由底部播控胶囊可见性触发的字幕上抬百分比（0.0 表示恢复原始基准位置）。
  double get currentSubtitleHudLiftPercent => _currentSubtitleHudLiftPercent;

  void _bindEnvironmentListeners() {
    env.shaderDiscoveryService.addListener(_onShadersChanged);
    _lastCloudPrefs = env.preferencesStore.read();
    _prefsSub = env.preferencesStore.watch().listen(_onPreferencesChanged);
  }

  void _onShadersChanged() {
    if (_disposed || _closing) return;
    _setState(
      _state.copyWith(availableShaders: env.shaderDiscoveryService.state.files),
    );
  }

  void _onPreferencesChanged(VideoPlaybackPreferences nextPrefs) {
    if (_disposed || _closing) return;
    final previous = _lastCloudPrefs;
    _lastCloudPrefs = nextPrefs;
    final cloud = env.cloudSubsetCoordinator;
    if (previous != null && cloud != null) {
      if ((previous.enableCloudSubset && !nextPrefs.enableCloudSubset) ||
          previous.fontInAssEndpoint != nextPrefs.fontInAssEndpoint) {
        cloud.cancelAllCloudSubsetTasks();
      }
      for (final removed
          in previous.authorizedCloudSubsetOrigins.toSet().difference(
            nextPrefs.authorizedCloudSubsetOrigins.toSet(),
          )) {
        final uri = Uri.tryParse(removed);
        if (uri != null &&
            uri.host.isNotEmpty &&
            (uri.scheme == 'http' || uri.scheme == 'https')) {
          cloud.revokeOriginAndCancel(uri);
        }
      }
    }
    _session?.applyLiveQualityConfig(nextPrefs.qualityConfig);
    final normVol = (nextPrefs.volume.clamp(0.0, 1.0)) * 100.0;
    if ((normVol - _state.volume).abs() > 0.5 ||
        nextPrefs.isMuted != _state.isMuted) {
      _session?.setVolume(normVol);
      _session?.setMute(nextPrefs.isMuted);
      _setState(_state.copyWith(volume: normVol, isMuted: nextPrefs.isMuted));
    } else if (previous?.autoEnterPip != nextPrefs.autoEnterPip) {
      notifyListeners();
    }
  }

  /// 初始化并装载指定作品或剧集的视频会话。
  Future<void> initialize(VideoLaunchRequest request) async {
    if (_disposed) return;
    final epoch = ++_initEpoch;
    _closing = false;
    _cancelAllTimers();

    _setState(
      _state.copyWith(
        isInitializing: true,
        isBuffering: true,
        hasFirstFrame: false,
        isClosing: false,
        clearError: true,
        clearSkipWindow: true,
        clearHwdecReason: true,
      ),
    );

    final bundle =
        request.initialBundle ??
        await VideoBundleLoader.load(
          databases: env.databases,
          workId: request.workId,
        );
    if (_disposed || epoch != _initEpoch) return;

    if (bundle == null || bundle.variants.isEmpty) {
      _setState(
        _state.copyWith(
          isInitializing: false,
          isBuffering: false,
          errorMessage: '未找到可播放的视频物理文件',
        ),
      );
      return;
    }

    final resolved = VideoSeriesHelper.resolveInitialTarget(bundle, request);
    final episode = resolved.episode;
    final variant = resolved.variant;
    final source = bundle.sourcesById[variant.sourceId];

    final existingRecord =
        bundle.playbackByEpisodeId[episode.id.value] ??
        env.databases.userState.playbackRecords.findLatestByEpisode(episode.id);
    final initialCompleted = existingRecord?.isCompleted ?? false;
    _hasCompletedCurrentEpisode = initialCompleted;
    if (initialCompleted) {
      _emittedCompletedEpisodes.add(episode.id.value);
    }

    var startSec = (request.initialPositionSeconds ?? 0).toDouble();
    if (request.initialPositionSeconds == null &&
        existingRecord != null &&
        !existingRecord.isCompleted &&
        existingRecord.positionSeconds >= 6) {
      startSec = existingRecord.positionSeconds.toDouble();
    }

    final prefs = env.preferencesStore.read();
    final qualityConfig = _resolveEffectiveQualityConfig(
      prefs.qualityConfig,
      variant,
    );
    final safetyDecision = _evaluateVariantHwdecSafety(variant);
    final volume100 = (prefs.volume.clamp(0.0, 1.0)) * 100.0;

    _watchedTracker = WatchedTracker();
    _skipPlan = null;
    _autoSkippedOpeningForEpisode = false;
    _autoSkippedEndingForEpisode = false;
    _lastSavedPosSeconds = startSec;

    positionNotifier.value = Duration(milliseconds: (startSec * 1000).round());
    durationNotifier.value =
        existingRecord != null && existingRecord.durationSeconds > 0
        ? Duration(seconds: existingRecord.durationSeconds)
        : Duration.zero;
    bufferedNotifier.value = Duration.zero;

    _setState(
      VideoPlaybackState(
        isInitializing: false,
        isBuffering: env.libMpvClientFactory != null,
        hasFirstFrame: false,
        isPlaying: false,
        isClosing: false,
        miniMode: _state.miniMode,
        currentWork: bundle.work,
        currentBundle: bundle,
        currentEpisode: episode,
        currentVariant: variant,
        durationSeconds: durationNotifier.value.inSeconds.toDouble(),
        speed: qualityConfig.defaultSpeed,
        volume: volume100,
        isMuted: prefs.isMuted,
        isFullscreen: await env.hostWindow.isFullScreen(),
        availableShaders: env.shaderDiscoveryService.state.files,
        trackMemory: CrossEpisodeTrackMemory(
          audioLang: prefs.preferredAudioLangs.firstOrNull,
          subLang: prefs.preferredSubtitleLangs.firstOrNull,
        ),
        isCompletedCurrentEpisode: initialCompleted,
        hwdecForcedSoftwareReason: safetyDecision.allowHardwareDecode
            ? null
            : safetyDecision.reason,
      ),
    );

    if (!safetyDecision.allowHardwareDecode &&
        safetyDecision.reason != null &&
        safetyDecision.reason!.isNotEmpty) {
      showTransientNotice(safetyDecision.reason!);
    }

    await env.shaderDiscoveryService.refresh();
    if (_disposed || epoch != _initEpoch) return;

    await env.hostWindow.setPreferredLandscape(true);
    await env.hostWindow.setKeepScreenOn(true);
    if (_disposed || epoch != _initEpoch) return;

    if (env.libMpvClientFactory == null &&
        Platform.environment.containsKey('FLUTTER_TEST')) {
      _setState(
        _state.copyWith(
          isInitializing: false,
          isBuffering: false,
          hasFirstFrame: true,
        ),
      );
      return;
    }

    await _startOrReloadSession(
      bundle: bundle,
      episode: episode,
      variant: variant,
      source: source?.toReadView(),
      qualityConfig: qualityConfig,
      startSeconds: startSec,
      volume100: volume100,
      startPlaying: request.initialPlaying,
    );
  }

  Future<void> _startOrReloadSession({
    required VideoWorkBundle bundle,
    required EpisodeRecord episode,
    required MediaVariantRecord variant,
    required MediaSourceView? source,
    required PlaybackQualityConfig qualityConfig,
    required double startSeconds,
    required double volume100,
    bool startPlaying = true,
  }) async {
    final existingSession = _session;
    final loadReq = EmbeddedVideoLoadRequest(
      workId: bundle.work.id.value,
      variant: variant,
      source: source,
      startSeconds: startSeconds,
      startPlaying: startPlaying,
    );

    if (existingSession != null) {
      _ensureSubtitleMemoryEngine().resetForPhysicalMediaEpoch();
      env.playbackEngine.beginPhysicalMedia(stage: PlaybackStageKind.video);
      await existingSession.loadMediaVariant(
        loadReq,
        trackMemory: _state.trackMemory,
        trackPreferences: env.preferencesStore.read().trackPreferences,
      );
      if (_currentSubtitleHudLiftPercent > 0.0) {
        existingSession.setSubtitleHudLiftPercent(0.0);
        existingSession.setSubtitleHudLiftPercent(
          _currentSubtitleHudLiftPercent,
        );
      }
      return;
    }

    final session = EmbeddedMpvSession(
      storageRoot: env.storageRoot,
      streamBridge: env.streamBridge,
      logStore: env.diagnosticLog,
      clientFactory: env.libMpvClientFactory,
      nativeClientAcquirer: ({onEvicted}) async {
        final acquired = await env.playbackEngine.acquireExclusiveNativeClient(
          stage: PlaybackStageKind.video,
          factoryOverride: env.libMpvClientFactory,
          onEvicted: onEvicted,
        );
        return acquired.client;
      },
      nativeClientReleaser: (client) =>
          env.playbackEngine.releaseNativeClient(client),
      desktopSurfaceBridge: env.desktopSurfaceBridge,
      desktopProfileDelegate: env.desktopProfileDelegate,
      gatewayFactory: env.gatewayFactory,
      subtitleDirectoryIndex: env.subtitleDirectoryIndex,
      androidSurfacePort: env.androidSurfacePort,
      mediaStorePublisher: env.mediaStorePublisher,
      fontPoolManager: env.fontPoolManager,
      isWindowsOverride: env.platform == KonataPlatform.windows,
      isAndroidOverride: env.platform != KonataPlatform.windows,
    );

    _session = session;
    _bindSessionCallbacks(session);

    env.playbackEngine.beginPhysicalMedia(stage: PlaybackStageKind.video);

    await session.initializeAndLoad(
      request: loadReq,
      qualityConfig: qualityConfig,
      trackMemory: _state.trackMemory,
      trackPreferences: env.preferencesStore.read().trackPreferences,
      initialVolume: volume100,
    );

    if (_disposed) return;
    if (_currentSubtitleHudLiftPercent > 0.0) {
      session.setSubtitleHudLiftPercent(_currentSubtitleHudLiftPercent);
    }
    unawaited(
      thumbnailService.warmUp(
        variant: variant,
        source: source,
        durationSeconds: _state.durationSeconds > 0
            ? _state.durationSeconds
            : null,
      ),
    );
  }

  void _bindSessionCallbacks(EmbeddedMpvSession session) {
    unawaited(_textureIdSub?.cancel());
    unawaited(_underlayActiveSub?.cancel());
    unawaited(_renderBackendSub?.cancel());
    unawaited(_adapterNameSub?.cancel());

    _textureIdSub = session.textureIdChanges.listen((tid) {
      if (!_disposed && !_closing) {
        _setState(_state.copyWith(textureId: tid, clearTextureId: tid == null));
      }
    });
    _underlayActiveSub = session.underlayActiveChanges.listen((active) {
      if (!_disposed && !_closing) {
        _setState(_state.copyWith(windowsUnderlayActive: active));
      }
    });
    _renderBackendSub = session.renderBackendChanges.listen((backend) {
      if (!_disposed && !_closing) {
        _setState(_state.copyWith(renderBackend: backend));
      }
    });
    _adapterNameSub = session.adapterNameChanges.listen((adapter) {
      if (!_disposed && !_closing) {
        _setState(_state.copyWith(adapterName: adapter));
      }
    });

    session.onNativeClientBound = (client) {
      env.playbackEngine.bindActiveNativeClient(
        client,
        stage: PlaybackStageKind.video,
      );
      env.audiophileCoordinator.attachSession(
        owner: this,
        clientProvider: () => client,
        prefsProvider: () => env.preferencesStore.read().audiophilePreferences,
        onTransientMuteAndPause: _handleAudioDeviceEmergencyPause,
      );
    };
    session.onBindMainStreamLease = (token) =>
        env.playbackEngine.bindMainStreamLease(token);
    session.onPlaylistEntryStarted = (entryId) {
      env.playbackEngine.bindPlaylistEntryId(entryId);
    };
    session.onValidatePhysicalEvent = ({playlistEntryId}) =>
        env.playbackEngine.matchesPhysicalEvent(
          physicalMediaEpoch: env.playbackEngine.physicalMediaEpoch,
          playlistEntryId: playlistEntryId,
        );
    session.onFileLoaded = () {
      env.playbackEngine.recordFileLoaded();
    };
    session.onApplyAudiophileSafetyChain = (client) {
      env.audiophileCoordinator.applyToClient(
        client,
        prefs: env.preferencesStore.read().audiophilePreferences,
      );
    };
    session.onTriggerMicroFadeIn =
        (client, {required targetVolume, required isMuted}) {
          _microFadeDriver.start(
            client: client,
            plan: env.audiophileCoordinator.activePlan,
            targetVolume: targetVolume,
            isMuted: isMuted,
            isAlive: () => !_disposed && !_closing,
          );
        };
    session.onPositionChanged = handlePositionUpdate;
    session.onDurationChanged = handleDurationUpdate;
    session.onPlayingChanged = _handlePlayingChanged;
    session.onBufferingChanged = (buffering) {
      if (!_disposed && !_closing && _state.isBuffering != buffering) {
        _setState(_state.copyWith(isBuffering: buffering));
      }
    };
    session.onSpeedChanged = (spd) {
      if (!_disposed && !_closing && (_state.speed - spd).abs() > 0.005) {
        _setState(_state.copyWith(speed: spd));
      }
    };
    session.onFirstFrameRendered = () {
      env.playbackEngine.recordEffectiveProgress();
      if (!_disposed && !_closing && !_state.hasFirstFrame) {
        _setState(_state.copyWith(hasFirstFrame: true, isBuffering: false));
      }
      refreshProbeOnce();
    };
    session.onHwdecChanged = _onHwdecChanged;
    session.onMediaMetadataUpdated = _onMediaMetadataUpdated;
    session.onEndOfFile = _onEndOfFile;
    session.onNotice = showTransientNotice;
    session.onFatalError = (msg) {
      if (!_disposed && !_closing) {
        _setState(
          _state.copyWith(
            isInitializing: false,
            isBuffering: false,
            errorMessage: msg,
          ),
        );
      }
    };
    session.mountedSubtitleSourcePathsReader = _readMountedSubtitleSourcePaths;
    session.mountedCloudSubsetTrackIdsReader = _readMountedCloudSubsetTrackIds;
    session.onMountExternalTextSubtitles =
        _mountDiscoveredExternalTextSubtitles;
  }

  /// 处理高频播放位置推进事件（仅更新叶子监听器，避免刷新整棵视图树）。
  void handlePositionUpdate(double posSeconds) {
    if (_disposed || _closing || !posSeconds.isFinite || posSeconds < 0) {
      return;
    }
    final nextDuration = Duration(milliseconds: (posSeconds * 1000).round());
    if (positionNotifier.value != nextDuration) {
      positionNotifier.value = nextDuration;
    }

    _watchedTracker?.sample(
      positionSeconds: posSeconds,
      durationSeconds: _state.durationSeconds,
      speed: _state.speed,
      isPlaying: _state.isPlaying,
    );

    _checkCompletionTransition(posSeconds);
    _updateSkipWindowForPosition(posSeconds);
  }

  /// 更新当前视频总时长并广播至叶子总时长监听器与章节缩略图预热队列。
  void handleDurationUpdate(double durSeconds) {
    if (_disposed || _closing || !durSeconds.isFinite || durSeconds < 0) {
      return;
    }
    final next = Duration(milliseconds: (durSeconds * 1000).round());
    if (durationNotifier.value != next) {
      durationNotifier.value = next;
    }
    if ((_state.durationSeconds - durSeconds).abs() > 0.2) {
      _setState(_state.copyWith(durationSeconds: durSeconds));
      _recomputeChapterSkipPlan();
      thumbnailService.updateChapters(
        _state.chapters,
        durationSeconds: durSeconds,
      );
    }
  }

  /// 更新当前缓冲前瞻时长叶子监听器，不触发控制层全量重建。
  void handleBufferedUpdate(double bufferedSeconds) {
    if (_disposed ||
        _closing ||
        !bufferedSeconds.isFinite ||
        bufferedSeconds < 0) {
      return;
    }
    final next = Duration(milliseconds: (bufferedSeconds * 1000).round());
    if (bufferedNotifier.value != next) {
      bufferedNotifier.value = next;
    }
  }

  void _handlePlayingChanged(bool playing) {
    if (_disposed || _closing) return;
    if (_state.isPlaying != playing) {
      _setState(_state.copyWith(isPlaying: playing));
    }
    _syncTimersForActivity();
    if (!playing) {
      unawaited(persistProgressNow());
      if (systemPipActive) unawaited(persistPipRecoverySnapshot());
    }
  }

  void _syncTimersForActivity() {
    if (!env.enablePeriodicTimers || _disposed || _closing) {
      _cancelPeriodicTimers();
      return;
    }
    final activePlaying = _state.isPlaying;
    if (!activePlaying) {
      _persistTimer?.cancel();
      _persistTimer = null;
      _probeTimer?.cancel();
      _probeTimer = null;
      _session?.setPositionObservationEnabled(false);
      return;
    }

    _session?.setPositionObservationEnabled(
      _hudVisible || _state.isMiniPlayer || _skipPlan != null,
    );
    _persistTimer ??= Timer.periodic(const Duration(seconds: 10), (_) {
      unawaited(persistProgressNow());
      if (systemPipActive) unawaited(persistPipRecoverySnapshot());
    });

    if (_state.probeOverlayVisible) {
      _probeTimer ??= Timer.periodic(
        const Duration(milliseconds: 500),
        (_) => refreshProbeOnce(),
      );
    } else {
      _probeTimer?.cancel();
      _probeTimer = null;
    }
  }

  /// 通知控制器界面控制层可见性变化，在隐藏状态按需收敛后台探针与定时轮询。
  void setHudVisible(bool visible) {
    if (_hudVisible == visible) return;
    _hudVisible = visible;
    if (!_disposed && !_closing) {
      if (visible) refreshProbeOnce();
      _syncTimersForActivity();
    }
  }

  /// 立即执行单次音画实时探针采样（不会残留常驻后台定时器）。
  void refreshProbeOnce() {
    final session = _session;
    if (_disposed || _closing || session == null) return;
    final stats = _state.probeOverlayVisible
        ? session.collectProbeStats()
        : session.collectLightProbeStats(previous: _state.probeStats);
    final cacheSec = stats.demuxerCacheSeconds;
    if (cacheSec != null && cacheSec >= 0) {
      handleBufferedUpdate(
        (positionNotifier.value.inMilliseconds / 1000.0) + cacheSec,
      );
    }
    final previous = _state.probeStats;
    if (_state.probeOverlayVisible ||
        stats.videoWidth != previous.videoWidth ||
        stats.videoHeight != previous.videoHeight ||
        stats.videoCodec != previous.videoCodec ||
        stats.videoPixelFormat != previous.videoPixelFormat ||
        stats.videoHwPixelFormat != previous.videoHwPixelFormat ||
        stats.videoProfile != previous.videoProfile ||
        stats.hwdecCurrent != previous.hwdecCurrent) {
      _setState(_state.copyWith(probeStats: stats));
    }
  }

  void _handleAudioDeviceEmergencyPause(String reason) {
    if (_disposed || _closing) return;
    _handlePlayingChanged(false);
    showTransientNotice('检测到音频输出外设断开（$reason），已自动静音并暂停', isError: true);
  }

  void _onHwdecChanged(String hwdecCurrent) {
    if (_disposed || _closing) return;
    refreshProbeOnce();
    final safety = HwdecSafetyPolicy.evaluate(
      platform: _toHwdecPlatform(),
      videoCodec: _state.probeStats.videoCodec,
      videoProfile: _state.probeStats.videoProfile,
      pixelFormat: _state.probeStats.videoPixelFormat,
      hwPixelFormat: _state.probeStats.videoHwPixelFormat,
    );
    if (!safety.allowHardwareDecode &&
        hwdecCurrent.trim().isNotEmpty &&
        hwdecCurrent.trim() != 'no') {
      _setState(
        _state.copyWith(
          hwdecForcedSoftwareReason: safety.reason ?? '已自动切换多线程软解保障画面稳定',
        ),
      );
    }
  }

  void _onMediaMetadataUpdated({
    required List<SubtitleChoice> subtitles,
    required List<AudioTrackChoice> audioTracks,
    required List<PlaybackChapter> chapters,
    required List<MpvAudioDevice> audioDevices,
  }) {
    if (_disposed || _closing) return;
    _setState(
      _state.copyWith(
        subtitles: subtitles,
        audioTracks: audioTracks,
        chapters: chapters,
        availableAudioDevices: audioDevices,
      ),
    );
    refreshProbeOnce();
    _recomputeChapterSkipPlan();
    thumbnailService.updateChapters(
      chapters,
      durationSeconds: _state.durationSeconds > 0
          ? _state.durationSeconds
          : null,
    );
  }

  void _onEndOfFile(int reason, int errorCode) {
    if (_disposed || _closing) return;
    if (errorCode != 0 && reason == 4) {
      env.playbackEngine.recordPhysicalMediaFailure();
      showTransientNotice('媒体播放异常中断（错误码 $errorCode）', isError: true);
      return;
    }
    if (reason == 0 && _state.durationSeconds > 0) {
      handlePositionUpdate(_state.durationSeconds);
      unawaited(persistProgressNow(forceCompleted: true));
      final autoNext = env.preferencesStore.read().autoPlayNextEpisode;
      if (autoNext && hasNextEpisode) {
        showTransientNotice('本集播放结束，即将自动播放下一集');
        _autoNextTimer?.cancel();
        _autoNextTimer = Timer(
          PlaybackQualityConfig.autoNextEpisodeToastDuration,
          () => unawaited(playNextEpisode()),
        );
      }
    }
  }

  /// 在屏幕中央触发全站统一居中悬浮胶囊瞬态轻提示。
  void showTransientNotice(
    String message, {
    bool isError = false,
    Duration duration = const Duration(seconds: 3),
  }) {
    final trimmed = message.trim();
    if (_disposed || trimmed.isEmpty) return;
    _noticeTimer?.cancel();
    final seq = ++_noticeSeq;
    _setState(
      _state.copyWith(
        transientNotice: (
          seq: seq,
          message: trimmed,
          isError: isError,
          duration: duration,
        ),
      ),
    );
    _noticeTimer = Timer(duration, () {
      if (!_disposed && _state.transientNotice?.seq == seq) {
        _setState(_state.copyWith(clearTransientNotice: true));
      }
    });
  }

  void _cancelPeriodicTimers() {
    _persistTimer?.cancel();
    _persistTimer = null;
    _probeTimer?.cancel();
    _probeTimer = null;
  }

  void _cancelAllTimers() {
    _cancelPeriodicTimers();
    _autoNextTimer?.cancel();
    _autoNextTimer = null;
    _noticeTimer?.cancel();
    _noticeTimer = null;
  }

  void _setState(VideoPlaybackState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _closing = true;
    _cancelAllTimers();
    env.shaderDiscoveryService.removeListener(_onShadersChanged);
    unawaited(_prefsSub?.cancel());
    unawaited(_textureIdSub?.cancel());
    unawaited(_underlayActiveSub?.cancel());
    unawaited(_renderBackendSub?.cancel());
    unawaited(_adapterNameSub?.cancel());
    env.audiophileCoordinator.detachSession(this);
    _session?.silenceAndDetachForClose();
    unawaited(_session?.dispose());
    _session = null;
    if (env.thumbnailService == null) {
      thumbnailService.dispose();
    }
    positionNotifier.dispose();
    durationNotifier.dispose();
    bufferedNotifier.dispose();
    miniPlayerOffsetNotifier.dispose();
    super.dispose();
  }
}
