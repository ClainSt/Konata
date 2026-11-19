import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../domain/models/media_source.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/playback/playback_probe_stats.dart';
import '../logging/diagnostics_log_store.dart';
import '../sources/byte_stream_source_gateway.dart';
import '../sources/local_source_gateway.dart';
import '../sources/source_gateway_factory.dart';
import '../stream_bridge/local_stream_bridge.dart';
import 'libmpv_ffi.dart';
import 'mpv_quality_profile.dart';

/// 缩略图时间桶量化与有界 LRU 内存缓存（支持抽帧等待期邻近帧无闪烁兜底）。
class ThumbnailBucketCache {
  /// 创建缩略图 LRU 缓存。
  ThumbnailBucketCache({this.capacity = 48}) : assert(capacity > 0);

  /// 最大缓存缩略图数量。
  final int capacity;

  final LinkedHashMap<int, ({double bucketSeconds, Uint8List bytes})> _entries =
      LinkedHashMap();

  /// 当前已缓存缩略图数量。
  int get length => _entries.length;

  /// 将目标时间（秒）按本地/远程策略量化到对应时间桶。
  ///
  /// - 本地源默认精细分桶（`1.0s`）；
  /// - WebDAV / SMB 远程源默认 `5.0s` 时间桶量化，降低跨网 Range 请求频次。
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

  /// 是否已缓存指定时间桶。
  bool containsBucket(double bucketSeconds) {
    return _entries.containsKey(_keyFor(bucketSeconds));
  }

  /// 读取精确命中时间桶并刷新 LRU 活跃度。
  Uint8List? getExact(double bucketSeconds) {
    final key = _keyFor(bucketSeconds);
    final existing = _entries.remove(key);
    if (existing == null) return null;
    _entries[key] = existing;
    return existing.bytes;
  }

  /// 优先查找精确命中，否则在 [maxDistanceSeconds] 内返回距离最近的高缓存邻近帧防闪烁。
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

  /// 写入时间桶帧并在超出 [capacity] 时淘汰最久未使用的条目。
  void put(double bucketSeconds, Uint8List bytes) {
    if (bytes.isEmpty) return;
    final key = _keyFor(bucketSeconds);
    _entries.remove(key);
    _entries[key] = (bucketSeconds: bucketSeconds, bytes: bytes);
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
  }

  /// 清空全部缓存帧。
  void clear() => _entries.clear();
}

/// 面向当前播放源的唯一常驻后台缩略图 `libmpv` 会话（`thumbfast` 机制）。
///
/// 核心保障：
/// - 主视频首帧稳定后静默预热一次 `loadfile` (`pause=yes`) 驻留 MKV `Cues` / `moov` 索引，
///   悬停时仅通过 `seek <sec> absolute keyframes` 抽帧，严禁重复 `loadfile`；
/// - 单并发 `Latest-Wins` 队列（鼠标快速扫过时自动覆盖丢弃中间过期点，绝不抢占主视频连接池）；
/// - 本地精细分桶 / 远程按 `5s` 分桶缓存，空闲时低优预取章节点缩略图。
class MpvThumbnailService extends ChangeNotifier {
  /// 创建针对单条播放源的后台缩略图会话。
  MpvThumbnailService({
    required this.streamBridge,
    this.gatewayFactory = const MediaSourceGatewayFactory(),
    this.logStore,
    this.clientFactory,
    this.localBucketSeconds = 1.0,
    this.remoteBucketSeconds = 5.0,
    int cacheCapacity = 48,
    this.decodeWidth = 192,
    this.decodeHeight = 108,
    this.seekTimeout = const Duration(seconds: 4),
  }) : _cache = ThumbnailBucketCache(capacity: cacheCapacity);

  final LocalStreamBridge streamBridge;
  final MediaSourceGatewayFactory gatewayFactory;
  final DiagnosticsLogStore? logStore;
  final LibMpvClient Function()? clientFactory;
  final double localBucketSeconds;
  final double remoteBucketSeconds;
  final int decodeWidth;
  final int decodeHeight;
  final Duration seekTimeout;

  final ThumbnailBucketCache _cache;

  LibMpvClient? _client;
  LibMpvSoftwareFrameSource? _frameSource;
  StreamSubscription<MpvClientEvent>? _eventSub;
  StreamSubscription<void>? _renderSub;
  String? _streamToken;

  bool _isRemote = false;
  double? _durationSeconds;
  bool _isWarmedUp = false;
  bool _isExtracting = false;
  bool _isUserHovering = false;
  bool _disposed = false;
  int _generation = 0;

  double? _pendingUserBucket;
  final Queue<double> _chapterPrefetchQueue = Queue<double>();
  Completer<void>? _fileLoadedCompleter;
  Completer<void>? _seekRestartCompleter;
  Completer<void>? _renderReadyCompleter;

