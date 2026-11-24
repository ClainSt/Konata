import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:engine_playback/engine_playback.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:konata_contracts/konata_contracts.dart';

/// Android 根窗口底层硬件表面控制器（仅在 Android 入口按需装配，零桌面插件依赖）。
final class AndroidVideoSurfaceAdapter implements AndroidVideoSurfacePort {
  /// 创建 Android 底层硬件表面控制器。
  AndroidVideoSurfaceAdapter({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(underlayChannelName) {
    _channel.setMethodCallHandler(_onMethodCall);
  }

  /// 与 Android 原生宿主约定的底层表面通道名称。
  static const String underlayChannelName = 'konata/android_underlay_surface';

  final MethodChannel _channel;
  final StreamController<AndroidSurfaceDescriptor?> _surfaceChanges =
      StreamController<AndroidSurfaceDescriptor?>.broadcast();

  AndroidSurfaceDescriptor? _current;
  bool _disposed = false;
  bool _shown = false;
  int? _lastLeftPx;
  int? _lastTopPx;
  int? _lastRightPx;
  int? _lastBottomPx;
  double? _lastRadiusPx;

  @override
  AndroidSurfaceDescriptor? get current => _current;

  @override
  Stream<AndroidSurfaceDescriptor?> get surfaceChanges =>
      _surfaceChanges.stream;

  @override
  bool get isDisposed => _disposed;

  Future<Object?> _onMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'changed':
        final args = call.arguments;
        if (args is Map) {
          final wid = (args['wid'] as num?)?.toInt() ?? 0;
          final width = (args['width'] as num?)?.toInt() ?? 0;
          final height = (args['height'] as num?)?.toInt() ?? 0;
          final hdrPeak = (args['hdrPeak'] as num?)?.toDouble() ?? 0.0;
          if (wid > 0 && (width <= 0 || height <= 0)) {
            _current = null;
            return null;
          }
          _current = (wid > 0 && width > 0 && height > 0)
              ? AndroidSurfaceDescriptor(
                  wid: wid,
                  width: width,
                  height: height,
                  hdrPeak: hdrPeak,
                )
              : null;
          if (!_surfaceChanges.isClosed) {
            _surfaceChanges.add(_current);
          }
        }
      case 'lost':
        _current = null;
        if (!_surfaceChanges.isClosed) {
          _surfaceChanges.add(null);
        }
    }
    return null;
  }

  @override
  Future<void> syncViewportRect({
    required int leftPx,
    required int topPx,
    required int rightPx,
    required int bottomPx,
    double cornerRadiusPx = 0.0,
  }) async {
    if (_disposed || rightPx <= leftPx || bottomPx <= topPx) return;
    final radiusChanged =
        _lastRadiusPx == null || (cornerRadiusPx - _lastRadiusPx!).abs() > 0.25;
    if (_shown &&
        _lastLeftPx == leftPx &&
        _lastTopPx == topPx &&
        _lastRightPx == rightPx &&
        _lastBottomPx == bottomPx &&
        !radiusChanged) {
      return;
    }
    _lastLeftPx = leftPx;
    _lastTopPx = topPx;
    _lastRightPx = rightPx;
    _lastBottomPx = bottomPx;
    _lastRadiusPx = cornerRadiusPx;
    final method = _shown ? 'setRect' : 'show';
    _shown = true;
    try {
      await _channel.invokeMethod<Object?>(method, <String, Object>{
        'leftPx': leftPx,
        'topPx': topPx,
        'rightPx': rightPx,
        'bottomPx': bottomPx,
        'radiusPx': cornerRadiusPx,
      });
    } on MissingPluginException {
      // 无 Android 原生表面通道时静默忽略。
    } on PlatformException catch (error) {
      developer.log('Android 表面视口同步异常', name: 'konata.android_surface', error: error);
    }
  }

  @override
  Future<void> hideViewport() async {
    if (_disposed || !_shown) return;
    _shown = false;
    _lastLeftPx = null;
    _lastTopPx = null;
    _lastRightPx = null;
    _lastBottomPx = null;
    _lastRadiusPx = null;
    try {
      await _channel.invokeMethod<void>('hide');
    } on MissingPluginException {
      // 忽略无宿主通道。
    } on PlatformException {
      // 忽略窗口已关闭异常。
    }
  }

