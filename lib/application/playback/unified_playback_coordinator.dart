import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/playback/video_aspect_mode.dart';
import '../providers/platform_capability.dart';
import 'audio_playback_notifier.dart';
import 'playback_preferences_provider.dart';
import 'video_playback_controller.dart';

/// 统一音视频活跃媒体类型。
enum UnifiedMediaKind {
  /// 无活跃媒体。
  none,

  /// 纯音频 / CD 音乐会话。
  audio,

  /// 内置视频（含小窗预览与视频切后台纯音频）会话。
  video,
}

/// 音视频共享统一播控状态快照（由常驻播放胶囊与全屏 HUD 同源消费，避免重复控制逻辑）。
@immutable
class UnifiedPlaybackControlSnapshot {
  /// 创建统一播控状态快照。
  const UnifiedPlaybackControlSnapshot({
    this.kind = UnifiedMediaKind.none,
    this.title = '',
    this.subtitle = '',
    this.isPlaying = false,
    this.canPrevious = false,
    this.canNext = false,
    this.isAudioOnlyVideo = false,
    this.cover = const EmptyAudioCover(),
  });

  /// 当前活跃媒体类型。
  final UnifiedMediaKind kind;

  /// 主标题（曲名或分集标题）。
  final String title;

  /// 副标题（作品标题或专辑名称）。
  final String subtitle;

  /// 是否正在播放。
  final bool isPlaying;

  /// 是否可切换上一项。
  final bool canPrevious;

  /// 是否可切换下一项。
  final bool canNext;

  /// 视频会话当前是否处于后台纯音频（`vid=no`）模式。
  final bool isAudioOnlyVideo;

  /// 封面图像数据源。
  final AudioCoverSource cover;

  /// 当前是否存在可展示的活跃媒体。
  bool get isActive => kind != UnifiedMediaKind.none;
}

/// Android 播放窗口与音频焦点原生通道封装。
class AndroidPlaybackWindowBridge {
  const AndroidPlaybackWindowBridge._();

  static const MethodChannel _windowChannel = MethodChannel(
    'ccplayer/playback_window',
  );
  static const MethodChannel _audioFocusChannel = MethodChannel(
    'ccplayer/audio_focus',
  );

  static VoidCallback? _onAudioFocusLoss;
  static bool _focusHandlerBound = false;

  /// 绑定音频焦点丢失回调并在 Android 端请求播放音频焦点。
  static Future<void> requestAudioFocus({VoidCallback? onLoss}) async {
    if (!KonataPlatform.isAndroid) return;
    _onAudioFocusLoss = onLoss;
    if (!_focusHandlerBound) {
      _focusHandlerBound = true;
      _audioFocusChannel.setMethodCallHandler((call) async {
        if (call.method == 'loss') {
          _onAudioFocusLoss?.call();
        }
        return null;
      });
    }
    try {
      await _audioFocusChannel.invokeMethod<bool>('request');
    } catch (_) {}
  }

  /// 释放 Android 音频焦点。
  static Future<void> abandonAudioFocus() async {
    _onAudioFocusLoss = null;
    if (!KonataPlatform.isAndroid) return;
    try {
      await _audioFocusChannel.invokeMethod<void>('abandon');
    } catch (_) {}
  }

  /// 开启 Android 播放传感器旋转支持。
  static Future<void> beginWindow() async {
    if (!KonataPlatform.isAndroid) return;
    try {
      await _windowChannel.invokeMethod<void>('begin');
    } catch (_) {}
  }

  /// 退出 Android 播放窗口系统栏隐藏与方向覆写。
  static Future<void> endWindow() async {
    if (!KonataPlatform.isAndroid) return;
    try {
      await _windowChannel.invokeMethod<void>('setBrightness', -1.0);
    } catch (_) {}
    try {
      await _windowChannel.invokeMethod<void>('end');
    } catch (_) {}
  }

  /// 切换系统状态栏与导航手势栏沉浸式隐藏。
  static Future<void> setSystemBarsHidden(bool hidden) async {
    if (!KonataPlatform.isAndroid) return;
    try {
      await _windowChannel.invokeMethod<void>('fullscreen', hidden);
    } catch (_) {}
  }

