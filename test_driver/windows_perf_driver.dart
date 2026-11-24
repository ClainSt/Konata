import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

/// 将 Windows 窗口拉伸、大片库静息与视频 OSD 播放实机基准采样落盘为 JSON 报告。
Future<void> main() => integrationDriver(
  timeout: const Duration(minutes: 5),
  responseDataCallback: (data) async {
    if (data == null || data['detail_resize'] == null) {
      throw StateError('设备未回传完整的 Windows 性能基准实测数据');
    }
    final tag = (data['tag'] ?? 'probe').toString();
    final output =
        Platform.environment['KONATA_WIN_PERF_OUTPUT'] ??
        '.agent-work/benchmarks/win_perf_$tag.json';
    final file = File(output);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(data),
      encoding: utf8,
    );
  },
);
