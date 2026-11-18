import 'dart:collection';
import 'dart:io';

import '../../domain/config/konata_lane_config.dart';

/// Konata 轻量诊断与异常日志环形缓冲存储器（纯 Infrastructure 层 IO 封装）。
class DiagnosticsLogStore {
  /// 创建诊断日志存储器。
  DiagnosticsLogStore({this.maxEntries = 300});

  /// 内存环形缓冲区最大保留条数。
  final int maxEntries;
  final ListQueue<String> _buffer = ListQueue<String>();
  bool _verbose = false;

  /// 是否开启详细调试日志。
  bool get verboseEnabled => _verbose;

  /// 更新详细调试日志开关状态。
  void setVerbose(bool enabled) {
    _verbose = enabled;
    record('DIAG', '详细调试日志已${enabled ? '开启' : '关闭'}');
  }

  /// 写入一条运行或异常日志。
  void record(String tag, String message, {bool isError = false}) {
    if (!isError && !_verbose && _buffer.length >= 40) {
      return;
    }
    final now = DateTime.now().toIso8601String();
    final line = '[$now][$tag]${isError ? '[ERR]' : ''} $message';
    if (_buffer.length >= maxEntries) {
      _buffer.removeFirst();
    }
    _buffer.addLast(line);
  }

  /// 生成最近一次异常前后的 TXT 诊断文本内容。
  String buildRecentIncidentReport() {
    final header = StringBuffer()
      ..writeln('Konata 2.0 诊断日志报告')
      ..writeln('导出时间: ${DateTime.now().toIso8601String()}')
      ..writeln('详细调试日志: ${_verbose ? '已开启' : '未开启'}')
      ..writeln('系统平台: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
    if (KonataLaneConfig.isIsolatedLane()) {
      header.writeln('隔离车道: ${KonataLaneConfig.resolveLane()}');
    }
    header.writeln('----------------------------------------');

    if (_buffer.isEmpty) {
      header.writeln('暂无异常或运行记录。');
    } else {
      for (final line in _buffer) {
        header.writeln(line);
      }
    }
    return header.toString();
  }

  /// 将诊断日志导出写入到指定路径 [filePath]。
  Future<void> exportToFile(String filePath) async {
    final file = File(filePath);
    await file.writeAsString(buildRecentIncidentReport());
  }
}
