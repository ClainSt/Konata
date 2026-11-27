import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:konata_contracts/konata_contracts.dart';
import 'package:path/path.dart' as p;

/// Konata v3 结构化脱敏诊断日志存储（纯 Dart，实现 [DiagnosticLogPort]）。
///
/// 采用「全局时间线环 + 告警/异常免淘汰环 + 按子系统独立保护环 + 操作轨迹面包屑环」
/// 四层隔离架构，确保高频业务日志绝不冲刷关键故障，所有导出均自动脱敏。
final class DiagnosticLogStore implements DiagnosticLogPort {
  /// 创建诊断日志存储器。
  DiagnosticLogStore({
    this.maxEntries = 600,
    this.verboseMaxEntries = 2000,
    this.maxErrorEntries = 150,
    this.maxEntriesPerSubsystem = 80,
    this.maxBreadcrumbs = 80,
    this.appVersion = KonataAppVersion.release,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// 非详细模式下的全局时间线容量上限。
  final int maxEntries;

  /// 开启详细调试日志后的全局时间线容量上限。
  final int verboseMaxEntries;

  /// 告警与异常专属免淘汰环容量上限。
  final int maxErrorEntries;

  /// 每个子系统独立保护环容量上限。
  final int maxEntriesPerSubsystem;

  /// 操作与路由轨迹面包屑保留上限。
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

  bool _verbose = false;
  int _nextEventSeq = 1;
  int _nextBreadcrumbSeq = 1;

  static final RegExp _konataPkgFramePattern = RegExp(
    r'package:(konata[a-z0-9_]*|engine_[a-z0-9_]+|feature_[a-z0-9_]+)/([^:\s)]+:\d+(?::\d+)?)',
  );
  static final RegExp _framePrefixPattern = RegExp(r'^#\d+\s+');

  @override
  bool get verboseEnabled => _verbose;

  @override
  DiagnosticSummaryCounts get summaryCounts {
    var warns = 0;
    var errs = 0;
    for (final ev in _errorRing) {
      if (ev.severity == DiagnosticSeverity.warn) {
        warns++;
      } else if (ev.severity.rank >= DiagnosticSeverity.error.rank) {
        errs++;
      }
    }
    return DiagnosticSummaryCounts(
      totalEvents: _globalRing.length,
      warningCount: warns,
      errorCount: errs,
      breadcrumbCount: _breadcrumbs.length,
    );
  }

  @override
  void setVerbose(bool enabled) {
    if (_verbose == enabled) return;
    _verbose = enabled;
    logEvent(
      subsystem: DiagnosticSubsystem.app,
      code: 'DIAG_VERBOSE_CHANGED',
      message: '详细调试日志已${enabled ? '开启' : '关闭'}',
      source: 'konata_storage:diagnostic_log_store.dart:setVerbose',
      context: <String, Object?>{'verbose': enabled},
    );
  }

  @override
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
    if (severity == DiagnosticSeverity.debug && !_verbose) {
      return;
    }

    final cleanMessage = DiagnosticTextSanitizer.redactForExport(
      message.trim(),
    );
    final cleanContext = _sanitizeContext(context);
    final effectiveStack =
        stackTrace ?? (error is Error ? error.stackTrace : null);
    final frames = _extractFrames(effectiveStack);
    final effectiveSource = (source != null && source.trim().isNotEmpty)
        ? source.trim()
        : _extractPrimarySource(effectiveStack);

    final event = DiagnosticEvent(
      seq: _nextEventSeq++,
      timestamp: _clock(),
      severity: severity,
      subsystem: subsystem,
      code: code.trim().isEmpty ? '${subsystem.code}_EVENT' : code.trim(),
      message: cleanMessage,
      source: effectiveSource,
      context: cleanContext,
      errorType: error?.runtimeType.toString(),
      appStackFrames: frames,
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
  }

  @override
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
      'errorDetail': DiagnosticTextSanitizer.redactForExport(error.toString()),
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

  @override
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
      label: DiagnosticTextSanitizer.redactForExport(label.trim()),
      source: source?.trim().isEmpty == true ? null : source?.trim(),
      detail: detail == null || detail.trim().isEmpty
          ? null
          : DiagnosticTextSanitizer.redactForExport(detail.trim()),
    );
    while (_breadcrumbs.length >= maxBreadcrumbs) {
      _breadcrumbs.removeFirst();
    }
    _breadcrumbs.addLast(crumb);
  }

