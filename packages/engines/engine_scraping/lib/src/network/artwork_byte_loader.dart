import 'dart:async';
import 'dart:typed_data';

import 'package:konata_contracts/konata_contracts.dart';

import '../models/tmdb_models.dart';
import 'tmdb_service.dart';

/// 读取托管艺术图的编码字节。
typedef ArtworkByteLoader =
    Future<Uint8List?> Function(
      String path, {
      int targetWidth,
      TmdbImageSize imageSize,
      String? ownerWorkId,
      PhotoSubfolder? subfolder,
    });

/// 通过同一个缓存和受控网络客户端加载艺术图，并复用相同的并发请求。
ArtworkByteLoader createArtworkByteLoader({
  required KonataHttpClientPort httpClient,
  required ArtworkCacheStore artworkCache,
}) {
  final tmdb = TmdbService(httpClient: httpClient, artworkCache: artworkCache);
  // 仅合并进行中的同一艺术图请求；作品、子目录及实际请求档位必须一致。
  final inFlight =
      <
        ({
          String path,
          TmdbImageSize size,
          String? owner,
          PhotoSubfolder? folder,
        }),
        Future<Uint8List?>
      >{};
  return (
    String path, {
    int targetWidth = 384,
    TmdbImageSize imageSize = TmdbImageSize.w500,
    String? ownerWorkId,
    PhotoSubfolder? subfolder,
  }) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return null;
    // 显式档位决定编码图片的请求尺寸，解码宽度仍由各自的图片组件控制。
    final key = (
      path: trimmed,
      size: imageSize,
      owner: ownerWorkId,
      folder: subfolder,
    );
    final running = inFlight[key];
    if (running != null) return running;
    Future<Uint8List?> fetch() async {
      try {
        final fetched = await tmdb.fetchImageBytes(
          trimmed,
          size: imageSize,
          targetWidth: targetWidth,
          ownerWorkId: ownerWorkId,
          subfolder: subfolder,
          priority: RequestPriority.interactive,
        );
        return fetched.isNotEmpty ? fetched : null;
      } catch (_) {
        return null;
      }
    }

    final future = fetch();
    inFlight[key] = future;
    try {
      return await future;
    } finally {
      if (identical(inFlight[key], future)) {
        // 此处移除的任务已在上方等待完成，无需再次等待。
        unawaited(inFlight.remove(key));
      }
    }
  };
}
