import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/library_foundation.dart';
import 'package:ccplayer/core/library_backup_exporter.dart';
import 'package:ccplayer/core/library_backup_restorer.dart';
import 'package:ccplayer/core/metadata_servers.dart';
import 'package:ccplayer/core/scrape_task_runner.dart';
import 'package:ccplayer/core/optional_feature_scope.dart';
import 'package:ccplayer/core/scrape_tasks.dart';
import 'package:ccplayer/core/shared_metadata_requests.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Loopback extends HttpOverrides {}

class ClosingClient extends MockClient {
  ClosingClient(super.handler, this.onClose);
  final void Function() onClose;
  @override
  void close() {
    onClose();
    super.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final cat = Catalog.instance;
  late Directory root;
  late ScrapeTasks tasks;
  late String work;
  final pools = <SharedMetadataRequests>[];
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('konata-tasks-');
    await cat.initialize(
      dataDirectory: root,
      enableFoundation: true,
      enableTasks: true,
    );
    tasks = cat.taskStore!;
    await cat.db.insert('sources', {
      'id': 's',
      'kind': 'local',
      'label': 'Fixture',
      'location': 'synthetic',
    });
    await cat.indexVideo('s', 'Series/01.mkv', 100, workFolder: 'Series');
    work = (await cat.db.query('works')).single['id'] as String;
  });
  tearDown(() async {
    for (final pool in pools) {
      pool.close();
    }
    pools.clear();
    tasks.dispose();
    cat.taskStore = null;
    await cat.db.close();
    await root.delete(recursive: true);
  });
  Future<TaskLease> lease(
    String id, {
    OptionalFeatureScope? feature,
    List<String> steps = const ['metadata'],
  }) async {
    await tasks.enqueue(
      id,
      workId: work,
      sourceId: 's',
      intent: {'kind': 'test'},
      steps: steps,
    );
    return (await tasks.claim(
      id,
      steps.first,
      feature: feature,
      fields: ['title', 'overview'],
    ))!;
  }

  MetadataResource resource({String id = '42', String token = ''}) =>
      MetadataResource(
        service: 'bangumi',
        resource: 'subject:$id',
        routes: [Uri.parse('https://api.bgm.tv/v0/subjects/$id')],
        headers: {'Authorization': token},
        accept: (body) => body['id'] == 42,
      );
  SharedMetadataRequests pool(
    Future<http.Response> Function(http.Request) respond, {
    Duration deadline = const Duration(seconds: 2),
  }) {
    final value = SharedMetadataRequests(
      tasks,
      clientFactory: () => MockClient(respond),
      retryDelays: [Duration.zero],
      deadline: deadline,
      jitter: () => 0,
    );
    pools.add(value);
    return value;
  }

  test('provider transport reuses sockets and cancellation leaves another request alive', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final ports = <String, int>{};
      final slow = Completer<void>();
      final peer = Completer<void>();
      final release = Completer<void>();
      server.listen((request) async {
        final path = request.uri.path;
        ports[path] = request.connectionInfo!.remotePort;
        if (path == '/slow') slow.complete();
        if (path == '/peer') peer.complete();
        if (path == '/slow' || path == '/peer') await release.future;
        try {
          request.response.write('{"id":42}');
          await request.response.close();
        } on IOException {
          // The cancelled request may have already disconnected.
        }
      });
      final p = SharedMetadataRequests(tasks, retryDelays: const []);
      pools.add(p);
      MetadataResource local(String service, String path) => MetadataResource(
        service: service,
        resource: path,
        routes: [Uri.http('127.0.0.1:${server.port}', path)],
      );
      try {
        await p.get(local('bangumi', '/warm'), await lease('warm'));
        await p.get(local('bangumi', '/again'), await lease('again'));
        expect(ports['/again'], ports['/warm']);

        final a = await lease('slow');
        final b = await lease('peer');
        final stopped = expectLater(p.get(local('bangumi', '/slow'), a),
          throwsA(isA<TaskStopped>()));
        await slow.future;
        final remaining = p.get(local('tmdb', '/peer'), b);
        await peer.future;
        await tasks.control('slow', 'cancel');
        await stopped;
        release.complete();
        expect(await remaining, {'id': 42});
        expect(p.activeRequests, 0);
      } finally {
        if (!release.isCompleted) release.complete();
        p.close();
        await server.close(force: true);
      }
    }, _Loopback());
  });

  test('an unauthorized mirror never prevents use of the official route', () async {
    final official = Uri.https('api.themoviedb.org', '/3/tv/42');
    final mirror = Uri.https('unapproved.example', '/3/tv/42');
    final visited = <Uri>[];
    final p = pool((request) async {
      visited.add(request.url);
      return http.Response('{"id":42}', 200);
    });
    final result = await p.get(MetadataResource(
      service: 'tmdb',
      resource: 'tv:42',
      routes: [mirror, official],
      headers: {'Authorization': 'Bearer fixture'},
    ), await lease('official'));
    expect(result['id'], 42);
    expect(visited, [official]);
  });

  test('recognition reuses successful responses only within the same lease', () async {
    var calls = 0;
    final transport = pool((_) async {
      calls++;
      return http.Response('{"id":42,"name":"Original"}', 200);
    });
    final first = await lease('first');
    final body = await transport.get(resource(), first, reuseCompleted: true);
    body['name'] = 'Modified by caller';
    expect((await transport.get(resource(), first, reuseCompleted: true))['name'], 'Original');
    expect(calls, 1);
    await transport.get(resource(), await lease('second'), reuseCompleted: true);
    expect(calls, 2);
    await tasks.control('first', 'cancel');
    await expectLater(transport.get(resource(), first, reuseCompleted: true), throwsA(isA<TaskStopped>()));
    expect(calls, 2);
  });

  test('recognition batch shares successful requests until a new scan or manual retry', () async {
    var calls = 0;
    final transport = pool((_) async => http.Response('{"id":42,"request":${++calls}}', 200));
    transport.beginRecognitionBatch();
    final first = await lease('batch-first');
    final next = await lease('batch-next');
    expect((await transport.get(resource(), first, reuseCompleted: true))['request'], 1);
    expect((await transport.get(resource(), next, reuseCompleted: true))['request'], 1);
    expect((await transport.get(resource(), next, reuseCompleted: true, manualRetry: true))['request'], 2);
    transport.endRecognitionBatch();
    final later = await lease('batch-later');
    expect((await transport.get(resource(), later, reuseCompleted: true))['request'], 3);
  });

  test('list endpoints are explicit and do not share object response contracts', () async {
    MetadataResource relation(bool list) => MetadataResource(
      service: 'bangumi', resource: 'subjects/42/subjects',
      routes: [Uri.parse('https://api.bgm.tv/v0/subjects/42/subjects')], listResponse: list);
    final transport = pool((_) async => http.Response.bytes(utf8.encode('[{"id":12,"relation":"主线故事"}]'), 200));
    expect(relation(true).key, isNot(relation(false).key));
    expect((await transport.get(relation(true), await lease('list')))['data'], [{'id': 12, 'relation': '主线故事'}]);
    await expectLater(transport.get(relation(false), await lease('object')), throwsA(isA<MetadataFailure>()));
  });

  test(
    'provider steps fall back after timeout and reuse the working route',
    () async {
      await MetadataServers.load();
      final calls = <String>[];
      final transport = pool((request) async {
        calls.add(request.url.host);
        if (request.url.host == 'api.bgm.tv')
          throw TimeoutException('Official timeout');
        return http.Response('{"id":42}', 200);
      });
      for (final id in ['42', '43']) {
        final request = MetadataResource(
          service: 'bangumi',
          resource: 'subject:$id',
          routes: MetadataServers.routes(2, 'subjects/$id'),
        );
        expect(
          (await transport.get(request, await lease('backup-$id')))['id'],
          42,
        );
      }
      expect(calls, ['api.bgm.tv', 'api.bangumi.lat', 'api.bangumi.lat']);
      await MetadataServers.load();
    },
  );

  test(
    'pause finishes short step, prohibits next step; resume does not revoke in-flight lease',
    () async {
      final a = await lease('a', steps: ['metadata', 'next']);
      await tasks.control('a', 'pause');
      await expectLater(tasks.beforeNextRequest(a), throwsA(isA<TaskPaused>()));
      await tasks.control('a', 'resume');
      expect(await tasks.valid(a), isTrue);
      expect(await tasks.claim('a', 'metadata'), isNull);
      await tasks.control('a', 'pause');
      await tasks.commit(a, (_) async => {'done': true});
      expect(await tasks.claim('a', 'next'), isNull);
      await tasks.control('a', 'resume');
      expect(await tasks.claim('a', 'metadata'), isNull);
      expect(await tasks.claim('a', 'next'), isNotNull);
    },
  );
  test('cancel and changed intent reject late database commits', () async {
    final a = await lease('a');
    await tasks.control('a', 'cancel');
    await expectLater(
      tasks.commitFields(a, {'title': 'late'}),
      throwsA(isA<TaskStopped>()),
    );
    await tasks.control('a', 'retry');
    final b = (await tasks.claim('a', 'metadata'))!;
    await tasks.enqueue(
      'a',
      workId: work,
      intent: {'kind': 'changed'},
      steps: ['metadata'],
    );
    expect(b.active, isFalse);
    expect(await tasks.valid(b), isFalse);
    await tasks.control('a', 'cancel', expectedGeneration: b.generation);
    expect((await tasks.list()).single['state'], 'queued');
  });
  test(
    'manual field edit remains visible while unrelated metadata commits',
    () async {
      final a = await lease('a');
      await LibraryFoundation(cat.db).writeField(
        work,
        'title',
        expectedScope: a.scope!,
        expectedBindingRevision: a.bindingRevision!,
        expectedRevision: 0,
        mode: 'manual',
        value: 'User title',
      );
      final result = await tasks.commitFields(a, {
        'title': 'Automatic title',
        'overview': 'New overview',
      });
      expect(result['title'], 'draft_only');
      expect((await cat.db.query('works')).single['title'], 'User title');
      expect((await cat.db.query('works')).single['overview'], 'New overview');
    },
  );
  test(
    'backup restores durable tasks and cooldown while invalidating active session',
    () async {
      final a = await lease('a');
      await cat.db.insert('scrape_network', {
        'key': resource().key,
        'failures': 1,
        'not_before': tasks.now + 100000,
        'category': 'timeout',
        'updated_at': tasks.now,
      });
      final cooldown = await cat.db.query('scrape_network');
      final art = await Directory('${root.path}/artwork').create();
      final prefs = await SharedPreferences.getInstance();
      final zip = File('${root.path}/tasks.zip');
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
      expect(await tasks.valid(a), isFalse);
      expect((await tasks.list()).single['state'], 'queued');
      expect(await cat.db.query('scrape_network'), cooldown);
      expect(await tasks.claim('a', 'metadata'), isNotNull);
    },
  );
  test(
    'runner fetches confirmed identity and persists metadata exactly once',
    () async {
      await cat.db.update(
        'works',
        {'bangumi_id': 42},
        where: 'id=?',
        whereArgs: [work],
      );
      var calls = 0;
      final runner = ScrapeTaskRunner(
        cat,
        requests: pool((_) async {
          calls++;
          return http.Response(
            '{"id":42,"name":"Confirmed title","summary":"Overview","date":"2020-01-01"}',
            200,
          );
        }),
      );
      final jobs = await runner.enqueueMetadata('s');
      expect(jobs, hasLength(1));
      await runner.run(jobs.single);
      expect((await tasks.list()).single['state'], 'complete');
      expect((await cat.db.query('works')).single['title'], 'Confirmed title');
      await runner.enqueueMetadata('s');
      await runner.run(jobs.single);
      expect(calls, 1);
    },
  );
  test(
    'pause prevents a second HTTP attempt until explicitly resumed',
    () async {
      final a = await lease('a');
      final started = Completer<void>(), response = Completer<http.Response>();
      var calls = 0;
      final p = pool((_) {
        calls++;
        started.complete();
        return response.future;
      });
      final pending = expectLater(
        p.get(resource(), a),
        throwsA(isA<TaskPaused>()),
      );
      await started.future;
      await tasks.control('a', 'pause');
      response.complete(http.Response('bad', 500));
      await pending;
      await tasks.park(a);
      expect(calls, 1);
      expect((await tasks.list()).single['state'], 'paused');
      expect(await cat.db.query('scrape_network'), isEmpty);
    },
  );
  test(
    'one changed automatic field does not discard unrelated fields',
    () async {
      final a = await lease('a');
      final b = await lease('b');
      await tasks.commitFields(b, {'title': 'newer'});
      final outcomes = await tasks.commitFields(a, {
        'title': 'old',
        'overview': 'summary',
      });
      expect(outcomes, {'title': 'superseded', 'overview': 'adopted'});
      final row = (await cat.db.query('works')).single;
      expect(row['title'], 'newer');
      expect(row['overview'], 'summary');
    },
  );
  test('field and checkpoint transaction rolls back together', () async {
    final a = await lease('a');
    await cat.db.execute(
      "CREATE TRIGGER reject_checkpoint BEFORE UPDATE ON scrape_steps WHEN NEW.state='complete' BEGIN SELECT RAISE(ABORT,'fixture'); END",
    );
    await expectLater(
      tasks.commitFields(a, {'title': 'uncommitted'}),
      throwsA(anything),
    );
    expect((await cat.db.query('works')).single['title'], isNot('uncommitted'));
    expect((await cat.db.query('scrape_steps')).single['state'], 'running');
  });
  test(
    'cache replacement removes old file; clear rejects late publication',
    () async {
      final a = await lease('a');
      final first = await tasks.publishCache(a, 'key', [1, 2]);
      final second = await tasks.publishCache(a, 'key', [3]);
      expect(await first.exists(), isFalse);
      expect(await second.readAsBytes(), [3]);
      expect(await tasks.cacheDirectory.list().length, 1);
      await tasks.clearCache();
      await expectLater(
        tasks.publishCache(a, 'key', [4]),
        throwsA(isA<TaskStopped>()),
      );
      expect(await tasks.cacheDirectory.list().length, 0);
      expect(await tasks.valid(a), isTrue);
    },
  );
  test(
    'restart preserves completed checkpoint and cooldown but revokes old lease',
    () async {
      final a = await lease('a', steps: ['metadata', 'next']);
      await tasks.commit(a, (_) async => {'ok': true});
      final b = (await tasks.claim('a', 'next'))!;
      await cat.db.insert('scrape_network', {
        'key': resource().key,
        'failures': 2,
        'not_before': tasks.now + 100000,
        'category': 'timeout',
        'updated_at': tasks.now,
      });
      final retry = await cat.db.query('scrape_network');
      await cat.db.close();
      await cat.initialize(
        dataDirectory: root,
        enableFoundation: true,
        enableTasks: true,
      );
      tasks = cat.taskStore!;
      expect(await tasks.valid(b), isFalse);
      expect(await tasks.claim('a', 'metadata'), isNull);
      expect(await tasks.claim('a', 'next'), isNotNull);
      expect(await cat.db.query('scrape_network'), retry);
    },
  );
  test(
    'shared request A cancellation leaves B alive with one HTTP request',
    () async {
      final a = await lease('a'), b = await lease('b');
      final response = Completer<http.Response>();
      final started = Completer<void>();
      var calls = 0;
      final p = pool((_) {
        calls++;
        if (!started.isCompleted) started.complete();
        return response.future;
      });
      final fa = p.get(resource(), a);
      final checked = expectLater(fa, throwsA(isA<TaskStopped>()));
      final fb = p.get(resource(), b);
      await started.future;
      // Wait for B's guarded admission into the same flight.
      await tasks.valid(b);
      await tasks.control('a', 'cancel');
      await checked;
      response.complete(http.Response('{"id":42}', 200));
      expect(await fb, {'id': 42});
      expect(calls, 1);
      expect(p.activeRequests, 0);
    },
  );
  test(
    'feature shutdown rejects late response; new scope can request again',
    () async {
      final scope = OptionalFeatureScope(() {});
      final a = await lease('a', feature: scope);
      final response = Completer<http.Response>(),
          started = Completer<http.Response>();
      final p = pool((_) {
        if (!started.isCompleted) started.complete(http.Response('', 200));
        return response.future;
      });
      final pending = expectLater(
        p.get(resource(), a),
        throwsA(isA<TaskStopped>()),
      );
      await started.future;
      scope.dispose();
      await pending;
      expect(p.activeRequests, 0);
      response.complete(http.Response('{"id":42}', 200));
      final next = OptionalFeatureScope(() {});
      final b = await lease('b', feature: next);
      expect(await p.get(resource(), b), {'id': 42});
      next.dispose();
    },
  );
  test('one deadline leaves another consumer of the same lease alive', () async {
    final task = await lease('a');
    final started = Completer<void>();
    final response = Completer<http.Response>();
    var calls = 0;
    final p = pool((_) {
      calls++;
      if (!started.isCompleted) started.complete();
      return response.future;
    });
    final remaining = expectLater(
      p.get(resource(), task),
      completion({'id': 42}),
    );
    await started.future;
    final expired = expectLater(
      p.get(resource(), task, consumerDeadline: Future<void>.value()),
      throwsA(
        isA<MetadataFailure>().having(
          (failure) => failure.category,
          'category',
          'candidate_budget',
        ),
      ),
    );
    await expired;
    response.complete(http.Response('{"id":42}', 200));
    await remaining;
    expect(calls, 1);
    expect(p.activeRequests, 0);
  });
  test('all consumers cancel closes HTTP and discards late payload', () async {
    final a = await lease('a'), b = await lease('b');
    final started = Completer<void>(), response = Completer<http.Response>();
    var closed = false;
    final p = SharedMetadataRequests(
      tasks,
      clientFactory: () => ClosingClient((_) {
        if (!started.isCompleted) started.complete();
        return response.future;
      }, () => closed = true),
    );
    pools.add(p);
    final pa = expectLater(p.get(resource(), a), throwsA(isA<TaskStopped>()));
    final pb = expectLater(p.get(resource(), b), throwsA(isA<TaskStopped>()));
    await started.future;
    await tasks.control('a', 'cancel');
    await tasks.control('b', 'cancel');
    await Future.wait([pa, pb]);
    expect(closed, isTrue);
    expect(p.activeRequests, 0);
    response.complete(http.Response('{"id":42}', 200));
    expect((await cat.db.query('works')).single['title'], isNot('late'));
  });
  test(
    'saved local scan intent survives reopening and repeated scan keeps identity',
    () async {
      final media = await Directory(
        '${root.path}/media/Fixture',
      ).create(recursive: true);
      await File('${media.path}/01.mkv').writeAsBytes([1]);
      await cat.db.update(
        'sources',
        {'location': '${root.path}/media'},
        where: 'id=?',
        whereArgs: ['s'],
      );
      await cat.reload();
      await cat.addScanRoot('s', 'Fixture');
      var runner = ScrapeTaskRunner(cat);
      final id = await runner.enqueueScan('s');
      await cat.db.close();
      await cat.initialize(
        dataDirectory: root,
        enableFoundation: true,
        enableTasks: true,
      );
      tasks = cat.taskStore!;
      runner = ScrapeTaskRunner(cat);
      await runner.run(id);
      expect((await tasks.list()).single['state'], 'complete');
      final before = await cat.db.query(
        'assets',
        where: 'relative_path=?',
        whereArgs: ['Fixture/01.mkv'],
      );
      expect(before, hasLength(1));
      await cat.addScanRoot('s', 'Fixture');
      await runner.run(await runner.enqueueScan('s'));
      expect(
        await cat.db.query(
          'assets',
          where: 'relative_path=?',
          whereArgs: ['Fixture/01.mkv'],
        ),
        before,
      );
    },
  );
  test(
    'binding revision rejects ABA; source move invalidates scan only',
    () async {
      final a = await lease('a');
      await tasks.enqueue(
        'scan',
        sourceId: 's',
        intent: {},
        steps: ['enumerate'],
      );
      final scan = (await tasks.claim(
        'scan',
        'enumerate',
        dependsOnLocation: true,
      ))!;
      await cat.db.update(
        'sources',
        {'location': 'new-fixture'},
        where: 'id=?',
        whereArgs: ['s'],
      );
      expect(await tasks.valid(scan), isFalse);
      expect(await tasks.valid(a), isTrue);
      await cat.db.update(
        'works',
        {'bangumi_id': 42},
        where: 'id=?',
        whereArgs: [work],
      );
      await cat.db.update(
        'works',
        {'bangumi_id': null},
        where: 'id=?',
        whereArgs: [work],
      );
      expect(await tasks.valid(a), isFalse);
    },
  );
  test('1000 durable intents stay bounded and idempotent', () async {
    final before =
        (await cat.db.rawQuery('PRAGMA page_count')).single.values.single
            as int;
    final size =
        (await cat.db.rawQuery('PRAGMA page_size')).single.values.single as int;
    final clock = Stopwatch()..start();
    for (var i = 0; i < 1000; i++) {
      await tasks.enqueue(
        'fixture:$i',
        workId: work,
        sourceId: 's',
        intent: {'kind': 'metadata'},
        steps: ['tmdb', 'bangumi'],
      );
    }
    final elapsed = clock.elapsedMilliseconds;
    await tasks.enqueue(
      'fixture:0',
      workId: work,
      sourceId: 's',
      intent: {'kind': 'metadata'},
      steps: ['tmdb', 'bangumi'],
    );
    expect((await cat.db.query('scrape_tasks')).length, 1000);
    expect((await cat.db.query('scrape_steps')).length, 2000);
    final after =
        (await cat.db.rawQuery('PRAGMA page_count')).single.values.single
            as int;
    // Benchmark evidence intentionally goes to the test runner log.
    // ignore: avoid_print
    print(
      'PHASE2 tasks=1000 steps=2000 enqueue_ms=$elapsed database_growth_bytes=${(after - before) * size}',
    );
  });
  for (final status in [403, 429]) {
    test(
      '$status Retry-After blocks service, alternate resources and manual retry',
      () async {
        var calls = 0;
        final p = pool((_) async {
          calls++;
          return http.Response('{}', status, headers: {'retry-after': '120'});
        });
        final a = await lease('a');
        await expectLater(
          p.get(resource(), a),
          throwsA(
            isA<MetadataFailure>().having(
              (e) => e.category,
              'category',
              'rate_limit',
            ),
          ),
        );
        final b = await lease('b');
        await expectLater(
          p.get(resource(id: '43'), b, manualRetry: true),
          throwsA(isA<MetadataFailure>()),
        );
        expect(calls, 1);
        expect(
          (await cat.db.query('scrape_network')).single['not_before'] as int,
          greaterThan(tasks.now),
        );
      },
    );
  }
  test(
    '403 authentication does not fallback; changing auth namespace permits retry',
    () async {
      var calls = 0;
      final p = pool((_) async {
        calls++;
        return http.Response('{}', 403);
      });
      final a = await lease('a');
      await expectLater(p.get(resource(), a), throwsA(isA<MetadataFailure>()));
      await expectLater(
        p.get(resource(), a, manualRetry: true),
        throwsA(isA<MetadataFailure>()),
      );
      expect(calls, 1);
      await expectLater(
        p.get(resource(token: 'new'), a),
        throwsA(isA<MetadataFailure>()),
      );
      expect(calls, 2);
    },
  );
  for (final kind in ['html', 'wrong_id', 'offline', 'timeout']) {
    test(
      '$kind is never adopted; three attempts then durable cooldown',
      () async {
        var calls = 0;
        final p = pool((_) async {
          calls++;
          if (kind == 'offline') throw const SocketException('fixture');
          if (kind == 'timeout') return Completer<http.Response>().future;
          return http.Response(
            kind == 'html' ? '<html>blocked</html>' : '{"id":43}',
            200,
          );
        }, deadline: const Duration(milliseconds: 10));
        final a = await lease('a');
        await expectLater(
          p.get(resource(), a),
          throwsA(isA<MetadataFailure>()),
        );
        expect(calls, 3);
        await expectLater(
          p.get(resource(), a),
          throwsA(isA<MetadataFailure>()),
        );
        expect(calls, 3);
        expect((await cat.db.query('scrape_network')).single['failures'], 1);
      },
    );
  }
}
