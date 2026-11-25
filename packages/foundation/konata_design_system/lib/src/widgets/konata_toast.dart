import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../tokens/konata_adaptive_tokens.dart';
import '../tokens/konata_palette.dart';
import '../tokens/konata_theme.dart';
import 'konata_tooltip.dart';

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

/// 纯 Flutter 悬浮轻提示与悬浮小窗矩形协同控制器（严格 0 Riverpod、零全局静态状态）。
class KonataToastController {
  /// 创建轻提示控制器。
  KonataToastController();

  /// 当前活跃悬浮轻提示通知器。
  final ValueNotifier<KonataToastData?> activeToast =
      ValueNotifier<KonataToastData?>(null);

  /// 悬浮小窗实时屏幕占用矩形通知器（供详情页、列表避让与全屏弹簧形变原点共享）。
  final ValueNotifier<Rect?> floatingMiniWindowRect = ValueNotifier<Rect?>(
    null,
  );

  int _nextToastId = 0;
  int _mountedViewportCount = 0;
  OverlayEntry? _fallbackToastEntry;
  bool _disposed = false;

  /// 当前控制器是否已被宿主释放。
  bool get isDisposed => _disposed;

  /// 安全写入悬浮小窗实时屏幕矩形（释放后静默忽略，防止跨帧竞态）。
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
    if (_disposed) return;
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
    if (!_disposed && activeToast.value != null) {
      activeToast.value = null;
    }
  }

  /// 登记根级宿主。
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

  /// 释放全部通知器与兜底浮层。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _removeFallbackOverlay();
    activeToast.dispose();
    floatingMiniWindowRect.dispose();
  }
}

/// 向子树提供 [KonataToastController] 的纯 Flutter 作用域（替代 Riverpod 容器查找）。
class KonataToastScope extends InheritedWidget {
  /// 创建悬浮提示作用域。
  const KonataToastScope({
    super.key,
    required this.controller,
    required super.child,
  });

  /// 当前应用实例共享的轻提示控制器。
  final KonataToastController controller;

  /// 读取最近的 [KonataToastController]（无订阅副作用，未挂载作用域时返回 `null`）。
  static KonataToastController? maybeOf(BuildContext context) {
    return context
        .getInheritedWidgetOfExactType<KonataToastScope>()
        ?.controller;
  }

  @override
  bool updateShouldNotify(KonataToastScope oldWidget) =>
      !identical(controller, oldWidget.controller);
}

