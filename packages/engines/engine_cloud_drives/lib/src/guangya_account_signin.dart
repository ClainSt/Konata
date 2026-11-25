import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:konata_contracts/konata_contracts.dart';

import 'guangya_protocol.dart';
import 'guangya_session_registry.dart';
import 'guangya_signin.dart';

/// 已获授权的应用配置驱动短信登录；不内置默认客户端身份。
final class GuangYaAccountSignIn implements CloudAccountSignInPort {
  GuangYaAccountSignIn({
    required GuangYaSessionRegistry sessions,
    required String clientId,
    this._expectedLocation,
  }) : _sessions = sessions,
       _signIn = LegacyGuangYaSignIn(
         clientId: clientId,
         deviceId: _newDeviceId(),
         request: sessions.request,
       );

  final GuangYaSessionRegistry _sessions;
  final String? _expectedLocation;
  final LegacyGuangYaSignIn _signIn;
  bool _closed = false;
  bool _busy = false;
  bool _sent = false;
  String? _maskedPhone;

  static String _newDeviceId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// 按服务端主体生成跨设备稳定的绑定标识；不使用手机号或文件哈希。
  static String accountBinding(String subject) {
    final digest = sha256.convert(
      utf8.encode('konata:guangyapan:subject:v1:$subject'),
    );
    return 'gya_$digest';
  }

  void _check() {
    if (_closed) {
      throw const SourceAccessException(
        SourceAccessProblemKind.authentication,
        '授权事务已结束',
      );
    }
  }

  @override
  Future<void> sendSms(String phone, {String? nationalNumber}) async {
    _check();
    if (_busy || _sent) {
      throw const SourceAccessException(
        SourceAccessProblemKind.authentication,
        '授权已在进行',
      );
    }
    _busy = true;
    try {
      await _signIn.sendSms(phone);
      _check();
      _sent = true;
      // 只保留脱敏尾号，完整号码不落盘。
      final digits =
          nationalNumber ?? (phone.startsWith('+86') ? phone.substring(3) : '');
      _maskedPhone =
          RegExp(r'^\d{8,14}$').hasMatch(digits) && phone.endsWith(digits)
          ? '${digits.substring(0, 3)}****${digits.substring(digits.length - 4)}'
          : null;
    } finally {
      _busy = false;
    }
  }

  @override
  Future<String> finishSms(String code) async {
    _check();
    if (_busy || !_sent) {
      throw const SourceAccessException(
        SourceAccessProblemKind.authentication,
        '请先请求短信验证码',
      );
    }
    _busy = true;
    _sent = false;
    try {
      final value = await _signIn.finishSms(code);
      _check();
      final binding = accountBinding(value.subject);
      final expected = _expectedLocation;
      if (expected != null) {
        final uri = Uri.tryParse(expected);
        if (uri == null || uri.scheme != 'guangyapan' || uri.host != binding) {
          throw const SourceAccessException(
            SourceAccessProblemKind.authentication,
            '授权账号与已绑定媒体源不一致',
          );
        }
      }
      await _sessions.authorize(
        binding,
        GuangYaCredentials(
          clientId: value.clientId,
          deviceId: value.deviceId,
          refreshToken: value.refreshToken,
          subject: value.subject,
          deviceSign: value.deviceSign,
          maskedPhone: _maskedPhone,
        ),
      );
      _closed = true;
      return Uri(scheme: 'guangyapan', host: binding).toString();
    } finally {
      _busy = false;
    }
  }

  @override
  void cancel() {
    _closed = true;
    _signIn.cancel();
  }
}
