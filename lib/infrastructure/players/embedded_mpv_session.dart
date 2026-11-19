import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../domain/models/media_extensions.dart';
import '../../domain/models/media_source.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/playback/ass_uue_font_decoder.dart';
import '../../domain/playback/hwdec_safety_policy.dart';
import '../../domain/playback/playback_probe_stats.dart';
import '../../domain/playback/subtitle_and_audio_choices.dart';
import '../../domain/playback/track_preferences.dart';
import '../../domain/playback/video_aspect_mode.dart';
import '../logging/diagnostics_log_store.dart';
import '../sources/byte_stream_source_gateway.dart';
import '../sources/local_source_gateway.dart';
import '../sources/source_gateway_factory.dart';
import '../sources/subtitle_matcher.dart';
import '../sources/work_detail_warmup_service.dart';
import '../storage/storage_root_provider.dart';
import '../stream_bridge/local_stream_bridge.dart';
import '../subtitles/subtitle_font_pool_manager.dart';
import 'android/android_video_surface_controller.dart';
import 'konata_video_texture_bridge.dart';
import 'libmpv_ffi.dart';
import 'mpv_quality_profile.dart';
import 'playback_probe.dart';

part 'embedded_mpv_session_sidecars.dart';
part 'embedded_mpv_session_surface.dart';

/// 单次内置视频装载描述。
class EmbeddedVideoLoadRequest {
  /// 创建视频装载请求。
  const EmbeddedVideoLoadRequest({
    required this.workId,
    required this.variant,
    this.source,
    this.startSeconds = 0.0,
    this.initialWidth = 1280,
    this.initialHeight = 720,
  });

  final String workId;
  final MediaVariant variant;
  final MediaSource? source;
  final double startSeconds;
  final int initialWidth;
  final int initialHeight;
}

/// 原画截图模式（严格经 FFI 参数数组传递给 `screenshot-to-file`）。
enum ScreenshotCaptureMode {
  /// 纯净视频帧（不含字幕与任何 UI 浮层）。
  pureVideo('video', '纯净原画'),

  /// 视频帧叠加原生渲染字幕（不含 UI 浮层）。
  withSubtitles('subtitles', '含字幕原画');

  const ScreenshotCaptureMode(this.mpvFlag, this.label);

  /// 传递给 `libmpv` `screenshot-to-file` 的模式参数。
  final String mpvFlag;

  /// 界面展示名称。
  final String label;
}

/// 截图落盘或相册事务发布结果。
class ScreenshotCaptureResult {
  /// 创建截图结果。
  const ScreenshotCaptureResult({
    required this.mode,
    required this.displayLabel,
    this.file,
    this.galleryUri,
  });

  /// 本次截图模式。
  final ScreenshotCaptureMode mode;

  /// 面向用户的路径或相册位置展示文案。
  final String displayLabel;

  /// 桌面端直存作品目录的文件实体（Android 经 MediaStore 发布并清理临时文件后为 null）。
  final File? file;

  /// Android `MediaStore` 事务入库返回的内容 URI。
  final String? galleryUri;
}

/// 内置 `libmpv` 视频底层会话封装（管理 Windows D3D11 共享纹理 / Android Surface、
/// 统一四维代数事件隔离、共享发烧音频安全链、硬解容错软解回退及安全串行销毁）。
class EmbeddedMpvSession {
  /// 创建内置视频会话实例。
  EmbeddedMpvSession({
    required this.storageRoot,
    required this.streamBridge,
    this.logStore,
    this.clientFactory,
    this.desktopSurfaceBridge,
    this.desktopProfileDelegate,
    this.gatewayFactory = const MediaSourceGatewayFactory(),
    this.probeCollector = const PlaybackProbeCollector(),
    this.subtitleDirectoryIndex,
    SubtitleFontPoolManager? fontPoolManager,
  }) : _fontPoolManager =
           fontPoolManager ?? SubtitleFontPoolManager(storageRoot: storageRoot);

  static const int _propTimePos = 201;
  static const int _propDuration = 202;
  static const int _propPause = 203;
  static const int _propCoreIdle = 204;
  static const int _propSpeed = 205;
  static const int _propVolume = 206;
  static const int _propMute = 207;
  static const int _propAid = 208;
  static const int _propSid = 209;
  static const int _propTrackListCount = 210;
  static const int _propHwdecCurrent = 211;
  static const int _propAudioDeviceList = 212;
  static const int _propAudioDevice = 213;

  final StorageRootService storageRoot;
  final LocalStreamBridge streamBridge;
  final DiagnosticsLogStore? logStore;
  final LibMpvClient Function()? clientFactory;
  final KonataVideoTextureBridge? desktopSurfaceBridge;
  final MpvPlatformProfileDelegate? desktopProfileDelegate;
  final MediaSourceGatewayFactory gatewayFactory;
  final PlaybackProbeCollector probeCollector;
  final SubtitleDirectoryIndex? subtitleDirectoryIndex;
  final SubtitleFontPoolManager _fontPoolManager;

  String _defaultSubFontsDir = '';
  String _activeSubFontsDir = '';

