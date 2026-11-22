import 'dart:convert';
import 'dart:io';

import 'package:konata/application/scraping/ongoing_work_auto_sync.dart';
import 'package:konata/application/scraping/scrape_compute_worker.dart';
import 'package:konata/application/scraping/scrape_orchestrator.dart';
import 'package:konata/domain/models/episode.dart';
import 'package:konata/domain/models/media_source.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/models/network_config.dart';
import 'package:konata/domain/models/playback_record.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/domain/repositories/file_system_gateway.dart';
import 'package:konata/infrastructure/database/drift_library_repository.dart';
import 'package:konata/infrastructure/database/konata_database.dart';
import 'package:konata/infrastructure/network/bangumi_service.dart';
import 'package:konata/infrastructure/network/priority_http_scheduler.dart';
import 'package:konata/infrastructure/network/tmdb_http_client.dart';
import 'package:konata/infrastructure/network/tmdb_service.dart';
import 'package:konata/infrastructure/sources/local_source_gateway.dart';
import 'package:konata/infrastructure/sources/source_access_error.dart';
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

class _FaultyCloudGateway implements MediaSourceGateway {
  _FaultyCloudGateway({required this.onList});

  final Future<List<RemoteEntry>> Function(String relativePath) onList;

  @override
  Future<List<RemoteEntry>> listDirectory(String relativePath) =>
      onList(relativePath);

  @override
  Future<String?> readTextFile(
    String relativePath, {
    int maxBytes = 256 * 1024,
  }) async => null;

  @override
  Future<String?> testConnection() async => null;

  @override
  Future<void> close() async {}
}

