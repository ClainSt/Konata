import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:engine_sources/engine_sources.dart';
import 'package:feature_settings/feature_settings.dart';
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

final class _FakeHttpClient implements KonataHttpClientPort {
  KonataNetworkConfig _config = const KonataNetworkConfig();
  final List<KonataNetworkConfig> updatedConfigs = <KonataNetworkConfig>[];

  @override
  KonataNetworkConfig get config => _config;

  @override
  void updateConfig(KonataNetworkConfig next) {
    _config = next;
    updatedConfigs.add(next);
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
  final List<({String fileName, Uint8List bytes, String? dialogTitle})> saved =
      <({String fileName, Uint8List bytes, String? dialogTitle})>[];

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
    saved.add((fileName: fileName, bytes: bytes, dialogTitle: dialogTitle));
    return 'D:/Exports/$fileName';
  }
}

final class _FakeUrlOpener implements UrlOpenerPort {
  final List<Uri> opened = <Uri>[];

  @override
  Future<bool> openExternalUrl(Uri uri) async {
    opened.add(uri);
    return true;
  }
}

final class _SensitiveDiagnosticLog implements DiagnosticLogPort {
  bool _verbose = false;
  int _events = 2;

  @override
  void clear() {
    _events = 0;
  }

  @override
  Future<String> buildJsonBundle() async => jsonEncode(<String, Object?>{
    'path': r'C:\Users\sakura\Videos\Anime\ep01.mkv',
    'tmdbError': 'api_key=tmdb_secret_key_abc123&token=my_fanart_key_xyz',
  });

  @override
  Future<String> buildTextReport() async =>
      r'Local file C:\Users\sakura\desktop failed with token=my_fanart_key_xyz';

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
  }) {
    _events++;
  }

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
  void setVerbose(bool enabled) {
    _verbose = enabled;
  }

  @override
  List<DiagnosticEvent> snapshotEvents() => const <DiagnosticEvent>[];

  @override
  List<DiagnosticFaultSummary> summarizeFaults() =>
      const <DiagnosticFaultSummary>[];

  @override
  DiagnosticSummaryCounts get summaryCounts => DiagnosticSummaryCounts(
    totalEvents: _events,
    warningCount: 1,
    errorCount: 0,
    breadcrumbCount: 0,
  );

  @override
  bool get verboseEnabled => _verbose;
}

