// 遵循 Flutter 官方组件 BSD 开源许可协议（详见随包 LICENSE 文件）。

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'folders.dart';
import 'guid.dart';
import 'win32_wrappers.dart';
import 'portable_data.dart';

/// `VersionInfo` 资源键中使用的 `en-US` 语言代码常量。
@visibleForTesting
const String languageEn = '0409';

/// `VersionInfo` 资源键中使用的 `CP1252` 代码页编码常量。
@visibleForTesting
const String encodingCP1252 = '04e4';

/// `VersionInfo` 资源键中使用的 Unicode 编码常量。
@visibleForTesting
const String encodingUnicode = '04b0';

/// 封装 Win32 `VerQueryValue` 版本资源查询调用，便于测试期注入模拟元数据。
///
@visibleForTesting
class VersionInfoQuerier {
  /// 查询指定语言与编码区段下 `[versionInfo]` 中 `[key]` 对应的字符串值（缺失返回空）。
  ///
  String? getStringValue(
    Pointer<Uint8>? versionInfo,
    String key, {
    required String language,
    required String encoding,
  }) {
    assert(language.isNotEmpty);
    assert(encoding.isNotEmpty);
    if (versionInfo == null) {
      return null;
    }
    final Pointer<Utf16> keyPath =
        '\\StringFileInfo\\$language$encoding\\$key'.toNativeUtf16();
    final Pointer<UINT> length = calloc<UINT>();
    final Pointer<Pointer<Utf16>> valueAddress = calloc<Pointer<Utf16>>();
    try {
      if (VerQueryValue(versionInfo, keyPath, valueAddress, length) == 0) {
        return null;
      }
      return valueAddress.value.toDartString();
    } finally {
      calloc.free(keyPath);
      calloc.free(length);
      calloc.free(valueAddress);
    }
  }
}

/// `[PathProviderPlatform]` 的 Windows 平台实现（基于 `package:path_provider` 与便携根目录）。
///
class PathProviderWindows extends PathProviderPlatform {
  String get executablePath => Platform.resolvedExecutable;
  static final _portableData = <String, Future<Directory>>{};

  Future<Directory> _supportDirectory() {
    final target = path.join(path.dirname(executablePath), 'userdata');
    return _portableData.putIfAbsent(target, () async {
      final directory = Directory(target);
      Directory? legacy;
      if (!await directory.exists()) {
        final base = await getPath(WindowsKnownFolder.RoamingAppData);
        if (base != null) {
          legacy =
              Directory(path.join(base, _getApplicationSpecificSubdirectory()));
        }
      }
      return preparePortableData(directory, legacy);
    });
  }

  /// 向全局平台通道注册当前 Windows 路径提供实现。
  static void registerWith() {
    PathProviderPlatform.instance = PathProviderWindows();
  }

  /// 用于执行版本资源查询的底层适配器实例。
  @visibleForTesting
  VersionInfoQuerier versionInfoQuerier = VersionInfoQuerier();

  /// 返回 Windows 临时目录（一般对应 `TMP` 环境变量）。
  @override
  Future<String?> getTemporaryPath() async {
    final directory =
        Directory(path.join(path.dirname(executablePath), 'cache', 'tmp'));
    await directory.create(recursive: true);
    return directory.path;
  }

  @override
  Future<String?> getApplicationSupportPath() async =>
      (await _supportDirectory()).path;

  @override
  Future<String?> getApplicationDocumentsPath() =>
      getPath(WindowsKnownFolder.Documents);

  @override
  Future<String?> getApplicationCachePath() async {
    final directory =
        Directory(path.join(path.dirname(executablePath), 'cache'));
    await directory.create(recursive: true);
    return directory.path;
  }

  @override
  Future<String?> getDownloadsPath() => getPath(WindowsKnownFolder.Downloads);

