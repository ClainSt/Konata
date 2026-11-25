import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:konata_contracts/konata_contracts.dart';

/// 文件标识独立于鉴权协议，未知修改时间不推测单位。
typedef GuangYaFile = ({String id, String name, bool directory, int? size});

/// 两套授权与业务接口只在此边界内变化。
abstract interface class GuangYaProtocol {
  Future<List<GuangYaFile>> list(String parentId);
  Future<RenewableLink> link(String fileId);
  Future<void> close();
}

/// 本机授权凭据；不进入媒体源摘要或同步载荷。
final class GuangYaCredentials {
  const GuangYaCredentials({
    required this.clientId,
    required this.deviceId,
    required this.refreshToken,
    required this.subject,
    this.deviceSign,
  });
  final String clientId;
  final String deviceId;
  final String refreshToken;
  final String subject;
  final String? deviceSign;
}

/// 单次请求传递凭据，不在公共 HTTP 客户端设置全局头。
typedef GuangYaRequest =
    Future<KonataHttpResponse> Function(
      String method,
      Uri uri,
      Map<String, String> headers,
      Map<String, Object?>? body,
    );

/// 既有协议的独立实现，仅根据已核实的协议事实工作。
final class LegacyGuangYaProtocol implements GuangYaProtocol {
  LegacyGuangYaProtocol({
    required GuangYaCredentials credentials,
    required this._request,
    required this._persistRefresh,
    Duration spacing = const Duration(milliseconds: 550),
    this.maxPages = 10000,
  }) : _credentials = credentials,
       _spacing = spacing {
    if (credentials.clientId.isEmpty ||
        credentials.refreshToken.isEmpty ||
        credentials.subject.isEmpty ||
        !RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(credentials.deviceId) ||
        spacing.isNegative ||
        maxPages < 1) {
      throw ArgumentError('实验性云盘凭据或配置不合法');
    }
  }

  final GuangYaCredentials _credentials;
  final GuangYaRequest _request;
  final Future<void> Function(String refreshToken) _persistRefresh;
  final Duration _spacing;
  final int maxPages;
  final Stopwatch _clock = Stopwatch()..start();
  Future<void> _tail = Future.value();
  int _lastRequestMs = -100000;
  int _cooldownUntilMs = 0;
  String? _access;
  String? _refreshToken;
  int _expiresAtMs = 0;
  Future<void>? _refreshing;
  bool _closed = false;
  bool _risk = false;

  void _check() {
    if (_risk) throw const RiskControlled();
    if (_closed) {
      throw const SourceAccessException(
        SourceAccessProblemKind.network,
        '云盘会话已关闭',
      );
    }
  }

  // 冷却期间不排队等待，也不自动重试，交由调用方决定恢复时机。
  void _checkCooldown() {
    final remaining = _cooldownUntilMs - _clock.elapsedMilliseconds;
    if (remaining > 0) {
      throw SourceRateLimitException(
        statusCode: 429,
        message: '光鸭访问处于冷却期',
        retryAfter: Duration(milliseconds: remaining),
      );
    }
  }

  SourceRateLimitException _rateLimited(Duration? retryAfter) {
    final delay = max(1000, retryAfter?.inMilliseconds ?? 30000);
    _cooldownUntilMs = max(
      _cooldownUntilMs,
      _clock.elapsedMilliseconds + delay,
    );
    return SourceRateLimitException(
      statusCode: 429,
      message: '光鸭访问频率受限',
      retryAfter: Duration(milliseconds: delay),
    );
  }

