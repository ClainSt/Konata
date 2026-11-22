import 'dart:async';
import 'dart:io';

import 'package:konata/application/playback/audio_playback_notifier.dart';
import 'package:konata/application/providers/konata_value_notifier.dart';
import 'package:konata/application/providers/library_providers.dart';
import 'package:konata/domain/models/episode.dart';
import 'package:konata/domain/models/media_source.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/models/playback_record.dart';
import 'package:konata/domain/models/series_group.dart';
import 'package:konata/domain/models/tmdb_models.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/infrastructure/cache/artwork_cache.dart';
import 'package:konata/infrastructure/cache/photos_storage.dart';
import 'package:konata/infrastructure/database/drift_library_repository.dart';
import 'package:konata/infrastructure/database/konata_database.dart';
import 'package:konata/infrastructure/network/tmdb_service.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

/// 记录 SQLite 语句执行次数的轻量 Drift 查询拦截器。
class _CountingQueryInterceptor extends QueryInterceptor {
  int statementCount = 0;

  void reset() => statementCount = 0;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    statementCount++;
    return executor.runSelect(statement, args);
  }

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    statementCount++;
    return executor.runInsert(statement, args);
  }

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    statementCount++;
    return executor.runUpdate(statement, args);
  }

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    statementCount++;
    return executor.runDelete(statement, args);
  }

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    statementCount++;
    return executor.runCustom(statement, args);
  }
}

