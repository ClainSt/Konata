import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/metadata.dart';
import 'package:ccplayer/core/personal_scraper.dart';
import 'package:ccplayer/core/scan_activity.dart';
import 'package:ccplayer/core/selected_scan_workflow.dart';
import 'package:ccplayer/ui/scan_progress_dialog.dart';

void main() {
  setUpAll(() => sqfliteFfiInit());
  test(
    'selected folders index first, auto-scrape once, report direct video counts',
    () async {
      final temp = await Directory.systemTemp.createTemp('ccplayer-scan-');
      const anime = '16bit的感动 ANOTHER LAYER (2023) {tmdb-217512}';
      final animeFolder = await Directory('${temp.path}/$anime').create();
      await File('${animeFolder.path}/[01].mkv').writeAsBytes([1, 2, 3]);
      await File('${animeFolder.path}/[01].chs.ass').writeAsString('subtitle');
      final sp = await Directory('${animeFolder.path}/SPs').create();
      await File('${sp.path}/CM01.mkv').writeAsBytes([4]);
      final scans = await Directory('${animeFolder.path}/Scans').create();
      await File('${scans.path}/bonus.mkv').writeAsBytes([5]);
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final cat = Catalog.instance;
      cat.db = db;
      final oldToken = Metadata.token, oldMode = Metadata.authMode;
      Metadata.token = 'test-token';
      Metadata.authMode = 'token';
      var tmdbCalls = 0;
      final client = MockClient((req) async {
        if (req.url.path == '/3/tv/217512') {
          tmdbCalls++;
          return http.Response(
            jsonEncode({
              'id': 217512,
              'name': '16bit的感动 ANOTHER LAYER',
              'poster_path': '/real.jpg',
              'overview': '官方简介',
              'first_air_date': '2023-10-04',
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response(jsonEncode({'data': []}), 200);
      });
      final scraper = PersonalMetadataScraper(client: client);
      try {
        await db.execute(
          'CREATE TABLE sources (id TEXT PRIMARY KEY,kind TEXT,label TEXT,location TEXT,username TEXT,password TEXT)',
        );
        await db.execute(
          'CREATE TABLE works (id TEXT PRIMARY KEY,title TEXT,year INTEGER,tmdb_id INTEGER,tmdb_type TEXT,bangumi_id INTEGER,poster TEXT,poster_fallback TEXT,manual_cover_url TEXT,manual_cover_source TEXT,overview TEXT,manual_lock INTEGER NOT NULL DEFAULT 0,needs_review INTEGER NOT NULL DEFAULT 1,hidden INTEGER NOT NULL DEFAULT 0,keep_hidden INTEGER NOT NULL DEFAULT 0)',
        );
        await db.execute(
          'CREATE TABLE assets (id TEXT PRIMARY KEY,source_id TEXT,work_id TEXT,relative_path TEXT,name TEXT,episode INTEGER,season INTEGER NOT NULL DEFAULT 1,category TEXT,extra_type TEXT,size INTEGER, UNIQUE(source_id,relative_path))',
        );
        await db.execute(
          'CREATE TABLE scan_roots (source_id TEXT,relative_path TEXT,mode TEXT,PRIMARY KEY(source_id,relative_path))',
        );
        await db.execute(
          'CREATE TABLE asset_overrides (asset_id TEXT PRIMARY KEY,work_id TEXT,category TEXT,episode INTEGER,season INTEGER,extra_type TEXT)',
        );
        await db.execute(
          'CREATE TABLE asset_override_history (asset_id TEXT PRIMARY KEY,work_id TEXT,category TEXT,episode INTEGER,season INTEGER,extra_type TEXT,was_locked INTEGER)',
        );
        await db.execute(
          'CREATE TABLE progress (asset_id TEXT PRIMARY KEY,position_ms INTEGER)',
        );
        final source = <String, Object?>{
          'id': 'test-source',
          'kind': 'local',
          'label': '本地样本',
          'location': temp.path,
          'username': '',
        };
        await db.insert('sources', source);
        await cat.reload();
        await cat.addScanRoot('test-source', anime);
        final activities = ScanActivityStore.instance;
        void cancelAfterFirstFolder() {
          final run = activities.forSource('test-source');
          if (run != null && run.completedFolders.isNotEmpty) {
            activities.requestCancel('test-source');
          }
        }
        activities.addListener(cancelAfterFirstFolder);
        try {
          await SelectedScanWorkflow.run(source, scraper: scraper);
        } finally {
          activities.removeListener(cancelAfterFirstFolder);
        }
        expect(activities.forSource('test-source')!.phase, ScanPhase.cancelled);
        expect(cat.scanning, isFalse);
        expect(cat.rootsFor('test-source'), isNotEmpty);
        expect(cat.assets, hasLength(1));
        await SelectedScanWorkflow.run(source, scraper: scraper);
        final activity = ScanActivityStore.instance.forSource('test-source')!;
        expect(activity.phase, ScanPhase.complete);
        expect(activity.videoCount, 2);
        expect(activity.folderVideos[anime], 1);
        expect(activity.folderVideos['$anime/SPs'], 1);
        expect(activity.folderVideos.keys, isNot(contains('$anime/Scans')));
        expect(activity.completedFolders.length, 2);
        expect(activity.videosUnder(anime), 2);
        expect(activity.metadataTotal, 1);
        expect(activity.metadataProcessed, 1);
        expect(
          activity.matched,
          1,
          reason:
              'review=${activity.needsReview} errors=${activity.metadataErrors} tmdbCalls=$tmdbCalls work=${cat.works}',
        );
        expect(tmdbCalls, 1);
        expect(cat.rootsFor('test-source'), isEmpty);
        expect(cat.assets.length, 2);
        expect(
          cat.works.single['poster'],
          'https://images.tmdb.org/t/p/w500/real.jpg',
        );
        expect(cat.scanning, isFalse);
      } finally {
        cat.updateStatus('就绪');
        Metadata.token = oldToken;
        Metadata.authMode = oldMode;
        scraper.close();
        client.close();
        await db.close();
        await temp.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'progress inspector shows exact folder and per-folder video counts',
    (tester) async {
      const id = 'test-inspector';
      final store = ScanActivityStore.instance;
      store.begin(id, ['动画-单作品/86']);
      store.beginFolder(id, '动画-单作品/86');
      store.video(id, '动画-单作品/86');
      store.endFolder(id, '动画-单作品/86');
      store.beginFolder(id, '动画-单作品/86/SPs');
      store.video(id, '动画-单作品/86/SPs');
      store.video(id, '动画-单作品/86/SPs');
      store.endFolder(id, '动画-单作品/86/SPs');
      store.beginScraping(id, 1);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => ScanProgressDialog.show(
                  tester.element(find.byType(ElevatedButton)),
                  sourceId: id,
                ),
                child: const Text('查看扫描进度'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('查看扫描进度'));
      await tester.pumpAndSettle();
      expect(find.text('扫描进度'), findsOneWidget);
      expect(find.text('索引视频：3'), findsOneWidget);
      expect(find.text('已扫描目录：2'), findsOneWidget);
      expect(find.text('动画-单作品/86/SPs'), findsOneWidget);
      expect(find.text('2 个视频'), findsOneWidget);
      store.metadataDone(id, matched: true);
      store.complete(id);
      await tester.pumpAndSettle();
      expect(find.text('扫描及自动刮削已完成'), findsOneWidget);
    },
  );
}
