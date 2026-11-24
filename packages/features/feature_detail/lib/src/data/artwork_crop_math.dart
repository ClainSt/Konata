import 'dart:math' as math;

/// 裁切选框四角拖拽锚点方位。
enum ArtworkCropCorner {
  /// 左上角。
  topLeft,

  /// 右上角。
  topRight,

  /// 左下角。
  bottomLeft,

  /// 右下角。
  bottomRight,
}

/// 归一化至原图宽高的裁切选框 `[0.0, 1.0]`，彻底与预览控件像素尺寸解耦。
class ArtworkNormalizedCropRect {
  /// 创建归一化裁切选框。
  const ArtworkNormalizedCropRect({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  /// 左边界比例（`0.0 ~ 1.0`）。
  final double left;

  /// 上边界比例（`0.0 ~ 1.0`）。
  final double top;

  /// 宽度比例（`0.0 ~ 1.0`）。
  final double width;

  /// 高度比例（`0.0 ~ 1.0`）。
  final double height;

  /// 右边界比例。
  double get right => left + width;

  /// 下边界比例。
  double get bottom => top + height;

  /// 中心 X 比例。
  double get centerX => left + width * 0.5;

  /// 中心 Y 比例。
  double get centerY => top + height * 0.5;
}

/// 映射回原始图片真实像素坐标系的整数裁切矩形。
class ArtworkSourcePixelRect {
  /// 创建原图像素级裁切区域。
  const ArtworkSourcePixelRect({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  /// 左上角 X 像素坐标。
  final int left;

  /// 左上角 Y 像素坐标。
  final int top;

  /// 裁切像素宽度。
  final int width;

  /// 裁切像素高度。
  final int height;
}

/// 预览画布内图片的等比适配绘制矩形。
class ArtworkDisplayRect {
  /// 创建等比适配矩形。
  const ArtworkDisplayRect({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  /// 左偏移。
  final double left;

  /// 上偏移。
  final double top;

  /// 绘制宽度。
  final double width;

  /// 绘制高度。
  final double height;
}

/// 作品自定义封面（`2:3`）与背景图（`16:9`）固定比例框选裁切几何引擎。
///
/// 全程采用归一化坐标与像素级边界钳制，确保画框拖拽、四角等比缩放与滚轮缩放绝不越界、绝不比例漂移。
abstract final class ArtworkCropMath {
  /// 作品封面标准锁定宽高比（`2 : 3`）。
  static const double posterAspectRatio = 2.0 / 3.0;

  /// 作品背景图标准锁定宽高比（`16 : 9`）。
  static const double backdropAspectRatio = 16.0 / 9.0;

  /// 裁切框允许的最小相对边长下限（至少占原图窄边的 18%）。
  static const double minNormalizedExtent = 0.18;

  /// 绝对最小有效像素边长下限，防止极小图过度缩小产生 0px 裁切框。
  static const double minPixelExtent = 48.0;

  /// 根据舞台可用空间计算图片无损完整显示（contain）的位置与尺寸。
  static ArtworkDisplayRect fitContainDisplayRect({
    required double stageWidth,
    required double stageHeight,
    required int imageWidth,
    required int imageHeight,
  }) {
    if (stageWidth <= 0 ||
        stageHeight <= 0 ||
        imageWidth <= 0 ||
        imageHeight <= 0) {
      return const ArtworkDisplayRect(left: 0, top: 0, width: 0, height: 0);
    }
    final imageRatio = imageWidth / imageHeight;
    final stageRatio = stageWidth / stageHeight;
    final double w;
    final double h;
    if (imageRatio > stageRatio) {
      w = stageWidth;
      h = stageWidth / imageRatio;
    } else {
      h = stageHeight;
      w = stageHeight * imageRatio;
    }
    return ArtworkDisplayRect(
      left: (stageWidth - w) * 0.5,
      top: (stageHeight - h) * 0.5,
      width: w,
      height: h,
    );
  }

  /// 生成初始最大居中框选区（严格按目标比例最大化撑满原图，且背景/海报优先居中保护）。
  static ArtworkNormalizedCropRect initialMaxCenteredRect({
    required int imageWidth,
    required int imageHeight,
    required double aspectRatio,
  }) {
    final safeW = math.max(1, imageWidth);
    final safeH = math.max(1, imageHeight);
    final normRatio = aspectRatio / (safeW / safeH);
    final double w;
    final double h;
    if (normRatio <= 1.0) {
      h = 1.0;
      w = normRatio;
    } else {
      w = 1.0;
      h = 1.0 / normRatio;
    }
    return ArtworkNormalizedCropRect(
      left: (1.0 - w) * 0.5,
      top: (1.0 - h) * 0.5,
      width: w,
      height: h,
    );
  }

  /// 在保持尺寸与比例完全不变的前提下平移选框，严格钳制在原图 `[0, 1]` 范围内。
  static ArtworkNormalizedCropRect moveRect(
    ArtworkNormalizedCropRect current, {
    required double deltaNormX,
    required double deltaNormY,
  }) {
    final w = current.width.clamp(0.01, 1.0);
    final h = current.height.clamp(0.01, 1.0);
    final nextLeft = (current.left + deltaNormX).clamp(0.0, 1.0 - w);
    final nextTop = (current.top + deltaNormY).clamp(0.0, 1.0 - h);
    return ArtworkNormalizedCropRect(
      left: nextLeft,
      top: nextTop,
      width: w,
      height: h,
    );
  }

  /// 拖拽四角锚点进行固定对角点的等比缩放，超出画幅边界或下限时平滑止步且绝不漂移比例。
  static ArtworkNormalizedCropRect resizeFromCorner(
    ArtworkNormalizedCropRect current, {
    required ArtworkCropCorner corner,
    required double pointerNormX,
    required double pointerNormY,
    required int imageWidth,
    required int imageHeight,
    required double aspectRatio,
  }) {
    final safeW = math.max(1, imageWidth);
    final safeH = math.max(1, imageHeight);
    final normRatio = aspectRatio / (safeW / safeH);
    final bounds = _computeNormWidthBounds(
      imageWidth: safeW,
      imageHeight: safeH,
      normRatio: normRatio,
    );

    final double anchorX;
    final double anchorY;
    final int signX;
    final int signY;
    switch (corner) {
      case ArtworkCropCorner.topLeft:
        anchorX = current.right;
        anchorY = current.bottom;
        signX = -1;
        signY = -1;
      case ArtworkCropCorner.topRight:
        anchorX = current.left;
        anchorY = current.bottom;
        signX = 1;
        signY = -1;
      case ArtworkCropCorner.bottomLeft:
        anchorX = current.right;
        anchorY = current.top;
        signX = -1;
        signY = 1;
      case ArtworkCropCorner.bottomRight:
        anchorX = current.left;
        anchorY = current.top;
        signX = 1;
        signY = 1;
    }

    final maxAvailW = signX < 0 ? anchorX : (1.0 - anchorX);
    final maxAvailH = signY < 0 ? anchorY : (1.0 - anchorY);
    final maxAllowedW = math.min(maxAvailW, maxAvailH * normRatio);
    final minAllowedW = math.min(bounds.minW, maxAllowedW);

    final rawW = signX < 0 ? (anchorX - pointerNormX) : (pointerNormX - anchorX);
    final rawH = signY < 0 ? (anchorY - pointerNormY) : (pointerNormY - anchorY);
    final candFromX = rawW;
    final candFromY = rawH * normRatio;
    final desiredW =
        (candFromX - current.width).abs() >= (candFromY - current.width).abs()
            ? candFromX
            : candFromY;

    final clampedW = desiredW
        .clamp(minAllowedW, math.max(minAllowedW, maxAllowedW))
        .toDouble();
    final clampedH = clampedW / normRatio;

    final nextLeft = signX < 0 ? (anchorX - clampedW) : anchorX;
    final nextTop = signY < 0 ? (anchorY - clampedH) : anchorY;

    return ArtworkNormalizedCropRect(
      left: nextLeft.clamp(0.0, 1.0 - clampedW).toDouble(),
      top: nextTop.clamp(0.0, 1.0 - clampedH).toDouble(),
      width: clampedW,
      height: clampedH,
    );
  }

  /// 围绕当前选框中心按缩放系数缩放（用于滚轮快捷放大或缩小选框）。
  static ArtworkNormalizedCropRect zoomAroundCenter(
    ArtworkNormalizedCropRect current, {
    required double zoomScale,
    required int imageWidth,
    required int imageHeight,
    required double aspectRatio,
  }) {
    final safeW = math.max(1, imageWidth);
    final safeH = math.max(1, imageHeight);
    final normRatio = aspectRatio / (safeW / safeH);
    final bounds = _computeNormWidthBounds(
      imageWidth: safeW,
      imageHeight: safeH,
      normRatio: normRatio,
    );
    final nextW = (current.width * zoomScale)
        .clamp(bounds.minW, bounds.maxW)
        .toDouble();
    final nextH = nextW / normRatio;
    final nextLeft = (current.centerX - nextW * 0.5).clamp(0.0, 1.0 - nextW);
    final nextTop = (current.centerY - nextH * 0.5).clamp(0.0, 1.0 - nextH);
    return ArtworkNormalizedCropRect(
      left: nextLeft,
      top: nextTop,
      width: nextW,
      height: nextH,
    );
  }

  /// 将归一化选框换算为原图真实像素整框区域，严格对齐目标宽高比并防越界。
  static ArtworkSourcePixelRect toSourcePixelRect(
    ArtworkNormalizedCropRect rect, {
    required int imageWidth,
    required int imageHeight,
  }) {
    final safeW = math.max(1, imageWidth);
    final safeH = math.max(1, imageHeight);
    final pxW = (rect.width * safeW).round().clamp(1, safeW);
    final pxH = (rect.height * safeH).round().clamp(1, safeH);
    final pxLeft = (rect.left * safeW).round().clamp(0, safeW - pxW);
    final pxTop = (rect.top * safeH).round().clamp(0, safeH - pxH);
    return ArtworkSourcePixelRect(
      left: pxLeft,
      top: pxTop,
      width: pxW,
      height: pxH,
    );
  }

  static ({double minW, double maxW}) _computeNormWidthBounds({
    required int imageWidth,
    required int imageHeight,
    required double normRatio,
  }) {
    final maxW = math.min(1.0, normRatio);
    final minFromRatio = math.min(
      minNormalizedExtent,
      minNormalizedExtent * normRatio,
    );
    final minFromPixels = math.max(
      minPixelExtent / imageWidth,
      (minPixelExtent / imageHeight) * normRatio,
    );
    final minW = math.min(maxW, math.max(minFromRatio, minFromPixels));
    return (minW: minW, maxW: maxW);
  }
}
