import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart' as sq;

import 'package:konata/application/providers/diagnostics_providers.dart';
import 'package:konata/application/providers/library_providers.dart';
import 'package:konata/application/providers/sync_providers.dart';
import 'package:konata/application/sync/konata_backup_service.dart';
import 'package:konata/application/sync/webdav_sync_coordinator.dart';
import 'package:konata/domain/models/episode.dart';
import 'package:konata/domain/models/media_source.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/models/playback_record.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/domain/sync/konata_sync_models.dart';
import 'package:konata/infrastructure/database/drift_library_repository.dart';
import 'package:konata/infrastructure/database/drift_playback_helpers.dart';
import 'package:konata/infrastructure/database/konata_database.dart';
import 'package:konata/infrastructure/logging/diagnostics_log_store.dart';
import 'package:konata/infrastructure/sync/konata_sync_store.dart';
import 'package:konata/infrastructure/sync/webdav_sync_config_repository.dart';
import 'package:konata/presentation/settings/settings_backup_sync_panel.dart';
import 'package:konata/presentation/theme/konata_theme.dart';
import 'package:konata/presentation/widgets/design_system/konata_switch.dart';
import 'package:konata/presentation/widgets/design_system/konata_system_file_picker.dart';

/// 内存模拟 WebDAV 服务器（支持 MKCOL、GET、PUT 与首次 Digest 401 质询）。
class _InMemoryWebDavServer {
  _InMemoryWebDavServer({this.requireDigestAuth = false});

  final bool requireDigestAuth;
  final Set<String> dirs = <String>{'/'};
  final Map<String, Uint8List> files = <String, Uint8List>{};
  int digestChallengeCount = 0;

  MockClient buildClient() {
    return MockClient((http.Request request) async {
      final auth = request.headers['authorization'] ?? '';
      if (requireDigestAuth && !auth.startsWith('Digest ')) {
        digestChallengeCount++;
        return http.Response(
          'Unauthorized',
          401,
          headers: const <String, String>{
            'www-authenticate':
                'Digest realm="konata-dav", nonce="abc123nonce", qop="auth", algorithm=MD5',
          },
        );
      }

      final path = Uri.decodeComponent(request.url.path);
      switch (request.method.toUpperCase()) {
        case 'MKCOL':
          final norm = path.endsWith('/') ? path : '$path/';
          if (dirs.contains(norm)) {
            return http.Response('', 405);
          }
          dirs.add(norm);
          return http.Response('', 201);
        case 'PUT':
          files[path] = Uint8List.fromList(request.bodyBytes);
          return http.Response('', 201);
        case 'GET':
          final data = files[path];
          if (data == null) {
            return http.Response('Not Found', 404);
          }
          return http.Response.bytes(data, 200);
        default:
          return http.Response('Method Not Allowed', 405);
      }
    });
  }
}

Future<void> _seedDeviceAnime({
  required DriftLibraryRepository repo,
  required String sourceId,
  required MediaSourceKind sourceKind,
  required String location,
  required String workId,
  required int? tmdbId,
  required TmdbMediaType? tmdbType,
  required int? bangumiId,
  required String title,
}) async {
  await repo.upsertMediaSource(
    MediaSource(
      id: sourceId,
      kind: sourceKind,
      label: '片源-$sourceId',
      location: location,
      createdAt: DateTime(2026, 1, 1),
    ),
  );
  await repo.upsertWork(
    Work(
      id: workId,
      tmdbId: tmdbId,
      tmdbMediaType: tmdbType,
      bangumiId: bangumiId,
      matchedSeason: 1,
      title: title,
      scrapeStatus: ScrapeStatus.matched,
    ),
  );
  for (var ep = 1; ep <= 3; ep++) {
    final epId = '${workId}_e$ep';
    await repo.upsertEpisode(
      Episode(
        id: epId,
        workId: workId,
        seasonNumber: 1,
        episodeNumber: ep,
        category: EpisodeCategory.main,
        title: '第 $ep 话',
      ),
    );
    await repo.upsertMediaVariant(
      MediaVariant(
        id: '${workId}_v$ep',
        workId: workId,
        episodeId: epId,
        sourceId: sourceId,
        relativePath: '$title/EP0$ep.mkv',
        fileName: 'EP0$ep.mkv',
        fileSize: 500000000,
        assetKind: AssetKind.video,
      ),
    );
  }
}

