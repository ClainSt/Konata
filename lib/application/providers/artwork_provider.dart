import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path_util;

import '../../domain/models/media_source.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/models/tmdb_models.dart';
import '../../infrastructure/cache/photos_storage.dart';
import '../../infrastructure/network/priority_http_scheduler.dart';
import '../../infrastructure/network/tmdb_http_client.dart';
import '../../infrastructure/network/tmdb_service.dart';
import '../../infrastructure/players/audio_art_extractor.dart';
import '../../presentation/widgets/managed_image.dart';
import 'library_providers.dart';
import 'playback_providers.dart';
import 'scraping_providers.dart';

final Map<String, (int, int)> _originalDimensionCache = {};
final Map<String, Uint8List> _audioAlbumCoverMemoryCache = {};

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
      final cached = _originalDimensionCache[clean];
      if (cached != null) return cached;

      final loader = ref.read(tmdbImageLoaderProvider);
      final bytes = await loader(clean, imageSize: TmdbImageSize.original);
      final dims = await decodeImageDimensionsFromBytes(bytes);
      if (dims != null) {
        if (_originalDimensionCache.length >= 512) {
          _originalDimensionCache.remove(_originalDimensionCache.keys.first);
        }
        _originalDimensionCache[clean] = dims;
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
    final cache = await ref.read(artworkCacheProvider.future);
    final client = TmdbHttpClient(config: config, scheduler: scheduler);
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
      final cached = _audioAlbumCoverMemoryCache[cacheKey];
      if (cached != null) return cached;

      final gatewayFactory = ref.read(mediaSourceGatewayFactoryProvider);
      final bytes = await AudioAssetExtractor.resolveAlbumCoverBytes(
        source: source,
        variant: variant,
        gatewayFactory: gatewayFactory,
      );
      if (bytes != null && bytes.isNotEmpty) {
        if (_audioAlbumCoverMemoryCache.length >= 64) {
          _audioAlbumCoverMemoryCache.remove(
            _audioAlbumCoverMemoryCache.keys.first,
          );
        }
        _audioAlbumCoverMemoryCache[cacheKey] = bytes;
        return bytes;
      }
      return null;
    });
