import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../composition/platform_composition.dart';
import '../../domain/models/media_source.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/models/playback_record.dart';
import '../../domain/models/work.dart';
import '../../domain/matching/supplementary_subclassifier.dart';
import '../../domain/playback/audiophile_safety_policy.dart';
import '../../domain/playback/cue_and_lrc_parser.dart';
import '../../domain/playback/cue_variant_resolver.dart';
import '../../domain/playback/lyric_version_matcher.dart';
import '../../domain/playback/playback_formatters.dart';
import '../../domain/repositories/file_system_gateway.dart';
import '../../infrastructure/cache/album_cover_compactor.dart';
import '../../infrastructure/cache/photos_storage.dart';
import '../../infrastructure/logging/diagnostics_log_store.dart';
import '../../infrastructure/players/android/android_media_session_bridge.dart';
import '../../infrastructure/players/audio_art_extractor.dart';
import '../../infrastructure/players/libmpv_ffi.dart';
import '../../infrastructure/players/mpv_quality_profile.dart';
import '../../infrastructure/players/online_lyric_lookup_service.dart';
import '../../infrastructure/sources/byte_stream_source_gateway.dart';
import '../../infrastructure/sources/local_source_gateway.dart';
import '../../infrastructure/sources/source_access_error.dart';
import '../../infrastructure/sources/source_gateway_factory.dart';
import '../../infrastructure/storage/storage_root_provider.dart';
import '../../infrastructure/storage/temp_cache_pruner.dart';
import '../../infrastructure/stream_bridge/local_stream_bridge.dart';
import '../providers/artwork_provider.dart';
import '../providers/diagnostics_providers.dart';
import '../providers/library_providers.dart';
import '../providers/memory_coordinator.dart';
import '../providers/platform_capability.dart';
import '../providers/playback_providers.dart';
import 'audiophile_safety_coordinator.dart';
import 'lyric_lookup_coordinator.dart';
import 'playback_preferences_provider.dart';
import 'unified_playback_coordinator.dart';
import 'unified_playback_engine.dart';

part 'audio_playback_assets.dart';
part 'audio_playback_models.dart';
part 'audio_playback_queue_builder.dart';
part 'audio_playback_transport.dart';

/// 基于 `libmpv`（`vid=no`, `vo=null`, `soxr`）并收敛于 `UnifiedPlaybackEngine` 与
/// `AudiophileSafetyCoordinator` 的 CD / 无损音频播放器控制器。
class AudioPlaybackNotifier extends Notifier<AudioPlaybackState> {
  /// 创建 CD / 无损音频播放控制器。
  AudioPlaybackNotifier({
    this.clientFactory,
    MediaSourceGatewayFactory? gatewayFactory,
    this.retryDelayBuilder,
    this.microFadeStepInterval = const Duration(milliseconds: 25),
    AndroidMediaSessionBridge? mediaSessionBridge,
    this.initialState,
  }) : _gatewayFactoryOverride = gatewayFactory,
       _mediaSessionBridgeOverride = mediaSessionBridge;

  /// 非致命流加载异常的最大静默重试次数。
  static const int maxSilentRetries = 3;

  Ref get _ref => ref;
  bool get mounted => ref.mounted;
  AudioPlaybackState get _state => state;
  set _state(AudioPlaybackState value) => state = value;

  static const int _propTimePos = 101;
  static const int _propDuration = 102;
  static const int _propPause = 103;
  static const int _propCoreIdle = 104;
  static const int _propAudioCodec = 105;
  static const int _propSampleRate = 106;
  static const int _propAudioFormat = 107;
  static const int _propAudioBitrate = 108;
  static const int _propEofReached = 109;
  static const int _propAudioDeviceList = 110;
  static const int _propAudioDevice = 111;

  static const Duration _cueSeekDebounceWindow = Duration(milliseconds: 900);
  static const int _maxAlbumCacheEntries = 32;

  final LibMpvClient Function()? clientFactory;
  final MediaSourceGatewayFactory? _gatewayFactoryOverride;
  MediaSourceGatewayFactory? _gatewayFactoryInstance;
  final Duration Function(int attempt)? retryDelayBuilder;

  /// S 型微淡入斜坡的离散步进周期（默认 25 ms，约 6 步完成 150 ms 后即停钟）。
  final Duration microFadeStepInterval;
  final AndroidMediaSessionBridge? _mediaSessionBridgeOverride;
  final AudioPlaybackState? initialState;
  AudiophileMicroFadeDriver? _microFadeDriverInstance;

  /// 惰性解析媒体源网关工厂（空载冷启动零提前读取）。
  MediaSourceGatewayFactory get gatewayFactory {
    final existing = _gatewayFactoryInstance;
    if (existing != null) return existing;
    final override = _gatewayFactoryOverride;
    if (override != null) {
      _gatewayFactoryInstance = override;
      return override;
    }
    final resolved = _ref.read(mediaSourceGatewayFactoryProvider);
    _gatewayFactoryInstance = resolved;
    return resolved;
  }

  @override
  AudioPlaybackState build() {
    ref.onDispose(_disposeResources);
    final seed = initialState ?? const AudioPlaybackState();
    _positionListenable.value = seed.positionSeconds;
    if (seed.isActive || _mediaSessionBridgeOverride != null) {
      Future<void>.microtask(() {
        if (ref.mounted) _syncAndroidMediaSession();
      });
    }
    return seed;
  }

  final ValueNotifier<double> _positionListenable = ValueNotifier<double>(0.0);

  /// 高频音频进度独立通道（驱动胶囊、触控滑杆、迷你圆环与逐字扫白漂移校准，零 Riverpod 扇出）。
  ValueListenable<double> get positionListenable => _positionListenable;

