import 'dart:io';

import '../engine/konata_sqlite_engine.dart';
import 'cache_migrations.dart';
import 'dao/artwork_negative_cache_dao.dart';
import 'dao/lyric_cache_dao.dart';
import 'dao/scrape_candidate_dao.dart';

/// `cache.db` 可丢弃缓存库门面（永不进入备份与同步，支持冷启动惰性打开与一键删库重建）。
final class CacheDatabase {
  CacheDatabase._(this.engine)
    : scrapeCandidates = ScrapeCandidateDao(engine),
      lyricCache = LyricCacheDao(engine),
      artworkNegativeCache = ArtworkNegativeCacheDao(engine);

  /// 打开物理文件型 `cache.db`（默认分配紧凑 2 MiB 页缓存）。
  factory CacheDatabase.openFile(
    String filePath, {
    int cacheSizeKib = 2048,
  }) {
    final engine = KonataSqliteEngine.openFile(
      filePath: filePath,
      databaseName: 'cache',
      migrations: CacheMigrations.steps,
      postOpenStatements: CacheMigrations.indexStatements,
      cacheSizeKib: cacheSizeKib,
    );
    return CacheDatabase._(engine);
  }

  /// 打开纯内存 `cache.db`（用于 `:memory:` 单元测试）。
  factory CacheDatabase.openInMemory() {
    final engine = KonataSqliteEngine.openInMemory(
      databaseName: 'cache',
      migrations: CacheMigrations.steps,
      postOpenStatements: CacheMigrations.indexStatements,
    );
    return CacheDatabase._(engine);
  }

  /// 底层响应式 SQLite 引擎。
  final KonataSqliteEngine engine;

  /// 待复核候选摘要缓存 DAO。
  final ScrapeCandidateDao scrapeCandidates;

  /// 在线歌词检索缓存 DAO。
  final LyricCacheDao lyricCache;

  /// 艺术图无图负缓存冷却 DAO。
  final ArtworkNegativeCacheDao artworkNegativeCache;

  /// 关闭当前缓存库连接。
  Future<void> close() => engine.close();

  /// 删除指定物理 `cache.db` 主文件及其 WAL / SHM 伴生文件。
  static Future<void> deletePhysicalFiles(String filePath) async {
    for (final path in <String>[filePath, '$filePath-wal', '$filePath-shm']) {
      final file = File(path);
      if (file.existsSync()) {
        await file.delete();
      }
    }
  }
}
