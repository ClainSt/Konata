import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ccplayer/core/metadata_servers.dart';
import 'package:ccplayer/core/metadata_http.dart';
import 'package:ccplayer/core/metadata.dart';
import 'package:ccplayer/core/connection_diagnostic.dart';
import 'package:ccplayer/core/bangumi_links.dart';
import 'package:ccplayer/core/debug_log.dart';
import 'package:ccplayer/core/image_store.dart';
import 'package:ccplayer/ui/poster_crop_page.dart';

Future<Uint8List> sampleImage({int width = 800, int height = 600}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width / 2, height.toDouble()),
    Paint()..color = Colors.red,
  );
  canvas.drawRect(
    Rect.fromLTWH(width / 2, 0, width / 2, height.toDouble()),
    Paint()..color = Colors.blue,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  picture.dispose();
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return bytes!.buffer.asUint8List();
}

Future<void> captureCrop(WidgetTester tester, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byType(RepaintBoundary).first,
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final directory = Directory('docs/verification');
    await directory.create(recursive: true);
    await File(
      '${directory.path}/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await MetadataServers.load();
    temp = await Directory.systemTemp.createTemp('ccplayer-metadata-test');
    MetadataHttp.cacheDirectory = Directory('${temp.path}/json')..createSync();
    ImageStore.root = Directory('${temp.path}/artwork');
    DebugLog.directory = null;
    DebugLog.enabled = false;
    Metadata.token = 'test-secret';
    Metadata.authMode = 'token';
  });
  tearDown(() async {
    await DebugLog.flush();
    DebugLog.directory = null;
    MetadataHttp.cacheDirectory = null;
    ImageStore.root = null;
    await temp.delete(recursive: true);
    Metadata.token = '';
  });
  test(
    'normalize version suffix, slashes, reject credentials and unsafe schemes',
    () {
      expect(
        MetadataServers.endpoint(
          2,
          '/v0/subjects/302189',
          base: 'https://example.org/v0/v0/',
        ).toString(),
        'https://example.org/v0/subjects/302189',
      );
      expect(
        MetadataServers.endpoint(
          0,
          '/tv/100565',
          base: 'https://example.org/3/3/',
        ).path,
        '/3/tv/100565',
      );
      expect(
        MetadataServers.endpoint(1, 'original/a.jpg').path,
        '/t/p/original/a.jpg',
      );
      for (final bad in [
        'ftp://host',
        'https://user:secret@host',
        'https://host?token=x',
        'https://host/#fragment',
      ]) {
        expect(() => MetadataServers.normalize(bad, 0), throwsFormatException);
      }
    },
  );
  test(
    'four addresses persist independently and restore from preferences',
    () async {
      final addresses = List.of(MetadataServers.defaults);
      addresses[2] = 'https://example.org/custom/v0/';
      await MetadataServers.save(addresses, false, false);
      MetadataServers.values = List.of(MetadataServers.official);
      await MetadataServers.load();
      expect(MetadataServers.values[0], MetadataServers.defaults[0]);
      expect(MetadataServers.values[2], 'https://example.org/custom/v0');
      expect(MetadataServers.fallback, false);
    },
  );
  test('image mapping preserves query and never maps unrelated hosts', () {
    expect(
      MetadataServers.mapImage('https://lain.bgm.tv/pic/cover/l/abc.jpg?x=2'),
      'https://lain.bangumi.lat/pic/cover/l/abc.jpg?x=2',
    );
    expect(
      MetadataServers.mapImage('https://lain.bangumi.lat/pic/a.jpg'),
      'https://lain.bangumi.lat/pic/a.jpg',
    );
    expect(
      MetadataServers.mapImage('https://example.org/a.jpg'),
      'https://example.org/a.jpg',
    );
    expect(
      ImageStore.identity('https://image.tmdb.org/t/p/w500/a.jpg'),
      ImageStore.identity('https://images.tmdb.org/t/p/w500/a.jpg'),
    );
  });
  test(
    'custom image base history survives restart without duplicate identities',
    () async {
      final addresses = List.of(MetadataServers.defaults);
      addresses[1] = 'https://first.example/art/';
      await MetadataServers.save(addresses, false, false);
      final first = MetadataServers.tmdbImage('/poster.jpg');
      addresses[1] = 'https://second.example/images/';
      await MetadataServers.save(addresses, false, false);
      await MetadataServers.load();
      expect(
        MetadataServers.mapImage(first),
        'https://second.example/images/w500/poster.jpg',
      );
      expect(
        ImageStore.identity(first),
        ImageStore.identity('https://images.tmdb.org/t/p/w500/poster.jpg'),
      );
      expect(
        MetadataServers.mapImage('artwork:crop_abc.png'),
        'artwork:crop_abc.png',
      );
    },
  );
  test(
    'transport rewrites current address, does not forward auth on redirects',
    () async {
      final calls = <Uri>[];
      final client = MetadataHttp(
        inner: MockClient((r) async {
          calls.add(r.url);
          expect(r.followRedirects, false);
          expect(r.headers['authorization'], 'Bearer test-secret');
          return http.Response('{"id":100565}', 200);
        }),
      );
      await client.get(
        Uri.parse('https://api.themoviedb.org/3/tv/100565'),
        headers: {'Authorization': 'Bearer test-secret'},
      );
      expect(calls.single.host, 'api.tmdb.org');
      client.close();
    },
  );
  test('untrusted custom TMDB never receives credentials', () async {
    MetadataServers.values[0] = 'https://untrusted.example/3';
    var sent = false;
    final client = MetadataHttp(
      inner: MockClient((r) async {
        sent = true;
        return http.Response('{}', 200);
      }),
    );
    await expectLater(
      client.get(
        Uri.parse('https://api.themoviedb.org/3/tv/1'),
        headers: {'Authorization': 'Bearer secret'},
      ),
      throwsStateError,
    );
    expect(sent, false);
    client.close();
  });
  for (final status in [401, 403, 429]) {
    test('HTTP $status never retries or returns cached success', () async {
      var count = 0;
      final client = MetadataHttp(
        inner: MockClient((r) async {
          count++;
          return http.Response('{}', status);
        }),
      );
      final response = await client.get(
        Uri.parse('https://api.bgm.tv/v0/subjects/302189'),
      );
      expect(response.statusCode, status);
      expect(count, 1);
      client.close();
    });
  }
  test(
    'metadata uses disk cache offline without fallback when disabled',
    () async {
      MetadataServers.fallback = false;
      final good = MetadataHttp(
        inner: MockClient((r) async => http.Response('{"id":302189}', 200)),
      );
      final uri = Uri.parse('https://api.bgm.tv/v0/subjects/302189');
      await good.get(uri);
      good.close();
      var count = 0;
      final offline = MetadataHttp(
        inner: MockClient((r) async {
          count++;
          throw const SocketException('offline');
        }),
      );
      expect(jsonDecode((await offline.get(uri)).body)['id'], 302189);
      expect(count, 1);
      offline.close();
    },
  );
  test(
    'diagnostics use unsaved exact address and report partial characters failure',
    () async {
      final addresses = List.of(MetadataServers.defaults);
      addresses[2] = 'https://custom.example/v0';
      final hosts = <String>[];
      final result = await ConnectionDiagnostic.test(
        2,
        addresses,
        client: MockClient((r) async {
          hosts.add(r.url.host);
          return r.url.path.endsWith('characters')
              ? http.Response('no', 503)
              : http.Response('{"id":302189,"name":"86"}', 200);
        }),
      );
      expect(result.status, DiagnosticStatus.partial);
      expect(result.issue, DiagnosticIssue.http);
      expect(result.details, contains('503'));
      expect(hosts, everyElement('custom.example'));
    },
  );
  test('diagnostics distinguish authentication failure', () async {
    final addresses = List.of(MetadataServers.defaults);
    addresses[3] = 'invalid unrelated image server';
    final result = await ConnectionDiagnostic.test(
      0,
      addresses,
      client: MockClient((r) async => http.Response('{}', 401)),
    );
    expect(result.status, DiagnosticStatus.failed);
    expect(result.issue, DiagnosticIssue.authentication);
    expect(result.details, contains('401'));
  });
  test('invalid HTML cannot pass image test', () async {
    await expectLater(
      ImageStore.download(
        'https://example.org/a',
        client: MockClient(
          (r) async => http.Response(
            '<html>error</html>',
            200,
            headers: {'content-type': 'text/html'},
          ),
        ),
      ),
      throwsFormatException,
    );
    await expectLater(
      ImageStore.download(
        'https://example.org/a',
        client: MockClient(
          (r) async =>
              http.Response('bad', 200, headers: {'content-type': 'image/png'}),
        ),
      ),
      throwsA(anything),
    );
  });
  test('merge by character ID, preserve source/actors, manual order wins', () {
    final result = BangumiLinks.mergeCharacters(
      [
        [
          {
            'id': 1,
            'name': 'same',
            'relation': '主角',
            'image': null,
            'actors': ['A'],
            'sources': [302189],
          },
          {
            'id': 2,
            'name': 'same',
            'relation': '配角',
            'actors': [],
            'sources': [302189],
          },
        ],
        [
          {
            'id': 1,
            'name': 'same',
            'relation': '主角',
            'image': 'avatar',
            'actors': ['A', 'B'],
            'sources': [331887],
          },
          {
            'id': 3,
            'name': 'new',
            'relation': '主角',
            'actors': ['C'],
            'sources': [331887],
          },
        ],
      ],
      manualOrder: [2],
    );
    expect(result.map((e) => e['id']), [2, 1, 3]);
    final main = result[1];
    expect(main['actors'], ['A', 'B']);
    expect(main['sources'], [302189, 331887]);
    expect(main['image'], 'avatar');
  });
  test(
    'logging default off, persists, redacts and survives disabled writes',
    () async {
      await DebugLog.initialize(root: temp);
      expect(DebugLog.enabled, false);
      DebugLog.write('TMDB', 'should not appear');
      await DebugLog.flush();
      expect(await DebugLog.directory!.exists(), false);
      await DebugLog.setEnabled(true);
      DebugLog.write(
        'TMDB',
        'Bearer abc api_key=secret https://user:pass@private/path?token=secret',
      );
      await DebugLog.flush();
      final file = File('${DebugLog.directory!.path}/current.log');
      final text = await file.readAsString();
      expect(text, contains('[TMDB]'));
      expect(text, contains(RegExp(r'\d{4}-\d\d-\d\dT')));
      expect(text, isNot(contains('secret')));
      expect(text, isNot(contains('private/path')));
      expect(text, isNot(contains('abc')));
      await DebugLog.initialize(root: temp);
      expect(DebugLog.enabled, true);
      await DebugLog.setEnabled(false);
      final length = await file.length();
      DebugLog.write('Image', 'stopped');
      await DebugLog.flush();
      expect(await file.length(), length);
    },
  );
  test('logging rotates and ignores directory IO failures', () async {
    await DebugLog.initialize(root: temp);
    await DebugLog.setEnabled(true);
    await DebugLog.flush();
    final file = File('${DebugLog.directory!.path}/current.log');
    await file.writeAsBytes(List.filled(DebugLog.maxBytes, 32));
    DebugLog.write('Test', 'rotate');
    await DebugLog.flush();
    expect(await file.length(), lessThan(1024));
    expect(await DebugLog.directory!.list().length, 2);
    final blocker = File('${temp.path}/blocker')..writeAsStringSync('file');
    DebugLog.directory = Directory(blocker.path);
    DebugLog.write('Test', 'no crash', level: 'ERROR');
    await DebugLog.flush();
  });
  testWidgets(
    'crop exports actual 2:3 source region and cancel leaves no output',
    (tester) async {
      final bytes = await tester.runAsync(() => sampleImage());
      Map<String, Object>? output;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => TextButton(
              onPressed: () async {
                output = await Navigator.push(
                  ctx,
                  MaterialPageRoute(
                    builder: (_) => PosterCropPage(bytes: bytes!),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      for (var i = 0; i < 100; i++) {
        await tester.pump();
        if (tester
                .widget<FilledButton>(find.widgetWithText(FilledButton, '确认保存'))
                .onPressed !=
            null) {
          break;
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      await tester.pumpAndSettle();
      expect(find.text('裁剪封面 · 2:3'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '确认保存'))
            .onPressed,
        isNotNull,
        reason: 'decoded image must enable save',
      );
      await captureCrop(tester, 'crop-desktop');
      final canvas = find.byWidgetPredicate(
        (w) =>
            w is CustomPaint &&
            w.painter.runtimeType.toString() == '_CropPainter',
      );
      await tester.dragFrom(tester.getCenter(canvas), const Offset(-100, 0));
      tester.binding.handlePointerEvent(
        PointerScrollEvent(
          position: tester.getCenter(canvas),
          scrollDelta: const Offset(0, -200),
        ),
      );
      await tester.pump();
      expect(tester.widget<Slider>(find.byType(Slider)).value, greaterThan(1));
      await tester.tap(find.text('重置'));
      await tester.pump();
      expect(tester.widget<Slider>(find.byType(Slider)).value, 1);
      await tester.tap(find.text('确认保存'));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      for (var i = 0; i < 100 && output == null; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(output, isNotNull);
      expect((output!['crop'] as Map)['rect'], [200.0, 0.0, 400.0, 600.0]);
      final codec = await tester.runAsync(
        () => ui.instantiateImageCodec(output!['bytes'] as Uint8List),
      );
      final frame = await tester.runAsync(() => codec!.getNextFrame());
      expect(frame!.image.width * 3, frame.image.height * 2);
      expect(frame.image.width, lessThanOrEqualTo(800));
      frame.image.dispose();
      codec!.dispose();
      output = null;
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(output, isNull);
    },
  );
}
