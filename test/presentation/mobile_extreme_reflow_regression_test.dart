import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:konata/application/playback/audio_playback_notifier.dart';
import 'package:konata/application/playback/video_playback_controller.dart';
import 'package:konata/application/providers/artwork_provider.dart';
import 'package:konata/application/providers/library_providers.dart';
import 'package:konata/application/providers/scraping_providers.dart';
import 'package:konata/application/scraping/scrape_progress.dart';
import 'package:konata/domain/models/episode.dart';
import 'package:konata/domain/models/media_source.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/models/network_config.dart';
import 'package:konata/domain/models/playback_record.dart';
import 'package:konata/domain/models/series_group.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/domain/playback/playback_probe_stats.dart';
import 'package:konata/infrastructure/cache/photos_storage.dart';
import 'package:konata/infrastructure/database/drift_library_repository.dart';
import 'package:konata/infrastructure/database/konata_database.dart';
import 'package:konata/infrastructure/storage/storage_root_provider.dart';
import 'package:konata/presentation/audio/mini_audio_bar.dart';
import 'package:konata/presentation/detail/work_detail_page.dart';
import 'package:konata/presentation/dialogs/series_manage_dialog.dart';
import 'package:konata/presentation/library/review_dialog.dart';
import 'package:konata/presentation/shell/desktop_shell.dart';
import 'package:konata/presentation/sources/scan_progress_dialog.dart';
import 'package:konata/presentation/sources/tmdb_scrape_guard.dart';
import 'package:konata/presentation/theme/konata_theme.dart';
import 'package:konata/presentation/video/embedded_video_page.dart';