  @override
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

  @override
  List<DiagnosticEvent> snapshotEvents() {
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
    return bySeq.values.toList(growable: false)
      ..sort((a, b) => a.seq.compareTo(b.seq));
  }

  /// 返回保留的用户操作面包屑列表（按时间升序）。
  List<DiagnosticBreadcrumb> snapshotBreadcrumbs() =>
      _breadcrumbs.toList(growable: false);

  @override
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
    final summaries = <DiagnosticFaultSummary>[
      for (final group in grouped.values) group.toSummary(),
    ];
    summaries.sort((a, b) {
      final sevCmp = b.severity.rank.compareTo(a.severity.rank);
      if (sevCmp != 0) return sevCmp;
      final timeCmp = b.lastSeen.compareTo(a.lastSeen);
      if (timeCmp != 0) return timeCmp;
      return b.count.compareTo(a.count);
    });
    return summaries;
  }

  /// 收集全部已注册模块提供的实时状态快照并做全量脱敏。
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
            entries: _sanitizeContext(raw.entries),
          ),
        );
      } catch (error) {
        sections.add(
          DiagnosticSnapshotSection(
            id: entry.key,
            title: '${entry.key}（采集异常）',
            entries: <String, String>{
              'collectorError': DiagnosticTextSanitizer.redactForExport(
                error.toString(),
              ),
            },
          ),
        );
      }
    }
    return sections;
  }

  @override
  Future<String> buildJsonBundle() async {
    final sections = await collectRuntimeSnapshot();
    final faults = summarizeFaults();
    final merged = snapshotEvents();
    final crumbs = snapshotBreadcrumbs();
    final counts = summaryCounts;

    final payload = <String, Object?>{
      'schemaVersion': 3,
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
      'faultSummary': <Map<String, Object?>>[
        for (final f in faults) f.toJson(),
      ],
      'runtimeSnapshot': <Map<String, Object?>>[
        for (final s in sections) s.toJson(),
      ],
      'breadcrumbs': <Map<String, Object?>>[for (final c in crumbs) c.toJson()],
      'incidents': <Map<String, Object?>>[
        for (final ev in _errorRing) ev.toJson(),
      ],
      'timeline': <Map<String, Object?>>[for (final ev in merged) ev.toJson()],
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  @override
  Future<String> buildTextReport() async {
    final sections = await collectRuntimeSnapshot();
    final faults = summarizeFaults();
    final merged = snapshotEvents();
    final crumbs = snapshotBreadcrumbs();
    final counts = summaryCounts;

    final buf = StringBuffer()
      ..writeln('============================================================')
      ..writeln('Konata 问题报告')
      ..writeln('============================================================')
      ..writeln('导出时间: ${_clock().toIso8601String()}')
      ..writeln('应用版本: Konata $appVersion')
      ..writeln(
        '运行平台: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      )
      ..writeln(DiagnosticReadableReport.overview(counts))
      ..writeln();

    buf.writeln('=== 1. 最近问题与处理建议 ===');
    if (faults.isEmpty) {
      buf.writeln('当前未捕获任何异常或警告。');
    } else {
      for (var i = 0; i < faults.length; i++) {
        final f = faults[i];
        buf.writeln('${i + 1}. ${DiagnosticReadableReport.formatFault(f)}');
      }
    }
    buf.writeln();

    buf.writeln('=== 2. 最近操作 ===');
    if (crumbs.isEmpty) {
      buf.writeln('暂无操作记录。');
    } else {
      for (final crumb in crumbs.reversed.take(12).toList().reversed) {
        buf.writeln(
          '  ${crumb.timestamp.toLocal().toString().split('.').first} ${crumb.label}',
        );
      }
    }
    buf.writeln();
    buf.writeln('=== 3. 最近运行记录 ===');
    for (final ev in merged.reversed.take(12).toList().reversed) {
      buf.writeln(DiagnosticReadableReport.formatEvent(ev));
    }
    buf.writeln();
    buf.writeln('=== 以下为开发者排查信息（已脱敏） ===');
    buf.writeln('--- 故障详情 ---');
    for (final f in faults) {
      buf.writeln(jsonEncode(f.toJson()));
    }
    buf.writeln('--- 应用运行状态 ---');
    if (sections.isEmpty) {
      buf.writeln('（无附加运行状态快照）');
    } else {
      for (final sec in sections) {
        buf.writeln('[${sec.id}] ${sec.title}');
        for (final entry in sec.entries.entries) {
          buf.writeln('  ${entry.key}: ${entry.value}');
        }
      }
    }
    buf.writeln();

    buf.writeln('--- 完整操作记录 ---');
    if (crumbs.isEmpty) {
      buf.writeln('暂无操作轨迹记录。');
    } else {
      for (final crumb in crumbs) {
        buf.writeln('  ${crumb.formatLine()}');
      }
    }
    buf.writeln();

    buf.writeln('--- 完整事件记录 ---');
    if (merged.isEmpty) {
      buf.writeln('暂无运行事件。');
    } else {
      for (final ev in merged) {
        buf.writeln(ev.formatCompactLine());
      }
    }
    return buf.toString();
  }

  /// 将完整诊断报告写入 `<Root>/userdata/logs/` 目录并返回落盘文件路径。
  Future<String> exportToLogsDir(
    StorageRootPort storageRoot, {
    bool asJson = true,
  }) async {
    final logsDirPath = await storageRoot.ensureLogsDirPath();
    final now = _clock();
    final stamp =
        '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}';
    final ext = asJson ? 'json' : 'txt';
    final targetPath = p.join(logsDirPath, 'konata_diag_$stamp.$ext');
    final content = asJson ? await buildJsonBundle() : await buildTextReport();
    await File(targetPath).writeAsString(content);
    return targetPath;
  }

  @override
  void clear() {
    _globalRing.clear();
    _errorRing.clear();
    _subsystemRings.clear();
    _breadcrumbs.clear();
  }

  static Map<String, String> _sanitizeContext(Map<String, Object?> raw) {
    if (raw.isEmpty) return const <String, String>{};
    final out = <String, String>{};
    for (final entry in raw.entries) {
      final key = entry.key.trim();
      if (key.isEmpty || entry.value == null) continue;
      if (DiagnosticTextSanitizer.isSensitiveKey(key)) {
        out[key] = '***';
        continue;
      }
      final rawText = entry.value.toString().replaceAll('\n', ' ').trim();
      final clipped = rawText.length > 260
          ? '${rawText.substring(0, 260)}...'
          : rawText;
      out[key] = DiagnosticTextSanitizer.redactForExport(clipped);
    }
    return Map<String, String>.unmodifiable(out);
  }

  static List<String> _extractFrames(StackTrace? stackTrace) {
    if (stackTrace == null) return const <String>[];
    final lines = stackTrace
        .toString()
        .replaceAll('\r\n', '\n')
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty);
    final appFrames = <String>[];
    final extFrames = <String>[];
    for (final line in lines) {
      if (line.contains('<asynchronous suspension>')) continue;
      final cleaned = DiagnosticTextSanitizer.redactForExport(
        line.replaceFirst(_framePrefixPattern, ''),
      );
      if (_konataPkgFramePattern.hasMatch(line)) {
        if (appFrames.length < 8) appFrames.add(cleaned);
      } else if (extFrames.length < 3) {
        extFrames.add(cleaned);
      }
      if (appFrames.length >= 8 && extFrames.length >= 3) break;
    }
    if (appFrames.isEmpty) return extFrames;
    return <String>[...appFrames, ...extFrames.take(2)];
  }

  static String? _extractPrimarySource(StackTrace? stackTrace) {
    if (stackTrace == null) return null;
    final match = _konataPkgFramePattern.firstMatch(stackTrace.toString());
    if (match == null) return null;
    return '${match.group(1)}:${match.group(2)}';
  }
}

final class _MutableFaultGroup {
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
