import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'package:konata_storage/konata_storage.dart';
import 'package:path/path.dart' as p;

import '../subtitles/subtitle_font_pool_manager.dart';

/// Android 便携 `mpv` 配置目录 CJK 兜底字体准备助手（纯 Dart，零 `flutter/services` 依赖）。
abstract final class AndroidCjkFontHelper {
  static const String _bundledFallbackCjkFontAsset =
      'assets/fonts/NotoSansCJKsc-VF.ttf';
  static const String _bundledFallbackFontFileName = 'KonataFallbackCJK.ttf';

  /// 为 Android 端便携 `mpv` 配置目录准备 `fonts/` 与 `subfont.ttf` 兜底字体。
  ///
  /// [assetLoaderOverride] 由外层宿主按需注入资源读取回调，避免纯 Dart 引擎直接耦合 `rootBundle`。
  static Future<void> preparePortableCjkFontSymlinks(
    Directory mpvConfigDir, {
    bool? isAndroidOverride,
    List<Directory>? systemFontRootsOverride,
    Future<ByteData?> Function(String assetKey)? assetLoaderOverride,
  }) async {
    final isAndroid = isAndroidOverride ?? Platform.isAndroid;
    if (!isAndroid) {
      return;
    }
    final fontsDir = Directory(p.join(mpvConfigDir.path, 'fonts'));
    if (!fontsDir.existsSync()) {
      fontsDir.createSync(recursive: true);
    }

    await _purgeStaleInvalidFontsInDir(fontsDir);

    final verifiedFonts =
        await SubtitleFontPoolManager.discoverVerifiedSystemCjkFonts(
          searchRootsOverride: systemFontRootsOverride,
        );

    final File? preferredDefaultFont = verifiedFonts.isNotEmpty
        ? verifiedFonts.first
        : null;
    for (final source in verifiedFonts) {
      final targetPath = p.join(fontsDir.path, p.basename(source.path));
      if (source == preferredDefaultFont) {
        await _ensureRegularVerifiedCjkFontCopy(
          source: source,
          targetPath: targetPath,
        );
      } else {
        await _linkOrCopyReadableFont(
          source: source,
          targetPath: targetPath,
          allowCopyFallback: false,
        );
      }
    }

    final subfontPath = p.join(mpvConfigDir.path, 'subfont.ttf');
    var subfontReady = await _isRegularVerifiedCjkFont(subfontPath);
    if (!subfontReady) {
      await _deleteFileOrLink(subfontPath);
    }
    if (!subfontReady && preferredDefaultFont != null) {
      subfontReady = await _ensureRegularVerifiedCjkFontCopy(
        source: preferredDefaultFont,
        targetPath: subfontPath,
      );
    }
    if (!subfontReady && assetLoaderOverride != null) {
      try {
        final data = await assetLoaderOverride(_bundledFallbackCjkFontAsset);
        if (data == null) {
          return;
        }
        final bytes = data.buffer.asUint8List(
          data.offsetInBytes,
          data.lengthInBytes,
        );
        if (bytes.length > 1024) {
          await _writeFontBytesAtomically(subfontPath, bytes);
          final dirCopyPath = p.join(
            fontsDir.path,
            _bundledFallbackFontFileName,
          );
          if (!await _isRegularNonEmptyFont(dirCopyPath)) {
            await _writeFontBytesAtomically(dirCopyPath, bytes);
          }
        }
      } catch (error) {
        developer.log(
          '内置 CJK 兜底字体写入失败',
          name: 'konata.android_cjk_font_helper',
          error: error,
        );
      }
    }
  }

