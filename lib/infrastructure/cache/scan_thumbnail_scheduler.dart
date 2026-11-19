import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:developer' as developer;

import '../../domain/models/media_source.dart';
import '../../domain/models/media_variant.dart';
import '../sources/byte_stream_source_gateway.dart';
import '../sources/source_gateway_factory.dart';
import 'compact_webp_encoder.dart';
import 'photos_storage.dart';

/// 抽象原图流读取回调签名（供正常源网关与单元测试可控模拟流统一注入）。
typedef ScanSourceStreamOpener = Future<({
  Stream<List<int>> stream,
  Future<void> Function() close,
})> Function(MediaSource source, MediaVariant variant, int maxBytes);

/// 单个 Scan 微缩图加载任务的取消凭证。
class ScanThumbnailTicket {
  ScanThumbnailTicket._(this._onCancel);

  final void Function() _onCancel;
  bool _cancelled = false;

  /// 请求取消该微缩图加载任务（队列中立即移出，下载中立即 `subscription.cancel()` + `close()`）。
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _onCancel();
  }
}

class _QueuedScanJob {
  _QueuedScanJob({
    required this.id,
    required this.workId,
    required this.workTitle,
    required this.variant,
    required this.source,
    required this.maxSide,
    required this.completer,
  });

  final int id;
  final String workId;
  final String? workTitle;
  final MediaVariant variant;
  final MediaSource source;
  final int maxSide;
  final Completer<Uint8List> completer;
  bool cancelled = false;
  StreamSubscription<List<int>>? activeSubscription;
  Future<void> Function()? activeClose;
}

/// Scan 扫图微缩图并发隔离与串行 LIFO 调度器（零原图落盘）。
///
/// 核心调度纪律：
/// 1. 优先零毫秒直接命中 `photos/<作品> [<tag>]/scans/<hash>.webp`；
/// 2. 命中失效时按源类型调度：
///    - 本地磁盘（[MediaSourceKind.local]）并发上限为 `4`；
///    - 远程源（[MediaSourceKind.webdav] / [MediaSourceKind.smb]）**严格串行 `concurrency = 1` + LIFO 栈**（后入视口优先）；
/// 3. 远程流在内存中限流收集后通过根 Isolate `ui.instantiateImageCodec` 硬件降采样，
///    再抛入 `Isolate.run` 交由 [CompactWebpEncoder] 编码为 15–30 KB 的 `.webp` 后按需写入 `scans/`；
/// 4. 任何离开可视区、切页、切筛选或退出详情页动作触发 `cancel` / `cancelAll` 时，
///    立即清空待排队任务并调用 `StreamSubscription.cancel()` 切断底层远程连接。
class ScanThumbnailScheduler {
  /// 创建 Scan 微缩图调度器。
  ScanThumbnailScheduler({
    required this._photosStorage,
    ScanSourceStreamOpener? streamOpener,
    this.localMaxConcurrency = 4,
    this.maxSourceBytes = 30 * 1024 * 1024,
    this.defaultMaxSide = 360,
  }) : _streamOpener = streamOpener ?? _defaultStreamOpener;

  final PhotosStorage _photosStorage;
  final ScanSourceStreamOpener _streamOpener;

  /// 本地源最大并发数（默认 4）。
  final int localMaxConcurrency;

  /// 单张远程/本地扫描图最大内存读取上限（默认 30 MB）。
  final int maxSourceBytes;

  /// 缩略图最大边长（默认 360px）。
  final int defaultMaxSide;

  int _nextJobId = 0;

  // 本地并发队列（FIFO/LIFO）
  final List<_QueuedScanJob> _localPending = <_QueuedScanJob>[];
  final Set<_QueuedScanJob> _localActive = <_QueuedScanJob>{};

  // 远程源严格单通道串行 LIFO 栈（后加入的当前可视卡片最先执行）
  final ListQueue<_QueuedScanJob> _remotePendingLifo =
      ListQueue<_QueuedScanJob>();
  _QueuedScanJob? _remoteActive;

  bool _disposed = false;

