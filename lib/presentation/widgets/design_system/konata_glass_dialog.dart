import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../shell/adaptive_capsule_layout.dart';
import '../../theme/konata_adaptive_tokens.dart';
import '../../theme/konata_palette.dart';
import '../../theme/konata_theme.dart';
import 'konata_draggable_dialog.dart';

/// 全站统一悬浮毛玻璃弹窗呼出入口（默认加深外部遮罩以突出前景弹窗并抑制底层穿透）。
Future<T?> showKonataGlassDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierColor: KonataTheme.glassDialogBarrier(isDark),
    builder: builder,
  );
}

/// 全站统一毛玻璃底部抽屉呼出入口（供窄屏折叠动作、筛选排序与播放队列共用，支持顶部横条跟手下拉与模态侧滑返回）。
Future<T?> showKonataGlassBottomSheet<T>({
  required BuildContext context,
  required String title,
  required WidgetBuilder builder,
  List<Widget>? actions,
}) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    enableDrag: false,
    backgroundColor: Colors.transparent,
    barrierColor: KonataTheme.glassModalBarrier(isDark),
    builder: (sheetCtx) {
      final p = sheetCtx.palette;
      final maxH = MediaQuery.sizeOf(sheetCtx).height * 0.78;
      return KonataFollowFingerSheetSurface(
        maxHeight: maxH,
        onDismiss: () => Navigator.of(sheetCtx).maybePop(),
        headerBuilder: (ctx) => Padding(
          padding: const EdgeInsets.fromLTRB(18, 6, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.textPrimary,
                    fontSize: KonataTheme.fontSizeTitle,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              KonataGlassCloseButton(
                onPressed: () => Navigator.of(ctx).maybePop(),
              ),
            ],
          ),
        ),
        body: Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: builder(sheetCtx),
          ),
        ),
        footer: (actions != null && actions.isNotEmpty)
            ? Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 10,
                  runSpacing: 8,
                  children: actions,
                ),
              )
            : null,
      );
    },
  );
}

/// 支持按住顶部横条跟手下拉收起的公共毛玻璃底部抽屉表面容器。
class KonataFollowFingerSheetSurface extends StatefulWidget {
  /// 创建跟手下拉毛玻璃底部抽屉表面。
  const KonataFollowFingerSheetSurface({
    super.key,
    required this.headerBuilder,
    required this.body,
    required this.onDismiss,
    this.footer,
    this.height,
    this.maxHeight,
    this.surfaceKey,
    this.dragHandleKey,
    this.topRadius = 22.0,
    this.blurSigma = 44.0,
    this.surfaceColor,
    this.borderColor,
    this.applyBottomSafeArea = true,
  });

  /// 抽屉顶部标题区构建器（与顶部横条一并响应跟手下拉手势）。
  final WidgetBuilder headerBuilder;

  /// 抽屉主体内容区。
  final Widget body;

  /// 可选底部操作区。
  final Widget? footer;

  /// 下拉触发收起回调。
  final VoidCallback onDismiss;

  /// 可选固定高度。
  final double? height;

  /// 可选最大高度约束。
  final double? maxHeight;

  /// 可选抽屉面板容器键（位于跟手位移内部）。
  final Key? surfaceKey;

  /// 可选顶部横条语义/测试标识键。
  final Key? dragHandleKey;

  /// 顶部圆角半径。
  final double topRadius;

  /// 毛玻璃模糊半径。
  final double blurSigma;

  /// 可选表面覆盖色。
  final Color? surfaceColor;

  /// 可选边框覆盖色。
  final Color? borderColor;

  /// 是否在内部包裹底部安全区避让。
  final bool applyBottomSafeArea;

  @override
  State<KonataFollowFingerSheetSurface> createState() =>
      _KonataFollowFingerSheetSurfaceState();
}

