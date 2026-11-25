import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:engine_playback/engine_playback.dart';
import 'package:engine_sources/engine_sources.dart';
import 'package:flutter/foundation.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';
import 'package:path/path.dart' as p;

import '../data/data.dart';

part 'audio_playback_controller_events.dart';
part 'audio_playback_controller_safety.dart';
part 'audio_playback_controller_telemetry.dart';
part 'audio_playback_controller_transport.dart';

/// 音频播放核心状态控制器（零状态框架耦合）。
///
/// 统一托管 `UnifiedPlaybackEngine` 四维代数隔离、`-12 dBFS` 发烧安全链路协调、
/// 普通音轨与 `.cue` 动态分轨播放调度、叶子 `ValueNotifier` 高频时钟，以及
/// 严格低频按需同步的 `LyricDisplayPort` 歌词端口协同。
class AudioPlaybackController extends ChangeNotifier {
  /// 构造音频播放控制器。
  AudioPlaybackController({
    required this._preferences,
    required this._assets,
    required this._engine,
    required this._safetyCoordinator,
    required this._gatewayFactory,
    required this._streamBridge,
    this._windowPort = const NoopPlaybackHostWindowPort(),
    this._lyricPort,
    KonataDatabaseBundle? database,
    PlaybackRecordDao? playbackRecordDao,
    this._photosStorage,
    this._artworkCacheStore,
    this._storageRoot,
    this._desktopRelayGateway,
    this._desktopMpvDelegate,
    this._androidMediaSessionPort,
    this._logPort,
    this._mpvClientFactoryOverride,
    this._isWindowsOverride,
  }) : _playbackRecordDao =
           playbackRecordDao ?? database?.userState.playbackRecords {
    final prefs = _preferences.read();
    final initialPlan = _safetyCoordinator.compilePlan(
      _effectiveAudiophilePrefs(prefs),
      upstreamDspFilters: _buildUpstreamDspFilters(prefs),
    );
    _snapshotNotifier.value = AudioPlaybackSnapshot(
      volume: prefs.defaultVolume,
      isMuted: prefs.isMuted,
      loopMode: prefs.loopMode,
      shuffleEnabled: prefs.shuffleEnabled,
      audiophileSafetyState: _safetyCoordinator.deviceSafetyState,
      audiophilePlan: initialPlan,
    );
    _safetyCoordinator.attachSession(
      owner: this,
      clientProvider: () => _client,
      prefsProvider: () => _effectiveAudiophilePrefs(_preferences.read()),
      onTransientMuteAndPause: _handleSafetyCoordinatorTransientMute,
      sampleRateProvider: () {
        final sr = _snapshotNotifier.value.sampleRateHz;
        return sr > 0 ? sr : null;
      },
      onPlanApplied: (plan) {
        _updateSnapshot(
          _snapshotNotifier.value.copyWith(
            audiophileSafetyState: _safetyCoordinator.deviceSafetyState,
            audiophilePlan: plan,
          ),
        );
      },
    );
    _bindAndroidMediaSessionCallbacks();
    if (_lyricPort != null) {
      _positionNotifier.addListener(_syncLyricsClock);
      _playingNotifier.addListener(_syncLyricsClock);
      _syncLyricsClock();
    }
  }

  void _syncLyricsClock() {
    if (_disposed) return;
    _lyricPort?.updatePlaybackPosition(
      _positionNotifier.value,
      isPlaying: _playingNotifier.value,
    );
  }

  final AudioPlaybackPreferences _preferences;
  final AudioPlaybackAssets _assets;
  final UnifiedPlaybackEngine _engine;
  final AudiophileSafetyCoordinator _safetyCoordinator;
  final MediaSourceGatewayFactoryPort _gatewayFactory;
  final LocalStreamBridgePort _streamBridge;
  final PlaybackHostWindowPort _windowPort;
  final LyricDisplayPort? _lyricPort;
  final PlaybackRecordDao? _playbackRecordDao;
  final PhotosStorage? _photosStorage;
  final ArtworkCacheStore? _artworkCacheStore;
  final StorageRootPort? _storageRoot;
  final DesktopRelayGateway? _desktopRelayGateway;
  final MpvPlatformProfileDelegate? _desktopMpvDelegate;
  final AndroidMediaSessionPort? _androidMediaSessionPort;
  final DiagnosticLogPort? _logPort;
  final LibMpvClient Function()? _mpvClientFactoryOverride;
  final bool? _isWindowsOverride;

