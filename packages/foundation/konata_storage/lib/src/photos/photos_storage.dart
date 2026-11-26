import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:path/path.dart' as p;

import '../paths/atomic_file_writer.dart';
import '../paths/portable_storage_root_service.dart';

/// 图片文件失效时的外部内存驱逐回调（由宿主注入，底层保持零界面框架依赖）。
typedef PhotoEvictCallback = Future<void> Function(File file);

/// 自定义图片统计与精准清理的五类图片分类。
enum PhotoStorageCategory {
  /// 封面海报。
  posters('posters', '封面海报', false),

  /// 背景原画。
  backdrops('backdrops', '背景原画', false),

  /// 标题徽标。
  logos('logos', '标题徽标', false),

  /// 分集剧照（可再生）。
  thumbnails('thumbnails', '分集剧照', true),

  /// 扫图微缩图（可再生）。
  scans('scans', '扫图微缩图', true);

  const PhotoStorageCategory(
    this.dirName,
    this.displayLabel,
    this.isRegenerable,
  );

  /// 磁盘子目录名。
  final String dirName;

  /// 中文展示标签。
  final String displayLabel;

  /// 是否属于可再生缓存类别。
  final bool isRegenerable;

  /// 映射至底层标准图片子目录枚举。
  PhotoSubfolder toSubfolder() => switch (this) {
    PhotoStorageCategory.posters => PhotoSubfolder.posters,
    PhotoStorageCategory.backdrops => PhotoSubfolder.backdrops,
    PhotoStorageCategory.logos => PhotoSubfolder.logos,
    PhotoStorageCategory.thumbnails => PhotoSubfolder.thumbnails,
    PhotoStorageCategory.scans => PhotoSubfolder.scans,
  };
}

/// 单个图片子类的容量统计快照。
final class PhotoCategoryStat {
  /// 创建子类统计条目。
  const PhotoCategoryStat({required this.bytes, required this.files});

  /// 空统计常量。
  static const PhotoCategoryStat zero = PhotoCategoryStat(bytes: 0, files: 0);

  /// 字节总数。
  final int bytes;

  /// 文件总张数。
  final int files;
}

/// 全站 `photos/` 磁盘占用统计快照。
final class PhotosStorageStats {
  /// 创建全局统计快照。
  const PhotosStorageStats({
    required this.rootPath,
    required this.totalBytes,
    required this.totalFiles,
    required this.workFolderCount,
    required this.byCategory,
  });

  /// 当前生效的根目录绝对路径。
  final String rootPath;

  /// 总字节数。
  final int totalBytes;

  /// 总文件数。
  final int totalFiles;

  /// 已建立图片目录的作品数量。
  final int workFolderCount;

  /// 五类子目录的分项字节与文件数统计。
  final Map<PhotoSubfolder, PhotoCategoryStat> byCategory;

  /// 获取可再生微缩图缓存总字节数。
  int get regenerableBytes =>
      (byCategory[PhotoSubfolder.scans]?.bytes ?? 0) +
      (byCategory[PhotoSubfolder.thumbnails]?.bytes ?? 0);

  /// 获取可再生微缩图缓存总文件数。
  int get regenerableFiles =>
      (byCategory[PhotoSubfolder.scans]?.files ?? 0) +
      (byCategory[PhotoSubfolder.thumbnails]?.files ?? 0);
}

/// 统一根目录 `<Root>/photos/<作品名> [<workIdTag>]/<子目录>/` 纯 Dart 图片存储管理器。
///
/// 遵循严格按需懒创建与只读媒体源边界：
/// - 仅在真正写入图片字节时按需建夹，绝不预建空目录；
/// - 作品标题中的非法路径字符与复杂主键安全映射为合法目录名；
/// - 支持可选内存图像缓存驱逐回调，底层保持零界面框架依赖。
final class PhotosStorage {
  /// 创建图片存储管理器。
  PhotosStorage({
    this._overrideRoot,
    StorageRootPort? storageRoot,
    this.onEvictImageFile,
  }) : _storageRoot = storageRoot ?? const PortableStorageRootService();

  final Directory? _overrideRoot;
  final StorageRootPort _storageRoot;

  /// 删除或覆盖本地图片文件后的可选内存缓存驱逐回调。
  final PhotoEvictCallback? onEvictImageFile;

