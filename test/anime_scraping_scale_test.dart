import 'dart:convert';
import 'dart:io';

import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/image_store.dart';
import 'package:ccplayer/core/scrape_task_runner.dart';
import 'package:ccplayer/core/shared_metadata_requests.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'scale: 2400-work directory scan and unchanged checkpoint',
    () async {
      const count = 2400;
      final root = await Directory.systemTemp.createTemp(
        'konata-scrape-scale-',
      );
      final catalog = Catalog.instance;
      SharedPreferences.setMockInitialValues({});
      var opened = false;
      try {
        final media = await Directory('${root.path}/media').create();
        for (var i = 0; i < count; i++) {
          final folder = await Directory(
            '${media.path}/Fixture Work ${i.toString().padLeft(4, '0')}',
          ).create();
          await File('${folder.path}/E01.mkv').writeAsBytes([1, 2, 3]);
        }
        final library = Directory('${root.path}/library');
        await catalog.initialize(
          dataDirectory: library,
          enableFoundation: true,
          enableTasks: true,
          enableMappings: true,
          enableRecognition: true,
          enableScopedArtwork: true,
          enableChapterRelations: true,
          enableLibraryMerge: true,
        );
        opened = true;
        final source = await catalog.addSource(
          'local',
          'Scale fixture',
          media.path,
        );
        await catalog.addScanRoot(source, '');
        var requests = 0;
        final runner = ScrapeTaskRunner(
          catalog,
          requests: SharedMetadataRequests(
            catalog.taskStore!,
            retryDelays: const [],
            clientFactory: () => MockClient((_) async {
              requests++;
              return http.Response(
                '{"data":[]}',
                200,
                headers: {'content-type': 'application/json'},
              );
            }),
          ),
        );
        Future<Map<String, Object?>> scan() async {
          final before = requests;
          final time = Stopwatch()..start();
          final id = await runner.enqueueScan(source);
          await runner.run(id);
          final elapsed = time.elapsedMilliseconds;
          final row = (await catalog.db.query(
            'scrape_steps',
            where: "task_id=? AND step='enumerate'",
            whereArgs: [id],
          )).single;
          expect(row['state'], 'complete');
          return {
            'ms': elapsed,
            'identity_requests': requests - before,
            ...jsonDecode(row['result_json'] as String) as Map<String, dynamic>,
          };
        }

        final initial = await scan();
        expect(initial['added'], count);
        final repeat = await scan();
        expect(repeat['added'], 0);
        expect(repeat['changed'], 0);
        expect(repeat['missing'], 0);
        expect(repeat['identity_requests'], lessThanOrEqualTo(16));
        expect(catalog.assets, hasLength(count));
        expect(catalog.works, hasLength(count));
        expect(await catalog.db.query('scan_discoveries'), isEmpty);
        final dbBytes =
            (await catalog.db.rawQuery(
                  'PRAGMA page_count',
                )).single.values.single
                as int;
        final pageSize =
            (await catalog.db.rawQuery('PRAGMA page_size')).single.values.single
                as int;
        // Process peak includes the Flutter test runner and fixture allocation.
        int? maxRss;
        try {
          maxRss = ProcessInfo.maxRss;
        } on UnsupportedError {
          maxRss = null;
        }
        // Report observed figures with their scope so they are not mistaken for app-only overhead.
        // ignore: avoid_print
        print(
          'KONATA_SCRAPE_SCALE ${jsonEncode({'works': count, 'initial': initial, 'repeat': repeat, 'db_page_bytes': dbBytes * pageSize, 'test_process_peak_rss_bytes': maxRss})}',
        );
      } finally {
        if (opened) {
          catalog.taskStore?.dispose();
          catalog.taskStore = null;
          await catalog.db.close();
          await ImageStore.close();
        }
        ImageStore.root = null;
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
