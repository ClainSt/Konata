import 'episodes_schema.dart';
import 'media_sources_schema.dart';
import 'works_schema.dart';

/// `media_variants` 表结构与列名常量（物理文件与多版本规格表）。
abstract final class MediaVariantsSchema {
  /// 物理表名。
  static const String table = 'media_variants';

  /// 物理版本主键。
  static const String colId = 'id';

  /// 跨设备稳定规范键。
  static const String colCanonicalKey = 'canonical_key';

  /// 所属作品主键（级联删除）。
  static const String colWorkId = 'work_id';

  /// 关联的逻辑剧集主键（剧集删除时置空）。
  static const String colEpisodeId = 'episode_id';

  /// 所属媒体源主键（级联删除）。
  static const String colSourceId = 'source_id';

  /// 相对媒体源根目录的路径。
  static const String colRelativePath = 'relative_path';

  /// 云盘稳定文件标识，不包含访问凭据。
  static const String colRemoteFileId = 'remote_file_id';

  /// 文件名（含扩展名）。
  static const String colFileName = 'file_name';

  /// 文件字节大小。
  static const String colFileSize = 'file_size';

  /// 资产分类（`video` / `cdAlbum` / `scanGallery`）。
  static const String colAssetKind = 'asset_kind';

  /// 压制组名称。
  static const String colReleaseGroup = 'release_group';

  /// 字幕组名称。
  static const String colSubtitleGroup = 'subtitle_group';

  /// 视频编码。
  static const String colVideoCodec = 'video_codec';

  /// 视频色深。
  static const String colBitDepth = 'bit_depth';

  /// 分辨率标签。
  static const String colResolution = 'resolution';

  /// 音频编码。
  static const String colAudioCodec = 'audio_codec';

  /// 外挂字幕相对路径列表 JSON。
  static const String colExternalSubtitlesJson = 'external_subtitles_json';

  /// 映射槽位人工锁。
  static const String colMappingLocked = 'mapping_locked';

  /// 作品归属人工锁。
  static const String colWorkLocked = 'work_locked';

  /// 附属资源在系列内的可见作用域。
  static const String colAssetScope = 'asset_scope';

  /// 作用域人工锁。
  static const String colScopeLocked = 'scope_locked';

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
  $colWorkId TEXT NOT NULL REFERENCES ${WorksSchema.table}(${WorksSchema.colId}) ON DELETE CASCADE,
  $colEpisodeId TEXT REFERENCES ${EpisodesSchema.table}(${EpisodesSchema.colId}) ON DELETE SET NULL,
  $colSourceId TEXT NOT NULL REFERENCES ${MediaSourcesSchema.table}(${MediaSourcesSchema.colId}) ON DELETE CASCADE,
  $colRelativePath TEXT NOT NULL,
  $colRemoteFileId TEXT,
  $colFileName TEXT NOT NULL,
  $colFileSize INTEGER NOT NULL DEFAULT 0,
  $colAssetKind TEXT NOT NULL DEFAULT 'video',
  $colReleaseGroup TEXT,
  $colSubtitleGroup TEXT,
  $colVideoCodec TEXT,
  $colBitDepth TEXT,
  $colResolution TEXT,
  $colAudioCodec TEXT,
  $colExternalSubtitlesJson TEXT NOT NULL DEFAULT '[]',
  $colMappingLocked INTEGER NOT NULL DEFAULT 0,
  $colWorkLocked INTEGER NOT NULL DEFAULT 0,
  $colAssetScope TEXT NOT NULL DEFAULT 'workExclusive',
  $colScopeLocked INTEGER NOT NULL DEFAULT 0,
  $colUpdatedAtMs INTEGER NOT NULL DEFAULT 0,
  $colSourceDeviceId TEXT NOT NULL DEFAULT '',
  $colDeletedAtMs INTEGER
);
''';

  /// 覆盖索引语句集合。
  static const List<String> indexStatements = <String>[
    'CREATE INDEX IF NOT EXISTS idx_media_variants_work '
        'ON $table ($colWorkId, $colDeletedAtMs);',
    'CREATE INDEX IF NOT EXISTS idx_media_variants_source '
        'ON $table ($colSourceId, $colDeletedAtMs);',
    'CREATE INDEX IF NOT EXISTS idx_media_variants_episode '
        'ON $table ($colEpisodeId);',
    'CREATE INDEX IF NOT EXISTS idx_media_variants_canonical '
        'ON $table ($colCanonicalKey);',
  ];
}