  final AudiophileMicroFadeDriver _microFadeDriver =
      AudiophileMicroFadeDriver();

  final ValueNotifier<Duration> _positionNotifier = ValueNotifier(
    Duration.zero,
  );
  final ValueNotifier<Duration> _durationNotifier = ValueNotifier(
    Duration.zero,
  );
  final ValueNotifier<bool> _playingNotifier = ValueNotifier(false);
  final ValueNotifier<bool> _activeNotifier = ValueNotifier(false);
  final ValueNotifier<AudioPlaybackSnapshot> _snapshotNotifier = ValueNotifier(
    const AudioPlaybackSnapshot(),
  );

  WorkRecord? _activeWork;
  LibMpvClient? _client;
  StreamSubscription<MpvClientEvent>? _clientEventSub;
  int _clientNativeInstanceId = 0;

  bool _disposed = false;
  bool _timePosObserved = false;
  bool _progressObservationHidden = false;
  int? _timePosObserveId;
  int _nextObserveId = 10;
  int _mediaOpenSeq = 0;

  double _rawDurationSeconds = 0.0;
  double _lastConfirmedAudioPosSeconds = 0.0;
  DateTime? _lastHistoryPersistAt;
  DateTime? _lastMediaSessionSyncAt;

  Timer? _cueBoundaryTimer;
  String? _prefetchedItemId;
  String? _prefetchedStreamToken;
  int? _expectedAppendPlaylistEntryId;

  /// 叶子当前逻辑曲目播放位置监听源（高频更新仅局部重绘，不触发整页重建）。
  ValueListenable<Duration> get positionListenable => _positionNotifier;

  /// 叶子当前逻辑曲目总时长监听源。
  ValueListenable<Duration> get durationListenable => _durationNotifier;

  /// 叶子当前播放/暂停布尔态监听源。
  ValueListenable<bool> get playingListenable => _playingNotifier;

  /// 叶子音频会话是否激活的布尔监听源。
  ValueListenable<bool> get activeListenable => _activeNotifier;

  /// 低频不可变会话状态快照监听源。
  ValueListenable<AudioPlaybackSnapshot> get snapshotListenable =>
      _snapshotNotifier;

  /// 当前低频快照只读视图。
  AudioPlaybackSnapshot get snapshot => _snapshotNotifier.value;

  /// 当前位置秒数（便于精确运算与测试断言）。
  double get currentTrackPositionSeconds =>
      _positionNotifier.value.inMilliseconds / 1000.0;

  /// 当前总时长秒数。
  double get currentTrackDurationSeconds =>
      _durationNotifier.value.inMilliseconds / 1000.0;

  /// 控制高频进度观察是否因舞台与悬浮小窗均不可见而静默暂停。
  void setProgressObservationHidden(bool hidden) {
    if (_progressObservationHidden == hidden) return;
    _progressObservationHidden = hidden;
    _reconcileClockObservation();
  }

