import 'dart:io';
import 'dart:typed_data';

import 'package:engine_scraping/engine_scraping.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 基于本地磁盘目录的纯 Dart 只读 [MediaSourceGateway] 测试替身。
final class TestLocalSourceGateway implements MediaSourceGateway {
  /// 构造本地目录只读网关。
  const TestLocalSourceGateway({required this.rootPath});

  /// 本地媒体根目录绝对路径。
  final String rootPath;

  @override
  Future<List<RemoteEntry>> listDirectory(String relativePath) async {
    final normalized = _normalizeRel(relativePath);
    final dirPath = normalized.isEmpty ? rootPath : p.join(rootPath, normalized);
    final dir = Directory(dirPath);
    if (!dir.existsSync()) {
      throw PathNotFoundException(
        dirPath,
        const OSError('目录不存在', 2),
      );
    }
    final entities = dir.listSync(followLinks: false);
    final entries = <RemoteEntry>[];
    for (final entity in entities) {
      final name = p.basename(entity.path);
      final rel = normalized.isEmpty ? name : '$normalized/$name';
      if (entity is Directory) {
        final stat = entity.statSync();
        entries.add(
          RemoteEntry(
            name: name,
            relativePath: rel,
            isDirectory: true,
            modifiedAt: stat.modified,
          ),
        );
      } else if (entity is File) {
        final stat = entity.statSync();
        entries.add(
          RemoteEntry(
            name: name,
            relativePath: rel,
            isDirectory: false,
            size: stat.size,
            modifiedAt: stat.modified,
          ),
        );
      }
    }
    entries.sort((a, b) => a.name.compareTo(b.name));
    return entries;
  }

  @override
  Future<String?> readTextFile(
    String relativePath, {
    int maxBytes = 256 * 1024,
  }) async {
    final normalized = _normalizeRel(relativePath);
    final filePath = normalized.isEmpty ? rootPath : p.join(rootPath, normalized);
    final file = File(filePath);
    if (!file.existsSync()) return null;
    final bytes = await file.readAsBytes();
    final slice = bytes.length > maxBytes ? bytes.sublist(0, maxBytes) : bytes;
    return String.fromCharCodes(slice);
  }

  @override
  Future<String?> testConnection() async {
    return Directory(rootPath).existsSync() ? null : '本地目录不存在：$rootPath';
  }

  @override
  Future<void> close() async {}

  static String _normalizeRel(String raw) {
    return raw
        .trim()
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'^/+|/+$'), '');
  }
}

/// 纯内存/可选目录型 [ArtworkCacheStore] 测试替身。
final class TestArtworkCacheStore implements ArtworkCacheStore {
  /// 构造可选绑定磁盘缓存目录的艺术图缓存容器。
  TestArtworkCacheStore([this.rootDir]);

  /// 可选物理缓存根目录。
  final Directory? rootDir;

  final Map<String, ({Uint8List bytes, int quality})> _memory =
      <String, ({Uint8List bytes, int quality})>{};

  @override
  Future<Uint8List?> read(
    String key, {
    int minimumQuality = 0,
    String? owner,
    PhotoSubfolder? subfolder,
  }) async {
    final fullKey = '${owner ?? ''}:${subfolder?.dirName ?? ''}:$key';
    final hit = _memory[fullKey];
    if (hit == null || hit.quality < minimumQuality) return null;
    return hit.bytes;
  }

  @override
  Future<void> write(
    String key,
    Uint8List bytes, {
    String? owner,
    int quality = 0,
    PhotoSubfolder? subfolder,
  }) async {
    final fullKey = '${owner ?? ''}:${subfolder?.dirName ?? ''}:$key';
    _memory[fullKey] = (bytes: Uint8List.fromList(bytes), quality: quality);
    if (rootDir == null || subfolder == null) return;
    final dir = Directory(p.join(rootDir!.path, subfolder.dirName));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    final safe = key.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    File(
      p.join(dir.path, '$safe.jpg'),
    ).writeAsBytesSync(bytes, flush: true);
  }

  @override
  Future<Uint8List?> readLocalWorkFile({
    required String owner,
    required PhotoSubfolder subfolder,
    required String fileName,
  }) async {
    if (rootDir == null) return null;
    final file = File(p.join(rootDir!.path, subfolder.dirName, fileName));
    if (!file.existsSync()) return null;
    return file.readAsBytes();
  }

  /// 关闭缓存资源（测试桩空实现）。
  void close() {}
}

/// 创建纯内存三库合一数据库与 [StorageScrapeRepository]，并在测试结束时自动关闭连接。
({KonataDatabaseBundle bundle, StorageScrapeRepository repository})
openTestScrapeDatabase() {
  final bundle = KonataDatabaseBundle.openInMemory();
  addTearDown(() async {
    await bundle.close();
  });
  return (
    bundle: bundle,
    repository: StorageScrapeRepository(bundle),
  );
}

/// 在工作区根目录或包根目录自适应定位跨仓随包资产文件（如 `assets/data/bangumi_tmdb_map.bin`）。
File resolveRepoAssetFile(String assetRelativePath) {
  final normalized = assetRelativePath.replaceAll('\\', '/');
  final candidates = <String>[
    normalized,
    p.join('apps', 'konata', normalized),
    p.join('..', '..', 'apps', 'konata', normalized),
    p.join('..', '..', '..', 'apps', 'konata', normalized),
  ];
  for (final candidate in candidates) {
    final file = File(candidate);
    if (file.existsSync()) return file;
  }
  return File(p.join('..', '..', 'apps', 'konata', normalized));
}
