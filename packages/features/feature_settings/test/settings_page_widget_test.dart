import 'dart:io';

import 'package:feature_settings/feature_settings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';
import 'package:konata_storage/konata_storage.dart';

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

void main() {
  testWidgets('桌面端分栏按 order 排列外部注入设置分区且支持存储诊断与外链交互', (tester) async {
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

    final externalSections = <SettingsSectionContribution>[
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
      sections: externalSections,
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
      ProviderScope(
        overrides: [
          featureSettingsDependenciesProvider.overrideWithValue(deps),
        ],
        child: MaterialApp(
          theme: KonataTheme.darkTheme(),
          home: KonataToastScope(
            controller: toastCtrl,
            child: Scaffold(
              body: featureSettingsManifest.navSections.single
                      .viewBuilder(const ViewSlotContext())
                  as Widget,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('外观与显示'), findsOneWidget);
    expect(find.text('网络与元数据凭据'), findsOneWidget);
    expect(find.text('外部播放器（仅桌面）'), findsOneWidget);
    expect(find.text('跨设备同步服务'), findsOneWidget);
    expect(find.text('存储与图片缓存'), findsOneWidget);
    expect(find.text('关于 Konata'), findsOneWidget);

    // 验证按 order 升序排列：appearance(10) < ext_desktop_player(30) < ext_sync(50)。
    final appearanceTop = tester.getTopLeft(find.text('外观与显示')).dy;
    final desktopExtTop = tester.getTopLeft(find.text('外部播放器（仅桌面）')).dy;
    final syncExtTop = tester.getTopLeft(find.text('跨设备同步服务')).dy;
    expect(appearanceTop, lessThan(desktopExtTop));
    expect(desktopExtTop, lessThan(syncExtTop));

    await tester.tap(find.text('外部播放器（仅桌面）'));
    await tester.pumpAndSettle();
    expect(find.text('桌面外部播放器占位面板'), findsOneWidget);

    await tester.tap(find.text('存储与图片缓存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导出脱敏 JSON 诊断包'));
    await tester.pumpAndSettle();
    expect(backupPort.savedFiles.length, equals(1));

    await tester.tap(find.text('关于 Konata'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('GitHub 开源主页'));
    await tester.pump();
    expect(urlOpener.openedUris.single.host, equals('github.com'));
  });

  testWidgets('手机端按平台过滤桌面专属分区并支持二级页面推入与返回', (tester) async {
    final tempDir = Directory.systemTemp.createTempSync('konata_settings_phone_');
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
      ProviderScope(
        overrides: [
          featureSettingsDependenciesProvider.overrideWithValue(deps),
        ],
        child: MaterialApp(
          theme: KonataTheme.darkTheme(),
          home: KonataToastScope(
            controller: toastCtrl,
            child: const Scaffold(body: SettingsPage()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 桌面独占扩展项必须被严格过滤。
    expect(find.text('Windows 桌面独占项'), findsNothing);
    expect(find.text('全平台扩展设置'), findsOneWidget);

    // 手机一级列表点击进入二级详情路由。
    await tester.tap(find.text('外观与显示'));
    await tester.pumpAndSettle();
    expect(detailStates.last, isTrue);
    expect(find.text('浅色模式'), findsOneWidget);

    await tester.tap(find.text('浅色模式'));
    await tester.pumpAndSettle();
    expect(selectedModes, equals(<ThemeMode>[ThemeMode.light]));

    // 返回手机一级分类页。
    await tester.tap(find.byKey(const ValueKey('settings_detail_back')));
    await tester.pumpAndSettle();
    expect(detailStates.last, isFalse);
    expect(find.text('全平台扩展设置'), findsOneWidget);
  });
}