  @override
  Future<AndroidSurfaceDescriptor?> queryCurrent() async {
    try {
      final result = await _channel.invokeMapMethod<String, Object?>('current');
      if (result == null) return null;
      final wid = (result['wid'] as num?)?.toInt() ?? 0;
      final width = (result['width'] as num?)?.toInt() ?? 0;
      final height = (result['height'] as num?)?.toInt() ?? 0;
      if (wid <= 0 || width <= 0 || height <= 0) {
        _current = null;
        return null;
      }
      _current = AndroidSurfaceDescriptor(
        wid: wid,
        width: width,
        height: height,
        hdrPeak: (result['hdrPeak'] as num?)?.toDouble() ?? 0.0,
      );
      return _current;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<void> releaseReference(int wid) async {
    if (wid <= 0) return;
    try {
      await _channel.invokeMethod<void>('release', wid);
    } on MissingPluginException {
      // 忽略无原生通道。
    } on PlatformException {
      // 忽略已回收句柄。
    }
  }

  @override
  Future<void> releaseSurface() async {
    _shown = false;
    _lastLeftPx = null;
    _lastTopPx = null;
    _lastRightPx = null;
    _lastBottomPx = null;
    _lastRadiusPx = null;
    try {
      await _channel.invokeMethod<void>('releaseAll');
    } on MissingPluginException {
      // 忽略无原生通道。
    } on PlatformException {
      // 忽略关闭期异常。
    }
    _current = null;
  }

  @override
  Future<void> detachWithoutClearingChannel() async {
    if (_disposed) return;
    _disposed = true;
    if (!_surfaceChanges.isClosed) {
      await _surfaceChanges.close();
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _channel.setMethodCallHandler(null);
    if (!_surfaceChanges.isClosed) {
      await _surfaceChanges.close();
    }
  }
}

/// Android 原生音频路由监听与外接 USB DAC 逐位直通协商适配器。
final class AndroidAudioRouteAdapter implements AndroidAudioRoutePort {
  /// 创建 Android 音频路由通道适配器。
  AndroidAudioRouteAdapter({
    MethodChannel? channel,
    bool Function()? isSupported,
  }) : _channel = channel ?? const MethodChannel(_channelName),
       _isSupported = isSupported ?? (() => Platform.isAndroid);

  static const String _channelName = 'konata/audio_route';

  final MethodChannel _channel;
  final bool Function() _isSupported;

  bool _handlerRegistered = false;
  final Map<Object, void Function(String reason)> _removedListeners =
      <Object, void Function(String reason)>{};
  final Map<Object, void Function(String deviceFingerprint)> _addedListeners =
      <Object, void Function(String deviceFingerprint)>{};

  @override
  void bindRouteListeners({
    required Object owner,
    void Function(String reason)? onOutputDeviceRemoved,
    void Function(String deviceFingerprint)? onOutputDeviceAdded,
  }) {
    if (onOutputDeviceRemoved != null) {
      _removedListeners[owner] = onOutputDeviceRemoved;
    } else {
      _removedListeners.remove(owner);
    }
    if (onOutputDeviceAdded != null) {
      _addedListeners[owner] = onOutputDeviceAdded;
    } else {
      _addedListeners.remove(owner);
    }
    if (!_isSupported() || _handlerRegistered) return;
    _handlerRegistered = true;
    _channel.setMethodCallHandler(_handlePlatformCall);
    unawaited(
      _channel
          .invokeMethod<Object?>('startMonitoring')
          .catchError((Object _) => null),
    );
  }

  @override
  void unbindRouteListeners({required Object owner}) {
    _removedListeners.remove(owner);
    _addedListeners.remove(owner);
  }

  Future<Object?> _handlePlatformCall(MethodCall call) async {
    switch (call.method) {
      case 'outputDeviceRemoved':
        final reason = (call.arguments as String?) ?? 'device_removed';
        for (final cb in List<void Function(String)>.of(
          _removedListeners.values,
        )) {
          cb(reason);
        }
      case 'outputDeviceAdded':
        final fingerprint = (call.arguments as String?) ?? 'external_audio';
        for (final cb in List<void Function(String)>.of(
          _addedListeners.values,
        )) {
          cb(fingerprint);
        }
    }
    return null;
  }

  @override
  Future<AndroidBitPerfectNegotiationResult> negotiateBitPerfectUsb({
    required bool enable,
    int? preferredSampleRateHz,
  }) async {
    if (!_isSupported()) {
      return const AndroidBitPerfectNegotiationResult(
        supported: false,
        engaged: false,
        detail: '当前平台无需 Android 混音器逐位协商',
      );
    }
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'negotiateBitPerfectUsb',
        <String, Object>{
          'sampleRateHz': preferredSampleRateHz ?? 48000,
          'enable': enable,
        },
      );
      if (raw == null) {
        return const AndroidBitPerfectNegotiationResult(
          supported: false,
          engaged: false,
        );
      }
      return AndroidBitPerfectNegotiationResult(
        supported: raw['supported'] == true,
        engaged: raw['engaged'] == true,
        deviceName: (raw['deviceName'] as String?) ?? '',
        sampleRateHz: (raw['sampleRateHz'] as num?)?.toInt() ?? 0,
        detail: (raw['detail'] as String?) ?? '',
      );
    } catch (error) {
      return AndroidBitPerfectNegotiationResult(
        supported: false,
        engaged: false,
        detail: error.toString(),
      );
    }
  }

  @override
  void dispose() {
    _removedListeners.clear();
    _addedListeners.clear();
    if (_handlerRegistered) {
      _handlerRegistered = false;
      _channel.setMethodCallHandler(null);
    }
  }
}

/// Android 锁屏与通知栏媒体会话双向桥接适配器。
final class AndroidMediaSessionAdapter implements AndroidMediaSessionPort {
  /// 创建 Android 媒体会话通道适配器。
  AndroidMediaSessionAdapter({
    MethodChannel? channel,
    bool Function()? isSupported,
  }) : _channel = channel ?? const MethodChannel('konata/media_session'),
       _isSupported =
           isSupported ??
           (() => !kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  final MethodChannel _channel;
  final bool Function() _isSupported;
  final AndroidMediaSessionSyncFilter _syncFilter =
      AndroidMediaSessionSyncFilter();

  bool _handlerBound = false;
  VoidCallback? _onPlay;
  VoidCallback? _onPause;
  VoidCallback? _onTogglePlayPause;
  VoidCallback? _onPrevious;
  VoidCallback? _onNext;
  ValueChanged<double>? _onSeekToSeconds;
  VoidCallback? _onStop;

  @override
  void bindCallbacks({
    required void Function() onPlay,
    required void Function() onPause,
    required void Function() onTogglePlayPause,
    required void Function() onPrevious,
    required void Function() onNext,
    required void Function(double positionSeconds) onSeekToSeconds,
    required void Function() onStop,
  }) {
    _onPlay = onPlay;
    _onPause = onPause;
    _onTogglePlayPause = onTogglePlayPause;
    _onPrevious = onPrevious;
    _onNext = onNext;
    _onSeekToSeconds = onSeekToSeconds;
    _onStop = onStop;
    if (_handlerBound || !_isSupported()) return;
    try {
      ServicesBinding.instance;
      _handlerBound = true;
      _channel.setMethodCallHandler(_handleNativeCall);
    } catch (_) {
      // 测试环境未初始化绑定时跳过监听注册。
    }
  }

  Future<Object?> _handleNativeCall(MethodCall call) async {
    if (call.method != 'onMediaAction') return null;
    final map = call.arguments as Map<Object?, Object?>?;
    final cmd = map?['command']?.toString() ?? '';
    switch (cmd) {
      case 'play':
        _onPlay?.call();
      case 'pause':
        _onPause?.call();
      case 'togglePlayPause':
        _onTogglePlayPause?.call();
      case 'previous':
        _onPrevious?.call();
      case 'next':
        _onNext?.call();
      case 'seekTo':
        final rawMs = (map?['positionMs'] as num?)?.toDouble();
        if (rawMs != null) {
          _onSeekToSeconds?.call((rawMs / 1000.0).clamp(0.0, double.infinity));
        }
      case 'stop':
        _onStop?.call();
    }
    return null;
  }

  @override
  Future<void> syncSession({
    required String trackId,
    required String title,
    required String artist,
    required String album,
    required double durationSeconds,
    required double positionSeconds,
    required bool isPlaying,
    required String coverKey,
    Uint8List? coverBytes,
    bool forcePositionSync = false,
  }) async {
    if (!_isSupported()) return;
    if (title.trim().isEmpty) {
      await stopSession();
      return;
    }
    final payload = _syncFilter.buildPayloadIfChanged(
      trackId: trackId,
      title: title,
      artist: artist,
      album: album,
      durationSeconds: durationSeconds,
      positionSeconds: positionSeconds,
      isPlaying: isPlaying,
      coverKey: coverKey,
      coverBytes: coverBytes,
      forcePositionSync: forcePositionSync,
    );
    if (payload == null) return;
    try {
      await _channel.invokeMethod<void>('update', payload);
    } catch (error) {
      developer.log('同步系统通知栏媒体卡片失败', name: 'konata.media_session', error: error);
    }
  }

  @override
  Future<void> stopSession() async {
    if (!_syncFilter.markStopped()) return;
    if (!_isSupported()) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (error) {
      developer.log('停止系统通知栏媒体卡片失败', name: 'konata.media_session', error: error);
    }
  }

  @override
  void dispose() {
    if (_handlerBound) {
      try {
        _channel.setMethodCallHandler(null);
      } catch (_) {
        // 忽略关闭期通道解绑异常。
      }
      _handlerBound = false;
    }
    _onPlay = null;
    _onPause = null;
    _onTogglePlayPause = null;
    _onPrevious = null;
    _onNext = null;
    _onSeekToSeconds = null;
    _onStop = null;
  }
}

/// Android 截图保存至系统相册适配器。
final class AndroidMediaStorePublisher implements MediaStorePublisherPort {
  /// 创建系统相册发布适配器。
  const AndroidMediaStorePublisher({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('konata/media_store');

  final MethodChannel _channel;

  @override
  Future<String?> saveImageToGallery({
    required File tempFile,
    required String displayName,
    required String albumName,
    String mimeType = 'image/png',
  }) async {
    try {
      return await _channel.invokeMethod<String>(
        'saveImageToGallery',
        <String, Object?>{
          'sourcePath': tempFile.path,
          'displayName': displayName,
          'albumName': albumName,
          'mimeType': mimeType,
        },
      );
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}

/// Android 全屏沉浸系统栏与横竖屏方向控制适配器（直连原生 `konata/playback_window` 通道）。
final class AndroidPlaybackWindowAdapter implements PlaybackHostWindowPort {
  /// 创建移动端窗口播控适配器。
  AndroidPlaybackWindowAdapter({
    MethodChannel? channel,
    bool Function()? isSupported,
  }) : _channel = channel ?? const MethodChannel('konata/playback_window'),
       _isSupported =
           isSupported ??
           (() => !kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  final MethodChannel _channel;
  final bool Function() _isSupported;

  bool _fullScreen = false;

  @override
  Future<bool> isFullScreen() async => _fullScreen;

  @override
  Future<void> setFullScreen(bool enable) async {
    _fullScreen = enable;
    if (_isSupported()) {
      try {
        await _channel.invokeMethod<void>('fullscreen', enable);
        return;
      } on MissingPluginException {
        // 测试或无原生通道环境自动回退至框架系统栏控制。
      } on PlatformException {
        // 忽略瞬态窗口状态异常并回退框架控制。
      }
    }
    await SystemChrome.setEnabledSystemUIMode(
      enable ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
  }

  @override
  Future<void> setAlwaysOnTop(bool enable) async {
    // 移动端不支持桌面窗口置顶。
  }

  @override
  Future<void> enterDesktopMiniWindow({
    required double width,
    required double height,
  }) async {
    // 移动端不启用桌面置顶迷你窗口。
  }

  @override
  Future<void> exitDesktopMiniWindow() async {
    // 移动端无需退出桌面置顶迷你窗口。
  }

  @override
  Future<void> setKeepScreenOn(bool enable) async {
    // 屏幕常亮由移动端视频硬件表面生命周期托管。
  }

  @override
  Future<void> setPreferredLandscape(bool landscape) async {
    if (_isSupported()) {
      try {
        await _channel.invokeMethod<void>('setLandscape', landscape);
        return;
      } on MissingPluginException {
        // 测试或无原生通道环境自动回退框架方向控制。
      } on PlatformException {
        // 忽略瞬态方向切换异常并回退框架方向控制。
      }
    }
    await SystemChrome.setPreferredOrientations(
      landscape
          ? const <DeviceOrientation>[
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ]
          : const <DeviceOrientation>[],
    );
  }
}

/// Android 原生音频焦点管理适配器（直连 `MainActivity.kt` 的 `konata/audio_focus` 通道）。
final class AndroidAudioFocusAdapter implements AndroidAudioFocusPort {
  /// 创建 Android 音频焦点适配器。
  AndroidAudioFocusAdapter({
    MethodChannel? channel,
    bool Function()? isSupported,
  }) : _channel = channel ?? const MethodChannel('konata/audio_focus'),
       _isSupported =
           isSupported ??
           (() => !kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  final MethodChannel _channel;
  final bool Function() _isSupported;

  bool _handlerBound = false;
  void Function()? _onLoss;
  void Function()? _onDuck;
  void Function()? _onGain;

  @override
  Future<void> requestAudioFocus({
    void Function()? onLoss,
    void Function()? onDuck,
    void Function()? onGain,
  }) async {
    _onLoss = onLoss;
    _onDuck = onDuck;
    _onGain = onGain;
    if (!_isSupported()) return;
    _ensureHandlerBound();
    try {
      await _channel.invokeMethod<bool>('request');
    } on MissingPluginException {
      // 无原生通道时静默忽略。
    } on PlatformException catch (error) {
      developer.log(
        '请求 Android 音频焦点失败',
        name: 'konata.android_audio_focus',
        error: error,
      );
    }
  }

  @override
  Future<void> abandonAudioFocus() async {
    _onLoss = null;
    _onDuck = null;
    _onGain = null;
    if (!_isSupported()) return;
    try {
      await _channel.invokeMethod<void>('abandon');
    } on MissingPluginException {
      // 无原生通道时静默忽略。
    } on PlatformException catch (error) {
      developer.log(
        '释放 Android 音频焦点失败',
        name: 'konata.android_audio_focus',
        error: error,
      );
    }
  }

  void _ensureHandlerBound() {
    if (_handlerBound) return;
    try {
      ServicesBinding.instance;
      _handlerBound = true;
      _channel.setMethodCallHandler(_handleNativeCall);
    } catch (_) {
      // 测试环境未初始化绑定时跳过通道回调注册。
    }
  }

  Future<Object?> _handleNativeCall(MethodCall call) async {
    if (call.method != 'focusChange') return null;
    switch (call.arguments?.toString()) {
      case 'loss':
      case 'lossTransient':
        _onLoss?.call();
      case 'duck':
        _onDuck?.call();
      case 'gain':
        _onGain?.call();
    }
    return null;
  }

  @override
  void dispose() {
    if (_handlerBound) {
      try {
        _channel.setMethodCallHandler(null);
      } catch (_) {
        // 忽略关闭期通道解绑异常。
      }
      _handlerBound = false;
    }
    _onLoss = null;
    _onDuck = null;
    _onGain = null;
  }
}

/// Android 原生画中画通道适配器（直连 `MainActivity.kt` 的 `konata/pip` 通道）。
final class AndroidPipAdapter implements AndroidPipPort {
  /// 创建 Android 画中画适配器。
  AndroidPipAdapter({
    MethodChannel? channel,
    bool Function()? isSupported,
  }) : _channel = channel ?? const MethodChannel('konata/pip'),
       _isSupported =
           isSupported ??
           (() => !kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  final MethodChannel _channel;
  final bool Function() _isSupported;

  bool _handlerBound = false;
  AndroidPipState? _lastSyncedState;
  void Function(bool active)? _onPipModeChanged;
  void Function(String action)? _onRemoteAction;
  void Function()? _onPipDismissed;

  @override
  void bindCallbacks({
    required void Function(bool active) onPipModeChanged,
    required void Function(String action) onRemoteAction,
    void Function()? onPipDismissed,
  }) {
    _onPipModeChanged = onPipModeChanged;
    _onRemoteAction = onRemoteAction;
    _onPipDismissed = onPipDismissed;
    if (!_isSupported() || _handlerBound) return;
    try {
      ServicesBinding.instance;
      _handlerBound = true;
      _channel.setMethodCallHandler(_handleNativeCall);
    } catch (_) {
      // 测试环境未初始化绑定时跳过通道回调注册。
    }
  }

  @override
  void unbindCallbacks() {
    _onPipModeChanged = null;
    _onRemoteAction = null;
    _onPipDismissed = null;
    if (_handlerBound) {
      try {
        _channel.setMethodCallHandler(null);
      } catch (_) {
        // 忽略关闭期通道解绑异常。
      }
      _handlerBound = false;
    }
  }

  Future<Object?> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'pipChanged':
        _onPipModeChanged?.call(call.arguments == true);
      case 'pipDismissed':
        _onPipDismissed?.call();
      case 'action':
        final cmd = call.arguments?.toString() ?? '';
        if (cmd.isNotEmpty) {
          _onRemoteAction?.call(cmd);
        }
    }
    return null;
  }

  @override
  Future<void> syncState(AndroidPipState state) async {
    if (!_isSupported() || _lastSyncedState == state) return;
    _lastSyncedState = state;
    try {
      await _channel.invokeMethod<void>('syncState', state.toChannelMap());
    } on MissingPluginException {
      // 无原生通道时静默忽略。
    } on PlatformException catch (error) {
      developer.log(
        '同步 Android 画中画状态失败',
        name: 'konata.android_pip',
        error: error,
      );
    }
  }

  @override
  Future<bool> enterPipNow() async {
    if (!_isSupported()) return false;
    try {
      final entered = await _channel.invokeMethod<bool>('enter');
      return entered == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
