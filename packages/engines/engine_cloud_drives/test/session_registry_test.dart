import 'dart:convert';

import 'package:engine_cloud_drives/engine_cloud_drives.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:test/test.dart';

import 'credential_store_test.dart' show fixture;

final class _Storage implements SecureStoragePort {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<Map<String, String>> readAllWithPrefix(String prefix) async =>
      Map.fromEntries(values.entries.where((e) => e.key.startsWith(prefix)));
}

MediaSourceView source(String account, [String root = '123']) =>
    MediaSourceView(
      id: SourceId.trusted('source-$account-$root'),
      kind: MediaSourceKind.cloudDrive,
      label: '云盘',
      location: 'guangyapan://$account/$root',
    );

KonataHttpResponse reply(Map<String, Object?> value, {int status = 200}) =>
    KonataHttpResponse.text(jsonEncode(value), statusCode: status);

void main() {
  test('同一账号多个媒体源共享刷新，关闭单个网关不影响其他网关', () async {
    final store = GuangYaCredentialStore(_Storage());
    var refreshes = 0, reads = 0;
    final registry = GuangYaSessionRegistry(
      credentials: store,
      spacing: Duration.zero,
      request: (method, uri, headers, body) async {
        if (uri.host == 'account.guangyapan.com') {
          refreshes++;
          expect(body?['refresh_token'], 'token-old');
          return reply({
            'access_token': 'access',
            'refresh_token': 'token-new',
            'sub': 'user-a',
            'expires_in': 3600,
          });
        }
        reads++;
        expect(headers['Authorization'], 'Bearer access');
        return reply({
          'code': 0,
          'data': {'list': <Object?>[], 'total': 0},
        });
      },
    );
    addTearDown(registry.close);
    await registry.authorize('account_a', fixture('user-a', 'token-old'));
    final gateways = await Future.wait([
      registry.contribution.create(source('account_a')),
      registry.create(source('account_a', '456')),
    ]);
    await Future.wait(gateways.map((g) => g.listDirectory('')));
    expect(refreshes, 1);
    expect(reads, 2);
    expect((await store.read('account_a'))!.refreshToken, 'token-new');
    await gateways.first.close();
    await gateways.last.listDirectory('');
    final next = await registry.create(source('account_a', '789'));
    await next.listDirectory('');
    expect(refreshes, 1);
    await registry.signOut('account_a');
    expect(await store.read('account_a'), isNull);
    await expectLater(
      next.listDirectory(''),
      throwsA(isA<SourceAccessException>()),
    );
    await expectLater(
      registry.create(source('account_a')),
      throwsA(isA<SourceAccessException>()),
    );
  });

  test('注销和重新授权失效旧网关，账号之间不共享凭据', () async {
    final store = GuangYaCredentialStore(_Storage());
    final registry = GuangYaSessionRegistry(
      credentials: store,
      spacing: Duration.zero,
      request: (method, uri, headers, body) async {
        if (uri.host == 'account.guangyapan.com') {
          final token = body!['refresh_token'] as String;
          return reply({
            'access_token': 'access-$token',
            'refresh_token': token,
            'sub': token.startsWith('b') ? 'user-b' : 'user-a',
            'expires_in': 3600,
          });
        }
        return reply({
          'code': 0,
          'data': {'list': <Object?>[], 'total': 0},
        });
      },
    );
    addTearDown(registry.close);
    await registry.authorize('account_a', fixture('user-a', 'a-old'));
    await registry.authorize('account_b', fixture('user-b', 'b-old'));
    final a = await registry.create(source('account_a'));
    final b = await registry.create(source('account_b'));
    await a.listDirectory('');
    await b.listDirectory('');
    await registry.authorize(
      'account_a',
      fixture('user-a', 'a-new', client: 'new-app'),
    );
    await expectLater(
      a.listDirectory(''),
      throwsA(isA<SourceAccessException>()),
    );
    final next = await registry.create(source('account_a'));
    await next.listDirectory('');
    await registry.signOut('account_a');
    await b.listDirectory('');
    expect((await store.read('account_b'))!.refreshToken, 'b-old');
    await registry.close();
    await expectLater(
      b.listDirectory(''),
      throwsA(isA<SourceAccessException>()),
    );
    expect(await store.read('account_b'), isNotNull);
  });
  test('非法媒体源地址不读取授权或发送网络请求', () async {
    final registry = GuangYaSessionRegistry(
      credentials: GuangYaCredentialStore(_Storage()),
      request: (method, uri, headers, body) async => throw StateError('不应请求'),
    );
    addTearDown(registry.close);
    for (final location in [
      'guangyapan://account_a/123?token=fixture',
      'guangyapan://user:secret@account_a/123',
      'guangyapan://account_a/a/b',
    ]) {
      await expectLater(
        registry.create(
          MediaSourceView(
            id: const SourceId.trusted('source'),
            kind: MediaSourceKind.cloudDrive,
            label: '云盘',
            location: location,
          ),
        ),
        throwsA(isA<SourceAccessException>()),
      );
    }
  });
}
