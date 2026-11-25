import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:konata_contracts/konata_contracts.dart';

import 'guangya_protocol.dart';

/// 协议与文件访问解耦；上游更换不改变媒体源接口。
final class GuangYaGateway implements CloudDriveGateway {
  GuangYaGateway({
    required this.protocol,
    required this.rootId,
    HttpClient Function()? createHttpClient,
    Duration directoryCacheTtl = const Duration(seconds: 30),
  }) : _createHttpClient = createHttpClient ?? HttpClient.new,
       _directoryCacheTtl = directoryCacheTtl {
    if (directoryCacheTtl.isNegative) {
      throw ArgumentError('云盘目录缓存有效期不能为负数');
    }
  }
  final GuangYaProtocol protocol;
  final String rootId;
  final HttpClient Function() _createHttpClient;
  HttpClient? _http;
  bool _closed = false;
  final Duration _directoryCacheTtl;
  final Stopwatch _directoryClock = Stopwatch()..start();
  final _directories = <String, ({List<GuangYaFile> files, int expiresAtMs})>{};
  final _pending = <String, Future<List<GuangYaFile>>>{};
  final _links = <String, _FileUpstream>{};

  /// 按稳定文件标识持有有界直链会话，只有访问时才刷新。
  Future<RenewableUpstream> upstreamFor(String relativePath) async {
    final file = await _resolve(relativePath);
    final size = file.size;
    if (file.directory || size == null || size <= 0) {
      throw const SourceAccessException(
        SourceAccessProblemKind.path,
        '云盘文件长度未知',
      );
    }
    return _upstream(file.id, size);
  }

  _FileUpstream _upstream(String id, int size) {
    _check();
    final existing = _links[id];
    if (existing != null && existing.totalSize != size) {
      throw const UpstreamRangeMismatchException('云盘文件长度发生变化');
    }
    _links.remove(id);
    final value =
        existing ??
        _FileUpstream(size, _check, () {
          _check();
          return protocol.link(id);
        });
    _links[id] = value;
    if (_links.length > 256) _links.remove(_links.keys.first);
    return value;
  }

  void _check() {
    if (_closed) {
      throw const SourceAccessException(
        SourceAccessProblemKind.network,
        '云盘网关已关闭',
      );
    }
  }

  List<String> _parts(String path) {
    final parts = path.isEmpty ? <String>[] : path.split('/');
    if (parts.any(
      (p) => p.isEmpty || p == '.' || p == '..' || p.contains('\\'),
    )) {
      throw const SourceAccessException(
        SourceAccessProblemKind.path,
        '云盘相对路径不合法',
      );
    }
    return parts;
  }

  Future<List<GuangYaFile>> _children(String id) async {
    _check();
    final existing = _directories.remove(id);
    if (existing != null &&
        _directoryClock.elapsedMilliseconds < existing.expiresAtMs) {
      _directories[id] = existing;
      return existing.files;
    }
    final active = _pending[id];
    if (active != null) return active;
    final task = protocol.list(id);
    _pending[id] = task;
    try {
      final files = await task;
      _check();
      _directories[id] = (
        files: List<GuangYaFile>.unmodifiable(files),
        expiresAtMs:
            _directoryClock.elapsedMilliseconds +
            _directoryCacheTtl.inMilliseconds,
      );
      if (_directories.length > 64) {
        _directories.remove(_directories.keys.first);
      }
      return _directories[id]!.files;
    } finally {
      unawaited(_pending.remove(id));
    }
  }

  Future<GuangYaFile> _resolve(String relativePath) async {
    final parts = _parts(relativePath);
    GuangYaFile entry = (id: rootId, name: '', directory: true, size: 0);
    for (final name in parts) {
      if (!entry.directory) {
        throw const SourceAccessException(
          SourceAccessProblemKind.path,
          '云盘上级不是目录',
        );
      }
      final matches = (await _children(
        entry.id,
      )).where((e) => e.name == name).toList();
      if (matches.length != 1) {
        throw const SourceAccessException(
          SourceAccessProblemKind.path,
          '云盘路径不存在或存在重名项',
        );
      }
      entry = matches.single;
    }
    return entry;
  }

