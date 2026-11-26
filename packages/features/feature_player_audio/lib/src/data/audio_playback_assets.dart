import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:engine_playback/engine_playback.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';
import 'package:path/path.dart' as p;

import 'audio_playback_models.dart';
import 'smart_cover_alignment.dart';

/// 曲目辅助资产（封面与随附/内嵌歌词文本）解析结果。
class ResolvedTrackAuxiliaryResult {
  /// 构造曲目辅助资产解析结果。
  const ResolvedTrackAuxiliaryResult({
    required this.cover,
    this.coverBytes,
    this.coverCacheKey,
    this.extractedLyricsText,
    this.siblings = const [],
  });

  /// 对外渲染用封面源对象。
  final AudioCoverSource cover;

  /// 若存在本地或内嵌可用封面字节，透传供流光配色与构图裁剪使用。
  final Uint8List? coverBytes;

  /// 封面对应的确定性缓存键（供色板与构图裁剪去重）。
  final String? coverCacheKey;

  /// 若探测到随附 `.lrc` 或内嵌歌词，以标准 LRC 或纯文本透传给歌词端口。
  final String? extractedLyricsText;

  /// 同目录扫描缓存（用于下一次切歌避免重复目录枚举）。
  final List<RemoteEntry> siblings;
}

/// 专辑封面与音频附属资源管理服务（零状态框架依赖）。
///
/// 遵循三级封面回退序：`内嵌音频封面` -> `专辑目录封面` -> `作品托管海报 / 空占位`，
/// 并通过内存 LRU 与可选 `PhotosStorage` 磁盘缓存避免反复跨网关读取字节流。
class AudioPlaybackAssets {
  /// 未命中本机海报时使用宿主已有的受管图片加载器。
  AudioPlaybackAssets({this.posterLoader});

  final Future<Uint8List?> Function(String path, String workId)? posterLoader;
  final Map<String, Future<Uint8List?>> _posterCropsInFlight = {};

  /// 内存 LRU 上限，单张图片控制在千字节级缩略/原始封面内。
  static const int maxMemoryCacheEntries = 48;

  final LinkedHashMap<String, Uint8List> _coverMemoryCache = LinkedHashMap();
  final Map<String, List<RemoteEntry>> _dirSiblingsCache = {};
  final Map<String, Future<ResolvedTrackAuxiliaryResult>> _inFlightAuxiliary =
      {};

  /// 构建或读取指定曲目的封面与内嵌/随附歌词资源。
  Future<ResolvedTrackAuxiliaryResult> resolveTrackAuxiliary({
    required AudioQueueItem item,
    required MediaSourceGatewayFactoryPort gatewayFactory,
    PhotosStorage? photosStorage,
    ArtworkCacheStore? artworkCacheStore,
    bool probeLyrics = true,
  }) {
    final memKey = _buildCoverMemoryKey(item);
    final inflightKey = '$memKey#lyrics:$probeLyrics';
    final pending = _inFlightAuxiliary[inflightKey];
    if (pending != null) return pending;

    final future =
        _resolveInternal(
          item: item,
          memKey: memKey,
          gatewayFactory: gatewayFactory,
          photosStorage: photosStorage,
          artworkCacheStore: artworkCacheStore,
          probeLyrics: probeLyrics,
        ).whenComplete(() {
          _inFlightAuxiliary.remove(inflightKey);
        });
    _inFlightAuxiliary[inflightKey] = future;
    return future;
  }

