import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../theme/konata_adaptive_tokens.dart';
import '../../theme/konata_palette.dart';
import '../../theme/konata_theme.dart';

/// 悬浮小窗实时屏幕占用矩形通知器（供底部 Toast、详情页与列表统一协同避让）。
final ValueNotifier<Rect?> konataFloatingMiniWindowRectNotifier =
    ValueNotifier<Rect?>(null);

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

/// 全局悬浮轻提示控制器（驱动根视口常驻 [KonataToastViewport]，不随滚动或切页跳位）。
abstract final class KonataToastController {
  static final ValueNotifier<KonataToastData?> activeToast =
      ValueNotifier<KonataToastData?>(null);
  static int _nextToastId = 0;
  static int _mountedViewportCount = 0;

  /// 当前是否已挂载根级 [KonataToastViewport]。
  static bool get hasMountedViewport => _mountedViewportCount > 0;

  /// 向根级视口投递一条自动消失悬浮提示。
  static void show(
    String message, {
    bool isError = false,
    Duration duration = KonataAdaptiveTokens.toastAutoDismissDuration,
  }) {
    final trimmed = message.trim();
    if (trimmed.isEmpty) return;
    _removeFallbackOverlay();
    activeToast.value = KonataToastData(
      id: ++_nextToastId,
      message: trimmed,
      isError: isError,
      duration: duration,
    );
  }

  /// 立即清除当前悬浮提示。
  static void dismiss() {
    _removeFallbackOverlay();
    if (activeToast.value != null) {
      activeToast.value = null;
    }
  }

  /// 登记根级宿主（允许按需懒挂载 [KonataToastViewport] 以消除静息态图层开销）。
  static void registerHost() {
    _mountedViewportCount += 1;
    _removeFallbackOverlay();
  }

  /// 注销根级宿主。
  static void unregisterHost() {
    if (_mountedViewportCount > 0) {
      _mountedViewportCount -= 1;
    }
  }

  static void _registerViewport() => registerHost();

  static void _unregisterViewport() => unregisterHost();
}

OverlayEntry? _fallbackToastEntry;

void _removeFallbackOverlay() {
  if (_fallbackToastEntry?.mounted == true) {
    _fallbackToastEntry!.remove();
  }
  _fallbackToastEntry = null;
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

  if (KonataToastController.hasMountedViewport) {
    KonataToastController.show(
      trimmed,
      isError: isError,
      duration: duration,
    );
    return;
  }

  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;

  _removeFallbackOverlay();
  final data = KonataToastData(
    id: ++KonataToastController._nextToastId,
    message: trimmed,
    isError: isError,
    duration: duration,
  );

  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => KonataToastViewport.standaloneOverlay(
      data: data,
      onDismissed: () {
        if (entry.mounted) {
          entry.remove();
        }
        if (identical(_fallbackToastEntry, entry)) {
          _fallbackToastEntry = null;
        }
      },
    ),
  );
  _fallbackToastEntry = entry;
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
  }) : _standaloneData = null,
       _onStandaloneDismissed = null;

  /// 创建独立 Overlay 兜底实例（兼容未包裹根壳层的独立组件测试）。
  const KonataToastViewport.standaloneOverlay({
    super.key,
    required KonataToastData data,
    required VoidCallback onDismissed,
  }) : baseBottomClearance = 0.0,
       _standaloneData = data,
       _onStandaloneDismissed = onDismissed;

  /// 外部壳层提供的底部导航/常驻避让基准高度。
  final double baseBottomClearance;
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
    } else {
      KonataToastController._registerViewport();
      KonataToastController.activeToast.addListener(_onControllerToastChanged);
      final existing = KonataToastController.activeToast.value;
      if (existing != null) {
        _presentData(existing);
      }
    }
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    if (!_isStandalone) {
      KonataToastController.activeToast.removeListener(
        _onControllerToastChanged,
      );
      KonataToastController._unregisterViewport();
    }
    _controller.dispose();
    super.dispose();
  }

  void _onControllerToastChanged() {
    final next = KonataToastController.activeToast.value;
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
    if (closingId != null &&
        KonataToastController.activeToast.value?.id != null &&
        KonataToastController.activeToast.value!.id != closingId) {
      return;
    }
    if (clearController &&
        KonataToastController.activeToast.value?.id == closingId) {
      KonataToastController.activeToast.value = null;
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

    return ValueListenableBuilder<Rect?>(
      valueListenable: konataFloatingMiniWindowRectNotifier,
      builder: (context, miniRect, _) {
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
      },
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
    final badge = data.isError ? p.dangerBadge : null;
    final bgColor = data.isError
        ? badge!.bg.withValues(alpha: p.isDark ? 0.90 : 0.95)
        : p.elevatedSurface.withValues(alpha: p.isDark ? 0.84 : 0.92);
    final borderColor = data.isError ? badge!.border : p.hoverBorder;
    final fgColor = data.isError ? badge!.fg : p.textPrimary;
    final iconColor = data.isError ? badge!.fg : p.accent;
    final closeHitSize = isAndroid
        ? KonataAdaptiveTokens.touchTarget
        : KonataAdaptiveTokens.desktopToastCloseHitSize;

    return Material(
      type: MaterialType.transparency,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(KonataAdaptiveTokens.capsuleRadius),
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: KonataAdaptiveTokens.toastBlurSigma,
            sigmaY: KonataAdaptiveTokens.toastBlurSigma,
          ),
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
                            fontSize: 13.0,
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
