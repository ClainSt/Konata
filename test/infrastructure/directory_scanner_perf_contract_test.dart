import 'dart:io';

import 'package:konata/domain/repositories/file_system_gateway.dart';
import 'package:konata/infrastructure/sources/directory_scanner.dart';
import 'package:konata/infrastructure/sources/subtitle_matcher.dart';
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

RemoteEntry _dir(String path) => RemoteEntry(
  name: path.split('/').last,
  relativePath: path,
  isDirectory: true,
);

void main() {
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