final Uint8List _testPng1x1 = Uint8List.fromList(const <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
  0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0x00, 0x00,
  0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

class _ExtremeViewportSpec {
  const _ExtremeViewportSpec({
    required this.label,
    required this.size,
    required this.textScale,
  });

  final String label;
  final Size size;
  final double textScale;
}

const List<_ExtremeViewportSpec> _viewportMatrix = <_ExtremeViewportSpec>[
  _ExtremeViewportSpec(
    label: '320x568@1.25x',
    size: Size(320, 568),
    textScale: 1.25,
  ),
  _ExtremeViewportSpec(
    label: '360x800@1.30x',
    size: Size(360, 800),
    textScale: 1.30,
  ),
  _ExtremeViewportSpec(
    label: '800x360@1.15x',
    size: Size(800, 360),
    textScale: 1.15,
  ),
  _ExtremeViewportSpec(
    label: '600x960@1.00x',
    size: Size(600, 960),
    textScale: 1.00,
  ),
];

class _StubVideoController extends VideoPlaybackController {
  _StubVideoController(super.request)
    : super(
        deferBootstrap: true,
        initialState: VideoPlaybackState(
          isInitializing: false,
          isBuffering: false,
          hasFirstFrame: true,
          isPlaying: true,
          currentWork: request.work,
          currentBundle: request.bundle,
          currentEpisode: request.episode,
          currentVariant: request.variant,
          durationSeconds: 1440.0,
          positionSeconds: 120.0,
          probeStats: const PlaybackProbeStats(
            videoWidth: 1920,
            videoHeight: 1080,
          ),
        ),
      );
}

class _ActiveAudioNotifier extends AudioPlaybackNotifier {
  _ActiveAudioNotifier() : super(initialState: _buildInitial());

  static AudioPlaybackState _buildInitial() {
    const work = Work(id: 'w_1', title: '葬送的芙莉莲原声音乐集');
    const variant = MediaVariant(
      id: 'v_cd_1',
      workId: 'w_1',
      sourceId: 'src_1',
      relativePath: 'CD/01.flac',
      fileName: '01.flac',
      fileSize: 32 * 1024 * 1024,
      assetKind: AssetKind.cdAlbum,
    );
    const track = AudioQueueItem(
      id: 'trk_1',
      title: '勇者与旅途的终章交响变奏曲',
      albumTitle: 'Frieren Original Soundtrack Vol.1',
      work: work,
      variant: variant,
    );
    return const AudioPlaybackState(
      isActive: true,
      isPlaying: true,
      queue: [track],
      currentIndex: 0,
      durationSeconds: 240,
      positionSeconds: 30,
    );
  }
}

class _FixedScrapeController extends ScrapeController {
  _FixedScrapeController()
    : super(
        initialState: const ScrapeProgress(
          phase: ScrapePhase.scraping,
          sourceId: 'src_1',
          sourceLabel: 'NAS 动画归档盘',
          processedWorks: 3,
          totalWorks: 12,
          matchedWorks: 3,
          reviewWorks: 1,
          scannedDirectories: 42,
          foundFiles: 184,
          currentItemName: '[VCB-Studio] Sousou no Frieren [Ma10p_1080p][01].mkv',
          folderVideoCounts: {'新番连载/葬送的芙莉莲': 12, '剧场版归档/轻音少女': 1},
          completedFolders: {'新番连载/葬送的芙莉莲', '剧场版归档/轻音少女'},
        ),
      );
}

Future<DriftLibraryRepository> _seedRealisticDatabase(
  KonataDatabase db,
) async {
  final repo = DriftLibraryRepository(db);
  const src = MediaSource(
    id: 'src_1',
    label: 'NAS 主番剧媒体源存储仓库目录',
    kind: MediaSourceKind.webdav,
    location: 'https://nas.example.com/dav/AnimeCollection/TV',
  );
  await repo.upsertMediaSource(src);

  final series = SeriesGroup(
    id: 'ser_1',
    title: '加速世界全系列典藏编组',
    createdAt: DateTime(2026, 11, 18),
    updatedAt: DateTime(2026, 11, 18),
  );
  await repo.upsertSeriesGroup(series);

  const work1 = Work(
    id: 'w_1',
    title: '葬送的芙莉莲：超越勇者终章的悠长旅途',
    originalTitle: '葬送のフリーレン',
    overview:
        '打倒魔王之后凯旋的勇者一行人迎来了各自的人生终点。身为精灵的魔法使芙莉莲在昔日同伴离世后，'
        '开始重新踏上了解人类情感与生命意义的旅程。',
    year: 2023,
    tmdbId: 209867,
    tmdbMediaType: TmdbMediaType.tv,
    bangumiScore: 8.6,
    scrapeStatus: ScrapeStatus.needsReview,
    reviewReason: '目录中同时包含多个压制组封装版本，请人工核对剧集顺序。',
    seriesId: 'ser_1',
    seriesOrder: 1,
    seriesLabel: '第 1 季',
  );
  const work2 = Work(
    id: 'w_2',
    title: '加速世界：无限超频剧场版特别篇',
    originalTitle: 'アクセル・ワールド INFINITE BURST',
    year: 2016,
    tmdbId: 390112,
    tmdbMediaType: TmdbMediaType.movie,
    bangumiScore: 6.4,
    scrapeStatus: ScrapeStatus.matched,
    seriesId: 'ser_1',
    seriesOrder: 2,
    seriesLabel: '剧场版',
  );
  await repo.upsertWork(work1);
  await repo.upsertWork(work2);

  const ep1 = Episode(
    id: 'ep_1',
    workId: 'w_1',
    category: EpisodeCategory.main,
    seasonNumber: 1,
    episodeNumber: 1,
    title: '冒险的终点',
  );
  const epExtra = Episode(
    id: 'ep_extra_1',
    workId: 'w_1',
    category: EpisodeCategory.extra,
    seasonNumber: 0,
    episodeNumber: 1,
    extraType: ExtraKind.ncop,
    title: '无字幕片头曲',
  );
  await repo.upsertEpisode(ep1);
  await repo.upsertEpisode(epExtra);

  const v1 = MediaVariant(
    id: 'v_1',
    workId: 'w_1',
    episodeId: 'ep_1',
    sourceId: 'src_1',
    relativePath: 'Frieren/[VCB-Studio] Frieren [01][Ma10p_1080p][x265_flac].mkv',
    fileName: '[VCB-Studio] Frieren [01][Ma10p_1080p][x265_flac].mkv',
    fileSize: 980 * 1024 * 1024,
    assetKind: AssetKind.video,
  );
  const v2 = MediaVariant(
    id: 'v_extra_1',
    workId: 'w_1',
    episodeId: 'ep_extra_1',
    sourceId: 'src_1',
    relativePath: 'Frieren/SP/[VCB-Studio] Frieren [NCOP][1080p].mkv',
    fileName: '[VCB-Studio] Frieren [NCOP][1080p].mkv',
    fileSize: 120 * 1024 * 1024,
    assetKind: AssetKind.video,
  );
  await repo.upsertMediaVariant(v1);
  await repo.upsertMediaVariant(v2);

  await repo.recordPlayback(
    PlaybackRecord(
      id: 'rec_1',
      workId: 'w_1',
      episodeId: 'ep_1',
      variantId: 'v_1',
      seasonNumber: 1,
      episodeNumber: 1,
      episodeTitle: '冒险的终点',
      sourceType: MediaSourceKind.webdav,
      playedAt: DateTime(2026, 11, 18, 9, 30),
      positionSeconds: 420,
      durationSeconds: 1440,
    ),
  );

  return repo;
}

/// 遍历完整渲染树，检查零 Overflow 且严禁出现长中文文本被挤成每行仅 1~2 个字的竖排畸形折行。
void _assertZeroOverflowAndNoChineseVerticalSqueeze(
  WidgetTester tester, {
  required String scenario,
}) {
  final rootView = tester.binding.renderViews.first;
  void visit(RenderObject obj) {
    if (obj is RenderParagraph && obj.attached && obj.hasSize) {
      final size = obj.size;
      if (size.width > 0 && size.height > 0) {
        final rawText = obj.text.toPlainText().trim();
        final cjkCount = RegExp(r'[\u4e00-\u9fff]').allMatches(rawText).length;
        if (cjkCount >= 4 && obj.maxLines != 1) {
          final painter = TextPainter(
            text: obj.text,
            textDirection: obj.textDirection,
            textScaler: obj.textScaler,
            maxLines: obj.maxLines,
            ellipsis: obj.overflow == TextOverflow.ellipsis ? '\u2026' : null,
            locale: obj.locale,
          )..layout(maxWidth: size.width);
          final metrics = painter.computeLineMetrics();
          if (metrics.length >= 3) {
            final nonSpaceCount = rawText.replaceAll(RegExp(r'\s+'), '').length;
            final avgCharsPerLine = nonSpaceCount / metrics.length;
            if (avgCharsPerLine <= 2.0) {
              fail(
                '[$scenario] 检测到畸形中文竖排挤压 (行数=${metrics.length}, '
                '每行均字=${avgCharsPerLine.toStringAsFixed(2)}, 宽度=${size.width.toStringAsFixed(1)}): "$rawText"',
              );
            }
          }
          painter.dispose();
        }
      }
    }
    obj.visitChildren(visit);
  }

  visit(rootView);
}

Widget _wrapViewportApp(
  Widget child, {
  required double textScale,
  required List<Override> overrides,
  bool wrapWithAudioOverlay = false,
}) {
  return ProviderScope(
    key: UniqueKey(),
    overrides: overrides,
    child: MaterialApp(
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: KonataTheme.darkTheme(),
      builder: (context, inner) {
        final content = wrapWithAudioOverlay
            ? MiniAudioOverlayHost(child: inner!)
            : inner!;
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: const EdgeInsets.fromLTRB(0, 24, 0, 16),
            textScaler: TextScaler.linear(textScale),
          ),
          child: content,
        );
      },
      home: child,
    ),
  );
}

