import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../domain/models/media_source.dart';
import '../../domain/models/media_variant.dart';
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
import 'android/android_video_surface_controller.dart';
import 'konata_video_texture_bridge.dart';
import 'libmpv_ffi.dart';
import 'mpv_quality_profile.dart';
import 'playback_probe.dart';

/// 单次内置视频装载描述。
class EmbeddedVideoLoadRequest {
  /// 创建视频装载请求。
  const EmbeddedVideoLoadRequest({
    required this.workId,
    required this.variant,
    this.source,
    this.startSeconds = 0,
    this.initialWidth = 1280,
    this.initialHeight = 720,
  });

  final String workId;
  final MediaVariant variant;
  final MediaSource? source;
  final int startSeconds;
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
/// 外挂音轨/字幕挂载、硬解容错软解回退、纯视频无损截图及安全串行销毁）。
class EmbeddedMpvSession {
  /// 创建内置视频会话实例。
  EmbeddedMpvSession({
    required this.storageRoot,
    required this.streamBridge,
    this.logStore,
    this.clientFactory,
    this.d3d11Bridge,
    this.gatewayFactory = const MediaSourceGatewayFactory(),
    this.probeCollector = const PlaybackProbeCollector(),
    this.subtitleDirectoryIndex,
  });

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

  final StorageRootService storageRoot;
  final LocalStreamBridge streamBridge;
  final DiagnosticsLogStore? logStore;
  final LibMpvClient Function()? clientFactory;
  final KonataVideoTextureBridge? d3d11Bridge;
  final MediaSourceGatewayFactory gatewayFactory;
  final PlaybackProbeCollector probeCollector;
  final SubtitleDirectoryIndex? subtitleDirectoryIndex;

  final ValueNotifier<int?> _textureId = ValueNotifier<int?>(null);
  final ValueNotifier<String> _renderBackend = ValueNotifier<String>('');
  final ValueNotifier<String> _adapterName = ValueNotifier<String>('');

  /// Flutter `Texture(textureId: ...)` 响应句柄。
  ValueListenable<int?> get textureIdListenable => _textureId;

  /// 当前实际图形后端名称（`d3d11` / `sw` / `gpu`）。
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

  LibMpvClient? _client;
  StreamSubscription<MpvClientEvent>? _eventSub;
  StreamSubscription<D3D11TextureChangedEvent>? _d3d11ChangeSub;
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

  int? _d3d11SessionId;
  final List<String> _activeStreamTokens = [];
  List<String> _pendingExternalSubtitles = const [];
  List<String> _pendingExternalAudioPaths = const [];
  CrossEpisodeTrackMemory _trackMemory = const CrossEpisodeTrackMemory();
  TrackPreferences _trackPreferences = const TrackPreferences();
  String _currentMediaTarget = '';
  double _lastPositionSeconds = 0.0;
  double? _pendingInitialSeekSeconds;
  double _totalDurationSeconds = 0.0;
  int _loadGeneration = 0;
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

