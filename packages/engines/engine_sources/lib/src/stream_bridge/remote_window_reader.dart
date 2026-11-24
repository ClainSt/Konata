import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:konata_contracts/konata_contracts.dart';

/// 远程分块读取配置，严格限制单请求窗口与会话缓存容量。
abstract final class RemoteWindowConfig {
  /// 首窗字节大小（1 MiB）。
  static const int firstWindowBytes = 1024 * 1024;

  /// 常规单窗字节大小（4 MiB）。
  static const int windowBytes = 4 * 1024 * 1024;

  /// 连续顺序流式播放时的自适应最大单窗上限（8 MiB），随机定位立即回落至 4 MiB。
  static const int maxSequentialWindowBytes = 8 * 1024 * 1024;

  /// 单会话窗口缓存最大字节容量（6 MiB）。
  static const int maxCachedBytes = 6 * 1024 * 1024;

  /// 小于等于该阈值的文件全量参与窗口缓存；超大媒体文件仅缓存首尾元数据区。
  static const int fullCacheFileThresholdBytes = 16 * 1024 * 1024;

  /// 超大媒体文件首部与尾部常驻元数据缓存大小（2 MiB）。
  static const int edgeMetadataCacheBytes = 2 * 1024 * 1024;
}

class _PrefetchedSegment {
  _PrefetchedSegment({
    required this.start,
    required this.endInclusive,
    required this.streamFuture,
  });

  final int start;
  final int endInclusive;
  final Future<Stream<List<int>>?> streamFuture;
  bool _disposed = false;

  Future<Stream<List<int>>?> take() async {
    if (_disposed) return null;
    final stream = await streamFuture;
    if (_disposed) {
      if (stream != null) {
        await stream.listen(null).cancel();
      }
      return null;
    }
    return stream;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final stream = await streamFuture;
    if (stream != null) {
      await stream.listen(null).cancel();
    }
  }
}

/// 远程文件的只读分块窗口读取器：下游持续收字节，上游分段区间读取。
///
/// 负责窗口缓存复用、预开启下一连续分段、断流强验证器一致性续传与取消穿透。
class RemoteWindowReader {
  /// 创建远程窗口读取器。
  RemoteWindowReader({
    required this.gateway,
    required this.relativePath,
    required this.totalLength,
    this.maxRetries = SourceRetryPolicy.maxRetries,
    this.maxRetryWallClock = SourceRetryPolicy.maxWallClockBudget,
  });

  /// 底层字节范围可读网关。
  final ByteRangeReadableGateway gateway;

  /// 媒体源中的文件相对路径。
  final String relativePath;

  /// 目标文件总字节长度。
  final int totalLength;

  /// 单次分块最大重试次数。
  final int maxRetries;

  /// 单次分块续传最大墙钟预算。
  final Duration maxRetryWallClock;

  final Map<int, Uint8List> _cached = <int, Uint8List>{};
  final Map<int, Completer<Uint8List?>> _inflight =
      <int, Completer<Uint8List?>>{};
  int _cachedBytes = 0;
  String? _lockedStrongValidator;

  /// 当前已缓存的总字节数。
  int get cachedBytes => _cachedBytes;

  /// 当前会话已锁定的上游强验证器。
  String? get lockedStrongValidator => _lockedStrongValidator;

  ({int offset, Uint8List data})? _lookup(int position) {
    for (final entry in _cached.entries) {
      if (position >= entry.key && position < entry.key + entry.value.length) {
        final key = entry.key;
        final data = entry.value;
        _cached.remove(key);
        _cached[key] = data;
        return (offset: key, data: data);
      }
    }
    return null;
  }

  void _store(int offset, Uint8List bytes) {
    if (bytes.isEmpty) return;
    final previous = _cached.remove(offset);
    if (previous != null) _cachedBytes -= previous.length;
    _cached[offset] = bytes;
    _cachedBytes += bytes.length;
    while (_cachedBytes > RemoteWindowConfig.maxCachedBytes &&
        _cached.isNotEmpty) {
      final oldest = _cached.keys.first;
      _cachedBytes -= _cached.remove(oldest)!.length;
    }
  }