class _KonataFollowFingerSheetSurfaceState
    extends State<KonataFollowFingerSheetSurface>
    with SingleTickerProviderStateMixin {
  final ValueNotifier<double> _dragOffset = ValueNotifier<double>(0.0);
  late final AnimationController _reboundController;
  double _reboundStartOffset = 0.0;
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    _reboundController = AnimationController(
      vsync: this,
      duration: KonataTheme.motionStandard,
    )..addListener(() {
        final t = Curves.easeOutCubic.transform(_reboundController.value);
        _dragOffset.value = _reboundStartOffset * (1.0 - t);
      });
  }

  @override
  void dispose() {
    _reboundController.dispose();
    _dragOffset.dispose();
    super.dispose();
  }

  void _onDragStart(DragStartDetails _) {
    if (_reboundController.isAnimating) {
      _reboundController.stop();
    }
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (_dismissed) return;
    final next = (_dragOffset.value + details.delta.dy).clamp(0.0, 900.0);
    _dragOffset.value = next;
  }

  void _onDragEnd(DragEndDetails details) {
    if (_dismissed) return;
    final velocity = details.primaryVelocity ?? 0.0;
    if (_dragOffset.value > 52.0 || velocity > 360.0) {
      _dismissed = true;
      widget.onDismiss();
      return;
    }
    if (_dragOffset.value > 0.0) {
      _reboundStartOffset = _dragOffset.value;
      _reboundController.forward(from: 0.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final glassBg =
        widget.surfaceColor ??
        (p.isDark
            ? p.elevatedSurface.withValues(alpha: 0.92)
            : p.elevatedSurface.withValues(alpha: 0.95));
    final glassBorder = widget.borderColor ?? p.hoverBorder;

    Widget content = Column(
      mainAxisSize: widget.height != null ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          dragStartBehavior: DragStartBehavior.down,
          onVerticalDragStart: _onDragStart,
          onVerticalDragUpdate: _onDragUpdate,
          onVerticalDragEnd: _onDragEnd,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: ColoredBox(
                  key: widget.dragHandleKey,
                  color: Colors.transparent,
                  child: Padding(
                    padding: const EdgeInsets.only(
                      top: 10,
                      bottom: 4,
                      left: 32,
                      right: 32,
                    ),
                    child: Container(
                      width: 38,
                      height: 4,
                      decoration: BoxDecoration(
                        color: p.textMuted.withValues(alpha: 0.48),
                        borderRadius: KonataTheme.borderRadiusPill,
                      ),
                    ),
                  ),
                ),
              ),
              widget.headerBuilder(context),
            ],
          ),
        ),
        Divider(height: 1, thickness: 1, color: p.hairline),
        widget.body,
        ?widget.footer,
      ],
    );

    if (widget.applyBottomSafeArea) {
      content = SafeArea(top: false, child: content);
    }

    Widget surface = ClipRRect(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(widget.topRadius),
      ),
      child: BackdropFilter(
        filter: KonataTheme.blurFilterOf(widget.blurSigma),
        child: Container(
          height: widget.height,
          decoration: BoxDecoration(
            color: glassBg,
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(widget.topRadius),
            ),
            border: Border(
              top: BorderSide(color: glassBorder, width: 1),
              left: BorderSide(color: glassBorder, width: 1),
              right: BorderSide(color: glassBorder, width: 1),
            ),
          ),
          child: Material(type: MaterialType.transparency, child: content),
        ),
      ),
    );

    if (widget.maxHeight != null) {
      surface = ConstrainedBox(
        constraints: BoxConstraints(maxHeight: widget.maxHeight!),
        child: surface,
      );
    }

    if (widget.surfaceKey != null) {
      surface = KeyedSubtree(key: widget.surfaceKey, child: surface);
    }

    return KonataModalRouteScope(
      child: ValueListenableBuilder<double>(
        valueListenable: _dragOffset,
        child: surface,
        builder: (context, dy, child) => Transform.translate(
          offset: Offset(0, dy),
          child: child,
        ),
      ),
    );
  }
}

class _KonataGlassDialogInputScope extends InheritedWidget {
  const _KonataGlassDialogInputScope({
    required this.viewInsets,
    required this.landscapeCompactInputActive,
    required super.child,
  });

  final EdgeInsets viewInsets;
  final bool landscapeCompactInputActive;

  static _KonataGlassDialogInputScope? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<_KonataGlassDialogInputScope>();
  }

  @override
  bool updateShouldNotify(_KonataGlassDialogInputScope oldWidget) {
    return viewInsets != oldWidget.viewInsets ||
        landscapeCompactInputActive != oldWidget.landscapeCompactInputActive;
  }
}

/// 全站统一悬浮毛玻璃弹窗容器（36px 高斯模糊 + 通透半透明玻璃叠色 + 1px 微光描边）。
class KonataGlassDialog extends StatelessWidget {
  /// 创建毛玻璃弹窗。
  const KonataGlassDialog({
    super.key,
    required this.title,
    required this.child,
    this.width = 520,
    this.height,
    this.maxHeight,
    this.headerTrailing,
    this.inlineHeaderTrailing = false,
    this.headerBottomSpacing,
    this.actions,
    this.onClose,
    this.enableLandscapeCompactInput = true,
  });

