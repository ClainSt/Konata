import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:developer' as developer;

import 'package:crypto/crypto.dart';
import 'package:flutter/painting.dart';
import 'package:path/path.dart' as p;

import '../../domain/models/work.dart';
import '../storage/storage_root_provider.dart';

/// 统一 `photos/` 根目录下的五类规范图片子目录。
enum PhotoSubfolder {
  /// 作品竖版封面图。
  posters('posters'),

  /// 作品详情页横版背景画作。
  backdrops('backdrops'),

  /// 作品官方透明标题 Logo。
  logos('logos'),

  /// 单集分集剧照缩略图（可再生）。
  thumbnails('thumbnails'),

  /// Scan 扫图微缩图（`.webp`，可再生）。
  scans('scans');

  const PhotoSubfolder(this.dirName);

  /// 磁盘子目录名。
  final String dirName;
}

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

  /// 映射至底层 [PhotoSubfolder]。
  PhotoSubfolder toSubfolder() => switch (this) {
    PhotoStorageCategory.posters => PhotoSubfolder.posters,
    PhotoStorageCategory.backdrops => PhotoSubfolder.backdrops,
    PhotoStorageCategory.logos => PhotoSubfolder.logos,
    PhotoStorageCategory.thumbnails => PhotoSubfolder.thumbnails,
    PhotoStorageCategory.scans => PhotoSubfolder.scans,
  };
}

/// 单个图片子类的容量统计快照。
class PhotoCategoryStat {
  /// 创建子类统计条目。
  const PhotoCategoryStat({required this.bytes, required this.files});

  /// 空统计常量。
  static const PhotoCategoryStat zero = PhotoCategoryStat(bytes: 0, files: 0);

  /// 字节总数。
  final int bytes;

  /// 文件总张数。
  final int files;
}

/// 按作品/目录聚合的五类图片存储明细。
class WorkPhotoStorageEntry {
  /// 创建按作品聚合的存储明细。
  const WorkPhotoStorageEntry({
    required this.workDirKey,
    required this.displayTitle,
    required this.isOrphan,
    required this.hasDiskFolder,
    required this.byCategory,
    this.workId,
    this.posterPath,
  });

  /// `photos/` 下对应作品目录的文件夹名称（即自定义清理的唯一目标键）。
  final String workDirKey;

  /// 关联到的媒体库作品 ID（残留目录为 `null`）。
  final String? workId;

  /// 作品标题（关联库内作品时使用准确作品名；残留目录取目录可读前缀）。
  final String displayTitle;

  /// 作品封面路径（关联库内作品时供展示 2:3 缩略封面）。
  final String? posterPath;

  /// 是否为已移出数据库的磁盘残留目录。
  final bool isOrphan;

  /// 当前在磁盘上是否已存在对应实体文件夹。
  final bool hasDiskFolder;

  /// 该作品在五类子目录下的字节与张数统计。
  final Map<PhotoStorageCategory, PhotoCategoryStat> byCategory;

  /// 汇总全部分类的字节数。
  int get totalBytes =>
      byCategory.values.fold<int>(0, (sum, item) => sum + item.bytes);

  /// 汇总全部分类的文件张数。
  int get totalFiles =>
      byCategory.values.fold<int>(0, (sum, item) => sum + item.files);

  /// 统计当前作品在指定分类集合下的命中总张数与总字节数。
  PhotoCategoryStat statForCategories(Set<PhotoStorageCategory> categories) {
    if (categories.isEmpty) return PhotoCategoryStat.zero;
    var bytes = 0;
    var files = 0;
    for (final cat in categories) {
      final stat = byCategory[cat];
      if (stat != null) {
        bytes += stat.bytes;
        files += stat.files;
      }
    }
    return PhotoCategoryStat(bytes: bytes, files: files);
  }
}

/// 包含全局汇总、按作品明细与媒体库总作品数的完整图片存储快照。
class PhotosStorageSnapshot {
  /// 创建完整存储快照。
  const PhotosStorageSnapshot({
    required this.stats,
    required this.workEntries,
    required this.libraryWorkCount,
  });

  /// 全局汇总统计。
  final PhotosStorageStats stats;

  /// 按作品/残留目录聚合的存储明细列表。
  final List<WorkPhotoStorageEntry> workEntries;

