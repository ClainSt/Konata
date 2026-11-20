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
  final Set<String> missingLocalAlbumCoverKeys = {};

  /// 缓存图片原始像素尺寸，超限时按 FIFO 淘汰最早条目。
  void putOriginalDimensions(String key, (int, int) dims) {
    if (originalDimensions.length >= 512) {
      originalDimensions.remove(originalDimensions.keys.first);
    }
    originalDimensions[key] = dims;
  }

  /// 缓存音频专辑封面字节，超限时按 FIFO 淘汰最早条目。
  void putAudioAlbumCover(String key, Uint8List bytes) {
    if (audioAlbumCovers.length >= 64) {
      audioAlbumCovers.remove(audioAlbumCovers.keys.first);
    }
    missingLocalAlbumCoverKeys.remove(key);
    audioAlbumCovers[key] = bytes;
  }

  /// 标记本地音频条目暂无专属封面，避免列表滚动重复扫盘。
  void markMissingLocalAlbumCover(String key) {
    if (missingLocalAlbumCoverKeys.length >= 256) {
      missingLocalAlbumCoverKeys.remove(missingLocalAlbumCoverKeys.first);
    }
    missingLocalAlbumCoverKeys.add(key);
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

/// 音频播放记录专属专辑封面异步加载器（优先目录 Folder/Cover，其次内嵌 CD 封面；无专属图返回 `null`）。
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

      final dir = path_util.posix.dirname(
        variant.relativePath.replaceAll('\\', '/'),
      );
      final cacheKey = '${source.id}::${dir == '.' ? '' : dir}::${variant.id}';
      final caches = ref.read(artworkMemoryCachesProvider);
      final cached = caches.audioAlbumCovers[cacheKey];
      if (cached != null) return cached;

      final gatewayFactory = ref.read(mediaSourceGatewayFactoryProvider);
      final bytes = await AudioAssetExtractor.resolveAlbumCoverBytes(
        source: source,
        variant: variant,
        gatewayFactory: gatewayFactory,
      );
      if (bytes != null && bytes.isNotEmpty) {
        caches.putAudioAlbumCover(cacheKey, bytes);
        return bytes;
      }
      return null;
    });

/// CD 卡片专辑封面安全加载器：
/// - 所有媒体源优先零开销命中内存缓存；
/// - 仅对本地磁盘源按需读取目录封面或内嵌封面，严禁向 WebDAV / SMB 发起列表探测风暴。
final cdCardAlbumCoverProvider = FutureProvider.autoDispose
    .family<Uint8List?, ({MediaSource source, MediaVariant variant})>((
      ref,
      args,
    ) async {
      final dir = path_util.posix.dirname(
        args.variant.relativePath.replaceAll('\\', '/'),
      );
      final normalizedDir = dir == '.' ? '' : dir;
      final cacheKey = '${args.source.id}::$normalizedDir::${args.variant.id}';
      final dirPrefix = '${args.source.id}::$normalizedDir::';
      final caches = ref.read(artworkMemoryCachesProvider);
      final exact = caches.audioAlbumCovers[cacheKey];
      if (exact != null && exact.isNotEmpty) return exact;
      // 复用同目录已缓存封面（同张专辑各曲目共享目录封面，零重复 IO）
      for (final entry in caches.audioAlbumCovers.entries) {
        if (entry.key.startsWith(dirPrefix) && entry.value.isNotEmpty) {
          return entry.value;
        }
      }
      if (args.source.kind != MediaSourceKind.local) {
        return null;
      }
      if (caches.missingLocalAlbumCoverKeys.contains(cacheKey)) {
        return null;
      }
      final gatewayFactory = ref.read(mediaSourceGatewayFactoryProvider);
      final bytes = await AudioAssetExtractor.resolveAlbumCoverBytes(
        source: args.source,
        variant: args.variant,
        gatewayFactory: gatewayFactory,
      );
      if (bytes != null && bytes.isNotEmpty) {
        caches.putAudioAlbumCover(cacheKey, bytes);
        return bytes;
      }
      caches.markMissingLocalAlbumCover(cacheKey);
      return null;
    });
