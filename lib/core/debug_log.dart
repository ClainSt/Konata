import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Bounded local diagnostics. No network upload or player-thread file I/O.
class DebugLog {
  static bool enabled = false;
  static Directory? directory;
  static Future<void> _queue = Future.value();
  static const maxBytes = 1024 * 1024;
  static const maxFiles = 4, maxEntryBytes = 4096, maxPending = 256;
  static int _pending = 0, _serial = 0;
  static int droppedEntries = 0, writeFailures = 0, truncatedEntries = 0;
  static String? _maintainedPath;
  static DateTime? _maintenanceAt;
  static final runId =
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-$pid';
  static const buildRevision = String.fromEnvironment(
    'KONATA_BUILD_REVISION',
    defaultValue: 'unknown',
  );
  static const buildVersion = String.fromEnvironment(
    'KONATA_BUILD_VERSION',
    defaultValue: 'unknown',
  );

  static String newId(String kind) =>
      '${kind.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '')}-$runId-${++_serial}';

  static Future<void> initialize({Directory? root}) async {
    await flush();
    directory = Directory(
      p.join((root ?? await getApplicationSupportDirectory()).path, 'logs'),
    );
    enabled =
        (await SharedPreferences.getInstance()).getBool('debug_logs') ?? false;
    event('App', 'startup', {
      'run': runId,
      'platform': Platform.operatingSystem,
      'version': buildVersion,
      'revision': buildRevision,
    }, level: 'INFO');
  }

  static Future<void> setEnabled(bool value) async {
    await (await SharedPreferences.getInstance()).setBool('debug_logs', value);
    enabled = value;
    event('App', 'detail_logging', {'enabled': value}, level: 'INFO');
    await flush();
  }

  static String redact(String value) => value
      .replaceAll(
        RegExp(r'''(?:https?|smb|webdav)://[^\s"'<>]+''', caseSensitive: false),
        '[URL]',
      )
      .replaceAll(
        RegExp(
          r'''\b(?:proxy-authorization|authorization|cookie|set-cookie)["']?\s*[:=][^\r\n]*''',
          caseSensitive: false,
        ),
        '[REDACTED HEADER]',
      )
      .replaceAll(
        RegExp(r'''Bearer\s+[^\s,;"']+''', caseSensitive: false),
        'Bearer [REDACTED]',
      )
      .replaceAll(
        RegExp(
          r'''\b(?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|password|passwd|secret|username)["']?\s*[:=]\s*(?:"[^"\r\n]*(?:"|$)|'[^'\r\n]*(?:'|$)|[^\s,;}]+)''',
          caseSensitive: false,
        ),
        '[REDACTED]',
      );

  /// Flat scalar fields preserve a small, machine-readable record.
  static void event(
    String module,
    String name,
    Map<String, Object?> fields, {
    String level = 'DEBUG',
  }) {
    if (!enabled && level == 'DEBUG') return;
    final safeName = name.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
    final data = <String, Object?>{
      'event': safeName.substring(0, safeName.length.clamp(0, 64)),
    };
    for (final entry in fields.entries.take(24)) {
      final key = entry.key;
      if (key == 'event' ||
          !RegExp(r'^[a-zA-Z][a-zA-Z0-9_]{0,40}$').hasMatch(key)) {
        continue;
      }
      if (RegExp(
        r'password|secret|token|cookie|authorization|username|api.?key',
        caseSensitive: false,
      ).hasMatch(key)) {
        data[key] = '[REDACTED]';
      } else {
        final value = entry.value;
        if (value is String) {
          final safe = redact(
            value.length > 16384 ? value.substring(0, 16384) : value,
          );
          data[key] = safe.length > 512 ? '${safe.substring(0, 512)}…' : safe;
          if (safe.length > 512 || value.length > 16384) truncatedEntries++;
        } else {
          data[key] =
              value == null || (value is num && value.isFinite) || value is bool
              ? value
              : '[unsupported]';
        }
      }
    }
    var omitted = fields.length - (data.length - 1);
    while (utf8.encode(jsonEncode(data)).length > maxEntryBytes - 256 &&
        data.length > 1) {
      data.remove(data.keys.last);
      omitted++;
    }
    if (omitted > 0) {
      data['fieldsOmitted'] = omitted;
      truncatedEntries++;
    }
    _write(module, jsonEncode(data), level);
  }

  static void write(String module, String message, {String level = 'DEBUG'}) {
    if (!enabled && level == 'DEBUG') return;
    _write(
      module,
      redact(message.length > 16384 ? message.substring(0, 16384) : message),
      level,
    );
  }

