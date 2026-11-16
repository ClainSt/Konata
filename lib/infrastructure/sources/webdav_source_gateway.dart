import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:xml/xml.dart';

import '../../domain/models/media_source.dart';
import '../../domain/repositories/file_system_gateway.dart';
import 'byte_stream_source_gateway.dart';
import 'source_access_error.dart';
import 'webdav_digest_auth.dart';

/// WebDAV 网关集中配置常量。
abstract final class WebDavGatewayConfig {
  /// 默认单次 HTTP 请求超时。
  static const Duration defaultRequestTimeout = Duration(seconds: 15);

  /// 持久连接空闲保活时长。
  static const Duration idleKeepAliveTimeout = Duration(seconds: 60);

  /// 单主机最大并发 Keep-Alive 连接数。
  static const int maxConnectionsPerHost = 8;

  /// 允许跟踪的最大 30x 重定向跳数（防重定向循环）。
  static const int maxRedirects = 5;
}

class _WebDavPoolSlot {
  _WebDavPoolSlot({required this.client, this.ioClient});

  final HttpClient? ioClient;
  final http.Client client;
  String? digestChallenge;
  int nonceCount = 0;

  void close() {
    client.close();
    ioClient?.close(force: true);
  }
}

/// 跨网关实例共享的 WebDAV HTTP Keep-Alive 连接池与 Digest 质询缓存。
class WebDavConnectionPool {
  WebDavConnectionPool({this.clientBuilder});

  final http.Client Function()? clientBuilder;
  final Map<String, _WebDavPoolSlot> _slots = {};
  bool _disposed = false;

  /// 根据协议、主机、端口、用户名及密码摘要构建隔离池键（绝不以明文缓存密码）。
  static String buildOriginKey({
    required Uri rootUri,
    String? username,
    String? password,
  }) {
    final scheme = rootUri.scheme.toLowerCase();
    final host = rootUri.host.toLowerCase();
    final port = rootUri.port;
    final user = username ?? '';
    final pwdHash = sha256.convert(utf8.encode(password ?? '')).toString();
    return '$scheme://$host:$port|$user|$pwdHash';
  }

  /// 当前连接池中已缓存的主机凭据槽位数量。
  int get activeHostCount => _slots.length;

  /// 获取或创建对应主机与凭据组合的持久 [http.Client]。
  http.Client acquireClient({
    required Uri rootUri,
    String? username,
    String? password,
  }) {
    if (_disposed) {
      throw StateError('WebDavConnectionPool has been disposed');
    }
    final key = buildOriginKey(
      rootUri: rootUri,
      username: username,
      password: password,
    );
    return _ensureSlot(key).client;
  }

  _WebDavPoolSlot _ensureSlot(String key) {
    return _slots.putIfAbsent(key, () {
      if (clientBuilder != null) {
        return _WebDavPoolSlot(client: clientBuilder!());
      }
      final io = HttpClient()
        ..maxConnectionsPerHost = WebDavGatewayConfig.maxConnectionsPerHost
        ..idleTimeout = WebDavGatewayConfig.idleKeepAliveTimeout;
      return _WebDavPoolSlot(ioClient: io, client: IOClient(io));
    });
  }

  /// 读取对应源站最近缓存的 Digest `WWW-Authenticate` 质询头。
  String? readDigestChallenge({
    required Uri rootUri,
    String? username,
    String? password,
  }) {
    final key = buildOriginKey(
      rootUri: rootUri,
      username: username,
      password: password,
    );
    return _slots[key]?.digestChallenge;
  }

  /// 记录对应源站返回的最新 Digest `WWW-Authenticate` 质询并复位 nonce 计数。
  void rememberDigestChallenge({
    required Uri rootUri,
    String? username,
    String? password,
    required String challenge,
  }) {
    if (_disposed) return;
    final key = buildOriginKey(
      rootUri: rootUri,
      username: username,
      password: password,
    );
    final slot = _ensureSlot(key);
    slot.digestChallenge = challenge;
    slot.nonceCount = 0;
  }

