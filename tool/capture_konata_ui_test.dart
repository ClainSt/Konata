// Local visual review using the approved prototype's exported artwork.
// Not part of the application assets, and never opens the user's database.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/app_theme.dart';
import 'package:ccplayer/core/optional_features.dart';
import 'package:ccplayer/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _LocalHttp extends HttpOverrides {}

void main() {
  final fixtures = File('design/ui-preview/flutter-fixtures.json');
  testWidgets(
    'capture actual Flutter layouts with offline fixture media',
    (tester) async {
      sqfliteFfiInit();
      // This standalone development harness deliberately uses test preferences.
      // ignore: invalid_use_of_visible_for_testing_member
      SharedPreferences.setMockInitialValues({
        OptionalFeatures.preferenceKey: '{}',
      });
      await OptionalFeatures.instance.initialize();
      tester.platformDispatcher.localesTestValue = [const Locale('zh', 'CN')];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('window_manager'),
            (_) async => false,
          );
      final media = jsonDecode(fixtures.readAsStringSync()) as List;
      final oldHttp = HttpOverrides.current;
      HttpOverrides.global = _LocalHttp();
      addTearDown(() => HttpOverrides.global = oldHttp);
      // ignore: invalid_use_of_visible_for_testing_member
      FlutterSecureStorage.setMockInitialValues({});
      final server = (await tester.runAsync(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          final root = request.uri.path;
          final names = root == '/media/'
              ? media.take(8).map((m) => '${m['title']}/').toList()
              : ['01.mkv', '02.mkv', 'SPs/'];
          String entry(String href, String name, bool directory) =>
              '<d:response><d:href>$href</d:href><d:propstat><d:prop>'
              '<d:displayname>$name</d:displayname><d:resourcetype>${directory ? '<d:collection/>' : ''}</d:resourcetype>'
              '<d:getcontentlength>1610612736</d:getcontentlength></d:prop>'
              '<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>';
          request.response.statusCode = 207;
          request.response.headers.contentType = ContentType(
            'application',
            'xml',
            charset: 'utf-8',
          );
          request.response.write(
            '<?xml version="1.0" encoding="utf-8"?><d:multistatus xmlns:d="DAV:">'
            '${entry(root, 'media', true)}${names.map((name) => entry('$root${Uri.encodeComponent(name.replaceAll('/', ''))}${name.endsWith('/') ? '/' : ''}', name.replaceAll('/', ''), name.endsWith('/'))).join()}'
            '</d:multistatus>',
          );
          await request.response.close();
        });
        return server;
      }))!;
      addTearDown(() => tester.runAsync(() => server.close(force: true)));
      final font = File('C:/Windows/Fonts/msyh.ttc');
      if (font.existsSync()) {
        for (final family in ['Microsoft YaHei', 'Roboto', 'Ahem']) {
          final loader = FontLoader(family)
            ..addFont(
              Future.value(ByteData.sublistView(font.readAsBytesSync())),
            );
          await loader.load();
        }
      }
      final icons = File(
        'D:/Codex-Projects/Anime/.flutter-sdk-cache/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      );
      final iconLoader = FontLoader('MaterialIcons')
        ..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
      await iconLoader.load();
      final db = (await tester.runAsync(
        () => databaseFactoryFfi.openDatabase(inMemoryDatabasePath),
      ))!;
      await tester.runAsync(() async {
        await db.execute(
          'CREATE TABLE works (id TEXT PRIMARY KEY, title TEXT, year INTEGER, poster TEXT)',
        );
        await db.execute(
          'CREATE TABLE sources (id TEXT PRIMARY KEY, label TEXT, kind TEXT, location TEXT)',
        );
        await db.execute(
          'CREATE TABLE scan_roots (source_id TEXT, relative_path TEXT, mode TEXT)',
        );
        await db.execute(
          'CREATE TABLE assets (id TEXT PRIMARY KEY, work_id TEXT, source_id TEXT, name TEXT, relative_path TEXT, episode INTEGER, category TEXT, season INTEGER)',
        );
        await db.execute(
          'CREATE TABLE work_details (work_id TEXT PRIMARY KEY, identity TEXT, payload TEXT, fetched_at TEXT)',
        );
        await db.execute(
          'CREATE TABLE progress (asset_id TEXT PRIMARY KEY, position_ms INTEGER, duration_ms INTEGER, completed INTEGER, updated_at TEXT)',
        );
      });
      final cat = Catalog.instance..db = db;
      cat.sources = [
        {
          'id': 'webdav',
          'kind': 'webdav',
          'label': 'WebDAV 收藏',
          'location': 'http://127.0.0.1:${server.port}/media/',
        },
      ];
      cat.works = [];
      cat.assets = [];
      await tester.runAsync(() async {
        await db.insert('sources', {
          'id': 'webdav',
          'label': 'WebDAV 收藏',
          'kind': 'webdav',
          'location': 'http://127.0.0.1:${server.port}/media/',
        });
        for (var i = 0; i < media.length; i++) {
          final m = media[i] as Map;
          final work = <String, Object?>{
            'id': 'work-$i',
            'title': m['title'],
            'year': m['year'],
            'poster': m['poster'],
          };
          cat.works.add(work);
          await db.insert('works', work);
          final eps = <String, dynamic>{};
          for (final e in m['episodes'] as List) {
            final n = int.parse('${e['number']}');
            final asset = <String, Object?>{
              'id': '$i-$n',
              'work_id': 'work-$i',
              'source_id': 'webdav',
              'name': '$n.mkv',
              'relative_path': '$i/$n.mkv',
              'episode': n,
              'season': 1,
              'category': 'main',
            };
            cat.assets.add(asset);
            await db.insert('assets', asset);
            eps['$n'] = {'name': e['name'], 'still': e['still']};
            if (i == 0 && n <= 3) {
              await db.insert('progress', {
                'asset_id': '$i-$n',
                'position_ms': n == 3 ? 872000 : 1400000,
                'duration_ms': 1400000,
                'completed': n == 3 ? 0 : 1,
                'updated_at': '2026-11-08T00:00:00Z',
              });
            }
          }
          await db.insert('work_details', {
            'work_id': 'work-$i',
            'identity': Catalog.detailIdentity(work),
            'fetched_at': DateTime.now().toUtc().toIso8601String(),
            'payload': jsonEncode({
              'schemaVersion': 6,
              'episodes': eps,
              'tags': m['tags'],
              'score': m['score'],
              'overview': m['overview'],
              'backdrop': m['backdrop'],
            }),
          });
        }
      });
      final capture = GlobalKey();
      Future<void> settle() async {
        for (var i = 0; i < 4; i++) {
          await tester.runAsync(() async {
            await tester.pump(const Duration(milliseconds: 200));
            await Future<void>.delayed(const Duration(milliseconds: 120));
          });
        }
        await tester.pumpAndSettle();
      }

      Future<void> screenshot(String name) async {
        await settle();
        final images = tester.widgetList<Image>(find.byType(Image)).toList();
        await tester.runAsync(() async {
          for (final image in images) {
            await precacheImage(image.image, capture.currentContext!);
          }
        });
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final boundary =
              capture.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            'design/ui-preview/screenshots/flutter-$name.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        expect(tester.takeException(), isNull, reason: name);
      }

      for (final dark in [false, true]) {
        await AppTheme.instance.setMode(
          dark ? ThemeMode.dark : ThemeMode.light,
        );
        for (final (device, size, mobile) in [
          ('windows', const Size(1440, 900), false),
          ('tablet-landscape', const Size(1024, 768), true),
          ('tablet-portrait', const Size(768, 1024), true),
          ('phone', const Size(390, 844), true),
        ]) {
          await tester.pumpWidget(const SizedBox());
          await tester.binding.setSurfaceSize(size);
          libraryDestination.value = false;
          await tester.pumpWidget(
            RepaintBoundary(
              key: capture,
              child: CCPlayer(mobile: mobile),
            ),
          );
          await screenshot('$device-${dark ? 'dark' : 'light'}-library');
          await tester.tap(find.byKey(const ValueKey('library-source-filter')));
          await screenshot('$device-${dark ? 'dark' : 'light'}-filter');
          await tester.tap(find.byKey(const ValueKey('library-source-filter')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('library-poster-work-0')));
          await screenshot('$device-${dark ? 'dark' : 'light'}-detail');
          await tester.drag(
            find.byKey(const ValueKey('detail-content-scroll')),
            const Offset(0, -500),
          );
          await screenshot('$device-${dark ? 'dark' : 'light'}-episodes');
          await tester.tap(find.byKey(const ValueKey('nav-history')));
          await screenshot('$device-${dark ? 'dark' : 'light'}-history');
          await tester.tap(find.byKey(const ValueKey('history-manage')));
          await settle();
          await tester.tap(find.byKey(const ValueKey('history-select-all')));
          await screenshot('$device-${dark ? 'dark' : 'light'}-history-manage');
          await tester.tap(find.byKey(const ValueKey('nav-settings')));
          await screenshot('$device-${dark ? 'dark' : 'light'}-settings');
          await tester.tap(find.byKey(const ValueKey('settings-category-6')));
          await screenshot('$device-${dark ? 'dark' : 'light'}-extensions');
          await OptionalFeatures.instance.setEnabled(
            OptionalFeature.characters,
            true,
          );
          await tester.tap(find.byKey(const ValueKey('nav-settings')));
          await settle();
          await tester.tap(find.byKey(const ValueKey('settings-category-1')));
          await screenshot('$device-${dark ? 'dark' : 'light'}-scraping');
          await OptionalFeatures.instance.setEnabled(
            OptionalFeature.characters,
            false,
          );
          await tester.tap(find.byKey(const ValueKey('nav-sources')));
          await settle();
          await tester.tap(find.text('WebDAV 收藏'));
          await screenshot('$device-${dark ? 'dark' : 'light'}-source-browser');
          final choices = find.descendant(
            of: find.byKey(const ValueKey('source-folder-browser')),
            matching: find.byType(Checkbox),
          );
          for (var i = 1; i <= 3; i++) {
            await tester.tap(choices.at(i));
            await settle();
          }
          await screenshot('$device-${dark ? 'dark' : 'light'}-source-selection');
        }
      }
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(db.close);
    },
    skip: !fixtures.existsSync(),
  );
}
