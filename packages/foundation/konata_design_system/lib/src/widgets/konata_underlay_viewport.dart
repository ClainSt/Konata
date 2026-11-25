import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 透明底层视口的物理像素矩形及圆角。
typedef KonataUnderlayGeometry = ({Rect rect, double radius});

/// 挖空根画布以显示原生底层表面，实际视口移动时于帧末同步物理坐标。
/// 本控件不得置于独立离屏绘制层中。
class KonataUnderlayViewport extends LeafRenderObjectWidget {
  const KonataUnderlayViewport({
    super.key,
    required this.owner,
    required this.onGeometryChanged,
    this.cornerRadius = 0,
  });

  final Object owner;
  final ValueChanged<KonataUnderlayGeometry?> onGeometryChanged;
  final double cornerRadius;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderUnderlayViewport(
        owner: owner,
        onGeometryChanged: onGeometryChanged,
        dpr: MediaQuery.devicePixelRatioOf(context),
        radius: cornerRadius,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderUnderlayViewport renderObject,
  ) {
    renderObject.update(
      owner: owner,
      onGeometryChanged: onGeometryChanged,
      dpr: MediaQuery.devicePixelRatioOf(context),
      radius: cornerRadius,
    );
  }
}

class _RenderUnderlayViewport extends RenderBox {
  _RenderUnderlayViewport({
    required Object owner,
    required ValueChanged<KonataUnderlayGeometry?> onGeometryChanged,
    required double dpr,
    required double radius,
  }) : _owner = owner,
       _onGeometryChanged = onGeometryChanged,
       _dpr = dpr,
       _radius = radius;

  static final Paint _clear = Paint()..blendMode = BlendMode.clear;
  Object _owner;
  ValueChanged<KonataUnderlayGeometry?> _onGeometryChanged;
  double _dpr;
  double _radius;
  KonataUnderlayGeometry? _last;
  KonataUnderlayGeometry? _pending;
  bool _scheduled = false;

  void update({
    required Object owner,
    required ValueChanged<KonataUnderlayGeometry?> onGeometryChanged,
    required double dpr,
    required double radius,
  }) {
    if (!identical(_owner, owner)) {
      _hide();
      _owner = owner;
    }
    _onGeometryChanged = onGeometryChanged;
    if (_dpr == dpr && _radius == radius && _last != null) return;
    _dpr = dpr;
    _radius = radius;
    markNeedsPaint();
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  bool hitTestSelf(Offset position) => true;

  void _hide() {
    _pending = null;
    if (_last == null) return;
    _last = null;
    _onGeometryChanged(null);
  }

  @override
  void detach() {
    _hide();
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (size.isEmpty) {
      _hide();
      return;
    }
    context.setWillChangeHint();
    final local = offset & size;
    context.canvas.drawRRect(
      RRect.fromRectAndRadius(local, Radius.circular(_radius)),
      _clear,
    );
    final a = localToGlobal(Offset.zero);
    final b = localToGlobal(size.bottomRight(Offset.zero));
    final rect = Rect.fromLTRB(
      (a.dx * _dpr).roundToDouble(),
      (a.dy * _dpr).roundToDouble(),
      (b.dx * _dpr).roundToDouble(),
      (b.dy * _dpr).roundToDouble(),
    );
    if (!rect.isFinite || rect.isEmpty) {
      _hide();
      return;
    }
    final next = (rect: rect, radius: _radius * _dpr);
    if (_last == next && _pending == null) return;
    _pending = next;
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      final geometry = _pending;
      _pending = null;
      if (!attached || geometry == null || geometry == _last) return;
      _last = geometry;
      _onGeometryChanged(geometry);
    });
  }
}