  /// 切换一键横屏或恢复传感器自由方向。
  static Future<void> setLandscapePreferred(bool landscape) async {
    if (!KonataPlatform.isAndroid) return;
    try {
      await _windowChannel.invokeMethod<void>('setLandscape', landscape);
    } catch (_) {}
  }

  /// 锁定或解锁当前物理屏幕方向。
  static Future<void> setOrientationLocked(bool locked) async {
    if (!KonataPlatform.isAndroid) return;
    try {
      await _windowChannel.invokeMethod<bool>('orientationLocked', locked);
    } catch (_) {}
  }

  /// 设置当前播放窗口亮度（`0.0 ~ 1.0`，负数恢复系统亮度）。
  static Future<void> setBrightness(double brightness) async {
    if (!KonataPlatform.isAndroid) return;
    try {
      await _windowChannel.invokeMethod<void>('setBrightness', brightness);
    } catch (_) {}
  }
}

/// Android 原生画中画（PiP）参数快照。
@immutable
class AndroidPipSyncPayload {
  /// 创建画中画同步载荷。
  const AndroidPipSyncPayload({
    required this.eligible,
    required this.isPlaying,
    required this.canPrevious,
    required this.canNext,
    required this.aspectNumerator,
    required this.aspectDenominator,
    this.sourceRect,
  });

  /// 当前是否允许切入后台时自动触发画中画。
  final bool eligible;

  /// 当前是否处于播放中。
  final bool isPlaying;

  /// 是否启用上一集动作。
  final bool canPrevious;

  /// 是否启用下一集动作。
  final bool canNext;

  /// 钳制在 `0.42 ~ 2.39` 后的宽高比分子。
  final int aspectNumerator;

  /// 钳制在 `0.42 ~ 2.39` 后的宽高比分母。
  final int aspectDenominator;

  /// 视频渲染区域在窗口中的物理/逻辑源矩形提示（`left, top, right, bottom`）。
  final ({int left, int top, int right, int bottom})? sourceRect;

  /// 序列化为平台通道参数映射。
  Map<String, Object?> toChannelMap() {
    return <String, Object?>{
      'eligible': eligible,
      'isPlaying': isPlaying,
      'canPrevious': canPrevious,
      'canNext': canNext,
      'aspectNumerator': aspectNumerator,
      'aspectDenominator': aspectDenominator,
      if (sourceRect != null) ...{
        'left': sourceRect!.left,
        'top': sourceRect!.top,
        'right': sourceRect!.right,
        'bottom': sourceRect!.bottom,
      },
    };
  }

  @override
  bool operator ==(Object other) {
    return other is AndroidPipSyncPayload &&
        other.eligible == eligible &&
        other.isPlaying == isPlaying &&
        other.canPrevious == canPrevious &&
        other.canNext == canNext &&
        other.aspectNumerator == aspectNumerator &&
        other.aspectDenominator == aspectDenominator &&
        other.sourceRect == sourceRect;
  }

  @override
  int get hashCode => Object.hash(
    eligible,
    isPlaying,
    canPrevious,
    canNext,
    aspectNumerator,
    aspectDenominator,
    sourceRect,
  );
}

