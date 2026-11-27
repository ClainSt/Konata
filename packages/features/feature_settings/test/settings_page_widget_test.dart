import 'dart:io';

import 'package:engine_sources/engine_sources.dart';
import 'package:feature_settings/feature_settings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';
import 'package:konata_storage/konata_storage.dart';
import 'package:path/path.dart' as p;

final class _TestStorageRoot implements StorageRootPort {
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

final class _StubNavigator implements AppNavigator {
  @override
  Future<void> openAudioPlayer({
    required WorkId workId,
    VariantId? variantId,
    int? initialCueTrackIndex,
    int? initialPositionSeconds,
  }) async {}

  @override
  Future<void> openSettings({String? sectionId}) async {}

  @override
  Future<void> openVideoPlayer({
    required WorkId workId,
    EpisodeId? episodeId,
    VariantId? variantId,
  }) async {}

  @override
  Future<void> openWorkDetail(WorkId workId, {String? initialTabId}) async {}

  @override
  Future<bool> pop() async => true;

  @override
  Future<void> switchNavSection(String sectionId) async {}
}

final class _StubHttpClient implements KonataHttpClientPort {
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
  }) async => KonataHttpResponse(
    statusCode: 200,
    headers: const <String, String>{},
    bodyBytes: Uint8List(0),
  );

  @override
  Future<KonataHttpResponse> post(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    Object? body,
    RequestPriority priority = RequestPriority.background,
    String? dedupeKey,
    String? bucketKey,
  }) async => KonataHttpResponse(
    statusCode: 200,
    headers: const <String, String>{},
    bodyBytes: Uint8List(0),
  );

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
  }) async => KonataHttpResponse(
    statusCode: 200,
    headers: const <String, String>{},
    bodyBytes: Uint8List(0),
  );

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
  }) async => KonataHttpResponse(
    statusCode: 200,
    headers: const <String, String>{},
    bodyBytes: Uint8List(0),
  );
}

final class _FakeBackupFilePort implements BackupFilePort {
  final List<String> savedFiles = <String>[];

  @override
  Future<String?> pickBackupFile({
    String? dialogTitle,
    List<String> allowedExtensions = const <String>[],
  }) async => null;

  @override
  Future<String?> saveFile({
    required String fileName,
    required Uint8List bytes,
    String? dialogTitle,
  }) async {
    savedFiles.add(fileName);
    return '/tmp/$fileName';
  }
}

final class _FakeUrlOpener implements UrlOpenerPort {
  final List<Uri> openedUris = <Uri>[];

  @override
  Future<bool> openExternalUrl(Uri uri) async {
    openedUris.add(uri);
    return true;
  }
}

final class _StubLog implements DiagnosticLogPort {
  @override
  void clear() {}

  @override
  Future<String> buildJsonBundle() async => '{"status":"ok"}';

  @override
  Future<String> buildTextReport() async => 'diagnostic ok';

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
    totalEvents: 1,
    warningCount: 0,
    errorCount: 0,
    breadcrumbCount: 0,
  );

  @override
  bool get verboseEnabled => false;
}

Widget _buildHarness({
  required FeatureSettingsDependencies deps,
  required KonataToastController toastCtrl,
  required Widget child,
}) {
  return ProviderScope(
    overrides: [featureSettingsDependenciesProvider.overrideWithValue(deps)],
    child: MaterialApp(
      theme: KonataTheme.darkTheme(),
      home: KonataToastScope(
        controller: toastCtrl,
        child: Scaffold(body: child),
      ),
    ),
  );
}

