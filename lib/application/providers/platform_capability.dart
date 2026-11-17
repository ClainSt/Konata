import 'dart:io';

import 'package:flutter/foundation.dart';

/// 跨端平台能力边界判定入口，兼容真实设备与桌面端单测默认目标平台覆写。
abstract final class KonataPlatform {
  /// 当前是否运行在 Android 触屏环境（真实 Android 系统，或测试显式覆写为 Android）。
  static bool get isAndroid {
    if (kIsWeb) return false;
    final override = debugDefaultTargetPlatformOverride;
    if (override != null) {
      return override == TargetPlatform.android;
    }
    return Platform.isAndroid;
  }

  /// 当前是否运行在 Windows 桌面环境（真实 Windows 系统且未被测试显式覆写为其他平台）。
  static bool get isWindows {
    if (kIsWeb) return false;
    final override = debugDefaultTargetPlatformOverride;
    if (override != null) {
      return override == TargetPlatform.windows;
    }
    return Platform.isWindows;
  }
}
