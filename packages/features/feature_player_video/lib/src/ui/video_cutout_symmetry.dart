import 'dart:math' as math;
import 'dart:ui' show DisplayFeature, DisplayFeatureType;

import 'package:flutter/widgets.dart';

/// 全屏视频播放时的屏幕异形屏或摄像头开孔对称黑边避让计算器。
abstract final class VideoCutoutSymmetry {
  /// 根据视口尺寸、安全边距与显示特征信息计算左右及上下对称安全内边距。
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
