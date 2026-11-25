import 'dart:async';
import 'dart:io';

import 'package:konata_contracts/konata_contracts.dart';

import 'guangya_credential_store.dart';
import 'guangya_gateway.dart';
import 'guangya_protocol.dart';

/// 宿主共享的云盘账号会话中心；同一账号共享刷新与限流状态。
final class GuangYaSessionRegistry {
  GuangYaSessionRegistry({
    required this.credentials,
    required this.request,
    this.createHttpClient,
    this.spacing = const Duration(milliseconds: 550),
  });

  final GuangYaCredentialStore credentials;
  final GuangYaRequest request;
  final HttpClient Function()? createHttpClient;
  final Duration spacing;
  final _sessions = <String, _AccountSession>{};
  final _tails = <String, Future<void>>{};
  bool _closed = false;

  void _check() {
    if (_closed) {
      throw const SourceAccessException(
        SourceAccessProblemKind.network,
        '云盘会话中心已关闭',
      );
    }
  }

  Future<T> _serial<T>(String account, Future<T> Function() task) async {
    _check();
    final previous = _tails[account] ?? Future<void>.value();
    final done = Completer<void>();
    _tails[account] = done.future;
    try {
      await previous;
      _check();
      return await task();
    } finally {
      done.complete();
      if (identical(_tails[account], done.future)) {
        unawaited(_tails.remove(account));
      }
    }
  }

  /// 媒体源虚拟地址只含账号绑定标识与目录标识。
  static Uri _location(MediaSourceView source) {
    final uri = Uri.tryParse(source.location);
    if (source.kind != MediaSourceKind.cloudDrive ||
        uri == null ||
        uri.scheme != 'guangyapan' ||
        !RegExp(r'^[a-z0-9_-]{8,128}$').hasMatch(uri.host) ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.pathSegments.length > 1 ||
        uri.pathSegments.any(
          (s) =>
              s.isEmpty ||
              s == '.' ||
              s == '..' ||
              s.contains('/') ||
              s.contains('\\'),
        )) {
      throw const SourceAccessException(
        SourceAccessProblemKind.path,
        '云盘媒体源地址无效',
      );
    }
    return uri;
  }

  CloudDriveProviderContribution get contribution =>
      CloudDriveProviderContribution(
        scheme: 'guangyapan',
        displayName: '光鸭云盘',
        create: create,
      );

  Future<CloudDriveGateway> create(MediaSourceView source) async {
    final uri = _location(source);
    final account = uri.host;
    return _serial(account, () async {
      var session = _sessions[account];
      if (session == null) {
        final saved = await credentials.read(account);
        _check();
        if (saved == null) {
          throw const SourceAccessException(
            SourceAccessProblemKind.authentication,
            '请在本机授权云盘账号',
          );
        }
        var expected = saved;
        final protocol = LegacyGuangYaProtocol(
          credentials: saved,
          request: request,
          spacing: spacing,
          persistRefresh: (token) async {
            await credentials.rotate(
              account,
              expected: expected,
              refreshToken: token,
            );
            expected = GuangYaCredentials(
              clientId: saved.clientId,
              deviceId: saved.deviceId,
              refreshToken: token,
              subject: saved.subject,
              deviceSign: saved.deviceSign,
            );
          },
        );
        session = _AccountSession(protocol);
        _sessions[account] = session;
      }
      return session.open(uri.pathSegments.firstOrNull ?? '', createHttpClient);
    });
  }

  /// 重新授权后立即失效旧网关；不携带其他应用的会话。
  Future<void> authorize(String account, GuangYaCredentials value) =>
      _serial(account, () async {
        await credentials.save(account, value);
        await _sessions.remove(account)?.close();
      });

  /// 本机注销先关闭读取会话，再删除授权，不写入远端。
  Future<void> signOut(String account) => _serial(account, () async {
    await _sessions.remove(account)?.close();
    await credentials.remove(account);
  });

  /// 应用退出时释放全部会话，不删除本机已保存授权。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await Future.wait(_tails.values.toList());
    final sessions = _sessions.values.toList();
    _sessions.clear();
    await Future.wait(sessions.map((s) => s.close()));
  }
}

final class _AccountSession {
  _AccountSession(this.protocol);
  final LegacyGuangYaProtocol protocol;
  final _gateways = <GuangYaGateway>{};

  GuangYaGateway open(String root, HttpClient Function()? createHttpClient) {
    late final GuangYaGateway gateway;
    gateway = GuangYaGateway(
      protocol: _ProtocolLease(protocol, () => _gateways.remove(gateway)),
      rootId: root,
      createHttpClient: createHttpClient,
    );
    _gateways.add(gateway);
    return gateway;
  }

  Future<void> close() async {
    await protocol.close();
    await Future.wait(_gateways.toList().map((g) => g.close()));
    _gateways.clear();
  }
}

/// 关闭单个媒体源仅释放其网关，不中断同账号其他活动媒体源。
final class _ProtocolLease implements GuangYaProtocol {
  _ProtocolLease(this._protocol, this._release);
  final GuangYaProtocol _protocol;
  final void Function() _release;
  bool _closed = false;

  void _check() {
    if (_closed) {
      throw const SourceAccessException(
        SourceAccessProblemKind.network,
        '云盘读取会话已关闭',
      );
    }
  }

  @override
  Future<List<GuangYaFile>> list(String parentId) async {
    _check();
    final result = await _protocol.list(parentId);
    _check();
    return result;
  }

  @override
  Future<RenewableLink> link(String fileId) async {
    _check();
    final result = await _protocol.link(fileId);
    _check();
    return result;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _release();
  }
}