void main() {
  group('1. SQLite 二级覆盖索引与 PRAGMA 参数契约', () {
    test('核心高频查询全部命中索引且零临时 B-Tree 排序，PRAGMA 配置生效', () async {
      final db = KonataDatabase(
        NativeDatabase.memory(setup: KonataDatabase.configureSqlitePragmas),
      );
      addTearDown(db.close);

      // 触发 beforeOpen 幂等创建二级索引。
      await db.customSelect('SELECT 1').get();

      final cacheRows = await db.customSelect('PRAGMA cache_size').get();
      expect(cacheRows.first.data.values.first, equals(-8192));

      final tempRows = await db.customSelect('PRAGMA temp_store').get();
      expect(tempRows.first.data.values.first, equals(2));

      final queries = <String, String>{
        'variants_by_work':
            "SELECT * FROM media_variants WHERE work_id = 'w1'",
        'episodes_by_work':
            "SELECT * FROM episodes WHERE work_id = 'w1' "
            'ORDER BY season_number ASC, episode_number ASC',
        'playbacks_by_work':
            "SELECT * FROM playback_records WHERE work_id = 'w1' "
            'ORDER BY played_at DESC',
        'works_by_series': "SELECT * FROM works WHERE series_id = 's1'",
        'history_recent':
            'SELECT * FROM playback_records ORDER BY played_at DESC LIMIT 30',
        'hidden_works': 'SELECT * FROM works WHERE is_hidden = 1',
      };

      for (final entry in queries.entries) {
        final rows = await db
            .customSelect('EXPLAIN QUERY PLAN ${entry.value}')
            .get();
        final plan = rows.map((r) => r.data['detail'].toString()).join(' | ');
        expect(
          plan,
          contains('USING INDEX'),
          reason: '${entry.key} 必须命中索引，实际计划：$plan',
        );
        expect(
          plan,
          isNot(contains('USE TEMP B-TREE FOR ORDER BY')),
          reason: '${entry.key} 不应退化为临时 B-Tree 排序，实际计划：$plan',
        );
      }
    });
  });

  group('2. 零 N+1 批量查询、特典签名缓存与批量孤儿清理等价性', () {
    late Directory tempRoot;
    late _CountingQueryInterceptor counter;
    late KonataDatabase db;
    late DriftLibraryRepository repo;
    late PhotosStorage photos;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('konata_speed_test_');
      counter = _CountingQueryInterceptor();
      db = KonataDatabase(
        NativeDatabase.memory(
          setup: KonataDatabase.configureSqlitePragmas,
        ).interceptWith(counter),
      );
      repo = DriftLibraryRepository(db);
      photos = PhotosStorage(overrideRoot: tempRoot);
    });

    tearDown(() async {
      await db.close();
      if (tempRoot.existsSync()) {
        await tempRoot.delete(recursive: true);
      }
    });

    Future<void> seedFixture() async {
      final now = DateTime(2026, 5, 1, 10, 0);
      await repo.upsertMediaSource(
        const MediaSource(
          id: 'src_local',
          kind: MediaSourceKind.local,
          label: '本地仓库',
          location: r'D:\Anime',
        ),
      );
      await repo.upsertMediaSource(
        const MediaSource(
          id: 'src_webdav',
          kind: MediaSourceKind.webdav,
          label: '云盘源',
          location: 'https://dav.example.com/anime',
        ),
      );
      await repo.upsertSeriesGroup(
        SeriesGroup(
          id: 'series_frieren',
          title: '葬送的芙莉莲',
          tmdbCollectionId: 209867,
          createdAt: now,
          updatedAt: now,
        ),
      );

      final works = <Work>[];
      final episodes = <Episode>[];
      final variants = <MediaVariant>[];

      // 4 季同系列作品 + 34 部常规作品 + 2 部隐藏作品。
      for (var i = 0; i < 40; i++) {
        final workId = 'w_$i';
        final isSeries = i < 4;
        final isHidden = i >= 38;
        final isCrossSourceCopy = i == 5;
        works.add(
          Work(
            id: workId,
            title: isSeries
                ? '葬送的芙莉莲 第${i + 1}季'
                : (isCrossSourceCopy ? '孤独摇滚！' : (i == 4 ? '孤独摇滚！' : '作品 $i')),
            originalTitle: isCrossSourceCopy || i == 4
                ? 'ぼっち・ざ・ろっく！'
                : 'Title $i',
            tmdbId: isSeries
                ? 209867
                : (isCrossSourceCopy || i == 4 ? 197189 : 10000 + i),
            tmdbMediaType: TmdbMediaType.tv,
            matchedSeason: isSeries ? i + 1 : 1,
            seriesId: isSeries ? 'series_frieren' : null,
            seriesOrder: isSeries ? i + 1 : null,
            seriesLabel: isSeries ? '第${i + 1}季' : null,
            scrapeStatus: ScrapeStatus.matched,
            isHidden: isHidden,
          ),
        );

        final sourceId = isCrossSourceCopy ? 'src_webdav' : 'src_local';
        for (var ep = 1; ep <= 3; ep++) {
          final epId = '${workId}_ep_$ep';
          episodes.add(
            Episode(
              id: epId,
              workId: workId,
              seasonNumber: isSeries ? i + 1 : 1,
              episodeNumber: ep,
              title: '第 $ep 话',
            ),
          );
          variants.add(
            MediaVariant(
              id: '${epId}_v1',
              workId: workId,
              episodeId: epId,
              sourceId: sourceId,
              relativePath: 'Work_$i/EP0$ep.mkv',
              fileName: '[VCB-Studio] Work_$i [0$ep][Ma10p_1080p].mkv',
              fileSize: 900000000,
              releaseGroup: 'VCB-Studio',
            ),
          );
          if (i == 0 && ep == 1) {
            // 为 w_0 第 1 集增加第二个多版本文件。
            variants.add(
              MediaVariant(
                id: '${epId}_v2',
                workId: workId,
                episodeId: epId,
                sourceId: sourceId,
                relativePath: 'Work_$i/EP0${ep}_alt.mkv',
                fileName: '[Moozzi2] Work_$i [0$ep][1080p].mkv',
                fileSize: 850000000,
                releaseGroup: 'Moozzi2',
              ),
            );
          }
        }
      }

      // 为 w_0 追加 1 个特典、1 个 CD 与 1 个 Scan。
      episodes.add(
        const Episode(
          id: 'w_0_sp_1',
          workId: 'w_0',
          seasonNumber: 0,
          episodeNumber: 1,
          category: EpisodeCategory.extra,
          extraType: ExtraKind.ncop,
          title: 'NCOP 01',
        ),
      );
      variants.addAll(const [
        MediaVariant(
          id: 'w_0_sp_1_v1',
          workId: 'w_0',
          episodeId: 'w_0_sp_1',
          sourceId: 'src_local',
          relativePath: 'Work_0/SPs/NCOP01.mkv',
          fileName: '[VCB-Studio] Work_0 [NCOP01].mkv',
          fileSize: 120000000,
          assetKind: AssetKind.video,
          assetScope: SupplementaryAssetScope.seriesShared,
        ),
        MediaVariant(
          id: 'w_0_cd_1',
          workId: 'w_0',
          sourceId: 'src_local',
          relativePath: 'Work_0/CDs/OST_01.flac',
          fileName: '01. Theme.flac',
          fileSize: 32000000,
          assetKind: AssetKind.cdAlbum,
        ),
        MediaVariant(
          id: 'w_0_scan_1',
          workId: 'w_0',
          sourceId: 'src_local',
          relativePath: 'Work_0/Scans/Booklet_01.webp',
          fileName: 'Booklet_01.webp',
          fileSize: 2500000,
          assetKind: AssetKind.scanGallery,
        ),
      ]);

      for (final w in works) {
        await repo.upsertWork(w);
      }
      await repo.upsertEpisodesBatch(episodes);
      await repo.upsertMediaVariantsBatch(variants);

      // 插入较晚的音频记录与较早的视频续播记录，验证 latestPlayback 自动跳过 cd::。
      await repo.recordPlayback(
        PlaybackRecord(
          id: 'pb_video_w0',
          workId: 'w_0',
          episodeId: 'w_0_ep_2',
          variantId: 'w_0_ep_2_v1',
          seasonNumber: 1,
          episodeNumber: 2,
          episodeTitle: '第 2 话',
          sourceType: MediaSourceKind.local,
          positionSeconds: 420,
          durationSeconds: 1440,
          playedAt: DateTime(2026, 5, 1, 10, 0),
        ),
      );
      await repo.recordPlayback(
        PlaybackRecord(
          id: 'pb_audio_w0',
          workId: 'w_0',
          episodeId: 'cd::w_0_cd_1',
          variantId: 'w_0_cd_1',
          seasonNumber: 1,
          episodeNumber: 1,
          episodeTitle: '01. Theme',
          sourceType: MediaSourceKind.local,
          positionSeconds: 80,
          durationSeconds: 240,
          playedAt: DateTime(2026, 5, 1, 12, 0),
        ),
      );
    }

    test(
      'libraryItemsProvider、hiddenWorksProvider 与 workDetailBundleProvider 零 N+1 且结果准确',
      () async {
        await seedFixture();
        final container = ProviderContainer(
          retry: konataNoProviderRetry,
          overrides: [
            libraryRepositoryProvider.overrideWithValue(repo),
            photosStorageProvider.overrideWithValue(photos),
          ],
        );
        addTearDown(container.dispose);

        // 1. 首次冷加载（含 SeriesAutoLinker 自动联结同 TMDB 跨源作品的写回），总 SQL 仍远低于 N+1 阈值。
        counter.reset();
        final items = await container.read(libraryItemsProvider.future);
        expect(counter.statementCount, lessThanOrEqualTo(16));
        expect(items.length, equals(38));

        final w0 = items.firstWhere((e) => e.work.id == 'w_0');
        expect(w0.episodeCount, equals(3));
        expect(w0.maxEpisodeVariantCount, equals(2));
        expect(w0.hasMultiVariants, isTrue);
        expect(w0.releaseGroups, containsAll(['VCB-Studio', 'Moozzi2']));

        // 验证跨源同名作品标注角标。
        final confirmed = container.read(confirmedLibraryItemsProvider).value!;
        final localBocchi = confirmed.firstWhere((e) => e.work.id == 'w_4');
        final webdavBocchi = confirmed.firstWhere((e) => e.work.id == 'w_5');
        expect(localBocchi.crossSourceBadgeLabel, equals('本地'));
        expect(webdavBocchi.crossSourceBadgeLabel, equals('WebDAV'));

        // 2. 全新容器冷加载（系列已稳定，仍执行一次 SeriesAutoLinker 校验）：SQL 严格恒定 <= 6。
        final coldContainer = ProviderContainer(
          retry: konataNoProviderRetry,
          overrides: [
            libraryRepositoryProvider.overrideWithValue(repo),
            photosStorageProvider.overrideWithValue(photos),
          ],
        );
        addTearDown(coldContainer.dispose);
        counter.reset();
        final coldItems = await coldContainer.read(libraryItemsProvider.future);
        expect(counter.statementCount, lessThanOrEqualTo(6));
        expect(coldItems.length, equals(38));

        // 3. 热刷新保持 4 条批量恒定 SQL（<= 5）。
        counter.reset();
        container.invalidate(libraryItemsProvider);
        final refreshed = await container.read(libraryItemsProvider.future);
        expect(counter.statementCount, lessThanOrEqualTo(5));
        expect(refreshed.length, equals(38));

        // 3. hiddenWorksProvider 仅执行 1 次索引查询。
        counter.reset();
        final hidden = await container.read(hiddenWorksProvider.future);
        expect(counter.statementCount, equals(1));
        expect(hidden.map((w) => w.id), unorderedEquals(['w_38', 'w_39']));

        // 4. workDetailBundleProvider 批量加载系列与 O(1) variantsForEpisode 索引。
        counter.reset();
        final bundle = await container.read(
          workDetailBundleProvider('w_0').future,
        );
        expect(bundle, isNotNull);
        expect(bundle!.latestPlayback?.episodeId, equals('w_0_ep_2'));
        expect(bundle.seriesMembers.length, equals(4));
        expect(bundle.cdVariants.length, equals(1));
        expect(bundle.scanVariants.length, equals(1));
        expect(bundle.variantsForEpisode('w_0_ep_1').length, equals(2));

        // 5. 特典自愈签名缓存：未变化时命中 clean，追加特典后立即失效。
        final sigCache = container.read(extraReconcileSignatureCacheProvider);
        final initialSig = ExtraReconcileSignatureCache.computeSignature(
          work: bundle.work,
          episodes: await repo.getEpisodesByWork('w_0'),
          variants: await repo.getVariantsByWork('w_0'),
        );
        expect(sigCache.isClean('w_0', initialSig), isTrue);

        await repo.upsertMediaVariantsBatch(const [
          MediaVariant(
            id: 'w_0_sp_2_v1',
            workId: 'w_0',
            episodeId: 'w_0_sp_1',
            sourceId: 'src_local',
            relativePath: 'Work_0/SPs/PV01.mkv',
            fileName: '[VCB-Studio] Work_0 [PV01].mkv',
            fileSize: 90000000,
            assetKind: AssetKind.video,
          ),
        ]);
        final updatedVariants = await repo.getVariantsByWork('w_0');
        final updatedSig = ExtraReconcileSignatureCache.computeSignature(
          work: bundle.work,
          episodes: await repo.getEpisodesByWork('w_0'),
          variants: updatedVariants,
        );
        expect(sigCache.isClean('w_0', updatedSig), isFalse);
      },
    );

    test('pruneStaleSourceEntries 批量清理 22 部孤儿作品且消除按作品 N+1 查询', () async {
      await seedFixture();
      // 保留前 18 部作品（除 w_5 属 webdav）在 src_local 上的文件，淘汰其余 21 部本地作品。
      final activeWorkIds = <String>{
        for (var i = 0; i < 18; i++)
          if (i != 5) 'w_$i',
      };
      final allLocalVariants = await repo.getVariantsBySource('src_local');
      final activeVariantIds = <String>{
        for (final v in allLocalVariants)
          if (activeWorkIds.contains(v.workId)) v.id,
      };

      counter.reset();
      await repo.pruneStaleSourceEntries(
        sourceId: 'src_local',
        activeWorkIds: activeWorkIds,
        activeVariantIds: activeVariantIds,
      );
      expect(counter.statementCount, lessThanOrEqualTo(12));

      final remainingWorks = await repo.getAllWorks();
      // 剩余：17 部 src_local 作品 + 1 部 src_webdav 作品（w_5）= 18 部。
      expect(remainingWorks.length, equals(18));
      expect(remainingWorks.any((w) => w.id == 'w_5'), isTrue);
      expect(remainingWorks.any((w) => w.id == 'w_25'), isFalse);
    });
  });

  group('3. PhotosStorage O(1) 目录索引与 TmdbService 缓存直出', () {
    late Directory tempRoot;
    late PhotosStorage photos;
    late ArtworkCache artworkCache;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('konata_photos_speed_');
      photos = PhotosStorage(overrideRoot: tempRoot);
      artworkCache = ArtworkCache.photos(photos);
    });

    tearDown(() async {
      artworkCache.close();
      if (tempRoot.existsSync()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('PhotosStorage 索引随写入/外部改动/删除保持一致，非分档文件未命中零扫描', () async {
      final pngBytes = Uint8List.fromList(<int>[137, 80, 78, 71, 13, 10, 26, 10]);
      final file = await photos.writeArtwork(
        workId: 'work_alpha',
        subfolder: PhotoSubfolder.posters,
        fileKey: 'w500_abc12345.jpg',
        bytes: pngBytes,
        title: '葬送的芙莉莲',
      );
      expect(file, isNotNull);

      final hit = await photos.readArtwork(
        workId: 'work_alpha',
        subfolder: PhotoSubfolder.posters,
        fileKey: 'w500_abc12345.jpg',
      );
      expect(hit, equals(pngBytes));

      // 模拟非分档专辑封面未命中：稳定返回 null，不误触发目录遍历异常。
      final albumMiss = await photos.readArtwork(
        workId: 'work_alpha',
        subfolder: PhotoSubfolder.thumbnails,
        fileKey: 'album_cover_deadbeef.bin',
      );
      expect(albumMiss, isNull);

      // 模拟外部直接在磁盘新建作品目录（不经 PhotosStorage.writeArtwork），依靠根目录 mtime 失效自动发现。
      await Future<void>.delayed(const Duration(milliseconds: 25));
      final externalDir = Directory(
        p.join(
          photos.resolveRootDirectory().path,
          '外部作品 [work_ext]',
          'posters',
        ),
      );
      await externalDir.create(recursive: true);
      await File(p.join(externalDir.path, 'w500_ext001.jpg'))
          .writeAsBytes(pngBytes, flush: true);

      final extHit = await photos.readArtwork(
        workId: 'work_ext',
        subfolder: PhotoSubfolder.posters,
        fileKey: 'w500_ext001.jpg',
      );
      expect(extHit, equals(pngBytes));

      // 删除作品后缓存同步失效。
      await photos.deleteWorkPhotos('work_alpha');
      final afterDelete = await photos.readArtwork(
        workId: 'work_alpha',
        subfolder: PhotoSubfolder.posters,
        fileKey: 'w500_abc12345.jpg',
      );
      expect(afterDelete, isNull);
    });

    test('TmdbService.readCachedImageBytes 零网络客户端命中缓存并保留显式本地路径读取', () async {
      final posterBytes = Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6]);
      const tmdbPath = '/sample_poster_999.jpg';
      final key = ArtworkCache.buildSizedKey(TmdbImageSize.w500, tmdbPath);
      await artworkCache.write(
        key,
        posterBytes,
        owner: 'work_cached',
        quality: TmdbImageSize.w500.qualityRank,
        subfolder: PhotoSubfolder.posters,
      );

      final fromCache = await TmdbService.readCachedImageBytes(
        tmdbPath,
        artworkCache: artworkCache,
        size: TmdbImageSize.w500,
        ownerWorkId: 'work_cached',
        subfolder: PhotoSubfolder.posters,
      );
      expect(fromCache, equals(posterBytes));

      // 未命中的单段 TMDB 路径不会误查驱动器根目录，直接返回 null。
      final miss = await TmdbService.readCachedImageBytes(
        '/not_cached_anywhere.jpg',
        artworkCache: artworkCache,
        size: TmdbImageSize.w500,
        ownerWorkId: 'work_cached',
        subfolder: PhotoSubfolder.posters,
      );
      expect(miss, isNull);

      // 显式本地绝对路径与 file:// URI 均正常直读。
      final localImg = File(p.join(tempRoot.path, 'custom_cover.png'));
      final localBytes = Uint8List.fromList(<int>[9, 8, 7, 6]);
      await localImg.writeAsBytes(localBytes, flush: true);

      final fromAbsPath = await TmdbService.readCachedImageBytes(
        localImg.path,
        artworkCache: artworkCache,
      );
      expect(fromAbsPath, equals(localBytes));

      final fromFileUri = await TmdbService.readCachedImageBytes(
        localImg.uri.toString(),
        artworkCache: artworkCache,
      );
      expect(fromFileUri, equals(localBytes));
    });
  });

  group('4. Riverpod 3.5.0 契约、关闭自动重试与路由压栈 Pause/Resume 安全', () {
    test('konataNoProviderRetry 严格阻止 Riverpod 3 自动重试放大', () async {
      expect(konataNoProviderRetry(0, StateError('boom')), isNull);

      var attempts = 0;
      final failingProvider = FutureProvider<int>((ref) async {
        attempts++;
        throw StateError('simulated_network_error');
      });

      final container = ProviderContainer(retry: konataNoProviderRetry);
      addTearDown(container.dispose);

      await expectLater(
        container.read(failingProvider.future),
        throwsA(isA<StateError>()),
      );
      // 等待超过 Riverpod 3 默认 200ms 首次退避窗口，确认绝不发生第二次重试。
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(attempts, equals(1));
    });

    test('KonataValueNotifier 支持初始值工厂、读写与函数式 update', () {
      final counterProvider = NotifierProvider<KonataValueNotifier<int>, int>(
        () => KonataValueNotifier<int>(() => 10),
      );
      final fixedProvider =
          NotifierProvider<KonataValueNotifier<String>, String>(
            () => KonataValueNotifier<String>.value('init'),
          );

      final container = ProviderContainer(retry: konataNoProviderRetry);
      addTearDown(container.dispose);

      expect(container.read(counterProvider), equals(10));
      expect(container.read(fixedProvider), equals('init'));

      container.read(counterProvider.notifier).state = 20;
      expect(container.read(counterProvider), equals(20));

      final next = container.read(counterProvider.notifier).update((v) => v + 5);
      expect(next, equals(25));
      expect(container.read(counterProvider), equals(25));
    });

    testWidgets('次级路由覆盖导致底层页面 Pause 后，后台音频状态更新不丢且返回后立即恢复同步', (
      tester,
    ) async {
      final navKey = GlobalKey<NavigatorState>();
      var homeBuilds = 0;

      await tester.pumpWidget(
        ProviderScope(
          retry: konataNoProviderRetry,
          overrides: [
            audioPlaybackProvider.overrideWith(
              () => _ControllableAudioNotifier(
                const AudioPlaybackState(
                  isActive: true,
                  isPlaying: true,
                  positionSeconds: 10,
                  durationSeconds: 200,
                ),
              ),
            ),
          ],
          child: MaterialApp(
            navigatorKey: navKey,
            home: Consumer(
              builder: (context, ref, _) {
                homeBuilds++;
                final pos = ref.watch(
                  audioPlaybackProvider.select((s) => s.positionSeconds),
                );
                return Scaffold(body: Text('home-pos:${pos.toInt()}'));
              },
            ),
          ),
        ),
      );

      expect(find.text('home-pos:10'), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp)),
      );
      final notifier =
          container.read(audioPlaybackProvider.notifier)
              as _ControllableAudioNotifier;

      // 推入不透明次级路由，底层首页进入后台（Riverpod 3 自动暂停其依赖订阅）。
      unawaited(
        navKey.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('detail-page')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('detail-page'), findsOneWidget);

      final buildsBeforeBackgroundTick = homeBuilds;
      notifier.advancePosition(42);
      notifier.advancePosition(88);
      await tester.pump();

      // 底层被遮挡页面未因后台进度产生多余重建，但控制器最新状态完整保留。
      expect(homeBuilds, equals(buildsBeforeBackgroundTick));
      expect(container.read(audioPlaybackProvider).positionSeconds, equals(88));

      // 返回首页后 Riverpod 3 自动恢复订阅并立刻渲染最新进度。
      navKey.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.text('home-pos:88'), findsOneWidget);
    });
  });
}

class _ControllableAudioNotifier extends AudioPlaybackNotifier {
  _ControllableAudioNotifier(AudioPlaybackState seed)
    : super(initialState: seed);

  void advancePosition(double seconds) {
    state = state.copyWith(positionSeconds: seconds);
  }
}
