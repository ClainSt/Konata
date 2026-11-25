import 'package:engine_cloud_drives/engine_cloud_drives.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:test/test.dart';

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

GuangYaCredentials fixture(
  String subject,
  String token, {
  String client = 'fixture-app',
}) => GuangYaCredentials(
  clientId: client,
  deviceId: '0123456789abcdef0123456789abcdef',
  refreshToken: token,
  subject: subject,
);

void main() {
  test('账号凭据隔离与重新授权主体保护', () async {
    final storage = _Storage();
    final store = GuangYaCredentialStore(storage);
    await store.save('account_a', fixture('user-a', 'token-a'));
    await store.save('account_b', fixture('user-b', 'token-b'));
    expect((await store.read('account_a'))!.refreshToken, 'token-a');
    expect((await store.read('account_b'))!.refreshToken, 'token-b');
    await expectLater(
      store.save('account_a', fixture('user-b', 'token-c')),
      throwsA(isA<SourceAccessException>()),
    );
    expect((await store.read('account_a'))!.subject, 'user-a');
    await store.remove('account_a');
    expect(await store.read('account_a'), isNull);
    expect((await store.read('account_b'))!.refreshToken, 'token-b');
  });
  test('只枚举有效本机授权绑定，不返回凭据', () async {
    final storage = _Storage();
    final store = GuangYaCredentialStore(storage);
    await store.save('account_b', fixture('user-b', 'token-b'));
    await store.save('account_a', fixture('user-a', 'token-a'));
    storage.values['cloud.guangyapan.v1.account_c'] = 'broken';
    storage.values['other.provider.account_d'] = 'unrelated';
    expect(await store.listAccounts(), ['account_a', 'account_b']);
    await store.remove('account_a');
    expect(await store.listAccounts(), ['account_b']);
  });
  test('并发轮换仅允许一次成功且旧令牌无法覆盖新授权', () async {
    final store = GuangYaCredentialStore(_Storage());
    final original = fixture('user-a', 'token-old');
    await store.save('account_a', original);
    final results = await Future.wait([
      for (final token in ['token-one', 'token-two'])
        store
            .rotate('account_a', expected: original, refreshToken: token)
            .then((_) => true, onError: (Object _) => false),
    ]);
    expect(results.where((x) => x).length, 1);
    expect((await store.read('account_a'))!.refreshToken, 'token-one');
    final old = (await store.read('account_a'))!;
    await store.save(
      'account_a',
      fixture('user-a', 'new-login', client: 'new-app'),
    );
    await expectLater(
      store.rotate('account_a', expected: old, refreshToken: 'stale'),
      throwsA(isA<SourceAccessException>()),
    );
    expect((await store.read('account_a'))!.clientId, 'new-app');
  });
  test('注销后迟到的刷新不得复活凭据', () async {
    final store = GuangYaCredentialStore(_Storage());
    final old = fixture('user-a', 'token-old');
    await store.save('account_a', old);
    await store.remove('account_a');
    await expectLater(
      store.rotate('account_a', expected: old, refreshToken: 'late'),
      throwsA(isA<SourceAccessException>()),
    );
    expect(await store.read('account_a'), isNull);
  });
  test('非法绑定标识和损坏凭据安全失败', () async {
    final storage = _Storage();
    final store = GuangYaCredentialStore(storage);
    await expectLater(store.read('../other'), throwsArgumentError);
    storage.values['cloud.guangyapan.v1.account_a'] = 'broken';
    await expectLater(
      store.read('account_a'),
      throwsA(isA<SourceAccessException>()),
    );
  });
}
