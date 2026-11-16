import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sq;

import '../../domain/models/tmdb_models.dart';
import 'photos_storage.dart';

/// 持久化内容寻址本地图片缓存（支持 `PhotosStorage` 分作品目录模式与独立目录兼容模式）。
///
/// 在全应用主流程中通过 [ArtworkCache.photos] 挂载至统一根目录 `<appRoot>/photos/`：
/// - 拥有明确 `ownerWorkId` 的图片按作品与类别落盘至
///   `photos/<作品名> [<tag>]/<posters|backdrops|logos|thumbnails>/`。
/// - 无归属的候选预览图（`owner == null`）仅保留在内存有界 LRU 中，绝不在磁盘建夹写入。
class ArtworkCache {
  /// 使用指定的缓存根目录创建独立图片缓存管理器（兼容纯临时目录单元测试）。
  ArtworkCache(
    this.root, {
    this.maxMemoryEntries = 64,
    this.maxMemoryBytes = 64 * 1024 * 1024,
  }) : _photosStorage = null;

  /// 使用统一 `photos/` 分作品目录存储后端创建缓存管理器（主应用唯一图片落盘通道）。
  ArtworkCache.photos(
    PhotosStorage photosStorage, {
    this.maxMemoryEntries = 64,
    this.maxMemoryBytes = 64 * 1024 * 1024,
  }) : _photosStorage = photosStorage,
       root = photosStorage.resolveRootDirectory();

  /// 缓存根目录。
  final Directory root;

  /// 内存缓存最大图片张数。
  final int maxMemoryEntries;

  /// 内存缓存总字节上限。
  final int maxMemoryBytes;

  static const int _maxSingleMemoryEntryBytes = 16 * 1024 * 1024;
  static const Set<String> _knownTiers = <String>{
    'w185',
    'w342',
    'w500',
    'w780',
    'w1280',
    'original',
  };

  final PhotosStorage? _photosStorage;
  sq.Database? _db;
  final LinkedHashMap<String, Uint8List> _memoryCache =
      LinkedHashMap<String, Uint8List>();
  int _currentMemoryBytes = 0;

  /// 图片二进制文件存储子目录（仅旧兼容模式使用）。
  Directory get imagesDir => Directory(p.join(root.path, 'images'));

