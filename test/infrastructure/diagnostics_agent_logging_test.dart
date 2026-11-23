import 'dart:convert';

import 'package:drift/native.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:konata/application/providers/diagnostics_providers.dart';
import 'package:konata/application/providers/diagnostics_runtime_bridge.dart';
import 'package:konata/application/providers/library_providers.dart';
import 'package:konata/domain/formatting/network_error_sanitizer.dart';
import 'package:konata/domain/logging/diagnostic_event.dart';
import 'package:konata/domain/models/media_source.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/infrastructure/database/drift_library_repository.dart';
import 'package:konata/infrastructure/database/konata_database.dart';
import 'package:konata/infrastructure/logging/diagnostics_log_store.dart';
import 'package:konata/presentation/settings/settings_about_panel.dart';
import 'package:konata/presentation/theme/konata_theme.dart';
import 'package:konata/presentation/widgets/design_system/konata_system_file_picker.dart';

void main() {
  group('Agent 友好结构化诊断日志系统回归', () {
    test('全链路自动脱敏 PAT、Basic/Digest 鉴权、URL 密码、JSON 敏感字段与本机用户路径', () {
      const raw =
          'Authorization: Bearer bgm_super_secret_pat_999 '
          'Basic dXNlcjpwYXNz '
          'response="deadbeef1234" '
          'https://alice:hunter2@nas.example.com/dav '
          '{"password":"my_pw","token":"tok_abc"} '
          r'C:\Users\Alice\Videos\secret.mkv';

      final redacted = NetworkErrorSanitizer.redactForDiagnosticsExport(raw);
      expect(redacted, isNot(contains('bgm_super_secret_pat_999')));
      expect(redacted, isNot(contains('dXNlcjpwYXNz')));
      expect(redacted, isNot(contains('deadbeef1234')));
      expect(redacted, isNot(contains('hunter2')));
      expect(redacted, isNot(contains('my_pw')));
      expect(redacted, isNot(contains('tok_abc')));
      expect(redacted, isNot(contains('Alice')));
      expect(redacted, contains('Bearer ***'));
      expect(redacted, contains('Basic ***'));
      expect(redacted, contains('https://alice:***@nas.example.com/dav'));
      expect(redacted, contains(r'<USER_HOME>\Videos\secret.mkv'));

      final store = DiagnosticsLogStore();
      store.logEvent(
        subsystem: DiagnosticSubsystem.bangumi,
        severity: DiagnosticSeverity.error,
        code: 'BGM_AUTH_401',
        message: '鉴权失败 Bearer pat_leak_777',
        source: 'lib/infrastructure/network/bangumi_sync_client.dart:verifyToken',
        context: const <String, Object?>{
          'pat': 'pat_leak_777',
          'password': 'dav_password_888',
          'subjectId': 42,
        },
      );

      final report = store.buildRecentIncidentReport();
      expect(report, isNot(contains('pat_leak_777')));
      expect(report, isNot(contains('dav_password_888')));
      expect(report, contains('subjectId'));
      expect(report, contains('42'));
      expect(report, contains('BGM_AUTH_401'));
      expect(
        report,
        contains(
          'lib/infrastructure/network/bangumi_sync_client.dart:verifyToken',
        ),
      );
    });

    test('多环防淘汰：高频播放日志冲刷绝不覆盖早期错误、其它子系统日志与操作轨迹', () async {
      final store = DiagnosticsLogStore(
        maxEntries: 50,
        maxErrorEntries: 30,
        maxEntriesPerSubsystem: 20,
        maxBreadcrumbs: 25,
      );

      store.recordBreadcrumb(
        category: 'route',
        label: '进入作品详情页',
        detail: 'workId=w_1',
      );
      store.logError(
        subsystem: DiagnosticSubsystem.sync,
        code: 'WEBDAV_SYNC_401',
        message: 'WebDAV 分片同步鉴权失败',
        error: StateError('HTTP 401'),
        stackTrace: StackTrace.fromString(
          '#0 WebDavSyncTransport.upload (package:konata/infrastructure/sync/webdav_sync_transport.dart:88:5)\n'
          '#1 Future._propagateToListeners (dart:async/future_impl.dart:100:1)',
        ),
      );
      store.logEvent(
        subsystem: DiagnosticSubsystem.scraper,
        code: 'SCRAPE_WORK_UNMATCHED',
        message: '未命中候选条目',
        source: 'lib/application/scraping/scrape_orchestrator.dart:scrape',
      );

      // 模拟播放阶段刷入大量普通 info 事件
      for (var i = 0; i < 200; i++) {
        store.record('VIDEO', '缓冲帧进度 #$i');
      }

      final faults = store.summarizeFaults();
      expect(faults.length, 1);
      expect(faults.single.code, 'WEBDAV_SYNC_401');
      expect(
        faults.single.source,
        'lib/infrastructure/sync/webdav_sync_transport.dart:88:5',
      );
      expect(faults.single.errorType, 'StateError');

      final merged = store.snapshotMergedEvents();
      expect(merged.any((e) => e.code == 'WEBDAV_SYNC_401'), isTrue);
      expect(merged.any((e) => e.code == 'SCRAPE_WORK_UNMATCHED'), isTrue);
      expect(store.snapshotBreadcrumbs().length, 1);

      // 同时验证快照贡献者故障隔离与 JSON Schema v2 输出完整性
      store.registerSnapshotContributor(
        'healthy',
        () => const DiagnosticSnapshotSection(
          id: 'healthy',
          title: '健康模块',
          entries: <String, String>{'status': 'ok', 'token': 'must_mask'},
        ),
      );
      store.registerSnapshotContributor(
        'broken',
        () => throw StateError('模拟快照采集失败'),
      );

      final jsonStr = await store.buildJsonDiagnosticBundleAsync();
      final decoded = jsonDecode(jsonStr) as Map<String, Object?>;
      expect(decoded['schemaVersion'], 2);
      expect(jsonStr, isNot(contains('must_mask')));
      expect(jsonStr, contains('WEBDAV_SYNC_401'));
      expect(jsonStr, contains('健康模块'));
      expect(jsonStr, contains('模拟快照采集失败'));

      final clipboardSummary = await store
          .buildCompactAgentClipboardSummaryAsync();
      expect(clipboardSummary, contains('WEBDAV_SYNC_401'));
      expect(clipboardSummary, contains('进入作品详情页'));
    });

    test('DiagnosticsRuntimeBridge 捕获未捕获 FlutterError 并采集内存库运行快照', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);
      await repo.upsertMediaSource(
        MediaSource(
          id: 'src_1',
          kind: MediaSourceKind.local,
          label: '本地片库',
          location: r'D:\Anime',
          createdAt: DateTime(2026, 1, 1),
        ),
      );
      await repo.upsertWork(
        const Work(
          id: 'work_1',
          title: '测试作品',
          bangumiId: 12345,
          scrapeStatus: ScrapeStatus.matched,
        ),
      );

      final prevHandler = FlutterError.onError;
      var forwardedToPrev = false;
      FlutterError.onError = (_) {
        forwardedToPrev = true;
      };
      addTearDown(() {
        FlutterError.onError = prevHandler;
      });

      final container = ProviderContainer(
        overrides: [
          libraryRepositoryProvider.overrideWithValue(repo),
        ],
      );
      addTearDown(container.dispose);

      container.read(diagnosticsRuntimeBridgeProvider);
      final store = container.read(diagnosticsLogStoreProvider);

      FlutterError.onError?.call(
        FlutterErrorDetails(
          exception: StateError('测试未捕获渲染异常'),
          stack: StackTrace.fromString(
            '#0 BrokenWidget.build (package:konata/presentation/library/broken.dart:42:9)',
          ),
          library: 'widgets library',
        ),
      );

      expect(forwardedToPrev, isTrue);
      expect(store.summaryCounts.errorCount, 1);

      final report = await store.buildAgentDiagnosticReportAsync();
      expect(report, contains('UNCAUGHT_FLUTTER_ERROR'));
      expect(report, contains('lib/presentation/library/broken.dart:42:9'));
      expect(report, contains('worksTotal: 1'));
      expect(report, contains('worksWithBangumiId: 1'));
    });

    testWidgets('SettingsAboutPanel 展示实时计数并支持导出 TXT/JSON、复制摘要与清空缓冲', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = DiagnosticsLogStore();
      store.logEvent(
        subsystem: DiagnosticSubsystem.playback,
        severity: DiagnosticSeverity.error,
        code: 'TEST_PLAYBACK_ERR',
        message: '示例播放错误',
        source: 'lib/application/playback/demo.dart:play',
      );

      final savedFiles = <String, String>{};
      final mockPicker = KonataSystemFilePicker(
        saveFileImpl: ({
          required String fileName,
          required Uint8List bytes,
          String? dialogTitle,
          String? initialDirectory,
          windowsOptions = const WindowsOptions(),
        }) async {
          savedFiles[fileName] = utf8.decode(bytes);
          return Uri.file('D:/tmp/$fileName');
        },
      );

      String? copiedClipboard;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              final args = call.arguments as Map<Object?, Object?>;
              copiedClipboard = args['text'] as String?;
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            diagnosticsLogStoreProvider.overrideWithValue(store),
            konataSystemFilePickerProvider.overrideWithValue(mockPicker),
            libraryRepositoryProvider.overrideWithValue(
              DriftLibraryRepository(db),
            ),
          ],
          child: MaterialApp(
            theme: KonataTheme.darkTheme(),
            home: const Scaffold(
              body: SingleChildScrollView(child: SettingsAboutPanel()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('1 异常'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('settings_export_diagnostics_txt')),
      );
      await tester.pumpAndSettle();
      expect(savedFiles.keys.any((k) => k.endsWith('.txt')), isTrue);
      expect(
        savedFiles.values.any((v) => v.contains('TEST_PLAYBACK_ERR')),
        isTrue,
      );

      await tester.tap(
        find.byKey(const ValueKey('settings_export_diagnostics_json')),
      );
      await tester.pumpAndSettle();
      final jsonKey = savedFiles.keys.firstWhere((k) => k.endsWith('.json'));
      final parsed = jsonDecode(savedFiles[jsonKey]!) as Map<String, Object?>;
      expect(parsed['schemaVersion'], 2);

      await tester.tap(
        find.byKey(const ValueKey('settings_copy_agent_summary')),
      );
      await tester.pumpAndSettle();
      expect(copiedClipboard, isNotNull);
      expect(copiedClipboard, contains('TEST_PLAYBACK_ERR'));

      await tester.tap(
        find.byKey(const ValueKey('settings_clear_diagnostics')),
      );
      await tester.pumpAndSettle();
      expect(store.summaryCounts.errorCount, 0);
      expect(
        find.byKey(const ValueKey('settings_clear_diagnostics')),
        findsNothing,
      );
    });
  });
}
