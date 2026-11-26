import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:feature_sync/feature_sync.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';
import 'package:konata_storage/konata_storage.dart';

final class _RecordingBackupFilePort implements BackupFilePort {
  String? pathToPick;
  String? pathToSave = r'C:\virtual\exported_backup.konata';
  String? lastSavedFileName;
  Uint8List? lastSavedBytes;

  @override
  Future<String?> pickBackupFile({
    String? dialogTitle,
    List<String> allowedExtensions = const <String>['konata', 'json'],
  }) async {
    return pathToPick;
  }

  @override
  Future<String?> saveFile({
    required String fileName,
    required Uint8List bytes,
    String? dialogTitle,
  }) async {
    lastSavedFileName = fileName;
    lastSavedBytes = bytes;
    return pathToSave;
  }
}

final class _FakeWidgetExtraSlice
    implements SyncSliceContributor<List<Map<String, Object?>>> {
  final Map<String, Map<String, Object?>> entries =
      <String, Map<String, Object?>>{};

  @override
  String get sliceId => 'lyric_overrides_slice';

  @override
  String get displayName => '歌词人工修正';

  @override
  int get schemaVersion => 1;

  @override
  Future<SyncSlicePayload> exportSlice({required String localDeviceId}) async {
    return SyncSlicePayload(
      sliceId: sliceId,
      schemaVersion: schemaVersion,
      exportedAtMs: 1000,
      sourceDeviceId: localDeviceId,
      data: <String, Object?>{'items': entries.values.toList(growable: false)},
    );
  }

  @override
  SyncMergePlan<List<Map<String, Object?>>> planMerge({
    required SyncSlicePayload local,
    required SyncSlicePayload remote,
  }) {
    final remoteList = (remote.data['items'] as List<Object?>?) ?? const [];
    final localMap = <String, Object?>{
      for (final item in ((local.data['items'] as List<Object?>?) ?? const []))
        if (item is Map) item['id'].toString(): item,
    };
    final updates = <Map<String, Object?>>[];
    for (final raw in remoteList) {
      if (raw is! Map) continue;
      final item = SyncSanitizer.coerceStringKeyMap(raw);
      if (!localMap.containsKey(item['id'].toString())) {
        updates.add(item);
      }
    }
    return SyncMergePlan<List<Map<String, Object?>>>(
      sliceId: sliceId,
      insertCount: updates.length,
      updateCount: 0,
      deleteCount: 0,
      skippedCount: 0,
      planData: List<Map<String, Object?>>.unmodifiable(updates),
    );
  }

  @override
  SyncApplyCompletion applyMergePlan(
    SyncTransactionContext tx,
    SyncMergePlan<List<Map<String, Object?>>> plan,
  ) {
    for (final item in plan.planData) {
      entries[item['id'].toString()] = item;
    }
    return SyncApplyCompletion.completed;
  }
}

final class _WidgetFakeWebDavServer {
  final Map<String, Uint8List> files = <String, Uint8List>{};

  http.Client createClient() => _WidgetFakeHttpClient(this);
}

final class _WidgetFakeHttpClient extends http.BaseClient {
  _WidgetFakeHttpClient(this._server);
  final _WidgetFakeWebDavServer _server;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final method = request.method.toUpperCase();
    final path = request.url.path;
    if (method == 'MKCOL') {
      return http.StreamedResponse(Stream<List<int>>.value(const <int>[]), 201);
    }
    if (method == 'GET') {
      final data = _server.files[path];
      if (data == null) {
        return http.StreamedResponse(
          Stream<List<int>>.value(const <int>[]),
          404,
        );
      }
      return http.StreamedResponse(
        Stream<List<int>>.value(data),
        200,
        contentLength: data.length,
        headers: {'etag': '"widget-etag"'},
      );
    }
    if (method == 'PUT') {
      final body = await request.finalize().toBytes();
      _server.files[path] = Uint8List.fromList(body);
      return http.StreamedResponse(Stream<List<int>>.value(const <int>[]), 201);
    }
    return http.StreamedResponse(Stream<List<int>>.value(const <int>[]), 405);
  }
}