void main() {
  group('极端窄屏 + 放大字号全端防回归与零竖排挤压巡检', () {
    for (final spec in _viewportMatrix) {
      testWidgets('核心主页、二级设置、详情页、关键弹窗与播放器全量巡检 (${spec.label})', (
        tester,
      ) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        tester.view.physicalSize = spec.size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        SharedPreferences.setMockInitialValues({});
        final storageRoot = StorageRootService();
        final photos = PhotosStorage(storageRoot: storageRoot);
        final db = KonataDatabase(NativeDatabase.memory());
        addTearDown(() async => tester.runAsync(db.close));
        final repo = await tester.runAsync(() => _seedRealisticDatabase(db));

        final overrides = <Override>[
          storageRootProvider.overrideWithValue(storageRoot),
          photosStorageProvider.overrideWithValue(photos),
          libraryRepositoryProvider.overrideWithValue(repo!),
          tmdbNetworkConfigProvider.overrideWith(
            (_) async => const TmdbNetworkConfig(),
          ),
          tmdbImageLoaderProvider.overrideWithValue(
            (_, {targetWidth, imageSize}) async => _testPng1x1,
          ),
          audioPlaybackProvider.overrideWith(_ActiveAudioNotifier.new),
          scrapeControllerProvider.overrideWith(_FixedScrapeController.new),
        ];

        Future<void> runPhase(
          String phase,
          Future<void> Function() action,
        ) async {
          final prevOnError = FlutterError.onError;
          final capturedErrors = <FlutterErrorDetails>[];
          FlutterError.onError = (details) {
            capturedErrors.add(details);
          };
          try {
            await action();
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 350));
          } finally {
            FlutterError.onError = prevOnError;
          }
          for (final err in capturedErrors) {
            final msg = err.toString();
            fail('[${spec.label} / $phase] 触发布局或运行时异常:\n$msg');
          }
          _assertZeroOverflowAndNoChineseVerticalSqueeze(
            tester,
            scenario: '${spec.label} / $phase',
          );
        }

        try {
          // 1. DesktopShell 含媒体库 + 媒体源 + 播放记录 + 设置（含二级面板）
          await runPhase('媒体库主页', () async {
            await tester.pumpWidget(
              _wrapViewportApp(
                const DesktopShell(),
                textScale: spec.textScale,
                overrides: overrides,
                wrapWithAudioOverlay: true,
              ),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 400));
          });

          await runPhase('媒体源页', () async {
            await tester.tap(find.byTooltip('媒体源'));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 350));
          });

          await runPhase('播放记录页', () async {
            await tester.tap(find.byTooltip('播放记录'));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 350));
          });

          await runPhase('设置主页面', () async {
            await tester.tap(find.byTooltip('设置'));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 350));
          });

          // 窄屏下验证一级分类与二级面板逐一巡检
          for (final catLabel in const [
            '外观',
            '显示',
            '刮削与网络',
            '播放器',
            '关于',
          ]) {
            await runPhase('设置-$catLabel', () async {
              final finder = find.text(catLabel);
              final listViews = find.byType(ListView);
              for (
                var step = 0;
                step < 6 &&
                    finder.evaluate().isEmpty &&
                    listViews.evaluate().isNotEmpty;
                step++
              ) {
                await tester.drag(
                  listViews.first,
                  const Offset(0, -180),
                );
                await tester.pump();
                await tester.pump(const Duration(milliseconds: 200));
              }
              final target = finder.first;
              await tester.ensureVisible(target);
              await tester.tap(target);
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 350));
            });
            final backBtn = find.byKey(const ValueKey('settings_detail_back'));
            if (backBtn.evaluate().isNotEmpty) {
              await tester.tap(backBtn.first);
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 350));
            }
          }

          // 2. 作品详情页（覆盖手机竖屏网易爆米花封面流 / 横屏平齐顶栏 / 平板态）
          await runPhase('作品详情页', () async {
            await tester.pumpWidget(
              _wrapViewportApp(
                const WorkDetailPage(workId: 'w_1'),
                textScale: spec.textScale,
                overrides: overrides,
                wrapWithAudioOverlay: true,
              ),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 400));
            if (find.textContaining('冒险的终点').evaluate().isEmpty) {
              final mainTab = find.textContaining('正片');
              if (mainTab.evaluate().isNotEmpty) {
                await tester.tap(mainTab.first);
                await tester.pump();
                await tester.pump(const Duration(milliseconds: 350));
              }
            }
          });

          // 3. 系列编组弹窗（重现并防范原竖排单字挤压）
          late WorkDetailBundle loadedBundle;
          await runPhase('管理系列编组弹窗', () async {
            await tester.pumpWidget(
              _wrapViewportApp(
                Consumer(
                  builder: (_, ref, _) {
                    final b = ref
                        .watch(workDetailBundleProvider('w_1'))
                        .value;
                    if (b == null) {
                      return const SizedBox.shrink();
                    }
                    loadedBundle = b;
                    return Scaffold(
                      body: Center(
                        child: SeriesManageDialog(bundle: b),
                      ),
                    );
                  },
                ),
                textScale: spec.textScale,
                overrides: overrides,
              ),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 400));
          });

          // 4. 实时刮削进度弹窗
          await runPhase('扫描与刮削进度弹窗', () async {
            await tester.pumpWidget(
              _wrapViewportApp(
                const Scaffold(
                  body: Center(child: ScanProgressDialog()),
                ),
                textScale: spec.textScale,
                overrides: overrides,
              ),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 350));
          });

          // 5. 待复核队列弹窗
          await runPhase('待复核队列弹窗', () async {
            await tester.pumpWidget(
              _wrapViewportApp(
                const Scaffold(
                  body: Center(child: ReviewDialog()),
                ),
                textScale: spec.textScale,
                overrides: overrides,
              ),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 350));
          });

          // 6. TMDB 未配置拦截弹窗
          await runPhase('TMDB未配置提示弹窗', () async {
            await tester.pumpWidget(
              _wrapViewportApp(
                Scaffold(
                  body: Consumer(
                    builder: (ctx, ref, _) => Center(
                      child: ElevatedButton(
                        onPressed: () =>
                            ensureTmdbConfiguredForScrape(ctx, ref),
                        child: const Text('触发检验'),
                      ),
                    ),
                  ),
                ),
                textScale: spec.textScale,
                overrides: overrides,
              ),
            );
            await tester.pump();
            await tester.tap(find.text('触发检验'));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 350));
            expect(find.text('TMDB API 未配置'), findsOneWidget);
          });

          // 7. 内置全屏视频播放器控制 HUD（竖矮/宽视口均不溢出）
          await runPhase('内置播放器HUD', () async {
            final req = VideoLaunchRequest(
              work: loadedBundle.work,
              bundle: loadedBundle,
              episode: loadedBundle.episodes.first,
              variant: loadedBundle.variants.first,
            );
            await tester.pumpWidget(
              _wrapViewportApp(
                EmbeddedVideoPage(request: req),
                textScale: spec.textScale,
                overrides: [
                  ...overrides,
                  videoPlaybackProvider(req).overrideWith(
                    () => _StubVideoController(req),
                  ),
                ],
              ),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 400));
          });
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  });
}
