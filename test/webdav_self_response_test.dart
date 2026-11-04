import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccplayer/core/sources.dart';

void main() {
  test('CloudDrive2 Depth:1 self href is not a phantom same-name child', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    const parent = '动画-单作品';
    const anime = '16bit的感动 ANOTHER LAYER (2023) {tmdb-217512}';
    final prefix =
        '/dav/${Uri.encodeComponent(parent)}/${Uri.encodeComponent(anime)}';
    var calls = 0;
    server.listen((request) async {
      calls++;
      await request.drain<void>();
      request.response.statusCode = 207;
      request.response.headers.contentType = ContentType('application', 'xml');
      String response(String href, {bool directory = true, int? size}) {
        return '<d:response><d:href>$href</d:href><d:propstat><d:prop>'
            '<d:resourcetype>${directory ? '<d:collection/>' : ''}</d:resourcetype>'
            "${size == null ? '' : '<d:getcontentlength>$size</d:getcontentlength>'}"
            '</d:prop></d:propstat></d:response>';
      }

      request.response.write(
        '<d:multistatus xmlns:d="DAV:">'
        "${response('$prefix/')}"
        '${response(prefix)}'
        "${response('/dav/${Uri.encodeComponent(parent)}/')}"
        "${response('$prefix/CDs/')}"
        "${response('$prefix/Scans/')}"
        "${response('$prefix/SPs/')}"
        "${response('$prefix/SPs/CM01.mkv', directory: false, size: 9)}"
        "${response('$prefix/%5BSweetSub%5D%20Episode%20%5B01%5D.mkv', directory: false, size: 1234)}"
        "${response('$prefix/%5BSweetSub%5D%20Episode%20%5B01%5D.mkv', directory: false, size: 1234)}"
        "${response('$prefix/%5BSweetSub%5D%20Episode%20%5B01%5D.chs.ass', directory: false, size: 99)}"
        '</d:multistatus>',
      );
      await request.response.close();
    });
    try {
      final dav = WebDav({
        'location': 'http://127.0.0.1:${server.port}/dav',
        'username': '',
        'password': '',
      });
      final current = dav.directoryUri('$parent/$anime');
      final children = await dav.list(current);
      expect(calls, 1);
      expect(
        children.map((e) => e.name).toList(),
        containsAll([
          'CDs',
          'Scans',
          'SPs',
          '[SweetSub] Episode [01].mkv',
          '[SweetSub] Episode [01].chs.ass',
        ]),
      );
      expect(children, hasLength(5));
      expect(
        children.where((e) => e.name == anime),
        isEmpty,
        reason: 'The parent PROPFIND response must not become a child',
      );
      expect(
        children.where((e) => e.name.contains('CM01')),
        isEmpty,
        reason: 'Depth:1 must never leak nested resources',
      );
      expect(children.singleWhere((e) => e.name.endsWith('.mkv')).size, 1234);
    } finally {
      await server.close(force: true);
    }
  });
}
