import 'dart:convert';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:konata/application/providers/library_providers.dart';
import 'package:konata/application/providers/scraping_providers.dart';
import 'package:konata/application/providers/source_actions_provider.dart';
import 'package:konata/application/scraping/scrape_orchestrator.dart';
import 'package:konata/application/scraping/scrape_progress.dart';
import 'package:konata/domain/models/episode.dart';
import 'package:konata/domain/models/media_source.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/models/network_config.dart';
import 'package:konata/domain/models/tmdb_models.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/domain/repositories/file_system_gateway.dart';
import 'package:konata/infrastructure/database/drift_library_repository.dart';
import 'package:konata/infrastructure/database/konata_database.dart';
import 'package:konata/infrastructure/network/priority_http_scheduler.dart';
import 'package:konata/infrastructure/network/tmdb_http_client.dart';
import 'package:konata/infrastructure/network/tmdb_service.dart';
import 'package:konata/infrastructure/sources/directory_scanner.dart';
import 'package:konata/infrastructure/sources/webdav_source_gateway.dart';
import 'package:konata/presentation/detail/work_detail_page.dart';
import 'package:konata/presentation/library/review_reason_labels.dart';
import 'package:konata/presentation/library/review_work_item_card.dart';
import 'package:konata/presentation/sources/scan_progress_dialog.dart';
import 'package:konata/presentation/sources/source_folder_picker_dialog.dart';
import 'package:konata/presentation/sources/sources_page.dart';
import 'package:konata/presentation/theme/konata_theme.dart';
import 'package:konata/presentation/widgets/design_system/konata_toast.dart';

Widget _wrapTestApp(
  Widget child, {
  List<Override> overrides = const [],
}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: KonataTheme.darkTheme(),
      home: Scaffold(body: child),
    ),
  );
}

class _FakeBrowserActions extends KonataActionsCoordinator {
  _FakeBrowserActions(super.ref);

  @override
  Future<List<RemoteEntry>> listSourceDirectory(
    MediaSource source,
    String relativePath,
  ) async {
    if (relativePath == 'Season_2025') {
      return const [
        RemoteEntry(
          name: '86 - 01.mkv',
          relativePath: 'Season_2025/86 - 01.mkv',
          isDirectory: false,
          size: 524288000,
        ),
      ];
    }
    return const [
      RemoteEntry(
        name: 'Season_2025',
        relativePath: 'Season_2025',
        isDirectory: true,
      ),
      RemoteEntry(
        name: 'Movie_Pack',
        relativePath: 'Movie_Pack',
        isDirectory: true,
      ),
      RemoteEntry(
        name: 'Trailer.mkv',
        relativePath: 'Trailer.mkv',
        isDirectory: false,
        size: 104857600,
      ),
      RemoteEntry(
        name: 'Trailer.ass',
        relativePath: 'Trailer.ass',
        isDirectory: false,
        size: 65536,
      ),
    ];
  }
}

class _FakeScrapeController extends ScrapeController {
  _FakeScrapeController(ScrapeProgress initial) : super(initialState: initial);

  bool cancelCalled = false;
  List<String>? lastScannedRoots;

  void emit(ScrapeProgress next) {
    state = next;
  }

  @override
  void requestCancel() {
    cancelCalled = true;
    super.requestCancel();
  }

  @override
  Future<void> scanSource(
    MediaSource source, {
    List<String>? scanRootsOverride,
  }) async {
    lastScannedRoots = scanRootsOverride;
  }
}

class _FakeGateway implements MediaSourceGateway {
  _FakeGateway(this.tree);

  final Map<String, List<RemoteEntry>> tree;

  @override
  Future<void> close() async {}

  @override
  Future<List<RemoteEntry>> listDirectory(String relativePath) async {
    return tree[relativePath] ?? const [];
  }

  @override
  Future<String?> readTextFile(
    String relativePath, {
    int maxBytes = 256 * 1024,
  }) async {
    return null;
  }

  @override
  Future<String?> testConnection() async => null;
}

