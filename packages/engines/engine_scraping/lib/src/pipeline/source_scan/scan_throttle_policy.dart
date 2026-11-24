import 'dart:async';

import 'package:konata_contracts/konata_contracts.dart';

/// 按媒体源协议与云盘风控特征集中定义的目录扫描并发与起搏配置档案。
class ScrapeDirectoryScanProfile {
  /// 创建目录扫描档案。
  const ScrapeDirectoryScanProfile({
    required this.initialConcurrency,
    required this.minConcurrency,
    required this.maxConcurrency,
    required this.warmPacing,
    required this.coldPacing,
    required this.maxPacing,
    required this.warmRttThreshold,
    required this.coldRttThreshold,
    required this.aimdIncreaseThreshold,
    required this.maxTransientRetries,
    required this.maxRateLimitRetries,
    required this.minRateLimitCooldown,
    required this.maxRateLimitCooldown,
  });

  /// 本地磁盘与 Windows CD2 挂载盘符档案：
  /// 克制并发 4 兼顾本地 SSD 3~4 倍提速与虚拟挂载盘温和防风控，零人为起搏延迟。
  static const ScrapeDirectoryScanProfile local = ScrapeDirectoryScanProfile(
    initialConcurrency: 4,
    minConcurrency: 1,
    maxConcurrency: 4,
    warmPacing: Duration.zero,
    coldPacing: Duration.zero,
    maxPacing: Duration(milliseconds: 500),
    warmRttThreshold: Duration(milliseconds: 30),
    coldRttThreshold: Duration(milliseconds: 120),
    aimdIncreaseThreshold: 12,
    maxTransientRetries: 2,
    maxRateLimitRetries: 4,
    minRateLimitCooldown: Duration(seconds: 1),
    maxRateLimitCooldown: Duration(seconds: 15),
  );

  /// 局域网 SMB 档案：底层单连接串行执行，并发固定为 1 零队列争用。
  static const ScrapeDirectoryScanProfile smb = ScrapeDirectoryScanProfile(
    initialConcurrency: 1,
    minConcurrency: 1,
    maxConcurrency: 1,
    warmPacing: Duration.zero,
    coldPacing: Duration.zero,
    maxPacing: Duration(milliseconds: 500),
    warmRttThreshold: Duration(milliseconds: 40),
    coldRttThreshold: Duration(milliseconds: 150),
    aimdIncreaseThreshold: 16,
    maxTransientRetries: 2,
    maxRateLimitRetries: 4,
    minRateLimitCooldown: Duration(seconds: 1),
    maxRateLimitCooldown: Duration(seconds: 20),
  );

  /// WebDAV / 云盘挂载（CD2 / AList / OpenList 挂载光鸭网盘等）防风控自适应档案：
  /// 慢启动并发 2 + 冷热 RTT 自适应起搏（命中 CD2 本地缓存时 15ms 极速放行，
  /// 回源云盘冷查询时 90ms 均匀错峰抹平尖峰），最高并发 4，遇 429/503 瞬间乘性降回 1。
  static const ScrapeDirectoryScanProfile webdav = ScrapeDirectoryScanProfile(
    initialConcurrency: 2,
    minConcurrency: 1,
    maxConcurrency: 4,
    warmPacing: Duration(milliseconds: 15),
    coldPacing: Duration(milliseconds: 90),
    maxPacing: Duration(milliseconds: 1500),
    warmRttThreshold: Duration(milliseconds: 45),
    coldRttThreshold: Duration(milliseconds: 120),
    aimdIncreaseThreshold: 12,
    maxTransientRetries: 2,
    maxRateLimitRetries: 5,
    minRateLimitCooldown: Duration(seconds: 2),
    maxRateLimitCooldown: Duration(seconds: 30),
  );

  /// 根据网关实际类型自动选择最优防风控扫描档案。
  static ScrapeDirectoryScanProfile forSourceKind(MediaSourceKind kind) {
    return switch (kind) {
      MediaSourceKind.webdav => webdav,
      MediaSourceKind.smb => smb,
      MediaSourceKind.local => local,
    };
  }

  /// 根据网关实例或可选显式协议选择扫描档案，保持零具体协议网关依赖。
  static ScrapeDirectoryScanProfile forGateway(
    MediaSourceGateway gateway, {
    MediaSourceKind? sourceKind,
  }) {
    if (sourceKind != null) {
      return forSourceKind(sourceKind);
    }
    final typeName = gateway.runtimeType.toString().toLowerCase();
    if (typeName.contains('webdav')) return webdav;
    if (typeName.contains('smb')) return smb;
    return local;
  }

