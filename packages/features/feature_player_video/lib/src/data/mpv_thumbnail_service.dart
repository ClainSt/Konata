import 'dart:async';
import 'dart:collection';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:engine_playback/engine_playback.dart';
import 'package:engine_sources/engine_sources.dart';
import 'package:flutter/foundation.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';
import 'package:path/path.dart' as p;

/// 缩略图时间桶量化与有界最近最少使用内存缓存（等待抽帧期间返回邻近帧以消除闪烁）。
class ThumbnailBucketCache {
  /// 创建缩略图内存缓存容器。
  ThumbnailBucketCache({this.capacity = 48}) : assert(capacity > 0);

  /// 缓存容量上限（帧数量）。
  final int capacity;

  final LinkedHashMap<int, ({double bucketSeconds, Uint8List bytes})> _entries =
      LinkedHashMap();

  /// 当前已缓存的缩略图数量。
  int get length => _entries.length;

  /// 将任意目标秒数按本地或远程策略量化至对应时间桶起点。
  static double quantizeBucketSeconds(
    double targetSeconds, {
    required bool isRemote,
    double? durationSeconds,
    double localBucketSeconds = 1.0,
    double remoteBucketSeconds = 5.0,
  }) {
    final step = isRemote ? remoteBucketSeconds : localBucketSeconds;
    final safeStep = step > 0 ? step : 1.0;
    var clamped = targetSeconds.isFinite && targetSeconds > 0
        ? targetSeconds
        : 0.0;
    if (durationSeconds != null &&
        durationSeconds.isFinite &&
        durationSeconds > 0 &&
        clamped > durationSeconds) {
      clamped = durationSeconds;
    }
    final quantized = (clamped / safeStep).round() * safeStep;
    if (durationSeconds != null &&
        durationSeconds.isFinite &&
        durationSeconds > 0 &&
        quantized > durationSeconds) {
      return (durationSeconds / safeStep).floor() * safeStep;
    }
    return quantized < 0 ? 0.0 : quantized;
  }

  static int _keyFor(double bucketSeconds) => (bucketSeconds * 1000).round();

  /// 判断指定时间桶是否已有缓存帧。
  bool containsBucket(double bucketSeconds) =>
      _entries.containsKey(_keyFor(bucketSeconds));

  /// 读取精确命中时间桶的位图字节并刷新最近访问次序。
  Uint8List? getExact(double bucketSeconds) {
    final key = _keyFor(bucketSeconds);
    final existing = _entries.remove(key);
    if (existing == null) return null;
    _entries[key] = existing;
    return existing.bytes;
  }

  /// 在允许时间差范围内返回距离目标时间点最近的邻近缓存帧字节。
  Uint8List? getNearest(
    double targetSeconds, {
    double maxDistanceSeconds = 120.0,
  }) {
    if (_entries.isEmpty) return null;
    final safeTarget = targetSeconds.isFinite && targetSeconds > 0
        ? targetSeconds
        : 0.0;
    Uint8List? bestBytes;
    var bestDist = double.infinity;
    for (final entry in _entries.values) {
      final dist = (entry.bucketSeconds - safeTarget).abs();
      if (dist <= maxDistanceSeconds && dist < bestDist) {
        bestDist = dist;
        bestBytes = entry.bytes;
        if (dist <= 0.01) break;
      }
    }
    return bestBytes;
  }

  /// 写入指定时间桶的位图字节并在超出容量上限时淘汰最旧条目。
  void put(double bucketSeconds, Uint8List bytes) {
    if (bytes.isEmpty) return;
    final key = _keyFor(bucketSeconds);
    _entries.remove(key);
    _entries[key] = (bucketSeconds: bucketSeconds, bytes: bytes);
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
  }

  /// 清空全部缓存缩略图字节。
  void clear() => _entries.clear();
}

/// 面向当前播放源的按需惰性后台缩略图解码服务。
///
/// 正常播片期间不常驻后台解码实例，仅在进度条悬停或拖拽时预热并采用最新意图优先策略按时间桶抽帧，
/// 空闲超时后自动销毁辅助实例与网络流租约，同时保留最近最少使用内存位图缓存。
class MpvThumbnailService extends ChangeNotifier {
  /// 创建后台缩略图服务实例。
  MpvThumbnailService({
    required this.streamBridge,
    this.gatewayFactory,
    this.logStore,
    this.clientFactory,
    this.localBucketSeconds = 1.0,
    this.remoteBucketSeconds = 5.0,
    int cacheCapacity = 48,
    this.decodeWidth = 192,
    this.decodeHeight = 108,
    this.seekTimeout = const Duration(seconds: 4),
    this.idleReleaseDuration = defaultIdleReleaseDuration,
  }) : _cache = ThumbnailBucketCache(capacity: cacheCapacity);