  final ValueNotifier<int?> _textureId = ValueNotifier<int?>(null);
  final ValueNotifier<bool> _underlayActive = ValueNotifier<bool>(false);
  final ValueNotifier<String> _renderBackend = ValueNotifier<String>('');
  final ValueNotifier<String> _adapterName = ValueNotifier<String>('');

  /// Flutter `Texture(textureId: ...)` 响应句柄。
  ValueListenable<int?> get textureIdListenable => _textureId;

  /// 桌面端是否激活底层 10-bit/HDR 视口挖空直出模式（`vo=gpu-next` 或 DirectComposition）。
  ValueListenable<bool> get underlayActiveListenable => _underlayActive;

  /// 当前实际图形后端名称（`gpu_next` / `dcomp_10bit` / `d3d11_fp16` / `sw` / `gpu-next`）。
  ValueListenable<String> get renderBackendListenable => _renderBackend;

  /// 当前显卡适配器或渲染说明。
  ValueListenable<String> get adapterNameListenable => _adapterName;

  /// 事件回调钩子（由上层 `VideoPlaybackController` 绑定）。
  void Function(double posSeconds)? onPositionChanged;
  void Function(double durationSeconds)? onDurationChanged;
  void Function(bool isPlaying)? onPlayingChanged;
  void Function(bool isBuffering)? onBufferingChanged;
  void Function(double speed)? onSpeedChanged;
  void Function()? onFirstFrameRendered;
  void Function(String hwdecCurrent)? onHwdecChanged;
  void Function({
    required List<SubtitleChoice> subtitles,
    required List<AudioTrackChoice> audioTracks,
    required List<PlaybackChapter> chapters,
    required List<MpvAudioDevice> audioDevices,
  })?
  onMediaMetadataUpdated;
  void Function(int reason, int errorCode)? onEndOfFile;
  void Function(String message)? onNotice;
  void Function(String message)? onFatalError;

  /// 统一内核同步钩子：由上层注入以串入 `UnifiedPlaybackEngine` 与 `AudiophileSafetyCoordinator`。
  String? Function(String leaseToken)? onBindMainStreamLease;
  void Function(int playlistEntryId)? onPlaylistEntryStarted;
  bool Function({int? playlistEntryId})? onValidatePhysicalEvent;
  void Function()? onFileLoaded;
  void Function(LibMpvClient client)? onApplyAudiophileSafetyChain;
  void Function(
    LibMpvClient client, {
    required double targetVolume,
    required bool isMuted,
  })?
  onTriggerMicroFadeIn;
  void Function(List<MpvAudioDevice> devices, String? currentDevice)?
  onAudioDeviceListChanged;

  /// 外挂文本字幕发现回调：交由上层 `SubtitleMemoryEngine` 单一串行通道完成编码归一与 `cached` 挂载选轨。
  Future<void> Function(
    List<String> textSubtitlePaths,
    CrossEpisodeTrackMemory trackMemory,
    TrackPreferences trackPreferences,
  )?
  onMountExternalTextSubtitles;

  /// 当前已生效的 `sub-fonts-dir` 目录路径（用于单测验证字库直挂与哈希池切换）。
  String get activeSubFontsDir => _activeSubFontsDir;

  /// 实时更新底层 `libmpv` 的 `sub-fonts-dir` 属性（供 `Fonts.zip`、ASS `[Fonts]` 与远程字库入池联动）。
  void applySubFontsDir(String dirPath) {
    final trimmed = dirPath.trim();
    if (trimmed.isEmpty || trimmed == _activeSubFontsDir) return;
    final client = _client;
    if (_disposed || client == null || client.isDisposed) return;
    client.setPropertyString('sub-fonts-dir', trimmed);
    _activeSubFontsDir = trimmed;
  }

  LibMpvClient? _client;
  StreamSubscription<MpvClientEvent>? _eventSub;
  StreamSubscription<NativeTextureChangedEvent>? _desktopSurfaceChangeSub;
  StreamSubscription<AndroidSurfaceDescriptor?>? _androidSurfaceSub;
  AndroidVideoSurfaceController? _androidSurface;
  Future<void> _androidSurfaceSerial = Future<void>.value();
  bool _useAndroidSurfaceSession = false;
  int _boundAndroidWid = 0;
  int _boundAndroidWidth = 0;
  int _boundAndroidHeight = 0;
  int _boundAndroidHdrPeak = -1;
  Timer? _firstFrameWatchdogTimer;
  bool _firstFrameWatchdogReboundOnce = false;

  int? _desktopSurfaceSessionId;
  bool _usingGpuNextUnderlay = false;
  final List<String> _activeStreamTokens = [];
  List<String> _pendingExternalSubtitles = const [];
  List<String> _pendingExternalAudioPaths = const [];
  CrossEpisodeTrackMemory _trackMemory = const CrossEpisodeTrackMemory();
  TrackPreferences _trackPreferences = const TrackPreferences();
  String _currentMediaTarget = '';
  double _lastPositionSeconds = 0.0;
  double? _pendingInitialSeekSeconds;
  double _totalDurationSeconds = 0.0;
  double _desiredVolume = 100.0;
  bool _isMuted = false;
  int _loadGeneration = 0;
  int? _activePlaylistEntryId;
  bool _fileLoadedForCurrentGen = false;
  bool _hasRestartedFirstFrame = false;
  bool _hwdecWasEnabled = true;
  bool _hwdecFallbackAttempted = false;
  bool _usingSoftwareFallback = false;
  bool _positionObserved = true;
  String _activeAndroidVo = MpvQualityProfile.androidVideoDriver;
  bool _disposed = false;
  bool _videoTrackEnabled = true;
  String? _savedVidBeforeDisable;
  VideoAspectMode _aspectMode = VideoAspectMode.auto;
  String? _cachedMpvVersion;
  String? _cachedFfmpegVersion;
  PlaybackQualityConfig _lastQualityConfig = const PlaybackQualityConfig();
  DateTime? _suppressBufferingUntil;
  ({EmbeddedVideoLoadRequest request, int generation})?
  _pendingRemoteSidecarJob;

