import 'dart:async';
import 'dart:convert';

import 'package:konata_contracts/konata_contracts.dart';

import 'guangya_protocol.dart';

/// 光鸭本机凭据仓储；每个账号独立键，禁止同步。
final class GuangYaCredentialStore {
  GuangYaCredentialStore(this._storage);

  final SecureStoragePort _storage;
  final _tails = <String, Future<void>>{};
  static final _validAccount = RegExp(r'^[a-z0-9_-]{8,128}$');

  String _key(String account) {
    if (!_validAccount.hasMatch(account)) {
      throw ArgumentError('云盘账号绑定标识无效');
    }
    return 'cloud.guangyapan.v1.$account';
  }

  /// 同一账号的读写与删除串行执行，结束后释放队列。
  Future<T> _serial<T>(
    String account,
    Future<T> Function(String key) task,
  ) async {
    final key = _key(account);
    final previous = _tails[key] ?? Future<void>.value();
    final done = Completer<void>();
    _tails[key] = done.future;
    try {
      await previous;
      return await task(key);
    } finally {
      done.complete();
      if (identical(_tails[key], done.future)) unawaited(_tails.remove(key));
    }
  }

  static GuangYaCredentials _decode(String raw) {
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final value = GuangYaCredentials(
        clientId: data['clientId'] as String,
        deviceId: data['deviceId'] as String,
        refreshToken: data['refreshToken'] as String,
        subject: data['subject'] as String,
        deviceSign: data['deviceSign'] as String?,
        maskedPhone: _safeMask(data['maskedPhone']),
      );
      _validate(value);
      return value;
    } catch (_) {
      throw const SourceAccessException(
        SourceAccessProblemKind.authentication,
        '本机云盘凭据无效，请重新授权',
      );
    }
  }

  static String? _safeMask(Object? value) =>
      value is String && RegExp(r'^\d{2,3}\*{4}\d{4}$').hasMatch(value)
      ? value
      : null;

  /// 仅提供脱敏号码，不返回凭据。
  Future<String?> readMaskedPhone(String account) async =>
      (await read(account))?.maskedPhone;

  static void _validate(GuangYaCredentials value) {
    if (value.clientId.isEmpty ||
        value.refreshToken.isEmpty ||
        value.subject.isEmpty ||
        !RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(value.deviceId)) {
      throw ArgumentError('云盘授权凭据不完整');
    }
  }

  static String _encode(GuangYaCredentials value) => jsonEncode({
    'clientId': value.clientId,
    'deviceId': value.deviceId,
    'refreshToken': value.refreshToken,
    'subject': value.subject,
    if (value.deviceSign != null) 'deviceSign': value.deviceSign,
    if (_safeMask(value.maskedPhone) != null) 'maskedPhone': value.maskedPhone,
  });

  Future<GuangYaCredentials?> read(String account) =>
      _serial(account, (key) async {
        final raw = await _storage.read(key);
        return raw == null ? null : _decode(raw);
      });

  /// 只返回本机有效授权的绑定标识，不向视图提供任何凭据。
  Future<List<String>> listAccounts() async {
    const prefix = 'cloud.guangyapan.v1.';
    final entries = await _storage.readAllWithPrefix(prefix);
    final accounts = <String>[];
    for (final entry in entries.entries) {
      if (!entry.key.startsWith(prefix)) continue;
      final account = entry.key.substring(prefix.length);
      if (!_validAccount.hasMatch(account)) continue;
      try {
        _decode(entry.value);
        accounts.add(account);
      } on SourceAccessException {
        // 损坏授权不出现在可选列表中。
      }
    }
    accounts.sort();
    return List<String>.unmodifiable(accounts);
  }

  /// 绑定同一账号时不得更换服务端主体。
  Future<void> save(String account, GuangYaCredentials credentials) =>
      _serial(account, (key) async {
        _validate(credentials);
        final raw = await _storage.read(key);
        if (raw != null && _decode(raw).subject != credentials.subject) {
          throw const SourceAccessException(
            SourceAccessProblemKind.authentication,
            '云盘账号主体不匹配，请添加独立媒体源',
          );
        }
        await _storage.write(key, _encode(credentials));
      });

  /// 比较旧令牌与应用、设备、主体，阻止过期会话覆盖新授权或注销状态。
  Future<void> rotate(
    String account, {
    required GuangYaCredentials expected,
    required String refreshToken,
  }) => _serial(account, (key) async {
    final raw = await _storage.read(key);
    final current = raw == null ? null : _decode(raw);
    if (current == null ||
        current.subject != expected.subject ||
        current.clientId != expected.clientId ||
        current.deviceId != expected.deviceId ||
        current.deviceSign != expected.deviceSign ||
        current.refreshToken != expected.refreshToken ||
        refreshToken.isEmpty) {
      throw const SourceAccessException(
        SourceAccessProblemKind.authentication,
        '云盘授权已变化，请重新连接',
      );
    }
    await _storage.write(
      key,
      _encode(
        GuangYaCredentials(
          clientId: current.clientId,
          deviceId: current.deviceId,
          refreshToken: refreshToken,
          subject: current.subject,
          deviceSign: current.deviceSign,
          maskedPhone: current.maskedPhone,
        ),
      ),
    );
  });

  /// 仅清除本机授权，不修改远端文件。
  Future<void> remove(String account) =>
      _serial(account, (key) => _storage.delete(key));
}