  /// 读取并在需要时将作品托管海报或本地自定义图片字节拉入内存，用于无法直接展示网络图时的兜底。
  Future<Uint8List?> resolveManagedPosterBytes({
    required AudioQueueItem item,
    PhotosStorage? photosStorage,
    ArtworkCacheStore? artworkCacheStore,
  }) async {
    final posterRef = item.posterRef;
    if (posterRef is LocalCustomArtworkRef) {
      final path = posterRef.localPath.trim();
      if (path.isNotEmpty) {
        try {
          final file = File(path);
          if (file.existsSync()) {
            final bytes = await file.readAsBytes();
            if (bytes.isNotEmpty) return bytes;
          }
        } catch (_) {}
      }
      if (photosStorage != null && path.isNotEmpty) {
        try {
          final bytes = await photosStorage.readLocalWorkFile(
            workId: item.workId.value,
            subfolder: PhotoSubfolder.posters,
            fileName: p.basename(path),
          );
          if (bytes != null && bytes.isNotEmpty) return bytes;
        } catch (_) {}
      }
    }
    if (posterRef is RemoteArtworkRef && artworkCacheStore != null) {
      try {
        final bytes = await artworkCacheStore.read(
          posterRef.uri,
          owner: item.workId.value,
          subfolder: PhotoSubfolder.posters,
        );
        if (bytes != null && bytes.isNotEmpty) return bytes;
      } catch (_) {}
    }
    if (photosStorage != null && posterRef is RemoteArtworkRef) {
      try {
        final bytes = await photosStorage.readArtwork(
          workId: item.workId.value,
          subfolder: PhotoSubfolder.posters,
          cacheKey: posterRef.uri,
        );
        if (bytes != null && bytes.isNotEmpty) return bytes;
      } catch (_) {}
    }
    final fallback = item.posterFallback?.trim() ?? '';
    if (fallback.isNotEmpty) {
      try {
        final file = File(fallback);
        if (file.existsSync()) {
          final bytes = await file.readAsBytes();
          if (bytes.isNotEmpty) return bytes;
        }
      } catch (_) {}
    }
    final loader = posterLoader;
    if (loader != null) {
      final candidates = <String>{
        if (posterRef is RemoteArtworkRef) posterRef.uri,
        if (fallback.isNotEmpty) fallback,
      };
      for (final candidate in candidates) {
        final uri = Uri.tryParse(candidate);
        if (uri == null ||
            (uri.hasScheme && uri.scheme != 'http' && uri.scheme != 'https')) {
          continue;
        }
        try {
          final bytes = await loader(candidate, item.workId.value);
          if (bytes != null && bytes.isNotEmpty) return bytes;
        } catch (_) {}
      }
    }
    return null;
  }

  /// 加载并解析 `.cue` 清单文件（自动使用 Windows 本地代码页回退以兼容日语/中文旧清单）。
  Future<CueSheet?> loadCueSheet({
    required MediaSourceView source,
    required String cueRelativePath,
    required MediaSourceGatewayFactoryPort gatewayFactory,
    int? knownFileSize,
  }) {
    return AudioAssetExtractor.loadCueSheet(
      source: source,
      cueRelativePath: cueRelativePath,
      gatewayFactory: gatewayFactory,
      knownFileSize: knownFileSize,
      legacyDecoder: Platform.isWindows ? WindowsCodePageDecoder.decode : null,
    );
  }

  /// 清空内存图片与目录项缓存。
  void clearCaches() {
    _coverMemoryCache.clear();
    _dirSiblingsCache.clear();
  }

