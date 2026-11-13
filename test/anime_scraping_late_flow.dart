import 'dart:convert';
import 'dart:io';

import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/chapter_relations.dart';
import 'package:ccplayer/core/image_store.dart';
import 'package:ccplayer/core/library_backup_exporter.dart';
import 'package:ccplayer/core/library_backup_restorer.dart';
import 'package:ccplayer/core/library_merge.dart';
import 'package:ccplayer/core/metadata.dart';
import 'package:ccplayer/core/metadata_servers.dart';
import 'package:ccplayer/core/scoped_artwork.dart';
import 'package:ccplayer/core/scan_recognition.dart';
import 'package:ccplayer/core/scrape_task_runner.dart';
import 'package:ccplayer/core/shared_metadata_requests.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> exerciseScrapeLibrary(
  Directory root, {
  List<int> videoBytes = const [0, 1, 2],
}) async {
  SharedPreferences.setMockInitialValues({});
  final catalog = Catalog.instance;
  Metadata.token = 'fixture-only-token';
  Metadata.authMode = 'token';
  MetadataServers.fallback = false;
  final libraryA = Directory('${root.path}/library-a');
  final libraryB = Directory('${root.path}/library-b');
  final mediaA = await Directory(
    '${root.path}/media-a/Series',
  ).create(recursive: true);
  final mediaB = await Directory(
    '${root.path}/media-b/Series',
  ).create(recursive: true);
  for (final dir in [mediaA, mediaB]) {
    await File('${dir.path}/E01.mkv').writeAsBytes(videoBytes);
    await File('${dir.path}/E02.mkv').writeAsBytes(videoBytes);
  }
  Future<void> open(Directory path) => catalog.initialize(
    dataDirectory: path,
    enableFoundation: true,
    enableTasks: true,
    enableMappings: true,
    enableRecognition: true,
    enableScopedArtwork: true,
    enableChapterRelations: true,
    enableLibraryMerge: true,
  );
  Future<String> seed(Directory path) async {
    final source = await catalog.addSource(
      'local',
      'Fixture',
      path.parent.path,
    );
    for (final episode in [1, 2]) {
      await catalog.indexVideo(
        source,
        'Series/E0$episode.mkv',
        videoBytes.length,
        workFolder: 'Series',
      );
    }
    await catalog.reload();
    return source;
  }

  Future<void> stop() async {
    catalog.taskStore?.dispose();
    catalog.taskStore = null;
    await catalog.db.close();
    await ImageStore.close();
  }

  var opened = false;
  try {
    await open(libraryA);
    opened = true;
    final sourceA = await seed(mediaA);
    final workA = catalog.works.single['id'] as String;
    final assetA =
        catalog.assets.singleWhere((a) => a['name'] == 'E01.mkv')['id']
            as String;
    final requests = <String>[];
    final downloads = <String>[];
    var bangumiImageFails = false;
    var backdropImageFails = false;
    http.Response reply(Map body) => http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json'},
    );
    final transport = SharedMetadataRequests(
      catalog.taskStore!,
      retryDelays: const [],
      clientFactory: () => MockClient((req) async {
        requests.add(req.url.path);
        if (req.url.path == '/v0/subjects/21') {
          return reply({
            'id': 21,
            'images': {'large': 'https://lain.bgm.tv/pic/cover/l/fixture.jpg'},
          });
        }
        if (req.url.path == '/3/tv/42/season/1/episode/1/images') {
          return reply({
            'id': 1101,
            'stills': [
              {
                'width': 1280,
                'height': 720,
                'iso_639_1': null,
                'file_path': '/episode-choice.jpg',
              },
            ],
          });
        }
        if (req.url.path == '/3/tv/42') {
          return reply({
            'id': 42,
            'poster_path': '/tmdb-default.jpg',
            'backdrop_path': '/default-background.jpg',
          });
        }
        return reply({
          'id': 1300,
          'posters': [
            {
              'width': 1000,
              'height': 1500,
              'iso_639_1': null,
              'file_path': '/fixture.jpg',
            },
          ],
        });
      }),
    );
    final runner = ScrapeTaskRunner(catalog, requests: transport);
    await runner.recognition.schedule(sourceA);
    Future<Map<String, Object?>> review(String source, String layer) async {
      final row = (await catalog.db.query(
        'scan_bindings',
        where: 'work_id=? AND provider=? AND layer=?',
        whereArgs: [workA, source, layer],
      )).single;
      return {
        ...row,
        'session': (await catalog.db.query('scrape_runtime')).single['session'],
        'identity_revision': (await catalog.db.query(
          'library_work_protection',
          where: 'work_id=?',
          whereArgs: [workA],
        )).single['revision'],
      };
    }

    await runner.recognition.decide(await review('tmdb', 'work'), {
      'id': 42,
      'type': 'tv',
      'title': 'Fixture series',
      'seasons': [
        {'season': 1, 'count': 12},
      ],
    });
    await runner.recognition.decide(await review('tmdb', 'range'), {
      'season': 1,
      'first': 1,
      'last': 12,
      'offset': 0,
    });
    await runner.recognition.decide(await review('bangumi', 'work'), {
      'id': 21,
      'type': 'anime',
    });
    await runner.recognition.decide(await review('bangumi', 'range'), {
      'id': 21,
      'summary': 'Fixture synopsis',
    });
    final partId = (await review('bangumi', 'range'))['id'] as String;
    final part = (await ScanRecognition.partOverviewPreview(catalog, partId))!;
    await ScanRecognition.savePartOverview(catalog, part, 'empty', null);
    final blank = (await ScanRecognition.partOverviewPreview(catalog, partId))!;
    expect(blank['value'], isNull);
    expect(blank['automatic'], 'Fixture synopsis');
    await expectLater(
      ScanRecognition.savePartOverview(catalog, part, 'manual', 'Stale'),
      throwsA(anything),
    );
    await ScanRecognition.savePartOverview(catalog, blank, 'auto', null);
    expect(
      (await ScanRecognition.partOverviewPreview(catalog, partId))!['value'],
      'Fixture synopsis',
    );
    final art = ScopedArtwork(
      catalog,
      transport,
      budget: const Duration(milliseconds: 300),
      fetchImage: (url, check) async {
        check();
        downloads.add(url);
        if (bangumiImageFails && url.contains('lain.bgm.tv')) {
          throw const FormatException('Fixture download failure');
        }
        if (backdropImageFails && url.endsWith('/default-background.jpg')) {
          throw const FormatException('Fixture download failure');
        }
      },
    );
    Future<void> pick({
      ScopedImage kind = ScopedImage.poster,
      Map<String, Object?>? restoreBackdrop,
    }) async {
      final id = await art.enqueue(
        workA,
        kind,
        restoreBackdrop: restoreBackdrop,
      );
      expect(id, isNotNull);
      final lease = (await catalog.taskStore!.claim(id!, 'scoped_artwork'))!;
      final task = (await catalog.db.query(
        'scrape_tasks',
        where: 'id=?',
        whereArgs: [id],
      )).single;
      await art.run(lease, jsonDecode(task['intent_json'] as String) as Map);
    }

    await pick();
    expect((await art.review(workA, ScopedImage.poster))!['state'], 'complete');
    expect((await art.displayed(workA, ScopedImage.poster)), contains('lain.'));
    expect(requests, ['/v0/subjects/21']);
    expect(Catalog.preferredPoster(catalog.works.single), contains('lain.'));
    bangumiImageFails = true;
    await art.decide(
      workA,
      ScopedImage.poster,
      (await art.review(workA, ScopedImage.poster))!,
      null,
      automatic: true,
    );
    await pick();
    expect((await art.review(workA, ScopedImage.poster))!['state'], 'complete');
    expect(
      await art.displayed(workA, ScopedImage.poster),
      contains('/w342/tmdb-default.jpg'),
    );
    expect(requests.where((p) => p == '/v0/subjects/21'), hasLength(2));
    expect(downloads, hasLength(3));
    expect(await art.enqueue(workA, ScopedImage.poster), isNull);
    final poster = (await art.review(workA, ScopedImage.poster))!;
    await art.decide(workA, ScopedImage.poster, poster, null);
    expect(await art.displayed(workA, ScopedImage.poster), isNull);
    await expectLater(
      art.decide(workA, ScopedImage.poster, poster, null),
      throwsA(anything),
    );
    await pick(kind: ScopedImage.backdrop);
    final backdrop = (await art.review(workA, ScopedImage.backdrop))!;
    expect(backdrop['can_restore'], true);
    expect(
      await art.displayed(workA, ScopedImage.backdrop),
      endsWith('/default-background.jpg'),
    );
    await art.decide(workA, ScopedImage.backdrop, backdrop, {
      'provider': 'tmdb',
      'url': 'https://image.tmdb.org/t/p/w780/chosen-background.jpg',
    });
    expect(
      await art.enqueue(workA, ScopedImage.backdrop, restoreBackdrop: backdrop),
      isNull,
    );
    final manualBackdrop = (await art.review(workA, ScopedImage.backdrop))!;
    backdropImageFails = true;
    await pick(kind: ScopedImage.backdrop, restoreBackdrop: manualBackdrop);
    expect(
      await art.displayed(workA, ScopedImage.backdrop),
      endsWith('/chosen-background.jpg'),
    );
    backdropImageFails = false;
    await pick(kind: ScopedImage.backdrop, restoreBackdrop: manualBackdrop);
    expect(
      await art.displayed(workA, ScopedImage.backdrop),
      endsWith('/default-background.jpg'),
    );
    final ep = (await catalog.db.query(
      'scan_bindings',
      where: "asset_id=? AND provider='tmdb' AND layer='episode'",
      whereArgs: [assetA],
    )).single;
    await runner.recognition.decide(
      {
        ...ep,
        'session': (await catalog.db.query('scrape_runtime')).single['session'],
        'identity_revision': (await review(
          'tmdb',
          'work',
        ))['identity_revision'],
      },
      {
        'season': 1,
        'episode': 1,
        'chapter_id': 1101,
        'still': 'https://image.tmdb.org/t/p/w500/episode-automatic.jpg',
      },
    );
    Future<Map> episodeDetails() async =>
        (await ScanRecognition.details(
              catalog,
              catalog.works.single,
            ))!['recognized_file_details'][assetA]
            as Map;
    expect(
      (await episodeDetails())['still'],
      contains('episode-automatic.jpg'),
    );
    final stillPreview = (await art.review(
      workA,
      ScopedImage.still,
      asset: assetA,
    ))!;
    final gallery = (await art.enqueue(
      workA,
      ScopedImage.still,
      asset: assetA,
      gallery: true,
    ))!;
    final galleryLease = (await catalog.taskStore!.claim(
      gallery,
      'scoped_artwork',
    ))!;
    final galleryTask = (await catalog.db.query(
      'scrape_tasks',
      where: 'id=?',
      whereArgs: [gallery],
    )).single;
    await art.run(
      galleryLease,
      jsonDecode(galleryTask['intent_json'] as String) as Map,
    );
    final galleryResult = (await catalog.db.query(
      'scrape_steps',
      where: 'task_id=?',
      whereArgs: [gallery],
    )).single;
    final candidate =
        (jsonDecode(galleryResult['result_json'] as String)['candidates']
                    as List)
                .single
            as Map<String, dynamic>;
    await art.decide(
      workA,
      ScopedImage.still,
      stillPreview,
      candidate,
      asset: assetA,
    );
    expect((await episodeDetails())['still'], contains('episode-choice.jpg'));
    await expectLater(
      art.decide(workA, ScopedImage.still, stillPreview, null, asset: assetA),
      throwsA(anything),
    );
    final manual = (await art.review(workA, ScopedImage.still, asset: assetA))!;
    await art.decide(workA, ScopedImage.still, manual, null, asset: assetA);
    expect((await episodeDetails())['blank_still'], isTrue);
    final blankStill = (await art.review(
      workA,
      ScopedImage.still,
      asset: assetA,
    ))!;
    await art.decide(
      workA,
      ScopedImage.still,
      blankStill,
      null,
      asset: assetA,
      automatic: true,
    );
    expect(
      (await episodeDetails())['still'],
      contains('episode-automatic.jpg'),
    );
    await art.decide(
      workA,
      ScopedImage.still,
      (await art.review(workA, ScopedImage.still, asset: assetA))!,
      candidate,
      asset: assetA,
    );

    await catalog.db.insert('progress', {
      'asset_id': assetA,
      'position_ms': 1900,
      'duration_ms': 4000,
      'completed': 0,
      'updated_at': '2026-01-01T00:00:00Z',
      'watched_ranges': '[[0,950],[1900,2000]]',
    });
    final chapter = ChapterRelations(catalog.db);
    final session = await chapter.session();
    for (final (label, start, end) in [
      ('First', 0, 1000),
      ('Second', 1000, 2000),
    ]) {
      await chapter.saveEdition(
        work: workA,
        title: label,
        label: 'Full source',
        expectedParts: 1,
        parts: [(asset: assetA, start: start, end: end)],
        session: session,
      );
    }
    final chapters = await chapter.chapters(workA);
    expect(ChapterRelations.completed(chapters.first, 90), isTrue);
    expect(ChapterRelations.completed(chapters.last, 90), isFalse);
    final second = ChapterRelations.parts(
      ChapterRelations.editions(chapters.last).single,
    ).single;
    expect(ChapterRelations.startPosition(second), 1900);
    final first = ChapterRelations.parts(
      ChapterRelations.editions(chapters.first).single,
    ).single;
    expect(ChapterRelations.startPosition(first), 0);
    final exporter = LibraryBackupExporter(
      database: catalog.db,
      artworkDirectory: await ImageStore.directory(),
      preferences: await SharedPreferences.getInstance(),
    );
    final backup = await exporter.export(File('${root.path}/library.zip'));
    for (final name in ['Retained', 'Withdrawn']) {
      await catalog.indexVideo(
        sourceA,
        '$name/Extra.mkv',
        videoBytes.length,
        workFolder: name,
      );
    }
    final undoBackup = await exporter.export(
      File('${root.path}/library-undo.zip'),
    );

    await stop();
    opened = false;
    await open(libraryB);
    opened = true;
    final sourceB = await seed(mediaB);
    final workB = catalog.works.single['id'] as String;
    final assetB =
        catalog.assets.singleWhere((a) => a['name'] == 'E01.mkv')['id']
            as String;
    expect(assetB, isNot(assetA));
    await catalog.db.insert('progress', {
      'asset_id': assetB,
      'position_ms': 2300,
      'duration_ms': 4000,
      'completed': 0,
      'updated_at': '2026-01-02T00:00:00Z',
      'watched_ranges': '[[2000,2300]]',
    });
    final restorer = LibraryBackupRestorer(
      database: catalog.db,
      artworkDirectory: await ImageStore.directory(),
    );
    final staged = await restorer.prepare(backup);
    try {
      final review = await restorer.previewMerge(staged, {sourceA: sourceB});
      expect(review.newRows['assets'], isNull);
      expect(review.conflicts.where((r) => r.positionChoice), hasLength(1));
      final rollback = await restorer.restore(staged, merge: review);
      expect(await rollback.exists(), isTrue);
      expect((await catalog.db.query('assets')).length, 2);
      expect(
        (await catalog.db.query('sources')).single['location'],
        mediaB.parent.path,
      );
      expect(await catalog.sourceNeedsAssociation(sourceB), isFalse);
      expect(await catalog.resumePosition(assetB), 2300);
      final conflicts = await catalog.db.query(
        'library_merge_conflicts',
        where: "table_name='progress'",
      );
      expect(conflicts, hasLength(1));
      await LibraryMerge.resolvePosition(
        catalog.db,
        conflicts.single['id'] as String,
        useIncoming: true,
      );
      expect(await catalog.resumePosition(assetB), 1900);
      expect(
        (await catalog.db.query('progress')).single['watched_ranges'],
        '[[2000,2300]]',
      );
      expect(await ChapterRelations(catalog.db).chapters(workB), hasLength(2));
      final still = (await catalog.db.query(
        'scoped_artwork',
        where: "work_id=? AND kind='still'",
        whereArgs: [workB],
      )).single;
      expect(still['state'], 'manual');
      expect(still['selected'], contains('episode-choice.jpg'));
      final merged = await LibraryBackupExporter(
        database: catalog.db,
        artworkDirectory: await ImageStore.directory(),
        preferences: await SharedPreferences.getInstance(),
      ).export(File('${root.path}/merged.zip'));
      final validation = await restorer.prepare(merged);
      await validation.dispose();
      final undo = (await restorer.previewMergeUndo())!;
      expect(undo.retained, greaterThan(0));
      expect(await catalog.resumePosition(assetB), 1900);
    } finally {
      await staged.dispose();
    }
    final undoStaged = await restorer.prepare(undoBackup);
    try {
      final review = await restorer.previewMerge(undoStaged, {
        sourceA: sourceB,
      });
      await restorer.restore(undoStaged, merge: review);
      final stale = (await restorer.previewMergeUndo())!;
      final retained = (await catalog.db.query(
        'assets',
        where: 'relative_path=?',
        whereArgs: ['Retained/Extra.mkv'],
      )).single;
      await catalog.db.insert('progress', {
        'asset_id': retained['id'],
        'position_ms': 900,
        'duration_ms': 4000,
        'completed': 0,
        'updated_at': '2026-01-03T00:00:00Z',
        'watched_ranges': '[[0,900]]',
      });
      await expectLater(restorer.undoMerge(stale), throwsStateError);
      final current = (await restorer.previewMergeUndo())!;
      expect(current.retained, greaterThan(stale.retained));
      expect(current.affected, greaterThan(0));
      await restorer.undoMerge(current);
      expect(await restorer.previewMergeUndo(), isNull);
      expect(await catalog.resumePosition(retained['id'] as String), 900);
      expect(await catalog.resumePosition(assetB), 1900);
      expect(
        await catalog.db.query(
          'assets',
          where: 'relative_path=?',
          whereArgs: ['Withdrawn/Extra.mkv'],
        ),
        isEmpty,
      );
    } finally {
      await undoStaged.dispose();
    }
  } finally {
    if (opened) await stop();
    ImageStore.root = null;
  }
}
