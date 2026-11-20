import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path_util;

import '../../domain/models/managed_artwork.dart';
import '../../domain/models/media_source.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/models/tmdb_models.dart';
import '../../infrastructure/cache/photos_storage.dart';
import '../../infrastructure/cache/scan_thumbnail_scheduler.dart';
import '../../infrastructure/network/priority_http_scheduler.dart';
import '../../infrastructure/network/tmdb_http_client.dart';
import '../../infrastructure/network/tmdb_service.dart';
import '../../infrastructure/players/audio_art_extractor.dart';
import 'library_providers.dart';
import 'playback_providers.dart';
import 'scraping_providers.dart';

/// 图片尺寸与专辑封面内存 LRU 缓存容器（由 Riverpod 托管，消除顶层可变静态表）。
class ArtworkMemoryCaches {
  final Map<String, (int, int)> originalDimensions = {};
  final Map<String, Uint8List> audioAlbumCovers = {};
  final Map<String, Uint8List> audioDirAlbumCovers = {};
  final Set<String> missingLocalAlbumCoverKeys = {};
  final Set<String> missingDirAlbumCoverKeys = {};
  final Map<String, Future<Uint8List?>> _inFlightDirCoverLoads = {};
  Future<void> _remoteCoverSerialTail = Future<void>.value();

  /// 计算音频所属专辑目录的标准化共享缓存键（同目录所有曲目共享单张专辑封面）。
  static String dirKeyOf(String sourceId, String relativePath) {
    final normRel = relativePath.replaceAll('\\', '/');
    final dir = path_util.posix.dirname(normRel);
    final normalizedDir = dir == '.' ? '' : dir;
    return '$sourceId::$normalizedDir';
  }

  /// 生成用于 `<workPhotoDir>/thumbnails/` 的确定性专辑封面磁盘缓存文件名。
  static String albumCoverDiskFileKey(String sourceId, String relativePath) {
    final dirKey = dirKeyOf(sourceId, relativePath);
    return 'album_cover_${PhotosStorage.shortDigest(dirKey)}.bin';
  }

  /// 缓存图片原始像素尺寸，超限时按 FIFO 淘汰最早条目。
  void putOriginalDimensions(String key, (int, int) dims) {
    if (originalDimensions.length >= 512) {
      originalDimensions.remove(originalDimensions.keys.first);
    }
    originalDimensions[key] = dims;
  }

  /// 同步查询曲目级或目录级已缓存的专辑封面字节（0ms 命中）。
  Uint8List? findAudioAlbumCover({
    required String sourceId,
    required String relativePath,
    String? variantId,
  }) {
    final dirKey = dirKeyOf(sourceId, relativePath);
    if (variantId != null && variantId.isNotEmpty) {
      final exact = audioAlbumCovers['$dirKey::$variantId'];
      if (exact != null && exact.isNotEmpty) return exact;
    }
    final byDir = audioDirAlbumCovers[dirKey];
    if (byDir != null && byDir.isNotEmpty) return byDir;
    final dirPrefix = '$dirKey::';
    for (final entry in audioAlbumCovers.entries) {
      if (entry.key.startsWith(dirPrefix) && entry.value.isNotEmpty) {
        return entry.value;
      }
    }
    return null;
  }

  /// 缓存音频专辑封面字节（同步写入曲目键与目录共享键），超限时按 FIFO 淘汰最早条目。
  void putAudioAlbumCover(String key, Uint8List bytes) {
    if (bytes.isEmpty) return;
    if (audioAlbumCovers.length >= 64) {
      audioAlbumCovers.remove(audioAlbumCovers.keys.first);
    }
    missingLocalAlbumCoverKeys.remove(key);
    audioAlbumCovers[key] = bytes;
  }

