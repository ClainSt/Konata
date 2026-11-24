import 'dart:async';
import 'dart:collection';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:engine_scraping/engine_scraping.dart';
import 'package:engine_sources/engine_sources.dart';
import 'package:flutter/foundation.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';
import 'package:path/path.dart' as p;

/// 抽象原图流读取回调签名（供生产媒体源网关与离线单元测试模拟流统一注入）。
typedef ScanSourceStreamOpener = Future<({
  Stream<List<int>> stream,
  Future<void> Function() close,
})> Function(MediaSourceView source, MediaVariant variant, int maxBytes);

/// 单个扫图微缩图加载任务的取消凭证。
final class ScanThumbnailTicket {
  ScanThumbnailTicket._(this._onCancel);

  final void Function() _onCancel;
  bool _cancelled = false;

  /// 当前取消凭证是否已被触发。
  bool get isCancelled => _cancelled;

  /// 请求取消该微缩图加载任务（队列中立即移出，下载中立即中止流并关闭网关）。
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _onCancel();
  }
}

final class _QueuedScanJob {
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
  final MediaSourceView source;
  final int maxSide;
  final Completer<Uint8List> completer;
  bool cancelled = false;
  bool preempted = false;
  int runEpoch = 0;
  StreamSubscription<List<int>>? activeSubscription;
  Future<void> Function()? activeClose;
  void Function()? abortCollector;
}

/// 后台隔离线程批量读取本地磁盘图片文件头宽高比（仅读前 64 KB，不做完整位图解码）。
Map<String, double> _probeLocalImageHeaderRatios(
  List<({String variantId, String absPath})> targets,
) {
  const headerReadLimit = 64 * 1024;
  final result = <String, double>{};
  for (final item in targets) {
    RandomAccessFile? raf;
    try {
      final file = File(item.absPath);
      if (!file.existsSync()) continue;
      raf = file.openSync();
      final bytes = raf.readSync(headerReadLimit);
      final ratio = ImageHeaderParser.parseAspectRatio(bytes);
      if (ratio != null) {
        result[item.variantId] = ratio;
      }
    } catch (error) {
      // 单文件损坏或不可读时跳过，由画廊默认比例兜底。
      developer.log(
        '读取本地扫图文件头失败',
        name: 'konata.scan_thumbnail_scheduler',
        error: error,
      );
    } finally {
      try {
        raf?.closeSync();
      } catch (error) {
        developer.log(
          '关闭本地扫图文件头句柄失败',
          name: 'konata.scan_thumbnail_scheduler',
          error: error,
        );
      }
    }
  }
  return result;
}

/// 扫图微缩图三级按源并发调度器与自然宽高比索引中心（严格零原图落盘）。
///
/// 核心调度纪律：
/// 1. 优先零开销命中 `photos/<作品>/scans/<hash>.webp`，并从帧头瞬时还原自然宽高比；
/// 2. 命中失效时按源协议三级隔离调度：
///    - 本地磁盘（[MediaSourceKind.local]）并发上限默认 `4`（LIFO）；
///    - 局域网共享（[MediaSourceKind.smb]）并发上限默认 `2`（LIFO）；
///    - 远程网络（[MediaSourceKind.webdav]）严格串行 `concurrency = 1` + LIFO 栈；
/// 3. 支持引用计数式 [pauseRemote] / [resumeRemote]，让前景灯箱独占远端通道；
/// 4. 划走、切换分组或释放页面触发取消时，立即从队列移出并切断在途流连接。
final class ScanThumbnailScheduler {
  /// 创建扫图微缩图并发调度器。
  ScanThumbnailScheduler({
    required this._photosStorage,
    MediaSourceGatewayFactoryPort? gatewayFactory,
    ScanSourceStreamOpener? streamOpener,
    this._diagnosticLog,
    this.localMaxConcurrency = 4,
    this.smbMaxConcurrency = 2,
    this.maxSourceBytes = 30 * 1024 * 1024,
    this.defaultMaxSide = 360,
  }) : _gatewayFactory = gatewayFactory ?? MediaSourceGatewayFactory(),
       _customStreamOpener = streamOpener;

  final PhotosStorage _photosStorage;
  final MediaSourceGatewayFactoryPort _gatewayFactory;
  final ScanSourceStreamOpener? _customStreamOpener;
  final DiagnosticLogPort? _diagnosticLog;

