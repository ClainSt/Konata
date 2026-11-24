import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:engine_playback/engine_playback.dart';
import 'package:engine_scraping/engine_scraping.dart';
import 'package:engine_sources/engine_sources.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:path/path.dart' as p;

/// 将 `24-bit` BMP 原始帧转换为紧凑无损 PNG 的编码器回调类型（便于离线单测注入）。
typedef BmpToPngEncoder = Future<Uint8List?> Function(Uint8List bmpBytes);

/// 批量正片自动抽帧任务描述项。
class MainEpisodeFrameTask {
  /// 创建单集正片抽帧任务。
  const MainEpisodeFrameTask({
    required this.key,
    required this.variant,
    this.source,
  });

  /// 业务调用方唯一标识（通常为 `Episode.id`）。
  final String key;

  /// 目标正片视频变体。
  final MediaVariant variant;

  /// 所属媒体源（本地源可省略）。
  final MediaSource? source;
}

/// 将领域媒体源实体投影为契约层只读摘要，绝不透传敏感凭据。
MediaSourceView projectMediaSourceView(MediaSource source) {
  return MediaSourceView(
    id: SourceId.trusted(source.id),
    kind: source.kind,
    label: source.label,
    location: source.location,
    username: source.username,
  );
}

/// 面向「正片视频」的无头流式抽帧服务（严格全局单并发串行，绝不对特典抽帧）。
///
/// - 仅处理正片视频（`AssetKind.video` 且由调用方严格限定为正片 `EpisodeCategory.main`）；
/// - 复用内置 `libmpv` 离屏软件渲染管线与 `LocalStreamBridgePort` Range 按需流读；
/// - 批量补图在单次会话内复用同一 `libmpv` 实例与按源缓存的远程网关连接，支持单集即时回调；
/// - 每次抽帧会话结束后立即释放 `libmpv` 实例、网关连接与流租约，零常驻内存与连接泄漏。
class MainEpisodeFrameExtractor {
  /// 单集卡片剧照默认最大宽度。
  static const int defaultStillWidth = 640;

  /// 单集卡片剧照默认最大高度。
  static const int defaultStillHeight = 360;

  /// 全屏背景图挑选默认最大宽度。
  static const int defaultBackdropWidth = 1280;

  /// 全屏背景图挑选默认最大高度。
  static const int defaultBackdropHeight = 720;

  static const String _fastLavfProbesize = '524288';
  static const String _fastLavfAnalyzeDuration = '0.5';
  static const String _stillDemuxerMaxBytes = '1572864';
  static const String _backdropDemuxerMaxBytes = '2097152';
  static const String _fastReconnectLavfOptions =
      'reconnect=1,reconnect_streamed=1,reconnect_delay_max=1';
  static const Duration _renderReadyFallbackTimeout = Duration(
    milliseconds: 120,
  );

  /// 创建正片抽帧服务实例。
  MainEpisodeFrameExtractor({
    required this.streamBridge,
    required this.gatewayFactory,
    this.logStore,
    this.clientFactory,
    BmpToPngEncoder? pngEncoder,
    this.maxWidth = defaultBackdropWidth,
    this.maxHeight = defaultBackdropHeight,
    this.stillMaxWidth = defaultStillWidth,
    this.stillMaxHeight = defaultStillHeight,
    this.loadTimeout = const Duration(seconds: 12),
    this.seekTimeout = const Duration(seconds: 6),
  }) : _pngEncoder = pngEncoder ?? _encodeBmpToPngWithFlutter;

  /// 流式网桥（用于 `WebDAV` / `SMB` 远程按需 `Range` 跳跃抽帧）。
  final LocalStreamBridgePort streamBridge;

  /// 媒体源只读网关工厂端口。
  final MediaSourceGatewayFactoryPort gatewayFactory;

  /// 统一脱敏诊断日志端口（可选）。
  final DiagnosticLogPort? logStore;

  /// 辅助原生 `libmpv` 客户端工厂。
  final LibMpvClient Function()? clientFactory;

