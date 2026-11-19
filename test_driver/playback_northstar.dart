import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

/// 将三端真实音视频播放专项基准（预热后正反 5 轮 A/B）原始采样落盘为 JSON 实测证据。
Future<void> main() => integrationDriver(
  timeout: const Duration(minutes: 5),
  responseDataCallback: (data) async {
    if (data == null ||
        data['rounds'] is! List ||
        (data['rounds'] as List).length != 5) {
      throw StateError('设备未回传完整 5 轮音视频播放专项实测数据');
    }
    final output =
        Platform.environment['KONATA_PLAYBACK_BENCH_OUTPUT'] ??
        '.agent-work/benchmarks/playback_northstar_probe.json';
    final file = File(output);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(data),
      encoding: utf8,
    );
  },
);
