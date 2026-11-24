import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:path/path.dart' as p;

/// 作品本机艺术图目录管理端口（用于在刮削改名、多版本归并与删作时同步整理 `photos/`）。
abstract interface class WorkArtworkStoragePort {
  /// 当作品标题修改时，同步将既有的作品图片文件夹重命名为新标题目录。
  Future<void> renameWorkFolderIfNeeded(String workId, String newTitle);

  /// 合并或迁移两部作品时，将源作品名下全部已缓存图片合并迁入目标作品文件夹并清理源目录。
  Future<void> mergeWorkPhotos({
    required String sourceWorkId,
    required String targetWorkId,
    String? targetTitle,
  });

  /// 删除作品名下全部本地图片缓存文件夹（绝不触碰物理媒体源目录）。
  Future<void> deleteWorkPhotos(String workId);
}

/// 基于 [StorageRootPort] 的纯 Dart 作品艺术图目录管理实现。
final class StorageRootWorkArtworkStorage implements WorkArtworkStoragePort {
  /// 使用统一存储根解析端口创建图片目录管理器。
  StorageRootWorkArtworkStorage({required this._storageRoot});

  final StorageRootPort _storageRoot;
  final Map<String, String> _knownTitleByWorkId = <String, String>{};

  /// 清理标题中的非法文件名字符，并限制最大长度为 64 字符。
  static String sanitizeTitle(String title) {
    final cleaned = title
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .replaceAll(RegExp(r'[. ]+$'), '');
    if (cleaned.isEmpty) return 'Untitled';
    return cleaned.length > 64 ? cleaned.substring(0, 64).trim() : cleaned;
  }

  /// 生成用于文件夹尾缀索引的稳定安全短标签。
  static String encodeWorkIdTag(String workId) {
    final trimmed = workId.trim();
    if (trimmed.isEmpty) return 'unknown';
    final prefix = trimmed
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
    final head = prefix.isEmpty
        ? 'w'
        : (prefix.length > 12 ? prefix.substring(0, 12) : prefix);
    final hash10 = sha256
        .convert(utf8.encode(trimmed))
        .toString()
        .substring(0, 10);
    return '$head-$hash10';
  }

  /// 拼接作品文件夹标准命名：`<安全作品名> [<workIdTag>]`。
  static String formatWorkFolderName({
    required String workId,
    required String title,
  }) {
    return '${sanitizeTitle(title)} [${encodeWorkIdTag(workId)}]';
  }

  @override
  Future<void> renameWorkFolderIfNeeded(String workId, String newTitle) async {
    final cleanId = workId.trim();
    final cleanTitle = newTitle.trim();
    if (cleanId.isEmpty || cleanTitle.isEmpty) return;
    _knownTitleByWorkId[cleanId] = cleanTitle;

    final photosRoot = Directory(await _storageRoot.resolvePhotosDirPath());
    if (!photosRoot.existsSync()) return;

    final desiredName = formatWorkFolderName(
      workId: cleanId,
      title: cleanTitle,
    );
    final desiredDir = Directory(p.join(photosRoot.path, desiredName));
    final existingDirs = _findAllWorkDirsForId(photosRoot, cleanId);
    if (existingDirs.isEmpty) return;

    for (final src in existingDirs) {
      if (_pathsEqual(src.path, desiredDir.path)) continue;
      await _mergeOrRenameDirectory(src, desiredDir);
    }
  }

  @override
  Future<void> mergeWorkPhotos({
    required String sourceWorkId,
    required String targetWorkId,
    String? targetTitle,
  }) async {
    final cleanSource = sourceWorkId.trim();
    final cleanTarget = targetWorkId.trim();
    if (cleanSource.isEmpty ||
        cleanTarget.isEmpty ||
        cleanSource == cleanTarget) {
      return;
    }
    if (targetTitle != null && targetTitle.trim().isNotEmpty) {
      _knownTitleByWorkId[cleanTarget] = targetTitle.trim();
    }
    final photosRoot = Directory(await _storageRoot.resolvePhotosDirPath());
    if (!photosRoot.existsSync()) {
      _knownTitleByWorkId.remove(cleanSource);
      return;
    }

    final sourceDirs = _findAllWorkDirsForId(photosRoot, cleanSource);
    if (sourceDirs.isEmpty) return;

    final resolvedTargetTitle = _knownTitleByWorkId[cleanTarget] ?? cleanTarget;
    final targetDir = Directory(
      p.join(
        photosRoot.path,
        formatWorkFolderName(workId: cleanTarget, title: resolvedTargetTitle),
      ),
    );
    for (final srcDir in sourceDirs) {
      await _mergeOrRenameDirectory(srcDir, targetDir);
    }
    _knownTitleByWorkId.remove(cleanSource);
  }

  @override
  Future<void> deleteWorkPhotos(String workId) async {
    final cleanId = workId.trim();
    if (cleanId.isEmpty) return;
    _knownTitleByWorkId.remove(cleanId);
    final photosRoot = Directory(await _storageRoot.resolvePhotosDirPath());
    if (!photosRoot.existsSync()) return;
    final existingDirs = _findAllWorkDirsForId(photosRoot, cleanId);
    for (final dir in existingDirs) {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    }
  }

  List<Directory> _findAllWorkDirsForId(Directory root, String workId) {
    if (!root.existsSync()) return const <Directory>[];
    final suffix = ' [${encodeWorkIdTag(workId)}]';
    final legacySuffix = ' [$workId]';
    final matches = <Directory>[];
    for (final entity in root.listSync(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = p.basename(entity.path);
      if (name.endsWith(suffix) || name.endsWith(legacySuffix)) {
        matches.add(entity);
      }
    }
    return matches;
  }

  Future<void> _mergeOrRenameDirectory(Directory src, Directory dst) async {
    if (!src.existsSync()) return;
    if (!dst.existsSync()) {
      try {
        dst.parent.createSync(recursive: true);
        await src.rename(dst.path);
        return;
      } catch (error) {
        developer.log(
          '作品图片目录直接改名失败，回退逐文件合并',
          name: 'konata.work_artwork_storage',
          error: error,
        );
      }
    }
    dst.createSync(recursive: true);
    for (final entity in src.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel = p.relative(entity.path, from: src.path);
      final targetFile = File(p.join(dst.path, rel));
      targetFile.parent.createSync(recursive: true);
      if (!targetFile.existsSync()) {
        await entity.copy(targetFile.path);
      }
    }
    try {
      src.deleteSync(recursive: true);
    } catch (error) {
      developer.log(
        '清理原作品图片目录残留占位失败已忽略',
        name: 'konata.work_artwork_storage',
        error: error,
      );
    }
  }

  static bool _pathsEqual(String a, String b) {
    final na = p.normalize(a).toLowerCase();
    final nb = p.normalize(b).toLowerCase();
    return na == nb;
  }
}