  int _nextNonceCount({
    required Uri rootUri,
    String? username,
    String? password,
  }) {
    if (_disposed) return 1;
    final key = buildOriginKey(
      rootUri: rootUri,
      username: username,
      password: password,
    );
    final slot = _slots[key];
    if (slot == null) return 1;
    slot.nonceCount += 1;
    return slot.nonceCount;
  }

  /// 释放所有池化 HTTP 连接句柄与缓存质询（随全局容器销毁调用）。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final slot in _slots.values) {
      slot.close();
    }
    _slots.clear();
  }
}

/// WebDAV 远程媒体源只读网关（支持 Basic / Digest 质询认证、30x 跨源凭据隔离与字节范围流式读取）。
class WebDavSourceGateway
    implements MediaSourceGateway, ByteRangeReadableGateway {
  /// 创建 WebDAV 网关。
  WebDavSourceGateway({
    required Uri rootUri,
    this.username,
    this.password,
    http.Client? httpClient,
    WebDavConnectionPool? connectionPool,
    this.requestTimeout = WebDavGatewayConfig.defaultRequestTimeout,
  }) : _rootUri = _normalizeRoot(rootUri),
       _connectionPool = connectionPool,
       _client =
           httpClient ??
           (connectionPool != null
               ? connectionPool.acquireClient(
                   rootUri: _normalizeRoot(rootUri),
                   username: username,
                   password: password,
                 )
               : _createDefaultHttpClient()),
       _ownsClient = httpClient == null && connectionPool == null;

  static http.Client _createDefaultHttpClient() {
    final io = HttpClient()
      ..maxConnectionsPerHost = WebDavGatewayConfig.maxConnectionsPerHost
      ..idleTimeout = WebDavGatewayConfig.idleKeepAliveTimeout;
    return IOClient(io);
  }

  final Uri _rootUri;
  final String? username;
  final String? password;
  final WebDavConnectionPool? _connectionPool;
  final http.Client _client;
  final bool _ownsClient;

  /// 单次 WebDAV 请求超时上限。
  final Duration requestTimeout;

  String? _lastDigestChallenge;
  int _nonceCount = 0;

  static Uri _normalizeRoot(Uri uri) {
    final path = uri.path.endsWith('/') ? uri.path : '${uri.path}/';
    return uri.replace(path: path);
  }

  static const String _propfindBody = '''<?xml version="1.0" encoding="utf-8" ?>
<D:propfind xmlns:D="DAV:">
  <D:prop>
    <D:resourcetype/>
    <D:getcontentlength/>
    <D:getlastmodified/>
  </D:prop>
</D:propfind>''';

  Map<String, String> _buildAuthHeaders({
    required String method,
    required Uri uri,
    Map<String, String>? extra,
    String? overrideChallenge,
  }) {
    final headers = <String, String>{...?extra};
    final user = username;
    if (user == null || user.isEmpty) {
      return headers;
    }

    final pooledChallenge = _connectionPool?.readDigestChallenge(
      rootUri: _rootUri,
      username: user,
      password: password,
    );
    final challenge =
        overrideChallenge ?? pooledChallenge ?? _lastDigestChallenge;
    if (challenge != null) {
      final nc = _connectionPool != null
          ? _connectionPool._nextNonceCount(
              rootUri: _rootUri,
              username: user,
              password: password,
            )
          : (++_nonceCount);
      final digestHeader = WebDavDigestAuth.buildAuthorizationHeader(
        wwwAuthenticateHeader: challenge,
        method: method,
        uri: uri,
        username: user,
        password: password ?? '',
        nonceCount: nc,
      );
      if (digestHeader != null) {
        headers[HttpHeaders.authorizationHeader] = digestHeader;
        return headers;
      }
    }

    final token = base64Encode(utf8.encode('$user:${password ?? ''}'));
    headers[HttpHeaders.authorizationHeader] = 'Basic $token';
    return headers;
  }

  Uri _resolveUri(String relativePath, {required bool asDirectory}) {
    final segments = relativePath
        .replaceAll('\\', '/')
        .split('/')
        .where((s) => s.isNotEmpty && s != '.')
        .toList();
    if (segments.any((s) => s == '..')) {
      throw ArgumentError('非法相对路径: $relativePath');
    }
    final baseSegments = _rootUri.pathSegments.where((s) => s.isNotEmpty);
    final all = [...baseSegments, ...segments];
    final joined = '/${all.join('/')}${asDirectory ? '/' : ''}';
    return _rootUri.replace(path: joined);
  }

  static bool _isSameOrigin(Uri a, Uri b) {
    return a.scheme.toLowerCase() == b.scheme.toLowerCase() &&
        a.host.toLowerCase() == b.host.toLowerCase() &&
        a.port == b.port;
  }

  static bool _isRedirectStatus(int statusCode) {
    return statusCode == HttpStatus.movedPermanently ||
        statusCode == HttpStatus.found ||
        statusCode == HttpStatus.seeOther ||
        statusCode == HttpStatus.temporaryRedirect ||
        statusCode == HttpStatus.permanentRedirect;
  }

  Future<http.StreamedResponse> _sendSingleWithDigest({
    required String method,
    required Uri uri,
    required bool includeCredentials,
    Map<String, String>? extraHeaders,
    String? body,
    required http.Client activeClient,
  }) async {
    http.Request build(Map<String, String> headers) {
      final req = http.Request(method, uri)
        ..followRedirects = false
        ..headers.addAll(headers);
      if (body != null) {
        req.body = body;
      }
      return req;
    }

    final initialHeaders = includeCredentials
        ? _buildAuthHeaders(method: method, uri: uri, extra: extraHeaders)
        : <String, String>{...?extraHeaders};
    var streamed = await activeClient
        .send(build(initialHeaders))
        .timeout(requestTimeout);

    if (includeCredentials &&
        streamed.statusCode == 401 &&
        username != null &&
        username!.isNotEmpty) {
      final wwwAuth =
          streamed.headers['www-authenticate'] ??
          streamed.headers['WWW-Authenticate'];
      if (wwwAuth != null && wwwAuth.toLowerCase().contains('digest ')) {
        await streamed.stream.drain<void>();
        _lastDigestChallenge = wwwAuth;
        _nonceCount = 0;
        _connectionPool?.rememberDigestChallenge(
          rootUri: _rootUri,
          username: username,
          password: password,
          challenge: wwwAuth,
        );
        final retryHeaders = _buildAuthHeaders(
          method: method,
          uri: uri,
          extra: extraHeaders,
          overrideChallenge: wwwAuth,
        );
        streamed = await activeClient
            .send(build(retryHeaders))
            .timeout(requestTimeout);
      }
    }
    return streamed;
  }

  Future<http.StreamedResponse> _sendWithDigestRetry(
    http.Request Function(Map<String, String> authHeaders) buildRequest, {
    required String method,
    required Uri uri,
    Map<String, String>? extraHeaders,
    String? body,
    http.Client? client,
  }) async {
    final activeClient = client ?? _client;
    var currentUri = uri;
    var currentMethod = method;
    var allowCredentials = _isSameOrigin(_rootUri, currentUri);

    for (var hop = 0; hop <= WebDavGatewayConfig.maxRedirects; hop++) {
      final streamed = await _sendSingleWithDigest(
        method: currentMethod,
        uri: currentUri,
        includeCredentials: allowCredentials,
        extraHeaders: extraHeaders,
        body: body ?? (hop == 0 ? buildRequest(const {}).body : null),
        activeClient: activeClient,
      );

      if (!_isRedirectStatus(streamed.statusCode)) {
        return streamed;
      }

      final location =
          streamed.headers[HttpHeaders.locationHeader] ??
          streamed.headers['Location'];
      if (location == null || location.trim().isEmpty) {
        return streamed;
      }

      await streamed.stream.drain<void>();
      final nextUri = currentUri.resolve(location.trim());
      // 严格 30x 跨源凭据隔离：一旦跳转至不同协议/主机/端口，立即剥离 Authorization。
      if (!_isSameOrigin(_rootUri, nextUri)) {
        allowCredentials = false;
      }
      if (streamed.statusCode == HttpStatus.seeOther) {
        currentMethod = 'GET';
      }
      currentUri = nextUri;
    }

    throw HttpException('WebDAV 重定向次数过多', uri: currentUri);
  }

  @override
  Future<List<RemoteEntry>> listDirectory(String relativePath) async {
    final targetUri = _resolveUri(relativePath, asDirectory: true);
    final streamed = await _sendWithDigestRetry(
      (headers) => http.Request('PROPFIND', targetUri)
        ..headers.addAll(headers)
        ..body = _propfindBody,
      method: 'PROPFIND',
      uri: targetUri,
      extraHeaders: const {
        'Depth': '1',
        HttpHeaders.contentTypeHeader: 'application/xml; charset=utf-8',
      },
    );
    final response = await http.Response.fromStream(
      streamed,
    ).timeout(requestTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'WebDAV PROPFIND 失败: HTTP ${response.statusCode}',
        uri: targetUri,
      );
    }

    return _parsePropfindXml(
      utf8.decode(response.bodyBytes, allowMalformed: true),
      targetUri,
      relativePath,
    );
  }

  List<RemoteEntry> _parsePropfindXml(
    String xmlText,
    Uri requestUri,
    String requestRelativePath,
  ) {
    final doc = XmlDocument.parse(xmlText);
    final decodedRoot = Uri.decodeFull(_rootUri.path);
    final rootPrefix = decodedRoot.endsWith('/') ? decodedRoot : '$decodedRoot/';
    final requestPath = _normalizeComparePath(Uri.decodeFull(requestUri.path));
    final normalizedSelfRel = requestRelativePath
        .trim()
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'^/+|/+$'), '');
    final entries = <RemoteEntry>[];

    for (final node in doc.findAllElements('response', namespaceUri: '*')) {
      final hrefNode = node.findElements('href', namespaceUri: '*').firstOrNull;
      if (hrefNode == null) continue;
      final rawHref = hrefNode.innerText.trim();
      final parsedHref = Uri.tryParse(rawHref);
      final hrefPath = Uri.decodeFull(parsedHref?.path ?? rawHref);
      if (_normalizeComparePath(hrefPath) == requestPath) continue;

      final prop = node
          .findAllElements('propstat', namespaceUri: '*')
          .expand((ps) => ps.findElements('prop', namespaceUri: '*'))
          .firstOrNull;
      if (prop == null) continue;

      final isDir =
          prop
              .findElements('resourcetype', namespaceUri: '*')
              .expand((rt) => rt.findElements('collection', namespaceUri: '*'))
              .isNotEmpty ||
          hrefPath.endsWith('/');

      final sizeText =
          prop
              .findElements('getcontentlength', namespaceUri: '*')
              .firstOrNull
              ?.innerText
              .trim() ??
          '0';
      final size = int.tryParse(sizeText) ?? 0;

      final modifiedText = prop
          .findElements('getlastmodified', namespaceUri: '*')
          .firstOrNull
          ?.innerText
          .trim();
      DateTime? modifiedAt;
      if (modifiedText != null && modifiedText.isNotEmpty) {
        try {
          modifiedAt = HttpDate.parse(modifiedText);
        } catch (_) {}
      }

      var relPath = hrefPath;
      if (relPath.startsWith(rootPrefix)) {
        relPath = relPath.substring(rootPrefix.length);
      } else if (_normalizeComparePath(relPath) ==
          _normalizeComparePath(rootPrefix)) {
        continue;
      }
      relPath = relPath.replaceAll(RegExp(r'^/+|/+$'), '');
      if (relPath.isEmpty || relPath == normalizedSelfRel) continue;

      entries.add(
        RemoteEntry(
          relativePath: relPath,
          name: relPath.split('/').last,
          isDirectory: isDir,
          size: isDir ? 0 : size,
          modifiedAt: modifiedAt,
        ),
      );
    }

    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  String _normalizeComparePath(String path) =>
      path.replaceAll(RegExp(r'/+$'), '');

  @override
  Future<String?> readTextFile(
    String relativePath, {
    int maxBytes = 256 * 1024,
  }) async {
    final uri = _resolveUri(relativePath, asDirectory: false);
    final streamed = await _sendWithDigestRetry(
      (headers) => http.Request('GET', uri)..headers.addAll(headers),
      method: 'GET',
      uri: uri,
      extraHeaders: {'Range': 'bytes=0-${maxBytes - 1}'},
    );
    final response = await http.Response.fromStream(
      streamed,
    ).timeout(requestTimeout);
    if (response.statusCode == 404) return null;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'WebDAV 读取文本失败: HTTP ${response.statusCode}',
        uri: uri,
      );
    }
    final bytes = response.bodyBytes.length > maxBytes
        ? response.bodyBytes.sublist(0, maxBytes)
        : response.bodyBytes;
    return utf8.decode(bytes, allowMalformed: true);
  }

  @override
  Future<int?> probeFileLength(String relativePath) async {
    final uri = _resolveUri(relativePath, asDirectory: false);
    final streamed = await _sendWithDigestRetry(
      (headers) => http.Request('HEAD', uri)..headers.addAll(headers),
      method: 'HEAD',
      uri: uri,
    );
    await streamed.stream.drain<void>();
    if (streamed.statusCode == 404) return null;
    if (streamed.statusCode >= 200 && streamed.statusCode < 300) {
      final lenStr = streamed.headers[HttpHeaders.contentLengthHeader];
      final parsed = lenStr != null ? int.tryParse(lenStr) : null;
      if (parsed != null && parsed > 0) return parsed;
    }

    // 兼容部分禁用 HEAD 或未返回 Content-Length 的 WebDAV 服务：回退至 bytes=0-0 探测 Content-Range 总长度。
    final probeResp = await _sendWithDigestRetry(
      (headers) => http.Request('GET', uri)..headers.addAll(headers),
      method: 'GET',
      uri: uri,
      extraHeaders: const {'Range': 'bytes=0-0'},
    );
    await probeResp.stream.drain<void>();
    if (probeResp.statusCode == 404) return null;
    final contentRange = probeResp.headers[HttpHeaders.contentRangeHeader];
    if (contentRange != null) {
      final match = RegExp(r'/\s*(\d+)\s*$').firstMatch(contentRange);
      final total = match != null ? int.tryParse(match.group(1)!) : null;
      if (total != null && total > 0) return total;
    }
    if (probeResp.statusCode == HttpStatus.ok) {
      final lenStr = probeResp.headers[HttpHeaders.contentLengthHeader];
      return lenStr != null ? int.tryParse(lenStr) : null;
    }
    return null;
  }

  @override
  Future<Stream<List<int>>> openByteRange(
    String relativePath, {
    required int start,
    int? endInclusive,
  }) async {
    final uri = _resolveUri(relativePath, asDirectory: false);
    final rangeHeader = endInclusive != null
        ? 'bytes=$start-$endInclusive'
        : 'bytes=$start-';

    // 复用持久 Keep-Alive HTTP 连接池与 Digest 质询认证缓存，消除分段 Seek / 读取的 TLS 与 401 冷启动开销。
    final http.StreamedResponse streamed = await _sendWithDigestRetry(
      (headers) => http.Request('GET', uri)..headers.addAll(headers),
      method: 'GET',
      uri: uri,
      extraHeaders: {'Range': rangeHeader},
      client: _client,
    );

    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      await streamed.stream.drain<void>().catchError((_) {});
      throw HttpException(
        'WebDAV 流式读取失败: HTTP ${streamed.statusCode}',
        uri: uri,
      );
    }

    StreamSubscription<List<int>>? upstreamSub;
    late final StreamController<List<int>> controller;
    controller = StreamController<List<int>>(
      onListen: () {
        upstreamSub = streamed.stream.listen(
          controller.add,
          onError: (Object error, StackTrace st) {
            if (!controller.isClosed) controller.addError(error, st);
          },
          onDone: () {
            if (!controller.isClosed) {
              unawaited(controller.close());
            }
          },
          cancelOnError: false,
        );
      },
      onPause: () => upstreamSub?.pause(),
      onResume: () => upstreamSub?.resume(),
      onCancel: () async {
        await upstreamSub?.cancel();
      },
    );
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
        MediaSourceKind.webdav,
      );
    }
  }

  @override
  Future<void> close() async {
    if (_ownsClient) {
      _client.close();
    }
  }
}
