import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'cloud_media_asset_presentation.dart';
import 'cloud_media_file_classifier.dart';
import 'personal_scraper.dart';
import 'work_season.dart';
import 'phantom_directory_repair.dart';
import 'sources.dart' show SmbSource;

class Catalog extends ChangeNotifier {
  Catalog._();
  static final instance = Catalog._();
  late Database db;
  static const _secrets = FlutterSecureStorage();
  List<Map<String, Object?>> sources = [],
      works = [],
      hiddenWorkEntries = [],
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
      version: 12,
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
        if (oldVersion < 4) {
          await db.execute(
            'CREATE TABLE work_details (work_id TEXT PRIMARY KEY, identity TEXT NOT NULL, payload TEXT NOT NULL, fetched_at TEXT NOT NULL)',
          );
        }
        if (oldVersion < 5) {
          await db.execute(
            'CREATE TABLE asset_overrides (asset_id TEXT PRIMARY KEY, work_id TEXT NOT NULL, category TEXT NOT NULL, episode INTEGER)',
          );
          await db.execute(
            'CREATE TABLE asset_override_history (asset_id TEXT PRIMARY KEY, work_id TEXT NOT NULL, category TEXT NOT NULL, episode INTEGER, was_locked INTEGER NOT NULL)',
          );
        }
        if (oldVersion < 6) {
          for (final table in [
            'assets',
            'asset_overrides',
            'asset_override_history',
          ]) {
            await db.execute(
              'ALTER TABLE $table ADD COLUMN season INTEGER NOT NULL DEFAULT 1',
            );
            await db.execute(
              "UPDATE $table SET season=0 WHERE category='extra'",
            );
          }
        }
        if (oldVersion < 7) {
          for (final table in [
            'assets',
            'asset_overrides',
            'asset_override_history',
          ]) {
            await db.execute('ALTER TABLE $table ADD COLUMN extra_type TEXT');
          }
        }
        if (oldVersion < 8) {
          // Offline-only upgrade: no WebDAV reads or video hashing.
          await repairIndexedAssets(db);
        }
        if (oldVersion < 9) {
          await db.execute('ALTER TABLE works ADD COLUMN poster_fallback TEXT');
        }
        if (oldVersion < 10) {
          await db.execute(
            'ALTER TABLE works ADD COLUMN manual_cover_url TEXT',
          );
          await db.execute(
            'ALTER TABLE works ADD COLUMN manual_cover_source TEXT',
          );
        }
        if (oldVersion < 11) {
          // Remove only validated phantom repeated-folder assets. Real files,
          // manual bindings, metadata and playback history are preserved.
          await PhantomDirectoryRepair.repair(db);
        }
        if (oldVersion < 12) {
          await db.execute(
            'ALTER TABLE works ADD COLUMN hidden INTEGER NOT NULL DEFAULT 0',
          );
          await db.execute(
            'ALTER TABLE works ADD COLUMN keep_hidden INTEGER NOT NULL DEFAULT 0',
          );
        }
      },
      onCreate: (db, version) async {
        await db.execute(
          'CREATE TABLE sources (id TEXT PRIMARY KEY, kind TEXT NOT NULL, label TEXT NOT NULL, location TEXT NOT NULL, username TEXT, password TEXT)',
        );
        await db.execute(
          'CREATE TABLE works (id TEXT PRIMARY KEY, title TEXT NOT NULL, year INTEGER, tmdb_id INTEGER, tmdb_type TEXT, bangumi_id INTEGER, poster TEXT, poster_fallback TEXT, manual_cover_url TEXT, manual_cover_source TEXT, overview TEXT, manual_lock INTEGER NOT NULL DEFAULT 0, needs_review INTEGER NOT NULL DEFAULT 1, hidden INTEGER NOT NULL DEFAULT 0, keep_hidden INTEGER NOT NULL DEFAULT 0)',
        );
        await db.execute(
          'CREATE TABLE assets (id TEXT PRIMARY KEY, source_id TEXT NOT NULL, work_id TEXT NOT NULL, relative_path TEXT NOT NULL, name TEXT NOT NULL, episode INTEGER, season INTEGER NOT NULL DEFAULT 1, category TEXT NOT NULL, extra_type TEXT, size INTEGER, UNIQUE(source_id,relative_path))',
        );
        await db.execute(
          'CREATE TABLE progress (asset_id TEXT PRIMARY KEY, position_ms INTEGER NOT NULL, duration_ms INTEGER NOT NULL, completed INTEGER NOT NULL, updated_at TEXT NOT NULL)',
        );
        await db.execute('CREATE INDEX assets_by_work ON assets(work_id)');
        await db.execute(
          'CREATE TABLE phantom_asset_archive ('
          'obsolete_asset_id TEXT PRIMARY KEY, canonical_asset_id TEXT NOT NULL, '
          'asset_json TEXT NOT NULL, progress_json TEXT, '
          'override_json TEXT, history_json TEXT, archived_at TEXT NOT NULL)',
        );
        await db.execute(
          'CREATE TABLE scan_roots (source_id TEXT NOT NULL, relative_path TEXT NOT NULL, mode TEXT NOT NULL, PRIMARY KEY(source_id,relative_path))',
        );
        await db.execute(
          'CREATE TABLE work_details (work_id TEXT PRIMARY KEY, identity TEXT NOT NULL, payload TEXT NOT NULL, fetched_at TEXT NOT NULL)',
        );
        await db.execute(
          'CREATE TABLE asset_overrides (asset_id TEXT PRIMARY KEY, work_id TEXT NOT NULL, category TEXT NOT NULL, episode INTEGER, season INTEGER NOT NULL DEFAULT 1, extra_type TEXT)',
        );
        await db.execute(
          'CREATE TABLE asset_override_history (asset_id TEXT PRIMARY KEY, work_id TEXT NOT NULL, category TEXT NOT NULL, episode INTEGER, season INTEGER NOT NULL DEFAULT 1, extra_type TEXT, was_locked INTEGER NOT NULL)',
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
    // Scan checkboxes are a temporary UI selection, never persistent library configuration.
    await db.delete('scan_roots');
    await reload();
  }

  Future<void> reload() async {
    sources = await db.query('sources', orderBy: 'label');
    final allWorks = await db.query('works', orderBy: 'title COLLATE NOCASE');
    works = allWorks.where((row) => row['hidden'] != 1).toList();
    hiddenWorkEntries = allWorks.where((row) => row['hidden'] == 1).toList();
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
    if (source['kind'] == 'smb') SmbSource.validateLocation(location);
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

  Future<void> clearScanRoots(String sourceId) async {
    await db.delete('scan_roots', where: 'source_id=?', whereArgs: [sourceId]);
    await reload();
  }

  Future<void> removeScanRoot(String sourceId, String path) async {
    await db.delete(
      'scan_roots',
      where: 'source_id=? AND relative_path=?',
      whereArgs: [sourceId, path],
    );
    await reload();
  }

  /// Hide a title from the poster wall without deleting source files,
  /// indexed assets, manual relations, metadata, or playback progress.
  /// If keepHidden=false, the next successful reindex makes it visible again.
  Future<void> hideWork(String workId, {required bool keepHidden}) async {
    final updated = await db.update(
      'works',
      {'hidden': 1, 'keep_hidden': keepHidden ? 1 : 0},
      where: 'id=?',
      whereArgs: [workId],
    );
    if (updated == 0) throw StateError('作品已不存在');
    await reload();
  }

  /// Explicitly restore a title irrespective of its rescan preference.
  Future<void> restoreWork(String workId) async {
    await db.update(
      'works',
      {'hidden': 0, 'keep_hidden': 0},
      where: 'id=?',
      whereArgs: [workId],
    );
    await reload();
  }

  Future<List<Map<String, Object?>>> hiddenWorks() async =>
      db.query('works', where: 'hidden=1', orderBy: 'title COLLATE NOCASE');

  Future<void> removeSource(String sourceId) async {
    await _secrets.delete(key: 'webdav:$sourceId');
    await db.transaction((txn) async {
      await txn.delete(
        'scan_roots',
        where: 'source_id=?',
        whereArgs: [sourceId],
      );
      await txn.rawDelete(
        'DELETE FROM asset_overrides WHERE asset_id IN (SELECT id FROM assets WHERE source_id=?)',
        [sourceId],
      );
      await txn.rawDelete(
        'DELETE FROM asset_override_history WHERE asset_id IN (SELECT id FROM assets WHERE source_id=?)',
        [sourceId],
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
  static int? tmdbId(String title) {
    for (final pattern in [
      r'\{\s*tmdb(?:tv|movie|id)?\s*[-=:]\s*(\d+)\s*\}',
      r'\[\s*tmdb\s*[-=:]\s*(\d+)\s*\]',
      r'\{\s*\[\s*tmdbid\s*=\s*(\d+)[^\]]*\]\s*\}',
    ]) {
      final id = int.tryParse(
        RegExp(pattern, caseSensitive: false).firstMatch(title)?.group(1) ?? '',
      );
      if (id != null && id > 0) return id;
    }
    return null;
  }

  static String? tmdbType(String title) {
    if (RegExp(
      r'tmdbmovie\s*[-=:]|type\s*=\s*(movie|film)',
      caseSensitive: false,
    ).hasMatch(title)) {
      return 'movie';
    }
    if (tmdbId(title) != null) return 'tv';
    return null;
  }

  static int? year(String title) => WorkSeason.year({'title': title});
  static String cleanTitle(String folder) {
    var title = folder.replaceAll(
      RegExp(
        r'\{\s*tmdb(?:tv|movie|id)?\s*[-=:]\s*\d+\s*\}|\{\s*\[\s*tmdbid[^}]*\}|\[\s*tmdb\s*[-=:]\s*\d+\s*\]',
        caseSensitive: false,
      ),
      '',
    );
    title = title.replaceAll(RegExp(r'\(\d{4}\)'), '').trim();
    return title.isEmpty ? folder : title;
  }

  /// Repair older indexed episode numbers and supplemental file types in
  /// SQLite only; manually locked file relations are never touched.
  static Future<int> repairIndexedAssets(Database db) async {
    final lockedRows = await db.query('asset_overrides', columns: ['asset_id']);
    final locked = lockedRows.map((row) => row['asset_id']?.toString()).toSet();
    final rows = await db.query(
      'assets',
      columns: [
        'id',
        'name',
        'relative_path',
        'episode',
        'season',
        'category',
        'extra_type',
      ],
      where: "episode IS NULL OR (category='extra' AND extra_type IS NULL)",
    );
    var corrected = 0;
    for (final row in rows) {
      final id = row['id']?.toString();
      if (id == null || locked.contains(id)) continue;
      final name = row['name']?.toString() ?? '';
      final relative = row['relative_path']?.toString() ?? name;
      final updated = <String, Object?>{};
      final ep = row['episode'];
      if (ep == null) {
        final found = episode(name);
        if (found != null) updated['episode'] = found;
      }
      final extra = isExtra(relative);
      if (extra && row['category'] == 'main') {
        updated['category'] = 'extra';
        updated['season'] = 0;
      }
      if ((row['category'] == 'extra' || extra) && row['extra_type'] == null) {
        updated['extra_type'] = CloudMediaAssetPresentation.extraType({
          'name': name,
          'relative_path': relative,
        });
      }
      if (updated.isNotEmpty) {
        await db.update('assets', updated, where: 'id=?', whereArgs: [id]);
        corrected++;
      }
    }
    return corrected;
  }

  static bool isExtra(String name) {
    final path = name.replaceAll('\\', '/');
    return CloudMediaFileClassifier.isClearlySupplementary(
      p.posix.dirname(path),
      p.posix.basename(path),
    );
  }

  /// Derive season from folder / filename when possible; explicit manual
  /// assignment always takes precedence on re-scan.
  static int detectedSeason(String relative) {
    final path = relative.replaceAll('\\', '/');
    if (isExtra(path)) return 0;
    final explicit = CloudMediaAssetPresentation.explicitSeasonNumber({
      'relative_path': path,
    });
    if (explicit != null) return explicit;
    final matched = RegExp(
      r'(?:^|[/\\])(?:Season[ ._-]*|S)(\d{1,2})(?:[/\\]|[ ._-])',
      caseSensitive: false,
    ).firstMatch(path);
    if (matched != null) return int.tryParse(matched.group(1)!) ?? 1;
    final inFilename = RegExp(
      r'\bS(\d{1,2})E\d+\b',
      caseSensitive: false,
    ).firstMatch(p.basename(path));
    if (inFilename != null) return int.tryParse(inFilename.group(1)!) ?? 1;
    final chinese = RegExp(r'第(\d{1,2})季').firstMatch(path);
    if (chinese != null) return int.tryParse(chinese.group(1)!) ?? 1;
    return 1;
  }

  static int? episode(String name) =>
      CloudMediaFileClassifier.episodeNumberFromName(name);

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
    final manual = await db.query(
      'asset_overrides',
      where: 'asset_id=?',
      whereArgs: [assetId],
      limit: 1,
    );
    var targetWorkId = manual.isNotEmpty
        ? manual.first['work_id'].toString()
        : workId;
    if (manual.isEmpty &&
        existing.isNotEmpty &&
        existing.first['work_id'] != workId) {
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
        'tmdb_type': tmdbType(displayFolder),
        'needs_review': needsReview ? 1 : 0,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    // Temporary removal is reversed by a real subsequent scan. Persistent
    // hidden titles remain suppressed even while their assets are indexed.
    await db.update(
      'works',
      {'hidden': 0},
      where: 'id=? AND hidden=1 AND keep_hidden=0',
      whereArgs: [targetWorkId],
    );
    await db.insert('assets', {
      'id': assetId,
      'source_id': sourceId,
      'work_id': targetWorkId,
      'relative_path': normalized,
      'name': name,
      'episode': manual.isNotEmpty
          ? manual.first['episode']
          : CloudMediaFileClassifier.episodeNumberFromNameInDirectory(
              p.posix.dirname(normalized),
              name,
            ),
      'season': manual.isNotEmpty
          ? manual.first['season']
          : detectedSeason(normalized),
      'category': manual.isNotEmpty
          ? manual.first['category']
          : isExtra(normalized)
          ? 'extra'
          : 'main',
      'extra_type': manual.isNotEmpty
          ? manual.first['extra_type']
          : isExtra(normalized)
          ? CloudMediaAssetPresentation.extraType({
              'name': name,
              'relative_path': normalized,
            })
          : null,
      'size': size,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static String detailIdentity(Map<String, Object?> work) =>
      '${work['tmdb_type'] ?? 'tv'}:${work['tmdb_id'] ?? ''}|${work['bangumi_id'] ?? ''}';

  Future<Map<String, dynamic>?> readWorkDetails(
    Map<String, Object?> work,
  ) async {
    final found = await db.query(
      'work_details',
      where: 'work_id=?',
      whereArgs: [work['id']],
      limit: 1,
    );
    if (found.isEmpty || found.first['identity'] != detailIdentity(work)) {
      return null;
    }
    try {
      return jsonDecode(found.first['payload']!.toString())
          as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<DateTime?> detailFetchedAt(String workId) async {
    final rows = await db.query(
      'work_details',
      columns: ['fetched_at'],
      where: 'work_id=?',
      whereArgs: [workId],
      limit: 1,
    );
    return rows.isEmpty
        ? null
        : DateTime.tryParse(rows.first['fetched_at'].toString());
  }

  Future<void> saveWorkDetails(
    Map<String, Object?> work,
    Map<String, dynamic> payload,
  ) async {
    await db.insert('work_details', {
      'work_id': work['id'],
      'identity': detailIdentity(work),
      'payload': jsonEncode(payload),
      'fetched_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    notifyListeners();
  }

  Future<Map<String, Map<String, Object?>>> progressForWork(
    String workId,
  ) async {
    final found = await db.rawQuery(
      'SELECT progress.* FROM progress JOIN assets ON progress.asset_id=assets.id '
      'WHERE assets.work_id=?',
      [workId],
    );
    return {for (final row in found) row['asset_id'].toString(): row};
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

  /// Updating a work's descriptive fields does not touch asset relations,
  /// source files or playback history. It locks manual metadata edits.
  Future<void> updateWorkMetadata(
    String workId, {
    required String title,
    int? year,
    required String overview,
  }) async {
    if (title.trim().isEmpty) throw ArgumentError('作品标题不能为空');
    await db.update(
      'works',
      {
        'title': title.trim(),
        'year': year,
        'overview': overview.trim(),
        'manual_lock': 1,
        'needs_review': 0,
      },
      where: 'id=?',
      whereArgs: [workId],
    );
    await reload();
  }

  /// Select a cover independently of the metadata lock. Automatic scraping
  /// may refresh the provider posters but never replaces this manual choice.
  Future<void> setManualCover(
    String workId, {
    String? source,
    String? url,
  }) async {
    if (source != null && source != 'tmdb' && source != 'bangumi') {
      throw ArgumentError('封面来源只支持 TMDB 或 Bangumi');
    }
    if (source != null && (url == null || url.trim().isEmpty)) {
      throw ArgumentError('没有可用的封面图片');
    }
    await db.update(
      'works',
      {
        'manual_cover_source': source,
        'manual_cover_url': source == null ? null : url?.trim(),
      },
      where: 'id=?',
      whereArgs: [workId],
    );
    await reload();
  }

  static String? preferredPoster(Map<String, Object?> work) {
    for (final field in ['manual_cover_url', 'poster', 'poster_fallback']) {
      final value = work[field]?.toString().trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  /// NipaPlay-style metadata-only upsert. User-locked values, file relations,
  /// watched positions and the source path are never replaced by a scraper.
  Future<bool> applyScrapedWork(
    String workId,
    ScrapedWork scraped, {
    bool reloadAfter = true,
  }) async {
    final records = await db.query(
      'works',
      where: 'id=?',
      whereArgs: [workId],
      limit: 1,
    );
    if (records.isEmpty || records.single['manual_lock'] == 1) return false;
    final old = records.single;
    final poster = scraped.poster?.trim();
    final overview = scraped.overview?.trim();
    final update = <String, Object?>{
      'title': scraped.title.trim().isNotEmpty ? scraped.title : old['title'],
      'year': scraped.year ?? old['year'],
      'poster': poster != null && poster.isNotEmpty ? poster : old['poster'],
      'poster_fallback': scraped.bangumiPoster ?? old['poster_fallback'],
      'overview': overview != null && overview.isNotEmpty
          ? overview
          : old['overview'],
      'tmdb_id': scraped.tmdbId ?? old['tmdb_id'],
      'tmdb_type': scraped.tmdbType ?? old['tmdb_type'],
      'bangumi_id': scraped.bangumiId ?? old['bangumi_id'],
      'needs_review': 0,
    };
    await db.update(
      'works',
      update,
      where: 'id=? AND manual_lock=0',
      whereArgs: [workId],
    );
    if (reloadAfter) await reload();
    return true;
  }

  /// Save a reversible manual relation. Asset IDs and progress stay stable.
  Future<void> lockAssetRelation(
    String assetId, {
    required String workId,
    required String category,
    int? episode,
    int season = 1,
    String? extraType,
  }) async {
    if (category != 'main' && category != 'extra' && category != 'other') {
      throw ArgumentError('分类必须是正片、特典或其他');
    }
    if (season < 0) throw ArgumentError('季数不能为负数');
    if (episode != null && episode < 0) throw ArgumentError('集数不能为负数');
    final rows = await db.query(
      'assets',
      where: 'id=?',
      whereArgs: [assetId],
      limit: 1,
    );
    if (rows.isEmpty) throw StateError('文件不存在');
    final old = rows.single;
    if (!workId.startsWith('work:${old['source_id']}:')) {
      throw StateError('只能关联相同媒体源内的作品');
    }
    final work = await db.query(
      'works',
      where: 'id=?',
      whereArgs: [workId],
      limit: 1,
    );
    if (work.isEmpty) throw StateError('目标作品不存在');
    final saved = await db.query(
      'asset_overrides',
      where: 'asset_id=?',
      whereArgs: [assetId],
      limit: 1,
    );
    await db.transaction((tx) async {
      await tx.insert('asset_override_history', {
        'asset_id': assetId,
        'work_id': old['work_id'],
        'category': old['category'],
        'episode': old['episode'],
        'season': old['season'],
        'extra_type': old['extra_type'],
        'was_locked': saved.isNotEmpty ? 1 : 0,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await tx.insert('asset_overrides', {
        'asset_id': assetId,
        'work_id': workId,
        'category': category,
        'episode': episode,
        'season': season,
        'extra_type': category == 'extra' ? extraType : null,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await tx.update(
        'assets',
        {
          'work_id': workId,
          'category': category,
          'episode': episode,
          'season': season,
          'extra_type': category == 'extra' ? extraType : null,
        },
        where: 'id=?',
        whereArgs: [assetId],
      );
    });
    await reload();
  }

  Future<bool> undoAssetRelation(String assetId) async {
    final rows = await db.query(
      'asset_override_history',
      where: 'asset_id=?',
      whereArgs: [assetId],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    final row = rows.single;
    await db.transaction((tx) async {
      await tx.update(
        'assets',
        {
          'work_id': row['work_id'],
          'category': row['category'],
          'episode': row['episode'],
          'season': row['season'],
          'extra_type': row['extra_type'],
        },
        where: 'id=?',
        whereArgs: [assetId],
      );
      if (row['was_locked'] == 1) {
        await tx.insert('asset_overrides', {
          'asset_id': assetId,
          'work_id': row['work_id'],
          'category': row['category'],
          'episode': row['episode'],
          'season': row['season'],
          'extra_type': row['extra_type'],
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      } else {
        await tx.delete(
          'asset_overrides',
          where: 'asset_id=?',
          whereArgs: [assetId],
        );
      }
      await tx.delete(
        'asset_override_history',
        where: 'asset_id=?',
        whereArgs: [assetId],
      );
    });
    await reload();
    return true;
  }

  Future<Set<String>> lockedAssetIds() async {
    final rows = await db.query('asset_overrides', columns: ['asset_id']);
    return rows.map((r) => r['asset_id'].toString()).toSet();
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