void main() {
  late Directory tempDir;
  late KonataDatabaseBundle db;
  late ScopedPrefsStore scopedPrefs;
  late InMemorySecureStorage secureStorage;
  late _FakeHttpClient httpClient;
  late PhotosStorage photosStorage;
  late _FakeBackupFilePort backupFilePort;
  late _FakeUrlOpener urlOpener;
  late _SensitiveDiagnosticLog diagnosticLog;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('konata_settings_unit_');
    db = KonataDatabaseBundle.openInMemory();
    scopedPrefs = ScopedPrefsStore(db.userState);
    secureStorage = InMemorySecureStorage();
    httpClient = _FakeHttpClient();
    photosStorage = PhotosStorage(storageRoot: _TestStorageRoot(tempDir.path));
    backupFilePort = _FakeBackupFilePort();
    urlOpener = _FakeUrlOpener();
    diagnosticLog = _SensitiveDiagnosticLog();
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('主题与流光设置持久落盘并触发宿主变更回调', () async {
    final themes = <ThemeMode>[];
    final ambients = <bool>[];

    final controller = SettingsController(
      databases: db,
      scopedPrefs: scopedPrefs,
      secureStorage: secureStorage,
      httpClient: httpClient,
      photosStorage: photosStorage,
      backupFilePort: backupFilePort,
      urlOpener: urlOpener,
      diagnosticLog: diagnosticLog,
      storageRoot: _TestStorageRoot(tempDir.path),
      onThemeModeChanged: themes.add,
      onAmbientBackdropChanged: ambients.add,
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    controller.setThemeMode(ThemeMode.light);
    controller.setAmbientBackdropEnabled(false);

    expect(themes, equals(<ThemeMode>[ThemeMode.light]));
    expect(ambients, equals(<bool>[false]));

    final persisted = SettingsAppearanceRepository(scopedPrefs).read();
    expect(persisted.themeMode, equals(ThemeMode.light));
    expect(persisted.ambientBackdropEnabled, isFalse);
  });

  test('Windows 窗口材质切换持久落盘并触发宿主变更回调且不覆盖其余外观字段', () async {
    final materials = <KonataWindowMaterial>[];

    final controller = SettingsController(
      databases: db,
      scopedPrefs: scopedPrefs,
      secureStorage: secureStorage,
      httpClient: httpClient,
      photosStorage: photosStorage,
      backupFilePort: backupFilePort,
      urlOpener: urlOpener,
      diagnosticLog: diagnosticLog,
      storageRoot: _TestStorageRoot(tempDir.path),
      onWindowMaterialChanged: materials.add,
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    controller.setThemeMode(ThemeMode.light);
    controller.setAmbientBackdropEnabled(false);
    controller.setWindowMaterial(KonataWindowMaterial.mica);
    controller.setWindowMaterial(KonataWindowMaterial.tabbed);

    expect(
      materials,
      equals(<KonataWindowMaterial>[
        KonataWindowMaterial.mica,
        KonataWindowMaterial.tabbed,
      ]),
    );

    final persisted = SettingsAppearanceRepository(scopedPrefs).read();
    expect(persisted.themeMode, equals(ThemeMode.light));
    expect(persisted.ambientBackdropEnabled, isFalse);
    expect(persisted.windowMaterial, equals(KonataWindowMaterial.tabbed));
  });

  test('显示偏好读写共享 feature_detail.display 分片且完整保留既有四字段', () async {
    db.userState.scopedPrefs.upsert(
      ScopedPrefRecord(
        namespace: 'feature_detail.display',
        schemaVersion: 1,
        syncPolicy: SyncPolicy.portable,
        payloadJson: jsonEncode(<String, Object?>{
          'showMainHeroBackdrop': false,
          'showEpisodeStillThumbnails': false,
          'showOriginalSubtitlesOnCards': false,
          'autoSilentWarmup': false,
          'futureUnknownKey': 'preserve-value',
        }),
        updatedAtMs: 1000,
      ),
    );

    final controller = SettingsController(
      databases: db,
      scopedPrefs: scopedPrefs,
      secureStorage: secureStorage,
      httpClient: httpClient,
      photosStorage: photosStorage,
      backupFilePort: backupFilePort,
      urlOpener: urlOpener,
      diagnosticLog: diagnosticLog,
      storageRoot: _TestStorageRoot(tempDir.path),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    expect(controller.displayPrefs.showMainHeroBackdrop, isFalse);
    expect(controller.displayPrefs.showEpisodeStillThumbnails, isFalse);
    expect(controller.displayPrefs.showOriginalSubtitlesOnCards, isFalse);
    expect(controller.displayPrefs.autoSilentWarmup, isFalse);
    expect(controller.displayPrefs.showTitleText, isTrue);
    expect(controller.displayPrefs.showTitleLogo, isTrue);
    expect(controller.displayPrefs.showOverview, isTrue);
    expect(controller.displayPrefs.showRawVideoFilename, isFalse);
    expect(controller.displayPrefs.showCdTab, isTrue);
    expect(controller.displayPrefs.showScanTab, isTrue);

    controller.setShowTitleText(false);
    controller.setShowTitleLogo(false);
    controller.setShowOverview(false);
    controller.setShowRawVideoFilename(true);
    controller.setShowCdTab(false);
    controller.setShowScanTab(false);

    final record = db.userState.scopedPrefs.findByNamespace(
      'feature_detail.display',
    )!;
    expect(record.syncPolicy, equals(SyncPolicy.portable));
    expect(record.schemaVersion, equals(1));
    final decoded = jsonDecode(record.payloadJson) as Map<String, dynamic>;
    expect(decoded['showMainHeroBackdrop'], isFalse);
    expect(decoded['showEpisodeStillThumbnails'], isFalse);
    expect(decoded['showOriginalSubtitlesOnCards'], isFalse);
    expect(decoded['autoSilentWarmup'], isFalse);
    expect(decoded['futureUnknownKey'], equals('preserve-value'));
    expect(decoded['showTitleText'], isFalse);
    expect(decoded['showTitleLogo'], isFalse);
    expect(decoded['showOverview'], isFalse);
    expect(decoded['showRawVideoFilename'], isTrue);
    expect(decoded['showCdTab'], isFalse);
    expect(decoded['showScanTab'], isFalse);
  });

  test('网络凭据与代理镜像分离持久化且脱敏诊断包剥离敏感信息', () async {
    final controller = SettingsController(
      databases: db,
      scopedPrefs: scopedPrefs,
      secureStorage: secureStorage,
      httpClient: httpClient,
      photosStorage: photosStorage,
      backupFilePort: backupFilePort,
      urlOpener: urlOpener,
      diagnosticLog: diagnosticLog,
      storageRoot: _TestStorageRoot(tempDir.path),
      connectivityProbeOverride: (targetId) async => ConnectivityReport(
        reachable: true,
        latencyMs: 36,
        resolvedAddress: targetId,
      ),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    const nextNetwork = KonataNetworkConfig(
      credential: 'tmdb_secret_key_abc123',
      fanartClientKey: 'my_fanart_key_xyz',
      proxyMode: ProxyMode.custom,
      proxyUrl: 'http://127.0.0.1:7890',
      tmdbBackupApiBase: 'https://mirror.example.com/tmdb',
    );
    await controller.saveNetworkConfig(nextNetwork);

    expect(
      await secureStorage.read(SettingsNetworkRepository.tmdbCredentialKey),
      equals('tmdb_secret_key_abc123'),
    );
    expect(
      await secureStorage.read(
        SettingsNetworkRepository.fanartClientKeyStorageKey,
      ),
      equals('my_fanart_key_xyz'),
    );

    final rawPrefsJson = db.userState.scopedPrefs
        .findByNamespace('feature_settings.network')
        ?.payloadJson;
    expect(rawPrefsJson, isNotNull);
    expect(rawPrefsJson, isNot(contains('tmdb_secret_key_abc123')));
    expect(rawPrefsJson, isNot(contains('my_fanart_key_xyz')));
    expect(httpClient.config.proxyMode, equals(ProxyMode.custom));

    final probe = await controller.runConnectivityProbe(
      NetworkProbeTargets.tmdbApi,
    );
    expect(probe.reachable, isTrue);
    expect(probe.latencyMs, equals(36));

    final exportedPath = await controller.exportDiagnosticBundle(asJson: true);
    expect(exportedPath, isNotNull);
    expect(backupFilePort.saved.length, equals(1));
    final exportedText = utf8.decode(backupFilePort.saved.single.bytes);
    expect(exportedText, isNot(contains('tmdb_secret_key_abc123')));
    expect(exportedText, isNot(contains('my_fanart_key_xyz')));
    expect(exportedText, isNot(contains('sakura')));
    expect(exportedText, contains('<USER_HOME>'));

    final textReportPath = await controller.exportDiagnosticBundle(asJson: false);
    expect(textReportPath, isNotNull);
    final plainText = utf8.decode(backupFilePort.saved.last.bytes);
    expect(plainText, isNot(contains('my_fanart_key_xyz')));
    expect(plainText, isNot(contains(r'C:\Users\sakura')));
    expect(plainText, contains('<USER_HOME>'));
  });

  test('图片统计扫描识别孤儿目录并支持按作品目录与分类精准清理', () async {
    db.library.works.upsert(
      const WorkRecord(
        id: WorkId.trusted('work_a'),
        title: '轻音少女',
      ),
    );
    final photosRoot = await photosStorage.resolveRootDirectory();
    final workPoster = File(
      p.join(photosRoot.path, '轻音少女 [work_a]', 'posters', 'cover.jpg'),
    )..createSync(recursive: true);
    workPoster.writeAsBytesSync(List<int>.filled(400, 1));

    final workThumb = File(
      p.join(photosRoot.path, '轻音少女 [work_a]', 'thumbnails', 'ep1.jpg'),
    )..createSync(recursive: true);
    workThumb.writeAsBytesSync(List<int>.filled(900, 2));

    final orphanScan = File(
      p.join(photosRoot.path, '已移除旧番 [work_orphan]', 'scans', 'page1.webp'),
    )..createSync(recursive: true);
    orphanScan.writeAsBytesSync(List<int>.filled(700, 3));

    final controller = SettingsController(
      databases: db,
      scopedPrefs: scopedPrefs,
      secureStorage: secureStorage,
      httpClient: httpClient,
      photosStorage: photosStorage,
      backupFilePort: backupFilePort,
      urlOpener: urlOpener,
      diagnosticLog: diagnosticLog,
      storageRoot: _TestStorageRoot(tempDir.path),
    );
    addTearDown(controller.dispose);
    await controller.refreshPhotosStorage();

    final snapshot = controller.photosSnapshot!;
    expect(snapshot.globalStats.totalFiles, equals(3));
    expect(snapshot.globalStats.totalBytes, equals(2000));
    expect(snapshot.workEntries.length, equals(2));
    expect(
      snapshot.workEntries.where((e) => e.workId == 'work_orphan').single.isOrphan,
      isTrue,
    );

    final customResult = await controller.clearCustomPhotos(
      workDirKeys: const <String>{'轻音少女 [work_a]'},
      categories: const <PhotoStorageCategory>{PhotoStorageCategory.thumbnails},
    );
    expect(customResult.removedFiles, equals(1));
    expect(customResult.freedBytes, equals(900));
    expect(workPoster.existsSync(), isTrue);
    expect(workThumb.existsSync(), isFalse);
    expect(orphanScan.existsSync(), isTrue);

    final removed = await controller.clearRegenerableCaches();
    expect(removed, equals(1));
    expect(orphanScan.existsSync(), isFalse);
  });
}