void main() {
  group('浏览多选刮削与进度诊断测试', () {
    testWidgets('多选目录弹窗展示文件大小、支持搜索过滤并立即扫描选中范围', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      SharedPreferences.setMockInitialValues({});
      const source = MediaSource(
        id: 'src_1',
        kind: MediaSourceKind.webdav,
        label: '测试动画源',
        location: 'https://nas.local/anime',
      );
      List<String>? scannedPaths;

      await tester.pumpWidget(
        _wrapTestApp(
          SourceFolderPickerDialog(
            source: source,
            onScanSelected: (paths) async {
              scannedPaths = paths;
            },
          ),
          overrides: [
            konataActionsProvider.overrideWith(
              (ref) => _FakeBrowserActions(ref),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // 不再显示“保存范围”按钮；未勾选任何目录时主按钮显示“扫描全库”
      expect(find.text('保存范围'), findsNothing);
      expect(find.text('扫描全库'), findsOneWidget);

      // 同时呈现目录与文件，且展示视频文件大小
      expect(find.text('Season_2025'), findsOneWidget);
      expect(find.text('Movie_Pack'), findsOneWidget);
      expect(find.text('Trailer.mkv'), findsOneWidget);
      expect(find.text('100.0 MB'), findsOneWidget);

      // 搜索过滤应隐藏无关目录与文件
      await tester.enterText(find.byType(TextField), 'Season');
      await tester.pumpAndSettle();
      expect(find.text('Season_2025'), findsOneWidget);
      expect(find.text('Movie_Pack'), findsNothing);
      expect(find.text('Trailer.mkv'), findsNothing);

      // 勾选第一个复选框（当前目录下搜索到的 Season_2025 行复选框）
      final checkboxes = find.byType(Checkbox);
      // 第一个是面包屑“当前目录勾选框”（在根目录禁用），第二个是 Season_2025 行复选框
      await tester.tap(checkboxes.at(1));
      await tester.pumpAndSettle();

      expect(find.text('扫描所选目录 (1)'), findsOneWidget);
      await tester.tap(find.text('扫描所选目录 (1)'));
      await tester.pumpAndSettle();

      expect(scannedPaths, ['Season_2025']);
    });

    testWidgets('ScanProgressDialog 展示分目录视频统计、支持取消与切换待复核列表', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      SharedPreferences.setMockInitialValues({});
      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);

      await repo.upsertMediaSource(
        const MediaSource(
          id: 'src_1',
          kind: MediaSourceKind.local,
          label: '本地番剧',
          location: 'D:/Anime',
        ),
      );
      await repo.upsertWork(
        const Work(
          id: 'work_review_1',
          title: '待复核测试番剧',
          scrapeStatus: ScrapeStatus.needsReview,
        ),
      );
      await repo.saveScrapeCandidates('work_review_1', const [
        ScrapeCandidateSummary(
          workId: 'work_review_1',
          rank: 0,
          tmdbId: 9001,
          mediaType: TmdbMediaType.tv,
          title: '候选命中番剧',
          score: 76,
          reasons: ['+40 title'],
        ),
      ]);
      await repo.upsertMediaVariant(
        const MediaVariant(
          id: 'var_1',
          workId: 'work_review_1',
          sourceId: 'src_1',
          relativePath: 'Anime_A/01.mkv',
          fileName: '01.mkv',
          fileSize: 1024,
          assetKind: AssetKind.video,
        ),
      );

      late _FakeScrapeController controller;
      const initialProgress = ScrapeProgress(
        phase: ScrapePhase.scraping,
        sourceId: 'src_1',
        sourceLabel: '本地番剧',
        currentItemName: 'Anime_A',
        scannedDirectories: 2,
        foundFiles: 4,
        totalWorks: 2,
        processedWorks: 1,
        matchedWorks: 1,
        reviewWorks: 1,
        selectedRoots: ['Anime_A'],
        folderVideoCounts: {'Anime_A': 3, 'Anime_A/SPs': 1},
        completedFolders: {'Anime_A', 'Anime_A/SPs'},
      );

      await tester.pumpWidget(
        _wrapTestApp(
          const SourcesPage(),
          overrides: [
            libraryRepositoryProvider.overrideWithValue(repo),
            scrapeControllerProvider.overrideWith(() {
              controller = _FakeScrapeController(initialProgress);
              return controller;
            }),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // 横幅应提供“查看详情”与“取消”操作
      expect(find.text('查看详情'), findsOneWidget);
      await tester.tap(find.text('查看详情'));
      await tester.pumpAndSettle();

      expect(find.byType(ScanProgressDialog), findsOneWidget);
      expect(find.text('目录 2'), findsOneWidget);
      expect(find.text('视频 4'), findsOneWidget);
      expect(find.text('Anime_A · 4 视频'), findsOneWidget);
      expect(find.text('Anime_A/SPs'), findsOneWidget);

      // 切换至“待复核条目”页签应展示该源下完整待复核卡片（相对路径、手动搜索、忽略复核、隐藏作品）
      await tester.tap(find.text('待复核条目 (1)'));
      await tester.pumpAndSettle();
      expect(find.text('待复核测试番剧'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ReviewWorkItemCard),
          matching: find.text('Anime_A'),
        ),
        findsOneWidget,
      );
      expect(find.text('手动搜索'), findsOneWidget);
      expect(find.text('忽略复核'), findsOneWidget);
      expect(find.text('隐藏作品'), findsOneWidget);

      // 候选列表默认折叠，点击“展开候选 (1)”后才显现候选与采纳按钮
      expect(find.text('候选命中番剧'), findsNothing);
      expect(find.text('展开候选 (1)'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ReviewWorkItemCard),
          matching: find.byIcon(Icons.keyboard_arrow_down_rounded),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('展开候选 (1)'));
      await tester.pumpAndSettle();
      expect(find.text('候选命中番剧'), findsOneWidget);
      expect(find.text('采纳'), findsOneWidget);
      expect(find.text('收起候选'), findsOneWidget);

      // 点击取消扫描应触发控制器请求
      await tester.tap(find.text('取消扫描'));
      await tester.pumpAndSettle();
      expect(controller.cancelCalled, isTrue);

      // 切换回“扫描状态与目录”关闭弹窗后，将状态更新为完成态验证横幅关闭按钮及右上角已移除“上次扫描详情”
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();

      controller.emit(
        initialProgress.copyWith(
          phase: ScrapePhase.completed,
          matchedWorks: 2,
          reviewWorks: 1,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('查看详情'), findsOneWidget);
      expect(find.text('上次扫描详情'), findsNothing);

      await tester.tap(find.byTooltip('关闭提示'));
      await tester.pumpAndSettle();
      expect(find.text('查看详情'), findsNothing);
      expect(find.text('上次扫描详情'), findsNothing);
    });

    test('ReviewReasonLabels 解析带分值特征并去重防止重复显示综合匹配特征参考', () {
      final labels = ReviewReasonLabels.formatAll([
        '+45 title',
        '+15 year (via Bangumi)',
        '+10 feature',
        '+8 unknown_future_signal',
        '+5 another_unknown_signal',
      ]);
      expect(labels, contains('标题精确匹配'));
      expect(labels, contains('年份吻合'));
      expect(labels, contains('类型一致'));
      expect(
        labels.where((e) => e == '综合匹配特征参考').length,
        1,
      );
    });

    test('ScrapeOrchestrator 支持采集目录视频计数并在取消时安全中止且不误删作品', () async {
      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);

      const source = MediaSource(
        id: 'src_local',
        kind: MediaSourceKind.local,
        label: '本地测试库',
        location: 'D:/Test',
      );
      await repo.upsertMediaSource(source);
      await repo.upsertWork(
        const Work(
          id: 'existing_work',
          title: '已有作品',
          scrapeStatus: ScrapeStatus.matched,
        ),
      );
      await repo.upsertMediaVariant(
        const MediaVariant(
          id: 'existing_var',
          workId: 'existing_work',
          sourceId: 'src_local',
          relativePath: 'Existing/01.mkv',
          fileName: '01.mkv',
          fileSize: 1024,
          assetKind: AssetKind.video,
        ),
      );

      final client = MockClient((_) async => http.Response(jsonEncode({'results': []}), 200));
      final tmdb = TmdbService(
        httpClient: TmdbHttpClient(
          config: const TmdbNetworkConfig(credential: 'test'),
          scheduler: PriorityHttpScheduler(),
          httpClient: client,
        ),
      );

      var listedDirs = 0;
      final orchestrator = ScrapeOrchestrator(
        repository: repo,
        tmdbService: tmdb,
        gatewayBuilder: (_) async => _FakeGateway({
          '': const [
            RemoteEntry(name: 'A', relativePath: 'A', isDirectory: true),
            RemoteEntry(name: 'B', relativePath: 'B', isDirectory: true),
          ],
          'A': const [
            RemoteEntry(name: '01.mkv', relativePath: 'A/01.mkv', isDirectory: false),
            RemoteEntry(name: '02.mkv', relativePath: 'A/02.mkv', isDirectory: false),
          ],
          'B': const [
            RemoteEntry(name: '01.mkv', relativePath: 'B/01.mkv', isDirectory: false),
          ],
        }),
      );

      // 场景 1：扫描首个目录后立即取消
      final cancelledProgress = await orchestrator.scanAndScrapeSource(
        source,
        isCancelled: () => listedDirs >= 1,
        onProgress: (p) {
          listedDirs = p.scannedDirectories;
        },
      );
      expect(cancelledProgress.phase, ScrapePhase.cancelled);
      expect(await repo.findWorkById('existing_work'), isNotNull);

      // 场景 2：仅选择 'A' 做局部扫描且不取消，'A' 被收集视频数 2，原有非选区作品不被清理
      final partialProgress = await orchestrator.scanAndScrapeSource(
        source,
        scanRootsOverride: const ['A'],
      );
      expect(partialProgress.phase, ScrapePhase.completed);
      expect(partialProgress.folderVideoCounts['A'], 2);
      expect(partialProgress.videosUnderRoot('A'), 2);
      expect(await repo.findWorkById('existing_work'), isNotNull);
    });

    test('WebDavSourceGateway 过滤含中文与特殊符号的自引用 PROPFIND 目录且不发生死循环', () async {
      const targetRel = '动画-单作品/16bit的感动 ANOTHER LAYER (2023) {tmdb-217512}';
      var calls = 0;
      final urls = <String>[];
      final client = MockClient((req) async {
        calls++;
        urls.add('${req.method} ${req.url.path}');
        const xml = '''<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/dav/动画-单作品/16bit的感动 ANOTHER LAYER (2023) {tmdb-217512}/</D:href>
    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/%E5%8A%A8%E7%94%BB-%E5%8D%95%E4%BD%9C%E5%93%81/16bit%E7%9A%84%E6%84%9F%E5%8A%A8%20ANOTHER%20LAYER%20(2023)%20%7Btmdb-217512%7D/01.mkv</D:href>
    <D:propstat><D:prop><D:resourcetype/><D:getcontentlength>1024000</D:getcontentlength></D:prop></D:propstat>
  </D:response>
</D:multistatus>''';
        return http.Response.bytes(utf8.encode(xml), 200);
      });

      final gateway = WebDavSourceGateway(
        rootUri: Uri.parse('http://192.168.1.247:5005/dav'),
        httpClient: client,
      );
      final result = await const DirectoryScanner().scan(
        gateway,
        scanRoots: const [targetRel],
      );

      expect(calls, 1, reason: '实际请求轨迹: $urls');
      expect(result.scannedDirectories, 1);
      expect(result.files, hasLength(1));
      expect(result.files.single.fileName, '01.mkv');
    });

    testWidgets('SourcesPage 已移除外层扫描刮削按钮，弹窗钻入单目录后可直接扫描当前目录', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      SharedPreferences.setMockInitialValues({});
      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);
      const source = MediaSource(
        id: 'src_wd',
        kind: MediaSourceKind.webdav,
        label: 'WebDAV 测试',
        location: 'http://192.168.1.1:5005/dav',
      );
      await repo.upsertMediaSource(source);

      await tester.pumpWidget(
        _wrapTestApp(
          const SourcesPage(),
          overrides: [
            libraryRepositoryProvider.overrideWithValue(repo),
            konataActionsProvider.overrideWith((ref) => _FakeBrowserActions(ref)),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // 外层不再展示独立的“扫描刮削”按钮
      expect(find.text('扫描刮削'), findsNothing);
      expect(find.text('选择目录'), findsOneWidget);

      // 钻入子目录而不勾选复选框时，主按钮仍显示“扫描全库”；勾选当前目录复选框后变为“扫描所选目录 (1)”
      List<String>? scanned;
      await tester.pumpWidget(
        ProviderScope(
          key: const ValueKey('dialog_only'),
          overrides: [
            konataActionsProvider.overrideWith((ref) => _FakeBrowserActions(ref)),
          ],
          child: MaterialApp(
            theme: KonataTheme.darkTheme(),
            home: Scaffold(
              body: SourceFolderPickerDialog(
                source: source,
                onScanSelected: (paths) async => scanned = paths,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('扫描全库'), findsOneWidget);
      await tester.tap(find.text('Season_2025'));
      await tester.pumpAndSettle();

      expect(find.text('扫描全库'), findsOneWidget);
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(find.text('扫描所选目录 (1)'), findsOneWidget);
      await tester.tap(find.text('扫描所选目录 (1)'));
      await tester.pumpAndSettle();
      expect(scanned, ['Season_2025']);
    });

    testWidgets('WorkDetailPage 展开正片剧集列表时，开始播放主按钮在大小窗口下均被顶起且不被遮挡', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);

      await repo.upsertMediaSource(
        const MediaSource(
          id: 's1',
          kind: MediaSourceKind.local,
          label: '本地',
          location: 'D:/Anime',
        ),
      );
      await repo.upsertWork(
        const Work(
          id: 'w_86',
          title: '86 -不存在的战区-',
          year: 2021,
          overview: '测试简介内容用于验证布局高度与播放交互按钮位置关系。',
          scrapeStatus: ScrapeStatus.matched,
        ),
      );
      await repo.upsertEpisode(
        const Episode(
          id: 'ep_1',
          workId: 'w_86',
          category: EpisodeCategory.main,
          seasonNumber: 1,
          episodeNumber: 1,
          title: '送葬者',
        ),
      );
      await repo.upsertMediaVariant(
        const MediaVariant(
          id: 'v_1',
          workId: 'w_86',
          episodeId: 'ep_1',
          sourceId: 's1',
          relativePath: '86/01.mkv',
          fileName: '01.mkv',
          fileSize: 1024000,
          assetKind: AssetKind.video,
        ),
      );

      for (final windowSize in const [Size(960, 620), Size(1600, 900)]) {
        tester.view.physicalSize = windowSize;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        await tester.pumpWidget(
          ProviderScope(
            key: ValueKey(windowSize),
            overrides: [
              libraryRepositoryProvider.overrideWithValue(repo),
            ],
            child: MaterialApp(
              theme: KonataTheme.darkTheme(),
              home: const WorkDetailPage(workId: 'w_86'),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('2021 · 1 话'), findsOneWidget);
        expect(find.text('开始播放'), findsOneWidget);
        await tester.tap(find.text('正片 (1)'));
        await tester.pumpAndSettle();

        final playBottom = tester.getBottomLeft(find.text('开始播放')).dy;
        final drawerTop = tester.getTopLeft(find.text('正片 (1)').first).dy;
        expect(
          playBottom,
          lessThan(drawerTop),
          reason: '窗口尺寸 $windowSize 下开始播放按钮底部($playBottom)必须严格高于抽屉顶部($drawerTop)',
        );
      }
    });

    testWidgets('showKonataToast 在桌面窗口正中弹出毛玻璃胶囊，报错使用红色区分，4 秒自动淡出且支持 × 关闭', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      late BuildContext capturedContext;
      await tester.pumpWidget(
        MaterialApp(
          theme: KonataTheme.darkTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) {
                capturedContext = context;
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      );

      showKonataToast(capturedContext, '已完成元数据刷新');
      await tester.pumpAndSettle();

      final capsuleFinder = find.byKey(const ValueKey('konata_toast_capsule'));
      final toastFinder = find.text('已完成元数据刷新');
      expect(capsuleFinder, findsOneWidget);
      expect(toastFinder, findsOneWidget);
      expect(find.byKey(const ValueKey('konata_toast_close')), findsOneWidget);
      final center = tester.getCenter(capsuleFinder);
      expect(center.dx, closeTo(640, 20));
      expect(center.dy, closeTo(360, 20));

      // 3 秒时仍可见，满 4 秒后自动淡出关闭。
      await tester.pump(const Duration(seconds: 3));
      expect(toastFinder, findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(toastFinder, findsNothing);

      // 报错复用完全一致的居中胶囊结构，仅以红色底色/边框/图标区分。
      showKonataToast(capturedContext, '连通测试失败', isError: true);
      await tester.pumpAndSettle();
      final errCenter = tester.getCenter(capsuleFinder);
      expect(errCenter.dx, closeTo(640, 20));
      expect(errCenter.dy, closeTo(360, 20));
      expect(
        find.descendant(
          of: capsuleFinder,
          matching: find.byIcon(Icons.error_outline_rounded),
        ),
        findsOneWidget,
      );
      final decorated = tester.widget<DecoratedBox>(
        find.descendant(of: capsuleFinder, matching: find.byType(DecoratedBox)),
      );
      final boxDec = decorated.decoration as BoxDecoration;
      expect(boxDec.color, equals(KonataTheme.toastErrorDarkSurface));
      await tester.tap(find.byKey(const ValueKey('konata_toast_close')));
      await tester.pumpAndSettle();
      expect(capsuleFinder, findsNothing);
    });
  });
}
