import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:konata_contracts/konata_contracts.dart';

// 单独标记可恢复的握手中断，不暴露请求体、令牌或底层异常原文。
final class _InterruptedHandshake extends SourceAccessException {
  _InterruptedHandshake(String host, ProxyMode mode)
    : super(
        SourceAccessProblemKind.tls,
        '云盘 HTTPS 握手中断（$host，${switch (mode) {
          ProxyMode.none => '直连',
          ProxyMode.system => '系统代理',
          ProxyMode.custom => '自定义代理',
        }}），请检查网络或代理后重试',
      );
}

/// 只向明确允许的光鸭账号及业务域发送认证数据，禁止重定向和非幂等请求重放。
final class GuangYaHttpTransport {
  GuangYaHttpTransport({
    required this._config,
    HttpClient Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? HttpClient.new;
  final KonataNetworkConfig Function() _config;
  final HttpClient Function() _clientFactory;
  static const _timeout = Duration(seconds: 15);
  HttpClient? _apiClient;
  (ProxyMode, String)? _proxyKey;
  bool _closed = false;

  // 仅业务与认证接口复用连接；媒体流仍由各网关独立持有。
  HttpClient _clientForApi() {
    if (_closed) {
      throw const SourceAccessException(
        SourceAccessProblemKind.network,
        '云盘传输已关闭',
      );
    }
    final config = _config();
    final key = (config.proxyMode, config.proxyUrl);
    if (_apiClient != null && _proxyKey != key) {
      _apiClient!.close();
      _apiClient = null;
    }
    _proxyKey = key;
    return _apiClient ??= _createClient(config);
  }

  HttpClient createClient() => _createClient(_config());

  HttpClient _createClient(KonataNetworkConfig config) {
    return _clientFactory()
      ..autoUncompress = false
      ..connectionTimeout = _timeout
      ..findProxy = ((uri) {
        switch (config.proxyMode) {
          case ProxyMode.none:
            return 'DIRECT';
          case ProxyMode.system:
            return HttpClient.findProxyFromEnvironment(uri);
          case ProxyMode.custom:
            final raw = config.proxyUrl.trim();
            final proxy = Uri.tryParse(
              raw.contains('://') ? raw : 'http://$raw',
            );
            if (proxy == null ||
                proxy.host.isEmpty ||
                !proxy.hasPort ||
                proxy.userInfo.isNotEmpty ||
                !{'http', 'https'}.contains(proxy.scheme)) {
              throw const SourceAccessException(
                SourceAccessProblemKind.network,
                '云盘自定义代理配置无效',
              );
            }
            return 'PROXY ${proxy.host}:${proxy.port}';
        }
      });
  }

  Future<KonataHttpResponse> request(
    String method,
    Uri uri,
    Map<String, String> headers,
    Map<String, Object?>? body,
  ) async {
    // 仅目录枚举是已核实的幂等只读 POST；认证及其他接口绝不重放。
    final isListing =
        method == 'POST' &&
        uri.host == 'api.guangyapan.com' &&
        uri.path == '/userres/v1/file/get_file_list' &&
        !uri.hasQuery &&
        !uri.hasFragment;
    for (var attempt = 0; ; attempt++) {
      try {
        return await _requestOnce(
          method,
          uri,
          headers,
          body,
          allowOpenRecovery: !isListing,
        );
      } on _InterruptedHandshake {
        if (!isListing || attempt >= 2 || _closed) rethrow;
        // 上一次的失败连接池已释放；保持原代理和证书校验，以新连接重查。
        await Future<void>.delayed(
          Duration(milliseconds: attempt == 0 ? 650 : 1300),
        );
        if (_closed) rethrow;
      }
    }
  }

  Future<KonataHttpResponse> _requestOnce(
    String method,
    Uri uri,
    Map<String, String> headers,
    Map<String, Object?>? body, {
    required bool allowOpenRecovery,
  }) async {
    if (uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        !{'account.guangyapan.com', 'api.guangyapan.com'}.contains(uri.host) ||
        !{'GET', 'POST'}.contains(method)) {
      throw const SourceAccessException(
        SourceAccessProblemKind.permission,
        '云盘认证请求目标不合法',
      );
    }
    final http = _clientForApi();
    var completed = false;
    try {
      final request = allowOpenRecovery
          ? await _openRequest(http, method, uri)
          : await http.openUrl(method, uri).timeout(_timeout);
      request.followRedirects = false;
      headers.forEach(request.headers.set);
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(_timeout);
      final encoding = response.headers.value(
        HttpHeaders.contentEncodingHeader,
      );
      if (encoding != null && encoding != 'identity') {
        await response.listen(null).cancel();
        throw const SourceAccessException(
          SourceAccessProblemKind.unknown,
          '云盘接口返回了未支持的压缩响应',
        );
      }
      if (response.isRedirect) {
        await response.listen(null).cancel();
        throw const SourceAccessException(
          SourceAccessProblemKind.permission,
          '云盘认证请求发生重定向',
        );
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(_timeout)) {
        if (bytes.length + chunk.length > 4 * 1024 * 1024) {
          throw const SourceAccessException(
            SourceAccessProblemKind.unknown,
            '云盘接口响应超限',
          );
        }
        bytes.add(chunk);
      }
      final safeHeaders = <String, String>{};
      final retryAfter = response.headers.value('retry-after');
      if (retryAfter != null) safeHeaders['retry-after'] = retryAfter;
      completed = true;
      return KonataHttpResponse(
        statusCode: response.statusCode,
        bodyBytes: bytes.takeBytes(),
        headers: safeHeaders,
      );
    } on SourceAccessException {
      rethrow;
    } on TimeoutException {
      throw const SourceAccessException(
        SourceAccessProblemKind.timeout,
        '云盘接口请求超时',
      );
    } on HandshakeException catch (error) {
      if (_isInterruptedHandshake(error)) {
        throw _InterruptedHandshake(uri.host, _config().proxyMode);
      }
      throw SourceAccessException(
        SourceAccessProblemKind.tls,
        '云盘 HTTPS 证书或协议校验失败（${uri.host}），请检查系统时间、证书及代理',
      );
    } on CertificateException {
      throw SourceAccessException(
        SourceAccessProblemKind.tls,
        '云盘 HTTPS 证书校验失败（${uri.host}），请检查系统时间、证书及代理',
      );
    } catch (_) {
      throw const SourceAccessException(
        SourceAccessProblemKind.network,
        '云盘接口连接或传输失败',
      );
    } finally {
      // 异常请求可能残留未消费响应，废弃对应连接池，不自动重试。
      if (!completed) {
        if (identical(_apiClient, http)) _apiClient = null;
        http.close(force: true);
      }
    }
  }

  // 仅在尚未写入认证头和请求体时恢复一次明确的握手中断。
  // 不重放已发送请求，不接受无效证书，也不绕开用户配置的代理。
  Future<HttpClientRequest> _openRequest(
    HttpClient http,
    String method,
    Uri uri,
  ) async {
    try {
      return await http.openUrl(method, uri).timeout(_timeout);
    } on HandshakeException catch (error) {
      if (!_isInterruptedHandshake(error)) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (_closed) rethrow;
      return http.openUrl(method, uri).timeout(_timeout);
    }
  }

  static bool _isInterruptedHandshake(HandshakeException error) {
    final message = '${error.message} ${error.osError?.message ?? ''}'
        .toLowerCase();
    if (message.contains('certificate') || message.contains('verify')) {
      return false;
    }
    return message.contains('connection terminated during handshake') ||
        message.contains('connection reset') ||
        message.contains('unexpected eof') ||
        message.contains('connection closed');
  }

  /// 宿主退出时释放空闲或正在使用的 API 连接。
  void close() {
    if (_closed) return;
    _closed = true;
    _apiClient?.close(force: true);
    _apiClient = null;
  }
}
