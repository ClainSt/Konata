import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:konata/application/scraping/hard_work_rescue_engine.dart';
import 'package:konata/application/scraping/scrape_candidate_fetcher.dart';
import 'package:konata/application/scraping/scrape_compute_worker.dart';
import 'package:konata/application/scraping/scrape_orchestrator.dart';
import 'package:konata/application/scraping/scrape_progress.dart';
import 'package:konata/application/scraping/scrape_progress_tracker.dart';
import 'package:konata/domain/matching/directory_grouper.dart';
import 'package:konata/domain/matching/work_matcher.dart';
import 'package:konata/domain/models/media_source.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/models/network_config.dart';
import 'package:konata/domain/models/tmdb_models.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/domain/scraping/directory_analyzer.dart';
import 'package:konata/domain/scraping/match_difficulty_classifier.dart';
import 'package:konata/domain/scraping/scrape_domain_adapter.dart';
import 'package:konata/infrastructure/database/drift_library_repository.dart';
import 'package:konata/infrastructure/database/konata_database.dart';
import 'package:konata/infrastructure/network/priority_http_scheduler.dart';
import 'package:konata/infrastructure/network/tmdb_http_client.dart';
import 'package:konata/infrastructure/network/tmdb_service.dart';
import 'package:konata/infrastructure/sources/local_source_gateway.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

http.Response _jsonResponse(Object data, [int statusCode = 200]) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(data)),
    statusCode,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

GroupedWorkFolder _makeFolder({
  required String path,
  required String folderName,
  required String cleanTitle,
  int? explicitTmdbId,
  TmdbMediaType? explicitMediaType,
  int? explicitBangumiId,
  bool ignoreExplicitTmdb = false,
  int? year,
  int? fileYear,
  int? seasonHint,
  List<int> mainEpisodes = const [1, 2, 3],
  bool isMovieHint = false,
  bool isSplitCluster = false,
  WorkShape shape = WorkShape.series,
  List<String> titleHints = const [],
  List<String> fileHints = const [],
  bool folderMovieMarker = false,
  bool fileMovieMarker = false,
}) {
  final inv = DirectoryInventory.synthetic(
    folder: path,
    title: cleanTitle,
    year: year,
    fileYear: fileYear,
    tmdbId: explicitTmdbId,
    tmdbType: explicitMediaType?.name,
    bangumiId: explicitBangumiId,
    season: seasonHint,
    folderMovieMarker: folderMovieMarker,
    fileMovieMarker: fileMovieMarker,
    main: const [],
    extras: const [],
    shape: shape,
    titleHints: titleHints.isEmpty ? [cleanTitle] : titleHints,
    fileHints: fileHints,
  );
  final raw = GroupedWorkFolder(
    folderRelativePath: path,
    folderName: folderName,
    cleanTitle: cleanTitle,
    explicitTmdbId: explicitTmdbId,
    explicitMediaType: explicitMediaType,
    year: year,
    seasonHint: seasonHint,
    mainEpisodeNumbers: mainEpisodes,
    isMovieHint: isMovieHint,
    variants: const [],
    inventory: inv,
    isSplitCluster: isSplitCluster,
    titleHints: titleHints.isEmpty ? [cleanTitle] : titleHints,
    fileHints: fileHints,
    ignoreExplicitTmdb: ignoreExplicitTmdb,
  );
  return raw.withMatchDifficulty(MatchDifficultyClassifier.classify(raw));
}

