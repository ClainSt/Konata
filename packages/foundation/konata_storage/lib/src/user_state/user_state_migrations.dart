import '../engine/konata_sqlite_engine.dart';
import 'schema/lyric_user_overrides_schema.dart';
import 'schema/playback_records_schema.dart';
import 'schema/scoped_prefs_schema.dart';
import 'schema/sync_meta_schema.dart';
import 'schema/tracker_sync_queue_schema.dart';

/// `user_state.db` 独立版本迁移脚本与索引清单。
abstract final class UserStateMigrations {
  /// 当前 `user_state.db` 模式版本号。
  static const int currentVersion = 1;

  /// 按版本号递增排列的迁移步骤列表。
  static final List<SqliteMigration> steps = <SqliteMigration>[
    SqliteMigration(
      targetVersion: 1,
      migrate: (db) {
        db.execute(PlaybackRecordsSchema.createTableSql);
        db.execute(ScopedPrefsSchema.createTableSql);
        db.execute(LyricUserOverridesSchema.createTableSql);
        db.execute(SyncMetaSchema.createTableSql);
        db.execute(TrackerSyncQueueSchema.createTableSql);
      },
    ),
  ];

  /// 每次打开后幂等校验的覆盖索引语句集合。
  static const List<String> indexStatements = <String>[
    ...PlaybackRecordsSchema.indexStatements,
    ...ScopedPrefsSchema.indexStatements,
    ...LyricUserOverridesSchema.indexStatements,
    ...TrackerSyncQueueSchema.indexStatements,
  ];
}