  /// 根据 `[WindowsKnownFolder]` 提供的 `GUID` 查询对应 Windows 系统目录。
  ///
  Future<String?> getPath(String folderID) {
    final Pointer<Pointer<Utf16>> pathPtrPtr = calloc<Pointer<Utf16>>();
    final Pointer<GUID> knownFolderID = calloc<GUID>()..ref.parse(folderID);

    try {
      final int hr = SHGetKnownFolderPath(
        knownFolderID,
        KF_FLAG_DEFAULT,
        NULL,
        pathPtrPtr,
      );

      if (FAILED(hr)) {
        if (hr == E_INVALIDARG || hr == E_FAIL) {
          throw _createWin32Exception(hr);
        }
        return Future<String?>.value();
      }

      final String path = pathPtrPtr.value.toDartString();
      return Future<String>.value(path);
    } finally {
      calloc.free(pathPtrPtr);
      calloc.free(knownFolderID);
    }
  }

  String? _getStringValue(Pointer<Uint8>? infoBuffer, String key) =>
      versionInfoQuerier.getStringValue(infoBuffer, key,
          language: languageEn, encoding: encodingCP1252) ??
      versionInfoQuerier.getStringValue(infoBuffer, key,
          language: languageEn, encoding: encodingUnicode);

  /// 生成追加于系统应用数据根目录之后的相对子路径（通常为 `厂商\产品名\`）；
  /// 读取可执行文件 `VERSIONINFO` 资源并缺省回落至可执行文件名称。
  ///
  String _getApplicationSpecificSubdirectory() {
    String? companyName;
    String? productName;

    final Pointer<Utf16> moduleNameBuffer =
        calloc<WCHAR>(MAX_PATH + 1).cast<Utf16>();
    final Pointer<DWORD> unused = calloc<DWORD>();
    Pointer<BYTE>? infoBuffer;
    try {
      // 查询当前可执行模块完整路径名。
      final int moduleNameLength =
          GetModuleFileName(0, moduleNameBuffer, MAX_PATH);
      if (moduleNameLength == 0) {
        final int error = GetLastError();
        throw _createWin32Exception(error);
      }

      // 基于模块路径加载 `VERSIONINFO` 资源块。
      final int infoSize = GetFileVersionInfoSize(moduleNameBuffer, unused);
      if (infoSize != 0) {
        infoBuffer = calloc<BYTE>(infoSize);
        if (GetFileVersionInfo(moduleNameBuffer, 0, infoSize, infoBuffer) ==
            0) {
          calloc.free(infoBuffer);
          infoBuffer = null;
        }
      }
      companyName =
          _sanitizedDirectoryName(_getStringValue(infoBuffer, 'CompanyName'));
      productName =
          _sanitizedDirectoryName(_getStringValue(infoBuffer, 'ProductName'));

      // 若版本资源缺少产品名，则回退采用可执行文件名（不含扩展名）。
      productName ??=
          path.basenameWithoutExtension(moduleNameBuffer.toDartString());

      return companyName != null
          ? path.join(companyName, productName)
          : productName;
    } finally {
      calloc.free(moduleNameBuffer);
      calloc.free(unused);
      if (infoBuffer != null) {
        calloc.free(infoBuffer);
      }
    }
  }

  /// 清洗 `[rawString]` 使之符合 Windows 合法目录名规范，全清理为空时返回 `null`。
  ///
  String? _sanitizedDirectoryName(String? rawString) {
    if (rawString == null) {
      return null;
    }
    String sanitized = rawString
        // 替换系统目录名禁止字符。
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        // 去除末尾空白字符。
        .trimRight()
        // 确保目录名不以点号 `.` 结尾。
        .replaceAll(RegExp(r'[.]+$'), '');
    const int kMaxComponentLength = 255;
    if (sanitized.length > kMaxComponentLength) {
      sanitized = sanitized.substring(0, kMaxComponentLength);
    }
    return sanitized.isEmpty ? null : sanitized;
  }
}

Exception _createWin32Exception(int errorCode) {
  return PlatformException(
      code: 'Win32 Error',
      message: 'Error code 0x${errorCode.toRadixString(16)}');
}