  final BmpToPngEncoder _pngEncoder;

  /// 全屏背景图候选抽帧最大宽度。
  final int maxWidth;

  /// 全屏背景图候选抽帧最大高度。
  final int maxHeight;

  /// 单集卡片剧照抽帧最大宽度。
  final int stillMaxWidth;

  /// 单集卡片剧照抽帧最大高度。
  final int stillMaxHeight;

  /// 打开容器头部超时上限。
  final Duration loadTimeout;

  /// 单次关键帧跳转超时上限。
  final Duration seekTimeout;

  // 全局串行尾链：确保任意时刻最多仅运行单个后台抽帧会话，严防并发压垮远程连接池。
  Future<void> _serialTail = Future<void>.value();

  Future<T> _runSerialized<T>(Future<T> Function() action) {
    final prev = _serialTail;
    final next = Completer<void>();
    _serialTail = next.future;
    return prev.then((_) async {
      try {
        return await action();
      } finally {
        if (!next.isCompleted) next.complete();
      }
    });
  }

  /// 从正片视频多点采样并自动择优返回画面最丰富的一帧（命中高置信主体帧自动早停）。
  Future<Uint8List?> extractBestMainFrame({
    required MediaVariant variant,
    MediaSource? source,
    int sampleCount = 5,
    int? targetWidth,
    int? targetHeight,
    bool Function()? isCancelled,
  }) async {
    final samples = await extractCandidateFrames(
      variant: variant,
      source: source,
      sampleCount: sampleCount.clamp(1, 6),
      encodeBestOnly: true,
      targetWidth: targetWidth ?? stillMaxWidth,
      targetHeight: targetHeight ?? stillMaxHeight,
      isCancelled: isCancelled,
    );
    if (samples.isEmpty) return null;
    return samples.first.imageBytes;
  }

  /// 批量为多集正片自动择优抽帧：单次复用 `libmpv` 实例与同源远程网关，按集即时回调。
  Future<Map<String, Uint8List>> extractBestMainFramesBatch({
    required List<MainEpisodeFrameTask> tasks,
    int sampleCount = 5,
    int? targetWidth,
    int? targetHeight,
    bool Function()? isCancelled,
    Future<void> Function(String key, Uint8List pngBytes)? onExtracted,
  }) async {
    final validTasks = tasks
        .where((t) => t.variant.assetKind == AssetKind.video)
        .toList(growable: false);
    if (validTasks.isEmpty) return const <String, Uint8List>{};

    final effW = targetWidth ?? stillMaxWidth;
    final effH = targetHeight ?? stillMaxHeight;

    if (validTasks.length == 1) {
      final only = validTasks.single;
      final bytes = await extractBestMainFrame(
        variant: only.variant,
        source: only.source,
        sampleCount: sampleCount,
        targetWidth: effW,
        targetHeight: effH,
        isCancelled: isCancelled,
      );
      if (bytes == null || bytes.isEmpty) return const <String, Uint8List>{};
      await onExtracted?.call(only.key, bytes);
      return <String, Uint8List>{only.key: bytes};
    }

    if (clientFactory == null &&
        Platform.environment.containsKey('FLUTTER_TEST')) {
      return const <String, Uint8List>{};
    }

    return _runSerialized(
      () => _extractBestBatchSession(
        tasks: validTasks,
        sampleCount: sampleCount.clamp(1, 6),
        targetWidth: effW,
        targetHeight: effH,
        isCancelled: isCancelled,
        onExtracted: onExtracted,
      ),
    );
  }

