import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:engine_scraping/engine_scraping.dart';
import 'package:engine_sources/engine_sources.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:path/path.dart' as p;

import 'scan_thumbnail_scheduler.dart';

/// 单次高清扫图内存流式拉取句柄（支持取消令牌即时中止并安全释放上游连接）。
final class ScanImageLoadHandle {
  /// 创建流式加载句柄。
  ScanImageLoadHandle({
    required this.future,
    required this._onCancel,
  });

  /// 解析完成后的原始图像字节流；若已被取消则返回 `null`。
  final Future<Uint8List?> future;

  final Future<void> Function() _onCancel;
  bool _cancelled = false;

  /// 当前加载句柄是否已收到取消指令。
  bool get isCancelled => _cancelled;

  /// 立即中止在途字节流并关闭底层网关连接。
  Future<void> cancel() {
    _cancelled = true;
    return _onCancel();
  }
}

/// 内存滑窗中缓存的单张原图条目（严禁写入磁盘）。
final class ScanMemoryWindowEntry {
  /// 创建滑窗缓存条目。
  ScanMemoryWindowEntry({
    required this.variantId,
    required this.pageIndex,
    required this.bytes,
    this.pixelWidth,
    this.pixelHeight,
    this.onEvict,
  });

  /// 物理扫图变体主键。
  final String variantId;

  /// 当前作用域内的顺序页码下标（用于计算与当前浏览页的距离）。
  final int pageIndex;

  /// 原图内存字节负载。
  final Uint8List bytes;

  /// 已解析的原图像素宽度。
  final int? pixelWidth;

  /// 已解析的原图像素高度。
  final int? pixelHeight;

  /// 从滑窗淘汰或清空时触发的附加释放回调（例如驱逐绘制缓存）。
  final FutureOr<void> Function()? onEvict;

  /// 条目占用的原始字节长度。
  int get byteLength => bytes.length;
}

/// 灯箱有界内存滑窗（默认上限 `96 MiB`，单帧上限 `64 MiB`，超出上限按最远距离淘汰）。
///
/// 核心保证：
/// - 原图字节严格常驻内存滑窗，绝不落盘写入；
/// - 插入新页导致总字节超限时，优先淘汰与 [currentIndex] 距离最远的非固定页（距离相同时按最久未访问淘汰）；
/// - 弹窗关闭或显式清理时立即清空条目并触发 `onEvict` 释放底层解码缓存。
final class ScanLightboxMemoryWindow {
  /// 默认内存滑窗字节上限（96 MiB）。
  static const int defaultMaxTotalBytes = 96 * 1024 * 1024;

  /// 默认单帧安全上限（64 MiB）。
  static const int defaultMaxSingleFrameBytes =
      KonataNetworkConfig.maxScanFullImageBytes;

  /// 创建灯箱有界内存滑窗。
  ScanLightboxMemoryWindow({
    this.maxTotalBytes = defaultMaxTotalBytes,
    this.maxSingleFrameBytes = defaultMaxSingleFrameBytes,
    this.maxEntries,
  }) : assert(maxTotalBytes > 0),
       assert(maxSingleFrameBytes > 0);

  /// 内存滑窗允许占用的总字节上限。
  final int maxTotalBytes;

  /// 单张扫图允许写入滑窗的最大字节护栏。
  final int maxSingleFrameBytes;

  /// 可选最大条数限制（未指定时仅受 [maxTotalBytes] 约束）。
  final int? maxEntries;

  final LinkedHashMap<String, ScanMemoryWindowEntry> _entries =
      LinkedHashMap<String, ScanMemoryWindowEntry>();
  final List<String> _evictedHistory = <String>[];
  int _totalBytes = 0;

  /// 当前滑窗已占用的总字节数。
  int get totalBytes => _totalBytes;

  /// 当前滑窗内缓存的条目数量。
  int get length => _entries.length;

  /// 滑窗当前是否为空。
  bool get isEmpty => _entries.isEmpty;

  /// 按最近淘汰顺序记录的变体标识列表（便于单测与诊断观测）。
  List<String> get evictedVariantIds =>
      List<String>.unmodifiable(_evictedHistory);

  /// 判断指定变体是否在滑窗中（不改变访问序）。
  bool contains(String variantId) => _entries.containsKey(variantId);

  /// 只读查询滑窗中的条目（不改变访问序）。
  ScanMemoryWindowEntry? peek(String variantId) => _entries[variantId];

  /// 命中并刷新条目的最近访问序；未命中返回 `null`。
  ScanMemoryWindowEntry? get(String variantId) {
    final existing = _entries.remove(variantId);
    if (existing != null) {
      _entries[variantId] = existing;
    }
    return existing;
  }

