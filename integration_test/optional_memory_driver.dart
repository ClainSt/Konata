import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_driver/flutter_driver.dart';
import 'package:integration_test/common.dart';

Future<void> main() async {
  final output = Directory(Platform.environment['KONATA_MEMORY_OUTPUT']!);
  await output.create(recursive: true);
  final driver = await FlutterDriver.connect();
  final vm = driver.serviceClient;
  final isolate = driver.appIsolate.id!;
  var done = false;
  final result = driver
      .requestData(null, timeout: const Duration(minutes: 12))
      .whenComplete(() => done = true);
  final seen = <String>{};
  final records = <Object?>[];
  final profilePhases = Platform.environment['KONATA_MEMORY_PROFILE_PHASES']
      ?.split(',')
      .toSet();
  try {
    while (!done) {
      final state = (await vm.callServiceExtension(
        'ext.konata.memoryProbe',
        isolateId: isolate,
      )).json!;
      final phase = state['phase'] as String;
      if (state['waiting'] == true && seen.add(phase)) {
        final before = await vm.getMemoryUsage(isolate);
        final allocations =
            profilePhases == null || profilePhases.contains(phase)
            ? await vm.getAllocationProfile(isolate, gc: true)
            : null;
        final after = await vm.getMemoryUsage(isolate);
        final afterState = (await vm.callServiceExtension(
          'ext.konata.memoryProbe',
          isolateId: isolate,
        )).json;
        if (allocations != null) {
          await File(
            '${output.path}/$phase-allocations.json',
          ).writeAsString(jsonEncode(allocations.toJson()));
        }
        final retained = (allocations?.members ?? []).where(
          (entry) =>
              {
                'OptionalPeopleSession',
                'OptionalFeatureScope',
                '_PeopleSectionState',
                '_PeopleImageState',
                '_MemoryFixtureClient',
              }.contains(entry.classRef!.name) &&
              entry.instancesCurrent! > 0,
        );
        if (retained.isNotEmpty) {
          throw StateError(
            'Optional objects remain after GC at $phase: '
            '${retained.map((entry) => '${entry.classRef!.name}: ${entry.instancesCurrent}').join(', ')}',
          );
        }
        final adb = await Process.run(Platform.environment['KONATA_ADB']!, [
          '-s',
          'b6b91961',
          'shell',
          'dumpsys',
          'meminfo',
          'com.anime.konata.profile',
        ]);
        await File(
          '${output.path}/$phase-meminfo.txt',
        ).writeAsString('${adb.stdout}');
        final record = {
          'phase': phase,
          'diagnosticGc': allocations != null,
          'before': state,
          'heapBefore': before.toJson(),
          'after': afterState,
          'heapAfter': after.toJson(),
        };
        records.add(record);
        await File(
          '${output.path}/checkpoints.json',
        ).writeAsString(const JsonEncoder.withIndent('  ').convert(records));
        // ignore: avoid_print
        print('MEMORY_PROBE ${jsonEncode(record)}');
        await vm.callServiceExtension(
          'ext.konata.memoryProbe',
          isolateId: isolate,
          args: {'action': 'continue'},
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    final response = Response.fromJson(await result);
    await File('${output.path}/result.json').writeAsString(
      jsonEncode({
        'passed': response.allTestsPassed,
        'data': response.data,
        'failures': response.formattedFailureDetails,
      }),
    );
    if (!response.allTestsPassed) {
      throw StateError(response.formattedFailureDetails);
    }
  } finally {
    await driver.close();
  }
}
