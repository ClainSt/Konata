import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccplayer/core/sources.dart';

void main() {
  test('anonymous WebDAV does not send Authorization header', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final headers = <String?>[];
    server.listen((req) async {
      headers.add(req.headers.value('authorization'));
      await req.drain<void>();
      req.response.statusCode = 207;
      req.response.write(
        '<d:multistatus xmlns:d="DAV:">'
        '<d:response><d:href>/dav/</d:href></d:response>'
        '<d:response><d:href>/dav/Anime/</d:href>'
        '<d:propstat><d:prop><d:resourcetype>'
        '<d:collection/></d:resourcetype></d:prop></d:propstat>'
        '</d:response></d:multistatus>',
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
      expect(entries.single.name, 'Anime');
      expect(headers, [null]);
    } finally {
      await server.close(force: true);
    }
  });
}
