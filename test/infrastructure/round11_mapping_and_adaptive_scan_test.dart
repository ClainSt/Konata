import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:konata/application/scraping/scrape_compute_worker.dart';
import 'package:konata/application/scraping/scrape_orchestrator.dart';
import 'package:konata/domain/models/media_source.dart';
import 'package:konata/domain/models/network_config.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/domain/repositories/file_system_gateway.dart';
import 'package:konata/domain/scraping/bangumi_tmdb_index.dart';
import 'package:konata/infrastructure/database/drift_library_repository.dart';
import 'package:konata/infrastructure/database/konata_database.dart';
import 'package:konata/infrastructure/network/bangumi_service.dart';
import 'package:konata/infrastructure/network/priority_http_scheduler.dart';
import 'package:konata/infrastructure/network/tmdb_http_client.dart';
import 'package:konata/infrastructure/network/tmdb_service.dart';
import 'package:konata/infrastructure/scraping/bangumi_tmdb_map_updater.dart';
import 'package:konata/infrastructure/sources/directory_scanner.dart';
import 'package:konata/infrastructure/sources/local_source_gateway.dart';
import 'package:konata/infrastructure/sources/scan_throttle_policy.dart';
import 'package:konata/infrastructure/sources/source_access_error.dart';
import 'package:konata/infrastructure/sources/webdav_source_gateway.dart';
import 'package:konata/infrastructure/storage/storage_root_provider.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

http.Response _jsonResp(Object data, [int statusCode = 200]) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(data)),
    statusCode,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

class _FakeCloudTreeGateway implements MediaSourceGateway {
  _FakeCloudTreeGateway(
    this._tree, {
    this.nfoTexts = const {},
    this.listFailures = const {},
    this.nfoFailures = const {},
    this.delay = Duration.zero,
  });

  final Map<String, List<RemoteEntry>> _tree;
  final Map<String, String> nfoTexts;
  final Map<String, List<Object>> listFailures;
  final Map<String, List<Object>> nfoFailures;
  final Duration delay;

  final List<String> listedDirs = [];
  final List<String> readNfos = [];
  final Map<String, int> _listAttempts = {};
  final Map<String, int> _nfoAttempts = {};

  @override
  Future<List<RemoteEntry>> listDirectory(String relativePath) async {
    listedDirs.add(relativePath);
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    final n = _listAttempts[relativePath] =
        (_listAttempts[relativePath] ?? 0) + 1;
    final planned = listFailures[relativePath] ?? const [];
    if (n <= planned.length) {
      throw planned[n - 1];
    }
    return _tree[relativePath] ?? const [];
  }

  @override
  Future<String?> readTextFile(
    String relativePath, {
    int maxBytes = 256 * 1024,
  }) async {
    readNfos.add(relativePath);
    final n = _nfoAttempts[relativePath] =
        (_nfoAttempts[relativePath] ?? 0) + 1;
    final planned = nfoFailures[relativePath] ?? const [];
    if (n <= planned.length) {
      throw planned[n - 1];
    }
    return nfoTexts[relativePath];
  }

  @override
  Future<String?> testConnection() async => null;

  @override
  Future<void> close() async {}
}

RemoteEntry _dirEntry(String path) => RemoteEntry(
  name: path.split('/').last,
  relativePath: path,
  isDirectory: true,
);

RemoteEntry _fileEntry(String path, {int size = 1024}) => RemoteEntry(
  name: path.split('/').last,
  relativePath: path,
  isDirectory: false,
  size: size,
);