  /// 初始并发目录枚举数。
  final int initialConcurrency;

  /// 允许降窗到的最低并发数。
  final int minConcurrency;

  /// 允许升窗到的最高并发数。
  final int maxConcurrency;

  /// 命中本地/CD2 目录缓存（低 RTT）时的最小起搏间隔。
  final Duration warmPacing;

  /// 回源远程云盘接口（高 RTT）时的平滑防风控起搏间隔。
  final Duration coldPacing;

  /// 连续触发限流后允许拉长的起搏间隔上限。
  final Duration maxPacing;

  /// 判定为热缓存响应的 RTT 阈值。
  final Duration warmRttThreshold;

  /// 判定为冷回源响应的 RTT 阈值。
  final Duration coldRttThreshold;

  /// 连续稳定低延迟成功达到该次数后，执行 AIMD 加性增窗（+1 并发）。
  final int aimdIncreaseThreshold;

  /// 普通瞬时网络故障最大重试次数。
  final int maxTransientRetries;

  /// 遇到 429/503/509 限流时的最大退避重试次数。
  final int maxRateLimitRetries;

  /// 触发限流后的单次最短冷却时长。
  final Duration minRateLimitCooldown;

  /// 触发限流后的单次最长冷却上限（防止异常超长 `Retry-After` 永久卡死）。
  final Duration maxRateLimitCooldown;
}

/// 自适应 AIMD 拥塞控制与令牌起搏扫描调度控制器。
///
/// 通过平滑错峰发包消除多并发突发毛刺，并基于实时 RTT 区分 CD2 本地缓存与云盘冷回源，
/// 在不触发光鸭等网盘风控的前提下最大化列目录吞吐。
class ScrapeAdaptiveScanController {
  /// 创建自适应扫描控制器。
  ScrapeAdaptiveScanController(
    this.profile, {
    DateTime Function()? nowProvider,
  }) : _now = nowProvider ?? DateTime.now,
       _currentConcurrency = profile.initialConcurrency.clamp(
         profile.minConcurrency,
         profile.maxConcurrency,
       ),
       _currentPacing = profile.warmPacing;

  /// 当前生效的协议扫描档案。
  final ScrapeDirectoryScanProfile profile;

  final DateTime Function() _now;

  int _currentConcurrency;
  Duration _currentPacing;
  double? _emaRttMs;
  int _stableSuccessStreak = 0;
  int _rateLimitHits = 0;
  int _slotCounter = 0;
  DateTime? _nextSlotAt;
  DateTime? _cooldownUntil;

  /// 当前允许的最大在途并发目录数。
  int get currentConcurrency => _currentConcurrency;

  /// 当前相邻请求起搏间隔。
  Duration get currentPacing => _currentPacing;

  /// 累计感知到的限流/风控事件次数。
  int get rateLimitHits => _rateLimitHits;

  /// 预定并等待下一个平滑起搏发包槽位（兼顾全局冷静期与错峰抖动）。
  Future<void> acquireSlot({bool Function()? isCancelled}) async {
    while (true) {
      if (isCancelled?.call() ?? false) return;
      final now = _now();
      final cooldown = _cooldownUntil;
      if (cooldown != null && cooldown.isAfter(now)) {
        final wait = cooldown.difference(now);
        await Future<void>.delayed(wait);
        continue;
      }
      final basePacingMs = _currentPacing.inMilliseconds;
      if (basePacingMs <= 0) return;

      // 叠加确定性 ±15% 轻度错峰，避免等距机械波被风控识别为脚本爬虫。
      final jitterFactor = switch ((_slotCounter++) % 5) {
        0 => 0.88,
        1 => 1.08,
        2 => 0.94,
        3 => 1.14,
        _ => 1.00,
      };
      final step = Duration(
        milliseconds: (basePacingMs * jitterFactor).round().clamp(1, 30000),
      );
      final scheduled =
          (_nextSlotAt != null && _nextSlotAt!.isAfter(now))
          ? _nextSlotAt!
          : now;
      _nextSlotAt = scheduled.add(step);
      if (scheduled.isAfter(now)) {
        await Future<void>.delayed(scheduled.difference(now));
      }
      return;
    }
  }

