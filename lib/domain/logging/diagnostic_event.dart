import '../formatting/network_error_sanitizer.dart';

/// 诊断事件严重级别（由低到高依次递增）。
enum DiagnosticSeverity {
  /// 详细调试跟踪（仅在开启详细调试日志时高频保留）。
  debug('DBG', 0),

  /// 关键状态流转与正常运行里程碑。
  info('INF', 1),

  /// 可恢复异常、降级回退或配置告警。
  warn('WRN', 2),

  /// 操作失败、接口异常或功能受阻。
  error('ERR', 3),

  /// 未捕获框架/异步致命异常。
  fatal('FTL', 4);

  const DiagnosticSeverity(this.badge, this.rank);

  /// 短标签（用于单行紧凑时间线）。
  final String badge;

  /// 数值优先级（用于故障归组排序）。
  final int rank;

  /// 是否属于需要永久免淘汰保护的异常/告警级别。
  bool get isIncident => rank >= DiagnosticSeverity.warn.rank;
}

/// Konata 核心业务子系统分区（每个分区拥有独立环形缓冲区，防止高频日志冲刷其它模块故障）。
enum DiagnosticSubsystem {
  /// 应用启动、未捕获异常与全局生命周期。
  app('APP'),

  /// 界面路由、页面构建与交互错误。
  ui('UI'),

  /// 视频播放、解复用、渲染与进出全屏。
  playback('PLAYBACK'),

  /// 字幕解码、内存直注、OpenCC、字体池与云端子集化。
  subtitle('SUBTITLE'),

  /// 音频播放、队列、发烧输出安全与歌词解析。
  audio('AUDIO'),

  /// 媒体库扫描、文件名解析、刮削匹配与合卡。
  scraper('SCRAPER'),

  /// 媒体源（本地 / WebDAV / SMB）连接与流网桥。
  source('SOURCE'),

  /// 本地 `.konata` 备份恢复与 WebDAV 多设备分片同步。
  sync('SYNC'),

  /// Bangumi PAT 鉴权与观看进度双向同步。
  bangumi('BANGUMI'),

  /// HTTP 客户端、代理、DoH、镜像回退与域名冷却。
  network('NETWORK'),

  /// SQLite 数据库、图片缓存与临时存储。
  storage('STORAGE'),

  /// 桌面窗口材质、置顶迷你窗与系统文件选择器。
  window('WINDOW');

  const DiagnosticSubsystem(this.code);

  /// 英文大写分区标识。
  final String code;

  /// 将既有旧式日志标签自动归类到结构化子系统分区，确保历史调用点零改动即可受益。
  static DiagnosticSubsystem fromLegacyTag(String rawTag) {
    final tag = rawTag.trim().toUpperCase();
    if (tag.isEmpty) return DiagnosticSubsystem.app;
    if (tag.contains('SUB') || tag.contains('FONT')) {
      return DiagnosticSubsystem.subtitle;
    }
    if (tag.contains('AUDIO') || tag.contains('LYRIC') || tag.contains('CD')) {
      return DiagnosticSubsystem.audio;
    }
    if (tag.contains('VIDEO') ||
        tag.contains('MPV') ||
        tag.contains('PLAY') ||
        tag.contains('SHADER') ||
        tag.contains('THUMB')) {
      return DiagnosticSubsystem.playback;
    }
    if (tag.contains('BGM') || tag.contains('BANGUMI')) {
      return DiagnosticSubsystem.bangumi;
    }
    if (tag.contains('SYNC') || tag.contains('BACKUP')) {
      return DiagnosticSubsystem.sync;
    }
    if (tag.contains('SCRAP') || tag.contains('MATCH') || tag.contains('MERGE')) {
      return DiagnosticSubsystem.scraper;
    }
    if (tag.contains('DAV') ||
        tag.contains('SMB') ||
        tag.contains('SOURCE') ||
        tag.contains('BRIDGE') ||
        tag.contains('SCAN')) {
      return DiagnosticSubsystem.source;
    }
    if (tag.contains('NET') ||
        tag.contains('HTTP') ||
        tag.contains('TMDB') ||
        tag.contains('FANART')) {
      return DiagnosticSubsystem.network;
    }
    if (tag.contains('DB') ||
        tag.contains('SQL') ||
        tag.contains('CACHE') ||
        tag.contains('PHOTO') ||
        tag.contains('STOR')) {
      return DiagnosticSubsystem.storage;
    }
    if (tag.contains('WIN') || tag.contains('PICKER')) {
      return DiagnosticSubsystem.window;
    }
    if (tag.contains('UI') || tag.contains('ROUTE')) {
      return DiagnosticSubsystem.ui;
    }
    return DiagnosticSubsystem.app;
  }
}

/// 单条结构化诊断事件（自带源码位置锚点、机器可读故障码、脱敏上下文与精炼应用堆栈）。
class DiagnosticEvent {
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

  /// 记录时间戳。
  final DateTime timestamp;

  /// 事件严重级别。
  final DiagnosticSeverity severity;

  /// 所属业务子系统。
  final DiagnosticSubsystem subsystem;

  /// 稳定机器可读故障/事件码（如 `PLAYBACK_FATAL`、`SUB_REBIND_FAILED`、`BGM_AUTH_401`）。
  final String code;

  /// 已脱敏的中文/结构化事件描述。
  final String message;

  /// 精确源码位置锚点（推荐格式 `lib/.../file.dart:methodName`，供排查时秒级定位源码）。
  final String? source;

  /// 已脱敏的结构化键值上下文（如 `workId`、`httpStatus`、`sid`、`hwdec`）。
  final Map<String, String> context;

  /// 捕获异常的运行时类型名。
  final String? errorType;

