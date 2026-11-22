import 'dart:typed_data';

import 'package:konata/application/providers/artwork_provider.dart';
import 'package:konata/application/providers/library_providers.dart';
import 'package:konata/application/providers/scraping_providers.dart';
import 'package:konata/application/providers/work_management_provider.dart';
import 'package:konata/domain/models/fanart_models.dart';
import 'package:konata/domain/models/managed_artwork.dart';
import 'package:konata/domain/models/media_source.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/models/tmdb_models.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/infrastructure/network/fanart_service.dart';
import 'package:konata/presentation/dialogs/work_artwork_picker_dialog.dart';
import 'package:konata/presentation/library/poster_card.dart';
import 'package:konata/presentation/theme/konata_theme.dart';
import 'package:material_ui/material_ui.dart';
import 'package:konata/application/providers/konata_value_notifier.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 最小合法 1×1 透明 PNG 字节流，确保组件测试零网络零磁盘。
final Uint8List _kTransparentPng = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

class _FakeWorkManagementActions extends WorkManagementActions {
  _FakeWorkManagementActions(super.ref, this.options);

  final WorkArtworkOptions options;
  String? savedPosterPath;
  String? savedBackdropPath;

  @override
  Future<WorkArtworkOptions> fetchWorkArtworkOptions(
    Work work, {
    bool includeLogos = false,
  }) async => options;

  @override
  Future<void> updateWorkArtwork({
    required String workId,
    String? posterPath,
    String? backdropPath,
    String? logoPath,
  }) async {
    savedPosterPath = posterPath;
    savedBackdropPath = backdropPath;
  }
}

