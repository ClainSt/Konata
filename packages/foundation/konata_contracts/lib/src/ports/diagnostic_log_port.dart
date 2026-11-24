import 'dart:async';

/// 诊断事件严重级别（由低到高依次递增）。
enum DiagnosticSeverity {
  /// 详细调试跟踪（仅在开启详细调试日志时保留）。
  debug('DBG', 0),

  /// 关键状态转移与正常运行里程碑。
  info('INF', 1),

  /// 可恢复异常、降级回退或配置告警。
  warn('WRN', 2),

  /// 操作失败、接口异常或功能受阻。
  error('ERR', 3),

  /// 未捕获框架或异步致命异常。
  fatal('FTL', 4);

  const DiagnosticSeverity(this.badge, this.rank);

  /// 单行时间线使用的三字母徽标。
  final String badge;

  /// 数值优先级（用于故障归组排序）。
  final int rank;

  /// 是否属于必须免淘汰保留的告警/异常事件。
  bool get isIncident => rank >= DiagnosticSeverity.warn.rank;
}

/// Konata 核心业务子系统分区（每分区独立环形保护，防止高频日志冲刷故障）。
enum DiagnosticSubsystem {
  /// 应用启动、未捕获异常与全局生命周期。
  app('APP'),

  /// 界面路由、页面构建与交互错误。
  ui('UI'),

  /// 视频播放、解复用、渲染与进出全屏。
  playback('PLAYBACK'),

  /// 字幕解码、内存直注、OpenCC 与字体池。
  subtitle('SUBTITLE'),

  /// 音频播放、队列、安全增益与歌词解析。
  audio('AUDIO'),

  /// 媒体库扫描、文件名解析、刮削匹配与合卡。
  scraper('SCRAPER'),

  /// 媒体源（本地 / WebDAV / SMB）连接与流网桥。
  source('SOURCE'),

  /// 本地 `.konata` 备份恢复与 WebDAV 多设备分片同步。
  sync('SYNC'),

  /// 第三方追番平台（Bangumi / MAL / AniList）鉴权与进度同步。
  tracker('TRACKER'),

  /// HTTP 客户端、代理、DoH 与域名冷却。
  network('NETWORK'),

  /// 三库 SQLite 引擎、配置切片、图片缓存与临时存储。
  storage('STORAGE'),

  /// 桌面窗口材质、置顶迷你窗与系统选择器。
  window('WINDOW');

  const DiagnosticSubsystem(this.code);

  /// 稳定大写分区标识。
  final String code;
}

/// 诊断文本凭据与本机用户名目录脱敏工具（纯 Dart 无外部依赖）。
abstract final class DiagnosticTextSanitizer {
  static final RegExp _querySecretPattern = RegExp(
    r'((?:api_key|client_key|api-key|client-key|access_token|token|pat|password|passwd|secret)\s*[=:]\s*)([^&\s)\x27",;}\]]+)',
    caseSensitive: false,
  );
  static final RegExp _encodedSecretPattern = RegExp(
    r'((?:api_key|client_key|access_token|token|password)%3d)([^&\s)\x27",;%]+)',
    caseSensitive: false,
  );
  static final RegExp _jsonSecretPattern = RegExp(
    r'("(?:api_key|client_key|access_token|token|pat|password|passwd|secret|credential|authorization)"\s*:\s*")([^"]*)(")',
    caseSensitive: false,
  );
  static final RegExp _bearerPattern = RegExp(
    r'(Bearer\s+)([A-Za-z0-9\-._~+/]+=*)',
    caseSensitive: false,
  );
  static final RegExp _basicPattern = RegExp(
    r'(Basic\s+)([A-Za-z0-9+/]+=*)',
    caseSensitive: false,
  );
  static final RegExp _digestPattern = RegExp(
    r'(response\s*=\s*")([^"]+)(")',
    caseSensitive: false,
  );
  static final RegExp _urlUserInfoPattern = RegExp(
    r'(https?://[^/\s:@]+:)([^/\s@]+)(@)',
    caseSensitive: false,
  );
  static final RegExp _windowsUserHomePattern = RegExp(
    r'[A-Za-z]:\\Users\\[^\\/\s"\x27]+',
  );
  static final RegExp _unixUserHomePattern = RegExp(
    r'/(?:Users|home)/[^/\s"\x27]+',
  );