  /// 提纯后的应用与顶部框架堆栈帧（优先呈现 `package:konata/...` 精确文件与行号）。
  final List<String> appStackFrames;

  /// 归组指纹键（用于把重复发生的同类故障自动折叠汇总）。
  String get faultSignature =>
      '${subsystem.code}|$code|${source ?? 'unknown'}|${errorType ?? ''}';

  /// 渲染为面向排查的紧凑单行文本。
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

  /// 序列化为结构化 JSON 对象。
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'seq': seq,
      'timestamp': timestamp.toIso8601String(),
      'severity': severity.name,
      'subsystem': subsystem.name,
      'code': code,
      'ifSource': source,
      'source': source,
      'message': message,
      if (context.isNotEmpty) 'context': context,
      if (errorType != null) 'errorType': errorType,
      if (appStackFrames.isNotEmpty) 'stackFrames': appStackFrames,
    }..remove('ifSource');
  }
}

/// 轻量用户操作与路由轨迹面包屑（低开销常驻保留，绝不因关闭详细日志而被丢弃）。
class DiagnosticBreadcrumb {
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

  /// 轨迹类型（如 `route`、`action`、`playback`、`sync`、`lifecycle`）。
  final String category;

  /// 简短中文动作描述。
  final String label;

  /// 可选源码位置锚点。
  final String? source;

  /// 可选脱敏附加参数。
  final String? detail;

  /// 格式化单行面包屑文本。
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
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'seq': seq,
      'timestamp': timestamp.toIso8601String(),
      'category': category,
      'label': label,
      if (source != null) 'source': source,
      if (detail != null) 'detail': detail,
    };
  }
}

/// 按 `(子系统, 故障码, 源码锚点)` 聚合后的故障分诊摘要，便于快速定位根因。
class DiagnosticFaultSummary {
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

  /// 发生次数。
  final int count;

  /// 首次出现时间。
  final DateTime firstSeen;

  /// 最近出现时间。
  final DateTime lastSeen;

  /// 最近一次事件描述。
  final String sampleMessage;

  /// 源码位置锚点。
  final String? source;

  /// 异常类型名。
  final String? errorType;

  /// 首条命中的 Konata 应用源码堆栈帧。
  final String? topAppFrame;

  /// 最近一次脱敏上下文键值。
  final Map<String, String> sampleContext;

  /// 序列化为 JSON 对象。
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'subsystem': subsystem.name,
      'code': code,
      'severity': severity.name,
      'count': count,
      'firstSeen': firstSeen.toIso8601String(),
      'lastSeen': lastSeen.toIso8601String(),
      'source': source,
      'errorType': errorType,
      'topAppFrame': topAppFrame,
      'sampleMessage': sampleMessage,
      if (sampleContext.isNotEmpty) 'sampleContext': sampleContext,
    };
  }
}

/// 导出时由各业务模块动态提供的运行时状态快照分节。
class DiagnosticSnapshotSection {
  /// 创建运行时状态快照分节。
  const DiagnosticSnapshotSection({
    required this.id,
    required this.title,
    required this.entries,
  });

  /// 稳定机器分节键（如 `app_ui`、`playback`、`library_db`、`network`、`sync`）。
  final String id;

  /// 中文展示标题。
  final String title;

  /// 脱敏后的状态键值表。
  final Map<String, String> entries;

  /// 序列化为 JSON 对象。
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'title': title,
      'entries': entries,
    };
  }
}

/// 堆栈精炼提取器：优先抽取 `package:konata/` 应用源码帧并附带少量顶部外部帧。
abstract final class DiagnosticStackParser {
  static final RegExp _konataFramePattern = RegExp(
    r'package:konata/([^:\s)]+:\d+(?::\d+)?)',
  );
  static final RegExp _framePrefixPattern = RegExp(r'^#\d+\s+');

  /// 从原始堆栈提取最多 [maxAppFrames] 条应用帧与 [maxExternalFrames] 条顶部外部帧。
  static List<String> extractFrames(
    StackTrace? stackTrace, {
    int maxAppFrames = 8,
    int maxExternalFrames = 3,
  }) {
    if (stackTrace == null) return const <String>[];
    final rawLines = stackTrace
        .toString()
        .replaceAll('\r\n', '\n')
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (rawLines.isEmpty) return const <String>[];

    final appFrames = <String>[];
    final extFrames = <String>[];
    for (final line in rawLines) {
      if (line.contains('<asynchronous suspension>')) continue;
      final cleaned = NetworkErrorSanitizer.redactForDiagnosticsExport(
        line.replaceFirst(_framePrefixPattern, ''),
      );
      if (line.contains('package:konata/')) {
        if (appFrames.length < maxAppFrames) {
          appFrames.add(cleaned);
        }
      } else if (extFrames.length < maxExternalFrames) {
        extFrames.add(cleaned);
      }
      if (appFrames.length >= maxAppFrames &&
          extFrames.length >= maxExternalFrames) {
        break;
      }
    }
    if (appFrames.isEmpty) {
      return extFrames;
    }
    return <String>[...appFrames, ...extFrames.take(2)];
  }

  /// 从堆栈中提取第一条 `lib/...:line` 形式的源码位置锚点。
  static String? extractPrimaryKonataSource(StackTrace? stackTrace) {
    if (stackTrace == null) return null;
    final match = _konataFramePattern.firstMatch(stackTrace.toString());
    if (match == null) return null;
    return 'lib/${match.group(1)}';
  }
}

String _formatShortTime(DateTime dt) {
  final h = dt.hour.toString().padLeft(2, '0');
  final m = dt.minute.toString().padLeft(2, '0');
  final s = dt.second.toString().padLeft(2, '0');
  final ms = dt.millisecond.toString().padLeft(3, '0');
  return '$h:$m:$s.$ms';
}
