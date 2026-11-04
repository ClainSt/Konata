import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class Catalog extends ChangeNotifier {
  Catalog._();
  static final instance = Catalog._();
  late Database db;
  static const _secrets = FlutterSecureStorage();
  List<Map<String, Object?>> sources = [],
      works = [],
      assets = [],
      scanRoots = [];
  bool scanning = false;
  String status = '就绪';

  Future<void> initialize() async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    final folder = await getApplicationSupportDirectory();
    await folder.create(recursive: true);
    db = await openDatabase(
      p.join(folder.path, 'ccplayer.db'),
      version: 3,
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            'CREATE TABLE scan_roots (source_id TEXT NOT NULL, relative_path TEXT NOT NULL, mode TEXT NOT NULL, PRIMARY KEY(source_id,relative_path))',
          );
        }
        if (oldVersion < 3) {
          await db.update('scan_roots', {'mode': 'auto'});
          await db.execute(
            'ALTER TABLE works ADD COLUMN needs_review INTEGER NOT NULL DEFAULT 1',
          );
          await db.execute(
            'UPDATE works SET needs_review=0 WHERE tmdb_id IS NOT NULL OR manual_lock=1',
          );
        }
      },
      onCreate: (db, version) async {
        await db.execute(
          'CREATE TABLE sources (id TEXT PRIMARY KEY, kind TEXT NOT NULL, label TEXT NOT NULL, location TEXT NOT NULL, username TEXT, password TEXT)',
        );
        await db.execute(
          'CREATE TABLE works (id TEXT PRIMARY KEY, title TEXT NOT NULL, year INTEGER, tmdb_id INTEGER, tmdb_type TEXT, bangumi_id INTEGER, poster TEXT, overview TEXT, manual_lock INTEGER NOT NULL DEFAULT 0, needs_review INTEGER NOT NULL DEFAULT 1)',
        );
        await db.execute(
          'CREATE TABLE assets (id TEXT PRIMARY KEY, source_id TEXT NOT NULL, work_id TEXT NOT NULL, relative_path TEXT NOT NULL, name TEXT NOT NULL, episode INTEGER, category TEXT NOT NULL, size INTEGER, UNIQUE(source_id,relative_path))',
        );
        await db.execute(
          'CREATE TABLE progress (asset_id TEXT PRIMARY KEY, position_ms INTEGER NOT NULL, duration_ms INTEGER NOT NULL, completed INTEGER NOT NULL, updated_at TEXT NOT NULL)',
        );
        await db.execute('CREATE INDEX assets_by_work ON assets(work_id)');
        await db.execute(
          'CREATE TABLE scan_roots (source_id TEXT NOT NULL, relative_path TEXT NOT NULL, mode TEXT NOT NULL, PRIMARY KEY(source_id,relative_path))',
        );
      },
    );
    // Migrate passwords previously kept in the early development SQLite schema.
    final previous = await db.query('sources', columns: ['id', 'password']);
    for (final entry in previous) {
      final oldPassword = entry['password']?.toString() ?? '';
      if (oldPassword.isNotEmpty) {
        await _secrets.write(key: 'webdav:${entry['id']}', value: oldPassword);
        await db.update(
          'sources',
          {'password': null},
          where: 'id=?',
          whereArgs: [entry['id']],
        );
      }
    }
    await reload();
  }

  Future<void> reload() async {
    sources = await db.query('sources', orderBy: 'label');
    works = await db.query('works', orderBy: 'title COLLATE NOCASE');
    assets = await db.query('assets', orderBy: 'episode, name');
    scanRoots = await db.query('scan_roots', orderBy: 'relative_path');
    notifyListeners();
  }

  void updateStatus(String message, [bool active = false]) {
    status = message;
    scanning = active;
    notifyListeners();
  }

  Future<String> addSource(
    String type,
    String name,
    String location, {
    String username = '',
    String password = '',
  }) async {
    final id = 'src-${DateTime.now().microsecondsSinceEpoch}';
    await db.insert('sources', {
      'id': id,
      'kind': type,
      'label': name,
      'location': location,
      'username': username,
      'password': null,
    });
    if (password.isNotEmpty) {
      await _secrets.write(key: 'webdav:$id', value: password);
    }
    await reload();
    return id;
  }

  /// Edit connection settings without changing stable source id or its indexes.
  /// Null password keeps the existing secret; empty password removes it.
  Future<void> updateSource(
    String sourceId, {
    required String label,
    required String location,
    required String username,
    String? password,
  }) async {
    final source = sourceOf(sourceId);
    if (source['kind'] == 'webdav') {
      final uri = Uri.tryParse(location);
      if (uri == null ||
          !uri.hasAuthority ||
          (uri.scheme != 'https' && uri.scheme != 'http')) {
        throw ArgumentError('请输入有效的 HTTP(S) WebDAV 地址');
      }
      if (username.isEmpty && password != null && password.isNotEmpty) {
        throw ArgumentError('匿名访问不能单独填写密码');
      }
    }
    if (password != null) {
      if (password.isEmpty) {
        await _secrets.delete(key: 'webdav:$sourceId');
      } else {
        await _secrets.write(key: 'webdav:$sourceId', value: password);
      }
    }
    await db.update(
      'sources',
      {
        'label': label.trim(),
        'location': location.trim(),
        'username': username.trim(),
      },
      where: 'id=?',
      whereArgs: [sourceId],
    );
    await reload();
  }

  Future<Map<String, Object?>> withCredentials(
    Map<String, Object?> source,
  ) async => {
    ...source,
    'password': (await _secrets.read(key: 'webdav:${source['id']}')) ?? '',
  };
  static String normalizeRoot(String raw) => raw
      .replaceAll('\\', '/')
      .split('/')
      .where((s) => s.isNotEmpty && s != '.')
      .join('/');
  List<Map<String, Object?>> rootsFor(String sourceId) =>
      scanRoots.where((r) => r['source_id'] == sourceId).toList();

  /// A selection identifies a scan scope only; work/collection inference is automatic.
  /// Selecting a parent replaces covered child scopes, and vice versa.
  Future<void> addScanRoot(String sourceId, String rawPath) async {
    final path = normalizeRoot(rawPath);
    if (path.split('/').contains('..')) {
      throw ArgumentError('不允许扫描父级目录');
    }
    await db.transaction((tx) async {
      final existing = await tx.query(
        'scan_roots',
        where: 'source_id=?',
        whereArgs: [sourceId],
      );
      for (final row in existing) {
        final other = row['relative_path'].toString();
        if (path.isEmpty ||
            other.isEmpty ||
            path == other ||
            path.startsWith('$other/') ||
            other.startsWith('$path/')) {
          await tx.delete(
            'scan_roots',
            where: 'source_id=? AND relative_path=?',
            whereArgs: [sourceId, other],
          );
        }
      }
      await tx.insert('scan_roots', {
        'source_id': sourceId,
        'relative_path': path,
        'mode': 'auto',
      });
    });
    await reload();
  }

  Future<void> toggleScanRoot(String sourceId, String rawPath) async {
    final path = normalizeRoot(rawPath);
    if (rootsFor(sourceId).any((r) => r['relative_path'] == path)) {
      await removeScanRoot(sourceId, path);
    } else {
      await addScanRoot(sourceId, path);
    }
  }

  Future<void> removeScanRoot(String sourceId, String path) async {
    await db.delete(
      'scan_roots',
      where: 'source_id=? AND relative_path=?',
      whereArgs: [sourceId, path],
    );
    await reload();
  }

  Future<void> removeSource(String sourceId) async {
    await _secrets.delete(key: 'webdav:$sourceId');
    await db.transaction((txn) async {
      await txn.delete(
        'scan_roots',
        where: 'source_id=?',
        whereArgs: [sourceId],
      );
      await txn.delete('assets', where: 'source_id=?', whereArgs: [sourceId]);
      await txn.delete('sources', where: 'id=?', whereArgs: [sourceId]);
      await txn.rawDelete(
        'DELETE FROM works WHERE manual_lock=0 AND id NOT IN (SELECT DISTINCT work_id FROM assets)',
      );
    });
    await reload();
  }

  static const videoExtensions = {
    '.mkv',
    '.mp4',
    '.avi',
    '.m2ts',
    '.ts',
    '.webm',
    '.mov',
  };
  static const subtitleExtensions = {'.ass', '.ssa', '.srt', '.vtt'};
  static bool isVideo(String name) =>
      videoExtensions.contains(p.extension(name).toLowerCase());
  static bool isSubtitle(String name) =>
      subtitleExtensions.contains(p.extension(name).toLowerCase());
  static int? tmdbId(String title) => int.tryParse(
    RegExp(
          r'\{tmdb-(\d+)\}',
          caseSensitive: false,
        ).firstMatch(title)?.group(1) ??
        '',
  );
  static int? year(String title) => int.tryParse(
    RegExp(r'\((19\d\d|20\d\d)\)').firstMatch(title)?.group(1) ?? '',
  );
  static String cleanTitle(String folder) {
    var title = folder.replaceAll(
      RegExp(r'\{tmdb-\d+\}', caseSensitive: false),
      '',
    );
    title = title.replaceAll(RegExp(r'\(\d{4}\)'), '').trim();
    return title.isEmpty ? folder : title;
  }

  static bool isExtra(String name) =>
      RegExp(
        r'(^|[/\\])(SPs?|Extra|Bonus|NCOP|NCED|PV)([/\\]|$)',
        caseSensitive: false,
      ).hasMatch(name) ||
      RegExp(
        r'(NCOP|NCED|Trailer|Preview|PV\d+|CM\d+)',
        caseSensitive: false,
      ).hasMatch(p.basename(name));
  static int? episode(String name) {
    final stem = p.basenameWithoutExtension(name);
    for (final re in [
      RegExp(r'[Ss]\d{1,2}[Ee](\d{1,3})'),
      RegExp(
        r'(?<![A-Za-z0-9])(?:EP|Episode|E)[\s._#-]?(\d{1,3})\b',
        caseSensitive: false,
      ),
      RegExp(r'^\[(\d{1,3})\]'),
      RegExp(r'[#＃](\d{1,3})\b'),
      RegExp(r'\s[-–]\s(\d{1,3})(?=\s|[([]|$)'),
      RegExp(r'^(\d{1,3})(?=$|[._\[(])'),
    ]) {
      final match = re.firstMatch(stem);
      if (match != null) return int.tryParse(match.group(1)!);
    }
    return null;
  }

  Future<void> indexVideo(
    String sourceId,
    String relative,
    int? size, {
    String? workFolder,
    bool needsReview = true,
  }) async {
    final normalized = relative.replaceAll('\\', '/');
    final name = p.posix.basename(normalized);
    final segments = p.posix.split(normalized);
    if (segments.isEmpty || !isVideo(name)) return;
    final folder = workFolder == null
        ? segments.first
        : normalizeRoot(workFolder);
    if (folder.isEmpty) return;
    final displayFolder = p.posix.basename(folder);
    if (RegExp(r'^(CDs?|Scans?)$', caseSensitive: false).hasMatch(folder)) {
      return;
    }
    final workId = 'work:$sourceId:${Uri.encodeComponent(folder)}';
    final assetId = 'asset:$sourceId:${Uri.encodeComponent(normalized)}';
    final existing = await db.query(
      'assets',
      columns: ['work_id'],
      where: 'id=?',
      whereArgs: [assetId],
      limit: 1,
    );
    var targetWorkId = workId;
    if (existing.isNotEmpty && existing.first['work_id'] != workId) {
      final oldId = existing.first['work_id']?.toString();
      if (oldId != null) {
        final oldWork = await db.query(
          'works',
          columns: ['manual_lock'],
          where: 'id=?',
          whereArgs: [oldId],
          limit: 1,
        );
        if (oldWork.isNotEmpty && oldWork.first['manual_lock'] == 1) {
          targetWorkId = oldId;
        }
      }
    }
    if (targetWorkId == workId) {
      await db.insert('works', {
        'id': workId,
        'title': cleanTitle(displayFolder),
        'year': year(displayFolder),
        'tmdb_id': tmdbId(displayFolder),
        'tmdb_type': tmdbId(displayFolder) == null ? null : 'tv',
        'needs_review': needsReview ? 1 : 0,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await db.insert('assets', {
      'id': assetId,
      'source_id': sourceId,
      'work_id': targetWorkId,
      'relative_path': normalized,
      'name': name,
      'episode': episode(name),
      'category': isExtra(normalized) ? 'extra' : 'main',
      'size': size,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Remove incorrect automatic groups that no longer own any file after rescanning.
  /// Never delete a manually locked work.
  Future<void> pruneOrphanedWorks() async {
    await db.rawDelete(
      'DELETE FROM works WHERE manual_lock=0 '
      'AND id NOT IN (SELECT DISTINCT work_id FROM assets)',
    );
    await reload();
  }

  Future<void> bind(
    String workId, {
    required String provider,
    required int providerId,
    required String title,
    int? year,
    String? poster,
    String? overview,
    String type = 'tv',
  }) async {
    final old = works.firstWhere((w) => w['id'] == workId);
    await db.update(
      'works',
      {
        'title': title,
        'year': year ?? old['year'],
        'poster': poster ?? old['poster'],
        'overview': overview ?? old['overview'],
        'manual_lock': 1,
        'needs_review': 0,
        if (provider == 'tmdb') ...{'tmdb_id': providerId, 'tmdb_type': type},
        if (provider == 'bangumi') 'bangumi_id': providerId,
      },
      where: 'id=?',
      whereArgs: [workId],
    );
    await reload();
  }

  Future<void> progress(String assetId, int position, int duration) async {
    await db.insert('progress', {
      'asset_id': assetId,
      'position_ms': position,
      'duration_ms': duration,
      'completed': duration > 0 && position / duration > 0.92 ? 1 : 0,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<int> resumePosition(String assetId) async {
    final rows = await db.query(
      'progress',
      where: 'asset_id=?',
      whereArgs: [assetId],
      limit: 1,
    );
    return rows.isEmpty ? 0 : (rows.first['position_ms'] as int? ?? 0);
  }

  List<Map<String, Object?>> forWork(String id) =>
      assets.where((a) => a['work_id'] == id).toList();
  Map<String, Object?> sourceOf(String id) =>
      sources.firstWhere((s) => s['id'] == id);
}
