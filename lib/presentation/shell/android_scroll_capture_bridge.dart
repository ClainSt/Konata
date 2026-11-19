import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_theme.dart';

/// 声明顶部/底部悬浮遮挡（如浮窗胶囊导航与迷你播控条），用于收窄长截屏采样窗口以免切片重复出现浮层。
class ScrollCaptureExclusionInsets extends InheritedWidget {
  /// 创建长截屏悬浮避让作用域。
  const ScrollCaptureExclusionInsets({
    super.key,
    required this.bottomInset,
    required super.child,
  });

  /// 当前视图底部悬浮避让高度（逻辑像素）。
  final double bottomInset;

  /// 读取最近的避让值（默认 0，无订阅副作用，可在帧末回调内安全调用）。
  static double bottomOf(BuildContext context) {
    return context
            .getInheritedWidgetOfExactType<ScrollCaptureExclusionInsets>()
            ?.bottomInset ??
        0.0;
  }

  @override
  bool updateShouldNotify(ScrollCaptureExclusionInsets oldWidget) =>
      oldWidget.bottomInset != bottomInset;
}

class _CandidateScrollable {
  const _CandidateScrollable({
    required this.state,
    required this.visibleRect,
    required this.area,
  });

  final ScrollableState state;
  final Rect visibleRect;
  final double area;
}

/// Android 12+（API 31+）系统原生滚动长截屏桥接容器。
///
/// 监听当前最前层路由内可见竖向可滚动组件并将物理边界同步给原生宿主；
/// 当系统发起长截屏切片请求时，精确驱动滚动偏移并在渲染帧落盘后回传实际消费区间。
class AndroidScrollCaptureScope extends StatefulWidget {
  /// 创建 Android 长截屏桥接包裹容器。
  const AndroidScrollCaptureScope({
    super.key,
    required this.navigatorKey,
    required this.child,
  });

  /// 根导航键，用于精准定位当前最顶层路由内容。
  final GlobalKey<NavigatorState> navigatorKey;

  /// 子界面树。
  final Widget child;

  @override
  State<AndroidScrollCaptureScope> createState() =>
      _AndroidScrollCaptureScopeState();
}

