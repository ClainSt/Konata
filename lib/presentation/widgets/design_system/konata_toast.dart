import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme/konata_adaptive_tokens.dart';
import '../../theme/konata_palette.dart';
import '../../theme/konata_theme.dart';

/// 单条悬浮轻提示载荷模型。
@immutable
class KonataToastData {
  /// 创建悬浮提示载荷。
  const KonataToastData({
    required this.id,
    required this.message,
    required this.isError,
    required this.duration,
  });

  /// 唯一递增序号（确保连续相同文案也能重置 4 秒倒计时）。
  final int id;

  /// 提示文本内容。
  final String message;

  /// 是否为错误告警语义。
  final bool isError;

  /// 自动淡出等待时长（默认 4 秒）。
  final Duration duration;
}

/// 由 Riverpod 托管的悬浮轻提示与悬浮小窗矩形协同控制器（零全局可变静态状态）。
class KonataToastController {
  /// 当前活跃悬浮轻提示通知器。
  final ValueNotifier<KonataToastData?> activeToast =
      ValueNotifier<KonataToastData?>(null);

  /// 悬浮小窗实时屏幕占用矩形通知器（供底部 Toast、详情页与列表统一协同避让）。
  final ValueNotifier<Rect?> floatingMiniWindowRect = ValueNotifier<Rect?>(
    null,
  );

  int _nextToastId = 0;
  int _mountedViewportCount = 0;
  OverlayEntry? _fallbackToastEntry;
  bool _disposed = false;

  /// 当前控制器是否已被容器释放。
  bool get isDisposed => _disposed;

  /// 安全写入悬浮小窗实时屏幕矩形（容器释放后静默忽略，防止跨帧竞态）。
  void publishFloatingMiniWindowRect(Rect? rect) {
    if (_disposed) return;
    if (floatingMiniWindowRect.value != rect) {
      floatingMiniWindowRect.value = rect;
    }
  }

  /// 仅当当前记录矩形仍等于 [expected] 且控制器未释放时清零。
  void clearFloatingMiniWindowRectIfMatches(Rect expected) {
    if (_disposed) return;
    if (floatingMiniWindowRect.value == expected) {
      floatingMiniWindowRect.value = null;
    }
  }

  /// 当前是否已挂载根级 [KonataToastViewport]。
  bool get hasMountedViewport => _mountedViewportCount > 0;

  /// 分配下一个递增提示序号。
  int nextToastId() => ++_nextToastId;

  /// 向根级视口投递一条自动消失悬浮提示。
  void show(
    String message, {
    bool isError = false,
    Duration duration = KonataAdaptiveTokens.toastAutoDismissDuration,
  }) {
    final trimmed = message.trim();
    if (trimmed.isEmpty) return;
    _removeFallbackOverlay();
    activeToast.value = KonataToastData(
      id: nextToastId(),
      message: trimmed,
      isError: isError,
      duration: duration,
    );
  }

  /// 立即清除当前悬浮提示。
  void dismiss() {
    _removeFallbackOverlay();
    if (activeToast.value != null) {
      activeToast.value = null;
    }
  }

  /// 登记根级宿主（允许按需懒挂载 [KonataToastViewport] 以消除静息态图层开销）。
  void registerHost() {
    _mountedViewportCount += 1;
    _removeFallbackOverlay();
  }

  /// 注销根级宿主。
  void unregisterHost() {
    if (_mountedViewportCount > 0) {
      _mountedViewportCount -= 1;
    }
  }

  void _attachFallbackOverlay(OverlayEntry entry) {
    _removeFallbackOverlay();
    _fallbackToastEntry = entry;
  }

  void _clearFallbackIfIdentical(OverlayEntry entry) {
    if (identical(_fallbackToastEntry, entry)) {
      _fallbackToastEntry = null;
    }
  }

  void _removeFallbackOverlay() {
    if (_fallbackToastEntry?.mounted == true) {
      _fallbackToastEntry!.remove();
    }
    _fallbackToastEntry = null;
  }

  /// 容器销毁时释放全部通知器与兜底浮层。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _removeFallbackOverlay();
    activeToast.dispose();
    floatingMiniWindowRect.dispose();
  }
}

