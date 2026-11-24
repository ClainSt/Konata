import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

import '../shell/konata_modal_layer_registry.dart';
import '../tokens/konata_theme.dart';

class _InstantPanGestureRecognizer extends PanGestureRecognizer {
  _InstantPanGestureRecognizer({super.debugOwner}) {
    dragStartBehavior = DragStartBehavior.down;
    gestureSettings = const DeviceGestureSettings(touchSlop: 1.0);
  }

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) {
    return globalDistanceMoved.abs() >= 1.0;
  }
}

class _KonataDraggableDialogScope extends InheritedWidget {
  const _KonataDraggableDialogScope({
    required this.isDragging,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onResetPosition,
    required super.child,
  });

  final bool isDragging;
  final VoidCallback onDragStart;
  final ValueChanged<Offset> onDragUpdate;
  final VoidCallback onDragEnd;
  final VoidCallback onResetPosition;

  static _KonataDraggableDialogScope? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<_KonataDraggableDialogScope>();
  }

  @override
  bool updateShouldNotify(_KonataDraggableDialogScope oldWidget) {
    return isDragging != oldWidget.isDragging;
  }
}

/// 桌面模态弹窗 0 延迟 1:1 跟手拖拽容器壳。
///
/// 配合标题栏上的 [KonataDialogDragHandle] 使用：
/// - 支持从第 1px 起 0ms 延迟 1:1 跟手平移（含先长按停顿再拖拽场景）；
/// - 实时根据视口宽高与弹窗尺寸收敛位置，窗口缩小时自动回拉至可视区；
/// - 双击标题栏即可重置回视口中心，且完全隔离关闭键、输入框划选、胶囊与滚动手势。
class KonataDraggableDialog extends StatefulWidget {
  /// 创建可拖拽弹窗容器。
  const KonataDraggableDialog({
    super.key,
    required this.child,
    this.viewportMargin = KonataTheme.dialogViewportMargin,
  });

  /// 被包裹的模态弹窗内容主体。
  final Widget child;

  /// 与屏幕边缘保持的最小安全距离。
  final double viewportMargin;

  @override
  State<KonataDraggableDialog> createState() => _KonataDraggableDialogState();
}

class _KonataDraggableDialogState extends State<KonataDraggableDialog> {
  final GlobalKey _dialogKey = GlobalKey();
  Offset _offset = Offset.zero;
  Size? _lastDialogSize;
  bool _isDragging = false;

  Size? _readDialogSize() {
    final obj = _dialogKey.currentContext?.findRenderObject();
    if (obj is RenderBox && obj.hasSize) {
      _lastDialogSize = obj.size;
      return obj.size;
    }
    return _lastDialogSize;
  }

  Offset _clampOffset(Offset candidate, Size viewport, Size? dialogSize) {
    if (dialogSize == null) return candidate;
    final maxDx = ((viewport.width - dialogSize.width) / 2 -
            widget.viewportMargin)
        .clamp(0.0, double.infinity);
    final maxDy = ((viewport.height - dialogSize.height) / 2 -
            widget.viewportMargin)
        .clamp(0.0, double.infinity);
    return Offset(
      candidate.dx.clamp(-maxDx, maxDx),
      candidate.dy.clamp(-maxDy, maxDy),
    );
  }

  void _handleDragStart() {
    if (!_isDragging) {
      setState(() => _isDragging = true);
    }
  }

  void _handleDragUpdate(Offset delta) {
    final viewport = MediaQuery.sizeOf(context);
    final dialogSize = _readDialogSize();
    final next = _clampOffset(_offset + delta, viewport, dialogSize);
    if (next != _offset) {
      setState(() => _offset = next);
    }
  }

  void _handleDragEnd() {
    if (_isDragging) {
      setState(() => _isDragging = false);
    }
  }

  void _handleResetPosition() {
    if (_offset != Offset.zero || _isDragging) {
      setState(() {
        _offset = Offset.zero;
        _isDragging = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context);
    final viewInsets = MediaQuery.viewInsetsOf(context);
    final safe = MediaQuery.paddingOf(context);
    final shortIme = viewport.height < 500 && viewInsets.bottom > 0;
    final clamped = shortIme
        ? Offset.zero
        : _clampOffset(_offset, viewport, _lastDialogSize);
    if (!shortIme && clamped != _offset) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final recheck = _clampOffset(_offset, MediaQuery.sizeOf(context), _readDialogSize());
        if (recheck != _offset) {
          setState(() => _offset = recheck);
        }
      });
    }

    return KonataModalRouteScope(
      child: _KonataDraggableDialogScope(
        isDragging: _isDragging,
        onDragStart: _handleDragStart,
        onDragUpdate: _handleDragUpdate,
        onDragEnd: _handleDragEnd,
        onResetPosition: _handleResetPosition,
        child: Padding(
          padding: shortIme
              ? EdgeInsets.fromLTRB(
                  widget.viewportMargin,
                  safe.top + widget.viewportMargin,
                  widget.viewportMargin,
                  viewInsets.bottom + widget.viewportMargin,
                )
              : viewInsets + EdgeInsets.all(widget.viewportMargin),
          child: MediaQuery.removeViewInsets(
            removeLeft: true,
            removeTop: true,
            removeRight: true,
            removeBottom: true,
            context: context,
            child: Transform.translate(
              offset: clamped,
              child: Align(
                alignment: Alignment.center,
                child: NotificationListener<SizeChangedLayoutNotification>(
                  onNotification: (_) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted) return;
                      final next = _clampOffset(
                        _offset,
                        MediaQuery.sizeOf(context),
                        _readDialogSize(),
                      );
                      if (next != _offset) {
                        setState(() => _offset = next);
                      }
                    });
                    return false;
                  },
                  child: SizeChangedLayoutNotifier(
                    child: Material(
                      type: MaterialType.transparency,
                      child: KeyedSubtree(key: _dialogKey, child: widget.child),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 绑定至弹窗标题栏的 0 延迟拖拽热区（显示 `grab` / `grabbing` 光标并支持双击归位居中）。
class KonataDialogDragHandle extends StatelessWidget {
  /// 创建弹窗标题栏拖拽热区。
  const KonataDialogDragHandle({super.key, required this.child});

  /// 标题文本及其左侧空白区域。
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scope = _KonataDraggableDialogScope.maybeOf(context);
    if (scope == null) {
      return child;
    }

    return MouseRegion(
      cursor: scope.isDragging
          ? SystemMouseCursors.grabbing
          : SystemMouseCursors.grab,
      child: RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: <Type, GestureRecognizerFactory>{
          _InstantPanGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<_InstantPanGestureRecognizer>(
                () => _InstantPanGestureRecognizer(debugOwner: this),
                (_InstantPanGestureRecognizer instance) {
                  instance
                    ..dragStartBehavior = DragStartBehavior.down
                    ..gestureSettings = const DeviceGestureSettings(
                      touchSlop: 1.0,
                    )
                    ..onStart = (_) {
                      scope.onDragStart();
                    }
                    ..onUpdate = (details) {
                      scope.onDragUpdate(details.delta);
                    }
                    ..onEnd = (_) {
                      scope.onDragEnd();
                    }
                    ..onCancel = () {
                      scope.onDragEnd();
                    };
                },
              ),
          DoubleTapGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<DoubleTapGestureRecognizer>(
                () => DoubleTapGestureRecognizer(debugOwner: this),
                (DoubleTapGestureRecognizer instance) {
                  instance.onDoubleTap = scope.onResetPosition;
                },
              ),
        },
        child: child,
      ),
    );
  }
}
