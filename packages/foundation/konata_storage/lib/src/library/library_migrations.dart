import '../engine/konata_sqlite_engine.dart';
import 'schema/episodes_schema.dart';
import 'schema/ignored_folders_schema.dart';
import 'schema/media_sources_schema.dart';
import 'schema/media_variants_schema.dart';
import 'schema/series_groups_schema.dart';
import 'schema/works_schema.dart';

/// `library.db` 独立版本迁移脚本与索引清单。
abstract final class LibraryMigrations {
  /// 当前 `library.db` 模式版本号。
  static const int currentVersion = 4;

  /// 按版本号递增排列的迁移步骤列表。
  static final List<SqliteMigration> steps = <SqliteMigration>[
    SqliteMigration(
      targetVersion: 1,
      migrate: (db) {
        db.execute(MediaSourcesSchema.createTableSql);
        db.execute(SeriesGroupsSchema.createTableSql);
        db.execute(WorksSchema.createTableSql);
        db.execute(EpisodesSchema.createTableSql);
        db.execute(MediaVariantsSchema.createTableSql);
        db.execute(IgnoredFoldersSchema.createTableSql);
      },
    ),
    SqliteMigration(
      targetVersion: 2,
      migrate: (db) {
        final columns = db.select('PRAGMA table_info(${WorksSchema.table});');
        final hasPortraitBackdrop = columns.any(
          (row) => row['name'] == WorksSchema.colPortraitBackdropRefJson,
        );
        if (!hasPortraitBackdrop) {
          db.execute(
            'ALTER TABLE ${WorksSchema.table} '
            'ADD COLUMN ${WorksSchema.colPortraitBackdropRefJson} TEXT;',
          );
        }
      },
    ),
    SqliteMigration(
      targetVersion: 3,
      migrate: (db) {
        final columns = db.select(
          'PRAGMA table_info(${MediaVariantsSchema.table});',
        );
        if (!columns.any(
          (row) => row['name'] == MediaVariantsSchema.colRemoteFileId,
        )) {
          db.execute(
            'ALTER TABLE ${MediaVariantsSchema.table} '
            'ADD COLUMN ${MediaVariantsSchema.colRemoteFileId} TEXT;',
          );
        }
      },
    ),
    SqliteMigration(
      targetVersion: 4,
      migrate: (db) {
        // 原位移除废弃可见性标记，保留作品、关联外键、行序及删除墓碑。
        db.execute('DROP INDEX IF EXISTS idx_works_visible;');
        final columns = db.select('PRAGMA table_info(${WorksSchema.table});');
        for (final name in ['is_hidden', 'keep_hidden']) {
          if (columns.any((row) => row['name'] == name)) {
            db.execute('ALTER TABLE ${WorksSchema.table} DROP COLUMN $name;');
          }
        }
      },
    ),
  ];

  /// 每次打开后幂等校验的覆盖索引语句集合。
  static const List<String> indexStatements = <String>[
    ...MediaSourcesSchema.indexStatements,
    ...SeriesGroupsSchema.indexStatements,
    ...WorksSchema.indexStatements,
    ...EpisodesSchema.indexStatements,
    ...MediaVariantsSchema.indexStatements,
    ...IgnoredFoldersSchema.indexStatements,
  ];
}
