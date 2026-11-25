import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() async {
  final output = Platform.environment['KONATA_BENCHMARK_OUTPUT'];
  if (output == null || output.isEmpty) {
    throw StateError('缺少负载实测输出路径');
  }
  await integrationDriver(
    responseDataCallback: (data) async {
      if (data == null || data['samples'] is! List) {
        throw StateError('真机未回传负载采样');
      }
      final file = File(output);
      if (file.existsSync()) {
        throw StateError('禁止覆盖已有实测证据');
      }
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(data),
      );
    },
  );
}
