import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:konata_contracts/konata_contracts.dart';

/// 只向明确允许的光鸭账号及业务域发送认证数据，禁止重定向和隐式重放。
final class GuangYaHttpTransport {
  GuangYaHttpTransport({required this._config});
  final KonataNetworkConfig Function() _config;
  static const _timeout = Duration(seconds: 15);

  HttpClient createClient() {
    final config = _config();
    return HttpClient()
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
    final http = createClient();
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
      http.close(force: true);
    }
  }
}