  /// 计算 URL 或缓存键的 SHA-256 摘要。
  static String digest(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  /// 构建带尺寸档位隔离的标准 TMDB 图片缓存键（例如 `original_/abc.jpg` 与 `w500_/abc.jpg`）。
  static String buildSizedKey(TmdbImageSize size, String imagePath) {
    final trimmed = imagePath.trim();
    final normalized = trimmed.startsWith('/') ? trimmed : '/$trimmed';
    return '${size.name}_$normalized';
  }

  sq.Database _ensureOpen() {
    final existing = _db;
    if (existing != null) return existing;
    imagesDir.createSync(recursive: true);
    final db = sq.sqlite3.open(p.join(root.path, 'cache-index.sqlite'));
    db.execute(
      'CREATE TABLE IF NOT EXISTS images ('
      'key TEXT PRIMARY KEY, file TEXT NOT NULL, bytes INTEGER NOT NULL, quality INTEGER NOT NULL)',
    );
    db.execute(
      'CREATE TABLE IF NOT EXISTS owners ('
      'owner TEXT NOT NULL, key TEXT NOT NULL, PRIMARY KEY(owner, key))',
    );
    _db = db;
    return db;
  }

  void _putMemory(String key, Uint8List bytes) {
    if (bytes.isEmpty ||
        bytes.length > _maxSingleMemoryEntryBytes ||
        maxMemoryEntries <= 0 ||
        maxMemoryBytes <= 0) {
      return;
    }
    final existing = _memoryCache.remove(key);
    if (existing != null) {
      _currentMemoryBytes -= existing.length;
    }
    while ((_memoryCache.length >= maxMemoryEntries ||
            _currentMemoryBytes + bytes.length > maxMemoryBytes) &&
        _memoryCache.isNotEmpty) {
      final oldestKey = _memoryCache.keys.first;
      final removed = _memoryCache.remove(oldestKey);
      if (removed != null) {
        _currentMemoryBytes -= removed.length;
      }
    }
    _memoryCache[key] = bytes;
    _currentMemoryBytes += bytes.length;
  }

  Uint8List? _touchMemory(String key) {
    final hit = _memoryCache.remove(key);
    if (hit != null) {
      _memoryCache[key] = hit;
    }
    return hit;
  }

  static String _memoryKey(String key, String? owner, PhotoSubfolder? sub) {
    if (owner == null || owner.trim().isEmpty) return key;
    return '${owner.trim()}::${(sub ?? PhotoSubfolder.posters).dirName}::$key';
  }

  static String _keyToPhotoFileName(String key) {
    if (key.startsWith('url:')) {
      final rawUrl = key.substring(4);
      final uri = Uri.tryParse(rawUrl);
      final ext = _safeExt(uri?.path ?? rawUrl);
      return 'url_${PhotosStorage.shortDigest(rawUrl)}$ext';
    }
    final idx = key.indexOf('_');
    if (idx > 0 && idx < key.length - 1) {
      final tier = key.substring(0, idx).toLowerCase();
      if (_knownTiers.contains(tier)) {
        final rel = key.substring(idx + 1);
        final ext = _safeExt(rel);
        return '${tier}_${PhotosStorage.shortDigest(rel)}$ext';
      }
    }
    return 'raw_${PhotosStorage.shortDigest(key)}.jpg';
  }

  static String _safeExt(String pathOrUrl) {
    final rawExt = p.extension(pathOrUrl).toLowerCase();
    return switch (rawExt) {
      '.jpg' || '.jpeg' || '.png' || '.webp' || '.gif' || '.bmp' => rawExt,
      _ => '.jpg',
    };
  }

  /// 写入或更新缓存图片并关联所有者（同步更新内存 LRU 缓存）。
  Future<void> write(
    String key,
    Uint8List bytes, {
    String? owner,
    int quality = 0,
    PhotoSubfolder? subfolder,
  }) async {
    final photos = _photosStorage;
    if (photos != null) {
      final cleanOwner = owner?.trim();
      final memKey = _memoryKey(key, cleanOwner, subfolder);
      _putMemory(memKey, bytes);
      if (cleanOwner == null || cleanOwner.isEmpty) {
        // 无归属作品的搜索/匹配候选预览仅驻留内存有界 LRU，严禁落盘建夹。
        return;
      }
      await photos.writeArtwork(
        workId: cleanOwner,
        subfolder: subfolder ?? PhotoSubfolder.posters,
        fileKey: _keyToPhotoFileName(key),
        bytes: bytes,
      );
      return;
    }

    final db = _ensureOpen();
    final fileName = digest(key);
    final file = File(p.join(imagesDir.path, fileName));
    await file.writeAsBytes(bytes, flush: true);
    db.execute(
      'INSERT OR REPLACE INTO images (key, file, bytes, quality) VALUES (?, ?, ?, ?)',
      [key, fileName, bytes.length, quality],
    );
    if (owner != null && owner.isNotEmpty) {
      db.execute(
        'INSERT OR IGNORE INTO owners (owner, key) VALUES (?, ?)',
        [owner, key],
      );
    }
    _putMemory(key, bytes);
  }

  /// 读取满足最低质量分档要求的本地缓存图片字节（优先命中内存 LRU 缓存）。
  Future<Uint8List?> read(
    String key, {
    int minimumQuality = 0,
    String? owner,
    PhotoSubfolder? subfolder,
  }) async {
    final photos = _photosStorage;
    if (photos != null) {
      final cleanOwner = owner?.trim();
      final memKey = _memoryKey(key, cleanOwner, subfolder);
      final inMem = _touchMemory(memKey);
      if (inMem != null) return inMem;
      if (cleanOwner == null || cleanOwner.isEmpty) {
        return null;
      }
      final fromDisk = await photos.readArtwork(
        workId: cleanOwner,
        subfolder: subfolder ?? PhotoSubfolder.posters,
        fileKey: _keyToPhotoFileName(key),
        minimumQuality: minimumQuality,
      );
      if (fromDisk != null) {
        _putMemory(memKey, fromDisk);
      }
      return fromDisk;
    }

    final inMemory = _memoryCache[key];
    if (inMemory != null && minimumQuality <= 0) {
      _memoryCache.remove(key);
      _memoryCache[key] = inMemory;
      return inMemory;
    }

    final db = _ensureOpen();
    final rows = db.select(
      'SELECT file FROM images WHERE key = ? AND quality >= ? LIMIT 1',
      [key, minimumQuality],
    );
    if (rows.isEmpty) return null;

    if (inMemory != null) {
      _memoryCache.remove(key);
      _memoryCache[key] = inMemory;
      return inMemory;
    }

    final fileName = rows.first['file'] as String;
    final file = File(p.join(imagesDir.path, fileName));
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    _putMemory(key, bytes);
    return bytes;
  }

  /// 关闭底层 SQLite 连接并清空内存缓存。
  void close() {
    _memoryCache.clear();
    _currentMemoryBytes = 0;
    _db?.close();
    _db = null;
  }
}
