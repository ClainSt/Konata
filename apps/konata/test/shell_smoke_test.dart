import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata/bootstrap/app_bootstrap.dart';
import 'package:konata/bootstrap/feature_registry.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';
import 'package:konata_storage/konata_storage.dart';

void main() {
  group('apps/konata 双端极薄组装壳', () {
    testWidgets('可完成内存底座初始化、挂载三端同源主题外壳且保持 cache.db 惰性未打开', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final bootstrap = await KonataBootstrapContext.initialize(
        platform: KonataPlatform.windows,
        storageRoot: const PortableStorageRootService(
          overrideRootPath: r'D:\Temp\KonataSmoke',
        ),
        secureStorage: InMemorySecureStorage(),
        useInMemoryDatabases: true,
      );
      addTearDown(bootstrap.databases.close);
      addTearDown(bootstrap.domainEventBus.dispose);

      expect(bootstrap.databases.isCacheOpen, isFalse);

      await tester.pumpWidget(
        KonataBootstrapApp(
          bootstrap: bootstrap,
          platformLabel: 'Windows',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(KonataAdaptiveShell), findsOneWidget);
      expect(find.text('Konata v3 (Windows)'), findsOneWidget);
      expect(find.textContaining('缓存库惰性态=未开'), findsOneWidget);
    });

    test('FeatureRegistry 强制校验字母序与唯一标识并按平台过滤扩展点', () {
      expect(
        () => FeatureRegistry(<FeatureManifest>[
          const FeatureManifest(id: 'feature_z', displayName: 'Z'),
          const FeatureManifest(id: 'feature_a', displayName: 'A'),
        ]),
        throwsArgumentError,
      );
      expect(
        () => FeatureRegistry(<FeatureManifest>[
          const FeatureManifest(id: 'feature_a', displayName: 'A1'),
          const FeatureManifest(id: 'feature_a', displayName: 'A2'),
        ]),
        throwsArgumentError,
      );

      final registry = FeatureRegistry(<FeatureManifest>[
        FeatureManifest(
          id: 'feature_alpha',
          displayName: 'Alpha',
          settingsSections: <SettingsSectionContribution>[
            SettingsSectionContribution(
              id: 'win_only',
              title: '仅桌面设置',
              iconKey: 'desktop',
              order: 20,
              supportedPlatforms: const <KonataPlatform>{KonataPlatform.windows},
              viewBuilder: (_) => 'win',
            ),
            SettingsSectionContribution(
              id: 'common',
              title: '通用设置',
              iconKey: 'settings',
              order: 10,
              viewBuilder: (_) => 'all',
            ),
          ],
        ),
      ]);

      final winSections = registry.settingsSectionsFor(KonataPlatform.windows);
      expect(
        winSections.map((s) => s.id),
        equals(<String>['common', 'win_only']),
      );

      final phoneSections = registry.settingsSectionsFor(
        KonataPlatform.androidPhone,
      );
      expect(phoneSections.map((s) => s.id), equals(<String>['common']));
    });
  });
}
