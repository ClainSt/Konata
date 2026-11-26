import 'dart:async';
import 'dart:developer' as developer;
import 'dart:ui' as ui;

import 'package:engine_playback/engine_playback.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';
import 'package:konata_storage/konata_storage.dart';
import 'package:window_manager/window_manager.dart' as wm;

/// Windows 桌面端高色深 D3D11 / DirectComposition 视频渲染桥接器。
///
/// 仅由 `bootstrap/windows_app.dart` 装配注入，物理隔离于 Android 裁剪入口之外。
final class WindowsD3d11VideoBridge implements KonataVideoTextureBridge {
  /// 构造桌面视频渲染通道桥接器。
  WindowsD3d11VideoBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName) {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  /// 与 Windows 原生宿主约定的通道名称。
  static const String channelName = 'konata/d3d11_video';

  final MethodChannel _channel;
  final StreamController<NativeTextureChangedEvent> _changesController =
      StreamController<NativeTextureChangedEvent>.broadcast();

  @override
  Stream<NativeTextureChangedEvent> get textureChanges =>
      _changesController.stream;

  Future<Object?> _handleNativeCall(MethodCall call) async {
    if (call.method == 'onTextureChanged' && call.arguments is Map) {
      final raw = call.arguments as Map<Object?, Object?>;
      if (!_changesController.isClosed) {
        _changesController.add(
          NativeTextureChangedEvent(
            sessionId: (raw['sessionId'] as num?)?.toInt() ?? 0,
            textureId: (raw['textureId'] as num?)?.toInt() ?? -1,
            backend: raw['backend']?.toString() ?? 'sw',
            surfaceFormat: raw['surfaceFormat']?.toString() ?? '',
            colorBitDepth: (raw['colorBitDepth'] as num?)?.toInt() ?? 8,
            adapterName: raw['adapterName']?.toString() ?? '',
            reason: raw['reason']?.toString() ?? '',
          ),
        );
      }
    }
    return null;
  }

  @override
  Future<NativeVideoSessionHandle> createSession({
    required int mpvHandleAddress,
    int width = 1280,
    int height = 720,
    bool preferSoftware = false,
    String renderBackend = 'gpu_next',
  }) async {
    final nativeBackend = switch (renderBackend) {
      'comp_10bit' => 'dcomp_10bit',
      'comp_fp16' => 'dcomp_fp16',
      'texture_fallback' => 'd3d11_10bit',
      _ => renderBackend,
    };
    final result = await _channel
        .invokeMapMethod<String, Object?>('createSession', <String, Object?>{
          'mpvHandle': mpvHandleAddress,
          'width': width,
          'height': height,
          'preferSoftware': preferSoftware,
          'renderBackend': nativeBackend,
        });
    if (result == null) {
      throw StateError('桌面视频纹理通道 createSession 返回空结果');
    }
    return NativeVideoSessionHandle(
      sessionId: (result['sessionId'] as num?)?.toInt() ?? 0,
      textureId: (result['textureId'] as num?)?.toInt() ?? -1,
      backend: result['backend']?.toString() ?? 'gpu_next',
      surfaceFormat:
          result['surfaceFormat']?.toString() ??
          'DXGI_FORMAT_R10G10B10A2_UNORM',
      colorBitDepth: (result['colorBitDepth'] as num?)?.toInt() ?? 10,
      underlaySwapChainActive: result['dcompActive'] == true,
      nativeWindowHandle: (result['nativeWindowHandle'] as num?)?.toInt() ?? 0,
      adapterName: result['adapterName']?.toString() ?? '',
    );
  }

  @override
  Future<void> resize({
    required int sessionId,
    required int width,
    required int height,
  }) async {
    if (sessionId <= 0 || width <= 0 || height <= 0) return;
    await _channel.invokeMethod<void>('resize', <String, Object?>{
      'sessionId': sessionId,
      'width': width,
      'height': height,
    });
  }

  @override
  Future<void> setViewportRect({
    required int sessionId,
    required int leftPx,
    required int topPx,
    required int rightPx,
    required int bottomPx,
    double cornerRadiusPx = 0.0,
    bool visible = true,
  }) async {
    if (sessionId <= 0) return;
    try {
      await _channel.invokeMethod<void>('setViewportRect', <String, Object?>{
        'sessionId': sessionId,
        'leftPx': leftPx,
        'topPx': topPx,
        'rightPx': rightPx,
        'bottomPx': bottomPx,
        'cornerRadiusPx': cornerRadiusPx,
        'visible': visible,
      });
    } on MissingPluginException catch (error) {
      developer.log(
        '跳过桌面视口同步',
        name: 'konata.windows_video_bridge',
        error: error,
      );
    } on PlatformException catch (error) {
      developer.log(
        '跳过瞬态桌面视口异常',
        name: 'konata.windows_video_bridge',
        error: error,
      );
    }
  }

  @override
  Future<NativeSessionMetrics?> getSessionMetrics(int sessionId) async {
    if (sessionId <= 0) return null;
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
        'getSessionMetrics',
        <String, Object?>{'sessionId': sessionId},
      );
      if (result == null) return null;
      return NativeSessionMetrics(
        renderedFrames: (result['renderedFrames'] as num?)?.toInt() ?? 0,
        renderP50Us: (result['renderP50Us'] as num?)?.toInt() ?? 0,
        renderP99Us: (result['renderP99Us'] as num?)?.toInt() ?? 0,
        renderAvgUs: (result['renderAvgUs'] as num?)?.toInt() ?? 0,
        backend: result['backend']?.toString() ?? '',
        surfaceFormat: result['surfaceFormat']?.toString() ?? '',
        colorBitDepth: (result['colorBitDepth'] as num?)?.toInt() ?? 8,
        underlaySwapChainActive: result['dcompActive'] == true,
      );
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<bool> setHdrFboEnabled({
    required int sessionId,
    required bool enabled,
  }) async {
    if (sessionId <= 0) return false;
    try {
      final applied = await _channel.invokeMethod<bool>(
        'setHdrFboEnabled',
        <String, Object?>{'sessionId': sessionId, 'enabled': enabled},
      );
      return applied == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> disposeSession(int sessionId) async {
    if (sessionId <= 0) return;
    try {
      await _channel.invokeMethod<void>('disposeSession', <String, Object?>{
        'sessionId': sessionId,
      });
    } on MissingPluginException {
      // 无原生桌面上下文时忽略会话释放。
    } on PlatformException {
      // 会话已销毁时忽略重复释放异常。
    }
  }

  @override
  Future<({bool available, String adapterName})> getAdapterInfo() async {
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
        'getAdapterInfo',
      );
      if (result == null) {
        return (available: false, adapterName: '');
      }
      return (
        available: result['available'] == true,
        adapterName: result['adapterName']?.toString() ?? '',
      );
    } on MissingPluginException {
      return (available: false, adapterName: '');
    } on PlatformException {
      return (available: false, adapterName: '');
    }
  }

  @override
  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    if (!_changesController.isClosed) {
      await _changesController.close();
    }
  }
}

