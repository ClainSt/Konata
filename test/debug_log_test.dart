import 'dart:convert';
import 'dart:io';
import 'package:ccplayer/core/debug_log.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('konata-logs-');
    await DebugLog.initialize(root: root);
    await DebugLog.flush();
  });
  tearDown(() async {
    await DebugLog.flush();
    DebugLog.directory = null;
    await root.delete(recursive: true);
  });
  File getCurrent() => File('${DebugLog.directory!.path}/current.log');
  String row(DateTime time, String level, String event, String session) =>
      '${time.toUtc().toIso8601String()} [$level] [Playback] ${jsonEncode({'event': event, 'session': session})}\n';

  test('large legacy errors remain bounded and retain their anchor', () async {
    await getCurrent().writeAsString(
      '${DateTime.now().toUtc().toIso8601String()} [ERROR] [Legacy] huge_failure ${'字' * 200000}\n',
    );
    final text = (await DebugLog.latestIncidentText())!;
    expect(
      utf8.encode(text).length,
      lessThanOrEqualTo(DebugLog.maxExportBytes),
    );
    expect(text, contains('huge_failure'));
    expect(text, contains('[legacy truncated]'));
  });

  test('later warnings do not replace the latest recorded failure', () async {
    DebugLog.event('Test', 'primary_failure', {}, level: 'ERROR');
    DebugLog.event('Test', 'later_warning', {}, level: 'WARN');
    final text = (await DebugLog.latestIncidentText())!;
    final incident = text.split('--- incident ---')[1].split('--- context')[0];
    expect(incident, contains('primary_failure'));
    expect(incident, isNot(contains('later_warning')));
  });

  test(
    'partial UTF8 and malformed tail do not prevent incident export',
    () async {
      DebugLog.event('Test', 'recorded_failure', {}, level: 'ERROR');
      await DebugLog.flush();
      await getCurrent().writeAsBytes([
        0xff,
        0xe5,
        0xad,
      ], mode: FileMode.append);
      final text = (await DebugLog.latestIncidentText())!;
      expect(text, contains('recorded_failure'));
      expect(text, contains('"unparsedLinesInRetainedFiles": 1'));
    },
  );

  test(
    'uncaught error contains package locations and sanitized message',
    () async {
      DebugLog.exception(
        'App',
        'uncaught',
        StateError('token=secret'),
        StackTrace.fromString(
          '#0 read (package:ccplayer/core/sources.dart:10:2)\n#1 main (file:///private/work/main.dart:3:4)',
        ),
      );
      final text = (await DebugLog.latestIncidentText())!;
      expect(text, contains('sources.dart:10:2'));
      expect(text, isNot(contains('/private/work')));
      expect(text, isNot(contains('secret')));
    },
  );

  test(
    'no incident exports nothing; detailed off still retains failures',
    () async {
      expect(await DebugLog.latestIncidentText(), isNull);
      DebugLog.event('Playback', 'hidden', {}, level: 'DEBUG');
      DebugLog.event('Playback', 'failed', {'session': 'a'}, level: 'ERROR');
      final text = (await DebugLog.latestIncidentText())!;
      expect(text, contains('failed'));
      expect(text, isNot(contains('hidden')));
      expect(text, contains('"incidentSeverity": "ERROR"'));
    },
  );

  test(
    'latest incident selects one session and time window across rotation',
    () async {
      final now = DateTime.now().toUtc();
      await File('${DebugLog.directory!.path}/100.log').writeAsString(
        row(
              now.subtract(const Duration(days: 8)),
              'ERROR',
              'old_failure',
              'old',
            ) +
            row(
              now.subtract(const Duration(minutes: 2)),
              'INFO',
              'session_start',
              'new',
            ) +
            row(
              now.subtract(const Duration(seconds: 5)),
              'INFO',
              'request_start',
              'new',
            ),
      );
      await getCurrent().writeAsString(
        row(
              now.subtract(const Duration(seconds: 1)),
              'INFO',
              'other_playback',
              'other',
            ) +
            row(now, 'WARN', 'timeout_warning', 'new') +
            row(
              now.add(const Duration(seconds: 2)),
              'INFO',
              'recovered',
              'new',
            ) +
            row(
              now.add(const Duration(seconds: 20)),
              'INFO',
              'unrelated_later',
              'new',
            ),
      );
      await File(
        '${DebugLog.directory!.path}/personal.log',
      ).writeAsString('private user file');
      final text = (await DebugLog.latestIncidentText())!;
      for (final event in [
        'session_start',
        'request_start',
        'timeout_warning',
        'recovered',
        'WARNING ONLY',
      ]) {
        expect(text, contains(event));
      }
      for (final event in [
        'old_failure',
        'other_playback',
        'unrelated_later',
        'private user file',
      ]) {
        expect(text, isNot(contains(event)));
      }
      expect(
        await File('${DebugLog.directory!.path}/personal.log').readAsString(),
        'private user file',
      );
    },
  );

  test('event redaction stays valid JSON in the exported TXT', () async {
    DebugLog.event('Playback', 'failure', {
      'session': 'test',
      'password': 'secret value',
      'authorization': 'Basic abc',
      'message': 'Bearer xyz https://user:pass@private/path?token=oops',
      'quoted': '"authorization": "Basic invisible"',
      'metric': double.nan,
    }, level: 'ERROR');
    final text = (await DebugLog.latestIncidentText())!;
    for (final secret in [
      'secret value',
      'abc',
      'xyz',
      'private/path',
      'oops',
      'invisible',
    ]) {
      expect(text, isNot(contains(secret)));
    }
    final line = text.split('\n').lastWhere((l) => l.contains('[ERROR]'));
    final data = jsonDecode(line.substring(line.indexOf('{'))) as Map;
    expect(data['event'], 'failure');
    expect(data['authorization'], '[REDACTED]');
  });

  test(
    'flood bounds pending writes; export keeps anchor and reports loss',
    () async {
      await DebugLog.setEnabled(true);
      final before = DebugLog.droppedEntries;
      for (var i = 0; i < 1000; i++) {
        DebugLog.event('Test', 'detail', {'text': '字' * 10000, 'index': i});
      }
      DebugLog.event('Test', 'important_failure', {
        'session': 'bounded',
      }, level: 'ERROR');
      final text = (await DebugLog.latestIncidentText())!;
      expect(DebugLog.droppedEntries, greaterThan(before));
      expect(
        utf8.encode(text).length,
        lessThanOrEqualTo(DebugLog.maxExportBytes),
      );
      expect(text, contains('important_failure'));
      expect(text, contains('contextLinesOmitted'));
      for (final line in await getCurrent().readAsLines()) {
        expect(
          utf8.encode('$line\n').length,
          lessThanOrEqualTo(DebugLog.maxEntryBytes),
        );
        jsonDecode(line.substring(line.indexOf('{')));
      }
    },
  );

  test('retention removes only owned logs and expires old incidents', () async {
    final dir = DebugLog.directory!;
    for (var i = 1; i <= 6; i++) {
      await File('${dir.path}/$i.log').writeAsString(' ' * DebugLog.maxBytes);
    }
    final old = File('${dir.path}/7.log');
    await old.writeAsString(
      row(
        DateTime.now().subtract(const Duration(days: 8)),
        'ERROR',
        'expired',
        'old',
      ),
    );
    await old.setLastModified(DateTime.now().subtract(const Duration(days: 8)));
    final personal = File('${dir.path}/notes.txt');
    await personal.writeAsString('preserve');
    expect(await DebugLog.latestIncidentText(), isNull);
    final owned = await dir
        .list()
        .where((f) => f.path.endsWith('.log'))
        .cast<File>()
        .toList();
    expect(owned.length, lessThanOrEqualTo(DebugLog.maxFiles));
    var bytes = 0;
    for (final file in owned) {
      bytes += await file.length();
    }
    expect(bytes, lessThanOrEqualTo(DebugLog.maxFiles * DebugLog.maxBytes));
    expect(await old.exists(), false);
    expect(await personal.readAsString(), 'preserve');
  });

  test(
    'rotation concurrent with export keeps the incident and queue alive',
    () async {
      await getCurrent().writeAsString(' ' * (DebugLog.maxBytes - 1));
      DebugLog.event('Test', 'rotation_failure', {}, level: 'ERROR');
      final exporting = DebugLog.latestIncidentText();
      DebugLog.event('Test', 'after_export', {}, level: 'INFO');
      expect(await exporting, contains('rotation_failure'));
      await DebugLog.flush();
      expect(await getCurrent().readAsString(), contains('after_export'));
    },
  );

  test('disk failure is counted without poisoning later writes', () async {
    final original = DebugLog.directory;
    final blocker = File('${root.path}/blocker');
    await blocker.writeAsString('file');
    DebugLog.directory = Directory(blocker.path);
    final before = DebugLog.writeFailures;
    DebugLog.event('Test', 'lost', {}, level: 'ERROR');
    await DebugLog.flush();
    expect(DebugLog.writeFailures, before + 1);
    DebugLog.directory = original;
    DebugLog.event('Test', 'recovered_failure', {}, level: 'ERROR');
    expect(await DebugLog.latestIncidentText(), contains('recovered_failure'));
  });
}
