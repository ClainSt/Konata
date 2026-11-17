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

  /// TCP 建连超时上限（快速失败防死连接挂起）。
  static const Duration defaultConnectTimeout = Duration(seconds: 6);

  /// `HEAD` 探测文件长度超时上限（超时立即降级 `Range: bytes=0-0`）。
  static const Duration defaultHeadProbeTimeout = Duration(seconds: 5);

  /// 远程流式读取首包响应头超时上限（兼容 AList / OpenList / CD2 云盘冷直链唤醒）。
  static const Duration defaultStreamOpenTimeout = Duration(seconds: 25);

  /// 持久连接空闲保活时长。
  static const Duration idleKeepAliveTimeout = Duration(seconds: 60);

  /// 单主机最大并发 Keep-Alive 连接数。
  static const int maxConnectionsPerHost = 8;

  /// 允许跟踪的最大 30x 重定向跳数（防重定向循环）。
  static const int maxRedirects = 5;

  /// 通用流媒体客户端标识（兼容各大网盘 302 CDN 与 WAF 放行策略）。
  static const String defaultUserAgent = 'VLC/3.0.20 LibVLC/3.0.20';

  /// 判断目标主机是否属于回环、RFC1918 局域网或 Tailscale/CGNAT 内网段（强制 DIRECT 直连绕过代理）。
  static bool isDirectBypassHost(String rawHost) {
    var host = rawHost.trim().toLowerCase();
    if (host.startsWith('[') && host.endsWith(']') && host.length > 2) {
      host = host.substring(1, host.length - 1);
    }
    if (host.isEmpty ||
        host == 'localhost' ||
        host == '::1' ||
        host == '0:0:0:0:0:0:0:1' ||
        host.endsWith('.local') ||
        host.endsWith('.lan') ||
        host.endsWith('.internal')) {
      return true;
    }
    if (host.startsWith('fe80:') ||
        host.startsWith('fc') ||
        host.startsWith('fd')) {
      return true;
    }
    final parts = host.split('.');
    if (parts.length == 4) {
      final o0 = int.tryParse(parts[0]);
      final o1 = int.tryParse(parts[1]);
      final o2 = int.tryParse(parts[2]);
      final o3 = int.tryParse(parts[3]);
      if (o0 != null && o1 != null && o2 != null && o3 != null) {
        if (o0 == 127 || o0 == 10) return true;
        if (o0 == 192 && o1 == 168) return true;
        if (o0 == 169 && o1 == 254) return true;
        if (o0 == 172 && o1 >= 16 && o1 <= 31) return true;
        if (o0 == 100 && o1 >= 64 && o1 <= 127) return true;
      }
    }
    return false;
  }

  /// 智能代理路由：内网与回环强制直连，公网地址尊重系统环境代理配置。
  static String resolveSmartProxy(Uri uri) {
    if (isDirectBypassHost(uri.host)) {
      return 'DIRECT';
    }
    try {
      return HttpClient.findProxyFromEnvironment(uri);
    } catch (_) {
      return 'DIRECT';
    }
  }

  /// 创建统一调优的底层 [HttpClient]。
  static HttpClient createConfiguredIoClient() {
    return HttpClient()
      ..connectionTimeout = defaultConnectTimeout
      ..maxConnectionsPerHost = maxConnectionsPerHost
      ..idleTimeout = idleKeepAliveTimeout
      ..userAgent = defaultUserAgent
      ..findProxy = resolveSmartProxy;
  }
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
      final io = WebDavGatewayConfig.createConfiguredIoClient();
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
    return IOClient(WebDavGatewayConfig.createConfiguredIoClient());
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

  /// 对路径逐段执行严格单次 UTF-8 百分号编码（确保 `+`->`%2B`、`&`->`%26`、`{}`/`[]`/空格精确编码且不二次编码 `%`）。
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
    final encodedSegments = all.map(Uri.encodeComponent).join('/');
    final encodedPath = all.isEmpty
        ? '/'
        : '/$encodedSegments${asDirectory ? '/' : ''}';
    final authority = _rootUri.hasAuthority ? '//${_rootUri.authority}' : '';
    return Uri.parse('${_rootUri.scheme}:$authority$encodedPath');
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
    Duration? timeoutOverride,
  }) async {
    final effectiveTimeout = timeoutOverride ?? requestTimeout;
    http.Request build(Map<String, String> headers) {
      final req = http.Request(method, uri)
        ..followRedirects = false
        ..headers.addAll(headers);
      req.headers.putIfAbsent(
        HttpHeaders.userAgentHeader,
        () => WebDavGatewayConfig.defaultUserAgent,
      );
      if (body != null) {
        req.body = body;
      }
      return req;
    }

    Future<http.StreamedResponse> sendWithStaleRetry(
      Map<String, String> headers,
    ) async {
      try {
        return await activeClient
            .send(build(headers))
            .timeout(effectiveTimeout);
      } catch (error) {
        // 当池化 Keep-Alive 连接被服务端半关闭时，立即换新连接无感重试一次。
        final isStaleSocket =
            error is SocketException ||
            error is HttpException ||
            error is http.ClientException;
        if (!isStaleSocket) rethrow;
        return activeClient.send(build(headers)).timeout(effectiveTimeout);
      }
    }

    final initialHeaders = includeCredentials
        ? _buildAuthHeaders(method: method, uri: uri, extra: extraHeaders)
        : <String, String>{...?extraHeaders};
    var streamed = await sendWithStaleRetry(initialHeaders);

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
        streamed = await sendWithStaleRetry(retryHeaders);
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
    Duration? timeoutOverride,
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
        timeoutOverride: timeoutOverride,
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
    final rootPrefix = decodedRoot.endsWith('/')
        ? decodedRoot
        : '$decodedRoot/';
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
    final headTimeout =
        requestTimeout < WebDavGatewayConfig.defaultHeadProbeTimeout
        ? requestTimeout
        : WebDavGatewayConfig.defaultHeadProbeTimeout;
    try {
      final streamed = await _sendWithDigestRetry(
        (headers) => http.Request('HEAD', uri)..headers.addAll(headers),
        method: 'HEAD',
        uri: uri,
        timeoutOverride: headTimeout,
      );
      await streamed.stream.drain<void>();
      if (streamed.statusCode == 404) return null;
      if (streamed.statusCode >= 200 && streamed.statusCode < 300) {
        final lenStr = streamed.headers[HttpHeaders.contentLengthHeader];
        final parsed = lenStr != null ? int.tryParse(lenStr) : null;
        if (parsed != null && parsed > 0) return parsed;
      }
    } catch (_) {
      // 兼容禁用 HEAD、对 HEAD 超时或主动断连的 WebDAV 驱动，立即回退 bytes=0-0。
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
    final streamTimeout =
        requestTimeout == WebDavGatewayConfig.defaultRequestTimeout
        ? WebDavGatewayConfig.defaultStreamOpenTimeout
        : requestTimeout;

    // 复用持久 Keep-Alive HTTP 连接池与 Digest 质询认证缓存，消除分段 Seek / 读取的 TLS 与 401 冷启动开销。
    final http.StreamedResponse streamed = await _sendWithDigestRetry(
      (headers) => http.Request('GET', uri)..headers.addAll(headers),
      method: 'GET',
      uri: uri,
      extraHeaders: {'Range': rangeHeader},
      client: _client,
      timeoutOverride: streamTimeout,
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
