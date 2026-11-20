import 'package:ccplayer/application/scraping/scrape_work_persister.dart';
import 'package:ccplayer/domain/matching/directory_grouper.dart';
import 'package:ccplayer/domain/models/episode.dart';
import 'package:ccplayer/domain/models/media_source.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/domain/models/tmdb_models.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/domain/scraping/scrape_domain_adapter.dart';
import 'package:ccplayer/infrastructure/database/drift_library_repository.dart';
import 'package:ccplayer/infrastructure/database/konata_database.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

ScannedFileInput _video(String path) => ScannedFileInput(
  relativePath: path,
  fileName: path.split('/').last,
  fileSize: 900 * 1024 * 1024,
  assetKind: AssetKind.video,
);

const _rangeFile =
    'Tamayura/[VCB-Studio] Tamayura [01-02][Ma10p_1080p][x265_flac_aac].mkv';
const _thirdFile =
    'Tamayura/[VCB-Studio] Tamayura [03][Ma10p_1080p][x265_flac_aac].mkv';

void main() {
  late KonataDatabase db;
  late DriftLibraryRepository repo;

  setUp(() async {
    db = KonataDatabase(NativeDatabase.memory());
    repo = DriftLibraryRepository(db);
    await repo.upsertMediaSource(
      const MediaSource(
        id: 's',
        kind: MediaSourceKind.local,
        label: '测试盘',
        location: 'D:/Anime',
      ),
    );
  });

  tearDown(() => db.close());

  Future<(Work, GroupedWorkFolder)> prepare() async {
    final folder = ScrapeDomainAdapter.groupAndSplitFiles(
      sourceId: 's',
      files: [_video(_rangeFile), _video(_thirdFile)],
    ).single;
    final work = Work(
      id: folder.variants.first.workId,
      tmdbId: 1,
      tmdbMediaType: TmdbMediaType.tv,
      title: 'Tamayura',
      scrapeStatus: ScrapeStatus.matched,
    );
    await repo.upsertWork(work);
    return (work, folder);
  }

  test('入库后生成 episodeNumber=1、episodeNumberEnd=2 的区间条目并持久化往返', () async {
    final (work, folder) = await prepare();
    await ScrapeWorkPersister(repo).syncEpisodesAndVariants(
      work: work,
      folder: folder,
      tmdbEpisodes: const [
        TmdbEpisodeDetail(
          seasonNumber: 1,
          episodeNumber: 1,
          title: '第一话',
          overview: '简介一',
          stillPath: '/s1.jpg',
        ),
        TmdbEpisodeDetail(
          seasonNumber: 1,
          episodeNumber: 2,
          title: '第二话',
          overview: '简介二',
          stillPath: '/s2.jpg',
        ),
        TmdbEpisodeDetail(seasonNumber: 1, episodeNumber: 3, title: '第三话'),
      ],
    );
    final episodes = (await repo.getEpisodesByWork(
      work.id,
    )).where((e) => e.category == EpisodeCategory.main).toList();
    expect(episodes, hasLength(2));
    final range = episodes.firstWhere((e) => e.episodeNumber == 1);
    expect(range.episodeNumberEnd, 2);
    expect(range.title, '第一话 / 第二话');
    expect(range.overview, '简介一\n\n简介二');
    expect(range.stillPath, '/s1.jpg');
    final third = episodes.firstWhere((e) => e.episodeNumber == 3);
    expect(third.episodeNumberEnd, isNull);

    final variants = await repo.getVariantsByWork(work.id);
    expect(
      variants.where((v) => v.episodeId == range.id).map((v) => v.relativePath),
      [_rangeFile],
    );
  });

  test('跨度大于 3 时标题取首末集并以 ～ 连接，简介取首集', () async {
    final folder = ScrapeDomainAdapter.groupAndSplitFiles(
      sourceId: 's',
      files: [
        _video('Nyanko/[VCB-Studio] Nyanko Days [01-05][Ma10p_1080p].mkv'),
        _video('Nyanko/[VCB-Studio] Nyanko Days [06][Ma10p_1080p].mkv'),
      ],
    ).single;
    final work = Work(
      id: folder.variants.first.workId,
      tmdbId: 2,
      tmdbMediaType: TmdbMediaType.tv,
      title: 'Nyanko Days',
      scrapeStatus: ScrapeStatus.matched,
    );
    await repo.upsertWork(work);
    await ScrapeWorkPersister(repo).syncEpisodesAndVariants(
      work: work,
      folder: folder,
      tmdbEpisodes: [
        for (var i = 1; i <= 6; i++)
          TmdbEpisodeDetail(
            seasonNumber: 1,
            episodeNumber: i,
            title: '标题$i',
            overview: '简介$i',
          ),
      ],
    );
    final range = (await repo.getEpisodesByWork(
      work.id,
    )).firstWhere((e) => e.episodeNumber == 1);
    expect(range.episodeNumberEnd, 5);
    expect(range.title, '标题1 ～ 标题5');
    expect(range.overview, '简介1');
  });

  test('缺少 TMDB 标题时回退默认占位标题', () async {
    final (work, folder) = await prepare();
    await ScrapeWorkPersister(repo).syncEpisodesAndVariants(
      work: work,
      folder: folder,
      tmdbEpisodes: const [],
    );
    final range = (await repo.getEpisodesByWork(
      work.id,
    )).firstWhere((e) => e.episodeNumber == 1);
    expect(range.episodeNumberEnd, 2);
    expect(range.title, '第 1-2 话');
  });
}
