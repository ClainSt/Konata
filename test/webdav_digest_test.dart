import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccplayer/core/sources.dart';

void main() {
  test('WebDAV supports Digest challenge on folder listing', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var digestRequests = 0;
    server.listen((request) async {
      final authorization = request.headers.value('authorization') ?? '';
      await request.drain<void>();
      if (authorization.startsWith('Digest ')) {
        digestRequests++;
        request.response.statusCode = 207;
        request.response.headers.contentType = ContentType(
          'application',
          'xml',
        );
        request.response.write(
          '<d:multistatus xmlns:d="DAV:">'
          '<d:response><d:href>/dav/</d:href></d:response>'
          '<d:response><d:href>/dav/Anime/</d:href>'
          '<d:propstat><d:prop><d:resourcetype><d:collection/>'
          '</d:resourcetype></d:prop></d:propstat></d:response></d:multistatus>',
        );
      } else {
        request.response.statusCode = 401;
        request.response.headers.set(
          'WWW-Authenticate',
          'Digest realm="demo", nonce="abc123", algorithm=MD5, qop="auth"',
        );
      }
      await request.response.close();
    });
    try {
      final dav = WebDav({
        'location': 'http://127.0.0.1:${server.port}/dav',
        'username': 'user',
        'password': 'demo',
      });
      final files = await dav.list(dav.directoryUri(''));
      expect(files.single.name, 'Anime');
      expect(digestRequests, 1);
    } finally {
      await server.close(force: true);
    }
  });
}
