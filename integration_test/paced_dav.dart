import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';


import 'package:ccplayer/core/sources.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

/// Test-only localhost DAV facade. All media and ASS bytes are read from the
/// real DAV via scoped playback tickets. Only video payload timing is changed.
class PacedDav {
  PacedDav._(this.server, this.prefix, this.files, this.bytesPerSecond);
  final HttpServer server;
  final String prefix;
  final Map<String, Uri> files;
  final int bytesPerSecond;
  final clock = Stopwatch()..start();
  final clients = <HttpClient>{};
  int nextMicros = 0, videoBytes = 0;
  String get location => 'http://127.0.0.1:${server.port}/$prefix/';

  static Future<PacedDav> open(
    Map<String, Object?> source,
    String relative,
    int rate,
  ) async {
    final subtitles = await StreamBroker.instance.subtitles(source, relative);
    final files = <String, Uri>{};
    try {
      for (final path in [relative, ...subtitles]) {
        files[p.posix.basename(path)] = await StreamBroker.instance.issue(
          source,
          path,
          purpose: path == relative ? 'playback' : 'subtitle',
        );
      }
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final prefix = base64UrlEncode(
        List.generate(24, (_) => Random.secure().nextInt(256)),
      );
      final result = PacedDav._(server, prefix, files, rate);
      server.listen(result.serve);
      return result;
    } catch (_) {
      for (final uri in files.values) {
        StreamBroker.instance.revoke(uri);
      }
      rethrow;
    }
  }

  Future<void> serve(HttpRequest request) async {
    final resp = request.response;
    final parts = request.uri.pathSegments.where((s) => s.isNotEmpty).toList();
    HttpClient? client;
    try {
      if (parts.isEmpty || parts.first != prefix) {
        resp.statusCode = 404;
        return;
      }
      if (request.method == 'PROPFIND' && parts.length == 1) {
        final xml = XmlBuilder();
        xml.element(
          'd:multistatus',
          namespaceUris: {'d': 'DAV:'},
          nest: () {
            for (final name in files.keys) {
              xml.element(
                'd:response',
                nest: () => xml.element(
                  'd:href',
                  nest: Uri(pathSegments: ['', prefix, name]).toString(),
                ),
              );
            }
          },
        );
        resp.statusCode = 207;
        resp.headers.contentType = ContentType(
          'application',
          'xml',
          charset: 'utf-8',
        );
        resp.write(xml.buildDocument().toXmlString());
        return;
      }
      if (parts.length != 2 ||
          !files.containsKey(parts.last) ||
          !['HEAD', 'GET'].contains(request.method)) {
        resp.statusCode = 404;
        return;
      }
      final upstream = HttpClient()..autoUncompress = false;
      client = upstream;
      clients.add(upstream);
      final req = await upstream.openUrl(request.method, files[parts.last]!);
      for (final key in ['range', 'if-range']) {
        final value = request.headers.value(key);
        if (value != null) req.headers.set(key, value);
      }
      final body = await req.close();
      resp.statusCode = body.statusCode;
      for (final key in [
        'content-length',
        'content-range',
        'content-type',
        'accept-ranges',
        'etag',
        'last-modified',
      ]) {
        final value = body.headers.value(key);
        if (value != null) resp.headers.set(key, value);
      }
      if (request.method == 'GET') {
        if (parts.last.endsWith('.mkv')) {
          await resp.addStream(pace(body));
        } else {
          await resp.addStream(body);
        }
      }
    } catch (_) {
      try {
        resp.statusCode = 502;
      } catch (_) {}
    } finally {
      client?.close(force: true);
      clients.remove(client);
      try {
        await resp.close();
      } catch (_) {}
    }
  }

  Stream<List<int>> pace(Stream<List<int>> body) async* {
    await for (final chunk in body) {
      for (int offset = 0; offset < chunk.length; offset += 32768) {
        final end = min(offset + 32768, chunk.length);
        final now = clock.elapsedMicroseconds;
        nextMicros =
            max(nextMicros, now - 24000) +
            ((end - offset) * 1000000 ~/ bytesPerSecond);
        if (nextMicros > now) {
          await Future<void>.delayed(Duration(microseconds: nextMicros - now));
        }
        videoBytes += end - offset;
        yield chunk.sublist(offset, end);
      }
    }
  }

  Future<void> close() async {
    for (final cli in clients.toList()) {
      cli.close(force: true);
    }
    for (final ticket in files.values) {
      StreamBroker.instance.revoke(ticket);
    }
    await server.close(force: true);
  }
}
