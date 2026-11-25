import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:engine_scraping/engine_scraping.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/test_helpers.dart';

void main() {
  group('BangumiTmdbIndex 二进制编解码与实测基准校验', () {
    test('编码、二分查找、多目标季号解析与损坏头拦截', () {
      final raw = BangumiTmdbIndex.encode(
        const [
          BangumiTmdbRecord(
            bangumiId: 300,
            type: TmdbMediaType.tv,
            tmdbId: 9001,
            season: 2,
            flags: BangumiTmdbTarget.flagOpenAni,
          ),
          BangumiTmdbRecord(
            bangumiId: 100,
            type: TmdbMediaType.movie,
            tmdbId: 12345,
            flags: BangumiTmdbTarget.flagWikidata,
          ),
          BangumiTmdbRecord(
            bangumiId: 300,
            type: TmdbMediaType.movie,
            tmdbId: 9002,
            flags:
                BangumiTmdbTarget.flagOpenAni | BangumiTmdbTarget.flagWikidata,
          ),
        ],
        snapshotDateYyyymmdd: 20261120,
      );

      final index = BangumiTmdbIndex.fromBytes(raw);
      expect(index.recordCount, 3);
      expect(index.uniqueBangumiCount, 2);
      expect(index.formattedSnapshotDate, '2026-11-20');

      final hit100 = index.lookup(100);
      expect(hit100, hasLength(1));
      expect(hit100.first.key, 'movie:12345');
      expect(hit100.first.season, isNull);
      expect(hit100.first.isWikidata, isTrue);

      final hit300 = index.lookup(300);
      expect(hit300, hasLength(2));
      expect(hit300.map((e) => e.key), containsAll(['tv:9001', 'movie:9002']));
      final tvHit = hit300.firstWhere((e) => e.type == TmdbMediaType.tv);
      expect(tvHit.season, 2);
      expect(tvHit.isOpenAni, isTrue);

      expect(index.lookup(999999), isEmpty);

      // 魔数损坏与截断字节必须被严格拒绝
      final badMagic = Uint8List.fromList(raw)..[0] = 0x00;
      expect(
        () => BangumiTmdbIndex.fromBytes(badMagic),
        throwsA(isA<FormatException>()),
      );
      final truncated = Uint8List.sublistView(raw, 0, raw.length - 4);
      expect(
        () => BangumiTmdbIndex.fromBytes(truncated),
        throwsA(isA<FormatException>()),
      );
    });

    test('随包资产 bangumi_tmdb_map.bin 可直接载入且在 r7 验收库保持零误绑与定季提升', () {
      final binFile = resolveRepoAssetFile('assets/data/bangumi_tmdb_map.bin');
      expect(binFile.existsSync(), isTrue);
      final bytes = binFile.readAsBytesSync();
      final index = BangumiTmdbIndex.fromBytes(bytes);

      expect(index.uniqueBangumiCount, greaterThanOrEqualTo(20000));
      expect(index.recordCount, greaterThanOrEqualTo(index.uniqueBangumiCount));
      // 验证经典条目与 Season 0 特典条目映射均已保留
      expect(
        index.lookup(237).any((e) => e.key == 'movie:9323'),
        isTrue,
      );
      expect(
        index.lookup(22599).any((e) => e.key == 'tv:45305' && e.season == 0),
        isTrue,
      );

      // 使用真实二进制映射表通过生产适配器 evaluateMatch 重跑 r7 离线基准，
      // 验证跨库防误拼与映射定季协同后保持零误绑且季号准确度不回退
      final fixture =
          jsonDecode(
                File(
                  'test/scraping_parity/fixtures/r7_scrape_benchmark.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final works = (fixture['works'] as List).cast<Map<String, dynamic>>();

      var tmdbWrong = 0;
      var tmdbBound = 0;
      var seasonRight = 0;
      var seasonWrong = 0;
      var seasonUnresolved = 0;
      final wrongDetails = <String>[];

      for (final work in works) {
        final relPath = work['path'] as String;
        final inventory = DirectoryAnalyzer.analyze(relPath, [
          for (final file in (work['files'] as List<Object?>).whereType<List<Object?>>())
            (path: file[0] as String, size: (file[1] as num?)?.toInt()),
        ]);
        final folder = GroupedWorkFolder(
          folderRelativePath: relPath,
          folderName: relPath.split('/').last,
          cleanTitle: inventory.title,
          explicitTmdbId: inventory.tmdbId,
          explicitMediaType: inventory.tmdbType == null
              ? null
              : (inventory.tmdbType == 'movie'
                    ? TmdbMediaType.movie
                    : TmdbMediaType.tv),
          year: inventory.year,
          seasonHint: inventory.season,
          mainEpisodeNumbers: inventory.episodes.toList(growable: false),
          isMovieHint: inventory.folderMovieMarker,
          variants: const [],
          inventory: inventory,
        );
        final bgmCands = [
          for (final row in (work['bangumi'] as List<Object?>).whereType<Map<String, Object?>>())
            BangumiSubjectCandidate(
              id: (row['id'] as num).toInt(),
              name: (row['title'] ?? '').toString(),
              nameCn: (row['title'] ?? '').toString(),
              year: (row['year'] as num?)?.toInt(),
              aliases: [
                for (final a in ((row['aliases'] as List<Object?>?) ?? const <Object?>[]))
                  a.toString(),
              ],
            ),
        ];
        final tmdbCands = [
          for (final row in (work['tmdb'] as List<Object?>).whereType<Map<String, Object?>>())
            TmdbWorkDetail(
              tmdbId: (row['id'] as num).toInt(),
              mediaType: row['type'] == 'movie'
                  ? TmdbMediaType.movie
                  : TmdbMediaType.tv,
              title: (row['title'] ?? '').toString(),
              year: (row['year'] as num?)?.toInt(),
              aliases: [
                for (final a in ((row['aliases'] as List<Object?>?) ?? const <Object?>[]))
                  a.toString(),
              ],
              seasons: [
                for (final s in ((row['seasons'] as List<Object?>?) ?? const <Object?>[]).whereType<List<Object?>>())
                  TmdbSeasonSummary(
                    seasonNumber: (s[0] as num).toInt(),
                    name: 'Season ${(s[0] as num).toInt()}',
                    episodeCount: (s[1] as num).toInt(),
                    airDate: s[2] == null ? null : '${s[2]}-01-01',
                  ),
              ],
            ),
        ];

        final decision = evaluateMatch(
          folder,
          tmdbCands,
          bangumiCandidates: bgmCands,
          mappingIndex: index,
        );
        final expectMap = work['expect'] as Map<String, dynamic>;
        if (!expectMap.containsKey('tmdb')) continue;
        final wantKey = expectMap['tmdb'] as String?;
        final gotDetail = decision.level == MatchLevel.unmatched
            ? null
            : decision.best?.detail;
        final gotKey = gotDetail == null
            ? null
            : '${gotDetail.mediaType.name}:${gotDetail.tmdbId}';
        if (wantKey != null && gotKey == wantKey) {
          tmdbBound++;
          final wantSeason = expectMap['season'] as int?;
          if (wantSeason != null) {
            final gotSeason = decision.matchedSeason;
            if (gotSeason == wantSeason) {
              seasonRight++;
            } else if (gotSeason == null) {
              seasonUnresolved++;
            } else {
              seasonWrong++;
            }
          }
        } else if (gotKey != null && gotKey != wantKey) {
          tmdbWrong++;
          wrongDetails.add(
            'path=$relPath want=$wantKey got=$gotKey '
            'level=${decision.level} reason=${decision.primaryReason}',
          );
        }
      }

      stdout.writeln(
        'r7 binary-index adapter check: tmdbBound=$tmdbBound, '
        'tmdbWrong=$tmdbWrong, seasonRight=$seasonRight, '
        'seasonUnresolved=$seasonUnresolved, seasonWrong=$seasonWrong',
      );
      expect(tmdbWrong, 0, reason: wrongDetails.join('\n'));
      expect(seasonWrong, 0);
      expect(tmdbBound, greaterThanOrEqualTo(145));
      expect(seasonRight, greaterThanOrEqualTo(66));
    });
  });

  group('BangumiTmdbMapUpdater 24 小时静默热更新与多镜像容灾', () {
    late Directory tempRoot;
    late StorageRootPort storageRoot;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('konata_map_upd_');
      storageRoot = PortableStorageRootService(overrideRootPath: tempRoot.path);
      
    });

    tearDown(() async {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    Uint8List buildBin({required int dateInt, required List<BangumiTmdbRecord> recs}) =>
        BangumiTmdbIndex.encode(recs, snapshotDateYyyymmdd: dateInt);

    Future<Uint8List?> Function(String) fakeAssetLoader(Uint8List bytes) {
      return (_) async => bytes;
    }

    test('多镜像回退成功下载、校验 SHA-256 原子落盘，并在 24 小时内静默跳过重复检查', () async {
      final bundledBytes = buildBin(
        dateInt: 20261110,
        recs: const [
          BangumiTmdbRecord(
            bangumiId: 10,
            type: TmdbMediaType.tv,
            tmdbId: 1000,
            season: 1,
          ),
        ],
      );
      final remoteBytes = buildBin(
        dateInt: 20261121,
        recs: const [
          BangumiTmdbRecord(
            bangumiId: 10,
            type: TmdbMediaType.tv,
            tmdbId: 1000,
            season: 1,
          ),
          BangumiTmdbRecord(
            bangumiId: 20,
            type: TmdbMediaType.tv,
            tmdbId: 2000,
            season: 2,
          ),
        ],
      );
      final remoteSha = sha256.convert(remoteBytes).toString();
      final remoteManifest = jsonEncode({
        'schemaVersion': 1,
        'snapshotDate': '2026-11-21',
        'recordCount': 2,
        'uniqueBangumiCount': 2,
        'binBytes': remoteBytes.length,
        'binSha256': remoteSha,
      });

      var now = DateTime.utc(2026, 11, 21, 8, 0, 0);
      final visitedHosts = <String>[];
      final mockClient = MockClient((request) async {
        visitedHosts.add(request.url.host);
        if (request.url.host == 'mirror1.example') {
          return http.Response('upstream error', 502);
        }
        if (request.url.path.endsWith('/manifest.json')) {
          if (request.headers['If-None-Match'] == '"etag-v2"') {
            return http.Response('', 304);
          }
          return http.Response(
            remoteManifest,
            200,
            headers: const {'etag': '"etag-v2"'},
          );
        }
        if (request.url.path.endsWith('/bangumi_tmdb_map.bin')) {
          return http.Response.bytes(remoteBytes, 200);
        }
        return http.Response('not found', 404);
      });

      final stateStore = InMemoryMappingUpdateStateStore();
      final updater = BangumiTmdbMapUpdater(
        storageRoot: storageRoot,
        stateStore: stateStore,
        bundledAssetLoader: fakeAssetLoader(bundledBytes),
        httpClient: mockClient,
        nowProvider: () => now,
        mirrorBases: const [
          'https://mirror1.example/mapping',
          'https://mirror2.example/mapping',
        ],
      );

      // 首次载入应命中内置资产
      final initial = await updater.loadActiveSnapshot();
      expect(initial.source, BangumiTmdbMapSource.bundledAsset);
      expect(initial.uniqueBangumiCount, 1);

      // 触发更新：节点 1 返回 502 自动回退至节点 2 并原子更新成功
      final firstUpdate = await updater.checkAndUpdateIfDue(force: false);
      expect(firstUpdate.state, BangumiTmdbUpdateState.updated);
      expect(firstUpdate.snapshot.source, BangumiTmdbMapSource.localHotUpdate);
      expect(firstUpdate.snapshot.uniqueBangumiCount, 2);
      expect(firstUpdate.snapshot.index.lookup(20).first.season, 2);
      expect(visitedHosts, contains('mirror1.example'));
      expect(visitedHosts, contains('mirror2.example'));

      // 6 小时后再次自动检查：应静默跳过，零网络请求
      final countBeforeSkip = visitedHosts.length;
      now = now.add(const Duration(hours: 6));
      final skipped = await updater.checkAndUpdateIfDue(force: false);
      expect(skipped.state, BangumiTmdbUpdateState.skippedNotDue);
      expect(visitedHosts.length, countBeforeSkip);

      // 25 小时后到期检查：节点 2 命中 ETag 304，不重下二进制文件
      now = now.add(const Duration(hours: 19));
      final rechecked = await updater.checkAndUpdateIfDue(force: false);
      expect(rechecked.state, BangumiTmdbUpdateState.upToDate);
      expect(rechecked.snapshot.uniqueBangumiCount, 2);
    });

    test('SHA-256 校验失败拒绝覆盖现有可用快照，损坏本地文件可自动自愈回退内置快照', () async {
      final bundledBytes = buildBin(
        dateInt: 20261110,
        recs: const [
          BangumiTmdbRecord(
            bangumiId: 10,
            type: TmdbMediaType.tv,
            tmdbId: 1000,
          ),
        ],
      );
      final tamperedBytes = Uint8List.fromList(bundledBytes)..[0] = 0xFF;

      final mockClient = MockClient((request) async {
        if (request.url.path.endsWith('/manifest.json')) {
          return http.Response(
            jsonEncode({
              'schemaVersion': 1,
              'snapshotDate': '2026-11-22',
              'recordCount': 1,
              'uniqueBangumiCount': 1,
              'binBytes': tamperedBytes.length,
              'binSha256': 'a' * 64,
            }),
            200,
          );
        }
        return http.Response.bytes(tamperedBytes, 200);
      });

      final stateStore = InMemoryMappingUpdateStateStore();
      final updater = BangumiTmdbMapUpdater(
        storageRoot: storageRoot,
        stateStore: stateStore,
        bundledAssetLoader: fakeAssetLoader(bundledBytes),
        httpClient: mockClient,
        mirrorBases: const ['https://mirror.example/mapping'],
      );

      final failed = await updater.checkAndUpdateIfDue(force: true);
      expect(failed.state, BangumiTmdbUpdateState.failed);
      expect(failed.snapshot.source, BangumiTmdbMapSource.bundledAsset);

      // 人为写入损坏本地文件，验证 loadActiveSnapshot 自动清理并回退内置资产
      final userdata = Directory(await storageRoot.ensureUserdataDirPath());
      final corruptFile = File(p.join(userdata.path, 'bangumi_tmdb_map.bin'));
      await corruptFile.writeAsBytes(const [1, 2, 3, 4, 5], flush: true);

      final healed = await updater.loadActiveSnapshot();
      expect(healed.source, BangumiTmdbMapSource.bundledAsset);
      expect(corruptFile.existsSync(), isFalse);
    });

    test('安装包内置快照日期新于本地旧热更新文件时自动选用新版内置快照', () async {
      final oldLocal = buildBin(
        dateInt: 20261101,
        recs: const [
          BangumiTmdbRecord(
            bangumiId: 10,
            type: TmdbMediaType.tv,
            tmdbId: 1000,
          ),
        ],
      );
      final newerBundled = buildBin(
        dateInt: 20261125,
        recs: const [
          BangumiTmdbRecord(
            bangumiId: 10,
            type: TmdbMediaType.tv,
            tmdbId: 1000,
          ),
          BangumiTmdbRecord(
            bangumiId: 99,
            type: TmdbMediaType.movie,
            tmdbId: 9999,
          ),
        ],
      );
      final userdata = Directory(await storageRoot.ensureUserdataDirPath());
      await File(
        p.join(userdata.path, 'bangumi_tmdb_map.bin'),
      ).writeAsBytes(oldLocal, flush: true);

      final stateStore = InMemoryMappingUpdateStateStore();
      final updater = BangumiTmdbMapUpdater(
        storageRoot: storageRoot,
        stateStore: stateStore,
        bundledAssetLoader: fakeAssetLoader(newerBundled),
      );
      final active = await updater.loadActiveSnapshot();
      expect(active.source, BangumiTmdbMapSource.bundledAsset);
      expect(active.uniqueBangumiCount, 2);
      expect(active.snapshotDate, '2026-11-25');
    });

    test('KTBM v2 二进制编解码携带 tvdbId 并支持通过 manifest_v2.json 热更新', () async {
      final bundledV1 = buildBin(
        dateInt: 20261110,
        recs: const [
          BangumiTmdbRecord(
            bangumiId: 10,
            type: TmdbMediaType.tv,
            tmdbId: 1000,
            season: 1,
          ),
        ],
      );
      final remoteV2 = buildBin(
        dateInt: 20261121,
        recs: const [
          BangumiTmdbRecord(
            bangumiId: 400602,
            type: TmdbMediaType.tv,
            tmdbId: 209867,
            season: 1,
            tvdbId: 424536,
          ),
          BangumiTmdbRecord(
            bangumiId: 10,
            type: TmdbMediaType.movie,
            tmdbId: 129,
          ),
        ],
      );
      final parsedV2 = BangumiTmdbIndex.fromBytes(remoteV2);
      expect(parsedV2.version, BangumiTmdbIndex.formatVersionV2);
      expect(parsedV2.supportsTvdbId, isTrue);
      expect(parsedV2.lookup(400602).first.tvdbId, 424536);
      expect(
        parsedV2.lookupTvdbIdByTmdb(
          mediaType: TmdbMediaType.tv,
          tmdbId: 209867,
        ),
        424536,
      );
      expect(
        parsedV2.lookupTvdbIdByTmdb(
          mediaType: TmdbMediaType.movie,
          tmdbId: 129,
        ),
        isNull,
      );

      final v2Sha = sha256.convert(remoteV2).toString();
      final mockClient = MockClient((request) async {
        if (request.url.path.endsWith('/manifest_v2.json')) {
          return http.Response(
            jsonEncode({
              'schemaVersion': 2,
              'snapshotDate': '2026-11-21',
              'recordCount': 2,
              'uniqueBangumiCount': 2,
              'binBytes': remoteV2.length,
              'binSha256': v2Sha,
            }),
            200,
            headers: const {'etag': '"etag-ktbm-v2"'},
          );
        }
        if (request.url.path.endsWith('/bangumi_tmdb_map_v2.bin')) {
          return http.Response.bytes(remoteV2, 200);
        }
        return http.Response('not found', 404);
      });

      final stateStore = InMemoryMappingUpdateStateStore();
      final updater = BangumiTmdbMapUpdater(
        storageRoot: storageRoot,
        stateStore: stateStore,
        bundledAssetLoader: fakeAssetLoader(bundledV1),
        httpClient: mockClient,
        mirrorBases: const ['https://mirror-v2.example/mapping'],
      );
      final updated = await updater.checkAndUpdateIfDue(force: true);
      expect(updated.state, BangumiTmdbUpdateState.updated);
      expect(updated.snapshot.source, BangumiTmdbMapSource.localHotUpdate);
      expect(updated.snapshot.index.supportsTvdbId, isTrue);
      expect(
        updated.snapshot.index.lookupTvdbIdByTmdb(
          mediaType: TmdbMediaType.tv,
          tmdbId: 209867,
        ),
        424536,
      );
    });
  });
}
