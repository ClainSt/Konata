import 'dart:convert';
import 'dart:io';

import 'package:konata_contracts/konata_contracts.dart';

import 'guangya_protocol.dart';

/// 实验性短信授权事务，仅由用户主动发起，不自动重发。
final class LegacyGuangYaSignIn {
  LegacyGuangYaSignIn({
    required this.clientId,
    required this.deviceId,
    required this._request,
    this.deviceSign,
  }) {
    if (clientId.isEmpty || !RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(deviceId)) {
      throw ArgumentError('云盘应用或设备配置无效');
    }
  }

  // Windows Web 登录兼容标识；不代表实际使用浏览器执行授权。
  static const _windowsWebUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/158.0.0.0 Safari/537.36';

  final String clientId;
  final String deviceId;
  final String? deviceSign;
  final GuangYaRequest _request;
  String? _phone;
  String? _verificationId;
  bool _busy = false;
  bool _risk = false;
  int _generation = 0;

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, Object?> body, {
    String? captchaToken,
  }) async {
    if (_risk) throw const RiskControlled();
    final generation = _generation;
    KonataHttpResponse response;
    try {
      response = await _request(
        'POST',
        Uri.https('account.guangyapan.com', path),
        {
          'Accept': 'application/json, text/plain, */*',
          'Content-Type': 'application/json',
          if (Platform.isWindows) 'User-Agent': _windowsWebUserAgent,
          'X-Client-Id': clientId,
          'X-Device-Id': deviceId,
          'X-Captcha-Token': ?captchaToken,
          if (deviceSign case final sign? when sign.isNotEmpty)
            'X-Device-Sign': sign,
        },
        {...body, 'client_id': clientId},
      );
    } on SourceAccessException {
      rethrow;
    } on SourceRateLimitException {
      rethrow;
    } catch (_) {
      throw const SourceAccessException(
        SourceAccessProblemKind.network,
        '光鸭授权网络请求失败',
      );
    }
    if (generation != _generation) {
      throw const SourceAccessException(
        SourceAccessProblemKind.authentication,
        '授权事务已取消',
      );
    }
    Map<String, dynamic>? obj;
    if (response.bodyBytes.length <= 128 * 1024) {
      try {
        final parsed = jsonDecode(response.body);
        if (parsed is Map<String, dynamic>) obj = parsed;
      } catch (_) {}
    }
    final status = response.statusCode;
    final rawCode = obj?['code'] ?? obj?['error_code'];
    final code = rawCode is int && rawCode >= 0 && rawCode <= 999999
        ? rawCode
        : null;
    final diagnostic = CloudAuthorizationDiagnostic(
      httpStatus: status,
      serviceCode: code,
    );
    final error = [
      obj?['error'],
      obj?['error_code'],
      obj?['error_description'],
      obj?['msg'],
      obj?['message'],
    ].whereType<String>().join(' ').toLowerCase();
    // 普通短信发送成功提示也可能包含验证码字样，不应视为风控。
    // 仅按明确的额外验证或风控提示停止事务，不跳过挑战。
    if (error.contains('captcha') ||
        error.contains('图形验证码') ||
        error.contains('人机验证') ||
        error.contains('额外验证') ||
        error.contains('安全验证') ||
        error.contains('风控') ||
        error.contains('risk_control')) {
      _risk = true;
      cancel();
      throw RiskControlled(diagnostic);
    }
    if (status == 429 ||
        error.contains('rate_limit') ||
        error.contains('too_many_requests')) {
      _risk = true;
      throw const SourceRateLimitException(
        statusCode: 429,
        message: '光鸭授权请求受到频率限制',
      );
    }
    if (status == 401 ||
        status == 403 ||
        error.contains('invalid_client') ||
        error.contains('unauthorized_client') ||
        error.contains('client_id not registered')) {
      _risk = true;
      throw SourceAccessException(
        SourceAccessProblemKind.permission,
        '服务端拒绝客户端或授权权限（HTTP $status）',
        diagnostic,
      );
    }
    if (status >= 500 && status <= 599) {
      throw SourceAccessException(
        SourceAccessProblemKind.network,
        '光鸭授权服务异常（HTTP $status）',
        diagnostic,
      );
    }
    if (status == 404 || status == 405 || obj == null) {
      throw SourceAccessException(
        SourceAccessProblemKind.unknown,
        '光鸭授权接口或响应格式不兼容（HTTP $status）',
        diagnostic,
      );
    }
    if (status != 200 ||
        obj['error'] != null ||
        (obj['code'] != null && obj['code'] != 0)) {
      throw SourceAccessException(
        SourceAccessProblemKind.authentication,
        '光鸭授权请求未获接受（HTTP $status）',
        diagnostic,
      );
    }
    return obj;
  }

  /// 服务端验证初始化。仅接受明确的令牌成功响应；未知挑战必须由用户通过官方方式处理。
  Future<String> _prepareVerification(String phone) async {
    final obj = await _post('/v1/shield/captcha/init', {
      'device_id': deviceId,
      'action': 'POST:/v1/auth/verification',
      'meta': {
        'username': phone,
        'phone_number': phone,
        'VERIFICATION_PHONE': phone,
      },
    });
    const knownFields = {
      'captcha_token',
      'expires_in',
      'error',
      'error_code',
      'error_description',
      'code',
      'msg',
      'message',
    };
    if (obj.keys.any((key) => !knownFields.contains(key))) {
      _risk = true;
      cancel();
      throw const RiskControlled();
    }
    final token = obj['captcha_token'];
    final expiry = obj['expires_in'];
    if (token is! String ||
        token.isEmpty ||
        token.length > 8192 ||
        token.trim() != token ||
        token.contains(RegExp(r'[\r\n]')) ||
        (expiry != null && (expiry is! int || expiry <= 0))) {
      _risk = true;
      cancel();
      throw const RiskControlled();
    }
    return token;
  }

  /// 仅申请一次短信验证码，手机号与验证 ID 保存在当前内存事务。
  Future<void> sendSms(String phone) async {
    if (_risk) throw const RiskControlled();
    if (_busy ||
        _verificationId != null ||
        !RegExp(r'^\+[1-9]\d{6,14}$').hasMatch(phone)) {
      throw const SourceAccessException(
        SourceAccessProblemKind.authentication,
        '手机号格式不合法或授权已在进行',
      );
    }
    _busy = true;
    try {
      final token = await _prepareVerification(phone);
      final obj = await _post('/v1/auth/verification', {
        'phone_number': phone,
        'target': 'ANY',
      }, captchaToken: token);
      final id = obj['verification_id'];
      if (id is! String || id.isEmpty) {
        throw const SourceAccessException(
          SourceAccessProblemKind.authentication,
          '光鸭未返回验证会话',
        );
      }
      _phone = phone;
      _verificationId = id;
    } finally {
      _busy = false;
    }
  }

  /// 验证并登录，成功后返回待安全存储的账号凭据。
  Future<GuangYaCredentials> finishSms(String code) async {
    if (_risk) throw const RiskControlled();
    final id = _verificationId;
    final phone = _phone;
    if (_busy ||
        id == null ||
        phone == null ||
        !RegExp(r'^\d{4,8}$').hasMatch(code)) {
      throw const SourceAccessException(
        SourceAccessProblemKind.authentication,
        '无有效验证会话或短信验证码格式异常',
      );
    }
    _busy = true;
    cancel();
    try {
      final result = await _post('/v1/auth/verification/verify', {
        'verification_id': id,
        'verification_code': code,
      });
      final verification = result['verification_token'];
      if (verification is! String || verification.isEmpty) {
        throw const SourceAccessException(
          SourceAccessProblemKind.authentication,
          '光鸭验证码校验失败',
        );
      }
      final obj = await _post('/v1/auth/signin', {
        'verification_code': code,
        'verification_token': verification,
        'username': phone,
      });
      return _credentials(obj);
    } finally {
      _busy = false;
    }
  }

  /// 已有授权会话导入，验证服务端主体并获取可能轮换的新令牌。
  Future<GuangYaCredentials> importRefresh(String refreshToken) async {
    if (_risk) throw const RiskControlled();
    if (_busy || _verificationId != null || refreshToken.isEmpty) {
      throw const SourceAccessException(
        SourceAccessProblemKind.authentication,
        '导入会话无效或已有授权在途',
      );
    }
    _busy = true;
    try {
      final obj = await _post('/v1/auth/token', {
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
      });
      return _credentials(obj, fallbackRefresh: refreshToken);
    } finally {
      _busy = false;
    }
  }

  GuangYaCredentials _credentials(
    Map<String, dynamic> obj, {
    String? fallbackRefresh,
  }) {
    final subject = obj['sub'];
    final refresh = obj['refresh_token'] ?? fallbackRefresh;
    final access = obj['access_token'];
    final expiry = obj['expires_in'];
    if (subject is! String ||
        subject.isEmpty ||
        refresh is! String ||
        refresh.isEmpty ||
        access is! String ||
        access.isEmpty ||
        expiry is! int ||
        expiry <= 0) {
      throw const SourceAccessException(
        SourceAccessProblemKind.authentication,
        '光鸭授权结果缺失必要字段',
      );
    }
    return GuangYaCredentials(
      clientId: clientId,
      deviceId: deviceId,
      refreshToken: refresh,
      subject: subject,
      deviceSign: deviceSign,
    );
  }

  void cancel() {
    _generation++;
    _phone = null;
    _verificationId = null;
  }
}