/// 全站唯一悬浮提示控制器 Provider（按 `ProviderScope` 容器生命周期独立隔离）。
final konataToastControllerProvider = Provider<KonataToastController>((ref) {
  final controller = KonataToastController();
  ref.onDispose(controller.dispose);
  return controller;
});

KonataToastController? _maybeResolveToastController(BuildContext context) {
  try {
    return ProviderScope.containerOf(
      context,
      listen: false,
    ).read(konataToastControllerProvider);
  } on StateError {
    return null;
  }
}

/// 弹出全站唯一底部悬浮毛玻璃胶囊提示（固定于底部安全区上方，4 秒自动淡出，支持 `×` 立即关闭，禁止使用 SnackBar）。
void showKonataToast(
  BuildContext context,
  String message, {
  bool isError = false,
  Duration duration = KonataAdaptiveTokens.toastAutoDismissDuration,
}) {
  final trimmed = message.trim();
  if (trimmed.isEmpty) return;

  final controller = _maybeResolveToastController(context);
  if (controller != null && controller.hasMountedViewport) {
    controller.show(trimmed, isError: isError, duration: duration);
    return;
  }

  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;

  final data = KonataToastData(
    id: controller?.nextToastId() ?? DateTime.now().microsecondsSinceEpoch,
    message: trimmed,
    isError: isError,
    duration: duration,
  );

  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => KonataToastViewport.standaloneOverlay(
      data: data,
      controller: controller,
      onDismissed: () {
        if (entry.mounted) {
          entry.remove();
        }
        controller?._clearFallbackIfIdentical(entry);
      },
    ),
  );
  controller?._attachFallbackOverlay(entry);
  overlay.insert(entry);
}

/// 计算底部悬浮提示相对视口底边的安全定位距离（统一避让安全区、底部胶囊与悬浮小窗）。
double resolveKonataToastBottomOffset({
  required Size viewportSize,
  required EdgeInsets safePadding,
  required bool isAndroid,
  double baseBottomClearance = 0.0,
  Rect? floatingMiniWindowRect,
}) {
  final minSafeBottom =
      safePadding.bottom +
      (isAndroid
          ? KonataAdaptiveTokens.toastSafeBottomGapAndroid
          : KonataAdaptiveTokens.toastSafeBottomGapDesktop);
  var bottom = math.max(minSafeBottom, baseBottomClearance);

  if (floatingMiniWindowRect != null &&
      viewportSize.width > 0 &&
      viewportSize.height > 0) {
    final toastMaxW = math.min(
      viewportSize.width - KonataAdaptiveTokens.toastHorizontalMargin * 2,
      KonataAdaptiveTokens.toastMaxWidth,
    );
    final toastLeft = (viewportSize.width - toastMaxW) / 2.0;
    final toastRight = toastLeft + toastMaxW;
    final overlapsHorizontally =
        floatingMiniWindowRect.right > toastLeft - 8.0 &&
        floatingMiniWindowRect.left < toastRight + 8.0;
    final inLowerHalf =
        floatingMiniWindowRect.bottom >= viewportSize.height * 0.45;
    if (overlapsHorizontally && inLowerHalf) {
      final aboveMini =
          viewportSize.height -
          floatingMiniWindowRect.top +
          KonataAdaptiveTokens.toastMiniWindowGap;
      bottom = math.max(bottom, aboveMini);
    }
  }

  final maxAllowedBottom = math.max(
    minSafeBottom,
    viewportSize.height - safePadding.top - 72.0,
  );
  return bottom.clamp(minSafeBottom, maxAllowedBottom);
}

/// 根视口底部常驻轻提示挂载层（与页面滚动和路由栈完全解耦，零跳位漂移）。
class KonataToastViewport extends StatefulWidget {
  /// 创建根级常驻轻提示视口层。
  const KonataToastViewport({
    super.key,
    this.baseBottomClearance = 0.0,
    this.controller,
  }) : _standaloneData = null,
       _onStandaloneDismissed = null;

