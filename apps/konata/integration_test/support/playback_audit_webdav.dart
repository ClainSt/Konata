import 'dart:async';
import 'dart:io';

/// 限定合成 CD 文件的只读回环服务，真实经过 WebDAV 网关与 libmpv。
class PlaybackAuditWebDav {
  PlaybackAuditWebDav._(this._server, this._files);
  final HttpServer _server;
  final Map<String, List<int>> _files;
  final Set<String> methods = {};
  int rangeRequests = 0;

  Uri get rootUri => Uri.parse('http://127.0.0.1:${_server.port}/dav/');

  static Future<PlaybackAuditWebDav> start(String fixture) async {
    final files = <String, List<int>>{};
    for (final entry in Directory('$fixture/CD').listSync(followLinks: false)) {
      if (entry is File &&
          RegExp(
            r'^0[1-4]\.(flac|lrc)$',
          ).hasMatch(entry.uri.pathSegments.last)) {
        files['/dav/CD/${entry.uri.pathSegments.last}'] = await entry
            .readAsBytes();
      }
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixtureServer = PlaybackAuditWebDav._(server, files);
    server.listen((request) => unawaited(fixtureServer._serve(request)));
    return fixtureServer;
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    try {
      methods.add(request.method);
      final path = request.uri.path;
      if (request.method == 'PROPFIND') {
        await request.drain<void>();
        final children = switch (path) {
          '/dav/' => ['/dav/CD/'],
          '/dav/CD/' => _files.keys.toList(),
          _ => <String>[],
        };
        response.statusCode = 207;
        response.headers.contentType = ContentType(
          'application',
          'xml',
          charset: 'utf-8',
        );
        response.write(
          '<?xml version="1.0" encoding="utf-8"?><D:multistatus xmlns:D="DAV:">',
        );
        for (final child in children) {
          final directory = child.endsWith('/');
          response.write(
            '<D:response><D:href>$child</D:href><D:propstat><D:prop>'
            '<D:resourcetype>${directory ? '<D:collection/>' : ''}</D:resourcetype>'
            '<D:getcontentlength>${_files[child]?.length ?? 0}</D:getcontentlength>'
            '<D:getetag>"fixture-v1"</D:getetag>'
            '</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>',
          );
        }
        response.write('</D:multistatus>');
        await response.close();
        return;
      }
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = 405;
        await response.close();
        return;
      }
      final data = _files[path];
      if (data == null) {
        response.statusCode = 404;
        await response.close();
        return;
      }
      response.headers.set(HttpHeaders.etagHeader, '"fixture-v1"');
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      var start = 0;
      var end = data.length - 1;
      final rawRange = request.headers.value(HttpHeaders.rangeHeader);
      if (rawRange != null) {
        final range = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(rawRange);
        if (range == null) {
          response.statusCode = 416;
          await response.close();
          return;
        }
        start = int.parse(range.group(1)!);
        end = (int.tryParse(range.group(2)!) ?? end).clamp(0, end);
        if (start > end) {
          response.statusCode = 416;
          await response.close();
          return;
        }
        rangeRequests++;
        response.statusCode = 206;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${data.length}',
        );
      }
      response.contentLength = end - start + 1;
      if (request.method == 'GET') response.add(data.sublist(start, end + 1));
      await response.close();
    } on Object {
      // 播放器主动取消预取可能关闭下游连接，服务端不重试或写入文件。
      try {
        await response.close();
      } on Object {
        // 已经关闭的连接无需重复处理。
      }
    }
  }

  Future<void> close() async => _server.close(force: true);
}