  /// 从正片视频按全片分布抽取多张候选画面（供背景选择弹窗挑帧）。
  Future<List<VideoFrameSample>> extractCandidateFrames({
    required MediaVariant variant,
    MediaSource? source,
    int sampleCount = 8,
    double phaseOffset = 0.0,
    bool encodeBestOnly = false,
    int? targetWidth,
    int? targetHeight,
    bool Function()? isCancelled,
  }) {
    if (variant.assetKind != AssetKind.video) {
      return Future<List<VideoFrameSample>>.value(const <VideoFrameSample>[]);
    }
    if (clientFactory == null &&
        Platform.environment.containsKey('FLUTTER_TEST')) {
      return Future<List<VideoFrameSample>>.value(const <VideoFrameSample>[]);
    }
    return _runSerialized(
      () => _extractSession(
        variant: variant,
        source: source,
        sampleCount: sampleCount.clamp(1, 8),
        phaseOffset: phaseOffset,
        encodeBestOnly: encodeBestOnly,
        targetWidth: targetWidth ?? maxWidth,
        targetHeight: targetHeight ?? maxHeight,
        isCancelled: isCancelled,
      ),
    );
  }

  void _applyFastFrameOptions(
    LibMpvClient client, {
    required bool isBackdropQuality,
  }) {
    MpvQualityProfile.applyPreInitThumbnailOptions(client, logStore: logStore);
    final setter = MpvSafePropertySetter(logStore: logStore);
    setter.setOption(client, 'keepaspect', 'yes');
    setter.setOption(client, 'load-scripts', 'no');
    setter.setOption(client, 'ytdl', 'no');
    setter.setOption(client, 'vd-lavc-threads', '4');
    setter.setOption(client, 'vd-lavc-skiploopfilter', 'nonkey');
    setter.setOption(client, 'scale', 'bilinear');
    setter.setOption(client, 'demuxer-lavf-probesize', _fastLavfProbesize);
    setter.setOption(
      client,
      'demuxer-lavf-analyzeduration',
      _fastLavfAnalyzeDuration,
    );
    setter.setOption(client, 'stream-lavf-o', _fastReconnectLavfOptions);
    setter.setOption(
      client,
      'demuxer-max-bytes',
      isBackdropQuality ? _backdropDemuxerMaxBytes : _stillDemuxerMaxBytes,
    );
    setter.setOption(client, 'demuxer-max-back-bytes', '0');
  }

