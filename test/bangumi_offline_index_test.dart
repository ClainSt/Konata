import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart' as archive;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ccplayer/core/bangumi_offline_index.dart';
import 'package:ccplayer/core/personal_scraper.dart';
import 'package:ccplayer/core/metadata.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  test(
    'official ZIP imports bounded animation aliases, preserves ambiguity and rollback',
    () async {
      final root = await Directory.systemTemp.createTemp('konata-offline-');
      addTearDown(() => root.delete(recursive: true));
      final index = BangumiOfflineIndex(Directory('${root.path}/index'));
      final interrupted = Directory('${root.path}/index/import-interrupted');
      await interrupted.create(recursive: true);
      await File('${interrupted.path}/compact.jsonl').writeAsString('partial');
      final zip = File('${root.path}/dump-test.zip');
      final rows = [
        {
          'id': 1,
          'type': 2,
          'name': '氷菓',
          'name_cn': '冰菓',
          'date': '2012-04-22',
          'infobox': '{{Infobox\n|别名={\n[Hyouka]\n[en|Hyouka English]\n}\n}}',
        },
        {
          'id': 2,
          'type': 2,
          'name': 'Hyouka',
          'name_cn': 'Another animation',
          'date': '2020-01-01',
        },
        {'id': 3, 'type': 4, 'name': 'Hyouka', 'date': '2012-01-01'},
      ];
      final bytes = utf8.encode('${rows.map(jsonEncode).join('\n')}\n');
      final data = archive.Archive()
        ..addFile(
          archive.ArchiveFile('subject.jsonlines', bytes.length, bytes),
        );
      await zip.writeAsBytes(archive.ZipEncoder().encode(data));
      expect(await index.status(), isNull);
      await index.install(zip: zip);
      expect(await interrupted.exists(), false);
      expect((await index.status())?['subjects'], '2');
      expect((await index.lookup('Hyouka')).map((m) => m['id']).toSet(), {
        1,
        2,
      });
      expect((await index.lookup('Hyouka English')).single['id'], 1);
      expect(await index.lookup('Hyoka'), isEmpty);
      final requests = <String>[];
      final token = Metadata.token, key = Metadata.apiKey;
      Metadata.token = '';
      Metadata.apiKey = '';
      addTearDown(() {
        Metadata.token = token;
        Metadata.apiKey = key;
      });
      final scraper = PersonalMetadataScraper(
        offlineIndex: index,
        client: MockClient((request) async {
          requests.add('${request.method} ${request.url.path}');
          if (request.method == 'GET') throw const SocketException('offline');
          return http.Response('{"data":[]}', 200);
        }),
      );
      addTearDown(scraper.close);
      final match = await scraper.scrape({'title': 'Hyouka', 'year': 2012});
      expect(match?.bangumiId, 1);
      expect(requests, ['GET /v0/subjects/1']);
      expect(
        await scraper.scrape({
          'title': 'Hyouka',
          'year': 2012,
          'bangumi_id': 2,
        }),
        isNull,
      );
      expect(
        await scraper.scrape({'title': 'Hyouka S2', 'year': 2012}),
        isNull,
      );
      expect(await scraper.scrape({'title': 'Hyouka'}), isNull);
      expect(requests.where((r) => r.startsWith('POST')), isNotEmpty);
      final before = await File(
        '${root.path}/index/animation.sqlite',
      ).readAsBytes();
      await zip.writeAsBytes([1, 2, 3]);
      await expectLater(index.install(zip: zip), throwsA(isA<Exception>()));
      expect(
        await File('${root.path}/index/animation.sqlite').readAsBytes(),
        before,
      );
      // Interruption between the old/new rename must still leave readable data.
      await File(
        '${root.path}/index/animation.sqlite',
      ).rename('${root.path}/index/animation.previous.sqlite');
      expect((await index.lookup('Hyouka English')).single['id'], 1);
      await index.remove();
      expect(await index.lookup('Hyouka'), isEmpty);
      expect(
        await scraper.scrape({'title': 'Hyouka', 'year': 2012}),
        isNull,
        reason:
            'Removing an index invalidates scraper memoized local identities',
      );
    },
  );

  test(
    'real official snapshot import measurement',
    () async {
      final source = File(const String.fromEnvironment('BANGUMI_ARCHIVE'));
      final root = Directory(
        const String.fromEnvironment('BANGUMI_INDEX_OUTPUT'),
      );
      final index = BangumiOfflineIndex(root);
      final watch = Stopwatch()..start();
      await index.install(zip: source);
      // ignore: avoid_print
      print(
        'BANGUMI_INDEX ${jsonEncode({...?await index.status(), 'ms': watch.elapsedMilliseconds, 'rssBytes': ProcessInfo.currentRss, 'maxRssBytes': ProcessInfo.maxRss})}',
      );
      expect((await index.lookup('Hyouka')).isNotEmpty, true);
    },
    timeout: const Timeout(Duration(minutes: 15)),
    skip:
        const String.fromEnvironment('BANGUMI_ARCHIVE').isEmpty ||
        const String.fromEnvironment('BANGUMI_INDEX_OUTPUT').isEmpty,
  );
}