class _AndroidScrollCaptureScopeState extends State<AndroidScrollCaptureScope>
    with WidgetsBindingObserver {
  static const MethodChannel _channel = MethodChannel('ccplayer/scroll_capture');

  Timer? _syncDebounceTimer;
  bool _syncScheduled = false;
  Rect? _lastSyncedPhysicalBounds;
  double? _lastSyncedDpr;

  ScrollableState? _capturedScrollable;
  Rect _capturedLogicalRect = Rect.zero;
  double _capturedInitialPixels = 0.0;
  double _capturedDpr = 1.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (KonataAdaptiveTokens.isAndroid) {
      _channel.setMethodCallHandler(_handleMethodCall);
      _scheduleSyncMetrics();
    }
  }

  @override
  void didUpdateWidget(covariant AndroidScrollCaptureScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (KonataAdaptiveTokens.isAndroid &&
        oldWidget.navigatorKey != widget.navigatorKey) {
      _scheduleSyncMetrics();
    }
  }

  @override
  void didChangeMetrics() {
    if (KonataAdaptiveTokens.isAndroid) {
      _scheduleSyncMetrics();
    }
  }

  @override
  void dispose() {
    _syncDebounceTimer?.cancel();
    _syncDebounceTimer = null;
    WidgetsBinding.instance.removeObserver(this);
    if (KonataAdaptiveTokens.isAndroid) {
      _channel.setMethodCallHandler(null);
    }
    super.dispose();
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    if (!mounted) return null;
    switch (call.method) {
      case 'beginCapture':
        return _beginCapture();
      case 'scrollToCaptureArea':
        final args = call.arguments as Map<Object?, Object?>?;
        final requestedTopPx =
            (args?['requestedTopPx'] as num?)?.toDouble() ?? 0.0;
        return _scrollToCaptureArea(requestedTopPx);
      case 'endCapture':
        return _endCapture();
      default:
        throw MissingPluginException('未知长截屏指令: ${call.method}');
    }
  }

  void _scheduleSyncMetrics() {
    if (!mounted) return;
    _syncDebounceTimer?.cancel();
    _syncDebounceTimer = Timer(KonataTheme.scrollCaptureMetricsDebounce, () {
      if (!mounted || _syncScheduled) return;
      _syncScheduled = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _syncScheduled = false;
        if (!mounted) return;
        _syncMetricsNow();
      });
    });
  }

  void _syncMetricsNow() {
    if (!KonataAdaptiveTokens.isAndroid || !mounted) return;
    final view = View.of(context);
    final dpr = view.devicePixelRatio;
    final candidate = _findPrimaryVerticalScrollable();
    final Rect physicalRect;
    if (candidate == null) {
      physicalRect = Rect.zero;
    } else {
      final r = candidate.visibleRect;
      physicalRect = Rect.fromLTRB(
        (r.left * dpr).roundToDouble(),
        (r.top * dpr).roundToDouble(),
        (r.right * dpr).roundToDouble(),
        (r.bottom * dpr).roundToDouble(),
      );
    }

    if (_lastSyncedPhysicalBounds == physicalRect && _lastSyncedDpr == dpr) {
      return;
    }
    _lastSyncedPhysicalBounds = physicalRect;
    _lastSyncedDpr = dpr;

    unawaited(
      _channel
          .invokeMethod<void>('updateScrollTarget', <String, Object>{
            'hasTarget': candidate != null && physicalRect.height > 4,
            'leftPx': physicalRect.left.round(),
            'topPx': physicalRect.top.round(),
            'rightPx': physicalRect.right.round(),
            'bottomPx': physicalRect.bottom.round(),
          })
          .catchError((Object error) {
            developer.log(
              '更新系统滚动长截屏目标区域忽略',
              name: 'konata.scroll_capture',
              error: error,
            );
          }),
    );
  }

  Future<Map<String, Object>> _beginCapture() async {
    final view = View.of(context);
    final dpr = view.devicePixelRatio;
    final candidate = _findPrimaryVerticalScrollable();
    if (candidate == null || !candidate.state.mounted) {
      _capturedScrollable = null;
      return const <String, Object>{'ready': false};
    }
    _capturedScrollable = candidate.state;
    _capturedLogicalRect = candidate.visibleRect;
    _capturedInitialPixels = candidate.state.position.pixels;
    _capturedDpr = dpr;
    return <String, Object>{
      'ready': true,
      'leftPx': (candidate.visibleRect.left * dpr).round(),
      'topPx': (candidate.visibleRect.top * dpr).round(),
      'rightPx': (candidate.visibleRect.right * dpr).round(),
      'bottomPx': (candidate.visibleRect.bottom * dpr).round(),
    };
  }

  Future<Map<String, Object>> _scrollToCaptureArea(
    double requestedTopPx,
  ) async {
    final state = _capturedScrollable;
    if (state == null || !state.mounted || _capturedLogicalRect.isEmpty) {
      return const <String, Object>{'ok': false};
    }
    final pos = state.position;
    if (!pos.hasPixels) {
      return const <String, Object>{'ok': false};
    }

    final dpr = _capturedDpr;
    final desiredLogical = _capturedInitialPixels + requestedTopPx / dpr;
    final targetLogical = desiredLogical
        .clamp(pos.minScrollExtent, pos.maxScrollExtent)
        .toDouble();

    if ((pos.pixels - targetLogical).abs() > 0.25) {
      pos.jumpTo(targetLogical);
    }

    // 等待引擎完成新偏移排版与光栅化，确保下一帧 PixelCopy 采到真实新像素
    SchedulerBinding.instance.scheduleFrame();
    await SchedulerBinding.instance.endOfFrame;
    await Future<void>.delayed(KonataTheme.scrollCaptureSettleDelay);
    if (!mounted || !state.mounted) {
      return const <String, Object>{'ok': false};
    }

    final actualDeltaLogical = state.position.pixels - _capturedInitialPixels;
    return <String, Object>{
      'ok': true,
      'actualDeltaPx': (actualDeltaLogical * dpr).round(),
      'leftPx': (_capturedLogicalRect.left * dpr).round(),
      'topPx': (_capturedLogicalRect.top * dpr).round(),
      'rightPx': (_capturedLogicalRect.right * dpr).round(),
      'bottomPx': (_capturedLogicalRect.bottom * dpr).round(),
    };
  }

  Future<void> _endCapture() async {
    final state = _capturedScrollable;
    final initial = _capturedInitialPixels;
    _capturedScrollable = null;
    if (state != null && state.mounted && state.position.hasPixels) {
      final pos = state.position;
      final restored = initial
          .clamp(pos.minScrollExtent, pos.maxScrollExtent)
          .toDouble();
      if ((pos.pixels - restored).abs() > 0.25) {
        pos.jumpTo(restored);
      }
      SchedulerBinding.instance.scheduleFrame();
      await SchedulerBinding.instance.endOfFrame;
    }
    _scheduleSyncMetrics();
  }

  _CandidateScrollable? _findPrimaryVerticalScrollable() {
    final rootElement =
        (widget.navigatorKey.currentContext ?? context) as Element?;
    if (rootElement == null || !rootElement.mounted) return null;

    final screenSize = MediaQuery.sizeOf(context);
    final safePadding = MediaQuery.paddingOf(context);
    final screenRect = Rect.fromLTRB(
      safePadding.left,
      safePadding.top,
      math.max(safePadding.left, screenSize.width - safePadding.right),
      math.max(safePadding.top, screenSize.height - safePadding.bottom),
    );
    _CandidateScrollable? best;

    void visit(Element element) {
      final widgetObj = element.widget;
      if (widgetObj is Offstage && widgetObj.offstage) return;
      if (widgetObj is Visibility && !widgetObj.visible) return;
      if (widgetObj is Opacity && widgetObj.opacity <= 0.01) return;

      if (element is StatefulElement && element.state is ScrollableState) {
        final scrollable = element.state as ScrollableState;
        final route = ModalRoute.of(element);
        if (route != null && !route.isCurrent) {
          element.visitChildren(visit);
          return;
        }
        final axis = axisDirectionToAxis(scrollable.axisDirection);
        if (axis == Axis.vertical && scrollable.mounted) {
          final pos = scrollable.position;
          if (pos.hasPixels &&
              pos.hasContentDimensions &&
              pos.maxScrollExtent > pos.minScrollExtent + 1.0) {
            final renderObj = element.findRenderObject();
            if (renderObj is RenderBox &&
                renderObj.attached &&
                renderObj.hasSize) {
              final size = renderObj.size;
              if (size.width >= 100 && size.height >= 120) {
                final topLeft = renderObj.localToGlobal(Offset.zero);
                final bottomExclusion = ScrollCaptureExclusionInsets.bottomOf(
                  element,
                );
                final rawRect = Rect.fromLTWH(
                  topLeft.dx,
                  topLeft.dy,
                  size.width,
                  size.height,
                );
                final maxBottom = math.max(
                  screenRect.top,
                  screenRect.bottom - bottomExclusion,
                );
                final clippedRect = Rect.fromLTRB(
                  math.max(rawRect.left, screenRect.left),
                  math.max(rawRect.top, screenRect.top),
                  math.min(rawRect.right, screenRect.right),
                  math.min(rawRect.bottom, maxBottom),
                );
                if (clippedRect.width >= 100 && clippedRect.height >= 120) {
                  final area = clippedRect.width * clippedRect.height;
                  if (best == null || area > best!.area) {
                    best = _CandidateScrollable(
                      state: scrollable,
                      visibleRect: clippedRect,
                      area: area,
                    );
                  }
                }
              }
            }
          }
        }
      }

      element.visitChildren(visit);
    }

    rootElement.visitChildren(visit);
    return best;
  }

  @override
  Widget build(BuildContext context) {
    if (!KonataAdaptiveTokens.isAndroid) {
      return widget.child;
    }
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) {
        if (notification.metrics.axis == Axis.vertical) {
          _scheduleSyncMetrics();
        }
        return false;
      },
      child: widget.child,
    );
  }
}
