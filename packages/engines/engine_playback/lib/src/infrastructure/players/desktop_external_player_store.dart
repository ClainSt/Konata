import 'package:konata_storage/konata_storage.dart';

import '../../domain/models/external_player_config.dart';

/// 桌面独占外部播放器配置存取端口（支持 SQLite 与内存测试替身注入）。
abstract interface class DesktopExternalPlayerStore {
  /// 读取全部已配置的外部播放器（自动忽略历史外部图片查看器残留记录）。
  Future<List<ExternalPlayerConfig>> getExternalPlayers();

  /// 新增或覆盖保存单条外部程序配置。
  Future<void> upsertExternalPlayer(ExternalPlayerConfig config);

  /// 按主键删除外部程序配置。
  Future<void> deleteExternalPlayer(String id);
}

/// 基于 `KonataSqliteEngine` 的桌面外部程序配置 SQLite 持久化存取器。
class SqliteDesktopExternalPlayerStore implements DesktopExternalPlayerStore {
  /// 基于共享 SQLite 引擎创建外部程序存取器。
  SqliteDesktopExternalPlayerStore(this._engine);

  final KonataSqliteEngine _engine;
  bool _tableEnsured = false;

  /// 历史版本遗留的外部看图器记录主键，读取时须显式过滤以防降级为视频播放器候选。
  static const String _legacyImageViewerId = 'player_image_viewer';
  static const String _legacyImageViewerKind = 'imageViewer';

  void _ensureTable() {
    if (_tableEnsured) {
      return;
    }
    _engine.execute(
      'CREATE TABLE IF NOT EXISTS external_players ('
      'id TEXT NOT NULL PRIMARY KEY, '
      'name TEXT NOT NULL, '
      'kind TEXT NOT NULL, '
      'executable_path TEXT NOT NULL, '
      "arguments_template TEXT NOT NULL DEFAULT '{url}', "
      'is_default INTEGER NOT NULL DEFAULT 0'
      ')',
    );
    _tableEnsured = true;
  }

  @override
  Future<List<ExternalPlayerConfig>> getExternalPlayers() async {
    _ensureTable();
    final rows = _engine.select(
      'SELECT id, name, kind, executable_path, arguments_template, is_default '
      'FROM external_players',
    );
    final results = <ExternalPlayerConfig>[];
    for (final row in rows) {
      final id = (row['id'] as String?) ?? '';
      final rawKind = (row['kind'] as String?) ?? '';
      if (id == _legacyImageViewerId || rawKind == _legacyImageViewerKind) {
        continue;
      }
      results.add(
        ExternalPlayerConfig(
          id: id,
          name: (row['name'] as String?) ?? '',
          kind: _parseKind(rawKind),
          executablePath: (row['executable_path'] as String?) ?? '',
          argumentsTemplate:
              (row['arguments_template'] as String?) ?? '{url}',
          isDefault: ((row['is_default'] as int?) ?? 0) != 0,
        ),
      );
    }
    return results;
  }

  @override
  Future<void> upsertExternalPlayer(ExternalPlayerConfig config) async {
    _ensureTable();
    _engine.execute(
      'INSERT INTO external_players '
      '(id, name, kind, executable_path, arguments_template, is_default) '
      'VALUES (?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET '
      'name = excluded.name, '
      'kind = excluded.kind, '
      'executable_path = excluded.executable_path, '
      'arguments_template = excluded.arguments_template, '
      'is_default = excluded.is_default',
      <Object?>[
        config.id,
        config.name,
        config.kind.name,
        config.executablePath,
        config.argumentsTemplate,
        config.isDefault ? 1 : 0,
      ],
    );
  }

  @override
  Future<void> deleteExternalPlayer(String id) async {
    _ensureTable();
    _engine.execute('DELETE FROM external_players WHERE id = ?', <Object?>[id]);
  }

  static ExternalPlayerKind _parseKind(String raw) {
    for (final item in ExternalPlayerKind.values) {
      if (item.name == raw) {
        return item;
      }
    }
    return ExternalPlayerKind.custom;
  }
}

/// 纯内存桌面外部播放器配置存储实现（供单元测试与无数据库隔离验证使用）。
class InMemoryDesktopExternalPlayerStore implements DesktopExternalPlayerStore {
  /// 创建纯内存外部播放器存储实例，可预填初始列表。
  InMemoryDesktopExternalPlayerStore([
    Iterable<ExternalPlayerConfig> initialPlayers = const [],
  ]) {
    for (final p in initialPlayers) {
      _items[p.id] = p;
    }
  }

  final Map<String, ExternalPlayerConfig> _items =
      <String, ExternalPlayerConfig>{};

  @override
  Future<List<ExternalPlayerConfig>> getExternalPlayers() async {
    return List<ExternalPlayerConfig>.unmodifiable(_items.values);
  }

  @override
  Future<void> upsertExternalPlayer(ExternalPlayerConfig config) async {
    _items[config.id] = config;
  }

  @override
  Future<void> deleteExternalPlayer(String id) async {
    _items.remove(id);
  }
}
