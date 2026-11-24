import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:sqlite3/sqlite3.dart';

import 'table_change_bus.dart';

/// 单步数据库结构迁移定义（每库维护独立 `PRAGMA user_version` 序列）。
final class SqliteMigration {
  /// 创建指定目标版本号的迁移步骤。
  const SqliteMigration({required this.targetVersion, required this.migrate});

  /// 执行完成后的目标 `PRAGMA user_version`（必须严格大于 0）。
  final int targetVersion;

  /// 在迁移事务内执行的 DDL / DML 逻辑。
  final void Function(Database db) migrate;
}

/// 事务作用域内的受控写入上下文（自动收集本次事务触达的表名，仅在提交成功后广播）。
final class SqliteTransaction {
  SqliteTransaction._(this._db, this._dirtyTables);

  final Database _db;
  final Set<String> _dirtyTables;

  /// 底层只读或自定义参数化查询所需连接句柄。
  Database get rawDatabase => _db;

  /// 执行 100% 参数化只读查询。
  ResultSet select(String sql, [List<Object?> parameters = const <Object?>[]]) {
    return _db.select(sql, parameters);
  }

  /// 执行 100% 参数化写语句，并登记受影响表名供提交后广播。
  void execute(
    String sql, [
    List<Object?> parameters = const <Object?>[],
    Set<String> affectedTables = const <String>{},
  ]) {
    _db.execute(sql, parameters);
    if (affectedTables.isNotEmpty) {
      _dirtyTables.addAll(affectedTables);
    }
  }

  /// 手动登记本次事务已改动的表名（用于批量多句写入统一声明）。
  void markTablesChanged(Iterable<String> tables) {
    _dirtyTables.addAll(tables);
  }
}

/// Konata v3 自研极薄纯 `sqlite3` 响应式存储引擎（零 `build_runner`、零 Flutter 依赖）。
///
/// 统一启用 `WAL`（文件库）、`foreign_keys=ON`、`busy_timeout=5000`、紧凑 `cache_size`
/// 与 `PRAGMA user_version` 迁移机制，并通过 [TableChangeBus] 提供 `watchQuery` 响应式查询。
final class KonataSqliteEngine {
  KonataSqliteEngine._({
    required Database database,
    required this.databaseName,
    required this.filePath,
    required this.cacheSizeKib,
    required this.busyTimeoutMs,
  }) : _db = database;

  /// 打开文件型数据库并自动执行 `PRAGMA` 配置、版本迁移与索引初始化。
  factory KonataSqliteEngine.openFile({
    required String filePath,
    required String databaseName,
    required List<SqliteMigration> migrations,
    List<String> postOpenStatements = const <String>[],
    int cacheSizeKib = 4096,
    int busyTimeoutMs = 5000,
  }) {
    final parent = File(filePath).parent;
    if (!parent.existsSync()) {
      parent.createSync(recursive: true);
    }
    final db = sqlite3.open(filePath);
    try {
      _configurePragmas(
        db,
        isMemory: false,
        cacheSizeKib: cacheSizeKib,
        busyTimeoutMs: busyTimeoutMs,
      );
      _applyMigrations(db, migrations, postOpenStatements);
      return KonataSqliteEngine._(
        database: db,
        databaseName: databaseName,
        filePath: filePath,
        cacheSizeKib: cacheSizeKib,
        busyTimeoutMs: busyTimeoutMs,
      );
    } catch (_) {
      db.close();
      rethrow;
    }
  }

  /// 打开纯内存数据库（供 `:memory:` 单元测试极速秒跑）。
  factory KonataSqliteEngine.openInMemory({
    required String databaseName,
    required List<SqliteMigration> migrations,
    List<String> postOpenStatements = const <String>[],
    int cacheSizeKib = 2048,
    int busyTimeoutMs = 5000,
  }) {
    final db = sqlite3.openInMemory();
    try {
      _configurePragmas(
        db,
        isMemory: true,
        cacheSizeKib: cacheSizeKib,
        busyTimeoutMs: busyTimeoutMs,
      );
      _applyMigrations(db, migrations, postOpenStatements);
      return KonataSqliteEngine._(
        database: db,
        databaseName: databaseName,
        filePath: null,
        cacheSizeKib: cacheSizeKib,
        busyTimeoutMs: busyTimeoutMs,
      );
    } catch (_) {
      db.close();
      rethrow;
    }
  }

