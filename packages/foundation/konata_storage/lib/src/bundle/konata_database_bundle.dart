import 'package:konata_contracts/konata_contracts.dart';

import '../cache/cache_database.dart';
import '../library/library_database.dart';
import '../user_state/user_state_database.dart';

/// Konata v3 三库物理分治生命周期总管（`<Root>/userdata/db/`）。
///
/// - `library.db` 与 `user_state.db` 在初始化时立即就绪；
/// - `cache.db` 严格遵守**冷启动惰性打开**原则，仅在首次访问时才创建连接，并支持一键删库重建。
final class KonataDatabaseBundle {
  KonataDatabaseBundle._({
    required this.library,
    required this.userState,
    required this._cacheFilePath,
    required this._inMemory,
  });

  /// 基于统一 [StorageRootPort] 在 `<Root>/userdata/db/` 下打开三库组合。
  ///
  /// 注意：此方法不会在冷启动阶段打开 `cache.db`。
  static Future<KonataDatabaseBundle> openFromStorageRoot(
    StorageRootPort storageRoot, {
    int libraryCacheSizeKib = 8192,
    int userStateCacheSizeKib = 4096,
  }) async {
    await storageRoot.ensureDatabaseDirPath();
    final libraryPath = await storageRoot.resolveDatabaseFilePath(
      StoragePathNames.libraryDbFile,
    );
    final userStatePath = await storageRoot.resolveDatabaseFilePath(
      StoragePathNames.userStateDbFile,
    );
    final cachePath = await storageRoot.resolveDatabaseFilePath(
      StoragePathNames.cacheDbFile,
    );

    final libraryDb = LibraryDatabase.openFile(
      libraryPath,
      cacheSizeKib: libraryCacheSizeKib,
    );
    try {
      final userStateDb = UserStateDatabase.openFile(
        userStatePath,
        cacheSizeKib: userStateCacheSizeKib,
      );
      return KonataDatabaseBundle._(
        library: libraryDb,
        userState: userStateDb,
        cacheFilePath: cachePath,
        inMemory: false,
      );
    } catch (_) {
      await libraryDb.close();
      rethrow;
    }
  }

  /// 创建纯内存三库组合（用于单元测试，`cache.db` 同样保持惰性打开）。
  factory KonataDatabaseBundle.openInMemory() {
    return KonataDatabaseBundle._(
      library: LibraryDatabase.openInMemory(),
      userState: UserStateDatabase.openInMemory(),
      cacheFilePath: null,
      inMemory: true,
    );
  }

  /// 核心媒体资产库（`library.db`）。
  final LibraryDatabase library;

  /// 用户态与同步库（`user_state.db`）。
  final UserStateDatabase userState;

  final String? _cacheFilePath;
  final bool _inMemory;
  CacheDatabase? _cache;
  bool _closed = false;

  /// `cache.db` 当前是否已被惰性打开。
  bool get isCacheOpen => _cache != null && !_cache!.engine.isClosed;

  /// 按需惰性打开并返回 `cache.db`。
  CacheDatabase get cache {
    if (_closed) {
      throw StateError('三库组合已关闭，禁止访问惰性缓存库');
    }
    final existing = _cache;
    if (existing != null && !existing.engine.isClosed) {
      return existing;
    }
    final opened = _inMemory
        ? CacheDatabase.openInMemory()
        : CacheDatabase.openFile(_cacheFilePath!);
    _cache = opened;
    return opened;
  }

  /// 一键清空并物理删库重建 `cache.db`（绝不影响 `library.db` 与 `user_state.db`）。
  ///
  /// 重建后保持惰性状态，直到下次业务实际访问 [cache] 时再按需打开；
  /// 若 [reopenImmediately] 为 `true`，则立即重建并返回全新空缓存库实例。
  Future<CacheDatabase?> resetCacheDatabase({
    bool reopenImmediately = false,
  }) async {
    final existing = _cache;
    _cache = null;
    if (existing != null && !existing.engine.isClosed) {
      await existing.close();
    }
    final path = _cacheFilePath;
    if (!_inMemory && path != null) {
      await CacheDatabase.deletePhysicalFiles(path);
    }
    if (reopenImmediately && !_closed) {
      return cache;
    }
    return null;
  }

  /// 依次安全关闭三库连接。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final openedCache = _cache;
    _cache = null;
    if (openedCache != null && !openedCache.engine.isClosed) {
      await openedCache.close();
    }
    await userState.close();
    await library.close();
  }
}
