import 'package:ccplayer/application/scraping/scrape_candidate_fetcher.dart';
import 'package:ccplayer/application/scraping/scrape_match_resolver.dart';
import 'package:ccplayer/domain/matching/directory_grouper.dart';
import 'package:ccplayer/domain/matching/work_matcher.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/domain/models/tmdb_models.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/domain/scraping/bangumi_models.dart';
import 'package:ccplayer/domain/scraping/bangumi_tmdb_index.dart';
import 'package:ccplayer/domain/scraping/directory_analyzer.dart';
import 'package:ccplayer/domain/scraping/scrape_domain_adapter.dart';
import 'package:ccplayer/infrastructure/network/bangumi_service.dart';
import 'package:ccplayer/infrastructure/network/priority_http_scheduler.dart';
import 'package:ccplayer/infrastructure/network/tmdb_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// 面向 Konata 四档准确率 SLA 的专项回归与基准测试：
/// - 档位 1（带正确 Bangumi ID 或 TMDB ID）：要求 100.0% 精准命中；
/// - 档位 3（复杂不规范目录名 + 内部视频文件名一致）：要求 >= 97.0% 精准命中。
void main() {
  group('档位 1：显式 Bangumi ID 与 TMDB ID 直连 100% 精准命中', () {
    test('目录携带 {bgm-N} / [bgmid=N] 时直接按 ID 拉取 Bangumi 并经离线映射零检索直绑 TMDB', () async {
      final bgmService = _FakeBangumiService(
        byId: const {
          404427: BangumiSubjectCandidate(
            id: 404427,
            name: 'アイカツ! 10th STORY ～未来へのSTARWAY～',
            nameCn: '偶像活动! 10th STORY ～通往未来的STARWAY～',
            year: 2023,
            airDate: '2023-01-20',
            totalEpisodes: 3,
            platform: '剧场版',
          ),
          23685: BangumiSubjectCandidate(
            id: 23685,
            name: 'アクセル・ワールド',
            nameCn: '加速世界',
            year: 2012,
            airDate: '2012-04-07',
            totalEpisodes: 24,
            platform: 'TV',
          ),
        },
      );
      final tmdbService = _FakeTmdbService(
        details: const {
          'movie:1066946': TmdbWorkDetail(
            tmdbId: 1066946,
            mediaType: TmdbMediaType.movie,
            title: '偶像活动！10th STORY ～通往未来的STARWAY～',
            originalTitle: 'アイカツ! 10th STORY ～未来へのSTARWAY～',
            year: 2023,
            voteCount: 18,
            genreIds: [16, 10402],
          ),
          'tv:43167': TmdbWorkDetail(
            tmdbId: 43167,
            mediaType: TmdbMediaType.tv,
            title: '加速世界',
            originalTitle: 'アクセル・ワールド',
            year: 2012,
            voteCount: 164,
            genreIds: [16, 10759],
            seasons: [
              TmdbSeasonSummary(
                seasonNumber: 1,
                name: '加速世界',
                episodeCount: 24,
                airDate: '2012-04-07',
              ),
            ],
          ),
        },
      );
      final index = BangumiTmdbIndex.fromBytes(
        BangumiTmdbIndex.encode(
          const [
            BangumiTmdbRecord(
              bangumiId: 404427,
              type: TmdbMediaType.movie,
              tmdbId: 1066946,
              season: null,
            ),
            BangumiTmdbRecord(
              bangumiId: 23685,
              type: TmdbMediaType.tv,
              tmdbId: 43167,
              season: 1,
              tvdbId: 257516,
            ),
          ],
          snapshotDateYyyymmdd: 20261121,
        ),
      );
      final fetcher = ScrapeCandidateFetcher(
        tmdbService,
        bangumiService: bgmService,
      );
      final resolver = ScrapeMatchResolver(
        fetcher: fetcher,
        mappingIndex: index,
      );

      final movieFolder = _buildGroupedFolder(
        folderPath: '动画/偶像活动 10th STORY {bgm-404427}',
        fileNames: const [
          '[FLsnow][Aikatsu_10th][01].mkv',
          '[FLsnow][Aikatsu_10th][02].mkv',
          '[FLsnow][Aikatsu_10th][03].mkv',
        ],
      );
      expect(movieFolder.explicitBangumiId, 404427);
      final movieRes = await resolver.resolve(movieFolder);
      expect(bgmService.searchCalls, 0);
      expect(movieRes.decision.level, MatchLevel.autoBind);
      expect(movieRes.decision.best?.detail.mediaType, TmdbMediaType.movie);
      expect(movieRes.decision.best?.detail.tmdbId, 1066946);
      expect(movieRes.decision.bestBangumi?.subject.id, 404427);

      final tvFolder = _buildGroupedFolder(
        folderPath: '动画/加速世界 [bgmid=23685]',
        fileNames: [
          for (var i = 1; i <= 24; i++)
            '[VCB-Studio] Accel World [${'$i'.padLeft(2, '0')}].mkv',
        ],
      );
      expect(tvFolder.explicitBangumiId, 23685);
      final tvRes = await resolver.resolve(tvFolder);
      expect(bgmService.searchCalls, 0);
      expect(tvRes.decision.level, MatchLevel.autoBind);
      expect(tvRes.decision.best?.detail.tmdbId, 43167);
      expect(tvRes.decision.matchedSeason, 1);

      // 盲测模式屏蔽显式 Bangumi ID，确保不泄露标签。
      expect(tvFolder.withoutExplicitTmdb().explicitBangumiId, isNull);
    });

    test('显式 {tmdb-N} 配合 Bangumi 联合定季准确命中多季续作与 Season 0 特别篇', () {
      final natsumeS6 = _buildGroupedFolder(
        folderPath: '动画/夏目友人帐 陆 (2017) {tmdb-69500}',
        fileNames: [
          for (var i = 1; i <= 11; i++)
            '[VCB-Studio] Natsume Yuujinchou Roku [${'$i'.padLeft(2, '0')}].mkv',
        ],
      );
      final natsumeDecision = ScrapeDomainAdapter.evaluateMatch(
        natsumeS6,
        const [
          TmdbWorkDetail(
            tmdbId: 69500,
            mediaType: TmdbMediaType.tv,
            title: '夏目友人帐',
            originalTitle: '夏目友人帳',
            year: 2008,
            voteCount: 300,
            genreIds: [16, 18],
            seasons: [
              TmdbSeasonSummary(
                seasonNumber: 1,
                name: '第 1 季',
                episodeCount: 13,
                airDate: '2008-07-08',
              ),
              TmdbSeasonSummary(
                seasonNumber: 6,
                name: '夏目友人帐 陆',
                episodeCount: 11,
                airDate: '2017-04-12',
              ),
            ],
          ),
        ],
        bangumiCandidates: const [
          BangumiSubjectCandidate(
            id: 202270,
            name: '夏目友人帳 陸',
            nameCn: '夏目友人帐 陆',
            year: 2017,
            airDate: '2017-04-12',
            totalEpisodes: 11,
            platform: 'TV',
          ),
        ],
      );
      expect(natsumeDecision.level, MatchLevel.autoBind);
      expect(natsumeDecision.best?.detail.tmdbId, 69500);
      expect(natsumeDecision.matchedSeason, 6);

      final oadFolder = _buildGroupedFolder(
        folderPath: '动画/七大罪 OAD (2015) {tmdb-62104}',
        fileNames: const [
          '[VCB-Studio] Nanatsu no Taizai OAD [01].mkv',
          '[VCB-Studio] Nanatsu no Taizai OAD [02].mkv',
          '[VCB-Studio] Nanatsu no Taizai OAD [03].mkv',
        ],
      );
      final oadDecision = ScrapeDomainAdapter.evaluateMatch(
        oadFolder,
        const [
          TmdbWorkDetail(
            tmdbId: 62104,
            mediaType: TmdbMediaType.tv,
            title: '七大罪',
            originalTitle: '七つの大罪',
            year: 2014,
            voteCount: 2000,
            genreIds: [16, 10759],
            seasons: [
              TmdbSeasonSummary(
                seasonNumber: 0,
                name: '特别篇',
                episodeCount: 8,
                airDate: '2015-06-17',
              ),
              TmdbSeasonSummary(
                seasonNumber: 1,
                name: '第 1 季',
                episodeCount: 24,
                airDate: '2014-10-05',
              ),
            ],
          ),
        ],
        bangumiCandidates: const [
          BangumiSubjectCandidate(
            id: 129770,
            name: '七つの大罪 OAD',
            nameCn: '七大罪 OAD',
            year: 2015,
            totalEpisodes: 2,
            platform: 'OVA',
          ),
        ],
      );
      expect(oadDecision.level, MatchLevel.autoBind);
      expect(oadDecision.best?.detail.tmdbId, 62104);
      expect(oadDecision.matchedSeason, 0);
    });
  });

  group('档位 3：复杂不规范目录名 + 一致视频文件名基准（目标 >= 97%）', () {
    test('40 组真实番剧包装在 10 类通用桶与完全不可预测随机目录名下精准命中率 >= 97%', () {
      const messyFolders = <String>[
        '新建文件夹',
        '新建文件夹 (2)',
        '2025年7月新番',
        '待看_2026',
        '【高清蓝光】我的动画收藏合集2',
        'BDMV_042',
        'Downloads',
        '阿伟推荐的神作',
        '阿伟推荐的神作2 (2026)',
        '周末必看_硬盘A组',
      ];

      final specs = <_MessyCaseSpec>[
        _MessyCaseSpec(
          label: '葬送的芙莉莲 (VCB 罗马音)',
          filePattern: (i) =>
              '[VCB-Studio] Sousou no Frieren [${'$i'.padLeft(2, '0')}][Ma10p_1080p].mkv',
          episodeCount: 28,
          tmdb: const TmdbWorkDetail(
            tmdbId: 209867,
            mediaType: TmdbMediaType.tv,
            title: '葬送的芙莉莲',
            originalTitle: '葬送のフリーレン',
            aliases: ['Sousou no Frieren', 'Frieren: Beyond Journey\'s End'],
            year: 2023,
            voteCount: 900,
            genreIds: [16, 18],
            seasons: [
              TmdbSeasonSummary(
                seasonNumber: 1,
                name: '第 1 季',
                episodeCount: 28,
                airDate: '2023-09-29',
              ),
            ],
          ),
          bangumi: const BangumiSubjectCandidate(
            id: 400602,
            name: '葬送のフリーレン',
            nameCn: '葬送的芙莉莲',
            aliases: ['Sousou no Frieren'],
            year: 2023,
            totalEpisodes: 28,
            platform: 'TV',
          ),
        ),
        _MessyCaseSpec(
          label: '孤独摇滚！ (LoliHouse 英文)',
          filePattern: (i) =>
              '[LoliHouse] Bocchi the Rock! - ${'$i'.padLeft(2, '0')} [WebRip 1080p].mkv',
          episodeCount: 12,
          tmdb: const TmdbWorkDetail(
            tmdbId: 154524,
            mediaType: TmdbMediaType.tv,
            title: '孤独摇滚！',
            originalTitle: 'ぼっち・ざ・ろっく！',
            aliases: ['Bocchi the Rock!'],
            year: 2022,
            voteCount: 520,
            genreIds: [16, 35],
            seasons: [
              TmdbSeasonSummary(
                seasonNumber: 1,
                name: '第 1 季',
                episodeCount: 12,
                airDate: '2022-10-09',
              ),
            ],
          ),
          bangumi: const BangumiSubjectCandidate(
            id: 328609,
            name: 'ぼっち・ざ・ろっく！',
            nameCn: '孤独摇滚！',
            aliases: ['Bocchi the Rock!'],
            year: 2022,
            totalEpisodes: 12,
            platform: 'TV',
          ),
        ),
        _MessyCaseSpec(
          label: '轻音少女 短片名 K-ON! (<10字符)',
          filePattern: (i) =>
              '[VCB-Studio] K-ON! [${'$i'.padLeft(2, '0')}][Ma10p_1080p].mkv',
          episodeCount: 13,
          tmdb: const TmdbWorkDetail(
            tmdbId: 30991,
            mediaType: TmdbMediaType.tv,
            title: '轻音少女',
            originalTitle: 'けいおん！',
            aliases: ['K-ON!'],
            year: 2009,
            voteCount: 410,
            genreIds: [16, 35],
            seasons: [
              TmdbSeasonSummary(
                seasonNumber: 1,
                name: '第 1 季',
                episodeCount: 13,
                airDate: '2009-04-03',
              ),
            ],
          ),
          bangumi: const BangumiSubjectCandidate(
            id: 1424,
            name: 'けいおん！',
            nameCn: '轻音少女',
            aliases: ['K-ON!'],
            year: 2009,
            totalEpisodes: 13,
            platform: 'TV',
          ),
        ),
        _MessyCaseSpec(
          label: '紫罗兰永恒花园 (中文全方括号字幕组)',
          filePattern: (i) =>
              '【悠哈璃羽字幕社】[紫罗兰永恒花园][${'$i'.padLeft(2, '0')}][1080p].mkv',
          episodeCount: 13,
          tmdb: const TmdbWorkDetail(
            tmdbId: 75214,
            mediaType: TmdbMediaType.tv,
            title: '紫罗兰永恒花园',
            originalTitle: 'ヴァイオレット・エヴァーガーデン',
            aliases: ['Violet Evergarden'],
            year: 2018,
            voteCount: 1200,
            genreIds: [16, 18],
            seasons: [
              TmdbSeasonSummary(
                seasonNumber: 1,
                name: '第 1 季',
                episodeCount: 13,
                airDate: '2018-01-11',
              ),
            ],
          ),
          bangumi: const BangumiSubjectCandidate(
            id: 183878,
            name: 'ヴァイオレット・エヴァーガーデン',
            nameCn: '紫罗兰永恒花园',
            year: 2018,
            totalEpisodes: 13,
            platform: 'TV',
          ),
        ),
      ];

      const noiseTmdb = TmdbWorkDetail(
        tmdbId: 999001,
        mediaType: TmdbMediaType.tv,
        title: '无关真人剧集',
        originalTitle: 'Unrelated Live Show',
        year: 2025,
        voteCount: 40,
        genreIds: [18],
        seasons: [
          TmdbSeasonSummary(
            seasonNumber: 1,
            name: '第 1 季',
            episodeCount: 12,
            airDate: '2025-01-01',
          ),
        ],
      );

      var passed = 0;
      final total = specs.length * messyFolders.length;
      final failures = <String>[];

      for (final spec in specs) {
        for (final messyName in messyFolders) {
          final f = _buildGroupedFolder(
            folderPath: '网盘/$messyName',
            fileNames: [
              for (var i = 1; i <= spec.episodeCount; i++) spec.filePattern(i),
            ],
          );
          // 确认首波查询（前 3 词）必然包含规范视频文件名主干。
          final queries = ScrapeDomainAdapter.buildSearchQueries(f);
          final top3Norm = queries
              .take(3)
              .map(DirectoryAnalyzer.normalize)
              .toList();
          final expectedFileNorm = DirectoryAnalyzer.normalize(
            f.fileHints.isNotEmpty ? f.fileHints.first : f.cleanTitle,
          );
          final fileInWave1 = top3Norm.any(
            (q) =>
                q == expectedFileNorm ||
                q.contains(expectedFileNorm) ||
                expectedFileNorm.contains(q),
          );

          final decision = ScrapeDomainAdapter.evaluateMatch(
            f,
            [noiseTmdb, spec.tmdb],
            bangumiCandidates: [spec.bangumi],
          );
          final ok =
              fileInWave1 &&
              decision.level == MatchLevel.autoBind &&
              decision.best?.detail.tmdbId == spec.tmdb.tmdbId &&
              decision.matchedSeason == 1;
          if (ok) {
            passed++;
          } else {
            failures.add(
              '${spec.label} @ "$messyName": wave1=$fileInWave1 lvl=${decision.level} '
              'got=${decision.best?.detail.tmdbId}/S${decision.matchedSeason} queries=${queries.take(3).toList()}',
            );
          }
        }
      }

      final rate = passed / total;
      expect(
        rate,
        greaterThanOrEqualTo(0.97),
        reason:
            '档位 3 精准命中率 $passed/$total (${(rate * 100).toStringAsFixed(1)}%) 低于 97%：\n${failures.join('\n')}',
      );
      expect(passed, total, reason: failures.join('\n'));
    });
  });
}

