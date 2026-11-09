import 'dart:io';
import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  const output = 'release/validation/optional-features-20261108/device';
  await Directory(output).create(recursive: true);
  await integrationDriver(
    writeResponseOnFailure: true,
    responseDataCallback: (data) => writeResponseData(
      data,
      destinationDirectory: output,
      testOutputFilename:
          Platform.environment['KONATA_DEVICE_RESULT'] ?? 'integration-results',
    ),
    onScreenshot: (name, bytes, [args]) async {
      await File('$output/$name.png').writeAsBytes(bytes);
      return true;
    },
  );
}
