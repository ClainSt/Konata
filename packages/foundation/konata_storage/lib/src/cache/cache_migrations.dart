import '../engine/konata_sqlite_engine.dart';
import 'schema/artwork_negative_cache_schema.dart';
import 'schema/lyric_cache_entries_schema.dart';
import 'schema/scrape_candidates_schema.dart';

/// `cache.db` 独立版本迁移脚本与索引清单（随时可删库重建）。
abstract final class CacheMigrations {
  /// 当前 `cache.db` 模式版本号。
  static const int currentVersion = 1;

  /// 按版本号递增排列的迁移步骤列表。
  static final List<SqliteMigration> steps = <SqliteMigration>[
    SqliteMigration(
      targetVersion: 1,
      migrate: (db) {
        db.execute(ScrapeCandidatesSchema.createTableSql);
        db.execute(LyricCacheEntriesSchema.createTableSql);
        db.execute(ArtworkNegativeCacheSchema.createTableSql);
      },
    ),
  ];

  /// 每次打开后幂等校验的覆盖索引语句集合。
  static const List<String> indexStatements = <String>[
    ...ScrapeCandidatesSchema.indexStatements,
    ...LyricCacheEntriesSchema.indexStatements,
    ...ArtworkNegativeCacheSchema.indexStatements,
  ];
}
