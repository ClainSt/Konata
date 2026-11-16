import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/models/media_source.dart';
import '../../domain/repositories/file_system_gateway.dart';
import 'byte_stream_source_gateway.dart';
import 'source_access_error.dart';

/// 本地磁盘媒体源只读网关。
class LocalSourceGateway
    implements MediaSourceGateway, ByteRangeReadableGateway {
  /// 创建本地磁盘网关，[rootPath] 为媒体源根目录。
  LocalSourceGateway({required String rootPath})
    : _rootDir = Directory(p.normalize(rootPath));

  final Directory _rootDir;

  /// 解析并校验相对路径是否仍在根目录之内，防止路径穿越。
  String resolveAbsolutePath(String relativePath) {
    final normalizedRel = relativePath
        .replaceAll('\\', '/')
        .split('/')
        .where((s) => s.isNotEmpty && s != '.')
        .toList();
    if (normalizedRel.any((s) => s == '..')) {
      throw ArgumentError('非法相对路径: $relativePath');
    }
    if (normalizedRel.isEmpty) {
      return _rootDir.path;
    }
    return p.joinAll([_rootDir.path, ...normalizedRel]);
  }

  String _toRelativePosix(String fullPath) {
    final rel = p.relative(fullPath, from: _rootDir.path);
    return rel == '.' ? '' : rel.replaceAll('\\', '/');
  }

  @override
  Future<List<RemoteEntry>> listDirectory(String relativePath) async {
    final targetPath = resolveAbsolutePath(relativePath);
    final dir = Directory(targetPath);
    if (!await dir.exists()) return const [];

    final entries = <RemoteEntry>[];
    await for (final entity in dir.list(followLinks: false)) {
      final stat = await entity.stat();
      final isDir = stat.type == FileSystemEntityType.directory;
      final isFile = stat.type == FileSystemEntityType.file;
      if (!isDir && !isFile) continue;

      entries.add(
        RemoteEntry(
          relativePath: _toRelativePosix(entity.path),
          name: p.basename(entity.path),
          isDirectory: isDir,
          size: isDir ? 0 : stat.size,
          modifiedAt: stat.modified,
        ),
      );
    }

    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  @override
  Future<String?> readTextFile(
    String relativePath, {
    int maxBytes = 256 * 1024,
  }) async {
    final file = File(resolveAbsolutePath(relativePath));
    if (!await file.exists()) return null;
    final length = await file.length();
    final readLength = length > maxBytes ? maxBytes : length;
    final bytes = <int>[];
    await for (final chunk in file.openRead(0, readLength)) {
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  @override
  Future<int?> probeFileLength(String relativePath) async {
    final file = File(resolveAbsolutePath(relativePath));
    if (!await file.exists()) return null;
    return file.length();
  }

  @override
  Future<Stream<List<int>>> openByteRange(
    String relativePath, {
    required int start,
    int? endInclusive,
  }) async {
    final file = File(resolveAbsolutePath(relativePath));
    final total = await file.length();
    if (start >= total) return const Stream<List<int>>.empty();
    final endExclusive = endInclusive != null
        ? (endInclusive + 1).clamp(start, total)
        : total;
    return file.openRead(start, endExclusive);
  }

  @override
  Future<String?> testConnection() async {
    try {
      if (!await _rootDir.exists()) {
        return SourceAccessErrorClassifier.formatKind(
          SourceAccessProblemKind.path,
          MediaSourceKind.local,
        );
      }
      await _rootDir.list(followLinks: false).take(1).toList();
      return null;
    } catch (error) {
      return SourceAccessErrorClassifier.toChineseMessage(
        error,
        MediaSourceKind.local,
      );
    }
  }

  @override
  Future<void> close() async {}
}