  /// Keep actionable package locations without absolute workstation paths.
  static void exception(
    String module,
    String name,
    Object error,
    StackTrace? stack,
  ) {
    event(module, name, {
      'type': error.runtimeType.toString(),
      'message': error.toString(),
      'frames': RegExp(r'(?:package:|dart:)[^\s)]+')
          .allMatches(stack?.toString() ?? '')
          .take(8)
          .map((m) => m[0])
          .join(' | '),
    }, level: 'ERROR');
  }

  static void _write(String module, String message, String level) {
    if (!const ['DEBUG', 'INFO', 'WARN', 'ERROR'].contains(level)) {
      level = 'DEBUG';
    }
    if (!enabled && level == 'DEBUG') return;
    final dir = directory;
    if (dir == null) return;
    // Reserve space for summaries/errors when detailed producers are busy.
    if (_pending >= (level == 'DEBUG' ? maxPending - 32 : maxPending)) {
      droppedEntries++;
      return;
    }
    final now = DateTime.now().toUtc();
    final text = message.replaceAll(RegExp(r'[\r\n]'), ' ');
    var tag = module.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
    if (tag.length > 32) tag = tag.substring(0, 32);
    var bytes = utf8.encode('${now.toIso8601String()} [$level] [$tag] $text\n');
    if (bytes.length > maxEntryBytes) {
      truncatedEntries++;
      bytes = utf8.encode(
        '${utf8.decode(bytes.sublist(0, maxEntryBytes - 64), allowMalformed: true)} …[truncated]\n',
      );
    }
    _pending++;
    _queue = _queue.then((_) async {
      try {
        await dir.create(recursive: true);
        var file = File(p.join(dir.path, 'current.log'));
        if (await FileSystemEntity.type(file.path, followLinks: false) ==
            FileSystemEntityType.link) {
          throw const FileSystemException('Log destination is a symbolic link');
        }
        if (await file.exists() &&
            await file.length() + bytes.length > maxBytes) {
          await file.rename(
            p.join(dir.path, '${DateTime.now().microsecondsSinceEpoch}.log'),
          );
          file = File(p.join(dir.path, 'current.log'));
          _maintenanceAt = null;
        }
        await file.writeAsBytes(
          bytes,
          mode: FileMode.append,
          flush: level == 'ERROR',
        );
        if (_maintainedPath != dir.path ||
            _maintenanceAt == null ||
            now.difference(_maintenanceAt!).inSeconds >= 30) {
          await _prune(dir);
          _maintainedPath = dir.path;
          _maintenanceAt = now;
        }
      } catch (_) {
        writeFailures++;
      } finally {
        _pending--;
      }
    });
  }

  static bool _owned(FileSystemEntity file) =>
      file is File &&
      RegExp(r'^(current|[0-9]+)\.log$').hasMatch(p.basename(file.path));
  static Future<List<File>> _files(Directory dir) async {
    if (!await dir.exists()) return [];
    final files = await dir
        .list(followLinks: false)
        .where(_owned)
        .cast<File>()
        .toList();
    files.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    return files;
  }

  static Future<void> _prune(Directory dir) async {
    final files = await _files(dir);
    var total = 0, kept = 0;
    for (final file in files.reversed) {
      final size = await file.length();
      final old =
          DateTime.now().difference(await file.lastModified()).inDays >= 7;
      if (old || kept >= maxFiles || total + size > maxBytes * maxFiles) {
        await file.delete();
      } else {
        total += size;
        kept++;
      }
    }
  }

  static const maxExportBytes = 256 * 1024, maxExportLines = 400;

