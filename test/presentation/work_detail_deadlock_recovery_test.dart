import 'dart:io';

import 'package:ccplayer/application/providers/artwork_provider.dart';
import 'package:ccplayer/application/providers/library_providers.dart';
import 'package:ccplayer/application/providers/scraping_providers.dart';
import 'package:ccplayer/application/providers/source_actions_provider.dart';
import 'package:ccplayer/application/providers/work_management_provider.dart';
import 'package:ccplayer/domain/models/episode.dart';
import 'package:ccplayer/domain/models/media_source.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/domain/models/network_config.dart';
import 'package:ccplayer/domain/models/playback_record.dart';
import 'package:ccplayer/domain/models/tmdb_models.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/domain/scraping/bangumi_models.dart';
import 'package:ccplayer/infrastructure/database/drift_library_repository.dart';
import 'package:ccplayer/infrastructure/database/konata_database.dart';
import 'package:ccplayer/presentation/detail/work_detail_page.dart';
import 'package:ccplayer/presentation/dialogs/manual_match_dialog.dart';
import 'package:ccplayer/presentation/history/playback_history_page.dart';
import 'package:ccplayer/presentation/shell/window_controls.dart';
import 'package:ccplayer/presentation/theme/konata_theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final Uint8List _transparentPng = Uint8List.fromList(const [
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

class _FakeKonataActionsCoordinator extends KonataActionsCoordinator {
  _FakeKonataActionsCoordinator(super.ref);

  @override
  Future<List<TmdbSearchResult>> searchTmdbInteractive(
    String query, {
    int? year,
  }) async {
    return const [
      TmdbSearchResult(
        tmdbId: 100565,
        mediaType: TmdbMediaType.tv,
        title: '86 -不存在的战区-',
        originalTitle: '86―エイティシックス―',
        year: 2021,
      ),
    ];
  }

  @override
  Future<List<BangumiSubjectCandidate>> searchBangumiInteractive(
    String query,
  ) async {
    return const [
      BangumiSubjectCandidate(
        id: 302189,
        name: '86―エイティシックス―',
        nameCn: '86 -不存在的战区-',
        year: 2021,
      ),
    ];
  }
}

class _FakeMergeScrapeController extends ScrapeController {
  _FakeMergeScrapeController(
    super.ref, {
    required this.onInvalidateWork,
    required this.repo,
    required this.mergedTargetWork,
  });

  final void Function(String workId) onInvalidateWork;
  final DriftLibraryRepository repo;
  final Work mergedTargetWork;

  @override
  Future<Work> rebindWork({
    required String workId,
    required int tmdbId,
    required TmdbMediaType mediaType,
    bool writeIdToFolderName = false,
    bool resetManualLocks = false,
  }) async {
    // 模拟重绑定命中库内同词条作品触发合并并删除旧 temp workId。
    await repo.deleteWork(workId);
    onInvalidateWork(workId);
    return mergedTargetWork;
  }
}

