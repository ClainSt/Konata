/// 视频画面比例覆写模式。
enum VideoAspectMode {
  /// 保持媒体文件原始宽高比并黑边居中。
  auto('原始比例'),

  /// 等比放大裁切以铺满视口。
  cover('裁切铺满'),

  /// 忽略原始比例拉伸铺满视口。
  stretch('拉伸满屏'),

  /// 强制按 `16:9` 宽屏比例显示。
  ratio16x9('16:9'),

  /// 强制按 `4:3` 经典比例显示。
  ratio4x3('4:3');

  const VideoAspectMode(this.label);

  /// 界面展示名称。
  final String label;
}

/// Android 画中画窗口宽高比钳制工具。
abstract final class PipAspectRatioPolicy {
  /// Android 系统允许的最小画中画宽高比。
  static const double minRatio = 0.42;

  /// Android 系统允许的最大画中画宽高比。
  static const double maxRatio = 2.39;

  /// 根据视频帧宽高计算钳制在 `[0.42, 2.39]` 区间内的有理数分子与分母。
  static ({int numerator, int denominator, double ratio}) clampRational(
    int videoWidth,
    int videoHeight,
  ) {
    final raw = (videoWidth > 0 && videoHeight > 0)
        ? videoWidth / videoHeight
        : 16.0 / 9.0;
    final clamped = raw.clamp(minRatio, maxRatio).toDouble();
    const scale = 1000;
    final numerator = (clamped * scale).round().clamp(420, 2390);
    return (numerator: numerator, denominator: scale, ratio: clamped);
  }
}
