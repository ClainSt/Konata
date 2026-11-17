import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

/// 将设备回传的原始采样保存为独立证据，缺失数据直接阻断。
Future<void> main() => integrationDriver(
  timeout: const Duration(minutes: 3),
  responseDataCallback: (data) async {
    if (data == null || data['samples'] is! List ||
        (data['samples'] as List).length != 5) {
      throw StateError('设备未回传完整五轮实测数据');
    }
    final output = Platform.environment['KONATA_BENCHMARK_OUTPUT'] ??
        '.agent-work/benchmarks/probe.json';
    await File(output).writeAsString(jsonEncode(data), encoding: utf8);
  },
);