  /// 弹窗标题。
  final String title;

  /// 主体内容（若外部未提供高度限制且内容较多，建议内部自行滚动或配合 [maxHeight]）。
  final Widget child;

  /// 弹窗基准宽度（窄视口自动收敛防溢出）。
  final double width;

  /// 可选固定高度。
  final double? height;

  /// 可选最大高度约束。
  final double? maxHeight;

  /// 可选标题栏右侧扩展控件（紧邻关闭按钮左侧）。
  final Widget? headerTrailing;

  /// 是否强制在窄宽度（如手机横屏）下也将 [headerTrailing] 内联放置于顶部标题行。
  final bool inlineHeaderTrailing;

  /// 可选自定义标题栏与主体之间的底部间距。
  final double? headerBottomSpacing;

  /// 可选底部操作按钮区（右对齐排列）。
  final List<Widget>? actions;

  /// 点击右上角关闭按钮回调（默认为 `Navigator.of(context).maybePop()`）。
  final VoidCallback? onClose;

  /// 在矮屏横屏（高度低于 `500dp`）且软键盘弹出时是否启用紧凑顶部输入态。
  final bool enableLandscapeCompactInput;

  /// 读取弹窗外层传入的真实系统软键盘遮挡间距（避免被 `removeViewInsets` 吞掉）。
  static EdgeInsets effectiveViewInsetsOf(BuildContext context) {
    return _KonataGlassDialogInputScope.maybeOf(context)?.viewInsets ??
        MediaQuery.viewInsetsOf(context);
  }