  /// 清洗文本中的各类密钥、认证头、JSON 凭据与 URL 内嵌密码。
  static String redactSecrets(String input) {
    if (input.isEmpty) return input;
    return input
        .replaceAllMapped(_urlUserInfoPattern, (m) => '${m[1]}***${m[3]}')
        .replaceAllMapped(_jsonSecretPattern, (m) => '${m[1]}***${m[3]}')
        .replaceAllMapped(_querySecretPattern, (m) => '${m[1]}***')
        .replaceAllMapped(_encodedSecretPattern, (m) => '${m[1]}***')
        .replaceAllMapped(_bearerPattern, (m) => '${m[1]}***')
        .replaceAllMapped(_basicPattern, (m) => '${m[1]}***')
        .replaceAllMapped(_digestPattern, (m) => '${m[1]}***${m[3]}');
  }

  /// 在密钥脱敏基础上进一步隐藏本机操作系统用户名主目录前缀。
  static String redactForExport(String input) {
    final secretSafe = redactSecrets(input);
    if (secretSafe.isEmpty) return secretSafe;
    return secretSafe
        .replaceAll(_windowsUserHomePattern, r'<USER_HOME>')
        .replaceAll(_unixUserHomePattern, '<USER_HOME>');
  }

  /// 判断结构化上下文字段名是否属于敏感凭据键。
  static bool isSensitiveKey(String rawKey) {
    final lower = rawKey.trim().toLowerCase();
    return lower.contains('password') ||
        lower.contains('passwd') ||
        lower.contains('secret') ||
        lower.contains('token') ||
        lower == 'pat' ||
        lower.contains('apikey') ||
        lower.contains('api_key') ||
        lower.contains('credential') ||
        lower.contains('authorization');
  }
}

/// 单条已脱敏的结构化诊断事件。
final class DiagnosticEvent {
  /// 创建结构化诊断事件。
  const DiagnosticEvent({
    required this.seq,
    required this.timestamp,
    required this.severity,
    required this.subsystem,
    required this.code,
    required this.message,
    this.source,
    this.context = const <String, String>{},
    this.errorType,
    this.appStackFrames = const <String>[],
  });

  /// 全局单调递增事件序号。
  final int seq;

  /// 事件记录时间。
  final DateTime timestamp;

  /// 严重级别。
  final DiagnosticSeverity severity;

  /// 所属业务子系统。
  final DiagnosticSubsystem subsystem;

  /// 稳定机器可读故障或事件码。
  final String code;

  /// 已脱敏的事件描述。
  final String message;

  /// 可选源码位置锚点（如 `konata_storage:sqlite_engine.dart:runTransaction`）。
  final String? source;

  /// 已脱敏的键值上下文。
  final Map<String, String> context;

  /// 异常运行时类型名。
  final String? errorType;

  /// 提纯后的应用源码堆栈帧列表。
  final List<String> appStackFrames;

  /// 同类故障折叠归组指纹。
  String get faultSignature =>
      '${subsystem.code}|$code|${source ?? 'unknown'}|${errorType ?? ''}';

  /// 格式化为紧凑单行日志。
  String formatCompactLine() {
    final buf = StringBuffer()
      ..write('#')
      ..write(seq.toString().padLeft(4, '0'))
      ..write(' [')
      ..write(_formatShortTime(timestamp))
      ..write('][')
      ..write(severity.badge)
      ..write('][')
      ..write(subsystem.code)
      ..write('][')
      ..write(code)
      ..write(']');
    if (source != null && source!.isNotEmpty) {
      buf
        ..write(' @')
        ..write(source);
    }
    buf
      ..write(' ')
      ..write(message);
    if (errorType != null && errorType!.isNotEmpty) {
      buf
        ..write(' (')
        ..write(errorType)
        ..write(')');
    }
    if (context.isNotEmpty) {
      buf.write(' {');
      var first = true;
      for (final entry in context.entries) {
        if (!first) buf.write(', ');
        first = false;
        buf
          ..write(entry.key)
          ..write('=')
          ..write(entry.value);
      }
      buf.write('}');
    }
    return buf.toString();
  }

