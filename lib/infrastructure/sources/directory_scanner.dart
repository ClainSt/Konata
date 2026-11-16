import 'package:path/path.dart' as p;

import '../../domain/matching/directory_grouper.dart';
import '../../domain/matching/supplementary_folder_rules.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/repositories/file_system_gateway.dart';
import 'subtitle_matcher.dart';

/// 目录扫描结果。
class DirectoryScanResult {
  /// 创建扫描结果实例。
  const DirectoryScanResult({
    required this.files,
    required this.nfoByFolder,
    required this.scannedDirectories,
    this.folderVideoCounts = const {},
    this.cancelled = false,
  });

  /// 已归类与关联外挂字幕后的媒体文件输入列表。
  final List<ScannedFileInput> files;

  /// 目录相对路径到 `.nfo` 文本内容的映射。
  final Map<String, String> nfoByFolder;

  /// 本次遍历的目录总数。
  final int scannedDirectories;

  /// 各已遍历目录对应的视频文件计数。
  final Map<String, int> folderVideoCounts;

  /// 本次遍历是否因用户取消而提前中断。
  final bool cancelled;
}

/// 扫描进度回调。
typedef DirectoryScanProgressCallback =
    void Function(String currentDirectory, int scannedDirectories, int foundFiles);

/// 单目录枚举完成回调。
typedef DirectoryFolderVisitedCallback =
    void Function(String folderPath, int videoCount, bool completed);

/// 统一异步只读目录扫描器。
///
/// 基于 [MediaSourceGateway] 遍历本地、WebDAV 与 SMB 目录树，仅读取目录项元数据与小文本
/// `.nfo` 文件，绝不读取视频流字节。
class DirectoryScanner {
  /// 创建目录扫描器实例。
  const DirectoryScanner();

  static const Set<String> _ignoredDirNames = {
    '@eadir',
    '\$recycle.bin',
    'system volume information',
    'fonts',
    'font',
    '.git',
    '.@__thumb',
  };

  static const Set<String> _videoExts = {
    '.mkv',
    '.mp4',
    '.m2ts',
    '.avi',
    '.ts',
    '.webm',
  };

  static const Set<String> _subtitleExts = {
    '.ass',
    '.ssa',
    '.srt',
    '.sup',
    '.vtt',
  };

  static const Set<String> _audioExts = {
    '.cue',
    '.flac',
    '.ape',
    '.wav',
    '.tta',
    '.tak',
    '.m4a',
    '.aac',
    '.ogg',
    '.opus',
    '.mka',
    '.mp3',
  };

  static const Set<String> _scanImageExts = {
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
    '.bmp',
    '.avif',
  };

  static final RegExp _cdDirRegex = RegExp(
    r'(?:^|[\s._\-\[\]()])(?:cd|cds|ost|soundtrack|music|radio|drama|disc\s*\d+)(?=$|[\s._\-\[\]()0-9])',
    caseSensitive: false,
  );

  static final RegExp _scanDirRegex = RegExp(
    r'(?:^|[\s._\-\[\]()])(?:scans?|booklets?|bk|artwork|gallery|illustrations?)(?=$|[\s._\-\[\]()0-9])',
    caseSensitive: false,
  );

