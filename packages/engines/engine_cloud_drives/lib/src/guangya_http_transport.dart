import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:konata_contracts/konata_contracts.dart';

/// 只向明确允许的光鸭账号及业务域发送认证数据，禁止重定向和隐式重放。
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
      final request = await http.openUrl(method, uri).timeout(_timeout);
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
    } on HandshakeException {
      throw const SourceAccessException(
        SourceAccessProblemKind.tls,
        '云盘接口安全连接校验失败',
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

  /// 宿主退出时释放空闲或正在使用的 API 连接。
  void close() {
    if (_closed) return;
    _closed = true;
    _apiClient?.close(force: true);
    _apiClient = null;
  }
}
