import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ccplayer/core/anime_mapping_store.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/detail_metadata.dart';
import 'package:ccplayer/core/directory_analyzer.dart';
import 'package:ccplayer/core/episode_metadata.dart';
import 'package:ccplayer/core/metadata.dart';
import 'package:ccplayer/core/personal_filename_parser.dart';
import 'package:ccplayer/core/scrape_pipeline.dart';
import 'package:ccplayer/core/selected_scan_workflow.dart';
import 'package:ccplayer/core/selected_scanner.dart';
import 'package:ccplayer/core/work_matcher.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late String savedToken, savedKey, savedMode;
  setUp(() {
    savedToken = Metadata.token;
    savedKey = Metadata.apiKey;
    savedMode = Metadata.authMode;
    Metadata.token = 'test-bearer-token';
    Metadata.apiKey = '';
    Metadata.authMode = 'token';
  });
  tearDown(() {
    Metadata.token = savedToken;
    Metadata.apiKey = savedKey;
    Metadata.authMode = savedMode;
  });

  test(
    'Edge case 1 & 2: Anitomy two-stage elimination preserves numeric anime titles, strips CRC32 & v2, and splits Roman season hints',
    () {
      // 1. Numeric anime title + fully bracketed BDRip
      const file86 =
          '[VCB-Studio] 86 -Eighty Six- [01][Ma10p_1080p][x265_flac].mkv';
      final kw86 = PersonalFilenameParser.extractAnimeTitleKeyword(file86);
      expect(kw86, contains('86'));
      expect(kw86, contains('Eighty Six'));

      final inv86 = DirectoryAnalyzer.analyze('86 -不存在的战区-', [
        (path: file86, size: 900 * 1024 * 1024),
        (
          path: '[VCB-Studio] 86 -Eighty Six- [02][Ma10p_1080p][x265_flac].mkv',
          size: 910 * 1024 * 1024,
        ),
      ]);
      expect(inv86.shape, WorkShape.series);
      expect(inv86.main.map((e) => e.episode).toList(), [1, 2]);
      expect(inv86.fileHints.any((h) => h.contains('86')), isTrue);

      // Steins;Gate 0 Episode 00 must keep '0' in title!
      const sg0 = '[VCB-Studio] Steins;Gate 0 [00][Ma10p_1080p][x265_flac].mkv';
      expect(
        PersonalFilenameParser.extractAnimeTitleKeyword(sg0),
        'Steins;Gate 0',
      );

      // 2. Numeric title + Roman numeral season + v2 revision + CRC32
      const mobFile =
          '[SubsPlease] Mob Psycho 100 II - 02v2 (1080p) [ABCD1234].mkv';
      final mobKw = PersonalFilenameParser.extractAnimeTitleKeyword(mobFile);
      expect(mobKw, 'Mob Psycho 100 II');

      final mobInv = DirectoryAnalyzer.analyze('Mob Psycho 100 II', [
        (
          path: '[SubsPlease] Mob Psycho 100 II - 01 (1080p) [11223344].mkv',
          size: 550 * 1024 * 1024,
        ),
        (path: mobFile, size: 560 * 1024 * 1024),
      ]);
      expect(mobInv.shape, WorkShape.series);
      expect(mobInv.season, 2);
      expect(mobInv.main.map((e) => e.episode).toList(), [1, 2]);
      expect(mobInv.titleHints, contains('Mob Psycho 100 II'));
      expect(mobInv.titleHints, contains('Mob Psycho 100'));
      expect(mobInv.fileHints, contains('Mob Psycho 100'));

      // Fractional episode 12.5 is preserved during dot normalization
      const recap =
          '[SubsPlease] 86 -Eighty Six- - 11.5 (1080p) [BAD7A16A].mkv';
      expect(
        PersonalFilenameParser.extractAnimeTitleKeyword(recap),
        contains('86'),
      );

      // Age token "17-sai" on theatrical movie is never misparsed as Episode 17!
      final haikara = DirectoryAnalyzer.analyze('窈窕淑女 前篇 红绪，花样的17岁', [
        (
          path:
              '[Moozzi2] Gekijouban Haikara-san ga Toru Zenpen - Benio, Hana no 17-sai [BD 1920x1080].mkv',
          size: 2000 * 1024 * 1024,
        ),
      ]);
      expect(haikara.shape, WorkShape.feature);
      expect(haikara.main.single.episode, isNull);
    },
  );

  test(
    'Edge case 3: Split-cour cumulative episodes (13~24 & ep 14) resolve Season 2 and dual-align ep/sort metadata',
    () async {
      // Single file ep 14 in Season 1 (24 eps) + Season 2 folder with cumulative 13..24
      final dmFiles = [
        for (var ep = 13; ep <= 24; ep++)
          (
            path:
                '[Group] Spy x Family Season 2 - $ep [BDRip 1920x1080 HEVC FLAC].mkv',
            size: 800 * 1024 * 1024,
          ),
      ];
      final invS2 = DirectoryAnalyzer.analyze('间谍过家家 Season 2', dmFiles);
      expect(invS2.season, 2);
      expect(invS2.episodes.first, 13);
      expect(invS2.episodes.last, 24);

      final tmdbCandidate = MatchCandidate(
        provider: 'tmdb',
        id: 120089,
        type: 'tv',
        title: '间谍过家家',
        year: 2022,
        aliases: const ['SPY×FAMILY', 'Spy x Family'],
        seasons: const [SeasonInfo(1, 12, 2022), SeasonInfo(2, 12, 2023)],
      );
      final match = WorkMatcher.tmdb(invS2, [tmdbCandidate]);
      expect(match.tier, MatchTier.medium);
      expect(match.season, 2);

      // With cross-provider Bangumi year/alias confirmation, auto-binds at MatchTier.high!
      final bgmS2 = WorkMatcher.bangumi(invS2, [
        const MatchCandidate(
          provider: 'bangumi',
          id: 404804,
          type: 'anime',
          title: '间谍过家家 第二季',
          year: 2023,
          aliases: ['SPY×FAMILY Season 2'],
          seasons: [SeasonInfo(1, 12, 2023)],
        ),
      ]);
      final highMatch = WorkMatcher.tmdb(invS2, [
        tmdbCandidate,
      ], bangumi: bgmS2);
      expect(highMatch.tier, MatchTier.high);
      expect(highMatch.season, 2);

      // Dungeon Meshi ep 13~14 extracts clean title and cumulative episodes
      expect(
        PersonalFilenameParser.extractAnimeTitleKeyword(
          '[Group] Dungeon Meshi - 14 [BDRip 1920x1080 HEVC FLAC].mkv',
        ),
        'Dungeon Meshi',
      );
      final dm14 = DirectoryAnalyzer.analyze('迷宫饭', [
        (
          path: '[Group] Dungeon Meshi - 13 [BDRip 1920x1080 HEVC FLAC].mkv',
          size: 810 * 1024 * 1024,
        ),
        (
          path: '[Group] Dungeon Meshi - 14 [BDRip 1920x1080 HEVC FLAC].mkv',
          size: 820 * 1024 * 1024,
        ),
      ]);
      expect(dm14.shape, WorkShape.series);
      expect(dm14.episodes, {13, 14});
      expect(dm14.fileHints, contains('Dungeon Meshi'));

      // EpisodeMetadata.lookup subtracts prior season count (14 - 12 = S2E2)
      final details = <String, dynamic>{
        'seasonEpisodeCounts': {'1': 12, '2': 12},
        'seasonEpisodes': {
          '2': {
            '2': {'name': '第二季第2话（总第14话）', 'still': 'https://img/s2e2.jpg'},
          },
        },
      };
      final resolvedEp = EpisodeMetadata.lookup(
        {'id': 'work:1:spy-s2', 'title': '间谍过家家 第2季', 'tmdb_type': 'tv'},
        details,
        {
          'name': '[Group] Spy x Family - 14 [1080p].mkv',
          'relative_path': '间谍过家家 第2季/[Group] Spy x Family - 14 [1080p].mkv',
          'category': 'main',
          'season': 2,
          'episode': 14,
        },
      );
      expect(resolvedEp['name'], '第二季第2话（总第14话）');

      // DetailMetadataService indexes both relative `ep` (1..12) AND cumulative `sort` (13..24) from Bangumi
      final bgmClient = MockClient((req) async {
        if (req.url.path == '/v0/subjects/373267') {
          return _json({
            'id': 373267,
            'name': 'SPY×FAMILY Cour 2',
            'name_cn': '间谍过家家 第二部',
            'date': '2022-10-01',
          });
        }
        if (req.url.path == '/v0/episodes') {
          return _json({
            'total': 2,
            'data': [
              {
                'type': 0,
                'ep': 1,
                'sort': 13,
                'name': 'Project Apple',
                'name_cn': '苹果计划',
              },
              {
                'type': 0,
                'ep': 2,
                'sort': 14,
                'name': 'Disarm the Time Bomb',
                'name_cn': '解除定时炸弹',
              },
            ],
          });
        }
        return _json({}, 404);
      });
      final detailSvc = DetailMetadataService(
        client: bgmClient,
        tmdbRequest: (_, _) async => null,
      );
      final bgmDetail = await detailSvc.fetch(
        {'id': 'work:1:spy', 'title': '间谍过家家', 'bangumi_id': 373267},
        assets: [
          {'category': 'main', 'season': 1, 'episode': 14},
        ],
      );
      final s1Map = (bgmDetail['seasonEpisodes'] as Map)['1'] as Map;
      expect(s1Map['1']['name'], '苹果计划');
      expect(s1Map['2']['name'], '解除定时炸弹');
      expect(s1Map['13']['name'], '苹果计划');
      expect(s1Map['14']['name'], '解除定时炸弹');
      detailSvc.close();
      bgmClient.close();
    },
  );

  test(
    'Edge case 4: BDRip extras (Menu/NCOP/NCED/PV) mixed with episodes + size-distribution guard + folder pruning',
    () {
      // Mixed BDRip directory: 01~12 (800 MB) + Menu, NCOP1, NCED1, PV01 (35 MB) + tiny unnumbered clip (20 MB)
      final bdFiles = <({String path, int? size})>[
        for (var i = 1; i <= 12; i++)
          (
            path:
                '[VCB-Studio] Hyouka [${i.toString().padLeft(2, '0')}][Ma10p_1080p][x265_flac].mkv',
            size: 800 * 1024 * 1024,
          ),
        (
          path: 'Menu/[VCB-Studio] Hyouka [Menu01][1080p].mkv',
          size: 45 * 1024 * 1024,
        ),
        (
          path: '[VCB-Studio] Hyouka [NCOP1][1080p].mkv',
          size: 38 * 1024 * 1024,
        ),
        (
          path: '[VCB-Studio] Hyouka [NCED1][1080p].mkv',
          size: 36 * 1024 * 1024,
        ),
        (
          path: 'SPs/[VCB-Studio] Hyouka [PV01][1080p].mkv',
          size: 25 * 1024 * 1024,
        ),
        (
          path: '[VCB-Studio] Hyouka Web Spot [1080p].mkv',
          size: 15 * 1024 * 1024,
        ),
      ];
      final bdInv = DirectoryAnalyzer.analyze('冰菓 (2012)', bdFiles);
      expect(bdInv.shape, WorkShape.series);
      expect(bdInv.episodeCount, 12);
      expect(bdInv.extras, hasLength(5));

      // Sole 600 MB main movie whose title contains ambiguous word ("Event"/"Talk") is rescued by size guard!
      final soleFeature = DirectoryAnalyzer.analyze('凉宫春日的消失 Event Screening', [
        (
          path: '[Group] Suzumiya Haruhi Event Movie [1080p].mkv',
          size: 600 * 1024 * 1024,
        ),
      ]);
      expect(soleFeature.shape, WorkShape.feature);
      expect(soleFeature.main, hasLength(1));

      // Unambiguous Sample / NCOP alone still remains WorkShape.empty!
      final sampleOnly = DirectoryAnalyzer.analyze('测试目录', [
        (path: 'Sample.mkv', size: 600 * 1024 * 1024),
      ]);
      expect(sampleOnly.shape, WorkShape.empty);

      // SelectedScanner.excluded prunes non-video asset trees (Gallery/絵コンテ集, 特典CD) while keeping Menu/SPs!
      expect(
        SelectedScanner.excluded(
          '未添加TMDB ID/机动战士高达 第08MS小队 (1996) {tmdb-43887}/Gallery/絵コンテ集/第01話Bパート',
          '未添加TMDB ID',
        ),
        isTrue,
      );
      expect(
        SelectedScanner.excluded(
          '未添加TMDB ID/Wake Up, Girls! 七人的偶像/特典CD',
          '未添加TMDB ID',
        ),
        isTrue,
      );
      expect(
        SelectedScanner.excluded(
          '未添加TMDB ID/Wake Up, Girls! 七人的偶像/Menu',
          '未添加TMDB ID',
        ),
        isFalse,
      );
      expect(
        SelectedScanner.excluded('未添加TMDB ID/冰菓/SPs', '未添加TMDB ID'),
        isFalse,
      );
    },
  );

  test(
    'Edge case 5 & Live Regressions: [bgm_N]/tvshow.nfo/bangumi-tmdb bridge, 女王之刃 x3 distinct covers/titles, 快盗天使防误配, WUG 新章, and transient error isolation',
    () async {
      final root = await Directory.systemTemp.createTemp('konata-comm-e2e-');
      final dataDir = await Directory.systemTemp.createTemp('konata-comm-db-');
      final catalog = Catalog.instance;
      await catalog.initialize(dataDirectory: dataDir);
      await AnimeMappingStore.createSchema(catalog.db);
      addTearDown(() async {
        await catalog.db.close();
        await root.delete(recursive: true);
        await dataDir.delete(recursive: true);
      });

      // Seed open-ani/bangumi-tmdb mapping row in SQLite for Bangumi 40001 -> TMDB tv:90001 S1
      await catalog.db.insert('mapping_batches', {
        'id': 'b1',
        'version': '0123456789abcdef0123456789abcdef01234567',
        'kind': 'index',
        'state': 'ready',
      });
      await catalog.db.insert('mapping_subjects', {
        'batch': 'b1',
        'subject': 40001,
        'targets': jsonEncode([
          {'type': 'tv', 'id': 90001, 'season': 1},
        ]),
      });

      // 1. Explicit [bgm_40001] folder bridged to TMDB tv:90001 via open-ani/bangumi-tmdb!
      final bgmDir = await Directory(
        '${root.path}/[bgm_40001] Kono Bijutsubu ni wa Mondai ga Aru!',
      ).create();
      for (var i = 1; i <= 12; i++) {
        await File(
          '${bgmDir.path}/[${i.toString().padLeft(2, '0')}].mkv',
        ).writeAsBytes([i]);
      }

      // 2. Local read-only tvshow.nfo marker folder (strictly read-only, 0 writes)
      final nfoDir = await Directory(
        '${root.path}/Custom Folder Name',
      ).create();
      await File('${nfoDir.path}/tvshow.nfo').writeAsString(
        '<?xml version="1.0" encoding="UTF-8"?><tvshow><tmdbid>90002</tmdbid><bangumiid>40002</bangumiid></tvshow>',
      );
      await File('${nfoDir.path}/01.mkv').writeAsBytes([1]);
      await File('${nfoDir.path}/02.mkv').writeAsBytes([2]);

      // 3. 女王之刃 3 installments sharing TMDB tv:45502 (single 24-ep season on TMDB) -> MUST keep 3 distinct titles & 3 distinct Bangumi covers!
      for (final (subName, count) in [
        ('女王之刃 流浪的战士', 12),
        ('女王之刃 王座的继承者', 12),
        ('女王之刃 美丽女斗士们', 6),
      ]) {
        final d = await Directory('${root.path}/$subName').create();
        for (var i = 1; i <= count; i++) {
          await File(
            '${d.path}/[${i.toString().padLeft(2, '0')}].mkv',
          ).writeAsBytes([i]);
        }
      }

      // 4. 快盗天使双胞胎~心跳不已☆甜蜜天堂!!~ -> MUST NOT match 快盗天使BREAK (tv:71021)!
      final twinDir = await Directory(
        '${root.path}/快盗天使双胞胎~心跳不已☆甜蜜天堂!!~',
      ).create();
      for (var i = 1; i <= 12; i++) {
        await File(
          '${twinDir.path}/[Moozzi2] Kaitou Tenshi Twin Angel - ${i.toString().padLeft(2, '0')} [1080p].mkv',
        ).writeAsBytes([i]);
      }

      // 5. Wake Up, Girls! (S1) vs Wake Up, Girls! 新章 (S2) -> distinct titles & season covers!
      final wug1 = await Directory('${root.path}/Wake Up, Girls!').create();
      final wug2 = await Directory('${root.path}/Wake Up, Girls! 新章').create();
      for (var i = 1; i <= 12; i++) {
        await File(
          '${wug1.path}/[${i.toString().padLeft(2, '0')}].mkv',
        ).writeAsBytes([i]);
        await File(
          '${wug2.path}/[${i.toString().padLeft(2, '0')}].mkv',
        ).writeAsBytes([i]);
      }

      final client = MockClient((req) async {
        final path = req.url.path;
        if (path == '/v0/subjects/40001') {
          return _json({
            'id': 40001,
            'name': 'この美術部には問題がある！',
            'name_cn': '这个美术社大有问题！',
            'date': '2016-07-07',
            'total_episodes': 12,
            'images': {'large': 'https://lain.bgm.tv/konobi.jpg'},
          });
        }
        if (path == '/3/tv/90001') {
          return _json({
            'id': 90001,
            'name': '这个美术社大有问题！',
            'original_name': 'この美術部には問題がある！',
            'first_air_date': '2016-07-07',
            'poster_path': '/konobi-tmdb.jpg',
            'seasons': [
              {
                'season_number': 1,
                'episode_count': 12,
                'air_date': '2016-07-07',
              },
            ],
          });
        }
        if (path == '/3/tv/90001/season/1') {
          return _json({'season_number': 1, 'poster_path': '/konobi-s1.jpg'});
        }
        if (path == '/3/tv/90002') {
          return _json({
            'id': 90002,
            'name': 'NFO 定投测试番剧',
            'first_air_date': '2020-01-01',
            'poster_path': '/nfo-tmdb.jpg',
            'seasons': [
              {
                'season_number': 1,
                'episode_count': 2,
                'air_date': '2020-01-01',
              },
            ],
          });
        }
        if (path == '/v0/subjects/40002') {
          return _json({
            'id': 40002,
            'name': 'NFO 定投测试番剧',
            'name_cn': 'NFO 定投测试番剧',
            'date': '2020-01-01',
            'images': {'large': 'https://lain.bgm.tv/nfo.jpg'},
          });
        }

        // Bangumi searches
        if (path == '/v0/search/subjects') {
          final kw = (jsonDecode(req.body) as Map)['keyword'].toString();
          if (kw.contains('流浪的战士')) {
            return _json({
              'data': [
                {
                  'id': 1434,
                  'name': 'クイーンズブレイド 流浪の戦士',
                  'name_cn': '女王之刃 流浪的战士',
                  'date': '2009-04-02',
                  'total_episodes': 12,
                },
              ],
            });
          }
          if (kw.contains('王座的继承者')) {
            return _json({
              'data': [
                {
                  'id': 2600,
                  'name': 'クイーンズブレイド 玉座を継ぐ者',
                  'name_cn': '女王之刃 王座的继承者',
                  'date': '2009-09-24',
                  'total_episodes': 12,
                },
              ],
            });
          }
          if (kw.contains('美丽女斗士们')) {
            return _json({
              'data': [
                {
                  'id': 7711,
                  'name': 'クイーンズブレイド 美しき闘士たち',
                  'name_cn': '女王之刃 美丽女斗士们',
                  'date': '2010-08-08',
                  'total_episodes': 6,
                },
              ],
            });
          }
          if (kw.contains('新章')) {
            return _json({
              'data': [
                {
                  'id': 202260,
                  'name': 'Wake Up, Girls! 新章',
                  'name_cn': 'Wake Up, Girls! 新章',
                  'date': '2017-10-09',
                  'total_episodes': 12,
                },
              ],
            });
          }
          if (kw.contains('Wake Up')) {
            return _json({
              'data': [
                {
                  'id': 48880,
                  'name': 'Wake Up, Girls!',
                  'name_cn': 'Wake Up, Girls!',
                  'date': '2014-01-10',
                  'total_episodes': 12,
                },
                {
                  'id': 202260,
                  'name': 'Wake Up, Girls! 新章',
                  'name_cn': 'Wake Up, Girls! 新章',
                  'date': '2017-10-09',
                  'total_episodes': 12,
                },
              ],
            });
          }
          return _json({'data': []});
        }
        if (path == '/v0/subjects/1434') {
          return _json({
            'id': 1434,
            'name': 'クイーンズブレイド 流浪の戦士',
            'name_cn': '女王之刃 流浪的战士',
            'date': '2009-04-02',
            'images': {'large': 'https://lain.bgm.tv/qb1.jpg'},
          });
        }
        if (path == '/v0/subjects/2600') {
          return _json({
            'id': 2600,
            'name': 'クイーンズブレイド 玉座を継ぐ者',
            'name_cn': '女王之刃 王座的继承者',
            'date': '2009-09-24',
            'images': {'large': 'https://lain.bgm.tv/qb2.jpg'},
          });
        }
        if (path == '/v0/subjects/7711') {
          return _json({
            'id': 7711,
            'name': 'クイーンズブレイド 美しき闘士たち',
            'name_cn': '女王之刃 美丽女斗士们',
            'date': '2010-08-08',
            'images': {'large': 'https://lain.bgm.tv/qb3.jpg'},
          });
        }
        if (path == '/v0/subjects/48880') {
          return _json({
            'id': 48880,
            'name': 'Wake Up, Girls!',
            'name_cn': 'Wake Up, Girls!',
            'date': '2014-01-10',
            'images': {'large': 'https://lain.bgm.tv/wug1.jpg'},
          });
        }
        if (path == '/v0/subjects/202260') {
          return _json({
            'id': 202260,
            'name': 'Wake Up, Girls! 新章',
            'name_cn': 'Wake Up, Girls! 新章',
            'date': '2017-10-09',
            'images': {'large': 'https://lain.bgm.tv/wug2.jpg'},
          });
        }

        // TMDB searches
        if (path == '/3/search/tv') {
          final q = req.url.queryParameters['query'] ?? '';
          if (q.contains('女王之刃') || q.contains('クイーンズブレイド')) {
            return _json({
              'results': [
                {
                  'id': 45502,
                  'name': '女王之刃',
                  'original_name': 'クイーンズブレイド',
                  'first_air_date': '2009-04-02',
                },
              ],
            });
          }
          if (q.contains('快盗天使') || q.contains('Twin Angel')) {
            // Simulate TMDB only returning the 2017 sequel/spin-off 快盗天使BREAK!
            return _json({
              'results': [
                {
                  'id': 71021,
                  'name': '快盗天使BREAK',
                  'original_name': 'ツインエンジェルBREAK',
                  'first_air_date': '2017-04-07',
                },
              ],
            });
          }
          if (q.contains('Wake Up')) {
            return _json({
              'results': [
                {
                  'id': 61419,
                  'name': 'Wake Up, Girls!',
                  'original_name': 'Wake Up, Girls!',
                  'first_air_date': '2014-01-11',
                },
              ],
            });
          }
          return _json({'results': []});
        }
        if (path == '/3/tv/45502') {
          return _json({
            'id': 45502,
            'name': '女王之刃',
            'original_name': 'クイーンズブレイド',
            'first_air_date': '2009-04-02',
            'poster_path': '/qb-generic.jpg',
            'seasons': [
              {
                'season_number': 1,
                'episode_count': 24,
                'air_date': '2009-04-02',
              },
            ],
          });
        }
        if (path == '/3/tv/71021') {
          return _json({
            'id': 71021,
            'name': '快盗天使BREAK',
            'original_name': 'ツインエンジェルBREAK',
            'first_air_date': '2017-04-07',
            'poster_path': '/break-wrong.jpg',
            'seasons': [
              {
                'season_number': 1,
                'episode_count': 12,
                'air_date': '2017-04-07',
              },
            ],
          });
        }
        if (path == '/3/tv/61419') {
          return _json({
            'id': 61419,
            'name': 'Wake Up, Girls!',
            'original_name': 'Wake Up, Girls!',
            'first_air_date': '2014-01-11',
            'poster_path': '/wug-series.jpg',
            'seasons': [
              {
                'season_number': 1,
                'episode_count': 12,
                'air_date': '2014-01-11',
              },
              {
                'season_number': 2,
                'episode_count': 12,
                'air_date': '2017-10-09',
                'name': '新章',
              },
            ],
          });
        }
        if (path == '/3/tv/61419/season/1') {
          return _json({'season_number': 1, 'poster_path': '/wug-s1.jpg'});
        }
        if (path == '/3/tv/61419/season/2') {
          return _json({'season_number': 2, 'poster_path': '/wug-s2.jpg'});
        }
        return _json({}, 404);
      });

      final sourceId = await catalog.addSource('local', '回归验收库', root.path);
      await catalog.addScanRoot(sourceId, '');
      await SelectedScanWorkflow.run(
        catalog.sourceOf(sourceId),
        pipeline: ScrapePipeline(catalog: catalog, client: client),
      );

      // Verify [bgm_40001] -> open-ani/bangumi-tmdb bridge -> TMDB tv:90001 S1
      final konobi = catalog.works.singleWhere((w) => w['bangumi_id'] == 40001);
      expect(konobi['tmdb_id'], 90001);
      expect(konobi['needs_review'], 0);

      // Verify read-only tvshow.nfo binding (and zero sidecar writes into nfoDir!)
      final nfoWork = catalog.works.singleWhere((w) => w['tmdb_id'] == 90002);
      expect(nfoWork['bangumi_id'], 40002);
      final nfoFiles = nfoDir
          .listSync()
          .map((e) => e.uri.pathSegments.last)
          .toSet();
      expect(nfoFiles, {'tvshow.nfo', '01.mkv', '02.mkv'});

      // Verify 女王之刃 3 installments keep 3 distinct titles AND 3 distinct Bangumi covers!
      final qbWorks = catalog.works
          .where((w) => const {1434, 2600, 7711}.contains(w['bangumi_id']))
          .toList();
      expect(qbWorks, hasLength(3));
      expect(qbWorks.map((w) => w['title']).toSet(), {
        '女王之刃 流浪的战士',
        '女王之刃 王座的继承者',
        '女王之刃 美丽女斗士们',
      });
      expect(qbWorks.map((w) => Catalog.preferredPoster(w)).toSet(), {
        'https://lain.bgm.tv/qb1.jpg',
        'https://lain.bgm.tv/qb2.jpg',
        'https://lain.bgm.tv/qb3.jpg',
      });

      // Verify 快盗天使双胞胎 rejects 快盗天使BREAK (tv:71021)!
      expect(catalog.works.where((w) => w['tmdb_id'] == 71021), isEmpty);
      final twinWork = catalog.works.singleWhere(
        (w) => w['title'].toString().contains('快盗天使双胞胎'),
      );
      expect(twinWork['poster'], isNull);
      expect(twinWork['needs_review'], 1);

      // Verify Wake Up, Girls! S1 vs 新章 S2 have distinct titles and covers!
      final wugWorks = catalog.works
          .where((w) => w['tmdb_id'] == 61419)
          .toList();
      expect(wugWorks, hasLength(2));
      expect(wugWorks.map((w) => w['title']).toSet(), {
        'Wake Up, Girls!',
        'Wake Up, Girls! 新章',
      });
      expect(wugWorks.map((w) => w['poster']).toSet(), {
        'https://image.tmdb.org/t/p/w500/wug-s1.jpg',
        'https://image.tmdb.org/t/p/w500/wug-s2.jpg',
      });

      // 6. Transient network timeout MUST NOT wipe already-bound metadata!
      final timeoutClient = MockClient((_) async {
        throw TimeoutException('Simulated transient API timeout');
      });
      final errPipeline = ScrapePipeline(
        catalog: catalog,
        client: timeoutClient,
      );
      final summary = await errPipeline.scrapeSource(
        sourceId,
        onlyPending: false,
      );
      expect(summary.errors, greaterThan(0));

      await catalog.reload();
      final konobiAfter = catalog.works.singleWhere(
        (w) => w['id'] == konobi['id'],
      );
      expect(konobiAfter['tmdb_id'], 90001);
      expect(konobiAfter['bangumi_id'], 40001);
      expect(
        konobiAfter['poster'],
        'https://image.tmdb.org/t/p/w500/konobi-s1.jpg',
      );
      expect(konobiAfter['needs_review'], 0);

      errPipeline.close();
      timeoutClient.close();
      client.close();
    },
  );
}