  /// 实时读取当前底层精确播放秒数（OSD 隐藏退订期间供低频持久化与唤醒同步使用）。
  double? readCurrentPositionSeconds() {
    final client = _client;
    if (_disposed || client == null || client.isDisposed || !client.isInitialized) {
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
    if (_disposed || client == null || client.isDisposed || !client.isInitialized) {
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

  /// 初始化底层 `libmpv`（Windows 创建 D3D11 离屏三缓冲纹理 / Android 绑定原生像素表面）并起播首个视频。
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
    _useAndroidSurfaceSession =
        Platform.isAndroid || androidSurfaceSupplier != null;
    final useWindowsD3D11 = Platform.isWindows && !_useAndroidSurfaceSession;
    final isRemote =
        request.source != null && request.source!.kind != MediaSourceKind.local;

    final mpvDir = await storageRoot.ensureMpvConfigDir();
    final workPhotoDir = await _resolveScreenshotDir(request.workId);
    if (Platform.isAndroid) {
      await AndroidVideoSurfaceController.preparePortableCjkFontSymlinks(
        mpvDir,
      );
    }

    final client = clientFactory != null
        ? clientFactory!()
        : FfiLibMpvClient.create();
    _client = client;

    final hwdecValue = MpvQualityProfile.resolveHwdecValue(
      config: qualityConfig,
      isWindows: useWindowsD3D11,
      isAndroid: _useAndroidSurfaceSession,
    );
    _hwdecWasEnabled = hwdecValue != 'no';
    _usingSoftwareFallback = !_hwdecWasEnabled;

    MpvQualityProfile.applyPreInitVideoOptions(
      client,
      config: qualityConfig,
      mpvConfigDir: mpvDir,
      screenshotDir: workPhotoDir,
      isRemoteStream: isRemote,
      isWindowsOverride: useWindowsD3D11,
      isAndroidOverride: _useAndroidSurfaceSession,
      logStore: logStore,
    );

    if (useWindowsD3D11) {
      client.setOptionString('gpu-api', 'd3d11');
    }

    final initRc = client.initialize();
    if (initRc < 0) {
      throw StateError('内置播放器初始化失败: ${client.errorString(initRc)}');
    }

    // 请求 warn 级别日志以便及时捕捉硬解回退信号
    client.requestLogMessages('warn');
    _cachedMpvVersion = client.getPropertyString('mpv-version');
    _cachedFfmpegVersion = client.getPropertyString('ffmpeg-version');

    if (useWindowsD3D11 && d3d11Bridge != null) {
      final handle = await d3d11Bridge!.createSession(
        mpvHandleAddress: client.handleAddress,
        width: request.initialWidth,
        height: request.initialHeight,
        preferSoftware:
            !qualityConfig.hardwareDecode ||
            qualityConfig.preset == VideoQualityPreset.softwareFallback,
      );
      _d3d11SessionId = handle.sessionId;
      _textureId.value = handle.textureId;
      _renderBackend.value = handle.backend;
      _adapterName.value = handle.adapterName;
      if (handle.isSoftwareFallback) {
        _usingSoftwareFallback = true;
      }
      _d3d11ChangeSub = d3d11Bridge!.textureChanges.listen((event) {
        if (_disposed || event.sessionId != _d3d11SessionId) return;
        _textureId.value = event.textureId;
        _renderBackend.value = event.backend;
        _adapterName.value = event.adapterName;
        if (event.backend == 'sw') {
          _usingSoftwareFallback = true;
        }
        if (event.reason.isNotEmpty) {
          onNotice?.call(
            event.backend == 'sw'
                ? '图形设备已切换为软件兼容渲染 (${event.reason})'
                : 'D3D11 渲染表面已重建',
          );
        }
      });
    }

    MpvQualityProfile.applyPostInitVideoProperties(
      client,
      config: qualityConfig,
      isWindowsOverride: useWindowsD3D11,
      onWasapiFallbackNotice: onNotice,
      logStore: logStore,
    );
    client.setPropertyDouble('volume', initialVolume.clamp(0.0, 100.0));

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
    MpvQualityProfile.applyRuntimeStreamProfile(
      client,
      isRemoteStream: isRemote,
      isAudio: false,
      config: _lastQualityConfig,
      logStore: logStore,
    );

    if (request.startSeconds > 0) {
      final startRc = client.setPropertyString(
        'start',
        '+${request.startSeconds}',
      );
      if (startRc < 0) {
        client.setPropertyDouble('start', request.startSeconds.toDouble());
      }
      _pendingInitialSeekSeconds = request.startSeconds.toDouble();
    } else {
      client.setPropertyString('start', 'none');
      _pendingInitialSeekSeconds = null;
    }
    client.setPropertyDouble('sub-delay', 0.0);
    client.setPropertyDouble('audio-delay', 0.0);
    client.setPropertyString('vid', _videoTrackEnabled ? 'auto' : 'no');
    _applyAspectModeToClient(client, _aspectMode);
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
        // 优先让主视频流独占 AList / OpenList / CD2 通道完成首帧建联，待 FileLoaded 后再异步补扫目录与下载外挂字幕。
        _pendingRemoteSidecarJob = (request: request, generation: generation);
      }
    }
  }

