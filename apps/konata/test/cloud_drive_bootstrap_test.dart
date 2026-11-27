import 'dart:convert';
import 'dart:io';

import 'package:engine_cloud_drives/engine_cloud_drives.dart';
import 'package:feature_sources/feature_sources.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata/bootstrap/app_bootstrap.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final platform in [
    KonataPlatform.windows,
    KonataPlatform.androidPhone,
  ]) {
    test('宿主双端注册云盘驱动且只在访问时加载授权', () async {
      final root = Directory.systemTemp.createTempSync('konata_cloud_host_');
      addTearDown(() => root.deleteSync(recursive: true));
      final storage = InMemorySecureStorage();
      var requests = 0;
      final signInClientIds = <String?>[];
      final boot = await KonataBootstrapContext.initialize(
        platform: platform,
        storageRoot: PortableStorageRootService(overrideRootPath: root.path),
        secureStorage: storage,
        useInMemoryDatabases: true,
        autoStartDetailWarmupAndBackfill: false,
        autoStartOngoingWorksSync: false,
        cloudDriveRequest: (method, uri, headers, body) async {
          requests++;
          if (uri.path == '/v1/shield/captcha/init') {
            return KonataHttpResponse.text(
              jsonEncode({
                'captcha_token': 'fixture-captcha',
                'expires_in': 60,
              }),
            );
          }
          if (uri.path == '/v1/auth/verification') {
            signInClientIds.add(headers['X-Client-Id']);
            return KonataHttpResponse.text(
              jsonEncode({'verification_id': 'fixture-verification'}),
            );
          }
          final response = uri.host == 'account.guangyapan.com'
              ? <String, Object?>{
                  'access_token': 'fixture-access',
                  'refresh_token': 'fixture-rotated',
                  'sub': 'fixture-user',
                  'expires_in': 3600,
                }
              : <String, Object?>{
                  'code': 0,
                  'data': {
                    'total': 1,
                    'list': [
                      {
                        'fileId': '9876543210987654321',
                        'fileName': '01.mkv',
                        'resType': 1,
                        'fileSize': 100,
                      },
                    ],
                  },
                };
          return KonataHttpResponse.text(jsonEncode(response));
        },
      );
      addTearDown(boot.dispose);
      expect(requests, 0);
      expect(boot.databases.isCacheOpen, isFalse);
      const source = MediaSourceView(
        id: SourceId.trusted('source-cloud-fixture'),
        kind: MediaSourceKind.cloudDrive,
        label: '测试云盘',
        location: 'guangyapan://account_fixture/123',
      );
      await expectLater(
        boot.gatewayFactory.create(source),
        throwsA(isA<SourceAccessException>()),
      );
      expect(requests, 0);
      await boot.cloudDriveSessions.authorize(
        'account_fixture',
        const GuangYaCredentials(
          clientId: 'fixture-app',
          deviceId: '0123456789abcdef0123456789abcdef',
          refreshToken: 'fixture-refresh',
          subject: 'fixture-user',
        ),
      );
      expect(requests, 0);
      final gateway = await boot.gatewayFactory.create(source);
      addTearDown(gateway.close);
      final files = await gateway.listDirectory('');
      expect(requests, 2);
      expect(files.single.remoteFileId, '9876543210987654321');
      expect(files.single.name, '01.mkv');
      expect(
        (await boot.cloudDriveSessions.credentials.read(
          'account_fixture',
        ))!.refreshToken,
        'fixture-rotated',
      );
      expect(
        await storage.read('cloud.guangyapan.v1.account_fixture'),
        isNotNull,
      );
      await boot.cloudDriveSessions.signOut('account_fixture');
      expect(await storage.read('cloud.guangyapan.v1.account_fixture'), isNull);
      await expectLater(
        gateway.listDirectory(''),
        throwsA(isA<SourceAccessException>()),
      );
      expect(requests, 2);
      final providers = ProviderContainer(
        overrides: boot.toProviderOverrides(
          navigator: HostAppNavigator(
            navigatorKey: GlobalKey<NavigatorState>(),
            onSwitchNavSection: (_) {},
          ),
        ),
      );
      addTearDown(providers.dispose);
      final createSignIn = providers
          .read(featureSourcesDependenciesProvider)
          .createCloudSignIn;
      expect(createSignIn, isNotNull);
      final signIn = createSignIn!(null);
      addTearDown(signIn.cancel);
      await signIn.sendSms('+8613800101234', nationalNumber: '13800101234');
      expect(signInClientIds, ['aMe-8VSlkrbQXpUR']);
    });
  }
}