  /// 当前处于活跃传输中的远程流数量（供并发测试精确断言 `<= 1`）。
  int get activeRemoteCount => _remoteActive == null ? 0 : 1;

  /// 当前正在排队等待的远程任务数量。
  int get pendingRemoteCount => _remotePendingLifo.length;

  /// 提交一次 Scan 缩略图加载请求，返回包含 Future 结果与可随时触发切断的取消凭证。
  ({Future<Uint8List> future, ScanThumbnailTicket ticket}) schedule({
    required String workId,
    String? workTitle,
    required MediaVariant variant,
    required MediaSource? source,
    int? maxSide,
  }) {
    final completer = Completer<Uint8List>();
    if (_disposed || source == null) {
      completer.complete(Uint8List(0));
      return (
        future: completer.future,
        ticket: ScanThumbnailTicket._(() {}),
      );
    }

    final job = _QueuedScanJob(
      id: ++_nextJobId,
      workId: workId,
      workTitle: workTitle,
      variant: variant,
      source: source,
      maxSide: maxSide ?? defaultMaxSide,
      completer: completer,
    );

    final ticket = ScanThumbnailTicket._(() => _cancelJob(job));
    unawaited(_startOrEnqueue(job));
    return (future: completer.future, ticket: ticket);
  }

  Future<void> _startOrEnqueue(_QueuedScanJob job) async {
    if (job.cancelled || _disposed) {
      if (!job.completer.isCompleted) {
        job.completer.complete(Uint8List(0));
      }
      return;
    }

    // 1. 优先命中 `photos/<work>/scans/<hash>.webp` 磁盘缓存（0 网络开销）
    try {
      final cached = await _photosStorage.readScanThumbnail(
        workId: job.workId,
        title: job.workTitle,
        variantId: job.variant.id,
        relativePath: job.variant.relativePath,
        fileSize: job.variant.fileSize,
      );
      if (job.cancelled || _disposed) {
        if (!job.completer.isCompleted) {
          job.completer.complete(Uint8List(0));
        }
        return;
      }
      if (cached != null && cached.isNotEmpty) {
        if (!job.completer.isCompleted) {
          job.completer.complete(cached);
        }
        return;
      }
    } catch (error) {
      // 忽略读缓存瞬态错误，继续走流式生成路径。
      developer.log('可恢复异常已记录', name: 'konata.scan_thumbnail_scheduler', error: error);
    }

    if (job.cancelled || _disposed) {
      if (!job.completer.isCompleted) {
        job.completer.complete(Uint8List(0));
      }
      return;
    }

    if (job.source.kind == MediaSourceKind.local) {
      _localPending.add(job);
      _pumpLocal();
    } else {
      // 远程源一律入 LIFO 栈尾，出队时从末尾取（最新进入视口的卡片优先加载）
      _remotePendingLifo.addLast(job);
      _pumpRemote();
    }
  }

  void _pumpLocal() {
    while (!_disposed &&
        _localActive.length < localMaxConcurrency &&
        _localPending.isNotEmpty) {
      final next = _localPending.removeLast();
      if (next.cancelled) {
        if (!next.completer.isCompleted) {
          next.completer.complete(Uint8List(0));
        }
        continue;
      }
      _localActive.add(next);
      unawaited(
        _runJob(next).whenComplete(() {
          _localActive.remove(next);
          _pumpLocal();
        }),
      );
    }
  }

  void _pumpRemote() {
    while (!_disposed &&
        _remoteActive == null &&
        _remotePendingLifo.isNotEmpty) {
      final next = _remotePendingLifo.removeLast();
      if (next.cancelled) {
        if (!next.completer.isCompleted) {
          next.completer.complete(Uint8List(0));
        }
        continue;
      }
      _remoteActive = next;
      unawaited(
        _runJob(next).whenComplete(() {
          if (identical(_remoteActive, next)) {
            _remoteActive = null;
          }
          _pumpRemote();
        }),
      );
    }
  }