  Future<Map<String, Uint8List>> _extractBestBatchSession({
    required List<MainEpisodeFrameTask> tasks,
    required int sampleCount,
    required int targetWidth,
    required int targetHeight,
    bool Function()? isCancelled,
    Future<void> Function(String key, Uint8List pngBytes)? onExtracted,
  }) async {
    if (isCancelled?.call() ?? false) return const <String, Uint8List>{};
    final factory = clientFactory;
    if (factory == null) return const <String, Uint8List>{};

    final results = <String, Uint8List>{};
    final cachedGateways = <String, ByteRangeReadableGateway>{};
    LibMpvClient? client;
    LibMpvSoftwareFrameSource? frameSource;
    StreamSubscription<MpvClientEvent>? eventSub;
    StreamSubscription<void>? renderSub;
    Completer<void>? activeFileLoadedCompleter;
    Completer<void>? activeSeekRestartCompleter;
    Completer<void>? activeRenderReadyCompleter;

    try {
      client = factory();
      final isBackdropQuality =
          targetWidth > stillMaxWidth || targetHeight > stillMaxHeight;
      _applyFastFrameOptions(client, isBackdropQuality: isBackdropQuality);
      if (client.initialize() < 0) return const <String, Uint8List>{};
      if (client is! LibMpvSoftwareFrameSource) {
        return const <String, Uint8List>{};
      }
      frameSource = client as LibMpvSoftwareFrameSource;

      eventSub = client.events.listen((event) {
        switch (event) {
          case MpvFileLoadedEvent():
            final c = activeFileLoadedCompleter;
            if (c != null && !c.isCompleted) c.complete();
          case MpvPlaybackRestartEvent():
            final c = activeSeekRestartCompleter;
            if (c != null && !c.isCompleted) c.complete();
          default:
            break;
        }
      });

      renderSub = frameSource.softwareRenderUpdates.listen((_) {
        final c = activeRenderReadyCompleter;
        if (c != null && !c.isCompleted) c.complete();
      });

      final initW = LibMpvSoftwareFrameSource.alignDimension(targetWidth);
      final initH = LibMpvSoftwareFrameSource.alignDimension(targetHeight);
      if (!frameSource.initSoftwareRenderer(width: initW, height: initH)) {
        return const <String, Uint8List>{};
      }

      for (final task in tasks) {
        if (isCancelled?.call() ?? false) break;
        String? streamToken;
        try {
          final mediaTarget = await _resolveMediaTarget(
            variant: task.variant,
            source: task.source,
            cachedGateways: cachedGateways,
            isCancelled: isCancelled,
            onRegisteredToken: (token) => streamToken = token,
          );
          if (mediaTarget == null || (isCancelled?.call() ?? false)) continue;

          final fileLoaded = Completer<void>();
          activeFileLoadedCompleter = fileLoaded;
          client.setPropertyFlag('pause', true);
          if (client.command(['loadfile', mediaTarget, 'replace']) < 0) {
            activeFileLoadedCompleter = null;
            continue;
          }
          try {
            await fileLoaded.future.timeout(loadTimeout);
          } catch (error) {
            developer.log(
              '批量正片抽帧等待文件载入超时，跳过当前集',
              name: 'konata.main_episode_frame_extractor',
              error: error,
            );
            continue;
          } finally {
            activeFileLoadedCompleter = null;
          }
          if (isCancelled?.call() ?? false) break;

          final sampled = await _sampleLoadedMedia(
            client: client,
            frameSource: frameSource,
            sampleCount: sampleCount,
            phaseOffset: 0.0,
            encodeBestOnly: true,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            isCancelled: isCancelled,
            setSeekCompleter: (c) => activeSeekRestartCompleter = c,
            setRenderCompleter: (c) => activeRenderReadyCompleter = c,
          );
          if (sampled.isEmpty || (isCancelled?.call() ?? false)) continue;
          final png = sampled.first.imageBytes;
          results[task.key] = png;
          await onExtracted?.call(task.key, png);
        } catch (error) {
          developer.log(
            '批量正片抽帧单集异常，继续后续剧集',
            name: 'konata.main_episode_frame_extractor',
            error: error,
          );
        } finally {
          activeFileLoadedCompleter = null;
          activeSeekRestartCompleter = null;
          activeRenderReadyCompleter = null;
          if (streamToken != null) {
            try {
              await streamBridge.unregisterSession(streamToken!);
            } catch (error) {
              developer.log(
                '注销单集抽帧流租约失败已忽略',
                name: 'konata.main_episode_frame_extractor',
                error: error,
              );
            }
          }
        }
      }
      return results;
    } catch (error) {
      developer.log(
        '批量正片流式抽帧异常，已安全返回已完成结果',
        name: 'konata.main_episode_frame_extractor',
        error: error,
      );
      return results;
    } finally {
      await eventSub?.cancel();
      await renderSub?.cancel();
      frameSource?.releaseSoftwareRenderer();
      if (client != null && !client.isDisposed) {
        await client.dispose();
      }
      for (final gw in cachedGateways.values) {
        try {
          await gw.close();
        } catch (error) {
          developer.log(
            '关闭抽帧远程网关连接异常已忽略',
            name: 'konata.main_episode_frame_extractor',
            error: error,
          );
        }
      }
    }
  }

