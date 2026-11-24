import 'dart:async';

/// SQLite 表级低频变更广播总线。
///
/// 仅在数据库事务真正 `COMMIT` 成功后按变动表名集合广播；
/// 性能红线：严禁承载超过 5Hz 的高频信号（如播放进度轮询、字幕逐帧时钟）。
final class TableChangeBus {
  /// 创建表级低频变更总线。
  TableChangeBus();

  final StreamController<Set<String>> _controller =
      StreamController<Set<String>>.broadcast();

  bool _disposed = false;

  /// 表变更事件广播流，每次事件为该次提交触达的不可变表名集合。
  Stream<Set<String>> get stream => _controller.stream;

  /// 在事务提交完成后广播受影响的表名集合。
  void notifyTables(Set<String> tables) {
    if (_disposed || _controller.isClosed || tables.isEmpty) {
      return;
    }
    _controller.add(Set<String>.unmodifiable(tables));
  }

  /// 关闭变更总线。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _controller.close();
  }
}
