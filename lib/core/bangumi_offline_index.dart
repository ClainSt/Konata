import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:archive/archive_io.dart' as archive;
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'personal_filename_parser.dart';
import 'transient_tls.dart';
import 'system_proxy.dart';

typedef OfflineSnapshot = ({Uri url, int bytes, String digest, String version});

/// User-installed, rebuildable animation name data. No timers or startup work.
/// Connections live only for one query/update; replacing data is serialized with
/// readers so Windows never renames an open SQLite database.
class BangumiOfflineIndex {
  BangumiOfflineIndex(this.root);
  final Directory root;
  static Directory? directory;
  static int generation = 0;
  static Future<void> _gate = Future.value();
  static bool _installing = false;
  static const maxArchiveBytes = 768 * 1024 * 1024;
  static const maxIndexBytes = 128 * 1024 * 1024;
  static const latestUrl =
      'https://raw.githubusercontent.com/bangumi/Archive/master/aux/latest.json';
  File get _current => File(p.join(root.path, 'animation.sqlite'));
  File get _previous => File(p.join(root.path, 'animation.previous.sqlite'));
  bool _cancelled = false;
  Directory? _staging;
  HttpClient? _http;
  File get _partial => File(p.join(root.path, 'archive.part'));
  File get _partialIdentity => File(p.join(root.path, 'archive.part.sha256'));

  Future<HttpClientResponse> _get(Uri uri, {int offset = 0}) =>
      retryInterruptedTls(() async {
        _check();
        final client = _http ??= (HttpClient()
          ..connectionTimeout = const Duration(seconds: 20)
          ..userAgent = 'ClainSt/Konata (+https://github.com/ClainSt/Konata)');
        try {
          return await (() async {
            var target = uri;
            for (var redirects = 0; redirects <= 5; redirects++) {
              _check();
              await configureSystemProxy(client, target);
              final request = await client.getUrl(target);
              request.followRedirects = false;
              if (offset > 0) {
                request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
              }
              final response = await request.close();
              if (![301, 302, 303, 307, 308].contains(response.statusCode)) {
                return response;
              }
              final location = response.headers.value(
                HttpHeaders.locationHeader,
              );
              await response.drain<void>();
              if (location == null || redirects == 5) {
                throw const HttpException('Invalid archive redirect');
              }
              target = target.resolve(location);
              if (target.scheme != 'https' || target.userInfo.isNotEmpty) {
                throw const HttpException('Unsafe archive redirect');
              }
            }
            throw const HttpException('Too many archive redirects');
          })().timeout(const Duration(seconds: 30));
        } catch (_) {
          client.close(force: true);
          if (identical(_http, client)) _http = null;
          rethrow;
        }
      });

  Future<OfflineSnapshot> checkLatest() async {
    if (_installing) throw StateError('Index update in progress');
    _cancelled = false;
    try {
      return await _manifest();
    } catch (_) {
      _check();
      rethrow;
    } finally {
      _http?.close(force: true);
      _http = null;
    }
  }

  Future<OfflineSnapshot> _manifest() async {
    try {
      return await _readManifest(Uri.parse(latestUrl));
    } catch (_) {
      _check();
      _http?.close(force: true);
      _http = null;
      // The same official file through GitHub's API helps networks that reset
      // raw.githubusercontent.com. No third-party mirror or TLS bypass.
      return _readManifest(
        Uri.parse(
          'https://api.github.com/repos/bangumi/Archive/contents/aux/latest.json?ref=master',
        ),
      );
    }
  }

