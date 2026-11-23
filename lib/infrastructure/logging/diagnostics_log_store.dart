import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import '../../domain/config/konata_lane_config.dart';
import '../../domain/formatting/network_error_sanitizer.dart';
import '../../domain/logging/diagnostic_event.dart';

/// 导出诊断快照时的异步贡献函数签名。
typedef DiagnosticSnapshotContributor =
    FutureOr<DiagnosticSnapshotSection?> Function();

/// 诊断日志统计摘要（供设置页实时展示已捕获的事件/告警/异常数量）。
class DiagnosticsSummaryCounts {
  /// 创建诊断统计摘要。
  const DiagnosticsSummaryCounts({
    required this.totalEvents,
    required this.warningCount,
    required this.errorCount,
    required this.breadcrumbCount,
  });

  /// 当前缓冲的总事件条数。
  final int totalEvents;

  /// 已捕获的警告条数。
  final int warningCount;

  /// 已捕获的错误与致命异常条数。
  final int errorCount;

  /// 当前保留的用户操作轨迹条数。
  final int breadcrumbCount;
}

/// Konata Agent 友好结构化诊断日志存储器（纯 Infrastructure 层，无界面依赖）。
///
/// 采用「全局时间线环 + 异常专属免淘汰环 + 按子系统独立分环 + 操作轨迹面包屑环」四层隔离架构，
/// 确保高频播放/扫描日志绝不冲刷关键错误，且导出即自带源码锚点、故障分诊表与实时运行状态快照。
class DiagnosticsLogStore {
  /// 创建诊断日志存储器。
  DiagnosticsLogStore({
    this.maxEntries = 600,
    this.verboseMaxEntries = 2000,
    this.maxErrorEntries = 150,
    this.maxEntriesPerSubsystem = 80,
    this.maxBreadcrumbs = 80,
    this.appVersion = '1.0.0+2006',
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// 非详细模式下的全局时间线容量上限。
  final int maxEntries;

  /// 开启详细调试日志后的全局时间线容量上限。
  final int verboseMaxEntries;

  /// 异常/警告专属免淘汰环容量上限。
  final int maxErrorEntries;

  /// 每个子系统独立保护环的容量上限。
  final int maxEntriesPerSubsystem;

  /// 用户操作与路由面包屑保留上限。
  final int maxBreadcrumbs;

  /// 应用版本标识。
  final String appVersion;

  final DateTime Function() _clock;
  final ListQueue<DiagnosticEvent> _globalRing = ListQueue<DiagnosticEvent>();
  final ListQueue<DiagnosticEvent> _errorRing = ListQueue<DiagnosticEvent>();
  final Map<DiagnosticSubsystem, ListQueue<DiagnosticEvent>> _subsystemRings =
      <DiagnosticSubsystem, ListQueue<DiagnosticEvent>>{};
  final ListQueue<DiagnosticBreadcrumb> _breadcrumbs =
      ListQueue<DiagnosticBreadcrumb>();
  final Map<String, DiagnosticSnapshotContributor> _snapshotContributors =
      <String, DiagnosticSnapshotContributor>{};
  final Set<void Function()> _listeners = <void Function()>{};

  bool _verbose = false;
  int _nextEventSeq = 1;
  int _nextBreadcrumbSeq = 1;
  int _revision = 0;

  /// 是否开启详细调试日志。
  bool get verboseEnabled => _verbose;

  /// 单调递增变更版本号（用于轻量通知界面刷新统计）。
  int get revision => _revision;

  /// 读取当前诊断统计计数。
  DiagnosticsSummaryCounts get summaryCounts {
    var warns = 0;
    var errs = 0;
    for (final ev in _errorRing) {
      if (ev.severity == DiagnosticSeverity.warn) {
        warns++;
      } else if (ev.severity.rank >= DiagnosticSeverity.error.rank) {
        errs++;
      }
    }
    return DiagnosticsSummaryCounts(
      totalEvents: _globalRing.length,
      warningCount: warns,
      errorCount: errs,
      breadcrumbCount: _breadcrumbs.length,
    );
  }

  /// 注册变更监听函数（返回注销回调）。
  void Function() addListener(void Function() listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void _notifyListeners() {
    _revision++;
    if (_listeners.isEmpty) return;
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

  /// 注册运行时状态快照贡献者（同一 [sectionId] 后注册者覆盖前者，返回注销回调）。
  void Function() registerSnapshotContributor(
    String sectionId,
    DiagnosticSnapshotContributor contributor,
  ) {
    _snapshotContributors[sectionId] = contributor;
    return () {
      if (identical(_snapshotContributors[sectionId], contributor)) {
        _snapshotContributors.remove(sectionId);
      }
    };
  }

  /// 更新详细调试日志开关状态。
  void setVerbose(bool enabled) {
    if (_verbose == enabled) return;
    _verbose = enabled;
    logEvent(
      subsystem: DiagnosticSubsystem.app,
      code: 'DIAG_VERBOSE_CHANGED',
      message: '详细调试日志已${enabled ? '开启' : '关闭'}',
      source: 'lib/infrastructure/logging/diagnostics_log_store.dart:setVerbose',
      context: <String, Object?>{'verbose': enabled},
    );
  }

  /// 兼容既有调用方的轻量日志接口（自动归类子系统并做全量密钥与路径脱敏）。
  void record(String tag, String message, {bool isError = false}) {
    final normalizedTag = tag.trim().isEmpty
        ? 'APP'
        : tag.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z0-9_]'), '_');
    final subsystem = DiagnosticSubsystem.fromLegacyTag(normalizedTag);
    logEvent(
      subsystem: subsystem,
      severity: isError ? DiagnosticSeverity.error : DiagnosticSeverity.info,
      code: isError ? '${normalizedTag}_ERROR' : '${normalizedTag}_INFO',
      message: message,
    );
  }

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
  }) {
    // 非详细模式下屏蔽纯 DEBUG 噪声，但 INFO/WARN/ERROR/FATAL 全部按子系统分环安全保留。
    if (severity == DiagnosticSeverity.debug && !_verbose) {
      return;
    }

    final cleanMessage = NetworkErrorSanitizer.redactForDiagnosticsExport(
      message.trim(),
    );
    final cleanContext = _sanitizeContext(context);
    final effectiveStack =
        stackTrace ??
        (error is Error ? error.stackTrace : null);
    final extractedFrames = DiagnosticStackParser.extractFrames(effectiveStack);
    final effectiveSource =
        (source != null && source.trim().isNotEmpty)
        ? source.trim()
        : DiagnosticStackParser.extractPrimaryKonataSource(effectiveStack);
    final errorType = error?.runtimeType.toString();

    final event = DiagnosticEvent(
      seq: _nextEventSeq++,
      timestamp: _clock(),
      severity: severity,
      subsystem: subsystem,
      code: code.trim().isEmpty ? '${subsystem.code}_EVENT' : code.trim(),
      message: cleanMessage,
      source: effectiveSource,
      context: cleanContext,
      errorType: errorType,
      appStackFrames: extractedFrames,
    );

    final globalCap = _verbose ? verboseMaxEntries : maxEntries;
    while (_globalRing.length >= globalCap) {
      _globalRing.removeFirst();
    }
    _globalRing.addLast(event);

    final subRing = _subsystemRings.putIfAbsent(
      subsystem,
      () => ListQueue<DiagnosticEvent>(),
    );
    while (subRing.length >= maxEntriesPerSubsystem) {
      subRing.removeFirst();
    }
    subRing.addLast(event);

    if (severity.isIncident) {
      while (_errorRing.length >= maxErrorEntries) {
        _errorRing.removeFirst();
      }
      _errorRing.addLast(event);
    }

    _notifyListeners();
  }

  /// 便捷记录异常事件（自动附带异常类型、精炼应用堆栈与脱敏错误说明）。
  void logError({
    required DiagnosticSubsystem subsystem,
    required String code,
    required String message,
    required Object error,
    StackTrace? stackTrace,
    DiagnosticSeverity severity = DiagnosticSeverity.error,
    String? source,
    Map<String, Object?> context = const <String, Object?>{},
  }) {
    final mergedContext = <String, Object?>{
      ...context,
      'errorDetail': NetworkErrorSanitizer.redactForDiagnosticsExport(
        error.toString(),
      ),
    };
    logEvent(
      subsystem: subsystem,
      severity: severity,
      code: code,
      message: message,
      source: source,
      context: mergedContext,
      error: error,
      stackTrace: stackTrace,
    );
  }

  /// 记录轻量用户交互、页面路由或状态流转轨迹（始终常驻保留）。
  void recordBreadcrumb({
    required String category,
    required String label,
    String? source,
    String? detail,
  }) {
    final crumb = DiagnosticBreadcrumb(
      seq: _nextBreadcrumbSeq++,
      timestamp: _clock(),
      category: category.trim().isEmpty ? 'action' : category.trim(),
      label: NetworkErrorSanitizer.redactForDiagnosticsExport(label.trim()),
      source: source?.trim().isEmpty == true ? null : source?.trim(),
      detail: detail == null || detail.trim().isEmpty
          ? null
          : NetworkErrorSanitizer.redactForDiagnosticsExport(detail.trim()),
    );
    while (_breadcrumbs.length >= maxBreadcrumbs) {
      _breadcrumbs.removeFirst();
    }
    _breadcrumbs.addLast(crumb);
    _notifyListeners();
  }

  /// 清空当前内存中的全部事件与操作轨迹（不影响已注册的状态快照贡献者）。
  void clear() {
    _globalRing.clear();
    _errorRing.clear();
    _subsystemRings.clear();
    _breadcrumbs.clear();
    _notifyListeners();
  }

  /// 返回去重并按序号升序排列的全量合并事件列表。
  List<DiagnosticEvent> snapshotMergedEvents() {
    final bySeq = <int, DiagnosticEvent>{};
    for (final ev in _globalRing) {
      bySeq[ev.seq] = ev;
    }
    for (final ev in _errorRing) {
      bySeq[ev.seq] = ev;
    }
    for (final ring in _subsystemRings.values) {
      for (final ev in ring) {
        bySeq[ev.seq] = ev;
      }
    }
    final list = bySeq.values.toList(growable: false)
      ..sort((a, b) => a.seq.compareTo(b.seq));
    return list;
  }

  /// 返回异常与告警专属环内的全部事件（按时间升序）。
  List<DiagnosticEvent> snapshotIncidentEvents() =>
      _errorRing.toList(growable: false);

  /// 返回保留的用户操作面包屑列表（按时间升序）。
  List<DiagnosticBreadcrumb> snapshotBreadcrumbs() =>
      _breadcrumbs.toList(growable: false);

  /// 将全部警告/错误按 `(子系统, 故障码, 源码位置)` 聚合排序，便于一秒定位最高优先级根因。
  List<DiagnosticFaultSummary> summarizeFaults() {
    final grouped = <String, _MutableFaultGroup>{};
    for (final ev in _errorRing) {
      final sig = ev.faultSignature;
      final existing = grouped[sig];
      if (existing == null) {
        grouped[sig] = _MutableFaultGroup(ev);
      } else {
        existing.absorb(ev);
      }
    }
    final summaries = [for (final g in grouped.values) g.toSummary()];
    summaries.sort((a, b) {
      final sevCmp = b.severity.rank.compareTo(a.severity.rank);
      if (sevCmp != 0) return sevCmp;
      final timeCmp = b.lastSeen.compareTo(a.lastSeen);
      if (timeCmp != 0) return timeCmp;
      return b.count.compareTo(a.count);
    });
    return summaries;
  }

  /// 收集全部已注册模块提供的实时运行时状态快照（单个模块异常不影响其它分节）。
  Future<List<DiagnosticSnapshotSection>> collectRuntimeSnapshot() async {
    final sections = <DiagnosticSnapshotSection>[];
    for (final entry in _snapshotContributors.entries) {
      try {
        final raw = await entry.value();
        if (raw == null) continue;
        sections.add(
          DiagnosticSnapshotSection(
            id: raw.id,
            title: raw.title,
            entries: _sanitizeStringMap(raw.entries),
          ),
        );
      } catch (error) {
        sections.add(
          DiagnosticSnapshotSection(
            id: entry.key,
            title: '${entry.key}（采集异常）',
            entries: <String, String>{
              'collectorError':
                  NetworkErrorSanitizer.redactForDiagnosticsExport(
                    error.toString(),
                  ),
            },
          ),
        );
      }
    }
    return sections;
  }

  /// 同步生成面向快速查看的诊断报告（不等待异步数据库快照，兼容既有同步调用）。
  String buildRecentIncidentReport() {
    return _formatTextReport(snapshotSections: const <DiagnosticSnapshotSection>[]);
  }

  /// 异步生成包含实时运行态快照、故障分诊表与完整时间线的 Agent 友好诊断报告（TXT）。
  Future<String> buildAgentDiagnosticReportAsync() async {
    final sections = await collectRuntimeSnapshot();
    return _formatTextReport(snapshotSections: sections);
  }

  /// 异步生成可直接投喂给 AI Agent 解析的精简 Markdown 剪贴板摘要（控制在 60 行以内）。
  Future<String> buildCompactAgentClipboardSummaryAsync() async {
    final sections = await collectRuntimeSnapshot();
    final faults = summarizeFaults();
    final counts = summaryCounts;
    final crumbs = snapshotBreadcrumbs();
    final buf = StringBuffer()
      ..writeln('# Konata Agent 诊断定位摘要')
      ..writeln(
        '- 环境: Konata $appVersion | ${Platform.operatingSystem} ${Platform.operatingSystemVersion}'
        '${KonataLaneConfig.isIsolatedLane() ? ' | lane=${KonataLaneConfig.resolveLane()}' : ''}',
      )
      ..writeln(
        '- 统计: 异常 ${counts.errorCount} / 警告 ${counts.warningCount} / 事件 ${counts.totalEvents} / 轨迹 ${counts.breadcrumbCount} | 详细日志=${_verbose ? '开' : '关'}',
      );

    buf.writeln('\n## 1. 故障分诊（按严重度与最近发生排序）');
    if (faults.isEmpty) {
      buf.writeln('- 当前未捕获任何异常或警告。');
    } else {
      for (final f in faults.take(8)) {
        final loc = f.source ?? f.topAppFrame ?? '未标注源码位置';
        buf.writeln(
          '- [${f.severity.badge}][${f.subsystem.code}][${f.code}] ×${f.count} | 源码: `$loc` | ${f.sampleMessage}',
        );
        if (f.topAppFrame != null && f.topAppFrame != f.source) {
          buf.writeln('  - 顶栈: `${f.topAppFrame}`');
        }
      }
    }

    if (sections.isNotEmpty) {
      buf.writeln('\n## 2. 当前运行状态快照');
      for (final sec in sections) {
        final pairs = sec.entries.entries
            .take(8)
            .map((e) => '${e.key}=${e.value}')
            .join(', ');
        buf.writeln('- **${sec.title}**: $pairs');
      }
    }

    if (crumbs.isNotEmpty) {
      buf.writeln('\n## 3. 最近操作轨迹（最后 12 步）');
      final recent = crumbs.length > 12
          ? crumbs.sublist(crumbs.length - 12)
          : crumbs;
      for (final c in recent) {
        buf.writeln('- ${c.formatLine()}');
      }
    }
    return buf.toString().trimRight();
  }

  /// 异步生成机器可读的结构化 JSON 诊断包（Schema v2）。
  Future<String> buildJsonDiagnosticBundleAsync() async {
    final sections = await collectRuntimeSnapshot();
    final faults = summarizeFaults();
    final incidents = snapshotIncidentEvents();
    final merged = snapshotMergedEvents();
    final crumbs = snapshotBreadcrumbs();
    final counts = summaryCounts;

    final payload = <String, Object?>{
      'schemaVersion': 2,
      'app': <String, Object?>{
        'name': 'Konata',
        'version': appVersion,
        'exportedAt': _clock().toIso8601String(),
        'platform': Platform.operatingSystem,
        'osVersion': Platform.operatingSystemVersion,
        'verboseLogging': _verbose,
        if (KonataLaneConfig.isIsolatedLane())
          'lane': KonataLaneConfig.resolveLane(),
      },
      'counts': <String, int>{
        'totalEvents': counts.totalEvents,
        'warnings': counts.warningCount,
        'errors': counts.errorCount,
        'breadcrumbs': counts.breadcrumbCount,
      },
      'faultSummary': [for (final f in faults) f.toJson()],
      'runtimeSnapshot': [for (final s in sections) s.toJson()],
      'breadcrumbs': [for (final c in crumbs) c.toJson()],
      'incidents': [for (final ev in incidents) ev.toJson()],
      'timeline': [for (final ev in merged) ev.toJson()],
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  /// 将完整诊断报告写入指定文件路径（自动识别 `.json` 扩展名输出结构化 JSON）。
  Future<void> exportToFile(String filePath) async {
    final file = File(filePath);
    final isJson = filePath.toLowerCase().endsWith('.json');
    final content = isJson
        ? await buildJsonDiagnosticBundleAsync()
        : await buildAgentDiagnosticReportAsync();
    await file.writeAsString(content);
  }

  String _formatTextReport({
    required List<DiagnosticSnapshotSection> snapshotSections,
  }) {
    final faults = summarizeFaults();
    final incidents = snapshotIncidentEvents();
    final merged = snapshotMergedEvents();
    final crumbs = snapshotBreadcrumbs();
    final counts = summaryCounts;

    final buf = StringBuffer()
      ..writeln('============================================================')
      ..writeln('KONATA AGENT DIAGNOSTIC REPORT (SCHEMA v2)')
      ..writeln('============================================================')
      ..writeln('导出时间: ${_clock().toIso8601String()}')
      ..writeln('应用版本: Konata $appVersion')
      ..writeln(
        '系统平台: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      )
      ..writeln('详细调试日志: ${_verbose ? '已开启' : '未开启（异常、子系统状态与操作轨迹仍始终保留）'}');
    if (KonataLaneConfig.isIsolatedLane()) {
      buf.writeln('隔离车道: ${KonataLaneConfig.resolveLane()}');
    }
    buf
      ..writeln(
        '事件计数: 错误/致命=${counts.errorCount} | 警告=${counts.warningCount} | '
        '合并事件=${merged.length} | 操作轨迹=${counts.breadcrumbCount}',
      )
      ..writeln();

    buf.writeln('=== 1. 故障分诊总览（优先直达源码位置） ===');
    if (faults.isEmpty) {
      buf.writeln('未捕获任何异常或警告事件。');
    } else {
      for (var i = 0; i < faults.length; i++) {
        final f = faults[i];
        buf.writeln(
          '${i + 1}. [${f.severity.badge}][${f.subsystem.code}][${f.code}] '
          '次数=${f.count} 最近=${f.lastSeen.toIso8601String()}',
        );
        if (f.source != null) {
          buf.writeln('   源码锚点: ${f.source}');
        }
        if (f.errorType != null) {
          buf.writeln('   异常类型: ${f.errorType}');
        }
        buf.writeln('   最近描述: ${f.sampleMessage}');
        if (f.sampleContext.isNotEmpty) {
          buf.writeln('   上下文: ${jsonEncode(f.sampleContext)}');
        }
        if (f.topAppFrame != null) {
          buf.writeln('   顶部应用帧: ${f.topAppFrame}');
        }
      }
    }
    buf.writeln();

    buf.writeln('=== 2. 当前运行状态快照（已自动脱敏） ===');
    if (snapshotSections.isEmpty) {
      buf.writeln('（无附加实时状态快照）');
    } else {
      for (final sec in snapshotSections) {
        buf.writeln('[${sec.id}] ${sec.title}');
        for (final entry in sec.entries.entries) {
          buf.writeln('  ${entry.key}: ${entry.value}');
        }
      }
    }
    buf.writeln();

    buf.writeln('=== 3. 最近用户操作与路由轨迹（最多 30 步） ===');
    if (crumbs.isEmpty) {
      buf.writeln('暂无用户操作轨迹记录。');
    } else {
      final tail = crumbs.length > 30
          ? crumbs.sublist(crumbs.length - 30)
          : crumbs;
      for (final crumb in tail) {
        buf.writeln('  ${crumb.formatLine()}');
      }
    }
    buf.writeln();

    buf.writeln('=== 4. 异常与告警详情（含精炼堆栈） ===');
    if (incidents.isEmpty) {
      buf.writeln('暂无异常或告警明细。');
    } else {
      for (final ev in incidents.reversed.take(40)) {
        buf.writeln(ev.formatCompactLine());
        for (final frame in ev.appStackFrames) {
          buf.writeln('    at $frame');
        }
      }
    }
    buf.writeln();

    buf.writeln('=== 5. 全量合并事件时间线 ===');
    if (merged.isEmpty) {
      buf.writeln('暂无异常或运行记录。');
    } else {
      for (final ev in merged) {
        buf.writeln(ev.formatCompactLine());
      }
    }
    return buf.toString();
  }

  static Map<String, String> _sanitizeContext(Map<String, Object?> raw) {
    if (raw.isEmpty) return const <String, String>{};
    final out = <String, String>{};
    for (final entry in raw.entries) {
      final key = entry.key.trim();
      if (key.isEmpty || entry.value == null) continue;
      final lowerKey = key.toLowerCase();
      if (lowerKey.contains('password') ||
          lowerKey.contains('passwd') ||
          lowerKey.contains('secret') ||
          lowerKey.contains('token') ||
          lowerKey == 'pat' ||
          lowerKey.contains('apikey') ||
          lowerKey.contains('api_key') ||
          lowerKey.contains('credential') ||
          lowerKey.contains('authorization')) {
        out[key] = '***';
        continue;
      }
      final rawText = entry.value.toString().replaceAll('\n', ' ').trim();
      final clipped = rawText.length > 260
          ? '${rawText.substring(0, 260)}...'
          : rawText;
      out[key] = NetworkErrorSanitizer.redactForDiagnosticsExport(clipped);
    }
    return Map<String, String>.unmodifiable(out);
  }

  static Map<String, String> _sanitizeStringMap(Map<String, String> raw) {
    if (raw.isEmpty) return const <String, String>{};
    return _sanitizeContext(raw);
  }
}

class _MutableFaultGroup {
  _MutableFaultGroup(DiagnosticEvent first)
    : subsystem = first.subsystem,
      code = first.code,
      severity = first.severity,
      count = 1,
      firstSeen = first.timestamp,
      lastSeen = first.timestamp,
      sampleMessage = first.message,
      source = first.source,
      errorType = first.errorType,
      topAppFrame = first.appStackFrames.isEmpty
          ? null
          : first.appStackFrames.first,
      sampleContext = first.context;

  final DiagnosticSubsystem subsystem;
  final String code;
  DiagnosticSeverity severity;
  int count;
  final DateTime firstSeen;
  DateTime lastSeen;
  String sampleMessage;
  String? source;
  String? errorType;
  String? topAppFrame;
  Map<String, String> sampleContext;

  void absorb(DiagnosticEvent ev) {
    count++;
    if (ev.severity.rank > severity.rank) {
      severity = ev.severity;
    }
    if (!ev.timestamp.isBefore(lastSeen)) {
      lastSeen = ev.timestamp;
      sampleMessage = ev.message;
      sampleContext = ev.context;
      if (ev.source != null) source = ev.source;
      if (ev.errorType != null) errorType = ev.errorType;
      if (ev.appStackFrames.isNotEmpty) {
        topAppFrame = ev.appStackFrames.first;
      }
    }
  }

  DiagnosticFaultSummary toSummary() => DiagnosticFaultSummary(
    subsystem: subsystem,
    code: code,
    severity: severity,
    count: count,
    firstSeen: firstSeen,
    lastSeen: lastSeen,
    sampleMessage: sampleMessage,
    source: source,
    errorType: errorType,
    topAppFrame: topAppFrame,
    sampleContext: sampleContext,
  );
}
