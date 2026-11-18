import 'dart:math' as math;
import 'dart:ui' show DisplayFeature, DisplayFeatureType;

import 'package:flutter/widgets.dart';

/// 全屏视频播放时的屏幕摄像头挖孔对称黑边避让计算工具。
///
/// 规则：
/// - 若挖孔位于横屏左侧或右侧，左右两侧对称裁掉最大挖孔宽度并填充纯黑边；
/// - 若挖孔位于横屏正上方或正下方，上下两侧对称裁掉最大挖孔高度并填充纯黑边；
/// - 确保视频有效画面完整无物理挖孔遮挡且相对于整块物理屏幕严格几何居中。
abstract final class VideoCutoutSymmetry {
  /// 根据视口尺寸、`viewPadding` 与 `DisplayFeature` 列表计算对称黑边内边距。
  static EdgeInsets resolveSymmetricCutoutPadding({
    required Size viewportSize,
    required EdgeInsets viewPadding,
    List<DisplayFeature> displayFeatures = const <DisplayFeature>[],
    bool systemBarsHidden = true,
  }) {
    if (viewportSize.width <= 0 || viewportSize.height <= 0) {
      return EdgeInsets.zero;
    }

    var leftCut = 0.0;
    var rightCut = 0.0;
    var topCut = 0.0;
    var bottomCut = 0.0;

    for (final feature in displayFeatures) {
      if (feature.type != DisplayFeatureType.cutout) continue;
      final r = feature.bounds;
      if (r.isEmpty) continue;
      final nearLeft = r.left <= 2.0 && r.right < viewportSize.width * 0.25;
      final nearRight =
          r.right >= viewportSize.width - 2.0 &&
          r.left > viewportSize.width * 0.75;
      final nearTop = r.top <= 2.0 && r.bottom < viewportSize.height * 0.25;
      final nearBottom =
          r.bottom >= viewportSize.height - 2.0 &&
          r.top > viewportSize.height * 0.75;

      // 当角落挖孔同时贴靠两条边时，归入侵入比例更浅的主边缘（如手机横屏归入左/右短边，平板横屏顶部居中挖孔归入顶边）。
      if ((nearLeft || nearRight) && !(nearTop && !nearLeft && !nearRight)) {
        if (nearLeft && (!nearTop || r.right <= r.bottom)) {
          leftCut = math.max(leftCut, r.right);
          continue;
        }
        if (nearRight &&
            (!nearTop || (viewportSize.width - r.left) <= r.bottom)) {
          rightCut = math.max(rightCut, viewportSize.width - r.left);
          continue;
        }
      }
      if (nearTop) {
        topCut = math.max(topCut, r.bottom);
      } else if (nearBottom) {
        bottomCut = math.max(bottomCut, viewportSize.height - r.top);
      } else if (nearLeft) {
        leftCut = math.max(leftCut, r.right);
      } else if (nearRight) {
        rightCut = math.max(rightCut, viewportSize.width - r.left);
      }
    }

    // 兼容仅通过 WindowInsets.displayCutout -> viewPadding 上报挖孔深度的 ROM（如部分 HyperOS / MIUI 机型）。
    if (systemBarsHidden) {
      leftCut = math.max(leftCut, viewPadding.left);
      rightCut = math.max(rightCut, viewPadding.right);
      topCut = math.max(topCut, viewPadding.top);
      bottomCut = math.max(bottomCut, viewPadding.bottom);
    } else {
      leftCut = math.max(leftCut, viewPadding.left);
      rightCut = math.max(rightCut, viewPadding.right);
    }

    final symHorizontal = math.max(leftCut, rightCut);
    final symVertical = math.max(topCut, bottomCut);

    return EdgeInsets.symmetric(
      horizontal: symHorizontal,
      vertical: symVertical,
    );
  }
}