  Future<OfflineSnapshot> _readManifest(Uri source) async {
    final response = await _get(source);
    if (response.statusCode != 200) {
      throw HttpException('Archive manifest HTTP ${response.statusCode}');
    }
    final bytes = <int>[];
    await for (final part in response.timeout(const Duration(seconds: 30))) {
      _check();
      bytes.addAll(part);
      if (bytes.length > 128 * 1024) {
        throw const FormatException('Manifest too large');
      }
    }
    var manifest = jsonDecode(utf8.decode(bytes)) as Map;
    if (source.host == 'api.github.com') {
      if (manifest['encoding'] != 'base64' || manifest['content'] is! String) {
        throw const FormatException('Invalid official file response');
      }
      final raw = base64Decode(
        (manifest['content'] as String).replaceAll(RegExp(r'\s'), ''),
      );
      if (raw.length > 64 * 1024) {
        throw const FormatException('Manifest too large');
      }
      manifest = jsonDecode(utf8.decode(raw)) as Map;
    }
    final uri = Uri.parse('${manifest['browser_download_url']}');
    final size = manifest['size'];
    final digest = '${manifest['digest']}'.replaceFirst('sha256:', '');
    if (size is! int) {
      throw const FormatException('Invalid official archive manifest');
    }
    final snapshot = (
      url: uri,
      bytes: size,
      digest: digest,
      version: '${manifest['name']}',
    );
    _validateSnapshot(snapshot);
    return snapshot;
  }

  static void _validateSnapshot(OfflineSnapshot snapshot) {
    if (snapshot.url.scheme != 'https' ||
        snapshot.url.host != 'github.com' ||
        !snapshot.url.path.startsWith('/bangumi/Archive/releases/download/') ||
        snapshot.bytes <= 0 ||
        snapshot.bytes > maxArchiveBytes ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(snapshot.digest)) {
      throw const FormatException('Invalid official archive manifest');
    }
  }