  @override
  Future<List<RemoteEntry>> listDirectory(String relativePath) async {
    final folder = await _resolve(relativePath);
    if (!folder.directory) {
      throw const SourceAccessException(
        SourceAccessProblemKind.path,
        '云盘目标不是目录',
      );
    }
    return [
      for (final file in await _children(folder.id))
        RemoteEntry(
          name: file.name,
          relativePath: relativePath.isEmpty
              ? file.name
              : '$relativePath/${file.name}',
          isDirectory: file.directory,
          size: file.size ?? 0,
          remoteFileId: file.id,
        ),
    ];
  }

  @override
  Future<int?> probeFileLength(String relativePath) async {
    final file = await _resolve(relativePath);
    return file.directory ? null : file.size;
  }

  @override
  Future<({int? length, String? validator})> probeFileMetadata(
    String relativePath,
  ) async => (length: await probeFileLength(relativePath), validator: null);

  @override
  Future<ValidatedByteRangeStream> openValidatedByteRange(
    String relativePath, {
    required int start,
    int? endInclusive,
    String? expectedStrongValidator,
  }) async {
    final file = await _resolve(relativePath);
    final size = file.size;
    if (file.directory ||
        size == null ||
        size <= 0 ||
        start < 0 ||
        start >= size) {
      throw const SourceAccessException(
        SourceAccessProblemKind.path,
        '云盘文件长度或读取范围无效',
      );
    }
    final end = endInclusive ?? size - 1;
    if (end < start || end >= size) {
      throw const UpstreamRangeMismatchException('请求范围超出文件长度');
    }
    final upstream = _upstream(file.id, size);
    var link = await upstream.current();
    for (var attempt = 0; attempt < 2; attempt++) {
      _check();
      if (link.uri.scheme != 'https' ||
          link.uri.userInfo.isNotEmpty ||
          link.uri.host.isEmpty ||
          link.uri.hasFragment) {
        throw const SourceAccessException(
          SourceAccessProblemKind.permission,
          '不安全的云盘直链',
        );
      }
      final http = _http ??= _createHttpClient()
        ..autoUncompress = false
        ..connectionTimeout = const Duration(seconds: 15);
      for (final header in link.headers.entries) {
        if (!{'user-agent', 'referer'}.contains(header.key.toLowerCase())) {
          throw const SourceAccessException(
            SourceAccessProblemKind.permission,
            '云盘直链请求头未获许可',
          );
        }
      }
      HttpClientResponse response;
      HttpClientRequest? pendingRequest;
      try {
        final request = await http
            .getUrl(link.uri)
            .timeout(const Duration(seconds: 15));
        pendingRequest = request;
        _check();
        request.followRedirects = false;
        for (final header in link.headers.entries) {
          request.headers.set(header.key, header.value);
        }
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$end');
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        response = await request.close().timeout(const Duration(seconds: 15));
      } on SourceAccessException {
        pendingRequest?.abort();
        rethrow;
      } catch (_) {
        pendingRequest?.abort();
        throw const SourceAccessException(
          SourceAccessProblemKind.network,
          '云盘直链请求失败',
        );
      }
      if (_closed) {
        await response.listen(null).cancel();
        _check();
      }
      if ({401, 403, 410}.contains(response.statusCode)) {
        await response.listen(null).cancel();
        if (attempt == 0) {
          link = await upstream.renewIfCurrent(link);
          continue;
        }
        throw TerminalSourceAuthException(
          '云盘直链续期后仍被拒绝',
          statusCode: response.statusCode,
        );
      }
      final range = response.headers.value(HttpHeaders.contentRangeHeader);
      final rawTag = response.headers.value(HttpHeaders.etagHeader);
      final strong =
          rawTag != null && rawTag.startsWith('"') && rawTag.endsWith('"')
          ? rawTag
          : null;
      final encoding = response.headers.value(
        HttpHeaders.contentEncodingHeader,
      );
      if (response.statusCode != 206 ||
          range != 'bytes $start-$end/$size' ||
          (encoding != null && encoding != 'identity') ||
          (expectedStrongValidator != null &&
              expectedStrongValidator != strong) ||
          (upstream.strongValidator != null &&
              upstream.strongValidator != strong)) {
        await response.listen(null).cancel();
        throw const UpstreamRangeMismatchException('云盘范围、长度或文件版本不一致');
      }
      upstream.observe(strong);
      return ValidatedByteRangeStream(
        stream: _bounded(response, end - start + 1),
        start: start,
        endInclusive: end,
        totalLength: size,
        strongValidator: strong,
      );
    }
    throw const SourceAccessException(
      SourceAccessProblemKind.authentication,
      '云盘直链续期失败',
    );
  }

