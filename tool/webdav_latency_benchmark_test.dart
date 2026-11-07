import 'dart:convert';
import 'dart:io';
import 'package:ccplayer/core/webdav_stream.dart' as current;
import 'package:flutter_test/flutter_test.dart';
import '../integration_test/support/webdav_stream_baseline.dart' as baseline;

void main() {
  test('bounded real CD2 relay A/B', () async {
    final session = jsonDecode(
      await File('.dart_tool/cd2-benchmark/session.json').readAsString(),
    );
    final video = File(session['mounted_video'] as String);
    final target = Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: 29798,
      pathSegments: [
        'dav',
        '动画-单作品',
        video.parent.uri.pathSegments.where((s) => s.isNotEmpty).last,
        video.uri.pathSegments.last,
      ],
    );
    final before = baseline.WebDavStream(
      target: target,
      authorization: 'Basic YW5vbnltb3VzOg==',
    );
    final after = current.WebDavStream(
      target: target,
      authorization: 'Basic YW5vbnltb3VzOg==',
    );
    final a = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final b = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    a.listen(before.serve);
    b.listen(after.serve);
    try {
      final config = File('.dart_tool/webdav-latency/probe-config.json');
      await config.writeAsString(
        jsonEncode({
          'mounted_video': video.path,
          'direct': target.toString(),
          'before': 'http://127.0.0.1:${a.port}/ticket',
          'after': 'http://127.0.0.1:${b.port}/ticket',
          'output':
              'docs/verification/webdav-latency-${Platform.environment['BENCH_LABEL'] ?? 'baseline'}.json',
        }),
      );
      final result = await Process.run('python', [
        'tool/webdav_latency_probe.py',
        config.path,
      ]);
      // The probe's output contains measurements, never authenticated URLs.
      stdout.write(result.stdout);
      expect(result.exitCode, 0, reason: result.stderr.toString());
    } finally {
      before.close();
      after.close();
      await a.close(force: true);
      await b.close(force: true);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
