import 'tmdb_models.dart';

export 'package:konata_contracts/konata_contracts.dart'
    show ArtworkCacheStore, PhotoSubfolder;

/// 构建带尺寸档位隔离的标准 TMDB 图片缓存键。
String buildSizedArtworkCacheKey(TmdbImageSize size, String imagePath) {
  final trimmed = imagePath.trim();
  final normalized = trimmed.startsWith('/') ? trimmed : '/$trimmed';
  return '${size.name}_$normalized';
}
