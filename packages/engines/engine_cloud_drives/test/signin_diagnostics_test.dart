import 'package:engine_cloud_drives/engine_cloud_drives.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:test/test.dart';

void main() {
  for (final item in [
    (401, '{}', SourceAccessProblemKind.permission),
    (403, '{}', SourceAccessProblemKind.permission),
    (200, '{"error":"invalid_client"}', SourceAccessProblemKind.permission),
    (404, '{}', SourceAccessProblemKind.unknown),
    (200, '<html>fixture</html>', SourceAccessProblemKind.unknown),
    (503, '{}', SourceAccessProblemKind.network),
    (
      200,
      '{"code":123,"msg":"fixture-secret"}',
      SourceAccessProblemKind.authentication,
    ),
    (200, '{}', SourceAccessProblemKind.authentication),
  ]) {
    test('授权失败分类不泄露响应正文：HTTP ${item.$1}', () async {
      var calls = 0;
      final signIn = LegacyGuangYaSignIn(
        clientId: 'fixture-app',
        deviceId: '0123456789abcdef0123456789abcdef',
        request: (method, uri, headers, body) async {
          calls++;
          return KonataHttpResponse.text(item.$2, statusCode: item.$1);
        },
      );
      await expectLater(
        signIn.sendSms('+15550101234'),
        throwsA(
          isA<SourceAccessException>()
              .having((e) => e.kind, 'kind', item.$3)
              .having(
                (e) => e.message,
                'safe message',
                isNot(contains('fixture-secret')),
              ),
        ),
      );
      expect(calls, 1);
    });
  }
  test('诊断仅暴露 HTTP 状态与有界数字错误码', () async {
    final signIn = LegacyGuangYaSignIn(
      clientId: 'fixture-app',
      deviceId: '0123456789abcdef0123456789abcdef',
      request: (method, uri, headers, body) async => KonataHttpResponse.text(
        '{"code":123,"msg":"private-fixture"}',
        statusCode: 200,
      ),
    );
    await expectLater(
      signIn.sendSms('+15550101234'),
      throwsA(
        isA<SourceAccessException>().having(
          (e) => e.cause,
          'diagnostic',
          isA<CloudAuthorizationDiagnostic>()
              .having((e) => e.httpStatus, 'status', 200)
              .having((e) => e.serviceCode, 'code', 123),
        ),
      ),
    );
  });

  test('正常短信成功提示不被误判为风控', () async {
    var calls = 0;
    final signIn = LegacyGuangYaSignIn(
      clientId: 'fixture-app',
      deviceId: '0123456789abcdef0123456789abcdef',
      request: (method, uri, headers, body) async {
        calls++;
        return KonataHttpResponse.text(
          '{"code":0,"msg":"验证码发送成功","verification_id":"fixture-id"}',
        );
      },
    );
    await signIn.sendSms('+15550101234');
    expect(calls, 1);
    await expectLater(
      signIn.sendSms('+15550101234'),
      throwsA(isA<SourceAccessException>()),
    );
    expect(calls, 1);
  });

  test('明确的额外验证提示仍停止事务', () async {
    for (final msg in ['请完成图形验证码', '请完成人机验证', '需要安全验证']) {
      var calls = 0;
      final signIn = LegacyGuangYaSignIn(
        clientId: 'fixture-app',
        deviceId: '0123456789abcdef0123456789abcdef',
        request: (method, uri, headers, body) async {
          calls++;
          return KonataHttpResponse.text('{"code":123,"message":"$msg"}');
        },
      );
      await expectLater(
        signIn.sendSms('+15550101234'),
        throwsA(isA<RiskControlled>()),
      );
      await expectLater(
        signIn.sendSms('+15550101234'),
        throwsA(isA<RiskControlled>()),
      );
      expect(calls, 1);
    }
  });

  test('风控与限流停止事务而不重发短信', () async {
    for (final response in [
      KonataHttpResponse.text('{"error":"captcha_required"}'),
      KonataHttpResponse.text('{}', statusCode: 429),
    ]) {
      var calls = 0;
      final signIn = LegacyGuangYaSignIn(
        clientId: 'fixture-app',
        deviceId: '0123456789abcdef0123456789abcdef',
        request: (method, uri, headers, body) async {
          calls++;
          return response;
        },
      );
      await expectLater(
        signIn.sendSms('+15550101234'),
        throwsA(anyOf(isA<RiskControlled>(), isA<SourceRateLimitException>())),
      );
      await expectLater(
        signIn.sendSms('+15550101234'),
        throwsA(isA<RiskControlled>()),
      );
      expect(calls, 1);
    }
  });
}