void main() {
  group('BangumiTmdbIndex 双向 O(log N) 索引与随包四源 v2 快照契约', () {
    test('反向二分查询支持严格季号校验、第一季无季号兜底与四源优先级排序', () {
      final raw = BangumiTmdbIndex.encode(const [
        BangumiTmdbRecord(
          bangumiId: 5001,
          type: TmdbMediaType.tv,
          tmdbId: 88001,
          season: 1,
          flags: BangumiTmdbTarget.flagAnimeListsMap,
          tvdbId: 77001,
        ),
        BangumiTmdbRecord(
          bangumiId: 5002,
          type: TmdbMediaType.tv,
          tmdbId: 88001,
          season: 1,
          flags: BangumiTmdbTarget.flagOpenAni,
          tvdbId: 77001,
        ),
        BangumiTmdbRecord(
          bangumiId: 5003,
          type: TmdbMediaType.tv,
          tmdbId: 88001,
          season: 2,
          flags: BangumiTmdbTarget.flagBangumiData,
          tvdbId: 77001,
        ),
        BangumiTmdbRecord(
          bangumiId: 6001,
          type: TmdbMediaType.tv,
          tmdbId: 88002,
          flags: BangumiTmdbTarget.flagWikidata,
        ),
        BangumiTmdbRecord(
          bangumiId: 7001,
          type: TmdbMediaType.movie,
          tmdbId: 99001,
          flags: BangumiTmdbTarget.flagOpenAni,
        ),
      ], snapshotDateYyyymmdd: 20261122);

      final index = BangumiTmdbIndex.fromBytes(raw);
      expect(index.version, BangumiTmdbIndex.formatVersionV2);
      expect(index.supportsTvdbId, isTrue);

      // O(log N) TVDB 反查
      expect(
        index.lookupTvdbIdByTmdb(mediaType: TmdbMediaType.tv, tmdbId: 88001),
        77001,
      );
      expect(
        index.lookupTvdbIdByTmdb(mediaType: TmdbMediaType.movie, tmdbId: 99001),
        isNull,
      );
      expect(
        index.lookupTvdbIdByTmdb(mediaType: TmdbMediaType.tv, tmdbId: 1234567),
        isNull,
      );

      // 第 1 季精确命中且按来源可信度排序（open-ani 优先于 anime-lists）
      final s1 = index.lookupBangumiIdsByTmdb(
        mediaType: TmdbMediaType.tv,
        tmdbId: 88001,
        season: 1,
      );
      expect(s1.map((e) => e.bangumiId).toList(), [5002, 5001]);
      expect(s1.first.isOpenAni, isTrue);

      // 第 2 季精确命中 bangumi-data 补全条目
      final s2 = index.lookupBangumiIdsByTmdb(
        mediaType: TmdbMediaType.tv,
        tmdbId: 88001,
        season: 2,
      );
      expect(s2.map((e) => e.bangumiId).toList(), [5003]);

      // 严格季号模式下查询未收录的第 3 季必须返回空，绝不误绑 S1/S2
      expect(
        index.lookupBangumiIdsByTmdb(
          mediaType: TmdbMediaType.tv,
          tmdbId: 88001,
          season: 3,
          strictSeason: true,
        ),
        isEmpty,
      );

      // 无季号作品级映射仅在查询第 1 季时兜底，查询第 2 季严格拒绝
      expect(
        index
            .lookupBangumiIdsByTmdb(
              mediaType: TmdbMediaType.tv,
              tmdbId: 88002,
              season: 1,
            )
            .map((e) => e.bangumiId)
            .toList(),
        [6001],
      );
      expect(
        index.lookupBangumiIdsByTmdb(
          mediaType: TmdbMediaType.tv,
          tmdbId: 88002,
          season: 2,
        ),
        isEmpty,
      );

      // 电影不受季号过滤影响
      expect(
        index
            .lookupBangumiIdsByTmdb(
              mediaType: TmdbMediaType.movie,
              tmdbId: 99001,
            )
            .map((e) => e.bangumiId)
            .toList(),
        [7001],
      );
    });

    test('随包资产 bangumi_tmdb_map.bin 已升级为四源融合 v2 快照并支持实时双向反查', () {
      final bytes = File('assets/data/bangumi_tmdb_map.bin').readAsBytesSync();
      final index = BangumiTmdbIndex.fromBytes(bytes);

      expect(index.version, BangumiTmdbIndex.formatVersionV2);
      expect(index.supportsTvdbId, isTrue);
      expect(index.uniqueBangumiCount, greaterThanOrEqualTo(20900));
      expect(index.recordCount, greaterThanOrEqualTo(21100));

      // 验证《葬送的芙莉莲》(tv:209867) 可离线反查 Bangumi ID 与 TVDB ID
      final frierenBgm = index.lookupBangumiIdsByTmdb(
        mediaType: TmdbMediaType.tv,
        tmdbId: 209867,
        season: 1,
      );
      expect(frierenBgm.any((e) => e.bangumiId == 400602), isTrue);
      expect(
        index.lookupTvdbIdByTmdb(mediaType: TmdbMediaType.tv, tmdbId: 209867),
        isNotNull,
      );
    });
  });

  group('BangumiTmdbMapUpdater 镜像记忆置顶与 Gzip 传输契约', () {
    late Directory tempRoot;
    late StorageRootService storageRoot;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('konata_r11_upd_');
      storageRoot = StorageRootService(overrideRoot: tempRoot);
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    tearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('首次落盘成功镜像会在下次检查时自动置顶，且请求显式声明 gzip 压缩', () async {
      final bundled = BangumiTmdbIndex.encode(const [
        BangumiTmdbRecord(
          bangumiId: 10,
          type: TmdbMediaType.tv,
          tmdbId: 1000,
          season: 1,
          tvdbId: 5000,
        ),
      ], snapshotDateYyyymmdd: 20261110);
      final remoteV2 = BangumiTmdbIndex.encode(const [
        BangumiTmdbRecord(
          bangumiId: 10,
          type: TmdbMediaType.tv,
          tmdbId: 1000,
          season: 1,
          tvdbId: 5000,
        ),
        BangumiTmdbRecord(
          bangumiId: 20,
          type: TmdbMediaType.tv,
          tmdbId: 2000,
          season: 1,
          tvdbId: 6000,
        ),
      ], snapshotDateYyyymmdd: 20261122);
      final sha = sha256.convert(remoteV2).toString();
      final requestLog = <({String host, String? acceptEncoding})>[];

      final client = MockClient((request) async {
        requestLog.add((
          host: request.url.host,
          acceptEncoding: request.headers['Accept-Encoding'],
        ));
        if (request.url.host == 'slow-bad.example') {
          return http.Response('bad gateway', 502);
        }
        if (request.url.path.endsWith('/manifest_v2.json')) {
          if (request.headers['If-None-Match'] == '"etag-fast"') {
            return http.Response('', 304);
          }
          return http.Response(
            jsonEncode({
              'schemaVersion': 2,
              'snapshotDate': '2026-11-22',
              'recordCount': 2,
              'uniqueBangumiCount': 2,
              'binBytes': remoteV2.length,
              'binSha256': sha,
            }),
            200,
            headers: const {'etag': '"etag-fast"'},
          );
        }
        if (request.url.path.endsWith('/bangumi_tmdb_map_v2.bin')) {
          return http.Response.bytes(remoteV2, 200);
        }
        return http.Response('not found', 404);
      });

      final updater = BangumiTmdbMapUpdater(
        storageRoot: storageRoot,
        assetLoader: (_) async => ByteData.sublistView(bundled),
        httpClient: client,
        mirrorBases: const [
          'https://slow-bad.example/mapping',
          'https://fast-ok.example/mapping',
        ],
      );

      final first = await updater.checkAndUpdateIfDue(force: true);
      expect(first.state, BangumiTmdbUpdateState.updated);
      expect(
        requestLog.every((r) => (r.acceptEncoding ?? '').contains('gzip')),
        isTrue,
      );

      // 第二次检查应直接首选上次成功的 fast-ok.example，不再撞 slow-bad.example
      requestLog.clear();
      final second = await updater.checkAndUpdateIfDue(force: true);
      expect(second.state, BangumiTmdbUpdateState.upToDate);
      expect(requestLog, hasLength(1));
      expect(requestLog.single.host, 'fast-ok.example');
    });
  });

  group('ScrapeOrchestrator 显式 TMDB 离线反查直拉 Bangumi 通道契约', () {
    late Directory tempRoot;
    late KonataDatabase db;
    late DriftLibraryRepository repo;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('konata_r11_orch_');
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

    test('命中离线反查的显式 TMDB 目录直拉 /v0/subjects/{id}，零模糊搜索请求；未命中自动回退搜索', () async {
      await touchFile('孤独摇滚 (2022) {tmdb-201950}/孤独摇滚 - 01.mkv');
      await touchFile('孤独摇滚 (2022) {tmdb-201950}/孤独摇滚 - 02.mkv');
      await touchFile('未收录新作 (2024) {tmdb-888888}/未收录新作 - 01.mkv');

      final source = MediaSource(
        id: 'local-r11-orch',
        kind: MediaSourceKind.local,
        label: '十一轮直拉验证',
        location: tempRoot.path,
      );
      await repo.upsertMediaSource(source);

      final bgmPostKeywords = <String>[];
      final bgmDirectIds = <int>[];

      final mockClient = MockClient((request) async {
        final host = request.url.host.toLowerCase();
        final path = request.url.path;
        if (host.contains('bgm.tv')) {
          if (request.method == 'POST' &&
              path.contains('/v0/search/subjects')) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            final kw = (body['keyword'] ?? '').toString();
            bgmPostKeywords.add(kw);
            if (kw.contains('未收录新作')) {
              return _jsonResp({
                'data': [
                  {
                    'id': 910001,
                    'name': '未收录新作',
                    'name_cn': '未收录新作',
                    'date': '2024-04-01',
                    'eps': 12,
                    'platform': 'TV',
                    'images': {
                      'large': 'https://lain.bgm.tv/pic/cover/l/new.jpg',
                    },
                  },
                ],
              });
            }
            return _jsonResp({'data': []});
          }
          if (path == '/v0/subjects/328609') {
            bgmDirectIds.add(328609);
            return _jsonResp({
              'id': 328609,
              'name': 'ぼっち・ざ・ろっく！',
              'name_cn': '孤独摇滚！',
              'date': '2022-10-08',
              'total_episodes': 12,
              'platform': 'TV',
              'images': {'large': 'https://lain.bgm.tv/pic/cover/l/bocchi.jpg'},
              'infobox': [
                {'key': '别名', 'value': 'Bocchi the Rock!'},
              ],
            });
          }
          if (path == '/v0/subjects/910001') {
            return _jsonResp({
              'id': 910001,
              'name': '未收录新作',
              'name_cn': '未收录新作',
              'date': '2024-04-01',
              'total_episodes': 12,
              'platform': 'TV',
              'images': {'large': 'https://lain.bgm.tv/pic/cover/l/new.jpg'},
            });
          }
          if (path == '/v0/episodes') {
            return _jsonResp({'data': []});
          }
          return http.Response('not found', 404);
        }

        if (path.endsWith('/tv/201950')) {
          return _jsonResp({
            'id': 201950,
            'name': '孤独摇滚！',
            'original_name': 'ぼっち・ざ・ろっく！',
            'first_air_date': '2022-10-08',
            'genres': [
              {'id': 16, 'name': '动画'},
            ],
            'vote_count': 500,
            'seasons': [
              {'season_number': 1, 'name': '第 1 季', 'episode_count': 12},
            ],
          });
        }
        if (path.endsWith('/tv/201950/season/1')) {
          return _jsonResp({
            'episodes': [
              {'episode_number': 1, 'name': '第一话'},
              {'episode_number': 2, 'name': '第二话'},
            ],
          });
        }
        if (path.endsWith('/tv/888888')) {
          return _jsonResp({
            'id': 888888,
            'name': '未收录新作',
            'original_name': '未收录新作',
            'first_air_date': '2024-04-01',
            'genres': [
              {'id': 16, 'name': '动画'},
            ],
            'vote_count': 80,
            'seasons': [
              {'season_number': 1, 'name': '第 1 季', 'episode_count': 12},
            ],
          });
        }
        if (path.endsWith('/tv/888888/season/1')) {
          return _jsonResp({
            'episodes': [
              {'episode_number': 1, 'name': '第一话'},
            ],
          });
        }
        return http.Response('{}', 404);
      });

      final mappingBytes = BangumiTmdbIndex.encode(const [
        BangumiTmdbRecord(
          bangumiId: 328609,
          type: TmdbMediaType.tv,
          tmdbId: 201950,
          season: 1,
          flags: BangumiTmdbTarget.flagOpenAni,
          tvdbId: 413577,
        ),
      ], snapshotDateYyyymmdd: 20261122);
      final mappingIndex = BangumiTmdbIndex.fromBytes(mappingBytes);
      final httpClient = TmdbHttpClient(
        config: const TmdbNetworkConfig(credential: 'dummy_v3_key'),
        scheduler: PriorityHttpScheduler(),
        httpClient: mockClient,
      );
      final orchestrator = ScrapeOrchestrator(
        repository: repo,
        tmdbService: TmdbService(httpClient: httpClient),
        bangumiService: BangumiService(httpClient: httpClient),
        gatewayBuilder: (s) async => LocalSourceGateway(rootPath: s.location),
        computeWorker: const ScrapeComputeWorker(useIsolate: false),
        mappingIndex: mappingIndex,
      );

      await orchestrator.scanAndScrapeSource(source);

      // 孤独摇滚命中离线反查：必须直拉 /v0/subjects/328609，且绝不触发模糊 POST 搜索
      expect(bgmDirectIds, contains(328609));
      expect(
        bgmPostKeywords.any((k) => k.contains('孤独摇滚') || k.contains('ぼっち')),
        isFalse,
      );
      // 未收录新作未命中离线反查：平滑回退至 POST 搜索并成功绑定
      expect(bgmPostKeywords.any((k) => k.contains('未收录新作')), isTrue);

      final works = await repo.getAllWorks();
      final bocchi = works.firstWhere((w) => w.tmdbId == 201950);
      final unmapped = works.firstWhere((w) => w.tmdbId == 888888);
      expect(bocchi.bangumiId, 328609);
      expect(bocchi.scrapeStatus, ScrapeStatus.matched);
      expect(unmapped.bangumiId, 910001);
      expect(unmapped.scrapeStatus, ScrapeStatus.matched);
    });
  });

  group('云盘防风控自适应扫描与 429 退避契约', () {
    test('Retry-After 头解析支持整型秒数与 HTTP-Date，且 429/503 识别为可重试限流错误', () {
      final now = DateTime.utc(2026, 11, 22, 10, 0, 0);
      expect(
        SourceAccessErrorClassifier.parseRetryAfterHeader(const {
          'Retry-After': '7',
        }, now: now),
        const Duration(seconds: 7),
      );
      expect(
        SourceAccessErrorClassifier.parseRetryAfterHeader(const {
          'retry-after': 'Sun, 22 Nov 2026 10:00:12 GMT',
        }, now: now),
        const Duration(seconds: 12),
      );
      expect(
        SourceAccessErrorClassifier.parseRetryAfterHeader(const {
          'Retry-After': 'invalid-date',
        }, now: now),
        isNull,
      );

      const err = SourceRateLimitException(
        statusCode: 429,
        message: '限流',
        retryAfter: Duration(seconds: 5),
      );
      expect(SourceAccessErrorClassifier.isRateLimitError(err), isTrue);
      expect(
        SourceAccessErrorClassifier.extractRetryAfter(err),
        const Duration(seconds: 5),
      );
      expect(SourceAccessErrorClassifier.isNonTransientError(err), isFalse);
      expect(
        SourceAccessErrorClassifier.classify(err, MediaSourceKind.webdav).kind,
        SourceAccessProblemKind.rateLimited,
      );
    });

    test('WebDavSourceGateway 在 HTTP 429 / 503 时抛出带 Retry-After 的 SourceRateLimitException', () async {
      final mockClient = MockClient((request) async {
        if (request.method == 'PROPFIND') {
          return http.Response(
            'too many requests',
            429,
            headers: const {'retry-after': '4'},
          );
        }
        return http.Response(
          'service unavailable',
          503,
          headers: const {'retry-after': '9'},
        );
      });

      final gateway = WebDavSourceGateway(
        rootUri: Uri.parse('http://127.0.0.1:19798/dav/guangya/'),
        httpClient: mockClient,
      );

      await expectLater(
        () => gateway.listDirectory(''),
        throwsA(
          isA<SourceRateLimitException>()
              .having((e) => e.statusCode, 'statusCode', 429)
              .having(
                (e) => e.retryAfter,
                'retryAfter',
                const Duration(seconds: 4),
              ),
        ),
      );
      await expectLater(
        () => gateway.readTextFile('Anime/tvshow.nfo'),
        throwsA(
          isA<SourceRateLimitException>()
              .having((e) => e.statusCode, 'statusCode', 503)
              .having(
                (e) => e.retryAfter,
                'retryAfter',
                const Duration(seconds: 9),
              ),
        ),
      );
    });

    test('AdaptiveScanController 实现冷热 RTT 起搏切换、AIMD 加性增窗与 429 瞬间乘性降窗', () {
      var now = DateTime.utc(2026, 11, 22, 12, 0, 0);
      final ctrl = AdaptiveScanController(
        DirectoryScanProfile.webdav,
        nowProvider: () => now,
      );
      expect(ctrl.currentConcurrency, 2);
      expect(ctrl.currentPacing, DirectoryScanProfile.webdav.warmPacing);

      // 连续 12 次低延迟缓存命中：保持热起搏并 AIMD 增窗至 3
      for (var i = 0; i < 12; i++) {
        ctrl.recordSuccess(const Duration(milliseconds: 10));
      }
      expect(ctrl.currentConcurrency, 3);
      expect(ctrl.currentPacing, DirectoryScanProfile.webdav.warmPacing);

      // 连续高 RTT 回源云盘：起搏自动抬升至冷回源安全间隔 90ms
      for (var i = 0; i < 6; i++) {
        ctrl.recordSuccess(const Duration(milliseconds: 220));
      }
      expect(
        ctrl.currentPacing,
        greaterThanOrEqualTo(DirectoryScanProfile.webdav.coldPacing),
      );

      // 遭遇 429 限流：瞬间乘性降窗至 1、起搏翻倍，并按上下界钳位冷静时长
      final wait1 = ctrl.recordRateLimit(
        retryAfter: const Duration(seconds: 6),
      );
      expect(ctrl.currentConcurrency, 1);
      expect(ctrl.rateLimitHits, 1);
      expect(wait1, const Duration(seconds: 6));
      expect(ctrl.currentPacing.inMilliseconds, greaterThanOrEqualTo(180));

      // 极端超长 Retry-After 被安全上限钳位，防止永久卡死
      final waitClamped = ctrl.recordRateLimit(
        retryAfter: const Duration(minutes: 30),
      );
      expect(waitClamped, DirectoryScanProfile.webdav.maxRateLimitCooldown);
    });

    test('DirectoryScanner 显式 ID 目录免读 NFO、无 ID 优先读 tvshow.nfo、剪枝 BDMV 垃圾目录并耐受 429 重试', () async {
      final tree = <String, List<RemoteEntry>>{
        '': [
          _dirEntry('有编号作品 (2023) {tmdb-10001}'),
          _dirEntry('番组编号作品 {bgm-328609}'),
          _dirEntry('无编号作品'),
          _dirEntry('#recycle'),
          _dirEntry('__MACOSX'),
        ],
        '有编号作品 (2023) {tmdb-10001}': [
          _fileEntry('有编号作品 (2023) {tmdb-10001}/tvshow.nfo'),
          _fileEntry('有编号作品 (2023) {tmdb-10001}/EP01.mkv'),
          _dirEntry('有编号作品 (2023) {tmdb-10001}/Season 1'),
          _dirEntry('有编号作品 (2023) {tmdb-10001}/BDMV'),
        ],
        '有编号作品 (2023) {tmdb-10001}/Season 1': [
          // 祖先已带 {tmdb-10001}，子目录的 season.nfo 也必须免读
          _fileEntry('有编号作品 (2023) {tmdb-10001}/Season 1/season.nfo'),
          _fileEntry('有编号作品 (2023) {tmdb-10001}/Season 1/EP02.mkv'),
        ],
        '有编号作品 (2023) {tmdb-10001}/BDMV': [
          _dirEntry('有编号作品 (2023) {tmdb-10001}/BDMV/STREAM'),
          _dirEntry('有编号作品 (2023) {tmdb-10001}/BDMV/BACKUP'),
          _dirEntry('有编号作品 (2023) {tmdb-10001}/BDMV/CLIPINF'),
          _dirEntry('有编号作品 (2023) {tmdb-10001}/BDMV/PLAYLIST'),
        ],
        '有编号作品 (2023) {tmdb-10001}/BDMV/STREAM': [
          _fileEntry('有编号作品 (2023) {tmdb-10001}/BDMV/STREAM/00001.m2ts'),
        ],
        '番组编号作品 {bgm-328609}': [
          _fileEntry('番组编号作品 {bgm-328609}/tvshow.nfo'),
          _fileEntry('番组编号作品 {bgm-328609}/EP01.mkv'),
        ],
        '无编号作品': [
          _fileEntry('无编号作品/01.nfo'),
          _fileEntry('无编号作品/tvshow.nfo'),
          _fileEntry('无编号作品/EP01.mkv'),
        ],
      };

      final gateway = _FakeCloudTreeGateway(
        tree,
        nfoTexts: const {
          '无编号作品/tvshow.nfo': '<tvshow><tmdbid>55555</tmdbid></tvshow>',
          '无编号作品/01.nfo': '<episodedetails><title>EP1</title></episodedetails>',
        },
        listFailures: {
          '无编号作品': const [
            SourceRateLimitException(
              statusCode: 429,
              message: '限流测试',
              retryAfter: Duration(milliseconds: 20),
            ),
          ],
        },
        nfoFailures: {
          '无编号作品/tvshow.nfo': const [
            SourceRateLimitException(
              statusCode: 429,
              message: 'NFO 限流测试',
              retryAfter: Duration(milliseconds: 20),
            ),
          ],
        },
      );

      const testProfile = DirectoryScanProfile(
        initialConcurrency: 2,
        minConcurrency: 1,
        maxConcurrency: 3,
        warmPacing: Duration(milliseconds: 5),
        coldPacing: Duration(milliseconds: 10),
        maxPacing: Duration(milliseconds: 50),
        warmRttThreshold: Duration(milliseconds: 40),
        coldRttThreshold: Duration(milliseconds: 120),
        aimdIncreaseThreshold: 4,
        maxTransientRetries: 1,
        maxRateLimitRetries: 3,
        minRateLimitCooldown: Duration(milliseconds: 15),
        maxRateLimitCooldown: Duration(milliseconds: 80),
      );

      final result = await const DirectoryScanner(profile: testProfile)
          .scan(gateway);

      // 1) 显式 TMDB / Bangumi 编号目录及其子目录绝不发起任何 .nfo 下载
      expect(gateway.readNfos.every((p) => p.startsWith('无编号作品/')), isTrue);
      // 2) 无编号目录优先读取 tvshow.nfo 而非 01.nfo，且在 429 重试后成功拿到内容
      expect(gateway.readNfos, ['无编号作品/tvshow.nfo', '无编号作品/tvshow.nfo']);
      expect(result.nfoByFolder['无编号作品'], contains('55555'));

      // 3) 垃圾目录与 BDMV 元数据子目录全部被剪枝，但 BDMV/STREAM 蓝光视频完整保留
      expect(gateway.listedDirs, isNot(contains('#recycle')));
      expect(gateway.listedDirs, isNot(contains('__MACOSX')));
      expect(
        gateway.listedDirs.any(
          (d) =>
              d.endsWith('/BACKUP') ||
              d.endsWith('/CLIPINF') ||
              d.endsWith('/PLAYLIST'),
        ),
        isFalse,
      );
      expect(
        result.files.map((f) => f.relativePath),
        containsAll([
          '有编号作品 (2023) {tmdb-10001}/EP01.mkv',
          '有编号作品 (2023) {tmdb-10001}/Season 1/EP02.mkv',
          '有编号作品 (2023) {tmdb-10001}/BDMV/STREAM/00001.m2ts',
          '番组编号作品 {bgm-328609}/EP01.mkv',
          '无编号作品/EP01.mkv',
        ]),
      );
    });

    test('DirectoryScanner 在并发扫描期间收到取消信号能及时终止', () async {
      final tree = <String, List<RemoteEntry>>{
        '': [for (var i = 1; i <= 20; i++) _dirEntry('Show_$i')],
        for (var i = 1; i <= 20; i++)
          'Show_$i': [_fileEntry('Show_$i/EP01.mkv')],
      };
      final gateway = _FakeCloudTreeGateway(
        tree,
        delay: const Duration(milliseconds: 25),
      );
      var cancelled = false;
      final result =
          await const DirectoryScanner(profile: DirectoryScanProfile.local)
              .scan(
                gateway,
                onProgress: (_, scanned, _) {
                  if (scanned >= 3) cancelled = true;
                },
                isCancelled: () => cancelled,
              );

      expect(result.cancelled, isTrue);
      expect(result.files, isEmpty);
      expect(gateway.listedDirs.length, lessThan(15));
    });
  });
}
