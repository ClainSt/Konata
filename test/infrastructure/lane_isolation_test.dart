import 'dart:io';

import 'package:ccplayer/domain/config/konata_lane_config.dart';
import 'package:ccplayer/infrastructure/storage/storage_root_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_windows/path_provider_windows.dart';

class _FakePathProviderWindows extends PathProviderWindows {
  _FakePathProviderWindows({required this.fakeExePath, super.laneOverride});

  final String fakeExePath;

  @override
  String get executablePath => fakeExePath;
}

void main() {
  group('KonataLaneConfig 车道解析与标题隔离测试', () {
    test('默认空值与 main（含大小写及空白）保持主干零改动', () {
      for (final candidate in ['', '   ', 'main', ' MAIN ']) {
        expect(KonataLaneConfig.resolveLane(candidate), isEmpty);
        expect(KonataLaneConfig.isIsolatedLane(candidate), isFalse);
        expect(KonataLaneConfig.isolatedDirectoryName(candidate), isNull);
        expect(
          KonataLaneConfig.resolveDesktopWindowTitle(rawOverride: candidate),
          equals('Konata'),
        );
        expect(
          KonataLaneConfig.resolveAndroidLauncherLabel(rawOverride: candidate),
          equals('Konata'),
        );
      }
    });

    test('next 与 maint 等合法车道标识生成规范化隔离目录与标题后缀', () {
      expect(KonataLaneConfig.resolveLane('next'), equals('next'));
      expect(KonataLaneConfig.resolveLane(' NEXT '), equals('next'));
      expect(KonataLaneConfig.isIsolatedLane('next'), isTrue);
      expect(
        KonataLaneConfig.isolatedDirectoryName('next'),
        equals('Konata_next'),
      );
      expect(
        KonataLaneConfig.resolveDesktopWindowTitle(rawOverride: 'next'),
        equals('Konata [NEXT]'),
      );
      expect(
        KonataLaneConfig.resolveAndroidLauncherLabel(rawOverride: 'next'),
        equals('Konata (NEXT)'),
      );

      expect(KonataLaneConfig.resolveLane('maint'), equals('maint'));
      expect(
        KonataLaneConfig.isolatedDirectoryName('maint'),
        equals('Konata_maint'),
      );
      expect(
        KonataLaneConfig.resolveDesktopWindowTitle(rawOverride: 'maint'),
        equals('Konata [MAINT]'),
      );
      expect(
        KonataLaneConfig.resolveAndroidLauncherLabel(rawOverride: 'maint'),
        equals('Konata (MAINT)'),
      );
    });

    test('包含路径分隔符或横杠等非法字符时立即抛出参数异常', () {
      for (final invalid in ['../bad', 'feat-next', '123lane', 'next.v2']) {
        expect(
          () => KonataLaneConfig.resolveLane(invalid),
          throwsArgumentError,
        );
      }
    });
  });

  group('StorageRootService 与 PathProviderWindows 车道路径隔离测试', () {
    late Directory tempBase;

    setUp(() async {
      tempBase = await Directory.systemTemp.createTemp('konata_lane_root_');
    });

    tearDown(() async {
      if (await tempBase.exists()) {
        await tempBase.delete(recursive: true);
      }
    });

    test('主干与空值直接复用基础根目录，next/maint 自动落入独立后缀目录', () async {
      final mainRoot = StorageRootService.resolvePortableDesktopRootSync(
        baseDirectory: tempBase,
        laneOverride: '',
      );
      final explicitMainRoot =
          StorageRootService.resolvePortableDesktopRootSync(
            baseDirectory: tempBase,
            laneOverride: 'main',
          );
      final nextRoot = StorageRootService.resolvePortableDesktopRootSync(
        baseDirectory: tempBase,
        laneOverride: 'next',
      );
      final maintRoot = StorageRootService.resolvePortableDesktopRootSync(
        baseDirectory: tempBase,
        laneOverride: 'maint',
      );

      expect(mainRoot.path, equals(tempBase.path));
      expect(explicitMainRoot.path, equals(tempBase.path));
      expect(nextRoot.path, equals(p.join(tempBase.path, 'Konata_next')));
      expect(maintRoot.path, equals(p.join(tempBase.path, 'Konata_maint')));

      final nextStorage = StorageRootService(
        overrideRoot: tempBase,
        laneOverride: 'next',
      );
      final maintStorage = StorageRootService(
        overrideRoot: tempBase,
        laneOverride: 'maint',
      );

      expect(
        (await nextStorage.photosRootDir()).path,
        equals(p.join(tempBase.path, 'Konata_next', 'photos')),
      );
      expect(
        (await nextStorage.ensureLogsDir()).path,
        equals(p.join(tempBase.path, 'Konata_next', 'userdata', 'logs')),
      );
      expect(
        (await maintStorage.ensureMpvConfigDir()).path,
        equals(p.join(tempBase.path, 'Konata_maint', 'userdata', 'mpv')),
      );
      expect(
        (await maintStorage.ensureTempDir()).path,
        equals(p.join(tempBase.path, 'Konata_maint', 'cache', 'tmp')),
      );
    });

    test('Windows 端 PathProviderWindows 按车道严格分流数据库支持目录与缓存目录', () async {
      final fakeExe = p.join(tempBase.path, 'konata.exe');

      final defaultProvider = _FakePathProviderWindows(
        fakeExePath: fakeExe,
        laneOverride: '',
      );
      final explicitMainProvider = _FakePathProviderWindows(
        fakeExePath: fakeExe,
        laneOverride: 'main',
      );
      final nextProvider = _FakePathProviderWindows(
        fakeExePath: fakeExe,
        laneOverride: 'next',
      );
      final maintProvider = _FakePathProviderWindows(
        fakeExePath: fakeExe,
        laneOverride: 'maint',
      );

      expect(
        await defaultProvider.getApplicationSupportPath(),
        equals(p.join(tempBase.path, 'userdata')),
      );
      expect(
        await explicitMainProvider.getApplicationSupportPath(),
        equals(p.join(tempBase.path, 'userdata')),
      );
      expect(
        await nextProvider.getApplicationSupportPath(),
        equals(p.join(tempBase.path, 'Konata_next', 'userdata')),
      );
      expect(
        await nextProvider.getTemporaryPath(),
        equals(p.join(tempBase.path, 'Konata_next', 'cache', 'tmp')),
      );
      expect(
        await nextProvider.getApplicationCachePath(),
        equals(p.join(tempBase.path, 'Konata_next', 'cache')),
      );
      expect(
        await maintProvider.getApplicationSupportPath(),
        equals(p.join(tempBase.path, 'Konata_maint', 'userdata')),
      );
      expect(
        await maintProvider.getTemporaryPath(),
        equals(p.join(tempBase.path, 'Konata_maint', 'cache', 'tmp')),
      );
    });
  });
}
