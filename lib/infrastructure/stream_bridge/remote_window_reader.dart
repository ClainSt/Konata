import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../sources/byte_stream_source_gateway.dart';

/// 远程分块读取配置，严格限制单请求窗口与会话缓存容量。
abstract final class RemoteWindowConfig {
  static const int firstWindowBytes = 1024 * 1024;
  static const int windowBytes = 4 * 1024 * 1024;
  static const int maxCachedBytes = 32 * 1024 * 1024;
}

/// 远程文件的只读分块流：下游持续收字节，上游分段 Range。
///
/// 职责边界：
/// - 完整分块放入 LRU，短区间不额外读取；取消立即传递给上游；
/// - 独占流网桥重试预算（最多 2 次、总墙钟 <= 8 秒，认证终态 401/403 与 404 立即终止）；
/// - 已交付前 `N` 字节后的断流续传必须核验强验证器一致且响应为 `206`、起点严格等于 `windowStart + N`，
///   遇 `200` 整包或文件换版立即熔断，严禁错位拼接。
class RemoteWindowReader {
  RemoteWindowReader({
    required this.gateway,
    required this.relativePath,
    required this.totalLength,
    this.maxRetries = SourceRetryPolicy.maxRetries,
    this.maxRetryWallClock = SourceRetryPolicy.maxWallClockBudget,
  });

  final ByteRangeReadableGateway gateway;
  final String relativePath;
  final int totalLength;
  final int maxRetries;
  final Duration maxRetryWallClock;

  final Map<int, Uint8List> _cached = {};
  final Map<int, Completer<Uint8List?>> _inflight = {};
  int _cachedBytes = 0;
  String? _lockedStrongValidator;

  int get cachedBytes => _cachedBytes;

  /// 当前会话已锁定的上游强验证器（强 ETag）。
  String? get lockedStrongValidator => _lockedStrongValidator;

  ({int offset, Uint8List data})? _lookup(int position) {
    for (final entry in _cached.entries.toList()) {
      if (position >= entry.key && position < entry.key + entry.value.length) {
        _cached.remove(entry.key);
        _cached[entry.key] = entry.value;
        return (offset: entry.key, data: entry.value);
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

  /// 返回普通单订阅字节流。使用显式订阅避免 async* 取消等待一个
  /// 已挂起的上游网络读取，确保播放 Seek/关闭可以立刻断开旧 Range。
  Stream<List<int>> read({required int start, required int endInclusive}) {
    late StreamController<List<int>> controller;
    StreamSubscription<List<int>>? activeUpstream;
    Completer<void>? activeWindowDone;
    var canceled = false;

    Future<void> cancel() async {
      canceled = true;
      final active = activeUpstream;
      if (active != null) {
        await active.cancel();
      }
      final done = activeWindowDone;
      if (done != null && !done.isCompleted) done.complete();
    }

    Future<void> pump() async {
      var cursor = start;
      try {
        while (!canceled && cursor <= endInclusive) {
          final hit = _lookup(cursor);
          if (hit != null) {
            final index = cursor - hit.offset;
            final count = (endInclusive - cursor + 1).clamp(
              0,
              hit.data.length - index,
            );
            controller.add(
              Uint8List.sublistView(hit.data, index, index + count),
            );
            cursor += count;
            continue;
          }

          // 只合并同一起始位置的在途请求。远距离 Seek 不等待片头，
          // 同起点的请求也设置很短的等待上限，避免挂死。
          final pending = _inflight[cursor];
          if (pending != null) {
            final shared = await Future.any<Uint8List?>([
              pending.future,
              Future<Uint8List?>.delayed(const Duration(milliseconds: 100)),
            ]);
            if (canceled) break;
            if (shared != null) continue;
          }

          final windowStart = cursor;
          final windowSize = cursor == 0
              ? RemoteWindowConfig.firstWindowBytes
              : RemoteWindowConfig.windowBytes;
          final windowEnd = (windowStart + windowSize - 1).clamp(
            windowStart,
            endInclusive < totalLength ? endInclusive : totalLength - 1,
          );
          final requested = windowEnd - windowStart + 1;
          final completeWindow = Completer<Uint8List?>();
          _inflight[windowStart] = completeWindow;
          final builder = BytesBuilder(copy: false);
          var received = 0;
          var finished = false;
          var retryAttempts = 0;
          final retryClock = Stopwatch()..start();

          try {
            while (!canceled && received < requested) {
              final segmentStart = windowStart + received;
              final isMidStreamResume = received > 0;
              try {
                Stream<List<int>> remote;
                if (gateway is ValidatedByteRangeGateway) {
                  final validatedGw = gateway as ValidatedByteRangeGateway;
                  final expectedValidator = isMidStreamResume
                      ? _lockedStrongValidator
                      : _lockedStrongValidator;
                  // 已交付前 N 字节后的断流续传必须具备强验证器，否则禁止拼接
                  if (isMidStreamResume &&
                      (expectedValidator == null ||
                          expectedValidator.isEmpty)) {
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
                  if (isMidStreamResume) {
                    if (!validated.isPartialContent ||
                        validated.start != segmentStart) {
                      await validated.stream.listen(null).cancel();
                      throw const UpstreamRangeMismatchException(
                        '断流续传未返回精确 206 续接起点，拒绝错位拼接',
                      );
                    }
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
                  remote = validated.stream;
                } else {
                  if (isMidStreamResume) {
                    throw const UpstreamRangeMismatchException(
                      '当前网关不支持强验证器 206 一致性续传',
                    );
                  }
                  remote = await gateway.openByteRange(
                    relativePath,
                    start: segmentStart,
                    endInclusive: windowEnd,
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
                    builder.add(chunk);
                    final skip = (cursor - chunkOffset).clamp(0, chunk.length);
                    final take = (endInclusive - cursor + 1).clamp(
                      0,
                      chunk.length - skip,
                    );
                    if (take > 0) {
                      controller.add(
                        Uint8List.fromList(chunk.sublist(skip, skip + take)),
                      );
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
            final bytes = builder.takeBytes();
            _store(windowStart, bytes);
            completeWindow.complete(bytes);
            finished = true;
          } finally {
            if (!finished && !completeWindow.isCompleted) {
              completeWindow.complete(null);
            }
            if (identical(_inflight[windowStart], completeWindow)) {
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

  void clear() {
    _cached.clear();
    _cachedBytes = 0;
    _lockedStrongValidator = null;
  }
}
