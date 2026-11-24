import 'dart:typed_data';

/// 跨平台系统文件与目录选择器抽象端口（由宿主应用壳通过平台插件实现）。
///
/// 业务 Feature 包严禁直接依赖平台文件选择插件，统一经本端口请求目录或文件选取，
/// 便于三端适配与无宿主离线组件测试注入。
abstract interface class FilePickerPort {
  /// 弹出系统目录选择器并返回用户选定的绝对路径；取消时返回空。
  Future<String?> pickDirectory({String? dialogTitle});

  /// 弹出图片文件选择器并返回用户选定的本地图片绝对路径；取消时返回空。
  Future<String?> pickImageFile({String? dialogTitle});

  /// 弹出外挂字幕文件选择器并返回本地绝对路径；取消时返回空。
  Future<String?> pickSubtitleFile({String? dialogTitle});
}

/// 默认空实现（供无宿主单测与占位环境安全兜底）。
final class NoopFilePickerPort implements FilePickerPort {
  /// 创建空文件选择端口。
  const NoopFilePickerPort();

  @override
  Future<String?> pickDirectory({String? dialogTitle}) async => null;

  @override
  Future<String?> pickImageFile({String? dialogTitle}) async => null;

  @override
  Future<String?> pickSubtitleFile({String? dialogTitle}) async => null;
}

/// 跨平台备份归档与诊断导出文件存取端口（由宿主壳实现，供同步备份与设置导出复用）。
abstract interface class BackupFilePort {
  /// 弹出备份归档选择器并返回本地绝对路径；取消时返回空。
  Future<String?> pickBackupFile({
    String? dialogTitle,
    List<String> allowedExtensions = const <String>['konata', 'json'],
  });

  /// 弹出保存文件对话框并写入字节内容，返回实际保存路径；取消时返回空。
  Future<String?> saveFile({
    required String fileName,
    required Uint8List bytes,
    String? dialogTitle,
  });
}

/// 默认空备份文件存取端口。
final class NoopBackupFilePort implements BackupFilePort {
  /// 创建空备份文件存取端口。
  const NoopBackupFilePort();

  @override
  Future<String?> pickBackupFile({
    String? dialogTitle,
    List<String> allowedExtensions = const <String>['konata', 'json'],
  }) async => null;

  @override
  Future<String?> saveFile({
    required String fileName,
    required Uint8List bytes,
    String? dialogTitle,
  }) async => null;
}

/// 跨平台外部链接打开端口（由宿主应用壳实现，供业务页面安全拉起浏览器）。
abstract interface class UrlOpenerPort {
  /// 使用系统默认应用打开目标链接；成功返回真。
  Future<bool> openExternalUrl(Uri uri);
}

/// 默认空链接打开端口。
final class NoopUrlOpenerPort implements UrlOpenerPort {
  /// 创建空链接打开端口。
  const NoopUrlOpenerPort();

  @override
  Future<bool> openExternalUrl(Uri uri) async => false;
}