  bool get isDisposed => _disposed;
  bool get isInitialized => _client?.isInitialized ?? false;
  bool get isUsingSoftwareFallback => _usingSoftwareFallback;
  bool get isPositionObservationEnabled => _positionObserved;

  /// 当前活跃的底层 `libmpv` 客户端实例（供上层字幕内存引擎与安全音频链统一控制）。
  LibMpvClient? get activeClient =>
      (_disposed || _client == null || _client!.isDisposed) ? null : _client;

  /// 当前物理媒体装载代数（切集或销毁时递增）。
  int get loadGeneration => _loadGeneration;

  /// 实时读取当前底层精确播放秒数（OSD 隐藏退订期间供低频持久化与唤醒同步使用）。
  double? readCurrentPositionSeconds() {
    final client = _client;
    if (_disposed ||
        client == null ||
        client.isDisposed ||
        !client.isInitialized) {
      return null;
    }
    final pos = client.getPropertyDouble('time-pos');
    if (pos != null && pos.isFinite) {
      _lastPositionSeconds = pos;
      return pos;
    }
    return _lastPositionSeconds;
  }

  /// 控制是否启用 `time-pos` 属性高频订阅（OSD 隐藏稳态或画中画时退订，消除 Flutter 无谓唤醒）。
  void setPositionObservationEnabled(bool enabled) {
    if (_positionObserved == enabled) return;
    _positionObserved = enabled;
    final client = _client;
    if (_disposed ||
        client == null ||
        client.isDisposed ||
        !client.isInitialized) {
      return;
    }
    if (enabled) {
      client.observeProperty(_propTimePos, 'time-pos', MpvFormat.double_);
      final latest = readCurrentPositionSeconds();
      if (latest != null) {
        onPositionChanged?.call(latest);
      }
    } else if (client is LibMpvUnobservable) {
      (client as LibMpvUnobservable).unobserveProperty(_propTimePos);
    }
  }

