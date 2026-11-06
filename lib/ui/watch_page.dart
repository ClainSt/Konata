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
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';
import '../core/catalog.dart';
import '../core/debug_log.dart';
import '../core/watched_timeline.dart';
import '../core/watch_settings.dart';
import '../l10n/strings.dart';
import '../core/sources.dart';
import 'nipaplay_style.dart';

class WatchPage extends StatefulWidget {
  const WatchPage({super.key, required this.asset, this.configurationStore});
  final Map<String, Object?> asset;
  final MpvConfigStore? configurationStore;
  @override
  State<WatchPage> createState() => _WatchPageState();
}

class _WatchPageState extends State<WatchPage> with WidgetsBindingObserver {
  late final Player player;
  bool _playerCreated = false;
  bool _androidFullscreen = false;
  static const _androidWindow = MethodChannel('ccplayer/playback_window');
  Directory? _profile;
  bool _profileError = false;
  // Opt-in Windows validation build. Keep the normal embedded surface as the
  // default until native output has passed display and subtitle validation.
  final _nativeWindow =
      Platform.isWindows &&
      const bool.fromEnvironment('CCPLAYER_NATIVE_SDR_OUTPUT');
  static const _surfaces = MethodChannel('ccplayer/native_video');
  final _viewportKey = GlobalKey();
  late final FocusNode _nativePlaybackFocus = FocusNode();
  int? _surface;
  List<int>? _lastLayout;
  static const _barHeight = 88.0;
  bool _barVisible = true;
  bool _checkingPointer = false;
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
      } finally {
        _checkingPointer = false;
      }
    });
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
  Future<void> _saveTail = Future.value();
  bool _opened = false,
      _visible = true,
      _seeking = false,
      _saveErrorShown = false;
  Timer? _saver;
  bool loading = true;
  String? error;
  List<SubtitleTrack> addedSubtitles = [];
  bool _userAudio = false, _userSubtitle = false;
  String? _lastAudio, _lastSubtitle;
  Future<void> _trackTail = Future.value();
  final _previewEnabled = ValueNotifier<bool>(false);
  Timer? _osdTimer;
  final _osd = ValueNotifier<String?>(null);
  final _statsVisible = ValueNotifier<bool>(false);
  Future<List<VideoChapter>> _chapterData = Future.value(const []);
  TimelineFrames? _frames;
  Future<String>? _previewUri;
  bool _webDav = false;
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && Platform.isAndroid) _setAndroidFullscreen(true);
      if (mounted && (AppHeader.desktop || Platform.isAndroid)) {
        playingHeader.value = PlayingHeader(
          widget.asset['name'].toString(),
          () => Navigator.maybePop(context),
          videoOverlay: !_nativeWindow,
        );
      }
    });
    _clock.start();
    final store = widget.configurationStore ?? MpvConfigStore.instance;
    final folder = store.externalFolder;
    if (store.enabled && folder != null) {
      unawaited(_prepareExternalPlayer(store, folder));
    } else {
      _startPlayer(store, store.playerConfiguration);
    }
  }

  Future<void> _prepareExternalPlayer(
    MpvConfigStore store,
    String folder,
  ) async {
    try {
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
    player = Player(configuration: config);
    _playerCreated = true;
    if (!_nativeWindow) {
      controller = VideoController(
        player,
        configuration: store.videoConfiguration,
      );
    }
    if (Platform.isWindows && !_nativeWindow) {
      _stateSubscriptions.add(
        player.stream.videoParams.listen((_) => _scheduleSubtitleCanvas()),
      );
    }
    _positionSubscription = player.stream.position.listen((v) {
      current = v;
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
    });
    _stateSubscriptions.addAll([
      player.stream.duration
          .where((duration) => duration > Duration.zero)
          .listen((_) {
            _chapterData = PlaybackProbe(
              _property,
            ).chapters().catchError((Object _) => <VideoChapter>[]);
            if (mounted) setState(() {});
          }),
      player.stream.tracks.listen((_) {
        if (_opened) _preferTracks();
      }),
      player.stream.playing.distinct().listen((_) => _tracker.reset()),
      player.stream.buffering.distinct().listen((_) => _tracker.reset()),
      player.stream.rate.distinct().listen((_) => _tracker.reset()),
    ]);
    _saver = Timer.periodic(const Duration(seconds: 5), (_) => _save());
    _open();
  }

  Future<void> _open() async {
    try {
      if (Platform.isAndroid && player.platform!.configuration.libass) {
        await controller.platform.future;
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
        final host = await _surfaces.invokeMethod<int>('create');
        if (host == null || host == 0) {
          throw StateError('Missing video surface');
        }
        if (!mounted) {
          await _surfaces.invokeMethod<void>('destroy', [host]);
          return;
        }
        _surface = host;
        await native.setProperty('wid', host.toString());
        if (await native.getProperty('wid') != host.toString()) {
          throw StateError('Native video did not attach to the player window');
        }
        await native.setProperty('vid', 'auto');
        final options = {
          'vo': 'gpu',
          'gpu-api': 'd3d11',
          'gpu-context': 'd3d11',
          'd3d11-output-format': 'rgb10_a2',
          'title': 'Konata',
          if (store.decodeMode != VideoDecodeMode.custom)
            'hwdec': store.videoConfiguration.hwdec ?? 'auto-safe',
        };
        for (final option in options.entries) {
          await native.setProperty(option.key, option.value);
          if (option.key != 'hwdec' &&
              await native.getProperty(option.key) != option.value) {
            throw StateError('Unsupported native output option: ${option.key}');
          }
        }
      }
      final asset = widget.asset;
      final source = Catalog.instance.sourceOf(asset['source_id'].toString());
      final relative = asset['relative_path'].toString();
      _webDav = source['kind'] == 'webdav';
      final uri = await _mediaUri(source, relative);
      if (!mounted) return;
      final resume = _webDav
          ? await Catalog.instance.resumePosition(asset['id'].toString())
          : 0;
      if (!mounted) return;
      final opening = player.open(
        Media(uri, start: resume > 0 ? Duration(milliseconds: resume) : null),
      );
      final remoteSubs = _webDav ? _webDavSubtitles(source, relative) : null;
      await opening;
      _chapterData = PlaybackProbe(
        _property,
      ).chapters().catchError((Object _) => <VideoChapter>[]);
      if (!mounted) return;
      if (_webDav) {
        _showPlayback();
      } else {
        final saved = await Catalog.instance.resumePosition(
          asset['id'].toString(),
        );
        if (!mounted) return;
        if (saved > 0) await _seek(Duration(milliseconds: saved));
      }
      if (!mounted) return;
      final subtitleFiles =
          await (remoteSubs ??
              StreamBroker.instance.subtitles(source, relative));
      final tracks = <SubtitleTrack>[];
      for (final subtitle in subtitleFiles) {
        if (!mounted) return;
        final target = source['kind'] == 'local'
            ? p.join(
                source['location'].toString(),
                subtitle.replaceAll('/', Platform.pathSeparator),
              )
            : await _issueStream(source, subtitle, purpose: 'subtitle');
        tracks.add(SubtitleTrack.uri(target, title: p.basename(subtitle)));
      }
      if (!mounted) return;
      addedSubtitles = [...addedSubtitles, ...tracks];
      await _preferTracks();
      if (mounted && !_opened) _showPlayback();
    } catch (e) {
      if (_webDav && _opened) {
        DebugLog.write(
          'Playback',
          'subtitle setup failed ${e.runtimeType}',
          level: 'WARN',
        );
        return;
      }
      DebugLog.write(
        'Playback',
        'open failed ${e.runtimeType}',
        level: 'ERROR',
      );
      if (mounted) {
        setState(() {
          error = e.runtimeType.toString();
          loading = false;
        });
      }
    }
  }

  Future<String> _mediaUri(
    Map<String, Object?> source,
    String path, {
    String purpose = 'playback',
  }) async {
    if (source['kind'] == 'local') {
      return p.join(
        source['location'].toString(),
        path.replaceAll('/', Platform.pathSeparator),
      );
    }
    return _issueStream(source, path, purpose: purpose);
  }

  Future<List<String>> _webDavSubtitles(
    Map<String, Object?> source,
    String path,
  ) async {
    try {
      return await StreamBroker.instance.subtitles(source, path);
    } catch (e) {
      DebugLog.write(
        'Playback',
        'subtitle listing failed ${e.runtimeType}',
        level: 'WARN',
      );
      return [];
    }
  }

  void _showPlayback() {
    if (_nativeWindow) _watchNativePointer();
    _opened = true;
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

  Future<void> _seek(Duration value) async {
    _seeking = true;
    _tracker.reset();
    try {
      await player.seek(value);
    } finally {
      _tracker.reset();
      _seeking = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _visible =
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    _tracker.reset();
    if (!_visible) unawaited(_save());
  }

  Future<void> _finish() async {
    try {
      await _save();
    } finally {
      try {
        if (_playerCreated) await player.dispose();
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
      }
    }
  }

  @override
  void dispose() {
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
    _previewEnabled.dispose();
    _statsVisible.dispose();
    if (_nativeWindow) _nativePlaybackFocus.dispose();
    _osdTimer?.cancel();
    _osd.dispose();
    unawaited(_frames?.dispose() ?? Future<void>.value());
    if (_androidFullscreen) {
      playerFullscreen.value = false;
      unawaited(_androidWindow.invokeMethod<void>('fullscreen', false));
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
    return enabled
        ? defaultEnterNativeFullscreen()
        : defaultExitNativeFullscreen();
  }

  void _setAndroidFullscreen(bool enabled) {
    setState(() => _androidFullscreen = enabled);
    playerFullscreen.value = enabled;
    unawaited(_androidWindow.invokeMethod<void>('fullscreen', enabled));
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
    if (_nativeWindow &&
        event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        playerFullscreen.value) {
      unawaited(_toggleNativeFullscreen());
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
        body: error != null
            ? Center(
                child: Text(
                  _profileError
                      ? context.l10n.mpvFolderReadError
                      : context.l10n.playbackFailed,
                ),
              )
            : loading
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
                                          MediaQuery.sizeOf(context).width < 520
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
    );
  }

  Future<void> _preferTracks() {
    _trackTail = _trackTail
        .then((_) async {
          if (!mounted) return;
          final audio = TrackPreferences.audio(player.state.tracks.audio);
          final subtitle = TrackPreferences.subtitle([
            ...player.state.tracks.subtitle,
            ...addedSubtitles,
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
      if (!mounted || _surface == null) return;
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

  Widget _nativeControls() => ColoredBox(
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
                  route?.isCurrent == true &&
                      route?.animation?.status == AnimationStatus.completed,
                );
                return SizedBox.expand(key: _viewportKey);
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
                                final end = duration.inMilliseconds.toDouble();
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
                                        activeTrackColor: NipaPlayStyle.accent,
                                        inactiveTrackColor: Colors.white54,
                                        thumbColor: Colors.white,
                                      ),
                                      child: Slider(
                                        padding: EdgeInsets.zero,
                                        max: end > 0 ? end : 1,
                                        value: value,
                                        onChanged: end > 0
                                            ? (v) => setState(() => _dragMs = v)
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
  );

  // Both gesture implementations share the action order and chapter overlay.
  List<Widget> _playbackActions({required bool desktop}) => [
    if (desktop)
      const MaterialDesktopPlayOrPauseButton()
    else
      const MaterialPlayOrPauseButton(),
    Expanded(child: _tools()),
    _volumeControl(),
    if (desktop)
      const MaterialDesktopPositionIndicator()
    else
      const MaterialPositionIndicator(),
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
          if (mounted) await Navigator.maybePop(context);
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
  Widget _tools() => Builder(
    builder: (toolContext) => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: IconTheme(
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
      ),
    ),
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
          if (!mounted || !_previewEnabled.value) return null;
          _frames ??= TimelineFrames(uri);
          return _frames!.frame(position);
        },
      ),
    ),
  );

  void _togglePreview(BuildContext context) {
    _previewEnabled.value = !_previewEnabled.value;
    _osd.value = _previewEnabled.value
        ? context.l10n.previewOn
        : context.l10n.previewOff;
    _osdTimer?.cancel();
    _osdTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) _osd.value = null;
    });
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
    await showPlayerDialog(
      sheetContext,
      TrackPicker(
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
      ),
    );
  }
}