  bool _isNonRetryableError(Object error) {
    if (error is TerminalSourceAuthException ||
        error is UpstreamRangeMismatchException ||
        error is PathNotFoundException) {
      return true;
    }
    final msg = error.toString();
    if (msg.contains('HTTP 403') || msg.contains('HTTP 404')) {
      return true;
    }
    return false;
  }

  static int _resolveWindowSize({
    required int cursor,
    required int sequentialWindows,
  }) {
    if (cursor == 0) {
      return RemoteWindowConfig.firstWindowBytes;
    }
    if (sequentialWindows <= 1) {
      return RemoteWindowConfig.windowBytes;
    }
    if (sequentialWindows == 2) {
      return RemoteWindowConfig.windowBytes * 2;
    }
    return RemoteWindowConfig.maxSequentialWindowBytes;
  }

  Future<Stream<List<int>>> _openUpstreamSegment({
    required int segmentStart,
    required int windowEnd,
    required bool isMidStreamResume,
  }) async {
    if (gateway is ValidatedByteRangeGateway) {
      final validatedGw = gateway as ValidatedByteRangeGateway;
      final expectedValidator = _lockedStrongValidator;
      // 已交付前段字节后的断流续传必须具备强验证器，否则禁止拼接。
      if (isMidStreamResume &&
          (expectedValidator == null || expectedValidator.isEmpty)) {
        throw const UpstreamRangeMismatchException(
          '上游缺少强 ETag 验证器，拒绝断流后继续拼接',
        );
      }
      final validated = await validatedGw.openValidatedByteRange(
        relativePath,
        start: segmentStart,
        endInclusive: windowEnd,
        expectedStrongValidator: expectedValidator,
      );
      if (isMidStreamResume &&
          (!validated.isPartialContent || validated.start != segmentStart)) {
        await validated.stream.listen(null).cancel();
        throw const UpstreamRangeMismatchException(
          '断流续传未返回精确 206 续接起点，拒绝错位拼接',
        );
      }
      final incomingValidator = validated.strongValidator;
      if (_lockedStrongValidator == null &&
          incomingValidator != null &&
          incomingValidator.isNotEmpty) {
        _lockedStrongValidator = incomingValidator;
      } else if (_lockedStrongValidator != null &&
          incomingValidator != null &&
          incomingValidator != _lockedStrongValidator) {
        await validated.stream.listen(null).cancel();
        throw const UpstreamRangeMismatchException(
          '远程文件版本已变更，终止当前流并重新装载',
        );
      }
      return validated.stream;
    }
    if (isMidStreamResume) {
      throw const UpstreamRangeMismatchException(
        '当前网关不支持强验证器 206 一致性续传',
      );
    }
    return gateway.openByteRange(
      relativePath,
      start: segmentStart,
      endInclusive: windowEnd,
    );
  }

