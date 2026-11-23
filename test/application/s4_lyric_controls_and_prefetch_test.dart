import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart' as sq;

import 'package:konata/application/playback/audio_playback_notifier.dart';
import 'package:konata/application/playback/audiophile_safety_coordinator.dart';
import 'package:konata/application/playback/lyric_candidate_sources.dart';
import 'package:konata/application/playback/lyric_race_engine.dart';
import 'package:konata/application/playback/lyrics_resolver.dart';
import 'package:konata/application/playback/playback_preferences_provider.dart';
import 'package:konata/application/playback/unified_playback_engine.dart';
import 'package:konata/application/providers/library_providers.dart';
import 'package:konata/domain/lyrics/bangumi_track_enricher.dart';
import 'package:konata/domain/lyrics/lyric_candidate.dart';
import 'package:konata/domain/lyrics/lyric_offset_resolver.dart';
import 'package:konata/domain/lyrics/lyric_search_query.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/domain/playback/playback_probe_stats.dart';
import 'package:konata/domain/playback/track_preferences.dart';
import 'package:konata/domain/repositories/lyric_cache_repository.dart';
import 'package:konata/infrastructure/database/drift_library_repository.dart';
import 'package:konata/infrastructure/database/drift_lyric_cache_repository.dart';
import 'package:konata/infrastructure/database/konata_database.dart';
import 'package:konata/infrastructure/players/libmpv_ffi.dart';
import 'package:konata/infrastructure/storage/storage_root_provider.dart';

class _RecordingCandidateSource implements LyricCandidateSource {
  _RecordingCandidateSource(this.label, this._handler);

  @override
  final String label;
  final Stream<LyricCandidate> Function(LyricSearchQuery query) _handler;
  final List<LyricSearchQuery> queries = [];

  @override
  Stream<LyricCandidate> candidates(LyricSearchQuery query) {
    queries.add(query);
    return _handler(query);
  }
}

class _S4FakeAudioClient implements LibMpvClient {
  final StreamController<MpvClientEvent> _events =
      StreamController<MpvClientEvent>.broadcast();
  final Map<String, String> _stringProps = {};
  final Map<String, double> _doubleProps = {};
  bool _disposed = false;
  bool _initialized = false;

  void emitTimePos(double seconds) {
    _doubleProps['time-pos'] = seconds;
    _events.add(
      MpvPropertyChangeEvent(
        name: 'time-pos',
        replyUserdata: 101,
        format: MpvFormat.double_,
        doubleValue: seconds,
      ),
    );
  }

  @override
  int get handleAddress => 0;

  @override
  bool get isDisposed => _disposed;

  @override
  bool get isInitialized => _initialized && !_disposed;

  @override
  Stream<MpvClientEvent> get events => _events.stream;

  @override
  int initialize() {
    _initialized = true;
    return 0;
  }

  @override
  int command(List<String> args) {
    if (args.length >= 2 && args.first == 'loadfile') {
      scheduleMicrotask(() {
        if (!_disposed && !_events.isClosed) {
          _events.add(const MpvStartFileEvent(1));
          _events.add(const MpvFileLoadedEvent());
          _events.add(const MpvPlaybackRestartEvent());
          _events.add(
            const MpvPropertyChangeEvent(
              name: 'pause',
              replyUserdata: 103,
              format: MpvFormat.flag,
              boolValue: false,
            ),
          );
          _events.add(
            const MpvPropertyChangeEvent(
              name: 'duration',
              replyUserdata: 102,
              format: MpvFormat.double_,
              doubleValue: 204.0,
            ),
          );
        }
      });
    }
    return 0;
  }

  @override
  int commandAsync(int replyUserdata, List<String> args) => command(args);

  @override
  int setOptionString(String name, String value) {
    _stringProps[name] = value;
    return 0;
  }

  @override
  int setPropertyString(String name, String value) {
    _stringProps[name] = value;
    return 0;
  }

  @override
  int setPropertyFlag(String name, bool value) => 0;

  @override
  int setPropertyInt64(String name, int value) {
    _stringProps[name] = '$value';
    return 0;
  }