  Future<List<VideoFrameSample>> _extractSession({
    required MediaVariant variant,
    required MediaSource? source,
    required int sampleCount,
    required double phaseOffset,
    required bool encodeBestOnly,
    required int targetWidth,
    required int targetHeight,
    bool Function()? isCancelled,
  }) async {
    if (isCancelled?.call() ?? false) return const <VideoFrameSample>[];
    final factory = clientFactory;
    if (factory == null) return const <VideoFrameSample>[];

    String? streamToken;
    LibMpvClient? client;
    LibMpvSoftwareFrameSource? frameSource;
    StreamSubscription<MpvClientEvent>? eventSub;
    StreamSubscription<void>? renderSub;
    Completer<void>? seekRestartCompleter;
    Completer<void>? renderReadyCompleter;

    try {
      final String mediaTarget;
      if (source == null || source.kind == MediaSourceKind.local) {
        final resolved = source == null
            ? variant.relativePath
            : LocalSourceGateway(
                rootPath: source.location,
              ).resolveAbsolutePath(variant.relativePath);
        if (!File(resolved).existsSync()) {
          return const <VideoFrameSample>[];
        }
        mediaTarget = resolved;
      } else {
        final gw = await gatewayFactory.create(projectMediaSourceView(source));
        if (isCancelled?.call() ?? false) {
          await gw.close();
          return const <VideoFrameSample>[];
        }
        if (gw is! ByteRangeReadableGateway) {
          await gw.close();
          return const <VideoFrameSample>[];
        }
        final reg = await streamBridge.registerSession(
          gateway: gw as ByteRangeReadableGateway,
          relativePath: variant.relativePath,
          fileName: p.basename(variant.relativePath),
          knownLength: variant.fileSize > 0 ? variant.fileSize : null,
          ownsGateway: true,
          sourceKind: source.kind,
        );
        streamToken = reg.token;
        mediaTarget = reg.url.toString();
      }

      if (isCancelled?.call() ?? false) return const <VideoFrameSample>[];
      client = factory();
      final isBackdropQuality =
          !encodeBestOnly ||
          targetWidth > stillMaxWidth ||
          targetHeight > stillMaxHeight;
      _applyFastFrameOptions(client, isBackdropQuality: isBackdropQuality);

      if (client.initialize() < 0) {
        return const <VideoFrameSample>[];
      }
      if (client is! LibMpvSoftwareFrameSource) {
        return const <VideoFrameSample>[];
      }
      frameSource = client as LibMpvSoftwareFrameSource;

      final fileLoadedCompleter = Completer<void>();

      eventSub = client.events.listen((event) {
        switch (event) {
          case MpvFileLoadedEvent():
            if (!fileLoadedCompleter.isCompleted) {
              fileLoadedCompleter.complete();
            }
          case MpvPlaybackRestartEvent():
            final seekCompleter = seekRestartCompleter;
            if (seekCompleter != null && !seekCompleter.isCompleted) {
              seekCompleter.complete();
            }
          default:
            break;
        }
      });

      renderSub = frameSource.softwareRenderUpdates.listen((_) {
        final renderCompleter = renderReadyCompleter;
        if (renderCompleter != null && !renderCompleter.isCompleted) {
          renderCompleter.complete();
        }
      });

      final initW = LibMpvSoftwareFrameSource.alignDimension(targetWidth);
      final initH = LibMpvSoftwareFrameSource.alignDimension(targetHeight);
      if (!frameSource.initSoftwareRenderer(width: initW, height: initH)) {
        return const <VideoFrameSample>[];
      }

      client.setPropertyFlag('pause', true);
      if (client.command(['loadfile', mediaTarget, 'replace']) < 0) {
        return const <VideoFrameSample>[];
      }
      try {
        await fileLoadedCompleter.future.timeout(loadTimeout);
      } catch (error) {
        developer.log(
          '正片抽帧等待文件载入超时，中止本次抽帧',
          name: 'konata.main_episode_frame_extractor',
          error: error,
        );
        return const <VideoFrameSample>[];
      }
      if (isCancelled?.call() ?? false) return const <VideoFrameSample>[];

      return await _sampleLoadedMedia(
        client: client,
        frameSource: frameSource,
        sampleCount: sampleCount,
        phaseOffset: phaseOffset,
        encodeBestOnly: encodeBestOnly,
        targetWidth: targetWidth,
        targetHeight: targetHeight,
        isCancelled: isCancelled,
        setSeekCompleter: (c) => seekRestartCompleter = c,
        setRenderCompleter: (c) => renderReadyCompleter = c,
      );
    } catch (error) {
      developer.log(
        '正片流式抽帧异常，已安全跳过',
        name: 'konata.main_episode_frame_extractor',
        error: error,
      );
      return const <VideoFrameSample>[];
    } finally {
      await eventSub?.cancel();
      await renderSub?.cancel();
      frameSource?.releaseSoftwareRenderer();
      if (client != null && !client.isDisposed) {
        await client.dispose();
      }
      if (streamToken != null) {
        try {
          await streamBridge.unregisterSession(streamToken);
        } catch (error) {
          developer.log(
            '注销抽帧流网桥租约异常忽略',
            name: 'konata.main_episode_frame_extractor',
            error: error,
          );
        }
      }
    }
  }