  /// 当前精确曲目播放秒数。
  double get currentPositionSeconds => _positionListenable.value;

  /// 惰性初始化微淡入驱动器（空载冷启动期零对象分配）。
  AudiophileMicroFadeDriver get _microFadeDriver =>
      _microFadeDriverInstance ??= AudiophileMicroFadeDriver(
        stepInterval: microFadeStepInterval,
      );

  AndroidMediaSessionBridge? _mediaSessionBridgeInstance;
  UnifiedPlaybackEngine? _engineInstance;
  AudiophileSafetyCoordinator? _safetyCoordinatorInstance;
  LocalStreamBridge? _streamBridgeInstance;
  DiagnosticsLogStore? _logStoreInstance;
  bool _runtimeListenersBound = false;
  final List<ProviderSubscription<Object?>> _runtimeSubscriptions = [];

  /// 惰性初始化统一播放代数引擎（空载未播音频时不提前构造）。
  UnifiedPlaybackEngine get _engine {
    final existing = _engineInstance;
    if (existing != null) return existing;
    final created = _ref.read(unifiedPlaybackEngineProvider);
    _engineInstance = created;
    return created;
  }

  /// 惰性初始化发烧音频安全协调器（避免空载冷启动提前绑定平台音频通道）。
  AudiophileSafetyCoordinator get _safetyCoordinator {
    final existing = _safetyCoordinatorInstance;
    if (existing != null) return existing;
    final created = _ref.read(audiophileSafetyCoordinatorProvider);
    _safetyCoordinatorInstance = created;
    return created;
  }

  /// 惰性初始化本地流网桥。
  LocalStreamBridge get _streamBridge {
    final existing = _streamBridgeInstance;
    if (existing != null) return existing;
    final created = _ref.read(localStreamBridgeProvider);
    _streamBridgeInstance = created;
    return created;
  }

  /// 惰性初始化诊断日志存储。
  DiagnosticsLogStore get _logStore {
    final existing = _logStoreInstance;
    if (existing != null) return existing;
    final created = _ref.read(diagnosticsLogStoreProvider);
    _logStoreInstance = created;
    return created;
  }

  /// 惰性初始化 Android 媒体会话通信桥（桌面与空载未播态零通道绑定）。
  AndroidMediaSessionBridge get _mediaSessionBridge {
    final existing = _mediaSessionBridgeInstance;
    if (existing != null) return existing;
    final created =
        _mediaSessionBridgeOverride ??
        AndroidMediaSessionBridge(isSupported: () => KonataPlatform.isAndroid);
    _mediaSessionBridgeInstance = created;
    _bindAndroidMediaSessionCallbacks();
    return created;
  }

  final Map<String, Uint8List> _posterNotificationBytesCache = {};
  final Set<String> _loadingPosterNotificationKeys = {};
  bool _androidMediaSessionStarted = false;

  /// 暴露媒体会话通信桥实例供集成与单元测试观测。
  AndroidMediaSessionBridge get mediaSessionBridge => _mediaSessionBridge;

  void _ensureRuntimeListenersBound() {
    if (_runtimeListenersBound || !mounted) return;
    _runtimeListenersBound = true;
    _runtimeSubscriptions.add(
      _ref.listen<bool>(videoPlaybackActiveProvider, (_, isVideoActive) {
        if (isVideoActive) {
          unawaited(pauseForVideoSession());
        }
      }),
    );
    _runtimeSubscriptions.add(
      _ref.listen<(bool, bool, bool)>(
        playbackPreferencesProvider.select(
          (p) => (
            p.bitstreamPassthrough,
            p.qualityConfig.exclusiveAudioOutput,
            p.androidBitPerfectUsb,
          ),
        ),
        (_, _) {
          unawaited(
            _safetyCoordinator.reapplyAll(
              _ref.read(playbackPreferencesProvider),
            ),
          );
        },
      ),
    );
    _runtimeSubscriptions.add(
      _ref.listen<AsyncValue<List<WorkLibraryItem>>>(libraryItemsProvider, (
        _,
        next,
      ) {
        final items = next.value;
        if (items != null) {
          syncUpdatedWorks([for (final e in items) e.work]);
        }
      }),
    );
  }

  @override
  set state(AudioPlaybackState value) {
    final prev = stateOrNull;
    final wasActive = prev?.isActive ?? false;
    final positionChanged =
        prev == null ||
        (prev.positionSeconds - value.positionSeconds).abs() > 0.0005;
    super.state = value;
    if (positionChanged &&
        (_positionListenable.value - value.positionSeconds).abs() > 0.0005) {
      _positionListenable.value = value.positionSeconds;
    }
    if (value.isActive || wasActive || _mediaSessionBridgeInstance != null) {
      _syncAndroidMediaSession();
    }
  }

  LibMpvClient? _client;
  StreamSubscription<MpvClientEvent>? _eventSub;
  ({
    int queueIndex,
    String physicalFileKey,
    String target,
    String? streamToken,
    bool mpvPlaylistQueued,
  })?
  _prefetchedNextTrack;
  ({
    int expectedIndex,
    String physicalFileKey,
    String? streamToken,
    int generation,
  })?
  _pendingGaplessAppendTransition;
  Timer? _gaplessAppendFallbackTimer;
  Timer? _lowFreqProgressTimer;
  Timer? _cueBoundaryTimer;
  Timer? _effectiveProgressCheckTimer;
  AudioProgressObservationMode _progressObservationMode =
      AudioProgressObservationMode.highFrequency;
  bool _timePosObserved = true;
  String? _loadedPhysicalKey;
  int _loadGeneration = 0;
  bool _isTransitioningCueBoundary = false;
  int _activeCommandedGeneration = 0;
  int _completedGeneration = -1;
  int _boundNativeInstanceId = 0;
  int _boundPhysicalEpoch = 0;
  int _retiredMpvPlaylistEntryId = 0;
  int _eofHandledMpvEntryId = -1;
  int _trackRetryCount = 0;
  double _trackProgressBaselineSeconds = 0.0;

