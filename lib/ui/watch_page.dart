import 'player_dialog.dart';
import 'player_volume_control.dart';
import 'player_scroll_volume.dart';
import '../core/subtitle_system_fonts.dart';
import '../core/mpv_config_store.dart';
import '../core/mpv_input_keys.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show listEquals;
import '../core/subtitle_choices.dart';
import 'app_header.dart';
import 'package:file_picker/file_picker.dart';
import '../core/timeline_frames.dart';
import '../core/android_audio_focus.dart';
import 'timeline_preview.dart';
import '../core/player_fullscreen.dart';
import '../core/track_preferences.dart';
import '../core/playback_probe.dart';
import 'playback_inspector.dart';
import 'track_picker.dart';
import 'seek_indicator.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
// Uses the same loaded DLL as NativePlayer for the opt-in render API trial.
// ignore: implementation_imports
import 'package:media_kit/src/player/native/core/native_library.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';
import '../core/catalog.dart';
import '../core/debug_log.dart';
import '../core/watched_timeline.dart';
import '../core/watch_settings.dart';
import '../l10n/strings.dart';
import '../core/sources.dart';
import '../core/local_media.dart';
import 'nipaplay_style.dart';
import 'android_native_video.dart';
import 'windows_hdr_output.dart';
import 'player_orientation_button.dart';

class WatchPage extends StatefulWidget {
  const WatchPage({
    super.key,
    required this.asset,
    this.configurationStore,
    this.createPlayer,
    this.chapterStartMs,
    this.chapterFloorMs,
    this.chapterEndMs,
    this.returnOnCompletion = false,
  });
  final Map<String, Object?> asset;
  final MpvConfigStore? configurationStore;
  final Player Function(PlayerConfiguration configuration)? createPlayer;
  final int? chapterStartMs, chapterFloorMs, chapterEndMs;
  final bool returnOnCompletion;
  @override
  State<WatchPage> createState() => _WatchPageState();
}

class _WatchPageState extends State<WatchPage> with WidgetsBindingObserver {
  bool _chapterEnded = false;
  bool _chapterReturnPending = false;
  late final Player player;
  bool _playerCreated = false;
  bool _leavingPlayback = false;
  AndroidAudioFocus? _audioFocus;
  bool _audioPauseObserved = false;
  bool _androidFullscreen = false;
  bool _orientationLocked = false;
  bool _orientationBusy = false;
  static const _androidWindow = MethodChannel('ccplayer/playback_window');
  Directory? _profile;
  final _subtitleMedia = <Media>[];
  bool _profileError = false;
  // Explicit false remains a build-time rollback to the legacy texture path.
  final _nativeWindow =
      Platform.isWindows &&
      (const bool.fromEnvironment('CCPLAYER_NATIVE_SDR_OUTPUT') ||
          _d3d11RenderApi);
  static const _d3d11RenderApi = bool.fromEnvironment(
    'CCPLAYER_D3D11_RENDER_API',
    defaultValue: true,
  );
  final _nativeAndroid =
      Platform.isAndroid &&
      const bool.fromEnvironment(
        'KONATA_ANDROID_NATIVE_OUTPUT',
        defaultValue: true,
      );
  AndroidNativeVideo? _androidVideo;
  WindowsHdrOutput? _windowsHdr;
  static const _surfaces = MethodChannel('ccplayer/native_video');
  final _viewportKey = GlobalKey();
  late final FocusNode _nativePlaybackFocus = FocusNode();
  int? _surface;
  List<int>? _lastLayout;
  static const _barHeight = 88.0;
  bool _barVisible = true;
  bool _checkingPointer = false;
  Future<void>? _surfaceRecovery;
  bool _surfaceRecoveryAttempted = false;
  String _lastNativeVideoTrack = 'auto';
  Timer? _pointerTimer;
  Duration _barUntil = Duration.zero;
  double? _dragMs;

  void _watchNativePointer() {
    _barUntil = _clock.elapsed + const Duration(seconds: 2);
    _pointerTimer = Timer.periodic(const Duration(milliseconds: 200), (
      _,
    ) async {
      if (_checkingPointer ||
          !mounted ||
          _surface == null ||
          _lastLayout == null) {
        return;
      }
      _checkingPointer = true;
      try {
        final over = await _surfaces.invokeMethod<bool>('pointerAtControls', [
          _surface,
          (_barHeight * View.of(context).devicePixelRatio).ceil(),
        ]);
        if (!mounted) return;
        if (over == true) {
          _barUntil = _clock.elapsed + const Duration(seconds: 1);
        }
        final visible = _dragMs != null || _clock.elapsed < _barUntil;
        if (_barVisible != visible) setState(() => _barVisible = visible);
      } on PlatformException catch (e) {
        if (e.code == 'render_failed' && mounted) {
          await (_surfaceRecovery ??= _recoverNativeSurface());
        } else {
          _log('surface_poll_failed', {'code': e.code}, level: 'WARN');
        }
      } finally {
        _checkingPointer = false;
      }
    });
  }

  Future<void> _recoverNativeSurface() async {
    final wasPlaying = player.state.playing;
    final native = player.platform as NativePlayer;
    try {
      await player.pause();
      if (_surfaceRecoveryAttempted) {
        throw StateError('Repeated native output failure');
      }
      _surfaceRecoveryAttempted = true;
      _log('surface_recovery_start', {
        'positionMs': current.inMilliseconds,
        'playing': wasPlaying,
      }, level: 'WARN');
      // Recreate only the failed output. Keep the loaded media, audio/subtitle
      // selection and timeline in the same mpv core.
      await native.setProperty('vid', 'no');
      await _windowsHdr?.close();
      await _surfaces.invokeMethod<void>('detachD3D11', [_surface]);
      if (!mounted) return;
      if ((await native.getProperty('hwdec')).startsWith('auto')) {
        await native.setProperty('hwdec', 'no');
      }
      await _surfaces.invokeMethod<void>('attachD3D11', [
        _surface,
        native.ctx.address,
        NativeLibrary.path,
      ]);
      await _initializeWindowsHdr(native);
      // Freeing a failed render context makes mpv set vid=no. Restore the last
      // active selection observed before that automatic disable.
      await native.setProperty('vid', _lastNativeVideoTrack);
      if (!mounted) return;
      if (wasPlaying) await player.play();
      if (!mounted) return;
      await native.command([
        'show-text',
        context.l10n.videoOutputRecovered,
        '5000',
      ]);
      _log('surface_recovery_complete', {
        'positionMs': current.inMilliseconds,
      }, level: 'WARN');
    } catch (e) {
      _pointerTimer?.cancel();
      if (_surface != null) {
        await _surfaces.invokeMethod<void>('hide', [_surface]);
      }
      _log('surface_recovery_failed', {
        'error': e.runtimeType.toString(),
      }, level: 'ERROR');
      if (mounted) setState(() => error = 'native-output');
    } finally {
      _surfaceRecovery = null;
    }
  }

  Future<void> _initializeWindowsHdr(NativePlayer native) async {
    final output = WindowsHdrOutput(native, _surface!, (failure) {
      _log('hdr_output_failed', {'reason': failure.toString()}, level: 'ERROR');
      if (mounted) setState(() => error = failure.toString());
    });
    _windowsHdr = output;
    await output.initialize();
  }

  // Give libass the fullscreen letterbox while keeping the picture at its
  // original texture resolution. Flutter scales the completed texture once.
  bool _fullscreenTexture = false;
  Timer? _textureResize;

  void _scheduleSubtitleCanvas() {
    if (!_fullscreenTexture) return;
    _textureResize?.cancel();
    _textureResize = Timer(const Duration(milliseconds: 80), () {
      if (!mounted || !_fullscreenTexture) return;
      final size = View.of(context).physicalSize;
      final params = player.state.videoParams;
      final quarterTurn = params.rotate == 90 || params.rotate == 270;
      final width = quarterTurn ? params.dh : params.dw;
      final height = quarterTurn ? params.dw : params.dh;
      if (size.isEmpty ||
          width == null ||
          height == null ||
          width <= 0 ||
          height <= 0) {
        return;
      }
      // Cap the canvas at the physical viewport for oversized source media.
      final scale = (width / size.width).clamp(0.0, 1.0);
      if (width * size.height <= height * size.width || scale == 0) {
        unawaited(controller.setSize());
      } else {
        unawaited(
          controller.setSize(
            width: (size.width * scale).round(),
            height: (size.height * scale).round(),
          ),
        );
      }
    });
  }