  /// 写入专辑目录级共享封面（供详情页 CD 卡片、播放记录与全屏音频页三处互通）。
  void putAudioAlbumCoverForDir({
    required String sourceId,
    required String relativePath,
    required Uint8List bytes,
    String? variantId,
  }) {
    if (bytes.isEmpty) return;
    final dirKey = dirKeyOf(sourceId, relativePath);
    missingDirAlbumCoverKeys.remove(dirKey);
    if (audioDirAlbumCovers.length >= 64) {
      audioDirAlbumCovers.remove(audioDirAlbumCovers.keys.first);
    }
    audioDirAlbumCovers[dirKey] = bytes;
    if (variantId != null && variantId.isNotEmpty) {
      putAudioAlbumCover('$dirKey::$variantId', bytes);
    }
  }

  /// 标记本地音频条目暂无专属封面，避免列表滚动重复扫盘。
  void markMissingLocalAlbumCover(String key) {
    if (missingLocalAlbumCoverKeys.length >= 256) {
      missingLocalAlbumCoverKeys.remove(missingLocalAlbumCoverKeys.first);
    }
    missingLocalAlbumCoverKeys.add(key);
  }

  /// 标记整张专辑目录暂无专属封面，避免同专辑曲目重复发起远程探测。
  void markMissingDirAlbumCover(String dirKey) {
    if (missingDirAlbumCoverKeys.length >= 256) {
      missingDirAlbumCoverKeys.remove(missingDirAlbumCoverKeys.first);
    }
    missingDirAlbumCoverKeys.add(dirKey);
  }

  /// 对同一专辑目录执行单次去重（Single-Flight）封面提取，防止同专辑多张卡片并发重复请求。
  Future<Uint8List?> deduplicateDirCoverLoad(
    String dirKey,
    Future<Uint8List?> Function() loader,
  ) {
    final existing = _inFlightDirCoverLoads[dirKey];
    if (existing != null) return existing;
    final future = loader().whenComplete(() {
      _inFlightDirCoverLoads.remove(dirKey);
    });
    _inFlightDirCoverLoads[dirKey] = future;
    return future;
  }

  /// 严格单通道串行（并发 = 1）执行远程 WebDAV / SMB 专辑封面拉取，防止请求风暴。
  Future<T> runRemoteCoverSerial<T>(Future<T> Function() task) {
    final completer = Completer<T>();
    final prev = _remoteCoverSerialTail;
    _remoteCoverSerialTail = prev.whenComplete(() async {
      try {
        completer.complete(await task());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }
}

/// 图片与专辑封面内存缓存 Provider。
final artworkMemoryCachesProvider = Provider<ArtworkMemoryCaches>(
  (ref) => ArtworkMemoryCaches(),
);

/// 全局 Scan 微缩图隔离与三级按源并发调度器 Provider（复用全局 WebDAV 连接池，严守单向依赖）。
final scanThumbnailSchedulerProvider = Provider<ScanThumbnailScheduler>((ref) {
  final photos = ref.watch(photosStorageProvider);
  final gatewayFactory = ref.watch(mediaSourceGatewayFactoryProvider);
  final scheduler = ScanThumbnailScheduler(
    photosStorage: photos,
    gatewayFactory: gatewayFactory,
  );
  ref.onDispose(scheduler.dispose);
  return scheduler;
});

/// 从已获取的原始图片字节流直接读取文件头真实像素宽高（不解码整张位图）。
Future<(int, int)?> decodeImageDimensionsFromBytes(Uint8List bytes) async {
  if (bytes.isEmpty) return null;
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        if (descriptor.width <= 0 || descriptor.height <= 0) {
          return null;
        }
        return (descriptor.width, descriptor.height);
      } finally {
        descriptor.dispose();
      }
    } finally {
      buffer.dispose();
    }
  } catch (_) {
    return null;
  }
}

/// 异步解析原图（Bangumi / 本地磁盘 / 自定义 URL / TMDB original）真实像素宽高并缓存。
final artworkOriginalDimensionsProvider =
    FutureProvider.family<(int, int)?, String>((ref, pathOrUrl) async {
      final clean = pathOrUrl.trim();
      if (clean.isEmpty) return null;
      final caches = ref.read(artworkMemoryCachesProvider);
      final cached = caches.originalDimensions[clean];
      if (cached != null) return cached;

      final loader = ref.read(tmdbImageLoaderProvider);
      final bytes = await loader(clean, imageSize: TmdbImageSize.original);
      final dims = await decodeImageDimensionsFromBytes(bytes);
      if (dims != null) {
        caches.putOriginalDimensions(clean, dims);
      }
      return dims;
    });

