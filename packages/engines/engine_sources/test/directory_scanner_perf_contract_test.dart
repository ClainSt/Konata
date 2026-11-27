import 'dart:io';

import 'package:engine_sources/engine_sources.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';
import 'package:test/test.dart';

/// 内存目录树网关；可指定某目录前若干次列举抛出的异常。
class _TreeGateway implements MediaSourceGateway {
  _TreeGateway(this._tree, {this.failures = const <String, List<Object>>{}});

  final Map<String, List<RemoteEntry>> _tree;
  final Map<String, List<Object>> failures;
  final Map<String, int> calls = <String, int>{};

  @override
  Future<List<RemoteEntry>> listDirectory(String relativePath) async {
    final n = calls[relativePath] = (calls[relativePath] ?? 0) + 1;
    final planned = failures[relativePath] ?? const <Object>[];
    if (n <= planned.length) throw planned[n - 1];
    return _tree[relativePath] ?? const <RemoteEntry>[];
  }

  @override
  Future<String?> readTextFile(
    String relativePath, {
    int maxBytes = 262144,
  }) async => null;

  @override
  Future<String?> testConnection() async => null;

  @override
  Future<void> close() async {}
}

class _CloudTreeGateway extends _TreeGateway implements CloudDriveGateway {
  _CloudTreeGateway(super.tree);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

RemoteEntry _file(String path, {String? remoteFileId}) => RemoteEntry(
  name: path.split('/').last,
  relativePath: path,
  isDirectory: false,
  size: 1,
  remoteFileId: remoteFileId,
);

RemoteEntry _dir(String path, {String? etag, DateTime? modifiedAt}) =>
    RemoteEntry(
      name: path.split('/').last,
      relativePath: path,
      isDirectory: true,
      etag: etag,
      modifiedAt: modifiedAt,
    );

void main() {
  test('云盘深度优先扫描保留所有文件及稳定路径顺序', () async {
    final tree = <String, List<RemoteEntry>>{
      '': [_dir('a'), _dir('b')],
      'a': [_dir('a/Scans'), _file('a/01.mkv', remoteFileId: 'one')],
      'b': [_dir('b/Scans'), _file('b/01.mkv', remoteFileId: 'two')],
      'a/Scans': [_file('a/Scans/01.jpg')],
      'b/Scans': [_file('b/Scans/01.jpg')],
    };
    for (final sourceId in ['', 'cloud']) {
      final gateway = _CloudTreeGateway(tree);
      final result = await const DirectoryScanner().scan(
        gateway,
        sourceId: sourceId,
      );
      expect(gateway.calls.keys, ['', 'b', 'b/Scans', 'a', 'a/Scans']);
      expect(result.files.map((e) => e.relativePath), [
        'a/01.mkv',
        'a/Scans/01.jpg',
        'b/01.mkv',
        'b/Scans/01.jpg',
      ]);
      expect(result.files.first.remoteFileId, 'one');
      expect(result.scannedDirectories, 5);
    }
  });

  group('远程目录扫描快照', () {
    const scanner = DirectoryScanner();
    final now = DateTime.utc(2026, 11, 23);

    test('稳定文件标识在扫描、快照序列化和增量复用中保持不变', () async {
      const id = '9876543210987654321';
      final tree = <String, List<RemoteEntry>>{
        '': [_dir('番剧', etag: '"版本一"')],
        '番剧': [
          _file('番剧/Show - 01.mkv', remoteFileId: id),
          _file('番剧/Show - 02.mkv'),
        ],
      };
      final initial = await scanner.scan(
        _TreeGateway(tree),
        sourceId: '云盘',
        clockNow: now,
      );
      expect(initial.files.first.remoteFileId, id);
      expect(initial.files.last.remoteFileId, isNull);
      final decoded = DirectoryScanSnapshot.fromJson(
        initial.snapshot!.toJson(),
      )!;
      expect(decoded.nodes['番剧']!.fileEntries.first.remoteFileId, id);
      final gateway = _TreeGateway(tree);
      final incremental = await scanner.scan(
        gateway,
        sourceId: '云盘',
        previousSnapshot: decoded,
        clockNow: now.add(const Duration(hours: 1)),
      );
      expect(gateway.calls, isNot(contains('番剧')));
      expect(incremental.files.first.remoteFileId, id);
      expect(incremental.files.last.remoteFileId, isNull);
    });

    test('旧快照或非字符串远端标识保持未知，不推测文件身份', () {
      for (final raw in [
        <String, Object?>{'n': '01.mkv', 'p': '01.mkv'},
        <String, Object?>{'n': '01.mkv', 'p': '01.mkv', 'i': 123},
        <String, Object?>{'n': '01.mkv', 'p': '01.mkv', 'i': ''},
      ]) {
        final node = DirectoryScanSnapshotNode.fromJson({
          'relativePath': '',
          'fileEntries': [raw],
        });
        expect(node.fileEntries.single.remoteFileId, isNull);
      }
    });

    test('普通父目录不冒泡时仍能找到新增分集并识别删除', () async {
      final source = <String, List<RemoteEntry>>{
        '': <RemoteEntry>[_dir('番剧', etag: '"根"')],
        '番剧': <RemoteEntry>[
          _dir('番剧/S01', etag: '"初版"'),
          _dir('番剧/Scans', modifiedAt: now),
          _dir('番剧/无版本', modifiedAt: now),
        ],
        '番剧/S01': <RemoteEntry>[_file('番剧/S01/Show - 01.mkv')],
        '番剧/Scans': <RemoteEntry>[_file('番剧/Scans/封面.jpg')],
        '番剧/无版本': <RemoteEntry>[_file('番剧/无版本/Show - 03.mkv')],
      };
      final initial = await scanner.scan(
        _TreeGateway(source),
        sourceId: '库',
        clockNow: now,
      );

      source['番剧']![0] = _dir('番剧/S01', etag: '"新增"');
      source['番剧/S01'] = <RemoteEntry>[_file('番剧/S01/Show - 02.mkv')];
      final gateway = _TreeGateway(source);
      final incremental = await scanner.scan(
        gateway,
        sourceId: '库',
        previousSnapshot: initial.snapshot,
        clockNow: now.add(const Duration(days: 1)),
      );

      expect(
        gateway.calls.keys,
        unorderedEquals(<String>['', '番剧', '番剧/S01', '番剧/无版本']),
      );
      expect(incremental.reusedDirectories, 1);
      expect(
        incremental.files.map((entry) => entry.relativePath),
        unorderedEquals(<String>[
          '番剧/S01/Show - 02.mkv',
          '番剧/Scans/封面.jpg',
          '番剧/无版本/Show - 03.mkv',
        ]),
      );

      final unchanged = _TreeGateway(source);
      final second = await scanner.scan(
        unchanged,
        sourceId: '库',
        previousSnapshot: incremental.snapshot,
        clockNow: now.add(const Duration(days: 6)),
      );
      expect(unchanged.calls, isNot(contains('番剧/S01')));
      expect(second.snapshot!.lastFullScanAt, now);

      final expired = _TreeGateway(source);
      await scanner.scan(
        expired,
        sourceId: '库',
        previousSnapshot: second.snapshot,
        clockNow: now.add(const Duration(days: 8)),
      );
      expect(expired.calls.keys, unorderedEquals(source.keys));

      final deep = _TreeGateway(source);
      await scanner.scan(
        deep,
        sourceId: '库',
        previousSnapshot: second.snapshot,
        enableSnapshotReuse: false,
        enableCheckpointResume: false,
        clockNow: now,
      );
      expect(deep.calls.keys, unorderedEquals(source.keys));
    });

    test('断网后从磁盘恢复，重新列举出错分支并恢复字幕配对', () async {
      final temp = await Directory.systemTemp.createTemp('konata_scan_');
      addTearDown(() => temp.delete(recursive: true));
      final storageRoot = PortableStorageRootService(
        overrideRootPath: temp.path,
      );
      final store = DirectoryScanSnapshotStore(storageRoot: storageRoot);
      final source = MediaSourceView(
        id: SourceId('媒体源'),
        kind: MediaSourceKind.webdav,
        label: '番剧',
        location: 'https://example.invalid/media/',
        username: '账号',
      );
      final key = DirectoryScanSnapshotStore.keyFor(source, const <String>['']);
      expect(
        DirectoryScanSnapshotStore.keyFor(
          MediaSourceView(
            id: source.id,
            kind: source.kind,
            label: source.label,
            location: source.location,
            username: '访客',
          ),
          const <String>[''],
        ),
        isNot(key),
      );
      expect(
        DirectoryScanSnapshotStore.keyFor(source, const <String>['第一部']),
        isNot(key),
      );

      final tree = <String, List<RemoteEntry>>{
        '': <RemoteEntry>[_dir('第一部'), _dir('第二部')],
        '第一部': <RemoteEntry>[
          _file('第一部/Show - 01.mkv'),
          _file('第一部/Show - 01.chs.ass'),
        ],
        '第二部': <RemoteEntry>[_file('第二部/Other - 01.mkv')],
      };
      final interrupted = _TreeGateway(
        tree,
        failures: <String, List<Object>>{
          '第二部': List<Object>.filled(3, const SocketException('连接已断开')),
        },
      );
      await expectLater(
        scanner.scan(
          interrupted,
          sourceId: key,
          profileOverride: DirectoryScanProfile.smb,
          onCheckpoint: store.save,
          clockNow: now,
        ),
        throwsA(isA<SocketException>()),
      );

      final reopened = DirectoryScanSnapshotStore(storageRoot: storageRoot);
      final checkpoint = await reopened.load(key);
      expect(checkpoint, isA<DirectoryScanSnapshot>());
      expect(checkpoint!.isComplete, isFalse);
      expect(checkpoint.pendingQueue, <String>['第二部']);

      final resumed = _TreeGateway(tree);
      final result = await scanner.scan(
        resumed,
        sourceId: key,
        previousSnapshot: checkpoint,
        onCheckpoint: reopened.save,
        clockNow: now.add(const Duration(hours: 1)),
      );
      expect(resumed.calls, <String, int>{'第二部': 1});
      expect(result.resumedFromCheckpoint, isTrue);
      expect(result.files.first.externalSubtitles, <String>[
        '第一部/Show - 01.chs.ass',
      ]);
      expect(result.files, hasLength(2));
      expect((await reopened.load(key))!.isComplete, isTrue);
    });
  });

  group('外挂字幕预处理匹配', () {
    test('预处理后的匹配结果与逐视频完整匹配逐条一致', () {
      const dir = '动画/孤独摇滚';
      final subs = <String>[
        '$dir/[VCB-Studio] Bocchi the Rock! [01][Ma10p_1080p].chs.ass',
        '$dir/[VCB-Studio] Bocchi the Rock! [01][Ma10p_1080p].cht.ass',
        '$dir/Subs/[Nekomoe] Bocchi the Rock! - 02 [SC].ass',
        '$dir/[Nekomoe] Bocchi the Rock! - 03.tc.srt',
        '$dir/SPs/[VCB-Studio] Bocchi the Rock! [NCOP].sc.ass',
        '动画/其他作品/Other - 01.ass',
        '$dir/readme.txt',
      ];
      final videos = <String>[
        '$dir/[VCB-Studio] Bocchi the Rock! [01][Ma10p_1080p].mkv',
        '$dir/[VCB-Studio] Bocchi the Rock! [02][Ma10p_1080p].mkv',
        '$dir/[VCB-Studio] Bocchi the Rock! [03][Ma10p_1080p].mkv',
        '$dir/[VCB-Studio] Bocchi the Rock! [NCOP][Ma10p_1080p].mkv',
      ];
      final prepared = SubtitleMatcher.prepare(subs);
      for (final video in videos) {
        final legacy = SubtitleMatcher.matchForVideo(
          videoRelativePath: video,
          allSubtitleRelativePaths: subs,
        );
        final fast = SubtitleMatcher.matchPrepared(
          videoRelativePath: video,
          subtitles: prepared,
        );
        expect(fast.subtitlePaths, legacy.subtitlePaths, reason: video);
        expect(fast.subtitleGroupHint, legacy.subtitleGroupHint, reason: video);
      }
      final first = SubtitleMatcher.matchPrepared(
        videoRelativePath: videos.first,
        subtitles: prepared,
      );
      expect(first.subtitlePaths.first, endsWith('.chs.ass'));
      expect(
        SubtitleMatcher.matchPrepared(
          videoRelativePath: videos[1],
          subtitles: prepared,
        ).subtitlePaths,
        <String>['$dir/Subs/[Nekomoe] Bocchi the Rock! - 02 [SC].ass'],
      );
    });

    test('支持注入精细集号解析回调以覆盖复杂命名场景', () {
      final matched = SubtitleMatcher.matchForVideo(
        videoRelativePath: 'Show/SpecialNaming_Alpha.mkv',
        allSubtitleRelativePaths: const <String>[
          'Show/Subs/Track_Custom_chs.ass',
        ],
        episodeParser: (fileName, {relativePath}) {
          if (fileName.contains('Alpha') || fileName.contains('Custom')) {
            return const SubtitleEpisodeProbe(
              category: EpisodeCategory.main,
              season: 2,
              episode: 9,
            );
          }
          return const SubtitleEpisodeProbe();
        },
      );
      expect(matched.subtitlePaths, <String>['Show/Subs/Track_Custom_chs.ass']);
    });
  });

  group('目录扫描器', () {
    test('大目录收尾汇总期间主动让出事件循环，且字幕挂载正确', () async {
      const dir = '动画/大合集';
      final entries = <RemoteEntry>[
        for (var i = 1; i <= 400; i++) ...<RemoteEntry>[
          _file('$dir/Show - ${i.toString().padLeft(3, '0')}.mkv'),
          _file('$dir/Show - ${i.toString().padLeft(3, '0')}.chs.ass'),
          _file('$dir/Show - ${i.toString().padLeft(3, '0')}.cht.ass'),
        ],
      ];
      final gateway = _TreeGateway(<String, List<RemoteEntry>>{
        '': <RemoteEntry>[_dir('动画')],
        '动画': <RemoteEntry>[_dir(dir)],
        dir: entries,
      });
      var ticks = 0;
      var scanning = true;
      Future<void> pump() async {
        while (scanning) {
          await Future<void>.delayed(Duration.zero);
          ticks++;
        }
      }

      final pumping = pump();
      final result = await const DirectoryScanner().scan(gateway);
      scanning = false;
      await pumping;

      final videos = result.files.where((f) => f.fileName.endsWith('.mkv'));
      expect(videos, hasLength(400));
      for (final v in videos) {
        expect(v.externalSubtitles, hasLength(2), reason: v.relativePath);
        expect(v.externalSubtitles.first, endsWith('.chs.ass'));
      }
      expect(ticks, greaterThan(0));
    });

    test('列目录遇瞬时 5xx 时重试成功，扫描照常完成', () async {
      final gateway = _TreeGateway(
        <String, List<RemoteEntry>>{
          '': <RemoteEntry>[_dir('作品')],
          '作品': <RemoteEntry>[_file('作品/作品 - 01.mkv')],
        },
        failures: const <String, List<Object>>{
          '作品': <Object>[HttpException('WebDAV PROPFIND 失败: HTTP 500')],
        },
      );

      final result = await const DirectoryScanner().scan(gateway);

      expect(result.files.map((f) => f.relativePath), <String>[
        '作品/作品 - 01.mkv',
      ]);
      expect(gateway.calls['作品'], 2);
    });

    test('列目录遇认证失败时不重试，立即抛出', () async {
      final gateway = _TreeGateway(
        <String, List<RemoteEntry>>{
          '': <RemoteEntry>[_dir('作品')],
        },
        failures: const <String, List<Object>>{
          '作品': <Object>[HttpException('WebDAV PROPFIND 失败: HTTP 401')],
        },
      );

      await expectLater(
        const DirectoryScanner().scan(gateway),
        throwsA(isA<HttpException>()),
      );
      expect(gateway.calls['作品'], 1);
    });

    test('瞬时故障重试耗尽后仍抛出，整次扫描失败', () async {
      const boom = HttpException('WebDAV PROPFIND 失败: HTTP 503');
      final gateway = _TreeGateway(
        <String, List<RemoteEntry>>{
          '': <RemoteEntry>[_dir('作品')],
        },
        failures: const <String, List<Object>>{
          '作品': <Object>[boom, boom, boom],
        },
      );

      await expectLater(
        const DirectoryScanner().scan(gateway),
        throwsA(isA<HttpException>()),
      );
      expect(gateway.calls['作品'], 3);
    });
  });
}