  double? _pendingSeekRawTargetSeconds;
  DateTime? _pendingSeekGuardUntil;
  DateTime? _lastAudioPersistAt;
  bool _persistInFlight = false;
  DateTime? _suppressBufferingUntil;
  ({AudioQueueItem item, int generation})? _pendingRemoteAuxJob;

  final Map<String, double> _rawDurationByPhysicalKey = {};
  final Map<String, ({AudioCoverSource cover, bool hasDedicatedCover})>
  _albumCoverCache = {};
  final Map<String, List<RemoteEntry>> _siblingsByDirCache = {};
  final Set<String> _checkedEmbeddedCoverPhysicalKeys = {};
  final Map<String, int> _workPosterRevisions = {};
  final Map<String, String> _lastKnownPosterByWorkId = {};

  List<MediaVariant> _sessionAllCdVariants = const [];
  Map<String, MediaSource> _sessionSourcesById = const {};
  final Map<String, AudioQueueItem> _unexpandedMasterByCueId = {};
  final Map<String, List<AudioQueueItem>> _expandedTracksByCueId = {};
  final Set<String> _nonExpandableCueIds = {};

  String _rawCodec = '';
  int? _rawSampleRateHz;
  String _rawAudioFormat = '';
  double _rawFileDurationSeconds = 0.0;
  double? _volumeBeforeDuck;
  bool _mobileAmllLyricConfirmed = false;

  /// 判断文件名是否为受支持的音频物理轨。
  static bool isPlayableAudioFile(String fileName) =>
      CueVariantResolver.isPlayableAudioFile(fileName);

  /// 判断文件名是否为 `.cue` 分轨清单。
  static bool isCueSheetFile(String fileName) =>
      CueVariantResolver.isCueSheetFile(fileName);

  /// 当前生效的发烧音频输出与防炸耳滤镜链计划（源自音视频共享协调器）。
  AudioSafetyChainPlan get activeSafetyPlan => _safetyCoordinator.activePlan;

  /// S 型微淡入斜坡计时器当前是否仍在推进（用于测试验证终态即停钟零空转）。
  bool get isMicroFadeActive => _microFadeDriverInstance?.isActive ?? false;

  /// 当前音频进度订阅与界面更新档位。
  AudioProgressObservationMode get progressObservationMode =>
      _progressObservationMode;

  /// 底层 `libmpv` 当前是否处于 `time-pos` 高频订阅态（退后台/贴边/迷你态为 `false`）。
  bool get isTimePosObserved => _timePosObserved;

  /// 切换音频 `time-pos` 订阅档位：
  /// - `highFrequency`：恢复 `libmpv` 高频属性订阅并即时同步精确秒数；
  /// - `lowFrequency`：退订 `time-pos` 高频 FFI 事件，仅在播控活跃期间以 1 Hz 轻量采样并由单次定时器守卫 CUE 边界；
  /// - `suspended`：彻底退订 `time-pos` 与 1 Hz 定时器（0 次进度唤醒），仅靠单次 CUE 边界定时器守卫无损分轨衔接。
  void setProgressObservationMode(AudioProgressObservationMode mode) {
    if (!mounted || _progressObservationMode == mode) return;
    _progressObservationMode = mode;
    _syncTimePosObservationAndTimers();
  }

  /// 以指定曲目（支持单轨物理音频与 `.cue` 按需动态拆轨）开启 CD 播放队列。
  Future<void> playCdCollection({
    required Work work,
    required List<MediaVariant> cdVariants,
    required MediaVariant initialVariant,
    required Map<String, MediaSource> sourcesById,
    int? initialCueTrackNumber,
    double initialTrackOffsetSeconds = 0.0,
  }) async {
    _ref.read(konataMemoryCoordinatorProvider).cancelPostPlaybackTrim();
    _ensureRuntimeListenersBound();
    final port = _ref.read(playbackPreferencesProvider).foobarBeefwebPort;
    unawaited(
      _ref
          .read(desktopRelayGatewayProvider)
          ?.stopActiveExternalAudioSession(beefwebPort: port),
    );
    final generation = ++_loadGeneration;
    final built = await _buildQueueItems(
      work: work,
      cdVariants: cdVariants,
      initialVariant: initialVariant,
      sourcesById: sourcesById,
      initialCueTrackNumber: initialCueTrackNumber,
    );
    if (generation != _loadGeneration || !mounted) return;
    final items = built.items;
    if (items.isEmpty) {
      _activeCommandedGeneration = 0;
      _loadedPhysicalKey = null;
      state = state.copyWith(
        isActive: true,
        isPlaying: false,
        errorMessage: '未找到可播放的 CD 音频轨道',
      );
      return;
    }

    final previousItem = state.currentItem;
    if (KonataPlatform.isAndroid) {
      unawaited(
        AndroidPlaybackWindowBridge.applyVideoOrientationAndWindow(
          landscape: false,
          hideSystemBars: false,
        ),
      );
    }
    final initialVol = _ref.read(playbackPreferencesProvider).defaultVolume;
    _trackRetryCount = 0;
    _engine.recordManualSelection();
    state = state.copyWith(
      isActive: true,
      queue: items,
      currentIndex: built.targetIndex,
      volume: state.isActive ? state.volume : initialVol,
      clearError: true,
    );

    await _startTrackAtIndex(
      built.targetIndex,
      generation: generation,
      previousItemOverride: previousItem,
      initialTrackOffsetSeconds: initialTrackOffsetSeconds,
    );
  }

