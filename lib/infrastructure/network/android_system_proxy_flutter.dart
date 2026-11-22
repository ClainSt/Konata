import 'package:flutter/services.dart';

const MethodChannel _androidNetworkChannel = MethodChannel('konata/network');

/// 通过 Android 平台通道查询当前系统 Wi-Fi HTTP 代理指令。
Future<String?> queryPlatformAndroidSystemProxy(Uri uri) {
  final probeUrl = '${uri.scheme}://${uri.host}/';
  return _androidNetworkChannel
      .invokeMethod<String>('proxy', probeUrl)
      .timeout(const Duration(milliseconds: 600));
}