/// 弹出全站唯一窗口居中毛玻璃胶囊提示（三端统一在窗口正中央弹出，4 秒自动淡出，支持 `×` 立即关闭，报错以红色区分）。
void showKonataToast(
  BuildContext context,
  String message, {
  bool isError = false,
  Duration duration = KonataAdaptiveTokens.toastAutoDismissDuration,
}) {
  final trimmed = message.trim();
  if (trimmed.isEmpty) return;

  final controller = KonataToastScope.maybeOf(context);
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

/// 根视口正中常驻轻提示挂载层（桌面、平板、手机三端统一于窗口中心弹出，与页面滚动和路由栈解耦）。
class KonataToastViewport extends StatefulWidget {
  /// 创建根级常驻轻提示视口层。
  const KonataToastViewport({super.key, this.controller})
    : _standaloneData = null,
      _onStandaloneDismissed = null;

  /// 创建独立 Overlay 兜底实例（兼容未包裹根壳层的独立组件测试）。
  const KonataToastViewport.standaloneOverlay({
    super.key,
    required KonataToastData data,
    required VoidCallback onDismissed,
    this.controller,
  }) : _standaloneData = data,
       _onStandaloneDismissed = onDismissed;

  /// 可选显式注入的轻提示控制器（缺省时自动从祖先 [KonataToastScope] 读取）。
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
  late final Animation<double> _scale;
  Timer? _dismissTimer;
  KonataToastData? _currentData;
  bool _closing = false;
  bool _standalonePresented = false;
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
    _scale = Tween<double>(
      begin: 0.94,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_isStandalone) {
      _boundToastController ??=
          widget.controller ?? KonataToastScope.maybeOf(context);
      if (!_standalonePresented) {
        _standalonePresented = true;
        _presentData(widget._standaloneData!, notifyState: false);
      }
      return;
    }
    final resolved = widget.controller ?? KonataToastScope.maybeOf(context);
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
          _presentData(existing, notifyState: false);
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

  void _presentData(KonataToastData data, {bool notifyState = true}) {
    _dismissTimer?.cancel();
    _closing = false;
    if (notifyState) {
      setState(() {
        _currentData = data;
      });
    } else {
      _currentData = data;
    }
    final disableAnimations =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (disableAnimations) {
      _controller.value = 1.0;
    } else {
      unawaited(_controller.forward(from: 0.0));
    }
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
    final disableAnimations =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
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

    final viewPadding = MediaQuery.viewPaddingOf(context);
    final padding = MediaQuery.paddingOf(context);
    final safePadding = EdgeInsets.only(
      left: math.max(padding.left, viewPadding.left),
      top: math.max(padding.top, viewPadding.top),
      right: math.max(padding.right, viewPadding.right),
      bottom: math.max(padding.bottom, viewPadding.bottom),
    );
    final isAndroid = KonataAdaptiveTokens.isAndroid;

    return Positioned.fill(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          safePadding.left + KonataAdaptiveTokens.toastHorizontalMargin,
          safePadding.top + KonataAdaptiveTokens.toastHorizontalMargin,
          safePadding.right + KonataAdaptiveTokens.toastHorizontalMargin,
          safePadding.bottom + KonataAdaptiveTokens.toastHorizontalMargin,
        ),
        child: Align(
          alignment: Alignment.center,
          child: FadeTransition(
            opacity: _opacity,
            child: ScaleTransition(
              scale: _scale,
              child: _KonataGlassToastCapsule(
                key: const ValueKey('konata_toast_capsule'),
                data: data,
                isAndroid: isAndroid,
                onCloseTap: () => unawaited(_beginClose(clearController: true)),
              ),
            ),
          ),
        ),
      ),
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
    final iconColor = data.isError ? p.danger : p.accent;
    final closeHitSize = isAndroid
        ? KonataAdaptiveTokens.touchTarget
        : KonataAdaptiveTokens.desktopToastCloseHitSize;

    // 全局提示可位于 Navigator 的 Overlay 外部，关闭按钮始终可用。
    final closeButton = Semantics(
      label: '关闭提示',
      button: true,
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
    );

    return ConstrainedBox(
      constraints: const BoxConstraints(
        maxWidth: KonataAdaptiveTokens.toastMaxWidth,
      ),
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: IgnorePointer(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(
                  KonataAdaptiveTokens.capsuleRadius,
                ),
                child: BackdropFilter(
                  filter: KonataTheme.blurFilterControl,
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
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: isAndroid ? 4 : 10,
              top: isAndroid ? 2 : 8,
              bottom: isAndroid ? 2 : 8,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                IgnorePointer(
                  child: Icon(
                    data.isError
                        ? Icons.error_outline_rounded
                        : Icons.check_circle_outline_rounded,
                    size: 18,
                    color: iconColor,
                  ),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: IgnorePointer(
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        vertical: isAndroid ? 8 : 0,
                      ),
                      child: Text(
                        data.message,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: KonataTheme.uiFontFamily,
                          fontFamilyFallback: KonataTheme.uiFontFamilyFallback,
                          color: fgColor,
                          fontSize: KonataTheme.fontSizeBodySm,
                          fontWeight: FontWeight.w600,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                KonataTooltip(
                  message: '关闭提示',
                  excludeFromSemantics: true,
                  child: closeButton,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
