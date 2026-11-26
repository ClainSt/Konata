import 'dart:convert';
import 'dart:io';

import 'package:engine_scraping/engine_scraping.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/test_helpers.dart';

http.Response _jsonResponse(Object data, [int statusCode = 200]) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(data)),
    statusCode,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

void main() {
  group('ScrapeOrchestrator 端到端四段漏斗测试', () {
    late Directory tempRoot;
    late StorageScrapeRepository repo;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('konata_e2e_');
      repo = openTestScrapeDatabase().repository;
    });

    tearDown(() async {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    Future<void> touchFile(String relPath, [String content = '']) async {
      final file = File(p.joinAll([tempRoot.path, ...relPath.split('/')]));
      await file.parent.create(recursive: true);
      await file.writeAsString(content);
    }

    test('多压制组同集归并 + 外挂字幕 + NCOP特典 + CD/CUE保留 + 歧义Top5 + 人工锁定与目录写回', () async {
      // 1. 构造真实 BDRip 目录树：
      //    作品 A：葬送的芙莉莲 (双压制组 01 话 + 外挂 .ass + NCOP + CD/.cue)
      //    作品 B：Ambiguous Anime (故意返回两个极其接近的候选，触发 needsReview)
      await touchFile(
        'Frieren (2023)/[VCB-Studio] Frieren S01E01 [Ma10p_1080p][x265_flac].mkv',
      );
      await touchFile(
        'Frieren (2023)/[VCB-Studio] Frieren S01E01 [Ma10p_1080p][x265_flac].sc.ass',
      );
      await touchFile('Frieren (2023)/[ANK-Raws] Frieren S01E01 [1080p].mkv');
      await touchFile('Frieren (2023)/Extras/[VCB-Studio] Frieren [NCOP].mkv');
      await touchFile('Frieren (2023)/CD/OST.cue', 'TITLE "Frieren OST"');
      await touchFile('Ambiguous Show/Ambiguous Show - 01.mkv');

      const source = MediaSource(
        id: 'local-src-1',
        kind: MediaSourceKind.local,
        label: '本地测试盘',
        location: '',
      );
      final actualSource = MediaSource(
        id: source.id,
        kind: source.kind,
        label: source.label,
        location: tempRoot.path,
      );
      await repo.upsertMediaSource(actualSource);

      final mockClient = MockClient((request) async {
        final path = request.url.path;
        final query = request.url.queryParameters['query'] ?? '';
        if (path.endsWith('/search/tv')) {
          if (query.toLowerCase().contains('frieren')) {
            return _jsonResponse({
              'results': [
                {
                  'id': 209867,
                  'name': '葬送的芙莉莲',
                  'original_name': '葬送のフリーレン',
                  'first_air_date': '2023-09-29',
                },
              ],
            });
          }
          return _jsonResponse({
            'results': [
              {
                'id': 5001,
                'name': 'Ambiguous Show Alpha',
                'first_air_date': '2020-01-01',
              },
              {
                'id': 5002,
                'name': 'Ambiguous Show Beta',
                'first_air_date': '2021-01-01',
              },
            ],
          });
        }
        if (path.endsWith('/search/movie')) {
          return _jsonResponse({'results': <Map<String, Object?>>[]});
        }
        if (path.endsWith('/tv/209867')) {
          return _jsonResponse({
            'id': 209867,
            'name': '葬送的芙莉莲',
            'original_name': '葬送のフリーレン',
            'first_air_date': '2023-09-29',
            'alternative_titles': {
              'results': [
                {'title': 'Frieren'},
              ],
            },
            'seasons': [
              {
                'season_number': 1,
                'name': 'Season 1',
                'episode_count': 1,
                'air_date': '2023-09-29',
              },
            ],
          });
        }
        if (path.endsWith('/tv/209867/season/1')) {
          return _jsonResponse({
            'episodes': [
              {'episode_number': 1, 'name': '冒险的终点'},
            ],
          });
        }
        if (path.endsWith('/tv/5001')) {
          return _jsonResponse({'id': 5001, 'name': 'Ambiguous Show Alpha'});
        }
        if (path.endsWith('/tv/5002')) {
          return _jsonResponse({'id': 5002, 'name': 'Ambiguous Show Beta'});
        }
        if (path.endsWith('/tv/5001/season/1')) {
          return _jsonResponse({
            'episodes': [
              {'episode_number': 1, 'name': '手动确认第一话'},
            ],
          });
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
        gatewayBuilder: (s) async =>
            TestLocalSourceGateway(rootPath: s.location),
        computeWorker: const ScrapeComputeWorker(useIsolate: false),
      );

      final summary = await orchestrator.scanAndScrapeSource(actualSource);
      expect(summary.totalWorks, 2);
      expect(summary.matchedWorks, 1);

      final works = await repo.getAllWorks();
      final frieren = works.firstWhere((w) => w.tmdbId == 209867);
      expect(frieren.scrapeStatus, ScrapeStatus.matched);

      // 验证多压制组同一集归并到唯一 S01E01，外加 NCOP 特典
      final episodes = await repo.getEpisodesByWork(frieren.id);
      final mainEp1 = episodes
          .where((e) => e.category == EpisodeCategory.main)
          .toList();
      final extras = episodes
          .where((e) => e.category == EpisodeCategory.extra)
          .toList();
      expect(mainEp1, hasLength(1));
      expect(mainEp1.single.title, '冒险的终点');
      expect(extras, hasLength(1));
      expect(extras.single.extraType, ExtraKind.ncop);

      // 验证 2 个不同压制组视频共用同一个 episodeId，外挂字幕挂载正确，CD/CUE 被保留为 cdAlbum
      final variants = await repo.getVariantsByWork(frieren.id);
      final ep1Variants = variants
          .where((v) => v.episodeId == mainEp1.single.id)
          .toList();
      expect(ep1Variants, hasLength(2));
      final vcbVariant = ep1Variants.firstWhere(
        (v) => v.releaseGroup == 'VCB-Studio',
      );
      expect(
        vcbVariant.externalSubtitles,
        contains(
          'Frieren (2023)/[VCB-Studio] Frieren S01E01 [Ma10p_1080p][x265_flac].sc.ass',
        ),
      );
      final cdVariants = variants
          .where((v) => v.assetKind == AssetKind.cdAlbum)
          .toList();
      expect(cdVariants, hasLength(1));

      // 验证歧义作品保存候选且可人工绑定只更新索引并保留原始路径，二次扫描锁定保护
      final ambiguous = works.firstWhere((w) => w.tmdbId != 209867);
      expect(
        ambiguous.scrapeStatus,
        anyOf(ScrapeStatus.needsReview, ScrapeStatus.unmatched),
      );
      final savedCandidates = await repo.getScrapeCandidates(ambiguous.id);
      expect(savedCandidates, isNotEmpty);

      final beforePaths = (await repo.getVariantsByWork(
        ambiguous.id,
      )).map((v) => v.relativePath).toSet();
      final rebound = await orchestrator.rebindWorkToTmdb(
        ambiguous.id,
        5001,
        TmdbMediaType.tv,
      );
      expect(rebound.isManualLocked, isTrue);
      expect(rebound.tmdbId, 5001);
      expect(await repo.getScrapeCandidates(ambiguous.id), isEmpty);
      expect(
        Directory(p.join(tempRoot.path, 'Ambiguous Show')).existsSync(),
        isTrue,
      );
      expect(
        Directory(
          p.join(tempRoot.path, 'Ambiguous Show [tmdbid=5001]'),
        ).existsSync(),
        isFalse,
      );
      expect(
        (await repo.getVariantsByWork(
          ambiguous.id,
        )).map((v) => v.relativePath).toSet(),
        beforePaths,
      );
      for (final path in beforePaths) {
        expect(File(p.join(tempRoot.path, path)).existsSync(), isTrue);
      }
      // 二次扫描时 isManualLocked 必须保护人工纠错结果不被覆盖
      await orchestrator.scanAndScrapeSource(actualSource);
      final lockedWork = await repo.findWorkById(ambiguous.id);
      expect(lockedWork?.tmdbId, 5001);
      expect(lockedWork?.isManualLocked, isTrue);
    });

    test('局部 scanRoots 重扫无变更时仅检查目标目录前缀，绝不将范围外老变体误判失联', () async {
      await touchFile('Frieren (2023)/[VCB-Studio] Frieren S01E01.mkv');
      await touchFile('OtherAnime (2022)/[VCB-Studio] OtherAnime S01E01.mkv');

      final actualSource = MediaSource(
        id: 'local-scoped-1',
        kind: MediaSourceKind.local,
        label: '本地局部测试',
        location: tempRoot.path,
      );
      await repo.upsertMediaSource(actualSource);

      var tmdbHits = 0;
      final mockClient = MockClient((request) async {
        tmdbHits++;
        final path = request.url.path;
        final query = (request.url.queryParameters['query'] ?? '')
            .toLowerCase();
        if (path.endsWith('/search/tv')) {
          if (query.contains('frieren')) {
            return _jsonResponse({
              'results': [
                {
                  'id': 209867,
                  'name': '葬送的芙莉莲',
                  'first_air_date': '2023-09-29',
                },
              ],
            });
          }
          return _jsonResponse({
            'results': [
              {
                'id': 300001,
                'name': 'OtherAnime',
                'first_air_date': '2022-04-01',
              },
            ],
          });
        }
        if (path.endsWith('/search/movie')) {
          return _jsonResponse({'results': <Map<String, Object?>>[]});
        }
        if (path.endsWith('/tv/209867')) {
          return _jsonResponse({
            'id': 209867,
            'name': '葬送的芙莉莲',
            'original_name': '葬送のフリーレン',
            'first_air_date': '2023-09-29',
            'alternative_titles': {
              'results': [
                {'title': 'Frieren'},
              ],
            },
            'seasons': [
              {'season_number': 1, 'name': 'Season 1', 'episode_count': 1},
            ],
          });
        }
        if (path.endsWith('/tv/209867/season/1')) {
          return _jsonResponse({
            'episodes': [
              {'episode_number': 1, 'name': '第一话'},
            ],
          });
        }
        if (path.endsWith('/tv/300001')) {
          return _jsonResponse({
            'id': 300001,
            'name': 'OtherAnime',
            'first_air_date': '2022-04-01',
            'seasons': [
              {'season_number': 1, 'name': 'Season 1', 'episode_count': 1},
            ],
          });
        }
        if (path.endsWith('/tv/300001/season/1')) {
          return _jsonResponse({
            'episodes': [
              {'episode_number': 1, 'name': 'EP 1'},
            ],
          });
        }
        return http.Response('{}', 404);
      });

      final countingRepo = _CountingSeriesRepo(repo);
      final orchestrator = ScrapeOrchestrator(
        repository: countingRepo,
        tmdbService: TmdbService(
          httpClient: TmdbHttpClient(
            config: const TmdbNetworkConfig(credential: 'v3_test'),
            scheduler: PriorityHttpScheduler(),
            httpClient: mockClient,
          ),
        ),
        gatewayBuilder: (s) async =>
            TestLocalSourceGateway(rootPath: s.location),
        computeWorker: const ScrapeComputeWorker(useIsolate: false),
      );

      await orchestrator.scanAndScrapeSource(actualSource);
      final initialWorks = await repo.getAllWorks();
      expect(initialWorks.length, 2);
      expect(
        initialWorks.every((w) => w.scrapeStatus == ScrapeStatus.matched),
        isTrue,
      );

      tmdbHits = 0;
      countingRepo.getAllSeriesGroupsCalls = 0;
      await orchestrator.scanAndScrapeSource(
        actualSource,
        scanRootsOverride: const ['Frieren (2023)'],
      );
      expect(tmdbHits, 0, reason: '未变更局部重扫必须零在线请求快跳');
      expect(
        countingRepo.getAllSeriesGroupsCalls,
        0,
        reason: '范围外 WorkB 老变体绝不可触发多余的全库 SeriesAutoLinker.reconcileAll',
      );
      expect((await repo.getAllWorks()).length, 2);
    });
  });
}

class _CountingSeriesRepo implements LibraryRepository {
  _CountingSeriesRepo(this._inner);

  final StorageScrapeRepository _inner;
  int getAllSeriesGroupsCalls = 0;

  @override
  Future<List<SeriesGroup>> getAllSeriesGroups() {
    getAllSeriesGroupsCalls++;
    return _inner.getAllSeriesGroups();
  }

  @override
  Future<void> addIgnoredFolder(String sourceId, String relativePath) =>
      _inner.addIgnoredFolder(sourceId, relativePath);

  @override
  Future<void> clearPlaybackHistory() => _inner.clearPlaybackHistory();

  @override
  Future<void> clearScrapeCandidates(String workId) =>
      _inner.clearScrapeCandidates(workId);

  @override
  Future<void> deleteMediaSource(String sourceId) =>
      _inner.deleteMediaSource(sourceId);

  @override
  Future<void> deleteMediaVariantsBatch(List<String> variantIds) =>
      _inner.deleteMediaVariantsBatch(variantIds);

  @override
  Future<void> deleteOrphanEpisodes(String workId) =>
      _inner.deleteOrphanEpisodes(workId);

  @override
  Future<void> deletePlaybackRecord(String recordId) =>
      _inner.deletePlaybackRecord(recordId);

  @override
  Future<void> deleteSeriesGroup(String seriesId) =>
      _inner.deleteSeriesGroup(seriesId);

  @override
  Future<void> deleteWork(String workId) => _inner.deleteWork(workId);

  @override
  Future<SeriesGroup?> findSeriesGroupById(String seriesId) =>
      _inner.findSeriesGroupById(seriesId);

  @override
  Future<MediaSource?> findSourceById(String sourceId) =>
      _inner.findSourceById(sourceId);

  @override
  Future<Work?> findWorkById(String workId) => _inner.findWorkById(workId);

  @override
  Future<List<Episode>> getAllEpisodes() => _inner.getAllEpisodes();

  @override
  Future<List<MediaVariant>> getAllVariants() => _inner.getAllVariants();

  @override
  Future<List<Work>> getAllWorks() => _inner.getAllWorks();

  @override
  Future<List<Episode>> getEpisodesByWork(String workId) =>
      _inner.getEpisodesByWork(workId);

  @override
  Future<List<Episode>> getEpisodesByWorkIds(List<String> workIds) =>
      _inner.getEpisodesByWorkIds(workIds);

  @override
  Future<List<String>> getIgnoredFolders(String sourceId) =>
      _inner.getIgnoredFolders(sourceId);

  @override
  Future<PlaybackRecord?> getLatestPlaybackForWork(String workId) =>
      _inner.getLatestPlaybackForWork(workId);

  @override
  Future<List<MediaSource>> getMediaSources() => _inner.getMediaSources();

  @override
  Future<List<PlaybackRecord>> getPlaybackHistory({int limit = 100}) =>
      _inner.getPlaybackHistory(limit: limit);

  @override
  Future<List<PlaybackRecord>> getPlaybacksByWork(String workId) =>
      _inner.getPlaybacksByWork(workId);

  @override
  Future<List<ScrapeCandidateSummary>> getScrapeCandidates(String workId) =>
      _inner.getScrapeCandidates(workId);

  @override
  Future<List<MediaVariant>> getVariantsBySource(String sourceId) =>
      _inner.getVariantsBySource(sourceId);

  @override
  Future<List<MediaVariant>> getVariantsByWork(String workId) =>
      _inner.getVariantsByWork(workId);

  @override
  Future<List<MediaVariant>> getVariantsByWorkIds(List<String> workIds) =>
      _inner.getVariantsByWorkIds(workIds);

  @override
  Future<List<Work>> getWorksBySeries(String seriesId) =>
      _inner.getWorksBySeries(seriesId);

  @override
  Future<void> pruneStaleSourceEntries({
    required String sourceId,
    required Set<String> activeWorkIds,
    required Set<String> activeVariantIds,
    List<String> scopedRoots = const [],
  }) => _inner.pruneStaleSourceEntries(
    sourceId: sourceId,
    activeWorkIds: activeWorkIds,
    activeVariantIds: activeVariantIds,
    scopedRoots: scopedRoots,
  );

  @override
  Future<void> recordPlayback(PlaybackRecord record) =>
      _inner.recordPlayback(record);

  @override
  Future<void> removeIgnoredFolder(String sourceId, String relativePath) =>
      _inner.removeIgnoredFolder(sourceId, relativePath);

  @override
  Future<T> runInTransaction<T>(Future<T> Function() action) =>
      _inner.runInTransaction(action);

  @override
  Future<void> saveScrapeCandidates(
    String workId,
    List<ScrapeCandidateSummary> candidates,
  ) => _inner.saveScrapeCandidates(workId, candidates);

  @override
  Future<void> upsertEpisode(Episode episode) => _inner.upsertEpisode(episode);

  @override
  Future<void> upsertEpisodesBatch(List<Episode> episodes) =>
      _inner.upsertEpisodesBatch(episodes);

  @override
  Future<void> upsertMediaSource(MediaSource source) =>
      _inner.upsertMediaSource(source);

  @override
  Future<void> upsertMediaVariant(MediaVariant variant) =>
      _inner.upsertMediaVariant(variant);

  @override
  Future<void> upsertMediaVariantsBatch(List<MediaVariant> variants) =>
      _inner.upsertMediaVariantsBatch(variants);

  @override
  Future<void> upsertSeriesGroup(SeriesGroup group) =>
      _inner.upsertSeriesGroup(group);

  @override
  Future<void> upsertWork(Work work) => _inner.upsertWork(work);
}