  final Map<String, String> _knownTitleByWorkId = <String, String>{};
  final Map<String, String> _workDirPathByTag = <String, String>{};

  static final RegExp _safePlainId = RegExp(r'^[A-Za-z0-9_-]{1,32}$');
  static final RegExp _nonTagChars = RegExp(r'[^A-Za-z0-9_-]+');
  static final RegExp _invalidFileChars = RegExp(r'[\\/:*?"<>|\x00-\x1F]+');

  /// 解析当前生效的 `photos/` 根目录路径。
  Future<Directory> resolveRootDirectory() async {
    final override = _overrideRoot;
    if (override != null) return override;
    return Directory(await _storageRoot.resolvePhotosDirPath());
  }

  /// 将作品名规范化为安全可读目录前缀。
  static String sanitizeTitle(String raw) {
    final cleaned = raw
        .replaceAll(_invalidFileChars, '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .replaceAll(RegExp(r'[. ]+$'), '');
    if (cleaned.isEmpty) return 'Untitled';
    return cleaned.length > 64 ? cleaned.substring(0, 64).trim() : cleaned;
  }

  /// 将任意作品主键确定性编码为路径安全短标签。
  static String encodeWorkIdTag(String workId) {
    final trimmed = workId.trim();
    if (_safePlainId.hasMatch(trimmed)) {
      return trimmed;
    }
    final prefix = trimmed.replaceAll(_nonTagChars, '');
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
  }) => '${sanitizeTitle(title)} [${encodeWorkIdTag(workId)}]';

  /// 计算稳定的缓存文件短哈希键。
  static String shortDigest(String key) =>
      sha256.convert(utf8.encode(key)).toString().substring(0, 20);

  /// 仅在内存中登记作品最新标题映射（零磁盘读写）。
  void cacheWorkTitle(String workId, String title) {
    final cleanId = workId.trim();
    final cleanTitle = title.trim();
    if (cleanId.isEmpty || cleanTitle.isEmpty) return;
    _knownTitleByWorkId[cleanId] = cleanTitle;
  }

  /// 当作品标题修改时，同步将既有的作品目录重命名为新标题目录。
  Future<void> renameWorkFolderIfNeeded(String workId, String newTitle) async {
    final cleanId = workId.trim();
    final cleanTitle = newTitle.trim();
    if (cleanId.isEmpty || cleanTitle.isEmpty) return;
    _knownTitleByWorkId[cleanId] = cleanTitle;

    final root = await resolveRootDirectory();
    if (!root.existsSync()) return;

    final desiredName = formatWorkFolderName(
      workId: cleanId,
      title: cleanTitle,
    );
    final desiredDir = Directory(p.join(root.path, desiredName));
    final existingDirs = _findAllWorkDirsForId(root, cleanId);
    if (existingDirs.isEmpty) return;

    for (final src in existingDirs) {
      if (_pathsEqual(src.path, desiredDir.path)) continue;
      await _mergeOrRenameDirectory(src, desiredDir);
    }
    _workDirPathByTag[encodeWorkIdTag(cleanId)] = desiredDir.path;
  }

  /// 合并两部作品已缓存的本地图片目录并清理源目录。
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
    final root = await resolveRootDirectory();
    if (!root.existsSync()) return;

