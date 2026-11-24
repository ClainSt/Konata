import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';
import 'package:path/path.dart' as p;

import '../../models/media_source.dart';
import 'directory_scan_snapshot.dart';

/// 将 WebDAV 扫描快照保存在当前应用的数据目录，按媒体源、账号和扫描范围隔离。
class ScrapeDirectoryScanSnapshotStore {
  /// 使用当前应用的平台存储根目录。
  const ScrapeDirectoryScanSnapshotStore({required this._storageRoot});

  final StorageRootPort _storageRoot;
  static final _snapshotCompression = GZipCodec(level: 1);

  /// 源地址或账号变化时作废旧快照，且不在快照中保存连接信息。
  static String keyFor(MediaSource source, List<String> normalizedRoots) {
    final identity = jsonEncode([
      source.id,
      source.location,
      source.username,
      normalizedRoots,
    ]);
    return sha256.convert(utf8.encode(identity)).toString();
  }

  Future<File> _snapshotFile(String key) async {
    final cacheRoot = await _storageRoot.resolveCacheRootPath();
    final directory = Directory(p.join(cacheRoot, StoragePathNames.scanSnapshotsSubdir));
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
    }
    return File(p.join(directory.path, '$key.json.gz'));
  }

  /// 无法读取或格式失效时由扫描器重新建立快照。
  Future<ScrapeDirectoryScanSnapshot?> load(String key) async {
    try {
      final file = await _snapshotFile(key);
      if (!file.existsSync()) return null;
      final snapshot = await Isolate.run(() {
        final bytes = gzip.decode(file.readAsBytesSync());
        final decoded = jsonDecode(utf8.decode(bytes));
        return decoded is Map<String, Object?>
            ? ScrapeDirectoryScanSnapshot.fromJson(decoded)
            : null;
      });
      return snapshot?.sourceId == key ? snapshot : null;
    } catch (error, stackTrace) {
      developer.log(
        '无法读取目录扫描快照，将重新列举目录',
        name: 'konata.directory_scan_snapshot_store',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  /// 在后台编码后使用同卷临时文件发布，写入失败时保留旧快照。
  Future<void> save(ScrapeDirectoryScanSnapshot snapshot) async {
    final file = await _snapshotFile(snapshot.sourceId);
    final part = File(
      '${file.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.part',
    );
    try {
      await Isolate.run(() {
        final jsonBytes = utf8.encode(jsonEncode(snapshot.toJson()));
        part.writeAsBytesSync(
          _snapshotCompression.encode(jsonBytes),
          flush: true,
        );
      });
      await AtomicFileWriter.replaceFile(part, file);
    } finally {
      try {
        if (part.existsSync()) part.deleteSync();
      } on FileSystemException catch (error) {
        developer.log(
          '清理目录扫描快照暂存文件失败',
          name: 'konata.directory_scan_snapshot_store',
          error: error,
        );
      }
    }
  }
}
