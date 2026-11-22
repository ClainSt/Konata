import 'dart:convert';
import 'dart:io';

import 'package:ccplayer/application/scraping/scrape_compute_worker.dart';
import 'package:ccplayer/application/scraping/scrape_orchestrator.dart';
import 'package:ccplayer/domain/matching/directory_grouper.dart';
import 'package:ccplayer/domain/matching/episode_remapper.dart';
import 'package:ccplayer/domain/matching/work_matcher.dart';
import 'package:ccplayer/domain/models/episode.dart';
import 'package:ccplayer/domain/models/media_source.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/domain/models/network_config.dart';
import 'package:ccplayer/domain/models/playback_record.dart';
import 'package:ccplayer/domain/models/tmdb_models.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/domain/scraping/bangumi_models.dart';
import 'package:ccplayer/domain/scraping/directory_analyzer.dart';
import 'package:ccplayer/domain/scraping/scrape_domain_adapter.dart';
import 'package:ccplayer/infrastructure/database/drift_library_repository.dart';
import 'package:ccplayer/infrastructure/database/konata_database.dart';
import 'package:ccplayer/infrastructure/network/priority_http_scheduler.dart';
import 'package:ccplayer/infrastructure/network/tmdb_http_client.dart';
import 'package:ccplayer/infrastructure/network/tmdb_service.dart';
import 'package:ccplayer/infrastructure/sources/local_source_gateway.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

http.Response _jsonResp(Object data, [int statusCode = 200]) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(data)),
    statusCode,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

ScannedFileInput _video(
  String relPath, {
  int sizeMb = 600,
  List<String> subs = const [],
}) => ScannedFileInput(
  relativePath: relPath,
  fileName: relPath.split('/').last,
  fileSize: sizeMb * 1024 * 1024,
  assetKind: AssetKind.video,
  externalSubtitles: subs,
);

ScannedFileInput _cd(String relPath) => ScannedFileInput(
  relativePath: relPath,
  fileName: relPath.split('/').last,
  fileSize: 40 * 1024 * 1024,
  assetKind: AssetKind.cdAlbum,
);

ScannedFileInput _scan(String relPath) => ScannedFileInput(
  relativePath: relPath,
  fileName: relPath.split('/').last,
  fileSize: 4 * 1024 * 1024,
  assetKind: AssetKind.scanGallery,
);

const _bocchiTvDetail = TmdbWorkDetail(
  tmdbId: 201950,
  mediaType: TmdbMediaType.tv,
  title: '孤独摇滚！',
  originalTitle: 'ぼっち・ざ・ろっく！',
  year: 2022,
  aliases: ['Bocchi the Rock!', '孤独摇滚'],
  genreIds: [16],
  voteCount: 420,
  seasons: [
    TmdbSeasonSummary(seasonNumber: 0, name: '特别篇', episodeCount: 3),
    TmdbSeasonSummary(
      seasonNumber: 1,
      name: '第 1 季',
      episodeCount: 12,
      airDate: '2022-10-09',
    ),
  ],
);

const _bocchiMovieDetail = TmdbWorkDetail(
  tmdbId: 1129598,
  mediaType: TmdbMediaType.movie,
  title: '剧场总集篇 孤独摇滚！ Re:',
  originalTitle: '劇場総集編ぼっち・ざ・ろっく！ Re:',
  year: 2024,
  aliases: ['Bocchi the Rock! Recap Part 1'],
  genreIds: [16],
  voteCount: 55,
);

const _bocchiBgmCandidate = BangumiSubjectCandidate(
  id: 328609,
  name: 'ぼっち・ざ・ろっく！',
  nameCn: '孤独摇滚！',
  aliases: ['Bocchi the Rock!', '孤独摇滚'],
  airDate: '2022-10-09',
  totalEpisodes: 12,
  platform: 'TV',
);