  /// 停止悬停且无后台预取任务后的自动销毁等待时长（15 秒）。
  static const Duration defaultIdleReleaseDuration = Duration(seconds: 15);

  /// 本地安全回环流网桥端口。
  final LocalStreamBridgePort streamBridge;

  /// 只读媒体源网关工厂端口。
  final MediaSourceGatewayFactoryPort? gatewayFactory;

  /// 可选脱敏结构化诊断日志端口。
  final DiagnosticLogPort? logStore;

  /// 可选辅助底层客户端实例工厂。
  final LibMpvClient Function()? clientFactory;

  /// 本地文件时间桶步长（秒）。
  final double localBucketSeconds;

  /// 远程协议媒体源时间桶步长（秒）。
  final double remoteBucketSeconds;

  /// 解码目标像素宽度。
  final int decodeWidth;

  /// 解码目标像素高度。
  final int decodeHeight;

  /// 单次关键帧定位超时上限。
  final Duration seekTimeout;

  /// 空闲回收辅助实例等待时长；为空则不自动定时销毁。
  final Duration? idleReleaseDuration;

  final ThumbnailBucketCache _cache;

  LibMpvClient? _client;
  LibMpvSoftwareFrameSource? _frameSource;
  StreamSubscription<MpvClientEvent>? _eventSub;
  StreamSubscription<void>? _renderSub;
  String? _streamToken;
  Timer? _idleReleaseTimer;
  MediaVariantRecord? _boundVariant;
  MediaSourceView? _boundSource;
  List<PlaybackChapter> _boundChapters = const <PlaybackChapter>[];

  bool _isRemote = false;
  double? _durationSeconds;
  bool _isWarmedUp = false;
  bool _isWarmingUp = false;
  bool _isExtracting = false;
  bool _isUserHovering = false;
  bool _disposed = false;
  int _generation = 0;

  double? _pendingUserBucket;
  final Queue<double> _chapterPrefetchQueue = Queue<double>();
  Completer<void>? _fileLoadedCompleter;
  Completer<void>? _seekRestartCompleter;
  Completer<void>? _renderReadyCompleter;

  /// 是否已完成媒体容器索引预热。
  bool get isWarmedUp => _isWarmedUp;

  /// 当前是否正在执行预热连接。
  bool get isWarmingUp => _isWarmingUp;

  /// 当前是否仍持有存活的辅助原生解码实例。
  bool get hasActiveNativeClient => _client != null && !_client!.isDisposed;

  /// 当前缓存中保留的缩略图帧数。
  int get cachedCount => _cache.length;

  /// 当前等待抽取的最新用户悬停目标时间桶。
  double? get pendingUserBucket => _pendingUserBucket;

