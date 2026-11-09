import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/metadata.dart';
import 'package:ccplayer/core/personal_scraper.dart';
import 'package:ccplayer/core/selected_scan_workflow.dart';
import 'package:ccplayer/core/scan_activity.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    '1001 WebDAV BDRip directories scan and scrape without reading media bytes',
    () async {
      final oldOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      final dir = await Directory.systemTemp.createTemp('konata-webdav-scale-');
      final cat = Catalog.instance;
      await cat.initialize(dataDirectory: dir);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final token = Metadata.token, key = Metadata.apiKey;
      Metadata.token = '';
      Metadata.apiKey = '';
      addTearDown(() async {
        Metadata.token = token;
        Metadata.apiKey = key;
        await server.close(force: true);
        await cat.db.close();
        await dir.delete(recursive: true);
        HttpOverrides.global = oldOverrides;
      });
      var listings = 0, mediaReads = 0;
      server.listen((request) async {
        await request.drain<void>();
        if (request.method != 'PROPFIND') {
          mediaReads++;
          request.response.statusCode = 405;
          await request.response.close();
          return;
        }
        listings++;
        String entry(String path, bool folder) =>
            '<d:response><d:href>${Uri.encodeFull(path)}</d:href><d:propstat><d:prop><d:resourcetype>${folder ? '<d:collection/>' : ''}</d:resourcetype><d:getcontentlength>1000000000</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>';
        final path =
            '/${request.uri.pathSegments.where((part) => part.isNotEmpty).join('/')}/';
        final entries = path == '/dav/'
            ? [for (var i = 0; i < 1001; i++) entry('/dav/Anime $i/', true)]
            : [
                for (var e = 1; e <= 12; e++) entry('$path[$e].mkv', false),
                entry('${path}cover.jpg', false),
                entry('${path}01.ass', false),
              ];
        request.response.statusCode = 207;
        request.response.write(
          '<d:multistatus xmlns:d="DAV:">${entry(path, true)}${entries.join()}</d:multistatus>',
        );
        await request.response.close();
      });
      final source = <String, Object?>{
        'id': 'scale',
        'kind': 'webdav',
        'label': 'Scale fixture',
        'location': 'http://127.0.0.1:${server.port}/dav/',
        'username': '',
      };
      await cat.db.insert('sources', source);
      await cat.reload();
      await cat.addScanRoot('scale', '');
      var metadataCalls = 0;
      final client = MockClient((request) async {
        metadataCalls++;
        final id = request.method == 'POST'
            ? int.parse(
                (jsonDecode(request.body) as Map)['keyword']
                    .toString()
                    .split(' ')
                    .last,
              )
            : int.parse(request.url.path.split('/').last);
        final row = {
          'id': id,
          'name': 'Anime $id',
          'images': {'large': 'https://example.org/$id.jpg'},
        };
        return http.Response(
          jsonEncode(
            request.method == 'POST'
                ? {
                    'data': [row],
                  }
                : row,
          ),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final scraper = PersonalMetadataScraper(client: client);
      addTearDown(() {
        scraper.close();
        client.close();
      });
      final watch = Stopwatch()..start();
      await SelectedScanWorkflow.run(source, scraper: scraper);
      final activity = ScanActivityStore.instance.forSource('scale')!;
      expect(activity.phase, ScanPhase.complete, reason: activity.error);
      expect(cat.works.length, 1001);
      expect(cat.assets.length, 12012);
      expect(activity.matched, 1001);
      expect(activity.metadataErrors, 0);
      expect(listings, 1002);
      expect(mediaReads, 0);
      expect(metadataCalls, 2002);
      // ignore: avoid_print
      print(
        'WEBDAV_SCALE directories=1002 titles=1001 assets=12012 mediaReads=0 metadataRequests=$metadataCalls elapsedMs=${watch.elapsedMilliseconds}',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