  /// 当前媒体库内总作品数量。
  final int libraryWorkCount;
}

/// 全站 `photos/` 磁盘占用统计快照。
class PhotosStorageStats {
  /// 创建全局统计快照。
  const PhotosStorageStats({
    required this.rootPath,
    required this.totalBytes,
    required this.totalFiles,
    required this.workFolderCount,
    required this.byCategory,
  });

  /// 当前生效的 `photos/` 根目录绝对路径。
  final String rootPath;

  /// 总字节数。
  final int totalBytes;

  /// 总文件数。
  final int totalFiles;

  /// 已建立图片目录的作品数量。
  final int workFolderCount;

  /// 五类子目录的分项字节与文件数统计。
  final Map<PhotoSubfolder, PhotoCategoryStat> byCategory;

  /// 获取可再生微缩图缓存（`scans + thumbnails`）总字节数。
  int get regenerableBytes =>
      (byCategory[PhotoSubfolder.scans]?.bytes ?? 0) +
      (byCategory[PhotoSubfolder.thumbnails]?.bytes ?? 0);

  /// 获取可再生微缩图缓存总文件数。
  int get regenerableFiles =>
      (byCategory[PhotoSubfolder.scans]?.files ?? 0) +
      (byCategory[PhotoSubfolder.thumbnails]?.files ?? 0);
}

/// 统一根目录 `<appRoot>/photos/<作品名> [<workIdTag>]/<子目录>/` 图片存储管理器。
///
/// 遵循严格按需懒创建与只读边界：
/// - 开发态下定位仓库根目录 `<cwd>/photos`，打包运行态定位可执行文件同级 `<exeDir>/photos`。
/// - 作品文件名中的 Windows 非法字符与 `Work.id` 中的 `::` 会被安全映射为合法稳定目录名，
///   杜绝 Windows errno 123 创建失败。
/// - 仅在真正需要写入具体图片字节时才按需创建目录，绝不预建空目录。
class PhotosStorage {
  /// 创建图片存储管理器。
  PhotosStorage({
    Directory? overrideRoot,
    StorageRootService? storageRoot,
  }) : _instanceOverrideRoot = overrideRoot,
       _storageRoot = storageRoot ?? const StorageRootService();

  /// 仅供单元测试注入临时隔离根目录。
  static Directory? debugOverrideRoot;

  final Directory? _instanceOverrideRoot;
  final StorageRootService _storageRoot;
  final Map<String, String> _knownTitleByWorkId = <String, String>{};

  static final RegExp _invalidPathChars = RegExp(r'[<>:"/\\|?*\x00-\x1F]');
  static final RegExp _safePlainId = RegExp(r'^[A-Za-z0-9_-]{1,32}$');
  static final RegExp _nonTagChars = RegExp(r'[^A-Za-z0-9_-]+');

  /// 解析当前运行环境对应的 `photos/` 根目录路径。
  Directory resolveRootDirectory() {
    final override = _instanceOverrideRoot ?? debugOverrideRoot;
    if (override != null) return override;
    return _storageRoot.photosRootDirSync();
  }

