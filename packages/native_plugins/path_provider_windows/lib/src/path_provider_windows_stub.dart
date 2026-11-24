// 遵循 Flutter 官方组件 BSD 开源许可协议（详见随包 LICENSE 文件）。

import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// 为多端公共包提供的空桩实现，仅用于满足编译期条件导出解析。
///
class PathProviderWindows extends PathProviderPlatform {
  String get executablePath => '';

  /// 可选注入的车道覆盖标识，保持与真实实现签名一致。
  final String? laneOverride;

  /// 运行期禁止实例化该占位空桩类。
  PathProviderWindows({this.laneOverride}) : assert(false);

  /// 向全局平台通道注册当前 Windows 路径提供实现。
  static void registerWith() {
    PathProviderPlatform.instance = PathProviderWindows();
  }

  /// 版本查询器空桩占位定义。
  VersionInfoQuerier versionInfoQuerier = VersionInfoQuerier();

  /// 保持与 `PathProviderWindows` 方法签名一致，以免分析器或测试桩报错。
  Future<String?> getPath(String folderID) async => '';
}

/// 为分析器提供稳定条件导出桩字段。
class VersionInfoQuerier {}
