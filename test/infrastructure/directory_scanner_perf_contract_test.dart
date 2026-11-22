import 'dart:io';

import 'package:konata/domain/models/media_source.dart';
import 'package:konata/domain/repositories/file_system_gateway.dart';
import 'package:konata/infrastructure/sources/directory_scan_snapshot.dart';
import 'package:konata/infrastructure/sources/directory_scan_snapshot_store.dart';
import 'package:konata/infrastructure/sources/directory_scanner.dart';
import 'package:konata/infrastructure/sources/scan_throttle_policy.dart';
import 'package:konata/infrastructure/sources/subtitle_matcher.dart';
import 'package:konata/infrastructure/storage/storage_root_provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// 内存目录树网关；可指定某目录前若干次列举抛出的异常。
class _TreeGateway implements MediaSourceGateway {
  _TreeGateway(this._tree, {this.failures = const {}});

  final Map<String, List<RemoteEntry>> _tree;
  final Map<String, List<Object>> failures;
  final Map<String, int> calls = {};

  @override
  Future<List<RemoteEntry>> listDirectory(String relativePath) async {
    final n = calls[relativePath] = (calls[relativePath] ?? 0) + 1;
    final planned = failures[relativePath] ?? const [];
    if (n <= planned.length) throw planned[n - 1];
    return _tree[relativePath] ?? const [];
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

RemoteEntry _file(String path) => RemoteEntry(
  name: path.split('/').last,
  relativePath: path,
  isDirectory: false,
  size: 1,
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
  group('远程目录扫描快照', () {
    const scanner = DirectoryScanner();
    final now = DateTime.utc(2026, 11, 23);

    test('普通父目录不冒泡时仍能找到新增分集并识别删除', () async {
      final source = {
        '': [_dir('番剧', etag: '"根"')],
        '番剧': [
          _dir('番剧/S01', etag: '"初版"'),
          _dir('番剧/Scans', modifiedAt: now),
          _dir('番剧/无版本', modifiedAt: now),
        ],
        '番剧/S01': [_file('番剧/S01/Show - 01.mkv')],
        '番剧/Scans': [_file('番剧/Scans/封面.jpg')],
        '番剧/无版本': [_file('番剧/无版本/Show - 03.mkv')],
      };
      final initial = await scanner.scan(
        _TreeGateway(source),
        sourceId: '库',
        clockNow: now,
      );

      source['番剧']![0] = _dir('番剧/S01', etag: '"新增"');
      source['番剧/S01'] = [_file('番剧/S01/Show - 02.mkv')];
      final gateway = _TreeGateway(source);
      final incremental = await scanner.scan(
        gateway,
        sourceId: '库',
        previousSnapshot: initial.snapshot,
        clockNow: now.add(const Duration(days: 1)),
      );

      expect(
        gateway.calls.keys,
        unorderedEquals(['', '番剧', '番剧/S01', '番剧/无版本']),
      );
      expect(incremental.reusedDirectories, 1);
      expect(
        incremental.files.map((entry) => entry.relativePath),
        unorderedEquals([
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
      final storageRoot = StorageRootService(overrideRoot: temp);
      final store = DirectoryScanSnapshotStore(storageRoot: storageRoot);
      const source = MediaSource(
        id: '媒体源',
        kind: MediaSourceKind.webdav,
        label: '番剧',
        location: 'https://example.invalid/media/',
        username: '账号',
      );
      final key = DirectoryScanSnapshotStore.keyFor(source, const ['']);
      expect(
        DirectoryScanSnapshotStore.keyFor(source.copyWith(username: '访客'), [
          '',
        ]),
        isNot(key),
      );
      expect(DirectoryScanSnapshotStore.keyFor(source, ['第一部']), isNot(key));

      final tree = {
        '': [_dir('第一部'), _dir('第二部')],
        '第一部': [_file('第一部/Show - 01.mkv'), _file('第一部/Show - 01.chs.ass')],
        '第二部': [_file('第二部/Other - 01.mkv')],
      };
      final interrupted = _TreeGateway(
        tree,
        failures: {
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
      expect(checkpoint.pendingQueue, ['第二部']);

      final resumed = _TreeGateway(tree);
      final result = await scanner.scan(
        resumed,
        sourceId: key,
        previousSnapshot: checkpoint,
        onCheckpoint: reopened.save,
        clockNow: now.add(const Duration(hours: 1)),
      );
      expect(resumed.calls, {'第二部': 1});
      expect(result.resumedFromCheckpoint, isTrue);
      expect(result.files.first.externalSubtitles, ['第一部/Show - 01.chs.ass']);
      expect(result.files, hasLength(2));
      expect((await reopened.load(key))!.isComplete, isTrue);
    });
  });

  group('外挂字幕预处理匹配', () {
    test('预处理后的匹配结果与逐视频完整匹配逐条一致', () {
      const dir = '动画/孤独摇滚';
      final subs = [
        '$dir/[VCB-Studio] Bocchi the Rock! [01][Ma10p_1080p].chs.ass',
        '$dir/[VCB-Studio] Bocchi the Rock! [01][Ma10p_1080p].cht.ass',
        '$dir/Subs/[Nekomoe] Bocchi the Rock! - 02 [SC].ass',
        '$dir/[Nekomoe] Bocchi the Rock! - 03.tc.srt',
        '$dir/SPs/[VCB-Studio] Bocchi the Rock! [NCOP].sc.ass',
        '动画/其他作品/Other - 01.ass',
        '$dir/readme.txt',
      ];
      final videos = [
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
        ['$dir/Subs/[Nekomoe] Bocchi the Rock! - 02 [SC].ass'],
      );
    });
  });

  group('目录扫描器', () {
    test('大目录收尾汇总期间主动让出事件循环，且字幕挂载正确', () async {
      const dir = '动画/大合集';
      final entries = <RemoteEntry>[
        for (var i = 1; i <= 400; i++) ...[
          _file('$dir/Show - ${i.toString().padLeft(3, '0')}.mkv'),
          _file('$dir/Show - ${i.toString().padLeft(3, '0')}.chs.ass'),
          _file('$dir/Show - ${i.toString().padLeft(3, '0')}.cht.ass'),
        ],
      ];
      final gateway = _TreeGateway({
        '': [_dir('动画')],
        '动画': [_dir(dir)],
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
        {
          '': [_dir('作品')],
          '作品': [_file('作品/作品 - 01.mkv')],
        },
        failures: {
          '作品': [const HttpException('WebDAV PROPFIND 失败: HTTP 500')],
        },
      );

      final result = await const DirectoryScanner().scan(gateway);

      expect(result.files.map((f) => f.relativePath), ['作品/作品 - 01.mkv']);
      expect(gateway.calls['作品'], 2);
    });

    test('列目录遇认证失败时不重试，立即抛出', () async {
      final gateway = _TreeGateway(
        {
          '': [_dir('作品')],
        },
        failures: {
          '作品': [const HttpException('WebDAV PROPFIND 失败: HTTP 401')],
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
        {
          '': [_dir('作品')],
        },
        failures: {
          '作品': [boom, boom, boom],
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