  Future<String?> _resolveMediaTarget({
    required MediaVariant variant,
    required MediaSource? source,
    required Map<String, ByteRangeReadableGateway> cachedGateways,
    bool Function()? isCancelled,
    required void Function(String token) onRegisteredToken,
  }) async {
    if (source == null || source.kind == MediaSourceKind.local) {
      final resolved = source == null
          ? variant.relativePath
          : LocalSourceGateway(
              rootPath: source.location,
            ).resolveAbsolutePath(variant.relativePath);
      if (!File(resolved).existsSync()) {
        return null;
      }
      return resolved;
    }

    var gw = cachedGateways[source.id];
    if (gw == null) {
      final created = await gatewayFactory.create(projectMediaSourceView(source));
      if (isCancelled?.call() ?? false) {
        await created.close();
        return null;
      }
      if (created is! ByteRangeReadableGateway) {
        await created.close();
        return null;
      }
      gw = created as ByteRangeReadableGateway;
      cachedGateways[source.id] = gw;
    }

    final reg = await streamBridge.registerSession(
      gateway: gw,
      relativePath: variant.relativePath,
      fileName: p.basename(variant.relativePath),
      knownLength: variant.fileSize > 0 ? variant.fileSize : null,
      ownsGateway: false,
      sourceKind: source.kind,
    );
    onRegisteredToken(reg.token);
    return reg.url.toString();
  }