  /// 将作品名规范化为 Windows / POSIX 安全可读目录前缀。
  static String sanitizeTitle(String raw) {
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

  /// 将任意包含 `::` / `/` 等字符的 `workId` 确定性编码为 Windows 安全唯一标识段。
  static String encodeWorkIdTag(String workId) {
    final trimmed = workId.trim();
    if (_safePlainId.hasMatch(trimmed)) {
      return trimmed;
    }
    final prefix = trimmed.replaceAll(_nonTagChars, '');
    final head = prefix.isEmpty
        ? 'w'
        : (prefix.length > 12 ? prefix.substring(0, 12) : prefix);
    final hash10 = sha256.convert(utf8.encode(trimmed)).toString().substring(0, 10);
    return '$head-$hash10';
  }

  /// 拼接作品文件夹标准命名：`<安全作品名> [<workIdTag>]`。
  static String formatWorkFolderName({
    required String workId,
    required String title,
  }) {
    return '${sanitizeTitle(title)} [${encodeWorkIdTag(workId)}]';
  }

  /// 计算稳定的缓存文件短哈希键。
  static String shortDigest(String key) {
    return sha256.convert(utf8.encode(key)).toString().substring(0, 20);
  }

  /// 仅在内存中登记作品最新标题映射（零磁盘 I/O，供只读查询 Provider 调用）。
  void cacheWorkTitle(String workId, String title) {
    final cleanId = workId.trim();
    final cleanTitle = title.trim();
    if (cleanId.isEmpty || cleanTitle.isEmpty) return;
    _knownTitleByWorkId[cleanId] = cleanTitle;
  }

  /// 记录作品最新标题；若该作品已有旧标题磁盘目录且名称变化，仅对已有目录静默改名。
  Future<void> registerWorkTitle(String workId, String title) async {
    final cleanId = workId.trim();
    final cleanTitle = title.trim();
    if (cleanId.isEmpty || cleanTitle.isEmpty) return;
    final previous = _knownTitleByWorkId[cleanId];
    _knownTitleByWorkId[cleanId] = cleanTitle;
    if (previous != null && previous != cleanTitle) {
      await renameWorkFolderIfNeeded(cleanId, cleanTitle);
    }
  }

  /// 当作品标题修改时，同步将既有的 `photos/<旧名> [<tag>]` 重命名为新标题目录。
  Future<void> renameWorkFolderIfNeeded(String workId, String newTitle) async {
    final cleanId = workId.trim();
    final cleanTitle = newTitle.trim();
    if (cleanId.isEmpty || cleanTitle.isEmpty) return;
    _knownTitleByWorkId[cleanId] = cleanTitle;

    final root = resolveRootDirectory();
    if (!root.existsSync()) return;

    final desiredName = formatWorkFolderName(workId: cleanId, title: cleanTitle);
    final desiredDir = Directory(p.join(root.path, desiredName));
    final existingDirs = await _findAllWorkDirsForId(cleanId);
    if (existingDirs.isEmpty) return;

    for (final src in existingDirs) {
      if (_pathsEqual(src.path, desiredDir.path)) continue;
      await _mergeOrRenameDirectory(src, desiredDir);
    }
  }

  /// 定位作品目录（默认懒解析，仅返回路径对象，不自动建空目录）。
  Future<Directory> resolveWorkDirectory(
    String workId, {
    String? title,
  }) async {
    final cleanId = workId.trim();
    if (title != null && title.trim().isNotEmpty) {
      _knownTitleByWorkId[cleanId] = title.trim();
    }
    final root = resolveRootDirectory();
    final knownTitle = _knownTitleByWorkId[cleanId];
    if (knownTitle != null) {
      final candidate = Directory(
        p.join(
          root.path,
          formatWorkFolderName(workId: cleanId, title: knownTitle),
        ),
      );
      if (candidate.existsSync()) {
        return candidate;
      }
      final existing = await _findFirstWorkDirForId(cleanId);
      if (existing != null) {
        return existing;
      }
      return candidate;
    }

    final existing = await _findFirstWorkDirForId(cleanId);
    if (existing != null) {
      return existing;
    }
    return Directory(
      p.join(
        root.path,
        formatWorkFolderName(workId: cleanId, title: cleanId),
      ),
    );
  }

  /// 解析指定作品子目录路径（默认不创建空文件夹）。
  Future<Directory> resolveSubfolderDirectory(
    String workId,
    PhotoSubfolder subfolder, {
    String? title,
  }) async {
    final workDir = await resolveWorkDirectory(workId, title: title);
    return Directory(p.join(workDir.path, subfolder.dirName));
  }

  /// 返回指定作品 Scan 缩略图的目标 `.webp` 文件句柄（写入前才创建父目录）。
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
    final sig = '${relativePath.replaceAll('\\', '/')}#$fileSize#$variantId';
    return File(p.join(dir.path, '${shortDigest(sig)}.webp'));
  }

  /// 查找并返回已缓存的 Scan `.webp` 字节（未命中返回 `null`，绝不建目录）。
  Future<Uint8List?> readScanThumbnail({
    required String workId,
    required String variantId,
    required String relativePath,
    required int fileSize,
    String? title,
  }) async {
    if (!resolveRootDirectory().existsSync()) return null;
    final file = await scanThumbnailFile(
      workId: workId,
      variantId: variantId,
      relativePath: relativePath,
      fileSize: fileSize,
      title: title,
    );
    if (!file.existsSync()) return null;
    final bytes = await file.readAsBytes();
    return bytes.isEmpty ? null : bytes;
  }

