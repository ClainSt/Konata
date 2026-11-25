import '../models/episode.dart';
import '../models/media_source.dart';
import '../models/media_variant.dart';
import '../models/playback_record.dart';
import '../models/series_group.dart';
import '../models/tmdb_models.dart';
import '../models/work.dart';

/// 媒体库核心持久化仓储抽象接口（纯 Dart 领域端口，隔离具体 SQLite DAO 实现）。
abstract interface class LibraryRepository {
  /// 新增或更新媒体源元数据。
  Future<void> upsertMediaSource(MediaSource source);

  /// 根据主键 ID 查询媒体源。
  Future<MediaSource?> findSourceById(String sourceId);

  /// 获取全部已配置的媒体源列表。
  Future<List<MediaSource>> getMediaSources();

  /// 新增或更新作品实体。
  Future<void> upsertWork(Work work);

  /// 根据主键 ID 查询单个作品。
  Future<Work?> findWorkById(String workId);

  /// 查询全部作品列表。
  Future<List<Work>> getAllWorks();

  /// 按系列 ID 索引查询所属系列全部作品。
  Future<List<Work>> getWorksBySeries(String seriesId);

  /// 新增或更新逻辑剧集条目。
  Future<void> upsertEpisode(Episode episode);

  /// 在单个批量事务中写入或更新多条逻辑剧集条目。
  Future<void> upsertEpisodesBatch(List<Episode> episodes);

  /// 查询指定作品下的全部剧集与特典。
  Future<List<Episode>> getEpisodesByWork(String workId);

  /// 一次性批量查询库内全部逻辑剧集。
  Future<List<Episode>> getAllEpisodes();

  /// 批量查询多个作品关联的全部逻辑剧集。
  Future<List<Episode>> getEpisodesByWorkIds(List<String> workIds);

  /// 新增或更新物理文件版本记录。
  Future<void> upsertMediaVariant(MediaVariant variant);

  /// 在单个批量事务中写入或更新多条物理文件版本记录。
  Future<void> upsertMediaVariantsBatch(List<MediaVariant> variants);

  /// 按 ID 批量删除源目录中已移除的失效物理文件版本记录。
  Future<void> deleteMediaVariantsBatch(List<String> variantIds);

  /// 查询指定作品关联的全部物理文件版本。
  Future<List<MediaVariant>> getVariantsByWork(String workId);

  /// 批量查询多个作品关联的全部物理文件版本。
  Future<List<MediaVariant>> getVariantsByWorkIds(List<String> workIds);

  /// 查询指定媒体源下全部已入库的物理文件版本。
  Future<List<MediaVariant>> getVariantsBySource(String sourceId);

  /// 查询库内全部物理文件版本。
  Future<List<MediaVariant>> getAllVariants();

  /// 在单一数据库事务中原子执行一组读写操作。
  Future<T> runInTransaction<T>(Future<T> Function() action);

  /// 保存作品的 Top-5 待复核候选摘要（覆盖旧候选）。
  Future<void> saveScrapeCandidates(
    String workId,
    List<ScrapeCandidateSummary> candidates,
  );

  /// 查询指定作品的待复核候选摘要列表（按排名升序）。
  Future<List<ScrapeCandidateSummary>> getScrapeCandidates(String workId);

  /// 清空指定作品的待复核候选摘要。
  Future<void> clearScrapeCandidates(String workId);

  /// 删除指定媒体源。
  Future<void> deleteMediaSource(String sourceId);

  /// 清理媒体源重新归组扫描后遗留的失效物理版本与无归属碎裂作品记录。
  Future<void> pruneStaleSourceEntries({
    required String sourceId,
    required Set<String> activeWorkIds,
    required Set<String> activeVariantIds,
    List<String> scopedRoots = const [],
  });

  /// 写入或刷新单集播放历史与精确到秒的观看进度。
  Future<void> recordPlayback(PlaybackRecord record);

  /// 按播放时间倒序查询全局播放历史。
  Future<List<PlaybackRecord>> getPlaybackHistory({int limit = 100});

  /// 查询指定作品下全部已记录剧集的播放进度。
  Future<List<PlaybackRecord>> getPlaybacksByWork(String workId);

  /// 查询指定作品最近一次播放记录。
  Future<PlaybackRecord?> getLatestPlaybackForWork(String workId);

  /// 删除单条播放历史记录。
  Future<void> deletePlaybackRecord(String recordId);

  /// 清空全部播放历史记录。
  Future<void> clearPlaybackHistory();

  /// 仅从媒体库数据库移除指定作品及其衍生记录（不触碰任何物理源文件）。
  Future<void> deleteWork(String workId);

  /// 删除作品下已没有任何物理文件关联的空剧集条目。
  Future<void> deleteOrphanEpisodes(String workId);

  /// 将目录路径加入指定媒体源的忽略名单。
  Future<void> addIgnoredFolder(String sourceId, String relativePath);

  /// 读取指定媒体源的忽略目录相对路径列表。
  Future<List<String>> getIgnoredFolders(String sourceId);

  /// 从指定媒体源忽略名单中移除一条目录规则。
  Future<void> removeIgnoredFolder(String sourceId, String relativePath);

  /// 新增或更新系列（Series）分组实体。
  Future<void> upsertSeriesGroup(SeriesGroup group);

  /// 根据主键 ID 查询系列分组。
  Future<SeriesGroup?> findSeriesGroupById(String seriesId);

  /// 查询库内全部系列分组。
  Future<List<SeriesGroup>> getAllSeriesGroups();

  /// 删除指定系列分组并解除旗下作品绑定（不删除作品本身）。
  Future<void> deleteSeriesGroup(String seriesId);
}