  /// 写入条目并在超出 [maxTotalBytes] 或 [maxEntries] 时按最远距离淘汰旧条目。
  ///
  /// 若单帧超过 [maxSingleFrameBytes] 护栏，拒绝入窗并立即回调 `onEvict` 返回 `false`。
  bool put(
    ScanMemoryWindowEntry entry, {
    int? currentIndex,
    String? pinnedVariantId,
  }) {
    if (entry.byteLength > maxSingleFrameBytes) {
      _invokeEvict(entry);
      return false;
    }

    final replaced = _entries.remove(entry.variantId);
    if (replaced != null) {
      _totalBytes -= replaced.byteLength;
      _invokeEvict(replaced);
    }

    _entries[entry.variantId] = entry;
    _totalBytes += entry.byteLength;

    final focusIndex = currentIndex ?? entry.pageIndex;
    while ((_totalBytes > maxTotalBytes ||
            (maxEntries != null && _entries.length > maxEntries!)) &&
        _entries.length > 1) {
      final victimKey = _selectFurthestVictimKey(
        focusIndex: focusIndex,
        pinnedVariantId: pinnedVariantId,
        justInsertedVariantId: entry.variantId,
      );
      if (victimKey == null) break;
      final victim = _entries.remove(victimKey);
      if (victim != null) {
        _totalBytes -= victim.byteLength;
        _evictedHistory.add(victim.variantId);
        _invokeEvict(victim);
      }
    }
    return true;
  }

  /// 从滑窗中移除指定条目并释放其资源。
  bool remove(String variantId) {
    final removed = _entries.remove(variantId);
    if (removed == null) return false;
    _totalBytes -= removed.byteLength;
    _evictedHistory.add(removed.variantId);
    _invokeEvict(removed);
    return true;
  }

  /// 同步清空滑窗中所有条目并逐个释放缓存资源。
  void clear() {
    if (_entries.isEmpty) return;
    final snapshot = _entries.values.toList(growable: false);
    _entries.clear();
    _totalBytes = 0;
    for (final entry in snapshot) {
      _evictedHistory.add(entry.variantId);
      _invokeEvict(entry);
    }
  }

  String? _selectFurthestVictimKey({
    required int focusIndex,
    required String? pinnedVariantId,
    required String justInsertedVariantId,
  }) {
    String? bestKey;
    var maxDistance = -1;

    // `LinkedHashMap` 按插入/访问时间从旧到新排列，严格大于时替换即可在同距下优先淘汰最久未用项。
    for (final item in _entries.values) {
      if (item.variantId == pinnedVariantId ||
          item.variantId == justInsertedVariantId) {
        continue;
      }
      final distance = (item.pageIndex - focusIndex).abs();
      if (distance > maxDistance) {
        maxDistance = distance;
        bestKey = item.variantId;
      }
    }
    return bestKey;
  }

  void _invokeEvict(ScanMemoryWindowEntry entry) {
    final callback = entry.onEvict;
    if (callback == null) return;
    try {
      final res = callback();
      if (res is Future<void>) {
        unawaited(res.catchError((_) {}));
      }
    } catch (_) {
      // 驱逐回调失败时静默忽略，确保不阻塞内存回收。
    }
  }
}

/// 扫图画集高清原图只读流式加载器（严格零磁盘写入 + 64 MiB 单帧安全护栏）。
final class ScanLightboxLoader {
  /// 创建扫图原图流式加载器。
  const ScanLightboxLoader({
    required this.gatewayFactory,
    this.diagnosticLog,
    this.streamOpener,
    this.maxFullImageBytes = KonataNetworkConfig.maxScanFullImageBytes,
  });

  /// 媒体源只读网关工厂。
  final MediaSourceGatewayFactoryPort gatewayFactory;

  /// 可选结构化诊断日志端口。
  final DiagnosticLogPort? diagnosticLog;

  /// 可选自定义流打开回调（便于离线单元测试注入可控字节流）。
  final ScanSourceStreamOpener? streamOpener;

  /// 单帧原图内存安全上限（默认 `64 MiB`）。
  final int maxFullImageBytes;