  /// 异步递归扫描媒体源根目录或用户勾选的 [scanRoots]，返回可供后台 Isolate 归组的文件清单。
  Future<DirectoryScanResult> scan(
    MediaSourceGateway gateway, {
    List<String> scanRoots = const [],
    DirectoryScanProgressCallback? onProgress,
    DirectoryFolderVisitedCallback? onFolderVisited,
    bool Function()? isCancelled,
  }) async {
    final queue = _normalizeScanRoots(scanRoots);
    final visitedDirs = <String>{};
    final rawFiles = <RemoteEntry>[];
    final subtitlesByFolder = <String, List<RemoteEntry>>{};
    final nfoByFolder = <String, String>{};
    final folderVideoCounts = <String, int>{};
    var scannedDirectories = 0;
    var cancelled = false;

    while (queue.isNotEmpty) {
      if (isCancelled?.call() ?? false) {
        cancelled = true;
        break;
      }
      final currentDir = queue.removeAt(0);
      final normalizedCurrent = currentDir
          .trim()
          .replaceAll('\\', '/')
          .replaceAll(RegExp(r'^/+|/+$'), '');
      if (!visitedDirs.add(normalizedCurrent)) {
        continue;
      }
      scannedDirectories++;
      folderVideoCounts.putIfAbsent(normalizedCurrent, () => 0);
      onFolderVisited?.call(normalizedCurrent, 0, false);
      onProgress?.call(normalizedCurrent, scannedDirectories, rawFiles.length);

      final entries = await gateway.listDirectory(normalizedCurrent);
      var dirVideoCount = 0;
      for (final entry in entries) {
        if (entry.isDirectory) {
          final normChild = entry.relativePath
              .trim()
              .replaceAll('\\', '/')
              .replaceAll(RegExp(r'^/+|/+$'), '');
          if (!_shouldSkipDirectory(entry.name) &&
              normChild.isNotEmpty &&
              !visitedDirs.contains(normChild)) {
            queue.add(normChild);
          }
          continue;
        }

        final lowerName = entry.name.toLowerCase();
        final ext = p.posix.extension(lowerName);
        if (ext == '.nfo' && !nfoByFolder.containsKey(normalizedCurrent)) {
          final nfoText = await gateway.readTextFile(entry.relativePath);
          if (nfoText != null && nfoText.trim().isNotEmpty) {
            nfoByFolder[normalizedCurrent] = nfoText;
          }
          continue;
        }

        if (_subtitleExts.contains(ext)) {
          subtitlesByFolder.putIfAbsent(normalizedCurrent, () => []).add(entry);
          continue;
        }

        final kind = _classifyAssetKind(normalizedCurrent, ext);
        if (kind != null) {
          rawFiles.add(entry);
          if (kind == AssetKind.video) {
            dirVideoCount++;
          }
        }
      }
      folderVideoCounts[normalizedCurrent] = dirVideoCount;
      onFolderVisited?.call(normalizedCurrent, dirVideoCount, true);
      onProgress?.call(normalizedCurrent, scannedDirectories, rawFiles.length);
    }

    if (cancelled || (isCancelled?.call() ?? false)) {
      return DirectoryScanResult(
        files: const [],
        nfoByFolder: nfoByFolder,
        scannedDirectories: scannedDirectories,
        folderVideoCounts: Map.unmodifiable(folderVideoCounts),
        cancelled: true,
      );
    }

    final allSubtitlePaths = [
      for (final subs in subtitlesByFolder.values)
        for (final sub in subs) sub.relativePath,
    ];

    final outputs = <ScannedFileInput>[];
    for (final entry in rawFiles) {
      final folder = _parentPosixDir(entry.relativePath);
      final ext = p.posix.extension(entry.name.toLowerCase());
      final kind = _classifyAssetKind(folder, ext);
      if (kind == null) continue;

      final subtitleMatch = kind == AssetKind.video
          ? SubtitleMatcher.matchForVideo(
              videoRelativePath: entry.relativePath,
              allSubtitleRelativePaths: allSubtitlePaths,
            )
          : null;

      outputs.add(
        ScannedFileInput(
          relativePath: entry.relativePath,
          fileName: entry.name,
          fileSize: entry.size,
          assetKind: kind,
          externalSubtitles: subtitleMatch?.subtitlePaths ?? const <String>[],
          subtitleGroupHint: subtitleMatch?.subtitleGroupHint,
        ),
      );
    }

    return DirectoryScanResult(
      files: outputs,
      nfoByFolder: nfoByFolder,
      scannedDirectories: scannedDirectories,
      folderVideoCounts: Map.unmodifiable(folderVideoCounts),
    );
  }

  /// 规范化勾选目录，并剔除被祖先目录覆盖的重复子目录。
  List<String> _normalizeScanRoots(List<String> scanRoots) {
    final cleaned = <String>{
      for (final raw in scanRoots)
        raw.replaceAll('\\', '/').replaceAll(RegExp(r'^/+|/+$'), ''),
    }.toList()
      ..sort();

    if (cleaned.isEmpty || cleaned.contains('')) {
      return [''];
    }

    final deduped = <String>[];
    for (final candidate in cleaned) {
      final covered = deduped.any(
        (parent) => candidate == parent || candidate.startsWith('$parent/'),
      );
      if (!covered) {
        deduped.add(candidate);
      }
    }
    return deduped;
  }

  bool _shouldSkipDirectory(String name) {
    final lower = name.trim().toLowerCase();
    if (lower.isEmpty || lower.startsWith('.')) return true;
    return _ignoredDirNames.contains(lower);
  }

  AssetKind? _classifyAssetKind(String folderPath, String ext) {
    if (_videoExts.contains(ext)) {
      return AssetKind.video;
    }
    final dirSegments = folderPath.split('/');
    final inAudioOrPackDir =
        dirSegments.any(_cdDirRegex.hasMatch) ||
        SupplementaryFolderRules.isAudioOrScanPath(folderPath);
    if (ext == '.cue' || (inAudioOrPackDir && _audioExts.contains(ext))) {
      return AssetKind.cdAlbum;
    }
    final inScanDir =
        dirSegments.any(_scanDirRegex.hasMatch) ||
        SupplementaryFolderRules.isAudioOrScanPath(folderPath);
    if (inScanDir && _scanImageExts.contains(ext)) {
      return AssetKind.scanGallery;
    }
    return null;
  }

  String _parentPosixDir(String relativePath) {
    final parent = p.posix.dirname(relativePath);
    return parent == '.' ? '' : parent;
  }
}
