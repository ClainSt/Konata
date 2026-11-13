import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ccplayer/core/artwork_settings.dart';
import 'package:ccplayer/core/bangumi_links.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/cloud_media_asset_presentation.dart';
import 'package:ccplayer/core/cloud_media_file_classifier.dart';
import 'package:ccplayer/core/detail_metadata.dart';
import 'package:ccplayer/core/episode_metadata.dart';
import 'package:ccplayer/core/image_store.dart';
import 'package:ccplayer/core/metadata.dart';
import 'package:ccplayer/core/multi_work_splitter.dart';
import 'package:ccplayer/core/optional_features.dart';
import 'package:ccplayer/core/optional_people.dart';
import 'package:ccplayer/core/scan_activity.dart';
import 'package:ccplayer/core/scrape_pipeline.dart';
import 'package:ccplayer/core/selected_scan_workflow.dart';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/ui/library_source_filter.dart';
import 'package:ccplayer/ui/nipaplay_detail_page.dart';
import 'package:ccplayer/ui/optional_scraping_settings.dart';
import 'package:ccplayer/ui/poster_crop_page.dart';
import 'package:ccplayer/ui/scan_progress_dialog.dart';
import 'package:ccplayer/ui/work_edit_dialogs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

class _RealHttp extends HttpOverrides {}

class _LocalPeopleClient implements HttpClient {
  _LocalPeopleClient(this.port, this.urls);
  final int port;
  final List<Uri> urls;
  final HttpClient delegate = HttpOverrides.runWithHttpOverrides(
    () => HttpClient(),
    _RealHttp(),
  );

  @override
  Future<HttpClientRequest> getUrl(Uri uri) {
    urls.add(uri);
    return delegate.getUrl(
      Uri.http('127.0.0.1:$port', uri.path, uri.queryParameters),
    );
  }

  @override
  set connectionTimeout(Duration? value) => delegate.connectionTimeout = value;

  @override
  void close({bool force = false}) => delegate.close(force: force);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<File> _createTestPng(
  Directory dir,
  String name, {
  int width = 900,
  int height = 600,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFF224488),
  );
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width / 2, height / 2),
    Paint()..color = const Color(0xFFEE6644),
  );
  final picture = recorder.endRecording();
  final img = await picture.toImage(width, height);
  picture.dispose();
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(bytes!.buffer.asUint8List());
  return file;
}