  /// 惰性预热指定物理版本及媒体源的后台缩略图解码会话。
  Future<void> warmUp({
    required MediaVariantRecord variant,
    MediaSourceView? source,
    List<PlaybackChapter> chapters = const <PlaybackChapter>[],
    double? durationSeconds,
    bool preserveCache = false,
    bool preservePendingUserRequest = false,
  }) async {
    if (_disposed) return;
    if (clientFactory == null &&
        Platform.environment.containsKey('FLUTTER_TEST')) {
      return;
    }

    final savedPendingBucket = preservePendingUserRequest
        ? _pendingUserBucket
        : null;
    final savedHovering = preservePendingUserRequest && _isUserHovering;

    await _resetSessionOnly(clearCache: !preserveCache);
    if (_disposed) return;

    _isWarmingUp = true;
    _boundVariant = variant;
    _boundSource = source;
    _boundChapters = chapters;
    final gen = ++_generation;
    _isRemote = source != null && source.kind != MediaSourceKind.local;
    _durationSeconds = durationSeconds;
    if (savedPendingBucket != null) {
      _pendingUserBucket = _quantize(savedPendingBucket);
      _isUserHovering = savedHovering;
    }

    try {
      String mediaTarget;
      if (source == null || source.kind == MediaSourceKind.local) {
        mediaTarget = source == null
            ? variant.relativePath
            : LocalSourceGateway(
                rootPath: source.location,
              ).resolveAbsolutePath(variant.relativePath);
      } else {
        final factory = gatewayFactory;
        if (factory == null) {
          return;
        }
        final gw = await factory.create(source);
        if (_disposed || gen != _generation) {
          await gw.close();
          return;
        }
        if (gw is! ByteRangeReadableGateway) {
          await gw.close();
          return;
        }
        final reg = await streamBridge.registerSession(
          gateway: gw as ByteRangeReadableGateway,
          relativePath: variant.relativePath,
          fileName: p.basename(variant.relativePath),
          knownLength: variant.fileSize > 0 ? variant.fileSize : null,
          ownsGateway: true,
          sourceKind: source.kind,
        );
        if (_disposed || gen != _generation) {
          await streamBridge.unregisterSession(reg.token);
          return;
        }
        _streamToken = reg.token;
        mediaTarget = reg.url.toString();
      }

      final factory = clientFactory;
      if (factory == null) {
        PlaybackLogHelper.record(logStore, 'mpv-thumb', '未注入缩略图客户端工厂，跳过预热');
        return;
      }
      LibMpvClient client;
      try {
        client = factory();
      } catch (error) {
        PlaybackLogHelper.record(
          logStore,
          'mpv-thumb',
          '创建缩略图实例失败: $error',
          isError: true,
          error: error,
        );
        return;
      }
      if (_disposed || gen != _generation) {
        await client.dispose();
        return;
      }
      _client = client;

      MpvQualityProfile.applyPreInitThumbnailOptions(client, logStore: logStore);
      final initRc = client.initialize();
      if (initRc < 0) {
        PlaybackLogHelper.record(
          logStore,
          'mpv-thumb',
          '初始化缩略图实例失败: ${client.errorString(initRc)}',
          isError: true,
        );
        await _resetSessionOnly(clearCache: !preserveCache);
        return;
      }

      if (client is LibMpvSoftwareFrameSource) {
        final fs = client as LibMpvSoftwareFrameSource;
        final alignedW = LibMpvSoftwareFrameSource.alignDimension(decodeWidth);
        final alignedH = LibMpvSoftwareFrameSource.alignDimension(decodeHeight);
        if (!fs.initSoftwareRenderer(width: alignedW, height: alignedH)) {
          PlaybackLogHelper.record(
            logStore,
            'mpv-thumb',
            '初始化软件渲染缩略图上下文失败',
            isError: true,
          );
          await _resetSessionOnly(clearCache: !preserveCache);
          return;
        }
        _frameSource = fs;
        _renderSub = fs.softwareRenderUpdates.listen((_) {
          final rc = _renderReadyCompleter;
          if (rc != null && !rc.isCompleted) {
            rc.complete();
          }
        });
      }

      _fileLoadedCompleter = Completer<void>();
      _eventSub = client.events.listen(_handleEvent);
      client.setPropertyFlag('pause', true);

      final loadRc = client.command(<String>['loadfile', mediaTarget, 'replace']);
      if (loadRc < 0) {
        PlaybackLogHelper.record(
          logStore,
          'mpv-thumb',
          '预热载入媒体失败: ${client.errorString(loadRc)}',
          isError: true,
        );
        await _resetSessionOnly(clearCache: !preserveCache);
        return;
      }

      try {
        await _fileLoadedCompleter!.future.timeout(const Duration(seconds: 10));
      } catch (error) {
        developer.log(
          '缩略图预热等待加载事件超时或中止',
          name: 'konata.mpv_thumbnail_service',
          error: error,
        );
      }

      if (_disposed || gen != _generation || _client == null) return;
      _isWarmedUp = true;
      updateChapters(chapters, durationSeconds: durationSeconds);
      unawaited(_pumpQueue());
    } finally {
      if (gen == _generation) {
        _isWarmingUp = false;
      }
    }
  }