  /// 序列化为 JSON 对象。
  Map<String, Object?> toJson() => <String, Object?>{
    'seq': seq,
    'timestamp': timestamp.toIso8601String(),
    'severity': severity.name,
    'subsystem': subsystem.name,
    'code': code,
    if (source != null) 'source': source,
    'message': message,
    if (context.isNotEmpty) 'context': context,
    if (errorType != null) 'errorType': errorType,
    if (appStackFrames.isNotEmpty) 'stackFrames': appStackFrames,
  };
}

/// 轻量操作与路由轨迹面包屑。
final class DiagnosticBreadcrumb {
  /// 创建操作轨迹面包屑。
  const DiagnosticBreadcrumb({
    required this.seq,
    required this.timestamp,
    required this.category,
    required this.label,
    this.source,
    this.detail,
  });

  /// 轨迹序号。
  final int seq;

  /// 发生时间。
  final DateTime timestamp;

  /// 轨迹类别（如 `route`、`action`、`fsm`、`sync`）。
  final String category;

  /// 简短中文动作描述。
  final String label;

  /// 可选源码位置锚点。
  final String? source;

  /// 可选已脱敏详情。
  final String? detail;

  /// 格式化为紧凑单行文本。
  String formatLine() {
    final buf = StringBuffer()
      ..write('[')
      ..write(_formatShortTime(timestamp))
      ..write('][')
      ..write(category.toUpperCase())
      ..write('] ')
      ..write(label);
    if (detail != null && detail!.isNotEmpty) {
      buf
        ..write(' | ')
        ..write(detail);
    }
    if (source != null && source!.isNotEmpty) {
      buf
        ..write(' (@')
        ..write(source)
        ..write(')');
    }
    return buf.toString();
  }

  /// 序列化为 JSON 对象。
  Map<String, Object?> toJson() => <String, Object?>{
    'seq': seq,
    'timestamp': timestamp.toIso8601String(),
    'category': category,
    'label': label,
    if (source != null) 'source': source,
    if (detail != null) 'detail': detail,
  };
}

/// 按同类故障指纹折叠后的分诊摘要。
final class DiagnosticFaultSummary {
  /// 创建故障分诊摘要。
  const DiagnosticFaultSummary({
    required this.subsystem,
    required this.code,
    required this.severity,
    required this.count,
    required this.firstSeen,
    required this.lastSeen,
    required this.sampleMessage,
    this.source,
    this.errorType,
    this.topAppFrame,
    this.sampleContext = const <String, String>{},
  });

  /// 所属子系统。
  final DiagnosticSubsystem subsystem;

  /// 故障码。
  final String code;

  /// 最高严重级别。
  final DiagnosticSeverity severity;

  /// 累计发生次数。
  final int count;

  /// 首次出现时间。
  final DateTime firstSeen;

  /// 最近一次出现时间。
  final DateTime lastSeen;

  /// 最近一次事件描述。
  final String sampleMessage;

  /// 源码位置锚点。
  final String? source;

  /// 异常类型名。
  final String? errorType;

  /// 顶部应用源码堆栈帧。
  final String? topAppFrame;

  /// 最近一次脱敏上下文。
  final Map<String, String> sampleContext;

  /// 序列化为 JSON 对象。
  Map<String, Object?> toJson() => <String, Object?>{
    'subsystem': subsystem.name,
    'code': code,
    'severity': severity.name,
    'count': count,
    'firstSeen': firstSeen.toIso8601String(),
    'lastSeen': lastSeen.toIso8601String(),
    if (source != null) 'source': source,
    if (errorType != null) 'errorType': errorType,
    if (topAppFrame != null) 'topAppFrame': topAppFrame,
    'sampleMessage': sampleMessage,
    if (sampleContext.isNotEmpty) 'sampleContext': sampleContext,
  };
}