/// Windows 桌面端窗口全屏、置顶与迷你窗口几何切换适配器（支持主窗口完整边界保存与恢复）。
final class WindowsPlaybackWindowAdapter
    implements PlaybackHostWindowPort, DesktopMiniDockPort {
  /// 创建桌面窗口播控适配器。
  WindowsPlaybackWindowAdapter();

  static const _dockChannel = MethodChannel('konata/desktop_mini');
  DesktopMiniDockSide? _dockSide;
  late final StreamController<void> _moveEnded =
      StreamController<void>.broadcast(
        onListen: () => _dockChannel.setMethodCallHandler((call) async {
          if (call.method == 'moveEnded' && _inMiniWindow) _moveEnded.add(null);
          return null;
        }),
        onCancel: () => _dockChannel.setMethodCallHandler(null),
      );

  @override
  Stream<void> get desktopMiniMoveEnded => _moveEnded.stream;

  @override
  Future<DesktopMiniDockSide?> snapDesktopMiniWindow() async {
    if (!_inMiniWindow) return null;
    final side = await _dockChannel.invokeMethod<String>('fit', 'snap');
    _dockSide = switch (side) {
      'left' => DesktopMiniDockSide.left,
      'right' => DesktopMiniDockSide.right,
      _ => null,
    };
    return _dockSide;
  }

  Future<void> _fitMiniWindow() =>
      _dockChannel.invokeMethod<void>('fit', _dockSide?.name ?? 'clamp');
  ui.Rect? _savedNormalBounds;
  ui.Offset? _lastMiniWindowOrigin;
  bool _savedNormalMaximized = false;
  bool _savedNormalFullScreen = false;
  bool _savedNormalAlwaysOnTop = false;
  bool _inMiniWindow = false;

  wm.Window? _currentWindow() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) {
      return null;
    }
    try {
      return wm.WindowManager.instance.getCurrent();
    } catch (_) {
      return null;
    }
  }

  Future<void> _ensureNativeControlsHidden() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return;
    try {
      await Window.hideWindowControls();
    } catch (_) {
      // 窗口未就绪时忽略隐藏标题栏控制键异常。
    }
  }

  @override
  Future<bool> isFullScreen() async {
    final win = _currentWindow();
    if (win == null) return false;
    try {
      return win.isFullScreen;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> setFullScreen(bool enable) async {
    final win = _currentWindow();
    if (win == null) return;
    try {
      win.isFullScreen = enable;
      await _ensureNativeControlsHidden();
    } catch (_) {
      // 窗口未就绪时忽略全屏切换异常。
    }
  }

  @override
  Future<void> setAlwaysOnTop(bool enable) async {
    final win = _currentWindow();
    if (win == null) return;
    try {
      win.isAlwaysOnTop = enable;
    } catch (_) {
      // 忽略置顶状态切换异常。
    }
  }

  @override
  Future<void> enterDesktopMiniWindow({
    required double width,
    required double height,
  }) async {
    final win = _currentWindow();
    if (win == null) throw StateError('桌面窗口不可用');
    if (_inMiniWindow) {
      final previous = win.bounds.toRect();
      final previousMinSize = win.minimumSize;
      final targetSize = ui.Size(width, height);
      try {
        win.minimumSize = wm.SizeToNative(targetSize).toNative();
        win.setSize(wm.SizeToNative(targetSize).toNative(), false);
        // 保持小窗右边缘稳定，展开时避免向原有右侧继续增长。
        win.position = wm.OffsetToNative(
          ui.Offset(
            _dockSide == DesktopMiniDockSide.left
                ? previous.left
                : previous.right - width,
            previous.top,
          ),
        ).toNative();
        await _fitMiniWindow();
      } catch (error, stack) {
        win.minimumSize = previousMinSize;
        win.bounds = wm.RectToNative(previous).toNative();
        Error.throwWithStackTrace(error, stack);
      }
      return;
    }
    _savedNormalFullScreen = win.isFullScreen;
    _savedNormalMaximized = win.isMaximized;
    _savedNormalAlwaysOnTop = win.isAlwaysOnTop;
    _savedNormalBounds = win.bounds.toRect();
    try {
      if (_savedNormalFullScreen) win.isFullScreen = false;
      if (_savedNormalMaximized) win.unmaximize();
      final normalBounds = win.bounds.toRect();
      _savedNormalBounds =
          normalBounds.width >= 600 && normalBounds.height >= 400
          ? normalBounds
          : KonataPlaybackTokens.desktopNormalWindowFallbackBounds;
      final targetSize = ui.Size(width, height);
      final minSize =
          height < KonataPlaybackTokens.desktopAlwaysOnTopVideoMinSize.height
          ? targetSize
          : (width - height).abs() <= 24.0
          ? KonataPlaybackTokens.desktopAlwaysOnTopAudioMinSize
          : KonataPlaybackTokens.desktopAlwaysOnTopVideoMinSize;
      win.minimumSize = wm.SizeToNative(minSize).toNative();
      win.setSize(wm.SizeToNative(targetSize).toNative(), false);
      final saved = _savedNormalBounds!;
      final desiredOrigin =
          _lastMiniWindowOrigin ??
          ui.Offset(
            (saved.right -
                targetSize.width -
                KonataPlaybackTokens.desktopAlwaysOnTopMiniEdgeOffset),
            (saved.bottom -
                targetSize.height -
                KonataPlaybackTokens.desktopAlwaysOnTopMiniEdgeOffset),
          );
      win.position = wm.OffsetToNative(desiredOrigin).toNative();
      win.isAlwaysOnTop = true;
      await _fitMiniWindow();
      await _ensureNativeControlsHidden();
      _inMiniWindow = true;
    } catch (error, stack) {
      // 切换失败时恢复此前窗口属性；保留原始异常供调用方回滚界面状态。
      try {
        _restoreNormalWindow(win);
        _clearSavedNormalWindow();
      } catch (rollbackError, rollbackStack) {
        developer.log(
          '小窗进入失败且窗口回滚失败',
          name: 'konata.windows_playback_window',
          error: rollbackError,
          stackTrace: rollbackStack,
        );
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  void _restoreNormalWindow(wm.Window win) {
    win.isAlwaysOnTop = _savedNormalAlwaysOnTop;
    win.minimumSize = wm.SizeToNative(
      KonataPlaybackTokens.desktopNormalWindowMinSize,
    ).toNative();
    win.bounds = wm.RectToNative(
      _savedNormalBounds ??
          KonataPlaybackTokens.desktopNormalWindowFallbackBounds,
    ).toNative();
    if (_savedNormalMaximized) win.maximize();
    if (_savedNormalFullScreen) win.isFullScreen = true;
  }

  void _clearSavedNormalWindow() {
    _inMiniWindow = false;
    _dockSide = null;
    _savedNormalBounds = null;
    _savedNormalMaximized = false;
    _savedNormalFullScreen = false;
    _savedNormalAlwaysOnTop = false;
  }

  @override
  Future<void> exitDesktopMiniWindow() async {
    if (!_inMiniWindow) return;
    final win = _currentWindow();
    if (win == null) throw StateError('桌面窗口不可用');
    final miniBounds = win.bounds.toRect();
    final miniMinSize = win.minimumSize;
    try {
      _restoreNormalWindow(win);
      await _ensureNativeControlsHidden();
      _lastMiniWindowOrigin = miniBounds.topLeft;
      _clearSavedNormalWindow();
    } catch (error, stack) {
      // 恢复主窗口失败时保留原快照和小窗形态，以便再次尝试。
      try {
        if (win.isFullScreen) win.isFullScreen = false;
        if (win.isMaximized) win.unmaximize();
        win.minimumSize = miniMinSize;
        win.bounds = wm.RectToNative(miniBounds).toNative();
        win.isAlwaysOnTop = true;
      } catch (rollbackError, rollbackStack) {
        developer.log(
          '主窗口恢复失败且小窗回滚失败',
          name: 'konata.windows_playback_window',
          error: rollbackError,
          stackTrace: rollbackStack,
        );
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  @override
  Future<void> setKeepScreenOn(bool enable) async {
    // 桌面端由原生播放引擎自行维护防休眠请求。
  }

  @override
  Future<void> setPreferredLandscape(bool landscape) async {
    // 桌面端无需屏幕旋转锁定。
  }
}

/// 构造 Windows 桌面专属外部播放器 SQLite 持久化配置仓储（隔离于 Android 裁剪入口之外）。
DesktopExternalPlayerStore createWindowsExternalPlayerStore(
  KonataDatabaseBundle databases,
) {
  return SqliteDesktopExternalPlayerStore(databases.userState.engine);
}

/// 构造 Windows 桌面专属外部播放器接力网关（支持 MPV IPC / PotPlayer Win32 / Foobar Beefweb）。
DesktopRelayGateway createWindowsDesktopRelayGateway({
  required DesktopExternalPlayerStore store,
  required LocalStreamBridgePort streamBridge,
  required MediaSourceGatewayFactoryPort gatewayFactory,
  required StorageRootPort storageRoot,
}) {
  return WindowsDesktopRelayGateway(
    store: store,
    launcher: RealExternalPlayerLauncher(
      streamBridge: streamBridge,
      gatewayFactory: gatewayFactory,
      storageRoot: storageRoot,
    ),
  );
}

/// 构造 Windows 桌面专属 `libmpv` 渲染与 WASAPI 独占音频参数策略委托。
MpvPlatformProfileDelegate createWindowsMpvProfileDelegate() {
  return const WindowsMpvProfileDelegate();
}

/// Windows 桌面专属传统代码页字幕字节解码回调（支持 Shift-JIS / GB18030 / Big5）。
LegacyCodePageDecoder get windowsLegacyCodePageDecoder =>
    WindowsCodePageDecoder.decode;
