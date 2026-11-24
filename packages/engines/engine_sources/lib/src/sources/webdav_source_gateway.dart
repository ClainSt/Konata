import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:xml/xml.dart';

import 'source_access_error.dart';
import 'webdav_digest_auth.dart';

part 'webdav_connection_pool.dart';

/// WebDAV 远程媒体源只读网关（支持 Basic/Digest 质询认证、30x 跨源凭据隔离与字节范围流式读取）。
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

  /// 可选 WebDAV 登录用户名。
  final String? username;

  /// 可选 WebDAV 登录密码。
  final String? password;
  final WebDavConnectionPool? _connectionPool;
  final http.Client _client;
  final bool _ownsClient;

  /// 单次 WebDAV 请求超时上限。
  final Duration requestTimeout;

  String? _lastDigestChallenge;
  int _nonceCount = 0;
  final Map<String, _CachedRedirectEntry> _localRedirectCache =
      <String, _CachedRedirectEntry>{};
  final Set<Future<void> Function()> _activeStreamAborters =
      <Future<void> Function()>{};

  Map<String, _CachedRedirectEntry> get _redirectCache =>
      _connectionPool?._redirectCacheFor(
        rootUri: _rootUri,
        username: username,
        password: password,
      ) ??
      _localRedirectCache;

  /// 解析直链查询参数中的签名过期时间，结合短有效期计算安全缓存截止时刻。
  static DateTime? _computeRedirectExpiry(Uri targetUri, DateTime now) {
    var expiresAt = now.add(WebDavGatewayConfig.redirectCacheTtl);
    for (final entry in targetUri.queryParameters.entries) {
      final key = entry.key.toLowerCase();
      final value = int.tryParse(entry.value.trim());
      if (value == null) continue;
      if ((key == 'expires' || key == 'x-oss-expires' || key == 'e') &&
          value > 1700000000 &&
          value < 4102444800) {
        final candidate = DateTime.fromMillisecondsSinceEpoch(
          value * 1000,
          isUtc: true,
        ).toLocal().subtract(WebDavGatewayConfig.redirectExpirySafetyMargin);
        if (candidate.isBefore(expiresAt)) expiresAt = candidate;
      } else if (key == 'x-amz-expires' && value > 0 && value <= 604800) {
        final candidate = now
            .add(Duration(seconds: value))
            .subtract(WebDavGatewayConfig.redirectExpirySafetyMargin);
        if (candidate.isBefore(expiresAt)) expiresAt = candidate;
      }
    }
    return expiresAt.isAfter(now) ? expiresAt : null;
  }

  Uri? _readCachedRedirect(Uri originUri) {
    final cache = _redirectCache;
    final key = originUri.toString();
    final entry = cache[key];
    if (entry == null) return null;
    if (!entry.expiresAt.isAfter(DateTime.now())) {
      cache.remove(key);
      return null;
    }
    cache.remove(key);
    cache[key] = entry;
    return entry.targetUri;
  }

  void _rememberCachedRedirect(Uri originUri, Uri resolvedUri) {
    if (originUri == resolvedUri) return;
    final expiresAt = _computeRedirectExpiry(resolvedUri, DateTime.now());
    if (expiresAt == null) return;
    final cache = _redirectCache;
    final key = originUri.toString();
    cache.remove(key);
    cache[key] = _CachedRedirectEntry(
      targetUri: resolvedUri,
      expiresAt: expiresAt,
    );
    while (cache.length > WebDavGatewayConfig.maxCachedRedirects) {
      cache.remove(cache.keys.first);
    }
  }

  void _evictCachedRedirect(Uri originUri) {
    _redirectCache.remove(originUri.toString());
  }

  /// 安全排空并释放轻量 HTTP 响应体；超时则直接取消订阅切断底层连接，防止池槽位长期占用。
  static Future<void> _safeDrainResponse(http.StreamedResponse response) async {
    try {
      await response.stream.drain<void>().timeout(const Duration(seconds: 5));
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

  /// 对路径逐段执行严格单次 UTF-8 百分号编码（确保特殊符号精确编码且不二次编码）。
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
    final all = <String>[...baseSegments, ...segments];
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
        // 当池化保活连接被服务端半关闭时，立即换新连接无感重试一次。
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
    void Function(Uri resolvedUri)? onFinalRedirectUri,
  }) async {
    final activeClient = client ?? _client;
    var currentUri = uri;
    var currentMethod = method;
    var allowCredentials = _isSameOrigin(_rootUri, currentUri);

    for (var hop = 0; hop <= WebDavGatewayConfig.maxRedirects; hop++) {
      final initialBody =
          body ?? (hop == 0 ? buildRequest(const <String, String>{}).body : null);
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
        if (hop > 0 &&
            (streamed.statusCode == HttpStatus.ok ||
                streamed.statusCode == HttpStatus.partialContent)) {
          onFinalRedirectUri?.call(currentUri);
        }
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
      // 严格 30x 跨源凭据隔离：一旦跳转至不同协议、主机或端口，立即剥离认证头。
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
      extraHeaders: const <String, String>{
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

      // 兼容返回多段属性状态（200 与 404 分离）的 WebDAV 服务，合并 2xx 属性防目录被误判。
      final propstats = node
          .findAllElements('propstat', namespaceUri: '*')
          .toList();
      final okProps = <XmlElement>[
        for (final ps in propstats)
          if (() {
            final st =
                ps
                    .findElements('status', namespaceUri: '*')
                    .firstOrNull
                    ?.innerText
                    .trim() ??
                '';
            return st.isEmpty || RegExp(r'\b2\d\d\b').hasMatch(st);
          }())
            ...ps.findElements('prop', namespaceUri: '*'),
      ];
      if (okProps.isEmpty) {
        okProps.addAll(
          propstats.expand((ps) => ps.findElements('prop', namespaceUri: '*')),
        );
      }
      if (okProps.isEmpty) continue;

      final isDir =
          okProps
              .expand((pr) => pr.findElements('resourcetype', namespaceUri: '*'))
              .expand((rt) => rt.findElements('collection', namespaceUri: '*'))
              .isNotEmpty ||
          hrefPath.endsWith('/');
      final sizeText = okProps
          .expand((pr) => pr.findElements('getcontentlength', namespaceUri: '*'))
          .map((e) => e.innerText.trim())
          .firstWhere((t) => t.isNotEmpty, orElse: () => '0');
      final size = int.tryParse(sizeText) ?? 0;
      final modifiedText = okProps
          .expand((pr) => pr.findElements('getlastmodified', namespaceUri: '*'))
          .map((e) => e.innerText.trim())
          .where((t) => t.isNotEmpty)
          .firstOrNull;
      DateTime? modifiedAt;
      if (modifiedText != null) {
        try {
          modifiedAt = HttpDate.parse(modifiedText);
        } on HttpException {
          modifiedAt = null;
        }
      }
      final etag = okProps
          .expand((pr) => pr.findElements('getetag', namespaceUri: '*'))
          .map((e) => e.innerText.trim())
          .where((t) => t.isNotEmpty)
          .firstOrNull;

      var relPath = hrefPath;
      if (relPath.startsWith(rootPrefix) ||
          relPath.toLowerCase().startsWith(rootPrefix.toLowerCase())) {
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
      extraHeaders: <String, String>{'Range': 'bytes=0-${maxBytes - 1}'},
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
      // 兼容禁用 HEAD、对 HEAD 超时或主动断连的 WebDAV 服务，立即回退首字节探测。
      developer.log(
        'HEAD 探测失败，回退 Range 探测',
        name: 'konata.webdav_source_gateway',
        error: error,
      );
    }

    final probeResp = await _sendWithDigestRetry(
      (headers) => http.Request('GET', uri)..headers.addAll(headers),
      method: 'GET',
      uri: uri,
      extraHeaders: const <String, String>{'Range': 'bytes=0-0'},
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
    // 完整文件从头读取走标准 GET，避免向部分网盘发送开放式区间请求头引发兼容挂起。
    if (!isFullFromStart) {
      final rangeHeader = endInclusive != null
          ? 'bytes=$start-$endInclusive'
          : 'bytes=$start-';
      extraHeaders['Range'] = rangeHeader;
    }
    if (hasValidator) {
      extraHeaders[HttpHeaders.ifRangeHeader] = expectedStrongValidator;
    }

    // 优先命中短 TTL 302 CDN 直链缓存（跨源绝不附带凭据）；遇签名过期或失效状态码立即驱逐并回源重试一次。
    http.StreamedResponse? cachedStreamed;
    final cachedRedirectUri = _readCachedRedirect(uri);
    if (cachedRedirectUri != null) {
      try {
        final directResp = await _sendWithDigestRetry(
          (headers) => http.Request('GET', cachedRedirectUri)
            ..headers.addAll(headers),
          method: 'GET',
          uri: cachedRedirectUri,
          extraHeaders: extraHeaders,
          client: _client,
          timeoutOverride: streamTimeout,
        );
        final directCode = directResp.statusCode;
        final shouldRetryOrigin =
            directCode == HttpStatus.unauthorized ||
            directCode == HttpStatus.forbidden ||
            directCode == HttpStatus.notFound ||
            directCode == HttpStatus.gone ||
            directCode >= 500;
        if (shouldRetryOrigin) {
          await _safeDrainResponse(directResp);
          _evictCachedRedirect(uri);
        } else {
          cachedStreamed = directResp;
        }
      } catch (error) {
        developer.log(
          'WebDAV 缓存 302 直链失效，自动回源重新签发',
          name: 'konata.webdav_source_gateway',
          error: error,
        );
        _evictCachedRedirect(uri);
      }
    }

    final http.StreamedResponse streamed =
        cachedStreamed ??
        await _sendWithDigestRetry(
          (headers) => http.Request('GET', uri)..headers.addAll(headers),
          method: 'GET',
          uri: uri,
          extraHeaders: extraHeaders,
          client: _client,
          timeoutOverride: streamTimeout,
          onFinalRedirectUri: (resolved) =>
              _rememberCachedRedirect(uri, resolved),
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

    // 禁止把上游 200 全文件或错误的 206 范围当作目标字节区间透传。
    final rangeValue = streamed.headers[HttpHeaders.contentRangeHeader];
    int? expectedBytes;
    int? totalLength;
    var actualEndValue = endInclusive ?? start;
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
        throw const UpstreamRangeMismatchException(
          'WebDAV Content-Range 与请求范围不一致',
        );
      }
      actualEndValue = actualEnd;
      totalLength = total;
      expectedBytes = actualEnd - start + 1;
    } else if (status == HttpStatus.ok &&
        start == 0 &&
        endInclusive == null &&
        (expectedStrongValidator == null || expectedStrongValidator.isEmpty)) {
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
          // 若下游在尚未监听前就取消或关闭网关，必须立即消费并取消底层响应，严防池化连接槽位泄漏。
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
    _localRedirectCache.clear();
    if (_ownsClient) {
      _client.close();
    }
  }
}