  /// 本地磁盘源最大并发数（默认 4）。
  final int localMaxConcurrency;

  /// 局域网共享源最大并发数（默认 2）。
  final int smbMaxConcurrency;

  /// 单张扫图微缩图生成期间的最大流式读取上限（默认 30 MiB）。
  final int maxSourceBytes;

  /// 缩略图长边最大像素尺寸（默认 360px）。
  final int defaultMaxSide;

  int _nextJobId = 0;

  // 本地并发 LIFO 栈。
  final List<_QueuedScanJob> _localPending = <_QueuedScanJob>[];
  final Set<_QueuedScanJob> _localActive = <_QueuedScanJob>{};

  // 局域网共享并发上限 2 的 LIFO 栈。
  final ListQueue<_QueuedScanJob> _smbPendingLifo = ListQueue<_QueuedScanJob>();
  final Set<_QueuedScanJob> _smbActive = <_QueuedScanJob>{};

  // 远程单通道串行 LIFO 栈（后进入可视区的卡片优先拉取）。
  final ListQueue<_QueuedScanJob> _webdavPendingLifo =
      ListQueue<_QueuedScanJob>();
  _QueuedScanJob? _webdavActive;

  // 远程通道引用计数暂停锁（用于灯箱浏览原图期间避让背景微缩图）。
  int _remotePauseCount = 0;

  // 已解析的自然宽高比内存索引。
  final Map<String, double> _aspectRatioByVariantId = <String, double>{};

  /// 自然宽高比修订版本号（供等高瀑布流平滑更新已发现比例）。
  final ValueNotifier<int> aspectRatioRevision = ValueNotifier<int>(0);

  bool _disposed = false;

  /// 当前远程微缩图拉取通道是否处于暂停避让状态。
  bool get isRemotePaused => _remotePauseCount > 0;

  /// 当前处于活跃传输中的本地流数量（严格 `<= localMaxConcurrency`）。
  int get activeLocalCount => _localActive.length;

  /// 当前正在排队等待的本地任务数量。
  int get pendingLocalCount => _localPending.length;

  /// 当前处于活跃传输中的远程网络流数量（严格 `<= 1`）。
  int get activeWebDavCount => _webdavActive == null ? 0 : 1;

  /// 当前处于活跃传输中的局域网共享流数量（严格 `<= smbMaxConcurrency`）。
  int get activeSmbCount => _smbActive.length;

  /// 当前处于活跃传输中的全部远程流总数。
  int get activeRemoteCount => activeWebDavCount + activeSmbCount;

  /// 当前正在排队等待的全部远程任务总数。
  int get pendingRemoteCount =>
      _webdavPendingLifo.length + _smbPendingLifo.length;

  /// 查询指定扫图变体已缓存的自然宽高比（未知时返回 `null`）。
  double? cachedAspectRatio(String variantId) =>
      _aspectRatioByVariantId[variantId];

  /// 写入单张扫图测得的自然宽高比，数值发生实质变化时推进修订号。
  void recordAspectRatio(String variantId, double ratio) {
    if (!ratio.isFinite || ratio <= 0) return;
    final clamped = ratio.clamp(
      ImageHeaderParser.minAspectRatio,
      ImageHeaderParser.maxAspectRatio,
    );
    final prev = _aspectRatioByVariantId[variantId];
    if (prev != null && (prev - clamped).abs() < 0.002) return;
    _aspectRatioByVariantId[variantId] = clamped;
    if (!_disposed) {
      aspectRatioRevision.value++;
    }
  }

  /// 暂停后台远程微缩图调度，让前景灯箱独占远端通道。
  ///
  /// 传入 `abortActive: true` 时抢占中止已在途的远程缩略图流并退回队列，
  /// 灯箱关闭调用 [resumeRemote] 后按 LIFO 顺序续传。
  void pauseRemote({bool abortActive = false}) {
    _remotePauseCount++;
    if (!abortActive) return;

    final activeWebdav = _webdavActive;
    if (activeWebdav != null) {
      _webdavActive = null;
      _preemptAndRequeue(activeWebdav, _webdavPendingLifo);
    }
    for (final activeSmb in _smbActive.toList(growable: false)) {
      _smbActive.remove(activeSmb);
      _preemptAndRequeue(activeSmb, _smbPendingLifo);
    }
  }