  Future<
    ({
      String mediaTarget,
      List<String> subtitlePaths,
      List<String> audioTargets,
    })
  >
  _prepareMediaAndSidecars(EmbeddedVideoLoadRequest request) async {
    final source = request.source;
    final variant = request.variant;

    if (source == null || source.kind == MediaSourceKind.local) {
      if (source == null) {
        return (
          mediaTarget: variant.relativePath,
          subtitlePaths: variant.externalSubtitles,
          audioTargets: const <String>[],
        );
      }
      final gw = LocalSourceGateway(rootPath: source.location);
      final mediaAbs = gw.resolveAbsolutePath(variant.relativePath);
      final candidates = <String>[];
      try {
        final parentRel = SubtitleAndAudioChoices.parentDirOf(
          variant.relativePath,
        );
        final entries = await gw.listDirectory(parentRel);
        for (final entry in entries) {
          if (!entry.isDirectory) candidates.add(entry.relativePath);
        }
        final audioSubRel = parentRel.isEmpty ? 'Audio' : '$parentRel/Audio';
        try {
          final subEntries = await gw.listDirectory(audioSubRel);
          for (final entry in subEntries) {
            if (!entry.isDirectory) candidates.add(entry.relativePath);
          }
        } catch (_) {}
      } catch (_) {}

      final matchedSubs = SubtitleMatcher.matchForVideo(
        videoRelativePath: variant.relativePath,
        allSubtitleRelativePaths: {
          ...candidates,
          ...variant.externalSubtitles,
        }.toList(),
      );
      final absSubs = <String>[];
      for (final rel in {
        ...matchedSubs.subtitlePaths,
        ...variant.externalSubtitles,
      }) {
        final abs = gw.resolveAbsolutePath(rel);
        if (await File(abs).exists()) absSubs.add(abs);
      }

      final matchedAudioRel =
          SubtitleAndAudioChoices.findMatchingExternalAudioPaths(
            videoRelativePath: variant.relativePath,
            candidatePaths: candidates,
          );
      final absAudio = <String>[];
      for (final rel in matchedAudioRel) {
        final abs = gw.resolveAbsolutePath(rel);
        if (await File(abs).exists()) absAudio.add(abs);
      }

      return (
        mediaTarget: mediaAbs,
        subtitlePaths: absSubs,
        audioTargets: absAudio,
      );
    }

    // WebDAV / SMB 远程流式透传：仅先注册主媒体流秒速调用 loadfile，目录枚举与外挂字幕/音轨延后至后台异步挂载
    final mainGw = await gatewayFactory.create(source);
    if (mainGw is! ByteRangeReadableGateway) {
      await mainGw.close();
      throw UnsupportedError('媒体源 ${source.kind.name} 不支持流式透传播放');
    }
    final byteGw = mainGw as ByteRangeReadableGateway;
    final mainReg = await streamBridge.registerSession(
      gateway: byteGw,
      relativePath: variant.relativePath,
      fileName: variant.fileName,
      knownLength: variant.fileSize > 0 ? variant.fileSize : null,
      ownsGateway: true,
    );
    _activeStreamTokens.add(mainReg.token);

    final cachedSubs = await streamBridge.resolveExistingCachedSubtitles(
      workId: request.workId,
      subtitleRelativePaths: variant.externalSubtitles,
    );
    return (
      mediaTarget: mainReg.url.toString(),
      subtitlePaths: cachedSubs,
      audioTargets: const <String>[],
    );
  }

