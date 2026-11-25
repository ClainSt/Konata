import 'dart:collection';

import 'package:konata_contracts/konata_contracts.dart';

import 'source_folder_rules.dart';

/// 单个目录在增量扫描快照中的元数据与直属条目记录。
class DirectoryScanSnapshotNode {
  /// 创建目录快照节点。
  const DirectoryScanSnapshotNode({
    required this.relativePath,
    this.cacheValidator,
    required this.childDirs,
    required this.hasNonSupplementarySubdir,
    required this.fileEntries,
    this.nfoText,
    this.localCoverPath,
  });

  /// 反序列化单个目录节点。
  factory DirectoryScanSnapshotNode.fromJson(Map<String, Object?> json) {
    final rawChildren = json['childDirs'];
    final childDirs = <String>[
      if (rawChildren is List)
        for (final item in rawChildren)
          if (item is String && item.isNotEmpty) item,
    ];
    final rawEntries = json['fileEntries'];
    final entries = <RemoteEntry>[
      if (rawEntries is List)
        for (final item in rawEntries)
          if (item is Map<String, Object?>) _remoteEntryFromJson(item),
    ];
    return DirectoryScanSnapshotNode(
      relativePath: json['relativePath'] as String? ?? '',
      cacheValidator: json['cacheValidator'] as String?,
      childDirs: List<String>.unmodifiable(childDirs),
      hasNonSupplementarySubdir:
          json['hasNonSupplementarySubdir'] as bool? ?? false,
      fileEntries: List<RemoteEntry>.unmodifiable(entries),
      nfoText: json['nfoText'] as String?,
      localCoverPath: json['localCoverPath'] as String?,
    );
  }

  /// 相对于媒体源根目录的规范化目录路径（根目录为空字符串）。
  final String relativePath;

  /// 上级目录列举时记录的目录版本标记。
  final String? cacheValidator;

  /// 直属未忽略子目录的规范化相对路径列表。
  final List<String> childDirs;

  /// 是否包含非静态附属子目录（例如季目录、分卷目录或嵌套作品目录）。
  ///
  /// 仅当该标记为假时，目录才允许在验证标识未变的情况下整棵子树免列举复用。
  final bool hasNonSupplementarySubdir;

  /// 目录内直接归属的媒体文件、字幕文件与封面文件列表。
  final List<RemoteEntry> fileEntries;

  /// 目录内缓存的元数据说明文本（若存在）。
  final String? nfoText;

  /// 本地源扫描顺手识别的目录封面相对路径（若存在）。
  final String? localCoverPath;

  /// 序列化为紧凑字典结构。
  Map<String, Object?> toJson() => <String, Object?>{
    'relativePath': relativePath,
    if (cacheValidator != null) 'cacheValidator': cacheValidator,
    'childDirs': childDirs,
    'hasNonSupplementarySubdir': hasNonSupplementarySubdir,
    'fileEntries': <Map<String, Object?>>[
      for (final entry in fileEntries) _remoteEntryToJson(entry),
    ],
    if (nfoText != null) 'nfoText': nfoText,
    if (localCoverPath != null) 'localCoverPath': localCoverPath,
  };

  static Map<String, Object?> _remoteEntryToJson(RemoteEntry entry) =>
      <String, Object?>{
        'n': entry.name,
        'p': entry.relativePath,
        if (entry.size > 0) 's': entry.size,
        if (entry.modifiedAt != null)
          'm': entry.modifiedAt!.toUtc().microsecondsSinceEpoch,
        if (entry.etag != null && entry.etag!.isNotEmpty) 'e': entry.etag,
      };

  static RemoteEntry _remoteEntryFromJson(Map<String, Object?> json) {
    final micros = json['m'];
    return RemoteEntry(
      name: json['n'] as String? ?? '',
      relativePath: json['p'] as String? ?? '',
      isDirectory: false,
      size: (json['s'] as num?)?.toInt() ?? 0,
      modifiedAt: micros is num
          ? DateTime.fromMicrosecondsSinceEpoch(micros.toInt(), isUtc: true)
          : null,
      etag: json['e'] as String?,
    );
  }
}

/// 媒体源目录树增量扫描快照与断点续扫检查点模型。
class DirectoryScanSnapshot {
  /// 创建目录扫描快照。
  const DirectoryScanSnapshot({
    required this.sourceId,
    required this.scanRoots,
    required this.detectLocalCovers,
    required this.startedAt,
    required this.lastFullScanAt,
    required this.isComplete,
    required this.nodes,
    this.pendingQueue = const <String>[],
    this.pendingValidators = const <String, String>{},
  });