const _frierenTvDetail = TmdbWorkDetail(
  tmdbId: 209867,
  mediaType: TmdbMediaType.tv,
  title: '葬送的芙莉莲',
  originalTitle: '葬送のフリーレン',
  year: 2023,
  aliases: ['Sousou no Frieren', "Frieren: Beyond Journey's End"],
  genreIds: [16],
  voteCount: 900,
  seasons: [
    TmdbSeasonSummary(seasonNumber: 0, name: '特别篇', episodeCount: 11),
    TmdbSeasonSummary(
      seasonNumber: 1,
      name: '第 1 季',
      episodeCount: 28,
      airDate: '2023-09-29',
    ),
    TmdbSeasonSummary(
      seasonNumber: 2,
      name: '第 2 季',
      episodeCount: 12,
      airDate: '2026-01-16',
    ),
  ],
);

const _frierenBgmCandidate = BangumiSubjectCandidate(
  id: 400602,
  name: '葬送のフリーレン',
  nameCn: '葬送的芙莉莲',
  aliases: ['Sousou no Frieren', "Frieren: Beyond Journey's End"],
  airDate: '2023-09-29',
  totalEpisodes: 28,
  platform: 'TV',
);

void main() {
  group('场景一：追番首集、单卷 Vol.1 与后续增量追加', () {
    test('追番仅第 1 集（01.mkv / 空格 01）与根目录 Vol.1 准确识别为正片 S1，绝不误判 S0 或剧场版', () {
      for (final relPath in const [
        '孤独摇滚/01.mkv',
        '孤独摇滚/Bocchi the Rock 01.mkv',
        '孤独摇滚/孤独摇滚 第01话.mkv',
      ]) {
        final groups = ScrapeDomainAdapter.groupAndSplitFiles(
          sourceId: 'src',
          files: [_video(relPath)],
        );
        expect(groups, hasLength(1), reason: relPath);
        final g = groups.single;
        expect(g.inventory?.shape, WorkShape.series, reason: relPath);
        expect(g.isMovieHint, isFalse, reason: relPath);
        expect(g.mainEpisodeNumbers, [1], reason: relPath);

        final decision = ScrapeDomainAdapter.evaluateMatch(
          g,
          const [_bocchiTvDetail, _bocchiMovieDetail],
          bangumiCandidates: const [_bocchiBgmCandidate],
        );
        expect(decision.level, MatchLevel.autoBind, reason: relPath);
        expect(decision.best?.detail.tmdbId, 201950, reason: relPath);
        expect(
          decision.matchedSeason ?? decision.best?.matchedSeason,
          1,
          reason: relPath,
        );
      }

      // 回归保护：带 Movie 标记的剧场版序号标题（Legend 01）仍严格保持 feature。
      final movieInv = DirectoryAnalyzer.analyze(
        '头文字D Legend1 -觉醒- (2014)',
        const [
          (
            path:
                '[AI-Raws&ANK-Raws] New Initial D the Movie Legend 01 - Awakening - (BDRip 1920x1080).mkv',
            size: 3500 * 1024 * 1024,
          ),
        ],
      );
      expect(movieInv.shape, WorkShape.feature);

      // 根目录带 Vol.1：必须自动补充剥离分卷后的纯净母剧名检索词。
      final volRoot = ScrapeDomainAdapter.groupAndSplitFiles(
        sourceId: 'src',
        files: [
          _video('孤独摇滚 Vol.1/[VCB-Studio] Bocchi the Rock! [01].mkv'),
          _video('孤独摇滚 Vol.1/[VCB-Studio] Bocchi the Rock! [02].mkv'),
        ],
      ).single;
      final queries = ScrapeDomainAdapter.buildSearchQueries(volRoot);
      expect(queries, contains('孤独摇滚'));
    });

    test('端到端追番与分卷增量更新：先扫 Vol.1 首集 → 追加新集与 Vol.2 后合并同卡且完整保留播放记录', () async {
      final tempRoot = await Directory.systemTemp.createTemp('konata_inc_');
      final db = KonataDatabase(NativeDatabase.memory());
      final repo = DriftLibraryRepository(db);
      addTearDown(() async {
        await db.close();
        if (await tempRoot.exists()) {
          await tempRoot.delete(recursive: true);
        }
      });

      Future<void> touch(String relPath, [String content = 'x']) async {
        final f = File(p.joinAll([tempRoot.path, ...relPath.split('/')]));
        await f.parent.create(recursive: true);
        await f.writeAsString(content);
      }

      await touch('孤独摇滚/Vol.1/[VCB-Studio] Bocchi the Rock! [01].mkv', 'ep1');
      await touch('孤独摇滚/Vol.1/CD/01.flac', 'cd1');
      await touch('孤独摇滚/Vol.1/Scans/001.jpg', 'scan1');

      final source = MediaSource(
        id: 'local-inc',
        kind: MediaSourceKind.local,
        label: '追番盘',
        location: tempRoot.path,
      );
      await repo.upsertMediaSource(source);

      var httpRequests = 0;
      final mockClient = MockClient((request) async {
        httpRequests++;
        final path = request.url.path;
        if (path.endsWith('/search/tv')) {
          return _jsonResp({
            'results': [
              {
                'id': 201950,
                'name': '孤独摇滚！',
                'original_name': 'ぼっち・ざ・ろっく！',
                'first_air_date': '2022-10-09',
                'genre_ids': [16],
                'vote_count': 420,
              },
            ],
          });
        }
        if (path.endsWith('/search/movie')) {
          return _jsonResp({'results': []});
        }
        if (path.endsWith('/tv/201950')) {
          return _jsonResp({
            'id': 201950,
            'name': '孤独摇滚！',
            'original_name': 'ぼっち・ざ・ろっく！',
            'first_air_date': '2022-10-09',
            'genres': [
              {'id': 16, 'name': '动画'},
            ],
            'vote_count': 420,
            'alternative_titles': {
              'results': [
                {'title': 'Bocchi the Rock!'},
              ],
            },
            'seasons': [
              {'season_number': 0, 'name': '特别篇', 'episode_count': 3},
              {
                'season_number': 1,
                'name': '第 1 季',
                'episode_count': 12,
                'air_date': '2022-10-09',
              },
            ],
          });
        }
        if (path.endsWith('/tv/201950/season/1')) {
          return _jsonResp({
            'episodes': [
              for (var i = 1; i <= 12; i++)
                {'episode_number': i, 'name': '第$i话'},
            ],
          });
        }
        if (path.endsWith('/tv/201950/season/0')) {
          return _jsonResp({'episodes': []});
        }
        return http.Response('{}', 404);
      });

      final orchestrator = ScrapeOrchestrator(
        repository: repo,
        tmdbService: TmdbService(
          httpClient: TmdbHttpClient(
            config: const TmdbNetworkConfig(credential: 'v3_test'),
            scheduler: PriorityHttpScheduler(),
            httpClient: mockClient,
          ),
        ),
        gatewayBuilder: (s) async => LocalSourceGateway(rootPath: s.location),
        computeWorker: const ScrapeComputeWorker(useIsolate: false),
      );

      // 首次扫描：仅 Vol.1 第 1 集 + CD + Scan。
      await orchestrator.scanAndScrapeSource(source);
      final works1 = await repo.getAllWorks();
      expect(works1, hasLength(1));
      final work1 = works1.single;
      expect(work1.tmdbId, 201950);
      expect(work1.matchedSeason, 1);

      final eps1 = await repo.getEpisodesByWork(work1.id);
      final mainEp1 = eps1.singleWhere((e) => e.category == EpisodeCategory.main);
      expect(mainEp1.episodeNumber, 1);

      // 模拟用户观看第 1 集至 120 秒。
      final variants1 = await repo.getVariantsByWork(work1.id);
      final ep1Variant = variants1.firstWhere((v) => v.episodeId == mainEp1.id);
      await repo.recordPlayback(
        PlaybackRecord(
          id: 'pb-ep1',
          workId: work1.id,
          episodeId: mainEp1.id,
          variantId: ep1Variant.id,
          seasonNumber: 1,
          episodeNumber: 1,
          episodeTitle: '第1话',
          sourceType: MediaSourceKind.local,
          playedAt: DateTime(2026, 11, 22, 12, 0),
          positionSeconds: 120,
          durationSeconds: 1440,
        ),
      );

      // 二次扫描：用户新增 Vol.1 第 2 集以及 Vol.2 第 3-4 集 + SP + CD + Scan。
      await touch('孤独摇滚/Vol.1/[VCB-Studio] Bocchi the Rock! [02].mkv', 'ep2');
      await touch('孤独摇滚/Vol.2/[Snow-Raws] Bocchi the Rock! [03].mkv', 'ep3');
      await touch('孤独摇滚/Vol.2/[Snow-Raws] Bocchi the Rock! [04].mkv', 'ep4');
      await touch('孤独摇滚/Vol.2/SPs/[Snow-Raws] Bocchi the Rock! [NCOP].mkv', 'sp');
      await touch('孤独摇滚/Vol.2/CD/02.flac', 'cd2');
      await touch('孤独摇滚/Vol.2/Scans/002.png', 'scan2');

      await orchestrator.scanAndScrapeSource(source);
      final works2 = await repo.getAllWorks();
      expect(works2, hasLength(1));
      expect(works2.single.id, work1.id);

      final eps2 = await repo.getEpisodesByWork(work1.id);
      final mainNums =
          eps2
              .where((e) => e.category == EpisodeCategory.main)
              .map((e) => e.episodeNumber)
              .toList()
            ..sort();
      expect(mainNums, [1, 2, 3, 4]);
      expect(
        eps2.where((e) => e.category == EpisodeCategory.extra).length,
        1,
      );

      final variants2 = await repo.getVariantsByWork(work1.id);
      expect(variants2.where((v) => v.assetKind == AssetKind.cdAlbum), hasLength(2));
      expect(variants2.where((v) => v.assetKind == AssetKind.scanGallery), hasLength(2));

      // 原有第 1 集观看进度完整保留。
      final playbacks = await repo.getPlaybacksByWork(work1.id);
      expect(playbacks, hasLength(1));
      expect(playbacks.single.positionSeconds, 120);

      // 第三次无变更重扫：走零请求快跳，不发起任何在线 API 请求。
      final reqBefore = httpRequests;
      await orchestrator.scanAndScrapeSource(source);
      expect(httpRequests, reqBefore);
    });
  });

  group('场景二：残缺起始集（3-12）与稀疏跳集（1,3,5 / 2,5,9）', () {
    test('多季番 S1=12 / S2=10 仅存 3..12 时精准命中 S1 且不误偏移集号', () {
      const multiSeasonTv = TmdbWorkDetail(
        tmdbId: 70001,
        mediaType: TmdbMediaType.tv,
        title: '某多季动画',
        originalTitle: '某多季アニメ',
        year: 2020,
        aliases: ['Multi Season Anime'],
        genreIds: [16],
        voteCount: 300,
        seasons: [
          TmdbSeasonSummary(seasonNumber: 0, name: '特别篇', episodeCount: 3),
          TmdbSeasonSummary(
            seasonNumber: 1,
            name: '第 1 季',
            episodeCount: 12,
            airDate: '2020-04-01',
          ),
          TmdbSeasonSummary(
            seasonNumber: 2,
            name: '第 2 季',
            episodeCount: 10,
            airDate: '2022-04-01',
          ),
        ],
      );
      final folder = ScrapeDomainAdapter.groupAndSplitFiles(
        sourceId: 'src',
        files: [
          for (var ep = 3; ep <= 12; ep++)
            _video(
              '某多季动画/[VCB-Studio] Multi Season Anime [${ep.toString().padLeft(2, '0')}].mkv',
            ),
        ],
      ).single;

      final decision = ScrapeDomainAdapter.evaluateMatch(folder, const [
        multiSeasonTv,
      ]);
      expect(decision.level, MatchLevel.autoBind);
      expect(decision.best?.detail.tmdbId, 70001);
      expect(decision.matchedSeason ?? decision.best?.matchedSeason, 1);

      final remap = EpisodeRemapper.buildPlan(
        folder: folder,
        tmdbSeasons: multiSeasonTv.seasons,
        matchedSeason: 1,
      );
      expect(remap.remappedSlots, isEmpty);
      expect(folder.mainEpisodeNumbers, [3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);
    });

    test('稀疏跳集 1,3,5 与无首集跳集 2,5,9 准确命中 S1 且集号原样保持', () {
      final sparse135 = ScrapeDomainAdapter.groupAndSplitFiles(
        sourceId: 'src',
        files: [
          _video('孤独摇滚/[VCB-Studio] Bocchi the Rock! [01].mkv'),
          _video('孤独摇滚/[VCB-Studio] Bocchi the Rock! [03].mkv'),
          _video('孤独摇滚/[VCB-Studio] Bocchi the Rock! [05].mkv'),
        ],
      ).single;
      final dec135 = ScrapeDomainAdapter.evaluateMatch(
        sparse135,
        const [_bocchiTvDetail, _bocchiMovieDetail],
        bangumiCandidates: const [_bocchiBgmCandidate],
      );
      expect(dec135.level, MatchLevel.autoBind);
      expect(dec135.best?.detail.tmdbId, 201950);
      expect(dec135.matchedSeason ?? dec135.best?.matchedSeason, 1);
      expect(sparse135.mainEpisodeNumbers, [1, 3, 5]);
      expect(
        EpisodeRemapper.buildPlan(
          folder: sparse135,
          tmdbSeasons: _bocchiTvDetail.seasons,
          matchedSeason: 1,
        ).remappedSlots,
        isEmpty,
      );

      final sparse259 = ScrapeDomainAdapter.groupAndSplitFiles(
        sourceId: 'src',
        files: [
          _video('葬送的芙莉莲/[LoliHouse] 葬送的芙莉莲 - 02.mkv'),
          _video('葬送的芙莉莲/[LoliHouse] 葬送的芙莉莲 - 05.mkv'),
          _video('葬送的芙莉莲/[LoliHouse] 葬送的芙莉莲 - 09.mkv'),
        ],
      ).single;
      final dec259 = ScrapeDomainAdapter.evaluateMatch(
        sparse259,
        const [_frierenTvDetail],
        bangumiCandidates: const [_frierenBgmCandidate],
      );
      expect(dec259.level, MatchLevel.autoBind);
      expect(dec259.best?.detail.tmdbId, 209867);
      expect(dec259.matchedSeason ?? dec259.best?.matchedSeason, 1);
      expect(sparse259.mainEpisodeNumbers, [2, 5, 9]);
    });
  });

  group('场景三：多压制组/字幕组混放洗版（正片 + 特典 + CD + Scan）', () {
    test('同目录 4 组异语种分段洗版 + 同集双版本字幕 + 压制组前缀 SP/Bonus/CD/Scan 零拆卡零丢失', () {
      final groups = ScrapeDomainAdapter.groupAndSplitFiles(
        sourceId: 'src',
        files: [
          // 第 01 集存在两个压制组双版本洗版及各自外挂字幕。
          _video(
            '葬送的芙莉莲/[VCB-Studio] Sousou no Frieren [01][Ma10p_1080p].mkv',
            subs: const [
              '葬送的芙莉莲/[VCB-Studio] Sousou no Frieren [01][Ma10p_1080p].sc.ass',
            ],
          ),
          _video(
            '葬送的芙莉莲/[Snow-Raws] 葬送のフリーレン 第01話 (BD 1920x1080).mkv',
            subs: const [
              '葬送的芙莉莲/[Snow-Raws] 葬送のフリーレン 第01話 (BD 1920x1080).tc.ass',
            ],
          ),
          _video('葬送的芙莉莲/[VCB-Studio] Sousou no Frieren [02][Ma10p_1080p].mkv'),
          _video('葬送的芙莉莲/[VCB-Studio] Sousou no Frieren [03][Ma10p_1080p].mkv'),
          for (var ep = 4; ep <= 6; ep++)
            _video(
              "葬送的芙莉莲/[LoliHouse] Frieren Beyond Journey's End - ${ep.toString().padLeft(2, '0')} [WebRip].mkv",
            ),
          for (var ep = 7; ep <= 9; ep++)
            _video(
              '葬送的芙莉莲/[Nekomoe kissaten] 葬送的芙莉莲 [${ep.toString().padLeft(2, '0')}][1080p].mkv',
            ),
          for (var ep = 10; ep <= 12; ep++)
            _video(
              '葬送的芙莉莲/[Snow-Raws] 葬送のフリーレン 第${ep.toString().padLeft(2, '0')}話 (BD 1920x1080).mkv',
            ),
          // 压制组前缀附属子目录（不同压制组的特典、CD 与 Scan）。
          _video(
            '葬送的芙莉莲/[ANK-Raws] SPs/[ANK-Raws] Sousou no Frieren [NCOP].mkv',
            sizeMb: 90,
          ),
          _video(
            '葬送的芙莉莲/[Moozzi2] Bonus/[Moozzi2] Frieren [Interview].mkv',
            sizeMb: 120,
          ),
          _cd('葬送的芙莉莲/[EAC] CDs/01.flac'),
          _scan('葬送的芙莉莲/[QTS] Scans/001.jpg'),
        ],
      );

      expect(groups, hasLength(1));
      final g = groups.single;
      expect(g.inventory?.shape, WorkShape.series);
      expect(g.mainEpisodeNumbers, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);
      expect(g.variants.where((v) => v.assetKind == AssetKind.video), hasLength(15));
      expect(g.variants.where((v) => v.assetKind == AssetKind.cdAlbum), hasLength(1));
      expect(
        g.variants.where((v) => v.assetKind == AssetKind.scanGallery),
        hasLength(1),
      );
      expect(
        g.slotAssignmentsByPath.values.where(
          (s) => s.category == EpisodeCategory.extra,
        ),
        hasLength(2),
      );
      final ep1Variants = g.slotAssignmentsByPath.entries
          .where(
            (e) =>
                e.value.category == EpisodeCategory.main &&
                e.value.episodeNumber == 1,
          )
          .length;
      expect(ep1Variants, 2);

      final decision = ScrapeDomainAdapter.evaluateMatch(
        g,
        const [_frierenTvDetail],
        bangumiCandidates: const [_frierenBgmCandidate],
      );
      expect(decision.level, MatchLevel.autoBind);
      expect(decision.best?.detail.tmdbId, 209867);
      expect(decision.matchedSeason ?? decision.best?.matchedSeason, 1);
    });

    test('同作品父目录下两压制组子目录洗版端到端自动归并为单卡，保留多版本/SP/CD/Scan 且重扫零请求快跳', () async {
      final tempRoot = await Directory.systemTemp.createTemp('konata_mixsub_');
      final db = KonataDatabase(NativeDatabase.memory());
      final repo = DriftLibraryRepository(db);
      addTearDown(() async {
        await db.close();
        if (await tempRoot.exists()) {
          await tempRoot.delete(recursive: true);
        }
      });

      Future<void> touch(String relPath, [String content = 'x']) async {
        final f = File(p.joinAll([tempRoot.path, ...relPath.split('/')]));
        await f.parent.create(recursive: true);
        await f.writeAsString(content);
      }

      // 同作品父目录「孤独摇滚」下并排放置两个不同压制组的完整子文件夹（含重叠第 01 集 + 互补集 + SP/CD/Scan）。
      for (var ep = 1; ep <= 6; ep++) {
        await touch(
          '孤独摇滚/[VCB-Studio] Bocchi the Rock! [Ma10p_1080p]/'
          '[VCB-Studio] Bocchi the Rock! [${ep.toString().padLeft(2, '0')}].mkv',
        );
      }
      await touch(
        '孤独摇滚/[VCB-Studio] Bocchi the Rock! [Ma10p_1080p]/SPs/[VCB-Studio] Bocchi the Rock! [NCOP].mkv',
      );
      await touch(
        '孤独摇滚/[Snow-Raws] ぼっち・ざ・ろっく！ (BD 1920x1080)/'
        '[Snow-Raws] ぼっち・ざ・ろっく！ 第01話.mkv',
      );
      for (var ep = 7; ep <= 12; ep++) {
        await touch(
          '孤独摇滚/[Snow-Raws] ぼっち・ざ・ろっく！ (BD 1920x1080)/'
          '[Snow-Raws] ぼっち・ざ・ろっく！ 第${ep.toString().padLeft(2, '0')}話.mkv',
        );
      }
      await touch(
        '孤独摇滚/[Snow-Raws] ぼっち・ざ・ろっく！ (BD 1920x1080)/CDs/OST.flac',
      );
      await touch(
        '孤独摇滚/[Snow-Raws] ぼっち・ざ・ろっく！ (BD 1920x1080)/Scans/001.jpg',
      );

      final source = MediaSource(
        id: 'local-mixsub',
        kind: MediaSourceKind.local,
        label: '洗版盘',
        location: tempRoot.path,
      );
      await repo.upsertMediaSource(source);

      var httpRequests = 0;
      final mockClient = MockClient((request) async {
        httpRequests++;
        final path = request.url.path;
        if (path.endsWith('/search/tv')) {
          return _jsonResp({
            'results': [
              {
                'id': 201950,
                'name': '孤独摇滚！',
                'original_name': 'ぼっち・ざ・ろっく！',
                'first_air_date': '2022-10-09',
                'genre_ids': [16],
                'vote_count': 420,
              },
            ],
          });
        }
        if (path.endsWith('/search/movie')) {
          return _jsonResp({'results': []});
        }
        if (path.endsWith('/tv/201950')) {
          return _jsonResp({
            'id': 201950,
            'name': '孤独摇滚！',
            'original_name': 'ぼっち・ざ・ろっく！',
            'first_air_date': '2022-10-09',
            'genres': [
              {'id': 16, 'name': '动画'},
            ],
            'vote_count': 420,
            'alternative_titles': {
              'results': [
                {'title': 'Bocchi the Rock!'},
              ],
            },
            'seasons': [
              {'season_number': 0, 'name': '特别篇', 'episode_count': 3},
              {
                'season_number': 1,
                'name': '第 1 季',
                'episode_count': 12,
                'air_date': '2022-10-09',
              },
            ],
          });
        }
        if (path.endsWith('/tv/201950/season/1')) {
          return _jsonResp({
            'episodes': [
              for (var i = 1; i <= 12; i++)
                {'episode_number': i, 'name': '第$i话'},
            ],
          });
        }
        if (path.endsWith('/tv/201950/season/0')) {
          return _jsonResp({'episodes': []});
        }
        return http.Response('{}', 404);
      });

      final orchestrator = ScrapeOrchestrator(
        repository: repo,
        tmdbService: TmdbService(
          httpClient: TmdbHttpClient(
            config: const TmdbNetworkConfig(credential: 'v3_test'),
            scheduler: PriorityHttpScheduler(),
            httpClient: mockClient,
          ),
        ),
        gatewayBuilder: (s) async => LocalSourceGateway(rootPath: s.location),
        computeWorker: const ScrapeComputeWorker(useIsolate: false),
      );

      // 首次扫描：两个同父目录压制组子文件夹刮削到同一 tv:201950 S1 后自动归并为唯一作品卡。
      await orchestrator.scanAndScrapeSource(source);
      final works = await repo.getAllWorks();
      expect(works, hasLength(1));
      final mergedWork = works.single;
      expect(mergedWork.tmdbId, 201950);
      expect(mergedWork.matchedSeason, 1);

      final episodes = await repo.getEpisodesByWork(mergedWork.id);
      final mainNums =
          episodes
              .where((e) => e.category == EpisodeCategory.main)
              .map((e) => e.episodeNumber)
              .toList()
            ..sort();
      expect(mainNums, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);
      expect(
        episodes.where((e) => e.category == EpisodeCategory.extra),
        hasLength(1),
      );

      final variants = await repo.getVariantsByWork(mergedWork.id);
      final ep1Id = episodes
          .singleWhere(
            (e) => e.category == EpisodeCategory.main && e.episodeNumber == 1,
          )
          .id;
      expect(variants.where((v) => v.episodeId == ep1Id), hasLength(2));
      expect(
        variants.where((v) => v.assetKind == AssetKind.cdAlbum),
        hasLength(1),
      );
      expect(
        variants.where((v) => v.assetKind == AssetKind.scanGallery),
        hasLength(1),
      );

      // 二次无变更重扫：两个已归并子目录均命中目录前缀快跳，零网络请求且不重复拆卡。
      final reqBefore = httpRequests;
      await orchestrator.scanAndScrapeSource(source);
      expect(httpRequests, reqBefore);
      expect(await repo.getAllWorks(), hasLength(1));
      expect((await repo.getVariantsByWork(mergedWork.id)).length, variants.length);
    });
  });
}
