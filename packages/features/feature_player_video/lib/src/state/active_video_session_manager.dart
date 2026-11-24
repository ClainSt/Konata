import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/video_session_models.dart';
import 'video_playback_controller.dart';

/// 构建独立视频播放控制器的工厂回调（由外层薄胶水注入具体依赖）。
typedef VideoPlaybackControllerFactory = VideoPlaybackController Function();

/// 全局跨路由活跃视频会话总管（零 Riverpod 纯状态管理器）。
///
/// 负责将当前活跃的 [VideoPlaybackController] 提升出路由局部生命周期，
/// 保证用户收拢至跨页 16:9 悬浮视频小窗或从小窗回弹全屏舞台时绝不重建底层解码会话。
class ActiveVideoSessionManager extends ChangeNotifier {
  /// 创建全局活跃视频会话总管。
  ActiveVideoSessionManager({required this._controllerFactory});

  final VideoPlaybackControllerFactory _controllerFactory;

  VideoLaunchRequest? _activeRequest;
  VideoPlaybackController? _controller;
  bool _stageExpanded = false;
  bool _disposed = false;

  /// 当前活跃视频起播请求（无活跃会话时为 `null`）。
  VideoLaunchRequest? get activeRequest => _activeRequest;

  /// 当前跨页保活的视频播放控制器实例。
  VideoPlaybackController? get controller => _controller;

  /// 当前全屏视频舞台是否正处于前台展开态。
  bool get isStageExpanded => _stageExpanded;

  /// 当前是否存在已激活的跨页视频会话。
  bool get hasActiveSession => _controller != null && _activeRequest != null;

  /// 当前是否应于应用根层展示跨页可拖拽 16:9 悬浮视频小窗。
  bool get shouldShowFloatingMiniPlayer =>
      _controller != null && !_stageExpanded && _controller!.state.isMiniPlayer;

  /// 启动新的视频播放会话，或对同作品同分集同版本的既有会话原地回弹复用（零重新解码）。
  VideoPlaybackController openOrReuseSession(VideoLaunchRequest request) {
    final existing = _controller;
    final currentReq = _activeRequest;
    final isSameTarget =
        existing != null &&
        currentReq != null &&
        currentReq.workId == request.workId &&
        (request.episodeId == null ||
            existing.state.currentEpisode.id == request.episodeId ||
            currentReq.episodeId == request.episodeId) &&
        (request.variantId == null ||
            existing.state.currentVariant.id == request.variantId ||
            currentReq.variantId == request.variantId);

    if (isSameTarget) {
      _stageExpanded = true;
      if (existing.state.isMiniPlayer) {
        unawaited(existing.exitMiniPlayerToStage());
      }
      _safeNotify();
      return existing;
    }

    if (existing != null) {
      existing.removeListener(_onControllerChanged);
      unawaited(_disposeOldController(existing));
    }

    final created = _controllerFactory();
    created.addListener(_onControllerChanged);
    _controller = created;
    _activeRequest = request;
    _stageExpanded = true;
    unawaited(created.initialize(request));
    _safeNotify();
    return created;
  }

  /// 将既有活跃视频会话切入跨页 16:9 悬浮小窗态（保持解码会话存活，仅通知全屏路由收起）。
  Future<void> collapseToFloatingMini() async {
    final ctrl = _controller;
    if (ctrl == null) return;
    _stageExpanded = false;
    await ctrl.enterMiniPlayer(desktopAlwaysOnTop: false);
    _safeNotify();
  }

  /// 从跨页悬浮小窗回弹展开至全屏视频舞台（零重新解码）。
  Future<void> expandFromFloatingMini() async {
    final ctrl = _controller;
    if (ctrl == null) return;
    _stageExpanded = true;
    await ctrl.exitMiniPlayerToStage();
    _safeNotify();
  }

  /// 标记全屏视频舞台路由已退场；若未进入悬浮小窗态则同步安全销毁会话。
  void handleStageRoutePopped() {
    final ctrl = _controller;
    if (ctrl == null) {
      _stageExpanded = false;
      _safeNotify();
      return;
    }
    _stageExpanded = false;
    if (!ctrl.state.isMiniPlayer) {
      unawaited(closeActiveSession());
    } else {
      _safeNotify();
    }
  }

  /// 彻底关闭当前活跃视频会话并释放全部原生解码资源。
  Future<void> closeActiveSession() async {
    final ctrl = _controller;
    _controller = null;
    _activeRequest = null;
    _stageExpanded = false;
    _safeNotify();
    if (ctrl != null) {
      ctrl.removeListener(_onControllerChanged);
      await _disposeOldController(ctrl);
    }
  }

  Future<void> _disposeOldController(VideoPlaybackController ctrl) async {
    try {
      await ctrl.closeSession();
    } finally {
      ctrl.dispose();
    }
  }

  void _onControllerChanged() {
    _safeNotify();
  }

  void _safeNotify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    final ctrl = _controller;
    _controller = null;
    _activeRequest = null;
    _stageExpanded = false;
    if (ctrl != null) {
      ctrl.removeListener(_onControllerChanged);
      unawaited(_disposeOldController(ctrl));
    }
    super.dispose();
  }
}