void main() {
  group('海报墙跨来源右上角角标渲染与单源静默规则', () {
    testWidgets('仅当不同来源存在相同作品卡片时才在海报右上角显示来源角标，单源唯一卡保持纯净', (
      tester,
    ) async {
      const frierenLocal = WorkLibraryItem(
        work: Work(
          id: 'w_local_frieren',
          title: '葬送的芙莉莲',
          tmdbId: 209867,
          tmdbMediaType: TmdbMediaType.tv,
          matchedSeason: 1,
          scrapeStatus: ScrapeStatus.matched,
        ),
        variants: [
          MediaVariant(
            id: 'v1',
            workId: 'w_local_frieren',
            sourceId: 'src_local',
            relativePath: 'Frieren/01.mkv',
            fileName: '01.mkv',
            fileSize: 100,
          ),
        ],
        episodeCount: 28,
        maxEpisodeVariantCount: 2,
        releaseGroups: ['VCB-Studio'],
        sourceIds: ['src_local'],
        primarySourceKind: MediaSourceKind.local,
        primarySourceLabel: '本地磁盘',
      );
      const frierenWebdav = WorkLibraryItem(
        work: Work(
          id: 'w_dav_frieren',
          title: '葬送的芙莉莲',
          tmdbId: 209867,
          tmdbMediaType: TmdbMediaType.tv,
          matchedSeason: 1,
          scrapeStatus: ScrapeStatus.matched,
        ),
        variants: [
          MediaVariant(
            id: 'v2',
            workId: 'w_dav_frieren',
            sourceId: 'src_dav',
            relativePath: 'Frieren/01.mkv',
            fileName: '01.mkv',
            fileSize: 100,
          ),
        ],
        episodeCount: 28,
        releaseGroups: ['Snow-Raws'],
        sourceIds: ['src_dav'],
        primarySourceKind: MediaSourceKind.webdav,
        primarySourceLabel: 'NAS WebDAV',
      );
      const uniqueBocchi = WorkLibraryItem(
        work: Work(
          id: 'w_local_bocchi',
          title: '孤独摇滚！',
          tmdbId: 200474,
          tmdbMediaType: TmdbMediaType.tv,
          matchedSeason: 1,
          scrapeStatus: ScrapeStatus.matched,
        ),
        variants: [
          MediaVariant(
            id: 'v3',
            workId: 'w_local_bocchi',
            sourceId: 'src_local',
            relativePath: 'Bocchi/01.mkv',
            fileName: '01.mkv',
            fileSize: 100,
          ),
        ],
        episodeCount: 12,
        releaseGroups: ['VCB-Studio'],
        sourceIds: ['src_local'],
        primarySourceKind: MediaSourceKind.local,
        primarySourceLabel: '本地磁盘',
      );

      final annotated = annotateCrossSourceBadges(const [
        frierenLocal,
        frierenWebdav,
        uniqueBocchi,
      ]);
      expect(annotated[0].crossSourceBadgeLabel, '本地');
      expect(annotated[1].crossSourceBadgeLabel, 'WebDAV');
      expect(annotated[2].crossSourceBadgeLabel, isNull);

      final dummyLoader = bindManagedArtworkLoader((
        String path, {
        int? targetWidth,
        TmdbImageSize? imageSize,
        String? ownerWorkId,
        ManagedArtwork? artwork,
      }) async => _kTransparentPng);

      await tester.pumpWidget(
        MaterialApp(
          theme: KonataTheme.darkTheme(),
          home: Scaffold(
            body: Row(
              children: [
                for (final item in annotated)
                  SizedBox(
                    width: 180,
                    height: 300,
                    child: PosterCard(
                      item: item,
                      imageLoader: dummyLoader,
                      onTap: () {},
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('poster_source_badge_w_local_frieren')),
        findsOneWidget,
      );
      expect(find.text('本地'), findsOneWidget);
      expect(find.text('2版本'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('poster_source_badge_w_dav_frieren')),
        findsOneWidget,
      );
      expect(find.text('WebDAV'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('poster_source_badge_w_local_bocchi')),
        findsNothing,
      );
    });
  });

  group('WorkArtworkPickerDialog 封面与背景图多源整合、/preview/ 预览与零落盘校验', () {
    testWidgets('封面弹窗渲染 Bangumi/TMDB/Fanart.tv·S1 与 1000×1426，预览走 /preview/ 且 owner 为 null，应用落盘原图', (
      tester,
    ) async {
      const work = Work(
        id: 'w_frieren',
        title: '葬送的芙莉莲',
        tmdbId: 209867,
        tmdbMediaType: TmdbMediaType.tv,
        bangumiId: 400602,
        tvdbId: 424536,
        matchedSeason: 1,
      );
      const fanartS1Original =
          'https://assets.fanart.tv/fanart/tv/424536/seasonposter/s1_p.jpg';
      final fanartS1Preview = FanartUrlHelper.toPreviewUrl(fanartS1Original);
      final fakeOptions = WorkArtworkOptions(
        posters: [
          const WorkArtworkOption(
            filePath: 'https://lain.bgm.tv/pic/cover/l/bgm.jpg',
            sourceLabel: 'Bangumi',
            isBangumi: true,
            width: 800,
            height: 1200,
          ),
          WorkArtworkOption(
            filePath: fanartS1Original,
            previewPath: fanartS1Preview,
            sourceLabel: 'Fanart.tv·S1',
            isFanart: true,
            isSeasonPoster: true,
            width: 1000,
            height: 1426,
          ),
          const WorkArtworkOption(
            filePath: '/tmdb_main.jpg',
            sourceLabel: 'TMDB',
            width: 1000,
            height: 1500,
          ),
        ],
      );

      final loadedCalls = <({String path, String? owner})>[];
      late _FakeWorkManagementActions fakeActions;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            fanartRelayHealthProvider.overrideWith(
              () => KonataValueNotifier.value(FanartRelayHealthSnapshot.ok),
            ),
            workManagementProvider.overrideWith((ref) {
              fakeActions = _FakeWorkManagementActions(ref, fakeOptions);
              return fakeActions;
            }),
            tmdbImageLoaderProvider.overrideWithValue(
              bindManagedArtworkLoader((
                String path, {
                int? targetWidth,
                TmdbImageSize? imageSize,
                String? ownerWorkId,
                ManagedArtwork? artwork,
              }) async {
                loadedCalls.add((path: path, owner: ownerWorkId));
                return _kTransparentPng;
              }),
            ),
          ],
          child: MaterialApp(
            theme: KonataTheme.darkTheme(),
            home: const Scaffold(
              body: WorkArtworkPickerDialog(
                work: work,
                kind: WorkArtworkKind.poster,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Bangumi / TMDB / Fanart.tv 候选封面 (3)'),
        findsOneWidget,
      );
      expect(find.text('Fanart.tv·S1'), findsOneWidget);
      expect(find.text('1000×1426'), findsOneWidget);
      // 网格预览全部走 /preview/ 且 owner 强制为 null（仅内存缓存，零 photos/ 落盘污染）
      expect(
        loadedCalls.any(
          (c) => c.path == fanartS1Preview && c.owner == null,
        ),
        isTrue,
      );
      expect(
        loadedCalls.any((c) => c.path == fanartS1Original),
        isFalse,
      );

      // 选中 Fanart.tv·S1 并点击「应用选中图片」，确认写回的是原图 /fanart/ URL
      await tester.tap(find.text('Fanart.tv·S1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('应用选中图片'));
      await tester.pumpAndSettle();
      expect(fakeActions.savedPosterPath, fanartS1Original);
    });

    testWidgets('背景图弹窗显示 TMDB / Fanart.tv 候选背景图、1920×1080 并使用 /preview/ 缩略图', (
      tester,
    ) async {
      const work = Work(
        id: 'w_frieren_bg',
        title: '葬送的芙莉莲',
        tmdbId: 209867,
        tmdbMediaType: TmdbMediaType.tv,
        tvdbId: 424536,
      );
      const fanartBgOriginal =
          'https://assets.fanart.tv/fanart/tv/424536/showbackground/bg1.jpg';
      final fanartBgPreview = FanartUrlHelper.toPreviewUrl(fanartBgOriginal);
      final fakeOptions = WorkArtworkOptions(
        backdrops: [
          const WorkArtworkOption(
            filePath: '/tmdb_bg_1080.jpg',
            sourceLabel: 'TMDB',
            width: 1920,
            height: 1080,
          ),
          WorkArtworkOption(
            filePath: fanartBgOriginal,
            previewPath: fanartBgPreview,
            sourceLabel: 'Fanart.tv',
            isFanart: true,
            width: 1920,
            height: 1080,
          ),
        ],
      );

      final loadedCalls = <({String path, String? owner})>[];
      late _FakeWorkManagementActions fakeActions;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            fanartRelayHealthProvider.overrideWith(
              () => KonataValueNotifier.value(FanartRelayHealthSnapshot.ok),
            ),
            workManagementProvider.overrideWith((ref) {
              fakeActions = _FakeWorkManagementActions(ref, fakeOptions);
              return fakeActions;
            }),
            tmdbImageLoaderProvider.overrideWithValue(
              bindManagedArtworkLoader((
                String path, {
                int? targetWidth,
                TmdbImageSize? imageSize,
                String? ownerWorkId,
                ManagedArtwork? artwork,
              }) async {
                loadedCalls.add((path: path, owner: ownerWorkId));
                return _kTransparentPng;
              }),
            ),
          ],
          child: MaterialApp(
            theme: KonataTheme.darkTheme(),
            home: const Scaffold(
              body: WorkArtworkPickerDialog(
                work: work,
                kind: WorkArtworkKind.backdrop,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('TMDB / Fanart.tv 候选背景图 (2)'), findsOneWidget);
      expect(find.text('Fanart.tv'), findsOneWidget);
      expect(find.text('1920×1080'), findsNWidgets(2));
      expect(
        loadedCalls.any(
          (c) => c.path == fanartBgPreview && c.owner == null,
        ),
        isTrue,
      );

      await tester.tap(find.text('Fanart.tv'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('应用选中图片'));
      await tester.pumpAndSettle();
      expect(fakeActions.savedBackdropPath, fanartBgOriginal);
    });
  });
}
