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
  List<Map<String, Object?>> sources = [], works = [], assets = [];
  bool scanning = false;
  String status = '就绪';

  Future<void> initialize() async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    final folder = await getApplicationSupportDirectory();
    await folder.create(recursive: true);
    db = await openDatabase(p.join(folder.path, 'ccplayer.db'), version: 1,
      onCreate: (db, version) async {
        await db.execute('CREATE TABLE sources (id TEXT PRIMARY KEY, kind TEXT NOT NULL, label TEXT NOT NULL, location TEXT NOT NULL, username TEXT, password TEXT)');
        await db.execute('CREATE TABLE works (id TEXT PRIMARY KEY, title TEXT NOT NULL, year INTEGER, tmdb_id INTEGER, tmdb_type TEXT, bangumi_id INTEGER, poster TEXT, overview TEXT, manual_lock INTEGER NOT NULL DEFAULT 0)');
        await db.execute('CREATE TABLE assets (id TEXT PRIMARY KEY, source_id TEXT NOT NULL, work_id TEXT NOT NULL, relative_path TEXT NOT NULL, name TEXT NOT NULL, episode INTEGER, category TEXT NOT NULL, size INTEGER, UNIQUE(source_id,relative_path))');
        await db.execute('CREATE TABLE progress (asset_id TEXT PRIMARY KEY, position_ms INTEGER NOT NULL, duration_ms INTEGER NOT NULL, completed INTEGER NOT NULL, updated_at TEXT NOT NULL)');
        await db.execute('CREATE INDEX assets_by_work ON assets(work_id)');
      });
    // Migrate passwords previously kept in the early development SQLite schema.
    final previous = await db.query('sources', columns:['id','password']);
    for (final entry in previous) {
      final oldPassword = entry['password']?.toString() ?? '';
      if (oldPassword.isNotEmpty) {
        await _secrets.write(key:'webdav:'+entry['id'].toString(),value:oldPassword);
        await db.update('sources',{'password':null},where:'id=?',whereArgs:[entry['id']]);
      }
    }
    await reload();
  }

  Future<void> reload() async {
    sources = await db.query('sources', orderBy: 'label');
    works = await db.query('works', orderBy: 'title COLLATE NOCASE');
    assets = await db.query('assets', orderBy: 'episode, name');
    notifyListeners();
  }
  void updateStatus(String message, [bool active = false]) {
    status = message; scanning = active; notifyListeners();
  }
  Future<String> addSource(String type, String name, String location,
      {String username = '', String password = ''}) async {
    final id = 'src-${DateTime.now().microsecondsSinceEpoch}';
    await db.insert('sources', {'id': id, 'kind': type, 'label': name,
      'location': location, 'username': username, 'password': null});
    if (password.isNotEmpty) await _secrets.write(key:'webdav:$id',value:password);
    await reload(); return id;
  }
  Future<Map<String,Object?>> withCredentials(Map<String,Object?> source) async => {
    ...source,
    'password': (await _secrets.read(key:'webdav:${source['id']}')) ?? '',
  };
  Future<void> removeSource(String sourceId) async {
    await _secrets.delete(key:'webdav:$sourceId');
    await db.transaction((txn) async {
      await txn.delete('assets', where: 'source_id=?', whereArgs: [sourceId]);
      await txn.delete('sources', where: 'id=?', whereArgs: [sourceId]);
      await txn.rawDelete('DELETE FROM works WHERE manual_lock=0 AND id NOT IN (SELECT DISTINCT work_id FROM assets)');
    });
    await reload();
  }

  static const videoExtensions = {'.mkv','.mp4','.avi','.m2ts','.ts','.webm','.mov'};
  static const subtitleExtensions = {'.ass','.ssa','.srt','.vtt'};
  static bool isVideo(String name) => videoExtensions.contains(p.extension(name).toLowerCase());
  static bool isSubtitle(String name) => subtitleExtensions.contains(p.extension(name).toLowerCase());
  static int? tmdbId(String title) => int.tryParse(RegExp(r'\{tmdb-(\d+)\}', caseSensitive:false).firstMatch(title)?.group(1) ?? '');
  static int? year(String title) => int.tryParse(RegExp(r'\((19\d\d|20\d\d)\)').firstMatch(title)?.group(1) ?? '');
  static String cleanTitle(String folder) {
    var title=folder.replaceAll(RegExp(r'\{tmdb-\d+\}',caseSensitive:false),'');
    title=title.replaceAll(RegExp(r'\(\d{4}\)'),'').trim();
    return title.isEmpty ? folder : title;
  }
  static bool isExtra(String name) => RegExp(r'(^|[/\\])(SPs?|Extra|Bonus|NCOP|NCED|PV)([/\\]|$)',caseSensitive:false).hasMatch(name) ||
    RegExp(r'(NCOP|NCED|Trailer|Preview|PV\d+|CM\d+)',caseSensitive:false).hasMatch(p.basename(name));
  static int? episode(String name) {
    final stem=p.basenameWithoutExtension(name);
    for(final re in [
      RegExp(r'[Ss]\d{1,2}[Ee](\d{1,3})'),
      RegExp(r'(?<![A-Za-z0-9])(?:EP|Episode|E)[\s._#-]?(\d{1,3})\b',caseSensitive:false),
      RegExp(r'^\[(\d{1,3})\]'),
      RegExp(r'[#＃](\d{1,3})\b'),
      RegExp(r'\s[-–]\s(\d{1,3})(?=\s|[([]|$)'),
      RegExp(r'^(\d{1,3})(?=$|[._\[(])')
    ]) {
      final match=re.firstMatch(stem);if(match!=null)return int.tryParse(match.group(1)!);
    }
    return null;
  }
  Future<void> indexVideo(String sourceId,String relative,int? size) async {
    final normalized=relative.replaceAll('\\','/');
    final name=p.posix.basename(normalized);
    final segments=p.posix.split(normalized);
    if(segments.length<2 || !isVideo(name))return;
    final folder=segments.first;
    if(RegExp(r'^(CDs?|Scans?)$',caseSensitive:false).hasMatch(folder))return;
    final workId='work:$sourceId:${Uri.encodeComponent(folder)}';
    await db.insert('works', {'id':workId,'title':cleanTitle(folder),
      'year':year(folder),'tmdb_id':tmdbId(folder),
      'tmdb_type':tmdbId(folder)==null?null:'tv'},
      conflictAlgorithm:ConflictAlgorithm.ignore);
    await db.insert('assets',{'id':'asset:$sourceId:${Uri.encodeComponent(normalized)}',
      'source_id':sourceId,'work_id':workId,'relative_path':normalized,
      'name':name,'episode':episode(name),'category':isExtra(normalized)?'extra':'main',
      'size':size},conflictAlgorithm:ConflictAlgorithm.replace);
  }
  Future<void> bind(String workId,{required String provider,required int providerId,
      required String title,int? year,String? poster,String? overview,String type='tv'}) async {
    final old=works.firstWhere((w)=>w['id']==workId);
    await db.update('works',{
      'title':title,'year':year??old['year'],'poster':poster??old['poster'],
      'overview':overview??old['overview'],'manual_lock':1,
      if(provider=='tmdb')...{'tmdb_id':providerId,'tmdb_type':type},
      if(provider=='bangumi')'bangumi_id':providerId,
    },where:'id=?',whereArgs:[workId]);
    await reload();
  }
  Future<void> progress(String assetId,int position,int duration) async {
    await db.insert('progress',{'asset_id':assetId,'position_ms':position,
      'duration_ms':duration,'completed':duration>0&&position/duration>0.92?1:0,
      'updated_at':DateTime.now().toUtc().toIso8601String()},
      conflictAlgorithm:ConflictAlgorithm.replace);
  }
  Future<int> resumePosition(String assetId) async {
    final rows=await db.query('progress',where:'asset_id=?',whereArgs:[assetId],limit:1);
    return rows.isEmpty?0:(rows.first['position_ms'] as int? ?? 0);
  }
  List<Map<String,Object?>> forWork(String id) => assets.where((a)=>a['work_id']==id).toList();
  Map<String,Object?> sourceOf(String id) => sources.firstWhere((s)=>s['id']==id);
}