  Future<void> _ensureClientInitialized({bool isRemoteStream = false}) async {
    if (_client != null && !_client!.isDisposed && _client!.isInitialized) {
      return;
    }
    final acquired = await _engine.acquireExclusiveNativeClient(
      stage: PlaybackStageKind.audio,
      factoryOverride: clientFactory,
      onEvicted: _evictAudioClientForStageSwitch,
    );
    final client = acquired.client;
    final storageRoot = _ref.read(storageRootProvider);
    unawaited(_ref.read(tempCachePrunerProvider).pruneIfDue());
    final mpvDir = await storageRoot.ensureMpvConfigDir();
    final prefs = _ref.read(playbackPreferencesProvider);

    MpvQualityProfile.applyPreInitAudioOptions(
      client,
      config: prefs.qualityConfig,
      mpvConfigDir: mpvDir,
      isRemoteStream: isRemoteStream,
      desktopDelegate: _ref.read(mpvPlatformProfileDelegateProvider),
      logStore: _logStore,
    );
    client.setOptionString('keep-open', 'no');
    final rc = client.initialize();
    if (rc < 0) {
      await _engine.releaseNativeClient(client);
      throw StateError('纯音频引擎初始化失败: ${client.errorString(rc)}');
    }

    _boundNativeInstanceId = acquired.nativeInstanceId;
    client.setPropertyDouble('volume', state.isMuted ? 0.0 : state.volume);
    client.setPropertyString('keep-open', 'no');
    client.setPropertyString('loop-file', 'no');
    client.setPropertyString('loop-playlist', 'no');
    client.setPropertyFlag('mute', state.isMuted);
    _applySafetyChainToClient(client);
    _safetyCoordinator.attachSession(
      owner: this,
      clientProvider: () => _client,
      prefsProvider: () => _ref.read(playbackPreferencesProvider),
      sampleRateProvider: () => _rawSampleRateHz,
      onTransientMuteAndPause: (_) => _handleAudioDeviceRemovedTransientMute(),
    );

    client.requestLogMessages('warn');
    if (_progressObservationMode ==
        AudioProgressObservationMode.highFrequency) {
      client.observeProperty(_propTimePos, 'time-pos', MpvFormat.double_);
      _timePosObserved = true;
    } else {
      _timePosObserved = false;
    }
    client.observeProperty(_propDuration, 'duration', MpvFormat.double_);
    client.observeProperty(_propPause, 'pause', MpvFormat.flag);
    client.observeProperty(_propCoreIdle, 'core-idle', MpvFormat.flag);
    client.observeProperty(
      _propAudioCodec,
      'audio-codec-name',
      MpvFormat.string,
    );
    client.observeProperty(
      _propSampleRate,
      'audio-params/samplerate',
      MpvFormat.int64,
    );
    client.observeProperty(
      _propAudioFormat,
      'audio-params/format',
      MpvFormat.string,
    );
    client.observeProperty(_propAudioBitrate, 'audio-bitrate', MpvFormat.int64);
    client.observeProperty(_propEofReached, 'eof-reached', MpvFormat.flag);
    if (KonataPlatform.isWindows) {
      client.observeProperty(
        _propAudioDeviceList,
        'audio-device-list',
        MpvFormat.string,
      );
      client.observeProperty(
        _propAudioDevice,
        'audio-device',
        MpvFormat.string,
      );
    }

    _client = client;
    _eventSub = client.events.listen(_handleMpvEvent);
  }

  /// 切换暂停 / 播放状态。
  Future<void> togglePlayPause() => setPlaying(!state.isPlaying);

  Future<void> _ensureAudioFocus() async {
    if (!KonataPlatform.isAndroid) return;
    await _ref
        .read(androidAudioFocusServiceProvider)
        .requestAudioFocus(
          onLoss: () {
            if (!mounted || !state.isActive) return;
            _volumeBeforeDuck = null;
            if (state.isPlaying) {
              unawaited(setPlaying(false));
            }
          },
          onDuck: () {
            if (!mounted || !state.isActive || !state.isPlaying) return;
            _volumeBeforeDuck ??= state.volume;
            final ducked = (_volumeBeforeDuck! * 0.25).clamp(0.0, 100.0);
            _client?.setPropertyDouble('volume', ducked);
          },
          onGain: () {
            if (!mounted || !state.isActive) return;
            final restore = _volumeBeforeDuck;
            _volumeBeforeDuck = null;
            if (restore != null) {
              _client?.setPropertyDouble(
                'volume',
                state.isMuted ? 0.0 : restore,
              );
            }
          },
        );
  }

  /// 显式设置播放状态（若已完播卸载或停在曲末，点击播放自动从头重载起播）。
  Future<void> setPlaying(bool playing) async {
    final wasPlaying = state.isPlaying;
    if (playing) {
      _volumeBeforeDuck = null;
      await _ensureAudioFocus();
      if (state.isActive &&
          state.currentIndex >= 0 &&
          state.currentIndex < state.queue.length) {
        final atTrackEnd =
            state.durationSeconds > 0 &&
            state.positionSeconds >= state.durationSeconds - 0.15;
        if (_loadedPhysicalKey == null || atTrackEnd) {
          final resumeOffset = atTrackEnd ? 0.0 : state.positionSeconds;
          final gen = ++_loadGeneration;
          await _startTrackAtIndex(
            state.currentIndex,
            generation: gen,
            initialTrackOffsetSeconds: resumeOffset,
          );
          return;
        }
      }
    } else {
      _cancelMicroFade();
    }
    final c = _client;
    if (c == null || c.isDisposed) return;
    if (playing) {
      _rebindAudioSessionIfSuperseded(c);
    }
    c.setPropertyFlag('pause', !playing);
    state = state.copyWith(
      isPlaying: playing,
      isBuffering: playing ? state.isBuffering : false,
    );
    if (playing && !wasPlaying) {
      _startMicroFadeInRamp(c);
    }
    _syncAudioBackgroundTimers();
    final item = state.currentItem;
    if (!playing && item != null) {
      unawaited(
        _persistAudioProgress(
          item,
          positionSeconds: state.positionSeconds,
          durationSeconds: state.durationSeconds,
          force: true,
        ),
      );
    }
  }

