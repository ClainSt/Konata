import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

/// 将 G01~G12 真实压缩编码微样本矩阵的实机探测结果落盘为 JSON 报告。
Future<void> main() => integrationDriver(
  timeout: const Duration(minutes: 6),
  responseDataCallback: (data) async {
    if (data == null || data['groups'] is! List || (data['groups'] as List).isEmpty) {
      throw StateError('设备未回传有效的 G01~G12 真实编码矩阵实测数据');
    }
    final output =
        Platform.environment['KONATA_CODEC_MATRIX_OUTPUT'] ??
        '.agent-work/benchmarks/codec_matrix_probe.json';
    final file = File(output);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(data),
      encoding: utf8,
    );
  },
);
