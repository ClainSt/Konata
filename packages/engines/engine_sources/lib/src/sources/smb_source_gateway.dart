import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:konata_contracts/konata_contracts.dart';
import 'package:smb_connect/smb_connect.dart';

import 'source_access_error.dart';

/// 局域网共享媒体源只读网关（含断线自动重连一次与安全分片流式读取）。
class SmbSourceGateway
    implements
        MediaSourceGateway,
        ByteRangeReadableGateway,
        FileValidatorProbeGateway {
  /// 创建 SMB 网关，[rootUri] 形如 `smb://192.168.1.2/Anime`。
  SmbSourceGateway({
    required this._rootUri,
    this.username = '',
    this.password = '',
    this._connector,
  });

  final Uri _rootUri;

  /// 登录用户名（可含域名反斜杠前缀）。
  final String username;

  /// 登录密码。
  final String password;
  final Future<SmbConnect> Function()? _connector;

  SmbConnect? _sharedClient;
  Future<void> _serial = Future<void>.value();
  bool _closed = false;

  Future<SmbConnect> _getClient() async {
    if (_closed) {
      throw StateError('SMB 网关已关闭');
    }
    if (_sharedClient != null) {
      return _sharedClient!;
    }
    if (_connector != null) {
      _sharedClient = await _connector();
      return _sharedClient!;
    }
    final split = username.indexOf('\\');
    _sharedClient = await SmbConnect.connectAuth(
      host: _rootUri.host,
      domain: split < 0 ? '' : username.substring(0, split),
      username: split < 0 ? username : username.substring(split + 1),
      password: password,
    );
    return _sharedClient!;
  }

  Future<void> _resetClient() async {
    final old = _sharedClient;
    _sharedClient = null;
    if (old != null) {
      try {
        await old.close();
      } catch (error) {
        developer.log(
          '关闭旧 SMB 连接失败',
          name: 'konata.smb_source_gateway',
          error: error,
        );
      }
    }
  }

  /// 串行执行 SMB 操作；遇到非确定性传输断线时自动重连并重试一次。
  Future<T> _runSerialized<T>(Future<T> Function(SmbConnect client) action) {
    final prev = _serial;
    final gate = Completer<void>();
    _serial = gate.future;
    return () async {
      await prev;
      try {
        for (var attempt = 0; attempt < 2; attempt++) {
          try {
            final client = await _getClient();
            return await action(client);
          } catch (error) {
            if (attempt == 1 ||
                _closed ||
                SourceAccessErrorClassifier.isNonTransientError(error)) {
              rethrow;
            }
            await _resetClient();
          }
        }
        throw StateError('SMB 重试耗尽');
      } finally {
        gate.complete();
      }
    }();
  }

  String _resolveSmbPath(String relativePath) {
    final relSegments = relativePath
        .replaceAll('\\', '/')
        .split('/')
        .where((s) => s.isNotEmpty && s != '.')
        .toList();
    if (relSegments.any((s) => s == '..')) {
      throw ArgumentError('非法 SMB 相对路径: $relativePath');
    }
    final baseSegments = _rootUri.pathSegments.where((s) => s.isNotEmpty);
    return '/${<String>[...baseSegments, ...relSegments].join('/')}';
  }

  String _joinRelative(String baseRel, String childName) {
    if (baseRel.isEmpty) return childName;
    return '${baseRel.replaceAll(RegExp(r'/+$'), '')}/$childName';
  }

  @override
  Future<List<RemoteEntry>> listDirectory(String relativePath) {
    return _runSerialized((client) async {
      final smbPath = _resolveSmbPath(relativePath);
      final folder = await client.file(smbPath);
      if (!folder.isExists) {
        if (relativePath.trim().isEmpty) {
          throw SourceAccessException(
            SourceAccessProblemKind.path,
            SourceAccessErrorClassifier.formatKind(
              SourceAccessProblemKind.path,
              MediaSourceKind.smb,
            ),
          );
        }
        return const <RemoteEntry>[];
      }
      final files = await client.listFiles(folder);
      final entries = <RemoteEntry>[];
      for (final file in files) {
        final name = file.name;
        if (name == '.' || name == '..') continue;
        final isDir = file.isDirectory();
        entries.add(
          RemoteEntry(
            relativePath: _joinRelative(relativePath, name),
            name: name,
            isDirectory: isDir,
            size: isDir ? 0 : file.size,
            modifiedAt: file.lastModified > 0
                ? DateTime.fromMillisecondsSinceEpoch(
                    file.lastModified,
                    isUtc: true,
                  )
                : null,
          ),
        );
      }
      entries.sort((a, b) {
        if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      return entries;
    });
  }

  @override
  Future<String?> readTextFile(
    String relativePath, {
    int maxBytes = 256 * 1024,
  }) {
    return _runSerialized((client) async {
      final smbPath = _resolveSmbPath(relativePath);
      final file = await client.file(smbPath);
      if (!file.isExists) return null;
      final stream = await client.openRead(file);
      final bytes = <int>[];
      await for (final chunk in stream) {
        final remaining = maxBytes - bytes.length;
        if (remaining <= 0) break;
        if (chunk.length <= remaining) {
          bytes.addAll(chunk);
        } else {
          bytes.addAll(chunk.sublist(0, remaining));
          break;
        }
      }
      return utf8.decode(bytes, allowMalformed: true);
    });
  }

  @override
  Future<({int? length, String? validator})> probeFileMetadata(
    String relativePath,
  ) {
    return _runSerialized((client) async {
      final file = await client.file(_resolveSmbPath(relativePath));
      if (!file.isExists || file.isDirectory()) {
        return (length: null, validator: null);
      }
      final validator = file.lastModified > 0
          ? 'mtime:${file.lastModified}'
          : null;
      return (length: file.size, validator: validator);
    });
  }

  @override
  Future<int?> probeFileLength(String relativePath) {
    return _runSerialized((client) async {
      final file = await client.file(_resolveSmbPath(relativePath));
      if (!file.isExists || file.isDirectory()) return null;
      return file.size;
    });
  }

  @override
  Future<Stream<List<int>>> openByteRange(
    String relativePath, {
    required int start,
    int? endInclusive,
  }) async {
    // 若已传入明确的区间右边界，免去额外的长度探测串行往返；仅开放尾部请求才探测总字节数。
    final int targetEndExclusive;
    if (endInclusive != null) {
      if (endInclusive < start) {
        return const Stream<List<int>>.empty();
      }
      targetEndExclusive = endInclusive + 1;
    } else {
      final total = await probeFileLength(relativePath);
      if (total == null || start >= total) {
        return const Stream<List<int>>.empty();
      }
      targetEndExclusive = total;
    }

    // 使用 256 KiB 分片窗口并严格响应背压，让高优并发定位与尾部索引请求能快速插队完成。
    const windowSize = 256 * 1024;
    var cancelled = false;
    Completer<void>? resumeSignal;
    late final StreamController<List<int>> controller;

    controller = StreamController<List<int>>(
      onResume: () {
        final signal = resumeSignal;
        if (signal != null && !signal.isCompleted) {
          signal.complete();
        }
        resumeSignal = null;
      },
      onCancel: () {
        cancelled = true;
        final signal = resumeSignal;
        if (signal != null && !signal.isCompleted) {
          signal.complete();
        }
        resumeSignal = null;
      },
    );

    unawaited(() async {
      try {
        var cursor = start;
        while (cursor < targetEndExclusive && !cancelled && !_closed) {
          if (controller.isPaused) {
            final waiter = Completer<void>();
            resumeSignal = waiter;
            await waiter.future;
            if (cancelled || _closed) {
              break;
            }
          }

          final sliceEnd = math.min(cursor + windowSize, targetEndExclusive);
          await _runSerialized((client) async {
            final file = await client.file(_resolveSmbPath(relativePath));
            if (!file.isExists) {
              throw const SourceAccessException(
                SourceAccessProblemKind.path,
                'SMB 文件不存在或已被移除',
              );
            }
            final chunkStream = await client.openRead(file, cursor, sliceEnd);
            await for (final chunk in chunkStream) {
              if (cancelled || _closed) break;
              if (!controller.isClosed) {
                controller.add(chunk);
              }
            }
          });
          cursor = sliceEnd;
          // 释放串行锁后让出一次事件循环调度权，防止长顺流饿死并发请求。
          await Future<void>.delayed(Duration.zero);
        }
      } catch (error, stackTrace) {
        if (!cancelled && !controller.isClosed) {
          controller.addError(error, stackTrace);
        }
      } finally {
        if (!controller.isClosed) {
          await controller.close();
        }
      }
    }());

    return controller.stream;
  }

  @override
  Future<String?> testConnection() async {
    try {
      await listDirectory('');
      return null;
    } catch (error) {
      return SourceAccessErrorClassifier.toChineseMessage(
        error,
        MediaSourceKind.smb,
      );
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    await _resetClient();
  }
}