  /// 当音频会话曾被视频舞台打断暂挂后重新恢复控制权时，通过统一内核原子重绑代数与流租约。
  void _rebindAudioSessionIfSuperseded(LibMpvClient client) {
    final alreadyAuthoritative =
        _engine.activeStage == PlaybackStageKind.audio &&
        identical(_engine.activeNativeClient, client) &&
        _engine.nativeInstanceId == _boundNativeInstanceId &&
        _engine.matchesPhysicalEvent(
          physicalMediaEpoch: _boundPhysicalEpoch,
          nativeInstanceId: _boundNativeInstanceId,
        );
    if (alreadyAuthoritative) return;
    _boundPhysicalEpoch = _engine.resumeOrRebindStage(
      PlaybackStageKind.audio,
      nativeInstanceId: _boundNativeInstanceId,
      client: client,
      fallbackPrefetchStreamLeaseToken: _prefetchedNextTrack?.streamToken,
    );
    _applySafetyChainToClient(client);
    _logStore.record(
      'AUDIO',
      '音频会话重获控制权并完成统一内核原子重绑：epoch=$_boundPhysicalEpoch instance=$_boundNativeInstanceId entry=${_engine.currentPlaylistEntryId} trackEpoch=${_engine.logicalTrackEpoch}',
    );
  }

  /// 当视频舞台互斥接管全局唯一底层句柄时，保存音频进度并安全释放本舞台持有的原生句柄。
  ///
  /// 队列、当前曲目与精确播放偏移均保留在内存状态中；待视频关闭后重新点击播放时自动
  /// 经 `UnifiedPlaybackEngine` 重新申请唯一句柄并从断点无缝续播。
  Future<void> _evictAudioClientForStageSwitch() async {
    _cancelMicroFade();
    _cancelAudioBackgroundTimers();
    _clearPendingGaplessAppendTransition();
    final item = state.currentItem;
    final savedPos = state.positionSeconds;
    final savedDur = state.durationSeconds;
    await _eventSub?.cancel();
    _eventSub = null;
    final c = _client;
    _client = null;
    _loadedPhysicalKey = null;
    if (c != null && !c.isDisposed) {
      await c.dispose();
    }
    if (mounted && state.isActive && (state.isPlaying || state.isBuffering)) {
      state = state.copyWith(isPlaying: false, isBuffering: false);
    }
    if (item != null) {
      unawaited(
        _persistAudioProgress(
          item,
          positionSeconds: savedPos,
          durationSeconds: savedDur,
          force: true,
        ),
      );
    }
  }

  /// 视频播放启动时自动暂停当前音乐（暂挂统一内核快照并释放唯一原生句柄交由视频舞台接管）。
  Future<void> pauseForVideoSession() async {
    if (!state.isActive) return;
    _engine.suspendStage(PlaybackStageKind.audio);
    final c = _client;
    if (c != null) {
      await _evictAudioClientForStageSwitch();
      await _engine.releaseNativeClient(c);
    } else if (state.isPlaying) {
      await setPlaying(false);
    }
  }

  /// 在当前曲目（已自动叠加 `.cue` 起点偏移）内精确 Seek。
  Future<void> seekRelativeTrackSeconds(double trackSeconds) async {
    final item = state.currentItem;
    final c = _client;
    if (item == null || c == null || c.isDisposed) return;
    _rebindAudioSessionIfSuperseded(c);
    _isTransitioningCueBoundary = false;

    final clamped = state.durationSeconds > 0
        ? trackSeconds.clamp(0.0, state.durationSeconds)
        : math.max(0.0, trackSeconds);

    if (_loadedPhysicalKey == null &&
        state.currentIndex >= 0 &&
        state.currentIndex < state.queue.length) {
      final gen = ++_loadGeneration;
      await _startTrackAtIndex(
        state.currentIndex,
        generation: gen,
        initialTrackOffsetSeconds: clamped,
      );
      return;
    }

    if (_completedGeneration == _activeCommandedGeneration &&
        (state.durationSeconds <= 0 ||
            clamped < state.durationSeconds - 0.15)) {
      _completedGeneration = -1;
    }
    final rawTarget = (item.cueStartSeconds ?? 0.0) + clamped;
    final ranges = c.readDemuxerSeekableRanges();
    final cachedHit = MpvSeekableRange.isPositionCached(rawTarget, ranges);
    if (cachedHit) {
      _suppressBufferingUntil = DateTime.now().add(
        const Duration(milliseconds: 900),
      );
    } else {
      _suppressBufferingUntil = null;
    }
    _pendingSeekRawTargetSeconds = rawTarget;
    _pendingSeekGuardUntil = DateTime.now().add(_cueSeekDebounceWindow);
    c.commandAsync(0, ['seek', rawTarget.toStringAsFixed(3), 'absolute', 'exact']);
    if (state.isPlaying) {
      _startMicroFadeInRamp(c);
    }
    final lyricIdx = state.lrcDocument?.activeIndexAt(clamped) ?? -1;
    state = state.copyWith(
      positionSeconds: clamped,
      activeLyricIndex: lyricIdx,
      isBuffering: cachedHit ? false : state.isBuffering,
    );
    _syncAudioBackgroundTimers();
    _syncAndroidMediaSession(forcePositionSync: true);
    unawaited(
      _persistAudioProgress(
        item,
        positionSeconds: clamped,
        durationSeconds: state.durationSeconds,
        force: true,
      ),
    );
  }

