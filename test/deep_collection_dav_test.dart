import 'dart:io';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/scrape_task_runner.dart';
import 'package:ccplayer/core/shared_metadata_requests.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Loopback extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('DAV traverses arbitrary containers and separates works from bonus folders', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final temp = await Directory.systemTemp.createTemp('konata-deep-dav-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      const base = '收藏/动画/未添加TMDB ID/弹丸论破系列';
      const files = [
        '$base/弹丸论破3/[LoliHouse] Danganronpa 3 - Mirai Hen - 01.mkv',
        '$base/弹丸论破3/SPs/Bonus/PV01.mkv',
        '$base/弹丸论破/Season 01/01.mkv',
      ];
      final visited = <String>{};
      final connections = <int>{};
      var activeListings = 0;
      var peakListings = 0;
      server.listen((request) async {
        final dir = Uri.decodeComponent(request.uri.path).replaceFirst('/fixture/', '').replaceFirst(RegExp(r'/$'), '');
        visited.add(dir);
        connections.add(request.connectionInfo!.remotePort);
        activeListings++;
        if (activeListings > peakListings) peakListings = activeListings;
        await Future<void>.delayed(const Duration(milliseconds: 80));
        activeListings--;
        final prefix = dir.isEmpty ? '' : '$dir/';
        final entries = <String, bool>{};
        for (final file in files.where((f) => f.startsWith(prefix))) {
          final rest = file.substring(prefix.length);
          entries[rest.split('/').first] = rest.contains('/');
        }
        request.response.statusCode = 207;
        request.response.headers.contentType = ContentType('application', 'xml');
        request.response.write('<d:multistatus xmlns:d="DAV:">');
        final self = Uri(path: '/fixture/$prefix').toString();
        request.response.write('<d:response><d:href>$self</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>');
        for (final e in entries.entries) {
          final href = Uri(path: '/fixture/$prefix${e.key}${e.value ? '/' : ''}').toString();
          request.response.write('<d:response><d:href>$href</d:href><d:propstat><d:prop><d:resourcetype>${e.value ? '<d:collection/>' : ''}</d:resourcetype><d:getcontentlength>10</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>');
        }
        request.response.write('</d:multistatus>');
        await request.response.close();
      });
      final cat = Catalog.instance;
      SharedPreferences.setMockInitialValues({});
      try {
        await cat.initialize(dataDirectory: Directory('${temp.path}/library'),
          enableFoundation: true, enableTasks: true, enableMappings: true, enableRecognition: true);
        final source = await cat.addSource('webdav', 'Fixture', 'http://127.0.0.1:${server.port}/fixture/');
        await cat.addScanRoot(source, '');
        final requests = SharedMetadataRequests(cat.taskStore!, clientFactory: () => MockClient((_) async => http.Response('{"results":[],"data":[]}', 200)));
        try {
          final runner = ScrapeTaskRunner(cat, requests: requests);
          await runner.run(await runner.enqueueScan(source));
          expect(cat.assets, hasLength(3));
          expect(cat.works.map((w) => w['title']), unorderedEquals(['弹丸论破3', '弹丸论破']));
          final rows = await cat.db.rawQuery('SELECT w.title,a.name FROM assets a JOIN works w ON w.id=a.work_id');
          expect(rows.singleWhere((r) => r['name'] == 'PV01.mkv')['title'], '弹丸论破3');
          expect(visited, contains('$base/弹丸论破3/SPs/Bonus'));
          expect(peakListings, inInclusiveRange(2, 4));
          expect(connections.length, lessThan(visited.length));
        } finally { requests.close(); }
      } finally {
        cat.taskStore?.dispose();
        cat.taskStore = null;
        await cat.db.close();
        await server.close(force: true);
        await temp.delete(recursive: true);
      }
    }, _Loopback());
  });
}