    final sourceDirs = _findAllWorkDirsForId(root, cleanSource);
    if (sourceDirs.isEmpty) return;
    final targetDir = await resolveWorkDirectory(
      cleanTarget,
      title: targetTitle,
    );
    for (final src in sourceDirs) {
      await _mergeOrRenameDirectory(src, targetDir);
    }
    _knownTitleByWorkId.remove(cleanSource);
    _workDirPathByTag.remove(encodeWorkIdTag(cleanSource));
  }

  /// 删除作品名下全部本地图片目录（绝不触碰媒体源物理文件）。
  Future<void> deleteWorkPhotos(String workId) async {
    final cleanId = workId.trim();
    if (cleanId.isEmpty) return;
    final root = await resolveRootDirectory();
    if (!root.existsSync()) return;

    for (final dir in _findAllWorkDirsForId(root, cleanId)) {
      if (!_isManagedDirectory(root, dir)) continue;
      for (final entity in dir.listSync(recursive: true, followLinks: false)) {
        if (entity is File) {
          await onEvictImageFile?.call(entity);
        }
      }
      dir.deleteSync(recursive: true);
    }
    _knownTitleByWorkId.remove(cleanId);
    _workDirPathByTag.remove(encodeWorkIdTag(cleanId));
  }

  /// 定位作品目录（默认懒解析，不主动建空目录）。
  Future<Directory> resolveWorkDirectory(String workId, {String? title}) async {
    final cleanId = workId.trim();
    if (title != null && title.trim().isNotEmpty) {
      _knownTitleByWorkId[cleanId] = title.trim();
    }
    final root = await resolveRootDirectory();
    final tag = encodeWorkIdTag(cleanId);
    final cachedPath = _workDirPathByTag[tag];
    if (cachedPath != null && Directory(cachedPath).existsSync()) {
      final dir = Directory(cachedPath);
      if (_isManagedDirectory(root, dir)) return dir;
      _workDirPathByTag.remove(tag);
    }
    final knownTitle = _knownTitleByWorkId[cleanId];
    if (knownTitle != null) {
      final candidate = Directory(
        p.join(
          root.path,
          formatWorkFolderName(workId: cleanId, title: knownTitle),
        ),
      );
      if (_isManagedDirectory(root, candidate)) {
        _workDirPathByTag[tag] = candidate.path;
        return candidate;
      }
    }
    final existing = _findAllWorkDirsForId(root, cleanId);
    if (existing.isNotEmpty) {
      _workDirPathByTag[tag] = existing.first.path;
      return existing.first;
    }
    return Directory(
      p.join(
        root.path,
        formatWorkFolderName(workId: cleanId, title: knownTitle ?? cleanId),
      ),
    );
  }

  /// 解析指定作品子目录路径（不主动建空文件夹）。
  Future<Directory> resolveSubfolderDirectory(
    String workId,
    PhotoSubfolder subfolder, {
    String? title,
  }) async {
    final workDir = await resolveWorkDirectory(workId, title: title);
    final dir = Directory(p.join(workDir.path, subfolder.dirName));
    final root = await resolveRootDirectory();
    if (!_isManagedDirectory(root, dir, allowMissing: true)) {
      throw FileSystemException('图片目录链接或路径越界', dir.path);
    }
    return dir;
  }

  /// 仅删除当前作品指定子目录中的受管图片；拒绝外部路径、跨作品引用及链接重定向。
  Future<bool> deleteManagedArtworkFile({
    required String workId,
    required PhotoSubfolder subfolder,
    required String path,
  }) async {
    if (workId.trim().isEmpty || !p.isAbsolute(path)) return false;
    final root = await resolveRootDirectory();
    final normalized = p.normalize(path);
    if (!p.isWithin(root.absolute.path, normalized)) return false;
    final segments = p.split(p.relative(normalized, from: root.absolute.path));
    if (segments.length != 3 || segments[1] != subfolder.dirName) return false;
    if (!segments.first.endsWith(' [${encodeWorkIdTag(workId)}]') &&
        !segments.first.endsWith(' [$workId]')) {
      return false;
    }
    final file = File(normalized);
    try {
      if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return false;
      }
      final realRoot = await root.resolveSymbolicLinks();
      final realPath = await file.resolveSymbolicLinks();
      final expected = p.joinAll([realRoot, ...segments]);
      if (!p.equals(realPath, expected)) return false;
      await file.delete();
      await onEvictImageFile?.call(file);
      return true;
    } on FileSystemException catch (error) {
      developer.log('受管图片清理未完成', name: 'konata.photos_storage', error: error);
      return false;
    }
  }

  static String _scanFileName(
    String variantId,
    String relativePath,
    int size,
  ) =>
      '${shortDigest('${relativePath.replaceAll('\\', '/')}#$size#$variantId')}.webp';

  /// 返回指定作品扫图微缩图的目标文件路径（写入前才建目录）。
  Future<File> scanThumbnailFile({
    required String workId,
    required String variantId,
    required String relativePath,
    required int fileSize,
    String? title,
  }) async {
    final dir = await resolveSubfolderDirectory(
      workId,
      PhotoSubfolder.scans,
      title: title,
    );
    return File(
      p.join(dir.path, _scanFileName(variantId, relativePath, fileSize)),
    );
  }

  /// 读取已缓存的扫图微缩图字节（未命中返回空，绝不建目录）。
  Future<Uint8List?> readScanThumbnail({
    required String workId,
    required String variantId,
    required String relativePath,
    required int fileSize,
    String? title,
  }) async {
    final file = await scanThumbnailFile(
      workId: workId,
      variantId: variantId,
      relativePath: relativePath,
      fileSize: fileSize,
      title: title,
    );
    if (!file.existsSync()) return null;
    try {
      final bytes = await file.readAsBytes();
      return bytes.isEmpty ? null : bytes;
    } on FileSystemException {
      return null;
    }
  }

  /// 仅读取已缓存扫图微缩图前 32 字节帧头（用于极速解析宽高比）。
  Future<Uint8List?> readScanThumbnailHeader({
    required String workId,
    required String variantId,
    required String relativePath,
    required int fileSize,
    String? title,
  }) async {
    final file = await scanThumbnailFile(
      workId: workId,
      variantId: variantId,
      relativePath: relativePath,
      fileSize: fileSize,
      title: title,
    );
    if (!file.existsSync()) return null;
    RandomAccessFile? raf;
    try {
      raf = await file.open();
      final header = await raf.read(32);
      return header.isEmpty ? null : header;
    } on FileSystemException {
      return null;
    } finally {
      await raf?.close();
    }
  }

  /// 懒创建目录并原子落盘轻量化扫图微缩图。
  Future<File> writeScanThumbnail({
    required String workId,
    required String variantId,
    required String relativePath,
    required int fileSize,
    required Uint8List webpBytes,
    String? title,
  }) async {
    final file = await scanThumbnailFile(
      workId: workId,
      variantId: variantId,
      relativePath: relativePath,
      fileSize: fileSize,
      title: title,
    );
    await _writeAtomic(file, webpBytes);
    _workDirPathByTag[encodeWorkIdTag(workId)] = file.parent.parent.path;
    return file;
  }

  /// 读取作品在指定子目录中按缓存键落盘的图片字节。
  Future<Uint8List?> readArtwork({
    required String workId,
    required PhotoSubfolder subfolder,
    required String cacheKey,
    String? title,
  }) async {
    final dir = await resolveSubfolderDirectory(
      workId,
      subfolder,
      title: title,
    );
    if (!dir.existsSync()) return null;
    final prefix = shortDigest(cacheKey);
    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name.startsWith(prefix)) {
        try {
          final bytes = await entity.readAsBytes();
          if (bytes.isNotEmpty) return bytes;
        } on FileSystemException {
          return null;
        }
      }
    }
    return null;
  }

  /// 将图片字节按缓存键原子写入指定作品子目录并返回落盘文件。
  Future<File> writeArtwork({
    required String workId,
    required PhotoSubfolder subfolder,
    required String cacheKey,
    required Uint8List bytes,
    String extension = '.bin',
    String? title,
  }) async {
    final dir = await resolveSubfolderDirectory(
      workId,
      subfolder,
      title: title,
    );
    final ext = extension.startsWith('.') ? extension : '.$extension';
    final file = File(p.join(dir.path, '${shortDigest(cacheKey)}$ext'));
    await _writeAtomic(file, bytes);
    _workDirPathByTag[encodeWorkIdTag(workId)] = file.parent.parent.path;
    await onEvictImageFile?.call(file);
    return file;
  }

  /// 按作品标识与子目录兜底读取指定文件名的本地图片字节。
  Future<Uint8List?> readLocalWorkFile({
    required String workId,
    required PhotoSubfolder subfolder,
    required String fileName,
    String? title,
  }) async {
    final dir = await resolveSubfolderDirectory(
      workId,
      subfolder,
      title: title,
    );
    final file = File(p.join(dir.path, p.basename(fileName)));
    if (!file.existsSync()) return null;
    try {
      final bytes = await file.readAsBytes();
      return bytes.isEmpty ? null : bytes;
    } on FileSystemException {
      return null;
    }
  }

  /// 将用户选定或裁切后的自定义艺术图原子写入作品对应子目录。
  Future<File> saveCustomArtwork({
    required String workId,
    required PhotoSubfolder subfolder,
    required Uint8List bytes,
    String extension = '.png',
    String? title,
  }) async {
    final dir = await resolveSubfolderDirectory(
      workId,
      subfolder,
      title: title,
    );
    final ext = extension.startsWith('.') ? extension : '.$extension';
    final ts = DateTime.now().millisecondsSinceEpoch;
    final file = File(p.join(dir.path, 'custom_$ts$ext'));
    await _writeAtomic(file, bytes);
    _workDirPathByTag[encodeWorkIdTag(workId)] = file.parent.parent.path;
    await onEvictImageFile?.call(file);
    return file;
  }

  /// 统计全站图片目录五类子目录的字节与文件占用。
  Future<PhotosStorageStats> computeStats() async {
    final root = await resolveRootDirectory();
    final counts = <PhotoSubfolder, ({int bytes, int files})>{
      for (final s in PhotoSubfolder.values) s: (bytes: 0, files: 0),
    };
    var workFolders = 0;
    if (root.existsSync()) {
      for (final entity in root.listSync(followLinks: false)) {
        if (entity is! Directory) continue;
        workFolders++;
        for (final sub in PhotoSubfolder.values) {
          final subDir = Directory(p.join(entity.path, sub.dirName));
          if (!_isManagedDirectory(root, subDir)) continue;
          var bytes = counts[sub]!.bytes;
          var files = counts[sub]!.files;
          for (final item in subDir.listSync(followLinks: false)) {
            if (item is File) {
              files++;
              bytes += item.lengthSync();
            }
          }
          counts[sub] = (bytes: bytes, files: files);
        }
      }
    }
    final byCategory = <PhotoSubfolder, PhotoCategoryStat>{
      for (final entry in counts.entries)
        entry.key: PhotoCategoryStat(
          bytes: entry.value.bytes,
          files: entry.value.files,
        ),
    };
    final totalBytes = byCategory.values.fold<int>(0, (s, c) => s + c.bytes);
    final totalFiles = byCategory.values.fold<int>(0, (s, c) => s + c.files);
    return PhotosStorageStats(
      rootPath: root.path,
      totalBytes: totalBytes,
      totalFiles: totalFiles,
      workFolderCount: workFolders,
      byCategory: Map<PhotoSubfolder, PhotoCategoryStat>.unmodifiable(
        byCategory,
      ),
    );
  }

  /// 安全列举指定作品目录下的图片文件，拒绝跨目录链接及任意外部路径。
  Future<List<File>> listManagedCategoryFiles({
    required String workDirKey,
    required PhotoStorageCategory category,
  }) async {
    final root = await resolveRootDirectory();
    if (workDirKey.isEmpty || p.basename(workDirKey) != workDirKey) {
      return const [];
    }
    final dir = Directory(p.join(root.path, workDirKey, category.dirName));
    return _isManagedDirectory(root, dir)
        ? dir.listSync(followLinks: false).whereType<File>().toList()
        : const [];
  }

  /// 按类别批量清理本地图片缓存（可选限定单个作品），并触发内存图像驱逐回调。
  Future<int> clearCategories(
    Set<PhotoStorageCategory> categories, {
    String? workId,
  }) async =>
      (await clearSelectedCategories(categories, workId: workId)).removedFiles;

  /// 共享批量清理入口，按实际删除文件汇总数量和释放字节。
  Future<({int removedFiles, int freedBytes})> clearSelectedCategories(
    Set<PhotoStorageCategory> categories, {
    String? workId,
    Set<String>? workDirKeys,
  }) async {
    if (categories.isEmpty || workDirKeys?.isEmpty == true) {
      return (removedFiles: 0, freedBytes: 0);
    }
    final root = await resolveRootDirectory();
    if (!root.existsSync()) return (removedFiles: 0, freedBytes: 0);
    final dirs = workId == null
        ? root.listSync(followLinks: false).whereType<Directory>()
        : _findAllWorkDirsForId(root, workId.trim());
    var removed = 0;
    var freed = 0;
    for (final dir in dirs) {
      if (workDirKeys != null && !workDirKeys.contains(p.basename(dir.path))) {
        continue;
      }
      for (final cat in categories) {
        final subDir = Directory(p.join(dir.path, cat.dirName));
        if (!_isManagedDirectory(root, subDir)) continue;
        for (final file
            in subDir.listSync(followLinks: false).whereType<File>()) {
          try {
            await onEvictImageFile?.call(file);
            // 驱逐回调可能异步等待，实际删除前再次确认父目录和文件仍为受管实体。
            if (!_isManagedDirectory(root, subDir) ||
                FileSystemEntity.typeSync(file.path, followLinks: false) !=
                    FileSystemEntityType.file) {
              continue;
            }
            final bytes = file.lengthSync();
            file.deleteSync();
            removed++;
            freed += bytes;
          } on FileSystemException catch (error) {
            developer.log(
              '图片分类清理未完成',
              name: 'konata.photos_storage',
              error: error,
            );
          }
        }
      }
    }
    return (removedFiles: removed, freedBytes: freed);
  }

  // 逐级校验真实目录归属，拒绝符号链接、目录联接点及缺失路径中的非目录实体。
  static bool _isManagedDirectory(
    Directory root,
    Directory dir, {
    bool allowMissing = false,
  }) {
    final rootPath = p.normalize(root.absolute.path);
    final candidate = p.normalize(dir.absolute.path);
    if (!p.isWithin(rootPath, candidate)) return false;
    try {
      final realRoot = root.existsSync()
          ? root.resolveSymbolicLinksSync()
          : rootPath;
      final relative = p.split(p.relative(candidate, from: rootPath));
      var current = rootPath;
      var expected = realRoot;
      for (final segment in relative) {
        current = p.join(current, segment);
        expected = p.join(expected, segment);
        final type = FileSystemEntity.typeSync(current, followLinks: false);
        if (type == FileSystemEntityType.notFound) return allowMissing;
        if (type != FileSystemEntityType.directory) return false;
        if (!p.equals(
          Directory(current).resolveSymbolicLinksSync(),
          expected,
        )) {
          return false;
        }
      }
      return true;
    } on FileSystemException {
      return false;
    }
  }

  Future<void> _writeAtomic(File target, Uint8List bytes) async {
    final root = await resolveRootDirectory();
    if (!_isManagedDirectory(root, target.parent, allowMissing: true) ||
        FileSystemEntity.typeSync(target.path, followLinks: false) ==
            FileSystemEntityType.link) {
      throw FileSystemException('图片写入路径越界', target.path);
    }
    target.parent.createSync(recursive: true);
    final part = File(
      '${target.path}.part.${DateTime.now().microsecondsSinceEpoch}',
    );
    await part.writeAsBytes(bytes, flush: true);
    await AtomicFileWriter.replaceFile(
      part,
      target,
      expectedLength: bytes.length,
    );
  }

  List<Directory> _findAllWorkDirsForId(Directory root, String workId) {
    if (!root.existsSync() || workId.isEmpty) return const <Directory>[];
    final suffix = ' [${encodeWorkIdTag(workId)}]';
    final legacySuffix = ' [$workId]';
    final matches = <Directory>[];
    for (final entity in root.listSync(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = p.basename(entity.path);
      if ((name.endsWith(suffix) || name.endsWith(legacySuffix)) &&
          _isManagedDirectory(root, entity)) {
        matches.add(entity);
      }
    }
    return matches;
  }

  Future<void> _mergeOrRenameDirectory(Directory src, Directory dst) async {
    final root = await resolveRootDirectory();
    if (!_isManagedDirectory(root, src) ||
        !_isManagedDirectory(root, dst, allowMissing: true)) {
      return;
    }
    if (!dst.existsSync()) {
      try {
        dst.parent.createSync(recursive: true);
        await src.rename(dst.path);
        return;
      } catch (error) {
        developer.log(
          '图片目录直接重命名失败，回退逐文件合并',
          name: 'konata.photos_storage',
          error: error,
        );
      }
    }
    dst.createSync(recursive: true);
    for (final entity in src.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel = p.relative(entity.path, from: src.path);
      final targetFile = File(p.join(dst.path, rel));
      if (!_isManagedDirectory(root, targetFile.parent, allowMissing: true) ||
          FileSystemEntity.typeSync(targetFile.path, followLinks: false) ==
              FileSystemEntityType.link) {
        throw FileSystemException('图片合并目标路径越界', targetFile.path);
      }
      targetFile.parent.createSync(recursive: true);
      if (!targetFile.existsSync()) {
        await entity.copy(targetFile.path);
      }
    }
    try {
      src.deleteSync(recursive: true);
    } catch (error) {
      developer.log(
        '清理原图片目录失败已忽略',
        name: 'konata.photos_storage',
        error: error,
      );
    }
  }

  static bool _pathsEqual(String a, String b) =>
      p.normalize(a).toLowerCase() == p.normalize(b).toLowerCase();
}
