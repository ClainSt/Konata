import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// 基于 HTTP Digest 协议的质询认证请求头生成器。
class WebDavDigestAuth {
  const WebDavDigestAuth._();

  static final Random _rng = Random.secure();

  /// 根据服务端 `WWW-Authenticate` 响应头计算单次请求的 `Authorization` 头。
  ///
  /// 若非 `Digest` 质询或缺少必要参数，返回 `null`。
  static String? buildAuthorizationHeader({
    required String? wwwAuthenticateHeader,
    required String method,
    required Uri uri,
    required String username,
    required String password,
    int nonceCount = 1,
  }) {
    if (wwwAuthenticateHeader == null) return null;
    final trimmed = wwwAuthenticateHeader.trim();
    if (!trimmed.toLowerCase().startsWith('digest ')) return null;

    final params = _parseChallengeParams(trimmed.substring(7));
    final realm = params['realm'];
    final nonce = params['nonce'];
    if (realm == null || nonce == null) return null;

    final algorithm = (params['algorithm'] ?? 'MD5').toUpperCase();
    final isSha256 = algorithm == 'SHA-256' || algorithm == 'SHA-256-SESS';
    final isSess = algorithm.endsWith('-SESS');
    String hashHex(String input) {
      final bytes = utf8.encode(input);
      return (isSha256 ? sha256.convert(bytes) : md5.convert(bytes)).toString();
    }

    final uriPath = uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
    final effectiveUri = uriPath.isEmpty ? '/' : uriPath;
    final cnonce = _randomHex(16);
    final nc = nonceCount.toRadixString(16).padLeft(8, '0');

    var ha1 = hashHex('$username:$realm:$password');
    if (isSess) {
      ha1 = hashHex('$ha1:$nonce:$cnonce');
    }
    final ha2 = hashHex('${method.toUpperCase()}:$effectiveUri');

    final qopRaw = params['qop'];
    String? selectedQop;
    if (qopRaw != null) {
      final options = qopRaw
          .split(',')
          .map((e) => e.trim().toLowerCase())
          .toSet();
      if (options.contains('auth')) {
        selectedQop = 'auth';
      }
    }

    final responseDigest = selectedQop != null
        ? hashHex('$ha1:$nonce:$nc:$cnonce:$selectedQop:$ha2')
        : hashHex('$ha1:$nonce:$ha2');

    final parts = <String>[
      'username="${_escape(username)}"',
      'realm="${_escape(realm)}"',
      'nonce="${_escape(nonce)}"',
      'uri="${_escape(effectiveUri)}"',
      'algorithm=$algorithm',
      'response="$responseDigest"',
      if (params['opaque'] != null) 'opaque="${_escape(params['opaque']!)}"',
      if (selectedQop != null) ...<String>[
        'qop=$selectedQop',
        'nc=$nc',
        'cnonce="$cnonce"',
      ],
    ];
    return 'Digest ${parts.join(', ')}';
  }

  static Map<String, String> _parseChallengeParams(String body) {
    final result = <String, String>{};
    final reg = RegExp(r'([a-zA-Z0-9_-]+)=("([^"\\]*(?:\\.[^"\\]*)*)"|[^,\s]+)');
    for (final match in reg.allMatches(body)) {
      final key = match.group(1)!.toLowerCase();
      final quoted = match.group(3);
      final raw = quoted ?? match.group(2) ?? '';
      result[key] = raw.replaceAll(r'\"', '"');
    }
    return result;
  }

  static String _randomHex(int length) {
    const chars = '0123456789abcdef';
    return List<String>.generate(
      length,
      (_) => chars[_rng.nextInt(16)],
    ).join();
  }

  static String _escape(String value) => value.replaceAll('"', r'\"');
}