void main() {
  group('WorkDetailPage 合并衔接与防死锁兜底回归', () {
    late Directory tempRoot;
    late KonataDatabase db;
    late DriftLibraryRepository repo;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tempRoot = await Directory.systemTemp.createTemp('konata_detail_lock_');
      db = KonataDatabase(NativeDatabase.memory());
      repo = DriftLibraryRepository(db);
    });

    tearDown(() async {
      await db.close();
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    testWidgets(
      '1. 合并/重绑路由衔接：从 Hero 人工匹配或整部合并触发并入已有作品后自动无缝切入存活目标页，零未找到黑屏',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 820);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        await repo.upsertMediaSource(
          MediaSource(
            id: 'src_local',
            kind: MediaSourceKind.local,
            label: 'Local',
            location: tempRoot.path,
          ),
        );
        const tempWork = Work(
          id: 'temp-work-1',
          title: 'EIGHTY SIX 临时',
          scrapeStatus: ScrapeStatus.needsReview,
          reviewReason: '待手动确认匹配',
        );
        const existing86 = Work(
          id: 'existing-work-86',
          title: '86 -不存在的战区-',
          originalTitle: '86―エイティシックス―',
          tmdbId: 100565,
          tmdbMediaType: TmdbMediaType.tv,
          bangumiId: 302189,
          year: 2021,
          scrapeStatus: ScrapeStatus.matched,
        );
        await repo.upsertWork(tempWork);
        await repo.upsertWork(existing86);
        await repo.upsertEpisode(
          const Episode(
            id: 'ep-existing-1',
            workId: 'existing-work-86',
            seasonNumber: 1,
            episodeNumber: 1,
            category: EpisodeCategory.main,
            title: 'Undertaker',
          ),
        );
        await repo.upsertMediaVariant(
          const MediaVariant(
            id: 'var-temp-sp',
            workId: 'temp-work-1',
            sourceId: 'src_local',
            relativePath: 'EIGHTY SIX/SP/NCOP.mkv',
            fileName: 'NCOP.mkv',
            fileSize: 100,
          ),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              libraryRepositoryProvider.overrideWithValue(repo),
              tmdbImageLoaderProvider.overrideWithValue(
                (_, {targetWidth, imageSize}) async => _transparentPng,
              ),
              tmdbNetworkConfigProvider.overrideWith(
                (_) async => const TmdbNetworkConfig(credential: 'test-tmdb-key'),
              ),
              konataActionsProvider.overrideWith(
                (ref) => _FakeKonataActionsCoordinator(ref),
              ),
              scrapeControllerProvider.overrideWith(
                (ref) => _FakeMergeScrapeController(
                  ref,
                  onInvalidateWork: (id) =>
                      ref.invalidate(workDetailBundleProvider(id)),
                  repo: repo,
                  mergedTargetWork: existing86,
                ),
              ),
            ],
            child: MaterialApp(
              locale: const Locale('zh', 'CN'),
              supportedLocales: const [Locale('zh', 'CN')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              theme: KonataTheme.darkTheme(),
              home: const WorkDetailPage(workId: 'temp-work-1'),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('EIGHTY SIX 临时'), findsOneWidget);
        // 通过 Hero 区「确认匹配」打开手动纠错弹窗
        await tester.tap(find.text('确认匹配'));
        await tester.pumpAndSettle();

        // 搜索 TMDB 并选择返回命中，触发合并进 existing-work-86（temp-work-1 已删除）
        await tester.tap(
          find.descendant(
            of: find.byType(ManualMatchDialog),
            matching: find.text('搜索'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('86 -不存在的战区-').last);
        await tester.pumpAndSettle();

        // 应直接无缝切换展示 existing-work-86 详情页，绝不出现空状态黑屏
        expect(find.text('86 -不存在的战区-'), findsWidgets);
        expect(find.text('未找到该作品记录'), findsNothing);
        expect(find.text('该作品记录已变更或移除'), findsNothing);
      },
    );

    testWidgets(
      '1b. 合并重定向守卫：执行 mergeWorkIntoExisting 移除旧 workId 后详情页自动重定向至存活目标页',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 820);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        await repo.upsertMediaSource(
          MediaSource(
            id: 'src_local',
            kind: MediaSourceKind.local,
            label: 'Local',
            location: tempRoot.path,
          ),
        );
        await repo.upsertWork(
          const Work(id: 'temp-work-1', title: '待合并旧条目'),
        );
        await repo.upsertWork(
          const Work(
            id: 'existing-work-86',
            title: '86 -不存在的战区-',
            scrapeStatus: ScrapeStatus.matched,
          ),
        );
        await repo.upsertMediaVariant(
          const MediaVariant(
            id: 'v-old',
            workId: 'temp-work-1',
            sourceId: 'src_local',
            relativePath: '86/SP01.mkv',
            fileName: 'SP01.mkv',
            fileSize: 512,
          ),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              libraryRepositoryProvider.overrideWithValue(repo),
              tmdbImageLoaderProvider.overrideWithValue(
                (_, {targetWidth, imageSize}) async => _transparentPng,
              ),
              tmdbNetworkConfigProvider.overrideWith(
                (_) async => const TmdbNetworkConfig(credential: 'test-tmdb-key'),
              ),
            ],
            child: MaterialApp(
              locale: const Locale('zh', 'CN'),
              supportedLocales: const [Locale('zh', 'CN')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              theme: KonataTheme.darkTheme(),
              home: const WorkDetailPage(workId: 'temp-work-1'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('待合并旧条目'), findsOneWidget);

        final container = ProviderScope.containerOf(
          tester.element(find.byType(WorkDetailPage)),
        );
        await container.read(workManagementProvider).mergeWorkIntoExisting(
          sourceWorkId: 'temp-work-1',
          targetWorkId: 'existing-work-86',
          forceCategory: EpisodeCategory.extra,
        );
        await tester.pumpAndSettle();

        expect(find.text('86 -不存在的战区-'), findsOneWidget);
        expect(find.text('该作品记录已变更或移除'), findsNothing);
      },
    );

    testWidgets(
      '2. 兜底空状态防死锁：不存在的 workId 保留返回键/窗口控制区/Esc，三种方式均可安全退回上一路由',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 820);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        Future<void> pumpHostWithRoute(
          ThemeData theme, {
          bool presetDrawerExpanded = false,
        }) async {
          await tester.pumpWidget(
            ProviderScope(
              key: ValueKey('${theme.brightness}_$presetDrawerExpanded'),
              overrides: [
                libraryRepositoryProvider.overrideWithValue(repo),
                tmdbImageLoaderProvider.overrideWithValue(
                  (_, {targetWidth, imageSize}) async => _transparentPng,
                ),
                tmdbNetworkConfigProvider.overrideWith(
                  (_) async => const TmdbNetworkConfig(),
                ),
                detailDrawerExpandedProvider.overrideWith(
                  (_) => presetDrawerExpanded,
                ),
              ],
              child: MaterialApp(
                locale: const Locale('zh', 'CN'),
                supportedLocales: const [Locale('zh', 'CN')],
                localizationsDelegates: GlobalMaterialLocalizations.delegates,
                theme: theme,
                home: Builder(
                  builder: (ctx) => Scaffold(
                    body: Center(
                      child: ElevatedButton(
                        onPressed: () {
                          Navigator.of(ctx).push(
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  const WorkDetailPage(workId: 'missing-id'),
                            ),
                          );
                        },
                        child: const Text('OPEN_DETAIL'),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
        }

        await pumpHostWithRoute(KonataTheme.darkTheme());

        // 场景 A：点击中央主操作按钮「返回媒体库」
        await tester.tap(find.text('OPEN_DETAIL'));
        await tester.pumpAndSettle();
        expect(find.text('该作品记录已变更或移除'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('work_detail_back_button')),
          findsOneWidget,
        );
        expect(find.byType(WindowControls), findsOneWidget);
        await tester.tap(find.text('返回媒体库'));
        await tester.pumpAndSettle();
        expect(find.text('OPEN_DETAIL'), findsOneWidget);

        // 场景 B：点击左上角磨砂返回按钮 `<`
        await tester.tap(find.text('OPEN_DETAIL'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('work_detail_back_button')));
        await tester.pumpAndSettle();
        expect(find.text('OPEN_DETAIL'), findsOneWidget);

        // 场景 C：亮色主题 + detailDrawerExpandedProvider 曾为 true 时按 Esc 也能直接退回
        await pumpHostWithRoute(
          KonataTheme.lightTheme(),
          presetDrawerExpanded: true,
        );
        await tester.tap(find.text('OPEN_DETAIL'));
        await tester.pumpAndSettle();
        expect(find.text('该作品记录已变更或移除'), findsOneWidget);
        expect(find.byType(WindowControls), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('OPEN_DETAIL'), findsOneWidget);
      },
    );

    testWidgets('3. 播放记录点击已删除作品条目时提示拦截且不跳入空白死页', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            libraryRepositoryProvider.overrideWithValue(repo),
            tmdbImageLoaderProvider.overrideWithValue(
              (_, {targetWidth, imageSize}) async => _transparentPng,
            ),
            playbackHistoryProvider.overrideWith(
              (_) => [
                PlaybackRecord(
                  id: 'rec-stale',
                  workId: 'missing-work-99',
                  episodeId: 'ep-stale',
                  variantId: 'var-stale',
                  seasonNumber: 1,
                  episodeNumber: 1,
                  episodeTitle: '第 1 话',
                  sourceType: MediaSourceKind.local,
                  playedAt: DateTime.utc(2026),
                  positionSeconds: 120,
                  durationSeconds: 1440,
                ),
              ],
            ),
          ],
          child: MaterialApp(
            locale: const Locale('zh', 'CN'),
            supportedLocales: const [Locale('zh', 'CN')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            theme: KonataTheme.darkTheme(),
            home: const Scaffold(body: PlaybackHistoryPage()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.textContaining('观看至'));
      await tester.pumpAndSettle();

      expect(find.byType(WorkDetailPage), findsNothing);
      expect(find.text('该作品记录已变更或被移出媒体库'), findsOneWidget);
    });
  });
}