  @override
  void didChangeMetrics() {
    _scheduleSubtitleCanvas();
  }

  late final VideoController controller;
  StreamSubscription<Duration>? _positionSubscription;
  final _stateSubscriptions = <StreamSubscription<dynamic>>[];
  final _tracker = WatchedTracker();
  final _clock = Stopwatch();
  final _diagnosticSession = DebugLog.newId('play');
  int _nativeWarnings = 0, _bufferCount = 0, _bufferTotalMs = 0;
  int? _bufferStarted, _firstPosition;
  bool _positionAdvanced = false,
      _videoParametersLogged = false,
      _checkingProgress = false;
  bool _samplingDiagnostics = false;
  Future<void> _sampleDiagnostics() async {
    if (!DebugLog.enabled || _samplingDiagnostics || !_opened || !mounted) {
      return;
    }
    _samplingDiagnostics = true;
    try {
      final fields = <String, Object?>{'positionMs': current.inMilliseconds};
      for (final entry in const {
        'decoderDrops': 'decoder-frame-drop-count',
        'outputDrops': 'frame-drop-count',
        'avSync': 'avsync',
        'cacheSeconds': 'demuxer-cache-duration',
        'estimatedVideoFps': 'estimated-vf-fps',
        'displayFps': 'display-fps',
        'hwdec': 'hwdec-current',
        'vo': 'current-vo',
      }.entries) {
        if (!mounted) return;
        try {
          final value = await _property(
            entry.value,
          ).timeout(const Duration(milliseconds: 250));
          fields[entry.key] = value.isEmpty
              ? 'unavailable'
              : num.tryParse(value) ?? value;
        } catch (_) {
          fields[entry.key] = 'unavailable';
        }
      }
      if (mounted) _log('sample', fields, level: 'DEBUG');
    } finally {
      _samplingDiagnostics = false;
    }
  }

  Future<void> _recordAdvancing() async {
    if (_checkingProgress) return;
    _checkingProgress = true;
    try {
      final seeking = await _property(
        'seeking',
      ).timeout(const Duration(seconds: 1));
      if (mounted &&
          seeking == 'no' &&
          !_seeking &&
          !player.state.buffering &&
          !_positionAdvanced) {
        _positionAdvanced = true;
        _log('position_advancing', {'positionMs': current.inMilliseconds});
      }
    } catch (_) {
      /* Missing native telemetry is not a playback error. */
    } finally {
      _checkingProgress = false;
    }
  }

  void _log(
    String event,
    Map<String, Object?> fields, {
    String level = 'INFO',
  }) {
    DebugLog.event('Playback', event, {
      'session': _diagnosticSession,
      'elapsedMs': _clock.elapsedMilliseconds,
      ...fields,
    }, level: level);
  }

  Future<void> _saveTail = Future.value();
  bool _opened = false,
      _visible = true,
      _seeking = false,
      _saveErrorShown = false;
  Timer? _saver;
  bool _precisionGuardRunning = false, _softwareFallbackRequested = false;
  bool loading = true;
  String? error;
  bool _dolbyVisionCheckRunning = false;
  List<SubtitleTrack> addedSubtitles = [];
  final _automaticSubtitles = <SubtitleTrack>[];
  bool _userAudio = false, _userSubtitle = false;
  String? _lastAudio, _lastSubtitle;
  Future<void> _trackTail = Future.value();
  Future<Set<String>?>? _decoderCodecs;
  final _previewEnabled = ValueNotifier<bool>(false);
  Timer? _osdTimer;
  final _osd = ValueNotifier<String?>(null);
  final _statsVisible = ValueNotifier<bool>(false);
  Future<List<VideoChapter>> _chapterData = Future.value(const []);
  TimelineFrames? _frames;
  Future<String>? _previewUri;
  bool _webDav = false;
  bool _openingMedia = false;
  bool _mediaRequested = false;
  Duration? _retryPosition;
  Uri? _playbackTicket;
  Future<void>? _subtitleDiscovery;
  final _streamTickets = <Uri>[];

  Future<String> _issueStream(
    Map<String, Object?> source,
    String path, {
    String purpose = 'playback',
  }) async {
    final uri = await StreamBroker.instance.issue(
      source,
      path,
      purpose: purpose,
      diagnosticSession: _diagnosticSession,
    );
    if (!mounted) {
      StreamBroker.instance.revoke(uri);
      throw StateError('Player closed');
    }
    _streamTickets.add(uri);
    return uri.toString();
  }

