import 'package:konata_contracts/konata_contracts.dart';

import '../engine/konata_sqlite_engine.dart';
import 'dao/lyric_user_override_dao.dart';
import 'dao/playback_record_dao.dart';
import 'dao/scoped_prefs_dao.dart';
import 'dao/sync_meta_dao.dart';
import 'dao/tracker_sync_queue_dao.dart';
import 'user_state_migrations.dart';

/// `user_state.db` 用户态与同步库门面（高频轻量读写不锁 `library.db`）。
final class UserStateDatabase {
  UserStateDatabase._(this.engine)
    : playbackRecords = PlaybackRecordDao(engine),
      scopedPrefs = ScopedPrefsDao(engine),
      lyricUserOverrides = LyricUserOverrideDao(engine),
      syncMeta = SyncMetaDao(engine),
      trackerSyncQueue = TrackerSyncQueueDao(engine);

  /// 打开物理文件型 `user_state.db`（默认分配 4 MiB 页缓存）。
  factory UserStateDatabase.openFile(
    String filePath, {
    int cacheSizeKib = 4096,
  }) {
    final engine = KonataSqliteEngine.openFile(
      filePath: filePath,
      databaseName: 'user_state',
      migrations: UserStateMigrations.steps,
      postOpenStatements: UserStateMigrations.indexStatements,
      cacheSizeKib: cacheSizeKib,
    );
    return UserStateDatabase._(engine);
  }

  /// 打开纯内存 `user_state.db`（用于 `:memory:` 单元测试）。
  factory UserStateDatabase.openInMemory() {
    final engine = KonataSqliteEngine.openInMemory(
      databaseName: 'user_state',
      migrations: UserStateMigrations.steps,
      postOpenStatements: UserStateMigrations.indexStatements,
    );
    return UserStateDatabase._(engine);
  }

  /// 底层响应式 SQLite 引擎。
  final KonataSqliteEngine engine;

  /// 播放历史记录表 DAO。
  final PlaybackRecordDao playbackRecords;

  /// 分命名空间配置切片表 DAO。
  final ScopedPrefsDao scopedPrefs;

  /// 用户手动歌词与偏移覆盖表 DAO。
  final LyricUserOverrideDao lyricUserOverrides;

  /// 同步元信息表 DAO。
  final SyncMetaDao syncMeta;

  /// 通用多平台第三方追番同步队列表 DAO。
  final TrackerSyncQueueDao trackerSyncQueue;

  /// 构造跨包只读播放进度查询端口适配器。
  PlaybackReadPort createPlaybackReadPort() =>
      StoragePlaybackReadAdapter(this);

  /// 关闭数据库连接。
  Future<void> close() => engine.close();
}

/// 将 [UserStateDatabase] 适配为 `konata_contracts` 定义的极薄只读 [PlaybackReadPort]。
final class StoragePlaybackReadAdapter implements PlaybackReadPort {
  /// 创建播放进度只读适配器。
  const StoragePlaybackReadAdapter(this._db);

  final UserStateDatabase _db;

  @override
  Future<PlaybackResumeView?> findLatestForWork(WorkId workId) async =>
      _db.playbackRecords.findLatestByWork(workId)?.toResumeView();

  @override
  Future<PlaybackResumeView?> findLatestForEpisode(EpisodeId episodeId) async =>
      _db.playbackRecords.findLatestByEpisode(episodeId)?.toResumeView();
}
