import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ccplayer/application/providers/artwork_provider.dart';
import 'package:ccplayer/application/providers/library_providers.dart';
import 'package:ccplayer/application/providers/scraping_providers.dart';
import 'package:ccplayer/application/providers/theme_providers.dart';
import 'package:ccplayer/application/providers/work_management_provider.dart';
import 'package:ccplayer/domain/models/episode.dart';
import 'package:ccplayer/domain/models/media_source.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/domain/models/network_config.dart';
import 'package:ccplayer/domain/models/tmdb_models.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/infrastructure/database/drift_library_repository.dart';
import 'package:ccplayer/infrastructure/database/konata_database.dart';
import 'package:ccplayer/presentation/detail/detail_hero_info.dart';
import 'package:ccplayer/presentation/detail/episode_drawer_card.dart';
import 'package:ccplayer/presentation/detail/inline_expandable_synopsis.dart';
import 'package:ccplayer/presentation/dialogs/source_files_review_dialog.dart';
import 'package:ccplayer/presentation/dialogs/work_artwork_picker_dialog.dart';
import 'package:ccplayer/presentation/library/review_work_item_card.dart';
import 'package:ccplayer/presentation/settings/settings_network_panel.dart';
import 'package:ccplayer/presentation/theme/konata_theme.dart';
import 'package:ccplayer/presentation/widgets/design_system/ellipsis_text_with_tooltip.dart';
import 'package:ccplayer/presentation/widgets/design_system/konata_surface_card.dart';

