import '../../domain/models/external_player_config.dart';
import '../database/konata_database.dart';

/// 桌面独占外部程序配置 SQLite 持久化存取器（复用同一 `konata_v2.sqlite` 的 `external_players` 表，零破坏老库兼容）。
class DesktopExternalPlayerStore {
  /// 基于共享数据库连接创建外部程序存取器。
  DesktopExternalPlayerStore(this._db);

  final KonataDatabase _db;
  bool _tableEnsured = false;

  Future<void> _ensureTable() async {
    if (_tableEnsured) return;
    await _db.customStatement(
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

  /// 读取全部已配置的外部播放器/查看器。
  Future<List<ExternalPlayerConfig>> getExternalPlayers() async {
    await _ensureTable();
    final rows = await _db
        .customSelect(
          'SELECT id, name, kind, executable_path, arguments_template, is_default '
          'FROM external_players',
        )
        .get();
    return [
      for (final row in rows)
        ExternalPlayerConfig(
          id: row.read<String>('id'),
          name: row.read<String>('name'),
          kind: _parseKind(row.read<String>('kind')),
          executablePath: row.read<String>('executable_path'),
          argumentsTemplate: row.read<String>('arguments_template'),
          isDefault: row.read<int>('is_default') != 0,
        ),
    ];
  }

  /// 新增或覆盖保存单条外部程序配置。
  Future<void> upsertExternalPlayer(ExternalPlayerConfig config) async {
    await _ensureTable();
    await _db.customStatement(
      'INSERT INTO external_players '
      '(id, name, kind, executable_path, arguments_template, is_default) '
      'VALUES (?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET '
      'name = excluded.name, '
      'kind = excluded.kind, '
      'executable_path = excluded.executable_path, '
      'arguments_template = excluded.arguments_template, '
      'is_default = excluded.is_default',
      [
        config.id,
        config.name,
        config.kind.name,
        config.executablePath,
        config.argumentsTemplate,
        config.isDefault ? 1 : 0,
      ],
    );
  }

  /// 按主键删除外部程序配置。
  Future<void> deleteExternalPlayer(String id) async {
    await _ensureTable();
    await _db.customStatement(
      'DELETE FROM external_players WHERE id = ?',
      [id],
    );
  }

  static ExternalPlayerKind _parseKind(String raw) {
    for (final item in ExternalPlayerKind.values) {
      if (item.name == raw) return item;
    }
    return ExternalPlayerKind.custom;
  }
}
