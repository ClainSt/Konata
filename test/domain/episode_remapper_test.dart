import 'package:ccplayer/domain/matching/episode_remapper.dart';
import 'package:ccplayer/domain/models/tmdb_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EpisodeRemapper 跨季绝对集号重映射测试', () {
    const reZeroSeasons = [
      TmdbSeasonSummary(seasonNumber: 0, name: 'Specials', episodeCount: 15),
      TmdbSeasonSummary(seasonNumber: 1, name: 'Season 1', episodeCount: 25),
      TmdbSeasonSummary(seasonNumber: 2, name: 'Season 2', episodeCount: 25),
      TmdbSeasonSummary(seasonNumber: 3, name: 'Season 3', episodeCount: 16),
    ];

    test('情形 1：Re:Zero 第三季采用绝对集号 [51..66] 精确重映射为 S3E1..E16', () {
      final mapping = EpisodeRemapper.computeRemapping(
        tmdbSeasons: reZeroSeasons,
        mainEpisodesBySeason: {
          3: {for (var i = 51; i <= 66; i++) i},
        },
      );

      expect(mapping['3:51'], (seasonNumber: 3, episodeNumber: 1));
      expect(mapping['3:66'], (seasonNumber: 3, episodeNumber: 16));
      expect(mapping.length, 16);
    });

    test('情形 2：未标分季导致超出 S1 集数的绝对集号按前序季累计顺延归季', () {
      const oshiSeasons = [
        TmdbSeasonSummary(seasonNumber: 1, name: 'S1', episodeCount: 11),
        TmdbSeasonSummary(seasonNumber: 2, name: 'S2', episodeCount: 13),
        TmdbSeasonSummary(seasonNumber: 3, name: 'S3', episodeCount: 13),
      ];

      final mapping = EpisodeRemapper.computeRemapping(
        tmdbSeasons: oshiSeasons,
        mainEpisodesBySeason: {
          1: {30, 31},
        },
      );

      expect(mapping['1:30'], (seasonNumber: 3, episodeNumber: 6));
      expect(mapping['1:31'], (seasonNumber: 3, episodeNumber: 7));
    });

    test('安全护栏：单季本身集数包含 53..75 时绝不误偏移', () {
      const rinneSeasons = [
        TmdbSeasonSummary(seasonNumber: 1, name: 'S1', episodeCount: 25),
        TmdbSeasonSummary(seasonNumber: 2, name: 'S2', episodeCount: 25),
        TmdbSeasonSummary(seasonNumber: 3, name: 'S3', episodeCount: 25),
      ];
      // 若目录为 S1 单季且仅 25 集以上不存在多季情况，保持原状；若实际单季就是 75 集亦不改。
      final longSingleSeason = EpisodeRemapper.computeRemapping(
        tmdbSeasons: const [
          TmdbSeasonSummary(seasonNumber: 1, name: 'S1', episodeCount: 75),
        ],
        mainEpisodesBySeason: {
          1: {53, 54, 75},
        },
      );
      expect(longSingleSeason, isEmpty);

      // 即使 S2 也有 25 集，正常分季 S2E1..S2E25 绝不触发二次偏移
      final normalS2 = EpisodeRemapper.computeRemapping(
        tmdbSeasons: rinneSeasons,
        mainEpisodesBySeason: {
          2: {1, 2, 25},
        },
      );
      expect(normalS2, isEmpty);
    });
  });
}
