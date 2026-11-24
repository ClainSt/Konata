import 'dart:convert';
import 'dart:io';

import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('DiagnosticLogStore 结构化脱敏与四层环形隔离', () {
    test('高频信息日志不冲刷异常环，且导出自动脱敏并落盘至 logs 目录', () async {
      final tempDir = await Directory.systemTemp.createTemp('konata_logs_');
      addTearDown(() async {
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
      });

      var tick = 0;
      final store = DiagnosticLogStore(
        maxEntries: 5,
        maxErrorEntries: 10,
        clock: () => DateTime.utc(2026, 1, 1, 0, 0, tick++),
      );
      store.registerSnapshotContributor(
        'storage',
        () => const DiagnosticSnapshotSection(
          id: 'storage',
          title: '存储状态',
          entries: <String, String>{
            'dbMode': 'WAL',
            'webdav_password': 'plain-secret-value',
          },
        ),
      );

      store.logError(
        subsystem: DiagnosticSubsystem.source,
        code: 'WEBDAV_401',
        message: '连接 https://user:myPass99@dav.test/anime?token=abc123 失败',
        error: StateError(r'C:\Users\SecretUser\file.mkv 读取拒绝'),
        context: const <String, Object?>{
          'sourceId': 'src-1',
          'api_key': 'tmdb_secret_key',
        },
      );

      // 灌入超出全局时间线容量上限的普通事件，验证异常环未被冲刷。
      for (var i = 0; i < 10; i++) {
        store.logEvent(
          subsystem: DiagnosticSubsystem.playback,
          code: 'PLAY_STEP',
          message: '播放里程碑 $i',
        );
      }

      store.recordBreadcrumb(
        category: 'route',
        label: '进入作品详情页',
        detail: 'workId=w-1',
      );

      final faults = store.summarizeFaults();
      expect(faults, hasLength(1));
      expect(faults.single.code, 'WEBDAV_401');
      expect(faults.single.sampleContext['api_key'], '***');

      final jsonText = await store.buildJsonBundle();
      expect(jsonText, isNot(contains('myPass99')));
      expect(jsonText, isNot(contains('abc123')));
      expect(jsonText, isNot(contains('tmdb_secret_key')));
      expect(jsonText, isNot(contains('plain-secret-value')));
      expect(jsonText, isNot(contains('SecretUser')));
      expect(jsonText, contains('<USER_HOME>'));

      final decoded = jsonDecode(jsonText) as Map<String, Object?>;
      expect(decoded['schemaVersion'], 3);

      final storageRoot = PortableStorageRootService(
        overrideRootPath: tempDir.path,
      );
      final exportedPath = await store.exportToLogsDir(storageRoot);
      expect(File(exportedPath).existsSync(), isTrue);
      expect(
        exportedPath,
        contains(p.join(StoragePathNames.userdataDir, StoragePathNames.logsSubdir)),
      );
    });
  });

  group('PortableStorageRootService 绿色便携与车道隔离', () {
    test('发布态定位可执行同级目录、开发态回溯工作区根、非主干分流 Konata_<lane>', () async {
      final tempDir = await Directory.systemTemp.createTemp('konata_root_');
      addTearDown(() async {
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
      });

      // 模拟发布态（当前工作目录无 pubspec.yaml）：应严格取可执行文件同级目录。
      final releaseDir = Directory(p.join(tempDir.path, 'ReleasePortable'))
        ..createSync(recursive: true);
      final fakeExe = p.join(releaseDir.path, 'Konata.exe');
      final detectedRelease = PortableStorageRootService.detectDesktopBasePathSync(
        workingDirectoryPath: tempDir.path,
        resolvedExecutablePath: fakeExe,
      );
      expect(detectedRelease, releaseDir.path);

      // 模拟隔离车道与三库路径布局。
      final laneService = PortableStorageRootService(
        overrideRootPath: releaseDir.path,
        laneOverride: 'next',
      );
      final dbPath = await laneService.resolveDatabaseFilePath(
        StoragePathNames.libraryDbFile,
      );
      expect(
        dbPath,
        p.join(
          releaseDir.path,
          'Konata_next',
          StoragePathNames.userdataDir,
          StoragePathNames.dbSubdir,
          StoragePathNames.libraryDbFile,
        ),
      );
      expect(
        await laneService.ensureTempDirPath(),
        p.join(
          releaseDir.path,
          'Konata_next',
          StoragePathNames.cacheDir,
          StoragePathNames.tempSubdir,
        ),
      );
    });

    test('InMemorySecureStorage 支持写入、前缀筛选与空值删除', () async {
      final storage = InMemorySecureStorage();
      await storage.write('source.1', 'pwd-1');
      await storage.write('source.2', 'pwd-2');
      await storage.write('tracker.bgm', 'pat-xyz');

      expect(await storage.read('source.1'), 'pwd-1');
      expect(
        (await storage.readAllWithPrefix('source.')).keys.toSet(),
        equals(<String>{'source.1', 'source.2'}),
      );

      await storage.write('source.1', '');
      expect(await storage.read('source.1'), isNull);
    });
  });
}
