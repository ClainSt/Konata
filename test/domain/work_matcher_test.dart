import 'package:flutter_test/flutter_test.dart';
import 'package:konata/domain/matching/directory_grouper.dart';
import 'package:konata/domain/matching/work_matcher.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/models/tmdb_models.dart';
import 'package:konata/domain/models/work.dart';

void main() {
  group('WorkMatcher & DirectoryGrouper', () {
    test('繁简转换与假名归一化准确命中作品并自动绑定', () {
      const folder = GroupedWorkFolder(
        folderRelativePath: '葬送的芙莉蓮 (2023)',
        folderName: '[VCB-Studio] 葬送的芙莉蓮 [1080p]',
        cleanTitle: '葬送的芙莉蓮',
        year: 2023,
        variants: [],
      );

      const candidates = [
        TmdbWorkDetail(
          tmdbId: 209867,
          mediaType: TmdbMediaType.tv,
          title: '葬送的芙莉莲',
          originalTitle: '葬送のフリーレン',
          year: 2023,
          aliases: ['葬送的芙莉莲'],
        ),
        TmdbWorkDetail(
          tmdbId: 999999,
          mediaType: TmdbMediaType.tv,
          title: '无关动画',
          year: 2020,
        ),
      ];

      final decision = WorkMatcher.evaluate(folder, candidates);
      expect(decision.level, MatchLevel.autoBind);
      expect(decision.best?.detail.tmdbId, 209867);
    });

    test('同系列不同年份候选通过年份惩罚拉开分差', () {
      const folder = GroupedWorkFolder(
        folderRelativePath: 'Spice and Wolf (2024)',
        folderName: 'Spice and Wolf (2024)',
        cleanTitle: 'Spice and Wolf',
        year: 2024,
        variants: [],
      );

      const candidates = [
        TmdbWorkDetail(
          tmdbId: 220001,
          mediaType: TmdbMediaType.tv,
          title: '狼与香辛料',
          originalTitle: '狼と香辛料',
          year: 2008,
          aliases: ['Spice and Wolf'],
        ),
        TmdbWorkDetail(
          tmdbId: 220002,
          mediaType: TmdbMediaType.tv,
          title: '狼与香辛料 行商邂逅贤狼',
          originalTitle: '狼と香辛料 MERCHANT MEETS THE WISE WOLF',
          year: 2024,
          aliases: ['Spice and Wolf'],
        ),
      ];

      final decision = WorkMatcher.evaluate(folder, candidates);
      expect(decision.best?.detail.tmdbId, 220002);
      expect(
        decision.topCandidates.first.score,
        greaterThan(decision.topCandidates.last.score),
      );
    });

    test('DirectoryGrouper 正确提取文件夹 [tmdbid=xxx] 与 NFO 显式 ID', () {
      final groups = DirectoryGrouper.groupFiles(
        sourceId: 'src-1',
        files: const [
          ScannedFileInput(
            relativePath:
                'Frieren [tmdbid=209867]/Season 1/[VCB-Studio] Frieren [01].mkv',
            fileName: '[VCB-Studio] Frieren [01].mkv',
            fileSize: 1024,
            assetKind: AssetKind.video,
          ),
          ScannedFileInput(
            relativePath: 'Demo Show/ep01.mkv',
            fileName: 'ep01.mkv',
            fileSize: 1024,
            assetKind: AssetKind.video,
          ),
        ],
        nfoByFolder: const {
          'Demo Show': '<tvshow><tmdbid>123456</tmdbid></tvshow>',
        },
      );

      expect(groups, hasLength(2));
      final frieren = groups.firstWhere((g) => g.explicitTmdbId == 209867);
      expect(frieren.variants, hasLength(1));
      final demo = groups.firstWhere((g) => g.explicitTmdbId == 123456);
      expect(demo.explicitMediaType, TmdbMediaType.tv);
    });
  });
}
