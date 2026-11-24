import 'dart:io';

import 'package:flutter/foundation.dart';

/// 跨端 UI 形态探测辅助工具（兼容真实设备与测试期 `debugDefaultTargetPlatformOverride` 覆写）。
abstract final class KonataUiPlatform {
  /// 当前是否运行在 Android 触屏环境（真实 Android 或单测覆写为 Android）。
  static bool get isAndroid {
    if (kIsWeb) return false;
    final override = debugDefaultTargetPlatformOverride;
    if (override != null) {
      return override == TargetPlatform.android;
    }
    return Platform.isAndroid;
  }

  /// 当前是否运行在 Windows 桌面环境（真实 Windows 且未被测试覆写为其它平台）。
  static bool get isWindows {
    if (kIsWeb) return false;
    final override = debugDefaultTargetPlatformOverride;
    if (override != null) {
      return override == TargetPlatform.windows;
    }
    return Platform.isWindows;
  }
}
