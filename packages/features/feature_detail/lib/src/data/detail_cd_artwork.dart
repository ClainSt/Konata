import 'dart:typed_data';

import 'package:engine_playback/engine_playback.dart';
import 'package:engine_scraping/engine_scraping.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import 'main_episode_frame_extractor.dart';

/// 详情轨道与完整列表共享的封面读取接口。
typedef DetailCdCoverLoader =
    Future<Uint8List?> Function(MediaVariant variant, MediaSource source);

/// 缓存优先、按专辑目录去重且全局串行的只读封面加载。
class DetailCdArtworkService {
  DetailCdArtworkService({
    required this.databases,
    required this.photosStorage,
    required this.gatewayFactory,
  });

  final KonataDatabaseBundle databases;
  final PhotosStorage photosStorage;
  final MediaSourceGatewayFactoryPort gatewayFactory;
  final _pending = <String, Future<Uint8List?>>{};
  final _missedUntil = <String, DateTime>{};
  Future<void> _tail = Future<void>.value();

  Future<Uint8List?> load(MediaVariant variant, MediaSource source) {
    final path = variant.relativePath.replaceAll(r'\', '/');
    final slash = path.lastIndexOf('/');
    final dir = slash < 0 ? '.' : path.substring(0, slash);
    final key = 'detail_cd_album::${source.id}::$dir';
    final identity = '${variant.workId}::$key';
    final missedUntil = _missedUntil[identity];
    if (missedUntil != null && DateTime.now().isAfter(missedUntil)) {
      _pending.remove(identity);
      _missedUntil.remove(identity);
    }
    final existing = _pending[identity];
    if (existing != null) return existing;
    final future = _tail.then((_) => _load(variant, source, dir, key)).then((
      bytes,
    ) {
      if (bytes == null || bytes.isEmpty) {
        // 短期去重失败结果，允许后续页面重访时重新检测。
        _missedUntil[identity] = DateTime.now().add(
          const Duration(seconds: 30),
        );
        if (_missedUntil.length > 64) {
          _missedUntil.remove(_missedUntil.keys.first);
        }
      }
      return bytes;
    });
    _tail = future.then<void>((_) {}, onError: (Object _) {});
    _pending[identity] = future;
    if (_pending.length > 64) _pending.remove(_pending.keys.first);
    return future;
  }

  Future<Uint8List?> _load(
    MediaVariant variant,
    MediaSource source,
    String dir,
    String key,
  ) async {
    try {
      for (final cacheKey in [
        'cd_cover::${source.id}::$dir::${variant.id}',
        key,
      ]) {
        final cached = await photosStorage.readArtwork(
          workId: variant.workId,
          subfolder: PhotoSubfolder.thumbnails,
          cacheKey: cacheKey,
        );
        if (cached != null && cached.isNotEmpty) return cached;
      }
      final record = databases.library.mediaVariants.findById(
        VariantId.trusted(variant.id),
      );
      if (record == null) return null;
      final bytes = await AudioAssetExtractor.resolveAlbumCoverBytes(
        source: projectMediaSourceView(source),
        variant: record,
        gatewayFactory: gatewayFactory,
      );
      if (bytes != null && bytes.isNotEmpty) {
        try {
          await photosStorage.writeArtwork(
            workId: variant.workId,
            subfolder: PhotoSubfolder.thumbnails,
            cacheKey: key,
            bytes: bytes,
          );
        } catch (_) {}
      }
      return bytes;
    } catch (_) {
      return null;
    }
  }
}