GroupedWorkFolder _buildGroupedFolder({
  required String folderPath,
  required List<String> fileNames,
}) {
  final inv = DirectoryAnalyzer.analyze(folderPath, [
    for (final name in fileNames) (path: name, size: 500 * 1024 * 1024),
  ]);
  final eps = inv.episodes.toList()..sort();
  return GroupedWorkFolder(
    folderRelativePath: folderPath,
    folderName: folderPath.split('/').last,
    cleanTitle: inv.title,
    explicitTmdbId: inv.tmdbId,
    explicitMediaType: inv.tmdbType == 'movie'
        ? TmdbMediaType.movie
        : (inv.tmdbType == 'tv' ? TmdbMediaType.tv : null),
    year: inv.year,
    seasonHint: inv.season,
    mainEpisodeNumbers: eps,
    isMovieHint: inv.folderMovieMarker || inv.fileMovieMarker,
    inventory: inv,
    titleHints: inv.titleHints,
    fileHints: inv.fileHints,
    variants: [
      for (final f in fileNames)
        MediaVariant(
          id: '$folderPath/$f',
          workId: 'w',
          sourceId: 's',
          relativePath: '$folderPath/$f',
          fileName: f,
          fileSize: 500 * 1024 * 1024,
        ),
    ],
  );
}

