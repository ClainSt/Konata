import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccplayer/core/sources.dart';

void main() {
  test('browse WebDAV folder with Chinese names through PROPFIND', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var calls = 0;
    server.listen((req) async {
      calls++;
      await req.drain<void>();
      req.response.statusCode = 207;
      req.response.headers.contentType = ContentType('application', 'xml');
      req.response.write(
        '<d:multistatus xmlns:d="DAV:">'
        '<d:response><d:href>/dav/</d:href></d:response>'
        '<d:response><d:href>/dav/%E5%8A%A8%E7%94%BB/</d:href>'
        '<d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype>'
        '</d:prop></d:propstat></d:response>'
        '<d:response><d:href>/dav/video.mkv</d:href>'
        '<d:propstat><d:prop><d:getcontentlength>1234</d:getcontentlength>'
        '</d:prop></d:propstat></d:response>'
        '</d:multistatus>',
      );
      await req.response.close();
    });
    try {
      final dav = WebDav({
        'location': 'http://127.0.0.1:${server.port}/dav',
        'username': '',
        'password': '',
      });
      final entries = await dav.list(dav.directoryUri(''));
      expect(calls, 1);
      expect(
        entries.map((entry) => entry.name),
        containsAll(['动画', 'video.mkv']),
      );
      expect(
        entries.firstWhere((entry) => entry.name == '动画').isDirectory,
        isTrue,
      );
      expect(
        entries.firstWhere((entry) => entry.name == 'video.mkv').size,
        1234,
      );
      expect(
        dav.directoryUri('动画').pathSegments.where((s) => s.isNotEmpty).last,
        '动画',
      );
    } finally {
      await server.close(force: true);
    }
  });
}