  /// 数据库逻辑标识（如 `library`、`user_state`、`cache`）。
  final String databaseName;

  /// 物理落盘路径；内存库时为 `null`。
  final String? filePath;

  /// 页缓存预算（KiB）。
  final int cacheSizeKib;

  /// 锁冲突等待超时（毫秒）。
  final int busyTimeoutMs;

  final Database _db;
  final TableChangeBus _changeBus = TableChangeBus();

  bool _closed = false;
  int _txDepth = 0;
  int _savepointSeq = 0;
  Set<String>? _activeTxDirtyTables;

  /// 当前数据库是否已关闭。
  bool get isClosed => _closed;

  /// 底层 `TableChangeBus` 实例（仅承载低频表级提交通知）。
  TableChangeBus get changeBus => _changeBus;

  /// 当前数据库 `PRAGMA user_version` 版本号。
  int get userVersion {
    _ensureOpen();
    final rs = _db.select('PRAGMA user_version;');
    return rs.first.columnAt(0) as int;
  }

  /// 执行参数化只读查询。
  ResultSet select(String sql, [List<Object?> parameters = const <Object?>[]]) {
    _ensureOpen();
    return _db.select(sql, parameters);
  }

  /// 执行单条参数化写操作；若处于事务外部则立即通知受影响表。
  void execute(
    String sql, [
    List<Object?> parameters = const <Object?>[],
    Set<String> affectedTables = const <String>{},
  ]) {
    _ensureOpen();
    _db.execute(sql, parameters);
    if (affectedTables.isNotEmpty) {
      if (_txDepth > 0 && _activeTxDirtyTables != null) {
        _activeTxDirtyTables!.addAll(affectedTables);
      } else {
        _changeBus.notifyTables(affectedTables);
      }
    }
  }

  /// 在原子事务内执行一组读写操作（支持嵌套保存点）。
  ///
  /// 仅当最外层事务成功 `COMMIT` 后统一广播变动表名；任一异常触发 `ROLLBACK` 时绝不广播。
  T runTransaction<T>(T Function(SqliteTransaction tx) action) {
    _ensureOpen();
    final isOuter = _txDepth == 0;
    final savepointName = isOuter ? null : 'konata_sp_${++_savepointSeq}';
    final localDirty = <String>{};

    if (isOuter) {
      _db.execute('BEGIN IMMEDIATE;');
      _activeTxDirtyTables = localDirty;
    } else {
      _db.execute('SAVEPOINT $savepointName;');
    }
    _txDepth++;

    final tx = SqliteTransaction._(_db, localDirty);
    try {
      final result = action(tx);
      _txDepth--;
      if (isOuter) {
        _db.execute('COMMIT;');
        final toBroadcast = Set<String>.of(localDirty);
        _activeTxDirtyTables = null;
        if (toBroadcast.isNotEmpty) {
          _changeBus.notifyTables(toBroadcast);
        }
      } else {
        _db.execute('RELEASE SAVEPOINT $savepointName;');
        _activeTxDirtyTables?.addAll(localDirty);
      }
      return result;
    } catch (_) {
      _txDepth--;
      if (isOuter) {
        try {
          _db.execute('ROLLBACK;');
        } finally {
          _activeTxDirtyTables = null;
        }
      } else {
        _db.execute('ROLLBACK TO SAVEPOINT $savepointName;');
        _db.execute('RELEASE SAVEPOINT $savepointName;');
      }
      rethrow;
    }
  }