PhotoSubfolder _mapArtworkToSubfolder(ManagedArtwork? artwork) {
  return switch (artwork) {
    ManagedArtwork.backdrop => PhotoSubfolder.backdrops,
    ManagedArtwork.logo => PhotoSubfolder.logos,
    ManagedArtwork.still => PhotoSubfolder.thumbnails,
    ManagedArtwork.poster || null => PhotoSubfolder.posters,
  };
}

/// 前台 UI 高优先级 TMDB 图片加载器 Provider（UI 层零 HTTP / IO 依赖）。
final tmdbImageLoaderProvider = Provider<ManagedImageLoader>((ref) {
  return bindManagedArtworkLoader((
    String pathOrUrl, {
    int? targetWidth,
    TmdbImageSize? imageSize,
    String? ownerWorkId,
    ManagedArtwork? artwork,
  }) async {
    if (pathOrUrl.isEmpty) {
      return Uint8List(0);
    }
    final config = await ref.read(tmdbNetworkConfigProvider.future);
    final scheduler = ref.read(priorityHttpSchedulerProvider);
    final cooldown = ref.read(domainCooldownRegistryProvider);
    final cache = await ref.read(artworkCacheProvider.future);
    final client = TmdbHttpClient(
      config: config,
      scheduler: scheduler,
      cooldownRegistry: cooldown,
    );
    final tmdb = TmdbService(httpClient: client, artworkCache: cache);
    return tmdb.fetchImageBytes(
      pathOrUrl,
      size: imageSize,
      targetWidth: targetWidth,
      ownerWorkId: ownerWorkId,
      subfolder: _mapArtworkToSubfolder(artwork),
      priority: RequestPriority.interactive,
    );
  });
});

/// 音频播放记录专属专辑封面异步加载器（优先内存与 `photos/` 磁盘缓存，未命中再查目录与内嵌封面）。
final audioRecordAlbumCoverProvider = FutureProvider.autoDispose
    .family<Uint8List?, ({String workId, String variantId})>((ref, args) async {
      if (args.variantId.trim().isEmpty) return null;
      final repo = ref.watch(libraryRepositoryProvider);
      final variants = await repo.getVariantsByWork(args.workId);
      MediaVariant? variant;
      for (final v in variants) {
        if (v.id == args.variantId) {
          variant = v;
          break;
        }
      }
      if (variant == null) return null;

      final sources = await repo.getMediaSources();
      MediaSource? source;
      for (final s in sources) {
        if (s.id == variant.sourceId) {
          source = s;
          break;
        }
      }
      if (source == null) return null;

      final caches = ref.read(artworkMemoryCachesProvider);
      final memHit = caches.findAudioAlbumCover(
        sourceId: source.id,
        relativePath: variant.relativePath,
        variantId: variant.id,
      );
      if (memHit != null) return memHit;

      final photos = ref.read(photosStorageProvider);
      final diskKey = ArtworkMemoryCaches.albumCoverDiskFileKey(
        source.id,
        variant.relativePath,
      );
      final diskHit = await photos.readArtwork(
        workId: args.workId,
        subfolder: PhotoSubfolder.thumbnails,
        fileKey: diskKey,
      );
      if (diskHit != null && diskHit.isNotEmpty) {
        caches.putAudioAlbumCoverForDir(
          sourceId: source.id,
          relativePath: variant.relativePath,
          variantId: variant.id,
          bytes: diskHit,
        );
        return diskHit;
      }

      final dirKey = ArtworkMemoryCaches.dirKeyOf(
        source.id,
        variant.relativePath,
      );
      final targetSource = source;
      final targetVariant = variant;
      final gatewayFactory = ref.read(mediaSourceGatewayFactoryProvider);
      final bytes = await caches.deduplicateDirCoverLoad(dirKey, () async {
        Future<Uint8List?> fetch() => AudioAssetExtractor.resolveAlbumCoverBytes(
          source: targetSource,
          variant: targetVariant,
          gatewayFactory: gatewayFactory,
        );
        return targetSource.kind == MediaSourceKind.local
            ? await fetch()
            : await caches.runRemoteCoverSerial(fetch);
      });
      if (bytes != null && bytes.isNotEmpty) {
        caches.putAudioAlbumCoverForDir(
          sourceId: targetSource.id,
          relativePath: targetVariant.relativePath,
          variantId: targetVariant.id,
          bytes: bytes,
        );
        unawaited(
          photos
              .writeArtwork(
                workId: args.workId,
                subfolder: PhotoSubfolder.thumbnails,
                fileKey: diskKey,
                bytes: bytes,
              )
              .catchError((_) => null),
        );
        return bytes;
      }
      return null;
    });