void main() {
  testWidgets('桌面端分栏按 order 排列分区并支持窗口材质、显示偏好持久化、诊断导出与外链交互', (tester) async {
    final tempDir = Directory.systemTemp.createTempSync('konata_settings_ui_');
    addTearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    final db = KonataDatabaseBundle.openInMemory();
    addTearDown(db.close);

    final backupPort = _FakeBackupFilePort();
    final urlOpener = _FakeUrlOpener();
    final materials = <KonataWindowMaterial>[];
    final ambients = <bool>[];
    final themes = <ThemeMode>[];

    final externalSections = <SettingsSectionContribution>[
      SettingsSectionContribution(
        id: 'display_test_child',
        title: '扩展面板标题',
        iconKey: 'display',
        order: 10,
        parentSectionId: displaySettingsSectionId,
        viewBuilder: (_) => const Text('显示扩展内容'),
      ),
      SettingsSectionContribution(
        id: 'ext_desktop_player',
        title: '外部播放器（仅桌面）',
        subtitle: '仅 Windows 平台可见',
        iconKey: 'player',
        order: 30,
        supportedPlatforms: const <KonataPlatform>{KonataPlatform.windows},
        viewBuilder: (_) => const Text('桌面外部播放器占位面板'),
      ),
      SettingsSectionContribution(
        id: 'ext_sync',
        title: '跨设备同步服务',
        subtitle: '全平台通用的外部注入设置项',
        iconKey: 'sync',
        order: 50,
        viewBuilder: (_) => const Text('外部注入跨设备同步面板'),
      ),
    ];

    final deps = FeatureSettingsDependencies(
      databases: db,
      scopedPrefs: ScopedPrefsStore(db.userState),
      secureStorage: InMemorySecureStorage(),
      httpClient: _StubHttpClient(),
      photosStorage: PhotosStorage(storageRoot: _TestStorageRoot(tempDir.path)),
      backupFilePort: backupPort,
      urlOpener: urlOpener,
      diagnosticLog: _StubLog(),
      navigator: _StubNavigator(),
      currentPlatform: KonataPlatform.windows,
      storageRoot: _TestStorageRoot(tempDir.path),
      sections: externalSections,
      onThemeModeChanged: themes.add,
      onAmbientBackdropChanged: ambients.add,
      onWindowMaterialChanged: materials.add,
    );

    expect(featureSettingsManifest.id, equals('feature_settings'));
    expect(featureSettingsManifest.navSections.single.id, equals('settings'));
    expect(featureSettingsManifest.settingsSections.length, equals(4));

    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final toastCtrl = KonataToastController();
    addTearDown(toastCtrl.dispose);

    await tester.pumpWidget(
      _buildHarness(
        deps: deps,
        toastCtrl: toastCtrl,
        child:
            featureSettingsManifest.navSections.single.viewBuilder(
                  const ViewSlotContext(),
                )
                as Widget,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('外观'), findsOneWidget);
    expect(find.text('显示与存储'), findsOneWidget);
    expect(find.text('刮削与网络'), findsOneWidget);
    expect(find.text('外部播放器（仅桌面）'), findsOneWidget);
    expect(find.text('跨设备同步服务'), findsOneWidget);
    expect(find.text('关于'), findsOneWidget);

    // 验证按 order 升序排列：appearance(10) < display(15) < network(20) < ext_desktop_player(30) < ext_sync(50)。
    final appearanceTop = tester.getTopLeft(find.text('外观')).dy;
    final displayTop = tester.getTopLeft(find.text('显示与存储')).dy;
    final networkTop = tester.getTopLeft(find.text('刮削与网络')).dy;
    final desktopExtTop = tester.getTopLeft(find.text('外部播放器（仅桌面）')).dy;
    final syncExtTop = tester.getTopLeft(find.text('跨设备同步服务')).dy;
    expect(appearanceTop, lessThan(displayTop));
    expect(displayTop, lessThan(networkTop));
    expect(networkTop, lessThan(desktopExtTop));
    expect(desktopExtTop, lessThan(syncExtTop));

    // 默认选中外观面板：三张主题预览卡片与 Windows 桌面材质控制均完整呈现。
    expect(find.text('影院黑曜石'), findsOneWidget);
    expect(find.text('画册米白'), findsOneWidget);
    expect(find.text('自动适配系统'), findsOneWidget);
    expect(find.text('窗口材质'), findsOneWidget);
    expect(find.text('流光氛围画布'), findsOneWidget);

    await tester.tap(find.text('云母'));
    await tester.pumpAndSettle();
    expect(
      materials,
      equals(<KonataWindowMaterial>[KonataWindowMaterial.mica]),
    );
    expect(find.text(KonataWindowMaterial.mica.subtitle), findsOneWidget);

    await tester.tap(find.text('云母变体'));
    await tester.pumpAndSettle();
    expect(
      materials,
      equals(<KonataWindowMaterial>[
        KonataWindowMaterial.mica,
        KonataWindowMaterial.tabbed,
      ]),
    );
    expect(find.text(KonataWindowMaterial.tabbed.subtitle), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('settings_ambient_canvas_switch')),
    );
    await tester.pumpAndSettle();
    expect(ambients, equals(<bool>[true]));

    await tester.tap(find.text('显示与存储'));
    await tester.pumpAndSettle();
    expect(find.text('扩展面板标题'), findsNothing);
    expect(find.text('显示扩展内容'), findsOneWidget);
    expect(find.text('本地图片存储'), findsOneWidget);

    // 切换至外部注入面板。
    await tester.tap(find.text('外部播放器（仅桌面）'));
    await tester.pumpAndSettle();
    expect(find.text('桌面外部播放器占位面板'), findsOneWidget);

    // 切换至「关于」验证结构化诊断包导出与外链打开。
    await tester.tap(find.text('关于'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Schema v3'), findsNothing);
    expect(find.text('导出包含故障信息、运行状态与操作记录的诊断数据'), findsOneWidget);
    await tester.tap(find.text('导出结构化诊断包 (.json)'));
    await tester.pumpAndSettle();
    expect(backupPort.savedFiles.length, equals(1));

    await tester.tap(find.text('ClainSt/Konata'));
    await tester.pump();
    expect(urlOpener.openedUris.single.host, equals('github.com'));
  });

  testWidgets('手机端按平台过滤桌面专属分区、隐藏窗口材质并支持二级页面推入与返回', (tester) async {
    final tempDir = Directory.systemTemp.createTempSync(
      'konata_settings_phone_',
    );
    addTearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    final db = KonataDatabaseBundle.openInMemory();
    addTearDown(db.close);
    final detailStates = <bool>[];
    final selectedModes = <ThemeMode>[];

    final deps = FeatureSettingsDependencies(
      databases: db,
      scopedPrefs: ScopedPrefsStore(db.userState),
      secureStorage: InMemorySecureStorage(),
      httpClient: _StubHttpClient(),
      photosStorage: PhotosStorage(storageRoot: _TestStorageRoot(tempDir.path)),
      backupFilePort: _FakeBackupFilePort(),
      urlOpener: _FakeUrlOpener(),
      diagnosticLog: _StubLog(),
      navigator: _StubNavigator(),
      currentPlatform: KonataPlatform.androidPhone,
      storageRoot: _TestStorageRoot(tempDir.path),
      onThemeModeChanged: selectedModes.add,
      onDetailVisibilityChanged: detailStates.add,
      sections: [
        SettingsSectionContribution(
          id: 'win_only',
          title: 'Windows 桌面独占项',
          iconKey: 'player',
          order: 30,
          supportedPlatforms: const <KonataPlatform>{KonataPlatform.windows},
          viewBuilder: (_) => const SizedBox.shrink(),
        ),
        SettingsSectionContribution(
          id: 'mobile_ext',
          title: '全平台扩展设置',
          subtitle: '支持移动端与桌面端的外部扩展面板',
          iconKey: 'sync',
          order: 50,
          viewBuilder: (_) => const Text('全平台扩展设置正文'),
        ),
      ],
    );

    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(390, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final toastCtrl = KonataToastController();
    addTearDown(toastCtrl.dispose);

    await tester.pumpWidget(
      _buildHarness(
        deps: deps,
        toastCtrl: toastCtrl,
        child: const SettingsPage(),
      ),
    );
    await tester.pumpAndSettle();

    // 桌面独占扩展项必须被严格过滤。
    expect(find.text('Windows 桌面独占项'), findsNothing);
    expect(find.text('全平台扩展设置'), findsOneWidget);

    // 手机一级列表点击进入二级详情路由，且自动隐藏桌面窗口材质区块。
    await tester.tap(find.text('外观'));
    await tester.pumpAndSettle();
    expect(detailStates.last, isTrue);
    expect(find.text('浅色模式'), findsOneWidget);
    expect(find.text('窗口材质'), findsNothing);
    expect(find.text('流光氛围画布'), findsNothing);

    await tester.tap(find.text('浅色模式'));
    await tester.pumpAndSettle();
    expect(selectedModes, equals(<ThemeMode>[ThemeMode.light]));

    // 返回手机一级分类页。
    await tester.tap(find.byKey(const ValueKey('settings_detail_back')));
    await tester.pumpAndSettle();
    expect(detailStates.last, isFalse);
    expect(find.text('全平台扩展设置'), findsOneWidget);
  });

  testWidgets('兼容旧深链 storage 并支持刮削网络测速与自定义图片清理弹窗', (tester) async {
    final tempDir = Directory.systemTemp.createTempSync(
      'konata_settings_deep_',
    );
    addTearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    final db = KonataDatabaseBundle.openInMemory();
    addTearDown(db.close);

    final photosStorage = PhotosStorage(
      storageRoot: _TestStorageRoot(tempDir.path),
    );
    final photosRoot = await photosStorage.resolveRootDirectory();
    final orphanThumb = File(
      p.join(photosRoot.path, '已移除旧作 [orphan_1]', 'thumbnails', 'ep01.jpg'),
    )..createSync(recursive: true);
    orphanThumb.writeAsBytesSync(List<int>.filled(1024, 5));

    final deps = FeatureSettingsDependencies(
      databases: db,
      scopedPrefs: ScopedPrefsStore(db.userState),
      secureStorage: InMemorySecureStorage(),
      httpClient: _StubHttpClient(),
      photosStorage: photosStorage,
      backupFilePort: _FakeBackupFilePort(),
      urlOpener: _FakeUrlOpener(),
      diagnosticLog: _StubLog(),
      navigator: _StubNavigator(),
      currentPlatform: KonataPlatform.windows,
      storageRoot: _TestStorageRoot(tempDir.path),
      connectivityProbeOverride: (targetId) async => ConnectivityReport(
        reachable: true,
        latencyMs: 42,
        resolvedAddress: targetId,
        statusSummary: '官方直连成功 (42ms)',
      ),
    );

    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final toastCtrl = KonataToastController();
    addTearDown(toastCtrl.dispose);

    await tester.pumpWidget(
      _buildHarness(
        deps: deps,
        toastCtrl: toastCtrl,
        child: const SettingsPage(initialSectionId: 'storage'),
      ),
    );
    await tester.pumpAndSettle();

    // 旧深链 `storage` 自动落地到「显示与存储」面板。
    expect(find.text('本地图片存储'), findsOneWidget);
    expect(find.text('本地图片存储'), findsOneWidget);
    expect(find.text('打开 photos 文件夹'), findsOneWidget);

    // 打开「自定义图片清理」弹窗并执行精确清理。
    await tester.tap(
      find.byKey(const ValueKey('settings_photos_custom_cleanup_button')),
    );
    await tester.pumpAndSettle();
    expect(find.text('自定义图片清理'), findsOneWidget);
    expect(find.text('残留目录'), findsOneWidget);
    await tester.tap(find.text('清理所选'));
    await tester.pumpAndSettle();
    expect(orphanThumb.existsSync(), isFalse);

    // 切换至「刮削与网络」并运行连通测速。
    await tester.tap(find.text('刮削与网络'));
    await tester.pumpAndSettle();
    expect(find.text('TMDB API 密钥'), findsOneWidget);
    expect(find.text('离线动画映射表'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('probe_tmdb_api')));
    await tester.pumpAndSettle();
    expect(find.text('官方直连成功 (42ms)'), findsOneWidget);

    expect(tester.takeException(), isNull);
  });

  testWidgets('四端标准视口切换各设置面板保持零溢出与零异常', (tester) async {
    final tempDir = Directory.systemTemp.createTempSync('konata_settings_vp_');
    addTearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    final db = KonataDatabaseBundle.openInMemory();
    addTearDown(db.close);

    final viewports =
        <
          ({
            String label,
            Size size,
            TargetPlatform target,
            KonataPlatform platform,
          })
        >[
          (
            label: '手机竖屏',
            size: const Size(390, 780),
            target: TargetPlatform.android,
            platform: KonataPlatform.androidPhone,
          ),
          (
            label: '手机横屏',
            size: const Size(780, 390),
            target: TargetPlatform.android,
            platform: KonataPlatform.androidPhone,
          ),
          (
            label: '平板横屏',
            size: const Size(1024, 700),
            target: TargetPlatform.android,
            platform: KonataPlatform.androidTablet,
          ),
          (
            label: '桌面宽屏',
            size: const Size(1440, 900),
            target: TargetPlatform.windows,
            platform: KonataPlatform.windows,
          ),
        ];

    for (final vp in viewports) {
      debugDefaultTargetPlatformOverride = vp.target;
      tester.view.physicalSize = vp.size;
      tester.view.devicePixelRatio = 1.0;

      final deps = FeatureSettingsDependencies(
        databases: db,
        scopedPrefs: ScopedPrefsStore(db.userState),
        secureStorage: InMemorySecureStorage(),
        httpClient: _StubHttpClient(),
        photosStorage: PhotosStorage(
          storageRoot: _TestStorageRoot(tempDir.path),
        ),
        backupFilePort: _FakeBackupFilePort(),
        urlOpener: _FakeUrlOpener(),
        diagnosticLog: _StubLog(),
        navigator: _StubNavigator(),
        currentPlatform: vp.platform,
        storageRoot: _TestStorageRoot(tempDir.path),
      );
      final toastCtrl = KonataToastController();

      await tester.pumpWidget(
        _buildHarness(
          deps: deps,
          toastCtrl: toastCtrl,
          child: const SettingsPage(),
        ),
      );
      await tester.pumpAndSettle();

      if (vp.platform == KonataPlatform.androidPhone) {
        for (final label in const <String>['外观', '显示与存储', '刮削与网络', '关于']) {
          await tester.tap(find.text(label));
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: '${vp.label} 进入「$label」不应发生溢出或异常',
          );
          await tester.tap(find.byKey(const ValueKey('settings_detail_back')));
          await tester.pumpAndSettle();
        }
      } else {
        for (final label in const <String>['外观', '显示与存储', '刮削与网络', '关于']) {
          await tester.tap(find.text(label));
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: '${vp.label} 切换「$label」不应发生溢出或异常',
          );
        }
      }

      toastCtrl.dispose();
    }

    debugDefaultTargetPlatformOverride = null;
    tester.view.reset();
  });
}
