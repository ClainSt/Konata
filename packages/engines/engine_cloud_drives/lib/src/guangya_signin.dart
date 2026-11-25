import 'dart:convert';

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

  final String clientId;
  final String deviceId;
  final String? deviceSign;
  final GuangYaRequest _request;
  String? _phone;
  String? _verificationId;
  bool _busy = false;
  bool _risk = false;

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, Object?> body,
  ) async {
    if (_risk) throw const RiskControlled();
    KonataHttpResponse response;
    try {
      response = await _request(
        'POST',
        Uri.https('account.guangyapan.com', path),
        {
          'Accept': 'application/json, text/plain, */*',
          'Content-Type': 'application/json',
          'X-Client-Id': clientId,
          'X-Device-Id': deviceId,
          if (deviceSign case final sign? when sign.isNotEmpty)
            'X-Device-Sign': sign,
        },
        {...body, 'client_id': clientId},
      );
    } on SourceAccessException {
      rethrow;
    } catch (_) {
      throw const SourceAccessException(
        SourceAccessProblemKind.network,
        '光鸭授权网络请求失败',
      );
    }
    Map<String, dynamic>? obj;
    if (response.bodyBytes.length <= 128 * 1024) {
      try {
        final parsed = jsonDecode(response.body);
        if (parsed is Map<String, dynamic>) obj = parsed;
      } catch (_) {}
    }
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
      cancel();
      throw const RiskControlled();
    }
    if (response.statusCode != 200 || obj == null || obj['error'] != null) {
      throw const SourceAccessException(
        SourceAccessProblemKind.authentication,
        '光鸭授权失败，请检查应用凭据或验证码',
      );
    }
    return obj;
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
      final obj = await _post('/v1/auth/verification', {
        'phone_number': phone,
        'target': 'ANY',
      });
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
    _phone = null;
    _verificationId = null;
  }
}
