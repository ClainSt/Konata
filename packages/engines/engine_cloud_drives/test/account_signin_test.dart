import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

KonataHttpResponse reply(Map<String, Object?> obj) =>
    KonataHttpResponse.text(jsonEncode(obj), statusCode: 200);

void main() {
  test('用户主动短信授权返回稳定地址且不返回凭据，重新授权保留绑定', () async {
    final store = GuangYaCredentialStore(_Storage());
    final paths = <String>[];
    final registry = GuangYaSessionRegistry(
      credentials: store,
      spacing: Duration.zero,
      request: (method, uri, headers, body) async {
        expect(headers['X-Client-Id'], 'fixture-authorized-app');
        if (Platform.isWindows) {
          expect(
            headers['User-Agent'],
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/158.0.0.0 Safari/537.36',
          );
        } else {
          expect(headers.containsKey('User-Agent'), isFalse);
        }
        expect(headers['X-Device-Id'], matches(RegExp(r'^[a-f0-9]{32}$')));
        if (uri.path == '/v1/auth/verification') {
          expect(headers['X-Captcha-Token'], 'fixture-captcha');
        } else {
          expect(headers.containsKey('X-Captcha-Token'), isFalse);
        }
        paths.add(uri.path);
        return reply(switch (uri.path) {
          '/v1/shield/captcha/init' => {
            'captcha_token': 'fixture-captcha',
            'expires_in': 60,
          },
          '/v1/auth/verification' => {'verification_id': 'fixture-id'},
          '/v1/auth/verification/verify' => {
            'verification_token': 'fixture-verification',
          },
          '/v1/auth/signin' => {
            'access_token': 'fixture-access',
            'refresh_token': 'fixture-refresh',
            'sub': 'fixture-subject',
            'expires_in': 3600,
          },
          _ => throw StateError('不应请求'),
        });
      },
    );
    addTearDown(registry.close);
    final signIn = GuangYaAccountSignIn(
      sessions: registry,
      clientId: 'fixture-authorized-app',
    );
    expect(paths, isEmpty);
    await signIn.sendSms('+15550101234', nationalNumber: '5550101234');
    await expectLater(
      signIn.sendSms('+15550101234'),
      throwsA(isA<SourceAccessException>()),
    );
    final location = await signIn.finishSms('123456');
    final binding = GuangYaAccountSignIn.accountBinding('fixture-subject');
    expect(Uri.parse(location).host, binding);
    expect(location, isNot(contains('fixture-subject')));
    expect(location, isNot(contains('fixture-refresh')));
    expect(paths, [
      '/v1/shield/captcha/init',
      '/v1/auth/verification',
      '/v1/auth/verification/verify',
      '/v1/auth/signin',
    ]);
    expect((await store.read(binding))!.refreshToken, 'fixture-refresh');
    expect(await store.readMaskedPhone(binding), '555****1234');
    final saved = (await store.read(binding))!;
    await store.rotate(binding, expected: saved, refreshToken: 'rotated');
    expect(await store.readMaskedPhone(binding), '555****1234');
    await registry.signOut(binding);
    final again = GuangYaAccountSignIn(
      sessions: registry,
      clientId: 'fixture-authorized-app',
      expectedLocation: location,
    );
    await again.sendSms('+15550101234');
    expect(await again.finishSms('123456'), location);
    final wrong = GuangYaAccountSignIn(
      sessions: registry,
      clientId: 'fixture-authorized-app',
      expectedLocation: 'guangyapan://other_account',
    );
    await wrong.sendSms('+15550101234');
    await expectLater(
      wrong.finishSms('123456'),
      throwsA(isA<SourceAccessException>()),
    );
    expect(await store.listAccounts(), [binding]);
  });

  test('取消授权后不保存迟到的验证结果', () async {
    final store = GuangYaCredentialStore(_Storage());
    final pending = Completer<KonataHttpResponse>();
    var requests = 0;
    final registry = GuangYaSessionRegistry(
      credentials: store,
      request: (method, uri, headers, body) {
        requests++;
        return pending.future;
      },
    );
    addTearDown(registry.close);
    final signIn = GuangYaAccountSignIn(
      sessions: registry,
      clientId: 'fixture-authorized-app',
    );
    final sending = signIn.sendSms('+15550101234');
    signIn.cancel();
    pending.complete(
      reply({'captcha_token': 'fixture-captcha', 'expires_in': 60}),
    );
    await expectLater(sending, throwsA(isA<SourceAccessException>()));
    await expectLater(
      signIn.finishSms('123456'),
      throwsA(isA<SourceAccessException>()),
    );
    expect(requests, 1);
    expect(await store.listAccounts(), isEmpty);
  });
}