Widget _localizedApp(Widget home) => MaterialApp(
  locale: const Locale('zh'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: home,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late String savedToken, savedKey, savedMode;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    savedToken = Metadata.token;
    savedKey = Metadata.apiKey;
    savedMode = Metadata.authMode;
    Metadata.token = 'test-bearer-token';
    Metadata.apiKey = '';
    Metadata.authMode = 'token';
  });
  tearDown(() {
    Metadata.token = savedToken;
    Metadata.apiKey = savedKey;
    Metadata.authMode = savedMode;
  });

  testWidgets(
    'Issue 1: ScanProgressDialog inspects pending-review works and LibrarySourceFilter filters needs_review',
    (tester) async {
      late final Directory dataDir;
      final catalog = Catalog.instance;
      const src = 'src1';
      await tester.runAsync(() async {
        dataDir = await Directory.systemTemp.createTemp('konata-r3-i1-');
        await catalog.initialize(dataDirectory: dataDir);
        await catalog.db.insert('sources', {
          'id': src,
          'kind': 'local',
          'label': '本地媒体',
          'location': dataDir.path,
        });
        await catalog.db.insert('works', {
          'id': 'work:$src:${Uri.encodeComponent('未添加TMDB ID/正常动画')}',
          'title': '正常动画',
          'poster': 'https://image.tmdb.org/t/p/w500/ok.jpg',
          'needs_review': 0,
          'hidden': 0,
        });
        await catalog.db.insert('works', {
          'id': 'work:$src:${Uri.encodeComponent('未添加TMDB ID/候选封面作品')}',
          'title': '候选封面作品',
          'poster': 'https://lain.bgm.tv/pic/cover/l/cand.jpg',
          'needs_review': 1,
          'hidden': 0,
        });
        await catalog.db.insert('works', {
          'id': 'work:$src:${Uri.encodeComponent('未添加TMDB ID/圣斗士星矢 冥王系列')}',
          'title': '圣斗士星矢 冥王系列',
          'poster': null,
          'needs_review': 1,
          'hidden': 0,
        });
        for (final (idx, wid) in [
          'work:$src:${Uri.encodeComponent('未添加TMDB ID/正常动画')}',
          'work:$src:${Uri.encodeComponent('未添加TMDB ID/候选封面作品')}',
          'work:$src:${Uri.encodeComponent('未添加TMDB ID/圣斗士星矢 冥王系列')}',
        ].indexed) {
          await catalog.db.insert('assets', {
            'id': 'asset:$wid',
            'source_id': src,
            'work_id': wid,
            'name': '01.mkv',
            'relative_path': 'dir_$idx/01.mkv',
            'category': 'main',
            'season': 1,
            'episode': 1,
          });
        }
        await catalog.reload();
      });
      addTearDown(() async {
        await tester.runAsync(() async {
          await catalog.db.close();
          await dataDir.delete(recursive: true);
        });
      });

      final onlyReview = filterLibraryWorks(
        works: catalog.works,
        assets: catalog.assets,
        sources: catalog.sources,
        kinds: librarySourceKinds,
        query: '',
        pendingReviewOnly: true,
      );
      expect(onlyReview.map((w) => w['title']).toSet(), {
        '候选封面作品',
        '圣斗士星矢 冥王系列',
      });

      final store = ScanActivityStore.instance;
      store.begin(src, ['未添加TMDB ID']);
      store.beginFolder(src, '未添加TMDB ID/圣斗士星矢 冥王系列');
      store.video(src, '未添加TMDB ID/圣斗士星矢 冥王系列');
      store.endFolder(src, '未添加TMDB ID/圣斗士星矢 冥王系列');
      store.beginScraping(src, 3);
      store.metadataDone(src, matched: true);
      store.metadataDone(src, review: true);
      store.metadataDone(src, review: true);
      store.complete(src);

      String? openedWorkId;
      await tester.binding.setSurfaceSize(const Size(1100, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _localizedApp(
          Scaffold(
            body: Builder(
              builder: (ctx) => Center(
                child: ElevatedButton(
                  onPressed: () => ScanProgressDialog.show(
                    ctx,
                    sourceId: src,
                    onOpenWork: (id) => openedWorkId = id,
                  ),
                  child: const Text('打开进度'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开进度'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('scan-progress-review-chip')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('scan-progress-tab-review')));
      await tester.pumpAndSettle();

      expect(find.text('候选封面作品'), findsOneWidget);
      expect(find.text('圣斗士星矢 冥王系列'), findsOneWidget);
      expect(find.textContaining('已生成候选封面'), findsOneWidget);
      expect(find.textContaining('未找到高置信匹配'), findsOneWidget);

      final targetWorkId =
          'work:$src:${Uri.encodeComponent('未添加TMDB ID/圣斗士星矢 冥王系列')}';
      await tester.tap(find.text('圣斗士星矢 冥王系列'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('manual-match-provider')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('scan-progress-tab-review')),
        findsOneWidget,
      );
      expect(openedWorkId, isNull);

      await tester.tap(find.text('关闭').last);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('scan-progress-tab-review')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(ValueKey('pending-review-detail-$targetWorkId')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('scan-progress-tab-review')),
        findsNothing,
      );
      expect(openedWorkId, targetWorkId);
    },
  );

  testWidgets(
    'Issue 2: Character role filter defaults to main+supporting, persists, and avoids fetching guest/other people',
    (tester) async {
      late final Directory temp;
      late final OptionalFeatures settings;
      late final HttpServer server;
      final hitPaths = <String>[];
      late final List<Map<String, Object?>> cards;
      await tester.runAsync(() async {
        temp = await Directory.systemTemp.createTemp('konata-r3-i2-');
        ImageStore.root = Directory('${temp.path}/artwork');
        settings = OptionalFeatures(legacyRoot: temp);
        await settings.initialize();

        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((r) async {
          hitPaths.add(r.uri.path);
          r.response.headers.contentType = ContentType.json;
          if (r.uri.path == '/v0/subjects/99/characters') {
            r.response.write(
              jsonEncode([
                {
                  'id': 1,
                  'name': 'Hero',
                  'relation': '主角',
                  'actors': [
                    {'id': 101, 'name': 'HeroVA'},
                  ],
                },
                {
                  'id': 2,
                  'name': 'Sidekick',
                  'relation': '配角',
                  'actors': [
                    {'id': 102, 'name': 'SideVA'},
                  ],
                },
                {
                  'id': 3,
                  'name': 'Cameo',
                  'relation': '客串',
                  'actors': [
                    {'id': 103, 'name': 'CameoVA'},
                  ],
                },
                {
                  'id': 4,
                  'name': 'Mob',
                  'relation': '闲角',
                  'actors': [
                    {'id': 104, 'name': 'MobVA'},
                  ],
                },
              ]),
            );
          } else {
            r.response.write(jsonEncode({'infobox': []}));
          }
          await r.response.close();
        });

        final session = OptionalPeopleSession(
          settings,
          OptionalFeature.characters,
          clientFactory: () => _LocalPeopleClient(server.port, []),
        );
        cards = await session.load({'bangumi_id': 99}, 'zh');
        session.dispose();
      });
      addTearDown(() async {
        await tester.runAsync(() async {
          await server.close(force: true);
          settings.dispose();
          await ImageStore.close();
          ImageStore.root = null;
          await temp.delete(recursive: true);
        });
      });

      expect(settings.characterRoles, {'main', 'supporting'});
      expect(cards.map((c) => c['title']).toList(), ['Hero', 'Sidekick']);
      expect(hitPaths, isNot(contains('/v0/characters/3')));
      expect(hitPaths, isNot(contains('/v0/persons/103')));
      expect(hitPaths, isNot(contains('/v0/characters/4')));
      expect(hitPaths, isNot(contains('/v0/persons/104')));

      // Verify UI multi-select under scraping settings + persistence across restart.
      await tester.pumpWidget(
        _localizedApp(
          Scaffold(body: OptionalScrapingSettings(settings: settings)),
        ),
      );
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('scraping-character-roles-filter')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('scraping-character-roles-filter')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('character-role-guest')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
      expect(settings.characterRoles, {'main', 'supporting', 'guest'});

      late final OptionalFeatures restored;
      await tester.runAsync(() async {
        restored = OptionalFeatures(legacyRoot: temp);
        await restored.initialize();
      });
      addTearDown(restored.dispose);
      expect(restored.characterRoles, {'main', 'supporting', 'guest'});
    },
  );

  testWidgets(
    'Issue 3 & 3b: Compact cover dialog, space-aware backdrop menu with portrait/landscape icons, and resizable crop box',
    (tester) async {
      late final Directory dbDir;
      await tester.runAsync(() async {
        dbDir = await Directory.systemTemp.createTemp('konata-r3-i3-db-');
        await Catalog.instance.initialize(dataDirectory: dbDir);
        await ArtworkSettings.instance.load();
        await ArtworkSettings.instance.setBackdrop(true);
      });
      addTearDown(() async {
        await tester.runAsync(() async {
          await Catalog.instance.db.close();
          await dbDir.delete(recursive: true);
        });
      });

      final work = <String, Object?>{
        'id': 'work:s:demo',
        'title': '测试作品',
        'poster': 'https://images.tmdb.org/t/p/w500/p.jpg',
        'poster_fallback': 'https://lain.bgm.tv/pic/cover/l/b.jpg',
      };

      // 3a. Narrow phone layout (390x844): hides 编辑背景图, shows 编辑封面 with portrait icon.
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _localizedApp(
          NipaPlayDetailPage(
            work: work,
            assets: const [],
            onEditMetadata: () {},
            onEditCover: () {},
            onEditBackdrop: (_) async {},
            onDelete: () {},
            onBack: () {},
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byKey(const ValueKey('detail-more-button')));
      await tester.pumpAndSettle();
      expect(find.text('编辑封面'), findsOneWidget);
      expect(find.byIcon(Icons.crop_portrait_outlined), findsOneWidget);
      expect(find.text('编辑背景图'), findsNothing);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      // 3b. Wide tablet/desktop layout (1100x760): shows both 编辑封面 and 编辑背景图.
      await tester.binding.setSurfaceSize(const Size(1100, 760));
      await tester.pumpWidget(
        _localizedApp(
          NipaPlayDetailPage(
            work: work,
            assets: const [],
            onEditMetadata: () {},
            onEditCover: () {},
            onEditBackdrop: (_) async {},
            onDelete: () {},
            onBack: () {},
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byKey(const ValueKey('detail-more-button')));
      await tester.pumpAndSettle();
      expect(find.text('编辑封面'), findsOneWidget);
      expect(find.text('编辑背景图'), findsOneWidget);
      expect(find.byIcon(Icons.crop_portrait_outlined), findsOneWidget);
      expect(find.byIcon(Icons.crop_landscape_outlined), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      // 3c. Cover dialog with 2 options adapts width to 360 instead of leaving empty right space.
      await tester.pumpWidget(
        _localizedApp(
          Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => WorkEditDialogs.cover(ctx, work),
                child: const Text('打开封面弹窗'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开封面弹窗'));
      await tester.pumpAndSettle();
      final coverBox = tester.widget<SizedBox>(
        find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.byWidgetPredicate(
                (w) => w is SizedBox && w.width == 360,
              ),
            )
            .first,
      );
      expect(coverBox.width, 360);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      // 3d. PosterCropPage interactive corner/edge resize shrinks crop rect cleanly.
      late final Directory imgDir;
      late final Uint8List imgBytes;
      await tester.runAsync(() async {
        imgDir = await Directory.systemTemp.createTemp('konata-r3-crop-');
        final imgFile = await _createTestPng(
          imgDir,
          'wide.png',
          width: 900,
          height: 600,
        );
        imgBytes = await imgFile.readAsBytes();
      });
      addTearDown(() async {
        await tester.runAsync(() async {
          await imgDir.delete(recursive: true);
        });
      });

      Map<String, Object>? cropResult;
      await tester.pumpWidget(
        _localizedApp(
          Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () async {
                  cropResult = await Navigator.push<Map<String, Object>>(
                    ctx,
                    MaterialPageRoute(
                      builder: (_) => PosterCropPage(bytes: imgBytes),
                    ),
                  );
                },
                child: const Text('裁剪测试'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('裁剪测试'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      // Wait for async ui.instantiateImageCodec in test binding.
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump();
      }

      // Use slider or corner drag to resize crop frame smaller than max height (600).
      final slider = find.byType(Slider);
      expect(slider, findsOneWidget);
      final sliderWidget = tester.widget<Slider>(slider);
      expect(sliderWidget.value, 1.0);

      // Drag right edge handle inward from right border of centered 2:3 crop box.
      final paintFinder = find.byKey(const ValueKey('poster-crop-canvas'));
      final paintRect = tester.getRect(paintFinder);
      // Viewport fits 900x600 centered (40px margin); initial 2:3 crop width is 400/900 of image width.
      final scale = (paintRect.width - 40) / 900 < (paintRect.height - 40) / 600
          ? (paintRect.width - 40) / 900
          : (paintRect.height - 40) / 600;
      final rightEdgeX = paintRect.center.dx + (400 * scale) / 2;
      await tester.dragFrom(
        Offset(rightEdgeX, paintRect.center.dy),
        const Offset(-80, 0),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('确认保存'));
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();

      expect(cropResult, isNotNull);
      final cropMeta = cropResult!['crop'] as Map<String, Object?>;
      final rect = (cropMeta['rect'] as List).cast<num>();
      // Initial max 2:3 box on 900x600 is 400x600; after dragging inward, width < 360!
      expect(rect[2], lessThan(360));
      expect(rect[2] / rect[3], closeTo(2 / 3, 0.02));
    },
  );

  test(
    'Issue 4: Maken-ki S1 & S2 keep Bangumi titles/covers, x.264 is stripped, Selling CM -> CM, and OVAs/OAD align',
    () async {
      // 4a. x.264 codec tag never becomes episode 264.
      final epNum = CloudMediaFileClassifier.episodeNumberFromName(
        '[Moozzi2] Maken-ki! - 01 (BD 1920x1080 x.264 Flac).mkv',
      );
      expect(epNum, 1);

      // 4b. Selling CM overrides OAD/SP -> CM, and [SP07] OVA - 01 extracts 1.
      expect(
        CloudMediaAssetPresentation.extraType({
          'name':
              '[Moozzi2] Maken-ki! - SP06 [Comic Vol.08 OAD DVD Selling CM].mkv',
          'relative_path':
              'SPs/[Moozzi2] Maken-ki! - SP06 [Comic Vol.08 OAD DVD Selling CM].mkv',
        }),
        'CM',
      );
      expect(
        CloudMediaAssetPresentation.explicitSpecialNumber({
          'name': '[Moozzi2] Maken-ki! - SP07 [OVA - 01].mkv',
          'relative_path': 'SPs/[Moozzi2] Maken-ki! - SP07 [OVA - 01].mkv',
        }),
        1,
      );

      // 4c. End-to-end ScrapePipeline preserves 魔具少女！ & 魔具少女！通 distinct titles and covers.
      final root = await Directory.systemTemp.createTemp('konata-r3-i4-media-');
      final dataDir = await Directory.systemTemp.createTemp('konata-r3-i4-db-');
      final catalog = Catalog.instance;
      await catalog.initialize(dataDirectory: dataDir);
      addTearDown(() async {
        await catalog.db.close();
        await root.delete(recursive: true);
        await dataDir.delete(recursive: true);
      });

      final s1Dir = await Directory('${root.path}/魔具少女 (2011)').create();
      for (var ep = 1; ep <= 12; ep++) {
        final n = ep.toString().padLeft(2, '0');
        await File(
          '${s1Dir.path}/[Moozzi2] Maken-ki! - $n (BD 1920x1080 x.264 Flac).mkv',
        ).writeAsBytes([ep]);
      }
      final s2Dir = await Directory('${root.path}/魔具少女 通 (2014)').create();
      for (var ep = 1; ep <= 10; ep++) {
        final n = ep.toString().padLeft(2, '0');
        await File(
          '${s2Dir.path}/[Moozzi2] Maken-ki! Tsuu - $n (BD 1920x1080 x.264 Flac).mkv',
        ).writeAsBytes([ep]);
      }

      final client = MockClient((req) async {
        final path = req.url.path;
        if (path == '/v0/search/subjects') {
          final body = jsonDecode(req.body) as Map;
          final kw = body['keyword'].toString();
          if (kw.contains('通') || kw.contains('Tsuu')) {
            return _json({
              'data': [
                {
                  'id': 72946,
                  'name': 'マケン姫っ! 通',
                  'name_cn': '魔具少女！通',
                  'date': '2014-01-15',
                  'eps': 10,
                },
              ],
            });
          }
          return _json({
            'data': [
              {
                'id': 21580,
                'name': 'マケン姫っ!',
                'name_cn': '魔具少女！',
                'date': '2011-10-04',
                'eps': 12,
              },
            ],
          });
        }
        if (path == '/v0/subjects/21580') {
          return _json({
            'id': 21580,
            'name': 'マケン姫っ!',
            'name_cn': '魔具少女！',
            'date': '2011-10-04',
            'total_episodes': 12,
            'summary': '第一季简介',
            'images': {'large': 'https://lain.bgm.tv/pic/cover/l/s1_21580.jpg'},
          });
        }
        if (path == '/v0/subjects/72946') {
          return _json({
            'id': 72946,
            'name': 'マケン姫っ! 通',
            'name_cn': '魔具少女！通',
            'date': '2014-01-15',
            'total_episodes': 10,
            'summary': '第二季简介',
            'images': {'large': 'https://lain.bgm.tv/pic/cover/l/s2_72946.jpg'},
          });
        }
        if (path == '/3/search/tv') {
          return _json({
            'results': [
              {
                'id': 44693,
                'name': '魔剑姬！',
                'original_name': 'マケン姫っ!',
                'first_air_date': '2011-10-05',
              },
            ],
          });
        }
        if (path == '/3/tv/44693') {
          return _json({
            'id': 44693,
            'name': '魔剑姬！',
            'original_name': 'マケン姫っ!',
            'first_air_date': '2011-10-05',
            'poster_path': '/maken_series_same.jpg',
            'seasons': [
              {
                'season_number': 0,
                'episode_count': 13,
                'air_date': '2011-12-21',
              },
              {
                'season_number': 1,
                'episode_count': 12,
                'air_date': '2011-10-05',
              },
              {
                'season_number': 2,
                'episode_count': 10,
                'air_date': '2014-01-15',
              },
            ],
          });
        }
        if (path == '/3/tv/44693/season/1' || path == '/3/tv/44693/season/2') {
          return _json({'poster_path': '/maken_series_same.jpg'});
        }
        return _json({}, 404);
      });

      final pipeline = ScrapePipeline(catalog: catalog, client: client);
      addTearDown(() {
        pipeline.close();
        client.close();
      });

      final sourceId = await catalog.addSource('local', '魔具测试', root.path);
      await catalog.addScanRoot(sourceId, '');
      await SelectedScanWorkflow.run(
        catalog.sourceOf(sourceId),
        pipeline: pipeline,
      );

      final titles = {for (final w in catalog.works) w['title']: w};
      expect(titles.keys, containsAll(['魔具少女！', '魔具少女！通']));
      expect(
        titles['魔具少女！']!['poster'],
        'https://lain.bgm.tv/pic/cover/l/s1_21580.jpg',
      );
      expect(
        titles['魔具少女！通']!['poster'],
        'https://lain.bgm.tv/pic/cover/l/s2_72946.jpg',
      );
      expect(titles['魔具少女！']!['needs_review'], 0);
      expect(titles['魔具少女！通']!['needs_review'], 0);
    },
  );

  test(
    'Issue 5: Milky Holmes Alternative binds sibling Bangumi subjects [42402, 49093], keeps Bangumi cover, and aligns Season 0 stills',
    () async {
      final root = await Directory.systemTemp.createTemp('konata-r3-i5-media-');
      final dataDir = await Directory.systemTemp.createTemp('konata-r3-i5-db-');
      final catalog = Catalog.instance;
      await catalog.initialize(dataDirectory: dataDir);
      addTearDown(() async {
        await catalog.db.close();
        await root.delete(recursive: true);
        await dataDir.delete(recursive: true);
      });

      final altDir = await Directory(
        '${root.path}/侦探歌剧 少女福尔摩斯 Alternative',
      ).create();
      await File(
        '${altDir.path}/[Group] Milky Holmes Alternative [01][1080p].mkv',
      ).writeAsBytes([1, 2, 3]);
      await File(
        '${altDir.path}/[Group] Milky Holmes Alternative [02][1080p].mkv',
      ).writeAsBytes([4, 5, 6]);

      final client = MockClient((req) async {
        final path = req.url.path;
        if (path == '/v0/search/subjects') {
          return _json({
            'data': [
              {
                'id': 8560,
                'name': '探偵オペラ ミルキィホームズ',
                'name_cn': '侦探歌剧 少女福尔摩斯',
                'date': '2010-10-07',
                'eps': 12,
              },
              {
                'id': 42402,
                'name': '探偵オペラ ミルキィホームズ Alternative ONE ～小林オペラと5枚の絵画～',
                'name_cn': '侦探歌剧 少女福尔摩斯 Alternative ONE ～小林歌剧与5幅绘画～',
                'date': '2012-08-25',
                'eps': 1,
              },
              {
                'id': 49093,
                'name': '探偵オペラ ミルキィホームズ Alternative TWO ～小林オペラと虚空の大鴉～',
                'name_cn': '侦探歌剧 少女福尔摩斯 Alternative TWO ～小林歌剧与虚空的大鸦～',
                'date': '2012-12-31',
                'eps': 1,
              },
            ],
          });
        }
        if (path == '/v0/subjects/42402') {
          return _json({
            'id': 42402,
            'name': '探偵オペラ ミルキィホームズ Alternative ONE ～小林オペラと5枚の絵画～',
            'name_cn': '侦探歌剧 少女福尔摩斯 Alternative ONE ～小林歌剧与5幅绘画～',
            'date': '2012-08-25',
            'total_episodes': 1,
            'summary': 'Alternative ONE 简介',
            'images': {'large': 'https://lain.bgm.tv/pic/cover/l/alt_one.jpg'},
          });
        }
        if (path == '/v0/subjects/49093') {
          return _json({
            'id': 49093,
            'name': '探偵オペラ ミルキィホームズ Alternative TWO ～小林オペラと虚空の大鴉～',
            'name_cn': '侦探歌剧 少女福尔摩斯 Alternative TWO ～小林歌剧与虚空的大鸦～',
            'date': '2012-12-31',
            'total_episodes': 1,
            'summary': 'Alternative TWO 简介',
            'images': {'large': 'https://lain.bgm.tv/pic/cover/l/alt_two.jpg'},
          });
        }
        if (path == '/v0/episodes') {
          final sid = req.url.queryParameters['subject_id'];
          if (sid == '42402') {
            return _json({
              'data': [
                {
                  'type': 0,
                  'ep': 1,
                  'sort': 1,
                  'name': '小林オペラと5枚の絵画',
                  'name_cn': '小林歌剧与5幅绘画',
                  'airdate': '2012-08-25',
                },
              ],
            });
          }
          if (sid == '49093') {
            return _json({
              'data': [
                {
                  'type': 0,
                  'ep': 1,
                  'sort': 1,
                  'name': '小林オペラと虚空の大鴉',
                  'name_cn': '小林歌剧与虚空的大鸦',
                  'airdate': '2012-12-31',
                },
              ],
            });
          }
        }
        if (path == '/3/search/tv') {
          final q = (req.url.queryParameters['query'] ?? '').toLowerCase();
          // Real TMDB returns [] when the episode subtitle "Alternative" is in the TV query!
          if (q.contains('alternative')) {
            return _json({'results': []});
          }
          return _json({
            'results': [
              {
                'id': 37618,
                'name': '侦探歌剧 少女福尔摩斯',
                'original_name': '探偵オペラ ミルキィホームズ',
                'first_air_date': '2010-10-07',
              },
            ],
          });
        }
        if (path == '/3/tv/37618') {
          return _json({
            'id': 37618,
            'name': '侦探歌剧 少女福尔摩斯',
            'original_name': '探偵オペラ ミルキィホームズ',
            'first_air_date': '2010-10-07',
            'poster_path': '/milky_parent_tv.jpg',
            'seasons': [
              {
                'season_number': 0,
                'episode_count': 5,
                'air_date': '2011-08-26',
              },
              {
                'season_number': 1,
                'episode_count': 12,
                'air_date': '2010-10-07',
              },
            ],
          });
        }
        if (path == '/3/tv/37618/season/0') {
          return _json({
            'season_number': 0,
            'poster_path': '/milky_parent_tv.jpg',
            'episodes': [
              {
                'episode_number': 1,
                'name': '夏日特辑',
                'air_date': '2011-08-26',
                'still_path': '/s0e1_summer.jpg',
              },
              {
                'episode_number': 2,
                'name': 'Alternative ONE 小林歌剧与5幅绘画',
                'air_date': '2012-08-25',
                'overview': '五幅画失窃案',
                'still_path': '/s0e2_alt1.jpg',
              },
              {
                'episode_number': 3,
                'name': 'Alternative TWO 小林歌剧与虚空的大鸦',
                'air_date': '2012-12-31',
                'overview': '虚空大鸦怪盗案',
                'still_path': '/s0e3_alt2.jpg',
              },
            ],
          });
        }
        return _json({}, 404);
      });

      final pipeline = ScrapePipeline(catalog: catalog, client: client);
      addTearDown(() {
        pipeline.close();
        client.close();
      });

      final sourceId = await catalog.addSource('local', '少女福尔摩斯', root.path);
      await catalog.addScanRoot(sourceId, '');
      await SelectedScanWorkflow.run(
        catalog.sourceOf(sourceId),
        pipeline: pipeline,
      );

      final work = catalog.works.single;
      expect(work['title'], '侦探歌剧 少女福尔摩斯 Alternative');
      expect(work['needs_review'], 0);
      expect(work['tmdb_id'], 37618);
      expect(work['poster'], 'https://lain.bgm.tv/pic/cover/l/alt_one.jpg');
      expect(BangumiLinks.ids(work), [42402, 49093]);

      final assets = catalog.forWork(work['id'].toString());
      expect(assets.every((a) => a['season'] == 0), isTrue);

      final detailService = DetailMetadataService(client: client);
      addTearDown(detailService.close);
      final details = await detailService.fetch(work, assets: assets);
      expect(
        details['poster'],
        'https://lain.bgm.tv/pic/cover/l/alt_one.jpg',
        reason: 'Parent TV poster must never overwrite Season 0 sub-work cover',
      );
      final sortedAssets = [...assets]
        ..sort((a, b) => (a['episode'] as int).compareTo(b['episode'] as int));
      final ep1Meta = EpisodeMetadata.lookup(work, details, sortedAssets[0]);
      final ep2Meta = EpisodeMetadata.lookup(work, details, sortedAssets[1]);
      expect(ep1Meta['still'], contains('/s0e2_alt1.jpg'));
      expect(ep2Meta['still'], contains('/s0e3_alt2.jpg'));
      expect(ep1Meta['name'], contains('5幅绘画'));
      expect(ep2Meta['name'], contains('虚空的大鸦'));
    },
  );

  test(
    'Issue 6: MultiWorkSplitter splits Slayers/Haikara-san/Aquarion and ScrapePipeline defers multi-work folders until last',
    () async {
      // 6a. Slayers Movie & OVA -> 5 movies + 2 OVAs (3 eps each) = 7 clusters!
      final slayersAssets = <Map<String, Object?>>[
        for (final (i, name) in [
          '[Kamigami] Slayers Movie 1995「Kanzen Muketsu」[BD x264].mkv',
          '[Kamigami] Slayers Movie 1996「RETURN」[BD x264].mkv',
          '[Kamigami] Slayers Movie 1997「GREAT」[BD x264].mkv',
          '[Kamigami] Slayers Movie 1998「GORGEOUS」[BD x264].mkv',
          '[Kamigami] Slayers Movie 2001「PREMIUM」[BD x264].mkv',
          '[Kamigami] Slayers OVA 1996「SPECIAL」01 [BD x264].mkv',
          '[Kamigami] Slayers OVA 1996「SPECIAL」02 [BD x264].mkv',
          '[Kamigami] Slayers OVA 1996「SPECIAL」03 [BD x264].mkv',
          '[Kamigami] Slayers OVA 1998「EXCELLENT」01 [BD x264].mkv',
          '[Kamigami] Slayers OVA 1998「EXCELLENT」02 [BD x264].mkv',
          '[Kamigami] Slayers OVA 1998「EXCELLENT」03 [BD x264].mkv',
          'SP/[Kamigami] Slayers Movie 1996「RETURN」Trailer.mkv',
        ].indexed)
          {
            'id': 'sl-$i',
            'name': name.split('/').last,
            'relative_path': name,
            'size': name.startsWith('SP/')
                ? 20 * 1024 * 1024
                : 900 * 1024 * 1024,
          },
      ];
      final slayersClusters = MultiWorkSplitter.split(
        '未添加TMDB ID/秀逗魔导士系列/秀逗魔导士 Movie & OVA',
        slayersAssets,
      );
      expect(slayersClusters, hasLength(7));
      final returnCluster = slayersClusters.singleWhere(
        (c) => c.inventory.year == 1996 && c.inventory.movieMarker,
      );
      expect(
        returnCluster.assignments.any(
          (a) => a.category == 'extra' && a.relativePath.contains('RETURN'),
        ),
        isTrue,
      );

      // 6b. 剧场版 窈窕淑女 -> Zenpen (2017) & Kouhen (2018) with SPs routed to their own part!
      final haikaraAssets = <Map<String, Object?>>[
        {
          'id': 'hk-1',
          'name':
              '[Nekomoe kissaten][Haikara-san ga Tooru Movie 1 - Benio, Hana no 17-sai][BDRip].mkv',
          'relative_path':
              '[Nekomoe kissaten][Haikara-san ga Tooru Movie 1 - Benio, Hana no 17-sai][BDRip].mkv',
          'size': 2000 * 1024 * 1024,
        },
        {
          'id': 'hk-2',
          'name':
              '[Nekomoe kissaten][Haikara-san ga Tooru Movie 2 - Tokyo Dai Roman][BDRip].mkv',
          'relative_path':
              '[Nekomoe kissaten][Haikara-san ga Tooru Movie 2 - Tokyo Dai Roman][BDRip].mkv',
          'size': 2100 * 1024 * 1024,
        },
        {
          'id': 'hk-sp1',
          'name': 'zenpen_pv01.mkv',
          'relative_path': 'SPs/zenpen_pv01.mkv',
          'size': 30 * 1024 * 1024,
        },
        {
          'id': 'hk-sp2',
          'name': 'kouhen_cm01.mkv',
          'relative_path': 'SPs/kouhen_cm01.mkv',
          'size': 25 * 1024 * 1024,
        },
      ];
      final haikaraClusters = MultiWorkSplitter.split(
        '剧场版 窈窕淑女',
        haikaraAssets,
      );
      expect(haikaraClusters, hasLength(2));
      expect(haikaraClusters[0].assignments.map((a) => a.assetId).toSet(), {
        'hk-1',
        'hk-sp1',
      });
      expect(haikaraClusters[1].assignments.map((a) => a.assetId).toSet(), {
        'hk-2',
        'hk-sp2',
      });

      // 6c. End-to-end deferred Phase 2 execution order + Catalog virtual split:
      final root = await Directory.systemTemp.createTemp('konata-r3-i6-media-');
      final dataDir = await Directory.systemTemp.createTemp('konata-r3-i6-db-');
      final catalog = Catalog.instance;
      await catalog.initialize(dataDirectory: dataDir);
      addTearDown(() async {
        await catalog.db.close();
        await root.delete(recursive: true);
        await dataDir.delete(recursive: true);
      });

      // Collection folder (alphabetically before 机动战士高达NT: U+521B < U+673A,
      // yet MUST scrape AFTER single work!).
      final multiDir = await Directory(
        '${root.path}/创星的大天使 & 创势的大天使EVOL',
      ).create();
      await File(
        '${multiDir.path}/[Group] Aquarion - Genesis of Aquarion [OVA][BDRip].mkv',
      ).writeAsBytes([1, 2, 3, 4]);
      await File(
        '${multiDir.path}/[Group] Aquarion - Genesis of Aquarion Evol [OVA][BDRip].mkv',
      ).writeAsBytes([5, 6, 7, 8]);

      final singleDir = await Directory('${root.path}/机动战士高达NT').create();
      await File(
        '${singleDir.path}/[VCB-Studio] Mobile Suit Gundam Narrative [1080p].mkv',
      ).writeAsBytes([9, 10, 11, 12]);

      final searchOrder = <String>[];
      final client = MockClient((req) async {
        final path = req.url.path;
        if (path == '/v0/search/subjects') {
          final kw = (jsonDecode(req.body) as Map)['keyword'].toString();
          searchOrder.add(kw);
          if (kw.contains('高达NT') || kw.contains('Narrative')) {
            return _json({
              'data': [
                {
                  'id': 243429,
                  'name': '機動戦士ガンダムNT',
                  'name_cn': '机动战士高达NT',
                  'date': '2018-11-30',
                  'eps': 1,
                },
              ],
            });
          }
          if (kw.contains('EVOL') || kw.contains('Evol')) {
            return _json({
              'data': [
                {
                  'id': 126797,
                  'name': '創勢のアクエリオンEVOL',
                  'name_cn': '创势的大天使EVOL',
                  'date': '2015-06-28',
                  'eps': 1,
                },
              ],
            });
          }
          if (kw.contains('创星的大天使') || kw.contains('Genesis')) {
            return _json({
              'data': [
                {
                  'id': 10291,
                  'name': '創星のアクエリオン ―裏切りの翼―',
                  'name_cn': '创星的大天使 背叛的翅膀',
                  'date': '2007-05-25',
                  'eps': 2,
                },
              ],
            });
          }
        }
        if (path == '/v0/subjects/243429') {
          return _json({
            'id': 243429,
            'name': '機動戦士ガンダムNT',
            'name_cn': '机动战士高达NT',
            'date': '2018-11-30',
            'images': {'large': 'https://lain.bgm.tv/pic/cover/l/nt.jpg'},
          });
        }
        if (path == '/v0/subjects/10291') {
          return _json({
            'id': 10291,
            'name': '創星のアクエリオン ―裏切りの翼―',
            'name_cn': '创星的大天使 背叛的翅膀',
            'date': '2007-05-25',
            'images': {'large': 'https://lain.bgm.tv/pic/cover/l/aq1.jpg'},
          });
        }
        if (path == '/v0/subjects/126797') {
          return _json({
            'id': 126797,
            'name': '創勢のアクエリオンEVOL',
            'name_cn': '创势的大天使EVOL',
            'date': '2015-06-28',
            'images': {'large': 'https://lain.bgm.tv/pic/cover/l/aq2.jpg'},
          });
        }
        if (path == '/3/search/movie') {
          final q = req.url.queryParameters['query'] ?? '';
          if (q.contains('高达NT') || q.contains('ガンダムNT')) {
            return _json({
              'results': [
                {
                  'id': 532945,
                  'title': '机动战士高达NT',
                  'original_title': '機動戦士ガンダムNT',
                  'release_date': '2018-11-30',
                },
              ],
            });
          }
        }
        if (path == '/3/movie/532945') {
          return _json({
            'id': 532945,
            'title': '机动战士高达NT',
            'original_title': '機動戦士ガンダムNT',
            'release_date': '2018-11-30',
            'poster_path': '/nt.jpg',
          });
        }
        return _json({'results': []}, 200);
      });

      final pipeline = ScrapePipeline(
        catalog: catalog,
        client: client,
        concurrency: 2,
      );
      addTearDown(() {
        pipeline.close();
        client.close();
      });

      final sourceId = await catalog.addSource('local', '合集后置测试', root.path);
      await catalog.addScanRoot(sourceId, '');
      await SelectedScanWorkflow.run(
        catalog.sourceOf(sourceId),
        pipeline: pipeline,
      );

      // Single-work folder MUST be queried BEFORE deferred multi-work clusters!
      final firstNtIdx = searchOrder.indexWhere(
        (q) => q.contains('高达NT') || q.contains('Narrative'),
      );
      final firstAquarionIdx = searchOrder.indexWhere(
        (q) => q.contains('大天使') || q.contains('Aquarion'),
      );
      expect(firstNtIdx, greaterThanOrEqualTo(0));
      expect(firstAquarionIdx, greaterThan(firstNtIdx));

      // Visible works now contain 3 independent poster cards, all needs_review == 0!
      final visibleTitles = catalog.works.map((w) => w['title']).toSet();
      expect(visibleTitles, {'机动战士高达NT', '创星的大天使 背叛的翅膀', '创势的大天使EVOL'});
      expect(catalog.works.every((w) => w['needs_review'] == 0), isTrue);
      for (final w in catalog.works) {
        expect(catalog.forWork(w['id'].toString()), hasLength(1));
      }
    },
  );
}