void main() {
  group('追番自动追加新集、删集自动清理与零冗余增量同步契约', () {
    late Directory tempRoot;
    late KonataDatabase db;
    late DriftLibraryRepository repo;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('konata_r12_sync_');
      db = KonataDatabase(NativeDatabase.memory());
      repo = DriftLibraryRepository(db);
    });

    tearDown(() async {
      await db.close();
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    Future<File> touchFile(String relPath, {String content = ''}) async {
      final file = File(p.joinAll([tempRoot.path, ...relPath.split('/')]));
      await file.parent.create(recursive: true);
      await file.writeAsString(content);
      return file;
    }

    MockClient buildMockApi(List<String> requestLog) {
      return MockClient((request) async {
        final host = request.url.host.toLowerCase();
        final path = request.url.path;
        requestLog.add('${request.method} $host$path');

        if (host.contains('bgm.tv')) {
          if (request.method == 'POST' &&
              path.contains('/v0/search/subjects')) {
            return _jsonResp({
              'data': [
                {
                  'id': 400602,
                  'name': '葬送のフリーレン',
                  'name_cn': '葬送的芙莉莲',
                  'date': '2023-09-29',
                  'eps': 28,
                  'platform': 'TV',
                  'images': {'large': 'https://lain.bgm.tv/pic/cover/l/fr.jpg'},
                },
              ],
            });
          }
          if (path == '/v0/subjects/400602') {
            return _jsonResp({
              'id': 400602,
              'name': '葬送のフリーレン',
              'name_cn': '葬送的芙莉莲',
              'date': '2023-09-29',
              'total_episodes': 28,
              'platform': 'TV',
              'images': {'large': 'https://lain.bgm.tv/pic/cover/l/fr.jpg'},
            });
          }
          if (path == '/v0/subjects/400602/subjects') {
            return _jsonResp([]);
          }
          if (path == '/v0/episodes') {
            return _jsonResp({'data': []});
          }
          return http.Response('not found', 404);
        }

        if (path.endsWith('/tv/209867')) {
          return _jsonResp({
            'id': 209867,
            'name': '葬送的芙莉莲',
            'original_name': '葬送のフリーレン',
            'first_air_date': '2023-09-29',
            'genres': [
              {'id': 16, 'name': '动画'},
            ],
            'vote_count': 800,
            'seasons': [
              {'season_number': 1, 'name': '第 1 季', 'episode_count': 28},
            ],
          });
        }
        if (path.endsWith('/tv/209867/season/1')) {
          return _jsonResp({
            'season_number': 1,
            'name': '第 1 季',
            'episodes': [
              {'episode_number': 1, 'name': '冒险的终点', 'still_path': '/ep1.jpg'},
              {'episode_number': 2, 'name': '没必要是魔法', 'still_path': '/ep2.jpg'},
              {'episode_number': 3, 'name': '杀人魔法', 'still_path': '/ep3.jpg'},
            ],
          });
        }
        if (path.endsWith('/search/tv') || path.endsWith('/search/movie')) {
          return _jsonResp({'results': []});
        }
        return http.Response('{}', 404);
      });
    }

    test('第一周扫第 1 集，第二周存入第 2 集自动新增（零搜索、保留进度）；删第 2 集自动清理幽灵集；删整目录安全清库', () async {
      await touchFile(
        '2026新番/葬送的芙莉莲 (2023) {tmdb-209867}/[LoliHouse] Frieren - 01 [1080p].mkv',
      );
      final source = MediaSource(
        id: 'local-r12-chase',
        kind: MediaSourceKind.local,
        label: '追番目录',
        location: tempRoot.path,
      );
      await repo.upsertMediaSource(source);

      final requestLog = <String>[];
      final httpClient = TmdbHttpClient(
        config: const TmdbNetworkConfig(credential: 'dummy_v3_key'),
        scheduler: PriorityHttpScheduler(),
        httpClient: buildMockApi(requestLog),
      );
      final orchestrator = ScrapeOrchestrator(
        repository: repo,
        tmdbService: TmdbService(httpClient: httpClient),
        bangumiService: BangumiService(httpClient: httpClient),
        gatewayBuilder: (s) async => LocalSourceGateway(rootPath: s.location),
        computeWorker: const ScrapeComputeWorker(useIsolate: false),
      );

      // 第一周首次扫描：仅入库第 1 集
      await orchestrator.scanAndScrapeSource(source);
      final worksWeek1 = await repo.getAllWorks();
      expect(worksWeek1, hasLength(1));
      final work = worksWeek1.single;
      expect(work.tmdbId, 209867);
      final epsWeek1 = await repo.getEpisodesByWork(work.id);
      expect(epsWeek1.map((e) => e.episodeNumber), [1]);
      expect(epsWeek1.single.title, '冒险的终点');

      // 模拟用户观看了第 1 集到 600 秒
      final week1Variants = await repo.getVariantsByWork(work.id);
      await repo.recordPlayback(
        PlaybackRecord(
          id: 'pb-ep1',
          workId: work.id,
          episodeId: epsWeek1.single.id,
          variantId: week1Variants.single.id,
          seasonNumber: 1,
          episodeNumber: 1,
          episodeTitle: '冒险的终点',
          positionSeconds: 600,
          durationSeconds: 1440,
          playedAt: DateTime.utc(2026, 11, 22, 12, 0),
          sourceType: MediaSourceKind.local,
        ),
      );

      // 第二周把第 2 集和外挂简中字幕放进同一目录，直接触发单作品自动同步（无需全盘重扫）
      await touchFile(
        '2026新番/葬送的芙莉莲 (2023) {tmdb-209867}/[LoliHouse] Frieren - 02 [1080p].mkv',
      );
      await touchFile(
        '2026新番/葬送的芙莉莲 (2023) {tmdb-209867}/[LoliHouse] Frieren - 02 [1080p].chs.ass',
      );

      requestLog.clear();
      final addResult = await orchestrator.syncSingleWorkDirectory(work.id);
      expect(addResult.changed, isTrue);
      expect(addResult.addedFileCount, 1);
      expect(addResult.removedFileCount, 0);
      expect(addResult.workRemoved, isFalse);

      // 增量加集快通道绝不触发任何搜索请求
      expect(requestLog.any((r) => r.contains('/search/')), isFalse);
      expect(
        requestLog.any((r) => r.contains('/subjects/400602/subjects')),
        isFalse,
      );

      final epsWeek2 = (await repo.getEpisodesByWork(work.id))
        ..sort(
          (a, b) => (a.episodeNumber ?? 0).compareTo(b.episodeNumber ?? 0),
        );
      expect(epsWeek2.map((e) => e.episodeNumber), [1, 2]);
      expect(epsWeek2[1].title, '没必要是魔法');

      final variantsWeek2 = await repo.getVariantsByWork(work.id);
      final ep2Variant = variantsWeek2.firstWhere(
        (v) => v.fileName.contains('02'),
      );
      expect(ep2Variant.externalSubtitles, hasLength(1));
      expect(ep2Variant.externalSubtitles.single, endsWith('.chs.ass'));

      // 第 1 集播放进度 100% 保留
      final savedPb = await repo.getPlaybacksByWork(work.id);
      expect(savedPb.single.positionSeconds, 600);

      // 无文件变化再次同步：零变更、零网络请求
      requestLog.clear();
      final noop = await orchestrator.syncSingleWorkDirectory(work.id);
      expect(noop.changed, isFalse);
      expect(requestLog, isEmpty);

      // 用户把源目录的第 2 集删除后，自动清理变体与第 2 集幽灵剧集（零外部 API 请求）
      final ep2File = File(
        p.join(
          tempRoot.path,
          '2026新番',
          '葬送的芙莉莲 (2023) {tmdb-209867}',
          '[LoliHouse] Frieren - 02 [1080p].mkv',
        ),
      );
      await ep2File.delete();

      requestLog.clear();
      final delResult = await orchestrator.syncSingleWorkDirectory(work.id);
      expect(delResult.changed, isTrue);
      expect(delResult.removedFileCount, 1);
      expect(delResult.workRemoved, isFalse);
      expect(requestLog, isEmpty);

      final epsAfterDel = await repo.getEpisodesByWork(work.id);
      expect(epsAfterDel.map((e) => e.episodeNumber), [1]);

      // 用户把整部作品目录删掉（而父目录 2026新番 仍存在可达）→ 自动清掉空作品卡片
      final workDir = Directory(
        p.join(tempRoot.path, '2026新番', '葬送的芙莉莲 (2023) {tmdb-209867}'),
      );
      await workDir.delete(recursive: true);

      final removeWorkResult = await orchestrator.syncSingleWorkDirectory(
        work.id,
      );
      expect(removeWorkResult.changed, isTrue);
      expect(removeWorkResult.workRemoved, isTrue);
      expect(await repo.findWorkById(work.id), isNull);
      expect(await repo.getEpisodesByWork(work.id), isEmpty);
    });

    test('多版本洗版单集仅删一个压制组文件时，仅移除该变体而保留该逻辑剧集', () async {
      await touchFile(
        '动画/葬送的芙莉莲 (2023) {tmdb-209867}/[VCB-Studio] Frieren [01].mkv',
      );
      await touchFile(
        '动画/葬送的芙莉莲 (2023) {tmdb-209867}/[LoliHouse] Frieren - 01.mkv',
      );
      final source = MediaSource(
        id: 'local-r12-multi',
        kind: MediaSourceKind.local,
        label: '洗版目录',
        location: tempRoot.path,
      );
      await repo.upsertMediaSource(source);

      final httpClient = TmdbHttpClient(
        config: const TmdbNetworkConfig(credential: 'dummy_v3_key'),
        scheduler: PriorityHttpScheduler(),
        httpClient: buildMockApi(<String>[]),
      );
      final orchestrator = ScrapeOrchestrator(
        repository: repo,
        tmdbService: TmdbService(httpClient: httpClient),
        gatewayBuilder: (s) async => LocalSourceGateway(rootPath: s.location),
        computeWorker: const ScrapeComputeWorker(useIsolate: false),
      );

      await orchestrator.scanAndScrapeSource(source);
      final work = (await repo.getAllWorks()).single;
      expect(await repo.getVariantsByWork(work.id), hasLength(2));

      // 只删除 LoliHouse 版本，保留 VCB-Studio 版本
      await File(
        p.join(
          tempRoot.path,
          '动画',
          '葬送的芙莉莲 (2023) {tmdb-209867}',
          '[LoliHouse] Frieren - 01.mkv',
        ),
      ).delete();

      final res = await orchestrator.syncSingleWorkDirectory(work.id);
      expect(res.changed, isTrue);
      expect(res.removedFileCount, 1);
      expect(res.workRemoved, isFalse);
      final remainVariants = await repo.getVariantsByWork(work.id);
      expect(remainVariants, hasLength(1));
      expect(remainVariants.single.fileName, contains('VCB-Studio'));
      final remainEps = await repo.getEpisodesByWork(work.id);
      expect(remainEps.map((e) => e.episodeNumber), [1]);
    });

    test('网盘限流 429、断网或盘符未挂载（父目录也不可达）时严格跳过，绝不误删库内剧集与作品', () async {
      await touchFile(
        '云盘库/葬送的芙莉莲 (2023) {tmdb-209867}/[LoliHouse] Frieren - 01.mkv',
      );
      final source = MediaSource(
        id: 'webdav-r12-safe',
        kind: MediaSourceKind.webdav,
        label: '光鸭 CD2',
        location: 'http://127.0.0.1:19798/dav/anime',
      );
      await repo.upsertMediaSource(source);

      final httpClient = TmdbHttpClient(
        config: const TmdbNetworkConfig(credential: 'dummy_v3_key'),
        scheduler: PriorityHttpScheduler(),
        httpClient: buildMockApi(<String>[]),
      );
      // 首次用本地网关模拟完成初始入库
      final initOrchestrator = ScrapeOrchestrator(
        repository: repo,
        tmdbService: TmdbService(httpClient: httpClient),
        gatewayBuilder: (_) async =>
            LocalSourceGateway(rootPath: tempRoot.path),
        computeWorker: const ScrapeComputeWorker(useIsolate: false),
      );
      await initOrchestrator.scanAndScrapeSource(source);
      final work = (await repo.getAllWorks()).single;

      // 场景 A：CD2 返回 429 限流
      final rateLimitOrch = ScrapeOrchestrator(
        repository: repo,
        tmdbService: TmdbService(httpClient: httpClient),
        gatewayBuilder: (_) async => _FaultyCloudGateway(
          onList: (_) async => throw const SourceRateLimitException(
            statusCode: 429,
            message: 'HTTP 429',
            retryAfter: Duration(milliseconds: 5),
          ),
        ),
        computeWorker: const ScrapeComputeWorker(useIsolate: false),
      );
      final r429 = await rateLimitOrch.syncSingleWorkDirectory(work.id);
      expect(r429.changed, isFalse);
      expect(r429.skippedDueToError, isTrue);
      expect(await repo.findWorkById(work.id), isNotNull);
      expect(await repo.getVariantsByWork(work.id), hasLength(1));

      // 场景 B：目标目录与父目录/根目录同时 404（模拟网盘未挂载/路径前缀异常）
      final unmountedOrch = ScrapeOrchestrator(
        repository: repo,
        tmdbService: TmdbService(httpClient: httpClient),
        gatewayBuilder: (_) async => _FaultyCloudGateway(
          onList: (_) async => throw const HttpException('HTTP 404'),
        ),
        computeWorker: const ScrapeComputeWorker(useIsolate: false),
      );
      final rUnmounted = await unmountedOrch.syncSingleWorkDirectory(work.id);
      expect(rUnmounted.changed, isFalse);
      expect(rUnmounted.skippedDueToError, isTrue);
      expect(await repo.findWorkById(work.id), isNotNull);
      expect(await repo.getVariantsByWork(work.id), hasLength(1));
    });

    test('全量重扫遇部分删集当轮立即清理幽灵剧集；增量加集走快通道且零冗余系列关联请求', () async {
      await touchFile(
        '新番/葬送的芙莉莲 (2023) {tmdb-209867}/[LoliHouse] Frieren - 01.mkv',
      );
      await touchFile(
        '新番/葬送的芙莉莲 (2023) {tmdb-209867}/[LoliHouse] Frieren - 02.mkv',
      );
      final source = MediaSource(
        id: 'local-r12-full',
        kind: MediaSourceKind.local,
        label: '全量回归',
        location: tempRoot.path,
      );
      await repo.upsertMediaSource(source);

      final requestLog = <String>[];
      final httpClient = TmdbHttpClient(
        config: const TmdbNetworkConfig(credential: 'dummy_v3_key'),
        scheduler: PriorityHttpScheduler(),
        httpClient: buildMockApi(requestLog),
      );
      final orchestrator = ScrapeOrchestrator(
        repository: repo,
        tmdbService: TmdbService(httpClient: httpClient),
        bangumiService: BangumiService(httpClient: httpClient),
        gatewayBuilder: (s) async => LocalSourceGateway(rootPath: s.location),
        computeWorker: const ScrapeComputeWorker(useIsolate: false),
      );

      await orchestrator.scanAndScrapeSource(source);
      final work = (await repo.getAllWorks()).single;
      expect((await repo.getEpisodesByWork(work.id)).length, 2);

      // 删掉第 2 集并全量重扫：必须在当轮立即清掉第 2 集幽灵剧集（不能残留到下一次扫描）
      await File(
        p.join(
          tempRoot.path,
          '新番',
          '葬送的芙莉莲 (2023) {tmdb-209867}',
          '[LoliHouse] Frieren - 02.mkv',
        ),
      ).delete();

      requestLog.clear();
      await orchestrator.scanAndScrapeSource(source);
      final epsAfterFullDel = await repo.getEpisodesByWork(work.id);
      expect(epsAfterFullDel.map((e) => e.episodeNumber), [1]);
      // 删除既有集数走快通道：零搜索、零 Bangumi 关联请求
      expect(requestLog.any((r) => r.contains('/search/')), isFalse);
      expect(
        requestLog.any((r) => r.contains('/v0/subjects/400602/subjects')),
        isFalse,
      );

      // 新增第 3 集再全量重扫：走增量加集快通道，零搜索且不重跑系列关联查询
      await touchFile(
        '新番/葬送的芙莉莲 (2023) {tmdb-209867}/[LoliHouse] Frieren - 03.mkv',
      );
      requestLog.clear();
      await orchestrator.scanAndScrapeSource(source);
      final epsAfterAdd3 = (await repo.getEpisodesByWork(work.id))
        ..sort(
          (a, b) => (a.episodeNumber ?? 0).compareTo(b.episodeNumber ?? 0),
        );
      expect(epsAfterAdd3.map((e) => e.episodeNumber), [1, 3]);
      expect(epsAfterAdd3.last.title, '杀人魔法');
      expect(requestLog.any((r) => r.contains('/search/')), isFalse);
      expect(
        requestLog.any((r) => r.contains('/v0/subjects/400602/subjects')),
        isFalse,
      );
    });

    test('OngoingWorkAutoSyncPlanner 优先选近期观看与连载新番并严格限额 12 部，跳过老旧完结库与隐藏作品', () {
      final now = DateTime.utc(2026, 11, 22, 12, 0);
      final works = <Work>[
        // 30 部老旧完结番（2018 年、12 集）不应被挤进巡检配额
        for (var i = 1; i <= 30; i++)
          Work(
            id: 'old_$i',
            title: '老番 $i',
            year: 2018,
            tmdbMediaType: TmdbMediaType.tv,
            scrapeStatus: ScrapeStatus.matched,
          ),
        // 近期在看的 3 部作品（即使年份较早，只要最近 30 天看过就排在最前）
        const Work(
          id: 'watching_a',
          title: '正在追 A',
          year: 2020,
          tmdbMediaType: TmdbMediaType.tv,
          scrapeStatus: ScrapeStatus.matched,
        ),
        const Work(
          id: 'watching_b',
          title: '正在追 B',
          year: 2026,
          tmdbMediaType: TmdbMediaType.tv,
          scrapeStatus: ScrapeStatus.matched,
        ),
        const Work(
          id: 'hidden_recent',
          title: '隐藏番',
          year: 2026,
          tmdbMediaType: TmdbMediaType.tv,
          isHidden: true,
          scrapeStatus: ScrapeStatus.matched,
        ),
        const Work(
          id: 'movie_recent',
          title: '新剧场版',
          year: 2026,
          tmdbMediaType: TmdbMediaType.movie,
          scrapeStatus: ScrapeStatus.matched,
        ),
        for (var i = 1; i <= 15; i++)
          Work(
            id: 'airing_$i',
            title: '2026 新番 $i',
            year: 2026,
            tmdbMediaType: TmdbMediaType.tv,
            scrapeStatus: ScrapeStatus.matched,
          ),
      ];

      final playbacks = [
        PlaybackRecord(
          id: 'p1',
          workId: 'watching_a',
          episodeId: 'ep_a1',
          variantId: 'var_a1',
          seasonNumber: 1,
          episodeNumber: 1,
          episodeTitle: '第 1 集',
          positionSeconds: 100,
          durationSeconds: 1440,
          playedAt: now.subtract(const Duration(days: 2)),
          sourceType: MediaSourceKind.webdav,
        ),
        PlaybackRecord(
          id: 'p2',
          workId: 'watching_b',
          episodeId: 'ep_b1',
          variantId: 'var_b1',
          seasonNumber: 1,
          episodeNumber: 1,
          episodeTitle: '第 1 集',
          positionSeconds: 200,
          durationSeconds: 1440,
          playedAt: now.subtract(const Duration(hours: 3)),
          sourceType: MediaSourceKind.webdav,
        ),
        PlaybackRecord(
          id: 'p_expired',
          workId: 'old_1',
          episodeId: 'ep_old1',
          variantId: 'var_old1',
          seasonNumber: 1,
          episodeNumber: 1,
          episodeTitle: '第 1 集',
          positionSeconds: 1440,
          durationSeconds: 1440,
          playedAt: now.subtract(const Duration(days: 60)),
          sourceType: MediaSourceKind.webdav,
        ),
      ];
      final epCounts = <String, int>{
        for (var i = 1; i <= 30; i++) 'old_$i': 12,
        for (var i = 1; i <= 15; i++) 'airing_$i': i <= 5 ? 3 : 12,
      };

      final selected = OngoingWorkAutoSyncPlanner.selectCandidateWorkIds(
        works: works,
        recentPlaybacks: playbacks,
        mainEpisodeCountByWorkId: epCounts,
        now: now,
      );

      expect(selected, hasLength(OngoingWorkAutoSyncConfig.maxWorksPerCycle));
      expect(selected[0], 'watching_b');
      expect(selected[1], 'watching_a');
      expect(selected, isNot(contains('hidden_recent')));
      expect(selected, isNot(contains('movie_recent')));
      expect(selected.any((id) => id.startsWith('old_')), isFalse);
      // 集数未满 12 集的新番应优先于已满 12 集的新番
      expect(
        selected.sublist(2, 7),
        containsAll([
          'airing_1',
          'airing_2',
          'airing_3',
          'airing_4',
          'airing_5',
        ]),
      );
    });

    test('共享混放目录同步仅追加归属当前作品的新集，绝不窃取同目录其他作品或无关新番', () async {
      await touchFile('混放目录/葬送的芙莉莲 - 01.mkv');
      await touchFile('混放目录/孤独摇滚 - 01.mkv');
      final source = MediaSource(
        id: 'local-r12-shared',
        kind: MediaSourceKind.local,
        label: '共享混放盘',
        location: tempRoot.path,
      );
      await repo.upsertMediaSource(source);

      // 预置同一混放目录下两部已独立入库的作品（模拟拆簇或手工分卡后的共享目录）
      const frieren = Work(
        id: 'work_frieren_shared',
        tmdbId: 209867,
        tmdbMediaType: TmdbMediaType.tv,
        matchedSeason: 1,
        title: '葬送的芙莉莲',
        originalTitle: '葬送のフリーレン',
        year: 2023,
        scrapeStatus: ScrapeStatus.matched,
      );
      const bocchi = Work(
        id: 'work_bocchi_shared',
        tmdbId: 201950,
        tmdbMediaType: TmdbMediaType.tv,
        matchedSeason: 1,
        title: '孤独摇滚！',
        originalTitle: 'ぼっち・ざ・ろっく！',
        year: 2022,
        scrapeStatus: ScrapeStatus.matched,
      );
      await repo.upsertWork(frieren);
      await repo.upsertWork(bocchi);
      await repo.upsertEpisode(
        const Episode(
          id: 'ep_fr_1',
          workId: 'work_frieren_shared',
          seasonNumber: 1,
          episodeNumber: 1,
          title: '冒险的终点',
        ),
      );
      await repo.upsertEpisode(
        const Episode(
          id: 'ep_bc_1',
          workId: 'work_bocchi_shared',
          seasonNumber: 1,
          episodeNumber: 1,
          title: '翻滚孤独',
        ),
      );
      await repo.upsertMediaVariant(
        const MediaVariant(
          id: 'var_fr_1',
          workId: 'work_frieren_shared',
          episodeId: 'ep_fr_1',
          sourceId: 'local-r12-shared',
          relativePath: '混放目录/葬送的芙莉莲 - 01.mkv',
          fileName: '葬送的芙莉莲 - 01.mkv',
          fileSize: 0,
          assetKind: AssetKind.video,
        ),
      );
      await repo.upsertMediaVariant(
        const MediaVariant(
          id: 'var_bc_1',
          workId: 'work_bocchi_shared',
          episodeId: 'ep_bc_1',
          sourceId: 'local-r12-shared',
          relativePath: '混放目录/孤独摇滚 - 01.mkv',
          fileName: '孤独摇滚 - 01.mkv',
          fileSize: 0,
          assetKind: AssetKind.video,
        ),
      );

      final httpClient = TmdbHttpClient(
        config: const TmdbNetworkConfig(credential: 'dummy_v3_key'),
        scheduler: PriorityHttpScheduler(),
        httpClient: buildMockApi(<String>[]),
      );
      final orchestrator = ScrapeOrchestrator(
        repository: repo,
        tmdbService: TmdbService(httpClient: httpClient),
        gatewayBuilder: (s) async => LocalSourceGateway(rootPath: s.location),
        computeWorker: const ScrapeComputeWorker(useIsolate: false),
      );

      // 往共享混放目录同时加入《葬送的芙莉莲》第 2 集和一部完全无关的新番《轻音少女》第 1 集
      await touchFile('混放目录/葬送的芙莉莲 - 02.mkv');
      await touchFile('混放目录/轻音少女 - 01.mkv');

      final syncRes = await orchestrator.syncSingleWorkDirectory(frieren.id);
      expect(syncRes.changed, isTrue);
      expect(syncRes.addedFileCount, 1);

      final frierenVars = await repo.getVariantsByWork(frieren.id);
      expect(frierenVars.map((v) => v.fileName).toSet(), {
        '葬送的芙莉莲 - 01.mkv',
        '葬送的芙莉莲 - 02.mkv',
      });
      final bocchiVars = await repo.getVariantsByWork(bocchi.id);
      expect(bocchiVars.map((v) => v.fileName).toList(), ['孤独摇滚 - 01.mkv']);
    });

    test('多作拆簇共享目录同步严格按拆簇边界隔离，绝不把兄弟剧场版未认领特典串吸入本作品', () async {
      await touchFile(
        '窈窕淑女系列/剧场版 窈窕淑女/[Nekomoe kissaten][Haikara-san ga Toru the movie zenpen - Benio Hana no 17-sai][BDRip][1080p].mkv',
      );
      await touchFile(
        '窈窕淑女系列/剧场版 窈窕淑女/[Nekomoe kissaten][Haikara-san ga Toru the movie kouhen - Hana no Tokyo Dai Roman][BDRip][1080p].mkv',
      );
      await touchFile(
        '窈窕淑女系列/剧场版 窈窕淑女/SPs/[Nekomoe kissaten][Haikara-san ga Toru the movie zenpen - Benio Hana no 17-sai][CM01][BDRip][1080p].mkv',
      );
      await touchFile(
        '窈窕淑女系列/剧场版 窈窕淑女/SPs/[Nekomoe kissaten][Haikara-san ga Toru the movie kouhen - Hana no Tokyo Dai Roman][CM01][BDRip][1080p].mkv',
      );

      final source = MediaSource(
        id: 'local-r12-haikara-shared',
        kind: MediaSourceKind.local,
        label: '拆簇共享盘',
        location: tempRoot.path,
      );
      await repo.upsertMediaSource(source);

      const zenpenWork = Work(
        id: 'work_haikara_zenpen',
        title: '剧场版 窈窕淑女 前篇 ~红绪，花样的17岁~',
        originalTitle: '劇場版 はいからさんが通る 前編',
        bangumiId: 184021,
        year: 2017,
        scrapeStatus: ScrapeStatus.matched,
      );
      const kouhenWork = Work(
        id: 'work_haikara_kouhen',
        title: '剧场版 窈窕淑女 后篇 ~花之东京大浪漫~',
        originalTitle: '劇場版 はいからさんが通る 後編',
        bangumiId: 197654,
        year: 2018,
        scrapeStatus: ScrapeStatus.matched,
      );
      await repo.upsertWork(zenpenWork);
      await repo.upsertWork(kouhenWork);
      await repo.upsertEpisode(
        const Episode(
          id: 'ep_zenpen_main',
          workId: 'work_haikara_zenpen',
          seasonNumber: 1,
          episodeNumber: null,
          title: '前篇',
        ),
      );
      await repo.upsertEpisode(
        const Episode(
          id: 'ep_kouhen_main',
          workId: 'work_haikara_kouhen',
          seasonNumber: 1,
          episodeNumber: null,
          title: '后篇',
        ),
      );
      await repo.upsertMediaVariant(
        const MediaVariant(
          id: 'var_zenpen_main',
          workId: 'work_haikara_zenpen',
          episodeId: 'ep_zenpen_main',
          sourceId: 'local-r12-haikara-shared',
          relativePath:
              '窈窕淑女系列/剧场版 窈窕淑女/[Nekomoe kissaten][Haikara-san ga Toru the movie zenpen - Benio Hana no 17-sai][BDRip][1080p].mkv',
          fileName:
              '[Nekomoe kissaten][Haikara-san ga Toru the movie zenpen - Benio Hana no 17-sai][BDRip][1080p].mkv',
          fileSize: 0,
          assetKind: AssetKind.video,
        ),
      );
      await repo.upsertMediaVariant(
        const MediaVariant(
          id: 'var_kouhen_main',
          workId: 'work_haikara_kouhen',
          episodeId: 'ep_kouhen_main',
          sourceId: 'local-r12-haikara-shared',
          relativePath:
              '窈窕淑女系列/剧场版 窈窕淑女/[Nekomoe kissaten][Haikara-san ga Toru the movie kouhen - Hana no Tokyo Dai Roman][BDRip][1080p].mkv',
          fileName:
              '[Nekomoe kissaten][Haikara-san ga Toru the movie kouhen - Hana no Tokyo Dai Roman][BDRip][1080p].mkv',
          fileSize: 0,
          assetKind: AssetKind.video,
        ),
      );

      final httpClient = TmdbHttpClient(
        config: const TmdbNetworkConfig(credential: 'dummy_v3_key'),
        scheduler: PriorityHttpScheduler(),
        httpClient: buildMockApi(<String>[]),
      );
      final orchestrator = ScrapeOrchestrator(
        repository: repo,
        tmdbService: TmdbService(httpClient: httpClient),
        gatewayBuilder: (s) async => LocalSourceGateway(rootPath: s.location),
        computeWorker: const ScrapeComputeWorker(useIsolate: false),
      );

      // 同步后篇目录时，仅应接纳归属 kouhen 子簇的 CM01，绝不把未认领的 zenpen CM01 误吸入后篇。
      final syncRes = await orchestrator.syncSingleWorkDirectory(kouhenWork.id);
      expect(syncRes.changed, isTrue);
      expect(syncRes.addedFileCount, 1);

      final kouhenVars = await repo.getVariantsByWork(kouhenWork.id);
      expect(
        kouhenVars.map((v) => v.fileName).toSet(),
        equals({
          '[Nekomoe kissaten][Haikara-san ga Toru the movie kouhen - Hana no Tokyo Dai Roman][BDRip][1080p].mkv',
          '[Nekomoe kissaten][Haikara-san ga Toru the movie kouhen - Hana no Tokyo Dai Roman][CM01][BDRip][1080p].mkv',
        }),
      );
      expect(
        kouhenVars.any((v) => v.fileName.toLowerCase().contains('zenpen')),
        isFalse,
      );
    });
  });
}