  void _handleEvent(MpvClientEvent event) {
    if (_disposed) return;
    switch (event) {
      case MpvFileLoadedEvent():
        if (_fileLoadedCompleter != null && !_fileLoadedCompleter!.isCompleted) {
          _fileLoadedCompleter!.complete();
        }
      case MpvPlaybackRestartEvent():
        if (_seekRestartCompleter != null &&
            !_seekRestartCompleter!.isCompleted) {
          _seekRestartCompleter!.complete();
        }
      case MpvEndFileEvent():
        if (_fileLoadedCompleter != null && !_fileLoadedCompleter!.isCompleted) {
          _fileLoadedCompleter!.complete();
        }
        if (_seekRestartCompleter != null &&
            !_seekRestartCompleter!.isCompleted) {
          _seekRestartCompleter!.complete();
        }
      default:
        break;
    }
  }

  /// 更新视频章节标记列表并将未缓存时间点加入空闲预取队列。
  void updateChapters(
    List<PlaybackChapter> chapters, {
    double? durationSeconds,
  }) {
    if (_disposed) return;
    if (durationSeconds != null && durationSeconds > 0) {
      _durationSeconds = durationSeconds;
    }
    _chapterPrefetchQueue.clear();
    final seenBuckets = <int>{};
    for (final ch in chapters) {
      if (ch.startSeconds < 0) continue;
      final bucket = _quantize(ch.startSeconds);
      final key = (bucket * 1000).round();
      if (!seenBuckets.add(key)) continue;
      if (!_cache.containsBucket(bucket)) {
        _chapterPrefetchQueue.add(bucket);
      }
    }
    if (_isWarmedUp && !_isUserHovering && !_isExtracting) {
      unawaited(_pumpQueue());
    }
  }

  /// 提交进度条悬停或拖拽目标秒数（以最新请求覆盖旧点，离开后进入空闲计时）。
  void requestPreview(double? targetSeconds) {
    if (_disposed) return;
    if (targetSeconds == null || !targetSeconds.isFinite) {
      _isUserHovering = false;
      _pendingUserBucket = null;
      if (_isWarmedUp && !_isExtracting && _chapterPrefetchQueue.isNotEmpty) {
        unawaited(_pumpQueue());
      } else {
        _scheduleIdleRelease();
      }
      return;
    }

    _idleReleaseTimer?.cancel();
    _idleReleaseTimer = null;
    _isUserHovering = true;
    final bucket = _quantize(targetSeconds);
    if (_cache.getExact(bucket) != null) {
      _pendingUserBucket = null;
      notifyListeners();
      return;
    }
    _pendingUserBucket = bucket;
    if (_isWarmedUp && !_isExtracting) {
      unawaited(_pumpQueue());
    } else if (!_isWarmedUp && !_isWarmingUp && _boundVariant != null) {
      unawaited(
        warmUp(
          variant: _boundVariant!,
          source: _boundSource,
          chapters: _boundChapters,
          durationSeconds: _durationSeconds,
          preserveCache: true,
          preservePendingUserRequest: true,
        ),
      );
    }
  }

  /// 查询精确匹配或邻近可用缓存缩略图位图字节以供界面无闪烁预览。
  Uint8List? resolvePreviewFrame(double targetSeconds) {
    final bucket = _quantize(targetSeconds);
    final exact = _cache.getExact(bucket);
    if (exact != null) return exact;
    return _cache.getNearest(targetSeconds);
  }

  double _quantize(double seconds) {
    return ThumbnailBucketCache.quantizeBucketSeconds(
      seconds,
      isRemote: _isRemote,
      durationSeconds: _durationSeconds,
      localBucketSeconds: localBucketSeconds,
      remoteBucketSeconds: remoteBucketSeconds,
    );
  }

  Future<void> _pumpQueue() async {
    if (_disposed || _isExtracting || !_isWarmedUp || _client == null) return;
    _isExtracting = true;
    final gen = _generation;

    try {
      while (!_disposed && gen == _generation && _client != null) {
        double? nextBucket;
        if (_pendingUserBucket != null) {
          nextBucket = _pendingUserBucket;
          _pendingUserBucket = null;
        } else if (!_isUserHovering && _chapterPrefetchQueue.isNotEmpty) {
          nextBucket = _chapterPrefetchQueue.removeFirst();
        } else {
          break;
        }

        if (nextBucket == null || _cache.containsBucket(nextBucket)) {
          continue;
        }

        final bytes = await _extractFrameAt(nextBucket, expectedGen: gen);
        if (_disposed || gen != _generation) break;
        if (bytes != null && bytes.isNotEmpty) {
          _cache.put(nextBucket, bytes);
          notifyListeners();
        }
      }
    } finally {
      _isExtracting = false;
      if (!_disposed && !_isUserHovering && _pendingUserBucket == null) {
        _scheduleIdleRelease();
      }
    }
  }

