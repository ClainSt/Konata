import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../domain/models/media_source.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/playback/playback_probe_stats.dart';
import '../../domain/playback/subtitle_and_audio_choices.dart';
import '../../domain/playback/track_preferences.dart';
import '../logging/diagnostics_log_store.dart';
import '../sources/byte_stream_source_gateway.dart';
import '../sources/local_source_gateway.dart';
import '../sources/source_gateway_factory.dart';
import '../sources/subtitle_matcher.dart';
import '../storage/storage_root_provider.dart';
import '../stream_bridge/local_stream_bridge.dart';
import 'android/android_video_surface_controller.dart';
import 'd3d11_video_bridge.dart';
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

/// 内置 `libmpv` 视频底层会话封装（管理 Windows D3D11 共享纹理 / Android Surface、
/// 外挂音轨/字幕挂载、硬解容错软解回退、纯视频无损截图及安全串行销毁）。
class EmbeddedMpvSession {
  /// 创建内置视频会话实例。
  EmbeddedMpvSession({
    required this.storageRoot,
    required this.streamBridge,
    this.logStore,
    this.clientFactory,
    D3D11VideoBridge? d3d11Bridge,
    this.gatewayFactory = const MediaSourceGatewayFactory(),
    this.probeCollector = const PlaybackProbeCollector(),
  }) : _d3d11Bridge = d3d11Bridge ?? D3D11VideoBridge();

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
  final D3D11VideoBridge _d3d11Bridge;
  final MediaSourceGatewayFactory gatewayFactory;
  final PlaybackProbeCollector probeCollector;

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
  bool _disposed = false;
  String? _cachedMpvVersion;
  String? _cachedFfmpegVersion;
  PlaybackQualityConfig _lastQualityConfig = const PlaybackQualityConfig();
  DateTime? _suppressBufferingUntil;

  bool get isDisposed => _disposed;
  bool get isInitialized => _client?.isInitialized ?? false;
  bool get isUsingSoftwareFallback => _usingSoftwareFallback;

  /// 初始化底层 `libmpv`（Windows 创建 D3D11 离屏三缓冲纹理 / Android 绑定 `wid`）并起播首个视频。
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
    final isRemote =
        request.source != null && request.source!.kind != MediaSourceKind.local;

    final mpvDir = await storageRoot.ensureMpvConfigDir();
    final workPhotoDir = await _resolveScreenshotDir(request.workId);
    if (Platform.isAndroid) {
      await AndroidVideoSurfaceController.preparePortableCjkFontSymlinks(
        mpvDir,
      );
    }

    int? androidWid;
    if (Platform.isAndroid && androidSurfaceSupplier != null) {
      final ctrl = await androidSurfaceSupplier();
      _androidSurface = ctrl;
      var desc = await ctrl.queryCurrent();
      if (desc == null || desc.wid <= 0) {
        desc = await ctrl.surfaceChanges
            .where((e) => e != null && e.wid > 0)
            .cast<AndroidSurfaceDescriptor>()
            .first
            .timeout(const Duration(seconds: 6));
      }
      androidWid = desc.wid;
      _renderBackend.value = 'gpu';
      _androidSurfaceSub = ctrl.surfaceChanges.listen((next) {
        if (_disposed || _client == null || _client!.isDisposed) return;
        if (next != null && next.wid > 0) {
          _client!.setPropertyInt64('wid', next.wid);
        }
      });
    }

    final client = clientFactory != null
        ? clientFactory!()
        : FfiLibMpvClient.create();
    _client = client;

    final hwdecValue = MpvQualityProfile.resolveHwdecValue(
      config: qualityConfig,
      isWindows: Platform.isWindows,
      isAndroid: Platform.isAndroid,
    );
    _hwdecWasEnabled = hwdecValue != 'no';
    _usingSoftwareFallback = !_hwdecWasEnabled;

    MpvQualityProfile.applyPreInitVideoOptions(
      client,
      config: qualityConfig,
      mpvConfigDir: mpvDir,
      screenshotDir: workPhotoDir,
      isRemoteStream: isRemote,
      logStore: logStore,
    );

    if (Platform.isWindows) {
      client.setOptionString('gpu-api', 'd3d11');
    } else if (androidWid != null && androidWid > 0) {
      client.setOptionString('wid', androidWid.toString());
    }

    final initRc = client.initialize();
    if (initRc < 0) {
      throw StateError('内置播放器初始化失败: ${client.errorString(initRc)}');
    }