  /// 切换上一首。
  Future<void> previous() async {
    if (state.queue.isEmpty) return;
    _engine.recordManualSelection();
    if (state.positionSeconds > 4.0) {
      await seekRelativeTrackSeconds(0.0);
      return;
    }
    final target = state.currentIndex > 0
        ? state.currentIndex - 1
        : state.queue.length - 1;
    final gen = ++_loadGeneration;
    await _startTrackAtIndex(
      target,
      generation: gen,
      selectLastOnCueExpand: true,
    );
  }

  /// 切换下一首。
  Future<void> next() async {
    if (state.queue.isEmpty) return;
    _engine.recordManualSelection();
    final target = (state.currentIndex + 1) % state.queue.length;
    final gen = ++_loadGeneration;
    await _startTrackAtIndex(target, generation: gen);
  }

  /// 跳转队列中指定索引曲目。
  Future<void> playQueueIndex(int index) async {
    if (index < 0 || index >= state.queue.length) return;
    _engine.recordManualSelection();
    final gen = ++_loadGeneration;
    await _startTrackAtIndex(index, generation: gen);
  }

  /// 调整音量（0 ~ 100）。
  void setVolume(double volume) {
    _cancelMicroFade();
    final clamped = volume.clamp(0.0, 100.0);
    _client?.setPropertyDouble('volume', clamped);
    if (clamped > 0 && state.isMuted) {
      _client?.setPropertyFlag('mute', false);
      state = state.copyWith(volume: clamped, isMuted: false);
    } else {
      state = state.copyWith(volume: clamped);
    }
    unawaited(
      _ref.read(playbackPreferencesProvider.notifier).setDefaultVolume(clamped),
    );
  }

  /// 切换静音。
  void toggleMute() {
    _cancelMicroFade();
    final nextMuted = !state.isMuted;
    _client?.setPropertyFlag('mute', nextMuted);
    state = state.copyWith(isMuted: nextMuted);
  }

  /// 循环切换单曲/列表/顺序播放模式。
  void cycleLoopMode() {
    final nextMode = state.loopMode.nextMode();
    state = state.copyWith(loopMode: nextMode);
    if (nextMode == AudioLoopMode.loopOne) {
      _clearMpvAppendedPlaylist();
      unawaited(_releasePrefetchLeaseIfAny());
    } else {
      unawaited(_scheduleGaplessNextTrackPrefetch(generation: _loadGeneration));
    }
  }

  /// 手动关闭当前音频错误提示横幅。
  void dismissError() {
    if (state.errorMessage != null) {
      state = state.copyWith(clearError: true);
    }
  }

  /// 停止音频播放、释放主流与预取流并关闭迷你栏与沉浸页。
  Future<void> stopAndClose() async {
    _cancelMicroFade();
    _cancelAudioBackgroundTimers();
    _clearPendingGaplessAppendTransition();
    final closingItem = state.currentItem;
    final closingPos = state.positionSeconds;
    final closingDur = state.durationSeconds;
    ++_loadGeneration;
    _activeCommandedGeneration = 0;
    _completedGeneration = -1;
    final currentEntry = _engineInstance?.currentPlaylistEntryId ?? 0;
    if (currentEntry > _retiredMpvPlaylistEntryId) {
      _retiredMpvPlaylistEntryId = currentEntry;
    }
    _trackRetryCount = 0;
    _engineInstance?.recordManualSelection();
    _loadedPhysicalKey = null;
    _isTransitioningCueBoundary = false;

    _pendingSeekRawTargetSeconds = null;
    _pendingSeekGuardUntil = null;
    _pendingRemoteAuxJob = null;
    _sessionAllCdVariants = const [];
    _sessionSourcesById = const {};
    _unexpandedMasterByCueId.clear();
    _expandedTracksByCueId.clear();
    _nonExpandableCueIds.clear();
    if (closingItem != null) {
      await _persistAudioProgress(
        closingItem,
        positionSeconds: closingPos,
        durationSeconds: closingDur,
        force: true,
      );
    }
    await _eventSub?.cancel();
    _eventSub = null;
    final c = _client;
    _client = null;
    if (c != null && !c.isDisposed) {
      MpvQualityProfile.resetAudioRangeAndLoopProperties(
        c,
        logStore: _logStore,
      );
      c.command(['stop']);
      await _engine.releaseNativeClient(c);
    }
    _volumeBeforeDuck = null;
    await _mediaSessionBridge.stopSession();
    await _ref.read(androidAudioFocusServiceProvider).abandonAudioFocus();
    await _releaseActiveStreamSession();
    _ref.read(immersiveAudioExpandedProvider.notifier).state = false;
    if (mounted) {
      state = const AudioPlaybackState();
    }
    _ref.read(konataMemoryCoordinatorProvider).schedulePostPlaybackTrim();
  }

  /// 根据当前播放偏好与平台实时重编译并向全端共享协调器应用音频输出安全链路。
  Future<void> reapplyAudiophileSafetyChain() async {
    final prefs = _ref.read(playbackPreferencesProvider);
    await _safetyCoordinator.reapplyAll(prefs);
  }