  void _scheduleIdleRelease() {
    final delay = idleReleaseDuration;
    if (_disposed || delay == null || delay <= Duration.zero || _client == null) {
      return;
    }
    _idleReleaseTimer?.cancel();
    _idleReleaseTimer = Timer(delay, () {
      if (_disposed ||
          _isUserHovering ||
          _isExtracting ||
          _pendingUserBucket != null) {
        return;
      }
      unawaited(_resetSessionOnly(clearCache: false));
    });
  }

  Future<Uint8List?> _extractFrameAt(
    double bucketSeconds, {
    required int expectedGen,
  }) async {
    final client = _client;
    if (_disposed ||
        expectedGen != _generation ||
        client == null ||
        client.isDisposed) {
      return null;
    }

    _seekRestartCompleter = Completer<void>();
    _renderReadyCompleter = Completer<void>();
    client.setPropertyFlag('pause', true);

    final rc = client.command(<String>[
      'seek',
      bucketSeconds.toStringAsFixed(3),
      'absolute',
      'keyframes',
    ]);
    if (rc < 0) return null;

    try {
      await _seekRestartCompleter!.future.timeout(seekTimeout);
    } catch (_) {
      if (_disposed || expectedGen != _generation) return null;
    }

    final frameSource = _frameSource;
    if (frameSource == null || _disposed || expectedGen != _generation) {
      return null;
    }

    if (!frameSource.pollSoftwareFrameReady() &&
        _renderReadyCompleter != null &&
        !_renderReadyCompleter!.isCompleted) {
      try {
        await _renderReadyCompleter!.future.timeout(
          const Duration(milliseconds: 90),
        );
      } catch (error) {
        developer.log(
          '等待软件帧渲染回调超时',
          name: 'konata.mpv_thumbnail_service',
          error: error,
        );
      }
      frameSource.pollSoftwareFrameReady();
    }

    if (_disposed || expectedGen != _generation) return null;
    final alignedW = LibMpvSoftwareFrameSource.alignDimension(decodeWidth);
    final alignedH = LibMpvSoftwareFrameSource.alignDimension(decodeHeight);
    return frameSource.renderSoftwareFrameBmp(
      width: alignedW,
      height: alignedH,
    );
  }

  Future<void> _resetSessionOnly({bool clearCache = true}) async {
    ++_generation;
    _idleReleaseTimer?.cancel();
    _idleReleaseTimer = null;
    _isWarmedUp = false;
    _isWarmingUp = false;
    _isExtracting = false;
    _isUserHovering = false;
    _pendingUserBucket = null;
    _chapterPrefetchQueue.clear();
    if (clearCache) {
      _cache.clear();
    }

    if (_fileLoadedCompleter != null && !_fileLoadedCompleter!.isCompleted) {
      _fileLoadedCompleter!.complete();
    }
    if (_seekRestartCompleter != null && !_seekRestartCompleter!.isCompleted) {
      _seekRestartCompleter!.complete();
    }
    if (_renderReadyCompleter != null && !_renderReadyCompleter!.isCompleted) {
      _renderReadyCompleter!.complete();
    }

    await _eventSub?.cancel();
    _eventSub = null;
    await _renderSub?.cancel();
    _renderSub = null;

    final fs = _frameSource;
    _frameSource = null;
    fs?.releaseSoftwareRenderer();

    final client = _client;
    _client = null;
    if (client != null && !client.isDisposed) {
      await client.dispose();
    }

    final token = _streamToken;
    _streamToken = null;
    if (token != null) {
      try {
        await streamBridge.unregisterSession(token);
      } catch (error) {
        developer.log(
          '注销缩略图流网桥会话异常已捕获',
          name: 'konata.mpv_thumbnail_service',
          error: error,
        );
      }
    }
  }

  /// 立即释放当前缩略图解码实例、软件渲染上下文并注销网络流会话。
  Future<void> release() async {
    if (_disposed) return;
    _disposed = true;
    await _resetSessionOnly();
  }

  @override
  void dispose() {
    if (!_disposed) {
      _disposed = true;
      unawaited(_resetSessionOnly());
    }
    super.dispose();
  }
}