  static const Duration defaultWarmupDelay = Duration(milliseconds: 800);

  /// 是否已完成预热并可响应悬停抽帧。
  bool get isWarmedUp => _isWarmedUp;

  /// 当前已缓存的缩略图数量。
  int get cachedCount => _cache.length;

  /// 当前挂起待抽取的用户目标时间桶（用于状态验证与单测断言）。
  double? get pendingUserBucket => _pendingUserBucket;

  /// 静默预热后台 `libmpv` 缩略图会话并驻留容器关键帧索引（仅调用一次 `loadfile`）。
  Future<void> warmUp({
    required MediaVariant variant,
    MediaSource? source,
    List<PlaybackChapter> chapters = const [],
    double? durationSeconds,
  }) async {
    if (_disposed) return;
    if (clientFactory == null && Platform.environment.containsKey('FLUTTER_TEST')) {
      return;
    }

    await _resetSessionOnly();
    if (_disposed) return;

    final gen = ++_generation;
    _isRemote = source != null && source.kind != MediaSourceKind.local;
    _durationSeconds = durationSeconds;

    String mediaTarget;
    if (source == null || source.kind == MediaSourceKind.local) {
      mediaTarget = source == null
          ? variant.relativePath
          : LocalSourceGateway(rootPath: source.location)
              .resolveAbsolutePath(variant.relativePath);
    } else {
      final gw = await gatewayFactory.create(source);
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
      );
      if (_disposed || gen != _generation) {
        await streamBridge.unregisterSession(reg.token);
        return;
      }
      _streamToken = reg.token;
      mediaTarget = reg.url.toString();
    }

    LibMpvClient client;
    try {
      client = clientFactory != null ? clientFactory!() : FfiLibMpvClient.create();
    } catch (e) {
      logStore?.record('mpv-thumb', '创建缩略图实例失败: $e', isError: true);
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
      logStore?.record(
        'mpv-thumb',
        '初始化缩略图实例失败: ${client.errorString(initRc)}',
        isError: true,
      );
      await _resetSessionOnly();
      return;
    }

    if (client is LibMpvSoftwareFrameSource) {
      final fs = client as LibMpvSoftwareFrameSource;
      final alignedW = LibMpvSoftwareFrameSource.alignDimension(decodeWidth);
      final alignedH = LibMpvSoftwareFrameSource.alignDimension(decodeHeight);
      if (!fs.initSoftwareRenderer(width: alignedW, height: alignedH)) {
        logStore?.record('mpv-thumb', '初始化软件渲染缩略图上下文失败', isError: true);
        await _resetSessionOnly();
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

    final loadRc = client.command(['loadfile', mediaTarget, 'replace']);
    if (loadRc < 0) {
      logStore?.record(
        'mpv-thumb',
        '预热载入媒体失败: ${client.errorString(loadRc)}',
        isError: true,
      );
      await _resetSessionOnly();
      return;
    }

    try {
      await _fileLoadedCompleter!.future.timeout(const Duration(seconds: 10));
    } catch (error) {
      developer.log('可恢复异常已记录', name: 'konata.mpv_thumbnail_service', error: error);
    }

    if (_disposed || gen != _generation || _client == null) return;
    _isWarmedUp = true;
    updateChapters(chapters, durationSeconds: durationSeconds);
    unawaited(_pumpQueue());
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

  /// 更新章节列表并将尚未缓存的章节点加入低优空闲预取队列。
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

  /// 提交用户进度条悬停/拖拽目标时间（单并发 `Latest-Wins`：仅保留最新目标，丢弃滑过中间点）。
  void requestPreview(double? targetSeconds) {
    if (_disposed) return;
    if (targetSeconds == null || !targetSeconds.isFinite) {
      _isUserHovering = false;
      _pendingUserBucket = null;
      if (_isWarmedUp && !_isExtracting && _chapterPrefetchQueue.isNotEmpty) {
        unawaited(_pumpQueue());
      }
      return;
    }

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
    }
  }

  /// 查询精确或邻近缓存帧字节（抽帧等待期返回邻近缓存帧以消除画面闪烁）。
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
    }
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

    final rc = client.command([
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
      developer.log('可恢复异常已记录', name: 'konata.mpv_thumbnail_service', error: error);
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

  Future<void> _resetSessionOnly() async {
    ++_generation;
    _isWarmedUp = false;
    _isExtracting = false;
    _isUserHovering = false;
    _pendingUserBucket = null;
    _chapterPrefetchQueue.clear();
    _cache.clear();

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
      developer.log('可恢复异常已记录', name: 'konata.mpv_thumbnail_service', error: error);
    }
    }
  }

  /// 立即终止后台缩略图会话、释放 `mpv_render_context`、销毁 `mpv_handle` 并注销流网桥。
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