  /// 快照结构版本号；结构变更时自动作废旧快照并无缝回退全量扫描。
  static const int currentSchemaVersion = 2;

  /// 完整增量快照默认有效期（超过后自动触发一次完整校准）。
  static const Duration defaultSnapshotMaxAge = Duration(days: 7);

  /// 中断断点续扫检查点默认有效期。
  static const Duration defaultCheckpointMaxAge = Duration(hours: 24);

  /// 静态附属容器目录名集合（除通用附属规则外的字幕与蓝光原盘目录）。
  static const Set<String> _extraStaticArchiveDirs = <String>{
    'subs',
    'sub',
    'subtitles',
    'subtitle',
    '字幕',
    'bdmv',
    'stream',
    'video_ts',
  };

  /// 从 JSON 字典反序列化快照；版本不匹配或字段损坏时返回空。
  static DirectoryScanSnapshot? fromJson(Map<String, Object?> json) {
    final version = (json['schemaVersion'] as num?)?.toInt();
    if (version != currentSchemaVersion) return null;
    final sourceId = json['sourceId'] as String? ?? '';
    final startedAtMicros = json['startedAtMicros'];
    final lastFullScanAtMicros = json['lastFullScanAtMicros'];
    if (startedAtMicros is! int ||
        lastFullScanAtMicros is! int ||
        lastFullScanAtMicros > startedAtMicros) {
      return null;
    }

    final rawRoots = json['scanRoots'];
    final roots = <String>[
      if (rawRoots is List)
        for (final item in rawRoots)
          if (item is String) item,
    ];

    final rawNodes = json['nodes'];
    if (rawNodes is! Map) return null;
    final nodes = <String, DirectoryScanSnapshotNode>{};
    for (final entry in rawNodes.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String || value is! Map<String, Object?>) return null;
      final node = DirectoryScanSnapshotNode.fromJson(value);
      if (node.relativePath != key) return null;
      nodes[key] = node;
    }

    final rawPending = json['pendingQueue'];
    final pendingQueue = <String>[
      if (rawPending is List)
        for (final item in rawPending)
          if (item is String) item,
    ];

    final rawValidators = json['pendingValidators'];
    final pendingValidators = <String, String>{};
    if (rawValidators is Map) {
      for (final entry in rawValidators.entries) {
        final k = entry.key;
        final v = entry.value;
        if (k is String && v is String && v.isNotEmpty) {
          pendingValidators[k] = v;
        }
      }
    }