/// Android 原生画中画平台通道客户端。
class AndroidPipChannelClient {
  /// 创建画中画通道客户端。
  AndroidPipChannelClient({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('ccplayer/pip');

  final MethodChannel _channel;
  AndroidPipSyncPayload? _lastSentPayload;

  /// 最近一次发送至原生端的画中画参数快照（便于测试断言）。
  AndroidPipSyncPayload? get lastSentPayload => _lastSentPayload;

  /// 绑定来自原生 Activity 的画中画生命周期与播控回调。
  void bindCallbacks({
    required ValueChanged<bool> onPipModeChanged,
    required ValueChanged<String> onRemoteAction,
  }) {
    try {
      ServicesBinding.instance;
      _channel.setMethodCallHandler((call) async {
        switch (call.method) {
          case 'pipChanged':
            final active = call.arguments == true;
            onPipModeChanged(active);
          case 'action':
            final action = call.arguments?.toString() ?? '';
            if (action.isNotEmpty) {
              onRemoteAction(action);
            }
        }
        return null;
      });
    } catch (_) {}
  }

  /// 解绑通道监听。
  void unbindCallbacks() {
    try {
      ServicesBinding.instance;
      _channel.setMethodCallHandler(null);
    } catch (_) {}
  }

  /// 实时向原生 Activity 同步自动进入开关、宽高比、源矩形与控制按钮状态。
  Future<void> syncState(AndroidPipSyncPayload payload) async {
    if (_lastSentPayload == payload) return;
    _lastSentPayload = payload;
    if (!KonataPlatform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('syncState', payload.toChannelMap());
    } catch (_) {}
  }

  /// 主动请求立即进入系统画中画小窗。
  Future<bool> enterPipNow() async {
    if (!KonataPlatform.isAndroid) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('enter');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }
}

/// Android 画中画通道客户端 Provider（可在测试中覆写验证）。
final androidPipChannelClientProvider = Provider<AndroidPipChannelClient>((
  ref,
) {
  final client = AndroidPipChannelClient();
  ref.onDispose(client.unbindCallbacks);
  return client;
});

/// 全局保活视频会话宿主状态（支持全屏与底部迷你圆角预览无缝切换，绝不重建解码会话）。
@immutable
class ActiveVideoSessionState {
  /// 创建活跃视频会话宿主状态。
  const ActiveVideoSessionState({
    this.request,
    this.isExpanded = false,
    this.isInPipMode = false,
    this.sourceRect,
  });

  /// 当前保活视频启动请求（`null` 表示无活跃视频会话）。
  final VideoLaunchRequest? request;

  /// 当前是否展开为全屏视频播放器（`false` 表示已收起至常驻播放胶囊圆角预览）。
  final bool isExpanded;

  /// 当前是否处于 Android 系统画中画小窗纯净模式。
  final bool isInPipMode;

  /// 最近一次测量的视频舞台屏幕矩形（供 Android 12+ PiP 丝滑过渡使用）。
  final ({int left, int top, int right, int bottom})? sourceRect;

  /// 是否存在活跃视频会话。
  bool get isActive => request != null;

  /// 当前是否收起在底部迷你播放胶囊中展示。
  bool get isMinimized => request != null && !isExpanded && !isInPipMode;

  ActiveVideoSessionState copyWith({
    VideoLaunchRequest? request,
    bool clearRequest = false,
    bool? isExpanded,
    bool? isInPipMode,
    ({int left, int top, int right, int bottom})? sourceRect,
    bool clearSourceRect = false,
  }) {
    return ActiveVideoSessionState(
      request: clearRequest ? null : (request ?? this.request),
      isExpanded: isExpanded ?? this.isExpanded,
      isInPipMode: isInPipMode ?? this.isInPipMode,
      sourceRect: clearSourceRect ? null : (sourceRect ?? this.sourceRect),
    );
  }
}

/// 全局视频会话与原生画中画生命周期编排器。
class ActiveVideoSessionNotifier extends StateNotifier<ActiveVideoSessionState> {
  /// 创建全局视频会话编排器。
  ActiveVideoSessionNotifier(this._ref)
    : super(const ActiveVideoSessionState()) {
    final pipClient = _ref.read(androidPipChannelClientProvider);
    pipClient.bindCallbacks(
      onPipModeChanged: _handleNativePipModeChanged,
      onRemoteAction: _handleNativePipRemoteAction,
    );
  }

  final Ref _ref;

  /// 启动或热切换全局视频会话并展开全屏舞台。
  Future<void> openVideo(VideoLaunchRequest nextRequest) async {
    // 互斥收起全屏音频页并暂停纯音频会话
    _ref.read(immersiveAudioExpandedProvider.notifier).state = false;
    await _ref.read(audioPlaybackProvider.notifier).pauseForVideoSession();

    final currentReq = state.request;
    if (currentReq != null) {
      if (currentReq == nextRequest) {
        state = state.copyWith(isExpanded: true);
        _ref.read(videoPlaybackActiveProvider.notifier).state = true;
        return;
      }
      // 同一作品或同一系列内的换集：直接复用现有底层解码器会话热切换，避免销毁重建！
      final currentCtrl = _ref.read(videoPlaybackProvider(currentReq).notifier);
      final currentState = _ref.read(videoPlaybackProvider(currentReq));
      if (!currentState.isClosing &&
          currentState.errorMessage == null &&
          currentCtrl.activeWork.id == nextRequest.work.id) {
        state = state.copyWith(isExpanded: true);
        _ref.read(videoPlaybackActiveProvider.notifier).state = true;
        await currentCtrl.switchToEpisode(
          nextRequest.episode,
          targetBundle: nextRequest.bundle,
          specificVariant: nextRequest.variant,
          startSeconds: nextRequest.startSeconds,
        );
        return;
      }
      await currentCtrl.closeAndRelease();
    }

    state = ActiveVideoSessionState(
      request: nextRequest,
      isExpanded: true,
      isInPipMode: false,
    );
    _ref.read(videoPlaybackActiveProvider.notifier).state = true;
  }

  /// 将当前视频从全屏收起至常驻播放胶囊圆角预览（保持解码器与播放状态不断流）。
  Future<void> collapseToMini() async {
    if (state.request == null) return;
    state = state.copyWith(isExpanded: false, isInPipMode: false);
    _ref.read(videoPlaybackActiveProvider.notifier).state = false;
    unawaited(AndroidPlaybackWindowBridge.setSystemBarsHidden(false));
    unawaited(AndroidPlaybackWindowBridge.setLandscapePreferred(false));
  }

  /// 从常驻播放胶囊重新平滑展开至全屏视频舞台（零重建解码会话）。
  void expandToFull() {
    if (state.request == null) return;
    _ref.read(immersiveAudioExpandedProvider.notifier).state = false;
    state = state.copyWith(isExpanded: true);
    _ref.read(videoPlaybackActiveProvider.notifier).state = true;
  }

  /// 更新视频舞台在屏幕中的源矩形提示。
  void updateSourceRect(({int left, int top, int right, int bottom})? rect) {
    if (state.sourceRect == rect) return;
    state = state.copyWith(
      sourceRect: rect,
      clearSourceRect: rect == null,
    );
  }

  /// 彻底停止并释放当前视频会话。
  Future<void> closeVideo() async {
    final req = state.request;
    state = const ActiveVideoSessionState();
    _ref.read(videoPlaybackActiveProvider.notifier).state = false;
    unawaited(
      _ref
          .read(androidPipChannelClientProvider)
          .syncState(
            const AndroidPipSyncPayload(
              eligible: false,
              isPlaying: false,
              canPrevious: false,
              canNext: false,
              aspectNumerator: 16,
              aspectDenominator: 9,
            ),
          ),
    );
    if (req != null) {
      await _ref.read(videoPlaybackProvider(req).notifier).closeAndRelease();
    }
  }

  /// 主动请求进入 Android 系统画中画。
  Future<bool> enterPipManually() async {
    final req = state.request;
    if (req == null) return false;
    final vidState = _ref.read(videoPlaybackProvider(req));
    if (vidState.audioOnlyMode) {
      _ref
          .read(videoPlaybackProvider(req).notifier)
          .setAudioOnlyMode(false);
    }
    return _ref.read(androidPipChannelClientProvider).enterPipNow();
  }

  void _handleNativePipModeChanged(bool inPip) {
    if (!mounted) return;
    if (state.request == null) {
      state = state.copyWith(isInPipMode: false);
      return;
    }
    if (inPip) {
      state = state.copyWith(isInPipMode: true, isExpanded: true);
      _ref.read(videoPlaybackActiveProvider.notifier).state = true;
    } else {
      state = state.copyWith(isInPipMode: false);
    }
  }

  void _handleNativePipRemoteAction(String action) {
    final req = state.request;
    if (!mounted || req == null) return;
    final ctrl = _ref.read(videoPlaybackProvider(req).notifier);
    switch (action) {
      case 'togglePlayPause':
        ctrl.togglePlayPause();
      case 'previous':
        unawaited(ctrl.goToPreviousEpisode());
      case 'next':
        unawaited(ctrl.goToNextEpisode());
    }
  }

  /// 测试辅助：直接模拟原生画中画状态切换。
  @visibleForTesting
  void debugSetPipMode(bool inPip) => _handleNativePipModeChanged(inPip);

  /// 测试辅助：直接模拟原生画中画远程动作。
  @visibleForTesting
  void debugTriggerRemoteAction(String action) =>
      _handleNativePipRemoteAction(action);
}

/// 全局保活视频会话 Provider。
final activeVideoSessionProvider =
    StateNotifierProvider<ActiveVideoSessionNotifier, ActiveVideoSessionState>(
      (ref) => ActiveVideoSessionNotifier(ref),
    );

/// 计算并实时同步 Android 原生画中画参数（仅订阅低频播放态、尺寸与设置开关，绝不订阅 `positionSeconds`）。
final androidPipAutoSyncProvider = Provider<AndroidPipSyncPayload>((ref) {
  final session = ref.watch(activeVideoSessionProvider);
  final autoEnterPref = ref.watch(
    playbackPreferencesProvider.select((p) => p.autoEnterPip),
  );
  final req = session.request;

  AndroidPipSyncPayload payload;
  if (req == null) {
    payload = const AndroidPipSyncPayload(
      eligible: false,
      isPlaying: false,
      canPrevious: false,
      canNext: false,
      aspectNumerator: 16,
      aspectDenominator: 9,
    );
  } else {
    final snap = ref.watch(
      videoPlaybackProvider(req).select(
        (s) => (
          isPlaying: s.isPlaying,
          audioOnly: s.audioOnlyMode,
          isClosing: s.isClosing,
          hasError: s.errorMessage != null,
          videoWidth: s.probeStats.videoWidth,
          videoHeight: s.probeStats.videoHeight,
          episodeId: s.currentEpisode.id,
        ),
      ),
    );
    final ctrl = ref.read(videoPlaybackProvider(req).notifier);
    final aspect = PipAspectRatioPolicy.clampRational(
      snap.videoWidth ?? 0,
      snap.videoHeight ?? 0,
    );
    final eligible =
        KonataPlatform.isAndroid &&
        autoEnterPref &&
        snap.isPlaying &&
        !snap.audioOnly &&
        !snap.isClosing &&
        !snap.hasError;
    payload = AndroidPipSyncPayload(
      eligible: eligible,
      isPlaying: snap.isPlaying,
      canPrevious: ctrl.hasPreviousEpisodeAny,
      canNext: ctrl.hasNextEpisodeAny,
      aspectNumerator: aspect.numerator,
      aspectDenominator: aspect.denominator,
      sourceRect: session.sourceRect,
    );
  }

  unawaited(ref.read(androidPipChannelClientProvider).syncState(payload));
  return payload;
});

/// 音视频共享统一控制快照 Provider（不订阅 `positionSeconds`，仅低频控制状态变更时刷新）。
final unifiedPlaybackControlProvider = Provider<UnifiedPlaybackControlSnapshot>(
  (ref) {
    final videoSession = ref.watch(activeVideoSessionProvider);
    final videoReq = videoSession.request;
    if (videoReq != null) {
      final vSnap = ref.watch(
        videoPlaybackProvider(videoReq).select(
          (s) => (
            isPlaying: s.isPlaying,
            audioOnly: s.audioOnlyMode,
            work: s.currentWork,
            episode: s.currentEpisode,
          ),
        ),
      );
      final ctrl = ref.read(videoPlaybackProvider(videoReq).notifier);
      final work = vSnap.work ?? videoReq.work;
      final posterUrl =
          work.posterPath ?? work.bangumiPosterPath ?? work.posterFallback;
      final cover = (posterUrl != null && posterUrl.isNotEmpty)
          ? ManagedPosterAudioCover(url: posterUrl, workId: work.id)
          : const EmptyAudioCover();
      return UnifiedPlaybackControlSnapshot(
        kind: UnifiedMediaKind.video,
        title: ctrl.currentEpisodeTitle,
        subtitle: work.title,
        isPlaying: vSnap.isPlaying,
        canPrevious: ctrl.hasPreviousEpisodeAny,
        canNext: ctrl.hasNextEpisodeAny,
        isAudioOnlyVideo: vSnap.audioOnly,
        cover: cover,
      );
    }

    final aSnap = ref.watch(
      audioPlaybackProvider.select(
        (s) => (
          isActive: s.isActive,
          isPlaying: s.isPlaying,
          item: s.currentItem,
          cover: s.cover,
          queueLen: s.queue.length,
        ),
      ),
    );
    if (aSnap.isActive && aSnap.item != null) {
      return UnifiedPlaybackControlSnapshot(
        kind: UnifiedMediaKind.audio,
        title: aSnap.item!.title,
        subtitle: aSnap.item!.work.title,
        isPlaying: aSnap.isPlaying,
        canPrevious: aSnap.queueLen > 0,
        canNext: aSnap.queueLen > 0,
        cover: aSnap.cover,
      );
    }

    return const UnifiedPlaybackControlSnapshot();
  },
);
