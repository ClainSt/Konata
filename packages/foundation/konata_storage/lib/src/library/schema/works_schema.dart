import 'series_groups_schema.dart';

/// `works` 表结构与列名常量（作品核心资产主表）。
abstract final class WorksSchema {
  /// 物理表名。
  static const String table = 'works';

  /// 作品唯一主键（UUID）。
  static const String colId = 'id';

  /// 跨设备稳定规范键（例如 `tmdb:tv:12345:s1` 或 `bgm:9876`）。
  static const String colCanonicalKey = 'canonical_key';

  /// 绑定的 TMDB 条目编号。
  static const String colTmdbId = 'tmdb_id';

  /// TMDB 媒体类型（`tv` / `movie`）。
  static const String colTmdbMediaType = 'tmdb_media_type';

  /// 绑定的 Bangumi 条目编号。
  static const String colBangumiId = 'bangumi_id';

  /// 关联的 TheTVDB 剧集编号。
  static const String colTvdbId = 'tvdb_id';

  /// 季级匹配绑定季号。
  static const String colMatchedSeason = 'matched_season';

  /// 展示标题。
  static const String colTitle = 'title';

  /// 原始语言标题。
  static const String colOriginalTitle = 'original_title';

  /// 发行或首播年份。
  static const String colYear = 'year';

  /// 作品简介。
  static const String colOverview = 'overview';

  /// 封面海报 `ArtworkRef` 序列化 JSON。
  static const String colPosterRefJson = 'poster_ref_json';

  /// 备用海报相对路径或 URL。
  static const String colPosterFallback = 'poster_fallback';

  /// Bangumi 官方封面 URL。
  static const String colBangumiPosterPath = 'bangumi_poster_path';

  /// 横版无字背景 `ArtworkRef` 序列化 JSON。
  static const String colBackdropRefJson = 'backdrop_ref_json';

  /// 竖版无字原画 `ArtworkRef` 序列化 JSON（供手机与平板竖屏详情页展示）。
  static const String colPortraitBackdropRefJson = 'portrait_backdrop_ref_json';

  /// 透明 PNG 标题徽标 `ArtworkRef` 序列化 JSON。
  static const String colLogoRefJson = 'logo_ref_json';

  /// TMDB 评分（0.0 ~ 10.0）。
  static const String colVoteAverage = 'vote_average';

  /// Bangumi 评分（0.0 ~ 10.0）。
  static const String colBangumiScore = 'bangumi_score';

  /// 文件夹显式 TMDB 提示编号。
  static const String colFolderTmdbHint = 'folder_tmdb_hint';

  /// 作品匹配是否已人工锁定。
  static const String colIsManualLocked = 'is_manual_locked';

  /// 基础元数据是否已人工锁定。
  static const String colMetadataLocked = 'metadata_locked';

  /// 刮削状态（`matched` / `needsReview` / `unmatched`）。
  static const String colScrapeStatus = 'scrape_status';

  /// 待复核或未匹配原因码。
  static const String colReviewReason = 'review_reason';

  /// 所属系列编组主键。
  static const String colSeriesId = 'series_id';

  /// 在所属系列中的排序序号。
  static const String colSeriesOrder = 'series_order';

  /// 在系列下拉框中的展示标签。
  static const String colSeriesLabel = 'series_label';

  /// 系列归属是否已人工锁定。
  static const String colSeriesLocked = 'series_locked';

  /// 最近更新时间（UTC 毫秒）。
  static const String colUpdatedAtMs = 'updated_at_ms';

  /// 最近修改设备标识。
  static const String colSourceDeviceId = 'source_device_id';

  /// 软删除墓碑时间戳（UTC 毫秒）。
  static const String colDeletedAtMs = 'deleted_at_ms';

  /// 建表 DDL 语句。
  static const String createTableSql =
      '''
CREATE TABLE IF NOT EXISTS $table (
  $colId TEXT NOT NULL PRIMARY KEY,
  $colCanonicalKey TEXT,
  $colTmdbId INTEGER,
  $colTmdbMediaType TEXT,
  $colBangumiId INTEGER,
  $colTvdbId INTEGER,
  $colMatchedSeason INTEGER,
  $colTitle TEXT NOT NULL,
  $colOriginalTitle TEXT,
  $colYear INTEGER,
  $colOverview TEXT,
  $colPosterRefJson TEXT,
  $colPosterFallback TEXT,
  $colBangumiPosterPath TEXT,
  $colBackdropRefJson TEXT,
  $colPortraitBackdropRefJson TEXT,
  $colLogoRefJson TEXT,
  $colVoteAverage REAL,
  $colBangumiScore REAL,
  $colFolderTmdbHint INTEGER,
  $colIsManualLocked INTEGER NOT NULL DEFAULT 0,
  $colMetadataLocked INTEGER NOT NULL DEFAULT 0,
  $colScrapeStatus TEXT NOT NULL DEFAULT 'unmatched',
  $colReviewReason TEXT,
  $colSeriesId TEXT REFERENCES ${SeriesGroupsSchema.table}(${SeriesGroupsSchema.colId}) ON DELETE SET NULL,
  $colSeriesOrder INTEGER,
  $colSeriesLabel TEXT,
  $colSeriesLocked INTEGER NOT NULL DEFAULT 0,
  $colUpdatedAtMs INTEGER NOT NULL DEFAULT 0,
  $colSourceDeviceId TEXT NOT NULL DEFAULT '',
  $colDeletedAtMs INTEGER
);
''';

  /// 覆盖索引语句集合。
  static const List<String> indexStatements = <String>[
    'CREATE INDEX IF NOT EXISTS idx_works_visible '
        'ON $table ($colDeletedAtMs);',
    'CREATE INDEX IF NOT EXISTS idx_works_series '
        'ON $table ($colSeriesId);',
    'CREATE INDEX IF NOT EXISTS idx_works_canonical '
        'ON $table ($colCanonicalKey);',
    'CREATE INDEX IF NOT EXISTS idx_works_updated '
        'ON $table ($colUpdatedAtMs DESC);',
  ];
}