  Future<ResolvedTrackAuxiliaryResult> _resolveInternal({
    required AudioQueueItem item,
    required String memKey,
    required MediaSourceGatewayFactoryPort gatewayFactory,
    PhotosStorage? photosStorage,
    ArtworkCacheStore? artworkCacheStore,
    required bool probeLyrics,
  }) async {
    var cachedCover = _peekMemory(memKey);
    if (cachedCover == null && photosStorage != null) {
      try {
        cachedCover = await photosStorage.readArtwork(
          workId: item.workId.value,
          subfolder: PhotoSubfolder.thumbnails,
          cacheKey: memKey,
          title: item.album,
        );
        if (cachedCover != null && cachedCover.isNotEmpty) {
          _putMemory(memKey, cachedCover);
        }
      } catch (_) {}
    }

    final needNetworkProbe = cachedCover == null || probeLyrics;
    String? extractedLyrics;
    List<RemoteEntry> siblings = const [];

    if (needNetworkProbe &&
        p.extension(item.relativePath).toLowerCase() != '.cue') {
      final dirKey = _buildDirCacheKey(item);
      final cachedSiblings = _dirSiblingsCache[dirKey];
      try {
        final aux = await AudioAssetExtractor.loadTrackAuxiliaryAssets(
          source: item.source,
          variant: item.variant,
          gatewayFactory: gatewayFactory,
          cueTrackTitle: item.cueTrackTitle,
          probeEmbeddedCover: cachedCover == null,
          probeEmbeddedLyrics: probeLyrics,
          probeFolderCover: cachedCover == null,
          cachedSiblings: cachedSiblings,
          legacyDecoder: Platform.isWindows
              ? WindowsCodePageDecoder.decode
              : null,
        );
        siblings = aux.siblings ?? const [];
        if (siblings.isNotEmpty) {
          _dirSiblingsCache[dirKey] = siblings;
        }
        final resolvedBytes = aux.embeddedCover ?? aux.folderCover;
        if (cachedCover == null &&
            resolvedBytes != null &&
            resolvedBytes.isNotEmpty) {
          cachedCover = resolvedBytes;
          _putMemory(memKey, resolvedBytes);
          if (photosStorage != null) {
            try {
              await photosStorage.writeArtwork(
                workId: item.workId.value,
                subfolder: PhotoSubfolder.thumbnails,
                cacheKey: memKey,
                bytes: resolvedBytes,
                extension: _guessImageExtension(resolvedBytes),
                title: item.album,
              );
            } catch (_) {}
          }
        }
        if (probeLyrics) {
          extractedLyrics = _formatLyricsForPort(
            aux.lrc,
            aux.embeddedPlainLyrics,
          );
        }
      } catch (_) {}
    }

    if (cachedCover != null && cachedCover.isNotEmpty) {
      return ResolvedTrackAuxiliaryResult(
        cover: MemoryAudioCover(cachedCover),
        coverBytes: cachedCover,
        coverCacheKey: memKey,
        extractedLyricsText: extractedLyrics,
        siblings: siblings,
      );
    }

    final fallbackPosterBytes = await resolveManagedPosterBytes(
      item: item,
      photosStorage: photosStorage,
      artworkCacheStore: artworkCacheStore,
    );
    if (fallbackPosterBytes != null && fallbackPosterBytes.isNotEmpty) {
      // 作品海报的内容变化与音轨专属封面分开缓存，不把衍生图写回原海报。
      final key =
          'poster-square::${item.workId.value}::${fallbackPosterBytes.length}::${Object.hashAll(fallbackPosterBytes)}';
      final square =
          _peekMemory(key) ??
          await (_posterCropsInFlight[key] ??=
              SmartCoverFraming.cropPosterToSquare(
                fallbackPosterBytes,
              ).whenComplete(() {
                _posterCropsInFlight.remove(key);
              }));
      if (square != null && square.isNotEmpty) {
        _putMemory(key, square);
        return ResolvedTrackAuxiliaryResult(
          cover: MemoryAudioCover(square),
          coverBytes: square,
          coverCacheKey: key,
          extractedLyricsText: extractedLyrics,
          siblings: siblings,
        );
      }
    }

    if (item.posterRef != null ||
        (item.posterFallback != null &&
            item.posterFallback!.trim().isNotEmpty)) {
      return ResolvedTrackAuxiliaryResult(
        cover: ManagedPosterAudioCover(
          artworkRef: item.posterRef,
          fallbackUrl: item.posterFallback,
        ),
        extractedLyricsText: extractedLyrics,
        siblings: siblings,
      );
    }

    return ResolvedTrackAuxiliaryResult(
      cover: const EmptyAudioCover(),
      extractedLyricsText: extractedLyrics,
      siblings: siblings,
    );
  }

  Uint8List? _peekMemory(String key) {
    final bytes = _coverMemoryCache.remove(key);
    if (bytes != null) {
      _coverMemoryCache[key] = bytes;
    }
    return bytes;
  }

  void _putMemory(String key, Uint8List bytes) {
    _coverMemoryCache.remove(key);
    if (_coverMemoryCache.length >= maxMemoryCacheEntries) {
      _coverMemoryCache.remove(_coverMemoryCache.keys.first);
    }
    _coverMemoryCache[key] = bytes;
  }

  static String _buildCoverMemoryKey(AudioQueueItem item) {
    final normDir = p.posix.dirname(item.relativePath.replaceAll('\\', '/'));
    return 'cd_cover::${item.sourceId.value}::$normDir::${item.variantId.value}';
  }

  static String _buildDirCacheKey(AudioQueueItem item) {
    final normDir = p.posix.dirname(item.relativePath.replaceAll('\\', '/'));
    return '${item.sourceId.value}::$normDir';
  }

  static String? _formatLyricsForPort(LrcDocument? lrc, String? plainText) {
    if (lrc != null && lrc.lines.isNotEmpty) {
      final buf = StringBuffer();
      for (final line in lrc.lines) {
        final totalMs = (line.startSeconds * 1000.0).round();
        final mm = (totalMs ~/ 60000).toString().padLeft(2, '0');
        final ss = ((totalMs % 60000) ~/ 1000).toString().padLeft(2, '0');
        final cc = ((totalMs % 1000) ~/ 10).toString().padLeft(2, '0');
        buf.writeln('[$mm:$ss.$cc]${line.primaryText}');
      }
      return buf.toString();
    }
    final clean = plainText?.trim() ?? '';
    return clean.isEmpty ? null : clean;
  }

  static String _guessImageExtension(Uint8List bytes) {
    if (bytes.length >= 4 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return '.png';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45) {
      return '.webp';
    }
    return '.jpg';
  }
}
