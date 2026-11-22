import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:developer' as developer;

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

  /// 单主机最大并发 Keep-Alive 连接数（为视频/音频流、封面探测与画册灯箱预留充足并发槽位）。
  static const int maxConnectionsPerHost = 16;

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
    implements
        MediaSourceGateway,
        ValidatedByteRangeGateway,
        FileValidatorProbeGateway {
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
  final Set<Future<void> Function()> _activeStreamAborters = {};

  /// 安全排空并释放轻量 HTTP 响应体；超时则直接取消订阅切断底层连接，防止池槽位长期占用。
  static Future<void> _safeDrainResponse(http.StreamedResponse response) async {
    try {
      await response.stream
          .drain<void>()
          .timeout(const Duration(seconds: 5));
    } catch (error) {
      developer.log(
        '排空 WebDAV 轻量响应体超时或中断，改用强制取消',
        name: 'konata.webdav_source_gateway',
        error: error,
      );
      try {
        await response.stream.listen(null).cancel();
      } catch (cancelErr) {
        developer.log(
          '强制取消 WebDAV 响应流忽略',
          name: 'konata.webdav_source_gateway',
          error: cancelErr,
        );
      }
    }
  }

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
    <D:getetag/>
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
      if (body != null && body.isNotEmpty) {
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
        await _safeDrainResponse(streamed);
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
      final initialBody = body ?? (hop == 0 ? buildRequest(const {}).body : null);
      final streamed = await _sendSingleWithDigest(
        method: currentMethod,
        uri: currentUri,
        includeCredentials: allowCredentials,
        extraHeaders: extraHeaders,
        body: (initialBody != null && initialBody.isNotEmpty)
            ? initialBody
            : null,
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

      await _safeDrainResponse(streamed);
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
    if (response.statusCode == 429 ||
        response.statusCode == 503 ||
        response.statusCode == 509) {
      throw SourceRateLimitException(
        statusCode: response.statusCode,
        message: 'WebDAV PROPFIND 触发限流: HTTP ${response.statusCode}',
        retryAfter: SourceAccessErrorClassifier.parseRetryAfterHeader(
          response.headers,
        ),
        uri: targetUri,
      );
    }
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
        } on HttpException {
          modifiedAt = null;
        }
      }

      final etagText = prop
          .findElements('getetag', namespaceUri: '*')
          .firstOrNull
          ?.innerText
          .trim();
      final etag = (etagText != null && etagText.isNotEmpty) ? etagText : null;

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
          etag: etag,
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
    if (response.statusCode == 429 ||
        response.statusCode == 503 ||
        response.statusCode == 509) {
      throw SourceRateLimitException(
        statusCode: response.statusCode,
        message: 'WebDAV 读取文本触发限流: HTTP ${response.statusCode}',
        retryAfter: SourceAccessErrorClassifier.parseRetryAfterHeader(
          response.headers,
        ),
        uri: uri,
      );
    }
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

  static String? _extractCacheValidator(Map<String, String> headers) {
    final rawEtag = (headers[HttpHeaders.etagHeader] ?? headers['ETag'] ?? '')
        .trim();
    if (rawEtag.isNotEmpty) {
      return rawEtag;
    }
    final rawModified =
        (headers[HttpHeaders.lastModifiedHeader] ??
                headers['Last-Modified'] ??
                '')
            .trim();
    if (rawModified.isNotEmpty) {
      try {
        final parsed = HttpDate.parse(rawModified);
        return 'mtime:${parsed.toUtc().microsecondsSinceEpoch}';
      } on HttpException {
        return 'mtime:$rawModified';
      }
    }
    return null;
  }

  @override
  Future<({int? length, String? validator})> probeFileMetadata(
    String relativePath,
  ) async {
    final uri = _resolveUri(relativePath, asDirectory: false);
    final headTimeout =
        requestTimeout < WebDavGatewayConfig.defaultHeadProbeTimeout
        ? requestTimeout
        : WebDavGatewayConfig.defaultHeadProbeTimeout;
    String? headValidator;
    try {
      final streamed = await _sendWithDigestRetry(
        (headers) => http.Request('HEAD', uri)..headers.addAll(headers),
        method: 'HEAD',
        uri: uri,
        timeoutOverride: headTimeout,
      );
      await streamed.stream.drain<void>();
      if (streamed.statusCode == 404) {
        return (length: null, validator: null);
      }
      if (streamed.statusCode >= 200 && streamed.statusCode < 300) {
        headValidator = _extractCacheValidator(streamed.headers);
        final lenStr = streamed.headers[HttpHeaders.contentLengthHeader];
        final parsed = lenStr != null ? int.tryParse(lenStr) : null;
        if (parsed != null && parsed > 0) {
          return (length: parsed, validator: headValidator);
        }
      }
    } catch (error) {
      // 兼容禁用 HEAD、对 HEAD 超时或主动断连的 WebDAV 驱动，立即回退 bytes=0-0。
      developer.log('可恢复异常已记录', name: 'konata.webdav_source_gateway', error: error);
    }

    // 兼容部分禁用 HEAD 或未返回 Content-Length 的 WebDAV 服务：回退至 bytes=0-0 探测总长度与验证器。
    final probeResp = await _sendWithDigestRetry(
      (headers) => http.Request('GET', uri)..headers.addAll(headers),
      method: 'GET',
      uri: uri,
      extraHeaders: const {'Range': 'bytes=0-0'},
    );
    await probeResp.stream.listen(null).cancel();
    if (probeResp.statusCode == 404) {
      return (length: null, validator: null);
    }
    final validator =
        _extractCacheValidator(probeResp.headers) ?? headValidator;
    final contentRange = probeResp.headers[HttpHeaders.contentRangeHeader];
    if (contentRange != null) {
      final match = RegExp(r'/\s*(\d+)\s*$').firstMatch(contentRange);
      final total = match != null ? int.tryParse(match.group(1)!) : null;
      if (total != null && total > 0) {
        return (length: total, validator: validator);
      }
    }
    if (probeResp.statusCode == HttpStatus.ok) {
      final lenStr = probeResp.headers[HttpHeaders.contentLengthHeader];
      return (
        length: lenStr != null ? int.tryParse(lenStr) : null,
        validator: validator,
      );
    }
    return (length: null, validator: validator);
  }

  @override
  Future<int?> probeFileLength(String relativePath) async {
    final meta = await probeFileMetadata(relativePath);
    return meta.length;
  }

  static String? _extractStrongEtag(Map<String, String> headers) {
    final raw = (headers[HttpHeaders.etagHeader] ?? headers['ETag'] ?? '').trim();
    if (raw.isEmpty || raw.startsWith('W/') || raw.startsWith('w/')) {
      return null;
    }
    return raw;
  }

  @override
  Future<ValidatedByteRangeStream> openValidatedByteRange(
    String relativePath, {
    required int start,
    int? endInclusive,
    String? expectedStrongValidator,
  }) async {
    final uri = _resolveUri(relativePath, asDirectory: false);
    final streamTimeout =
        requestTimeout == WebDavGatewayConfig.defaultRequestTimeout
        ? WebDavGatewayConfig.defaultStreamOpenTimeout
        : requestTimeout;
    final hasValidator =
        expectedStrongValidator != null &&
        expectedStrongValidator.isNotEmpty &&
        !expectedStrongValidator.startsWith('W/') &&
        !expectedStrongValidator.startsWith('w/');
    final isFullFromStart =
        start == 0 && endInclusive == null && !hasValidator;
    final extraHeaders = <String, String>{};
    // 完整文件从头读取（如 Scan 原图与缩略图）走标准 HTTP GET，避免向 CloudDrive2/网盘发送开放式 bytes=0- Range 头引发兼容挂起。
    if (!isFullFromStart) {
      final rangeHeader = endInclusive != null
          ? 'bytes=$start-$endInclusive'
          : 'bytes=$start-';
      extraHeaders['Range'] = rangeHeader;
    }
    if (hasValidator) {
      extraHeaders[HttpHeaders.ifRangeHeader] = expectedStrongValidator;
    }

    // 复用持久 Keep-Alive HTTP 连接池与 Digest 质询认证缓存，消除分段 Seek / 读取的 TLS 与 401 冷启动开销。
    final http.StreamedResponse streamed = await _sendWithDigestRetry(
      (headers) => http.Request('GET', uri)..headers.addAll(headers),
      method: 'GET',
      uri: uri,
      extraHeaders: extraHeaders,
      client: _client,
      timeoutOverride: streamTimeout,
    );

    final status = streamed.statusCode;
    if (status == HttpStatus.unauthorized || status == HttpStatus.forbidden) {
      await streamed.stream.listen(null).cancel();
      throw TerminalSourceAuthException(
        status == HttpStatus.forbidden
            ? 'WebDAV 拒绝访问该资源 (HTTP 403)'
            : 'WebDAV 认证失败，请核对账号与密码 (HTTP 401)',
        statusCode: status,
      );
    }

    final strongEtag = _extractStrongEtag(streamed.headers);
    if (expectedStrongValidator != null &&
        expectedStrongValidator.isNotEmpty &&
        (strongEtag == null || strongEtag != expectedStrongValidator)) {
      await streamed.stream.listen(null).cancel();
      throw const UpstreamRangeMismatchException('远程文件强验证器已变化，终止断流续传防数据错位');
    }

    // 禁止把上游 200 全文件或错误的 206 范围当作目标字节区间透传：
    // 下游 LocalStreamBridge 会声明精确 Content-Range，错位数据会导致
    // MKV/FLAC 解复用失败，甚至被错误地缓存。
    final rangeValue = streamed.headers[HttpHeaders.contentRangeHeader];
    int? expectedBytes;
    int? totalLength;
    int actualEndValue = endInclusive ?? start;
    var isPartial = false;
    if (status == HttpStatus.partialContent) {
      isPartial = true;
      final match = rangeValue == null
          ? null
          : RegExp(
              r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$',
              caseSensitive: false,
            ).firstMatch(rangeValue.trim());
      final actualStart = match == null ? null : int.tryParse(match.group(1)!);
      final actualEnd = match == null ? null : int.tryParse(match.group(2)!);
      final total = match == null || match.group(3) == '*'
          ? null
          : int.tryParse(match.group(3)!);
      final expectedEnd = endInclusive == null
          ? null
          : (total != null && endInclusive >= total ? total - 1 : endInclusive);
      if (actualStart != start ||
          actualEnd == null ||
          actualEnd < start ||
          (expectedEnd != null && actualEnd != expectedEnd) ||
          (total != null && actualEnd >= total)) {
        await streamed.stream.listen(null).cancel();
        throw UpstreamRangeMismatchException('WebDAV Content-Range 与请求范围不一致');
      }
      actualEndValue = actualEnd;
      totalLength = total;
      expectedBytes = actualEnd - start + 1;
    } else if (status == HttpStatus.ok &&
        start == 0 &&
        endInclusive == null &&
        (expectedStrongValidator == null || expectedStrongValidator.isEmpty)) {
      // 某些不支持 Range 的服务仅允许从零开始完整读取。
      expectedBytes = int.tryParse(
        streamed.headers[HttpHeaders.contentLengthHeader] ?? '',
      );
      totalLength = expectedBytes;
    } else {
      await streamed.stream.listen(null).cancel();
      if (status == HttpStatus.ok) {
        throw const UpstreamRangeMismatchException(
          'WebDAV 对 Range 请求返回 200 整包响应，拒绝错位拼接',
        );
      }
      throw HttpException('WebDAV Range 读取失败: HTTP $status', uri: uri);
    }

    // 渐进式输出，不等待完整分块；同时防止上游提前 EOF 或超额发送
    // 导致本地 HTTP 桥接声称的 Content-Length 与真实字节不一致。
    Stream<List<int>> checkedResponse() async* {
      var received = 0;
      await for (final chunk in streamed.stream) {
        received += chunk.length;
        if (expectedBytes != null && received > expectedBytes) {
          throw HttpException('WebDAV 响应字节超出声明范围', uri: uri);
        }
        yield chunk;
      }
      if (expectedBytes != null && received != expectedBytes) {
        throw HttpException(
          'WebDAV 响应提前结束，实际 $received / $expectedBytes 字节',
          uri: uri,
        );
      }
    }

    StreamSubscription<List<int>>? upstreamSub;
    var streamReleased = false;
    var listened = false;
    late final StreamController<List<int>> controller;
    late final Future<void> Function() aborter;
    aborter = () async {
      if (streamReleased) return;
      streamReleased = true;
      _activeStreamAborters.remove(aborter);
      try {
        if (upstreamSub != null) {
          await upstreamSub!.cancel();
          upstreamSub = null;
        } else if (!listened) {
          // 若下游在尚未 listen 前就取消或关闭网关，必须立即消费并取消底层响应，严防池化 TCP 槽位永久泄漏。
          await streamed.stream.listen(null).cancel();
        }
      } catch (error) {
        developer.log(
          '释放 WebDAV 响应流忽略',
          name: 'konata.webdav_source_gateway',
          error: error,
        );
      }
    };
    _activeStreamAborters.add(aborter);

    controller = StreamController<List<int>>(
      onListen: () {
        listened = true;
        if (streamReleased) {
          if (!controller.isClosed) {
            unawaited(controller.close());
          }
          return;
        }
        upstreamSub = checkedResponse().listen(
          controller.add,
          onError: (Object error, StackTrace st) {
            if (!controller.isClosed) controller.addError(error, st);
          },
          onDone: () {
            streamReleased = true;
            _activeStreamAborters.remove(aborter);
            upstreamSub = null;
            if (!controller.isClosed) {
              unawaited(controller.close());
            }
          },
          cancelOnError: false,
        );
      },
      onPause: () => upstreamSub?.pause(),
      onResume: () => upstreamSub?.resume(),
      onCancel: aborter,
    );
    return ValidatedByteRangeStream(
      stream: controller.stream,
      start: start,
      endInclusive: isPartial ? actualEndValue : null,
      totalLength: totalLength,
      strongValidator: strongEtag,
      isPartialContent: isPartial,
    );
  }

  @override
  Future<Stream<List<int>>> openByteRange(
    String relativePath, {
    required int start,
    int? endInclusive,
  }) async {
    final validated = await openValidatedByteRange(
      relativePath,
      start: start,
      endInclusive: endInclusive,
    );
    return validated.stream;
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
    final pending = _activeStreamAborters.toList(growable: false);
    _activeStreamAborters.clear();
    for (final abort in pending) {
      await abort();
    }
    if (_ownsClient) {
      _client.close();
    }
  }
}