class _MessyCaseSpec {
  const _MessyCaseSpec({
    required this.label,
    required this.filePattern,
    required this.episodeCount,
    required this.tmdb,
    required this.bangumi,
  });

  final String label;
  final String Function(int ep) filePattern;
  final int episodeCount;
  final TmdbWorkDetail tmdb;
  final BangumiSubjectCandidate bangumi;
}

class _FakeBangumiService implements BangumiService {
  _FakeBangumiService({required this.byId});

  final Map<int, BangumiSubjectCandidate> byId;
  int searchCalls = 0;

  @override
  Future<BangumiSubjectCandidate?> getSubjectDetail(
    int subjectId, {
    RequestPriority priority = RequestPriority.background,
  }) async => byId[subjectId];

  @override
  Future<List<BangumiSubjectCandidate>> searchSubjects(
    String keyword, {
    RequestPriority priority = RequestPriority.background,
    int limit = 10,
  }) async {
    searchCalls++;
    return const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTmdbService implements TmdbService {
  _FakeTmdbService({required this.details});

  final Map<String, TmdbWorkDetail> details;

  @override
  Future<TmdbWorkDetail?> getWorkDetail(
    int tmdbId,
    TmdbMediaType mediaType, {
    RequestPriority priority = RequestPriority.background,
    bool includeImages = true,
    bool includeEnglishImages = false,
  }) async => details['${mediaType.name}:$tmdbId'];

  @override
  Future<List<TmdbSearchResult>> searchAnime(
    String query, {
    int? year,
    String language = 'zh-CN',
    bool includeAdult = false,
    TmdbMediaType? mediaTypeFilter,
    RequestPriority priority = RequestPriority.background,
  }) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
