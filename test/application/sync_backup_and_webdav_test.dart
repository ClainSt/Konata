import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart' as sq;

import 'package:konata/application/sync/konata_backup_service.dart';
import 'package:konata/application/sync/webdav_sync_coordinator.dart';
import 'package:konata/domain/models/episode.dart';
import 'package:konata/domain/models/media_source.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/models/playback_record.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/domain/sync/konata_sync_models.dart';
import 'package:konata/infrastructure/database/drift_library_repository.dart';
import 'package:konata/infrastructure/database/konata_database.dart';
import 'package:konata/infrastructure/logging/diagnostics_log_store.dart';
import 'package:konata/infrastructure/sync/konata_sync_store.dart';

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
  });
}