final Uint8List _transparentPng = Uint8List.fromList([
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

Widget _wrapApp(
  Widget child, {
  Key? scopeKey,
  List<Override> overrides = const [],
}) {
  return ProviderScope(
    key: scopeKey,
    overrides: [
      tmdbImageLoaderProvider.overrideWithValue(
        (_, {targetWidth, imageSize}) async => _transparentPng,
      ),
      ...overrides,
    ],
    child: Consumer(
      builder: (context, ref, _) {
        final mode = ref.watch(themeModeProvider);
        return MaterialApp(
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          theme: KonataTheme.lightTheme(),
          darkTheme: KonataTheme.darkTheme(),
          themeMode: mode,
          home: Scaffold(body: child),
        );
      },
    ),
  );
}

class _FakeArtworkWorkManagement extends WorkManagementActions {
  _FakeArtworkWorkManagement(super.ref, this.options);

  final WorkArtworkOptions options;

  @override
  Future<WorkArtworkOptions> fetchWorkArtworkOptions(
    Work work, {
    bool includeLogos = false,
  }) async => options;
}

void main() {
  group('阶段 1~2 UI 细节打磨与交互回归测试', () {
    testWidgets('EllipsisTextWithTooltip 仅在真正省略截断时挂载 350ms 悬停 Tooltip', (
      tester,
    ) async {
      const longTitle = '轻音少女 K-ON!! 第二季 全24话 + 番外篇 特别收纳合集版';

      await tester.pumpWidget(
        _wrapApp(
          const Center(
            child: SizedBox(
              width: 900,
              child: EllipsisTextWithTooltip(
                text: longTitle,
                maxLines: 1,
                style: TextStyle(fontSize: 14),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Tooltip), findsNothing);

      await tester.pumpWidget(
        _wrapApp(
          const Center(
            child: SizedBox(
              width: 140,
              child: EllipsisTextWithTooltip(
                text: longTitle,
                maxLines: 1,
                style: TextStyle(fontSize: 14),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final tooltipFinder = find.byType(Tooltip);
      expect(tooltipFinder, findsOneWidget);
      final tooltip = tester.widget<Tooltip>(tooltipFinder);
      expect(tooltip.message, longTitle);
      expect(tooltip.waitDuration, const Duration(milliseconds: 350));
    });

    testWidgets('InlineExpandableSynopsis 无感内联拼接 展开/收起 且限制展开最大高度', (
      tester,
    ) async {
      final longOverview = List.generate(
        18,
        (i) => '第${i + 1}段：这是一段用于测试无感内联展开与高度保护的详情页动画作品简介文本。',
      ).join(' ');

      await tester.pumpWidget(
        _wrapApp(
          Center(
            child: SizedBox(
              width: 420,
              child: InlineExpandableSynopsis(
                text: longOverview,
                collapsedMaxLines: 3,
                maxExpandedHeight: 190,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('… 展开', findRichText: true), findsOneWidget);
      expect(find.textContaining(' 收起', findRichText: true), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
      expect(find.byType(ElevatedButton), findsNothing);

      final collapsedSize = tester.getSize(
        find.byType(InlineExpandableSynopsis),
      );

      await tester.tap(find.byType(InlineExpandableSynopsis));
      await tester.pumpAndSettle();

      expect(find.textContaining(' 收起', findRichText: true), findsOneWidget);
      expect(find.textContaining('第18段', findRichText: true), findsOneWidget);
      final expandedSize = tester.getSize(
        find.byType(InlineExpandableSynopsis),
      );
      expect(expandedSize.height, greaterThan(collapsedSize.height));
      expect(expandedSize.height, lessThanOrEqualTo(192));

      await tester.tap(find.byType(InlineExpandableSynopsis));
      await tester.pumpAndSettle();
      expect(find.textContaining('… 展开', findRichText: true), findsOneWidget);
    });

    testWidgets('DetailHeroInfo 改用 Bangumi 评分且 EpisodeDrawerCard 移除源类型标签', (
      tester,
    ) async {
      const workWithScore = Work(
        id: 'w-hero-1',
        title: '葬送的芙莉莲',
        year: 2023,
        bangumiScore: 8.64,
        voteAverage: 8.9,
        tmdbMediaType: TmdbMediaType.tv,
        overview: '勇者一行人打倒魔王之后的旅途故事。',
      );
      const workNoScore = Work(
        id: 'w-hero-2',
        title: '未评分测试作',
        year: 2022,
        voteAverage: 7.5,
      );
      const episode = Episode(
        id: 'ep-1',
        workId: 'w-hero-1',
        seasonNumber: 1,
        episodeNumber: 1,
        category: EpisodeCategory.main,
        title: '冒险的终点与漫长旅程的序幕（超长分集标题测试）',
      );
      const variant = MediaVariant(
        id: 'v-webdav-1',
        workId: 'w-hero-1',
        episodeId: 'ep-1',
        sourceId: 'src-wd',
        relativePath: 'Frieren/[VCB-Studio] Frieren [01].mkv',
        fileName: '[VCB-Studio] Frieren [01][Ma10p_1080p].mkv',
        fileSize: 1024 * 1024 * 600,
        releaseGroup: 'VCB-Studio',
      );

      await tester.pumpWidget(
        _wrapApp(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DetailHeroInfo(
                bundle: const WorkDetailBundle(
                  work: workWithScore,
                  episodes: [episode],
                  variants: [variant],
                  sourcesById: {},
                  latestPlayback: null,
                ),
                imageLoader: (_, {targetWidth, imageSize}) async => _transparentPng,
                onPrimaryPlay: () {},
              ),
              SizedBox(
                width: 300,
                child: EpisodeDrawerCard(
                  episode: episode,
                  variants: const [variant],
                  fallbackBackdropPath: null,
                  imageLoader: (_, {targetWidth, imageSize}) async =>
                      _transparentPng,
                  onTap: () {},
                  onAdjustSlot: () {},
                ),
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Bangumi 8.6'), findsOneWidget);
      expect(find.textContaining('TMDB'), findsNothing);
      expect(find.text('WebDAV'), findsNothing);
      expect(find.text('SMB'), findsNothing);
      expect(find.text('本地'), findsNothing);

      // 未命中 Bangumi 评分时优雅隐藏评分段且不回退显示 TMDB 评分
      await tester.pumpWidget(
        _wrapApp(
          DetailHeroInfo(
            bundle: const WorkDetailBundle(
              work: workNoScore,
              episodes: [episode],
              variants: [variant],
              sourcesById: {},
              latestPlayback: null,
            ),
            imageLoader: (_, {targetWidth, imageSize}) async => _transparentPng,
            onPrimaryPlay: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Bangumi'), findsNothing);
      expect(find.textContaining('TMDB'), findsNothing);
    });

    testWidgets('SettingsNetworkPanel 在宽/窄窗口间自适应双栏并排与单列回退', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);

      Future<void> pumpAtWidth(double width) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1.0;
        await tester.pumpWidget(
          _wrapApp(
            const SingleChildScrollView(
              padding: EdgeInsets.all(24),
              child: SettingsNetworkPanel(),
            ),
            overrides: [
              libraryRepositoryProvider.overrideWithValue(repo),
              tmdbNetworkConfigProvider.overrideWith(
                (_) async => const TmdbNetworkConfig(),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();
      }

      addTearDown(tester.view.resetPhysicalSize);

      // 宽屏 >= 760：TMDB 与 Bangumi 服务左右并排（比较所属卡片顶边严密对齐）
      await pumpAtWidth(1120);
      final tmdbCardTop = tester.getTopLeft(
        find.ancestor(
          of: find.text('TMDB 服务'),
          matching: find.byType(KonataSurfaceCard),
        ).first,
      );
      final bgmCardTop = tester.getTopLeft(
        find.ancestor(
          of: find.text('Bangumi 服务'),
          matching: find.byType(KonataSurfaceCard),
        ).first,
      );
      expect(tmdbCardTop.dy, equals(bgmCardTop.dy));
      expect(bgmCardTop.dx, greaterThan(tmdbCardTop.dx));

      // 窄屏 < 760：自动回退为上下单列堆叠
      await pumpAtWidth(680);
      final tmdbNarrow = tester.getTopLeft(find.text('TMDB 服务'));
      final bgmNarrow = tester.getTopLeft(find.text('Bangumi 服务'));
      expect(bgmNarrow.dy, greaterThan(tmdbNarrow.dy));
    });

    testWidgets('待复核卡片单行按钮、矢量展开箭头与查看源文件搜索/多选拆作面板', (
      tester,
    ) async {
      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);

      const source = MediaSource(
        id: 'src-rev-1',
        kind: MediaSourceKind.webdav,
        label: '客厅 NAS WebDAV',
        location: 'https://nas.local/anime',
      );
      await repo.upsertMediaSource(source);

      const work = Work(
        id: 'w-review-1',
        title: '侦探歌剧 少女福尔摩斯 特别合集超长命名作品标题',
        scrapeStatus: ScrapeStatus.needsReview,
        reviewReason: '多版本置信度接近，需人工核对',
      );
      await repo.upsertWork(work);

      const v1 = MediaVariant(
        id: 'rv-1',
        workId: 'w-review-1',
        sourceId: 'src-rev-1',
        relativePath: 'Milky/OVA/Milky Holmes Alternative ONE.mkv',
        fileName: 'Milky Holmes Alternative ONE.mkv',
        fileSize: 520 * 1024 * 1024,
      );
      const v2 = MediaVariant(
        id: 'rv-2',
        workId: 'w-review-1',
        sourceId: 'src-rev-1',
        relativePath: 'Milky/OVA/Milky Holmes Alternative TWO.mkv',
        fileName: 'Milky Holmes Alternative TWO.mkv',
        fileSize: 540 * 1024 * 1024,
      );
      await repo.upsertMediaVariant(v1);
      await repo.upsertMediaVariant(v2);

      final item = WorkLibraryItem(
        work: work,
        variants: const [v1, v2],
        episodeCount: 0,
        releaseGroups: const [],
      );

      final capturedSelection = <MediaVariant>[];

      await tester.pumpWidget(
        _wrapApp(
          Center(
            child: SizedBox(
              width: 460,
              child: ReviewWorkItemCard(item: item),
            ),
          ),
          overrides: [
            libraryRepositoryProvider.overrideWithValue(repo),
            tmdbNetworkConfigProvider.overrideWith(
              (_) async => const TmdbNetworkConfig(),
            ),
            workScrapeCandidatesProvider(work.id).overrideWith(
              (_) async => const [
                ScrapeCandidateSummary(
                  workId: 'w-review-1',
                  tmdbId: 70010,
                  mediaType: TmdbMediaType.tv,
                  title: '侦探歌剧 少女福尔摩斯',
                  score: 0.72,
                  rank: 1,
                ),
                ScrapeCandidateSummary(
                  workId: 'w-review-1',
                  tmdbId: 70011,
                  mediaType: TmdbMediaType.tv,
                  title: '侦探歌剧 少女福尔摩斯 特别篇',
                  score: 0.68,
                  rank: 2,
                ),
              ],
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // 矢量图标替代硬编码 ⌄ / ⌃ 字符，且抽屉宽度下四枚按钮处于同一行
      expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsOneWidget);
      expect(find.text('展开候选 (2)'), findsOneWidget);
      expect(find.textContaining('⌄'), findsNothing);
      expect(find.textContaining('⌃'), findsNothing);
      expect(find.text('查看源文件'), findsOneWidget);

      final searchBtnY = tester.getCenter(find.text('手动搜索')).dy;
      final dismissBtnY = tester.getCenter(find.text('忽略复核')).dy;
      final hideBtnY = tester.getCenter(find.text('隐藏作品')).dy;
      final toggleBtnY = tester.getCenter(find.text('展开候选 (2)')).dy;
      expect((searchBtnY - dismissBtnY).abs(), lessThan(2.0));
      expect((searchBtnY - hideBtnY).abs(), lessThan(2.0));
      expect((searchBtnY - toggleBtnY).abs(), lessThan(2.0));

      // 打开查看源文件检视弹窗验证过滤与单多选/全选绑定触发
      await tester.pumpWidget(
        _wrapApp(
          Builder(
            builder: (context) => SourceFilesReviewDialog(
              item: item,
              onBindSelected: (selected) async {
                capturedSelection
                  ..clear()
                  ..addAll(selected);
              },
            ),
          ),
          scopeKey: const ValueKey('source-files-review-scope'),
          overrides: [
            libraryRepositoryProvider.overrideWithValue(repo),
            mediaSourcesProvider.overrideWith((_) async => const [source]),
            workDetailBundleProvider(work.id).overrideWith(
              (_) async => const WorkDetailBundle(
                work: work,
                episodes: [],
                variants: [v1, v2],
                sourcesById: {'src-rev-1': source},
                latestPlayback: null,
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Milky Holmes Alternative ONE.mkv'), findsOneWidget);
      expect(find.text('Milky Holmes Alternative TWO.mkv'), findsOneWidget);
      expect(find.text('将所选文件绑定为独立作品 (0)'), findsOneWidget);

      // 关键词搜索过滤只保留 ONE
      await tester.enterText(find.byType(TextField).first, 'ONE');
      await tester.pumpAndSettle();
      expect(find.text('Milky Holmes Alternative ONE.mkv'), findsOneWidget);
      expect(find.text('Milky Holmes Alternative TWO.mkv'), findsNothing);

      // 选中该文件并触发绑定回调
      await tester.tap(find.text('Milky Holmes Alternative ONE.mkv'));
      await tester.pumpAndSettle();
      expect(find.text('将所选文件绑定为独立作品 (1)'), findsOneWidget);

      await tester.tap(find.text('将所选文件绑定为独立作品 (1)'));
      await tester.pumpAndSettle();
      expect(capturedSelection.map((v) => v.id).toList(), ['rv-1']);
    });

    testWidgets('WorkArtworkPickerDialog 候选封面/背景图右下角显示真实像素分辨率', (
      tester,
    ) async {
      const work = Work(
        id: 'w-art-1',
        title: '视觉分辨率验证作品',
        tmdbId: 209867,
        tmdbMediaType: TmdbMediaType.tv,
        bangumiId: 400602,
      );
      const options = WorkArtworkOptions(
        posters: [
          WorkArtworkOption(
            filePath: '/poster_2000x3000.jpg',
            sourceLabel: 'TMDB',
            width: 2000,
            height: 3000,
          ),
        ],
        backdrops: [
          WorkArtworkOption(
            filePath: '/backdrop_4k.jpg',
            sourceLabel: 'TMDB',
            width: 3840,
            height: 2160,
          ),
        ],
      );

      await tester.pumpWidget(
        _wrapApp(
          const WorkArtworkPickerDialog(
            key: ValueKey('poster-picker'),
            work: work,
            kind: WorkArtworkKind.poster,
          ),
          overrides: [
            workManagementProvider.overrideWith(
              (ref) => _FakeArtworkWorkManagement(ref, options),
            ),
            tmdbNetworkConfigProvider.overrideWith(
              (_) async => const TmdbNetworkConfig(),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('2000×3000'), findsOneWidget);

      await tester.pumpWidget(
        _wrapApp(
          const WorkArtworkPickerDialog(
            key: ValueKey('backdrop-picker'),
            work: work,
            kind: WorkArtworkKind.backdrop,
          ),
          overrides: [
            workManagementProvider.overrideWith(
              (ref) => _FakeArtworkWorkManagement(ref, options),
            ),
            tmdbNetworkConfigProvider.overrideWith(
              (_) async => const TmdbNetworkConfig(),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('3840×2160'), findsOneWidget);
    });
  });
}
