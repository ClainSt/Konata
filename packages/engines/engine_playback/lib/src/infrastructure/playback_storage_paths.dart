import 'dart:io';

import 'package:konata_contracts/konata_contracts.dart';
import 'package:path/path.dart' as p;

/// 基于 [StorageRootPort] 的播放、字体池与截图便携目录解析助手。
abstract final class PlaybackStoragePaths {
  static final RegExp _invalidPathChars = RegExp(r'[<>:"/\\|?*\x00-\x1F]');
  static final RegExp _safePlainId = RegExp(r'^[a-zA-Z0-9._-]{1,48}$');
  static final RegExp _nonTagChars = RegExp(r'[^a-zA-Z0-9_-]');

  /// 确保并返回便携 `libmpv` 配置目录（`<userdata>/mpv`）。
  static Future<Directory> ensureMpvConfigDir(StorageRootPort storageRoot) async {
    final userdataPath = await storageRoot.ensureUserdataDirPath();
    final dir = Directory(p.join(userdataPath, StoragePathNames.mpvSubdir));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  /// 确保并返回 `libmpv` GPU 着色器编译缓存目录（`<cache>/mpv_shader_cache`）。
  static Future<Directory> ensureMpvShaderCacheDir(
    StorageRootPort storageRoot,
  ) async {
    final cacheRoot = await storageRoot.resolveCacheRootPath();
    final dir = Directory(
      p.join(cacheRoot, StoragePathNames.gpuShaderCacheSubdir),
    );
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  /// 确保并返回 `libmpv` ICC 色彩查找表缓存目录（`<cache>/mpv_icc_cache`）。
  static Future<Directory> ensureMpvIccCacheDir(
    StorageRootPort storageRoot,
  ) async {
    final cacheRoot = await storageRoot.resolveCacheRootPath();
    final dir = Directory(p.join(cacheRoot, StoragePathNames.iccCacheSubdir));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  /// 确保并返回单级字幕字体哈希池目录（`<cache>/font_pool`）。
  static Future<Directory> ensureFontPoolDir(StorageRootPort storageRoot) async {
    final cacheRoot = await storageRoot.resolveCacheRootPath();
    final dir = Directory(p.join(cacheRoot, StoragePathNames.fontPoolSubdir));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  /// 确保并返回云端字体子集化字幕缓存目录（`<cache>/cloud_subset`）。
  static Future<Directory> ensureCloudSubsetDir(
    StorageRootPort storageRoot,
  ) async {
    final cacheRoot = await storageRoot.resolveCacheRootPath();
    final dir = Directory(
      p.join(cacheRoot, StoragePathNames.cloudSubsetSubdir),
    );
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  /// 确保并返回本地影子 `.cue` 暂存目录（`<tmp>/konata_cues`）。
  static Future<Directory> ensureCueStageDir(StorageRootPort storageRoot) async {
    final tmpPath = await storageRoot.ensureTempDirPath();
    final dir = Directory(p.join(tmpPath, 'konata_cues'));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  /// 扫描便携着色器目录（`<appRoot>/shaders` 与 `<userdata>/shaders`）中的 `.glsl` / `.hook` 文件。
  static Future<List<File>> discoverShaderFiles(
    StorageRootPort storageRoot,
  ) async {
    final appRoot = await storageRoot.resolveAppRootPath();
    final userdataPath = await storageRoot.ensureUserdataDirPath();
    final candidateDirs = <Directory>[
      Directory(p.join(appRoot, 'shaders')),
      Directory(p.join(userdataPath, 'shaders')),
    ];
    final seenPaths = <String>{};
    final result = <File>[];
    for (final dir in candidateDirs) {
      if (!dir.existsSync()) {
        continue;
      }
      final files = <File>[];
      for (final entity in dir.listSync(followLinks: false)) {
        if (entity is File) {
          final ext = p.extension(entity.path).toLowerCase();
          if (ext == '.glsl' || ext == '.hook') {
            files.add(entity);
          }
        }
      }
      files.sort((a, b) => a.path.compareTo(b.path));
      for (final file in files) {
        if (seenPaths.add(file.path)) {
          result.add(file);
        }
      }
    }
    return result;
  }

  /// 规范化作品名，过滤 Windows 非法路径字符与尾随句点。
  static String sanitizeWorkTitle(String raw) {
    var cleaned = raw.replaceAll(_invalidPathChars, ' ');
    cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
    while (cleaned.endsWith('.')) {
      cleaned = cleaned.substring(0, cleaned.length - 1).trim();
    }
    if (cleaned.length > 48) {
      cleaned = cleaned.substring(0, 48).trim();
      while (cleaned.endsWith('.')) {
        cleaned = cleaned.substring(0, cleaned.length - 1).trim();
      }
    }
    return cleaned.isEmpty ? '未命名作品' : cleaned;
  }

  /// 将作品 ID 映射为确定性的安全目录后缀标签。
  static String encodeWorkIdTag(String workId) {
    final trimmed = workId.trim();
    if (_safePlainId.hasMatch(trimmed)) {
      return trimmed;
    }
    final prefix = trimmed.replaceAll(_nonTagChars, '');
    final head = prefix.isEmpty
        ? 'w'
        : (prefix.length > 12 ? prefix.substring(0, 12) : prefix);
    var hash = 2166136261;
    for (final unit in trimmed.codeUnits) {
      hash ^= unit;
      hash = (hash * 16777619) & 0xFFFFFFFF;
    }
    final suffix = hash.toRadixString(16).padLeft(8, '0');
    return '$head-$suffix';
  }

  /// 解析当前作品截图目录（`<photos>/work [<tag>]`）。
  static Future<Directory> resolveWorkScreenshotDir(
    StorageRootPort storageRoot,
    String workId,
  ) async {
    final photosRoot = await storageRoot.resolvePhotosDirPath();
    final safeTag = encodeWorkIdTag(workId);
    return Directory(p.join(photosRoot, 'work [$safeTag]'));
  }

  /// 在指定作品截图目录下分配不重名的原画截图文件路径。
  static Future<File> allocateWorkScreenshotFile({
    required Directory workPhotoDirectory,
    required DateTime timestamp,
    String? episodeTag,
  }) async {
    workPhotoDirectory.createSync(recursive: true);
    final stamp =
        '${timestamp.year}'
        '${timestamp.month.toString().padLeft(2, '0')}'
        '${timestamp.day.toString().padLeft(2, '0')}_'
        '${timestamp.hour.toString().padLeft(2, '0')}'
        '${timestamp.minute.toString().padLeft(2, '0')}'
        '${timestamp.second.toString().padLeft(2, '0')}';
    final cleanTag = (episodeTag ?? '')
        .replaceAll(_invalidPathChars, '')
        .replaceAll(RegExp(r'\s+'), '_')
        .trim();
    final baseName = cleanTag.isEmpty
        ? 'konata_$stamp'
        : 'konata_${cleanTag}_$stamp';

    var candidate = File(p.join(workPhotoDirectory.path, '$baseName.png'));
    var seq = 1;
    while (candidate.existsSync()) {
      candidate = File(p.join(workPhotoDirectory.path, '${baseName}_$seq.png'));
      seq += 1;
    }
    return candidate;
  }
}
