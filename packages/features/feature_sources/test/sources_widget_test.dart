import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:engine_scraping/engine_scraping.dart';
import 'package:feature_sources/feature_sources.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';
import 'package:konata_storage/konata_storage.dart';

class _FakeCloudSignIn implements CloudAccountSignInPort {
  _FakeCloudSignIn(this.onFinish);
  final void Function() onFinish;
  int sendCount = 0;
  int finishCount = 0;
  bool cancelled = false;
  @override
  Future<void> sendSms(String phone) async {
    expect(phone, '+15550101234');
    sendCount++;
  }

  @override
  Future<String> finishSms(String code) async {
    expect(code, '123456');
    finishCount++;
    onFinish();
    return 'guangyapan://account_fixture';
  }

  @override
  void cancel() {
    cancelled = true;
  }
}

class _TestStorageRoot implements StorageRootPort {
  _TestStorageRoot(this.rootPath);

  final String rootPath;

  @override
  Future<String> ensureDatabaseDirPath() async => '$rootPath/userdata/db';

  @override
  Future<String> ensureLogsDirPath() async => '$rootPath/userdata/logs';

  @override
  Future<String> ensureTempDirPath() async => '$rootPath/cache/tmp';

  @override
  Future<String> ensureUserdataDirPath() async => '$rootPath/userdata';

  @override
  Future<String> resolveAppRootPath() async => rootPath;

  @override
  Future<String> resolveCacheRootPath() async => '$rootPath/cache';

  @override
  Future<String> resolveDatabaseFilePath(String dbFileName) async =>
      '$rootPath/userdata/db/$dbFileName';

  @override
  Future<String> resolvePhotosDirPath() async => '$rootPath/photos';
}

class _FakeNavigator implements AppNavigator {
  final List<String> openedSettingsSections = <String>[];
  final List<String> switchedSections = <String>[];
  final List<WorkId> openedWorkDetails = <WorkId>[];

  @override
  Future<void> openAudioPlayer({
    required WorkId workId,
    VariantId? variantId,
  }) async {}

  @override
  Future<void> openSettings({String? sectionId}) async {
    openedSettingsSections.add(sectionId ?? '');
  }

  @override
  Future<void> openVideoPlayer({
    required WorkId workId,
    EpisodeId? episodeId,
    VariantId? variantId,
  }) async {}

  @override
  Future<void> openWorkDetail(WorkId workId, {String? initialTabId}) async {
    openedWorkDetails.add(workId);
  }

  @override
  Future<bool> pop() async => true;

  @override
  Future<void> switchNavSection(String sectionId) async {
    switchedSections.add(sectionId);
  }
}

class _FakeFilePicker implements FilePickerPort {
  _FakeFilePicker(this.directoryToReturn);

  final String? directoryToReturn;
  int pickCalls = 0;

  @override
  Future<String?> pickDirectory({String? dialogTitle}) async {
    pickCalls++;
    return directoryToReturn;
  }

  @override
  Future<String?> pickImageFile({String? dialogTitle}) async => null;

  @override
  Future<String?> pickSubtitleFile({String? dialogTitle}) async => null;
}

class _FakeDiagnosticLog implements DiagnosticLogPort {
  @override
  Future<String> buildJsonBundle() async => '{}';

  @override
  Future<String> buildTextReport() async => '';

  @override
  void clear() {}

  @override
  void logError({
    required DiagnosticSubsystem subsystem,
    required String code,
    required String message,
    required Object error,
    StackTrace? stackTrace,
    DiagnosticSeverity severity = DiagnosticSeverity.error,
    String? source,
    Map<String, Object?> context = const <String, Object?>{},
  }) {}

  @override
  void logEvent({
    required DiagnosticSubsystem subsystem,
    required String code,
    required String message,
    DiagnosticSeverity severity = DiagnosticSeverity.info,
    String? source,
    Map<String, Object?> context = const <String, Object?>{},
    Object? error,
    StackTrace? stackTrace,
  }) {}

  @override
  void recordBreadcrumb({
    required String category,
    required String label,
    String? source,
    String? detail,
  }) {}