  /// 初始化底层 `libmpv`（Windows 创建 D3D11 共享纹理 / Android 绑定原生像素表面）并起播首个视频。
  Future<void> initializeAndLoad({
    required EmbeddedVideoLoadRequest request,
    required PlaybackQualityConfig qualityConfig,
    CrossEpisodeTrackMemory trackMemory = const CrossEpisodeTrackMemory(),
    TrackPreferences trackPreferences = const TrackPreferences(),
    double initialVolume = 100.0,
    Future<AndroidVideoSurfaceController> Function()? androidSurfaceSupplier,
  }) async {
    if (_disposed) return;
    _trackMemory = trackMemory;
    _trackPreferences = trackPreferences;
    _lastQualityConfig = qualityConfig;
    _desiredVolume = initialVolume.clamp(0.0, 100.0);
    _useAndroidSurfaceSession =
        Platform.isAndroid || androidSurfaceSupplier != null;
    final useDesktopSurface = Platform.isWindows && !_useAndroidSurfaceSession;
    final isRemote =
        request.source != null && request.source!.kind != MediaSourceKind.local;

    final mpvDir = await storageRoot.ensureMpvConfigDir();
    _defaultSubFontsDir = p.join(mpvDir.path, 'fonts');
    _activeSubFontsDir = _defaultSubFontsDir;
    final workPhotoDir = await _resolveScreenshotDir(request.workId);
    final verifiedShaders = await MpvQualityProfile.filterExistingShaderPaths(
      qualityConfig.activeShaderPaths,
    );
    if (Platform.isAndroid) {
      await AndroidVideoSurfaceController.preparePortableCjkFontSymlinks(
        mpvDir,
      );
    }

    final initResult = await _initializeMpvClientAndDesktopBackend(
      request: request,
      qualityConfig: qualityConfig,
      mpvDir: mpvDir,
      workPhotoDir: workPhotoDir,
      verifiedShaders: verifiedShaders,
      isRemote: isRemote,
      useDesktopSurface: useDesktopSurface,
    );
    final client = initResult.client;
    final effectiveQualityConfig = initResult.effectiveConfig;

    MpvQualityProfile.applyPostInitVideoProperties(
      client,
      config: effectiveQualityConfig,
      isWindowsOverride: useDesktopSurface,
      desktopDelegate: desktopProfileDelegate,
      onExclusiveFallbackNotice: onNotice,
      logStore: logStore,
    );
    onApplyAudiophileSafetyChain?.call(client);
    // 存在微淡入斜坡钩子时先以静音起点装载，待首帧/重启动后再平滑拉起目标音量，防止启播瞬间爆音。
    client.setPropertyDouble(
      'volume',
      onTriggerMicroFadeIn != null ? 0.0 : _desiredVolume,
    );

    if (_positionObserved) {
      client.observeProperty(_propTimePos, 'time-pos', MpvFormat.double_);
    }
    client.observeProperty(_propDuration, 'duration', MpvFormat.double_);
    client.observeProperty(_propPause, 'pause', MpvFormat.flag);
    client.observeProperty(_propCoreIdle, 'core-idle', MpvFormat.flag);
    client.observeProperty(_propSpeed, 'speed', MpvFormat.double_);
    client.observeProperty(_propVolume, 'volume', MpvFormat.double_);
    client.observeProperty(_propMute, 'mute', MpvFormat.flag);
    client.observeProperty(_propAid, 'aid', MpvFormat.string);
    client.observeProperty(_propSid, 'sid', MpvFormat.string);
    client.observeProperty(
      _propTrackListCount,
      'track-list/count',
      MpvFormat.int64,
    );
    client.observeProperty(
      _propHwdecCurrent,
      'hwdec-current',
      MpvFormat.string,
    );
    if (useDesktopSurface) {
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

    _eventSub = client.events.listen(_handleMpvEvent);

    if (_useAndroidSurfaceSession && androidSurfaceSupplier != null) {
      final ctrl = await androidSurfaceSupplier();
      if (_disposed) return;
      _bindAndroidSurfaceController(ctrl);
      var desc = await ctrl.queryCurrent();
      if (desc == null ||
          desc.wid <= 0 ||
          desc.width <= 0 ||
          desc.height <= 0) {
        try {
          desc = await ctrl.surfaceChanges
              .where(
                (e) => e != null && e.wid > 0 && e.width > 0 && e.height > 0,
              )
              .cast<AndroidSurfaceDescriptor>()
              .first
              .timeout(const Duration(milliseconds: 350));
        } on TimeoutException {
          desc = ctrl.current;
        }
      }
      if (_disposed) return;
      if (desc != null && desc.wid > 0 && desc.width > 0 && desc.height > 0) {
        await _enqueueAndroidSurfaceUpdate(desc, sourceCtrl: ctrl);
      }
    }

    await loadMediaVariant(request, trackMemory: _trackMemory);
  }

  /// 在现有渲染会话内热切换至目标分集/变体（零黑闪、保持 D3D11 共享纹理句柄）。
  Future<void> loadMediaVariant(
    EmbeddedVideoLoadRequest request, {
    CrossEpisodeTrackMemory? trackMemory,
    TrackPreferences? trackPreferences,
  }) async {
    final client = _client;
    if (_disposed || client == null || client.isDisposed) return;

    if (trackMemory != null) {
      _trackMemory = trackMemory;
    }
    if (trackPreferences != null) {
      _trackPreferences = trackPreferences;
    }

    final generation = ++_loadGeneration;
    _activePlaylistEntryId = null;
    _pendingRemoteSidecarJob = null;
    _fileLoadedForCurrentGen = false;
    _hasRestartedFirstFrame = false;
    _firstFrameWatchdogReboundOnce = false;
    _firstFrameWatchdogTimer?.cancel();
    _hwdecFallbackAttempted = false;
    _lastPositionSeconds = request.startSeconds > 0
        ? request.startSeconds.toDouble()
        : 0.0;
    _totalDurationSeconds = 0.0;

    final previousTokens = List<String>.from(_activeStreamTokens);
    _activeStreamTokens.clear();

    final resolved = await _prepareMediaAndSidecars(request);
    if (_disposed || generation != _loadGeneration) {
      await _unregisterTokens(_activeStreamTokens);
      await _unregisterTokens(previousTokens);
      return;
    }

    _currentMediaTarget = resolved.mediaTarget;
    _pendingExternalSubtitles = resolved.subtitlePaths;
    _pendingExternalAudioPaths = resolved.audioTargets;
    _suppressBufferingUntil = null;

    final isRemote =
        request.source != null && request.source!.kind != MediaSourceKind.local;
    // 本地媒体优先同级 Fonts/ 原位只读直挂，其次同级 Fonts.zip 解包入单级哈希池。
    if (!isRemote) {
      final resolvedFontDir = await _resolveLocalFontPackDir(
        resolved.mediaTarget,
      );
      if (_disposed || generation != _loadGeneration) {
        await _unregisterTokens(_activeStreamTokens);
        await _unregisterTokens(previousTokens);
        return;
      }
      final targetFontsDir = resolvedFontDir ?? _defaultSubFontsDir;
      if (targetFontsDir.isNotEmpty) {
        applySubFontsDir(targetFontsDir);
      }
    } else if (_defaultSubFontsDir.isNotEmpty) {
      applySubFontsDir(_defaultSubFontsDir);
    }

    MpvQualityProfile.applyRuntimeStreamProfile(
      client,
      isRemoteStream: isRemote,
      isAudio: false,
      config: _lastQualityConfig,
      logStore: logStore,
    );
    onApplyAudiophileSafetyChain?.call(client);

    if (request.startSeconds > 0) {
      final formattedStart = request.startSeconds == request.startSeconds.roundToDouble()
          ? request.startSeconds.toInt().toString()
          : request.startSeconds.toStringAsFixed(3);
      final startRc = client.setPropertyString('start', '+$formattedStart');
      if (startRc < 0) {
        client.setPropertyDouble('start', request.startSeconds);
      }
      _pendingInitialSeekSeconds = request.startSeconds;
    } else {
      client.setPropertyString('start', 'none');
      _pendingInitialSeekSeconds = null;
    }
    client.setPropertyDouble('sub-delay', 0.0);
    client.setPropertyDouble('audio-delay', 0.0);
    client.setPropertyString('vid', _videoTrackEnabled ? 'auto' : 'no');
    _applyAspectModeToClient(client, _aspectMode);
    if (onTriggerMicroFadeIn != null) {
      client.setPropertyDouble('volume', 0.0);
    }
    client.setPropertyFlag('pause', false);

    final rc = client.command(['loadfile', resolved.mediaTarget, 'replace']);
    await _unregisterTokens(previousTokens);
    if (rc < 0) {
      onFatalError?.call('视频装载失败: ${client.errorString(rc)}');
      return;
    }

    if (request.source != null &&
        request.source!.kind != MediaSourceKind.local) {
      if (Platform.environment.containsKey('FLUTTER_TEST')) {
        unawaited(
          _discoverAndAttachRemoteSidecars(request, generation: generation),
        );
      } else {
        // 优先让主视频流独占远程通道完成首帧建联，待 FileLoaded 后再异步补扫目录与下载外挂字幕。
        _pendingRemoteSidecarJob = (request: request, generation: generation);
      }
    }
  }

  void _handleMpvEvent(MpvClientEvent event) {
    if (_disposed) return;
    switch (event) {
      case MpvStartFileEvent():
        _activePlaylistEntryId = event.playlistEntryId > 0
            ? event.playlistEntryId
            : null;
        onPlaylistEntryStarted?.call(event.playlistEntryId);
        onBufferingChanged?.call(true);
      case MpvFileLoadedEvent():
        if (onValidatePhysicalEvent != null &&
            !onValidatePhysicalEvent!(
              playlistEntryId: _activePlaylistEntryId,
            )) {
          return;
        }
        _fileLoadedForCurrentGen = true;
        onFileLoaded?.call();
        _enforceHwdecSafetyPolicy();
        final pendingSeek = _pendingInitialSeekSeconds;
        _pendingInitialSeekSeconds = null;
        _client?.setPropertyString('start', 'none');
        if (pendingSeek != null && pendingSeek > 0) {
          final currentPos = _client?.getPropertyDouble('time-pos');
          if (currentPos != null && (currentPos - pendingSeek).abs() > 2.5) {
            _client?.command([
              'seek',
              pendingSeek.toStringAsFixed(1),
              'absolute',
              'exact',
            ]);
          }
        }
        _mountSidecarsAndResolveTracks();
        if (_useAndroidSurfaceSession && _videoTrackEnabled) {
          _scheduleFirstFrameWatchdog();
        }
        final activeClient = _client;
        if (activeClient != null && !activeClient.isDisposed) {
          onTriggerMicroFadeIn?.call(
            activeClient,
            targetVolume: _desiredVolume,
            isMuted: _isMuted,
          );
        }
        final sidecarJob = _pendingRemoteSidecarJob;
        if (sidecarJob != null && sidecarJob.generation == _loadGeneration) {
          _pendingRemoteSidecarJob = null;
          unawaited(
            _discoverAndAttachRemoteSidecars(
              sidecarJob.request,
              generation: sidecarJob.generation,
            ),
          );
        }
      case MpvPlaybackRestartEvent():
        if (onValidatePhysicalEvent != null &&
            !onValidatePhysicalEvent!(
              playlistEntryId: _activePlaylistEntryId,
            )) {
          return;
        }
        _hasRestartedFirstFrame = true;
        _firstFrameWatchdogTimer?.cancel();
        _suppressBufferingUntil = null;
        onFirstFrameRendered?.call();
        onBufferingChanged?.call(false);
        _syncHwdecCurrent();
        _emitMediaMetadataSnapshot();
      case MpvVideoReconfigEvent():
        _firstFrameWatchdogTimer?.cancel();
        _enforceHwdecSafetyPolicy();
        _syncHwdecCurrent();
        _emitMediaMetadataSnapshot();
      case MpvAudioReconfigEvent():
        _emitMediaMetadataSnapshot();
      case MpvPropertyChangeEvent():
        _handlePropertyEvent(event);
      case MpvLogMessageEvent():
        _inspectLogForHwdecFailure(event);
      case MpvEndFileEvent():
        _handleEndFile(event);
      case MpvSeekEvent():
      case MpvShutdownEvent():
        break;
    }
  }

  void _syncHwdecCurrent() {
    final client = _client;
    if (_disposed || client == null || client.isDisposed) return;
    final current = client.getPropertyString('hwdec-current');
    if (current != null) {
      onHwdecChanged?.call(current);
    }
  }

  /// 解码层精准拦截 AVC Hi10P / 非 4:2:0 与 HEVC Rext / >10-bit 流，在首帧花屏前自动回落多线程 SIMD 软解。
  void _enforceHwdecSafetyPolicy() {
    final client = _client;
    if (_disposed ||
        client == null ||
        client.isDisposed ||
        !_hwdecWasEnabled ||
        _usingSoftwareFallback) {
      return;
    }
    final codec =
        client.getPropertyString('video-format') ??
        client.getPropertyString('video-codec') ??
        '';
    final profile =
        client.getPropertyString('video-params/profile') ??
        client.getPropertyString('video-codec') ??
        '';
    final pixfmt = client.getPropertyString('video-params/pixelformat');
    final hwPixfmt = client.getPropertyString('video-params/hw-pixelformat');
    final platform = _useAndroidSurfaceSession
        ? HwdecPlatformKind.android
        : (Platform.isWindows
              ? HwdecPlatformKind.windows
              : HwdecPlatformKind.other);
    final decision = HwdecSafetyPolicy.evaluate(
      platform: platform,
      videoCodec: codec,
      videoProfile: profile,
      pixelFormat: pixfmt,
      hwPixelFormat: hwPixfmt,
    );
    if (decision.allowHardwareDecode) {
      return;
    }
    _hwdecFallbackAttempted = true;
    _usingSoftwareFallback = true;
    client.setPropertyString('hwdec', 'no');
    client.setPropertyString('vd-lavc-threads', '0');
    logStore?.record(
      'mpv-hwdec-guard',
      'rule=${decision.matchedRule} codec=$codec profile=$profile pixfmt=$pixfmt hw=$hwPixfmt -> hwdec=no',
    );
    onHwdecChanged?.call('no');
    if (decision.reason != null) {
      onNotice?.call(decision.reason!);
    }
  }

  void _handlePropertyEvent(MpvPropertyChangeEvent e) {
    switch (e.replyUserdata) {
      case _propTimePos:
        final pos = e.doubleValue;
        if (pos != null && pos.isFinite) {
          _lastPositionSeconds = pos;
          if (_positionObserved) {
            onPositionChanged?.call(pos);
          }
        }
      case _propDuration:
        final dur = e.doubleValue;
        if (dur != null && dur.isFinite && dur > 0) {
          _totalDurationSeconds = dur;
          onDurationChanged?.call(dur);
          _emitMediaMetadataSnapshot();
        }
      case _propPause:
        final paused = e.boolValue;
        if (paused != null) {
          onPlayingChanged?.call(!paused);
        }
      case _propCoreIdle:
        final idle = e.boolValue ?? false;
        final isPaused = _client?.getPropertyFlag('pause') ?? false;
        final suppressed =
            _suppressBufferingUntil != null &&
            DateTime.now().isBefore(_suppressBufferingUntil!);
        if (suppressed && idle) {
          onBufferingChanged?.call(false);
        } else {
          onBufferingChanged?.call(!isPaused && idle);
        }
      case _propSpeed:
        final spd = e.doubleValue;
        if (spd != null && spd.isFinite) {
          onSpeedChanged?.call(spd);
        }
      case _propAid:
      case _propSid:
      case _propTrackListCount:
        _emitMediaMetadataSnapshot();
      case _propHwdecCurrent:
        onHwdecChanged?.call(e.stringValue ?? '');
      case _propAudioDeviceList:
      case _propAudioDevice:
        final client = _client;
        if (client != null && !client.isDisposed && client.isInitialized) {
          final devices = client.readAudioDeviceList();
          final currentDev = client.getPropertyString('audio-device');
          onAudioDeviceListChanged?.call(devices, currentDev);
          _emitMediaMetadataSnapshot();
        }
    }
  }

  void _inspectLogForHwdecFailure(MpvLogMessageEvent event) {
    final level = event.level.toLowerCase();
    if (level != 'error' && level != 'fatal') return;
    logStore?.record(
      'mpv-video',
      '[${event.prefix}] ${event.text.trim()}',
      isError: true,
    );

    if (!_hwdecWasEnabled || _hwdecFallbackAttempted) return;
    final msg = '${event.prefix} ${event.text}'.toLowerCase();
    final isDesktopHwdecWarn =
        desktopProfileDelegate?.isDesktopHardwareDecodeWarning(msg) ?? false;
    final isFatalHwdecError =
        level == 'fatal' &&
        (msg.contains('hwdec') ||
            isDesktopHwdecWarn ||
            msg.contains('mediacodec') ||
            msg.contains('hardware decoding'));
    final isExplicitUnrecoverable =
        msg.contains('hardware decoding failed') || isDesktopHwdecWarn;
    if (isFatalHwdecError || isExplicitUnrecoverable) {
      _triggerSoftwareDecodeFallback();
    }
  }

  void _handleEndFile(MpvEndFileEvent event) {
    if (onValidatePhysicalEvent != null &&
        !onValidatePhysicalEvent!(playlistEntryId: event.playlistEntryId)) {
      return;
    }
    if (event.reason == MpvEndFileReason.error &&
        _hwdecWasEnabled &&
        !_hwdecFallbackAttempted &&
        !_hasRestartedFirstFrame) {
      _triggerSoftwareDecodeFallback();
      return;
    }
    onEndOfFile?.call(event.reason, event.errorCode);
  }

  void _triggerSoftwareDecodeFallback() {
    final client = _client;
    if (_disposed ||
        client == null ||
        client.isDisposed ||
        _hwdecFallbackAttempted ||
        _currentMediaTarget.isEmpty) {
      return;
    }
    _hwdecFallbackAttempted = true;
    _usingSoftwareFallback = true;
    client.setPropertyString('hwdec', 'no');
    if (_lastPositionSeconds > 0.5) {
      client.setPropertyDouble('start', _lastPositionSeconds);
    }
    client.setPropertyFlag('pause', false);
    client.command(['loadfile', _currentMediaTarget, 'replace']);
    onNotice?.call('硬件解码受限，已保留当前进度无缝切回软件解码');
  }

  /// 采集当前实时 40+ 项技术探针快照。
  PlaybackProbeStats collectProbeStats() {
    final client = _client;
    if (_disposed || client == null || client.isDisposed) {
      return const PlaybackProbeStats();
    }
    return probeCollector.collect(
      client,
      gpuApiOverride: _renderBackend.value,
      mpvVersionCache: _cachedMpvVersion,
      ffmpegVersionCache: _cachedFfmpegVersion,
    );
  }

  /// 读取最新原生轨道并刷新侧栏列表。
  void refreshMetadata() => _emitMediaMetadataSnapshot();

  /// 应用播放/画质/字幕/着色器/音频设备实时更新（异步校验着色器路径，避免主线程同步盘检）。
  void applyLiveQualityConfig(PlaybackQualityConfig config) {
    _lastQualityConfig = config;
    final client = _client;
    if (_disposed || client == null || client.isDisposed) return;
    _usingSoftwareFallback =
        !config.hardwareDecode ||
        config.preset == VideoQualityPreset.softwareFallback;
    unawaited(_applyLiveQualityAsync(client, config));
  }

  Future<void> _applyLiveQualityAsync(
    LibMpvClient client,
    PlaybackQualityConfig config,
  ) async {
    final verifiedShaders = await MpvQualityProfile.filterExistingShaderPaths(
      config.activeShaderPaths,
    );
    if (_disposed || client.isDisposed) return;
    MpvQualityProfile.applyLiveQualityUpdate(
      client,
      config: config,
      desktopDelegate: desktopProfileDelegate,
      verifiedShaderPaths: verifiedShaders,
      onExclusiveFallbackNotice: onNotice,
      logStore: logStore,
    );
    onApplyAudiophileSafetyChain?.call(client);
    _emitMediaMetadataSnapshot();
  }

  /// 同步播放控制与轨道操作封装（恢复播放时施加 S 型微淡入斜坡防爆音）。
  void setPlaying(bool playing) {
    final client = _client;
    if (_disposed || client == null || client.isDisposed) return;
    final wasPaused = client.getPropertyFlag('pause') ?? false;
    if (playing && wasPaused) {
      onTriggerMicroFadeIn?.call(
        client,
        targetVolume: _desiredVolume,
        isMuted: _isMuted,
      );
    }
    client.setPropertyFlag('pause', !playing);
  }

  /// 绝对时间点 Seek（命中 `demuxer-cache-state/seekable-ranges` 内存环形缓冲时返回 `true` 并抑制缓冲遮罩）。
  bool seekAbsolute(double seconds) {
    final client = _client;
    if (_disposed || client == null || client.isDisposed) return false;
    final target = seconds < 0 ? 0.0 : seconds;
    final ranges = client.readDemuxerSeekableRanges();
    final cachedHit = MpvSeekableRange.isPositionCached(target, ranges);
    if (cachedHit) {
      _suppressBufferingUntil = DateTime.now().add(
        const Duration(milliseconds: 900),
      );
      onBufferingChanged?.call(false);
    } else {
      _suppressBufferingUntil = null;
    }
    client.command(['seek', target.toStringAsFixed(3), 'absolute', 'exact']);
    if (!(client.getPropertyFlag('pause') ?? false)) {
      onTriggerMicroFadeIn?.call(
        client,
        targetVolume: _desiredVolume,
        isMuted: _isMuted,
      );
    }
    return cachedHit;
  }

  void seekRelative(double deltaSeconds) {
    _client?.command(['seek', deltaSeconds.toStringAsFixed(3), 'relative']);
  }

  void stepFrameForward() {
    _client?.setPropertyFlag('pause', true);
    _client?.command(['frame-step']);
  }

  void stepFrameBackward() {
    _client?.setPropertyFlag('pause', true);
    _client?.command(['frame-back-step']);
  }

  void setSpeed(double speed) {
    _client?.setPropertyDouble('speed', speed.clamp(0.25, 4.0));
  }

  void setVolume(double volume) {
    _desiredVolume = volume.clamp(0.0, 100.0);
    _client?.setPropertyDouble('volume', _desiredVolume);
  }

  void setMute(bool muted) {
    _isMuted = muted;
    _client?.setPropertyFlag('mute', muted);
  }

  /// 在不重建解码会话的前提下无缝切换视频轨道开关（用于视频小窗切换后台纯音频模式）。
  void setVideoTrackEnabled(bool enabled) {
    if (_videoTrackEnabled == enabled) return;
    _videoTrackEnabled = enabled;
    final client = _client;
    if (_disposed || client == null || client.isDisposed) return;
    if (!enabled) {
      final currentVid = client.getPropertyString('vid');
      if (currentVid != null && currentVid.isNotEmpty && currentVid != 'no') {
        _savedVidBeforeDisable = currentVid;
      }
      client.setPropertyString('vid', 'no');
    } else {
      final restore = _savedVidBeforeDisable;
      _savedVidBeforeDisable = null;
      client.setPropertyString(
        'vid',
        (restore != null && restore.isNotEmpty) ? restore : 'auto',
      );
      if (_useAndroidSurfaceSession && _androidSurface != null) {
        unawaited(attachOrRebindAndroidSurface(_androidSurface!));
      }
    }
  }

  /// 动态应用视频画面比例模式。
  void applyAspectMode(VideoAspectMode mode) {
    _aspectMode = mode;
    final client = _client;
    if (_disposed || client == null || client.isDisposed) return;
    _applyAspectModeToClient(client, mode);
  }

  void _applyAspectModeToClient(LibMpvClient client, VideoAspectMode mode) {
    switch (mode) {
      case VideoAspectMode.auto:
        client.setPropertyFlag('keepaspect', true);
        client.setPropertyDouble('panscan', 0.0);
        client.setPropertyString('video-aspect-override', '-1');
      case VideoAspectMode.cover:
        client.setPropertyFlag('keepaspect', true);
        client.setPropertyDouble('panscan', 1.0);
        client.setPropertyString('video-aspect-override', '-1');
      case VideoAspectMode.stretch:
        client.setPropertyFlag('keepaspect', false);
        client.setPropertyDouble('panscan', 0.0);
        client.setPropertyString('video-aspect-override', '-1');
      case VideoAspectMode.ratio16x9:
        client.setPropertyFlag('keepaspect', true);
        client.setPropertyDouble('panscan', 0.0);
        client.setPropertyString('video-aspect-override', '16:9');
      case VideoAspectMode.ratio4x3:
        client.setPropertyFlag('keepaspect', true);
        client.setPropertyDouble('panscan', 0.0);
        client.setPropertyString('video-aspect-override', '4:3');
    }
  }

  /// 严格按「停止事件订阅 -> 释放 D3D11/Android 渲染句柄 -> 异步 `mpv_terminate_destroy` -> 注销流网桥」串行释放。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    ++_loadGeneration;
    _firstFrameWatchdogTimer?.cancel();
    _firstFrameWatchdogTimer = null;
    _pendingRemoteSidecarJob = null;

    await _eventSub?.cancel();
    _eventSub = null;
    await _desktopSurfaceChangeSub?.cancel();
    _desktopSurfaceChangeSub = null;
    await _androidSurfaceSub?.cancel();
    _androidSurfaceSub = null;

    final surfaceSessionId = _desktopSurfaceSessionId;
    _desktopSurfaceSessionId = null;
    final wasGpuNextUnderlay = _usingGpuNextUnderlay;
    _usingGpuNextUnderlay = false;
    if (surfaceSessionId != null &&
        surfaceSessionId > 0 &&
        desktopSurfaceBridge != null) {
      if (wasGpuNextUnderlay) {
        // vo=gpu-next 持有底层子窗口交换链，须先隐藏视口并关闭 libmpv，再销毁子窗口句柄。
        await desktopSurfaceBridge!.setViewportRect(
          sessionId: surfaceSessionId,
          leftPx: 0,
          topPx: 0,
          rightPx: 0,
          bottomPx: 0,
          visible: false,
        );
      } else {
        await desktopSurfaceBridge!.disposeSession(surfaceSessionId);
      }
    }

    final androidSurf = _androidSurface;
    _androidSurface = null;
    if (androidSurf != null || _useAndroidSurfaceSession) {
      await _androidSurfaceSerial.catchError((Object e) {
        logStore?.record('mpv-surface', '销毁期等待表面队列异常：$e', isError: true);
      });
      final activeClient = _client;
      if (activeClient != null &&
          !activeClient.isDisposed &&
          activeClient.isInitialized) {
        activeClient.setPropertyString('vo', 'null');
        activeClient.setPropertyString('wid', '0');
      }
      _boundAndroidWid = 0;
      _boundAndroidWidth = 0;
      _boundAndroidHeight = 0;
      _boundAndroidHdrPeak = -1;
    }
    if (androidSurf != null) {
      await androidSurf.releaseSurface();
      await androidSurf.dispose();
    }

    final client = _client;
    _client = null;
    if (client != null && !client.isDisposed) {
      if (wasGpuNextUnderlay && client.isInitialized) {
        client.setPropertyString('vo', 'null');
        client.setPropertyString('wid', '0');
      }
      await client.dispose();
    }

    if (wasGpuNextUnderlay &&
        surfaceSessionId != null &&
        surfaceSessionId > 0 &&
        desktopSurfaceBridge != null) {
      await desktopSurfaceBridge!.disposeSession(surfaceSessionId);
    }

    final tokens = List<String>.from(_activeStreamTokens);
    _activeStreamTokens.clear();
    await _unregisterTokens(tokens);

    _textureId.dispose();
    _underlayActive.dispose();
    _renderBackend.dispose();
    _adapterName.dispose();
  }
}