  static Future<T> _locked<T>(Future<T> Function() action) {
    final next = _gate.then((_) => action());
    _gate = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  void cancel() {
    _cancelled = true;
    _http?.close(force: true);
    final staging = _staging;
    if (staging != null && staging.existsSync()) {
      File(p.join(staging.path, 'cancel')).writeAsStringSync('cancel');
    }
  }

  void _check() {
    if (_cancelled) throw const OfflineIndexCancelled();
  }

  Future<Map<String, Object?>?> status() => _locked(() async {
    final file = await _readable();
    if (file == null) return null;
    final db = await databaseFactory.openDatabase(
      file.path,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    try {
      final rows = await db.query('info');
      return {
        for (final row in rows) '${row['key']}': row['value'],
        'bytes': await file.length(),
      };
    } finally {
      await db.close();
    }
  });

  Future<File?> _readable() async {
    if (await _current.exists()) return _current;
    return await _previous.exists() ? _previous : null;
  }

  Future<RandomAccessFile> _lockUpdate() async {
    await root.create(recursive: true);
    final lock = await File(
      p.join(root.path, 'update.lock'),
    ).open(mode: FileMode.append);
    try {
      // Nonblocking OS lock prevents two app processes replacing the same
      // snapshot. The OS releases it even if a process is terminated.
      await lock.lock(FileLock.exclusive);
      return lock;
    } catch (_) {
      await lock.close();
      rethrow;
    }
  }

  Future<void> _cleanStaging() async {
    // Called only with the update lock held. These are owned import scratch
    // directories, never the selected source ZIP or a followed symlink.
    await for (final entry in root.list(followLinks: false)) {
      if (entry is Directory &&
          p.basename(entry.path).startsWith('import-') &&
          p.isWithin(p.absolute(root.path), p.absolute(entry.path))) {
        await entry.delete(recursive: true);
      }
    }
  }

  static String? _indexedFile;
  static int _indexedGen = -1;

  static String _indexExpression() {
    var expression = 'name';
    for (final mark in PersonalFilenameParser.identityPunctuation) {
      expression = "replace($expression, '${mark.replaceAll("'", "''")}', '')";
    }
    return expression;
  }

  static Set<String> _expandedKeys(Iterable<String> titles) {
    const romanToAscii = {
      'ⅰ': 'i',
      'ⅱ': 'ii',
      'ⅲ': 'iii',
      'ⅳ': 'iv',
      'ⅴ': 'v',
      'ⅵ': 'vi',
      'ⅶ': 'vii',
      'ⅷ': 'viii',
      'ⅸ': 'ix',
      'ⅹ': 'x',
    };
    final keys = <String>{};
    for (final title in titles) {
      final key = PersonalFilenameParser.normalizeIdentity(title);
      if (key.isEmpty) continue;
      keys.add(key);
      var converted = key;
      for (final entry in romanToAscii.entries) {
        converted = converted.replaceAll(entry.key, entry.value);
      }
      if (converted != key) keys.add(converted);
    }
    return keys;
  }

  Future<void> _ensureExpressionIndex(File file, String expression) async {
    final stamp = '${file.path}:${await file.length()}';
    if (_indexedFile == stamp && _indexedGen == generation) return;
    final db = await databaseFactory.openDatabase(
      file.path,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    try {
      final indexes = await db.rawQuery(
        "SELECT 1 FROM sqlite_master WHERE type='index' AND name='names_punctuation_v2'",
      );
      if (indexes.isEmpty) {
        await db.transaction((transaction) async {
          await transaction.execute(
            'CREATE INDEX IF NOT EXISTS names_punctuation_v2 ON names($expression)',
          );
          final pages =
              (await transaction.rawQuery(
                    'PRAGMA page_count',
                  )).single.values.single
                  as int;
          final pageSize =
              (await transaction.rawQuery(
                    'PRAGMA page_size',
                  )).single.values.single
                  as int;
          if (pages * pageSize > maxIndexBytes) {
            throw const FormatException('Index exceeds storage limit');
          }
        });
      }
      _indexedFile = '${file.path}:${await file.length()}';
      _indexedGen = generation;
    } finally {
      await db.close();
    }
  }

  /// Batch-lookup multiple title/filename hints in a single read-only SQLite
  /// connection, avoiding per-hint open/close overhead while keeping file
  /// replacement serialized on Windows.
  Future<List<Map<String, dynamic>>> lookupMany(
    Iterable<String> titles, {
    int limit = 48,
  }) => _locked(() async {
    final keys = _expandedKeys(titles).take(32).toList();
    if (keys.isEmpty) return [];
    final file = await _readable();
    if (file == null) return [];
    final expression = _indexExpression();
    await _ensureExpressionIndex(file, expression);
    final db = await databaseFactory.openDatabase(
      file.path,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    try {
      final placeholders = List.filled(keys.length, '?').join(',');
      final rows = await db.rawQuery(
        'SELECT DISTINCT s.id, s.payload FROM names n JOIN subjects s ON s.id=n.subject_id WHERE $expression IN ($placeholders) LIMIT ?',
        [...keys, limit],
      );
      return rows
          .map(
            (r) => jsonDecode(r['payload'] as String) as Map<String, dynamic>,
          )
          .toList();
    } finally {
      await db.close();
    }
  });

  /// All exact identities are retained. More than 32 means callers must defer
  /// to online confirmation; a truncated lookup never establishes uniqueness.
  Future<List<Map<String, dynamic>>> lookup(String title) => _locked(() async {
    final key = PersonalFilenameParser.normalizeIdentity(title);
    if (key.isEmpty) return [];
    final file = await _readable();
    if (file == null) return [];
    final expression = _indexExpression();
    await _ensureExpressionIndex(file, expression);
    final db = await databaseFactory.openDatabase(
      file.path,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    try {
      final rows = await db.rawQuery(
        'SELECT DISTINCT s.id, s.payload FROM names n JOIN subjects s ON s.id=n.subject_id WHERE $expression=? LIMIT 33',
        [key],
      );
      return rows
          .map(
            (r) => jsonDecode(r['payload'] as String) as Map<String, dynamic>,
          )
          .toList();
    } finally {
      await db.close();
    }
  });

  Future<void> remove() => _locked(() async {
    if (_installing) throw StateError('Index update in progress');
    if (!await root.exists()) return;
    final lock = await _lockUpdate();
    try {
      for (final file in [_current, _previous, _partial, _partialIdentity]) {
        if (await file.exists()) await file.delete();
      }
      await _cleanStaging();
      generation++;
    } finally {
      await lock.close();
    }
  });

  /// A local official ZIP may be imported without internet. Downloads always
  /// verify the digest advertised by Bangumi's official latest.json.
  Future<void> install({
    File? zip,
    OfflineSnapshot? snapshot,
    void Function(String, int, int)? progress,
  }) async {
    if (_installing) throw StateError('Index update in progress');
    final downloaded = zip == null;
    _installing = true;
    _cancelled = false;
    RandomAccessFile? updateLock;
    try {
      updateLock = await _lockUpdate();
      await _cleanStaging();
      _staging = await root.createTemp('import-');
      final stage = _staging!;
      String? expected;
      var version = zip == null ? '' : p.basename(zip.path);
      if (zip == null) {
        // Use the snapshot whose version and download size the user reviewed.
        final manifest = snapshot ?? await _manifest();
        _validateSnapshot(manifest);
        expected = manifest.digest;
        version = manifest.version;
        final size = manifest.bytes;
        if ((await status())?['archive_sha256'] == expected) {
          progress?.call('complete', 1, 1);
          return;
        }
        if (!await _partialIdentity.exists() ||
            await _partialIdentity.readAsString() != expected) {
          if (await _partial.exists()) await _partial.delete();
          await _partialIdentity.writeAsString(expected);
        }
        zip = _partial;
        var received = await zip.exists() ? await zip.length() : 0;
        if (received > size) {
          await zip.delete();
          received = 0;
        }
        if (received < size) {
          final download = await _get(manifest.url, offset: received);
          if (download.statusCode == 200) {
            received = 0;
          } else if (download.statusCode != 206 ||
              download.headers.value(HttpHeaders.contentRangeHeader) !=
                  'bytes $received-${size - 1}/$size') {
            throw HttpException(
              'Invalid archive range response (${download.statusCode})',
            );
          }
          final out = zip.openWrite(
            mode: received == 0 ? FileMode.write : FileMode.append,
          );
          var notified = received;
          try {
            await for (final part in download.timeout(
              const Duration(seconds: 30),
            )) {
              _check();
              received += part.length;
              if (received > size) {
                throw const FormatException('Archive size mismatch');
              }
              out.add(part);
              if (received - notified >= 1024 * 1024) {
                await out.flush();
                notified = received;
                progress?.call('download', received, size);
              }
            }
          } finally {
            await out.close();
          }
          if (received != size) {
            throw const FormatException('Incomplete archive');
          }
        }
      }
      _check();
      progress?.call('import', 0, 0);
      final zipPath = zip.path, stagePath = stage.path;
      final digest = expected;
      final compact = await _compactInBackground((zipPath, stagePath, digest));
      final count = compact.count;
      _check();
      final fresh = File(p.join(stage.path, 'animation.sqlite'));
      final db = await databaseFactory.openDatabase(
        fresh.path,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      try {
        await db.execute('PRAGMA journal_mode=DELETE');
        await db.execute(
          'CREATE TABLE subjects (id INTEGER PRIMARY KEY, payload TEXT NOT NULL)',
        );
        await db.execute(
          'CREATE TABLE names (name TEXT NOT NULL, subject_id INTEGER NOT NULL, PRIMARY KEY(name,subject_id)) WITHOUT ROWID',
        );
        await db.execute(
          'CREATE TABLE info (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
        );
        var batch = db.batch(), pending = 0, done = 0;
        await for (final line in File(
          p.join(stage.path, 'compact.jsonl'),
        ).openRead().transform(utf8.decoder).transform(const LineSplitter())) {
          _check();
          final row = jsonDecode(line) as Map<String, dynamic>;
          final names = (row.remove('_names') as List).cast<String>();
          batch.insert('subjects', {
            'id': row['id'],
            'payload': jsonEncode(row),
          });
          for (final name in names) {
            batch.insert('names', {'name': name, 'subject_id': row['id']});
          }
          pending++;
          if (pending == 250) {
            await batch.commit(noResult: true);
            done += pending;
            pending = 0;
            batch = db.batch();
            progress?.call('index', done, count);
            if (await fresh.length() > maxIndexBytes) {
              throw const FormatException('Index exceeds storage limit');
            }
          }
        }
        await batch.commit(noResult: true);
        for (final entry in {
          'version': version,
          'subjects': '$count',
          'schema': '1',
          'archive_sha256': compact.digest,
          'imported': DateTime.now().toUtc().toIso8601String(),
        }.entries) {
          await db.insert('info', {'key': entry.key, 'value': entry.value});
        }
        if ((await db.rawQuery('PRAGMA quick_check')).single.values.single !=
            'ok') {
          throw const FormatException('Index integrity check failed');
        }
      } finally {
        await db.close();
      }
      if (await fresh.length() > maxIndexBytes) {
        throw const FormatException('Index too large');
      }
      _check();
      await _locked(() async {
        _check();
        if (await _previous.exists() && await _current.exists()) {
          await _previous.delete();
        }
        if (await _current.exists()) await _current.rename(_previous.path);
        try {
          await fresh.rename(_current.path);
        } catch (_) {
          if (!await _current.exists() && await _previous.exists()) {
            await _previous.rename(_current.path);
          }
          rethrow;
        }
        if (await _previous.exists()) await _previous.delete();
        generation++;
      });
      progress?.call('complete', count, count);
      if (expected != null) {
        if (await _partial.exists()) await _partial.delete();
        if (await _partialIdentity.exists()) await _partialIdentity.delete();
      }
    } on FormatException {
      _check();
      if (downloaded) {
        if (await _partial.exists()) await _partial.delete();
        if (await _partialIdentity.exists()) await _partialIdentity.delete();
      }
      rethrow;
    } catch (_) {
      // Closing an active HTTP stream reports HttpException. Cancellation is
      // intentional, and its flushed partial download is retained for retry.
      _check();
      rethrow;
    } finally {
      _http?.close(force: true);
      _http = null;
      final stage = _staging;
      _staging = null;
      try {
        if (stage != null && await stage.exists()) {
          await stage.delete(recursive: true);
        }
      } finally {
        try {
          await updateLock?.close();
        } finally {
          _installing = false;
        }
      }
    }
  }
}

Future<({int count, String digest})> _compactInBackground(
  (String, String, String?) args,
) => Isolate.run(() => _compactArchive(args.$1, args.$2, args.$3));

class OfflineIndexCancelled implements Exception {
  const OfflineIndexCancelled();
}

/// Only the needed wiki fields are parsed. Malformed alias lists are ignored,
/// not guessed. Raw text is never executed and no archive path is extracted.
List<Map<String, Object?>> offlineWikiFields(String wiki) {
  final fields = <Map<String, Object?>>[];
  String? key;
  var values = <Map<String, String>>[];
  for (final raw in const LineSplitter().convert(wiki)) {
    final line = raw.trim();
    if (key != null) {
      if (line == '}') {
        fields.add({'key': key, 'value': values});
        key = null;
        values = [];
      } else if (line.startsWith('[') && line.endsWith(']')) {
        final content = line.substring(1, line.length - 1);
        values.add({'v': content.substring(content.indexOf('|') + 1).trim()});
      } else if (line.isNotEmpty) {
        key = null;
        values = [];
      }
      continue;
    }
    final match = RegExp(r'^\|([^=]+)=(.*)$').firstMatch(line);
    if (match == null) continue;
    final name = match[1]!.trim(), value = match[2]!.trim();
    if (!['别名', '中文名', 'alias', 'aliases'].contains(name.toLowerCase()) &&
        !name.toLowerCase().contains('tmdb')) {
      continue;
    }
    if (value == '{') {
      key = name;
    } else if (value.isNotEmpty) {
      fields.add({'key': name, 'value': value});
    }
  }
  return fields;
}

Future<({int count, String digest})> _compactArchive(
  String zipPath,
  String staging,
  String? expected,
) async {
  final zip = File(zipPath), cancel = File(p.join(staging, 'cancel'));
  void check() {
    if (cancel.existsSync()) throw const OfflineIndexCancelled();
  }

  final size = await zip.length();
  if (size <= 0 || size > BangumiOfflineIndex.maxArchiveBytes) {
    throw const FormatException('Archive too large');
  }
  final digest =
      (await sha256
              .bind(
                zip.openRead().map((part) {
                  check();
                  return part;
                }),
              )
              .first)
          .toString();
  if (expected != null) {
    if (digest != expected) {
      throw const FormatException('Archive SHA-256 mismatch');
    }
  }
  final input = archive.InputFileStream(zipPath);
  final output = File(p.join(staging, 'compact.jsonl')).openWrite();
  var count = 0, outputBytes = 0;
  try {
    final decoded = archive.ZipDecoder().decodeStream(input);
    final entries = decoded.files
        .where((entry) => entry.name == 'subject.jsonlines')
        .toList();
    if (entries.length != 1) {
      throw const FormatException('Missing unique subject.jsonlines');
    }
    final entry = entries.single;
    if (!entry.isFile ||
        entry.isSymbolicLink ||
        entry.size > 2 * 1024 * 1024 * 1024 ||
        ![
          archive.CompressionType.none,
          archive.CompressionType.deflate,
        ].contains(entry.compression)) {
      throw const FormatException('Unsupported subject archive');
    }
    final raw = entry.rawContent!.getStream(decompress: false);
    Stream<List<int>> chunks() async* {
      while (!raw.isEOS) {
        check();
        yield raw
            .readBytes(raw.length < 65536 ? raw.length : 65536)
            .toUint8List();
      }
    }

    final bytes = entry.compression == archive.CompressionType.deflate
        ? chunks().transform(ZLibDecoder(raw: true))
        : chunks();
    var total = 0, crc = 0, lineBytes = 0;
    final checked = bytes.map((part) {
      check();
      total += part.length;
      if (total > entry.size) {
        throw const FormatException('Expanded size mismatch');
      }
      crc = archive.getCrc32(part, crc);
      var start = 0;
      for (
        var end = part.indexOf(10);
        end >= 0;
        end = part.indexOf(10, start)
      ) {
        if (lineBytes + end - start > 1024 * 1024) {
          throw const FormatException('Subject row too large');
        }
        lineBytes = 0;
        start = end + 1;
      }
      lineBytes += part.length - start;
      if (lineBytes > 1024 * 1024) {
        throw const FormatException('Subject row too large');
      }
      return part;
    });
    await for (final line
        in checked.transform(utf8.decoder).transform(const LineSplitter())) {
      final data = jsonDecode(line) as Map;
      if (data['type'] != 2) continue;
      if (data['id'] is! int || (data['id'] as int) <= 0) {
        throw const FormatException('Invalid subject ID');
      }
      final fields = offlineWikiFields('${data['infobox'] ?? ''}');
      final names = <String>{
        '${data['name'] ?? ''}',
        '${data['name_cn'] ?? ''}',
      };
      for (final field in fields) {
        if (![
          '别名',
          '中文名',
          'alias',
          'aliases',
        ].contains('${field['key']}'.toLowerCase())) {
          continue;
        }
        final value = field['value'];
        if (value is String) names.add(value);
        if (value is List) names.addAll(value.map((v) => '${(v as Map)['v']}'));
      }
      final row = jsonEncode({
        for (final key in ['id', 'name', 'name_cn', 'date', 'platform'])
          key: data[key],
        'infobox': fields,
        '_names': names
            .map(PersonalFilenameParser.normalizeIdentity)
            .where((s) => s.isNotEmpty)
            .toSet()
            .toList(),
      });
      outputBytes += utf8.encode(row).length + 1;
      if (++count > 200000 || outputBytes > BangumiOfflineIndex.maxIndexBytes) {
        throw const FormatException('Animation data too large');
      }
      output.writeln(row);
      if (count % 250 == 0) await output.flush();
    }
    if (total != entry.size || crc != entry.crc32 || count == 0) {
      throw const FormatException('Invalid subject data or checksum');
    }
    return (count: count, digest: digest);
  } finally {
    await output.close();
    await input.close();
  }
}
