import 'package:konata/domain/matching/directory_grouper.dart';
import 'package:konata/domain/matching/work_matcher.dart';
import 'package:konata/domain/models/episode.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/models/tmdb_models.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/domain/parsing/bdrip_parser.dart';
import 'package:konata/domain/parsing/season_number_parser.dart';
import 'package:konata/domain/parsing/title_normalizer.dart';
import 'package:konata/presentation/library/review_reason_labels.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Phase 4 刮削解析、季号折叠、半集特典、序列保护与 WorkMatcher 回归测试', () {
    test('多季折叠路径识别 Season 2 / S02 / 2nd Season / 第二季 / II，并排除 Mk-II', () {
      const seasonTwoCases = [
        'Fate Stay Night/Season 2/01.mkv',
        'Fate Stay Night/S02/01.mkv',
        'ReZero/2nd Season/01.mkv',
        'Frieren/第二季/01.mkv',
        'Mob Psycho 100/第2期/01.mkv',
        'Code Geass R2/Show II/01.mkv',
      ];

      for (final rel in seasonTwoCases) {
        final groups = DirectoryGrouper.groupFiles(
          sourceId: 's1',
          files: [
            ScannedFileInput(
              relativePath: rel,
              fileName: '01.mkv',
              fileSize: 1024,
              assetKind: AssetKind.video,
            ),
          ],
        );
        expect(groups.length, 1, reason: '路径 $rel 应折叠为 1 个作品组');
        expect(
          groups.first.seasonHint,
          2,
          reason: '路径 $rel 折叠后必须保留 seasonHint=2，不能落入第 1 季',
        );
      }

      // 机体型号 Mk-II 绝不可误判为第 2 季
      expect(
        SeasonNumberParser.extractSeasonFromPath(
          'Mobile Suit Zeta Gundam Mk-II/01.mkv',
        ),
        isNull,
      );
      expect(
        SeasonNumberParser.splitSeasonSuffix('Mobile Suit Zeta Gundam Mk-II')
            .seasonNumber,
        isNull,
      );
    });

    test('15 级集号正则、区间集、行首集号、无括号 Scene 规格与 12bit/HDR/DTS-HD/LPCM/FLACx2', () {
      final hashEp = BdripParser.parseFileName('Violet Evergarden #03 [1080p].mkv');
      expect(hashEp.episode, 3);

      final cnEp = BdripParser.parseFileName('葬送的芙莉莲 第三话 1080p.mkv');
      expect(cnEp.episode, 3);

      final leadingEp = BdripParser.parseFileName('01 - Pilot [BD].mkv');
      expect(leadingEp.episode, 1);

      final dotEp = BdripParser.parseFileName('Frieren.05.1080p.WEB-DL.mkv');
      expect(dotEp.episode, 5);

      final endEp = BdripParser.parseFileName('[SweetSub] Show [12 END][1080p].mkv');
      expect(endEp.episode, 12);

      final rangeEp = BdripParser.parseFileName('[Moozzi2] Show [01-04].mkv');
      expect(rangeEp.episode, 1);
      expect(rangeEp.episodeEnd, 4);

      final scene = BdripParser.parseFileName(
        'Show.S02E07.2024.1080p.WEB-DL.H265.12bit.HDR.DTS-HD.mkv',
      );
      expect(scene.season, 2);
      expect(scene.episode, 7);
      expect(scene.resolution, '1080p');
      expect(scene.videoCodec, 'HEVC');
      expect(scene.bitDepth, '12bit');
      expect(scene.dynamicRange, 'HDR');
      expect(scene.audioCodec, 'DTS-HD');

      final lpcm = BdripParser.parseFileName('[VCB-Studio] Show [01][1080p][Ma10p_LPCM].mkv');
      expect(lpcm.audioCodec, 'PCM');

      final flac2 = BdripParser.parseFileName('[VCB-Studio] Show [01][FLACx2][DoVi].mkv');
      expect(flac2.audioCodec, contains('FLAC'));
      expect(flac2.dynamicRange, 'DV');
    });

    test('小数半集 11.5、MenuEX1、[12(OVA01)]、MV、op/ed 目录及连续正片序列防误降级保护', () {
      final halfEp = BdripParser.parseFileName('[VCB-Studio] Show [11.5][1080p].mkv');
      expect(halfEp.category, EpisodeCategory.extra);
      expect(halfEp.fractionalEpisode, '11.5');
      expect(halfEp.episode, 11);

      final menuEx = BdripParser.parseFileName('[ANK-Raws] Show MenuEX1.mkv');
      expect(menuEx.category, EpisodeCategory.extra);
      expect(menuEx.extraType, ExtraKind.menu);

      final bundledOva = BdripParser.parseFileName('[VCB-Studio] K-On [12(OVA01)][1080p].mkv');
      expect(bundledOva.category, EpisodeCategory.extra);
      expect(bundledOva.extraType, ExtraKind.ova);

      final mvExtra = BdripParser.parseFileName('[Snow-Raws] Eve MV.mkv');
      expect(mvExtra.category, EpisodeCategory.extra);
      expect(mvExtra.extraType, ExtraKind.mv);

      final opSubdir = BdripParser.parseFileName(
        '01.mkv',
        relativePath: 'Show/op/01.mkv',
      );
      expect(opSubdir.category, EpisodeCategory.extra);
      expect(opSubdir.extraType, ExtraKind.ncop);

      final edSubdir = BdripParser.parseFileName(
        '01.mkv',
        relativePath: 'Show/ed/01.mkv',
      );
      expect(edSubdir.category, EpisodeCategory.extra);
      expect(edSubdir.extraType, ExtraKind.nced);

      // 连续 1..12 正片中夹杂仅带弱词 "Special" 的第 08 话，保护机制应将其挽回为正片
      final weakMainEp8 = BdripParser.parseFileName('Show 第08话 Special.mkv');
      expect(weakMainEp8.category, EpisodeCategory.extra);
      expect(weakMainEp8.isWeakExtra, isTrue);
      expect(
        shouldRestoreWeakExtraToMain(
          weakMainEp8,
          const {1, 2, 3, 4, 5, 6, 7, 9, 10, 11, 12},
        ),
        isTrue,
      );
    });

    test('WorkMatcher 季级集数/年份打分、2年容差、副标题冲突与 ReviewReasonLabels 零英文泄露', () {
      const folder = GroupedWorkFolder(
        folderRelativePath: 'Jujutsu Kaisen/Season 2',
        folderName: 'Season 2',
        cleanTitle: '呪術廻戦',
        year: 2023,
        seasonHint: 2,
        mainEpisodeNumbers: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23],
        variants: [],
      );

      const candidateSeason2Match = TmdbWorkDetail(
        tmdbId: 95479,
        mediaType: TmdbMediaType.tv,
        title: '咒术回战',
        originalTitle: '呪術廻戦',
        year: 2020,
        seasons: [
          TmdbSeasonSummary(
            seasonNumber: 1,
            name: '第 1 季',
            episodeCount: 24,
            airDate: '2020-10-03',
          ),
          TmdbSeasonSummary(
            seasonNumber: 2,
            name: '怀玉·玉折 / 涩谷事变',
            episodeCount: 23,
            airDate: '2023-07-06',
          ),
        ],
      );

      const candidateWrongShow = TmdbWorkDetail(
        tmdbId: 10002,
        mediaType: TmdbMediaType.tv,
        title: '呪術廻戦：虚构副标题',
        originalTitle: '呪術廻戦',
        year: 2021,
        seasons: [
          TmdbSeasonSummary(
            seasonNumber: 1,
            name: '第 1 季',
            episodeCount: 12,
            airDate: '2021-01-01',
          ),
        ],
      );

      final decision = WorkMatcher.evaluate(
        folder,
        const [candidateWrongShow, candidateSeason2Match],
      );
      expect(decision.best?.detail.tmdbId, 95479);
      expect(
        decision.best?.reasons,
        containsAll([
          'season_year_match',
          'season_episode_match',
          'season_name_match',
        ]),
      );

      // 罗马音跨语言相似度（平假名そうそうのふりーれん vs 罗马音 Sousou no Frieren）
      final romajiSim = TitleNormalizer.romajiKanaSimilarity(
        'そうそうのふりーれん',
        'Sousou no Frieren',
      );
      expect(romajiSim, greaterThan(0.70));

      // 全量原因码中文映射校验，杜绝出现英文 snake_case 裸露
      const allCodes = [
        'explicit_tmdb_match',
        'explicit_id_mismatch',
        'exact_title_match',
        'high_title_similarity',
        'partial_title_similarity',
        'low_title_similarity',
        'romaji_similarity',
        'year_exact_match',
        'year_close_match',
        'year_span_tolerance',
        'year_mismatch',
        'season_year_match',
        'season_episode_match',
        'season_name_match',
        'subtitle_conflict',
        'missing_sequel_number',
        'partial_latin_prefix',
        'media_type_match',
        'media_type_conflict',
        'close_candidates',
        'low_confidence',
        'high_confidence',
        'no_match',
        'no_candidates',
      ];
      for (final code in allCodes) {
        final label = ReviewReasonLabels.format(code);
        expect(label, isNot(contains('_')), reason: '原因码 $code 不得泄露英文下划线');
        expect(
          RegExp(r'[\u4e00-\u9fff]').hasMatch(label),
          isTrue,
          reason: '原因码 $code 映射结果必须包含简体中文: $label',
        );
      }
    });
  });
}