  /// 懒创建 `scans/` 目录并落盘编码后的轻量化 `.webp` 微缩图。
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
    await file.parent.create(recursive: true);
    await file.writeAsBytes(webpBytes, flush: true);
    return file;
  }

  /// 读取作品在指定子目录中按关键字匹配的图片字节（优先命中更高质量档位）。
  Future<Uint8List?> readArtwork({
    required String workId,
    required PhotoSubfolder subfolder,
    required String fileKey,
    int minimumQuality = 0,
    String? title,
  }) async {
    if (!resolveRootDirectory().existsSync()) return null;
    final dir = await resolveSubfolderDirectory(
      workId,
      subfolder,
      title: title,
    );
    if (!dir.existsSync()) return null;

    // 精确前缀命中：<size>_<hash>.<ext> 或 url_<hash>.<ext>
    final direct = File(p.join(dir.path, fileKey));
    if (direct.existsSync()) {
      final data = await direct.readAsBytes();
      if (data.isNotEmpty) return data;
    }

    // 兼容性查找同资源高画质档位（fileKey 格式 `<tier>_<digest><ext>`）
    final parsed = _parseTieredFileName(fileKey);
    if (parsed == null) return null;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      final candidate = _parseTieredFileName(name);
      if (candidate == null) continue;
      if (candidate.digest == parsed.digest &&
          candidate.quality >= minimumQuality) {
        final data = await entity.readAsBytes();
        if (data.isNotEmpty) return data;
      }
    }
    return null;
  }

  /// 懒创建子目录并写入图片文件，返回最终落盘文件句柄（若字节为空返回 `null`）。
  Future<File?> writeArtwork({
    required String workId,
    required PhotoSubfolder subfolder,
    required String fileKey,
    required Uint8List bytes,
    String? title,
  }) async {
    if (bytes.isEmpty) return null;
    final dir = await resolveSubfolderDirectory(
      workId,
      subfolder,
      title: title,
    );
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, fileKey));
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  /// 删除作品对应的整套图片目录（用于从媒体库移除作品时同步清理）。
  Future<void> deleteWorkPhotos(String workId) async {
    final cleanId = workId.trim();
    if (cleanId.isEmpty) return;
    _knownTitleByWorkId.remove(cleanId);
    if (!resolveRootDirectory().existsSync()) return;
    final existingDirs = await _findAllWorkDirsForId(cleanId);
    for (final dir in existingDirs) {
      if (dir.existsSync()) {
        await dir.delete(recursive: true);
      }
    }
  }

  /// 合并/迁移两部作品时，将源作品名下全部已缓存图片无损合并迁入目标作品文件夹并清理源目录。
  Future<void> mergeWorkPhotos({
    required String sourceWorkId,
    required String targetWorkId,
    String? targetTitle,
  }) async {
    final cleanSource = sourceWorkId.trim();
    final cleanTarget = targetWorkId.trim();
    if (cleanSource.isEmpty || cleanTarget.isEmpty || cleanSource == cleanTarget) {
      return;
    }
    if (targetTitle != null && targetTitle.trim().isNotEmpty) {
      _knownTitleByWorkId[cleanTarget] = targetTitle.trim();
    }
    if (!resolveRootDirectory().existsSync()) {
      _knownTitleByWorkId.remove(cleanSource);
      return;
    }

    final sourceDirs = await _findAllWorkDirsForId(cleanSource);
    if (sourceDirs.isEmpty) return;

    final targetDir = await resolveWorkDirectory(
      cleanTarget,
      title: targetTitle,
    );

    for (final srcDir in sourceDirs) {
      if (_pathsEqual(srcDir.path, targetDir.path)) continue;
      await _mergeOrRenameDirectory(srcDir, targetDir);
    }
    _knownTitleByWorkId.remove(cleanSource);
  }

  /// 扫描 `photos/` 根目录并统计总空间与 5 个子类占用详情。
  Future<PhotosStorageStats> computeStats() async {
    final root = resolveRootDirectory();
    final categoryBytes = <PhotoSubfolder, int>{
      for (final f in PhotoSubfolder.values) f: 0,
    };
    final categoryFiles = <PhotoSubfolder, int>{
      for (final f in PhotoSubfolder.values) f: 0,
    };
    var totalBytes = 0;
    var totalFiles = 0;
    var workCount = 0;

    if (root.existsSync()) {
      await for (final workEntity in root.list(followLinks: false)) {
        if (workEntity is! Directory) continue;
        workCount++;
        for (final sub in PhotoSubfolder.values) {
          final subDir = Directory(p.join(workEntity.path, sub.dirName));
          if (!subDir.existsSync()) continue;
          await for (final item in subDir.list(recursive: true, followLinks: false)) {
            if (item is! File) continue;
            final len = await item.length();
            categoryBytes[sub] = (categoryBytes[sub] ?? 0) + len;
            categoryFiles[sub] = (categoryFiles[sub] ?? 0) + 1;
            totalBytes += len;
            totalFiles++;
          }
        }
      }
    }

    return PhotosStorageStats(
      rootPath: root.path,
      totalBytes: totalBytes,
      totalFiles: totalFiles,
      workFolderCount: workCount,
      byCategory: <PhotoSubfolder, PhotoCategoryStat>{
        for (final f in PhotoSubfolder.values)
          f: PhotoCategoryStat(
            bytes: categoryBytes[f] ?? 0,
            files: categoryFiles[f] ?? 0,
          ),
      },
    );
  }

  /// 从标准目录名 `<title> [<workIdTag>]` 提取末端的 `workIdTag` 片段。
  static String? extractWorkTagFromFolderName(String dirName) {
    final open = dirName.lastIndexOf(' [');
    if (open > 0 && dirName.endsWith(']')) {
      return dirName.substring(open + 2, dirName.length - 1);
    }
    return null;
  }

  /// 提取不含 `[<tag>]` 后缀的可读作品前缀。
  static String extractReadableTitleFromFolderName(String dirName) {
    final open = dirName.lastIndexOf(' [');
    if (open > 0 && dirName.endsWith(']')) {
      final head = dirName.substring(0, open).trim();
      if (head.isNotEmpty) return head;
    }
    return dirName;
  }

  /// 扫描 `photos/` 并结合媒体库作品列表生成完整的分作品、分类别占用快照。
  Future<PhotosStorageSnapshot> computeSnapshot({
    List<Work> knownWorks = const [],
  }) async {
    final root = resolveRootDirectory();
    final workByTag = <String, Work>{};
    for (final work in knownWorks) {
      workByTag[encodeWorkIdTag(work.id)] = work;
      workByTag[work.id.trim()] = work;
      cacheWorkTitle(work.id, work.title);
    }

    final globalBytes = <PhotoSubfolder, int>{
      for (final f in PhotoSubfolder.values) f: 0,
    };
    final globalFiles = <PhotoSubfolder, int>{
      for (final f in PhotoSubfolder.values) f: 0,
    };
    var totalBytes = 0;
    var totalFiles = 0;
    var workFolderCount = 0;

    final matchedWorkIds = <String>{};
    final entries = <WorkPhotoStorageEntry>[];

    if (root.existsSync()) {
      await for (final entity in root.list(followLinks: false)) {
        if (entity is! Directory) continue;
        workFolderCount++;
        final dirName = p.basename(entity.path);
        final tag = extractWorkTagFromFolderName(dirName);
        final matchedWork = tag != null ? workByTag[tag] : null;
        if (matchedWork != null) {
          matchedWorkIds.add(matchedWork.id);
        }

        final catStats = <PhotoStorageCategory, PhotoCategoryStat>{};
        for (final cat in PhotoStorageCategory.values) {
          final subDir = Directory(p.join(entity.path, cat.dirName));
          var bytes = 0;
          var files = 0;
          if (subDir.existsSync()) {
            await for (final item in subDir.list(
              recursive: true,
              followLinks: false,
            )) {
              if (item is! File) continue;
              final len = await item.length();
              bytes += len;
              files++;
            }
          }
          catStats[cat] = PhotoCategoryStat(bytes: bytes, files: files);
          final sub = cat.toSubfolder();
          globalBytes[sub] = (globalBytes[sub] ?? 0) + bytes;
          globalFiles[sub] = (globalFiles[sub] ?? 0) + files;
          totalBytes += bytes;
          totalFiles += files;
        }

        entries.add(
          WorkPhotoStorageEntry(
            workDirKey: dirName,
            workId: matchedWork?.id,
            displayTitle: matchedWork != null
                ? matchedWork.title
                : extractReadableTitleFromFolderName(dirName),
            posterPath: matchedWork?.posterPath,
            isOrphan: matchedWork == null,
            hasDiskFolder: true,
            byCategory: catStats,
          ),
        );
      }
    }

    for (final work in knownWorks) {
      if (matchedWorkIds.contains(work.id)) continue;
      entries.add(
        WorkPhotoStorageEntry(
          workDirKey: formatWorkFolderName(workId: work.id, title: work.title),
          workId: work.id,
          displayTitle: work.title,
          posterPath: work.posterPath,
          isOrphan: false,
          hasDiskFolder: false,
          byCategory: {
            for (final cat in PhotoStorageCategory.values)
              cat: PhotoCategoryStat.zero,
          },
        ),
      );
    }

    entries.sort((a, b) {
      final byteCmp = b.totalBytes.compareTo(a.totalBytes);
      if (byteCmp != 0) return byteCmp;
      final fileCmp = b.totalFiles.compareTo(a.totalFiles);
      if (fileCmp != 0) return fileCmp;
      if (a.isOrphan != b.isOrphan) return a.isOrphan ? 1 : -1;
      return a.displayTitle.compareTo(b.displayTitle);
    });

    return PhotosStorageSnapshot(
      stats: PhotosStorageStats(
        rootPath: root.path,
        totalBytes: totalBytes,
        totalFiles: totalFiles,
        workFolderCount: workFolderCount,
        byCategory: {
          for (final f in PhotoSubfolder.values)
            f: PhotoCategoryStat(
              bytes: globalBytes[f] ?? 0,
              files: globalFiles[f] ?? 0,
            ),
        },
      ),
      workEntries: entries,
      libraryWorkCount: knownWorks.length,
    );
  }

  /// 按指定「作品目录键 × 图片分类集合」执行安全自定义清理，仅删除命中的本地缓存文件。
  ///
  /// - 严格校验所有目标路径均位于当前 `photos/` 根目录之内；
  /// - 未选作品与同作品未选分类 100% 保留；清理后若子目录或作品目录为空则同步移除空文件夹；
  /// - 对每个删除的本地图片调用 `FileImage(file).evict()` 驱逐 Flutter 内存图像缓存。
  Future<({int deletedBytes, int deletedFiles})> cleanCustomPhotos({
    required Set<String> workDirKeys,
    required Set<PhotoStorageCategory> categories,
  }) async {
    if (workDirKeys.isEmpty || categories.isEmpty) {
      return (deletedBytes: 0, deletedFiles: 0);
    }
    final root = resolveRootDirectory();
    if (!root.existsSync()) {
      return (deletedBytes: 0, deletedFiles: 0);
    }

    final normalizedRoot = p.normalize(root.absolute.path);
    var deletedBytes = 0;
    var deletedFiles = 0;

    for (final rawKey in workDirKeys) {
      final cleanKey = rawKey.trim();
      if (cleanKey.isEmpty ||
          cleanKey == '.' ||
          cleanKey == '..' ||
          cleanKey.contains('/') ||
          cleanKey.contains('\\')) {
        continue;
      }
      final workDir = Directory(p.join(normalizedRoot, cleanKey));
      if (!p.isWithin(normalizedRoot, p.normalize(workDir.absolute.path))) {
        continue;
      }
      if (!workDir.existsSync()) continue;

      final normalizedWorkDir = p.normalize(workDir.absolute.path);
      for (final cat in categories) {
        final subDir = Directory(p.join(normalizedWorkDir, cat.dirName));
        if (!p.isWithin(
          normalizedWorkDir,
          p.normalize(subDir.absolute.path),
        )) {
          continue;
        }
        if (!subDir.existsSync()) continue;

        await for (final item in subDir.list(
          recursive: true,
          followLinks: false,
        )) {
          if (item is! File) continue;
          final absItemPath = p.normalize(item.absolute.path);
          if (!p.isWithin(normalizedRoot, absItemPath)) continue;
          deletedBytes += await item.length();
          deletedFiles++;
          await _evictFileImageCache(item);
          await item.delete();
        }
        if (subDir.existsSync() && !await _containsAnyFile(subDir)) {
          await subDir.delete(recursive: true);
        }
      }

      if (workDir.existsSync() && !await _containsAnyFile(workDir)) {
        await workDir.delete(recursive: true);
      }
    }

    return (deletedBytes: deletedBytes, deletedFiles: deletedFiles);
  }

  static Future<void> _evictFileImageCache(File file) async {
    try {
      await FileImage(file).evict();
    } catch (error) {
      // 纯 Dart 非 UI 单元测试环境下 PaintingBinding 未初始化，安全忽略。
      developer.log('可恢复异常已记录', name: 'konata.photos_storage', error: error);
    }
  }

  static Future<bool> _containsAnyFile(Directory dir) async {
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) return true;
    }
    return false;
  }

  /// 清理所有作品下的可再生微缩图（`scans/` 与 `thumbnails/`），保留封面、背景与 Logo。
  Future<({int deletedBytes, int deletedFiles})> clearRegenerableCache() async {
    final root = resolveRootDirectory();
    if (!root.existsSync()) {
      return (deletedBytes: 0, deletedFiles: 0);
    }

    var bytes = 0;
    var files = 0;
    const targets = <PhotoSubfolder>[
      PhotoSubfolder.scans,
      PhotoSubfolder.thumbnails,
    ];

    await for (final workEntity in root.list(followLinks: false)) {
      if (workEntity is! Directory) continue;
      for (final sub in targets) {
        final subDir = Directory(p.join(workEntity.path, sub.dirName));
        if (!subDir.existsSync()) continue;
        await for (final item in subDir.list(recursive: true, followLinks: false)) {
          if (item is File) {
            bytes += await item.length();
            files++;
          }
        }
        await subDir.delete(recursive: true);
      }
      // 若清理后作品目录完全空了，顺带清理空作品文件夹避免残留无用空夹。
      final remaining = await workEntity.list(followLinks: false).isEmpty;
      if (remaining) {
        await workEntity.delete();
      }
    }

    return (deletedBytes: bytes, deletedFiles: files);
  }

  Future<Directory?> _findFirstWorkDirForId(String workId) async {
    final all = await _findAllWorkDirsForId(workId);
    return all.isEmpty ? null : all.first;
  }

  Future<List<Directory>> _findAllWorkDirsForId(String workId) async {
    final root = resolveRootDirectory();
    if (!root.existsSync()) return const <Directory>[];
    final suffix = ' [${encodeWorkIdTag(workId)}]';
    final legacySuffix = ' [$workId]';
    final matches = <Directory>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = p.basename(entity.path);
      if (name.endsWith(suffix) || name.endsWith(legacySuffix)) {
        matches.add(entity);
      }
    }
    return matches;
  }

  Future<void> _mergeOrRenameDirectory(Directory src, Directory dst) async {
    if (!await src.exists()) return;
    if (!await dst.exists()) {
      try {
        await dst.parent.create(recursive: true);
        await src.rename(dst.path);
        return;
      } catch (error) {
      // Windows 目录下若句柄短暂未释放则回退逐文件合并。
      developer.log('可恢复异常已记录', name: 'konata.photos_storage', error: error);
    }
    }
    await dst.create(recursive: true);
    await for (final entity in src.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel = p.relative(entity.path, from: src.path);
      final targetFile = File(p.join(dst.path, rel));
      await targetFile.parent.create(recursive: true);
      if (!await targetFile.exists()) {
        await entity.copy(targetFile.path);
      }
    }
    try {
      await src.delete(recursive: true);
    } catch (error) {
      // 忽略残留只读占位失败。
      developer.log('可恢复异常已记录', name: 'konata.photos_storage', error: error);
    }
  }

  static bool _pathsEqual(String a, String b) {
    final na = p.normalize(a).toLowerCase();
    final nb = p.normalize(b).toLowerCase();
    return na == nb;
  }

  static ({String digest, int quality})? _parseTieredFileName(String name) {
    final stem = p.basenameWithoutExtension(name);
    final idx = stem.indexOf('_');
    if (idx <= 0 || idx >= stem.length - 1) return null;
    final tier = stem.substring(0, idx).toLowerCase();
    final digest = stem.substring(idx + 1);
    final quality = switch (tier) {
      'w185' => 1,
      'w342' => 2,
      'w500' => 3,
      'w780' => 4,
      'w1280' => 5,
      'original' => 6,
      'url' => 6,
      _ => 0,
    };
    return (digest: digest, quality: quality);
  }
}