  void _applySafetyChainToClient(LibMpvClient client) {
    _safetyCoordinator.applyToClient(
      client,
      prefs: _ref.read(playbackPreferencesProvider),
      preferredSampleRateHz: _rawSampleRateHz,
    );
  }

  void _cancelMicroFade() => _microFadeDriverInstance?.cancel();

  void _startMicroFadeInRamp(LibMpvClient client) {
    _microFadeDriver.start(
      client: client,
      plan: _safetyCoordinator.activePlan,
      targetVolume: state.volume,
      isMuted: state.isMuted,
      isAlive: () => mounted && !state.isMuted && state.isPlaying,
    );
  }

  void _handleAudioDeviceRemovedTransientMute() {
    _cancelMicroFade();
    _cancelAudioBackgroundTimers();
    if (mounted) {
      state = state.copyWith(isPlaying: false, isMuted: true);
    }
  }

  int? _resolveNextSequentialIndex() {
    if (state.loopMode == AudioLoopMode.loopOne || state.queue.isEmpty) {
      return null;
    }
    final nextIdx = state.currentIndex + 1;
    if (nextIdx < state.queue.length) return nextIdx;
    if (state.loopMode == AudioLoopMode.loopAll) return 0;
    return null;
  }

  /// 收到 `libmpv` 原生无缝续播的 `MpvStartFileEvent` 时原地晋升预取租约与队列状态（0 ms 硬件切换）。
  void _completeGaplessAppendPromotion(
    ({
      int expectedIndex,
      String physicalFileKey,
      String? streamToken,
      int generation,
    })
    pending, {
    required int playlistEntryId,
  }) {
    _clearPendingGaplessAppendTransition();
    if (!mounted ||
        !state.isActive ||
        pending.expectedIndex < 0 ||
        pending.expectedIndex >= state.queue.length) {
      return;
    }
    final previousItem = state.currentItem;
    final nextItem = state.queue[pending.expectedIndex];
    final previousEntry = _engine.currentPlaylistEntryId ?? 0;
    if (previousEntry > _retiredMpvPlaylistEntryId) {
      _retiredMpvPlaylistEntryId = previousEntry;
    }
    final previousMainToken = _engine.mainStreamLease?.leaseToken;
    String? displacedMainToken;
    if (pending.streamToken != null) {
      displacedMainToken = _engine.promotePrefetchLeaseToMain(
        playlistEntryId: playlistEntryId,
      );
    } else {
      _engine.beginPhysicalMedia(
        nativeInstanceId: _boundNativeInstanceId,
        stage: PlaybackStageKind.audio,
      );
      _engine.bindPlaylistEntryId(playlistEntryId);
      displacedMainToken = previousMainToken;
    }
    _boundPhysicalEpoch = _engine.physicalMediaEpoch;
    if (displacedMainToken != null &&
        displacedMainToken != pending.streamToken) {
      unawaited(_unregisterStreamToken(displacedMainToken));
    }

    final nextGen = ++_loadGeneration;
    _activeCommandedGeneration = nextGen;
    _loadedPhysicalKey = pending.physicalFileKey;
    _trackProgressBaselineSeconds = 0.0;
    final cachedRawDuration =
        _rawDurationByPhysicalKey[pending.physicalFileKey] ?? 0.0;
    _rawFileDurationSeconds = cachedRawDuration;
    final initialDuration = _resolveTrackDurationSeconds(
      nextItem,
      cachedRawDuration,
    );
    final initialCover = _resolveInitialCoverForTrack(
      nextItem,
      previousItem: previousItem,
    );
    state = state.copyWith(
      currentIndex: pending.expectedIndex,
      positionSeconds: 0.0,
      durationSeconds: initialDuration,
      isPlaying: true,
      isBuffering: false,
      cover: initialCover,
      activeLyricIndex: -1,
      clearLrcDocument: true,
      clearError: true,
    );
    if (initialCover is EmptyAudioCover && nextItem.source != null) {
      unawaited(_hydrateAlbumCoverFromDisk(nextItem, generation: nextGen));
    }
    unawaited(
      _persistAudioProgress(
        nextItem,
        positionSeconds: 0.0,
        durationSeconds: initialDuration,
        force: true,
      ),
    );
    final isRemote =
        nextItem.source != null && nextItem.source!.kind != MediaSourceKind.local;
    if (!isRemote || Platform.environment.containsKey('FLUTTER_TEST')) {
      unawaited(_loadAuxiliaryAssets(nextItem, generation: nextGen));
    } else {
      _pendingRemoteAuxJob = (item: nextItem, generation: nextGen);
    }
    _syncAudioBackgroundTimers();
  }

  /// 按当前 [_progressObservationMode] 同步 `libmpv` `time-pos` 属性订阅与轻量后台定时器。
  void _syncTimePosObservationAndTimers() {
    final client = _client;
    final wantNativeTimePos =
        _progressObservationMode == AudioProgressObservationMode.highFrequency;
    if (client != null && !client.isDisposed && client.isInitialized) {
      if (wantNativeTimePos && !_timePosObserved) {
        client.observeProperty(_propTimePos, 'time-pos', MpvFormat.double_);
        _timePosObserved = true;
        final latest = client.getPropertyDouble('time-pos');
        if (latest != null && latest.isFinite) {
          _updateTrackProgress(latest);
        }
      } else if (!wantNativeTimePos && _timePosObserved) {
        if (client is LibMpvUnobservable) {
          (client as LibMpvUnobservable).unobserveProperty(_propTimePos);
        }
        _timePosObserved = false;
      }
    } else {
      _timePosObserved = wantNativeTimePos;
    }
    _syncAudioBackgroundTimers();
  }