  @override
  int setPropertyDouble(String name, double value) {
    _doubleProps[name] = value;
    return 0;
  }

  @override
  String? getPropertyString(String name) => _stringProps[name];

  @override
  double? getPropertyDouble(String name) => _doubleProps[name];

  @override
  bool? getPropertyFlag(String name) => false;

  @override
  int? getPropertyInt64(String name) => 0;

  @override
  int observeProperty(int replyUserdata, String name, int format) => 0;

  @override
  int requestLogMessages(String minLevel) => 0;

  @override
  String errorString(int errorCode) => 'ok($errorCode)';

  @override
  List<MpvTrackInfo> readTrackList() => const [];

  @override
  List<PlaybackChapter> readChapterList({double? totalDurationSeconds}) =>
      const [];

  @override
  List<MpvAudioDevice> readAudioDeviceList() => const [];

  @override
  List<MpvSeekableRange> readDemuxerSeekableRanges() => const [];

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _events.close();
  }
}

Future<void> _pumpUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      break;
    }
    await Future<void>.delayed(const Duration(milliseconds: 15));
  }
}

void main() {
  setUpAll(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('S4 Drift Schema v15 → v16 迁移与三级偏移持久仓储', () {
    test('v15 旧库无缝升级至 v16：保留既有缓存行、新增偏移与锁列、创建专辑偏移表', () async {
      final raw = sq.sqlite3.openInMemory();
      // 模拟 v15 已有完整核心表结构与一条历史歌词缓存（尚未包含 offset_millis 等列）。
      raw.execute('''
        CREATE TABLE media_sources (id TEXT PRIMARY KEY);
        CREATE TABLE series (id TEXT PRIMARY KEY);
        CREATE TABLE works (id TEXT PRIMARY KEY, series_id TEXT, is_hidden INTEGER DEFAULT 0);
        CREATE TABLE episodes (id TEXT PRIMARY KEY, work_id TEXT, season_number INTEGER, episode_number INTEGER);
        CREATE TABLE media_variants (id TEXT PRIMARY KEY, work_id TEXT, source_id TEXT, episode_id TEXT);
        CREATE TABLE playback_records (id TEXT PRIMARY KEY, work_id TEXT, episode_id TEXT, played_at INTEGER);
        CREATE TABLE ignored_folders (id TEXT PRIMARY KEY, source_id TEXT);
        CREATE TABLE sync_tombstones (id TEXT PRIMARY KEY, entity_type TEXT, deleted_at_ms INTEGER);
        CREATE TABLE bangumi_sync_queue (id TEXT PRIMARY KEY, next_retry_at_ms INTEGER);
        CREATE TABLE lyric_cache_entries (
          track_key TEXT NOT NULL PRIMARY KEY,
          song_key TEXT,
          status TEXT NOT NULL,
          source TEXT,
          source_id TEXT NOT NULL DEFAULT '',
          lrc_content TEXT NOT NULL DEFAULT '',
          score REAL NOT NULL DEFAULT 0.0,
          engine_version INTEGER NOT NULL DEFAULT 1,
          updated_at INTEGER NOT NULL
        );
      ''');
      final ts = DateTime(2026, 11, 1).millisecondsSinceEpoch ~/ 1000;
      raw.execute(
        "INSERT INTO lyric_cache_entries VALUES ('src|a.flac|100|', 'song_a', 'found', 'netease', '101', '[00:01.00]旧行', 0.95, 1, $ts);",
      );
      raw.execute('PRAGMA user_version = 15;');

      final db = KonataDatabase(NativeDatabase.opened(raw));
      addTearDown(db.close);

      final repo = DriftLyricCacheRepository(db);
      final migrated = await repo.findByTrackKey('src|a.flac|100|');
      expect(migrated, isNotNull);
      expect(migrated!.lrcContent, '[00:01.00]旧行');
      expect(migrated.offsetMillis, 0);
      expect(migrated.userOffsetLocked, isFalse);
      expect(migrated.userEdited, isFalse);

      // 无在线缓存记录的纯本地外挂 `.lrc` 曲目也可独立写入单曲偏移锚点（engineVersion = 0）。
      await repo.updateTrackOffset(
        'local|ext.flac|200|',
        offsetMillis: 350,
        userOffsetLocked: true,
      );
      final localAnchor = await repo.findByTrackKey('local|ext.flac|200|');
      expect(localAnchor, isNotNull);
      expect(localAnchor!.offsetMillis, 350);
      expect(localAnchor.userOffsetLocked, isTrue);
      expect(localAnchor.engineVersion, 0);

      // 专辑偏移表读写与归零清理。
      await repo.saveAlbumOffsetMillis('album:結束バンド', -400);
      expect(await repo.findAlbumOffsetMillis('album:結束バンド'), -400);
      await repo.saveAlbumOffsetMillis('album:結束バンド', 0);
      expect(await repo.findAlbumOffsetMillis('album:結束バンド'), 0);
    });
  });

  group('S4 用户编辑锁、手动重搜、Bangumi 补全与分级队列预取', () {
    test('手动重搜返回含低置信度的全部非占位候选；手动锁定后永不被自动流程或版本升级覆盖', () async {
      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLyricCacheRepository(db);
      final engine = UnifiedPlaybackEngine();

      final source = _RecordingCandidateSource('Netease', (query) async* {
        // 占位纯音乐候选应被过滤。
        yield const LyricCandidate(
          source: LyricSource.netease,
          sourceId: 'inst_1',
          title: '青春コンプレックス',
          artist: '結束バンド',
          lrcContent: '[00:00.00]纯音乐，请欣赏',
        );
        // 低置信度（时长/名偏离）候选在手动重搜中应保留供用户挑选。
        yield const LyricCandidate(
          source: LyricSource.netease,
          sourceId: 'alt_live',
          title: 'Seishun Complex Live Ver',
          artist: 'Bocchi',
          durationSeconds: 260,
          lrcContent:
              '[00:05.00]手动现场版第一句\n[00:10.00]手动现场版第二句\n[00:15.00]手动现场版第三句',
        );
        // 高分标准候选。
        yield const LyricCandidate(
          source: LyricSource.netease,
          sourceId: 'std_1',
          title: '青春コンプレックス',
          artist: '結束バンド',
          durationSeconds: 204,
          lrcContent:
              '[00:05.00]自动标准版第一句\n[00:10.00]自动标准版第二句\n[00:15.00]自动标准版第三句',
        );
      });

      final resolver = LyricsResolver(
        playbackEngine: engine,
        cacheRepository: repo,
        sourcesFactory: () async => [source],
        raceEngine: const LyricRaceEngine(
          firstPaintGrace: Duration(milliseconds: 20),
          lowConfidencePaintAfter: Duration(milliseconds: 50),
          deadline: Duration(milliseconds: 200),
        ),
      );

      final query = LyricSearchQuery(
        title: '青春コンプレックス',
        artist: '結束バンド',
        durationSeconds: 204,
      );
      final candidates = await resolver.searchCandidatesManual(
        query,
        trackKey: 'track_lock_1',
      );
      expect(candidates.map((c) => c.candidate.sourceId), ['std_1', 'alt_live']);

      // 用户先锁单曲偏移 +300ms，再手动选定 alt_live。
      await resolver.saveTrackOffset(
        'track_lock_1',
        offsetMillis: 300,
        userOffsetLocked: true,
      );
      final manualChoice = candidates.firstWhere(
        (c) => c.candidate.sourceId == 'alt_live',
      );
      final applied = await resolver.applyManualCandidate(
        trackKey: 'track_lock_1',
        songKey: query.songKey,
        selected: manualChoice,
      );
      expect(applied, isNotNull);
      expect(applied!.userEdited, isTrue);
      expect(applied.trackOffsetMillis, 300);

      // 模拟未来引擎版本升级（把行 engineVersion 降为旧版本 0）后再跑自动解析：仍必须命中用户锁定版且 0 网络请求。
      final savedRow = await repo.findByTrackKey('track_lock_1');
      await repo.save(savedRow!.copyWith(engineVersion: 0));
      source.queries.clear();

      final req = LyricResolveRequest(trackKey: 'track_lock_1', query: query);
      final autoAgain = await resolver.resolve(req);
      expect(autoAgain.fromCache, isTrue);
      expect(autoAgain.userEdited, isTrue);
      expect(autoAgain.sourceId, 'alt_live');
      expect(autoAgain.trackOffsetMillis, 300);
      expect(source.queries, isEmpty);

      // 后台预取也绝对不能覆盖 userEdited 条目。
      final prefetched = await resolver.prefetchUpcomingTracks([req]);
      expect(prefetched, 0);
      expect(source.queries, isEmpty);

      // 解除用户锁定后执行 bypassCache 自动重匹配：切换回高分 std_1，同时完整保留单曲偏移 +300ms。
      await resolver.unlockUserEdit('track_lock_1');
      final restored = await resolver.resolve(req, bypassCache: true);
      expect(restored.sourceId, 'std_1');
      expect(restored.userEdited, isFalse);
      expect(restored.trackOffsetMillis, 300);
      expect(restored.userOffsetLocked, isTrue);
    });

    test('Bangumi 关联音乐条目恢复 Track 01 真实日文原名；常规曲名超时不拖慢首屏', () async {
      final engine = UnifiedPlaybackEngine();
      final source = _RecordingCandidateSource('Netease', (query) async* {
        if (query.title.contains('青春コンプレックス')) {
          yield const LyricCandidate(
            source: LyricSource.netease,
            sourceId: 'bgm_recovered',
            title: '青春コンプレックス',
            artist: '結束バンド',
            durationSeconds: 204,
            lrcContent:
                '[00:05.00]青い春が\n[00:10.00]駆け抜ける\n[00:15.00]今ここで叫ぶ',
          );
        }
      });

      final resolver = LyricsResolver(
        playbackEngine: engine,
        sourcesFactory: () async => [source],
        bangumiMusicTracksLoader: (subjectId) async {
          if (subjectId == 328609) {
            return const [
              BangumiMusicTrack(
                subjectId: 400001,
                subjectTitle: '結束バンド',
                trackNumber: 1,
                title: '青春コンプレックス',
                titleCn: '青春情结',
              ),
            ];
          }
          // 模拟慢速 Bangumi 接口，验证常规清晰曲名最多等 150ms 即降级放行。
          await Future<void>.delayed(const Duration(seconds: 2));
          return const [];
        },
      );

      final weakOutcome = await resolver.resolve(
        LyricResolveRequest(
          trackKey: 'weak_track_01',
          bangumiSubjectId: 328609,
          trackNumber: 1,
          query: LyricSearchQuery(
            title: 'Track 01',
            album: '結束バンド',
            fileName: 'Track 01.flac',
            durationSeconds: 204,
          ),
        ),
      );
      expect(weakOutcome.sourceId, 'bgm_recovered');
      expect(source.queries.first.title, '青春コンプレックス');

      final sw = Stopwatch()..start();
      final enrichedSlow = await resolver.enrichQueryWithBangumi(
        LyricResolveRequest(
          trackKey: 'normal_slow',
          bangumiSubjectId: 999999,
          query: LyricSearchQuery(title: 'unravel', artist: 'TK'),
        ),
      );
      sw.stop();
      expect(enrichedSlow.title, 'unravel');
      expect(sw.elapsedMilliseconds, lessThan(600));
    });

    test('队列分级预取：Wi-Fi 预取后续 2 首、移动计量网络只预取 1 首，预取后切歌零网络命中缓存', () async {
      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLyricCacheRepository(db);
      final engine = UnifiedPlaybackEngine();

      var metered = false;
      final source = _RecordingCandidateSource('Netease', (query) async* {
        yield LyricCandidate(
          source: LyricSource.netease,
          sourceId: 'id_${query.title}',
          title: query.title,
          artist: query.artist,
          durationSeconds: query.durationSeconds,
          lrcContent:
              '[00:02.00]${query.title} 第一句\n[00:08.00]${query.title} 第二句\n[00:14.00]${query.title} 第三句',
        );
      });

      final resolver = LyricsResolver(
        playbackEngine: engine,
        cacheRepository: repo,
        isMeteredNetwork: () async => metered,
        sourcesFactory: () async => [source],
        raceEngine: const LyricRaceEngine(
          firstPaintGrace: Duration(milliseconds: 10),
          lowConfidencePaintAfter: Duration(milliseconds: 30),
          deadline: Duration(milliseconds: 150),
        ),
      );

      LyricResolveRequest makeReq(String id, String title) => LyricResolveRequest(
        trackKey: 'k_$id',
        query: LyricSearchQuery(
          title: title,
          artist: '結束バンド',
          durationSeconds: 200,
        ),
      );

      final upcomingWifi = [
        makeReq('2', 'ひとりぼっち東京'),
        makeReq('3', 'Distortion!!'),
        makeReq('4', 'カラカラ'),
      ];
      final wifiCount = await resolver.prefetchUpcomingTracks(upcomingWifi);
      expect(wifiCount, 2);
      expect(source.queries.map((q) => q.title), ['ひとりぼっち東京', 'Distortion!!']);

      // 已预取的第 2 首切歌时必须零网络命中持久缓存。
      source.queries.clear();
      final hit = await resolver.resolve(upcomingWifi.first);
      expect(hit.fromCache, isTrue);
      expect(hit.sourceId, 'id_ひとりぼっち東京');
      expect(source.queries, isEmpty);

      // 切换移动计量网络：仅预取后续 1 首（绝不触碰第 2 首）。
      metered = true;
      final upcomingMobile = [
        makeReq('5', 'ギターと孤独と蒼い惑星'),
        makeReq('6', 'あのバンド'),
      ];
      final mobileCount = await resolver.prefetchUpcomingTracks(upcomingMobile);
      expect(mobileCount, 1);
      expect(source.queries.map((q) => q.title), ['ギターと孤独と蒼い惑星']);
    });
  });

  group('S4 AudioPlaybackNotifier 端到端控制、三级偏移联动与防覆盖守卫', () {
    test('三级偏移实时叠加、一键应用到整张专辑、蓝牙路由切换联动及用户锁定免疫渐进升级', () async {
      final tmpDir = await Directory.systemTemp.createTemp('konata_s4_audio_');
      addTearDown(() async {
        if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
      });
      final albumDir = Directory('${tmpDir.path}${Platform.pathSeparator}結束バンド')
        ..createSync(recursive: true);
      final f1 = File(
        '${albumDir.path}${Platform.pathSeparator}01_青春コンプレックス.flac',
      )..writeAsBytesSync(const [0, 1, 2, 3]);
      final f2 = File(
        '${albumDir.path}${Platform.pathSeparator}02_ひとりぼっち東京.flac',
      )..writeAsBytesSync(const [0, 1, 2, 3, 4]);

      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final libRepo = DriftLibraryRepository(db);
      final fakeClient = _S4FakeAudioClient();
      final upgradeGate = Completer<void>();

      final neteaseFast = _RecordingCandidateSource('Netease', (query) async* {
        if (query.title.contains('青春コンプレックス')) {
          yield const LyricCandidate(
            source: LyricSource.netease,
            sourceId: 'ncm_fast',
            title: '青春コンプレックス',
            artist: '結束バンド',
            durationSeconds: 204,
            lrcContent: '[00:10.00]第一句\n[00:11.00]第二句\n[00:12.00]第三句',
          );
          yield const LyricCandidate(
            source: LyricSource.netease,
            sourceId: 'ncm_user_pick',
            title: '青春コンプレックス (User Pick)',
            artist: '結束バンド',
            durationSeconds: 204,
            lrcContent: '[00:10.00]用户锁定第一句\n[00:11.00]用户锁定第二句\n[00:12.00]用户锁定第三句',
          );
        } else if (query.title.contains('ひとりぼっち東京')) {
          yield const LyricCandidate(
            source: LyricSource.netease,
            sourceId: 'ncm_track2',
            title: 'ひとりぼっち東京',
            artist: '結束バンド',
            durationSeconds: 204,
            lrcContent:
                '[00:05.00]第二首第一句\n[00:06.00]第二首第二句\n[00:07.00]第二首第三句',
          );
        }
      });

      final amllSlow = _RecordingCandidateSource('AMLL', (query) async* {
        if (query.title.contains('青春コンプレックス')) {
          await upgradeGate.future;
          yield const LyricCandidate(
            source: LyricSource.amll,
            sourceId: 'amll_word_upgrade',
            title: '青春コンプレックス',
            artist: '結束バンド',
            durationSeconds: 204,
            hasWordTiming: true,
            lrcContent:
                '[00:10.00]<00:10.000-00:10.800>第一句\n[00:11.00]<00:11.000-00:11.800>第二句\n[00:12.00]<00:12.000-00:12.800>第三句',
          );
        }
      });

      final container = ProviderContainer(
        overrides: [
          storageRootProvider.overrideWithValue(
            StorageRootService(overrideRoot: tmpDir),
          ),
          libraryRepositoryProvider.overrideWithValue(libRepo),
          libraryItemsProvider.overrideWith((ref) async => const []),
          playbackPreferencesProvider.overrideWith(
            () => PlaybackPreferencesNotifier(enablePersistence: false),
          ),
          audioPlaybackProvider.overrideWith(
            () => AudioPlaybackNotifier(clientFactory: () => fakeClient),
          ),
          lyricsResolverProvider.overrideWith((ref) {
            final resolver = LyricsResolver(
              playbackEngine: ref.read(unifiedPlaybackEngineProvider),
              cacheRepository: ref.read(lyricCacheRepositoryProvider),
              isMeteredNetwork: () async => false,
              sourcesFactory: () async => [neteaseFast, amllSlow],
              raceEngine: const LyricRaceEngine(
                firstPaintGrace: Duration(milliseconds: 25),
                lowConfidencePaintAfter: Duration(milliseconds: 50),
                deadline: Duration(seconds: 2),
              ),
            );
            ref.onDispose(resolver.cancelPendingLookups);
            return resolver;
          }),
        ],
      );
      addTearDown(container.dispose);

      const work = Work(id: 'w_s4', title: '孤独摇滚！');
      final v1 = MediaVariant(
        id: 'v1',
        workId: 'w_s4',
        sourceId: 'local_s4',
        relativePath: '結束バンド/01_青春コンプレックス.flac',
        fileName: '01_青春コンプレックス.flac',
        fileSize: f1.lengthSync(),
        assetKind: AssetKind.cdAlbum,
      );
      final v2 = MediaVariant(
        id: 'v2',
        workId: 'w_s4',
        sourceId: 'local_s4',
        relativePath: '結束バンド/02_ひとりぼっち東京.flac',
        fileName: '02_ひとりぼっち東京.flac',
        fileSize: f2.lengthSync(),
        assetKind: AssetKind.cdAlbum,
      );

      final notifier = container.read(audioPlaybackProvider.notifier);
      await notifier.playCdCollection(
        work: work,
        cdVariants: [v1, v2],
        initialVariant: v1,
        sourcesById: const {},
      );

      // 等待第一首首屏歌词就绪，并等第二首后台预取落盘。
      final cacheRepo = container.read(lyricCacheRepositoryProvider)!;
      final track2Item = container.read(audioPlaybackProvider).queue[1];
      final track2Key = LyricsResolver.buildTrackKey(
        physicalFileKey: track2Item.physicalFileKey,
        fileSize: v2.fileSize,
      );
      await _pumpUntil(
        () => container.read(audioPlaybackProvider).lrcDocument != null,
      );
      expect(
        container.read(audioPlaybackProvider).activeLyricSourceId,
        'ncm_fast',
      );

      // 在 AMLL 慢速渐进升级到达之前，用户手动选定 ncm_user_pick 并锁定。
      final manualList = await notifier.searchLyricCandidatesManual(
        title: '青春コンプレックス',
        artist: '結束バンド',
      );
      final userPick = manualList.firstWhere(
        (c) => c.candidate.sourceId == 'ncm_user_pick',
      );
      expect(await notifier.selectLyricCandidate(userPick), isTrue);
      expect(container.read(audioPlaybackProvider).isLyricUserEdited, isTrue);
      expect(
        container.read(audioPlaybackProvider).activeLyricSourceId,
        'ncm_user_pick',
      );

      // 放行 AMLL 逐字渐进升级：由于用户已手动锁定，绝不允许覆盖。
      upgradeGate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      fakeClient.emitTimePos(10.7);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        container.read(audioPlaybackProvider).activeLyricSourceId,
        'ncm_user_pick',
      );
      expect(
        container
            .read(audioPlaybackProvider)
            .lrcDocument!
            .lines
            .first
            .primaryText,
        '用户锁定第一句',
      );
      expect(container.read(audioPlaybackProvider).activeLyricIndex, 0);

      // 单曲偏移 +500ms：10.7s + 0.5s = 11.2s，实时提前到索引 1（零重解析）。
      await notifier.adjustTrackLyricOffsetMillis(500);
      expect(container.read(audioPlaybackProvider).lyricOffset.trackOffsetMillis, 500);
      expect(container.read(audioPlaybackProvider).lyricOffset.totalOffsetMillis, 500);
      expect(container.read(audioPlaybackProvider).activeLyricIndex, 1);

      // 一键提升为整张专辑偏移：单曲归零，专辑变为 +500ms，总偏移零跳变。
      await notifier.promoteCurrentOffsetToAlbum();
      expect(container.read(audioPlaybackProvider).lyricOffset.trackOffsetMillis, 0);
      expect(container.read(audioPlaybackProvider).lyricOffset.albumOffsetMillis, 500);
      expect(container.read(audioPlaybackProvider).lyricOffset.totalOffsetMillis, 500);

      // 预置蓝牙路由补偿 +800ms，随后模拟切到蓝牙耳机：10.7s + 0.5s + 0.8s = 12.0s → 索引 2。
      await notifier.setRouteLyricOffsetMillis(LyricAudioRouteKind.bluetooth, 800);
      container
          .read(audiophileSafetyCoordinatorProvider)
          .handleExternalDeviceChanged('android:a2dp:airpods_pro');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final btOffset = container.read(audioPlaybackProvider).lyricOffset;
      expect(btOffset.activeRouteKind, LyricAudioRouteKind.bluetooth);
      expect(btOffset.routeOffsetMillis, 800);
      expect(btOffset.totalOffsetMillis, 1300);
      expect(container.read(audioPlaybackProvider).activeLyricIndex, 2);

      // 等待后台预取完成第二首落库，清空网络记录后切至第二首：必须零网络命中缓存并自动继承专辑 + 蓝牙偏移。
      await _pumpUntil(() {
        return true;
      });
      // 等待后台缓存确实写入（最多 2 秒）。
      LyricCacheEntry? prefetchedRow;
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (prefetchedRow == null && DateTime.now().isBefore(deadline)) {
        prefetchedRow = await cacheRepo.findByTrackKey(track2Key);
        if (prefetchedRow == null) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
      }
      expect(prefetchedRow, isNotNull);
      expect(prefetchedRow!.sourceId, 'ncm_track2');

      neteaseFast.queries.clear();
      await notifier.next();
      await _pumpUntil(
        () =>
            container.read(audioPlaybackProvider).activeLyricSourceId ==
            'ncm_track2',
      );
      expect(neteaseFast.queries, isEmpty);
      final t2Offset = container.read(audioPlaybackProvider).lyricOffset;
      expect(t2Offset.albumOffsetMillis, 500);
      expect(t2Offset.routeOffsetMillis, 800);
      expect(t2Offset.totalOffsetMillis, 1300);

      await notifier.stopAndClose();
    });
  });
}