Widget _wrapForTest({
  required Widget child,
  required KonataToastController toastController,
  required FeatureSyncDependencies dependencies,
  bool isDark = true,
}) {
  final themeData = isDark ? KonataTheme.darkTheme() : KonataTheme.lightTheme();
  return ProviderScope(
    overrides: [
      featureSyncDependenciesProvider.overrideWithValue(dependencies),
    ],
    child: KonataToastScope(
      controller: toastController,
      child: KonataBottomClearanceScope(
        bottomClearance: 0,
        child: MaterialApp(
          theme: themeData,
          home: Scaffold(
            body: Stack(
              children: <Widget>[
                child,
                KonataToastViewport(controller: toastController),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('featureSyncManifest 与 SettingsBackupSyncPanel 组件测试', () {
    test('featureSyncManifest 正确声明设置入口与三个内置同步切片', () {
      expect(featureSyncManifest.id, 'feature_sync');
      expect(featureSyncManifest.settingsSections, hasLength(1));
      expect(featureSyncManifest.settingsSections.single.id, 'backup_sync');
      expect(
        featureSyncManifest.syncSlices.map((s) => s.sliceId),
        equals(<String>[
          'prefs_slice',
          'playback_history_slice',
          'library_catalog_slice',
        ]),
      );
    });

    testWidgets('多端视口与明暗主题（1440x900 / 1024x700 / 390x780 / 844x390）零溢出渲染', (
      tester,
    ) async {
      final db = KonataDatabaseBundle.openInMemory();
      addTearDown(db.close);
      final prefs = ScopedPrefsStore(db.userState);
      final secure = InMemorySecureStorage();
      final extra = _FakeWidgetExtraSlice();

      final cases = <({Size size, bool dark})>[
        (size: const Size(1440, 900), dark: true),
        (size: const Size(1024, 700), dark: false),
        (size: const Size(390, 780), dark: true),
        (size: const Size(844, 390), dark: false),
      ];

      for (final item in cases) {
        tester.view.physicalSize = item.size;
        tester.view.devicePixelRatio = 1.0;

        final toastCtrl = KonataToastController();
        await tester.pumpWidget(
          _wrapForTest(
            toastController: toastCtrl,
            isDark: item.dark,
            dependencies: FeatureSyncDependencies(
              databases: db,
              scopedPrefs: prefs,
              secureStorage: secure,
              extraSlices: <SyncSliceContributor<Object?>>[extra],
            ),
            child: const SettingsBackupSyncPanel(),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('创建备份与恢复'), findsOneWidget);
        expect(find.text('WebDAV 同步'), findsOneWidget);
        expect(find.text('歌词人工修正'), findsNothing);
        expect(tester.takeException(), isNull);
        toastCtrl.dispose();
      }
      tester.view.reset();
    });

    testWidgets('旧版 v2 恢复预览锁定全部迁移切片，取消不落库，确认一次性恢复', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final db = KonataDatabaseBundle.openInMemory();
      addTearDown(db.close);
      final toast = KonataToastController();
      addTearDown(toast.dispose);
      final bytes = File(
        'test/fixtures/legacy_backup/legacy-complete-v2.konata',
      ).readAsBytesSync();
      await tester.pumpWidget(
        _wrapForTest(
          toastController: toast,
          dependencies: FeatureSyncDependencies(
            databases: db,
            scopedPrefs: ScopedPrefsStore(db.userState),
            secureStorage: InMemorySecureStorage(),
            backupFilePort: _RecordingBackupFilePort()
              ..pathToPick = '/virtual/legacy.konata',
            readFileBytes: (_) async => bytes,
          ),
          child: const SettingsBackupSyncPanel(),
        ),
      );
      await tester.pumpAndSettle();
      final importBtn = find.byKey(const Key('import_konata_button'));
      Future<void> open() async {
        await tester.ensureVisible(importBtn);
        await tester.tap(importBtn);
        await tester.pumpAndSettle();
        expect(find.textContaining('须一次性智能合并全部项目'), findsOneWidget);
        expect(find.byKey(const Key('restore_mode_segmented')), findsNothing);
        for (final id in [
          'library_catalog_slice',
          'playback_history_slice',
          'prefs_slice',
        ]) {
          final toggle = find.byKey(Key('preview_slice_$id'));
          expect(tester.widget<KonataSwitch>(toggle).value, isTrue);
          expect(tester.widget<KonataSwitch>(toggle).onChanged, isNull);
        }
      }

      await open();
      await tester.tap(find.byKey(const Key('restore_preview_cancel_button')));
      await tester.pumpAndSettle();
      expect(db.library.works.listVisible(), isEmpty);
      await open();
      await tester.tap(find.byKey(const Key('restore_preview_confirm_button')));
      await tester.pumpAndSettle();
      expect(db.library.works.listVisible().single.id.value, 'old-work');
      expect(
        db.userState.playbackRecords
            .listAllWithTombstones()
            .single
            .positionSeconds,
        42,
      );
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('交互覆盖：选择性导出 .konata、干跑预览弹窗确认恢复、以及 WebDAV 凭据存储与立即同步', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // 构造远端设备 A 的一份待导入归档（包含偏好、媒体库与自定义歌词修正切片）。
      final sourceDb = KonataDatabaseBundle.openInMemory();
      addTearDown(sourceDb.close);
      final sourcePrefs = ScopedPrefsStore(sourceDb.userState);
      const appearanceSlice = TypedPrefsSlice<Map<String, Object?>>(
        namespace: 'appearance',
        schemaVersion: 1,
        syncPolicy: SyncPolicy.portable,
        defaultValue: <String, Object?>{},
        encode: _identityEncode,
        decode: _identityDecode,
      );
      sourcePrefs.write(appearanceSlice, <String, Object?>{
        'themeMode': 'dark',
      });
      sourceDb.library.works.upsert(
        WorkRecord(id: WorkId('w-import'), title: '白箱', updatedAtMs: 5000),
      );
      final sourceExtra = _FakeWidgetExtraSlice();
      sourceExtra.entries['ovr-1'] = <String, Object?>{
        'id': 'ovr-1',
        'line': '第 1 行校对',
      };
      final sourceService = KonataBackupService(
        databases: sourceDb,
        scopedPrefs: sourcePrefs,
        deviceStore: SyncDeviceStore(sourceDb.userState.syncMeta),
        extraSlices: <SyncSliceContributor<Object?>>[sourceExtra],
      );
      final incomingArchiveBytes = await sourceService.exportArchiveBytes();

      // 本地目标设备 B 容器配置。
      final targetDb = KonataDatabaseBundle.openInMemory();
      addTearDown(targetDb.close);
      final targetPrefs = ScopedPrefsStore(targetDb.userState);
      final secureStorage = InMemorySecureStorage();
      final eventBus = InMemoryDomainEventBus();
      addTearDown(eventBus.dispose);
      final localExtra = _FakeWidgetExtraSlice();
      final filePort = _RecordingBackupFilePort()
        ..pathToPick = '/virtual/import_sample.konata';
      final fakeWebDavServer = _WidgetFakeWebDavServer();
      final toastCtrl = KonataToastController();
      addTearDown(toastCtrl.dispose);

      final events = <SyncCompletedEvent>[];
      final sub = eventBus.stream.listen((e) {
        if (e is SyncCompletedEvent) events.add(e);
      });
      addTearDown(sub.cancel);

      await tester.pumpWidget(
        _wrapForTest(
          toastController: toastCtrl,
          dependencies: FeatureSyncDependencies(
            databases: targetDb,
            scopedPrefs: targetPrefs,
            secureStorage: secureStorage,
            backupFilePort: filePort,
            eventBus: eventBus,
            extraSlices: <SyncSliceContributor<Object?>>[localExtra],
            httpClientFactory: (_) => fakeWebDavServer.createClient(),
            readFileBytes: (_) async => incomingArchiveBytes,
            nowMs: () => 1700000100000,
          ),
          child: const SettingsBackupSyncPanel(),
        ),
      );
      await tester.pumpAndSettle();

      final exportBtn = find.byKey(const Key('export_konata_button'));
      final exportCatalogToggle = find.byKey(
        const Key('export_slice_library_catalog_slice'),
      );
      expect(exportCatalogToggle, findsNothing);
      await tester.ensureVisible(exportBtn);
      await tester.tap(exportBtn);
      await tester.pumpAndSettle();
      expect(exportCatalogToggle, findsOneWidget);
      await tester.tap(exportCatalogToggle);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('export_backup_cancel_button')));
      await tester.pumpAndSettle();
      expect(exportCatalogToggle, findsNothing);
      expect(filePort.lastSavedBytes, isNull);

      await tester.tap(exportBtn);
      await tester.pumpAndSettle();
      expect(tester.widget<KonataSwitch>(exportCatalogToggle).value, isTrue);
      await tester.tap(exportCatalogToggle);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('export_backup_confirm_button')));
      await tester.pumpAndSettle();
      expect(exportCatalogToggle, findsNothing);
      expect(filePort.lastSavedFileName, endsWith('.konata'));
      expect(filePort.lastSavedBytes, isNotNull);
      final exportedArchive = KonataBackupArchive.parseAndVerify(
        utf8.decode(gzip.decode(filePort.lastSavedBytes!)),
      );
      expect(
        exportedArchive.sliceIds,
        isNot(contains('library_catalog_slice')),
      );
      expect(exportedArchive.sliceIds, contains('lyric_overrides_slice'));

      // 2. 点击“导入并预览恢复”，校验干跑预览弹窗、切换模式及确认仅应用勾选切片。
      final importBtn = find.byKey(const Key('import_konata_button'));
      await tester.ensureVisible(importBtn);
      await tester.tap(importBtn);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('restore_preview_confirm_button')),
        findsOneWidget,
      );
      expect(find.textContaining('预计累计变更'), findsOneWidget);

      // 在弹窗中切换至覆盖还原再切回智能合并，并取消勾选 library_catalog_slice。
      await tester.tap(find.text('覆盖还原'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('智能合并'));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('preview_slice_library_catalog_slice')),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('restore_preview_confirm_button')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('restore_preview_confirm_button')),
        findsNothing,
      );
      expect(targetPrefs.read(appearanceSlice)['themeMode'], 'dark');
      expect(localExtra.entries['ovr-1']?['line'], '第 1 行校对');
      expect(targetDb.library.works.listVisible(), isEmpty);
      expect(events, isNotEmpty);

      // 3. 填写 WebDAV 配置与密码，测试连接、保存配置并立即双向同步。
      final webDavSwitch = find.byKey(const Key('webdav_enabled_switch'));
      await tester.ensureVisible(webDavSwitch);
      await tester.tap(webDavSwitch);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('webdav_url_field')),
        'https://dav.example.com/root',
      );
      await tester.enterText(
        find.byKey(const Key('webdav_remote_dir_field')),
        'konata-cloud',
      );
      await tester.enterText(
        find.byKey(const Key('webdav_username_field')),
        'widget_user',
      );
      await tester.enterText(
        find.byKey(const Key('webdav_password_field')),
        'widget-secret-password',
      );
      await tester.pumpAndSettle();

      final items = find.byKey(const Key('webdav_sync_items'));
      final catalog = find.byKey(
        const Key('webdav_slice_library_catalog_slice'),
      );
      expect(catalog, findsNothing);
      final fields = [
        'webdav_url_field',
        'webdav_remote_dir_field',
        'webdav_username_field',
        'webdav_password_field',
      ];
      for (var i = 1; i < fields.length; i++) {
        expect(
          tester.getTopLeft(find.byKey(Key(fields[i]))).dy,
          greaterThan(tester.getBottomLeft(find.byKey(Key(fields[i - 1]))).dy),
        );
      }
      await tester.ensureVisible(items);
      await tester.tap(
        find.descendant(of: items, matching: find.text('已选 4 / 4')),
      );
      await tester.pumpAndSettle();
      await tester.tap(catalog);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('webdav_items_cancel')));
      await tester.pumpAndSettle();
      expect(catalog, findsNothing);
      await tester.tap(
        find.descendant(of: items, matching: find.text('已选 4 / 4')),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<KonataSwitch>(catalog).value, isTrue);
      await tester.tap(catalog);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('webdav_items_confirm')));
      await tester.pumpAndSettle();
      expect(catalog, findsNothing);
      expect(find.text('已选 3 / 4'), findsOneWidget);
      final testBtn = find.byKey(const Key('webdav_test_button'));
      await tester.ensureVisible(testBtn);
      await tester.tap(testBtn);
      await tester.pumpAndSettle();
      expect(find.textContaining('连接成功'), findsOneWidget);

      final saveBtn = find.byKey(const Key('webdav_save_button'));
      await tester.ensureVisible(saveBtn);
      await tester.tap(saveBtn);
      await tester.pumpAndSettle();

      expect(
        await secureStorage.read(WebDavSyncConfigRepository.passwordSecretKey),
        'widget-secret-password',
      );
      final webDavPrefRow = targetDb.userState.scopedPrefs.findByNamespace(
        'sync_webdav',
      );
      expect(webDavPrefRow, isNotNull);
      expect(
        webDavPrefRow!.payloadJson,
        isNot(contains('widget-secret-password')),
      );

      final syncBtn = find.byKey(const Key('webdav_sync_now_button'));
      await tester.ensureVisible(syncBtn);
      await tester.tap(syncBtn);
      await tester.pumpAndSettle();

      expect(
        fakeWebDavServer.files.containsKey('/root/konata-cloud/manifest.json'),
        isTrue,
      );
      expect(tester.takeException(), isNull);

      // 等待 Toast 自动退场定时器自然完成，防止挂起定时器报错。
      await tester.pump(const Duration(seconds: 5));
    });
  });
}

Map<String, Object?> _identityEncode(Map<String, Object?> value) => value;
Map<String, Object?> _identityDecode(
  Map<String, Object?> json,
  int schemaVersion,
) => json;