  /// 返回普通单订阅字节流，在下游取消或跳转时立即中断上游传输。
  Stream<List<int>> read({required int start, required int endInclusive}) {
    late StreamController<List<int>> controller;
    StreamSubscription<List<int>>? activeUpstream;
    Completer<void>? activeWindowDone;
    _PrefetchedSegment? pendingPrefetch;
    var canceled = false;

    Future<void> disposePendingPrefetch() async {
      final pf = pendingPrefetch;
      pendingPrefetch = null;
      if (pf != null) {
        await pf.dispose();
      }
    }

    Future<void> cancel() async {
      canceled = true;
      unawaited(disposePendingPrefetch());
      final active = activeUpstream;
      if (active != null) {
        await active.cancel();
      }
      final done = activeWindowDone;
      if (done != null && !done.isCompleted) done.complete();
    }

    Future<void> pump() async {
      var cursor = start;
      var sequentialWindows = 0;
      int? lastWindowEnd;
      final effectiveEnd = endInclusive < totalLength
          ? endInclusive
          : totalLength - 1;
      try {
        while (!canceled && cursor <= effectiveEnd) {
          final hit = _lookup(cursor);
          if (hit != null) {
            final index = cursor - hit.offset;
            final count = (effectiveEnd - cursor + 1).clamp(
              0,
              hit.data.length - index,
            );
            controller.add(
              Uint8List.sublistView(hit.data, index, index + count),
            );
            cursor += count;
            continue;
          }

          // 只合并同一起始位置的在途请求，远距离跳转不阻塞等待片头。
          final pending = _inflight[cursor];
          if (pending != null) {
            final shared = await Future.any<Uint8List?>(<Future<Uint8List?>>[
              pending.future,
              Future<Uint8List?>.delayed(const Duration(milliseconds: 100)),
            ]);
            if (canceled) break;
            if (shared != null) continue;
          }

          final windowStart = cursor;
          if (lastWindowEnd != null && windowStart == lastWindowEnd + 1) {
            sequentialWindows += 1;
          } else {
            sequentialWindows = 0;
          }
          final windowSize = _resolveWindowSize(
            cursor: windowStart,
            sequentialWindows: sequentialWindows,
          );
          final windowEnd = (windowStart + windowSize - 1).clamp(
            windowStart,
            effectiveEnd,
          );
          final requested = windowEnd - windowStart + 1;
          final shouldCacheWindow =
              totalLength <= RemoteWindowConfig.fullCacheFileThresholdBytes ||
              windowStart < RemoteWindowConfig.edgeMetadataCacheBytes ||
              windowEnd >=
                  totalLength - RemoteWindowConfig.edgeMetadataCacheBytes;
          final completeWindow = shouldCacheWindow
              ? Completer<Uint8List?>()
              : null;
          if (completeWindow != null) {
            _inflight[windowStart] = completeWindow;
          }
          final builder = shouldCacheWindow ? BytesBuilder(copy: false) : null;
          var received = 0;
          var finished = false;
          var retryAttempts = 0;
          final retryClock = Stopwatch()..start();

          // 若上一窗中段已流水线预开启与当前窗严格吻合的分段，则直接接手。
          Stream<List<int>>? prefetchedRemote;
          final pf = pendingPrefetch;
          pendingPrefetch = null;
          if (pf != null) {
            if (pf.start == windowStart && pf.endInclusive == windowEnd) {
              prefetchedRemote = await pf.take();
            } else {
              unawaited(pf.dispose());
            }
          }
          if (canceled) {
            if (prefetchedRemote != null) {
              await prefetchedRemote.listen(null).cancel();
            }
            if (completeWindow != null && !completeWindow.isCompleted) {
              completeWindow.complete(null);
            }
            if (completeWindow != null &&
                identical(_inflight[windowStart], completeWindow)) {
              _inflight.remove(windowStart);
            }
            break;
          }

          void maybeTriggerNextWindowPrefetch() {
            if (canceled ||
                pendingPrefetch != null ||
                totalLength <= RemoteWindowConfig.fullCacheFileThresholdBytes ||
                windowEnd >= effectiveEnd ||
                received < (requested >> 1)) {
              return;
            }
            if (gateway is ValidatedByteRangeGateway &&
                (_lockedStrongValidator == null ||
                    _lockedStrongValidator!.isEmpty)) {
              return;
            }
            final nextStart = windowEnd + 1;
            if (_lookup(nextStart) != null || _inflight.containsKey(nextStart)) {
              return;
            }
            final nextSize = _resolveWindowSize(
              cursor: nextStart,
              sequentialWindows: sequentialWindows + 1,
            );
            final nextEnd = (nextStart + nextSize - 1).clamp(
              nextStart,
              effectiveEnd,
            );
            final prefetchFuture = _openUpstreamSegment(
              segmentStart: nextStart,
              windowEnd: nextEnd,
              isMidStreamResume: false,
            ).then<Stream<List<int>>?>((s) => s, onError: (_) => null);
            pendingPrefetch = _PrefetchedSegment(
              start: nextStart,
              endInclusive: nextEnd,
              streamFuture: prefetchFuture,
            );
          }

          try {
            while (!canceled && received < requested) {
              final segmentStart = windowStart + received;
              final isMidStreamResume = received > 0;
              try {
                final Stream<List<int>> remote;
                if (!isMidStreamResume && prefetchedRemote != null) {
                  remote = prefetchedRemote;
                  prefetchedRemote = null;
                } else {
                  remote = await _openUpstreamSegment(
                    segmentStart: segmentStart,
                    windowEnd: windowEnd,
                    isMidStreamResume: isMidStreamResume,
                  );
                }

                if (canceled) {
                  await remote.listen(null).cancel();
                  break;
                }

                final done = Completer<void>();
                activeWindowDone = done;
                activeUpstream = remote.listen(
                  (chunk) {
                    if (canceled || chunk.isEmpty) return;
                    final chunkOffset = windowStart + received;
                    received += chunk.length;
                    if (received > requested) {
                      if (!done.isCompleted) {
                        done.completeError(StateError('远程分块返回超出请求范围'));
                      }
                      unawaited(activeUpstream?.cancel());
                      return;
                    }
                    maybeTriggerNextWindowPrefetch();
                    builder?.add(chunk);
                    final skip = (cursor - chunkOffset).clamp(0, chunk.length);
                    final take = (effectiveEnd - cursor + 1).clamp(
                      0,
                      chunk.length - skip,
                    );
                    if (take > 0) {
                      final Uint8List slice;
                      if (chunk is Uint8List) {
                        slice = (skip == 0 && take == chunk.length)
                            ? chunk
                            : Uint8List.sublistView(chunk, skip, skip + take);
                      } else {
                        slice = Uint8List.fromList(
                          chunk.sublist(skip, skip + take),
                        );
                      }
                      controller.add(slice);
                      cursor += take;
                    }
                  },
                  onError: (Object error, StackTrace stack) {
                    if (!done.isCompleted) done.completeError(error, stack);
                  },
                  onDone: () {
                    if (!done.isCompleted) done.complete();
                  },
                  cancelOnError: true,
                );
                if (controller.isPaused) activeUpstream?.pause();
                await done.future;
                if (canceled) break;
                if (received < requested) {
                  throw HttpException(
                    '远程分块提前结束：收到 $received / $requested 字节',
                  );
                }
              } catch (error) {
                await activeUpstream?.cancel();
                activeUpstream = null;
                activeWindowDone = null;
                if (canceled) break;
                if (_isNonRetryableError(error)) {
                  rethrow;
                }
                if (retryAttempts >= maxRetries ||
                    retryClock.elapsed >= maxRetryWallClock) {
                  rethrow;
                }
                retryAttempts += 1;
              }
            }

            if (canceled) break;
            if (received != requested) {
              throw StateError('远程分块提前结束：收到 $received / $requested 字节');
            }
            if (builder != null) {
              final bytes = builder.takeBytes();
              _store(windowStart, bytes);
              completeWindow?.complete(bytes);
            }
            lastWindowEnd = windowEnd;
            finished = true;
          } finally {
            if (prefetchedRemote != null) {
              await prefetchedRemote.listen(null).cancel();
            }
            if (!finished &&
                completeWindow != null &&
                !completeWindow.isCompleted) {
              completeWindow.complete(null);
            }
            if (completeWindow != null &&
                identical(_inflight[windowStart], completeWindow)) {
              _inflight.remove(windowStart);
            }
            await activeUpstream?.cancel();
            activeUpstream = null;
            activeWindowDone = null;
          }
        }
      } catch (error, stack) {
        if (!canceled && !controller.isClosed) {
          controller.addError(error, stack);
        }
      } finally {
        await disposePendingPrefetch();
        if (!canceled && !controller.isClosed) {
          await controller.close();
        }
      }
    }

    controller = StreamController<List<int>>(
      onListen: () => unawaited(pump()),
      onPause: () => activeUpstream?.pause(),
      onResume: () => activeUpstream?.resume(),
      onCancel: cancel,
    );
    return controller.stream;
  }

  /// 清空当前会话缓存与强验证器锁定状态。
  void clear() {
    _cached.clear();
    _cachedBytes = 0;
    _lockedStrongValidator = null;
  }
}