  @override
  void Function() registerSnapshotContributor(
    String sectionId,
    DiagnosticSnapshotContributor contributor,
  ) => () {};

  @override
  void setVerbose(bool enabled) {}

  @override
  List<DiagnosticEvent> snapshotEvents() => const <DiagnosticEvent>[];

  @override
  List<DiagnosticFaultSummary> summarizeFaults() =>
      const <DiagnosticFaultSummary>[];

  @override
  DiagnosticSummaryCounts get summaryCounts => const DiagnosticSummaryCounts(
    totalEvents: 0,
    warningCount: 0,
    errorCount: 0,
    breadcrumbCount: 0,
  );

  @override
  bool get verboseEnabled => false;
}

class _FakeHttpClient implements KonataHttpClientPort {
  KonataNetworkConfig _config = const KonataNetworkConfig();

  @override
  KonataNetworkConfig get config => _config;

  @override
  void updateConfig(KonataNetworkConfig next) {
    _config = next;
  }

  @override
  void close() {}

  @override
  Future<KonataHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    RequestPriority priority = RequestPriority.background,
    String? dedupeKey,
    String? bucketKey,
  }) async => KonataHttpResponse(
    statusCode: 200,
    headers: const <String, String>{},
    bodyBytes: Uint8List(0),
  );

  @override
  Future<KonataHttpResponse> getWithFallback(
    Uri primaryUri, {
    Uri? backupUri,
    Map<String, String> headers = const <String, String>{},
    RequestPriority priority = RequestPriority.background,
    String? dedupeKey,
    String? bucketKey,
    bool retryOnRateLimit = true,
    Duration? timeoutOverride,
  }) => get(primaryUri);

  @override
  Future<KonataHttpResponse> post(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    Object? body,
    RequestPriority priority = RequestPriority.background,
    String? dedupeKey,
    String? bucketKey,
  }) => get(uri);

  @override
  Future<KonataHttpResponse> postWithFallback(
    Uri primaryUri, {
    Uri? backupUri,
    Map<String, String> headers = const <String, String>{},
    Object? body,
    RequestPriority priority = RequestPriority.background,
    String? dedupeKey,
    String? bucketKey,
    bool retryOnRateLimit = true,
    Duration? timeoutOverride,
  }) => get(primaryUri);

  @override
  Future<KonataHttpResponse> sendWithFallback({
    required String method,
    required Uri primaryUri,
    Uri? backupUri,
    Map<String, String> headers = const <String, String>{},
    Object? body,
    RequestPriority priority = RequestPriority.background,
    String? dedupeKey,
    String? bucketKey,
    bool retryOnRateLimit = true,
    Duration? timeoutOverride,
  }) => get(primaryUri);
}

class _FakeGateway implements MediaSourceGateway {
  @override
  Future<void> close() async {}

  @override
  Future<List<RemoteEntry>> listDirectory(String relativePath) async {
    if (relativePath == '2024') {
      return const [
        RemoteEntry(
          name: 'Frieren',
          relativePath: '2024/Frieren',
          isDirectory: true,
        ),
        RemoteEntry(
          name: '01.mkv',
          relativePath: '2024/01.mkv',
          isDirectory: false,
          size: 1024 * 1024 * 512,
        ),
      ];
    }
    return const [
      RemoteEntry(name: '2024', relativePath: '2024', isDirectory: true),
      RemoteEntry(name: '剧场版', relativePath: '剧场版', isDirectory: true),
      RemoteEntry(
        name: 'readme.nfo',
        relativePath: 'readme.nfo',
        isDirectory: false,
        size: 2048,
      ),
    ];
  }

  @override
  Future<String?> readTextFile(
    String relativePath, {
    int maxBytes = 256 * 1024,
  }) async => null;

  @override
  Future<String?> testConnection() async => null;
}

class _FakeGatewayFactory implements MediaSourceGatewayFactoryPort {
  @override
  Future<MediaSourceGateway> create(
    MediaSourceView source, {
    String? passwordOverride,
    bool clearPassword = false,
  }) async => _FakeGateway();
}