  Future<void> _runJob(_QueuedScanJob job) async {
    if (job.cancelled || _disposed) {
      if (!job.completer.isCompleted) job.completer.complete(Uint8List(0));
      return;
    }

    Future<void> Function()? closeFn;
    try {
      // 二次查重（若同文件刚由前一请求生成则无需再次拉流）
      final secondCheck = await _photosStorage.readScanThumbnail(
        workId: job.workId,
        title: job.workTitle,
        variantId: job.variant.id,
        relativePath: job.variant.relativePath,
        fileSize: job.variant.fileSize,
      );
      if (secondCheck != null && secondCheck.isNotEmpty) {
        if (!job.completer.isCompleted) {
          job.completer.complete(secondCheck);
        }
        return;
      }

      if (job.cancelled || _disposed) {
        if (!job.completer.isCompleted) job.completer.complete(Uint8List(0));
        return;
      }

      final opened = await _streamOpener(job.source, job.variant, maxSourceBytes);
      closeFn = opened.close;
      job.activeClose = closeFn;
      if (job.cancelled || _disposed) {
        await _safeClose(closeFn);
        if (!job.completer.isCompleted) job.completer.complete(Uint8List(0));
        return;
      }

      final rawBytes = await _collectStreamBytesCancellable(
        job: job,
        stream: opened.stream,
        maxBytes: maxSourceBytes,
      );
      await _safeClose(closeFn);
      closeFn = null;
      job.activeClose = null;

      if (job.cancelled || _disposed || rawBytes == null || rawBytes.isEmpty) {
        if (!job.completer.isCompleted) job.completer.complete(Uint8List(0));
        return;
      }

      // 根 Isolate C++ 引擎按长边 <= maxSide 硬件降采样转 RGBA 并立即释放原图引用
      final decoded = await _decodeDownsampledRgba(rawBytes, job.maxSide);
      if (job.cancelled || _disposed || decoded == null) {
        if (!job.completer.isCompleted) job.completer.complete(Uint8List(0));
        return;
      }

      // 后台 Isolate 压缩编码为紧凑 .webp 字节（15–30 KB）
      final rgba = decoded.rgba;
      final w = decoded.width;
      final h = decoded.height;
      final webpBytes = await Isolate.run(
        () => CompactWebpEncoder.encodeRgba(rgba: rgba, width: w, height: h),
      );

      if (job.cancelled || _disposed) {
        if (!job.completer.isCompleted) job.completer.complete(Uint8List(0));
        return;
      }

      await _photosStorage.writeScanThumbnail(
        workId: job.workId,
        title: job.workTitle,
        variantId: job.variant.id,
        relativePath: job.variant.relativePath,
        fileSize: job.variant.fileSize,
        webpBytes: webpBytes,
      );
      if (!job.completer.isCompleted) {
        job.completer.complete(webpBytes);
      }
    } catch (_) {
      if (!job.completer.isCompleted) {
        job.completer.complete(Uint8List(0));
      }
    } finally {
      await _safeClose(closeFn);
      job.activeSubscription = null;
      job.activeClose = null;
    }
  }

  Future<Uint8List?> _collectStreamBytesCancellable({
    required _QueuedScanJob job,
    required Stream<List<int>> stream,
    required int maxBytes,
  }) async {
    final builder = BytesBuilder(copy: false);
    final done = Completer<Uint8List?>();
    late final StreamSubscription<List<int>> sub;

    sub = stream.listen(
      (chunk) {
        if (job.cancelled || _disposed) {
          unawaited(sub.cancel());
          if (!done.isCompleted) done.complete(null);
          return;
        }
        builder.add(chunk);
        if (builder.length >= maxBytes) {
          unawaited(sub.cancel());
          if (!done.isCompleted) done.complete(builder.takeBytes());
        }
      },
      onError: (_) {
        if (!done.isCompleted) done.complete(null);
      },
      onDone: () {
        if (!done.isCompleted) {
          done.complete(job.cancelled ? null : builder.takeBytes());
        }
      },
      cancelOnError: true,
    );
    job.activeSubscription = sub;
    if (job.cancelled || _disposed) {
      await sub.cancel();
      if (!done.isCompleted) done.complete(null);
    }
    return done.future;
  }

