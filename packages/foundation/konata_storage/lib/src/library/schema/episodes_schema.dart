import 'works_schema.dart';

/// `episodes` 表结构与列名常量（逻辑剧集与特典表）。
abstract final class EpisodesSchema {
  /// 物理表名。
  static const String table = 'episodes';

  /// 剧集主键。
  static const String colId = 'id';

  /// 跨设备稳定规范键。
  static const String colCanonicalKey = 'canonical_key';

  /// 所属作品主键（级联删除）。
  static const String colWorkId = 'work_id';

  /// 季号（特典通常为 0）。
  static const String colSeasonNumber = 'season_number';

  /// 集号或特典序号（未识别时为空）。
  static const String colEpisodeNumber = 'episode_number';

  /// 多集合并文件的区间结束集号。
  static const String colEpisodeNumberEnd = 'episode_number_end';

  /// 分类（`main` / `extra`）。
  static const String colCategory = 'category';

  /// 特典细分类型。
  static const String colExtraType = 'extra_type';

  /// 单集标题。
  static const String colTitle = 'title';

  /// 单集简介。
  static const String colOverview = 'overview';

  /// 单集剧照路径。
  static const String colStillPath = 'still_path';

  /// 最近更新时间（UTC 毫秒）。
  static const String colUpdatedAtMs = 'updated_at_ms';

  /// 最近修改设备标识。
  static const String colSourceDeviceId = 'source_device_id';

  /// 软删除墓碑时间戳（UTC 毫秒）。
  static const String colDeletedAtMs = 'deleted_at_ms';

  /// 建表 DDL 语句。
  static const String createTableSql = '''
CREATE TABLE IF NOT EXISTS $table (
  $colId TEXT NOT NULL PRIMARY KEY,
  $colCanonicalKey TEXT,
  $colWorkId TEXT NOT NULL REFERENCES ${WorksSchema.table}(${WorksSchema.colId}) ON DELETE CASCADE,
  $colSeasonNumber INTEGER NOT NULL,
  $colEpisodeNumber INTEGER,
  $colEpisodeNumberEnd INTEGER,
  $colCategory TEXT NOT NULL DEFAULT 'main',
  $colExtraType TEXT,
  $colTitle TEXT,
  $colOverview TEXT,
  $colStillPath TEXT,
  $colUpdatedAtMs INTEGER NOT NULL DEFAULT 0,
  $colSourceDeviceId TEXT NOT NULL DEFAULT '',
  $colDeletedAtMs INTEGER
);
''';

  /// 覆盖索引语句集合。
  static const List<String> indexStatements = <String>[
    'CREATE INDEX IF NOT EXISTS idx_episodes_work_order '
        'ON $table ($colWorkId, $colDeletedAtMs, $colSeasonNumber, $colEpisodeNumber);',
    'CREATE INDEX IF NOT EXISTS idx_episodes_canonical '
        'ON $table ($colCanonicalKey);',
  ];
}
