import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:ccplayer/application/providers/konata_value_notifier.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ccplayer/application/playback/audio_playback_notifier.dart';
import 'package:ccplayer/application/playback/playback_preferences_provider.dart';
import 'package:ccplayer/application/playback/unified_playback_coordinator.dart';
import 'package:ccplayer/application/playback/video_playback_controller.dart';
import 'package:ccplayer/application/providers/artwork_provider.dart';
import 'package:ccplayer/application/providers/library_providers.dart';
import 'package:ccplayer/application/providers/source_actions_provider.dart';
import 'package:ccplayer/application/scraping/scrape_compute_worker.dart';
import 'package:ccplayer/application/scraping/scrape_orchestrator.dart';
import 'package:ccplayer/domain/formatting/network_error_sanitizer.dart';
import 'package:ccplayer/domain/models/episode.dart';
import 'package:ccplayer/domain/models/media_source.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/domain/models/network_config.dart';
import 'package:ccplayer/domain/models/playback_record.dart';
import 'package:ccplayer/domain/models/series_group.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/domain/repositories/file_system_gateway.dart';
import 'package:ccplayer/infrastructure/database/drift_library_repository.dart';
import 'package:ccplayer/infrastructure/database/konata_database.dart';
import 'package:ccplayer/infrastructure/logging/diagnostics_log_store.dart';
import 'package:ccplayer/infrastructure/network/bangumi_service.dart';
import 'package:ccplayer/infrastructure/network/priority_http_scheduler.dart';
import 'package:ccplayer/infrastructure/network/tmdb_http_client.dart';
import 'package:ccplayer/infrastructure/network/tmdb_service.dart';
import 'package:ccplayer/infrastructure/players/android/android_media_session_bridge.dart';
import 'package:ccplayer/presentation/audio/mini_audio_bar.dart';
import 'package:ccplayer/presentation/detail/detail_bottom_drawer.dart';
import 'package:ccplayer/presentation/detail/work_detail_page.dart';
import 'package:ccplayer/presentation/history/playback_history_page.dart';
import 'package:ccplayer/presentation/library/library_page.dart';
import 'package:ccplayer/presentation/shell/adaptive_capsule_layout.dart';
import 'package:ccplayer/presentation/sources/source_folder_picker_dialog.dart';
import 'package:ccplayer/presentation/sources/sources_page.dart';
import 'package:ccplayer/presentation/theme/konata_palette.dart';
import 'package:ccplayer/presentation/theme/konata_theme.dart';
import 'package:ccplayer/presentation/video/embedded_video_page.dart';
import 'package:ccplayer/presentation/video/video_cutout_symmetry.dart';
import 'package:ccplayer/presentation/widgets/playback/konata_playback_capsule.dart';
import 'package:ccplayer/presentation/widgets/playback/konata_volume_control.dart';

final Uint8List _sample1x1Png = Uint8List.fromList(const <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
  0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0x00, 0x00,
  0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

class _HierarchicalPickerActions extends KonataActionsCoordinator {
  _HierarchicalPickerActions(super.ref);

  @override
  Future<List<RemoteEntry>> listSourceDirectory(
    MediaSource source,
    String relativePath,
  ) async {
    if (relativePath == 'Anime') {
      return const [
        RemoteEntry(
          name: 'Frieren',
          relativePath: 'Anime/Frieren',
          isDirectory: true,
        ),
        RemoteEntry(
          name: 'Bocchi',
          relativePath: 'Anime/Bocchi',
          isDirectory: true,
        ),
      ];
    }
    return const [
      RemoteEntry(name: 'Anime', relativePath: 'Anime', isDirectory: true),
      RemoteEntry(name: 'Movies', relativePath: 'Movies', isDirectory: true),
    ];
  }
}

class _FakeWebDavGateway implements MediaSourceGateway {
  @override
  Future<String?> testConnection() async => null;

  @override
  Future<List<RemoteEntry>> listDirectory(String relativePath) async {
    switch (relativePath) {
      case '':
        return const [
          RemoteEntry(
            name: '葬送的芙莉莲',
            relativePath: '葬送的芙莉莲',
            isDirectory: true,
          ),
          RemoteEntry(
            name: '孤独摇滚',
            relativePath: '孤独摇滚',
            isDirectory: true,
          ),
        ];
      case '葬送的芙莉莲':
        return const [
          RemoteEntry(
            name: '[BDRip] Frieren - 01 [1080p].mkv',
            relativePath: '葬送的芙莉莲/[BDRip] Frieren - 01 [1080p].mkv',
            isDirectory: false,
            size: 800 * 1024 * 1024,
          ),
        ];
      case '孤独摇滚':
        return const [
          RemoteEntry(
            name: '[BDRip] Bocchi - 01 [1080p].mkv',
            relativePath: '孤独摇滚/[BDRip] Bocchi - 01 [1080p].mkv',
            isDirectory: false,
            size: 780 * 1024 * 1024,
          ),
        ];
      default:
        return const [];
    }
  }

  @override
  Future<String?> readTextFile(
    String relativePath, {
    int maxBytes = 256 * 1024,
  }) async => null;

  @override
  Future<void> close() async {}
}

class _StubAudioNotifier extends AudioPlaybackNotifier {
  _StubAudioNotifier(
    AudioPlaybackState initial, {
    super.mediaSessionBridge,
  }) : super(initialState: initial);

  double? lastSeekSeconds;
  bool? lastSetPlaying;
  int previousCount = 0;
  int nextCount = 0;

  @override
  Future<void> setPlaying(bool playing) async {
    lastSetPlaying = playing;
    state = state.copyWith(isPlaying: playing);
  }

  @override
  Future<void> togglePlayPause() async {
    await setPlaying(!state.isPlaying);
  }

  @override
  Future<void> previous() async {
    previousCount++;
  }

  @override
  Future<void> next() async {
    nextCount++;
  }

  @override
  Future<void> seekRelativeTrackSeconds(double trackSeconds) async {
    lastSeekSeconds = trackSeconds;
    state = state.copyWith(positionSeconds: trackSeconds);
  }
}

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
          positionSeconds: 120,
          durationSeconds: 1420,
        ),
      );

  @override
  bool get hasPreviousEpisodeAny => true;

  @override
  bool get hasNextEpisodeAny => true;

  @override
  Future<void> closeAndRelease() async {
    state = state.copyWith(isClosing: true);
  }
}