  Future<T> _serial<T>(Future<T> Function() operation) async {
    _check();
    _checkCooldown();
    final result = _tail.then((_) async {
      _check();
      _checkCooldown();
      final delay =
          _spacing.inMilliseconds -
          (_clock.elapsedMilliseconds - _lastRequestMs);
      if (delay > 0) await Future<void>.delayed(Duration(milliseconds: delay));
      _check();
      _checkCooldown();
      _lastRequestMs = _clock.elapsedMilliseconds;
      return operation();
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<Map<String, dynamic>> _send(
    String method,
    Uri uri,
    Map<String, String> headers,
    Map<String, Object?>? body,
  ) => _serial(() async {
    try {
      final response = await _request(method, uri, headers, body);
      _check();
      return _json(response);
    } on RateLimitedHttpException catch (error) {
      throw _rateLimited(error.retryAfter);
    } on SourceAccessException {
      rethrow;
    } on TerminalSourceAuthException {
      rethrow;
    } on SourceRateLimitException catch (error) {
      throw _rateLimited(error.retryAfter);
    } catch (_) {
      throw const SourceAccessException(
        SourceAccessProblemKind.network,
        '光鸭请求失败',
      );
    }
  });

  Map<String, dynamic> _json(KonataHttpResponse response) {
    Map<String, dynamic>? obj;
    if (response.bodyBytes.length > 4 * 1024 * 1024) {
      throw const SourceAccessException(
        SourceAccessProblemKind.unknown,
        '云盘响应超限',
      );
    }
    try {
      final parsed = jsonDecode(response.body);
      if (parsed is Map<String, dynamic>) obj = parsed;
    } catch (_) {}
    final error = [
      obj?['error'],
      obj?['error_code'],
      obj?['error_description'],
      obj?['msg'],
    ].whereType<String>().join(' ').toLowerCase();
    if (error.contains('captcha') ||
        error.contains('验证码') ||
        error.contains('风控') ||
        error.contains('risk_control')) {
      _risk = true;
      throw const RiskControlled();
    }
    if (response.statusCode == 429) {
      final raw = response.headers.entries
          .where((e) => e.key.toLowerCase() == 'retry-after')
          .firstOrNull
          ?.value;
      final seconds = int.tryParse(raw ?? '');
      Duration? wait;
      if (seconds != null && seconds >= 0) {
        wait = Duration(seconds: seconds);
      } else if (raw != null) {
        try {
          final duration = HttpDate.parse(raw).difference(DateTime.now());
          wait = duration.isNegative ? Duration.zero : duration;
        } catch (_) {}
      }
      throw SourceRateLimitException(
        statusCode: 429,
        message: '光鸭访问频率受限',
        retryAfter: wait,
      );
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw TerminalSourceAuthException(
        '光鸭访问授权失效',
        statusCode: response.statusCode,
      );
    }
    if (response.statusCode != 200 || obj == null) {
      throw const SourceAccessException(
        SourceAccessProblemKind.unknown,
        '光鸭响应格式或状态异常',
      );
    }
    return obj;
  }

  Future<void> _refresh() async {
    _check();
    final active = _refreshing;
    if (active != null) return active;
    final task = _refreshOnce();
    _refreshing = task;
    try {
      await task;
    } finally {
      if (identical(_refreshing, task)) _refreshing = null;
    }
  }

  Future<void> _refreshOnce() async {
    final token = _refreshToken ?? _credentials.refreshToken;
    final obj = await _send(
      'POST',
      Uri.https('account.guangyapan.com', '/v1/auth/token'),
      {
        'Accept': 'application/json, text/plain, */*',
        'Content-Type': 'application/json',
        'X-Client-Id': _credentials.clientId,
        'X-Device-Id': _credentials.deviceId,
        if (_credentials.deviceSign case final sign? when sign.isNotEmpty)
          'X-Device-Sign': sign,
      },
      {
        'client_id': _credentials.clientId,
        'grant_type': 'refresh_token',
        'refresh_token': token,
      },
    );
    final access = obj['access_token'];
    final refresh = obj['refresh_token'] ?? token;
    final expiry = obj['expires_in'];
    final subject = obj['sub'];
    if (access is! String ||
        access.isEmpty ||
        refresh is! String ||
        refresh.isEmpty ||
        expiry is! int ||
        expiry <= 0 ||
        subject != _credentials.subject) {
      throw const SourceAccessException(
        SourceAccessProblemKind.authentication,
        '光鸭凭据无效或需重新授权',
      );
    }
    _check();
    // 先完成安全存储的轮换，再发布新的访问令牌。
    if (refresh != token) {
      _refreshToken = refresh;
      try {
        await _persistRefresh(refresh);
      } catch (_) {
        _closed = true;
        _access = null;
        throw const SourceAccessException(
          SourceAccessProblemKind.authentication,
          '云盘令牌轮换保存失败，请重新授权',
        );
      }
    }
    _check();
    _refreshToken = refresh;
    _access = access;
    _expiresAtMs = _clock.elapsedMilliseconds + max(1, expiry - 30) * 1000;
    _check();
  }

  Future<Map<String, dynamic>> _business(
    String path,
    Map<String, Object?> body,
  ) async {
    _check();
    if (_access == null || _clock.elapsedMilliseconds >= _expiresAtMs) {
      await _refresh();
    }
    for (var attempt = 0; attempt < 2; attempt++) {
      final token = _access!;
      try {
        final obj = await _send('POST', Uri.https('api.guangyapan.com', path), {
          'Accept': 'application/json, text/plain, */*',
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
          'Did': _credentials.deviceId,
          'Dt': '4',
        }, body);
        // 既有接口完整错误码未获实测，只接受明确成功的结构。
        if (obj['code'] != 0 || obj['data'] is! Map<String, dynamic>) {
          throw const SourceAccessException(
            SourceAccessProblemKind.unknown,
            '光鸭业务拒绝或协议尚未确认',
          );
        }
        return obj['data'] as Map<String, dynamic>;
      } on TerminalSourceAuthException {
        if (attempt != 0) rethrow;
        if (_access == token) await _refresh();
      }
    }
    throw const SourceAccessException(
      SourceAccessProblemKind.authentication,
      '光鸭授权已失效',
    );
  }

  @override
  Future<List<GuangYaFile>> list(String parentId) async {
    const pageSize = 100;
    final result = <GuangYaFile>[];
    final seen = <String>{};
    int? expectedTotal;
    for (var page = 0; page < maxPages; page++) {
      final data = await _business('/userres/v1/file/get_file_list', {
        'parentId': parentId,
        'page': page,
        'pageSize': pageSize,
        'orderBy': 3,
        'sortType': 1,
      });
      final rows = data['list'];
      final total = data['total'];
      if (rows is! List ||
          total is! int ||
          total < 0 ||
          rows.length > pageSize ||
          (expectedTotal != null && total != expectedTotal) ||
          seen.length + rows.length > total ||
          total > maxPages * pageSize) {
        throw const SourceAccessException(
          SourceAccessProblemKind.unknown,
          '光鸭目录分页格式异常',
        );
      }
      expectedTotal ??= total;
      for (final raw in rows) {
        if (raw is! Map<String, dynamic>) {
          throw const SourceAccessException(
            SourceAccessProblemKind.unknown,
            '光鸭目录条目异常',
          );
        }
        final id = raw['fileId'];
        final name = raw['fileName'];
        final kind = raw['resType'];
        final size = raw['fileSize'];
        if (id is! String ||
            id.isEmpty ||
            name is! String ||
            name.isEmpty ||
            name == '.' ||
            name == '..' ||
            name.contains('/') ||
            name.contains('\\') ||
            !seen.add(id)) {
          throw const SourceAccessException(
            SourceAccessProblemKind.unknown,
            '光鸭目录项不唯一或路径非法',
          );
        }
        if (kind != 1 && kind != 2) continue;
        result.add((
          id: id,
          name: name,
          directory: kind == 2,
          size: kind == 2 ? 0 : (size is int && size >= 0 ? size : null),
        ));
      }
      if (seen.length == total) return result;
      if (rows.length < pageSize) {
        throw const SourceAccessException(
          SourceAccessProblemKind.unknown,
          '光鸭目录分页提前结束',
        );
      }
    }
    throw const SourceAccessException(
      SourceAccessProblemKind.unknown,
      '光鸭目录超过分页安全上限',
    );
  }

  @override
  Future<RenewableLink> link(String fileId) async {
    final data = await _business('/nd.bizuserres.s/v1/get_res_download_url', {
      'fileId': fileId,
    });
    final raw = data['signedURL'] ?? data['downloadUrl'];
    final uri = raw is String ? Uri.tryParse(raw) : null;
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw const SourceAccessException(
        SourceAccessProblemKind.unknown,
        '光鸭未返回安全下载地址',
      );
    }
    return RenewableLink(uri);
  }

  @override
  Future<void> close() async {
    _closed = true;
    _access = null;
    _refreshToken = null;
    _expiresAtMs = 0;
  }
}
