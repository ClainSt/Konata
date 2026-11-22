import 'package:konata/domain/models/episode.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/models/tmdb_models.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/domain/scraping/cloud_media_asset_presentation.dart';
import 'package:konata/domain/scraping/scrape_domain_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const episode = <String, dynamic>{
    'name': 'OVA story',
    'episode_number': 1,
  };

  Map<String, Object?> asset(String name) => {
    'name': name,
    'relative_path': 'Bonus/$name',
    'category': 'extra',
  };

  for (final name in [
    '[LoliHouse] Sasaki to Miyano - OVA CM [BDRip 1080p HEVC-10bit FLAC].mkv',
    'Show OAD PV01.mkv',
    'Show OVA01 [CM02].mkv',
    'Show OVA PV_01.mkv',
    'Show OAD TVCM.mkv',
  ]) {
    test('宣传片 CM/PV 不得误消费 OVA 正片故事条目: $name', () {
      final file = asset(name);
      expect(
        CloudMediaAssetPresentation.mapSpecialEpisodes(
          assets: [file],
          specials: [episode],
        ),
        isEmpty,
      );
      expect(
        CloudMediaAssetPresentation.specialEpisode(file, {'0': [episode]}),
        isNull,
      );
    });
  }

  for (final name in ['Show OVA01.mkv', 'Show OAD.mkv', 'Acme OVA01.mkv']) {
    test('常规 OVA/OAD 特典正常映射到 Season 0 对应集条目: $name', () {
      final file = asset(name);
      expect(
        CloudMediaAssetPresentation.mapSpecialEpisodes(
          assets: [file],
          specials: [episode],
        )[file['relative_path']],
        episode,
      );
    });
  }

  test('ScrapeDomainAdapter.mapSpecialEpisodes 保持 CM 防护与普通 OVA 精确映射一致', () {
    const work = Work(id: 'w1', title: 'Test Show', tmdbId: 100);
    const extraOva = MediaVariant(
      id: 'v-ova',
      workId: 'w1',
      sourceId: 's1',
      relativePath: 'Bonus/Show OVA01.mkv',
      fileName: 'Show OVA01.mkv',
      fileSize: 100,
      assetKind: AssetKind.video,
    );
    const extraCm = MediaVariant(
      id: 'v-cm',
      workId: 'w1',
      sourceId: 's1',
      relativePath: 'Bonus/[LoliHouse] Show - OVA CM [1080p].mkv',
      fileName: '[LoliHouse] Show - OVA CM [1080p].mkv',
      fileSize: 100,
      assetKind: AssetKind.video,
    );
    const s0Ep = TmdbEpisodeDetail(
      seasonNumber: 0,
      episodeNumber: 1,
      title: 'OVA story',
    );
    final mapped = ScrapeDomainAdapter.mapSpecialEpisodes(
      work: work,
      extraVariants: const [extraOva, extraCm],
      seasonZeroEpisodes: const [s0Ep],
    );
    expect(mapped[extraOva.relativePath], s0Ep);
    expect(mapped.containsKey(extraCm.relativePath), isFalse);
  });

  test('显式 Season 0 分集号映射在 Episode 模型中保持完整标题与归类', () {
    const manualExtra = Episode(
      id: 'ep-manual-s0',
      workId: 'w1',
      seasonNumber: 0,
      episodeNumber: 1,
      category: EpisodeCategory.extra,
      extraType: ExtraKind.ova,
      title: 'OVA story',
    );
    expect(manualExtra.seasonNumber, 0);
    expect(manualExtra.episodeNumber, 1);
    expect(manualExtra.title, 'OVA story');
  });
}