Widget _wrapApp(
  Widget home, {
  List<Override> overrides = const [],
  EdgeInsets padding = EdgeInsets.zero,
  EdgeInsets viewPadding = EdgeInsets.zero,
  ThemeMode themeMode = ThemeMode.dark,
}) {
  return ProviderScope(
    key: UniqueKey(),
    overrides: overrides,
    child: MaterialApp(
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: KonataTheme.lightTheme(),
      darkTheme: KonataTheme.darkTheme(),
      themeMode: themeMode,
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(padding: padding, viewPadding: viewPadding),
          child: home,
        ),
      ),
    ),
  );
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final Uint8List posterPng = _sample1x1Png;
  final Uint8List backdropPng = _sample1x1Png;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  group('第三轮 30 项全端 UI 精修与播放器/扫描闭环防回归验证', () {
    testWidgets(
      '模块一（问题 01-04, 09）：媒体源顶栏图文胶囊、目录弹窗精简标题与管理入口、手机横屏左右双栏及根目录交互',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        SharedPreferences.setMockInitialValues({});

        final source = MediaSource(
          id: 'src_dav',
          label: 'dav (192.168.1.192)',
          kind: MediaSourceKind.webdav,
          location: 'http://192.168.1.192:5244/dav',
          createdAt: DateTime(2026, 5, 1),
        );

        // 1. 手机竖屏：媒体源管理页顶栏恢复「+ 添加媒体源」图文胶囊并同行垂直居中
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          _wrapApp(
            const SourcesPage(),
            overrides: [
              mediaSourcesProvider.overrideWith((_) async => [source]),
            ],
          ),
        );
        await tester.pumpAndSettle();

        final titleRect = tester.getRect(find.text('媒体源管理'));
        final addBtnRect = tester.getRect(find.text('添加媒体源'));
        expect((titleRect.center.dy - addBtnRect.center.dy).abs(), lessThan(8));

        // 2. 手机竖屏：目录选择弹窗标题仅显示源名称、入口文案「已选目录 · N（点击管理）」、问号右对齐且无行末 ×
        await tester.pumpWidget(
          _wrapApp(
            Scaffold(body: SourceFolderPickerDialog(source: source)),
            overrides: [
              konataActionsProvider.overrideWith(
                (ref) => _HierarchicalPickerActions(ref),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('dav (192.168.1.192)'), findsOneWidget);
        expect(find.textContaining('浏览与多选目录'), findsNothing);

        // 根路径三态复选框点击触发全选
        final rootCheckbox = find.byTooltip('全选或取消全选根路径下的全部目录');
        expect(rootCheckbox, findsOneWidget);
        await tester.tap(rootCheckbox);
        await tester.pump();
        expect(find.text('已选目录 · 2（点击管理）'), findsOneWidget);

        // 进入子目录 Anime，点击路径栏「根目录」立即跳回根路径
        await tester.tap(find.text('Anime'));
        await tester.pumpAndSettle();
        expect(find.text('Frieren'), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('source_picker_root_crumb')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Movies'), findsOneWidget);

        // 进入整窗管理视图：说明问号图标靠最右对齐，且移除每行独立 × 删除按钮
        await tester.tap(
          find.byKey(const ValueKey('source_selected_scope_entry')),
        );
        await tester.pumpAndSettle();
        final helpRect = tester.getRect(
          find.byKey(const ValueKey('source_scope_help_button')),
        );
        final batchRect = tester.getRect(find.text('反选'));
        expect(helpRect.left, greaterThan(batchRect.right));
        expect(find.byTooltip('取消选择该目录'), findsNothing);

        // 3. 手机横屏：内联右上搜索框 + 左栏浏览目录 / 右栏常驻已选目录管理左右双栏
        tester.view.physicalSize = const Size(844, 390);
        await tester.pumpWidget(
          _wrapApp(
            Scaffold(body: SourceFolderPickerDialog(source: source)),
            overrides: [
              konataActionsProvider.overrideWith(
                (ref) => _HierarchicalPickerActions(ref),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final leftBrowse = tester.getRect(find.text('Movies'));
        final rightScope = tester.getRect(
          find.text('当前未勾选指定目录（默认扫描整源）'),
        );
        expect(leftBrowse.right, lessThanOrEqualTo(rightScope.left + 24));
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      },
    );

    test(
      '模块一（问题 24）：TMDB DNS 解析失败时扫描管线自动降级入库不中断，且全链路隐藏 api_key',
      () async {
        // 1. 验证正则脱敏与中文错误转译
        const rawLeak =
            "ClientException with SocketException: Failed host lookup: 'api.themoviedb.org' "
            '(OS Error: No address associated with hostname, errno = 7), '
            'uri=https://api.themoviedb.org/3/search/tv?api_key=9988776655secret&query=Frieren';
        final redacted = NetworkErrorSanitizer.redactSecrets(rawLeak);
        expect(redacted, isNot(contains('9988776655secret')));
        expect(redacted, contains('api_key=***'));

        final friendly = NetworkErrorSanitizer.toUserMessage(
          rawLeak,
          prefix: '扫描异常',
        );
        expect(friendly, isNot(contains('9988776655secret')));
        expect(friendly, contains('域名解析失败'));

        final logStore = DiagnosticsLogStore();
        logStore.record('tmdb', rawLeak, isError: true);
        final report = logStore.buildRecentIncidentReport();
        expect(report, isNot(contains('9988776655secret')));
        expect(report, contains('api_key=***'));

        // 2. 验证 WebDAV 多目录扫描遇到单部 TMDB DNS 失败时不中断整轮扫描，自动降级入库并标为待复核
        final db = KonataDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final repo = DriftLibraryRepository(db);
        final source = MediaSource(
          id: 'webdav_dns_test',
          label: 'WebDAV',
          kind: MediaSourceKind.webdav,
          location: 'http://192.168.1.192:5244/dav',
          createdAt: DateTime(2026, 5, 1),
        );
        await repo.upsertMediaSource(source);

        final mockHttp = MockClient((request) async {
          if (request.url.host.contains('themoviedb.org') ||
              request.url.host.contains('tmdb.org')) {
            throw const SocketException(
              "Failed host lookup: 'api.themoviedb.org'",
            );
          }
          // Bangumi 正常返回空列表，验证纯本地目录降级兜底同样不中断
          return http.Response(
            jsonEncode({'data': <Object>[]}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        });

        final tmdbClient = TmdbHttpClient(
          config: const TmdbNetworkConfig(credential: 'super_secret_tmdb_key'),
          scheduler: PriorityHttpScheduler(),
          httpClient: mockHttp,
        );
        final orchestrator = ScrapeOrchestrator(
          repository: repo,
          tmdbService: TmdbService(httpClient: tmdbClient),
          bangumiService: BangumiService(httpClient: tmdbClient),
          gatewayBuilder: (_) async => _FakeWebDavGateway(),
          computeWorker: const ScrapeComputeWorker(useIsolate: false),
        );

        await orchestrator.scanAndScrapeSource(source);

        final works = await repo.getAllWorks();
        expect(works, hasLength(2));
        for (final w in works) {
          expect(w.scrapeStatus, ScrapeStatus.needsReview);
        }
      },
    );

    testWidgets(
      '模块二（问题 10, 23）：媒体库「全部作品」顶栏默认单行合流、原地展开搜索与窄屏两级阶梯折行',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        SharedPreferences.setMockInitialValues({});

        final visibleItems = [
          for (var i = 0; i < 3; i++)
            WorkLibraryItem(
              work: Work(
                id: 'w_$i',
                title: '测试作品 $i',
                scrapeStatus: i == 0
                    ? ScrapeStatus.needsReview
                    : ScrapeStatus.matched,
              ),
              variants: const [],
              episodeCount: 12,
              releaseGroups: const [],
            ),
        ];
        const hiddenWorks = [
          Work(
            id: 'w_hidden',
            title: '隐藏作品',
            isHidden: true,
            scrapeStatus: ScrapeStatus.matched,
          ),
        ];

        // 1. 常规手机竖屏（412dp）：全部作品 + 计数胶囊 + [放大镜 -> 遮眼 -> 待复核] 单行合流且顺序正确
        tester.view.physicalSize = const Size(412, 892);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          _wrapApp(
            const LibraryPage(),
            overrides: [
              libraryItemsProvider.overrideWith((_) async => visibleItems),
              hiddenWorksProvider.overrideWith((_) async => hiddenWorks),
              tmdbImageLoaderProvider.overrideWithValue(
                (_, {targetWidth, imageSize}) async => posterPng,
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('library_header_second_row')),
          findsNothing,
        );
        final titleRect = tester.getRect(find.text('全部作品'));
        final countRect = tester.getRect(
          find.byKey(const ValueKey('library_works_count_pill')),
        );
        final searchRect = tester.getRect(
          find.byKey(const ValueKey('library_header_search_button')),
        );
        final hiddenRect = tester.getRect(
          find.byKey(const ValueKey('library_hidden_works_button')),
        );
        final reviewRect = tester.getRect(
          find.byKey(const ValueKey('library_review_pill')),
        );
        expect((titleRect.center.dy - searchRect.center.dy).abs(), lessThan(6));
        expect(countRect.left, greaterThan(titleRect.right - 2));
        expect(searchRect.right, lessThanOrEqualTo(hiddenRect.left + 2));
        expect(hiddenRect.right, lessThanOrEqualTo(reviewRect.left + 2));

        // 点击放大镜原位顶替首行展开搜索框，不产生多余空行
        await tester.tap(
          find.byKey(const ValueKey('library_header_search_button')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('library_header_search_row')),
          findsOneWidget,
        );
        expect(find.text('全部作品'), findsNothing);
        await tester.tap(
          find.byKey(const ValueKey('library_header_search_close')),
        );
        await tester.pumpAndSettle();

        // 2. 第一级窄屏降级：仅将计数胶囊下移至「全部作品」正下方，放大镜仍在首行
        tester.view.physicalSize = const Size(345, 800);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('library_header_second_row')),
          findsOneWidget,
        );
        final step1Title = tester.getRect(find.text('全部作品'));
        final step1Count = tester.getRect(
          find.byKey(const ValueKey('library_works_count_pill')),
        );
        final step1Search = tester.getRect(
          find.byKey(const ValueKey('library_header_search_button')),
        );
        expect(step1Count.top, greaterThanOrEqualTo(step1Title.bottom - 2));
        expect((step1Title.center.dy - step1Search.center.dy).abs(), lessThan(6));

        // 3. 第二级极端窄屏降级：计数胶囊在第二行左，搜索放大镜下移至第二行最右侧
        tester.view.physicalSize = const Size(256, 800);
        await tester.pumpAndSettle();
        final step2Title = tester.getRect(find.text('全部作品'));
        final step2Search = tester.getRect(
          find.byKey(const ValueKey('library_header_search_button')),
        );
        expect(step2Search.top, greaterThanOrEqualTo(step2Title.bottom - 2));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      },
    );

    testWidgets(
      '模块二（问题 05, 06, 08, 23）：播放记录五层排版、去「观看至」前缀、音频主色标题及横屏 108dp 等高封面',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        SharedPreferences.setMockInitialValues({});

        const work = Work(
          id: 'hist_work_1',
          title: '吹响吧！上低音号 第三季',
          posterPath: '/eupho.jpg',
          scrapeStatus: ScrapeStatus.matched,
        );
        const videoVar = MediaVariant(
          id: 'var_vid_1',
          workId: 'hist_work_1',
          episodeId: 'ep_1',
          sourceId: 'src_1',
          relativePath: 'Eupho/05.mkv',
          fileName: '05.mkv',
          fileSize: 500000000,
        );
        const audioVar = MediaVariant(
          id: 'var_aud_1',
          workId: 'hist_work_1',
          sourceId: 'src_1',
          relativePath: 'Eupho/CD/01 ReCoda.flac',
          fileName: '01 ReCoda.flac',
          fileSize: 32000000,
          assetKind: AssetKind.cdAlbum,
        );
        final videoRec = PlaybackRecord(
          id: 'rec_vid_1',
          workId: work.id,
          episodeId: 'ep_1',
          variantId: videoVar.id,
          seasonNumber: 3,
          episodeNumber: 5,
          episodeTitle: '两人黄昏',
          sourceType: MediaSourceKind.webdav,
          playedAt: DateTime(2026, 5, 18, 21, 30),
          positionSeconds: 1136,
          durationSeconds: 1421,
        );
        final audioRec = PlaybackRecord(
          id: '${PlaybackRecord.audioEpisodePrefix}track_1',
          workId: work.id,
          episodeId: '${PlaybackRecord.audioEpisodePrefix}track_1',
          variantId: audioVar.id,
          seasonNumber: 0,
          episodeNumber: 1,
          episodeTitle: 'ReCoda (TV Size)',
          sourceType: MediaSourceKind.webdav,
          playedAt: DateTime(2026, 5, 18, 21, 45),
          positionSeconds: 58,
          durationSeconds: 92,
        );

        // 1. 手机竖屏：无「观看至」前缀，右上角 ... 对齐第 1 行，音频作品名颜色与常规标题一致
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          _wrapApp(
            const PlaybackHistoryPage(),
            overrides: [
              playbackHistoryProvider.overrideWith(
                (_) async => [videoRec, audioRec],
              ),
              libraryItemsProvider.overrideWith(
                (_) async => const [
                  WorkLibraryItem(
                    work: work,
                    variants: [videoVar, audioVar],
                    episodeCount: 13,
                    releaseGroups: [],
                  ),
                ],
              ),
              tmdbImageLoaderProvider.overrideWithValue(
                (_, {targetWidth, imageSize}) async => posterPng,
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('观看至'), findsNothing);
        expect(find.text('18:56 / 23:41'), findsOneWidget);
        final videoTitleRect = tester.getRect(find.text('吹响吧！上低音号 第三季'));
        final moreBtnRect = tester.getRect(
          find.byKey(const ValueKey('history_more_rec_vid_1')),
        );
        expect(
          (moreBtnRect.top - videoTitleRect.top).abs(),
          lessThanOrEqualTo(8),
        );

        // 切换到音频记录页签：验证作品名采用常规 textPrimary 而非蓝色 accent
        await tester.tap(find.textContaining('音频'));
        await tester.pumpAndSettle();
        final audioWorkText = tester.widget<Text>(
          find.text('吹响吧！上低音号 第三季'),
        );
        const darkPal = KonataPalette.dark;
        expect(audioWorkText.style?.color, isNot(equals(darkPal.accent)));
        expect(audioWorkText.style?.color, equals(darkPal.textPrimary));

        // 2. 手机横屏：视频海报与音频 1:1 封面高度统一锚定在 108dp
        tester.view.physicalSize = const Size(844, 390);
        await tester.pumpAndSettle();
        final audioCoverSize = tester.getSize(
          find.byKey(ValueKey('history_audio_cover_${audioRec.id}')),
        );
        expect(audioCoverSize.height, closeTo(108.0, 0.5));
        expect(audioCoverSize.width, closeTo(108.0, 0.5));

        await tester.tap(find.textContaining('视频'));
        await tester.pumpAndSettle();
        final videoPosterSize = tester.getSize(
          find.byKey(ValueKey('history_video_cover_${videoRec.id}')),
        );
        expect(videoPosterSize.height, closeTo(108.0, 0.5));
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      },
    );

    testWidgets(
      '模块三（问题 11-13, 20, 22, 25）：详情页避让状态栏、同行播放与系列下拉、横屏滚动、二级等大卡片与可滚动齿轮菜单',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        SharedPreferences.setMockInitialValues({});

        final db = KonataDatabase(NativeDatabase.memory());
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          await tester.runAsync(db.close);
        });
        await tester.runAsync(() => db.customSelect('SELECT 1').get());
        final repo = DriftLibraryRepository(db);

        final seriesGroup = SeriesGroup(
          id: 'grp_frieren',
          title: '葬送的芙莉莲 系列',
          createdAt: DateTime(2026, 5, 1),
          updatedAt: DateTime(2026, 5, 1),
        );
        const s1 = Work(
          id: 'frieren_s1',
          title: '葬送的芙莉莲',
          seriesId: 'grp_frieren',
          seriesOrder: 1,
          seriesLabel: '第 1 季',
          matchedSeason: 1,
          backdropPath: '/bg.jpg',
          posterPath: '/poster.jpg',
          overview:
              '打倒魔王之后勇者一行人的后日谈奇幻物语，身为精灵魔法使的芙莉莲为了重新理解人类短暂却璀璨的一生，踏上了跨越千年的旅途与回忆。',
          scrapeStatus: ScrapeStatus.matched,
        );
        const s2 = Work(
          id: 'frieren_s2',
          title: '葬送的芙莉莲 第二季',
          seriesId: 'grp_frieren',
          seriesOrder: 2,
          seriesLabel: '第 2 季',
          matchedSeason: 2,
          scrapeStatus: ScrapeStatus.matched,
        );
        const ep1 = Episode(
          id: 'ep_f_1',
          workId: 'frieren_s1',
          seasonNumber: 1,
          episodeNumber: 1,
          title: '冒险的终点',
        );
        const epExtra = Episode(
          id: 'ep_f_extra_1',
          workId: 'frieren_s1',
          seasonNumber: 0,
          episodeNumber: 1,
          title: 'NCOP1',
          category: EpisodeCategory.extra,
        );
        const mainVar = MediaVariant(
          id: 'v_main_1',
          workId: 'frieren_s1',
          episodeId: 'ep_f_1',
          sourceId: 'src_1',
          relativePath: 'Frieren/[BDRip] Frieren - 01.mkv',
          fileName: '[BDRip] Frieren - 01.mkv',
          fileSize: 900000000,
        );
        const extraVar = MediaVariant(
          id: 'v_extra_1',
          workId: 'frieren_s1',
          episodeId: 'ep_f_extra_1',
          sourceId: 'src_1',
          relativePath: 'Frieren/SP/[BDRip] Frieren - NCOP1.mkv',
          fileName: '[BDRip] Frieren - NCOP1.mkv',
          fileSize: 120000000,
        );
        const cdVar = MediaVariant(
          id: 'v_cd_1',
          workId: 'frieren_s1',
          sourceId: 'src_1',
          relativePath: 'Frieren/CD/01 Yuusha.flac',
          fileName: '01 Yuusha.flac',
          fileSize: 38000000,
          assetKind: AssetKind.cdAlbum,
        );

        await tester.runAsync(() async {
          await repo.upsertMediaSource(
            MediaSource(
              id: 'src_1',
              label: 'WebDAV',
              kind: MediaSourceKind.webdav,
              location: 'http://192.168.1.192:5244/dav',
              createdAt: DateTime(2026, 5, 1),
            ),
          );
          await repo.upsertSeriesGroup(seriesGroup);
          await repo.upsertWork(s1);
          await repo.upsertWork(s2);
          await repo.upsertEpisode(ep1);
          await repo.upsertEpisode(epExtra);
          await repo.upsertMediaVariant(mainVar);
          await repo.upsertMediaVariant(extraVar);
          await repo.upsertMediaVariant(cdVar);
        });

        final overrides = <Override>[
          libraryRepositoryProvider.overrideWithValue(repo),
          tmdbImageLoaderProvider.overrideWithValue(
            (_, {targetWidth, imageSize}) async => backdropPng,
          ),
        ];

        // 1. 手机竖屏：16:9 背景图严格从状态栏安全区下方开始，播放键与系列切换同行，移除卡片 ...
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          _wrapApp(
            WorkDetailPage(workId: s1.id),
            overrides: overrides,
            padding: const EdgeInsets.only(top: 44, bottom: 24),
            viewPadding: const EdgeInsets.only(top: 44, bottom: 24),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)),
        );
        await tester.pumpAndSettle();

        final backdropRect = tester.getRect(
          find.byKey(const ValueKey('detail_portrait_hero_header')),
        );
        expect(backdropRect.top, closeTo(0.0, 0.5));
        final playRect = tester.getRect(find.text('开始播放'));
        expect(playRect.width, lessThan(220.0));
        expect(find.byKey(const ValueKey('episode_more_ep_f_1')), findsNothing);

        // 2. 手机横屏：整页可纵向滚动、二级分类特典/CD 卡片显示原始文件名，齿轮菜单在矮视口可滚动不裁切
        tester.view.physicalSize = const Size(844, 360);
        await tester.pumpWidget(
          _wrapApp(
            WorkDetailPage(workId: s1.id),
            overrides: overrides,
            padding: const EdgeInsets.only(left: 40, top: 20, bottom: 16),
            viewPadding: const EdgeInsets.only(left: 40, top: 20, bottom: 16),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('detail_phone_landscape_scroll_view')),
          findsOneWidget,
        );

        await tester.ensureVisible(find.textContaining('特典').first);
        await tester.tap(find.textContaining('特典').first);
        await tester.pumpAndSettle();
        expect(find.text('[BDRip] Frieren - NCOP1.mkv'), findsWidgets);

        await tester.tap(find.textContaining('CD').first);
        await tester.pumpAndSettle();
        expect(find.text('01 Yuusha.flac'), findsWidgets);

        // 验证矮视口弹出齿轮菜单受安全区高度钳制且内部带可交互滚动视图，「编辑封面」可完整滑出
        await tester.tap(find.byIcon(Icons.settings_rounded).first);
        await tester.pumpAndSettle();
        final gearMenuBox = find.byKey(
          const ValueKey('detail_gear_menu_container'),
        );
        expect(gearMenuBox, findsOneWidget);
        expect(tester.getSize(gearMenuBox).height, lessThanOrEqualTo(360.0));
        expect(find.text('编辑封面'), findsOneWidget);
        await tester.tapAt(const Offset(12, 12));
        await tester.pumpAndSettle();

        // 3. 平板竖屏：背景图从状态栏正下方起绘，简介横向通栏且迷你胶囊开启时不覆盖播放按钮
        tester.view.physicalSize = const Size(820, 1180);
        await tester.pumpWidget(
          _wrapApp(
            WorkDetailPage(workId: s1.id),
            overrides: [
              ...overrides,
              miniAudioBottomClearanceProvider.overrideWithValue(72.0),
            ],
            padding: const EdgeInsets.only(top: 36, bottom: 20),
            viewPadding: const EdgeInsets.only(top: 36, bottom: 20),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)),
        );
        await tester.pumpAndSettle();
        final tabletBgRect = tester.getRect(
          find.byKey(const ValueKey('detail_portrait_hero_header')),
        );
        expect(tabletBgRect.top, closeTo(0.0, 0.5));
        final overviewRect = tester.getRect(
          find.textContaining('打倒魔王之后勇者一行人'),
        );
        expect(overviewRect.width, greaterThan(600.0));
        expect(find.byType(DetailBottomDrawer), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        debugDefaultTargetPlatformOverride = null;
      },
    );

    testWidgets(
      '模块四（问题 07, 14-16, 26-28）：视频播放器单顶栏无重影、底栏音量键与绝对居中、挖孔对称黑边及退出解锁方向',
      (tester) async {
        // 1. 验证左右与上下摄像头挖孔对称黑边计算
        expect(
          VideoCutoutSymmetry.resolveSymmetricCutoutPadding(
            viewportSize: const Size(844, 390),
            viewPadding: const EdgeInsets.only(left: 42),
          ),
          const EdgeInsets.symmetric(horizontal: 42),
        );
        expect(
          VideoCutoutSymmetry.resolveSymmetricCutoutPadding(
            viewportSize: const Size(1280, 800),
            viewPadding: const EdgeInsets.only(top: 28, bottom: 12),
          ),
          const EdgeInsets.symmetric(vertical: 28),
        );

        // 2. 验证退出/收起视频时立即调用 SystemChrome.setPreferredOrientations(DeviceOrientation.values)
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);

        final orientationCalls = <Object?>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
              if (call.method == 'SystemChrome.setPreferredOrientations') {
                orientationCalls.add(call.arguments);
              }
              return null;
            });
        const playbackWindowChannel = MethodChannel('ccplayer/playback_window');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(playbackWindowChannel, (_) async => null);
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(SystemChannels.platform, null);
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(playbackWindowChannel, null);
        });

        await AndroidPlaybackWindowBridge.applyVideoOrientationAndWindow(
          landscape: true,
          hideSystemBars: true,
        );
        expect(
          orientationCalls.last,
          equals([
            'DeviceOrientation.landscapeLeft',
            'DeviceOrientation.landscapeRight',
          ]),
        );

        await AndroidPlaybackWindowBridge.applyVideoOrientationAndWindow(
          landscape: false,
          hideSystemBars: false,
        );
        expect(
          orientationCalls.last,
          containsAll(<String>[
            'DeviceOrientation.portraitUp',
            'DeviceOrientation.portraitDown',
            'DeviceOrientation.landscapeLeft',
            'DeviceOrientation.landscapeRight',
          ]),
        );

        // 3. 验证 Android 视频页唯一顶栏胶囊、底栏补齐音量键及上一话/播放暂停/下一话严格 50.0% 居中
        tester.view.physicalSize = const Size(844, 390);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        const work = Work(
          id: 'vid_w1',
          title: '葬送的芙莉莲',
          scrapeStatus: ScrapeStatus.matched,
        );
        const ep1 = Episode(
          id: 'vid_ep1',
          workId: 'vid_w1',
          seasonNumber: 1,
          episodeNumber: 1,
          title: '冒险的终点',
        );
        const ep2 = Episode(
          id: 'vid_ep2',
          workId: 'vid_w1',
          seasonNumber: 1,
          episodeNumber: 2,
          title: '并非魔法',
        );
        const variant1 = MediaVariant(
          id: 'vid_v1',
          workId: 'vid_w1',
          episodeId: 'vid_ep1',
          sourceId: 'src_1',
          relativePath: 'Frieren/01.mkv',
          fileName: '01.mkv',
          fileSize: 800000000,
        );
        const variant2 = MediaVariant(
          id: 'vid_v2',
          workId: 'vid_w1',
          episodeId: 'vid_ep2',
          sourceId: 'src_1',
          relativePath: 'Frieren/02.mkv',
          fileName: '02.mkv',
          fileSize: 800000000,
        );
        const bundle = WorkDetailBundle(
          work: work,
          episodes: [ep1, ep2],
          variants: [variant1, variant2],
          sourcesById: {},
          latestPlayback: null,
        );
        const req = VideoLaunchRequest(
          work: work,
          episode: ep1,
          variant: variant1,
          bundle: bundle,
        );

        await tester.pumpWidget(
          _wrapApp(
            EmbeddedVideoPage(
              request: req,
              sharedVideoSurface: const ColoredBox(color: Colors.black),
            ),
            overrides: [
              videoPlaybackProvider(
                req,
              ).overrideWith(() => _StubVideoController(req)),
            ],
            viewPadding: const EdgeInsets.only(left: 36),
          ),
        );
        await tester.pump();

        expect(
          find.byKey(const ValueKey('android_video_top_capsule')),
          findsOneWidget,
        );
        expect(find.byType(KonataVolumeControl), findsOneWidget);

        final capsuleRect = tester.getRect(find.byType(KonataPlaybackCapsule));
        final centerClusterRect = tester.getRect(
          find.byKey(const ValueKey('konata_capsule_center_transport')),
        );
        expect(
          (centerClusterRect.center.dx - capsuleRect.center.dx).abs(),
          lessThanOrEqualTo(1.0),
        );
        expect(
          find.byKey(const ValueKey('video_symmetric_cutout_frame')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 4));
        debugDefaultTargetPlatformOverride = null;
      },
    );

    testWidgets(
      '模块四（问题 18, 19, 30）：音频播放器竖屏队列抽屉、三端封面倒影、横屏单行顶栏及平板底部正中央全套控制坞',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        SharedPreferences.setMockInitialValues({});

        const work = Work(
          id: 'aud_w1',
          title: '孤独摇滚！',
          scrapeStatus: ScrapeStatus.matched,
        );
        const variant = MediaVariant(
          id: 'aud_v1',
          workId: 'aud_w1',
          sourceId: 'src_1',
          relativePath: 'Bocchi/CD/01.flac',
          fileName: '01.flac',
          fileSize: 35000000,
          assetKind: AssetKind.cdAlbum,
        );
        final initialState = AudioPlaybackState(
          isActive: true,
          isPlaying: true,
          currentIndex: 0,
          positionSeconds: 24,
          durationSeconds: 248,
          audioCodecLabel: 'FLAC',
          sampleRateAndBitDepthLabel: '48kHz/24bit',
          cover: const EmptyAudioCover(),
          queue: const [
            AudioQueueItem(
              id: 't1',
              work: work,
              variant: variant,
              title: '青春コンプレックス',
              albumTitle: '結束バンド',
            ),
            AudioQueueItem(
              id: 't2',
              work: work,
              variant: variant,
              title: 'ギターと孤独と蒼い惑星',
              albumTitle: '結束バンド',
            ),
          ],
        );

        // 1. 手机竖屏（挂载于真实 MiniAudioOverlayHost 层级下）：无「轻触封面查看歌词详情」、含倒影、右下队列按钮正常弹出抽屉
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              audioPlaybackProvider.overrideWith(
                () => _StubAudioNotifier(initialState),
              ),
              immersiveAudioExpandedProvider.overrideWith(
                () => KonataValueNotifier.value(true),
              ),
              tmdbImageLoaderProvider.overrideWithValue(
                (_, {targetWidth, imageSize}) async => posterPng,
              ),
            ],
            child: MaterialApp(
              locale: const Locale('zh', 'CN'),
              supportedLocales: const [Locale('zh', 'CN')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              theme: KonataTheme.darkTheme(),
              builder: (_, child) => MiniAudioOverlayHost(child: child!),
              home: const Scaffold(body: SizedBox.expand()),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('轻触封面查看歌词详情'), findsNothing);
        expect(
          find.byKey(const ValueKey('immersive_cover_reflection')),
          findsOneWidget,
        );

        await tester.tap(
          find.byKey(const ValueKey('portrait_open_queue_button')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('portrait_queue_sheet_overlay')),
          findsOneWidget,
        );
        expect(find.text('播放队列 (2)'), findsOneWidget);

        await tester.tap(
          find.byKey(const ValueKey('portrait_close_queue_button')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('portrait_queue_sheet_overlay')),
          findsNothing,
        );

        // 2. 手机横屏：与平板/桌面同源底部居中光学长胶囊，左栏带倒影且不展示专辑副标题
        tester.view.physicalSize = const Size(844, 390);
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('immersive_collapse_button')),
          findsOneWidget,
        );
        final landscapeDockRect = tester.getRect(
          find.byType(KonataPlaybackCapsule),
        );
        expect((landscapeDockRect.center.dx - 422.0).abs(), lessThanOrEqualTo(1.5));
        expect(find.text('FLAC · 48kHz/24bit'), findsOneWidget);
        expect(find.text('青春コンプレックス'), findsWidgets);
        expect(find.text('結束バンド'), findsNothing);
        expect(
          find.byKey(const ValueKey('immersive_cover_reflection')),
          findsOneWidget,
        );

        // 3. 平板竖屏（800x1280）：控制胶囊位于整个播放器底部水平正中央，且保留循环/上一首/播放暂停/下一首/音量键
        tester.view.physicalSize = const Size(800, 1280);
        await tester.pumpAndSettle();

        final dockRect = tester.getRect(find.byType(KonataPlaybackCapsule));
        expect((dockRect.center.dx - 400.0).abs(), lessThanOrEqualTo(1.0));
        expect(dockRect.bottom, greaterThan(1100.0));
        expect(find.byTooltip('上一项'), findsOneWidget);
        expect(find.byTooltip('下一项'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('konata_audio_loop_button')),
          findsOneWidget,
        );
        expect(find.byType(KonataVolumeControl), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        debugDefaultTargetPlatformOverride = null;
      },
    );

    test(
      '模块四（问题 17, 20, 21, 28, 29）：详情页与平板迷你胶囊整屏居中及 AndroidMediaSessionBridge 双向交互',
      () async {
        // 1. 验证手机横屏（含左侧挖孔）与平板竖屏下悬浮小窗严格遵守安全区且不压住导航胶囊
        final phoneDetailLandscape = AdaptiveCapsuleLayout(
          size: const Size(844, 390),
          safe: const EdgeInsets.fromLTRB(44, 0, 0, 16),
          android: true,
          navigationVisible: false,
          miniKind: FloatingMiniPlayerKind.video,
        );
        expect(
          phoneDetailLandscape.floatingMiniWindowRect!.left,
          greaterThanOrEqualTo(44.0),
        );

        final phoneLibVideoMiniLandscape = AdaptiveCapsuleLayout(
          size: const Size(844, 390),
          safe: const EdgeInsets.fromLTRB(44, 0, 0, 16),
          android: true,
          navigationVisible: true,
          miniKind: FloatingMiniPlayerKind.video,
        );
        expect(
          phoneLibVideoMiniLandscape.floatingMiniWindowRect!.overlaps(
            phoneLibVideoMiniLandscape.navigationRect,
          ),
          isFalse,
        );

        final narrowTabletPortrait = AdaptiveCapsuleLayout(
          size: const Size(600, 960),
          safe: const EdgeInsets.fromLTRB(0, 24, 0, 16),
          android: true,
          navigationVisible: true,
          miniKind: FloatingMiniPlayerKind.audio,
        );
        expect(
          narrowTabletPortrait.floatingMiniWindowRect!.overlaps(
            narrowTabletPortrait.navigationRect,
          ),
          isFalse,
        );

        // 2. 验证 AndroidMediaSessionBridge 向原生通知栏推送高清封面/元数据/时长，并响应双向拖拽 seekTo 与上下首
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);

        const mediaChannel = MethodChannel('ccplayer/media_session_test');
        final sentCalls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(mediaChannel, (call) async {
              sentCalls.add(call);
              return null;
            });
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(mediaChannel, null);
        });

        final bridge = AndroidMediaSessionBridge(
          channel: mediaChannel,
          isSupported: () => true,
        );
        const work = Work(
          id: 'ms_w1',
          title: '葬送的芙莉莲',
          scrapeStatus: ScrapeStatus.matched,
        );
        const variant = MediaVariant(
          id: 'ms_v1',
          workId: 'ms_w1',
          sourceId: 'src_1',
          relativePath: 'Frieren/CD/01.flac',
          fileName: '01.flac',
          fileSize: 30000000,
          assetKind: AssetKind.cdAlbum,
        );
        late _StubAudioNotifier notifier;
        final container = ProviderContainer(
          overrides: [
            audioPlaybackProvider.overrideWith(() {
              notifier = _StubAudioNotifier(
                AudioPlaybackState(
                  isActive: true,
                  isPlaying: true,
                  currentIndex: 0,
                  positionSeconds: 12.5,
                  durationSeconds: 266.0,
                  cover: MemoryAudioCover(posterPng),
                  queue: const [
                    AudioQueueItem(
                      id: 'ms_t1',
                      work: work,
                      variant: variant,
                      title: '晴る',
                      performer: 'ヨルシカ',
                      albumTitle: '晴る Single',
                    ),
                  ],
                ),
                mediaSessionBridge: bridge,
              );
              return notifier;
            }),
          ],
        );
        addTearDown(container.dispose);

        container.read(audioPlaybackProvider);
        await Future<void>.delayed(Duration.zero);

        expect(sentCalls, isNotEmpty);
        final updateArgs =
            sentCalls.last.arguments as Map<Object?, Object?>;
        expect(sentCalls.last.method, 'update');
        expect(updateArgs['title'], '晴る');
        expect(updateArgs['artist'], 'ヨルシカ · 葬送的芙莉莲');
        expect(updateArgs['durationMs'], 266000);
        expect(updateArgs['isPlaying'], isTrue);
        expect(updateArgs['coverBytes'], isNotNull);

        // 模拟用户在系统通知栏拖动进度条至 95.4 秒及点击下一首按键
        const codec = StandardMethodCodec();
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              mediaChannel.name,
              codec.encodeMethodCall(
                const MethodCall('onMediaAction', <String, Object?>{
                  'command': 'seekTo',
                  'positionMs': 95400,
                }),
              ),
              (_) {},
            );
        expect(notifier.lastSeekSeconds, closeTo(95.4, 0.01));

        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              mediaChannel.name,
              codec.encodeMethodCall(
                const MethodCall('onMediaAction', <String, Object?>{
                  'command': 'next',
                }),
              ),
              (_) {},
            );
        expect(notifier.nextCount, 1);
        debugDefaultTargetPlatformOverride = null;
      },
    );
  });
}