class _StubWidgetPipeline extends ScrapePipeline {
  _StubWidgetPipeline({
    required super.repository,
    required KonataHttpClientPort httpClient,
    required this.onRun,
  }) : super(
         tmdbService: TmdbService(httpClient: httpClient),
         gatewayBuilder: (_) => throw UnimplementedError(),
       );

  final Future<ScrapeProgress> Function(
    MediaSource source,
    ScrapeProgressListener? onProgress,
  )
  onRun;

  @override
  Future<ScrapeProgress> scanAndScrapeSource(
    MediaSource source, {
    List<String>? scanRootsOverride,
    bool Function()? isCancelled,
    ScrapeProgressListener? onProgress,
    ScrapeWorkPersistedListener? onWorkPersisted,
  }) {
    return onRun(source, onProgress);
  }
}

Future<Widget> _wrapTestApp({
  required FeatureSourcesDependencies deps,
  required KonataToastController toastCtrl,
  required Widget child,
  ThemeData? theme,
  SourceScrapeController? scrapeControllerOverride,
}) async {
  return ProviderScope(
    overrides: [
      featureSourcesDependenciesProvider.overrideWithValue(deps),
      if (scrapeControllerOverride != null)
        sourceScrapeControllerProvider.overrideWithValue(
          scrapeControllerOverride,
        ),
    ],
    child: MaterialApp(
      theme: theme ?? KonataTheme.darkTheme(),
      home: KonataToastScope(
        controller: toastCtrl,
        child: Scaffold(
          body: Stack(
            children: [
              child,
              KonataToastViewport(controller: toastCtrl),
            ],
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('媒体源主页面与编辑弹窗在四组标准视口与明暗双主题下零溢出且交互闭环', (tester) async {
    final tempRoot = Directory.systemTemp.createTempSync('konata_src_ui_');
    addTearDown(() {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    final db = KonataDatabaseBundle.openInMemory();
    addTearDown(db.close);
    final eventBus = InMemoryDomainEventBus();
    addTearDown(eventBus.dispose);
    final navigator = _FakeNavigator();
    final picker = _FakeFilePicker('D:/NewAnime');
    final storageRoot = _TestStorageRoot(tempRoot.path);
    final prefs = ScopedPrefsStore(db.userState);
    final photos = PhotosStorage(storageRoot: storageRoot);

    final repo = StorageScrapeRepository(db);
    await repo.upsertMediaSource(
      const MediaSource(
        id: 'src_ui_1',
        kind: MediaSourceKind.webdav,
        label: '家庭主力 WebDAV 动画库超长名称测试字段',
        location: 'https://nas.example.com:5006/bangumi/collection',
        username: 'admin',
      ),
    );
    await repo.upsertMediaSource(
      const MediaSource(
        id: 'src_ui_2',
        kind: MediaSourceKind.smb,
        label: '客厅 NAS SMB 共享',
        location: 'smb://192.168.1.10/Anime',
      ),
    );
    await repo.addIgnoredFolder('src_ui_1', 'NCOP/2024');
    await repo.upsertWork(
      const Work(
        id: 'w_ui_1',
        title: '葬送的芙莉莲',
        scrapeStatus: ScrapeStatus.needsReview,
        reviewReason: 'ambiguous_candidates',
      ),
    );
    await repo.upsertMediaVariant(
      const MediaVariant(
        id: 'var_ui_1',
        workId: 'w_ui_1',
        sourceId: 'src_ui_1',
        relativePath: 'Frieren/01.mkv',
        fileName: '01.mkv',
        fileSize: 1024,
      ),
    );

    var cloudAuthorized = false;
    final fakeSignIn = _FakeCloudSignIn(() => cloudAuthorized = true);
    final deps = FeatureSourcesDependencies(
      databases: db,
      storageRoot: storageRoot,
      secureStorage: InMemorySecureStorage(),
      diagnosticLog: _FakeDiagnosticLog(),
      scopedPrefs: prefs,
      domainEventBus: eventBus,
      navigator: navigator,
      filePicker: picker,
      httpClient: _FakeHttpClient(),
      gatewayFactory: _FakeGatewayFactory(),
      photosStorage: photos,
      platform: KonataPlatform.windows,
      listCloudAccountLocations: () async => cloudAuthorized
          ? const ['guangyapan://account_fixture']
          : const <String>[],
      createCloudSignIn: (expectedLocation) {
        expect(expectedLocation, isNull);
        return fakeSignIn;
      },
    );

    const viewports = <Size>[
      Size(390, 780),
      Size(780, 390),
      Size(1024, 700),
      Size(1440, 900),
    ];

    for (final theme in [KonataTheme.darkTheme(), KonataTheme.lightTheme()]) {
      for (final viewport in viewports) {
        tester.view.physicalSize = viewport;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final toastCtrl = KonataToastController();
        addTearDown(toastCtrl.dispose);

        await tester.pumpWidget(
          await _wrapTestApp(
            deps: deps,
            toastCtrl: toastCtrl,
            theme: theme,
            child:
                featureSourcesManifest.navSections.first.viewBuilder(
                      const ViewSlotContext(),
                    )
                    as Widget,
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text('尚未配置 TMDB API 凭证'), findsOneWidget);
        expect(find.textContaining('家庭主力 WebDAV'), findsOneWidget);
        expect(find.text('WebDAV'), findsOneWidget);
        expect(find.text('SMB 共享'), findsOneWidget);
        expect(find.text('1 部 · 1 视频'), findsOneWidget);
        expect(find.text('全部扫描'), findsNothing);
        expect(find.text('扫库刮削'), findsNothing);
        expect(find.byTooltip('更多媒体源操作'), findsNothing);
        expect(find.text('待复核 1 ↗'), findsOneWidget);
      }
    }

    await tester.tap(find.text('去配置'));
    await tester.pumpAndSettle();
    expect(navigator.openedSettingsSections, contains('network'));

    await tester.tap(find.byKey(const Key('sources_add_button')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(KonataGlassDialog),
        matching: find.text('添加媒体源'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('source_kind_dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('光鸭云盘'));
    await tester.pumpAndSettle();
    expect(find.textContaining('本机尚无已授权光鸭账号'), findsOneWidget);
    expect(find.textContaining('密码（'), findsNothing);
    await tester.tap(find.text('授权光鸭账号'));
    await tester.pumpAndSettle();
    expect(find.text('光鸭账号授权'), findsOneWidget);
    final phoneField = find.descendant(
      of: find.byType(KonataGlassDialog).last,
      matching: find.byType(EditableText),
    );
    await tester.enterText(phoneField.first, '+15550101234');
    await tester.tap(find.text('发送验证码'));
    await tester.pumpAndSettle();
    expect(fakeSignIn.sendCount, 1);
    await tester.enterText(phoneField.last, '123456');
    await tester.tap(find.text('确认授权'));
    await tester.pumpAndSettle();
    expect(fakeSignIn.finishCount, 1);
    expect(fakeSignIn.cancelled, isTrue);
    expect(find.text('光鸭账号 1'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('source_kind_dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('本地目录'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('浏览'));
    await tester.pumpAndSettle();
    expect(picker.pickCalls, 1);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final sourcesAfterAdd = await repo.getMediaSources();
    expect(sourcesAfterAdd.any((s) => s.location == 'D:/NewAnime'), isTrue);
    expect(find.text('本地磁盘'), findsOneWidget);

    // 验证目录范围选择器与已选目录管理面板交互。
    await tester.tap(find.text('选择目录').first);
    await tester.pumpAndSettle();
    expect(find.text('readme.nfo'), findsOneWidget);
    expect(find.text('已选目录 · 0（点击管理）'), findsOneWidget);
    final scanButton = find.byKey(const ValueKey('source_start_scan'));
    expect(tester.widget<KonataPillButton>(scanButton).onPressed, isNull);
    expect(find.byTooltip('需要选择扫描目录'), findsOneWidget);
    expect(find.text('仅保存范围'), findsNothing);
    expect(find.text('忽略缓存重扫'), findsNothing);

    await tester.tap(find.byType(Checkbox).at(1));
    await tester.pumpAndSettle();
    expect(find.text('扫描'), findsOneWidget);
    expect(tester.widget<KonataPillButton>(scanButton).onPressed, isNotNull);

    await tester.tap(find.byKey(const ValueKey('source_selected_scope_entry')));
    await tester.pumpAndSettle();
    expect(find.text('返回浏览目录'), findsOneWidget);
    expect(find.text('全选'), findsOneWidget);
    expect(find.text('反选'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('source_scope_back_to_browse')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('选择目录'), findsWidgets);
    await tester.tap(find.text('选择目录').first);
    await tester.pumpAndSettle();
    expect(tester.widget<KonataPillButton>(scanButton).onPressed, isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    // 验证移除确认弹窗与安全承诺文案。
    await tester.tap(find.byTooltip('删除').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('安全承诺'), findsOneWidget);
    await tester.tap(find.text('确认移除索引'));
    await tester.pumpAndSettle();
    expect((await repo.getMediaSources()).length, 2);
  });

  testWidgets('扫库进度横幅、全功能扫描进度弹窗及手机横屏双栏目录选择器正常运行', (tester) async {
    final tempRoot = Directory.systemTemp.createTempSync('konata_src_scan_ui_');
    addTearDown(() {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    final db = KonataDatabaseBundle.openInMemory();
    addTearDown(db.close);
    final eventBus = InMemoryDomainEventBus();
    addTearDown(eventBus.dispose);
    final navigator = _FakeNavigator();
    final storageRoot = _TestStorageRoot(tempRoot.path);
    final prefs = ScopedPrefsStore(db.userState);
    final photos = PhotosStorage(storageRoot: storageRoot);

    final repo = StorageScrapeRepository(db);
    const source = MediaSource(
      id: 'src_scan_ui',
      kind: MediaSourceKind.local,
      label: '动画盘',
      location: 'D:/Anime',
    );
    await repo.upsertMediaSource(source);
    await repo.upsertWork(
      const Work(
        id: 'w_rev_ui',
        title: '孤独摇滚待复核',
        scrapeStatus: ScrapeStatus.needsReview,
        reviewReason: 'close_candidates',
      ),
    );
    await repo.upsertMediaVariant(
      const MediaVariant(
        id: 'var_rev_ui',
        workId: 'w_rev_ui',
        sourceId: 'src_scan_ui',
        relativePath: 'Bocchi/01.mkv',
        fileName: '01.mkv',
        fileSize: 1024,
      ),
    );

    final fakeHttp = _FakeHttpClient();
    final deps = FeatureSourcesDependencies(
      databases: db,
      storageRoot: storageRoot,
      secureStorage: InMemorySecureStorage(),
      diagnosticLog: _FakeDiagnosticLog(),
      scopedPrefs: prefs,
      domainEventBus: eventBus,
      navigator: navigator,
      filePicker: _FakeFilePicker(null),
      httpClient: fakeHttp,
      gatewayFactory: _FakeGatewayFactory(),
      photosStorage: photos,
      platform: KonataPlatform.androidPhone,
    );

    List<String>? chosenScanPaths;
    final enteredScrape = Completer<void>();
    final allowFinish = Completer<void>();
    final scrapeController = SourceScrapeController(
      databases: db,
      storageRoot: storageRoot,
      scopedPrefs: prefs,
      eventBus: eventBus,
      httpClient: fakeHttp,
      gatewayFactory: _FakeGatewayFactory(),
      mappingLoaderOverride: () async => null,
      pipelineBuilder: ({required repository, required mappingIndex}) =>
          _StubWidgetPipeline(
            repository: repository,
            httpClient: fakeHttp,
            onRun: (src, onProgress) async {
              onProgress?.call(
                ScrapeProgress(
                  phase: ScrapePhase.scraping,
                  sourceId: src.id,
                  sourceLabel: src.label,
                  currentItemName: '葬送的芙莉莲',
                  scannedDirectories: 4,
                  foundFiles: 30,
                  totalWorks: 5,
                  processedWorks: 2,
                  matchedWorks: 1,
                  reviewWorks: 1,
                  selectedRoots: const <String>['2024'],
                  folderVideoCounts: const <String, int>{'2024/Frieren': 24},
                  completedFolders: const <String>{'2024/Frieren'},
                ),
              );
              enteredScrape.complete();
              await allowFinish.future;
              return ScrapeProgress(
                phase: ScrapePhase.completed,
                sourceId: src.id,
                sourceLabel: src.label,
                scannedDirectories: 4,
                foundFiles: 30,
                totalWorks: 5,
                processedWorks: 5,
                matchedWorks: 4,
                reviewWorks: 1,
                selectedRoots: const <String>['2024'],
                folderVideoCounts: const <String, int>{'2024/Frieren': 24},
                completedFolders: const <String>{'2024/Frieren'},
              );
            },
          ),
    );
    addTearDown(scrapeController.dispose);
    final scanFuture = scrapeController.scanSource(
      source,
      scanRootsOverride: const ['2024'],
    );
    await enteredScrape.future;

    tester.view.physicalSize = const Size(780, 390);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final toastCtrl = KonataToastController();
    addTearDown(toastCtrl.dispose);

    await tester.pumpWidget(
      await _wrapTestApp(
        deps: deps,
        toastCtrl: toastCtrl,
        scrapeControllerOverride: scrapeController,
        child: Builder(
          builder: (context) => ListenableBuilder(
            listenable: scrapeController,
            builder: (context, _) => Column(
              children: [
                ScrapeProgressBanner(
                  phase: scrapeController.phase,
                  onInspectDetail: () => showScanProgressDialog(
                    context,
                    focusSourceId: 'src_scan_ui',
                  ),
                  onCancelScan: scrapeController.cancelActiveScan,
                  onDismissTerminal: scrapeController.dismissTerminalBanner,
                ),
                const SizedBox(height: 12),
                KonataPillButton.primary(
                  label: '打开进度',
                  onPressed: () => showScanProgressDialog(
                    context,
                    focusSourceId: 'src_scan_ui',
                  ),
                ),
                KonataPillButton.secondary(
                  label: '打开目录',
                  onPressed: () => showSourceFolderPickerDialog(
                    context,
                    sourceId: 'src_scan_ui',
                    kind: MediaSourceKind.local,
                    location: 'D:/Anime',
                    sourceLabel: '动画盘',
                    onScanSelected: (paths) async {
                      chosenScanPaths = paths;
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await _pumpFrames(tester);

    expect(tester.takeException(), isNull);
    expect(find.textContaining('正在刮削 (2/5)'), findsOneWidget);

    await tester.tap(find.text('打开进度'));
    await _pumpFrames(tester);
    expect(find.text('扫描与刮削进度 · 动画盘'), findsOneWidget);
    expect(find.text('已扫目录 (1)'), findsOneWidget);
    expect(find.text('待复核条目 (1)'), findsOneWidget);
    expect(find.text('2024/Frieren'), findsOneWidget);

    await tester.tap(find.text('待复核条目 (1)'));
    await _pumpFrames(tester);
    expect(find.text('孤独摇滚待复核'), findsOneWidget);
    expect(find.text('多个候选分数接近，需人工核实'), findsOneWidget);

    await tester.tap(find.text('查看详情').last);
    await _pumpFrames(tester);
    expect(navigator.openedWorkDetails, [const WorkId.trusted('w_rev_ui')]);

    allowFinish.complete();
    await scanFuture;
    await _pumpFrames(tester);
    expect(find.textContaining('扫描刮削完成：已匹配 4'), findsOneWidget);

    await tester.tap(find.text('打开目录'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('已选目录 · 0'), findsOneWidget);
    expect(find.text('当前未勾选扫描目录'), findsOneWidget);

    final scan = find.byKey(const ValueKey('source_start_scan'));
    expect(tester.widget<KonataPillButton>(scan).onPressed, isNull);
    expect(chosenScanPaths, isNull);
    // 手机横屏目录浏览侧同样必须明确选中路径才可扫描。
    await tester.tap(find.byType(Checkbox).at(1));
    await tester.pumpAndSettle();
    expect(tester.widget<KonataPillButton>(scan).onPressed, isNotNull);
    await tester.tap(scan);
    await tester.pumpAndSettle();
    expect(chosenScanPaths, isNotNull);
    expect(chosenScanPaths, hasLength(1));
    expect(chosenScanPaths!.single, isNotEmpty);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpFrames(WidgetTester tester, {int count = 6}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}
