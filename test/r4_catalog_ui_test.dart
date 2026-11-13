import 'dart:convert';
import 'dart:io';

import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/image_store.dart';
import 'package:ccplayer/core/optional_features.dart';
import 'package:ccplayer/core/scan_activity.dart';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/main.dart';
import 'package:ccplayer/ui/nipaplay_style.dart';
import 'package:ccplayer/ui/scan_progress_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

Widget _testApp(Widget home, {double textScale = 1.0}) {
  return MaterialApp(
    locale: const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    theme: NipaPlayStyle.theme(Brightness.light),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: home,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      OptionalFeatures.preferenceKey: '{}',
    });
  });

  group('Issue 9A: hidden shell filtering and deleteWork vs hideWork', () {
    test(
      'hiddenWorkEntries and hiddenWorks exclude 0-asset shells but retain hidden works with assets',
      () async {
        final root = await Directory.systemTemp.createTemp('konata-r4-shell-');
        final catalog = Catalog.instance;
        await catalog.initialize(dataDirectory: root);
        try {
          await catalog.db.insert('sources', {
            'id': 'src-shell',
            'kind': 'local',
            'label': '本地媒体',
            'location': root.path,
          });
          // 0-asset shell left behind after splitting a multi-work folder.
          await catalog.db.insert('works', {
            'id': 'work:src-shell:Collection',
            'title': 'Collection Shell',
            'hidden': 1,
            'keep_hidden': 0,
            'needs_review': 0,
          });
          // Split child work that owns the actual asset.
          await catalog.db.insert('works', {
            'id': 'work:src-shell:Collection:classified:child-a',
            'title': 'Split Child A',
            'hidden': 0,
            'keep_hidden': 0,
            'needs_review': 0,
          });
          await catalog.db.insert('assets', {
            'id': 'asset-child-a',
            'source_id': 'src-shell',
            'work_id': 'work:src-shell:Collection:classified:child-a',
            'relative_path': 'Collection/A/01.mkv',
            'name': '01.mkv',
            'category': 'main',
            'season': 1,
            'episode': 1,
            'size': 1024,
          });
          // Normally hidden work that still owns assets.
          await catalog.db.insert('works', {
            'id': 'work:src-shell:HiddenReal',
            'title': 'Hidden Real Work',
            'hidden': 1,
            'keep_hidden': 1,
            'needs_review': 0,
          });
          await catalog.db.insert('assets', {
            'id': 'asset-hidden-real',
            'source_id': 'src-shell',
            'work_id': 'work:src-shell:HiddenReal',
            'relative_path': 'HiddenReal/01.mkv',
            'name': '01.mkv',
            'category': 'main',
            'season': 1,
            'episode': 1,
            'size': 1024,
          });

          await catalog.reload();
          expect(
            catalog.hiddenWorkEntries.map((w) => w['id']).toList(),
            ['work:src-shell:HiddenReal'],
          );
          final queried = await catalog.hiddenWorks();
          expect(
            queried.map((w) => w['id']).toList(),
            ['work:src-shell:HiddenReal'],
          );
          expect(
            catalog.works.map((w) => w['id']).toList(),
            ['work:src-shell:Collection:classified:child-a'],
          );
        } finally {
          await ImageStore.close();
          ImageStore.root = null;
          await catalog.db.close();
          await root.delete(recursive: true);
        }
      },
    );

    test(
      '0-asset hidden entries keep keep_hidden=1 without classified children but exclude split parents',
      () async {
        final root = await Directory.systemTemp.createTemp('konata-r4-keep-');
        final catalog = Catalog.instance;
        await catalog.initialize(dataDirectory: root);
        try {
          await catalog.db.insert('works', {
            'id': 'work:src:Explicit%20Pinned',
            'title': 'Explicit Pinned Without Assets',
            'hidden': 1,
            'keep_hidden': 1,
            'needs_review': 0,
          });
          await catalog.db.insert('works', {
            'id': 'work:src:Split%20Pinned',
            'title': 'Split Pinned Parent Shell',
            'hidden': 1,
            'keep_hidden': 1,
            'needs_review': 0,
          });
          await catalog.db.insert('works', {
            'id': 'work:src:Split%20Pinned:classified:child-1',
            'title': 'Split Child',
            'hidden': 0,
            'keep_hidden': 0,
            'needs_review': 0,
          });

          await catalog.reload();
          expect(
            catalog.hiddenWorkEntries.map((w) => w['id']).toList(),
            ['work:src:Explicit%20Pinned'],
          );
          final queried = await catalog.hiddenWorks();
          expect(
            queried.map((w) => w['id']).toList(),
            ['work:src:Explicit%20Pinned'],
          );
        } finally {
          await ImageStore.close();
          ImageStore.root = null;
          await catalog.db.close();
          await root.delete(recursive: true);
        }
      },
    );

    test(
      'deleteWork removes all work SQLite records and exclusive cached cover without touching source files',
      () async {
        final temp = await Directory.systemTemp.createTemp('konata-r4-del-');
        final dataDir = await Directory(p.join(temp.path, 'data')).create();
        final mediaDir = await Directory(p.join(temp.path, 'media')).create();
        final videoFile = File(p.join(mediaDir.path, 'Sample', '01.mkv'));
        await videoFile.parent.create(recursive: true);
        final originalBytes = utf8.encode('source-video-must-stay-intact');
        await videoFile.writeAsBytes(originalBytes);

        final catalog = Catalog.instance;
        await catalog.initialize(dataDirectory: dataDir);
        ImageStore.root ??= Directory(p.join(dataDir.path, 'artwork'));
        try {
          final artworkRoot = ImageStore.root!;
          final exclusiveCover = File(
            p.join(artworkRoot.path, 'custom', 'only-target.png'),
          );
          final sharedCover = File(
            p.join(artworkRoot.path, 'custom', 'shared.png'),
          );
          await exclusiveCover.parent.create(recursive: true);
          await exclusiveCover.writeAsBytes([1, 2, 3, 4]);
          await sharedCover.writeAsBytes([5, 6, 7, 8]);

          await catalog.db.insert('sources', {
            'id': 'src-del',
            'kind': 'local',
            'label': '本地媒体',
            'location': mediaDir.path,
          });
          const targetWorkId = 'work:src-del:Sample';
          const otherWorkId = 'work:src-del:Other';
          await catalog.db.insert('works', {
            'id': targetWorkId,
            'title': 'Target Work',
            'manual_cover_source': 'local',
            'manual_cover_url': 'artwork:custom/only-target.png',
            'cover_edit_json': jsonEncode({
              'resource': 'artwork:custom/only-target.png',
              'backdrop': {'resource': 'artwork:custom/shared.png'},
            }),
            'needs_review': 0,
          });
          await catalog.db.insert('works', {
            'id': otherWorkId,
            'title': 'Other Work',
            'manual_cover_source': 'local',
            'manual_cover_url': 'artwork:custom/shared.png',
            'needs_review': 0,
          });
          await catalog.db.insert('assets', {
            'id': 'asset-del-1',
            'source_id': 'src-del',
            'work_id': targetWorkId,
            'relative_path': 'Sample/01.mkv',
            'name': '01.mkv',
            'category': 'main',
            'season': 1,
            'episode': 1,
            'size': originalBytes.length,
          });
          await catalog.db.insert('progress', {
            'asset_id': 'asset-del-1',
            'position_ms': 15000,
            'duration_ms': 60000,
            'completed': 0,
            'updated_at': DateTime.now().toIso8601String(),
          });
          await catalog.db.insert('asset_overrides', {
            'asset_id': 'asset-del-1',
            'work_id': targetWorkId,
            'category': 'main',
            'episode': 1,
            'season': 1,
          });
          await catalog.db.insert('asset_override_history', {
            'asset_id': 'asset-del-1',
            'work_id': targetWorkId,
            'category': 'main',
            'episode': 1,
            'season': 1,
            'was_locked': 0,
          });
          await catalog.db.insert('work_details', {
            'work_id': targetWorkId,
            'identity': 'id-target',
            'payload': '{}',
            'fetched_at': DateTime.now().toIso8601String(),
          });
          await catalog.db.insert('logical_episode_confirmations', {
            'asset_id': 'asset-del-1',
            'logical_key': 'tmdb:tv:1:s1:e1',
            'revoked': 0,
            'created_at': DateTime.now().toIso8601String(),
          });
          await catalog.db.insert('bangumi_episode_mappings', {
            'episode_key': 'tmdb:tv:1:s1:e1',
            'asset_id': 'asset-del-1',
            'revision': 1,
            'subject_id': 10,
            'episode_id': 101,
            'episode_type': 0,
            'episode_sort': 1.0,
            'episode_name': 'Ep 1',
            'revoked': 0,
            'verified_at': DateTime.now().toIso8601String(),
          });

          await catalog.reload();
          await catalog.deleteWork(targetWorkId);

          expect(catalog.works.map((w) => w['id']).toList(), [otherWorkId]);
          expect(catalog.hiddenWorkEntries, isEmpty);
          expect(
            await catalog.db.query(
              'works',
              where: 'id=?',
              whereArgs: [targetWorkId],
            ),
            isEmpty,
          );
          expect(
            await catalog.db.query(
              'assets',
              where: 'work_id=?',
              whereArgs: [targetWorkId],
            ),
            isEmpty,
          );
          expect(
            await catalog.db.query(
              'progress',
              where: 'asset_id=?',
              whereArgs: ['asset-del-1'],
            ),
            isEmpty,
          );
          expect(
            await catalog.db.query(
              'asset_overrides',
              where: 'work_id=?',
              whereArgs: [targetWorkId],
            ),
            isEmpty,
          );
          expect(
            await catalog.db.query(
              'asset_override_history',
              where: 'work_id=?',
              whereArgs: [targetWorkId],
            ),
            isEmpty,
          );
          expect(
            await catalog.db.query(
              'work_details',
              where: 'work_id=?',
              whereArgs: [targetWorkId],
            ),
            isEmpty,
          );
          expect(
            await catalog.db.query(
              'logical_episode_confirmations',
              where: 'asset_id=?',
              whereArgs: ['asset-del-1'],
            ),
            isEmpty,
          );
          expect(
            await catalog.db.query(
              'bangumi_episode_mappings',
              where: 'asset_id=?',
              whereArgs: ['asset-del-1'],
            ),
            isEmpty,
          );

          // Exclusive cover file removed; shared cover & source video untouched.
          expect(await exclusiveCover.exists(), isFalse);
          expect(await sharedCover.exists(), isTrue);
          expect(await videoFile.exists(), isTrue);
          expect(await videoFile.readAsBytes(), originalBytes);
        } finally {
          await ImageStore.close();
          ImageStore.root = null;
          await catalog.db.close();
          await temp.delete(recursive: true);
        }
      },
    );

    testWidgets(
      'WorkPage distinguishes hideWork vs deleteWork with secondary confirmation and pops safely',
      (tester) async {
        late Directory temp;
        late File sourceVideo;
        final catalog = Catalog.instance;
        const hideWorkId = 'work:src-ui:HideTarget';
        const deleteWorkId = 'work:src-ui:DeleteTarget';

        await tester.runAsync(() async {
          temp = await Directory.systemTemp.createTemp('konata-r4-workpage-');
          final dataDir = await Directory(p.join(temp.path, 'data')).create();
          final mediaDir = await Directory(p.join(temp.path, 'media')).create();
          sourceVideo = File(p.join(mediaDir.path, 'DeleteTarget', '01.mkv'));
          await sourceVideo.parent.create(recursive: true);
          await sourceVideo.writeAsBytes([9, 8, 7]);

          await catalog.initialize(dataDirectory: dataDir);
          await catalog.db.insert('sources', {
            'id': 'src-ui',
            'kind': 'local',
            'label': '本地',
            'location': mediaDir.path,
          });
          for (final (id, title) in const [
            (hideWorkId, '要隐藏的作品'),
            (deleteWorkId, '要真删除的作品'),
          ]) {
            await catalog.db.insert('works', {
              'id': id,
              'title': title,
              'needs_review': 0,
            });
            await catalog.db.insert('assets', {
              'id': 'asset:$id',
              'source_id': 'src-ui',
              'work_id': id,
              'relative_path': '$title/01.mkv',
              'name': '01.mkv',
              'category': 'main',
              'season': 1,
              'episode': 1,
              'size': 3,
            });
          }
          await catalog.reload();
        });
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(() async {
            await ImageStore.close();
            ImageStore.root = null;
            if (catalog.db.isOpen) {
              await catalog.db.close().timeout(
                const Duration(seconds: 2),
                onTimeout: () {},
              );
            }
            if (await temp.exists()) await temp.delete(recursive: true);
          });
        });

        await tester.binding.setSurfaceSize(const Size(390, 780));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          _testApp(
            Scaffold(
              body: Builder(
                builder: (ctx) => Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ElevatedButton(
                      onPressed: () => Navigator.of(ctx).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const WorkPage(workId: hideWorkId),
                        ),
                      ),
                      child: const Text('打开隐藏目标'),
                    ),
                    ElevatedButton(
                      onPressed: () => Navigator.of(ctx).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const WorkPage(workId: deleteWorkId),
                        ),
                      ),
                      child: const Text('打开删除目标'),
                    ),
                  ],
                ),
              ),
            ),
            textScale: 1.35,
          ),
        );

        // 1. Hide flow via WorkPage menu ("隐藏该作品").
        await tester.tap(find.text('打开隐藏目标'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('detail-more-button')));
        await tester.pumpAndSettle();
        expect(find.text('隐藏该作品'), findsOneWidget);
        expect(find.text('删除该作品'), findsOneWidget);
        await tester.tap(find.text('隐藏该作品'));
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('confirm-hide-work')), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.ensureVisible(
          find.byKey(const ValueKey('keep-work-hidden-checkbox')),
        );
        await tester.tap(
          find.byKey(const ValueKey('keep-work-hidden-checkbox')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('confirm-hide-work')));
        await tester.pump();
        for (var i = 0;
            i < 100 && catalog.works.any((w) => w['id'] == hideWorkId);
            i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
        await tester.pumpAndSettle();

        expect(find.text('打开隐藏目标'), findsOneWidget);
        expect(
          catalog.hiddenWorkEntries.map((w) => w['id']).toList(),
          [hideWorkId],
        );

        // 2. Permanent delete flow via WorkPage menu ("删除该作品") with secondary confirmation dialog.
        await tester.tap(find.text('打开删除目标'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('detail-more-button')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('删除该作品'));
        await tester.pumpAndSettle();

        expect(find.text('确认删除该作品？'), findsOneWidget);
        expect(find.textContaining('不会删除源文件夹中的视频文件'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.tap(find.byKey(const ValueKey('confirm-delete-work')));
        await tester.pump();
        for (var i = 0;
            i < 100 && catalog.works.any((w) => w['id'] == deleteWorkId);
            i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
        await tester.pumpAndSettle();

        expect(find.text('打开删除目标'), findsOneWidget);
        expect(
          catalog.works.any((w) => w['id'] == deleteWorkId),
          isFalse,
        );
        expect(
          catalog.hiddenWorkEntries.any((w) => w['id'] == deleteWorkId),
          isFalse,
        );
        final sourceStillExists = await tester.runAsync(sourceVideo.exists);
        expect(sourceStillExists, isTrue);
      },
    );
  });

  group('Issue 1: ScanProgressDialog in-place review workflow', () {
    testWidgets(
      'supports in-place rematch, confirmWorkReview count sync, and explicit detail navigation across sizes',
      (tester) async {
        late Directory dataDir;
        final catalog = Catalog.instance;
        const src = 'src-review';
        final workCand =
            'work:$src:${Uri.encodeComponent('Anime/CandidateWork')}';
        final workUnmatched =
            'work:$src:${Uri.encodeComponent('Anime/UnmatchedWork')}';
        final workOk = 'work:$src:${Uri.encodeComponent('Anime/MatchedWork')}';

        await tester.runAsync(() async {
          dataDir = await Directory.systemTemp.createTemp('konata-r4-review-');
          await catalog.initialize(dataDirectory: dataDir);
          await catalog.db.insert('sources', {
            'id': src,
            'kind': 'local',
            'label': '本地媒体',
            'location': dataDir.path,
          });
          await catalog.db.insert('works', {
            'id': workOk,
            'title': '已匹配动画',
            'poster': 'https://image.tmdb.org/t/p/w500/ok.jpg',
            'needs_review': 0,
          });
          await catalog.db.insert('works', {
            'id': workCand,
            'title': '待确认候选动画',
            'poster': 'https://lain.bgm.tv/pic/cover/l/cand.jpg',
            'needs_review': 1,
          });
          await catalog.db.insert('works', {
            'id': workUnmatched,
            'title': '未匹配动画',
            'poster': null,
            'needs_review': 1,
          });
          for (final (idx, wid) in [workOk, workCand, workUnmatched].indexed) {
            await catalog.db.insert('assets', {
              'id': 'asset-r-$idx',
              'source_id': src,
              'work_id': wid,
              'relative_path': 'dir_$idx/01.mkv',
              'name': '01.mkv',
              'category': 'main',
              'season': 1,
              'episode': 1,
              'size': 1024,
            });
          }
          await catalog.reload();
        });
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(() async {
            await ImageStore.close();
            ImageStore.root = null;
            await catalog.db.close();
            await dataDir.delete(recursive: true);
          });
        });

        final store = ScanActivityStore.instance;
        store.begin(src, ['Anime']);
        store.beginFolder(src, 'Anime/UnmatchedWork');
        store.video(src, 'Anime/UnmatchedWork');
        store.endFolder(src, 'Anime/UnmatchedWork');
        store.beginScraping(src, 3);
        store.metadataDone(src, matched: true);
        store.metadataDone(src, review: true);
        store.metadataDone(src, review: true);
        store.complete(src);

        String? openedWorkId;
        Future<bool> fakeRematch(
          BuildContext ctx,
          Map<String, Object?> work,
        ) async {
          await catalog.bind(
            work['id'].toString(),
            provider: 'tmdb',
            providerId: 9999,
            title: '手动重匹配完成动画',
            year: 2024,
            poster: 'https://image.tmdb.org/t/p/w500/new.jpg',
            overview: '手动匹配简介',
            type: 'tv',
          );
          return true;
        }

        // Verify responsive rendering with zero overflow on 1440x900, 640x700, 390x780 + 1.35x scale.
        for (final (size, scale) in const [
          (Size(1440, 900), 1.0),
          (Size(640, 700), 1.35),
          (Size(390, 780), 1.35),
        ]) {
          await tester.binding.setSurfaceSize(size);
          await tester.pumpWidget(
            _testApp(
              Scaffold(
                body: Builder(
                  builder: (ctx) => Center(
                    child: ElevatedButton(
                      onPressed: () => ScanProgressDialog.show(
                        ctx,
                        sourceId: src,
                        onOpenWork: (id) => openedWorkId = id,
                        onMatchWork: fakeRematch,
                      ),
                      child: const Text('打开进度'),
                    ),
                  ),
                ),
              ),
              textScale: scale,
            ),
          );
          await tester.tap(find.text('打开进度'));
          await tester.pumpAndSettle();

          await tester.tap(find.byKey(const ValueKey('scan-progress-tab-review')));
          await tester.pumpAndSettle();

          expect(find.text('待复核／失败项 (2)'), findsNWidgets(2));
          final listFinder = find.byKey(
            const ValueKey('scan-progress-folder-list'),
          );
          await tester.dragUntilVisible(
            find.text('待确认候选动画'),
            listFinder,
            const Offset(0, -160),
          );
          await tester.pumpAndSettle();
          expect(find.text('待确认候选动画'), findsOneWidget);
          await tester.dragUntilVisible(
            find.text('未匹配动画'),
            listFinder,
            const Offset(0, -160),
          );
          await tester.pumpAndSettle();
          expect(find.text('未匹配动画'), findsOneWidget);
          expect(tester.takeException(), isNull, reason: '$size @ $scale');

          await tester.tap(find.text('关闭'));
          await tester.pumpAndSettle();
        }

        // Test interactive in-place workflow on desktop layout.
        await tester.binding.setSurfaceSize(const Size(1440, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        // First verify production path (no custom onOpenWork):
        // 1) default row tap opens manual match dialog without closing ScanProgressDialog;
        // 2) tapping "查看详情" pushes WorkPage on top of ScanProgressDialog, and tapping
        //    WorkPage's back button returns directly to ScanProgressDialog's review tab.
        await tester.pumpWidget(
          _testApp(
            Scaffold(
              body: Builder(
                builder: (ctx) => Center(
                  child: ElevatedButton(
                    onPressed: () => ScanProgressDialog.show(
                      ctx,
                      sourceId: src,
                    ),
                    child: const Text('打开默认进度'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开默认进度'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('scan-progress-tab-review')));
        await tester.pumpAndSettle();

        await tester.tap(find.text('未匹配动画'));
        await tester.pumpAndSettle();
        expect(openedWorkId, isNull);
        expect(find.byKey(const ValueKey('manual-match-provider')), findsOneWidget);
        expect(find.byKey(const ValueKey('scan-progress-tab-review')), findsOneWidget);
        // Close manual match dialog; ScanProgressDialog stays open.
        await tester.tap(find.text('关闭').last);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('scan-progress-tab-review')), findsOneWidget);

        // Tap "查看详情" on CandidateWork: opens WorkPage on top of ScanProgressDialog.
        await tester.tap(
          find.byKey(ValueKey('pending-review-detail-$workCand')),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('detail-back-button')), findsOneWidget);

        // Tap back on WorkPage: returns directly to ScanProgressDialog's review tab!
        await tester.tap(find.byKey(const ValueKey('detail-back-button')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('detail-back-button')), findsNothing);
        expect(find.byKey(const ValueKey('scan-progress-tab-review')), findsOneWidget);
        expect(find.text('待确认候选动画'), findsOneWidget);
        expect(find.text('未匹配动画'), findsOneWidget);

        // Close default dialog and run complete bind + confirm + custom onOpenWork cycle.
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();

        await tester.pumpWidget(
          _testApp(
            Scaffold(
              body: Builder(
                builder: (ctx) => Center(
                  child: ElevatedButton(
                    onPressed: () => ScanProgressDialog.show(
                      ctx,
                      sourceId: src,
                      onOpenWork: (id) => openedWorkId = id,
                      onMatchWork: fakeRematch,
                    ),
                    child: const Text('打开闭环进度'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开闭环进度'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('scan-progress-tab-review')));
        await tester.pumpAndSettle();

        // 1. Rematch UnmatchedWork via button: keeps dialog open and decrements count 2 -> 1.
        await tester.tap(
          find.byKey(ValueKey('pending-review-rematch-$workUnmatched')),
        );
        await tester.pump();
        await tester.runAsync(() async {
          final deadline = DateTime.now().add(const Duration(seconds: 5));
          while (catalog.works.any(
                (w) => w['id'] == workUnmatched && w['needs_review'] == 1,
              ) &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        });
        await tester.pumpAndSettle();
        expect(openedWorkId, isNull);
        expect(find.text('未匹配动画'), findsNothing);
        expect(find.text('待确认候选动画'), findsOneWidget);
        expect(find.text('待复核／失败项 (1)'), findsNWidgets(2));

        // 2. Tap detail icon button on CandidateWork: closes dialog and invokes onOpenWork.
        await tester.tap(
          find.byKey(ValueKey('pending-review-detail-$workCand')),
        );
        await tester.pumpAndSettle();
        expect(openedWorkId, workCand);
        expect(find.byKey(const ValueKey('scan-progress-tab-review')), findsNothing);

        // 3. Re-open and confirm CandidateWork via confirmWorkReview: decrements 1 -> 0.
        openedWorkId = null;
        await tester.tap(find.text('打开闭环进度'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('scan-progress-tab-review')));
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(ValueKey('pending-review-confirm-$workCand')),
        );
        await tester.pump();
        await tester.runAsync(() async {
          final deadline = DateTime.now().add(const Duration(seconds: 5));
          while (catalog.works.any(
                (w) => w['id'] == workCand && w['needs_review'] == 1,
              ) &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        });
        await tester.pumpAndSettle();

        expect(openedWorkId, isNull);
        expect(find.text('待确认候选动画'), findsNothing);
        expect(find.text('待复核／失败项 (0)'), findsNWidgets(2));
        expect(find.text('所有作品均已高置信匹配完成。'), findsOneWidget);
        final confirmedRow = (await tester.runAsync(
          () => catalog.db.query(
            'works',
            where: 'id=?',
            whereArgs: [workCand],
          ),
        ))!
            .single;
        expect(confirmedRow['needs_review'], 0);
      },
    );
  });
}
