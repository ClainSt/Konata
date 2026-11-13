import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:ccplayer/core/anime_mapping.dart';
import 'package:ccplayer/core/anime_mapping_store.dart';
import 'package:ccplayer/core/anime_mapping_acquisition.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/library_backup_exporter.dart';
import 'package:ccplayer/core/library_backup_restorer.dart';
import 'package:ccplayer/core/scrape_tasks.dart';
import 'package:ccplayer/core/shared_metadata_requests.dart';
import 'package:ccplayer/core/player_fullscreen.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final cat = Catalog.instance;
  final v1 = '1' * 40, v2 = '2' * 40, v3 = '3' * 40;
  late Directory root;
  late AnimeMappingStore store;
  var sequence = 0;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('konata-mapping-');
    await cat.initialize(
      dataDirectory: root,
      enableFoundation: true,
      enableTasks: true,
      enableMappings: true,
    );
    store = cat.mappingStore!;
    for (final v in [v1, v2, v3]) {
      await store.registerVersion(v);
    }
  });
  tearDown(() async {
    cat.taskStore!.dispose();
    cat.taskStore = null;
    cat.mappingStore = null;
    await cat.db.close();
    await root.delete(recursive: true);
  });
  Future<TaskLease> lease() async {
    final id = 'fixture:${sequence++}';
    await store.tasks.enqueue(id, intent: {}, steps: ['mapping']);
    return (await store.tasks.claim(id, 'mapping'))!;
  }

  Future<void> newer(String parent, String child) =>
      store.proveDescendant(parent, child, {
        'status': 'ahead',
        'base_commit': {'sha': parent},
        'merge_base_commit': {'sha': parent},
        'commits': [
          {'sha': child},
        ],
      });
  Map<String, dynamic> detail({
    int subject = 1,
    int destination = 1,
    bool exclusion = false,
    bool uncovered = false,
  }) => {
    'schemaVersion': 1,
    'bangumiId': subject,
    'targets': [
      {'type': 'tv', 'id': 42, 'season': 1},
    ],
    'episodes': [
      {'id': 101, 'type': 0, 'sort': 1},
      {'id': 103, 'type': 0, 'sort': 3},
      {'id': 115, 'type': 1, 'sort': 1.5},
    ],
    'rules': uncovered
        ? []
        : [
            {
              'bangumiType': 0,
              'start': 1,
              'end': 3,
              'tmdbId': 42,
              'season': 1,
              'episodeStart': destination,
            },
          ],
    'overrides': [
      if (exclusion) {'bangumiEpisodeId': 101, 'targets': []},
      {
        'bangumiEpisodeId': 115,
        'targets': [
          {'type': 'tv', 'id': 42, 'season': 0, 'episode': 2},
        ],
      },
    ],
  };
  Future<void> bulk(
    String version,
    List<AnimeMapping> entries, {
    TaskLease? active,
    bool schemaLast = false,
  }) async {
    final subjects = [
      for (final e in entries) {'bangumiId': e.subject, 'targets': e.targets},
    ];
    final episodes = [
      for (final e in entries)
        for (final row in e.episodes.entries)
          {
            'bangumiId': e.subject,
            'bangumiEpisodeId': row.key,
            'targets': row.value,
          },
    ];
    final s = File('${root.path}/subjects.json'),
        e = File('${root.path}/episodes.json');
    await s.writeAsString(
      jsonEncode(
        schemaLast
            ? {'subjects': subjects, 'schemaVersion': 1}
            : {'schemaVersion': 1, 'subjects': subjects},
      ),
    );
    await e.writeAsString(
      jsonEncode(
        schemaLast
            ? {'episodes': episodes, 'schemaVersion': 1}
            : {'schemaVersion': 1, 'episodes': episodes},
      ),
    );
    await store.importPublished(
      version: version,
      subjects: s,
      subjectsDigest: sha256.convert(await s.readAsBytes()).toString(),
      episodes: e,
      episodesDigest: sha256.convert(await e.readAsBytes()).toString(),
      subjectCount: subjects.length,
      episodeCount: episodes.length,
      lease: active ?? await lease(),
    );
  }

  test(
    'fixed upstream samples expand exactly like published episode rows',
    () async {
      final published =
          jsonDecode(
                await File(
                  'test/fixtures/anime_mapping/published-sample-episodes.json',
                ).readAsString(),
              )
              as List;
      for (final file
          in Directory('test/fixtures/anime_mapping')
              .listSync()
              .whereType<File>()
              .where((f) => f.path.contains('mapping-'))) {
        final data = Map<String, dynamic>.from(
          jsonDecode(await file.readAsString()),
        );
        final item = AnimeMapping.detail(data);
        final expected = {
          for (final r in published.where(
            (r) => r['bangumiId'] == item.subject,
          ))
            r['bangumiEpisodeId']: AnimeMapping.targetList(
              r['targets'],
              episode: true,
            ),
        };
        expect(item.episodes, expected, reason: '${item.subject}');
      }
    },
  );
  test(
    'gaps do not shift; decimal override and empty exclusion precede rules',
    () {
      final item = AnimeMapping.detail(detail(exclusion: true));
      expect(item.excluded, {101});
      expect(item.episodes[103]!.single['episode'], 3);
      expect(item.episodes[115]!.single['season'], 0);
      final raw = detail()..['overrides'] = [];
      expect(AnimeMapping.detail(raw).episodes.containsKey(115), isFalse);
    },
  );
  test(
    'movie destinations allow multiple chapters; duplicate TV destinations reject',
    () {
      final raw = detail();
      raw['rules'] = [];
      raw['overrides'] = [
        for (final id in [101, 103])
          {
            'bangumiEpisodeId': id,
            'targets': [
              {'type': 'movie', 'id': 42},
            ],
          },
      ];
      expect(AnimeMapping.detail(raw).episodes.length, 2);
      raw['overrides'] = [
        for (final id in [101, 103])
          {
            'bangumiEpisodeId': id,
            'targets': [
              {'type': 'tv', 'id': 42, 'season': 1, 'episode': 1},
            ],
          },
      ];
      expect(() => AnimeMapping.detail(raw), throwsFormatException);
    },
  );
  test(
    'old bulk then newer detail is whole-entry selection, not per-episode fallback',
    () async {
      await newer(v1, v2);
      await bulk(v1, [AnimeMapping.detail(detail())], schemaLast: true);
      expect(await store.reverse('tv', 42), [1]);
      await store.importDetail(v2, detail(uncovered: true), await lease());
      expect((await store.lookup(1, 101)).state, 'uncovered');
      expect((await store.lookup(1, 103)).state, 'uncovered');
      expect((await store.lookup(1, 115)).state, 'mapped');
      await bulk(v1, [AnimeMapping.detail(detail())]);
      expect((await store.lookup(1, 101)).version, v2);
    },
  );
  test(
    'newer bulk supersedes detail and omitted subjects become uncovered',
    () async {
      await newer(v1, v2);
      await store.importDetail(v1, detail(), await lease());
      await bulk(v2, []);
      expect((await store.lookup(1, 101)).state, 'uncovered');
      expect((await store.lookup(1, 101)).version, v2);
      expect((await store.lookup(999, 1)).state, 'uncovered');
      await store.clearCache();
      await bulk(v1, [AnimeMapping.detail(detail())]);
      expect((await store.lookup(1, 101)).state, 'not_acquired');
      expect((await store.lookup(999, 1)).version, v2);
    },
  );
  test(
    'unknown order never overwrites; same version disagreement blocks new binding',
    () async {
      await store.importDetail(v1, detail(), await lease());
      await store.importDetail(v2, detail(destination: 10), await lease());
      expect((await store.lookup(1, 101)).version, v1);
      await bulk(v1, [AnimeMapping.detail(detail(destination: 10))]);
      expect((await store.lookup(1, 101)).state, 'conflict');
      await store.clearCache();
      expect((await store.lookup(1, 101)).state, 'conflict');
    },
  );
  test(
    'exclusions survive cleanup, backup, restoration and old bulk re-download',
    () async {
      await newer(v1, v2);
      await bulk(v1, [AnimeMapping.detail(detail())]);
      await store.importDetail(v2, detail(exclusion: true), await lease());
      final art = await Directory('${root.path}/artwork').create();
      final prefs = await SharedPreferences.getInstance();
      final zip = File('${root.path}/backup.zip');
      await LibraryBackupExporter(
        database: cat.db,
        artworkDirectory: art,
        preferences: prefs,
      ).export(zip);
      final restorer = LibraryBackupRestorer(
        database: cat.db,
        artworkDirectory: art,
        preferences: prefs,
      );
      final prepared = await restorer.prepare(zip);
      try {
        await restorer.restore(prepared);
      } finally {
        await prepared.dispose();
      }
      expect((await store.lookup(1, 101)).state, 'excluded');
      expect((await store.lookup(1, 103)).state, 'not_acquired');
      await bulk(v1, [AnimeMapping.detail(detail())]);
      expect((await store.lookup(1, 101)).state, 'excluded');
      expect((await store.lookup(1, 103)).state, 'not_acquired');
    },
  );
  test(
    'same-version change from explicit exclusion to uncovered is conflict',
    () async {
      final a = detail(uncovered: true, exclusion: true);
      await store.importDetail(v1, a, await lease());
      await store.importDetail(v1, detail(uncovered: true), await lease());
      expect((await store.lookup(1, 101)).state, 'conflict');
    },
  );
  test(
    'invalid schema, checksum, truncated arrays and cancelled imports preserve head',
    () async {
      await store.importDetail(v1, detail(), await lease());
      final s = File('${root.path}/bad.json');
      for (final body in [
        '{"schemaVersion":2,"subjects":[]}',
        '{"subjects":[],"schemaVersion":2}',
        '{"schemaVersion":1,"subjects":[',
        '{"schemaVersion":1,"subjects":[{},]}',
      ]) {
        await s.writeAsString(body);
        await expectLater(
          store.importPublished(
            version: v2,
            subjects: s,
            subjectsDigest: sha256.convert(utf8.encode(body)).toString(),
            subjectCount: 0,
            lease: await lease(),
          ),
          throwsFormatException,
        );
      }
      await s.writeAsString('{"schemaVersion":1,"subjects":[]}');
      await expectLater(
        store.importPublished(
          version: v2,
          subjects: s,
          subjectsDigest: '0' * 64,
          subjectCount: 0,
          lease: await lease(),
        ),
        throwsFormatException,
      );
      final old = await lease();
      await store.clearCache();
      await expectLater(
        store.importDetail(v2, detail(), old),
        throwsA(isA<TaskStopped>()),
      );
      expect((await store.lookup(1, 101)).version, v1);
      expect(
        await cat.db.query('mapping_batches', where: "state='staging'"),
        isEmpty,
      );
    },
  );
  test(
    'failure at final checkpoint rolls back version, exclusions and cache activation',
    () async {
      await newer(v1, v2);
      await store.importDetail(v1, detail(), await lease());
      await cat.db.execute(
        "CREATE TRIGGER mapping_failure BEFORE UPDATE ON scrape_steps WHEN NEW.state='complete' BEGIN SELECT RAISE(ABORT,'fixture'); END",
      );
      await expectLater(
        store.importDetail(v2, detail(exclusion: true), await lease()),
        throwsA(anything),
      );
      expect((await store.lookup(1, 101)).state, 'mapped');
      expect((await store.lookup(1, 101)).version, v1);
      expect(
        await cat.db.query('mapping_batches', where: "state='staging'"),
        isEmpty,
      );
    },
  );
  test(
    'reopen removes incomplete staging but preserves active indexes and floors',
    () async {
      await store.importDetail(v1, detail(exclusion: true), await lease());
      await cat.db.insert('mapping_batches', {
        'id': 'interrupted',
        'version': v2,
        'kind': 'bulk',
        'state': 'staging',
      });
      await cat.db.close();
      await cat.initialize(
        dataDirectory: root,
        enableFoundation: true,
        enableTasks: true,
        enableMappings: true,
      );
      store = cat.mappingStore!;
      expect((await store.lookup(1, 101)).state, 'excluded');
      expect((await store.lookup(1, 103)).state, 'mapped');
      expect(
        await cat.db.query('mapping_batches', where: "state='staging'"),
        isEmpty,
      );
    },
  );
  test(
    '3000 distinct subjects choose one batch job; validated release takes four requests',
    () async {
      final subjectRows = [
        for (var i = 1; i <= 3000; i++)
          {
            'bangumiId': i,
            'targets': [
              {'type': 'tv', 'id': i, 'season': 1},
            ],
          },
      ];
      final episodeRows = [
        for (var i = 1; i <= 3000; i++)
          for (var ep = 1; ep <= 12; ep++)
            {
              'bangumiId': i,
              'bangumiEpisodeId': i * 100 + ep,
              'targets': [
                {'type': 'tv', 'id': i, 'season': 1, 'episode': ep},
              ],
            },
      ];
      final files = <int, String>{
        2: jsonEncode({'schemaVersion': 1, 'subjects': subjectRows}),
        3: jsonEncode({'schemaVersion': 1, 'episodes': episodeRows}),
      };
      String hash(int id) => sha256.convert(utf8.encode(files[id]!)).toString();
      files[1] = jsonEncode({
        'schemaVersion': 1,
        'sourceCommit': v1,
        'sourceDirty': false,
        'counts': {'subjects': 3000, 'episodes': 36000},
        'files': {
          'subjects.json': {'sha256': hash(2)},
          'episodes.json': {'sha256': hash(3)},
        },
      });
      final names = {
        1: 'manifest.json',
        2: 'subjects.json',
        3: 'episodes.json',
      };
      var calls = 0;
      final pool = SharedMetadataRequests(
        store.tasks,
        clientFactory: () => MockClient((request) async {
          calls++;
          if (request.url.path.contains('/releases/tags/')) {
            return http.Response(
              jsonEncode({
                'tag_name': 'data-$v1',
                'draft': false,
                'prerelease': false,
                'assets': [
                  for (final id in files.keys)
                    {
                      'name': names[id],
                      'id': id,
                      'size': utf8.encode(files[id]!).length,
                      'digest': 'sha256:${hash(id)}',
                    },
                ],
              }),
              200,
            );
          }
          final id = int.parse(request.url.pathSegments.last);
          return http.Response(files[id]!, 200);
        }),
        retryDelays: [Duration.zero],
      );
      addTearDown(pool.close);
      final acquisition = AnimeMappingAcquisition(store, pool);
      final jobs = await acquisition.plan(v1, [
        for (var i = 1; i <= 3000; i++) i,
      ]);
      expect(jobs, hasLength(2));
      expect(jobs.last, contains(':bulk:'));
      final watch = Stopwatch()..start();
      final rssBefore = ProcessInfo.currentRss;
      for (final id in jobs) {
        await acquisition.run(id);
      }
      final importMs = watch.elapsedMilliseconds;
      watch.reset();
      for (var i = 1; i <= 3000; i++) {
        expect((await store.lookup(i, i * 100 + 12)).state, 'mapped');
      }
      final pages =
          (await cat.db.rawQuery('PRAGMA page_count')).single.values.single
              as int;
      final pageSize =
          (await cat.db.rawQuery('PRAGMA page_size')).single.values.single
              as int;
      expect(calls, 4);
      expect(await acquisition.plan(v1, [1, 1, 2]), isEmpty);
      // ignore: avoid_print
      print(
        'PHASE3 ${jsonEncode({'subjects': 3000, 'episodes': 36000, 'requests': calls, 'import_ms': importMs, 'lookup_3000_ms': watch.elapsedMilliseconds, 'database_bytes': pages * pageSize, 'raw_bytes': files.values.fold<int>(0, (n, s) => n + utf8.encode(s).length), 'rss_before': rssBefore, 'rss_after': ProcessInfo.currentRss, 'process_max_rss': ProcessInfo.maxRss})}',
      );
    },
  );
  test(
    'small entry fetch pins commit and verifies Git blob while retaining evidence',
    () async {
      final raw = detail()
        ..['provenance'] = {
          'method': 'fixture',
          'source': 'fixture source',
          'evidence': 'explicit fixture',
        };
      final bytes = utf8.encode(jsonEncode(raw));
      final sha = sha1.convert([
        ...utf8.encode('blob ${bytes.length}\u0000'),
        ...bytes,
      ]).toString();
      var calls = 0;
      final pool = SharedMetadataRequests(
        store.tasks,
        clientFactory: () => MockClient((r) async {
          calls++;
          expect(r.url.queryParameters['ref'], v1);
          expect(r.url.path, endsWith('/contents/data/1.json'));
          return http.Response(
            jsonEncode({
              'path': 'data/1.json',
              'encoding': 'base64',
              'sha': sha,
              'content': base64Encode(bytes),
            }),
            200,
          );
        }),
      );
      addTearDown(pool.close);
      final acquisition = AnimeMappingAcquisition(store, pool);
      final releaseId = await acquisition.enqueue(v1, 'release');
      final releaseLease = (await store.tasks.claim(releaseId, 'acquire'))!;
      await store.tasks.commit(releaseLease, (_) async => {'version': v1});
      final id = await acquisition.enqueue(v1, 'detail', subject: 1);
      await acquisition.run(id);
      expect(calls, 1);
      expect((await store.lookup(1, 103)).targets.single['episode'], 3);
      expect((await store.evidence(1))!['evidence'], 'explicit fixture');
      expect(AnimeMappingAcquisition.chooseMode(24), 'detail');
      expect(AnimeMappingAcquisition.chooseMode(25), 'bulk');
      expect(AnimeMappingAcquisition.chooseMode(2, remaining: 7), 'bulk');
    },
  );
  test(
    'GitHub primary quota survives restart and blocks bulk endpoint too',
    () async {
      var calls = 0;
      var pool = SharedMetadataRequests(
        store.tasks,
        clientFactory: () => MockClient((r) async {
          calls++;
          return http.Response(
            '{"message":"API rate limit exceeded"}',
            403,
            headers: {
              'x-ratelimit-remaining': '0',
              'x-ratelimit-reset': '${(store.tasks.now ~/ 1000) + 3600}',
            },
          );
        }),
      );
      final r = MetadataResource(
        service: 'github',
        resource: 'release',
        routes: [
          Uri.parse(
            'https://api.github.com/repos/open-ani/bangumi-tmdb/releases/latest',
          ),
        ],
      );
      await expectLater(
        pool.get(r, await lease()),
        throwsA(
          isA<MetadataFailure>().having(
            (e) => e.category,
            'category',
            'rate_limit',
          ),
        ),
      );
      pool.close();
      await cat.db.close();
      await cat.initialize(
        dataDirectory: root,
        enableFoundation: true,
        enableTasks: true,
        enableMappings: true,
      );
      store = cat.mappingStore!;
      pool = SharedMetadataRequests(
        store.tasks,
        clientFactory: () => MockClient((r) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );
      addTearDown(pool.close);
      await expectLater(
        pool.download(
          MetadataResource(
            service: 'github',
            resource: 'asset',
            routes: [
              Uri.parse(
                'https://api.github.com/repos/open-ani/bangumi-tmdb/releases/assets/1',
              ),
            ],
          ),
          await lease(),
          File('${root.path}/blocked.part'),
          maxBytes: 1000,
          digest: '0' * 64,
        ),
        throwsA(isA<MetadataFailure>()),
      );
      expect(calls, 1);
    },
  );
  test(
    'secondary quota without headers waits at least one minute; plain 403 is authentication',
    () async {
      for (final limited in [true, false]) {
        final pool = SharedMetadataRequests(
          store.tasks,
          clientFactory: () => MockClient(
            (_) async => http.Response(
              limited
                  ? '{"message":"secondary rate limit"}'
                  : '{"message":"Forbidden"}',
              403,
            ),
          ),
        );
        final r = MetadataResource(
          service: 'github',
          resource: 'fixture',
          routes: [Uri.parse('https://api.github.com/fixture')],
          headers: {'Authorization': limited ? 'a' : 'b'},
          trustCustom: true,
        );
        await expectLater(
          pool.get(r, await lease()),
          throwsA(
            isA<MetadataFailure>().having(
              (e) => e.category,
              'category',
              limited ? 'rate_limit' : 'authentication',
            ),
          ),
        );
        if (limited) {
          expect(
            (await cat.db.query('scrape_network')).single['not_before'] as int,
            greaterThanOrEqualTo(store.tasks.now + 59000),
          );
        }
        pool.close();
      }
    },
  );
  test(
    'cancel during asset headers releases caller without waiting for timeout',
    () async {
      final started = Completer<void>(), response = Completer<http.Response>();
      final pool = SharedMetadataRequests(
        store.tasks,
        clientFactory: () => MockClient((_) {
          started.complete();
          return response.future;
        }),
      );
      addTearDown(pool.close);
      final active = await lease();
      final pending = expectLater(
        pool.download(
          MetadataResource(
            service: 'github',
            resource: 'asset',
            routes: [
              Uri.parse(
                'https://api.github.com/repos/open-ani/bangumi-tmdb/releases/assets/1',
              ),
            ],
          ),
          active,
          File('${root.path}/cancel.part'),
          maxBytes: 10,
          digest: '0' * 64,
        ),
        throwsA(isA<TaskStopped>()),
      );
      await started.future;
      await store.tasks.control(active.taskId, 'cancel');
      await pending.timeout(const Duration(seconds: 2));
      response.complete(http.Response('late', 200));
      expect(await File('${root.path}/cancel.part').exists(), isFalse);
    },
  );
  test('playback pauses mapping task before any network request', () async {
    var calls = 0;
    final pool = SharedMetadataRequests(
      store.tasks,
      clientFactory: () => MockClient((_) async {
        calls++;
        return http.Response('{}', 200);
      }),
    );
    addTearDown(pool.close);
    final acquisition = AnimeMappingAcquisition(store, pool);
    final id = await acquisition.enqueue(v1, 'bulk');
    playingHeader.value = PlayingHeader('fixture', () {});
    try {
      await acquisition.run(id);
    } finally {
      playingHeader.value = null;
    }
    expect(calls, 0);
    expect((await store.tasks.list()).single['state'], 'paused');
  });
  test(
    'new small index does not redownload all details; old entries review two per day',
    () async {
      await bulk(v1, [
        for (var id = 1; id <= 4; id++)
          AnimeMapping.detail(detail(subject: id)),
      ]);
      final pool = SharedMetadataRequests(store.tasks);
      addTearDown(pool.close);
      final acquisition = AnimeMappingAcquisition(store, pool);
      final first = await acquisition.plan(v2, [1, 2, 3, 4]);
      expect(first.where((id) => id.contains(':detail:')), isEmpty);
      await cat.db.update('mapping_controls', {
        'checked_at': store.tasks.now - const Duration(days: 29).inMilliseconds,
      });
      final review = await acquisition.plan(v2, [1, 2, 3, 4]);
      expect(review.where((id) => id.contains(':detail:')), hasLength(2));
      final again = await acquisition.plan(v2, [1, 2, 3, 4]);
      expect(again.where((id) => id.contains(':detail:')), isEmpty);
      final budget = (await cat.db.query('mapping_review')).single;
      await store.clearCache();
      expect((await cat.db.query('mapping_review')).single, budget);
    },
  );
  test(
    'successful last API response persists exhausted quota before next request',
    () async {
      var calls = 0;
      final pool = SharedMetadataRequests(
        store.tasks,
        clientFactory: () => MockClient((_) async {
          calls++;
          return http.Response(
            '{"ok":true}',
            200,
            headers: {
              'x-ratelimit-remaining': '0',
              'x-ratelimit-reset': '${store.tasks.now ~/ 1000 + 3600}',
            },
          );
        }),
      );
      addTearDown(pool.close);
      final r = MetadataResource(
        service: 'github',
        resource: 'last',
        routes: [Uri.parse('https://api.github.com/last')],
      );
      final active = await lease();
      expect(await pool.get(r, active), {'ok': true});
      await expectLater(
        pool.get(r, active, manualRetry: true),
        throwsA(isA<MetadataFailure>()),
      );
      expect(calls, 1);
    },
  );
  test(
    'asset redirect is bounded and untrusted destination is never requested',
    () async {
      var calls = 0;
      final pool = SharedMetadataRequests(
        store.tasks,
        clientFactory: () => MockClient((r) async {
          calls++;
          expect(r.url.host, 'api.github.com');
          return http.Response(
            '',
            302,
            headers: {'location': 'https://untrusted.invalid/file'},
          );
        }),
        retryDelays: [Duration.zero],
      );
      addTearDown(pool.close);
      final r = MetadataResource(
        service: 'github',
        resource: 'asset',
        routes: [
          Uri.parse(
            'https://api.github.com/repos/open-ani/bangumi-tmdb/releases/assets/1',
          ),
        ],
      );
      await expectLater(
        pool.download(
          r,
          await lease(),
          File('${root.path}/redirect.part'),
          maxBytes: 100,
          digest: '0' * 64,
        ),
        throwsA(
          isA<MetadataFailure>().having(
            (e) => e.category,
            'category',
            'protocol',
          ),
        ),
      );
      expect(calls, 3);
      expect(await File('${root.path}/redirect.part').exists(), isFalse);
    },
  );
  test(
    'cancel during staging preserves ready version and recovery clears owned temporary files',
    () async {
      await store.importDetail(v1, detail(), await lease());
      final active = await lease();
      await store.tasks.control(active.taskId, 'cancel');
      await expectLater(
        bulk(v2, [
          AnimeMapping.detail(detail(destination: 10)),
        ], active: active),
        throwsA(isA<TaskStopped>()),
      );
      expect((await store.lookup(1, 101)).version, v1);
      final temp = await Directory(
        '${root.path}/mapping-downloads/request-fixture',
      ).create(recursive: true);
      await File('${temp.path}/partial').writeAsBytes([1]);
      await store.recover();
      expect(await temp.exists(), isFalse);
    },
  );
  test(
    'restoring an older snapshot cannot lower the accepted exclusion floor',
    () async {
      await store.importDetail(v1, detail(), await lease());
      final art = await Directory('${root.path}/artwork').create();
      final prefs = await SharedPreferences.getInstance();
      final zip = File('${root.path}/older.zip');
      await LibraryBackupExporter(
        database: cat.db,
        artworkDirectory: art,
        preferences: prefs,
      ).export(zip);
      await newer(v1, v2);
      await store.importDetail(v2, detail(exclusion: true), await lease());
      final restorer = LibraryBackupRestorer(
        database: cat.db,
        artworkDirectory: art,
        preferences: prefs,
      );
      final prepared = await restorer.prepare(zip);
      try {
        await restorer.restore(prepared);
      } finally {
        await prepared.dispose();
      }
      expect((await store.lookup(1, 101)).state, 'excluded');
      expect((await store.lookup(1, 101)).version, v2);
      await bulk(v1, [AnimeMapping.detail(detail())]);
      expect((await store.lookup(1, 101)).state, 'excluded');
    },
  );
  test(
    'source exclusion never rewrites adopted library identity or playback',
    () async {
      await cat.db.insert('sources', {
        'id': 's',
        'kind': 'local',
        'label': 'Fixture',
        'location': 'synthetic',
      });
      await cat.indexVideo('s', 'Series/01.mkv', 100, workFolder: 'Series');
      final asset = (await cat.db.query('assets')).single['id'] as String;
      await cat.progress(asset, 5000, 10000);
      final before = {
        for (final table in [
          'works',
          'assets',
          'progress',
          'watch_events',
          'logical_episode_confirmations',
        ])
          table: await cat.db.query(table),
      };
      await store.importDetail(v1, detail(), await lease());
      await newer(v1, v2);
      await store.importDetail(v2, detail(exclusion: true), await lease());
      for (final table in before.keys) {
        expect(await cat.db.query(table), before[table], reason: table);
      }
    },
  );
}