  Future<void> _discoverAndAttachRemoteSidecars(
    EmbeddedVideoLoadRequest request, {
    required int generation,
  }) async {
    final source = request.source;
    final variant = request.variant;
    if (_disposed ||
        generation != _loadGeneration ||
        source == null ||
        source.kind == MediaSourceKind.local) {
      return;
    }

    final sidecarGw = await gatewayFactory.create(source);
    if (sidecarGw is! ByteRangeReadableGateway) {
      await sidecarGw.close();
      return;
    }
    final byteGw = sidecarGw as ByteRangeReadableGateway;
    final stagedAudioTokens = <String>[];

    try {
      final siblingPaths = <String>[...variant.externalSubtitles];
      try {
        final parentRel = SubtitleAndAudioChoices.parentDirOf(
          variant.relativePath,
        );
        final cachedSnapshot = subtitleDirectoryIndex?.lookup(
          source.id,
          parentRel,
        );
        if (cachedSnapshot != null) {
          siblingPaths.addAll(cachedSnapshot.siblingPaths);
        } else {
          final entries = await sidecarGw.listDirectory(parentRel);
          if (_disposed || generation != _loadGeneration) return;

          final discoveredPaths = <String>[];
          final candidateSubdirs = <String>[];
          for (final entry in entries) {
            if (!entry.isDirectory) {
              discoveredPaths.add(entry.relativePath);
            } else {
              final lowerName = entry.name.toLowerCase();
              if (lowerName == 'subs' ||
                  lowerName == 'subtitles' ||
                  lowerName == '字幕' ||
                  lowerName == 'audio' ||
                  lowerName == 'sp audio') {
                candidateSubdirs.add(entry.relativePath);
              }
            }
          }
          var scannedSubdirs = 0;
          for (final subDir in candidateSubdirs) {
            if (scannedSubdirs >=
                SubtitleDirectoryIndex.maxAutoSubdirScanCount) {
              break;
            }
            scannedSubdirs += 1;
            try {
              final subEntries = await sidecarGw.listDirectory(subDir);
              for (final sub in subEntries) {
                if (!sub.isDirectory) discoveredPaths.add(sub.relativePath);
              }
            } catch (_) {}
          }
          subtitleDirectoryIndex?.put(
            sourceId: source.id,
            dirRelativePath: parentRel,
            siblingPaths: discoveredPaths,
            hasUnscannedSubdirs: candidateSubdirs.length > scannedSubdirs,
            scannedSubdirCount: scannedSubdirs,
          );
          siblingPaths.addAll(discoveredPaths);
        }
      } catch (_) {}

      if (_disposed || generation != _loadGeneration) return;

      final matchedSubs = SubtitleMatcher.matchForVideo(
        videoRelativePath: variant.relativePath,
        allSubtitleRelativePaths: siblingPaths,
      );
      final localSubs = await streamBridge.materializeRemoteSubtitles(
        gateway: byteGw,
        workId: request.workId,
        subtitleRelativePaths: {
          ...matchedSubs.subtitlePaths,
          ...variant.externalSubtitles,
        }.toList(),
      );
      if (_disposed || generation != _loadGeneration) return;

      final matchedAudioRel =
          SubtitleAndAudioChoices.findMatchingExternalAudioPaths(
            videoRelativePath: variant.relativePath,
            candidatePaths: siblingPaths,
          );
      final audioUrls = <String>[];
      for (final audioRel in matchedAudioRel) {
        if (_disposed || generation != _loadGeneration) {
          await _unregisterTokens(stagedAudioTokens);
          return;
        }
        try {
          final extGw = await gatewayFactory.create(source);
          if (extGw is! ByteRangeReadableGateway) {
            await extGw.close();
            continue;
          }
          final reg = await streamBridge.registerSession(
            gateway: extGw as ByteRangeReadableGateway,
            relativePath: audioRel,
            fileName: p.basename(audioRel),
            ownsGateway: true,
          );
          stagedAudioTokens.add(reg.token);
          audioUrls.add(reg.url.toString());
        } catch (_) {}
      }

      if (_disposed || generation != _loadGeneration) {
        await _unregisterTokens(stagedAudioTokens);
        return;
      }

      _activeStreamTokens.addAll(stagedAudioTokens);
      _pendingExternalSubtitles = localSubs;
      _pendingExternalAudioPaths = audioUrls;
      if (_fileLoadedForCurrentGen) {
        _mountSidecarsAndResolveTracks();
      }
    } finally {
      await sidecarGw.close().catchError((_) {});
    }
  }

  Future<void> _unregisterTokens(List<String> tokens) async {
    for (final token in tokens) {
      try {
        await streamBridge.unregisterSession(token);
      } catch (_) {}
    }
  }

  void _handleMpvEvent(MpvClientEvent event) {
    if (_disposed) return;
    switch (event) {
      case MpvFileLoadedEvent():
        _fileLoadedForCurrentGen = true;
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
      case MpvStartFileEvent():
        onBufferingChanged?.call(true);
      case MpvSeekEvent():
      case MpvShutdownEvent():
        break;
    }
  }