void main() {
  group('MatchDifficultyClassifier 零开销三级难度分级与稳定排程', () {
    test('显式 ID 判为简单、规范无 ID 判为中等、乱目录/拆簇/合集/冲突/噪声判为困难', () {
      final easyTmdb = _makeFolder(
        path: '葬送的芙莉莲 (2023) {tmdb-209867}',
        folderName: '葬送的芙莉莲 (2023) {tmdb-209867}',
        cleanTitle: '葬送的芙莉莲',
        explicitTmdbId: 209867,
        year: 2023,
      );
      final easyBgm = _makeFolder(
        path: '孤独摇滚 {bgm-328609}',
        folderName: '孤独摇滚 {bgm-328609}',
        cleanTitle: '孤独摇滚',
        explicitBangumiId: 328609,
      );
      final mediumNormal = _makeFolder(
        path: '葬送的芙莉莲 (2023)',
        folderName: '葬送的芙莉莲 (2023)',
        cleanTitle: '葬送的芙莉莲',
        year: 2023,
      );
      final hardAnthologyWithId = _makeFolder(
        path: '合集 {tmdb-1000}',
        folderName: '合集 {tmdb-1000}',
        cleanTitle: '合集',
        explicitTmdbId: 1000,
        shape: WorkShape.anthology,
      );
      final hardSplit = _makeFolder(
        path: '混放::1',
        folderName: '混放',
        cleanTitle: '星之梦剧场版',
        isSplitCluster: true,
      );
      final hardMessy = _makeFolder(
        path: 'Downloads',
        folderName: 'Downloads',
        cleanTitle: '葬送的芙莉莲',
        fileHints: const ['葬送的芙莉莲'],
      );
      final hardYearConflict = _makeFolder(
        path: '钢之炼金术师 (2003)',
        folderName: '钢之炼金术师 (2003)',
        cleanTitle: '钢之炼金术师',
        year: 2003,
        fileYear: 2009,
      );
      final hardNoise = _makeFolder(
        path: '最游记外传 SP00',
        folderName: '最游记外传 SP00',
        cleanTitle: '最游记外传 SP00',
      );
      final hardShortLatin = _makeFolder(
        path: 'K-ON',
        folderName: 'K-ON',
        cleanTitle: 'K-ON',
      );

      expect(easyTmdb.matchDifficulty, MatchDifficulty.easy);
      expect(easyBgm.matchDifficulty, MatchDifficulty.easy);
      expect(mediumNormal.matchDifficulty, MatchDifficulty.medium);
      expect(hardAnthologyWithId.matchDifficulty, MatchDifficulty.hard);
      expect(hardSplit.matchDifficulty, MatchDifficulty.hard);
      expect(hardMessy.matchDifficulty, MatchDifficulty.hard);
      expect(hardYearConflict.matchDifficulty, MatchDifficulty.hard);
      expect(hardNoise.matchDifficulty, MatchDifficulty.hard);
      expect(hardShortLatin.matchDifficulty, MatchDifficulty.hard);

      // 撤销显式 TMDB ID 后应自动重新归类为中等。
      final stripped = easyTmdb.withoutExplicitTmdb();
      expect(stripped.matchDifficulty, MatchDifficulty.medium);
    });

    test('sortByDifficulty 按 简单→中等→困难 稳定排序且同档保序，countByDifficulty 精确计数', () {
      final h1 = _makeFolder(
        path: 'H1',
        folderName: 'Downloads',
        cleanTitle: 'H1',
      );
      final m1 = _makeFolder(
        path: 'M1',
        folderName: '轻音少女第一季 (2009)',
        cleanTitle: '轻音少女第一季',
        year: 2009,
      );
      final e1 = _makeFolder(
        path: 'E1',
        folderName: '轻音少女 {tmdb-1}',
        cleanTitle: '轻音少女',
        explicitTmdbId: 1,
      );
      final h2 = _makeFolder(
        path: 'H2',
        folderName: 'Pretty Rhythm Club 10bit',
        cleanTitle: 'Pretty Rhythm Club 10bit',
      );
      final m2 = _makeFolder(
        path: 'M2',
        folderName: '紫罗兰永恒花园 (2018)',
        cleanTitle: '紫罗兰永恒花园',
        year: 2018,
      );
      final e2 = _makeFolder(
        path: 'E2',
        folderName: '孤独摇滚 {tmdb-2}',
        cleanTitle: '孤独摇滚',
        explicitTmdbId: 2,
      );

      final sorted = MatchDifficultyClassifier.sortByDifficulty([
        h1,
        m1,
        e1,
        h2,
        m2,
        e2,
      ]);
      expect(sorted.map((e) => e.folderRelativePath).toList(), [
        'E1',
        'E2',
        'M1',
        'M2',
        'H1',
        'H2',
      ]);
      final counts = MatchDifficultyClassifier.countByDifficulty(sorted);
      expect(counts, (easy: 2, medium: 2, hard: 2));
    });
  });

  group('HardWorkRescueEngine 第二套困难目录专属规则与防误绑门禁', () {
    test('buildRescuedFolder 剥离 SP00/10bit/テレビアニメ 噪声，不以更长罗马音篡位中文主名', () {
      final saiyuki = _makeFolder(
        path: '最游记系列/最游记外传 SP00',
        folderName: '最游记外传 SP00',
        cleanTitle: '最游记外传 SP00',
        isMovieHint: true,
        mainEpisodes: const [1],
        fileHints: const ['Saiyuki Gaiden'],
      );
      final built = HardWorkRescueEngine.buildRescuedFolder(saiyuki);
      expect(built.changed, isTrue);
      expect(built.folder.cleanTitle, '最游记外传');
      expect(built.folder.isMovieHint, isFalse);
      expect(built.folder.seasonHint, 0);

      // 纯载体文件名（Movie Edition）严禁接管主标题。
      final carrier = _makeFolder(
        path: '锁链战记::1',
        folderName: '锁链战记',
        cleanTitle: '锁链战记 系列',
        fileHints: const ['Movie Edition'],
      );
      final builtCarrier = HardWorkRescueEngine.buildRescuedFolder(carrier);
      expect(builtCarrier.folder.cleanTitle, '锁链战记');
    });

    test('第二套规则安全救援噪声目录，同时严格拦住テレビアニメ误绑剧场版与无条目同人错绑', () async {
      final mockClient = MockClient((request) async {
        final path = request.url.path;
        final query = request.url.queryParameters['query'] ?? '';
        if (path.endsWith('/search/tv')) {
          if (query.contains('星海奇谭')) {
            return _jsonResponse({
              'results': [
                {
                  'id': 88001,
                  'name': '星海奇谭',
                  'original_name': '星海奇譚',
                  'first_air_date': '2021-04-01',
                  'genre_ids': [16],
                  'vote_count': 120,
                },
              ],
            });
          }
          if (query.contains('少女波子汽水')) {
            return _jsonResponse({
              'results': [
                {
                  'id': 88002,
                  'name': '弹珠汽水瓶里的千岁同学',
                  'original_name': '千歳くんはラムネ瓶のなか',
                  'first_air_date': '2025-10-01',
                  'genre_ids': [16],
                  'vote_count': 80,
                },
              ],
            });
          }
          return _jsonResponse({'results': []});
        }
        if (path.endsWith('/search/movie')) {
          if (query.contains('CLANNAD')) {
            return _jsonResponse({
              'results': [
                {
                  'id': 16516,
                  'title': 'CLANNAD',
                  'original_title': '劇場版 CLANNAD',
                  'release_date': '2007-09-15',
                  'genre_ids': [16],
                  'vote_count': 240,
                },
              ],
            });
          }
          return _jsonResponse({'results': []});
        }
        if (path.endsWith('/tv/88001')) {
          return _jsonResponse({
            'id': 88001,
            'name': '星海奇谭',
            'original_name': '星海奇譚',
            'first_air_date': '2021-04-01',
            'genres': [
              {'id': 16, 'name': '动画'},
            ],
            'vote_count': 120,
            'seasons': [
              {
                'season_number': 0,
                'name': '特别篇',
                'episode_count': 2,
                'air_date': '2021-07-01',
              },
              {
                'season_number': 1,
                'name': '第 1 季',
                'episode_count': 12,
                'air_date': '2021-04-01',
              },
            ],
          });
        }
        if (path.endsWith('/tv/88002')) {
          return _jsonResponse({
            'id': 88002,
            'name': '弹珠汽水瓶里的千岁同学',
            'original_name': '千歳くんはラムネ瓶のなか',
            'first_air_date': '2025-10-01',
            'genres': [
              {'id': 16, 'name': '动画'},
            ],
            'vote_count': 80,
            'seasons': [
              {'season_number': 1, 'name': '第 1 季', 'episode_count': 12},
            ],
          });
        }
        if (path.endsWith('/movie/16516')) {
          return _jsonResponse({
            'id': 16516,
            'title': 'CLANNAD',
            'original_title': '劇場版 CLANNAD',
            'release_date': '2007-09-15',
            'genres': [
              {'id': 16, 'name': '动画'},
            ],
            'vote_count': 240,
          });
        }
        return http.Response('{}', 404);
      });

      final tmdbService = TmdbService(
        httpClient: TmdbHttpClient(
          config: const TmdbNetworkConfig(credential: 'v3_test'),
          scheduler: PriorityHttpScheduler(),
          httpClient: mockClient,
        ),
      );
      final engine = HardWorkRescueEngine(
        fetcher: ScrapeCandidateFetcher(tmdbService),
      );
      const worker = ScrapeComputeWorker(useIsolate: false);

      // 场景 1：真实归组产出的噪声目录「星海奇谭 SP00 10bit」（目录与文件名均含整理噪声），
      // 首轮查询带噪声未命中 → 二轮深度剥离出全新干净片名「星海奇谭」补搜后精准自动绑定。
      final noisyFolder = ScrapeDomainAdapter.groupAndSplitFiles(
        sourceId: 'test',
        files: const [
          ScannedFileInput(
            relativePath: '星海奇谭 SP00 10bit/星海奇谭 SP00 10bit [1080p].mkv',
            fileName: '星海奇谭 SP00 10bit [1080p].mkv',
            fileSize: 800 * 1024 * 1024,
            assetKind: AssetKind.video,
          ),
        ],
      ).single;
      expect(noisyFolder.matchDifficulty, MatchDifficulty.hard);
      const emptyDecision = MatchDecision(
        level: MatchLevel.unmatched,
        topCandidates: [],
        primaryReason: 'no_candidates',
      );
      final rescued = await engine.rescue(
        originalFolder: noisyFolder,
        pass1Decision: emptyDecision,
        existingBangumi: const [],
        existingTmdb: const [],
        computeWorker: worker,
      );
      expect(rescued.adopted, isTrue);
      expect(rescued.rescuedToAutoBind, isTrue);
      expect(rescued.decision.level, MatchLevel.autoBind);
      expect(rescued.decision.best?.detail.tmdbId, 88001);
      expect(rescued.decision.best?.detail.mediaType, TmdbMediaType.tv);

      // 场景 2：原标题显式标注「テレビアニメ CLANNAD」且无剧场版标记 → 严禁误绑 movie:16516。
      final tvMarkedFolder = ScrapeDomainAdapter.groupAndSplitFiles(
        sourceId: 'test',
        files: const [
          ScannedFileInput(
            relativePath:
                'CLANNAD Extra/テレビアニメ CLANNAD/CLANNAD Special [1080p].mkv',
            fileName: 'CLANNAD Special [1080p].mkv',
            fileSize: 600 * 1024 * 1024,
            assetKind: AssetKind.video,
          ),
        ],
      ).single;
      final blockedMovie = await engine.rescue(
        originalFolder: tvMarkedFolder,
        pass1Decision: emptyDecision,
        existingBangumi: const [],
        existingTmdb: const [
          TmdbWorkDetail(
            tmdbId: 16516,
            mediaType: TmdbMediaType.movie,
            title: 'CLANNAD',
            originalTitle: '劇場版 CLANNAD',
            year: 2007,
            genreIds: [16],
            voteCount: 240,
          ),
        ],
        computeWorker: worker,
      );
      expect(blockedMovie.rescuedToAutoBind, isFalse);

      // 场景 3：无条目作品「少女波子汽水」→ 严禁被无关动画「弹珠汽水瓶里的千岁同学」误绑。
      final unindexedFolder = ScrapeDomainAdapter.groupAndSplitFiles(
        sourceId: 'test',
        files: const [
          ScannedFileInput(
            relativePath: '少女波子汽水/少女波子汽水 - 01.mkv',
            fileName: '少女波子汽水 - 01.mkv',
            fileSize: 500 * 1024 * 1024,
            assetKind: AssetKind.video,
          ),
          ScannedFileInput(
            relativePath: '少女波子汽水/少女波子汽水 - 02.mkv',
            fileName: '少女波子汽水 - 02.mkv',
            fileSize: 500 * 1024 * 1024,
            assetKind: AssetKind.video,
          ),
        ],
      ).single;
      final blockedUnrelated = await engine.rescue(
        originalFolder: unindexedFolder,
        pass1Decision: emptyDecision,
        existingBangumi: const [],
        existingTmdb: const [],
        computeWorker: worker,
      );
      expect(blockedUnrelated.rescuedToAutoBind, isFalse);
      expect(blockedUnrelated.decision.level, isNot(MatchLevel.autoBind));
    });
  });

  group('ScrapeLibraryRefreshThrottler 实时展示节流器契约', () {
    test('首部匹配立即可见，高频命中合并刷新，阈值触发与销毁不泄漏', () async {
      var refreshCount = 0;
      final throttler = ScrapeLibraryRefreshThrottler(
        onRefresh: () => refreshCount++,
        interval: const Duration(milliseconds: 60),
        batchThreshold: 3,
      );

      // 首条到达即刻刷新。
      throttler.notifyMatched();
      expect(refreshCount, 1);

      // 窗口内连续 2 条暂缓并合并。
      throttler.notifyMatched();
      throttler.notifyMatched();
      expect(refreshCount, 1);

      // 第 3 条达到 batchThreshold 立即刷出。
      throttler.notifyMatched();
      expect(refreshCount, 2);

      // 单独 1 条等待尾随计时器触发。
      throttler.notifyMatched();
      expect(refreshCount, 2);
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(refreshCount, 3);

      // dispose 后挂起计时器取消且后续通知不再触发。
      throttler.notifyMatched();
      throttler.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(refreshCount, 3);
      throttler.notifyMatched();
      expect(refreshCount, 3);
    });
  });

  group('ScrapeOrchestrator 端到端三级排程 + 二轮救援 + 实时上墙契约', () {
    late Directory tempRoot;
    late KonataDatabase db;
    late DriftLibraryRepository repo;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('konata_r9_e2e_');
      db = KonataDatabase(NativeDatabase.memory());
      repo = DriftLibraryRepository(db);
    });

    tearDown(() async {
      await db.close();
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    Future<void> touchFile(String relPath) async {
      final file = File(p.joinAll([tempRoot.path, ...relPath.split('/')]));
      await file.parent.create(recursive: true);
      await file.writeAsString('');
    }

    test('严格按 简单→中等→困难 调度，简单/中等提前落库实时上墙，困难触发二轮救援，重扫快跳零无效刷新', () async {
      // 故意让字典序与难度倒挂：
      // 01 为困难噪声目录、02 为中等常规目录、03 为简单显式 TMDB ID 目录。
      await touchFile('01_星云战记 SP00 10bit/星云战记 - SP00 [1080p].mkv');
      await touchFile('02_苍穹交响曲 (2022)/苍穹交响曲 - 01 [1080p].mkv');
      await touchFile('02_苍穹交响曲 (2022)/苍穹交响曲 - 02 [1080p].mkv');
      await touchFile('03_银翼幻想 (2023) {tmdb-30001}/银翼幻想 - 01 [1080p].mkv');
      await touchFile('03_银翼幻想 (2023) {tmdb-30001}/银翼幻想 - 02 [1080p].mkv');

      final source = MediaSource(
        id: 'local-r9',
        kind: MediaSourceKind.local,
        label: '第九轮验证盘',
        location: tempRoot.path,
      );
      await repo.upsertMediaSource(source);

      // 挂起困难目录的检索响应，用以断言简单与中等在困难尚未返回前已提前入库并推送给媒体库。
      final hardGate = Completer<void>();
      final hardEntered = Completer<void>();

      final mockClient = MockClient((request) async {
        final path = request.url.path;
        final query = request.url.queryParameters['query'] ?? '';
        if (path.endsWith('/tv/30001')) {
          return _jsonResponse({
            'id': 30001,
            'name': '银翼幻想',
            'original_name': '銀翼ファンタジア',
            'first_air_date': '2023-04-01',
            'genres': [
              {'id': 16, 'name': '动画'},
            ],
            'vote_count': 200,
            'seasons': [
              {'season_number': 1, 'name': '第 1 季', 'episode_count': 2},
            ],
          });
        }
        if (path.endsWith('/tv/30001/season/1')) {
          return _jsonResponse({
            'episodes': [
              {'episode_number': 1, 'name': '第一话'},
              {'episode_number': 2, 'name': '第二话'},
            ],
          });
        }
        if (path.endsWith('/search/tv')) {
          if (query.contains('苍穹交响曲')) {
            return _jsonResponse({
              'results': [
                {
                  'id': 30002,
                  'name': '苍穹交响曲',
                  'original_name': '蒼穹シンフォニー',
                  'first_air_date': '2022-07-01',
                  'genre_ids': [16],
                  'vote_count': 180,
                },
              ],
            });
          }
          if (query.contains('星云战记')) {
            if (!hardEntered.isCompleted) hardEntered.complete();
            await hardGate.future;
            // 首轮查询含噪声词（SP00/10bit/01）不返回结果；仅二轮剥离出干净片名「星云战记」时返回。
            if (query.trim() == '星云战记') {
              return _jsonResponse({
                'results': [
                  {
                    'id': 30003,
                    'name': '星云战记',
                    'original_name': '星雲戦記',
                    'first_air_date': '2020-01-01',
                    'genre_ids': [16],
                    'vote_count': 150,
                  },
                ],
              });
            }
            return _jsonResponse({'results': []});
          }
          return _jsonResponse({'results': []});
        }
        if (path.endsWith('/search/movie')) {
          return _jsonResponse({'results': []});
        }
        if (path.endsWith('/tv/30002')) {
          return _jsonResponse({
            'id': 30002,
            'name': '苍穹交响曲',
            'original_name': '蒼穹シンフォニー',
            'first_air_date': '2022-07-01',
            'genres': [
              {'id': 16, 'name': '动画'},
            ],
            'vote_count': 180,
            'seasons': [
              {'season_number': 1, 'name': '第 1 季', 'episode_count': 2},
            ],
          });
        }
        if (path.endsWith('/tv/30002/season/1')) {
          return _jsonResponse({
            'episodes': [
              {'episode_number': 1, 'name': '序曲'},
              {'episode_number': 2, 'name': '终章'},
            ],
          });
        }
        if (path.endsWith('/tv/30003')) {
          return _jsonResponse({
            'id': 30003,
            'name': '星云战记',
            'original_name': '星雲戦記',
            'first_air_date': '2020-01-01',
            'genres': [
              {'id': 16, 'name': '动画'},
            ],
            'vote_count': 150,
            'seasons': [
              {'season_number': 0, 'name': '特别篇', 'episode_count': 1},
              {'season_number': 1, 'name': '第 1 季', 'episode_count': 12},
            ],
          });
        }
        if (path.endsWith('/tv/30003/season/0') ||
            path.endsWith('/tv/30003/season/1')) {
          return _jsonResponse({
            'episodes': [
              {'episode_number': 1, 'name': '星云特别篇'},
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
        gatewayBuilder: (s) async => LocalSourceGateway(rootPath: s.location),
        computeWorker: const ScrapeComputeWorker(useIsolate: false),
      );

      final dispatchOrder = <MatchDifficulty>[];
      final persistedEvents =
          <({String id, ScrapeStatus status, String title})>[];
      final twoEarlyPersisted = Completer<void>();
      var sawTierCounts = false;

      final scanFuture = orchestrator.scanAndScrapeSource(
        source,
        onProgress: (p) {
          if (p.phase == ScrapePhase.scraping) {
            if (p.easyWorks == 1 && p.mediumWorks == 1 && p.hardWorks == 1) {
              sawTierCounts = true;
            }
            final diff = p.currentDifficulty;
            if (diff != null &&
                p.processedWorks == 0 &&
                (dispatchOrder.isEmpty || dispatchOrder.last != diff)) {
              dispatchOrder.add(diff);
            }
          }
        },
        onWorkPersisted: (workId, status, displayTitle) {
          persistedEvents.add((
            id: workId,
            status: status,
            title: displayTitle,
          ));
          if (persistedEvents.length >= 2 && !twoEarlyPersisted.isCompleted) {
            twoEarlyPersisted.complete();
          }
        },
      );

      // 等待简单与中等目录提前落库，同时困难目录仍被 hardGate 挂起，证明实时展示不等待全量结束。
      await hardEntered.future.timeout(const Duration(seconds: 5));
      await twoEarlyPersisted.future.timeout(const Duration(seconds: 5));

      final midScanWorks = await repo.getAllWorks();
      final midMatchedTitles = midScanWorks
          .where((w) => w.scrapeStatus == ScrapeStatus.matched)
          .map((w) => w.title)
          .toSet();
      expect(midMatchedTitles, containsAll(['银翼幻想', '苍穹交响曲']));
      expect(midMatchedTitles, isNot(contains('星云战记')));

      // 放行困难目录，等待二轮救援完成。
      hardGate.complete();
      final summary = await scanFuture;

      expect(sawTierCounts, isTrue);
      expect(dispatchOrder, [
        MatchDifficulty.easy,
        MatchDifficulty.medium,
        MatchDifficulty.hard,
      ]);
      expect(summary.totalWorks, 3);
      expect(summary.matchedWorks, 3);
      expect(summary.easyWorks, 1);
      expect(summary.mediumWorks, 1);
      expect(summary.hardWorks, 1);
      expect(summary.hardRescuedWorks, 1);
      expect(persistedEvents.length, 3);
      expect(
        persistedEvents.every((e) => e.status == ScrapeStatus.matched),
        isTrue,
      );
      final allWorks = await repo.getAllWorks();
      expect(allWorks.map((w) => w.tmdbId).toSet(), {30001, 30002, 30003});
      expect(
        persistedEvents.map((e) => e.id).toSet(),
        allWorks.map((w) => w.id).toSet(),
      );

      // 第二次无变更重扫：走快跳分支，不应重复触发实时落库回调。
      final secondRunEvents = <String>[];
      final summary2 = await orchestrator.scanAndScrapeSource(
        source,
        onWorkPersisted: (workId, status, displayTitle) {
          secondRunEvents.add(displayTitle);
        },
      );
      expect(summary2.matchedWorks, 3);
      expect(secondRunEvents, isEmpty);
    });
  });
}