  /// 启动整张专辑/CD 变体集合的沉浸式播放会话。
  Future<void> playCdCollection({
    required WorkRecord work,
    required List<MediaVariantRecord> variants,
    required List<MediaSourceView> sources,
    MediaVariantRecord? initialVariant,
    int? initialCueTrackIndex,
    String? activeAlbumKey,
    double? startPositionSeconds,
  }) async {
    if (_disposed) return;
    _activeWork = work;
    _mediaOpenSeq++;
    _clearPrefetchTracking(releaseBridge: true);

    final sourceById = <String, MediaSourceView>{
      for (final s in sources) s.id.value: s,
    };

    CueSheet? initialCueSheet;
    if (initialVariant != null &&
        p.extension(initialVariant.fileName).toLowerCase() == '.cue') {
      final source = sourceById[initialVariant.sourceId.value];
      if (source != null) {
        try {
          initialCueSheet = await _assets.loadCueSheet(
            source: source,
            cueRelativePath: initialVariant.relativePath,
            gatewayFactory: _gatewayFactory,
            knownFileSize: initialVariant.fileSize,
          );
        } catch (error, stackTrace) {
          _recordError(
            code: 'AUDIO_CUE_INITIAL_LOAD_FAIL',
            message: '初始 .cue 分轨清单解析失败',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }
    }

    final builtQueue = AudioPlaybackQueueBuilder.buildInitialQueue(
      work: work,
      variants: variants,
      sourceById: sourceById,
      initialVariant: initialVariant,
      initialCueSheet: initialCueSheet,
      initialCueTrackIndex: initialCueTrackIndex,
      activeAlbumKey: activeAlbumKey,
    );

    if (builtQueue.isEmpty) {
      _updateSnapshot(
        _snapshotNotifier.value.copyWith(
          status: AudioPlaybackStatus.error,
          isActive: false,
          queue: const [],
          currentIndex: -1,
          errorMessage: '未找到可播放的 CD 音轨资源',
        ),
      );
      _activeNotifier.value = false;
      _playingNotifier.value = false;
      _clearLyrics();
      return;
    }

    var targetIndex = AudioPlaybackQueueBuilder.resolveTargetQueueIndex(
      queue: builtQueue,
      initialVariant: initialVariant,
      initialCueTrackIndex: initialCueTrackIndex,
    );
    if (targetIndex < 0) targetIndex = 0;

    final prefs = _preferences.read();
    final playOrder = AudioPlaybackQueueBuilder.buildPlayOrder(
      length: builtQueue.length,
      currentIndex: targetIndex,
      shuffle: prefs.shuffleEnabled,
    );
    final playOrderPos = playOrder.indexOf(targetIndex);

    final expandedCues = <String>{
      for (final item in builtQueue)
        if (item.isCueTrack && item.cueSheetPath != null)
          AudioPlaybackQueueBuilder.normalizeQueuePath(
            item.cueSheetPath!,
          ).toLowerCase(),
    };

    _activeNotifier.value = true;
    _updateSnapshot(
      _snapshotNotifier.value.copyWith(
        status: AudioPlaybackStatus.loading,
        isActive: true,
        isBuffering: true,
        queue: builtQueue,
        currentIndex: targetIndex,
        playOrder: playOrder,
        playOrderPos: playOrderPos,
        loopMode: prefs.loopMode,
        shuffleEnabled: prefs.shuffleEnabled,
        volume: prefs.defaultVolume,
        isMuted: prefs.isMuted,
        expandedCuePaths: expandedCues,
        clearErrorMessage: true,
      ),
    );

    await playQueueIndex(
      targetIndex,
      initialTrackSeconds: startPositionSeconds,
      manualSelection: true,
    );
  }

  /// 切换到指定队列下标播放，按需自动展开 `.cue` 清单或同流分轨无感快进。
  Future<void> playQueueIndex(
    int index, {
    double? initialTrackSeconds,
    bool manualSelection = true,
  }) async {
    await _playQueueIndexInternal(
      index,
      initialTrackSeconds: initialTrackSeconds,
      manualSelection: manualSelection,
    );
  }

  /// 显式切换播放或暂停态，暂停时自动取消 150 ms 微淡入并挂起时钟监听。
  Future<void> setPlaying(bool playing) async {
    if (_disposed || !_activeNotifier.value) return;
    final client = _client;
    if (client == null || client.isDisposed || !client.isInitialized) return;

    if (playing) {
      final prefs = _preferences.read();
      final plan = _safetyCoordinator.compilePlan(
        _effectiveAudiophilePrefs(prefs),
        upstreamDspFilters: _buildUpstreamDspFilters(prefs),
      );
      _updateSnapshot(
        _snapshotNotifier.value.copyWith(
          status: AudioPlaybackStatus.playing,
          audiophilePlan: plan,
          audiophileSafetyState: _safetyCoordinator.deviceSafetyState,
          clearErrorMessage: true,
        ),
      );
      client.setPropertyFlag('pause', false);
      _playingNotifier.value = true;
      _applyVolumeWithSafetyFade(
        client: client,
        plan: plan,
        useMicroFade: true,
      );
    } else {
      _microFadeDriver.cancel();
      client.setPropertyFlag('pause', true);
      _playingNotifier.value = false;
      _updateSnapshot(
        _snapshotNotifier.value.copyWith(status: AudioPlaybackStatus.paused),
      );
      unawaited(_persistPlaybackHistory(force: true));
    }
    _reconcileClockObservation();
    _syncAndroidMediaSession(forcePosition: true);
  }

  /// 切换播放与暂停。
  Future<void> togglePlayPause() => setPlaying(!_playingNotifier.value);

  /// 播放逻辑顺序中的下一首。
  Future<void> next({bool manual = true}) async {
    final snap = _snapshotNotifier.value;
    if (snap.queue.isEmpty) return;

    final nextPos = _resolveNextPlayOrderPos(manual: manual);
    if (nextPos == null) {
      await setPlaying(false);
      return;
    }
    final nextQueueIndex = snap.playOrder[nextPos];
    _updateSnapshot(snap.copyWith(playOrderPos: nextPos));
    await playQueueIndex(nextQueueIndex, manualSelection: manual);
  }

  /// 播放逻辑顺序中的上一首（曲内已播超过 3 秒时优先回零重听当前曲目）。
  Future<void> previous() async {
    final snap = _snapshotNotifier.value;
    if (snap.queue.isEmpty) return;

    if (currentTrackPositionSeconds > 3.0) {
      await seekRelativeTrackSeconds(0.0);
      return;
    }
    final prevPos = _resolvePreviousPlayOrderPos();
    if (prevPos == null) {
      await seekRelativeTrackSeconds(0.0);
      return;
    }
    final prevQueueIndex = snap.playOrder[prevPos];
    _updateSnapshot(snap.copyWith(playOrderPos: prevPos));
    await playQueueIndex(prevQueueIndex, manualSelection: true);
  }

  /// 在当前逻辑曲目相对坐标（`0 ~ duration`）内精确跳转，并同步防爆耳微淡入。
  Future<void> seekRelativeTrackSeconds(double trackSeconds) async {
    if (_disposed) return;
    final snap = _snapshotNotifier.value;
    final item = snap.currentItem;
    final client = _client;
    if (item == null ||
        client == null ||
        client.isDisposed ||
        !client.isInitialized) {
      return;
    }

    final trackDur = currentTrackDurationSeconds > 0
        ? currentTrackDurationSeconds
        : item.durationSeconds;
    final clampedRel = trackDur > 0
        ? trackSeconds.clamp(0.0, trackDur)
        : math.max(0.0, trackSeconds);
    final absPos = item.startSeconds + clampedRel;

    _microFadeDriver.cancel();
    final prefs = _preferences.read();
    final plan = _safetyCoordinator.compilePlan(
      _effectiveAudiophilePrefs(prefs),
      upstreamDspFilters: _buildUpstreamDspFilters(prefs),
    );
    if (_playingNotifier.value &&
        !plan.safetyLimiterEngaged &&
        plan.microFadeInDurationMs > 0) {
      client.setPropertyDouble('volume', 0.0);
    }

    client.command(<String>['seek', absPos.toStringAsFixed(3), 'absolute']);
    _positionNotifier.value = Duration(
      milliseconds: (clampedRel * 1000.0).round(),
    );
    if (_playingNotifier.value) {
      _applyVolumeWithSafetyFade(
        client: client,
        plan: plan,
        useMicroFade: true,
      );
    }
    unawaited(_persistPlaybackHistory(force: true));
    _syncAndroidMediaSession(forcePosition: true);
  }

  /// 按 `Duration` 在当前逻辑曲目内定位。
  Future<void> seekToTrackPosition(Duration position) =>
      seekRelativeTrackSeconds(position.inMilliseconds / 1000.0);

  /// 依次切换循环模式：`sequence -> loopAll -> loopOne -> sequence`。
  void cycleLoopMode() {
    final nextMode = switch (_snapshotNotifier.value.loopMode) {
      AudioLoopMode.sequence => AudioLoopMode.loopAll,
      AudioLoopMode.loopAll => AudioLoopMode.loopOne,
      AudioLoopMode.loopOne => AudioLoopMode.sequence,
    };
    setLoopMode(nextMode);
  }

  /// 显式设置循环模式并持久化到 `playback_audio`。
  void setLoopMode(AudioLoopMode mode) {
    if (_snapshotNotifier.value.loopMode == mode) return;
    _updateSnapshot(_snapshotNotifier.value.copyWith(loopMode: mode));
    _preferences.update((p) => p.copyWith(loopMode: mode));
  }

  /// 切换随机乱序播放。
  void toggleShuffle() => setShuffle(!_snapshotNotifier.value.shuffleEnabled);

  /// 显式设置随机播放状态，保留当前曲目作为起点重建播放顺序。
  void setShuffle(bool enabled) {
    final snap = _snapshotNotifier.value;
    if (snap.shuffleEnabled == enabled) return;
    final newOrder = AudioPlaybackQueueBuilder.buildPlayOrder(
      length: snap.queue.length,
      currentIndex: snap.currentIndex,
      shuffle: enabled,
    );
    final newPos = snap.currentIndex >= 0
        ? newOrder.indexOf(snap.currentIndex)
        : -1;
    _updateSnapshot(
      snap.copyWith(
        shuffleEnabled: enabled,
        playOrder: newOrder,
        playOrderPos: newPos,
      ),
    );
    _preferences.update((p) => p.copyWith(shuffleEnabled: enabled));
  }

  /// 调整软件安全缩放音量（`0 ~ 100`）；源码透传模式下保持受控只读提示。
  Future<void> setVolume(double volume) async {
    final clamped = volume.clamp(0.0, 100.0);
    _updateSnapshot(
      _snapshotNotifier.value.copyWith(
        volume: clamped,
        isMuted: clamped <= 0.0 ? _snapshotNotifier.value.isMuted : false,
      ),
    );
    _preferences.update(
      (p) => p.copyWith(
        defaultVolume: clamped,
        isMuted: clamped <= 0.0 ? p.isMuted : false,
      ),
    );
    final client = _client;
    if (client != null && !client.isDisposed && client.isInitialized) {
      _microFadeDriver.cancel();
      final isMuted = _snapshotNotifier.value.isMuted;
      client.setPropertyFlag('mute', isMuted);
      if (!isMuted) {
        client.setPropertyDouble('volume', clamped);
      }
    }
  }

  /// 切换静音状态。
  Future<void> toggleMute() async {
    final nextMute = !_snapshotNotifier.value.isMuted;
    _updateSnapshot(_snapshotNotifier.value.copyWith(isMuted: nextMute));
    _preferences.update((p) => p.copyWith(isMuted: nextMute));
    final client = _client;
    if (client != null && !client.isDisposed && client.isInitialized) {
      _microFadeDriver.cancel();
      client.setPropertyFlag('mute', nextMute);
      if (!nextMute) {
        client.setPropertyDouble('volume', _snapshotNotifier.value.volume);
      }
    }
  }

  /// 在队列视图中动态展开或折叠指定 `.cue` 清单分组。
  Future<void> toggleCueExpansion(String cueRelativePath) async {
    final norm = AudioPlaybackQueueBuilder.normalizeQueuePath(
      cueRelativePath,
    ).toLowerCase();
    final expanded = _snapshotNotifier.value.expandedCuePaths.contains(norm);
    if (expanded) {
      await collapseCueGroup(cueRelativePath);
    } else {
      final idx = _snapshotNotifier.value.queue.indexWhere(
        (item) =>
            AudioPlaybackQueueBuilder.normalizeQueuePath(
              item.cueSheetPath ?? '',
            ).toLowerCase() ==
            norm,
      );
      if (idx >= 0) {
        await expandCueAtQueueIndex(idx);
      }
    }
  }

  /// 触发针对当前音频硬件直通路由的物理电平实证核验。
  Future<HardwareRouteVerificationResult> verifyAudiophileHardwareRoute() =>
      _verifyAudiophileHardwareRouteImpl();

  /// 确认解除当次会话 `-12 dBFS` 安全衰减并应用至底层客户端（需已完成后端硬件实证）。
  Future<AudioSafetyChainPlan> confirmFullScaleUnlock() =>
      _confirmFullScaleUnlockImpl();

  /// 切换 `-12 dBFS` 发烧防炸耳天花板保护开关，开启时立即重锁安全限幅并热更路由。
  Future<void> setAudiophileSafetyLimiterEnabled(bool enabled) =>
      _setAudiophileSafetyLimiterEnabledImpl(enabled);

  /// 读取最新音频设备列表并在可用时刷新给设置页/弹窗展示。
  Future<List<MpvAudioDevice>> refreshAudioDevices() =>
      _refreshAudioDevicesImpl();

  /// 切换输出设备并自动重锁 `-12 dBFS` 防炸耳门锁，消除切设备爆耳风险。
  Future<void> selectAudioDevice(String deviceName) =>
      _selectAudioDeviceImpl(deviceName);

  /// 将持久化存储中刚变更的高保真参数（限幅/重采样/独占/增益）实时下发到活跃客户端。
  Future<void> syncPreferencesFromStore({
    AudioPlaybackPrefsData? overridePrefs,
  }) => _syncPreferencesFromStoreImpl(overridePrefs: overridePrefs);

  /// 切换桌面端置顶便携小窗形态（通过窗口抽象端口委托给宿主壳层）。
  Future<void> setDesktopMiniWindow(bool enabled) async {
    if (_snapshotNotifier.value.isDesktopMiniWindow == enabled) return;
    if (enabled) {
      await _windowPort.enterDesktopMiniWindow(width: 392, height: 108);
    } else {
      await _windowPort.exitDesktopMiniWindow();
    }
    _updateSnapshot(
      _snapshotNotifier.value.copyWith(isDesktopMiniWindow: enabled),
    );
  }

  /// 将当前正在播放的专辑队列或单曲移交给桌面端已配置的外部发烧播放器接力。
  Future<LaunchPlaybackResult?> relayActiveToDesktop({String? targetId}) =>
      _relayActiveToDesktopImpl(targetId: targetId);

  /// 当用户打开独立视频播放会话时自动退避挂起音频输出并释放独占原生实例。
  Future<void> pauseForVideoSession() async {
    await setPlaying(false);
    await _releaseCurrentClient();
    _updateSnapshot(
      _snapshotNotifier.value.copyWith(
        status: AudioPlaybackStatus.paused,
        isBuffering: false,
      ),
    );
  }

  /// 彻底结束音频播放会话，重置叶子通知器并通知歌词端口清空当前活动曲目。
  Future<void> stopAndClose() async {
    if (_disposed) return;
    await _persistPlaybackHistory(force: true);
    _cueBoundaryTimer?.cancel();
    _cueBoundaryTimer = null;
    _microFadeDriver.cancel();
    _mediaOpenSeq++;
    for (final domain in PlaybackTaskDomain.values) {
      _engine.cancelTaskDomain(domain);
    }
    _clearPrefetchTracking(releaseBridge: true);
    await _releaseCurrentClient();

    if (_snapshotNotifier.value.isDesktopMiniWindow) {
      await _windowPort.exitDesktopMiniWindow();
    }

    _activeWork = null;
    _rawDurationSeconds = 0.0;
    _lastConfirmedAudioPosSeconds = 0.0;

    _playingNotifier.value = false;
    _activeNotifier.value = false;
    _positionNotifier.value = Duration.zero;
    _durationNotifier.value = Duration.zero;
    _updateSnapshot(
      AudioPlaybackSnapshot(
        loopMode: _preferences.read().loopMode,
        shuffleEnabled: _preferences.read().shuffleEnabled,
        volume: _preferences.read().defaultVolume,
        isMuted: _preferences.read().isMuted,
        audiophileSafetyState: _safetyCoordinator.deviceSafetyState,
        audiophilePlan: _safetyCoordinator.compilePlan(
          _effectiveAudiophilePrefs(_preferences.read()),
          upstreamDspFilters: _buildUpstreamDspFilters(_preferences.read()),
        ),
      ),
    );
    _clearLyrics();
    await _androidMediaSessionPort?.stopSession();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cueBoundaryTimer?.cancel();
    _cueBoundaryTimer = null;
    _microFadeDriver.cancel();
    _safetyCoordinator.detachSession(this);
    unawaited(_clientEventSub?.cancel());
    _clientEventSub = null;
    unawaited(_releaseCurrentClient());
    _positionNotifier.removeListener(_syncLyricsClock);
    _playingNotifier.removeListener(_syncLyricsClock);
    _positionNotifier.dispose();
    _durationNotifier.dispose();
    _playingNotifier.dispose();
    _activeNotifier.dispose();
    _snapshotNotifier.dispose();
    super.dispose();
  }

  AudiophileAudioPreferences _effectiveAudiophilePrefs(
    AudioPlaybackPrefsData prefs,
  ) {
    return prefs.toAudiophilePreferences();
  }

  void _updateSnapshot(AudioPlaybackSnapshot next) {
    if (_disposed) return;
    _snapshotNotifier.value = next;
    notifyListeners();
  }
}