  void _mountSidecarsAndResolveTracks() {
    final client = _client;
    if (client == null || client.isDisposed) return;

    final existingTracks = client.readTrackList();
    final mountedNames = <String>{};
    for (final t in existingTracks) {
      final f = t.externalFilename;
      if (f != null && f.isNotEmpty) {
        mountedNames.add(p.basename(f.split('?').first).toLowerCase());
      }
    }

    // 挂载额外扫描到的外挂字幕与 .mka/.flac 外挂音轨
    final idxStems = _pendingExternalSubtitles
        .where((s) => SubtitleAndAudioChoices.extensionOf(s) == '.idx')
        .map((s) => s.replaceAll('\\', '/').toLowerCase())
        .toSet();
    for (final sub in _pendingExternalSubtitles) {
      final base = p.basename(sub.split('?').first).toLowerCase();
      if (mountedNames.contains(base)) continue;
      if (SubtitleAndAudioChoices.extensionOf(sub) == '.sub') {
        final stem = '${sub.substring(0, sub.length - 4)}.idx'
            .replaceAll('\\', '/')
            .toLowerCase();
        if (idxStems.contains(stem)) continue;
      }
      client.command(['sub-add', sub, 'auto']);
      mountedNames.add(base);
    }

    for (final aud in _pendingExternalAudioPaths) {
      final base = p.basename(aud.split('?').first).toLowerCase();
      if (mountedNames.contains(base)) continue;
      client.command(['audio-add', aud, 'auto']);
      mountedNames.add(base);
    }

    // 基于 CrossEpisodeTrackMemory 或默认简中/日语偏好锁定轨道
    final refreshedTracks = client.readTrackList();
    final chosenAudio = _trackMemory.resolveAudioTrack(
      refreshedTracks,
      fallback: _trackPreferences,
    );
    if (chosenAudio != null && !chosenAudio.selected) {
      client.setPropertyInt64('aid', chosenAudio.id);
    }

    if (_trackMemory.subtitleDisabled) {
      client.setPropertyString('sid', 'no');
    } else {
      final chosenSub = _trackMemory.resolveSubtitleTrack(
        refreshedTracks,
        fallback: _trackPreferences,
      );
      if (chosenSub != null && !chosenSub.selected) {
        client.setPropertyInt64('sid', chosenSub.id);
      }
    }

    _emitMediaMetadataSnapshot();
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

  void _emitMediaMetadataSnapshot() {
    final client = _client;
    if (client == null || client.isDisposed || !client.isInitialized) return;
    final tracks = client.readTrackList();
    final subs = SubtitleAndAudioChoices.mergeSubtitles(
      mpvTracks: tracks,
      discoveredExternalPaths: _pendingExternalSubtitles,
    );
    final audios = SubtitleAndAudioChoices.mergeAudioTracks(
      mpvTracks: tracks,
      discoveredExternalAudioPaths: _pendingExternalAudioPaths,
    );
    final chapters = client.readChapterList(
      totalDurationSeconds: _totalDurationSeconds > 0
          ? _totalDurationSeconds
          : null,
    );
    final devices = client.readAudioDeviceList();
    onMediaMetadataUpdated?.call(
      subtitles: subs,
      audioTracks: audios,
      chapters: chapters,
      audioDevices: devices,
    );
  }

  void _handlePropertyEvent(MpvPropertyChangeEvent e) {
    switch (e.replyUserdata) {
      case _propTimePos:
        if (!_positionObserved) return;
        final pos = e.doubleValue;
        if (pos != null && pos.isFinite) {
          _lastPositionSeconds = pos;
          onPositionChanged?.call(pos);
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
    final isFatalHwdecError =
        level == 'fatal' &&
        (msg.contains('hwdec') ||
            msg.contains('d3d11va') ||
            msg.contains('dxva2') ||
            msg.contains('mediacodec') ||
            msg.contains('hardware decoding'));
    final isExplicitUnrecoverable =
        msg.contains('hardware decoding failed') ||
        msg.contains('failed to create direct3d');
    if (isFatalHwdecError || isExplicitUnrecoverable) {
      _triggerSoftwareDecodeFallback();
    }
  }

  void _handleEndFile(MpvEndFileEvent event) {
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

  /// 同步更新运行中的 Windows D3D11 渲染目标分辨率。
  Future<void> resizeD3D11Target(int width, int height) async {
    final id = _d3d11SessionId;
    final bridge = d3d11Bridge;
    if (_disposed || id == null || bridge == null || !Platform.isWindows) {
      return;
    }
    await bridge.resize(sessionId: id, width: width, height: height);
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

  /// 应用播放/画质/字幕/着色器/音频设备实时更新。
  void applyLiveQualityConfig(PlaybackQualityConfig config) {
    _lastQualityConfig = config;
    final client = _client;
    if (_disposed || client == null || client.isDisposed) return;
    _usingSoftwareFallback =
        !config.hardwareDecode ||
        config.preset == VideoQualityPreset.softwareFallback;
    MpvQualityProfile.applyLiveQualityUpdate(
      client,
      config: config,
      onWasapiFallbackNotice: onNotice,
      logStore: logStore,
    );
    _emitMediaMetadataSnapshot();
  }

  /// 同步播放控制与轨道操作封装。
  void setPlaying(bool playing) => _client?.setPropertyFlag('pause', !playing);

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
    _client?.setPropertyDouble('volume', volume.clamp(0.0, 100.0));
  }

  void setMute(bool muted) => _client?.setPropertyFlag('mute', muted);

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

  void setSubtitleDelay(double seconds) {
    final client = _client;
    if (_disposed || client == null || client.isDisposed) return;
    final rc = client.setPropertyDouble('sub-delay', seconds);
    if (rc < 0) {
      client.setPropertyString('sub-delay', seconds.toStringAsFixed(2));
    }
    if (client.getPropertyFlag('pause') ?? false) {
      client.command(['seek', '0', 'relative', 'exact']);
    }
  }

  void setAudioDelay(double seconds) {
    final client = _client;
    if (_disposed || client == null || client.isDisposed) return;
    final rc = client.setPropertyDouble('audio-delay', seconds);
    if (rc < 0) {
      client.setPropertyString('audio-delay', seconds.toStringAsFixed(2));
    }
  }

  void selectSubtitle(SubtitleChoice? choice) {
    final client = _client;
    if (client == null || client.isDisposed) return;
    if (choice == null) {
      client.setPropertyString('sid', 'no');
    } else if (choice.mpvTrackId != null) {
      final trackId = choice.mpvTrackId!;
      final rc = client.setPropertyInt64('sid', trackId);
      if (rc < 0) {
        client.setPropertyString('sid', '$trackId');
      }
    } else if (choice.externalPath != null && choice.externalPath!.isNotEmpty) {
      client.command(['sub-add', choice.externalPath!, 'select']);
    }
    _emitMediaMetadataSnapshot();
  }

  void addExternalSubtitleFile(String absolutePath) {
    final client = _client;
    if (client == null || client.isDisposed || absolutePath.trim().isEmpty) {
      return;
    }
    client.command(['sub-add', absolutePath.trim(), 'select']);
    _emitMediaMetadataSnapshot();
  }

  void selectAudioTrack(AudioTrackChoice choice) {
    final client = _client;
    if (client == null || client.isDisposed) return;
    if (choice.mpvTrackId != null) {
      final trackId = choice.mpvTrackId!;
      final rc = client.setPropertyInt64('aid', trackId);
      if (rc < 0) {
        client.setPropertyString('aid', '$trackId');
      }
    } else if (choice.externalPath != null && choice.externalPath!.isNotEmpty) {
      client.command(['audio-add', choice.externalPath!, 'select']);
    }
    _emitMediaMetadataSnapshot();
  }

  static const MethodChannel _mediaStoreChannel = MethodChannel(
    'ccplayer/media_store',
  );

  /// 截取纯净原画 PNG 视频帧（不含 UI/HUD 浮层），保存至作品目录并防重名。
  Future<File?> captureCleanScreenshot({
    required Directory workPhotoDir,
    String? episodeTag,
    ScreenshotCaptureMode mode = ScreenshotCaptureMode.pureVideo,
  }) async {
    final res = await captureScreenshot(
      workPhotoDir: workPhotoDir,
      episodeTag: episodeTag,
      mode: mode,
    );
    return res?.file;
  }

  /// 双模原画截图（支持 `video` 纯净帧与 `subtitles` 含字幕帧）：
  /// - 统一通过 FFI 参数数组 `["screenshot-to-file", path, mode]` 调用，零字符串转义风险；
  /// - Android 端通过 `MediaStore` `IS_PENDING` 事务原子写入系统相册并幂等删除临时文件。
  Future<ScreenshotCaptureResult?> captureScreenshot({
    required Directory workPhotoDir,
    String? episodeTag,
    ScreenshotCaptureMode mode = ScreenshotCaptureMode.pureVideo,
    String albumName = 'Konata',
    Future<String?> Function(File tempFile, String displayName, String album)?
    androidMediaStorePublisher,
  }) async {
    final client = _client;
    if (_disposed || client == null || client.isDisposed) return null;
    final targetFile = await storageRoot.allocateWorkScreenshotFile(
      workPhotoDirectory: workPhotoDir,
      timestamp: DateTime.now(),
      episodeTag: episodeTag,
    );
    final rc = client.command([
      'screenshot-to-file',
      targetFile.path,
      mode.mpvFlag,
    ]);
    if (rc < 0) return null;
    var ready = false;
    for (var i = 0; i < 10; i++) {
      if (await targetFile.exists() && await targetFile.length() > 0) {
        ready = true;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 35));
    }
    if (!ready && !await targetFile.exists()) {
      return null;
    }

    final useAndroidGallery =
        Platform.isAndroid || androidMediaStorePublisher != null;
    if (useAndroidGallery) {
      final displayName = p.basename(targetFile.path);
      try {
        final uri = androidMediaStorePublisher != null
            ? await androidMediaStorePublisher(
                targetFile,
                displayName,
                albumName,
              )
            : await _mediaStoreChannel.invokeMethod<String>(
                'saveImageToGallery',
                <String, Object>{
                  'sourcePath': targetFile.path,
                  'displayName': displayName,
                  'albumName': albumName,
                  'mimeType': 'image/png',
                },
              );
        if (uri != null && uri.isNotEmpty) {
          return ScreenshotCaptureResult(
            mode: mode,
            displayLabel: '系统相册 / Pictures/$albumName/$displayName',
            galleryUri: uri,
          );
        }
      } catch (e) {
        logStore?.record(
          'screenshot-mediastore',
          'MediaStore publish failed: $e',
          isError: true,
        );
      } finally {
        try {
          if (await targetFile.exists()) {
            await targetFile.delete();
          }
        } catch (_) {}
      }
      return null;
    }

    return ScreenshotCaptureResult(
      mode: mode,
      displayLabel: targetFile.path,
      file: targetFile,
    );
  }

  Future<Directory> _resolveScreenshotDir(String workId) async {
    final photosRoot = await storageRoot.photosRootDir();
    final safeTag = StorageRootService.encodeWorkIdTag(workId);
    final fallback = Directory(p.join(photosRoot.path, 'work [$safeTag]'));
    return fallback;
  }

  /// Android 运行期间动态接入或热重绑硬件视频表面，避免路由或容器变更后丢帧黑屏。
  Future<void> attachOrRebindAndroidSurface(
    AndroidVideoSurfaceController ctrl,
  ) async {
    if (_disposed || !_useAndroidSurfaceSession || ctrl.isDisposed) return;
    if (identical(_androidSurface, ctrl)) {
      final desc = await ctrl.queryCurrent();
      if (_disposed || desc == null) return;
      await _enqueueAndroidSurfaceUpdate(desc, sourceCtrl: ctrl);
      return;
    }

    await _androidSurfaceSub?.cancel();
    _androidSurfaceSub = null;
    final previous = _androidSurface;
    _bindAndroidSurfaceController(ctrl);

    // 先在串口队列内解绑旧表面的 EGL 与 vo，再释放其全部原生句柄
    await _enqueueAndroidSurfaceUpdate(null, sourceCtrl: previous);
    if (previous != null && !previous.isDisposed) {
      await previous.releaseSurface();
      await previous.dispose();
    }
    if (_disposed || ctrl.isDisposed) return;

    var desc = await ctrl.queryCurrent();
    if (desc == null || desc.wid <= 0 || desc.width <= 0 || desc.height <= 0) {
      try {
        desc = await ctrl.surfaceChanges
            .where(
              (e) => e != null && e.wid > 0 && e.width > 0 && e.height > 0,
            )
            .cast<AndroidSurfaceDescriptor>()
            .first
            .timeout(const Duration(milliseconds: 2500));
      } on TimeoutException {
        desc = ctrl.current;
      }
    }
    if (_disposed || desc == null) return;
    await _enqueueAndroidSurfaceUpdate(desc, sourceCtrl: ctrl);
  }

  void _bindAndroidSurfaceController(AndroidVideoSurfaceController ctrl) {
    _androidSurface = ctrl;
    unawaited(_androidSurfaceSub?.cancel());
    _androidSurfaceSub = ctrl.surfaceChanges.listen((next) {
      if (_disposed || _client == null || _client!.isDisposed) return;
      unawaited(_enqueueAndroidSurfaceUpdate(next, sourceCtrl: ctrl));
    });
  }

  Future<void> _enqueueAndroidSurfaceUpdate(
    AndroidSurfaceDescriptor? desc, {
    AndroidVideoSurfaceController? sourceCtrl,
    bool forceRebind = false,
  }) {
    final op = _androidSurfaceSerial.then((_) async {
      await _applyAndroidSurfaceUpdate(
        desc,
        sourceCtrl: sourceCtrl,
        forceRebind: forceRebind,
      );
    });
    _androidSurfaceSerial = op.catchError((Object _, StackTrace _) {});
    return op;
  }

  Future<void> _applyAndroidSurfaceUpdate(
    AndroidSurfaceDescriptor? desc, {
    AndroidVideoSurfaceController? sourceCtrl,
    bool forceRebind = false,
  }) async {
    final client = _client;
    if (_disposed ||
        client == null ||
        client.isDisposed ||
        !client.isInitialized) {
      return;
    }

    final nextWid = desc?.wid ?? 0;
    final width = desc?.width ?? 0;
    final height = desc?.height ?? 0;
    final hdrPeak = (desc?.hdrPeak ?? 0).round();

    if (nextWid != 0 && (width <= 0 || height <= 0)) {
      return;
    }

    // 同一 Surface 仅像素尺寸变化时原地更新 android-surface-size，避免重开 VO 打断硬解
    if (!forceRebind &&
        nextWid != 0 &&
        nextWid == _boundAndroidWid &&
        hdrPeak == _boundAndroidHdrPeak) {
      if (width != _boundAndroidWidth || height != _boundAndroidHeight) {
        client.setPropertyString('android-surface-size', '${width}x$height');
        _boundAndroidWidth = width;
        _boundAndroidHeight = height;
      }
      if (_videoTrackEnabled &&
          client.getPropertyString('vo') != _activeAndroidVo) {
        _applyAndroidVo(client);
      }
      return;
    }

    // 更换或卸载 Surface 前必须先置空 vo=null 与 wid=0 安全释放旧 EGLSurface
    final previousWid = _boundAndroidWid;
    client.setPropertyString('vo', 'null');
    client.setPropertyString('wid', '0');
    _boundAndroidWid = 0;
    _boundAndroidWidth = 0;
    _boundAndroidHeight = 0;
    _boundAndroidHdrPeak = -1;

    if (previousWid != 0 && previousWid != nextWid) {
      await (sourceCtrl ?? _androidSurface)?.releaseReference(previousWid);
      if (_disposed || client.isDisposed || !client.isInitialized) return;
    }

    if (nextWid <= 0) {
      return;
    }

    client.setPropertyString('android-hdr-peak', '$hdrPeak');
    client.setPropertyString('android-surface-size', '${width}x$height');
    client.setPropertyString('wid', '$nextWid');
    _boundAndroidWid = nextWid;
    _boundAndroidWidth = width;
    _boundAndroidHeight = height;
    _boundAndroidHdrPeak = hdrPeak;

    if (_videoTrackEnabled) {
      _applyAndroidVo(client);
      final vid = client.getPropertyString('vid');
      if (vid == 'no') {
        client.setPropertyString('vid', _savedVidBeforeDisable ?? 'auto');
      }
      if (client.getPropertyFlag('pause') ?? false) {
        client.command(['seek', '0', 'relative', 'exact']);
      }
    }
  }

  /// 优先挂载 `vo=gpu-next`（libplacebo 杜比视界/动态 HDR 管线），若底层驱动受限则平滑回落至 `vo=gpu`。
  void _applyAndroidVo(LibMpvClient client) {
    final rc = client.setPropertyString(
      'vo',
      MpvQualityProfile.androidVideoDriver,
    );
    if (rc >= 0) {
      _activeAndroidVo = MpvQualityProfile.androidVideoDriver;
    } else {
      client.setPropertyString('vo', MpvQualityProfile.androidLegacyVideoDriver);
      _activeAndroidVo = MpvQualityProfile.androidLegacyVideoDriver;
    }
    _renderBackend.value = _activeAndroidVo;
  }

  void _scheduleFirstFrameWatchdog() {
    _firstFrameWatchdogTimer?.cancel();
    final gen = _loadGeneration;
    _firstFrameWatchdogTimer = Timer(
      const Duration(milliseconds: 2500),
      () => unawaited(_verifyFirstFrameRenderedOrRecover(gen)),
    );
  }

  Future<void> _verifyFirstFrameRenderedOrRecover(int generation) async {
    final client = _client;
    if (_disposed ||
        generation != _loadGeneration ||
        !_videoTrackEnabled ||
        _hasRestartedFirstFrame ||
        client == null ||
        client.isDisposed ||
        !client.isInitialized) {
      return;
    }
    if (!_firstFrameWatchdogReboundOnce) {
      _firstFrameWatchdogReboundOnce = true;
      final surf = _androidSurface;
      if (surf != null && !surf.isDisposed) {
        final desc = await surf.queryCurrent();
        if (desc != null &&
            desc.wid > 0 &&
            desc.width > 0 &&
            desc.height > 0 &&
            !_disposed &&
            generation == _loadGeneration) {
          await _enqueueAndroidSurfaceUpdate(
            desc,
            sourceCtrl: surf,
            forceRebind: true,
          );
          _scheduleFirstFrameWatchdog();
          return;
        }
      }
    }
    if (!_hwdecFallbackAttempted && _hwdecWasEnabled) {
      _triggerSoftwareDecodeFallback();
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
    await _d3d11ChangeSub?.cancel();
    _d3d11ChangeSub = null;
    await _androidSurfaceSub?.cancel();
    _androidSurfaceSub = null;

    final d3dId = _d3d11SessionId;
    _d3d11SessionId = null;
    if (d3dId != null && d3dId > 0 && d3d11Bridge != null) {
      await d3d11Bridge!.disposeSession(d3dId);
    }

    final androidSurf = _androidSurface;
    _androidSurface = null;
    if (androidSurf != null || _useAndroidSurfaceSession) {
      await _androidSurfaceSerial.catchError((_) {});
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
      await client.dispose();
    }

    final tokens = List<String>.from(_activeStreamTokens);
    _activeStreamTokens.clear();
    await _unregisterTokens(tokens);

    _textureId.dispose();
    _renderBackend.dispose();
    _adapterName.dispose();
  }
}
