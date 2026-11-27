import 'dart:collection';
import 'dart:typed_data';

import 'package:konata_contracts/konata_contracts.dart';

import 'photos_storage.dart';

/// 基于 [PhotosStorage] 与有界内存 LRU 的纯 Dart 图片缓存实现（实现 [ArtworkCacheStore]）。
///
/// - 拥有明确归属作品（`owner`）且指定子目录的图片按作品目录落盘持久化；
/// - 无归属的候选预览图仅保留在有界内存中，绝不在磁盘建空文件夹。
final class ArtworkDiskCache implements RequestScopedArtworkCacheStore {
  /// 创建基于统一图片存储管理器的缓存实例。
  ArtworkDiskCache({
    required this.photosStorage,
    this.maxMemoryEntries = 96,
    this.maxMemoryBytes = 16 * 1024 * 1024,
  });

  /// 底层统一分作品目录存储管理器。
  final PhotosStorage photosStorage;

  /// 内存缓存最大条目数。
  final int maxMemoryEntries;

  /// 内存缓存总字节上限。
  final int maxMemoryBytes;

  static const int _maxSingleMemoryEntryBytes = 4 * 1024 * 1024;
  static const int _maxDiskBackedMemoryEntryBytes = 512 * 1024;

  final LinkedHashMap<String, ({int quality, Uint8List bytes})> _memory =
      LinkedHashMap<String, ({int quality, Uint8List bytes})>();
  int _memoryBytes = 0;
  int _memoryGeneration = 0;

  /// 当前内存缓存占用字节数。
  int get currentMemoryBytes => _memoryBytes;

  /// 当前内存缓存条目数。
  int get memoryEntryCount => _memory.length;

  /// 清空内存字节缓存（磁盘图片文件保持完好）。
  void clearMemoryCache() {
    _memoryGeneration++;
    _memory.clear();
    _memoryBytes = 0;
  }

  @override
  ArtworkCacheStore captureRequestScope() =>
      _ArtworkRequestScope(this, _memoryGeneration);

  @override
  Future<Uint8List?> read(
    String key, {
    int minimumQuality = 0,
    String? owner,
    PhotoSubfolder? subfolder,
  }) => _read(
    key,
    generation: _memoryGeneration,
    minimumQuality: minimumQuality,
    owner: owner,
    subfolder: subfolder,
  );

  Future<Uint8List?> _read(
    String key, {
    int minimumQuality = 0,
    String? owner,
    PhotoSubfolder? subfolder,
    required int generation,
  }) async {
    final memKey = _memoryKey(key, owner: owner, subfolder: subfolder);
    final hit = _memory.remove(memKey);
    if (hit != null) {
      _memory[memKey] = hit;
      if (hit.quality >= minimumQuality) {
        return hit.bytes;
      }
    }
    if (owner != null && owner.trim().isNotEmpty && subfolder != null) {
      final diskBytes = await photosStorage.readArtwork(
        workId: owner,
        subfolder: subfolder,
        cacheKey: key,
      );
      if (diskBytes != null && diskBytes.isNotEmpty) {
        // 清理前开始的读取可以返回结果，但不能重新占用内存预算。
        if (generation == _memoryGeneration &&
            diskBytes.length <= _maxDiskBackedMemoryEntryBytes) {
          _putMemory(memKey, diskBytes, quality: minimumQuality);
        }
        return diskBytes;
      }
    }
    return null;
  }

  @override
  Future<void> write(
    String key,
    Uint8List bytes, {
    String? owner,
    int quality = 0,
    PhotoSubfolder? subfolder,
  }) => _write(
    key,
    bytes,
    generation: _memoryGeneration,
    owner: owner,
    quality: quality,
    subfolder: subfolder,
  );

  Future<void> _write(
    String key,
    Uint8List bytes, {
    String? owner,
    int quality = 0,
    PhotoSubfolder? subfolder,
    required int generation,
  }) async {
    if (bytes.isEmpty) return;
    final memKey = _memoryKey(key, owner: owner, subfolder: subfolder);
    if (owner != null && owner.trim().isNotEmpty && subfolder != null) {
      await photosStorage.writeArtwork(
        workId: owner,
        subfolder: subfolder,
        cacheKey: key,
        bytes: bytes,
        extension: _detectImageExtension(bytes),
      );
      if (generation == _memoryGeneration &&
          bytes.length <= _maxDiskBackedMemoryEntryBytes) {
        _putMemory(memKey, bytes, quality: quality);
      }
      return;
    }
    if (generation == _memoryGeneration &&
        bytes.length <= _maxSingleMemoryEntryBytes) {
      _putMemory(memKey, bytes, quality: quality);
    }
  }

  @override
  Future<Uint8List?> readLocalWorkFile({
    required String owner,
    required PhotoSubfolder subfolder,
    required String fileName,
  }) {
    return photosStorage.readLocalWorkFile(
      workId: owner,
      subfolder: subfolder,
      fileName: fileName,
    );
  }

  String _memoryKey(String key, {String? owner, PhotoSubfolder? subfolder}) =>
      '${owner ?? ''}|${subfolder?.dirName ?? ''}|$key';

  void _putMemory(String key, Uint8List bytes, {required int quality}) {
    if (maxMemoryEntries <= 0 || maxMemoryBytes <= 0) return;
    final prev = _memory.remove(key);
    if (prev != null) {
      _memoryBytes -= prev.bytes.length;
    }
    while ((_memory.length >= maxMemoryEntries ||
            _memoryBytes + bytes.length > maxMemoryBytes) &&
        _memory.isNotEmpty) {
      final oldestKey = _memory.keys.first;
      final removed = _memory.remove(oldestKey);
      if (removed != null) {
        _memoryBytes -= removed.bytes.length;
      }
    }
    if (bytes.length <= maxMemoryBytes) {
      _memory[key] = (quality: quality, bytes: bytes);
      _memoryBytes += bytes.length;
    }
  }

  static String _detectImageExtension(Uint8List bytes) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return '.png';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return '.jpg';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return '.webp';
    }
    return '.bin';
  }
}

/// 绑定单次请求启动时的内存代次；磁盘写入仍然由底层统一完成。
final class _ArtworkRequestScope implements ArtworkCacheStore {
  _ArtworkRequestScope(this.cache, this.generation);

  final ArtworkDiskCache cache;
  final int generation;

  @override
  Future<Uint8List?> read(
    String key, {
    int minimumQuality = 0,
    String? owner,
    PhotoSubfolder? subfolder,
  }) => cache._read(
    key,
    generation: generation,
    minimumQuality: minimumQuality,
    owner: owner,
    subfolder: subfolder,
  );

  @override
  Future<void> write(
    String key,
    Uint8List bytes, {
    String? owner,
    int quality = 0,
    PhotoSubfolder? subfolder,
  }) => cache._write(
    key,
    bytes,
    generation: generation,
    owner: owner,
    quality: quality,
    subfolder: subfolder,
  );

  @override
  Future<Uint8List?> readLocalWorkFile({
    required String owner,
    required PhotoSubfolder subfolder,
    required String fileName,
  }) => cache.readLocalWorkFile(
    owner: owner,
    subfolder: subfolder,
    fileName: fileName,
  );
}
