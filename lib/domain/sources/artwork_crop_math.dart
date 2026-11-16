import 'dart:math' as math;

/// 归一化至 `[0.0, 1.0]` 原图坐标系下的矩形裁切区域。
class ArtworkNormalizedCropRect {
  /// 创建归一化裁切矩形。
  const ArtworkNormalizedCropRect({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  /// 左边界归一化坐标 `[0.0, 1.0]`。
  final double left;

  /// 上边界归一化坐标 `[0.0, 1.0]`。
  final double top;

  /// 宽度归一化占比 `(0.0, 1.0]`。
  final double width;

  /// 高度归一化占比 `(0.0, 1.0]`。
  final double height;

  /// 右边界归一化坐标。
  double get right => left + width;

  /// 下边界归一化坐标。
  double get bottom => top + height;

  /// 中心点 X 归一化坐标。
  double get centerX => left + width / 2.0;

  /// 中心点 Y 归一化坐标。
  double get centerY => top + height / 2.0;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ArtworkNormalizedCropRect &&
        (left - other.left).abs() < 1e-9 &&
        (top - other.top).abs() < 1e-9 &&
        (width - other.width).abs() < 1e-9 &&
        (height - other.height).abs() < 1e-9;
  }

  @override
  int get hashCode => Object.hash(left, top, width, height);

  @override
  String toString() =>
      'ArtworkNormalizedCropRect(l=$left, t=$top, w=$width, h=$height)';
}

/// 裁切选框四个角点锚点标识。
enum ArtworkCropCorner { topLeft, topRight, bottomLeft, bottomRight }

/// 阶段舞台内原图等比居中的可视化坐标框（纯数值模型，不依赖 Flutter UI 类型）。
class ArtworkDisplayFrame {
  /// 创建显示坐标框。
  const ArtworkDisplayFrame({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  /// 舞台内左上角 X。
  final double left;

  /// 舞台内左上角 Y。
  final double top;

  /// 显示宽度。
  final double width;

  /// 显示高度。
  final double height;

  /// 右边缘 X。
  double get right => left + width;

  /// 下边缘 Y。
  double get bottom => top + height;
}

/// 映射回原图真实像素坐标系后的整型裁切框。
class ArtworkSourcePixelRect {
  /// 创建像素裁切框。
  const ArtworkSourcePixelRect({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  /// 起始像素 X。
  final int left;

  /// 起始像素 Y。
  final int top;

  /// 裁切像素宽度。
  final int width;

  /// 裁切像素高度。
  final int height;
}

/// 作品封面（2:3）与背景图（16:9）固定比例框选裁切纯数学引擎。
abstract final class ArtworkCropMath {
  /// 竖版海报封面强制锁定的目标长宽比 (`2 : 3`)。
  static const double posterAspectRatio = 2.0 / 3.0;

  /// 横版背景画作强制锁定的目标长宽比 (`16 : 9`)。
  static const double backdropAspectRatio = 16.0 / 9.0;

  /// 根据目标真实像素宽高比 [aspectRatio]，计算居中最大化的初始归一化选框。
  static ArtworkNormalizedCropRect initialMaxCenteredRect({
    required int imageWidth,
    required int imageHeight,
    required double aspectRatio,
  }) {
    final safeW = math.max(1, imageWidth).toDouble();
    final safeH = math.max(1, imageHeight).toDouble();
    final normalizedRatio = aspectRatio * (safeH / safeW);

    late final double w;
    late final double h;
    if (normalizedRatio >= 1.0) {
      w = 1.0;
      h = (1.0 / normalizedRatio).clamp(0.01, 1.0);
    } else {
      h = 1.0;
      w = normalizedRatio.clamp(0.01, 1.0);
    }

    return ArtworkNormalizedCropRect(
      left: ((1.0 - w) / 2.0).clamp(0.0, 1.0),
      top: ((1.0 - h) / 2.0).clamp(0.0, 1.0),
      width: w,
      height: h,
    );
  }

  /// 平移选框并严格钳制在原图 `[0.0, 1.0]` 边界内，保持宽高不变。
  static ArtworkNormalizedCropRect panCrop(
    ArtworkNormalizedCropRect rect, {
    required double deltaNormX,
    required double deltaNormY,
  }) {
    final maxLeft = math.max(0.0, 1.0 - rect.width);
    final maxTop = math.max(0.0, 1.0 - rect.height);
    return ArtworkNormalizedCropRect(
      left: (rect.left + deltaNormX).clamp(0.0, maxLeft),
      top: (rect.top + deltaNormY).clamp(0.0, maxTop),
      width: rect.width,
      height: rect.height,
    );
  }

  /// 拖拽四角锚点进行严格等比缩放（固定对角顶点并钳制在原图与最小短边范围内）。
  static ArtworkNormalizedCropRect resizeFromCorner(
    ArtworkNormalizedCropRect rect, {
    required ArtworkCropCorner corner,
    required double pointerNormX,
    required double pointerNormY,
    required int imageWidth,
    required int imageHeight,
    required double aspectRatio,
    double minShortSideFraction = 0.14,
  }) {
    final safeW = math.max(1, imageWidth).toDouble();
    final safeH = math.max(1, imageHeight).toDouble();
    final normalizedRatio = aspectRatio * (safeH / safeW);

    late final double anchorX;
    late final double anchorY;
    late final int signX;
    late final int signY;
    late final double availableW;
    late final double availableH;

    switch (corner) {
      case ArtworkCropCorner.topLeft:
        anchorX = rect.right;
        anchorY = rect.bottom;
        signX = -1;
        signY = -1;
        availableW = anchorX;
        availableH = anchorY;
      case ArtworkCropCorner.topRight:
        anchorX = rect.left;
        anchorY = rect.bottom;
        signX = 1;
        signY = -1;
        availableW = 1.0 - anchorX;
        availableH = anchorY;
      case ArtworkCropCorner.bottomLeft:
        anchorX = rect.right;
        anchorY = rect.top;
        signX = -1;
        signY = 1;
        availableW = anchorX;
        availableH = 1.0 - anchorY;
      case ArtworkCropCorner.bottomRight:
        anchorX = rect.left;
        anchorY = rect.top;
        signX = 1;
        signY = 1;
        availableW = 1.0 - anchorX;
        availableH = 1.0 - anchorY;
    }

    final boundMaxW = math.max(
      1e-4,
      math.min(availableW, availableH * normalizedRatio),
    );
    final desiredMinW = normalizedRatio >= 1.0
        ? minShortSideFraction * normalizedRatio
        : minShortSideFraction;
    final minW = math.min(boundMaxW, math.max(0.02, desiredMinW));

    final rawW = math.max(0.0, signX * (pointerNormX - anchorX));
    final rawH = math.max(0.0, signY * (pointerNormY - anchorY));
    final projectedH =
        (rawW * normalizedRatio + rawH) /
        (normalizedRatio * normalizedRatio + 1.0);
    final nextW = (projectedH * normalizedRatio).clamp(minW, boundMaxW);
    final nextH = nextW / normalizedRatio;

    final left = signX > 0 ? anchorX : (anchorX - nextW);
    final top = signY > 0 ? anchorY : (anchorY - nextH);
    return ArtworkNormalizedCropRect(
      left: left.clamp(0.0, 1.0 - nextW),
      top: top.clamp(0.0, 1.0 - nextH),
      width: nextW,
      height: nextH,
    );
  }

  /// 围绕选框中心进行等比缩放（供鼠标滚轮缩放使用），自动钳制不出界。
  static ArtworkNormalizedCropRect zoomAroundCenter(
    ArtworkNormalizedCropRect rect, {
    required double zoomScale,
    required int imageWidth,
    required int imageHeight,
    required double aspectRatio,
    double minShortSideFraction = 0.14,
  }) {
    final safeW = math.max(1, imageWidth).toDouble();
    final safeH = math.max(1, imageHeight).toDouble();
    final normalizedRatio = aspectRatio * (safeH / safeW);

    final globalMaxW = math.min(1.0, normalizedRatio);
    final desiredMinW = normalizedRatio >= 1.0
        ? minShortSideFraction * normalizedRatio
        : minShortSideFraction;
    final minW = math.min(globalMaxW, math.max(0.02, desiredMinW));

    final nextW = (rect.width * zoomScale).clamp(minW, globalMaxW);
    final nextH = (nextW / normalizedRatio).clamp(0.001, 1.0);

    final maxLeft = math.max(0.0, 1.0 - nextW);
    final maxTop = math.max(0.0, 1.0 - nextH);
    final left = (rect.centerX - nextW / 2.0).clamp(0.0, maxLeft);
    final top = (rect.centerY - nextH / 2.0).clamp(0.0, maxTop);

    return ArtworkNormalizedCropRect(
      left: left,
      top: top,
      width: nextW,
      height: nextH,
    );
  }

  /// 将归一化选框精确映射回本地原图真实像素坐标区域。
  static ArtworkSourcePixelRect toSourcePixelRect(
    ArtworkNormalizedCropRect rect, {
    required int imageWidth,
    required int imageHeight,
  }) {
    final safeW = math.max(1, imageWidth);
    final safeH = math.max(1, imageHeight);

    final left = (rect.left * safeW).round().clamp(0, safeW - 1);
    final top = (rect.top * safeH).round().clamp(0, safeH - 1);
    final right = ((rect.right * safeW).round()).clamp(left + 1, safeW);
    final bottom = ((rect.bottom * safeH).round()).clamp(top + 1, safeH);

    return ArtworkSourcePixelRect(
      left: left,
      top: top,
      width: math.max(1, right - left),
      height: math.max(1, bottom - top),
    );
  }

  /// 计算图片在舞台可视区内的 `BoxFit.contain` 居中展示矩形。
  static ArtworkDisplayFrame fitContainDisplayRect({
    required double stageWidth,
    required double stageHeight,
    required int imageWidth,
    required int imageHeight,
  }) {
    final safeStageW = math.max(1.0, stageWidth);
    final safeStageH = math.max(1.0, stageHeight);
    final imgAspect = math.max(1, imageWidth) / math.max(1, imageHeight);
    final stageAspect = safeStageW / safeStageH;

    late final double w;
    late final double h;
    if (imgAspect > stageAspect) {
      w = safeStageW;
      h = safeStageW / imgAspect;
    } else {
      h = safeStageH;
      w = safeStageH * imgAspect;
    }

    return ArtworkDisplayFrame(
      left: (safeStageW - w) / 2.0,
      top: (safeStageH - h) / 2.0,
      width: w,
      height: h,
    );
  }
}
