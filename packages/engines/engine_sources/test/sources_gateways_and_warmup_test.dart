import 'dart:io';

import 'package:engine_sources/engine_sources.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _FakeWarmupGateway implements MediaSourceGateway {
  _FakeWarmupGateway(this.tree);

  final Map<String, List<RemoteEntry>> tree;
  final List<String> listed = <String>[];
  bool closed = false;

  @override
  Future<List<RemoteEntry>> listDirectory(String relativePath) async {
    listed.add(relativePath);
    return tree[relativePath] ?? const <RemoteEntry>[];
  }

  @override
  Future<String?> readTextFile(
    String relativePath, {
    int maxBytes = 262144,
  }) async => null;

  @override
  Future<String?> testConnection() async => null;

  @override
  Future<void> close() async {
    closed = true;
  }
}

class _FakeGatewayFactory implements MediaSourceGatewayFactoryPort {
  _FakeGatewayFactory(this.gateway);

  final _FakeWarmupGateway gateway;
  int createCount = 0;

  @override
  Future<MediaSourceGateway> create(
    MediaSourceView source, {
    String? passwordOverride,
    bool clearPassword = false,
  }) async {
    createCount += 1;
    return gateway;
  }
}

void main() {
  group('SourceLocationValidator 地址校验与规范化', () {
    test('支持本地路径、WebDAV HTTP(S) 与 SMB 445 端口及防穿越校验', () {
      expect(
        SourceLocationValidator.validate(MediaSourceKind.local, '').isValid,
        isFalse,
      );
      expect(
        SourceLocationValidator.validate(
          MediaSourceKind.local,
          ' D:\\Anime ',
        ).normalizedLocation,
        'D:\\Anime',
      );
      expect(
        SourceLocationValidator.validate(
          MediaSourceKind.webdav,
          'ftp://nas.local/anime',
        ).isValid,
        isFalse,
      );
      expect(
        SourceLocationValidator.validate(
          MediaSourceKind.webdav,
          'https://nas.local:5006/Anime',
        ).isValid,
        isTrue,
      );

      final smbUnc = SourceLocationValidator.validate(
        MediaSourceKind.smb,
        r'\\192.168.1.2\Anime',
      );
      expect(smbUnc.isValid, isTrue);
      expect(smbUnc.normalizedLocation, 'smb://192.168.1.2/Anime');

      expect(
        SourceLocationValidator.validate(
          MediaSourceKind.smb,
          'smb://192.168.1.2:4450/Anime',
        ).isValid,
        isFalse,
      );
      expect(
        SourceLocationValidator.validate(
          MediaSourceKind.smb,
          'smb://192.168.1.2/../etc',
        ).isValid,
        isFalse,
      );
      expect(
        SourceLocationValidator.validate(
          MediaSourceKind.smb,
          'smb://192.168.1.2/',
        ).isValid,
        isFalse,
      );
    });
  });

  group('SourceAccessErrorClassifier 与 SourceCredentialStore', () {
    test('精确归类常见连接故障并解析 Retry-After 头', () {
      expect(
        SourceAccessErrorClassifier.classify(
          const HttpException('HTTP 401'),
          MediaSourceKind.webdav,
        ).kind,
        SourceAccessProblemKind.authentication,
      );
      expect(
        SourceAccessErrorClassifier.classify(
          const PathAccessException('x', OSError('denied')),
          MediaSourceKind.local,
        ).kind,
        SourceAccessProblemKind.permission,
      );
      expect(
        SourceAccessErrorClassifier.classify(
          const PathNotFoundException('x', OSError('missing')),
          MediaSourceKind.local,
        ).kind,
        SourceAccessProblemKind.path,
      );
      expect(
        SourceAccessErrorClassifier.classify(
          const SocketException('Connection refused'),
          MediaSourceKind.smb,
        ).kind,
        SourceAccessProblemKind.network,
      );

      final now = DateTime.utc(2026, 11, 24, 10, 0, 0);
      expect(
        SourceAccessErrorClassifier.parseRetryAfterHeader(
          const <String, String>{'Retry-After': '15'},
          now: now,
        ),
        const Duration(seconds: 15),
      );
      expect(
        SourceAccessErrorClassifier.parseRetryAfterHeader(
          const <String, String>{'retry-after': 'Tue, 24 Nov 2026 10:00:20 GMT'},
          now: now,
        ),
        const Duration(seconds: 20),
      );
    });

    test('SourceCredentialStore 基于 SecureStoragePort 安全读写与删除凭据', () async {
      final storage = InMemorySecureStorage();
      final store = SourceCredentialStore(storage: storage);

      expect(await store.readPassword('src_1'), isNull);
      await store.savePassword('src_1', 's3cr3t');
      expect(await store.readPassword('src_1'), 's3cr3t');
      await store.savePassword('src_1', '');
      expect(await store.readPassword('src_1'), isNull);
      await store.savePassword('src_2', 'pwd2');
      await store.deletePassword('src_2');
      expect(await store.readPassword('src_2'), isNull);
    });
  });

  group('LocalSourceGateway 本地只读网关', () {
    late Directory tempRoot;
    late LocalSourceGateway gateway;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('konata_local_gw_');
      Directory(p.join(tempRoot.path, 'Season 1')).createSync(recursive: true);
      File(p.join(tempRoot.path, 'Season 1', 'ep01.mkv')).writeAsBytesSync(
        <int>[1, 2, 3, 4, 5, 6, 7, 8],
      );
      File(p.join(tempRoot.path, 'tvshow.nfo')).writeAsStringSync('<tvshow/>');
      gateway = LocalSourceGateway(rootPath: tempRoot.path);
    });

    tearDown(() async {
      await gateway.close();
      if (tempRoot.existsSync()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('列目录、防穿越、读取小文本、元数据探测与字节区间流读取均正常', () async {
      expect(await gateway.testConnection(), isNull);
      expect(() => gateway.resolveAbsolutePath('../secret'), throwsArgumentError);

      final rootEntries = await gateway.listDirectory('');
      expect(rootEntries, hasLength(2));
      expect(rootEntries.first.isDirectory, isTrue);
      expect(rootEntries.first.name, 'Season 1');
      expect(rootEntries.last.name, 'tvshow.nfo');

      final nfo = await gateway.readTextFile('tvshow.nfo', maxBytes: 5);
      expect(nfo, '<tvsh');

      final meta = await gateway.probeFileMetadata('Season 1/ep01.mkv');
      expect(meta.length, 8);
      expect(meta.validator, startsWith('mtime:'));

      final slice = await (await gateway.openByteRange(
        'Season 1/ep01.mkv',
        start: 2,
        endInclusive: 5,
      )).expand((c) => c).toList();
      expect(slice, <int>[3, 4, 5, 6]);
    });
  });

  group('WorkDetailWarmupService 与 SubtitleDirectoryIndex', () {
    test('预热同级文件与最多 4 个附属子目录，标记简体完备性并支持代数取消', () async {
      var now = DateTime.utc(2026, 11, 24, 15, 0, 0);
      final index = SubtitleDirectoryIndex(
        ttl: const Duration(minutes: 5),
        maxEntries: 2,
        clock: () => now,
      );
      final gw = _FakeWarmupGateway(<String, List<RemoteEntry>>{
        'Show': <RemoteEntry>[
          const RemoteEntry(
            name: '01.mkv',
            relativePath: 'Show/01.mkv',
            isDirectory: false,
            size: 100,
            etag: '"v1"',
          ),
          const RemoteEntry(
            name: 'Subs',
            relativePath: 'Show/Subs',
            isDirectory: true,
          ),
          const RemoteEntry(
            name: 'Subtitles',
            relativePath: 'Show/Subtitles',
            isDirectory: true,
          ),
          const RemoteEntry(
            name: 'Subs2',
            relativePath: 'Show/Subs2',
            isDirectory: true,
          ),
          const RemoteEntry(
            name: 'Audio',
            relativePath: 'Show/Audio',
            isDirectory: true,
          ),
          const RemoteEntry(
            name: 'SP Audio',
            relativePath: 'Show/SP Audio',
            isDirectory: true,
          ),
        ],
        'Show/Subs': const <RemoteEntry>[
          RemoteEntry(
            name: '01.jpn.ass',
            relativePath: 'Show/Subs/01.jpn.ass',
            isDirectory: false,
          ),
        ],
      });
      final factory = _FakeGatewayFactory(gw);
      final SubtitleDirectoryWarmupPort warmup = WorkDetailWarmupService(
        gatewayFactory: factory,
        directoryIndex: index,
      );

      final source = MediaSourceView(
        id: SourceId('src_webdav'),
        kind: MediaSourceKind.webdav,
        label: 'NAS',
        location: 'https://nas.local/dav/',
      );

      final snap = await warmup.warmupDirectory(
        source: source,
        dirRelativePath: 'Show',
      );
      expect(snap, isNotNull);
      expect(snap!.scannedSubdirCount, 4);
      expect(snap.hasUnscannedSubdirs, isTrue);
      expect(snap.unscannedSubdirs, <String>['Show/SP Audio']);
      expect(snap.incompleteForSimplified, isTrue);
      expect(snap.validatorsByPath['Show/01.mkv'], '"v1"');
      expect(gw.closed, isTrue);

      // 有效期内的第二次查询直接命中内存表。
      final hit = warmup.lookupDirectorySnapshot('src_webdav', 'Show');
      expect(hit, same(snap));
      await warmup.warmupDirectory(source: source, dirRelativePath: 'Show');
      expect(factory.createCount, 1);

      // 代数切换后过时预期代数的预热任务立即放弃。
      warmup.cancelPending();
      final stale = await warmup.warmupDirectory(
        source: source,
        dirRelativePath: 'Other',
        expectedGeneration: 0,
      );
      expect(stale, isNull);

      // 超过有效期自动失效。
      now = now.add(const Duration(minutes: 6));
      expect(warmup.lookupDirectorySnapshot('src_webdav', 'Show'), isNull);
    });
  });

  group('AdaptiveScanController 与显式编号免读 NFO', () {
    test('AdaptiveScanController 冷热切换、限流乘性降窗与 DirectoryScanner 跳过 NFO', () async {
      final ctrl = AdaptiveScanController(DirectoryScanProfile.webdav);
      expect(ctrl.currentConcurrency, 2);
      for (var i = 0; i < 12; i++) {
        ctrl.recordSuccess(const Duration(milliseconds: 10));
      }
      expect(ctrl.currentConcurrency, 3);
      ctrl.recordRateLimit(retryAfter: const Duration(seconds: 5));
      expect(ctrl.currentConcurrency, 1);
      expect(ctrl.rateLimitHits, 1);

      var readNfoCalled = false;
      final gw = _NfoCheckGateway(
        onReadText: (_) => readNfoCalled = true,
      );
      final result = await const DirectoryScanner().scan(gw);
      expect(readNfoCalled, isFalse);
      expect(result.files.single.relativePath, 'Anime {tmdb-12345}/01.mkv');
    });
  });
}

class _NfoCheckGateway implements MediaSourceGateway {
  _NfoCheckGateway({required this.onReadText});

  final void Function(String path) onReadText;

  @override
  Future<List<RemoteEntry>> listDirectory(String relativePath) async {
    if (relativePath.isEmpty) {
      return const <RemoteEntry>[
        RemoteEntry(
          name: 'Anime {tmdb-12345}',
          relativePath: 'Anime {tmdb-12345}',
          isDirectory: true,
        ),
      ];
    }
    return const <RemoteEntry>[
      RemoteEntry(
        name: 'tvshow.nfo',
        relativePath: 'Anime {tmdb-12345}/tvshow.nfo',
        isDirectory: false,
      ),
      RemoteEntry(
        name: '01.mkv',
        relativePath: 'Anime {tmdb-12345}/01.mkv',
        isDirectory: false,
      ),
    ];
  }

  @override
  Future<String?> readTextFile(
    String relativePath, {
    int maxBytes = 262144,
  }) async {
    onReadText(relativePath);
    return null;
  }

  @override
  Future<String?> testConnection() async => null;

  @override
  Future<void> close() async {}
}