/// 导出诊断快照时由各模块动态提供的运行时状态分节。
final class DiagnosticSnapshotSection {
  /// 创建运行态快照分节。
  const DiagnosticSnapshotSection({
    required this.id,
    required this.title,
    required this.entries,
  });

  /// 稳定机器分节标识。
  final String id;

  /// 中文展示标题。
  final String title;

  /// 脱敏后的状态键值映射。
  final Map<String, String> entries;

  /// 序列化为 JSON 对象。
  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'title': title,
    'entries': entries,
  };
}

/// 诊断事件计数摘要。
final class DiagnosticSummaryCounts {
  /// 创建诊断统计摘要。
  const DiagnosticSummaryCounts({
    required this.totalEvents,
    required this.warningCount,
    required this.errorCount,
    required this.breadcrumbCount,
  });

  /// 当前全局缓冲事件条数。
  final int totalEvents;

  /// 已捕获的警告条数。
  final int warningCount;

  /// 已捕获的错误与致命异常条数。
  final int errorCount;

  /// 当前保留的操作轨迹条数。
  final int breadcrumbCount;
}

/// 运行时诊断快照异步贡献函数签名。
typedef DiagnosticSnapshotContributor =
    FutureOr<DiagnosticSnapshotSection?> Function();

/// 全仓统一结构化脱敏诊断日志端口。
///
/// 覆盖 FSM 状态转移、刮削步骤决策、同步合并明细与播放代数切换，支持一键导出排查快照。
abstract interface class DiagnosticLogPort {
  /// 当前是否开启详细调试日志。
  bool get verboseEnabled;

  /// 当前缓冲事件统计计数。
  DiagnosticSummaryCounts get summaryCounts;

  /// 切换详细调试日志开关。
  void setVerbose(bool enabled);

  /// 写入一条带源码锚点、故障码与结构化上下文的标准诊断事件。
  void logEvent({
    required DiagnosticSubsystem subsystem,
    required String code,
    required String message,
    DiagnosticSeverity severity = DiagnosticSeverity.info,
    String? source,
    Map<String, Object?> context = const <String, Object?>{},
    Object? error,
    StackTrace? stackTrace,
  });

  /// 便捷记录异常事件并自动脱敏异常详情与堆栈。
  void logError({
    required DiagnosticSubsystem subsystem,
    required String code,
    required String message,
    required Object error,
    StackTrace? stackTrace,
    DiagnosticSeverity severity = DiagnosticSeverity.error,
    String? source,
    Map<String, Object?> context = const <String, Object?>{},
  });

  /// 记录轻量用户操作、路由或状态机轨迹面包屑。
  void recordBreadcrumb({
    required String category,
    required String label,
    String? source,
    String? detail,
  });

  /// 注册导出时的运行时状态快照贡献者，返回注销回调。
  void Function() registerSnapshotContributor(
    String sectionId,
    DiagnosticSnapshotContributor contributor,
  );

  /// 聚合当前全部警告与异常形成故障分诊列表。
  List<DiagnosticFaultSummary> summarizeFaults();

  /// 返回去重升序排列的全部保留事件快照。
  List<DiagnosticEvent> snapshotEvents();

  /// 异步导出结构化 JSON 诊断包字符串。
  Future<String> buildJsonBundle();

  /// 异步导出纯文本人类可读诊断报告。
  Future<String> buildTextReport();

  /// 清空内存缓冲中的事件与操作轨迹。
  void clear();
}

String _formatShortTime(DateTime dt) {
  final h = dt.hour.toString().padLeft(2, '0');
  final m = dt.minute.toString().padLeft(2, '0');
  final s = dt.second.toString().padLeft(2, '0');
  final ms = dt.millisecond.toString().padLeft(3, '0');
  return '$h:$m:$s.$ms';
}
