import 'dart:io';

import 'package:konata_storage/konata_storage.dart';
import 'package:path/path.dart' as p;

/// 单个作品图片目录占用统计详情（用于自定义精确清理弹窗）。
final class WorkPhotoStorageEntry {
  /// 创建单个作品图片占用条目。
  const WorkPhotoStorageEntry({
    required this.workId,
    required this.displayTitle,
    required this.folderPath,
    required this.isOrphan,
    required this.totalBytes,
    required this.totalFiles,
    required this.byCategory,
  });

  /// 目录标签映射的作品标识。
  final String workId;

  /// 展示标题（匹配作品库标题或孤儿目录原名）。
  final String displayTitle;

  /// 磁盘目录绝对路径。
  final String folderPath;

  /// 是否已不在作品库中（孤儿缓存目录）。
  final bool isOrphan;

  /// 总占用字节数。
  final int totalBytes;

  /// 总文件数。
  final int totalFiles;

  /// 按图片五分类统计的占用明细。
  final Map<PhotoStorageCategory, PhotoCategoryStat> byCategory;
}

/// 图片存储全局及作品维度扫描快照。
final class PhotosCleanupSnapshot {
  /// 创建图片占用扫描快照。
  const PhotosCleanupSnapshot({
    required this.globalStats,
    required this.workEntries,
  });

  /// 全局分类汇总统计。
  final PhotosStorageStats globalStats;

  /// 按总占用降序排列的作品目录列表。
  final List<WorkPhotoStorageEntry> workEntries;
}

/// 本地图片存储扫描与精准清理辅助服务（零 Riverpod）。
final class PhotosCleanupScanner {
  /// 创建图片存储扫描服务。
  const PhotosCleanupScanner({
    required this._photosStorage,
    required this._workDao,
  });

  final PhotosStorage _photosStorage;
  final WorkDao _workDao;

  /// 格式化字节数为可读容量字符串。
  static String formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// 扫描全站图片根目录并关联作品库元数据生成明细快照。
  Future<PhotosCleanupSnapshot> scanSnapshot() async {
    final globalStats = await _photosStorage.computeStats();
    final rootDir = await _photosStorage.resolveRootDirectory();
    if (!rootDir.existsSync()) {
      return PhotosCleanupSnapshot(
        globalStats: globalStats,
        workEntries: const <WorkPhotoStorageEntry>[],
      );
    }

    final worksByTag = <String, WorkRecord>{};
    for (final work in _workDao.listAll()) {
      worksByTag[work.id.value] = work;
      worksByTag[PhotosStorage.encodeWorkIdTag(work.id.value)] = work;
    }

    final entries = <WorkPhotoStorageEntry>[];
    for (final entity in rootDir.listSync(followLinks: false)) {
      if (entity is! Directory) {
        continue;
      }
      final dirName = p.basename(entity.path);
      final tag = _extractWorkTag(dirName) ?? dirName;
      final matchedWork = worksByTag[tag];

      final categoryMap = <PhotoStorageCategory, PhotoCategoryStat>{};
      var workBytes = 0;
      var workFiles = 0;
      for (final category in PhotoStorageCategory.values) {
        final subDir = Directory(p.join(entity.path, category.dirName));
        var catBytes = 0;
        var catFiles = 0;
        if (subDir.existsSync()) {
          for (final file in subDir.listSync(followLinks: false)) {
            if (file is File) {
              catFiles++;
              catBytes += file.lengthSync();
            }
          }
        }
        categoryMap[category] = PhotoCategoryStat(
          bytes: catBytes,
          files: catFiles,
        );
        workBytes += catBytes;
        workFiles += catFiles;
      }

      if (workFiles == 0) {
        continue;
      }

      final fallbackTitle = _stripTagFromDirName(dirName);
      entries.add(
        WorkPhotoStorageEntry(
          workId: matchedWork?.id.value ?? tag,
          displayTitle: matchedWork?.title ?? fallbackTitle,
          folderPath: entity.path,
          isOrphan: matchedWork == null,
          totalBytes: workBytes,
          totalFiles: workFiles,
          byCategory: Map<PhotoStorageCategory, PhotoCategoryStat>.unmodifiable(
            categoryMap,
          ),
        ),
      );
    }

    entries.sort((a, b) => b.totalBytes.compareTo(a.totalBytes));
    return PhotosCleanupSnapshot(
      globalStats: globalStats,
      workEntries: List<WorkPhotoStorageEntry>.unmodifiable(entries),
    );
  }

  /// 执行指定图片分类或指定作品目录的精确删除，并返回删除文件数。
  Future<int> clearCategories(
    Set<PhotoStorageCategory> categories, {
    String? workId,
  }) {
    return _photosStorage.clearCategories(categories, workId: workId);
  }

  /// 一键清理全部可再生缓存（分集剧照与扫图微缩图）。
  Future<int> clearRegenerableCaches() {
    return _photosStorage.clearCategories(const <PhotoStorageCategory>{
      PhotoStorageCategory.thumbnails,
      PhotoStorageCategory.scans,
    });
  }

  static String? _extractWorkTag(String dirName) {
    final open = dirName.lastIndexOf('[');
    final close = dirName.lastIndexOf(']');
    if (open != -1 && close > open + 1) {
      return dirName.substring(open + 1, close).trim();
    }
    return null;
  }

  static String _stripTagFromDirName(String dirName) {
    final open = dirName.lastIndexOf('[');
    if (open > 0) {
      return dirName.substring(0, open).trim();
    }
    return dirName;
  }
}
