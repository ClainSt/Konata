/// 不可达官方域名冷却注册表（防止主线受阻时每张图片或每条请求重复等待超时）。
class DomainCooldownRegistry {
  /// 创建独立域名冷却注册表。
  DomainCooldownRegistry({this.cooldownDuration = const Duration(minutes: 10)});

  /// 官方域名不可达后的跳过冷却时长。
  final Duration cooldownDuration;

  final Map<String, DateTime> _blockedUntil = <String, DateTime>{};
  final Map<String, int> _backupServerErrorStreaks = <String, int>{};

  /// 备用链路连续返回服务端 5xx 达到该次数后解除主域名冷却并重新探活。
  static const int backupErrorStreakToUnblock = 3;

  /// 判断指定域名当前是否处于冷却窗口内。
  bool isCoolingDown(String host, [DateTime? now]) {
    final key = host.trim().toLowerCase();
    if (key.isEmpty) return false;
    final until = _blockedUntil[key];
    if (until == null) return false;
    final current = now ?? DateTime.now();
    if (!current.isBefore(until)) {
      _blockedUntil.remove(key);
      _backupServerErrorStreaks.remove(key);
      return false;
    }
    return true;
  }

  /// 将指定域名标记为临时不可达并进入冷却窗口。
  void markBlocked(String host, [DateTime? now]) {
    final key = host.trim().toLowerCase();
    if (key.isEmpty) return;
    final current = now ?? DateTime.now();
    _blockedUntil[key] = current.add(cooldownDuration);
    _backupServerErrorStreaks.remove(key);
  }

  /// 记录备用链路返回一次瞬时 5xx；连续达到阈值时自动解除主域名冷却以重新探活。
  bool recordBackupServerError(String host) {
    final key = host.trim().toLowerCase();
    if (key.isEmpty) return false;
    final streak = (_backupServerErrorStreaks[key] ?? 0) + 1;
    if (streak >= backupErrorStreakToUnblock) {
      _backupServerErrorStreaks.remove(key);
      _blockedUntil.remove(key);
      return true;
    }
    _backupServerErrorStreaks[key] = streak;
    return false;
  }

  /// 备用链路返回正常响应时清空连续服务端异常计数。
  void resetBackupServerError(String host) {
    final key = host.trim().toLowerCase();
    if (key.isNotEmpty) {
      _backupServerErrorStreaks.remove(key);
    }
  }

  /// 解除指定域名的冷却状态（例如手工测试连通恢复时）。
  void clearHost(String host) {
    final key = host.trim().toLowerCase();
    if (key.isNotEmpty) {
      _blockedUntil.remove(key);
      _backupServerErrorStreaks.remove(key);
    }
  }

  /// 清空全部冷却记录。
  void clearAll() {
    _blockedUntil.clear();
    _backupServerErrorStreaks.clear();
  }
}

/// 网络连通性与测速诊断结果。
class ConnectivityReport {
  /// 创建测速诊断报告。
  const ConnectivityReport({
    required this.reachable,
    required this.latencyMs,
    this.usedBackup = false,
    this.resolvedAddress,
    this.errorMessage,
    this.statusSummary,
  });

  /// 是否成功连通目标服务。
  final bool reachable;

  /// 往返耗时（毫秒）。
  final int latencyMs;

  /// 是否通过备用地址自动回退连通。
  final bool usedBackup;

  /// 实际命中的地址。
  final String? resolvedAddress;

  /// 失败原因说明（成功时为空）。
  final String? errorMessage;

  /// 面向界面的简明测试结论（例如 `官方直连成功 (180ms)`）。
  final String? statusSummary;

  /// 格式化用于界面展示的结果文本。
  String get displayText {
    if (statusSummary != null && statusSummary!.isNotEmpty) {
      return statusSummary!;
    }
    if (reachable) {
      return usedBackup
          ? '官方不可达，已自动回退备用地址连通 (${latencyMs}ms)'
          : '官方直连成功 (${latencyMs}ms)';
    }
    return errorMessage ?? '官方与备用地址均无法连接（请检查密钥/备用地址或代理）';
  }
}