  /// A single bounded TXT incident, serialized with rotation and writes.
  /// No incident means no export; normal history is never used as a substitute.
  static Future<String?> latestIncidentText() {
    final dir = directory;
    final result = _queue.then((_) async {
      if (dir == null) return null;
      await _prune(dir);
      final records = <_LogRecord>[];
      var unreadableLines = 0;
      final cutoff = DateTime.now().toUtc().subtract(const Duration(days: 7));
      for (final file in await _files(dir)) {
        for (final line in const LineSplitter().convert(
          utf8.decode(await file.readAsBytes(), allowMalformed: true),
        )) {
          final record = _LogRecord.parse(line);
          if (record == null && line.trim().isNotEmpty) unreadableLines++;
          if (record != null && !record.time.isBefore(cutoff)) {
            records.add(record);
          }
        }
      }
      var anchorIndex = records.lastIndexWhere((r) => r.level == 'ERROR');
      if (anchorIndex < 0) {
        anchorIndex = records.lastIndexWhere((r) => r.level == 'WARN');
      }
      if (anchorIndex < 0) return null;
      final anchor = records[anchorIndex];
      final before = anchor.time.subtract(const Duration(seconds: 60));
      final after = anchor.time.add(const Duration(seconds: 15));
      final candidates = <int>[];
      int? sessionStart;
      for (var i = 0; i < records.length; i++) {
        final r = records[i];
        if (anchor.session != null &&
            r.session != null &&
            r.session != anchor.session) {
          continue;
        }
        if (anchor.session != null &&
            r.session == anchor.session &&
            r.event == 'session_start' &&
            i <= anchorIndex) {
          sessionStart = i;
        }
        if (!r.time.isBefore(before) && !r.time.isAfter(after)) {
          candidates.add(i);
        }
      }
      if (sessionStart != null && !candidates.contains(sessionStart)) {
        candidates.add(sessionStart);
      }
      // Closest records first for allocation; the anchor can never be truncated away.
      candidates.sort(
        (a, b) => (a - anchorIndex).abs().compareTo((b - anchorIndex).abs()),
      );
      final selected = <int>[];
      var used = 0;
      for (final i in candidates) {
        final size = utf8.encode(records[i].line).length + 1;
        if (selected.length < maxExportLines &&
            used + size <= maxExportBytes - 8192) {
          selected.add(i);
          used += size;
        }
      }
      selected.sort();
      final header = <String, Object?>{
        'format': 'Konata incident TXT v1',
        'exportedAtUtc': DateTime.now().toUtc().toIso8601String(),
        'incidentAtUtc': anchor.time.toIso8601String(),
        'incidentSeverity': anchor.level,
        'session': anchor.session,
        'exportingProcessRun': runId,
        'exportingBuildVersion': buildVersion,
        'exportingBuildRevision': buildRevision,
        'platform': Platform.operatingSystem,
        'osVersion': redact(Platform.operatingSystemVersion),
        'detailedLoggingNow': enabled,
        'droppedEntriesThisProcess': droppedEntries,
        'writeFailuresThisProcess': writeFailures,
        'truncatedEntriesThisProcess': truncatedEntries,
        'contextBeforeSeconds': 60,
        'contextAfterSeconds': 15,
        'contextLinesOmitted': candidates.length - selected.length,
        'records': selected.length,
        'unparsedLinesInRetainedFiles': unreadableLines,
      };
      return 'Konata — 最近异常日志 / Latest incident\n'
          '${const JsonEncoder.withIndent('  ').convert(header)}\n'
          '${anchor.level == 'WARN' ? 'WARNING ONLY: this record does not establish playback failure.\n' : ''}'
          'Context is limited by retention, logging mode and export time; missing records do not prove success.\n'
          'Build identity above is the exporting process; use session_start for the incident build. Unknown means unverified.\n'
          'UTC [level] [module] JSON/text. session links playback and requests.\n'
          'headersMs / firstByteMs measure relay observations; maxObservedGapMs can include downstream backpressure.\n'
          'position_advancing is not a physical first-frame or smoothness measurement.\n'
          '--- incident ---\n${anchor.line}\n--- context (chronological) ---\n'
          '${selected.map((i) => records[i].line).join('\n')}\n';
    });
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  static Future<void> flush() => _queue;
}

class _LogRecord {
  _LogRecord(this.line, this.time, this.level, this.session, this.event);
  final String line, level;
  final DateTime time;
  final String? session, event;

  static _LogRecord? parse(String line) {
    final match = RegExp(
      r'^(\S+) \[(DEBUG|INFO|WARN|ERROR)\] \[[^\]]+\] (.*)$',
    ).firstMatch(line);
    if (match == null) return null;
    final time = DateTime.tryParse(match[1]!);
    if (time == null) return null;
    String? session, event;
    var safeLine = DebugLog.redact(line);
    try {
      final data = jsonDecode(match[3]!);
      if (data is Map) {
        if (data['session'] is String) session = data['session'] as String;
        if (data['event'] is String) event = data['event'] as String;
        if (event != null) {
          final safe = <String, Object?>{};
          for (final entry in data.entries) {
            final key = entry.key.toString();
            safe[key] =
                RegExp(
                  r'password|secret|token|cookie|authorization|username|api.?key',
                  caseSensitive: false,
                ).hasMatch(key)
                ? '[REDACTED]'
                : entry.value is String
                ? DebugLog.redact(entry.value as String)
                : entry.value;
          }
          safeLine =
              '${line.substring(0, line.length - match[3]!.length)}${jsonEncode(safe)}';
        }
      }
    } catch (_) {
      /* Legacy text remains readable. */
    }
    // Old installations did not cap individual messages. Keep their incident
    // anchor, but never let one legacy line exceed the TXT budget by itself.
    final bytes = utf8.encode(safeLine);
    if (bytes.length > DebugLog.maxEntryBytes) {
      safeLine =
          '${utf8.decode(bytes.sublist(0, DebugLog.maxEntryBytes - 64), allowMalformed: true)} …[legacy truncated]';
    }
    return _LogRecord(safeLine, time.toUtc(), match[2]!, session, event);
  }
}