  void _preemptAndRequeue(
    _QueuedScanJob job,
    ListQueue<_QueuedScanJob> pendingQueue,
  ) {
    if (job.cancelled || _disposed) return;
    job.preempted = true;
    job.runEpoch++;
    job.abortCollector?.call();
    job.abortCollector = null;
    final sub = job.activeSubscription;
    if (sub != null) {
      job.activeSubscription = null;
      unawaited(sub.cancel());
    }
    final closeFn = job.activeClose;
    if (closeFn != null) {
      job.activeClose = null;
      unawaited(_safeClose(closeFn));
    }
    if (!pendingQueue.contains(job)) {
      pendingQueue.addLast(job);
    }
  }

  /// 恢复后台远程微缩图调度并立即驱动待排队任务。
  void resumeRemote() {
    if (_remotePauseCount > 0) {
      _remotePauseCount--;
    }
    if (_remotePauseCount == 0 && !_disposed) {
      _pumpWebDav();
      _pumpSmb();
    }
  }

  /// 仅读取本地已落盘的 `.webp` 微缩图缓存（绝不触发网络请求或原图解码）。
  Future<Uint8List?> readCachedThumbnailOnly({
    required String workId,
    String? workTitle,
    required MediaVariant variant,
  }) async {
    if (_disposed) return null;
    try {
      final cached = await _photosStorage.readScanThumbnail(
        workId: workId,
        title: workTitle,
        variantId: variant.id,
        relativePath: variant.relativePath,
        fileSize: variant.fileSize,
      );
      if (cached != null && cached.isNotEmpty) {
        final ratio = ImageHeaderParser.parseAspectRatio(cached);
        if (ratio != null) {
          recordAspectRatio(variant.id, ratio);
        }
        return cached;
      }
    } catch (error, stackTrace) {
      _logWarn(
        code: 'SCAN_THUMB_CACHE_READ_FAIL',
        message: '只读命中扫图微缩图缓存失败',
        error: error,
        stackTrace: stackTrace,
      );
    }
    return null;
  }