    // 请求 warn 级别日志以便及时捕捉硬解回退信号
    client.requestLogMessages('warn');
    _cachedMpvVersion = client.getPropertyString('mpv-version');
    _cachedFfmpegVersion = client.getPropertyString('ffmpeg-version');

    if (Platform.isWindows) {
      final handle = await _d3d11Bridge.createSession(
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
      _d3d11ChangeSub = _d3d11Bridge.textureChanges.listen((event) {
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
      onWasapiFallbackNotice: onNotice,
      logStore: logStore,
    );
    client.setPropertyDouble('volume', initialVolume.clamp(0.0, 100.0));

    client.observeProperty(_propTimePos, 'time-pos', MpvFormat.double_);
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
    _fileLoadedForCurrentGen = false;
    _hasRestartedFirstFrame = false;
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
    client.setPropertyFlag('pause', false);

    final rc = client.command(['loadfile', resolved.mediaTarget, 'replace']);
    await _unregisterTokens(previousTokens);
    if (rc < 0) {
      onFatalError?.call('视频装载失败: ${client.errorString(rc)}');
      return;
    }

    if (request.source != null &&
        request.source!.kind != MediaSourceKind.local) {
      unawaited(
        _discoverAndAttachRemoteSidecars(request, generation: generation),
      );
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

    return (
      mediaTarget: mainReg.url.toString(),
      subtitlePaths: const <String>[],
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
        final entries = await sidecarGw.listDirectory(parentRel);
        if (_disposed || generation != _loadGeneration) return;

        for (final entry in entries) {
          if (!entry.isDirectory) {
            siblingPaths.add(entry.relativePath);
          } else {
            final lowerName = entry.name.toLowerCase();
            if (lowerName == 'subs' ||
                lowerName == 'subtitles' ||
                lowerName == 'audio' ||
                lowerName == 'sp audio') {
              try {
                final subEntries = await sidecarGw.listDirectory(
                  entry.relativePath,
                );
                for (final sub in subEntries) {
                  if (!sub.isDirectory) siblingPaths.add(sub.relativePath);
                }
              } catch (_) {}
            }
          }
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
      case MpvPlaybackRestartEvent():
        _hasRestartedFirstFrame = true;
        _suppressBufferingUntil = null;
        onFirstFrameRendered?.call();
        onBufferingChanged?.call(false);
        _syncHwdecCurrent();
        _emitMediaMetadataSnapshot();
      case MpvVideoReconfigEvent():
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
    if (_disposed || id == null || !Platform.isWindows) return;
    await _d3d11Bridge.resize(sessionId: id, width: width, height: height);
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

  /// 截取纯净原画 PNG 视频帧（不含 UI/HUD 浮层），保存至作品目录并防重名。
  Future<File?> captureCleanScreenshot({
    required Directory workPhotoDir,
    String? episodeTag,
  }) async {
    final client = _client;
    if (_disposed || client == null || client.isDisposed) return null;
    final targetFile = await storageRoot.allocateWorkScreenshotFile(
      workPhotoDirectory: workPhotoDir,
      timestamp: DateTime.now(),
      episodeTag: episodeTag,
    );
    final rc = client.command(['screenshot-to-file', targetFile.path, 'video']);
    if (rc < 0) return null;
    for (var i = 0; i < 10; i++) {
      if (await targetFile.exists() && await targetFile.length() > 0) {
        return targetFile;
      }
      await Future<void>.delayed(const Duration(milliseconds: 35));
    }
    return await targetFile.exists() ? targetFile : null;
  }

  Future<Directory> _resolveScreenshotDir(String workId) async {
    final photosRoot = await storageRoot.photosRootDir();
    final safeTag = StorageRootService.encodeWorkIdTag(workId);
    final fallback = Directory(p.join(photosRoot.path, 'work [$safeTag]'));
    return fallback;
  }

  /// 严格按「停止事件订阅 -> 释放 D3D11/Android 渲染句柄 -> 异步 `mpv_terminate_destroy` -> 注销流网桥」串行释放。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    ++_loadGeneration;

    await _eventSub?.cancel();
    _eventSub = null;
    await _d3d11ChangeSub?.cancel();
    _d3d11ChangeSub = null;
    await _androidSurfaceSub?.cancel();
    _androidSurfaceSub = null;

    final d3dId = _d3d11SessionId;
    _d3d11SessionId = null;
    if (d3dId != null && d3dId > 0) {
      await _d3d11Bridge.disposeSession(d3dId);
    }

    final androidSurf = _androidSurface;
    _androidSurface = null;
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
