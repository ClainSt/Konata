import 'dart:io';

import 'package:flutter/services.dart';

/// 移动计量网络（蜂窝流量 / 按量计费热点）实时探测器。
class MeteredNetworkDetector {
  /// 创建计量网络探测器。
  const MeteredNetworkDetector({this.overrideProbe});

  static const MethodChannel _networkChannel = MethodChannel(
    'ccplayer/network',
  );

  /// 可选测试注入探针。
  final Future<bool> Function()? overrideProbe;

  /// 查询当前活动网络是否属于移动计量网络（桌面端固定返回 `false`，Android 查系统 `ConnectivityManager`）。
  Future<bool> isMeteredMobileNetwork() async {
    final override = overrideProbe;
    if (override != null) {
      return override();
    }
    if (!Platform.isAndroid) {
      return false;
    }
    try {
      final metered = await _networkChannel.invokeMethod<bool>(
        'isMeteredNetwork',
      );
      return metered ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