  /// 零远程请求预热一批扫图的自然宽高比：
  /// - 优先读取已落盘 `.webp` 前 32 字节帧头；
  /// - 仅对未缓存的本地磁盘源，在隔离线程中只读文件前 64 KB 解析帧头；
  /// - 对未缓存的远程源严禁发送任何探测包。
  Future<void> prewarmCachedAndLocalAspectRatios({
    required String workId,
    String? workTitle,
    required List<MediaVariant> variants,
    required Map<String, MediaSourceView> sourcesById,
  }) async {
    if (_disposed || variants.isEmpty) return;

    var updated = false;
    final localTargets = <({String variantId, String absPath})>[];

    for (final v in variants) {
      if (_disposed) return;
      if (_aspectRatioByVariantId.containsKey(v.id)) continue;

      try {
        final header = await _photosStorage.readScanThumbnailHeader(
          workId: workId,
          title: workTitle,
          variantId: v.id,
          relativePath: v.relativePath,
          fileSize: v.fileSize,
        );
        if (header != null && header.isNotEmpty) {
          final ratio = ImageHeaderParser.parseAspectRatio(header);
          if (ratio != null) {
            _aspectRatioByVariantId[v.id] = ratio;
            updated = true;
            continue;
          }
        }
      } catch (error, stackTrace) {
        _logWarn(
          code: 'SCAN_THUMB_HEADER_FAIL',
          message: '读取缓存微缩图帧头失败',
          error: error,
          stackTrace: stackTrace,
        );
      }

      final source = sourcesById[v.sourceId];
      if (source != null && source.kind == MediaSourceKind.local) {
        final relSegments = v.relativePath
            .split(RegExp(r'[/\\]+'))
            .where((s) => s.isNotEmpty && s != '.' && s != '..')
            .toList(growable: false);
        if (relSegments.isNotEmpty) {
          final absPath = p.normalize(
            p.joinAll([source.location, ...relSegments]),
          );
          localTargets.add((variantId: v.id, absPath: absPath));
        }
      }
    }

    if (updated && !_disposed) {
      aspectRatioRevision.value++;
    }

    if (localTargets.isEmpty || _disposed) return;

    try {
      final probed = await Isolate.run(
        () => _probeLocalImageHeaderRatios(localTargets),
      );
      if (_disposed || probed.isEmpty) return;
      var localUpdated = false;
      for (final entry in probed.entries) {
        if (!_aspectRatioByVariantId.containsKey(entry.key)) {
          _aspectRatioByVariantId[entry.key] = entry.value;
          localUpdated = true;
        }
      }
      if (localUpdated && !_disposed) {
        aspectRatioRevision.value++;
      }
    } catch (error, stackTrace) {
      _logWarn(
        code: 'SCAN_LOCAL_HEADER_PROBE_FAIL',
        message: '本地扫图文件头宽高比预热失败',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// 提交一次扫图微缩图加载任务，返回结果期约与可即时切断连接的取消凭证。
  ({Future<Uint8List> future, ScanThumbnailTicket ticket}) schedule({
    required String workId,
    String? workTitle,
    required MediaVariant variant,
    required MediaSourceView? source,
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

    // 优先命中本地落盘微缩图缓存（零网络请求）。
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
        final ratio = ImageHeaderParser.parseAspectRatio(cached);
        if (ratio != null) {
          recordAspectRatio(job.variant.id, ratio);
        }
        if (!job.completer.isCompleted) {
          job.completer.complete(cached);
        }
        return;
      }
    } catch (error, stackTrace) {
      // 忽略读缓存瞬态故障，回退源流式生成路径。
      _logWarn(
        code: 'SCAN_THUMB_PRECHECK_FAIL',
        message: '读取扫图微缩图缓存出现可恢复异常',
        error: error,
        stackTrace: stackTrace,
      );
    }

    if (job.cancelled || _disposed) {
      if (!job.completer.isCompleted) {
        job.completer.complete(Uint8List(0));
      }
      return;
    }

    switch (job.source.kind) {
      case MediaSourceKind.local:
        _localPending.add(job);
        _pumpLocal();
      case MediaSourceKind.smb:
        _smbPendingLifo.addLast(job);
        _pumpSmb();
      case MediaSourceKind.webdav:
        _webdavPendingLifo.addLast(job);
        _pumpWebDav();
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
      final epoch = ++next.runEpoch;
      unawaited(
        _runJob(next, epoch).whenComplete(() {
          if (epoch == next.runEpoch) {
            _localActive.remove(next);
            _pumpLocal();
          }
        }),
      );
    }
  }

  void _pumpSmb() {
    while (!_disposed &&
        !isRemotePaused &&
        _smbActive.length < smbMaxConcurrency &&
        _smbPendingLifo.isNotEmpty) {
      final next = _smbPendingLifo.removeLast();
      if (next.cancelled) {
        if (!next.completer.isCompleted) {
          next.completer.complete(Uint8List(0));
        }
        continue;
      }
      _smbActive.add(next);
      next.preempted = false;
      final epoch = ++next.runEpoch;
      unawaited(
        _runJob(next, epoch).whenComplete(() {
          if (epoch == next.runEpoch) {
            _smbActive.remove(next);
            _pumpSmb();
          }
        }),
      );
    }
  }

  void _pumpWebDav() {
    while (!_disposed &&
        !isRemotePaused &&
        _webdavActive == null &&
        _webdavPendingLifo.isNotEmpty) {
      final next = _webdavPendingLifo.removeLast();
      if (next.cancelled) {
        if (!next.completer.isCompleted) {
          next.completer.complete(Uint8List(0));
        }
        continue;
      }
      _webdavActive = next;
      next.preempted = false;
      final epoch = ++next.runEpoch;
      unawaited(
        _runJob(next, epoch).whenComplete(() {
          if (epoch == next.runEpoch && identical(_webdavActive, next)) {
            _webdavActive = null;
            _pumpWebDav();
          }
        }),
      );
    }
  }

  static bool _isJobStale(_QueuedScanJob job, int epoch) =>
      job.preempted || epoch != job.runEpoch;

  static Future<Uint8List> _encodeWebpInIsolate(
    Uint8List rgba,
    int width,
    int height,
  ) => Isolate.run(
    () => CompactWebpEncoder.encodeRgba(rgba: rgba, width: width, height: height),
  );

  Future<void> _runJob(_QueuedScanJob job, int epoch) async {
    if (job.cancelled || _disposed) {
      if (!job.completer.isCompleted) job.completer.complete(Uint8List(0));
      return;
    }
    if (_isJobStale(job, epoch)) return;

    Future<void> Function()? closeFn;
    try {
      // 二次查重：若同文件刚由前一请求写入磁盘则直接复用。
      final secondCheck = await _photosStorage.readScanThumbnail(
        workId: job.workId,
        title: job.workTitle,
        variantId: job.variant.id,
        relativePath: job.variant.relativePath,
        fileSize: job.variant.fileSize,
      );
      if (_isJobStale(job, epoch)) return;
      if (secondCheck != null && secondCheck.isNotEmpty) {
        final ratio = ImageHeaderParser.parseAspectRatio(secondCheck);
        if (ratio != null) {
          recordAspectRatio(job.variant.id, ratio);
        }
        if (!job.completer.isCompleted) {
          job.completer.complete(secondCheck);
        }
        return;
      }

      if (job.cancelled || _disposed) {
        if (!job.completer.isCompleted) job.completer.complete(Uint8List(0));
        return;
      }
      if (_isJobStale(job, epoch)) return;

      final opener = _customStreamOpener ?? _openWithGatewayFactory;
      final opened = await opener(job.source, job.variant, maxSourceBytes);
      closeFn = opened.close;
      if (job.cancelled || _isJobStale(job, epoch) || _disposed) {
        unawaited(opened.stream.listen(null).cancel());
        await _safeClose(closeFn);
        closeFn = null;
        if (!_isJobStale(job, epoch) && !job.completer.isCompleted) {
          job.completer.complete(Uint8List(0));
        }
        return;
      }
      job.activeClose = closeFn;

      final rawBytes = await _collectStreamBytesCancellable(
        job: job,
        epoch: epoch,
        stream: opened.stream,
        maxBytes: maxSourceBytes,
      );
      await _safeClose(closeFn);
      closeFn = null;
      if (!_isJobStale(job, epoch)) {
        job.activeClose = null;
      }

      if (_isJobStale(job, epoch)) return;
      if (job.cancelled || _disposed || rawBytes == null || rawBytes.isEmpty) {
        if (!job.completer.isCompleted) job.completer.complete(Uint8List(0));
        return;
      }

      // 按长边上限硬件降采样解码为像素，并记录原图自然宽高比。
      final decoded = await _decodeDownsampledRgba(rawBytes, job.maxSide);
      if (_isJobStale(job, epoch)) return;
      if (job.cancelled || _disposed || decoded == null) {
        if (!job.completer.isCompleted) job.completer.complete(Uint8List(0));
        return;
      }

      if (decoded.srcWidth > 0 && decoded.srcHeight > 0) {
        recordAspectRatio(job.variant.id, decoded.srcWidth / decoded.srcHeight);
      }

      // 后台隔离线程压缩为紧凑微缩图（静态方法隔离，防止捕获不可序列化闭包）。
      final webpBytes = await _encodeWebpInIsolate(
        decoded.rgba,
        decoded.width,
        decoded.height,
      );

      if (_isJobStale(job, epoch)) return;
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
      if (!_isJobStale(job, epoch) && !job.completer.isCompleted) {
        job.completer.complete(webpBytes);
      }
    } catch (error, stackTrace) {
      _logWarn(
        code: 'SCAN_THUMB_BUILD_FAIL',
        message: '生成扫图微缩图任务失败',
        error: error,
        stackTrace: stackTrace,
      );
      if (!_isJobStale(job, epoch) && !job.completer.isCompleted) {
        job.completer.complete(Uint8List(0));
      }
    } finally {
      await _safeClose(closeFn);
      if (!_isJobStale(job, epoch)) {
        job.abortCollector = null;
        job.activeSubscription = null;
        job.activeClose = null;
      }
    }
  }

  Future<Uint8List?> _collectStreamBytesCancellable({
    required _QueuedScanJob job,
    required int epoch,
    required Stream<List<int>> stream,
    required int maxBytes,
  }) async {
    final builder = BytesBuilder(copy: false);
    final done = Completer<Uint8List?>();
    late final StreamSubscription<List<int>> sub;
    bool aborted() =>
        job.cancelled || job.preempted || epoch != job.runEpoch || _disposed;

    job.abortCollector = () {
      builder.clear();
      if (!done.isCompleted) {
        done.complete(null);
      }
    };

    sub = stream.listen(
      (chunk) {
        if (aborted()) {
          builder.clear();
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
        builder.clear();
        if (!done.isCompleted) done.complete(null);
      },
      onDone: () {
        if (!done.isCompleted) {
          done.complete(aborted() ? null : builder.takeBytes());
        }
      },
      cancelOnError: true,
    );
    job.activeSubscription = sub;
    if (aborted()) {
      builder.clear();
      await sub.cancel();
      if (!done.isCompleted) done.complete(null);
    }
    return done.future;
  }

  static Future<({
    Uint8List rgba,
    int width,
    int height,
    int srcWidth,
    int srcHeight,
  })?>
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
        srcWidth: srcW,
        srcHeight: srcH,
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
    job.runEpoch++;
    _localPending.remove(job);
    _smbPendingLifo.remove(job);
    _webdavPendingLifo.remove(job);
    _localActive.remove(job);
    _smbActive.remove(job);
    if (identical(_webdavActive, job)) {
      _webdavActive = null;
    }
    job.abortCollector?.call();
    job.abortCollector = null;
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
      _pumpSmb();
      _pumpWebDav();
    }
  }

  /// 立即清空所有排队中的任务并强制终止所有活跃流（供切页、切换分卷或退出页面调用）。
  void cancelAll() {
    for (final job in _localPending.toList(growable: false)) {
      _cancelJob(job);
    }
    for (final job in _smbPendingLifo.toList(growable: false)) {
      _cancelJob(job);
    }
    for (final job in _webdavPendingLifo.toList(growable: false)) {
      _cancelJob(job);
    }
    for (final job in _localActive.toList(growable: false)) {
      _cancelJob(job);
    }
    for (final job in _smbActive.toList(growable: false)) {
      _cancelJob(job);
    }
    final activeWebdav = _webdavActive;
    if (activeWebdav != null) {
      _cancelJob(activeWebdav);
    }
  }

  /// 释放调度器并中止一切任务。
  void dispose() {
    _disposed = true;
    cancelAll();
    aspectRatioRevision.dispose();
  }

  void _logWarn({
    required String code,
    required String message,
    required Object error,
    StackTrace? stackTrace,
  }) {
    final log = _diagnosticLog;
    if (log != null) {
      log.logError(
        subsystem: DiagnosticSubsystem.storage,
        code: code,
        message: message,
        error: error,
        stackTrace: stackTrace,
        severity: DiagnosticSeverity.warn,
        source: 'feature_scan_viewer:scan_thumbnail_scheduler.dart',
      );
      return;
    }
    developer.log(
      message,
      name: 'konata.scan_thumbnail_scheduler',
      error: error,
      stackTrace: stackTrace,
    );
  }

  Future<void> _safeClose(Future<void> Function()? closeFn) async {
    if (closeFn == null) return;
    try {
      await closeFn();
    } catch (error, stackTrace) {
      // 忽略已断开网关的重复关闭异常。
      _logWarn(
        code: 'SCAN_GATEWAY_CLOSE_IGNORED',
        message: '关闭扫图网关时捕获可恢复异常',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<({
    Stream<List<int>> stream,
    Future<void> Function() close,
  })>
  _openWithGatewayFactory(
    MediaSourceView source,
    MediaVariant variant,
    int maxBytes,
  ) async {
    final gw = await _gatewayFactory.create(source);
    if (gw is! ByteRangeReadableGateway) {
      await gw.close();
      return (stream: const Stream<List<int>>.empty(), close: () async {});
    }
    final byteGw = gw as ByteRangeReadableGateway;
    // 取消冗余探测往返，直接发起单次流式读取：
    // 远程网络源与本地传入空终点以兼容整包与范围响应并复用连接池；
    // 局域网共享在已知文件长度时显式截断右边界以省去网关二次状态查询。
    final int? endInclusive =
        (source.kind == MediaSourceKind.smb && variant.fileSize > 0)
        ? math.min(variant.fileSize, maxBytes) - 1
        : null;
    final stream = await byteGw.openByteRange(
      variant.relativePath,
      start: 0,
      endInclusive: endInclusive,
    );
    return (stream: stream, close: gw.close);
  }
}