    return DirectoryScanSnapshot(
      sourceId: sourceId,
      scanRoots: List<String>.unmodifiable(roots),
      detectLocalCovers: json['detectLocalCovers'] as bool? ?? false,
      startedAt: DateTime.fromMicrosecondsSinceEpoch(
        startedAtMicros,
        isUtc: true,
      ),
      lastFullScanAt: DateTime.fromMicrosecondsSinceEpoch(
        lastFullScanAtMicros,
        isUtc: true,
      ),
      isComplete: json['isComplete'] as bool? ?? false,
      nodes: Map<String, DirectoryScanSnapshotNode>.unmodifiable(nodes),
      pendingQueue: List<String>.unmodifiable(pendingQueue),
      pendingValidators: Map<String, String>.unmodifiable(pendingValidators),
    );
  }

  /// 所属媒体源唯一标识。
  final String sourceId;

  /// 生成本快照时规范化后的扫描根目录列表。
  final List<String> scanRoots;

  /// 是否已同步采集本地封面路径。
  final bool detectLocalCovers;

  /// 本次扫描开始时间，续扫时沿用，用于限制采集结果的陈旧程度。
  final DateTime startedAt;

  /// 最近一次无缓存遍历的开始时间，增量扫描不刷新该时间。
  final DateTime lastFullScanAt;

  /// 是否已完成完整目录遍历（为假表示中途取消或异常中断留下的断点检查点）。
  final bool isComplete;

  /// 已完成枚举的目录路径到节点数据的映射。
  final Map<String, DirectoryScanSnapshotNode> nodes;

  /// 断点检查点尚未遍历的待扫描目录队列（完整快照固定为空）。
  final List<String> pendingQueue;

  /// 待扫描目录队列在上级列举阶段已捕获的目录验证标识映射。
  final Map<String, String> pendingValidators;

  /// 判定子目录名在给定父目录语义下是否属于静态附属或归档子目录。
  ///
  /// 季目录、分卷目录与普通子作品目录一律返回假，保证嵌套追番目录绝不会被误跳过。
  static bool isStaticSupplementaryChildDir(
    String childName, {
    required bool parentIsStaticSupplementary,
    bool Function(String) isSupplementary = SourcePathRules.isSupplementarySegment,
  }) {
    if (parentIsStaticSupplementary) return true;
    final trimmed = childName.trim();
    if (trimmed.isEmpty) return false;
    final lower = trimmed.toLowerCase();
    if (_extraStaticArchiveDirs.contains(lower)) return true;
    if (SourcePathRules.isSeasonOrVolumeSegment(trimmed)) {
      return false;
    }
    return isSupplementary(trimmed);
  }

  /// 校验快照是否仍处于有效期内。
  bool isFresh({
    required DateTime now,
    Duration maxAge = defaultSnapshotMaxAge,
  }) {
    final age = now.difference(lastFullScanAt);
    return !age.isNegative && age <= maxAge;
  }

  /// 判断本快照是否可作为指定扫描范围的断点续扫检查点恢复。
  bool canResumeCheckpoint({
    required List<String> normalizedRoots,
    required bool requireLocalCovers,
    required DateTime now,
    Duration maxAge = defaultCheckpointMaxAge,
  }) {
    if (isComplete || pendingQueue.isEmpty || nodes.isEmpty) return false;
    if (requireLocalCovers && !detectLocalCovers) return false;
    final age = now.difference(startedAt);
    if (age.isNegative || age > maxAge) return false;
    if (scanRoots.length != normalizedRoots.length) return false;
    for (var i = 0; i < scanRoots.length; i++) {
      if (scanRoots[i] != normalizedRoots[i]) return false;
    }
    return true;
  }

  /// 判断以 [dirPath] 为根的整棵子树是否可依据验证标识安全复用而免发网络列举请求。
  bool canReuseSubtree(
    String dirPath, {
    required String? expectedValidator,
    required bool allowArchiveReuse,
    required bool requireLocalCovers,
  }) {
    if (expectedValidator == null || expectedValidator.isEmpty) return false;
    if (requireLocalCovers && !detectLocalCovers) return false;
    final rootNode = nodes[dirPath];
    if (rootNode == null || rootNode.cacheValidator != expectedValidator) {
      return false;
    }
    if (rootNode.childDirs.isEmpty) return true;
    if (!allowArchiveReuse || rootNode.hasNonSupplementarySubdir) return false;

    final seen = <String>{dirPath};
    final queue = Queue<String>()..addAll(rootNode.childDirs);
    while (queue.isNotEmpty) {
      final childPath = queue.removeFirst();
      if (!seen.add(childPath)) continue;
      final childNode = nodes[childPath];
      if (childNode == null || childNode.hasNonSupplementarySubdir) {
        return false;
      }
      queue.addAll(childNode.childDirs);
    }
    return true;
  }

  /// 按广度优先顺序收集以 [dirPath] 为根的整棵缓存子树节点（内置防环保护）。
  List<DirectoryScanSnapshotNode> collectSubtreeNodes(String dirPath) {
    final rootNode = nodes[dirPath];
    if (rootNode == null) return const <DirectoryScanSnapshotNode>[];
    final out = <DirectoryScanSnapshotNode>[];
    final seen = <String>{dirPath};
    final queue = Queue<DirectoryScanSnapshotNode>()..add(rootNode);
    while (queue.isNotEmpty) {
      final current = queue.removeFirst();
      out.add(current);
      for (final childPath in current.childDirs) {
        if (!seen.add(childPath)) continue;
        final childNode = nodes[childPath];
        if (childNode != null) {
          queue.add(childNode);
        }
      }
    }
    return out;
  }

  /// 序列化为完整 JSON 字典。
  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': currentSchemaVersion,
    'sourceId': sourceId,
    'scanRoots': scanRoots,
    'detectLocalCovers': detectLocalCovers,
    'startedAtMicros': startedAt.microsecondsSinceEpoch,
    'lastFullScanAtMicros': lastFullScanAt.microsecondsSinceEpoch,
    'isComplete': isComplete,
    'nodes': <String, Object?>{
      for (final entry in nodes.entries) entry.key: entry.value.toJson(),
    },
    if (pendingQueue.isNotEmpty) 'pendingQueue': pendingQueue,
    if (pendingValidators.isNotEmpty) 'pendingValidators': pendingValidators,
  };
}