  /// 在后台 `Isolate` 中针对文件型数据库执行批量重写入事务，提交完成后自动向主线程总线广播。
  ///
  /// 若当前为 `:memory:` 数据库（无法跨 Isolate 共享内存库指针），则安全回退至当前线程事务执行。
  Future<T> runWriteBatchInIsolate<T>({
    required Set<String> affectedTables,
    required T Function(Database db) action,
  }) async {
    _ensureOpen();
    final path = filePath;
    if (path == null) {
      return runTransaction((tx) {
        final result = action(tx.rawDatabase);
        tx.markTablesChanged(affectedTables);
        return result;
      });
    }

    final cacheKib = cacheSizeKib;
    final timeoutMs = busyTimeoutMs;
    final result = await Isolate.run<T>(() {
      final bgDb = sqlite3.open(path);
      try {
        _configurePragmas(
          bgDb,
          isMemory: false,
          cacheSizeKib: cacheKib,
          busyTimeoutMs: timeoutMs,
        );
        bgDb.execute('BEGIN IMMEDIATE;');
        try {
          final value = action(bgDb);
          bgDb.execute('COMMIT;');
          return value;
        } catch (_) {
          bgDb.execute('ROLLBACK;');
          rethrow;
        }
      } finally {
        bgDb.close();
      }
    });

    if (!_closed && affectedTables.isNotEmpty) {
      _changeBus.notifyTables(affectedTables);
    }
    return result;
  }

  /// 响应式查询订阅：订阅即刻发射当前快照，后续在 [tables] 任一表提交变更时自动重新查询发射。
  Stream<T> watchQuery<T>({
    required Set<String> tables,
    required T Function(Database db) query,
  }) {
    _ensureOpen();
    final watchedTables = Set<String>.unmodifiable(tables);
    late final StreamController<T> controller;
    StreamSubscription<Set<String>>? subscription;

    void emitSnapshot() {
      if (_closed || controller.isClosed) return;
      try {
        controller.add(query(_db));
      } catch (error, stackTrace) {
        controller.addError(error, stackTrace);
      }
    }

    controller = StreamController<T>(
      onListen: () {
        emitSnapshot();
        subscription = _changeBus.stream.listen(
          (changedTables) {
            if (changedTables.any(watchedTables.contains)) {
              emitSnapshot();
            }
          },
          onDone: () {
            if (!controller.isClosed) {
              unawaited(controller.close());
            }
          },
        );
      },
      onCancel: () async {
        await subscription?.cancel();
        subscription = null;
      },
    );

    return controller.stream;
  }

  /// 关闭数据库连接与表变更总线。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _changeBus.dispose();
    _db.close();
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('数据库引擎 `$databaseName` 已关闭，无法继续执行操作');
    }
  }

  static void _configurePragmas(
    Database db, {
    required bool isMemory,
    required int cacheSizeKib,
    required int busyTimeoutMs,
  }) {
    if (!isMemory) {
      db.execute('PRAGMA journal_mode = WAL;');
    }
    db.execute('PRAGMA foreign_keys = ON;');
    db.execute('PRAGMA busy_timeout = $busyTimeoutMs;');
    db.execute('PRAGMA synchronous = NORMAL;');
    db.execute('PRAGMA temp_store = MEMORY;');
    db.execute('PRAGMA cache_size = -$cacheSizeKib;');
  }

  static void _applyMigrations(
    Database db,
    List<SqliteMigration> migrations,
    List<String> postOpenStatements,
  ) {
    final sorted = List<SqliteMigration>.of(migrations)
      ..sort((a, b) => a.targetVersion.compareTo(b.targetVersion));
    var currentVersion = db.select('PRAGMA user_version;').first.columnAt(0) as int;

    for (final step in sorted) {
      if (step.targetVersion <= 0) {
        throw ArgumentError.value(
          step.targetVersion,
          'targetVersion',
          '迁移版本号必须大于 0',
        );
      }
      if (step.targetVersion <= currentVersion) {
        continue;
      }
      db.execute('BEGIN IMMEDIATE;');
      try {
        step.migrate(db);
        db.execute('PRAGMA user_version = ${step.targetVersion};');
        db.execute('COMMIT;');
        currentVersion = step.targetVersion;
      } catch (_) {
        db.execute('ROLLBACK;');
        rethrow;
      }
    }

    for (final stmt in postOpenStatements) {
      db.execute(stmt);
    }
  }
}
