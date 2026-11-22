import 'dart:async';
import 'dart:collection';

/// 网络请求优先级通道类型。
enum RequestPriority {
  /// 前台交互通道（海报墙封面、详情页、手动纠错搜索）。
  interactive,

  /// 后台批量刮削通道（受按域限流、退避与在途去重约束）。
  background,
}

/// HTTP 429 限流异常（携带服务端建议的等待时长与可选响应摘要以区分频率限流与日额度耗尽）。
class RateLimitedHttpException implements Exception {
  /// 创建限流异常。
  const RateLimitedHttpException(
    this.retryAfter, [
    this.message = 'HTTP 429',
    this.headers = const {},
    this.bodySnippet,
    this.isQuotaExhausted = false,
  ]);

  /// 建议退避等待时长。
  final Duration retryAfter;

  /// 描述信息。
  final String message;

  /// 原始响应头（用于区分 `X-Konata-Relay-Error: rate_limited` 与平台日额度耗尽）。
  final Map<String, String> headers;

  /// 截断后的响应正文片段（用于识别 Cloudflare 1027 或非 JSON 错误页）。
  final String? bodySnippet;

  /// 是否已判定为日额度耗尽（为 `true` 时调度器不再退避重试）。
  final bool isQuotaExhausted;

  @override
  String toString() => 'RateLimitedHttpException($message, $retryAfter)';
}

/// 物理隔离前后台队列与上游域桶的双优先级 HTTP 调度器。
///
/// - `InteractiveChannel`：默认最大并发 6，高优立即调度，不被后台刮削阻塞；
/// - `BackgroundChannel`：按上游域（如 `tmdb`、`bangumi`）独立分桶并发与 429 退避冷却，
///   支持在途相同键去重，避免单域限流拖慢另一数据源吞吐。
class PriorityHttpScheduler {
  /// 创建双通道调度器。
  PriorityHttpScheduler({
    this.interactiveConcurrency = 6,
    this.backgroundConcurrency = defaultBackgroundConcurrency,
    this.maxRetries = 3,
    Map<String, int>? backgroundBucketConcurrency,
  }) : _customBucketLimits = backgroundBucketConcurrency == null
           ? const {}
           : Map<String, int>.unmodifiable(backgroundBucketConcurrency);

  /// 后台通用通道默认并发上限。
  static const int defaultBackgroundConcurrency = 3;

  /// 未显式覆写时的分域后台默认并发上限（平衡吞吐与上游风控）。
  static const Map<String, int> defaultBucketConcurrency = <String, int>{
    'tmdb': 6,
    'bangumi': 4,
    'fanart': 2,
  };

  /// 前台交互通道最大并发数。
  final int interactiveConcurrency;

  /// 后台默认通道最大并发数。
  final int backgroundConcurrency;

  /// 429 限流最大重试次数。
  final int maxRetries;

  final Map<String, int> _customBucketLimits;

  int _interactiveActive = 0;
  final Queue<Completer<void>> _interactiveQueue = Queue();

  final Map<String, _BackgroundBucket> _backgroundBuckets = {};
  final Map<String, Future<Object?>> _inflightBackground = {};

  /// 当前处于执行中的后台任务总数（测试可观测）。
  int get backgroundActiveCount {
    var total = 0;
    for (final bucket in _backgroundBuckets.values) {
      total += bucket.active;
    }
    return total;
  }

  /// 当前处于执行中的前台任务数（测试可观测）。
  int get interactiveActiveCount => _interactiveActive;

  /// 查询指定后台域桶当前实际并发上限（测试可观测，保底不低于 1 防队列饥饿）。
  int concurrencyLimitForBucket(String? bucketKey) {
    final key = _normalizeBucketKey(bucketKey);
    final custom = _customBucketLimits[key];
    if (custom != null && custom > 0) return custom;
    final fallback = backgroundConcurrency < 1 ? 1 : backgroundConcurrency;
    if (key.isNotEmpty &&
        backgroundConcurrency == defaultBackgroundConcurrency) {
      return defaultBucketConcurrency[key] ?? fallback;
    }
    return fallback;
  }

  /// 在指定优先级通道与可选上游域桶中调度请求。
  ///
  /// 当 [priority] 为 [RequestPriority.background] 且提供了 [dedupeKey] 时，
  /// 在途相同的 [dedupeKey] 会自动合并为一次真实网络请求；
  /// [retryOnRateLimit] 为 `false` 时遇到 HTTP 429 立即向调用方上抛（供外层自有熔断器快速降级）。
  Future<T> schedule<T>(
    RequestPriority priority,
    Future<T> Function() task, {
    String? dedupeKey,
    String? bucketKey,
    bool retryOnRateLimit = true,
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

    final bucketName = _normalizeBucketKey(bucketKey);
    final bucket = _backgroundBuckets.putIfAbsent(
      bucketName,
      () => _BackgroundBucket(limit: concurrencyLimitForBucket(bucketName)),
    );

    final future = _runBackgroundWithRetry(
      bucket,
      task,
      retryOnRateLimit: retryOnRateLimit,
    );
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

  Future<void> _awaitBucketCooldown(_BackgroundBucket bucket) async {
    while (true) {
      final now = DateTime.now();
      if (!bucket.cooldownUntil.isAfter(now)) {
        return;
      }
      await Future<void>.delayed(bucket.cooldownUntil.difference(now));
    }
  }

  Future<T> _runBackgroundWithRetry<T>(
    _BackgroundBucket bucket,
    Future<T> Function() task, {
    required bool retryOnRateLimit,
  }) async {
    var attempt = 0;
    while (true) {
      await _awaitBucketCooldown(bucket);

      try {
        return await _runInChannel(
          queue: bucket.queue,
          isFull: () => bucket.active >= bucket.limit,
          increment: () => bucket.active++,
          decrement: () => bucket.active--,
          action: () async {
            // 排队等待槽位期间若已有同桶请求触发 429 冷却，须在真正发包前再次对齐冷却截止时刻。
            await _awaitBucketCooldown(bucket);
            return task();
          },
        );
      } on RateLimitedHttpException catch (e) {
        if (e.isQuotaExhausted || !retryOnRateLimit) rethrow;
        attempt++;
        if (attempt > maxRetries) rethrow;
        final backoffMs = e.retryAfter.inMilliseconds * (1 << (attempt - 1));
        final wait = Duration(milliseconds: backoffMs.clamp(200, 30000));
        final nextAllowed = DateTime.now().add(wait);
        if (nextAllowed.isAfter(bucket.cooldownUntil)) {
          bucket.cooldownUntil = nextAllowed;
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

  static String _normalizeBucketKey(String? raw) =>
      (raw ?? '').trim().toLowerCase();
}

class _BackgroundBucket {
  _BackgroundBucket({required this.limit});

  final int limit;
  int active = 0;
  final Queue<Completer<void>> queue = Queue();
  DateTime cooldownUntil = DateTime.fromMillisecondsSinceEpoch(0);
}