  Future<List<VideoFrameSample>> _sampleLoadedMedia({
    required LibMpvClient client,
    required LibMpvSoftwareFrameSource frameSource,
    required int sampleCount,
    required double phaseOffset,
    required bool encodeBestOnly,
    required int targetWidth,
    required int targetHeight,
    bool Function()? isCancelled,
    required void Function(Completer<void>? completer) setSeekCompleter,
    required void Function(Completer<void>? completer) setRenderCompleter,
  }) async {
    final duration = client.getPropertyDouble('duration');
    final aspect = client.getPropertyDouble('video-params/aspect');
    final outDims = _resolveTargetDimensions(
      aspect,
      limitWidth: targetWidth,
      limitHeight: targetHeight,
    );
    final timestamps = encodeBestOnly && phaseOffset == 0.0
        ? VideoFrameSamplePlan.buildAutoPriorityTimestamps(
            duration,
            count: sampleCount,
          )
        : VideoFrameSamplePlan.buildTimestamps(
            duration,
            count: sampleCount,
            phaseOffset: phaseOffset,
          );

    final rawSamples =
        <
          ({
            double ts,
            Uint8List bmp,
            VideoFrameQualityMetrics metrics,
            int width,
            int height,
          })
        >[];
    ({
      double ts,
      Uint8List bmp,
      VideoFrameQualityMetrics metrics,
      int width,
      int height,
    })?
    bestSoFar;

    for (final ts in timestamps) {
      if (isCancelled?.call() ?? false) break;
      final seekCompleter = Completer<void>();
      final renderCompleter = Completer<void>();
      setSeekCompleter(seekCompleter);
      setRenderCompleter(renderCompleter);
      client.setPropertyFlag('pause', true);
      final rc = client.command([
        'seek',
        ts.toStringAsFixed(3),
        'absolute',
        'keyframes',
      ]);
      if (rc < 0) {
        setSeekCompleter(null);
        setRenderCompleter(null);
        continue;
      }

      try {
        await seekCompleter.future.timeout(seekTimeout);
      } catch (error) {
        developer.log(
          '正片抽帧关键帧跳转超时',
          name: 'konata.main_episode_frame_extractor',
          error: error,
        );
        setSeekCompleter(null);
        setRenderCompleter(null);
        continue;
      } finally {
        setSeekCompleter(null);
      }
      if (isCancelled?.call() ?? false) {
        setRenderCompleter(null);
        break;
      }

      if (!frameSource.pollSoftwareFrameReady() &&
          !renderCompleter.isCompleted) {
        try {
          await renderCompleter.future.timeout(_renderReadyFallbackTimeout);
        } catch (error) {
          developer.log(
            '等待软渲染首帧就绪超时，转为轮询读取',
            name: 'konata.main_episode_frame_extractor',
            error: error,
          );
        }
        frameSource.pollSoftwareFrameReady();
      }
      setRenderCompleter(null);
      if (isCancelled?.call() ?? false) break;

      final bmp = frameSource.renderSoftwareFrameBmp(
        width: outDims.width,
        height: outDims.height,
      );
      if (bmp == null || bmp.isEmpty) continue;
      final metrics = VideoFrameQualityScorer.evaluateBmp24(bmp);
      if (metrics.score < 0) continue;

      final candidate = (
        ts: ts,
        bmp: bmp,
        metrics: metrics,
        width: outDims.width,
        height: outDims.height,
      );
      rawSamples.add(candidate);
      if (bestSoFar == null || metrics.score > bestSoFar.metrics.score) {
        bestSoFar = candidate;
      }

      if (encodeBestOnly) {
        if (metrics.isImmediateAccept) {
          break;
        }
        if (rawSamples.length >= 2 && bestSoFar.metrics.isEarlyStopAfterTwo) {
          break;
        }
      }
    }

    if (rawSamples.isEmpty) return const <VideoFrameSample>[];

    if (encodeBestOnly) {
      final best = bestSoFar ?? rawSamples.first;
      final png = await _pngEncoder(best.bmp);
      if (png == null || png.isEmpty) return const <VideoFrameSample>[];
      return <VideoFrameSample>[
        VideoFrameSample(
          timestampSeconds: best.ts,
          imageBytes: png,
          score: best.metrics.score,
          width: best.width,
          height: best.height,
        ),
      ];
    }

    final encoded = <VideoFrameSample>[];
    for (final raw in rawSamples) {
      if (isCancelled?.call() ?? false) break;
      final png = await _pngEncoder(raw.bmp);
      if (png == null || png.isEmpty) continue;
      encoded.add(
        VideoFrameSample(
          timestampSeconds: raw.ts,
          imageBytes: png,
          score: raw.metrics.score,
          width: raw.width,
          height: raw.height,
        ),
      );
    }
    return encoded;
  }

  ({int width, int height}) _resolveTargetDimensions(
    double? aspect, {
    required int limitWidth,
    required int limitHeight,
  }) {
    final safeAspect =
        (aspect != null && aspect.isFinite && aspect >= 0.5 && aspect <= 3.0)
        ? aspect
        : (16.0 / 9.0);
    int rawW;
    int rawH;
    if (safeAspect >= limitWidth / limitHeight) {
      rawW = limitWidth;
      rawH = (limitWidth / safeAspect).round();
    } else {
      rawH = limitHeight;
      rawW = (limitHeight * safeAspect).round();
    }
    return (
      width: math.max(16, LibMpvSoftwareFrameSource.alignDimension(rawW)),
      height: math.max(16, LibMpvSoftwareFrameSource.alignDimension(rawH)),
    );
  }

  static Future<Uint8List?> _encodeBmpToPngWithFlutter(
    Uint8List bmpBytes,
  ) async {
    ui.Codec? codec;
    ui.Image? image;
    try {
      codec = await ui.instantiateImageCodec(bmpBytes);
      final frame = await codec.getNextFrame();
      image = frame.image;
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      return byteData?.buffer.asUint8List();
    } catch (error) {
      developer.log(
        'BMP 帧转无损 PNG 失败',
        name: 'konata.main_episode_frame_extractor',
        error: error,
      );
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }
}
