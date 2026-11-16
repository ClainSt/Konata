import 'dart:async';
import 'dart:collection';

/// 网络请求优先级通道类型。
enum RequestPriority {
  /// 前台交互通道（海报墙封面、详情页、手动纠错搜索）。
  interactive,

  /// 后台批量刮削通道（受限流、退避与在途去重约束）。
  background,
}

/// HTTP 429 限流异常（携带服务端建议的等待时长）。
class RateLimitedHttpException implements Exception {
  /// 创建限流异常。
  const RateLimitedHttpException(this.retryAfter, [this.message = 'HTTP 429']);

  /// 建议退避等待时长。
  final Duration retryAfter;

  /// 描述信息。
  final String message;

  @override
  String toString() => 'RateLimitedHttpException($message, $retryAfter)';
}

/// 物理隔离前后台队列的双优先级 HTTP 调度器。
///
/// - `InteractiveChannel`：默认最大并发 6，高优立即调度，不被后台刮削阻塞；
/// - `BackgroundChannel`：默认最大并发 3，支持在途相同键去重与 429 指数退避冷却。
class PriorityHttpScheduler {
  /// 创建双通道调度器。
  PriorityHttpScheduler({
    this.interactiveConcurrency = 6,
    this.backgroundConcurrency = 3,
    this.maxRetries = 3,
  });

  /// 前台交互通道最大并发数。
  final int interactiveConcurrency;

  /// 后台批量通道最大并发数。
  final int backgroundConcurrency;

  /// 429 限流最大重试次数。
  final int maxRetries;

  int _interactiveActive = 0;
  final Queue<Completer<void>> _interactiveQueue = Queue();

  int _backgroundActive = 0;
  final Queue<Completer<void>> _backgroundQueue = Queue();

  final Map<String, Future<Object?>> _inflightBackground = {};
  DateTime _backgroundCooldownUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// 当前处于排队或执行中的后台任务数（测试可观测）。
  int get backgroundActiveCount => _backgroundActive;

  /// 当前处于排队或执行中的前台任务数（测试可观测）。
  int get interactiveActiveCount => _interactiveActive;

  /// 在指定优先级通道中调度请求。
  ///
  /// 当 [priority] 为 [RequestPriority.background] 且提供了 [dedupeKey] 时，
  /// 在途相同的 [dedupeKey] 会自动合并为一次真实网络请求。
  Future<T> schedule<T>(
    RequestPriority priority,
    Future<T> Function() task, {
    String? dedupeKey,
  }) async {
    if (priority == RequestPriority.interactive) {
      return _runInChannel(
        queue: _interactiveQueue,
        isFull: () => _interactiveActive >= interactiveConcurrency,
        increment: () => _interactiveActive++,
        decrement: () => _interactiveActive--,
        action: task,
      );
    }

    if (dedupeKey != null && _inflightBackground.containsKey(dedupeKey)) {
      final shared = await _inflightBackground[dedupeKey]!;
      return shared as T;
    }

    final future = _runBackgroundWithRetry(task);
    if (dedupeKey != null) {
      _inflightBackground[dedupeKey] = future;
    }
    try {
      return await future;
    } finally {
      if (dedupeKey != null) {
        _inflightBackground.remove(dedupeKey);
      }
    }
  }

  Future<T> _runBackgroundWithRetry<T>(Future<T> Function() task) async {
    var attempt = 0;
    while (true) {
      final now = DateTime.now();
      if (_backgroundCooldownUntil.isAfter(now)) {
        await Future<void>.delayed(_backgroundCooldownUntil.difference(now));
      }

      try {
        return await _runInChannel(
          queue: _backgroundQueue,
          isFull: () => _backgroundActive >= backgroundConcurrency,
          increment: () => _backgroundActive++,
          decrement: () => _backgroundActive--,
          action: task,
        );
      } on RateLimitedHttpException catch (e) {
        attempt++;
        if (attempt > maxRetries) rethrow;
        final backoffMs = e.retryAfter.inMilliseconds * (1 << (attempt - 1));
        final wait = Duration(milliseconds: backoffMs.clamp(200, 30000));
        final nextAllowed = DateTime.now().add(wait);
        if (nextAllowed.isAfter(_backgroundCooldownUntil)) {
          _backgroundCooldownUntil = nextAllowed;
        }
      }
    }
  }

  Future<T> _runInChannel<T>({
    required Queue<Completer<void>> queue,
    required bool Function() isFull,
    required void Function() increment,
    required void Function() decrement,
    required Future<T> Function() action,
  }) async {
    if (isFull()) {
      final ready = Completer<void>();
      queue.add(ready);
      await ready.future;
    } else {
      increment();
    }

    try {
      return await action();
    } finally {
      if (queue.isEmpty) {
        decrement();
      } else {
        queue.removeFirst().complete();
      }
    }
  }
}