  void _cancelAudioBackgroundTimers() {
    _lowFreqProgressTimer?.cancel();
    _lowFreqProgressTimer = null;
    _cueBoundaryTimer?.cancel();
    _cueBoundaryTimer = null;
    _effectiveProgressCheckTimer?.cancel();
    _effectiveProgressCheckTimer = null;
  }

  /// 同步低频 1 Hz 迷你进度采样器与单次 CUE 边界守卫定时器（非播放或高频模式下全部停钟）。
  void _syncAudioBackgroundTimers() {
    _lowFreqProgressTimer?.cancel();
    _lowFreqProgressTimer = null;
    _cueBoundaryTimer?.cancel();
    _cueBoundaryTimer = null;

    if (!mounted || !state.isActive || !state.isPlaying) {
      return;
    }
    final client = _client;
    if (client == null || client.isDisposed || !client.isInitialized) {
      return;
    }

    if (_progressObservationMode == AudioProgressObservationMode.lowFrequency) {
      _lowFreqProgressTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted || !state.isActive || !state.isPlaying) {
          _lowFreqProgressTimer?.cancel();
          _lowFreqProgressTimer = null;
          return;
        }
        final c = _client;
        if (c == null || c.isDisposed) return;
        final rawPos = c.getPropertyDouble('time-pos');
        if (rawPos != null && rawPos.isFinite) {
          _updateTrackProgress(rawPos);
        }
      });
    }

    if (_progressObservationMode !=
        AudioProgressObservationMode.highFrequency) {
      _scheduleCueBoundaryTimer();
    }
  }

  void _scheduleCueBoundaryTimer() {
    _cueBoundaryTimer?.cancel();
    _cueBoundaryTimer = null;
    final item = state.currentItem;
    final cueEnd = item?.cueEndSeconds;
    final client = _client;
    if (item == null ||
        cueEnd == null ||
        !state.isPlaying ||
        client == null ||
        client.isDisposed) {
      return;
    }
    final currentRaw =
        client.getPropertyDouble('time-pos') ??
        ((item.cueStartSeconds ?? 0.0) + state.positionSeconds);
    final remainingSec = cueEnd - currentRaw;
    final delayMs = remainingSec <= 0.05
        ? 50
        : (remainingSec * 1000).round().clamp(50, 86400000);
    _cueBoundaryTimer = Timer(Duration(milliseconds: delayMs), () {
      _cueBoundaryTimer = null;
      if (!mounted || !state.isActive || !state.isPlaying) return;
      final c = _client;
      if (c == null || c.isDisposed) return;
      final latestRaw = c.getPropertyDouble('time-pos');
      if (latestRaw != null && latestRaw.isFinite) {
        _updateTrackProgress(latestRaw);
      }
      if (mounted &&
          state.isPlaying &&
          _progressObservationMode !=
              AudioProgressObservationMode.highFrequency) {
        _scheduleCueBoundaryTimer();
      }
    });
  }

  void _scheduleEffectiveProgressCheckIfNeeded() {
    _effectiveProgressCheckTimer?.cancel();
    _effectiveProgressCheckTimer = null;
    if (_progressObservationMode ==
            AudioProgressObservationMode.highFrequency ||
        _engine.effectiveProgressConfirmed) {
      return;
    }
    _effectiveProgressCheckTimer = Timer(
      const Duration(milliseconds: 650),
      () {
        _effectiveProgressCheckTimer = null;
        if (!mounted || !state.isActive || !state.isPlaying) return;
        final c = _client;
        final item = state.currentItem;
        if (c == null || c.isDisposed || item == null) return;
        final rawPos = c.getPropertyDouble('time-pos');
        if (rawPos == null || !rawPos.isFinite) return;
        final relPos = math.max(0.0, rawPos - (item.cueStartSeconds ?? 0.0));
        final advancedMs = ((relPos - _trackProgressBaselineSeconds) * 1000)
            .round();
        if (_engine.fileLoadedInCurrentEpoch &&
            !_engine.effectiveProgressConfirmed &&
            advancedMs >=
                UnifiedPlaybackEngine.effectiveAudioProgressThresholdMs) {
          _engine.recordEffectiveProgress(audioAdvancedMs: advancedMs);
        }
      },
    );
  }

  void _disposeResources() {
    ++_loadGeneration;
    _cancelMicroFade();
    _cancelAudioBackgroundTimers();
    _clearPendingGaplessAppendTransition();
    for (final sub in _runtimeSubscriptions) {
      sub.close();
    }
    _runtimeSubscriptions.clear();
    _engineInstance?.cancelTaskDomain(PlaybackTaskDomain.lyricLookup);
    _safetyCoordinatorInstance?.detachSession(this);
    final mediaBridge = _mediaSessionBridgeInstance;
    if (mediaBridge != null) {
      unawaited(mediaBridge.stopSession());
      mediaBridge.dispose();
    }
    unawaited(_eventSub?.cancel());
    _eventSub = null;
    final hasTrackedLease =
        _engineInstance?.mainStreamLease != null ||
        _engineInstance?.prefetchStreamLease != null ||
        _prefetchedNextTrack != null;
    if (hasTrackedLease) {
      unawaited(_releaseActiveStreamSession());
    }
    final c = _client;
    _client = null;
    if (c != null && !c.isDisposed) {
      final eng = _engineInstance;
      if (eng != null) {
        unawaited(eng.releaseNativeClient(c));
      } else {
        unawaited(c.dispose());
      }
    }
    _positionListenable.dispose();
  }
}

/// 全局持久 CD 纯音频播放器 Provider（静息冷启动零偏好/数据库/音频通道提前装配）。
final audioPlaybackProvider =
    NotifierProvider<AudioPlaybackNotifier, AudioPlaybackState>(
      AudioPlaybackNotifier.new,
    );