  static Future<void> _purgeStaleInvalidFontsInDir(Directory fontsDir) async {
    try {
      for (final entity in fontsDir.listSync(followLinks: false)) {
        final base = p.basename(entity.path);
        if (base == _bundledFallbackFontFileName) {
          if (entity is Link || !await _isRegularNonEmptyFont(entity.path)) {
            await _deleteFileOrLink(entity.path);
          }
          continue;
        }
        final allowedName =
            SubtitleFontPoolManager.isAllowedCjkFallbackFontName(base);
        if (!allowedName) {
          await _deleteFileOrLink(entity.path);
          continue;
        }
        if (!await SubtitleFontPoolManager.hasVerifiedCjkGlyph(
          File(entity.path),
        )) {
          await _deleteFileOrLink(entity.path);
        }
      }
    } catch (error) {
      developer.log(
        '清理无效兜底字体缓存时遇到可恢复异常',
        name: 'konata.android_cjk_font_helper',
        error: error,
      );
    }
  }

  static Future<void> _deleteFileOrLink(String path) async {
    try {
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type == FileSystemEntityType.link) {
        await Link(path).delete();
      } else if (type == FileSystemEntityType.file) {
        await File(path).delete();
      }
    } catch (error) {
      developer.log(
        '删除失效字体缓存文件时遇到可恢复异常',
        name: 'konata.android_cjk_font_helper',
        error: error,
      );
    }
  }

  static Future<bool> _isRegularNonEmptyFont(String path) async {
    try {
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type != FileSystemEntityType.file) {
        return false;
      }
      return File(path).lengthSync() > 1024;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _isRegularVerifiedCjkFont(String path) async {
    try {
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type != FileSystemEntityType.file) {
        return false;
      }
      final file = File(path);
      if (file.lengthSync() <= 12) {
        return false;
      }
      return await SubtitleFontPoolManager.hasVerifiedCjkGlyph(file);
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _ensureRegularVerifiedCjkFontCopy({
    required File source,
    required String targetPath,
  }) async {
    if (await _isRegularVerifiedCjkFont(targetPath)) {
      return true;
    }
    await _deleteFileOrLink(targetPath);
    final partPath =
        '$targetPath.part.${DateTime.now().microsecondsSinceEpoch}';
    final partFile = File(partPath);
    try {
      await source.copy(partPath);
      final expectedLen = partFile.lengthSync();
      await AtomicFileWriter.replaceFile(
        partFile,
        File(targetPath),
        expectedLength: expectedLen,
      );
      return await _isRegularVerifiedCjkFont(targetPath);
    } catch (error) {
      if (partFile.existsSync()) {
        await partFile.delete().catchError((_) => partFile);
      }
      developer.log(
        '原子拷贝系统主 CJK 兜底字体失败',
        name: 'konata.android_cjk_font_helper',
        error: error,
      );
      return false;
    }
  }

  static Future<void> _writeFontBytesAtomically(
    String targetPath,
    Uint8List bytes,
  ) async {
    await _deleteFileOrLink(targetPath);
    final partPath =
        '$targetPath.part.${DateTime.now().microsecondsSinceEpoch}';
    final partFile = File(partPath);
    try {
      await partFile.writeAsBytes(bytes, flush: true);
      await AtomicFileWriter.replaceFile(
        partFile,
        File(targetPath),
        expectedLength: bytes.length,
      );
    } catch (error) {
      if (partFile.existsSync()) {
        await partFile.delete().catchError((_) => partFile);
      }
      rethrow;
    }
  }

  static Future<bool> _linkOrCopyReadableFont({
    required File source,
    required String targetPath,
    bool allowCopyFallback = false,
  }) async {
    if (await SubtitleFontPoolManager.hasVerifiedCjkGlyph(File(targetPath))) {
      return true;
    }
    await _deleteFileOrLink(targetPath);
    try {
      await Link(targetPath).create(source.path);
      if (await SubtitleFontPoolManager.hasVerifiedCjkGlyph(File(targetPath))) {
        return true;
      }
    } catch (error) {
      developer.log(
        '符号链接系统字体受限，按需降级拷贝',
        name: 'konata.android_cjk_font_helper',
        error: error,
      );
    }
    if (!allowCopyFallback) {
      return false;
    }
    return _ensureRegularVerifiedCjkFontCopy(
      source: source,
      targetPath: targetPath,
    );
  }
}