/// CD 卡片专辑封面安全加载器：
/// - 所有媒体源优先 0ms 命中内存缓存与 `photos/<作品>/thumbnails/` 本地磁盘缓存；
/// - 未命中时按专辑目录 Single-Flight 去重；远程 WebDAV / SMB 严格单通道串行（并发 = 1），
///   杜绝并发风暴并让同张专辑下全部曲目共享一次探测结果。
final cdCardAlbumCoverProvider = FutureProvider.autoDispose
    .family<Uint8List?, ({MediaSource source, MediaVariant variant})>((
      ref,
      args,
    ) async {
      final caches = ref.read(artworkMemoryCachesProvider);
      final dirKey = ArtworkMemoryCaches.dirKeyOf(
        args.source.id,
        args.variant.relativePath,
      );
      final memHit = caches.findAudioAlbumCover(
        sourceId: args.source.id,
        relativePath: args.variant.relativePath,
        variantId: args.variant.id,
      );
      if (memHit != null) return memHit;
      if (caches.missingDirAlbumCoverKeys.contains(dirKey)) {
        return null;
      }

      final photos = ref.read(photosStorageProvider);
      final diskKey = ArtworkMemoryCaches.albumCoverDiskFileKey(
        args.source.id,
        args.variant.relativePath,
      );
      final diskHit = await photos.readArtwork(
        workId: args.variant.workId,
        subfolder: PhotoSubfolder.thumbnails,
        fileKey: diskKey,
      );
      if (diskHit != null && diskHit.isNotEmpty) {
        caches.putAudioAlbumCoverForDir(
          sourceId: args.source.id,
          relativePath: args.variant.relativePath,
          variantId: args.variant.id,
          bytes: diskHit,
        );
        return diskHit;
      }

      final gatewayFactory = ref.read(mediaSourceGatewayFactoryProvider);
      final bytes = await caches.deduplicateDirCoverLoad(dirKey, () async {
        final again = caches.findAudioAlbumCover(
          sourceId: args.source.id,
          relativePath: args.variant.relativePath,
          variantId: args.variant.id,
        );
        if (again != null) return again;
        Future<Uint8List?> fetch() => AudioAssetExtractor.resolveAlbumCoverBytes(
          source: args.source,
          variant: args.variant,
          gatewayFactory: gatewayFactory,
        );
        return args.source.kind == MediaSourceKind.local
            ? await fetch()
            : await caches.runRemoteCoverSerial(fetch);
      });
      if (bytes != null && bytes.isNotEmpty) {
        caches.putAudioAlbumCoverForDir(
          sourceId: args.source.id,
          relativePath: args.variant.relativePath,
          variantId: args.variant.id,
          bytes: bytes,
        );
        unawaited(
          photos
              .writeArtwork(
                workId: args.variant.workId,
                subfolder: PhotoSubfolder.thumbnails,
                fileKey: diskKey,
                bytes: bytes,
              )
              .catchError((_) => null),
        );
        return bytes;
      }
      caches.markMissingDirAlbumCover(dirKey);
      return null;
    });