  /// 创建独立 Overlay 兜底实例（兼容未包裹根壳层的独立组件测试）。
  const KonataToastViewport.standaloneOverlay({
    super.key,
    required KonataToastData data,
    required VoidCallback onDismissed,
    this.controller,
  }) : baseBottomClearance = 0.0,
       _standaloneData = data,
       _onStandaloneDismissed = onDismissed;

  /// 外部壳层提供的底部导航/常驻避让基准高度。
  final double baseBottomClearance;

  /// 可选显式注入的轻提示控制器（缺省时自动从当前 `ProviderScope` 读取）。
  final KonataToastController? controller;
  final KonataToastData? _standaloneData;
  final VoidCallback? _onStandaloneDismissed;

  @override
  State<KonataToastViewport> createState() => _KonataToastViewportState();
}

class _KonataToastViewportState extends State<KonataToastViewport>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<Offset> _slide;
  Timer? _dismissTimer;
  KonataToastData? _currentData;
  bool _closing = false;
  KonataToastController? _boundToastController;

  bool get _isStandalone => widget._standaloneData != null;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: KonataAdaptiveTokens.toastEnterDuration,
      reverseDuration: KonataAdaptiveTokens.toastExitDuration,
    );
    _opacity = CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.18),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));

    if (_isStandalone) {
      _presentData(widget._standaloneData!);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_isStandalone) {
      _boundToastController ??=
          widget.controller ?? _maybeResolveToastController(context);
      return;
    }
    final resolved = widget.controller ?? _maybeResolveToastController(context);
    if (!identical(_boundToastController, resolved)) {
      if (_boundToastController != null) {
        _boundToastController!.activeToast.removeListener(
          _onControllerToastChanged,
        );
        _boundToastController!.unregisterHost();
      }
      _boundToastController = resolved;
      if (resolved != null) {
        resolved.registerHost();
        resolved.activeToast.addListener(_onControllerToastChanged);
        final existing = resolved.activeToast.value;
        if (existing != null) {
          _presentData(existing);
        }
      }
    }
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    if (!_isStandalone && _boundToastController != null) {
      _boundToastController!.activeToast.removeListener(
        _onControllerToastChanged,
      );
      _boundToastController!.unregisterHost();
    }
    _boundToastController = null;
    _controller.dispose();
    super.dispose();
  }

  void _onControllerToastChanged() {
    final next = _boundToastController?.activeToast.value;
    if (next == null) {
      if (_currentData != null && !_closing) {
        unawaited(_beginClose(clearController: false));
      }
      return;
    }
    _presentData(next);
  }

  void _presentData(KonataToastData data) {
    _dismissTimer?.cancel();
    _closing = false;
    setState(() {
      _currentData = data;
    });
    _controller.forward(from: 0.0);
    _dismissTimer = Timer(data.duration, () {
      unawaited(_beginClose(clearController: true));
    });
  }

  Future<void> _beginClose({required bool clearController}) async {
    if (!mounted || _closing) return;
    _closing = true;
    _dismissTimer?.cancel();
    _dismissTimer = null;
    final closingId = _currentData?.id;
    final disableAnimations = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (!disableAnimations) {
      await _controller.reverse();
    }
    if (!mounted) return;
    if (_isStandalone) {
      widget._onStandaloneDismissed?.call();
      return;
    }
    final bound = _boundToastController;
    if (closingId != null &&
        bound?.activeToast.value?.id != null &&
        bound!.activeToast.value!.id != closingId) {
      return;
    }
    if (clearController && bound?.activeToast.value?.id == closingId) {
      bound?.activeToast.value = null;
    }
    setState(() {
      _currentData = null;
      _closing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final data = _currentData;
    if (data == null) return const SizedBox.shrink();

    final size = MediaQuery.sizeOf(context);
    final viewPadding = MediaQuery.viewPaddingOf(context);
    final padding = MediaQuery.paddingOf(context);
    final safePadding = EdgeInsets.only(
      left: math.max(padding.left, viewPadding.left),
      top: math.max(padding.top, viewPadding.top),
      right: math.max(padding.right, viewPadding.right),
      bottom: math.max(padding.bottom, viewPadding.bottom),
    );
    final isAndroid = KonataAdaptiveTokens.isAndroid;
    final miniRectListenable = _boundToastController?.floatingMiniWindowRect;

    Widget buildPositioned(Rect? miniRect) {
      final bottomOffset = resolveKonataToastBottomOffset(
        viewportSize: size,
        safePadding: safePadding,
        isAndroid: isAndroid,
        baseBottomClearance: widget.baseBottomClearance,
        floatingMiniWindowRect: miniRect,
      );

      return Positioned(
        left: safePadding.left + KonataAdaptiveTokens.toastHorizontalMargin,
        right: safePadding.right + KonataAdaptiveTokens.toastHorizontalMargin,
        bottom: bottomOffset,
        child: Align(
          alignment: Alignment.bottomCenter,
          heightFactor: 1.0,
          child: FadeTransition(
            opacity: _opacity,
            child: SlideTransition(
              position: _slide,
              child: _KonataGlassToastCapsule(
                key: const ValueKey('konata_toast_capsule'),
                data: data,
                isAndroid: isAndroid,
                onCloseTap: () => unawaited(
                  _beginClose(clearController: true),
                ),
              ),
            ),
          ),
        ),
      );
    }

    if (miniRectListenable == null) {
      return buildPositioned(null);
    }

    return ValueListenableBuilder<Rect?>(
      valueListenable: miniRectListenable,
      builder: (context, miniRect, _) => buildPositioned(miniRect),
    );
  }
}

class _KonataGlassToastCapsule extends StatelessWidget {
  const _KonataGlassToastCapsule({
    super.key,
    required this.data,
    required this.isAndroid,
    required this.onCloseTap,
  });

  final KonataToastData data;
  final bool isAndroid;
  final VoidCallback onCloseTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final bgColor = data.isError
        ? KonataTheme.toastErrorSurface(p)
        : p.elevatedSurface.withValues(alpha: p.isDark ? 0.84 : 0.92);
    final borderColor = data.isError
        ? KonataTheme.toastErrorBorder(p)
        : p.hoverBorder;
    final fgColor = data.isError
        ? KonataTheme.toastErrorForeground(p)
        : p.textPrimary;
    final iconColor = data.isError
        ? KonataTheme.toastErrorForeground(p)
        : p.accent;
    final closeHitSize = isAndroid
        ? KonataAdaptiveTokens.touchTarget
        : KonataAdaptiveTokens.desktopToastCloseHitSize;

    return Material(
      type: MaterialType.transparency,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(KonataAdaptiveTokens.capsuleRadius),
        child: BackdropFilter(
          filter: KonataTheme.blurFilterControl,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: KonataAdaptiveTokens.toastMaxWidth,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(
                  KonataAdaptiveTokens.capsuleRadius,
                ),
                border: Border.all(
                  color: borderColor,
                  width: KonataAdaptiveTokens.borderWidth,
                ),
              ),
              child: Padding(
                padding: EdgeInsets.only(
                  left: 16,
                  right: isAndroid ? 4 : 10,
                  top: isAndroid ? 2 : 8,
                  bottom: isAndroid ? 2 : 8,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      data.isError
                          ? Icons.error_outline_rounded
                          : Icons.check_circle_outline_rounded,
                      size: 18,
                      color: iconColor,
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          vertical: isAndroid ? 8 : 0,
                        ),
                        child: Text(
                          data.message,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: KonataTheme.uiFontFamily,
                            fontFamilyFallback:
                                KonataTheme.uiFontFamilyFallback,
                            color: fgColor,
                            fontSize: KonataTheme.fontSizeBodySm,
                            fontWeight: FontWeight.w600,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Tooltip(
                      message: '关闭提示',
                      child: GestureDetector(
                        key: const ValueKey('konata_toast_close'),
                        behavior: HitTestBehavior.opaque,
                        onTap: onCloseTap,
                        child: SizedBox(
                          width: closeHitSize,
                          height: closeHitSize,
                          child: Center(
                            child: Icon(
                              Icons.close_rounded,
                              size: 16,
                              color: fgColor.withValues(alpha: 0.86),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
