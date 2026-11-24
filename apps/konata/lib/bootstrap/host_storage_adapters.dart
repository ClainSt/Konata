import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// 基于 `flutter_secure_storage` 的跨端敏感凭据安全存储实现（实现 [SecureStoragePort]）。
///
/// Windows 端经由本地绿色便携加密插件落盘，Android 端走系统密钥库加密存储，
/// 敏感密码与令牌绝不进入 SQLite 或跨设备同步切片。
final class FlutterSecureStorageAdapter implements SecureStoragePort {
  /// 创建跨端安全存储适配器。
  const FlutterSecureStorageAdapter({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String? value) {
    if (value == null || value.isEmpty) {
      return _storage.delete(key: key);
    }
    return _storage.write(key: key, value: value);
  }

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<Map<String, String>> readAllWithPrefix(String prefix) async {
    final all = await _storage.readAll();
    return <String, String>{
      for (final entry in all.entries)
        if (entry.key.startsWith(prefix)) entry.key: entry.value,
    };
  }
}

/// 基于系统文件选择器插件的跨端目录、文件选取与导出保存端口实现。
final class HostFilePickerAdapter implements FilePickerPort, BackupFilePort {
  /// 创建宿主文件选择器适配器。
  const HostFilePickerAdapter();

  @override
  Future<String?> pickDirectory({String? dialogTitle}) async {
    final uri = await FilePicker.pickDirectory(dialogTitle: dialogTitle);
    if (uri == null) return null;
    if (uri.scheme == 'file') {
      return uri.toFilePath();
    }
    return uri.toString();
  }

  @override
  Future<String?> pickImageFile({String? dialogTitle}) async {
    final picked = await FilePicker.pickFile(
      dialogTitle: dialogTitle,
      type: FileType.image,
    );
    return picked?.path;
  }

  @override
  Future<String?> pickSubtitleFile({String? dialogTitle}) async {
    final picked = await FilePicker.pickFile(
      dialogTitle: dialogTitle,
      type: FileType.custom,
      allowedExtensions: KonataMediaExtensions.subtitleExtensionsNoDot,
    );
    return picked?.path;
  }

  @override
  Future<String?> pickBackupFile({
    String? dialogTitle,
    List<String> allowedExtensions = const <String>['konata', 'json'],
  }) async {
    final picked = await FilePicker.pickFile(
      dialogTitle: dialogTitle,
      type: FileType.custom,
      allowedExtensions: allowedExtensions,
    );
    return picked?.path;
  }

  @override
  Future<String?> saveFile({
    required String fileName,
    required Uint8List bytes,
    String? dialogTitle,
  }) async {
    final outputUri = await FilePicker.saveFile(
      dialogTitle: dialogTitle,
      fileName: fileName,
      bytes: bytes,
    );
    if (outputUri == null) {
      return null;
    }
    if (outputUri.scheme == 'file') {
      final path = outputUri.toFilePath();
      final file = File(path);
      if (!file.existsSync() || file.lengthSync() != bytes.length) {
        await file.writeAsBytes(bytes, flush: true);
      }
      return path;
    }
    return outputUri.toString();
  }
}

/// 基于系统链接拉起插件的跨端外部链接打开端口实现（实现 [UrlOpenerPort]）。
final class HostUrlOpenerAdapter implements UrlOpenerPort {
  /// 创建宿主外部链接打开适配器。
  const HostUrlOpenerAdapter();

  @override
  Future<bool> openExternalUrl(Uri uri) async {
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

/// 构造 Windows 桌面端绿色便携存储根目录端口（严禁写入 C 盘系统用户目录）。
StorageRootPort createWindowsStorageRoot({String? laneOverride}) {
  return PortableStorageRootService(laneOverride: laneOverride);
}

/// 构造 Android 端应用沙箱存储根目录端口（委托应用支持目录）。
Future<StorageRootPort> createAndroidStorageRoot() async {
  final supportDir = await getApplicationSupportDirectory();
  return PortableStorageRootService(overrideRootPath: supportDir.path);
}