  /// 按单帧安全上限流式读取单张扫图原图字节至内存；超限或不支持字节流时抛出 [StateError]。
  ScanImageLoadHandle startLoad({
    required MediaVariant variant,
    required MediaSourceView source,
  }) {
    var cancelled = false;
    StreamSubscription<List<int>>? activeSub;
    Future<void> Function()? closeFn;
    void Function()? abortCollector;

    Future<void> cleanup() async {
      cancelled = true;
      abortCollector?.call();
      abortCollector = null;
      final sub = activeSub;
      activeSub = null;
      if (sub != null) {
        try {
          await sub.cancel();
        } catch (error, stackTrace) {
          diagnosticLog?.logError(
            subsystem: DiagnosticSubsystem.source,
            code: 'SCAN_LIGHTBOX_SUB_CANCEL_FAIL',
            message: '取消扫图原图流订阅失败',
            error: error,
            stackTrace: stackTrace,
            severity: DiagnosticSeverity.warn,
            source: 'feature_scan_viewer:scan_lightbox_loader.dart',
          );
        }
      }
      final close = closeFn;
      closeFn = null;
      if (close != null) {
        try {
          await close();
        } catch (error, stackTrace) {
          diagnosticLog?.logError(
            subsystem: DiagnosticSubsystem.source,
            code: 'SCAN_LIGHTBOX_GW_CLOSE_FAIL',
            message: '关闭扫图原图网关连接失败',
            error: error,
            stackTrace: stackTrace,
            severity: DiagnosticSeverity.warn,
            source: 'feature_scan_viewer:scan_lightbox_loader.dart',
          );
        }
      }
    }

    Future<Uint8List?> run() async {
      if (variant.fileSize > maxFullImageBytes) {
        final limitMb = (maxFullImageBytes / (1024 * 1024)).round();
        throw StateError('单张扫图原图体积超过 $limitMb MiB 内存安全护栏，已中止加载');
      }

      final customOpener = streamOpener;
      if (customOpener != null) {
        try {
          final opened = await customOpener(source, variant, maxFullImageBytes);
          closeFn = opened.close;
          if (cancelled) {
            unawaited(opened.stream.listen(null).cancel());
            await cleanup();
            return null;
          }
          return await _consumeGuardedStream(
            stream: opened.stream,
            isCancelled: () => cancelled,
            onSubscription: (sub) => activeSub = sub,
            onRegisterAbort: (fn) => abortCollector = fn,
          );
        } catch (err) {
          if (cancelled) return null;
          if (err is StateError) rethrow;
          throw StateError(
            SourceAccessErrorClassifier.toChineseMessage(err, source.kind),
          );
        } finally {
          await cleanup();
        }
      }

      final gw = await gatewayFactory.create(source);
      if (cancelled) {
        await gw.close();
        return null;
      }
      closeFn = gw.close;

      if (gw is! ByteRangeReadableGateway) {
        await cleanup();
        throw StateError('当前媒体源不支持流式读取高清大图');
      }

      final byteGw = gw as ByteRangeReadableGateway;
      // 取消冗余长度探测，直接发起单次流式读取：
      // 远程网络与本地传入空终点以兼容整包与范围响应并复用连接池；
      // 局域网共享在已知文件长度时传入精确右边界省去二次往返。
      final int? endInclusive =
          (source.kind == MediaSourceKind.smb && variant.fileSize > 0)
          ? math.min(variant.fileSize, maxFullImageBytes) - 1
          : null;

      try {
        final stream = await byteGw.openByteRange(
          variant.relativePath,
          start: 0,
          endInclusive: endInclusive,
        );
        if (cancelled) {
          unawaited(stream.listen(null).cancel());
          await cleanup();
          return null;
        }
        return await _consumeGuardedStream(
          stream: stream,
          isCancelled: () => cancelled,
          onSubscription: (sub) => activeSub = sub,
          onRegisterAbort: (fn) => abortCollector = fn,
        );
      } catch (err) {
        if (cancelled) return null;
        if (err is StateError) rethrow;
        throw StateError(
          SourceAccessErrorClassifier.toChineseMessage(err, source.kind),
        );
      } finally {
        await cleanup();
      }
    }

    return ScanImageLoadHandle(future: run(), onCancel: cleanup);
  }

  Future<Uint8List?> _consumeGuardedStream({
    required Stream<List<int>> stream,
    required bool Function() isCancelled,
    required void Function(StreamSubscription<List<int>> sub) onSubscription,
    required void Function(void Function() abort) onRegisterAbort,
  }) {
    final builder = BytesBuilder(copy: false);
    final done = Completer<Uint8List?>();
    late final StreamSubscription<List<int>> sub;

    onRegisterAbort(() {
      builder.clear();
      if (!done.isCompleted) {
        done.complete(null);
      }
    });

    sub = stream.listen(
      (chunk) {
        if (isCancelled()) {
          builder.clear();
          unawaited(sub.cancel());
          if (!done.isCompleted) done.complete(null);
          return;
        }
        if (builder.length + chunk.length > maxFullImageBytes) {
          builder.clear();
          unawaited(sub.cancel());
          if (!done.isCompleted) {
            final limitMb = (maxFullImageBytes / (1024 * 1024)).round();
            done.completeError(
              StateError('单张扫图原图流超过 $limitMb MiB 内存安全护栏，已中止读取'),
            );
          }
          return;
        }
        builder.add(chunk);
      },
      onError: (Object err) {
        builder.clear();
        if (!done.isCompleted) done.completeError(err);
      },
      onDone: () {
        if (!done.isCompleted) {
          done.complete(isCancelled() ? null : builder.takeBytes());
        }
      },
      cancelOnError: true,
    );
    onSubscription(sub);
    if (isCancelled()) {
      builder.clear();
      unawaited(sub.cancel());
      if (!done.isCompleted) done.complete(null);
    }
    return done.future;
  }

  /// 异步校验本地原图是否存在并返回规范绝对路径（仅桌面端外部看图调用，零磁盘写入）。
  Future<String?> resolveExistingLocalPath({
    required MediaVariant variant,
    required MediaSourceView source,
  }) async {
    if (source.kind != MediaSourceKind.local) return null;
    final relSegments = variant.relativePath
        .split(RegExp(r'[/\\]+'))
        .where((s) => s.isNotEmpty && s != '.' && s != '..')
        .toList(growable: false);
    if (relSegments.isEmpty) return null;
    final fullPath = p.normalize(p.joinAll([source.location, ...relSegments]));
    final file = File(fullPath);
    if (!file.existsSync()) return null;
    return file.path;
  }
}