  /// 不缓存完整媒体；消费方取消时由异步迭代取消底层订阅。
  Stream<List<int>> _bounded(HttpClientResponse response, int expected) async* {
    var sent = 0;
    try {
      await for (final chunk in response.timeout(const Duration(seconds: 15))) {
        if (sent + chunk.length > expected) {
          throw const UpstreamRangeMismatchException('云盘响应超出请求范围');
        }
        sent += chunk.length;
        yield chunk;
      }
    } on UpstreamRangeMismatchException {
      rethrow;
    } catch (_) {
      throw const SourceAccessException(
        SourceAccessProblemKind.network,
        '云盘字节流中断',
      );
    }
    if (sent != expected) {
      throw const SourceAccessException(
        SourceAccessProblemKind.network,
        '云盘字节流提前结束',
      );
    }
  }

  @override
  Future<Stream<List<int>>> openByteRange(
    String relativePath, {
    required int start,
    int? endInclusive,
  }) async => (await openValidatedByteRange(
    relativePath,
    start: start,
    endInclusive: endInclusive,
  )).stream;

  @override
  Future<String?> readTextFile(
    String relativePath, {
    int maxBytes = 256 * 1024,
  }) async {
    final length = await probeFileLength(relativePath);
    if (length == null || length > maxBytes || length < 0) return null;
    if (length == 0) return '';
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in await openByteRange(
      relativePath,
      start: 0,
      endInclusive: length - 1,
    )) {
      bytes.add(chunk);
    }
    return utf8.decode(bytes.takeBytes(), allowMalformed: true);
  }

  @override
  Future<String?> testConnection() async {
    try {
      await listDirectory('');
      return null;
    } on SourceAccessException catch (e) {
      return e.message;
    } catch (_) {
      return '云盘连接失败';
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    _directories.clear();
    _pending.clear();
    _links.clear();
    _http?.close(force: true);
    _http = null;
    await protocol.close();
  }
}

/// 既有接口未公开有效期，短期内存复用并在实际拒绝时单飞换链。
final class _FileUpstream implements RenewableUpstream {
  _FileUpstream(this.totalSize, this._check, this._fetch);
  @override
  final int totalSize;
  final void Function() _check;
  final Future<RenewableLink> Function() _fetch;
  final Stopwatch _clock = Stopwatch()..start();
  RenewableLink? _link;
  Future<RenewableLink>? _pending;
  int _expires = 0;
  String? _validator;

  @override
  String? get strongValidator => _validator;

  void observe(String? validator) {
    _validator ??= validator;
  }

  @override
  Future<RenewableLink> current() async {
    _check();
    final pending = _pending;
    if (pending != null) return pending;
    final link = _link;
    if (link != null && _clock.elapsedMilliseconds < _expires) return link;
    return renew();
  }

  Future<RenewableLink> renewIfCurrent(RenewableLink rejected) async {
    final link = _link;
    if (link != null && !identical(link, rejected)) return current();
    return renew();
  }

  @override
  Future<RenewableLink> renew() async {
    _check();
    final pending = _pending;
    if (pending != null) return pending;
    final task = _fetch().then((link) {
      _check();
      _link = link;
      _expires = _clock.elapsedMilliseconds + 30000;
      return link;
    });
    _pending = task;
    try {
      return await task;
    } finally {
      _pending = null;
    }
  }
}
