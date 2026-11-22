import 'dart:convert';
import 'dart:io';

import 'package:ccplayer/application/scraping/scrape_artwork_enricher.dart';
import 'package:ccplayer/domain/matching/directory_grouper.dart';
import 'package:ccplayer/domain/models/episode.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/domain/models/network_config.dart';
import 'package:ccplayer/domain/models/tmdb_models.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/domain/scraping/bangumi_models.dart';
import 'package:ccplayer/domain/scraping/bangumi_tmdb_index.dart';
import 'package:ccplayer/domain/scraping/work_matcher.dart' as legacy;
import 'package:ccplayer/infrastructure/network/fanart_service.dart';
import 'package:ccplayer/infrastructure/network/priority_http_scheduler.dart';
import 'package:ccplayer/infrastructure/network/tmdb_http_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../tool/eval/eval_models.dart';
import '../../tool/eval/eval_scorer_and_reporter.dart';
import '../../tool/eval/eval_vcr_http_client.dart';
import '../../tool/scrape_eval_support.dart';

void main() {
  group('EvalVcrHttpClient 脱敏归一化缓存、流控退避与缺密拦截', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('konata_eval_vcr_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('跨官方与备用镜像归一化为同一缓存键，并彻底剥离 Query 与 Header 全部密钥', () async {
      var upstreamHits = 0;
      final mockInner = MockClient((req) async {
        upstreamHits++;
        return http.Response(
          jsonEncode({'id': 100565, 'name': '86 -不存在的战区-'}),
          200,
          headers: const {'content-type': 'application/json'},
        );
      });

      final vcr = EvalVcrHttpClient(inner: mockInner, cacheDir: tempDir);
      addTearDown(vcr.close);

      const secretTmdbKey = 'SUPER_SECRET_TMDB_KEY_987654321';
      const secretBearer = 'eyJhbGciOiJIUzI1NiJ9.SECRET_PAYLOAD';

      // 首次走官方域名并携带 api_key 与 Authorization 头。
      final r1 = await vcr.get(
        Uri.parse(
          'https://api.themoviedb.org/3/tv/100565?language=zh-CN&api_key=$secretTmdbKey&append_to_response=images',
        ),
        headers: const {'Authorization': 'Bearer $secretBearer'},
      );
      expect(r1.statusCode, 200);
      expect(upstreamHits, 1);

      // 第二次切换备用镜像且打乱 Query 顺序、更换密钥，必须 100% 命中同一本地缓存。
      final r2 = await vcr.get(
        Uri.parse(
          'https://api.tmdb.org/3/tv/100565?append_to_response=images&api_key=ANOTHER_KEY&language=zh-CN',
        ),
      );
      expect(r2.statusCode, 200);
      expect(upstreamHits, 1);
      expect(vcr.stats.of('tmdb').cacheHits, 1);
      expect(vcr.stats.of('tmdb').cacheMisses, 1);

      // 校验 Fanart 官方与中继路径归一化一致。
      final kDirect = EvalVcrHttpClient.buildCanonicalRequestKey(
        method: 'GET',
        uri: Uri.parse('https://webservice.fanart.tv/v3/tv/424536'),
      );
      final kRelay = EvalVcrHttpClient.buildCanonicalRequestKey(
        method: 'GET',
        uri: Uri.parse('https://api.konata.acgcc.cn/fanart/v3/tv/424536'),
      );
      expect(kDirect.canonicalKey, 'GET fanart:/v3/tv/424536');
      expect(kRelay.canonicalKey, kDirect.canonicalKey);
      expect(kRelay.sha256Hex, kDirect.sha256Hex);

      // 遍历落盘缓存文件，确保绝无任何明文密钥残留。
      final cachedFiles = tempDir
          .listSync(recursive: true)
          .whereType<File>()
          .toList();
      expect(cachedFiles, hasLength(1));
      final rawDisk = cachedFiles.single.readAsStringSync();
      expect(rawDisk, isNot(contains(secretTmdbKey)));
      expect(rawDisk, isNot(contains(secretBearer)));
      expect(rawDisk, isNot(contains('api_key')));
    });

    test('本地缓存未命中且缺少 TMDB 密钥时直接抛出 EvalKeyRequiredException，不触发网络请求', () async {
      var upstreamHits = 0;
      final vcr = EvalVcrHttpClient(
        inner: MockClient((_) async {
          upstreamHits++;
          return http.Response('{}', 200);
        }),
        cacheDir: tempDir,
      );
      addTearDown(vcr.close);

      await expectLater(
        () => vcr.get(
          Uri.parse('https://api.themoviedb.org/3/search/tv?query=86'),
        ),
        throwsA(
          isA<EvalKeyRequiredException>().having(
            (e) => e.service,
            'service',
            'tmdb',
          ),
        ),
      );
      expect(upstreamHits, 0);
    });

    test('HTTP 429 遵循 Retry-After 重试且绝不缓存 429，Cloudflare 1027 立即停止重试', () async {
      var tmdbAttempts = 0;
      var fanartAttempts = 0;
      final mockInner = MockClient((req) async {
        if (req.url.host.contains('themoviedb')) {
          tmdbAttempts++;
          if (tmdbAttempts == 1) {
            return http.Response(
              '{"status_message":"rate limited"}',
              429,
              headers: const {'retry-after': '1'},
            );
          }
          return http.Response('{"id":129}', 200);
        }
        fanartAttempts++;
        return http.Response(
          'Error 1027 quota_exceeded',
          429,
          headers: const {'content-type': 'text/plain'},
        );
      });

      final vcr = EvalVcrHttpClient(
        inner: mockInner,
        cacheDir: tempDir,
        maxRetries: 2,
      );
      addTearDown(vcr.close);

      final ok = await vcr.get(
        Uri.parse('https://api.themoviedb.org/3/movie/129?api_key=TESTKEY123'),
      );
      expect(ok.statusCode, 200);
      expect(tmdbAttempts, 2);
      expect(vcr.stats.of('tmdb').http429Count, 1);

      final quota = await vcr.get(
        Uri.parse('https://webservice.fanart.tv/v3/movies/129'),
        headers: const {'api-key': 'TEST_FANART_KEY_123456'},
      );
      expect(quota.statusCode, 429);
      expect(fanartAttempts, 1);
      expect(vcr.stats.of('fanart').quotaExhausted, isTrue);
    });
  });

  group('ScrapeArtworkEnricher 生产与评测同源 Fanart 整包富化与四通道上墙', () {
    test('TMDB 英文徽标与 720p 背景经 Fanart 整包联合升级为日文高清徽标与 1080p 无字背景', () async {
      final mockHttp = MockClient((req) async {
        expect(req.url.toString(), 'https://webservice.fanart.tv/v3/tv/424536');
        return http.Response(
          jsonEncode({
            'hdtvlogo': [
              {
                'id': '1',
                'url': 'https://assets.fanart.tv/fanart/tv/424536/hdtvlogo/ja.png',
                'lang': 'ja',
                'likes': '10',
              },
            ],
            'showbackground': [
              {
                'id': '2',
                'url':
                    'https://assets.fanart.tv/fanart/tv/424536/showbackground/clean.jpg',
                'likes': '8',
              },
            ],
          }),
          200,
        );
      });
      final tmdbHttp = TmdbHttpClient(
        config: const TmdbNetworkConfig(
          fanartApiKeyOverride: 'custom_fanart_key_123456',
          fanartBackupApiBase: '',
        ),
        httpClient: mockHttp,
        scheduler: PriorityHttpScheduler(maxRetries: 0),
      );
      addTearDown(tmdbHttp.close);

      final enricher = ScrapeArtworkEnricher(
        fanartService: FanartService(
          httpClient: tmdbHttp,
          artworkCache: FanartArtworkCache(),
        ),
      );

      const detail = TmdbWorkDetail(
        tmdbId: 209867,
        mediaType: TmdbMediaType.tv,
        title: '葬送的芙莉莲',
        tvdbId: 424536,
        posterPath: '/poster.jpg',
        backdropPath: '/bg720.jpg',
        logoPath: '/en_logo.png',
        candidateBackdrops: [
          TmdbArtworkImage(
            filePath: '/bg720.jpg',
            width: 1280,
            height: 720,
            isoLanguage: null,
          ),
        ],
        candidateLogos: [
          TmdbArtworkImage(
            filePath: '/en_logo.png',
            isoLanguage: 'en',
            width: 800,
          ),
        ],
        imagesLoaded: true,
      );

      final outcome = await enricher.enrichTmdbDetail(
        detail: detail,
        seasonDetail: null,
        matchedSeason: 1,
        bangumiCandidate: null,
        priority: RequestPriority.background,
        upgradeNonZhCnLogo: true,
      );

      expect(outcome.tvdbId, 424536);
      expect(outcome.tvdbIdSource, TvdbIdSource.tmdbExternalIds);
      expect(outcome.logoUpgradedByFanart, isTrue);
      expect(outcome.logoOverride, contains('/hdtvlogo/ja.png'));
      expect(outcome.backdropSuboptimal, isTrue);
      expect(outcome.backdropUpgradedByFanart, isTrue);
      expect(outcome.backdropOverride, contains('/showbackground/clean.jpg'));
    });

    test('通路 B 经 KTBM v2 离线映射反查 tvdbId 补全 Fanart 整包并拦截 0 正片纯特典目录', () async {
      final v2Bytes = BangumiTmdbIndex.encode(
        const [
          BangumiTmdbRecord(
            bangumiId: 400602,
            type: TmdbMediaType.tv,
            tmdbId: 209867,
            season: 1,
            tvdbId: 424536,
          ),
        ],
        snapshotDateYyyymmdd: 20261121,
        formatVersionOverride: BangumiTmdbIndex.formatVersionV2,
      );
      final v2Index = BangumiTmdbIndex.fromBytes(v2Bytes);

      final tmdbHttp = TmdbHttpClient(
        config: const TmdbNetworkConfig(
          fanartApiKeyOverride: 'custom_fanart_key_123456',
          fanartBackupApiBase: '',
        ),
        httpClient: MockClient((_) async {
          return http.Response(
            jsonEncode({
              'tvposter': [
                {
                  'id': 'p1',
                  'url':
                      'https://assets.fanart.tv/fanart/tv/424536/tvposter/main.jpg',
                  'lang': 'ja',
                  'likes': '5',
                },
              ],
              'hdtvlogo': [
                {
                  'id': 'l1',
                  'url':
                      'https://assets.fanart.tv/fanart/tv/424536/hdtvlogo/zh.png',
                  'lang': 'zh',
                  'likes': '9',
                },
              ],
            }),
            200,
          );
        }),
        scheduler: PriorityHttpScheduler(maxRetries: 0),
      );
      addTearDown(tmdbHttp.close);

      final enricher = ScrapeArtworkEnricher(
        fanartService: FanartService(httpClient: tmdbHttp),
        mappingIndex: v2Index,
      );

      const playableFolder = GroupedWorkFolder(
        folderRelativePath: 'OVA/某独立OVA',
        folderName: '某独立OVA',
        cleanTitle: '某独立OVA',
        mainEpisodeNumbers: [1],
        variants: [
          MediaVariant(
            id: 'v1',
            workId: 'w1',
            sourceId: 'eval',
            relativePath: 'OVA/某独立OVA/01.mkv',
            fileName: '01.mkv',
            fileSize: 800 * 1024 * 1024,
            assetKind: AssetKind.video,
          ),
        ],
      );
      const pureExtraFolder = GroupedWorkFolder(
        folderRelativePath: '杂项/纯特典目录',
        folderName: '纯特典目录',
        cleanTitle: '纯特典目录',
        variants: [
          MediaVariant(
            id: 'v2',
            workId: 'w2',
            sourceId: 'eval',
            relativePath: '杂项/纯特典目录/NCOP01.mkv',
            fileName: 'NCOP01.mkv',
            fileSize: 50 * 1024 * 1024,
            assetKind: AssetKind.video,
          ),
        ],
        slotAssignmentsByPath: {
          '杂项/纯特典目录/NCOP01.mkv': EpisodeSlotAssignment(
            category: EpisodeCategory.extra,
            seasonNumber: 0,
            extraType: ExtraKind.ncop,
          ),
        },
        localPosterPath: '杂项/纯特典目录/poster.jpg',
      );

      const bgmCandidate = ScoredBangumiCandidate(
        subject: BangumiSubjectCandidate(
          id: 400602,
          name: '某独立OVA',
          nameCn: '某独立OVA',
        ),
        score: 88,
        reasons: ['title_exact'],
      );

      final bgmWall = await enricher.evaluateBangumiOnly(
        folder: playableFolder,
        bangumiCandidate: bgmCandidate,
        bangumiTier: legacy.MatchTier.high,
      );
      expect(bgmWall.canPromote, isTrue);
      expect(bgmWall.tvdbId, 424536);
      expect(bgmWall.tvdbIdSource, TvdbIdSource.offlineMappingV2);
      expect(bgmWall.coverSource, 'fanart');
      expect(bgmWall.fanartLogo, contains('/hdtvlogo/zh.png'));

      final blockedCover = await enricher.evaluateCoverFallback(
        folder: pureExtraFolder,
      );
      expect(blockedCover.canPromote, isFalse);
    });
  });

  group('黄金集 CSV 编解码、六维分桶计分、基线 Diff 与纯 Dart CLI 冒烟', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('konata_eval_cli_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('GoldenSetCsvCodec 带 UTF-8 BOM 往返无损且支持逗号引号转义', () {
      final csvFile = File('${tempDir.path}${Platform.pathSeparator}golden.csv');
      const cases = [
        GoldenCase(
          caseId: 'G001',
          bucket: 'tv',
          physicalRoot: '2021/Wake Up, Girls! 新章',
          clusterHint: '*',
          expectedTmdb: 'tv:74191',
          expectedSeason: '2',
          expectedBangumi: '201212',
          expectedWall: 'tmdb',
          expectedMainCount: 12,
          forbiddenExtraLeak: true,
          expectLogoMinTier: 'ja_hd',
          verified: true,
          suggestedTitle: 'Wake Up, Girls! "新章"',
          notes: '含逗号,与"引号"',
        ),
      ];
      GoldenSetCsvCodec.writeFile(csvFile, cases);
      final rawBytes = csvFile.readAsBytesSync();
      expect(rawBytes.take(3), [0xEF, 0xBB, 0xBF]);

      final parsed = GoldenSetCsvCodec.readFile(csvFile);
      expect(parsed, hasLength(1));
      expect(parsed.single.physicalRoot, '2021/Wake Up, Girls! 新章');
      expect(parsed.single.suggestedTitle, 'Wake Up, Girls! "新章"');
      expect(parsed.single.notes, '含逗号,与"引号"');
      expect(parsed.single.verified, isTrue);
      expect(parsed.single.expectedMainCount, 12);
    });

    test('EvalScorerAndReporter 精准计算六维分桶、错绑/误上墙红线与退化修复 Diff', () {
      const golden = [
        GoldenCase(
          caseId: 'G001',
          bucket: 'tv',
          physicalRoot: 'Anime/86',
          expectedTmdb: 'tv:100565',
          expectedSeason: '1',
          expectedWall: 'tmdb',
          verified: true,
        ),
        GoldenCase(
          caseId: 'G002',
          bucket: 'pure_noise',
          physicalRoot: 'Anime/SampleExtras',
          expectedTmdb: 'none',
          expectedWall: 'block',
          verified: true,
        ),
      ];
      const records = [
        EvalClusterRecord(
          folderKey: 'Anime/86',
          physicalRoot: 'Anime/86',
          folderName: '86',
          cleanTitle: '86',
          isSplitCluster: false,
          isMovieHint: false,
          hasMainPlayable: true,
          mainVideoCount: 23,
          extraVideoCount: 2,
          cdAssetCount: 0,
          scanAssetCount: 0,
          mainEpisodeNumbers: [1, 2],
          suspectedExtraLeakPaths: [],
          matchLevel: 'autoBind',
          bestTmdbKey: 'tv:999999',
          matchedSeason: 1,
          wallChannel: 'tmdb',
          tvdbId: 394812,
          tvdbIdSource: 'tmdb_external_ids',
          logoSource: 'fanart',
          logoLanguage: 'zh_cn',
          logoIsHd: true,
          logoUpgradedByFanart: true,
          backdropSuboptimal: true,
          backdropUpgradedByFanart: true,
          fanartQueried: true,
        ),
        EvalClusterRecord(
          folderKey: 'Anime/SampleExtras',
          physicalRoot: 'Anime/SampleExtras',
          folderName: 'SampleExtras',
          cleanTitle: 'SampleExtras',
          isSplitCluster: false,
          isMovieHint: false,
          hasMainPlayable: false,
          mainVideoCount: 0,
          extraVideoCount: 3,
          cdAssetCount: 0,
          scanAssetCount: 0,
          mainEpisodeNumbers: [],
          suspectedExtraLeakPaths: [],
          matchLevel: 'unmatched',
          wallChannel: 'block',
        ),
      ];

      final report = EvalScorerAndReporter.evaluate(
        runId: 'test_run',
        mode: EvalMode.golden,
        artworkMode: EvalArtworkMode.full,
        sourceKind: EvalSourceKind.webdav,
        mappingInfo: 'assets v1',
        elapsedMs: 1200,
        records: records,
        goldenCases: golden,
        networkStatsJson: const {
          'totalCacheHits': 10,
          'totalCacheMisses': 0,
          'totalNetworkRequests': 0,
          'totalHttp429': 0,
        },
      );

      expect(report.buckets['tv']!.wrongBind, 1);
      expect(report.buckets['pure_noise']!.passed, 1);
      expect(report.buckets['pure_noise']!.falseWallPromotions, 0);
      expect(report.artworkSummary.logoUpgradedByFanartCount, 1);
      expect(report.artworkSummary.backdropUpgradedByFanartCount, 1);

      final fakeBaseline = <String, Object?>{
        'buckets': {
          'tv': {'accuracyPct': 100.0},
          'pure_noise': {'accuracyPct': 0.0},
        },
        'verdicts': {
          'G001': {'passed': true, 'actualTmdb': 'tv:100565'},
          'G002': {'passed': false, 'actualTmdb': 'tv:111'},
        },
      };
      final md = EvalScorerAndReporter.renderDiffMarkdown(
        report: report,
        baselineJson: fakeBaseline,
      );
      expect(md, contains('退化项（原对现错：1）'));
      expect(md, contains('修复项（原错现对：1）'));
      expect(md, contains('Fanart 跨源升级'));

      final failedFile = File(
        '${tempDir.path}${Platform.pathSeparator}failed_keys.json',
      );
      EvalScorerAndReporter.writeFailedKeys(
        file: failedFile,
        report: report,
        baselineJson: fakeBaseline,
      );
      final failedJson =
          jsonDecode(failedFile.readAsStringSync()) as Map<String, Object?>;
      expect(failedJson['failedPhysicalRoots'], ['Anime/86']);
      expect(failedJson['recentlyFixedRoots'], ['Anime/SampleExtras']);
    });

    test('纯 Dart CLI 端到端冒烟：parse-only -> init-golden -> golden(缺密返回42) -> accept-baseline', () async {
      final manifest = File(
        '${tempDir.path}${Platform.pathSeparator}corpus_manifest.tsv',
      );
      manifest.writeAsStringSync(
        [
          '2021/86 -不存在的战区-/01.mkv\t1200000000',
          '2021/86 -不存在的战区-/02.mkv\t1200000000',
          '2021/86 -不存在的战区-/SPs/NCOP01.mkv\t80000000',
          '2021/86 -不存在的战区-/CDs/OST01.flac\t45000000',
          '2021/86 -不存在的战区-/Scans/001.jpg\t3000000',
          '2021/86 -不存在的战区-/poster.jpg\t500000',
          'Movie/千与千寻 (2001)/Spirited Away.mkv\t4500000000',
        ].join('\n'),
        flush: true,
      );

      // 同时验证 groupListing 在 detectLocalCovers=true 时能透传本地目录封面。
      final localGrouped = await groupListing(
        manifest.path,
        detectLocalCovers: true,
      );
      expect(
        localGrouped.groups.any(
          (g) => (g.localPosterPath ?? '').endsWith('poster.jpg'),
        ),
        isTrue,
      );

      // 预编译单次 Kernel 快照供后续 4 次独立子进程冒烟复用，避免 Dart 3.14 每次 `dart run` 重复触发原生资产构建钩子。
      final dillPath =
          '${tempDir.path}${Platform.pathSeparator}eval_scraper.dill';
      final rCompile = await Process.run(
        'dart',
        ['compile', 'kernel', 'tool/eval_scraper.dart', '-o', dillPath],
        runInShell: Platform.isWindows,
      );
      expect(rCompile.exitCode, 0, reason: '${rCompile.stderr}');

      final rParse = await Process.run(
        'dart',
        [
          dillPath,
          '--parse-only',
          '--eval-dir=${tempDir.path}',
        ],
        runInShell: Platform.isWindows,
      );
      expect(rParse.exitCode, 0, reason: '${rParse.stderr}');
      expect(
        File(
          '${tempDir.path}${Platform.pathSeparator}runs${Platform.pathSeparator}latest_diff.md',
        ).existsSync(),
        isTrue,
      );

      final rInit = await Process.run(
        'dart',
        [
          dillPath,
          '--init-golden',
          '--sample-size=20',
          '--eval-dir=${tempDir.path}',
        ],
        runInShell: Platform.isWindows,
      );
      expect(rInit.exitCode, 0, reason: '${rInit.stderr}');
      final goldenFile = File(
        '${tempDir.path}${Platform.pathSeparator}golden_set.csv',
      );
      expect(goldenFile.existsSync(), isTrue);

      // 纯离线无缓存运行 golden，必须精准返回退出码 42 以唤醒启动脚本按需弹窗。
      final rGolden = await Process.run(
        'dart',
        [
          dillPath,
          '--golden',
          '--offline',
          '--eval-dir=${tempDir.path}',
        ],
        runInShell: Platform.isWindows,
      );
      expect(rGolden.exitCode, 42, reason: '${rGolden.stdout}\n${rGolden.stderr}');

      final rAccept = await Process.run(
        'dart',
        [
          dillPath,
          '--accept-baseline',
          '--eval-dir=${tempDir.path}',
        ],
        runInShell: Platform.isWindows,
      );
      expect(rAccept.exitCode, 0, reason: '${rAccept.stderr}');
      expect(
        File(
          '${tempDir.path}${Platform.pathSeparator}runs${Platform.pathSeparator}baseline.json',
        ).existsSync(),
        isTrue,
      );
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