  Duration current = Duration.zero;
  Duration total = Duration.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (mounted && Platform.isAndroid) {
        await _androidWindow.invokeMethod<void>('begin');
        if (mounted) _setAndroidFullscreen(true);
      }
      if (mounted && (AppHeader.desktop || Platform.isAndroid)) {
        playingHeader.value = PlayingHeader(
          widget.asset['name'].toString(),
          _requestPlaybackExit,
          videoOverlay: !_nativeWindow,
        );
      }
    });
    _clock.start();
    _log('session_start', {
      'platform': Platform.operatingSystem,
      'version': DebugLog.buildVersion,
      'revision': DebugLog.buildRevision,
      'detail': DebugLog.enabled,
    });
    final store = widget.configurationStore ?? MpvConfigStore.instance;
    if (store.enabled) {
      unawaited(_prepareConfiguredPlayer(store));
    } else {
      _startPlayer(store, store.playerConfiguration);
    }
  }

  Future<void> _prepareConfiguredPlayer(MpvConfigStore store) async {
    try {
      final folder = store.externalFolder ?? (await store.directory).path;
      final profile = await store.snapshot(folder);
      if (!mounted) {
        await profile.delete(recursive: true);
        return;
      }
      _profile = profile;
      _startPlayer(store, store.configurationFor(profile));
    } catch (e) {
      if (mounted) {
        setState(() {
          _profileError = true;
          error = e.runtimeType.toString();
        });
      }
    }
  }

  void _startPlayer(MpvConfigStore store, PlayerConfiguration config) {
    player = widget.createPlayer?.call(config) ?? Player(configuration: config);
    _playerCreated = true;
    final native = player.platform;
    if (native is NativePlayer) native.onFileError = _mediaFailed;
    if (Platform.isAndroid) {
      _audioFocus = AndroidAudioFocus(player.stream.playing, player.pause);
    }
    if (!_nativeWindow) {
      if (_nativeAndroid) {
        _androidVideo = AndroidNativeVideo(player, store.videoConfiguration);
      }
      controller = VideoController(
        player,
        configuration: store.videoConfiguration,
        platformFactory: _androidVideo?.initialize,
      );
    }
    if (_nativeAndroid && mounted) setState(() {});
    if (Platform.isWindows && !_nativeWindow) {
      _stateSubscriptions.add(
        player.stream.videoParams.listen((_) => _scheduleSubtitleCanvas()),
      );
    }
    _positionSubscription = player.stream.position.listen((v) {
      current = v;
      if (_opened &&
          player.state.playing &&
          !player.state.buffering &&
          !_seeking &&
          !_positionAdvanced) {
        _firstPosition ??= v.inMilliseconds;
        if (v.inMilliseconds > _firstPosition! + 300) {
          unawaited(_recordAdvancing());
        }
      }
      if (_opened && !_seeking) {
        _tracker.sample(
          position: v.inMilliseconds,
          duration: player.state.duration.inMilliseconds,
          clock: _clock.elapsedMilliseconds,
          playing: player.state.playing,
          buffering: player.state.buffering,
          rate: player.state.rate,
          visible: _visible,
        );
      }
      final boundary = widget.chapterEndMs;
      if (_opened &&
          !_seeking &&
          player.state.playing &&
          boundary != null &&
          v.inMilliseconds >= boundary) {
        unawaited(_finishChapter());
      }
    });
    _stateSubscriptions.addAll([
      player.stream.completed.listen((completed) {
        final ticket = _playbackTicket;
        // libmpv can report a truncated HTTP body as EOF. Require both a
        // verified upstream read failure and a position well before the end.
        if (completed &&
            _opened &&
            ticket != null &&
            player.state.duration - current > const Duration(seconds: 1) &&
            StreamBroker.instance.interruptedWebDavRead(ticket)) {
          _mediaFailed(0);
        } else if (completed &&
            _opened &&
            widget.returnOnCompletion &&
            widget.chapterEndMs == null &&
            current >= player.state.duration - const Duration(seconds: 1) &&
            player.state.duration > Duration.zero) {
          unawaited(_finishChapter());
        }
      }),
      player.stream.error.listen(
        (message) => _log('player_error', {'message': message}, level: 'ERROR'),
      ),
      player.stream.log.listen((entry) {
        if (!['warn', 'error', 'fatal'].contains(entry.level)) return;
        // The Android output guard has already refused mismatched HDR pixels.
        // Surface this specific terminal error; ordinary fallback warnings may
        // still be followed by successful playback and must remain nonfatal.
        if (mounted &&
            error != 'hdr-target' &&
            entry.text.trim() ==
                'Explicit HDR target is incompatible with this output') {
          setState(() {
            error = 'hdr-target';
            loading = false;
          });
          unawaited(player.pause());
        }
        if (PlaybackProbe.unsupportedMediaCodecProfile(
          entry.prefix,
          entry.text,
        )) {
          unawaited(_useSoftwareDecoder('unsupported_profile'));
        }
        if (++_nativeWarnings <= 20) {
          _log('native_warning', {
            'prefix': entry.prefix,
            'engineLevel': entry.level,
            'message': entry.text,
            // A decoder error may be followed by successful fallback. The
            // application failure stream is logged separately as player_error.
          }, level: entry.level == 'fatal' ? 'ERROR' : 'WARN');
        } else if (_nativeWarnings == 21) {
          _log('native_log_limit', {'limit': 20}, level: 'WARN');
        }
      }),
      player.stream.videoParams.listen((params) {
        if (params.pixelformat != null) unawaited(_preserveDecodePrecision());
        if (_videoParametersLogged || params.pixelformat == null) return;
        _videoParametersLogged = true;
        _log('decoded_video_parameters', {
          'width': params.w,
          'height': params.h,
          'pixelFormat': params.pixelformat,
          'hardwarePixelFormat': params.hwPixelformat,
        });
      }),
      player.stream.duration
          .where((duration) => duration > Duration.zero)
          .listen((_) {
            _chapterData = PlaybackProbe(
              _property,
            ).chapters().catchError((Object _) => <VideoChapter>[]);
            if (mounted) setState(() {});
          }),
      player.stream.tracks.listen((_) {
        unawaited(_checkDolbyVisionSupport());
        unawaited(_preserveDecodePrecision());
        if (_opened) _preferTracks();
      }),
      if (_d3d11RenderApi)
        player.stream.track.listen((track) {
          if (track.video.id != 'no') _lastNativeVideoTrack = track.video.id;
        }),
      player.stream.playing.distinct().listen((_) => _tracker.reset()),
      player.stream.buffering.distinct().listen((buffering) {
        _tracker.reset();
        if (buffering) {
          _bufferStarted = _clock.elapsedMilliseconds;
          _bufferCount++;
          _log('buffer_start', {'positionMs': current.inMilliseconds});
        } else if (_bufferStarted != null) {
          final duration = _clock.elapsedMilliseconds - _bufferStarted!;
          _bufferTotalMs += duration;
          _bufferStarted = null;
          _log('buffer_end', {
            'durationMs': duration,
            'positionMs': current.inMilliseconds,
          }, level: duration >= 1000 ? 'WARN' : 'INFO');
        }
      }),
      player.stream.rate.distinct().listen((_) => _tracker.reset()),
    ]);
    _saver = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_save());
      unawaited(_sampleDiagnostics());
      unawaited(_recoverUndecodedVideo());
    });
    _open();
  }

  Future<void> _preserveDecodePrecision() async {
    if (!Platform.isAndroid ||
        !mounted ||
        _precisionGuardRunning ||
        _softwareFallbackRequested) {
      return;
    }
    _precisionGuardRunning = true;
    try {
      final native = player.platform as NativePlayer;
      if (await native.getProperty('hwdec-current') != 'mediacodec-copy') {
        return;
      }
      final source = await PlaybackProbe(
        native.getProperty,
      ).sourceVideoParameters();
      final decoded = await native.getProperty('video-dec-params/pixelformat');
      if (!mounted ||
          !PlaybackProbe.needsPrecisionFallback(
            sourceCodec: source['codec'],
            sourceFormat: source['format-name'],
            sourceProfile: source['codec-profile'],
            decodedFormat: decoded,
          )) {
        return;
      }
      await _useSoftwareDecoder('precision', {
        'sourceCodec': source['codec'],
        'sourceFormat': source['format-name'],
        'sourceProfile': source['codec-profile'],
        'decodedFormat': decoded,
      });
    } catch (e) {
      _log('decode_precision_check_failed', {
        'type': e.runtimeType.toString(),
      }, level: 'WARN');
    } finally {
      _precisionGuardRunning = false;
    }
  }

  Future<void> _checkDolbyVisionSupport() async {
    if (!mounted || _dolbyVisionCheckRunning || error == 'dv-profile-5') return;
    _dolbyVisionCheckRunning = true;
    try {
      final source = await PlaybackProbe(_property).sourceVideoParameters();
      if (!mounted || source['dolby-vision-profile'] != '5') return;
      setState(() {
        error = 'dv-profile-5';
        loading = false;
      });
      await player.pause();
    } finally {
      _dolbyVisionCheckRunning = false;
    }
  }

  Future<void> _recoverUndecodedVideo() async {
    if (!Platform.isAndroid ||
        !mounted ||
        !_opened ||
        _precisionGuardRunning ||
        _softwareFallbackRequested ||
        player.state.videoParams.pixelformat != null) {
      return;
    }
    _precisionGuardRunning = true;
    try {
      final native = player.platform as NativePlayer;
      // FFmpeg logs belong to only one libmpv instance. A previous player's
      // delayed destruction can hide a MediaCodec rejection from this player.
      // Check an idle, loaded video with no decoded frame instead of relying
      // exclusively on the warning. Pauses and cache waits are exempt. mpv can
      // remain "seeking" at startup until the first frame, so that flag alone
      // cannot disqualify this recovery.
      final state = <String, String>{};
      for (final key in [
        'hwdec',
        'core-idle',
        'pause',
        'paused-for-cache',
        'seeking',
        'video-params/w',
        'video-dec-params',
        'time-pos',
      ]) {
        state[key] = await native.getProperty(key);
      }
      if (mounted &&
          (state['hwdec'] ?? '').startsWith('auto') &&
          state['core-idle'] == 'yes' &&
          state['pause'] == 'no' &&
          state['paused-for-cache'] == 'no' &&
          (int.tryParse(state['video-params/w'] ?? '') ?? 0) > 0 &&
          (state['video-dec-params'] ?? '').isEmpty) {
        await _useSoftwareDecoder('no_decoded_frame', state);
      }
    } catch (_) {
      // Missing state is not evidence of a failed hardware decoder.
    } finally {
      _precisionGuardRunning = false;
    }
  }

  Future<void> _useSoftwareDecoder(
    String reason, [
    Map<String, Object?> evidence = const {},
  ]) async {
    if (!Platform.isAndroid || !mounted || _softwareFallbackRequested) {
      return;
    }
    try {
      final native = player.platform as NativePlayer;
      final requested = await native.getProperty(
        'hwdec',
        waitForInitialization: false,
      );
      if (!mounted ||
          !requested.startsWith('auto') ||
          _softwareFallbackRequested) {
        return;
      }
      _softwareFallbackRequested = true;
      final position = double.tryParse(
        await native.getProperty('time-pos', waitForInitialization: false),
      );
      // Switch in place even before the first decoded frame. A MediaCodec
      // profile rejection can otherwise leave the Surface waiting forever.
      // A native warning or the observed decoder state proves initialization;
      // waiting for a first-frame controller here could deadlock startup.
      await native.setProperty('hwdec', 'no', waitForInitialization: false);
      if (await native.getProperty('hwdec', waitForInitialization: false) !=
          'no') {
        throw StateError('Software fallback was not applied');
      }
      _log('decode_software_fallback', {'reason': reason, ...evidence});
      // A new decoder needs the current GOP's reference frames, including
      // after a precision fallback. Without reseeking, slow network input
      // leaves playback waiting for the next keyframe.
      if (mounted && position != null && position.isFinite && position >= 0) {
        await native.command(['seek', '$position', 'absolute+exact']);
      }
    } catch (error) {
      _log('decode_software_fallback_failed', {
        'type': error.runtimeType.toString(),
      }, level: 'WARN');
    }
  }

  Future<void> _open() async {
    try {
      if (Platform.isAndroid && player.platform!.configuration.libass) {
        await controller.platform.future;
        if (_nativeAndroid) {
          await _androidVideo!.ready.future.timeout(
            const Duration(seconds: 15),
          );
        }
        _log('controller_ready', {}, level: 'DEBUG');
        final native = player.platform as NativePlayer;
        try {
          if ((await native.getProperty('sub-fonts-dir')).isEmpty) {
            await configureAndroidSubtitleFonts(
              native.setProperty,
              // Without an Android font provider, libass needs a concrete
              // fallback for mpv's generic sans-serif default.
              setDefaultFamily:
                  (await native.getProperty('sub-font')) == 'sans-serif',
            );
          }
        } on FileSystemException {
          DebugLog.write(
            'Player',
            'Subtitle fallback links unavailable',
            level: 'WARN',
          );
        }
      }
      if (_nativeWindow) {
        final native = player.platform as NativePlayer;
        final store = widget.configurationStore ?? MpvConfigStore.instance;
        final host = await _surfaces.invokeMethod<int>(
          'create',
          _d3d11RenderApi,
        );
        if (host == null || host == 0) {
          throw StateError('Missing video surface');
        }
        if (!mounted || _leavingPlayback) {
          await _surfaces.invokeMethod<void>('destroy', [host]);
          return;
        }
        _surface = host;
        if (_d3d11RenderApi) {
          await native.setProperty('vid', 'auto');
          await native.setProperty('vo', 'libmpv');
          if (!native.configuration.mpvRespectRenderingConfiguration) {
            await native.setProperty(
              'hwdec',
              store.videoConfiguration.hwdec ?? 'auto',
            );
          }
          await _surfaces.invokeMethod<void>('attachD3D11', [
            host,
            native.ctx.address,
            NativeLibrary.path,
          ]);
          await _initializeWindowsHdr(native);
        } else {
          await native.setProperty('wid', host.toString());
          if (await native.getProperty('wid') != host.toString()) {
            throw StateError(
              'Native video did not attach to the player window',
            );
          }
          await native.setProperty('vid', 'auto');
          final options = {
            'vo': 'gpu',
            'gpu-api': 'd3d11',
            'gpu-context': 'd3d11',
            'd3d11-output-format': 'rgb10_a2',
            'title': 'Konata',
            if (!native.configuration.mpvRespectRenderingConfiguration)
              'hwdec': store.videoConfiguration.hwdec ?? 'auto-safe',
          };
          for (final option in options.entries) {
            await native.setProperty(option.key, option.value);
            if (option.key != 'hwdec' &&
                await native.getProperty(option.key) != option.value) {
              throw StateError(
                'Unsupported native output option: ${option.key}',
              );
            }
          }
        }
      }
      if (mounted && _audioFocus != null) {
        final native = player.platform as NativePlayer;
        await native.observeProperty('pause', (value) async {
          if (mounted && _opened) _audioFocus?.updatePlaying(value == 'no');
        }, waitForInitialization: false);
        _audioPauseObserved = true;
      }
      final native = player.platform;
      if (mounted &&
          native is NativePlayer &&
          native.configuration.mpvConfigurationDirectory == null) {
        await native.setProperty('sub-auto', 'no');
      }
      if (mounted) await _openMedia();
    } catch (e) {
      _log('open_failed', {'type': e.runtimeType.toString()}, level: 'ERROR');
      if (mounted) {
        setState(() {
          error = e.runtimeType.toString();
          loading = false;
        });
      }
    }
  }

  void _mediaFailed(int code) {
    if (!mounted || !_mediaRequested || error != null) return;
    _mediaRequested = false;
    _log('media_failed', {'code': code}, level: 'ERROR');
    if (_opened && current > Duration.zero) {
      _retryPosition = current;
      unawaited(_save());
    }
    _opened = false;
    _tracker.reset();
    _audioFocus?.updatePlaying(false);
    if (_nativeWindow) _layoutSurface(false);
    setState(() {
      error = 'media-open';
      loading = false;
    });
  }

  Future<void> _openMedia() async {
    if (!mounted || _openingMedia) return;
    _openingMedia = true;
    if (error == 'media-open') setState(() => error = null);
    try {
      await _trackTail;
      if (!mounted) return;
      final previous = _playbackTicket;
      if (previous != null) {
        _streamTickets.remove(previous);
        StreamBroker.instance.revoke(previous);
        _playbackTicket = null;
      }
      final asset = widget.asset;
      final source = Catalog.instance.sourceOf(asset['source_id'].toString());
      final relative = asset['relative_path'].toString();
      _webDav = source['kind'] == 'webdav';
      final uri = await _mediaUri(source, relative);
      if (!mounted) return;
      if (source['kind'] != 'local') _playbackTicket = Uri.parse(uri);
      final resume =
          _retryPosition ??
          Duration(
            milliseconds:
                widget.chapterStartMs ??
                await Catalog.instance.resumePosition(asset['id'].toString()),
          );
      if (!mounted) return;
      _retryPosition = resume;
      _lastAudio = _lastSubtitle = null;
      _mediaRequested = true;
      _log('open_requested', {
        'sourceKind': source['kind'],
        'resumeMs': resume.inMilliseconds,
      });
      await player.open(
        Media(uri, start: resume > Duration.zero ? resume : null),
      );
      await _checkDolbyVisionSupport();
      if (!mounted || error != null) return;
      _log('open_returned', {}, level: 'DEBUG');
      _chapterData = PlaybackProbe(
        _property,
      ).chapters().catchError((Object _) => <VideoChapter>[]);
      if (!mounted) return;
      // A readable media file does not imply its directory can be enumerated.
      // Show the opened player before optional external subtitle discovery on
      // every source, including local document providers and SMB shares.
      _showPlayback();
      if (_subtitleDiscovery == null) {
        _subtitleDiscovery = _loadSubtitles(source, relative);
      } else {
        unawaited(_preferTracks());
      }
    } catch (e) {
      _log('open_failed', {'type': e.runtimeType.toString()}, level: 'ERROR');
      _mediaRequested = true;
      _mediaFailed(0);
    } finally {
      _openingMedia = false;
      if (mounted && error == 'media-open') setState(() {});
    }
  }

  Future<void> _loadSubtitles(
    Map<String, Object?> source,
    String relative,
  ) async {
    try {
      final matches = await StreamBroker.instance.subtitleMatches(
        source,
        relative,
      );
      final tracks = <SubtitleTrack>[];
      final automatic = <SubtitleTrack>[];
      for (final match in matches) {
        if (!mounted) return;
        final subtitle = match.path;
        var target = source['kind'] == 'local'
            ? await LocalMedia.uri(source['location'].toString(), subtitle)
            : await _issueStream(source, subtitle, purpose: 'subtitle');
        if (!mounted) return;
        if (target.startsWith('content://')) {
          // Keep the existing media_kit descriptor alive for the subtitle session.
          final media = Media(target);
          _subtitleMedia.add(media);
          target = media.uri;
        }
        final track = SubtitleTrack.uri(target, title: p.basename(subtitle));
        tracks.add(track);
        if (match.automatic) automatic.add(track);
      }
      if (!mounted) return;
      addedSubtitles = [...addedSubtitles, ...tracks];
      _automaticSubtitles.addAll(automatic);
      if (_opened) await _preferTracks();
    } catch (e) {
      DebugLog.write(
        'Playback',
        'subtitle setup failed ${e.runtimeType}',
        level: 'WARN',
      );
    }
  }

  Future<String> _mediaUri(
    Map<String, Object?> source,
    String path, {
    String purpose = 'playback',
  }) async {
    if (source['kind'] == 'local') {
      return LocalMedia.uri(source['location'].toString(), path);
    }
    return _issueStream(source, path, purpose: purpose);
  }

  void _showPlayback() {
    if (_nativeWindow && _pointerTimer == null) _watchNativePointer();
    _opened = true;
    _audioFocus?.updatePlaying(player.state.playing);
    _tracker.reset();
    setState(() => loading = false);
  }

  Future<void> _save() {
    if (!_opened) return _saveTail;
    final duration = player.state.duration;
    if (duration <= Duration.zero) return _saveTail;
    final position = current.inMilliseconds;
    final ranges = _tracker.timeline.ranges;
    final threshold = WatchSettings.instance.completionPercent;
    _saveTail = _saveTail
        .then(
          (_) => Catalog.instance.progress(
            widget.asset['id'].toString(),
            position,
            duration.inMilliseconds,
            watchedRanges: ranges,
            completionPercent: threshold,
          ),
        )
        .then((_) {
          _saveErrorShown = false;
        })
        .catchError((Object e) {
          DebugLog.write(
            'Playback',
            'progress save failed ${e.runtimeType}',
            level: 'ERROR',
          );
          if (mounted && !_saveErrorShown) {
            _saveErrorShown = true;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(context.l10n.progressSaveFailed)),
            );
          }
        });
    return _saveTail;
  }

  Future<void> _finishChapter() async {
    if (_chapterEnded) return;
    _chapterEnded = true;
    await player.pause();
    await _save();
    if (!mounted) return;
    _chapterReturnPending = true;
    _returnFromChapter();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if ((widget.chapterEndMs != null || widget.returnOnCompletion) &&
        ModalRoute.isCurrentOf(context) == true &&
        _chapterReturnPending) {
      // The navigator can still be updating its routes during this rebuild.
      WidgetsBinding.instance.addPostFrameCallback((_) => _returnFromChapter());
    }
  }

  void _returnFromChapter() {
    if (!mounted ||
        !_chapterReturnPending ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    _chapterReturnPending = false;
    Navigator.of(context).pop(true);
  }

  void _requestPlaybackExit() {
    if (!mounted || _leavingPlayback || ModalRoute.isCurrentOf(context) != true) return;
    _leavingPlayback = true;
    _log('exit_requested', {'positionMs': current.inMilliseconds});
    final surface = _surface;
    if (surface != null) {
      unawaited(_surfaces.invokeMethod<void>('hide', [surface]).catchError(
        (Object error, StackTrace stack) =>
            DebugLog.exception('Playback', 'surface_hide_failed', error, stack),
      ));
    }
    Navigator.of(context).pop();
  }

  Future<void> _seek(Duration value) async {
    if (widget.chapterEndMs case final end?) {
      value = Duration(
        milliseconds: value.inMilliseconds.clamp(
          widget.chapterFloorMs ?? 0,
          end - 1,
        ),
      );
    }
    _log('seek_requested', {'positionMs': value.inMilliseconds});
    _firstPosition = null;
    _seeking = true;
    _tracker.reset();
    try {
      await player.seek(value);
      _log('seek_command_returned', {
        'positionMs': value.inMilliseconds,
      }, level: 'DEBUG');
    } finally {
      _tracker.reset();
      _seeking = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _log('lifecycle', {
      'state': state.name,
      'positionMs': current.inMilliseconds,
    });
    _visible =
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    _tracker.reset();
    if (!_visible) unawaited(_save());
  }

  Future<void> _finish() async {
    final releaseClock = Stopwatch()..start();
    try {
      await _surfaceRecovery;
      await _save();
    } finally {
      try {
        try {
          await _androidVideo?.close();
          await _windowsHdr?.close();
          if (_d3d11RenderApi && _surface != null) {
            await _surfaces.invokeMethod<void>('destroy', [_surface]);
            _surface = null;
          }
        } finally {
          // A platform surface failure must not retain the decoder or audio.
          try {
            if (_audioPauseObserved) {
              await (player.platform as NativePlayer).unobserveProperty(
                'pause',
                waitForInitialization: false,
              );
            }
          } finally {
            try {
              await _audioFocus?.dispose();
            } finally {
              if (_playerCreated) await player.dispose();
            }
          }
        }
        _subtitleMedia.clear();
      } catch (e) {
        DebugLog.write(
          'Playback',
          'dispose failed ${e.runtimeType}',
          level: 'ERROR',
        );
      } finally {
        await _profile?.delete(recursive: true);
        if (_surface != null) {
          await _surfaces.invokeMethod<void>('destroy', [_surface]);
        }
        _log('disposed', {'releaseMs': releaseClock.elapsedMilliseconds});
      }
    }
  }

  // Explicit test/diagnostic request; no per-frame readback during playback.
  Future<Map<Object?, Object?>> capturePresentedBuffer({
    bool pixels = false,
    bool packed10 = false,
  }) async {
    final result = _nativeAndroid
        ? await _androidVideo!.capture(pixels: pixels, packed10: packed10)
        : await _surfaces.invokeMapMethod<Object?, Object?>('captureD3D11', [
                _surface,
              ]) ??
              {};
    if (!pixels) result.remove('pixels');
    return result;
  }

  // Debug native builds expose the injection; release builds do not.
  Future<void> simulateNativeOutputFailure() =>
      _surfaces.invokeMethod<void>('simulateD3D11Failure', [_surface]);

  @override
  void dispose() {
    final native = _playerCreated ? player.platform : null;
    if (native is NativePlayer) {
      native.onFileError = null;
    }
    _log('session_end', {
      'positionMs': current.inMilliseconds,
      'bufferCount': _bufferCount,
      'bufferTotalMs': _bufferTotalMs,
      'bufferPendingMs': _bufferStarted == null
          ? 0
          : _clock.elapsedMilliseconds - _bufferStarted!,
      'nativeLogsSuppressed': (_nativeWarnings - 20).clamp(0, _nativeWarnings),
    });
    if (_surface != null) {
      unawaited(_surfaces.invokeMethod<void>('hide', [_surface]));
    }
    for (final uri in _streamTickets) {
      StreamBroker.instance.revoke(uri);
    }
    _streamTickets.clear();
    _textureResize?.cancel();
    _pointerTimer?.cancel();
    _saver?.cancel();
    final header = playingHeader.value;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (identical(playingHeader.value, header)) playingHeader.value = null;
    });
    _releasePreview();
    _previewEnabled.dispose();
    _statsVisible.dispose();
    if (_nativeWindow) _nativePlaybackFocus.dispose();
    _osdTimer?.cancel();
    _osd.dispose();
    if (Platform.isAndroid) {
      playerFullscreen.value = false;
      unawaited(_androidWindow.invokeMethod<void>('end'));
    } else if (playerFullscreen.value) {
      playerFullscreen.value = false;
      unawaited(_setWindowFullscreen(false));
    }
    WidgetsBinding.instance.removeObserver(this);
    _clock.stop();
    _positionSubscription?.cancel();
    for (final subscription in _stateSubscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_finish());
    super.dispose();
  }

  Future<void> _setWindowFullscreen(bool enabled) {
    // The plugin owning our hidden Windows title bar also owns its resize border.
    if (Platform.isWindows) return windowManager.setFullScreen(enabled);
    if (Platform.isAndroid) return _setAndroidFullscreen(enabled);
    return enabled
        ? defaultEnterNativeFullscreen()
        : defaultExitNativeFullscreen();
  }

  Future<void> _setAndroidFullscreen(bool enabled) {
    setState(() => _androidFullscreen = enabled);
    playerFullscreen.value = enabled;
    return _androidWindow.invokeMethod<void>('fullscreen', enabled);
  }

  Future<void> _toggleOrientation() async {
    if (_orientationBusy) return;
    setState(() => _orientationBusy = true);
    try {
      final locked = await _androidWindow.invokeMethod<bool>(
        'orientationLocked',
        !_orientationLocked,
      );
      if (mounted && locked != null) {
        setState(() => _orientationLocked = locked);
      }
    } on PlatformException catch (failure) {
      _log('orientation_lock_failed', {'code': failure.code}, level: 'WARN');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.orientationUnavailable)),
        );
      }
    } finally {
      if (mounted) setState(() => _orientationBusy = false);
    }
  }

  Future<void> _toggleNativeFullscreen() async {
    if (playerFullscreen.value) {
      await _setWindowFullscreen(false);
      playerFullscreen.value = false;
    } else {
      await _setWindowFullscreen(true);
      if (mounted) {
        playerFullscreen.value = true;
        // The fullscreen button disappears with the controls; keep Escape on the player.
        _nativePlaybackFocus.requestFocus();
      }
    }
  }

  KeyEventResult _forwardMpvKey(FocusNode _, KeyEvent event) {
    if (error == 'dv-profile-5' || error == 'media-open') {
      return KeyEventResult.ignored;
    }
    if (_nativeWindow &&
        event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        playerFullscreen.value) {
      unawaited(_toggleNativeFullscreen());
      return KeyEventResult.handled;
    }
    if (_nativeWindow &&
        !MpvConfigStore.instance.enabled &&
        _opened &&
        (event is KeyDownEvent || event is KeyRepeatEvent)) {
      final key = event.logicalKey;
      if (key == LogicalKeyboardKey.space) {
        if (event is KeyDownEvent) unawaited(player.playOrPause());
      } else if (key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.arrowRight) {
        _seek(
          player.state.position +
              Duration(seconds: key == LogicalKeyboardKey.arrowLeft ? -5 : 5),
        );
      } else if (key == LogicalKeyboardKey.keyF) {
        if (event is KeyDownEvent) unawaited(_toggleNativeFullscreen());
      } else {
        return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    }
    if (!MpvConfigStore.instance.enabled ||
        !_opened ||
        (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
      return KeyEventResult.ignored;
    }
    final native = player.platform;
    if (native is! NativePlayer) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    final name = MpvInputKeys.encode(
      event.logicalKey,
      shift: keyboard.isShiftPressed,
      control: keyboard.isControlPressed,
      alt: keyboard.isAltPressed,
      meta: keyboard.isMetaPressed,
    );
    if (name == null) return KeyEventResult.ignored;
    unawaited(
      native.command(['keypress', name]).catchError((Object e) {
        DebugLog.write('MPV', 'input forwarding failed');
      }),
    );
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _nativeWindow ? _nativePlaybackFocus : null,
      autofocus: _nativeWindow || MpvConfigStore.instance.enabled,
      onKeyEvent: _forwardMpvKey,
      child: Scaffold(
        appBar:
            (AppHeader.desktop || Platform.isAndroid) &&
                    !loading &&
                    error == null ||
                _nativeWindow
            ? null
            : AppBar(
                title: Text(
                  widget.asset['name'].toString(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
        body: _withMediaError(
          error != null && error != 'media-open'
              ? Center(
                  child: Text(
                    _profileError
                        ? context.l10n.mpvFolderReadError
                        : error == 'hdr-target'
                        ? context.l10n.hdrTargetIncompatible
                        : error == 'dv-profile-5'
                        ? context.l10n.dolbyVisionProfile5Unsupported
                        : context.l10n.playbackFailed,
                  ),
                )
              : loading && !(_nativeAndroid && _playerCreated)
              ? const Center(child: CircularProgressIndicator())
              : _nativeWindow
              ? _nativeControls()
              : SizedBox.expand(
                  child: ColoredBox(
                    color: Colors.black,
                    child: MaterialDesktopVideoControlsTheme(
                      normal: _desktopControls(fullscreen: false),
                      fullscreen: _desktopControls(fullscreen: true),
                      child: MaterialVideoControlsTheme(
                        normal: _touchControls(),
                        fullscreen: _touchControls(),
                        child: Video(
                          controller: controller,
                          surfaceBuilder: _androidVideo?.buildSurface,
                          onEnterFullscreen: () async {
                            playerFullscreen.value = true;
                            await _setWindowFullscreen(true);
                            if (mounted &&
                                Platform.isWindows &&
                                player.platform!.configuration.libass) {
                              _fullscreenTexture = true;
                              _scheduleSubtitleCanvas();
                            }
                          },
                          onExitFullscreen: () async {
                            try {
                              if (_fullscreenTexture) {
                                _fullscreenTexture = false;
                                _textureResize?.cancel();
                                await controller.setSize();
                              }
                              await _setWindowFullscreen(false);
                            } finally {
                              playerFullscreen.value = false;
                            }
                          },
                          controls: (state) => Stack(
                            children: [
                              Positioned.fill(
                                child: PlayerScrollVolume(
                                  enabled: Platform.isWindows,
                                  volume: () => player.state.volume,
                                  onChanged: (value) async {
                                    await player.setVolume(value);
                                    _osd.value = '${value.round()}%';
                                    _osdTimer?.cancel();
                                    _osdTimer = Timer(
                                      const Duration(seconds: 1),
                                      () {
                                        if (mounted) _osd.value = null;
                                      },
                                    );
                                  },
                                  // Fullscreen controls live on a separate route,
                                  // outside the playback page's keyboard focus.
                                  child: Focus(
                                    canRequestFocus: false,
                                    onKeyEvent: _forwardMpvKey,
                                    child: AdaptiveVideoControls(state),
                                  ),
                                ),
                              ),
                              ValueListenableBuilder<String?>(
                                valueListenable: _osd,
                                builder: (_, text, _) => text == null
                                    ? const SizedBox.shrink()
                                    : Positioned(
                                        top: 16,
                                        left: 16,
                                        right: 16,
                                        child: IgnorePointer(
                                          child: Text(
                                            text,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 22,
                                              shadows: [
                                                Shadow(
                                                  color: Colors.black,
                                                  blurRadius: 4,
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                              ),
                              ValueListenableBuilder<bool>(
                                valueListenable: _statsVisible,
                                builder: (context, visible, _) => visible
                                    ? Positioned(
                                        top: 64,
                                        left: 12,
                                        bottom: 88,
                                        width:
                                            MediaQuery.sizeOf(context).width <
                                                520
                                            ? MediaQuery.sizeOf(context).width -
                                                  24
                                            : 480,
                                        child: Theme(
                                          data: Theme.of(context),
                                          child: Material(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .surface
                                                .withValues(alpha: .94),
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                            child: PlaybackInspector(
                                              probe: PlaybackProbe(
                                                _property,
                                                textureResolution: () {
                                                  final rect =
                                                      controller.rect.value;
                                                  return rect == null
                                                      ? null
                                                      : '${rect.width.round()} × ${rect.height.round()}';
                                                },
                                              ),
                                              onClose: () =>
                                                  _statsVisible.value = false,
                                              position: () =>
                                                  player.state.position,
                                              onSeek: _seek,
                                            ),
                                          ),
                                        ),
                                      )
                                    : const SizedBox.shrink(),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  Widget _withMediaError(Widget playback) {
    final failed = error == 'media-open';
    return Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(ignoring: failed, child: playback),
        if (failed)
          ColoredBox(
            color: Theme.of(context).colorScheme.surface,
            child: SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        context.l10n.playbackFailed,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: _openingMedia ? null : _openMedia,
                        child: Text(context.l10n.retry),
                      ),
                      BackButton(onPressed: _requestPlaybackExit),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Future<Set<String>?> _readDecoderCodecs() async {
    try {
      final native = player.platform as NativePlayer;
      final count = int.parse(await native.getProperty('decoder-list/count'));
      if (count <= 0 || count > 4096) return null;
      final codecs = <String>{};
      for (var i = 0; i < count; i++) {
        final codec = await native.getProperty('decoder-list/$i/codec');
        if (codec.isNotEmpty) codecs.add(codec.toLowerCase());
      }
      return codecs.isEmpty ? null : codecs;
    } catch (_) {
      return null;
    }
  }

  Future<void> _preferTracks() {
    _trackTail = _trackTail
        .then((_) async {
          if (!mounted) return;
          final codecs = await (_decoderCodecs ??= _readDecoderCodecs());
          if (!mounted) return;
          final audio = TrackPreferences.audio(
            player.state.tracks.audio,
            supportedCodecs: codecs,
          );
          final subtitle = TrackPreferences.subtitle([
            ...player.state.tracks.subtitle,
            ..._automaticSubtitles,
          ]);
          if (!_userAudio && audio != null && _lastAudio != audio.id) {
            _lastAudio = audio.id;
            try {
              await player.setAudioTrack(audio);
            } catch (_) {
              DebugLog.write('Playback', 'preferred audio unavailable');
            }
          }
          if (mounted &&
              !_userSubtitle &&
              subtitle != null &&
              _lastSubtitle != subtitle.id) {
            _lastSubtitle = subtitle.id;
            try {
              await player.setSubtitleTrack(subtitle);
            } catch (_) {
              DebugLog.write('Playback', 'preferred subtitles unavailable');
            }
          }
        })
        .catchError((Object error) {
          DebugLog.write(
            'Playback',
            'track preference failed ${error.runtimeType}',
          );
        });
    return _trackTail;
  }

  Future<String> _property(String name) async {
    final native = player.platform;
    if (native is! NativePlayer) throw UnsupportedError('Native mpv required');
    return native.getProperty(name);
  }

  void _layoutSurface(bool visible) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _leavingPlayback || _surface == null) return;
      final box = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
      if (!visible || box == null || !box.hasSize || box.size.isEmpty) {
        _lastLayout = null;
        unawaited(_surfaces.invokeMethod<void>('hide', [_surface]));
        return;
      }
      final scale = View.of(context).devicePixelRatio;
      final origin = box.localToGlobal(Offset.zero) * scale;
      final layout = [
        _surface!,
        origin.dx.round(),
        origin.dy.round(),
        (box.size.width * scale).round(),
        (box.size.height * scale).round(),
        _barVisible ? (_barHeight * scale).ceil() : 0,
      ];
      if (listEquals(_lastLayout, layout)) return;
      _lastLayout = layout;
      unawaited(_surfaces.invokeMethod<void>('layout', layout));
    });
  }

  Widget _nativeControls() => PlayerScrollVolume(
    volume: () => player.state.volume,
    onChanged: player.setVolume,
    child: ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          LayoutBuilder(
            builder: (context, _) {
              final route = ModalRoute.of(context);
              return AnimatedBuilder(
                animation: route?.animation ?? kAlwaysCompleteAnimation,
                builder: (context, _) {
                  _layoutSurface(
                    error == null &&
                        route?.isCurrent == true &&
                        route?.animation?.status == AnimationStatus.completed,
                  );
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _d3d11RenderApi
                        ? () {
                            _nativePlaybackFocus.requestFocus();
                            unawaited(player.playOrPause());
                          }
                        : null,
                    onDoubleTap: _d3d11RenderApi
                        ? _toggleNativeFullscreen
                        : null,
                    child: SizedBox.expand(key: _viewportKey),
                  );
                },
              );
            },
          ),
          if (_barVisible)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              height: _barHeight,
              child: ColoredBox(
                color: Colors.black,
                child: Column(
                  children: [
                    SizedBox(
                      height: 40,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        child: LayoutBuilder(
                          builder: (context, constraints) =>
                              StreamBuilder<Duration>(
                                stream: player.stream.position,
                                initialData: player.state.position,
                                builder: (_, snapshot) {
                                  final duration = player.state.duration;
                                  final end = duration.inMilliseconds
                                      .toDouble();
                                  final value =
                                      (_dragMs ??
                                              (snapshot.data ?? Duration.zero)
                                                  .inMilliseconds
                                                  .toDouble())
                                          .clamp(0.0, end);
                                  return Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      SliderTheme(
                                        data: SliderTheme.of(context).copyWith(
                                          trackHeight: 6,
                                          activeTrackColor:
                                              NipaPlayStyle.accent,
                                          inactiveTrackColor: Colors.white54,
                                          thumbColor: Colors.white,
                                        ),
                                        child: Slider(
                                          padding: EdgeInsets.zero,
                                          max: end > 0 ? end : 1,
                                          value: value,
                                          onChanged: end > 0
                                              ? (v) =>
                                                    setState(() => _dragMs = v)
                                              : null,
                                          onChangeEnd: (v) {
                                            setState(() => _dragMs = null);
                                            _seek(
                                              Duration(milliseconds: v.round()),
                                            );
                                          },
                                        ),
                                      ),
                                      Positioned.fill(
                                        child: IgnorePointer(
                                          child: _timeline(
                                            context,
                                            duration,
                                            null,
                                            constraints.maxWidth,
                                          ),
                                        ),
                                      ),
                                    ],
                                  );
                                },
                              ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Row(
                        children: [
                          StreamBuilder<bool>(
                            stream: player.stream.playing,
                            initialData: player.state.playing,
                            builder: (_, state) => IconButton(
                              color: Colors.white,
                              tooltip: state.data == true
                                  ? context.l10n.pause
                                  : context.l10n.play,
                              icon: Icon(
                                state.data == true
                                    ? Icons.pause
                                    : Icons.play_arrow,
                              ),
                              onPressed: player.playOrPause,
                            ),
                          ),
                          Expanded(child: _tools()),
                          _volumeControl(),
                          ValueListenableBuilder<bool>(
                            valueListenable: playerFullscreen,
                            builder: (_, full, _) => IconButton(
                              color: Colors.white,
                              icon: Icon(
                                full ? Icons.fullscreen_exit : Icons.fullscreen,
                              ),
                              onPressed: _toggleNativeFullscreen,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    ),
  );

  // Both gesture implementations share the action order and chapter overlay.
  List<Widget> _playbackActions({required bool desktop}) => [
    if (desktop)
      const MaterialDesktopPlayOrPauseButton()
    else
      const MaterialPlayOrPauseButton(),
    if (!desktop && Platform.isAndroid)
      PlayerOrientationButton(
        locked: _orientationLocked,
        busy: _orientationBusy,
        onPressed: _toggleOrientation,
      ),
    if (!desktop && Platform.isAndroid)
      Expanded(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _tools(scrollable: false),
              _volumeControl(),
              const MaterialPositionIndicator(),
            ],
          ),
        ),
      )
    else ...[
      Expanded(child: _tools()),
      _volumeControl(),
      if (desktop)
        const MaterialDesktopPositionIndicator()
      else
        const MaterialPositionIndicator(),
    ],
    if (desktop)
      const MaterialDesktopFullscreenButton()
    else if (Platform.isAndroid)
      IconButton(
        tooltip: _androidFullscreen
            ? context.l10n.exitFullscreen
            : context.l10n.fullscreen,
        color: Colors.white,
        icon: Icon(
          _androidFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
        ),
        onPressed: () => _setAndroidFullscreen(!_androidFullscreen),
      )
    else
      const MaterialFullscreenButton(),
  ];

  List<Widget> _topActions({required bool windowed}) => [
    Builder(
      builder: (overlayContext) => BackButton(
        color: Colors.white,
        onPressed: () async {
          if (isFullscreen(overlayContext)) {
            await exitFullscreen(overlayContext);
          }
          _requestPlaybackExit();
        },
      ),
    ),
    Expanded(
      child: PlaybackOverlayTitle(
        title: widget.asset['name'].toString(),
        draggable: windowed,
      ),
    ),
    if (windowed && MediaQuery.sizeOf(context).width >= 600)
      const WindowActions(color: Colors.white),
  ];

  MaterialDesktopVideoControlsThemeData _desktopControls({
    required bool fullscreen,
  }) => MaterialDesktopVideoControlsThemeData(
    modifyVolumeOnScroll: false,
    topButtonBar: _topActions(windowed: !fullscreen),
    bottomButtonBar: _playbackActions(desktop: true),
    seekWhileDragging: !_webDav,
    seekBarOverlayBuilder: _timeline,
    seekBarPositionColor: NipaPlayStyle.accent,
    seekBarThumbColor: NipaPlayStyle.accent,
  );

  MaterialVideoControlsThemeData _touchControls() =>
      MaterialVideoControlsThemeData(
        primaryButtonBar: const [],
        topButtonBar: _topActions(windowed: false),
        bottomButtonBar: _playbackActions(desktop: false),
        seekBarMargin: const EdgeInsets.only(left: 16, right: 16, bottom: 56),
        initialVolume: player.state.volume / 100,
        volumeGesture: true,
        seekGesture: true,
        gesturesEnabledWhileControlsVisible: true,
        onVolumeChanged: (value) => player.setVolume(value * 100),
        seekWhileDragging: !_webDav,
        seekBarOverlayBuilder: _timeline,
        seekDurationLabel: (duration) =>
            context.l10n.seekSeconds(duration.inSeconds.abs()),
        seekIndicatorBuilder: (_, offset) => SeekIndicator(offset: offset),
        seekBarPositionColor: NipaPlayStyle.accent,
        seekBarThumbColor: NipaPlayStyle.accent,
      );

  Widget _volumeControl() => PlayerVolumeControl(
    volume: player.stream.volume,
    initialVolume: player.state.volume,
    onChanged: player.setVolume,
  );
  Widget _tools({bool scrollable = true}) => Builder(
    builder: (toolContext) {
      final actions = IconTheme(
        data: const IconThemeData(color: Colors.white),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: toolContext.l10n.playbackStats,
              icon: const Icon(Icons.info_outline),
              onPressed: () => _nativeWindow
                  ? _inspect(toolContext, false)
                  : _statsVisible.value = !_statsVisible.value,
            ),
            if (!_nativeWindow)
              ValueListenableBuilder<bool>(
                valueListenable: _previewEnabled,
                builder: (_, enabled, _) => IconButton(
                  tooltip: toolContext.l10n.timelinePreview,
                  isSelected: enabled,
                  icon: const Icon(Icons.image_outlined),
                  onPressed: () => _togglePreview(toolContext),
                ),
              ),
            IconButton(
              tooltip: toolContext.l10n.subtitles,
              icon: const Icon(Icons.subtitles_outlined),
              onPressed: () => _tracks(
                toolContext,
                true,
                player.state.track.audio.id,
                player.state.track.subtitle.id,
              ),
            ),
            IconButton(
              tooltip: toolContext.l10n.audioTracks,
              icon: const Icon(Icons.graphic_eq),
              onPressed: () => _tracks(
                toolContext,
                false,
                player.state.track.audio.id,
                player.state.track.subtitle.id,
              ),
            ),
            IconButton(
              tooltip: toolContext.l10n.chapters,
              icon: const Icon(Icons.bookmarks_outlined),
              onPressed: () => _inspect(toolContext, true),
            ),
          ],
        ),
      );
      return scrollable
          ? SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: actions,
            )
          : actions;
    },
  );

  Widget _timeline(
    BuildContext context,
    Duration duration,
    double? fraction,
    double width,
  ) => ValueListenableBuilder<bool>(
    valueListenable: _previewEnabled,
    builder: (_, enabled, _) => FutureBuilder<List<VideoChapter>>(
      future: _chapterData,
      builder: (_, snapshot) => TimelinePreview(
        duration: duration,
        fraction: enabled ? fraction : null,
        width: width,
        chapters: snapshot.data ?? const [],
        loadFrame: (position) async {
          if (!mounted || !_previewEnabled.value) return null;
          final asset = widget.asset;
          final pending = _previewUri ??= _mediaUri(
            Catalog.instance.sourceOf(asset['source_id'].toString()),
            asset['relative_path'].toString(),
            purpose: 'preview',
          );
          final String uri;
          try {
            uri = await pending;
          } catch (_) {
            if (identical(_previewUri, pending)) _previewUri = null;
            return null;
          }
          if (!mounted ||
              !_previewEnabled.value ||
              !identical(_previewUri, pending)) {
            return null;
          }
          _frames ??= TimelineFrames(uri);
          return _frames!.frame(position);
        },
      ),
    ),
  );

  void _togglePreview(BuildContext context) {
    _previewEnabled.value = !_previewEnabled.value;
    if (!_previewEnabled.value) _releasePreview();
    _osd.value = _previewEnabled.value
        ? context.l10n.previewOn
        : context.l10n.previewOff;
    _osdTimer?.cancel();
    _osdTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) _osd.value = null;
    });
  }

  void _releasePreview() {
    final pending = _previewUri;
    _previewUri = null;
    final frames = _frames;
    _frames = null;
    if (pending != null) {
      unawaited(
        pending
            .then((value) {
              final uri = Uri.parse(value);
              // Only revoke a broker ticket owned by this preview. Local files and
              // the primary playback/subtitle tickets remain untouched.
              if (_streamTickets.remove(uri)) StreamBroker.instance.revoke(uri);
            })
            .catchError((Object _) {}),
      );
    }
    if (frames != null) {
      unawaited(
        frames.dispose().catchError((Object e) {
          DebugLog.write(
            'Playback',
            'preview dispose failed ${e.runtimeType}',
            level: 'ERROR',
          );
        }),
      );
    }
  }

  void _inspect(BuildContext context, bool chapters) {
    showPlayerDialog(
      context,
      PlaybackInspector(
        probe: PlaybackProbe(
          _property,
          textureResolution: () {
            final rect = _nativeWindow ? null : controller.rect.value;
            return rect == null || rect.width <= 0 || rect.height <= 0
                ? null
                : '${rect.width.round()} × ${rect.height.round()}';
          },
        ),
        chapterMode: chapters,
        position: () => player.state.position,
        onSeek: _seek,
      ),
    );
  }

  Future<Map<String, Map<String, String>>> _subtitleInfo() async {
    final result = <String, Map<String, String>>{};
    try {
      final count = int.tryParse(await _property('track-list/count')) ?? 0;
      for (var i = 0; i < count; i++) {
        if (await _property('track-list/$i/type') != 'sub') continue;
        final id = await _property('track-list/$i/id');
        final values = <String, String>{};
        for (final key in ['external', 'external-filename']) {
          try {
            values[key] = await _property('track-list/$i/$key');
          } catch (_) {
            /* Optional metadata. */
          }
        }
        result[id] = values;
      }
    } catch (_) {
      /* Track picker can still use media_kit metadata. */
    }
    return result;
  }

  Future<void> _tracks(
    BuildContext sheetContext,
    bool subtitles,
    String audioId,
    String subId,
  ) async {
    final info = subtitles
        ? await _subtitleInfo()
        : <String, Map<String, String>>{};
    if (!sheetContext.mounted) return;
    Widget picker() => TrackPicker(
      subtitles: subtitles,
      selectedId: subtitles
          ? player.state.track.subtitle.id
          : player.state.track.audio.id,
      choices: SubtitleChoices.merge(
        player.state.tracks.subtitle,
        addedSubtitles,
        info,
      ),
      audioTracks: player.state.tracks.audio
          .where((t) => t.id != 'auto')
          .toList(),
      onImport: subtitles
          ? () async {
              final files = await FilePicker.pickFiles(
                type: FileType.custom,
                allowedExtensions: [
                  'ass',
                  'ssa',
                  'srt',
                  'vtt',
                  'sub',
                  'idx',
                  'sup',
                ],
              );
              if (!mounted || files.isEmpty || files.single.path == null) {
                return false;
              }
              final path = files.single.path!;
              final track = SubtitleTrack.uri(
                File(path).uri.toString(),
                title: p.basename(path),
              );
              _userSubtitle = true;
              await _trackTail;
              await player.setSubtitleTrack(track);
              addedSubtitles = [
                ...addedSubtitles.where((s) => s.id != track.id),
                track,
              ];
              return true;
            }
          : null,
      onSubtitle: (track) async {
        _userSubtitle = true;
        await _trackTail;
        await player.setSubtitleTrack(track);
      },
      onAudio: (track) async {
        _userAudio = true;
        await _trackTail;
        await player.setAudioTrack(track);
      },
    );
    await showPlayerDialog(
      sheetContext,
      subtitles
          ? FutureBuilder<void>(
              future: _subtitleDiscovery,
              builder: (_, _) => picker(),
            )
          : picker(),
    );
  }
}