  /// 上报一次成功列目录的往返耗时，动态调节冷热起搏与 AIMD 加性增窗。
  void recordSuccess(Duration rtt) {
    final ms = rtt.inMilliseconds.toDouble();
    _emaRttMs = _emaRttMs == null ? ms : (_emaRttMs! * 0.7 + ms * 0.3);

    final warmMs = profile.warmRttThreshold.inMilliseconds;
    final coldMs = profile.coldRttThreshold.inMilliseconds;

    if (profile.coldPacing > Duration.zero) {
      if (_emaRttMs! >= coldMs) {
        // 明显回源云盘接口：若当前起搏快于冷回源安全阈值，拉高到冷回源平滑起搏。
        if (_currentPacing < profile.coldPacing) {
          _currentPacing = profile.coldPacing;
        }
      } else if (_emaRttMs! <= warmMs && _rateLimitHits == 0) {
        // 持续命中 CD2 本地目录缓存且零风控：平滑收敛回热缓存极速起搏。
        final nextMs = (_currentPacing.inMilliseconds * 0.8).round();
        final floorMs = profile.warmPacing.inMilliseconds;
        _currentPacing = Duration(
          milliseconds: nextMs < floorMs ? floorMs : nextMs,
        );
      } else if (_currentPacing > profile.coldPacing) {
        // 限流冷静后持续成功：每次成功缓慢衰减起搏间隔（每次 -10%），避免猛然加速再撞风控。
        final decayedMs = (_currentPacing.inMilliseconds * 0.9).round();
        final targetFloor = _emaRttMs! <= warmMs
            ? profile.warmPacing.inMilliseconds
            : profile.coldPacing.inMilliseconds;
        _currentPacing = Duration(
          milliseconds: decayedMs < targetFloor ? targetFloor : decayedMs,
        );
      }
    }

    if (_emaRttMs! < coldMs * 2) {
      _stableSuccessStreak++;
      if (_stableSuccessStreak >= profile.aimdIncreaseThreshold) {
        _stableSuccessStreak = 0;
        if (_currentConcurrency < profile.maxConcurrency) {
          _currentConcurrency++;
        }
      }
    } else {
      _stableSuccessStreak = 0;
    }
  }

  /// 上报云盘限流/风控信号（429 / 503 / 509）：瞬间乘性降窗、起搏倍增并设定全局冷静期。
  Duration recordRateLimit({Duration? retryAfter}) {
    _rateLimitHits++;
    _stableSuccessStreak = 0;

    // AIMD 乘性减窗：立刻减半并钳位到 minConcurrency（WebDAV 下直降 1）。
    final halved = _currentConcurrency ~/ 2;
    _currentConcurrency = halved < profile.minConcurrency
        ? profile.minConcurrency
        : halved;

    // 起搏间隔翻倍保护，最高不超过 maxPacing。
    final baseMs = _currentPacing.inMilliseconds > 0
        ? _currentPacing.inMilliseconds
        : (profile.coldPacing.inMilliseconds > 0
              ? profile.coldPacing.inMilliseconds
              : 100);
    final doubledMs = (baseMs * 2).clamp(
      baseMs,
      profile.maxPacing.inMilliseconds,
    );
    _currentPacing = Duration(milliseconds: doubledMs);

    // 冷静时长优先尊重服务端 `Retry-After`，否则按命中次数指数增长，严格夹逼在安全上下界内。
    final expFallback = Duration(
      milliseconds:
          profile.minRateLimitCooldown.inMilliseconds *
          (1 << (_rateLimitHits - 1).clamp(0, 4)),
    );
    var cooldown = retryAfter ?? expFallback;
    if (cooldown < profile.minRateLimitCooldown) {
      cooldown = profile.minRateLimitCooldown;
    }
    if (cooldown > profile.maxRateLimitCooldown) {
      cooldown = profile.maxRateLimitCooldown;
    }

    final until = _now().add(cooldown);
    if (_cooldownUntil == null || until.isAfter(_cooldownUntil!)) {
      _cooldownUntil = until;
    }
    _nextSlotAt = _cooldownUntil;
    return cooldown;
  }

  /// 上报普通瞬时网络抖动：温和缩窗并小幅放慢起搏，避免弱网雪崩。
  void recordTransientError() {
    _stableSuccessStreak = 0;
    if (_currentConcurrency > profile.minConcurrency) {
      _currentConcurrency--;
    }
    if (profile.coldPacing > Duration.zero) {
      final raisedMs = (_currentPacing.inMilliseconds * 1.5).round().clamp(
        profile.coldPacing.inMilliseconds,
        profile.maxPacing.inMilliseconds,
      );
      _currentPacing = Duration(milliseconds: raisedMs);
    }
  }
}