  /// 判断当前弹窗是否处于矮横屏（`height < 500dp`）软键盘弹出紧凑输入态。
  static bool isLandscapeCompactInputActive(BuildContext context) {
    final scope = _KonataGlassDialogInputScope.maybeOf(context);
    if (scope != null) return scope.landscapeCompactInputActive;
    final size = MediaQuery.sizeOf(context);
    return size.height < KonataAdaptiveTokens.shortViewportHeight &&
        MediaQuery.viewInsetsOf(context).bottom > 0;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final screen = MediaQuery.sizeOf(context);
    final safe = MediaQuery.paddingOf(context);
    final viewInsets = MediaQuery.viewInsetsOf(context);
    final landscapeCompactInput =
        enableLandscapeCompactInput &&
        screen.height < KonataAdaptiveTokens.shortViewportHeight &&
        viewInsets.bottom > 0;
    final shortViewport =
        screen.height < KonataAdaptiveTokens.shortViewportHeight;
    final narrowWidth = screen.width < KonataAdaptiveTokens.tabletBreakpoint;
    final compact = narrowWidth || shortViewport;
    final outerMargin = landscapeCompactInput
        ? 2.0
        : (shortViewport ? 6.0 : 12.0);
    final availableW = math.max(
      220.0,
      screen.width - safe.horizontal - outerMargin * 2,
    );
    final availableH = landscapeCompactInput
        ? math.max(
            48.0,
            screen.height - safe.top - viewInsets.bottom - outerMargin * 2,
          )
        : math.max(
            180.0,
            screen.height - safe.vertical - viewInsets.vertical - outerMargin * 2,
          );
    final effectiveWidth = math.min(width, availableW);
    final effectiveHeight = height != null
        ? math.min(height!, availableH)
        : null;
    final effectiveMaxHeight = maxHeight != null
        ? math.min(maxHeight!, availableH)
        : (KonataAdaptiveTokens.isAndroid ? availableH : null);

    final glassBg = KonataTheme.glassDialogSurface(p);
    final glassBorder = KonataTheme.glassDialogBorder(p);
    final shadowColor = KonataTheme.glassDialogShadow(p);

    Widget body = child;
    if (effectiveHeight == null &&
        effectiveMaxHeight != null &&
        maxHeight == null) {
      body = SingleChildScrollView(child: child);
    }

    return _KonataGlassDialogInputScope(
      viewInsets: viewInsets,
      landscapeCompactInputActive: landscapeCompactInput,
      child: KonataDraggableDialog(
        viewportMargin: outerMargin,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: KonataTheme.borderRadiusDialog,
            boxShadow: [
              BoxShadow(
                color: shadowColor,
                blurRadius: 36,
                offset: const Offset(0, 14),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: KonataTheme.borderRadiusDialog,
            child: BackdropFilter(
              filter: KonataTheme.blurFilterSheet,
              child: Container(
                width: effectiveWidth,
                height: effectiveHeight,
                constraints: effectiveMaxHeight != null
                    ? BoxConstraints(maxHeight: effectiveMaxHeight)
                    : null,
                padding: landscapeCompactInput
                    ? const EdgeInsets.symmetric(horizontal: 10, vertical: 4)
                    : (shortViewport
                          ? const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 10,
                            )
                          : EdgeInsets.all(compact ? 16 : 22)),
                decoration: BoxDecoration(
                  color: glassBg,
                  gradient: KonataTheme.opticalSheenGradient(p),
                  borderRadius: KonataTheme.borderRadiusDialog,
                  border: Border.all(color: glassBorder, width: 1),
                ),
                // 使用 Offstage 而非条件增删节点，保持主体槽位深度恒定，防止软键盘切换时输入框卸载丢焦点。
                child: Column(
                  mainAxisSize: effectiveHeight != null
                      ? MainAxisSize.max
                      : MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Offstage(
                      offstage:
                          landscapeCompactInput &&
                          !(inlineHeaderTrailing && headerTrailing != null),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: KonataDialogDragHandle(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 4,
                                    ),
                                    child: Text(
                                      title,
                                      maxLines: inlineHeaderTrailing ? 1 : 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: p.textPrimary,
                                        fontSize: compact ? 16.5 : 18,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: -0.2,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              if (headerTrailing != null &&
                                  (!narrowWidth || inlineHeaderTrailing)) ...[
                                const SizedBox(width: 8),
                                headerTrailing!,
                              ],
                              const SizedBox(width: 8),
                              KonataGlassCloseButton(
                                onPressed:
                                    onClose ??
                                    () => Navigator.of(context).maybePop(),
                              ),
                            ],
                          ),
                          if (headerTrailing != null &&
                              narrowWidth &&
                              !inlineHeaderTrailing) ...[
                            const SizedBox(height: 8),
                            headerTrailing!,
                          ],
                          SizedBox(
                            height: landscapeCompactInput
                                ? 2
                                : (headerBottomSpacing ??
                                      (shortViewport
                                          ? 6
                                          : (compact ? 12 : 16))),
                          ),
                        ],
                      ),
                    ),
                    if (effectiveHeight != null || effectiveMaxHeight != null)
                      Flexible(child: body)
                    else
                      body,
                    if (actions != null && actions!.isNotEmpty)
                      Offstage(
                        offstage: landscapeCompactInput,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(height: shortViewport ? 8 : (compact ? 12 : 18)),
                            Align(
                              alignment: Alignment.centerRight,
                              child: Wrap(
                                alignment: WrapAlignment.end,
                                spacing: 10,
                                runSpacing: 8,
                                children: actions!,
                              ),
                            ),
                          ],
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

/// 圆形半透明微光关闭按钮（供毛玻璃侧栏与弹窗头部复用，Android 保证 48dp 热区）。
class KonataGlassCloseButton extends StatefulWidget {
  /// 创建圆形微光关闭按钮。
  const KonataGlassCloseButton({
    super.key,
    required this.onPressed,
    this.tooltip = '关闭',
  });

  /// 点击回调。
  final VoidCallback? onPressed;

  /// 悬停提示。
  final String tooltip;

  @override
  State<KonataGlassCloseButton> createState() => _KonataGlassCloseButtonState();
}

class _KonataGlassCloseButtonState extends State<KonataGlassCloseButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final enabled = widget.onPressed != null;
    final touchSize = KonataAdaptiveTokens.isAndroid
        ? KonataAdaptiveTokens.touchTarget
        : 30.0;

    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: SizedBox(
            width: touchSize,
            height: touchSize,
            child: Center(
              child: AnimatedContainer(
                duration: KonataTheme.motionFast,
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _hovered && enabled ? p.surfaceHover : p.surface,
                  border: Border.all(
                    color: _hovered && enabled ? p.hoverBorder : p.hairline,
                    width: 1,
                  ),
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.close_rounded,
                  size: 16,
                  color: enabled ? p.textSecondary : p.textMuted,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
