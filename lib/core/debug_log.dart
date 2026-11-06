import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DebugLog {
  static bool enabled = false;
  static Directory? directory;
  static Future<void> _queue = Future.value();
  static const maxBytes = 10 * 1024 * 1024;
  static Future<void> initialize({Directory? root}) async {
    directory = Directory(
      p.join((root ?? await getApplicationSupportDirectory()).path, 'logs'),
    );
    enabled =
        (await SharedPreferences.getInstance()).getBool('debug_logs') ?? false;
    write('App', 'startup version=1.0.0 platform=${Platform.operatingSystem}');
  }

  static Future<void> setEnabled(bool value) async {
    await (await SharedPreferences.getInstance()).setBool('debug_logs', value);
    enabled = value;
    if (value) write('App', 'debug logging enabled');
    await flush();
  }

  static String redact(String value) => value
      .replaceAll(
        RegExp(r'(?:https?|smb|webdav)://[^\s]+', caseSensitive: false),
        '[URL]',
      )
      .replaceAll(
        RegExp(
          r'\b(?:authorization|cookie|set-cookie)\s*[:=][^\r\n]*',
          caseSensitive: false,
        ),
        '[REDACTED HEADER]',
      )
      .replaceAll(
        RegExp(r'(Bearer\s+)[^\s,;]+', caseSensitive: false),
        'Bearer [REDACTED]',
      )
      .replaceAll(
        RegExp(
          r'(api_key|token|password|authorization|cookie|username)\s*[:=]\s*[^\s,;]+',
          caseSensitive: false,
        ),
        '[REDACTED]',
      );
  static void write(String module, String event, {String level = 'DEBUG'}) {
    if (!enabled && level != 'ERROR') return;
    final dir = directory;
    if (dir == null) return;
    final now = DateTime.now();
    final offset = now.timeZoneOffset;
    final zone =
        '${offset.isNegative ? '-' : '+'}${offset.inHours.abs().toString().padLeft(2, '0')}:${(offset.inMinutes.abs() % 60).toString().padLeft(2, '0')}';
    final line =
        '${now.toIso8601String()}$zone [$level] [$module] ${redact(event).replaceAll(RegExp(r'[\r\n]'), ' ')}\n';
    _queue = _queue.then((_) async {
      try {
        await dir.create(recursive: true);
        final files = await dir
            .list()
            .where((e) => e is File && e.path.endsWith('.log'))
            .cast<File>()
            .toList();
        files.sort((a, b) => a.path.compareTo(b.path));
        for (final f in files) {
          if (now.difference(await f.lastModified()).inDays >= 7 ||
              files.length > 14 && f != files.last) {
            await f.delete();
          }
        }
        var file = File(p.join(dir.path, 'current.log'));
        if (await file.exists() &&
            await file.length() + line.length > maxBytes) {
          await file.rename(
            p.join(dir.path, '${now.microsecondsSinceEpoch}.log'),
          );
          file = File(p.join(dir.path, 'current.log'));
        }
        await file.writeAsString(
          line,
          mode: FileMode.append,
          flush: level == 'ERROR',
        );
      } catch (_) {
        /* Diagnostics must never break application operations. */
      }
    });
  }

  static Future<void> flush() => _queue;
}