  static Future<({Uint8List rgba, int width, int height})?>
  _decodeDownsampledRgba(Uint8List rawBytes, int maxSide) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.FrameInfo? frame;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(rawBytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final srcW = descriptor.width;
      final srcH = descriptor.height;
      if (srcW <= 0 || srcH <= 0) return null;

      int? targetWidth;
      int? targetHeight;
      if (math.max(srcW, srcH) > maxSide) {
        if (srcW >= srcH) {
          targetWidth = maxSide;
        } else {
          targetHeight = maxSide;
        }
      }

      codec = await descriptor.instantiateCodec(
        targetWidth: targetWidth,
        targetHeight: targetHeight,
      );
      frame = await codec.getNextFrame();
      final byteData = await frame.image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (byteData == null) return null;
      final outW = frame.image.width;
      final outH = frame.image.height;
      return (
        rgba: byteData.buffer.asUint8List(
          byteData.offsetInBytes,
          byteData.lengthInBytes,
        ),
        width: outW,
        height: outH,
      );
    } catch (_) {
      return null;
    } finally {
      frame?.image.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  void _cancelJob(_QueuedScanJob job) {
    if (job.cancelled) return;
    job.cancelled = true;
    _localPending.remove(job);
    _remotePendingLifo.remove(job);
    _localActive.remove(job);
    if (identical(_remoteActive, job)) {
      _remoteActive = null;
    }
    final sub = job.activeSubscription;
    if (sub != null) {
      unawaited(sub.cancel());
      job.activeSubscription = null;
    }
    final closeFn = job.activeClose;
    if (closeFn != null) {
      unawaited(_safeClose(closeFn));
      job.activeClose = null;
    }
    if (!job.completer.isCompleted) {
      job.completer.complete(Uint8List(0));
    }
    if (!_disposed) {
      _pumpLocal();
      _pumpRemote();
    }
  }

  /// 立即清空所有排队中的任务并强制终止所有活跃远程流（供切页/切标签/退页面调用）。
  void cancelAll() {
    for (final job in _localPending.toList(growable: false)) {
      _cancelJob(job);
    }
    for (final job in _remotePendingLifo.toList(growable: false)) {
      _cancelJob(job);
    }
    for (final job in _localActive.toList(growable: false)) {
      _cancelJob(job);
    }
    final activeRemote = _remoteActive;
    if (activeRemote != null) {
      _cancelJob(activeRemote);
    }
  }

  /// 释放调度器并中止一切任务。
  void dispose() {
    _disposed = true;
    cancelAll();
  }

  static Future<void> _safeClose(Future<void> Function()? closeFn) async {
    if (closeFn == null) return;
    try {
      await closeFn();
    } catch (error) {
      // 忽略已断开网关的重复关闭异常。
      developer.log('可恢复异常已记录', name: 'konata.scan_thumbnail_scheduler', error: error);
    }
  }

  static Future<({
    Stream<List<int>> stream,
    Future<void> Function() close,
  })>
  _defaultStreamOpener(
    MediaSource source,
    MediaVariant variant,
    int maxBytes,
  ) async {
    final gw = await const MediaSourceGatewayFactory().create(source);
    if (gw is! ByteRangeReadableGateway) {
      await gw.close();
      return (stream: const Stream<List<int>>.empty(), close: () async {});
    }
    final byteGw = gw as ByteRangeReadableGateway;
    final len = await byteGw.probeFileLength(variant.relativePath);
    final endInclusive = (len != null && len > 0)
        ? (len > maxBytes ? maxBytes - 1 : len - 1)
        : maxBytes - 1;
    if (endInclusive < 0) {
      await gw.close();
      return (stream: const Stream<List<int>>.empty(), close: () async {});
    }
    final stream = await byteGw.openByteRange(
      variant.relativePath,
      start: 0,
      endInclusive: endInclusive,
    );
    return (stream: stream, close: gw.close);
  }
}