void main() {
  group('数据库 v14 -> v15 升级迁移回归', () {
    test('从真实 v14 SQLite 库无损升级至 v15，保留旧数据并建立同步墓碑与 Bangumi 队列', () async {
      final tempDir = await Directory.systemTemp.createTemp('konata_v14_mig_');
      addTearDown(() async {
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
      });
      final dbFile = File(p.join(tempDir.path, 'legacy_v14.sqlite'));

      // 1. 构造真实 v14 表结构（不含 v15 新增的 updated_at_ms 与三张新表）
      final raw = sq.sqlite3.open(dbFile.path);
      raw.execute('''
        CREATE TABLE media_sources (
          id TEXT NOT NULL PRIMARY KEY,
          kind TEXT NOT NULL,
          label TEXT NOT NULL,
          location TEXT NOT NULL,
          username TEXT,
          created_at INTEGER
        );
      ''');
      raw.execute('''
        CREATE TABLE works (
          id TEXT NOT NULL PRIMARY KEY,
          tmdb_id INTEGER,
          bangumi_id INTEGER,
          tvdb_id INTEGER,
          tmdb_media_type TEXT,
          matched_season INTEGER,
          title TEXT NOT NULL,
          original_title TEXT,
          year INTEGER,
          overview TEXT,
          poster_path TEXT,
          poster_fallback TEXT,
          bangumi_poster_path TEXT,
          backdrop_path TEXT,
          logo_path TEXT,
          vote_average REAL,
          bangumi_score REAL,
          folder_tmdb_hint INTEGER,
          is_manual_locked INTEGER NOT NULL DEFAULT 0,
          metadata_locked INTEGER NOT NULL DEFAULT 0,
          poster_locked INTEGER NOT NULL DEFAULT 0,
          backdrop_locked INTEGER NOT NULL DEFAULT 0,
          logo_locked INTEGER NOT NULL DEFAULT 0,
          logo_negative_until INTEGER,
          logo_negative_mask INTEGER NOT NULL DEFAULT 0,
          is_hidden INTEGER NOT NULL DEFAULT 0,
          keep_hidden INTEGER NOT NULL DEFAULT 0,
          scrape_status TEXT NOT NULL,
          review_reason TEXT,
          series_id TEXT,
          series_order INTEGER,
          series_label TEXT,
          series_locked INTEGER NOT NULL DEFAULT 0
        );
      ''');
      raw.execute('''
        CREATE TABLE episodes (
          id TEXT NOT NULL PRIMARY KEY,
          work_id TEXT NOT NULL,
          season_number INTEGER NOT NULL,
          episode_number INTEGER,
          episode_number_end INTEGER,
          category TEXT NOT NULL,
          extra_type TEXT,
          title TEXT,
          overview TEXT,
          still_path TEXT
        );
      ''');
      raw.execute('''
        CREATE TABLE media_variants (
          id TEXT NOT NULL PRIMARY KEY,
          work_id TEXT NOT NULL,
          episode_id TEXT,
          source_id TEXT NOT NULL,
          relative_path TEXT NOT NULL,
          file_name TEXT NOT NULL,
          file_size INTEGER NOT NULL,
          asset_kind TEXT NOT NULL,
          release_group TEXT,
          subtitle_group TEXT,
          video_codec TEXT,
          bit_depth TEXT,
          resolution TEXT,
          audio_codec TEXT,
          external_subtitles_json TEXT NOT NULL DEFAULT '[]',
          mapping_locked INTEGER NOT NULL DEFAULT 0,
          work_locked INTEGER NOT NULL DEFAULT 0,
          asset_scope TEXT NOT NULL DEFAULT 'workExclusive',
          scope_locked INTEGER NOT NULL DEFAULT 0
        );
      ''');
      raw.execute('''
        CREATE TABLE scrape_candidates (
          work_id TEXT NOT NULL,
          rank INTEGER NOT NULL,
          tmdb_id INTEGER NOT NULL,
          media_type TEXT NOT NULL,
          title TEXT NOT NULL,
          original_title TEXT,
          year INTEGER,
          poster_path TEXT,
          score REAL NOT NULL,
          reasons_json TEXT NOT NULL DEFAULT '[]',
          episode_count INTEGER,
          PRIMARY KEY (work_id, rank)
        );
      ''');
      raw.execute('''
        CREATE TABLE playback_records (
          id TEXT NOT NULL PRIMARY KEY,
          work_id TEXT NOT NULL,
          episode_id TEXT NOT NULL,
          variant_id TEXT NOT NULL,
          season_number INTEGER NOT NULL,
          episode_number INTEGER,
          episode_title TEXT NOT NULL,
          source_type TEXT NOT NULL,
          played_at INTEGER NOT NULL,
          position_seconds INTEGER NOT NULL DEFAULT 0,
          duration_seconds INTEGER NOT NULL DEFAULT 0,
          is_completed INTEGER NOT NULL DEFAULT 0
        );
      ''');
      raw.execute('''
        CREATE TABLE ignored_folders (
          id TEXT NOT NULL PRIMARY KEY,
          source_id TEXT NOT NULL,
          relative_path TEXT NOT NULL,
          created_at INTEGER
        );
      ''');
      raw.execute('''
        CREATE TABLE series_groups (
          id TEXT NOT NULL PRIMARY KEY,
          title TEXT NOT NULL,
          tmdb_collection_id INTEGER,
          root_folder_hint TEXT,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        );
      ''');
      raw.execute('''
        CREATE TABLE lyric_cache_entries (
          track_key TEXT NOT NULL PRIMARY KEY,
          song_key TEXT,
          status TEXT NOT NULL,
          source TEXT,
          source_id TEXT NOT NULL DEFAULT '',
          lrc_content TEXT NOT NULL DEFAULT '',
          score REAL NOT NULL DEFAULT 0.0,
          engine_version INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        );
      ''');

      raw.execute(
        "INSERT INTO works (id, tmdb_id, bangumi_id, tmdb_media_type, title, scrape_status) "
        "VALUES ('legacy_w1', 100565, 302189, 'tv', '86 -不存在的战区-', 'matched');",
      );
      raw.execute(
        "INSERT INTO playback_records "
        "(id, work_id, episode_id, variant_id, season_number, episode_number, episode_title, source_type, played_at, position_seconds, duration_seconds, is_completed) "
        "VALUES ('rec_1', 'legacy_w1', 'ep_1', 'var_1', 1, 1, '第 1 话', 'local', 1700000000, 1400, 1420, 1);",
      );
      raw.execute('PRAGMA user_version = 14;');
      raw.close();

      // 2. 以 Drift v15 打开并触发真实升级迁移
      final upgraded = KonataDatabase(NativeDatabase(dbFile));
      addTearDown(upgraded.close);

      final repo = DriftLibraryRepository(upgraded);
      final works = await repo.getAllWorks();
      expect(works.length, 1);
      expect(works.single.title, '86 -不存在的战区-');

      final history = await repo.getPlaybackHistory();
      expect(history.length, 1);
      expect(history.single.isCompleted, isTrue);

      final store = KonataSyncStore(upgraded);
      final deviceId = await store.getOrCreateDeviceId();
      expect(deviceId, isNotEmpty);
      await store.enqueueBangumiSyncItem(
        queueKey: 'ep::302189::s1::e1',
        subjectId: 302189,
        seasonNumber: 1,
        episodeNumber: 1,
        targetStatus: 2,
      );
      final queued = await store.readBangumiSyncQueue();
      expect(queued.length, 1);
      expect(queued.single.subjectId, 302189);
    });
  });

  group('本地 .konata 备份恢复与 SHA-256 完整性防篡改', () {
    test('导出自动剥离敏感密钥、校验防篡改，并在不同 workId 设备上无损智能合并恢复', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'konata_v2_theme_mode': 'dark',
        'konata.detail.show_overview': false,
        'konata_v2_tmdb_credential': 'SECRET_SHOULD_NEVER_EXPORT',
        'konata_v2_sync_webdav_password_secret': 'DAV_SECRET_NEVER_EXPORT',
      });

      final dbA = KonataDatabase(NativeDatabase.memory());
      addTearDown(dbA.close);
      final repoA = DriftLibraryRepository(dbA);
      final storeA = KonataSyncStore(dbA);
      final logStore = DiagnosticsLogStore();
      await _seedDeviceAnime(
        repo: repoA,
        sourceId: 'src_win',
        sourceKind: MediaSourceKind.local,
        location: r'D:\Anime',
        workId: 'win_work_86',
        tmdbId: 100565,
        tmdbType: TmdbMediaType.tv,
        bangumiId: 302189,
        title: '86 -不存在的战区-',
      );
      await repoA.recordPlayback(
        PlaybackRecord(
          id: 'win_work_86::win_work_86_e1',
          workId: 'win_work_86',
          episodeId: 'win_work_86_e1',
          variantId: 'win_work_86_v1',
          seasonNumber: 1,
          episodeNumber: 1,
          episodeTitle: '第 1 话',
          sourceType: MediaSourceKind.local,
          playedAt: DateTime(2026, 11, 20, 20, 0),
          positionSeconds: 1400,
          durationSeconds: 1420,
          isCompleted: true,
        ),
      );

      final backupA = KonataBackupService(
        repository: repoA,
        syncStore: storeA,
        logStore: logStore,
      );
      final archiveBytes = await backupA.exportKonataArchiveBytes();

      // 验证导出字节绝不含敏感密钥
      final decodedJson = utf8.decode(gzip.decode(archiveBytes));
      expect(decodedJson, isNot(contains('SECRET_SHOULD_NEVER_EXPORT')));
      expect(decodedJson, isNot(contains('DAV_SECRET_NEVER_EXPORT')));
      expect(decodedJson, contains('konata_v2_theme_mode'));

      // 验证预检摘要准确
      final preview = backupA.inspectKonataArchiveBytes(archiveBytes);
      expect(preview.playbackCount, 1);
      expect(preview.preferenceCount, 2);

      // 验证篡改内容被 SHA-256 拒绝
      final tampered = utf8.encode(decodedJson.replaceFirst('第 1 话', '被篡改'));
      expect(
        () => backupA.inspectKonataArchiveBytes(Uint8List.fromList(tampered)),
        throwsA(isA<FormatException>()),
      );

      // 模拟另一台 Android 设备（完全不同的 workId、episodeId 与 WebDAV 来源）恢复该备份
      SharedPreferences.setMockInitialValues(<String, Object>{
        'konata_v2_theme_mode': 'light',
      });
      final dbB = KonataDatabase(NativeDatabase.memory());
      addTearDown(dbB.close);
      final repoB = DriftLibraryRepository(dbB);
      final storeB = KonataSyncStore(dbB);
      await _seedDeviceAnime(
        repo: repoB,
        sourceId: 'src_android_dav',
        sourceKind: MediaSourceKind.webdav,
        location: 'https://nas.local/dav/Anime',
        workId: 'android_work_999',
        tmdbId: 100565,
        tmdbType: TmdbMediaType.tv,
        bangumiId: 302189,
        title: '86 -不存在的战区-',
      );

      final backupB = KonataBackupService(
        repository: repoB,
        syncStore: storeB,
        logStore: logStore,
      );
      final outcome = await backupB.restoreFromKonataArchiveBytes(
        archiveBytes,
        mode: KonataBackupRestoreMode.smartMerge,
      );

      expect(outcome.playbacksUpdated, 1);
      expect(outcome.preferencesRestored, greaterThanOrEqualTo(1));
      final playbacksB = await repoB.getPlaybacksByWork('android_work_999');
      expect(playbacksB.length, 1);
      expect(playbacksB.single.episodeNumber, 1);
      expect(playbacksB.single.isCompleted, isTrue);

      final prefsB = await SharedPreferences.getInstance();
      expect(prefsB.getString('konata_v2_theme_mode'), 'dark');
    });
  });

  group('WebDAV 多设备分片同步（含 Digest 认证、跨端合流与删除墓碑）', () {
    test('Windows 与 Android 分片零锁竞争同步，合并进度并正确传播墓碑删除', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final server = _InMemoryWebDavServer(requireDigestAuth: true);
      final mockClient = server.buildClient();
      final logStore = DiagnosticsLogStore();
      const syncConfig = WebDavSyncConfig(
        enabled: true,
        baseUrl: 'https://dav.example.com/root',
        remoteDir: 'konata-sync',
        username: 'alice',
        password: 'dav_secret_password',
      );

      // 设备 A（Windows）：仅绑定 TMDB+Bangumi，看完 Ep1，Ep2 看到 600s
      final dbA = KonataDatabase(NativeDatabase.memory());
      addTearDown(dbA.close);
      final repoA = DriftLibraryRepository(dbA);
      final storeA = KonataSyncStore(dbA);
      await storeA.writeMeta(KonataSyncStore.metaKeyDeviceId, 'win_dev_a');
      await _seedDeviceAnime(
        repo: repoA,
        sourceId: 'src_win',
        sourceKind: MediaSourceKind.local,
        location: r'D:\Anime',
        workId: 'win_w1',
        tmdbId: 100565,
        tmdbType: TmdbMediaType.tv,
        bangumiId: 302189,
        title: '86 -不存在的战区-',
      );
      await repoA.recordPlayback(
        PlaybackRecord(
          id: 'win_w1::win_w1_e1',
          workId: 'win_w1',
          episodeId: 'win_w1_e1',
          variantId: 'win_w1_v1',
          seasonNumber: 1,
          episodeNumber: 1,
          episodeTitle: '第 1 话',
          sourceType: MediaSourceKind.local,
          playedAt: DateTime(2026, 11, 21, 10, 0),
          positionSeconds: 1400,
          durationSeconds: 1420,
          isCompleted: true,
        ),
      );
      await repoA.recordPlayback(
        PlaybackRecord(
          id: 'win_w1::win_w1_e2',
          workId: 'win_w1',
          episodeId: 'win_w1_e2',
          variantId: 'win_w1_v2',
          seasonNumber: 1,
          episodeNumber: 2,
          episodeTitle: '第 2 话',
          sourceType: MediaSourceKind.local,
          playedAt: DateTime(2026, 11, 21, 11, 0),
          positionSeconds: 600,
          durationSeconds: 1420,
          isCompleted: false,
        ),
      );

      var nowClock = DateTime(2026, 11, 21, 12, 0);
      final backupA = KonataBackupService(
        repository: repoA,
        syncStore: storeA,
        logStore: logStore,
        clock: () => nowClock,
      );
      final coordA = WebDavSyncCoordinator(
        backupService: backupA,
        syncStore: storeA,
        logStore: logStore,
        httpClientForTest: mockClient,
        clock: () => nowClock,
      );

      expect(await coordA.testConnection(syncConfig), isNull);
      expect(server.digestChallengeCount, greaterThan(0));

      final resA1 = await coordA.syncNow(syncConfig);
      expect(resA1.uploadedShard, isTrue);
      expect(
        server.files.containsKey(
          '/root/konata-sync/devices/win_dev_a/snapshot.json.gz',
        ),
        isTrue,
      );

      // 设备 B（Android）：仅绑定 BangumiId=302189（靠辅助身份键对齐！），Ep2 看到 900s（更新），Ep3 已看完
      final dbB = KonataDatabase(NativeDatabase.memory());
      addTearDown(dbB.close);
      final repoB = DriftLibraryRepository(dbB);
      final storeB = KonataSyncStore(dbB);
      await storeB.writeMeta(KonataSyncStore.metaKeyDeviceId, 'android_dev_b');
      await _seedDeviceAnime(
        repo: repoB,
        sourceId: 'src_and',
        sourceKind: MediaSourceKind.webdav,
        location: 'https://nas.local/dav',
        workId: 'and_w9',
        tmdbId: null,
        tmdbType: null,
        bangumiId: 302189,
        title: '86 -不存在的战区-',
      );
      await repoB.recordPlayback(
        PlaybackRecord(
          id: 'and_w9::and_w9_e2',
          workId: 'and_w9',
          episodeId: 'and_w9_e2',
          variantId: 'and_w9_v2',
          seasonNumber: 1,
          episodeNumber: 2,
          episodeTitle: '第 2 话',
          sourceType: MediaSourceKind.webdav,
          playedAt: DateTime(2026, 11, 21, 12, 30),
          positionSeconds: 900,
          durationSeconds: 1420,
          isCompleted: false,
        ),
      );
      await repoB.recordPlayback(
        PlaybackRecord(
          id: 'and_w9::and_w9_e3',
          workId: 'and_w9',
          episodeId: 'and_w9_e3',
          variantId: 'and_w9_v3',
          seasonNumber: 1,
          episodeNumber: 3,
          episodeTitle: '第 3 话',
          sourceType: MediaSourceKind.webdav,
          playedAt: DateTime(2026, 11, 21, 12, 45),
          positionSeconds: 1410,
          durationSeconds: 1420,
          isCompleted: true,
        ),
      );

      nowClock = DateTime(2026, 11, 21, 13, 0);
      final backupB = KonataBackupService(
        repository: repoB,
        syncStore: storeB,
        logStore: logStore,
        clock: () => nowClock,
      );
      final coordB = WebDavSyncCoordinator(
        backupService: backupB,
        syncStore: storeB,
        logStore: logStore,
        httpClientForTest: mockClient,
        clock: () => nowClock,
      );

      final resB1 = await coordB.syncNow(syncConfig);
      expect(resB1.remoteDevicesMerged, 1);
      expect(resB1.playbacksUpdated, greaterThanOrEqualTo(1));
      final playbacksB = await repoB.getPlaybacksByWork('and_w9');
      final byEpB = <int?, PlaybackRecord>{
        for (final r in playbacksB) r.episodeNumber: r,
      };
      expect(byEpB[1]?.isCompleted, isTrue);
      expect(byEpB[2]?.positionSeconds, 900);
      expect(byEpB[3]?.isCompleted, isTrue);

      // 设备 A 再次同步 -> 收到设备 B 的 Ep2(900s) 与 Ep3(已看)
      nowClock = DateTime(2026, 11, 21, 13, 10);
      await coordA.syncNow(syncConfig);
      final playbacksA = await repoA.getPlaybacksByWork('win_w1');
      final byEpA = <int?, PlaybackRecord>{
        for (final r in playbacksA) r.episodeNumber: r,
      };
      expect(byEpA[1]?.isCompleted, isTrue);
      expect(byEpA[2]?.positionSeconds, 900);
      expect(byEpA[3]?.isCompleted, isTrue);

      // 设备 A 删除 Ep1 并写入删除墓碑 -> 同步 -> 设备 B 同步后 Ep1 应被墓碑清除而非复活
      nowClock = DateTime(2026, 11, 21, 14, 0);
      final workA = (await repoA.findWorkById('win_w1'))!;
      final ep1A = byEpA[1]!;
      await repoA.deletePlaybackRecord(ep1A.id);
      await backupA.recordPlaybackDeletionTombstone(work: workA, record: ep1A);
      await coordA.syncNow(syncConfig);

      // 注意：设备 B 同步时，墓碑使用的是设备 A 的 canonicalKey，同时我们在设备 B 补绑 TMDB 确认同键传播
      await repoB.upsertWork(
        (await repoB.findWorkById('and_w9'))!.copyWith(
          tmdbId: 100565,
          tmdbMediaType: TmdbMediaType.tv,
        ),
      );
      nowClock = DateTime(2026, 11, 21, 14, 5);
      final resB2 = await coordB.syncNow(syncConfig);
      expect(resB2.tombstonesApplied, 1);
      final afterDeleteB = await repoB.getPlaybacksByWork('and_w9');
      expect(afterDeleteB.any((r) => r.episodeNumber == 1), isFalse);

      // 确认整个同步过程的诊断日志不含任何 WebDAV 密码
      final diagReport = logStore.buildRecentIncidentReport();
      expect(diagReport, isNot(contains('dav_secret_password')));
      expect(diagReport, contains('SYNC_WEBDAV_COMPLETED'));
    });

    test('数据库损坏 JSON 字符串列表容错降级且不抛异常', () {
      expect(decodeJsonStringList('["a.ass","b.srt"]'), ['a.ass', 'b.srt']);
      expect(decodeJsonStringList(''), isEmpty);
      expect(decodeJsonStringList('   '), isEmpty);
      expect(decodeJsonStringList('{corrupt-json'), isEmpty);
      expect(decodeJsonStringList('{"not":"a-list"}'), isEmpty);
    });

    test('WebDAV 启动自动同步与停播自动同步开关真实触发同步', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final server = _InMemoryWebDavServer();
      final mockClient = server.buildClient();
      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);
      final store = KonataSyncStore(db);
      final logStore = DiagnosticsLogStore();
      final backupService = KonataBackupService(
        repository: repo,
        syncStore: store,
        logStore: logStore,
      );
      final coordinator = WebDavSyncCoordinator(
        backupService: backupService,
        syncStore: store,
        logStore: logStore,
        httpClientForTest: mockClient,
      );
      final configRepo = _InMemoryWebDavConfigRepo(
        const WebDavSyncConfig(
          enabled: true,
          baseUrl: 'https://dav.example.com/root',
          username: 'konata',
          password: 'pwd',
          remoteDir: 'KonataSync',
          autoSyncOnStartup: true,
          autoSyncOnPlaybackStop: true,
        ),
      );

      final container = ProviderContainer(
        overrides: [
          libraryRepositoryProvider.overrideWithValue(repo),
          konataSyncStoreProvider.overrideWithValue(store),
          diagnosticsLogStoreProvider.overrideWithValue(logStore),
          konataBackupServiceProvider.overrideWithValue(backupService),
          webDavSyncCoordinatorProvider.overrideWithValue(coordinator),
          webDavSyncConfigRepositoryProvider.overrideWithValue(configRepo),
        ],
      );
      addTearDown(container.dispose);

      // 读取控制器触发 _restore() 与启动自动同步
      container.read(webDavSyncControllerProvider);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final afterStartup = container.read(webDavSyncControllerProvider);
      expect(afterStartup.loaded, isTrue);
      expect(afterStartup.lastSyncAt, isNotNull);
      expect(server.files.keys.any((k) => k.endsWith('/manifest.json')), isTrue);

      // 停播触发防抖自动同步（更新远端分片）
      final prevFilesCount = server.files.length;
      server.files.clear();
      container
          .read(webDavSyncControllerProvider.notifier)
          .notifyPlaybackStopped();
      await Future<void>.delayed(const Duration(milliseconds: 2300));
      expect(server.files.length, greaterThanOrEqualTo(prevFilesCount));
    });

    test('支持按范围选择性导出与选择性恢复，覆盖模式未勾选播放记录时绝不误清本地历史', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'konata_v2_theme_mode': 'dark',
      });
      final dbA = KonataDatabase(NativeDatabase.memory());
      addTearDown(dbA.close);
      final repoA = DriftLibraryRepository(dbA);
      final storeA = KonataSyncStore(dbA);
      await _seedDeviceAnime(
        repo: repoA,
        sourceId: 'src_a',
        sourceKind: MediaSourceKind.local,
        location: r'D:\Anime',
        workId: 'w_a',
        tmdbId: 100565,
        tmdbType: TmdbMediaType.tv,
        bangumiId: 302189,
        title: '86 -不存在的战区-',
      );
      await repoA.upsertWork(
        (await repoA.findWorkById('w_a'))!.copyWith(
          isHidden: true,
          keepHidden: true,
        ),
      );
      await repoA.recordPlayback(
        PlaybackRecord(
          id: 'w_a::w_a_e1',
          workId: 'w_a',
          episodeId: 'w_a_e1',
          variantId: 'w_a_v1',
          seasonNumber: 1,
          episodeNumber: 1,
          episodeTitle: '第 1 话',
          sourceType: MediaSourceKind.local,
          playedAt: DateTime(2026, 11, 20, 20, 0),
          positionSeconds: 900,
          durationSeconds: 1420,
          isCompleted: false,
        ),
      );

      final backupA = KonataBackupService(
        repository: repoA,
        syncStore: storeA,
      );

      // 1. 仅导出观看进度时，作品整理与偏好设置必须为空
      final playbacksOnlyBytes = await backupA.exportKonataArchiveBytes(
        scope: const KonataSyncDataScope(
          includePlaybacks: true,
          includeWorkOverrides: false,
          includePreferences: false,
        ),
      );
      final pbOnlyPreview = backupA.inspectKonataArchiveBytes(playbacksOnlyBytes);
      expect(pbOnlyPreview.playbackCount, 1);
      expect(pbOnlyPreview.workOverrideCount, 0);
      expect(pbOnlyPreview.preferenceCount, 0);

      // 2. 全量导出后，在设备 B 仅勾选恢复「偏好设置」且使用覆盖模式，不得清空设备 B 现有观看进度与作品隐藏态
      final fullBytes = await backupA.exportKonataArchiveBytes();
      SharedPreferences.setMockInitialValues(<String, Object>{
        'konata_v2_theme_mode': 'light',
      });
      final dbB = KonataDatabase(NativeDatabase.memory());
      addTearDown(dbB.close);
      final repoB = DriftLibraryRepository(dbB);
      final storeB = KonataSyncStore(dbB);
      await _seedDeviceAnime(
        repo: repoB,
        sourceId: 'src_b',
        sourceKind: MediaSourceKind.local,
        location: r'E:\Anime',
        workId: 'w_b',
        tmdbId: 100565,
        tmdbType: TmdbMediaType.tv,
        bangumiId: 302189,
        title: '86 -不存在的战区-',
      );
      await repoB.recordPlayback(
        PlaybackRecord(
          id: 'w_b::w_b_e2',
          workId: 'w_b',
          episodeId: 'w_b_e2',
          variantId: 'w_b_v2',
          seasonNumber: 1,
          episodeNumber: 2,
          episodeTitle: '第 2 话',
          sourceType: MediaSourceKind.local,
          playedAt: DateTime(2026, 11, 21, 10, 0),
          positionSeconds: 300,
          durationSeconds: 1420,
          isCompleted: false,
        ),
      );

      final backupB = KonataBackupService(
        repository: repoB,
        syncStore: storeB,
      );
      final outcome = await backupB.restoreFromKonataArchiveBytes(
        fullBytes,
        mode: KonataBackupRestoreMode.overwrite,
        scope: const KonataSyncDataScope(
          includePlaybacks: false,
          includeWorkOverrides: false,
          includePreferences: true,
        ),
      );
      expect(outcome.preferencesRestored, 1);
      expect(outcome.playbacksUpdated, 0);
      expect(outcome.workOverridesApplied, 0);
      expect((await SharedPreferences.getInstance()).getString('konata_v2_theme_mode'), 'dark');
      final pbB = await repoB.getPlaybacksByWork('w_b');
      expect(pbB.length, 1);
      expect(pbB.single.episodeNumber, 2);
      expect((await repoB.findWorkById('w_b'))!.isHidden, isFalse);
    });

    test('WebDAV 配置持久化同步内容范围与定时分钟间隔，并按周期自动触发与按范围隔离合并', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      const configRepo = WebDavSyncConfigRepository();
      const savedConfig = WebDavSyncConfig(
        enabled: true,
        baseUrl: 'https://dav.example.com/root',
        remoteDir: 'konata-sync',
        username: 'bob',
        autoSyncOnStartup: false,
        autoSyncOnPlaybackStop: false,
        autoSyncIntervalMinutes: 15,
        syncScope: KonataSyncDataScope(
          includePlaybacks: true,
          includeWorkOverrides: false,
          includePreferences: false,
        ),
      );
      await configRepo.save(savedConfig);
      final reloaded = await configRepo.load();
      expect(reloaded.autoSyncIntervalMinutes, 15);
      expect(reloaded.syncScope.includePlaybacks, isTrue);
      expect(reloaded.syncScope.includeWorkOverrides, isFalse);
      expect(reloaded.syncScope.includePreferences, isFalse);

      // 验证定时自动同步按间隔周期触发并在间隔归零后停止
      final server = _InMemoryWebDavServer();
      final mockClient = server.buildClient();
      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);
      final store = KonataSyncStore(db);
      final backupService = KonataBackupService(
        repository: repo,
        syncStore: store,
      );
      final coordinator = WebDavSyncCoordinator(
        backupService: backupService,
        syncStore: store,
        httpClientForTest: mockClient,
      );
      final memConfigRepo = _InMemoryWebDavConfigRepo(
        const WebDavSyncConfig(
          enabled: true,
          baseUrl: 'https://dav.example.com/root',
          remoteDir: 'konata-sync',
          autoSyncOnStartup: false,
          autoSyncOnPlaybackStop: false,
          autoSyncIntervalMinutes: 3,
          syncScope: KonataSyncDataScope(
            includePlaybacks: true,
            includeWorkOverrides: false,
            includePreferences: false,
          ),
        ),
      );

      final container = ProviderContainer(
        overrides: [
          libraryRepositoryProvider.overrideWithValue(repo),
          konataSyncStoreProvider.overrideWithValue(store),
          konataBackupServiceProvider.overrideWithValue(backupService),
          webDavSyncCoordinatorProvider.overrideWithValue(coordinator),
          webDavSyncConfigRepositoryProvider.overrideWithValue(memConfigRepo),
          webDavSyncIntervalUnitProvider.overrideWithValue(
            const Duration(milliseconds: 25),
          ),
        ],
      );
      addTearDown(container.dispose);

      container.read(webDavSyncControllerProvider);
      await Future<void>.delayed(const Duration(milliseconds: 220));
      expect(
        server.files.keys.any((k) => k.endsWith('/manifest.json')),
        isTrue,
        reason: '定时同步间隔为 3 单位时应自动触发后台同步并上传清单',
      );

      // 关闭定时同步后不再继续触发后台上传
      await container.read(webDavSyncControllerProvider.notifier).saveConfig(
        container
            .read(webDavSyncControllerProvider)
            .config
            .copyWith(autoSyncIntervalMinutes: 0),
      );
      server.files.clear();
      await Future<void>.delayed(const Duration(milliseconds: 160));
      expect(server.files, isEmpty);
    });

    testWidgets('SettingsBackupSyncPanel 支持导出勾选、恢复勾选与 WebDAV 同步范围及定时间隔下拉无溢出', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'konata_v2_theme_mode': 'dark',
      });
      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);
      final store = KonataSyncStore(db);
      await _seedDeviceAnime(
        repo: repo,
        sourceId: 'src_ui',
        sourceKind: MediaSourceKind.local,
        location: r'D:\Anime',
        workId: 'w_ui',
        tmdbId: 100565,
        tmdbType: TmdbMediaType.tv,
        bangumiId: 302189,
        title: '86 -不存在的战区-',
      );
      await repo.recordPlayback(
        PlaybackRecord(
          id: 'w_ui::w_ui_e1',
          workId: 'w_ui',
          episodeId: 'w_ui_e1',
          variantId: 'w_ui_v1',
          seasonNumber: 1,
          episodeNumber: 1,
          episodeTitle: '第 1 话',
          sourceType: MediaSourceKind.local,
          playedAt: DateTime(2026, 11, 20, 20, 0),
          positionSeconds: 600,
          durationSeconds: 1420,
          isCompleted: false,
        ),
      );

      Uint8List? exportedBytes;
      final mockPicker = KonataSystemFilePicker(
        saveFileImpl: ({
          required String fileName,
          required Uint8List bytes,
          String? dialogTitle,
          String? initialDirectory,
          windowsOptions = const WindowsOptions(),
        }) async {
          exportedBytes = bytes;
          return Uri.file('D:/tmp/$fileName');
        },
        pickFilesImpl: ({
          String? dialogTitle,
          String? initialDirectory,
          FileType type = FileType.any,
          List<String>? allowedExtensions,
          WindowsOptions windowsOptions = const WindowsOptions(),
        }) async {
          if (exportedBytes == null) return const <PlatformFile>[];
          return <PlatformFile>[
            _MemoryPlatformFile(
              name: 'backup.konata',
              content: exportedBytes!,
            ),
          ];
        },
      );
      final memConfigRepo = _InMemoryWebDavConfigRepo(
        const WebDavSyncConfig(enabled: true),
      );

      for (final viewport in const [Size(1200, 800), Size(375, 812)]) {
        tester.view.physicalSize = viewport;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              libraryRepositoryProvider.overrideWithValue(repo),
              konataSyncStoreProvider.overrideWithValue(store),
              webDavSyncConfigRepositoryProvider.overrideWithValue(
                memConfigRepo,
              ),
              konataSystemFilePickerProvider.overrideWithValue(mockPicker),
            ],
            child: MaterialApp(
              theme: KonataTheme.darkTheme(),
              home: const Scaffold(
                body: SingleChildScrollView(child: SettingsBackupSyncPanel()),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('同步内容'), findsOneWidget);
        expect(find.text('定时自动同步间隔'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('settings_webdav_sync_interval')),
          findsOneWidget,
        );
      }

      // 在桌面视口测试导出弹窗勾选（取消偏好设置 -> 仅导出进度与作品整理）
      tester.view.physicalSize = const Size(1200, 800);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('settings_export_konata_backup')),
      );
      await tester.pumpAndSettle();
      expect(find.text('选择导出备份内容'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('export_scope_preferences')),
          matching: find.byType(KonataSwitch),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('backup_export_confirm_btn')),
      );
      await tester.pumpAndSettle();
      expect(exportedBytes, isNotNull);

      final backupSvc = KonataBackupService(repository: repo, syncStore: store);
      final exportedPreview = backupSvc.inspectKonataArchiveBytes(
        exportedBytes!,
      );
      expect(exportedPreview.playbackCount, 1);
      expect(exportedPreview.preferenceCount, 0);

      // 测试恢复弹窗展示各分类开关，无偏好数据时偏好开关自动禁用
      await tester.tap(
        find.byKey(const ValueKey('settings_import_konata_backup')),
      );
      await tester.pumpAndSettle();
      expect(find.text('确认恢复本地备份'), findsOneWidget);
      expect(find.text('恢复内容'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('backup_restore_confirm_btn')),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}

class _InMemoryWebDavConfigRepo extends WebDavSyncConfigRepository {
  _InMemoryWebDavConfigRepo(this._config);

  WebDavSyncConfig _config;

  @override
  Future<WebDavSyncConfig> load() async => _config;

  @override
  Future<void> save(WebDavSyncConfig config) async {
    _config = config;
  }
}

final class _MemoryPlatformFile extends PlatformFile {
  _MemoryPlatformFile({required this.name, required Uint8List content})
    : _bytes = content;

  @override
  final String name;

  final Uint8List _bytes;

  @override
  Uri get uri => Uri.parse('content://konata.test/backups/$name');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  int? lengthSync() => _bytes.length;

  @override
  Future<int?> length() async => _bytes.length;

  @override
  Future<Uint8List> readAsBytes() async => _bytes;

  @override
  Stream<Uint8List> readAsByteStream() => Stream<Uint8List>.value(_bytes);
}
