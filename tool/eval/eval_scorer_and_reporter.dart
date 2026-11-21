import 'dart:convert';
import 'dart:io';

import 'eval_models.dart';

/// 单条黄金集用例的逐项判定明细。
class CaseEvalVerdict {
  /// 创建单条判定结果。
  const CaseEvalVerdict({
    required this.caseItem,
    required this.passed,
    required this.outcome,
    required this.rootCause,
    this.record,
    this.detail = '',
    this.isWrongBind = false,
    this.isFalseWallPromotion = false,
    this.hasExtraLeak = false,
    this.seasonChecked = false,
    this.seasonRight = false,
  });

  /// 对应的黄金集用例。
  final GoldenCase caseItem;

  /// 是否综合通过。
  final bool passed;

  /// 匹配结果分类（`auto_right` / `review_hit` / `miss` / `wrong_bind` / `correct_none` / `split_missed` / `noise_fail`）。
  final String outcome;

  /// 失败根因聚类码（通过时为空串）。
  final String rootCause;

  /// 实际匹配的评测记录（漏拆或缺失目录时为 `null`）。
  final EvalClusterRecord? record;

  /// 简短人类可读差异说明。
  final String detail;

  /// 是否触犯“错绑红线”。
  final bool isWrongBind;

  /// 是否触犯“0 正片纯特典误上墙红线”。
  final bool isFalseWallPromotion;

  /// 是否出现非正片噪音泄漏到正片。
  final bool hasExtraLeak;

  /// 是否纳入季号考评。
  final bool seasonChecked;

  /// 季号是否命中。
  final bool seasonRight;

  /// 导出可序列化结构（用于写入 `baseline.json` 与跨轮 Diff）。
  Map<String, Object?> toJson() => {
    'caseId': caseItem.caseId,
    'bucket': caseItem.bucket,
    'physicalRoot': caseItem.physicalRoot,
    'clusterHint': caseItem.clusterHint,
    'verified': caseItem.verified,
    'passed': passed,
    'outcome': outcome,
    'rootCause': rootCause,
    'isWrongBind': isWrongBind,
    'isFalseWallPromotion': isFalseWallPromotion,
    'hasExtraLeak': hasExtraLeak,
    'seasonChecked': seasonChecked,
    'seasonRight': seasonRight,
    'actualTmdb': record?.bestTmdbKey,
    'actualSeason': record?.matchedSeason,
    'actualBangumi': record?.bestBangumiId,
    'actualWall': record?.wallChannel,
    'actualLevel': record?.matchLevel,
    'logoSource': record?.logoSource,
    'logoLanguage': record?.logoLanguage,
    'detail': detail,
  };
}

/// 单个评测分桶的汇总计分指标。
class BucketScoreSummary {
  /// 创建分桶汇总。
  const BucketScoreSummary({
    required this.bucket,
    required this.total,
    required this.passed,
    required this.autoRight,
    required this.reviewHit,
    required this.miss,
    required this.wrongBind,
    required this.extraLeaks,
    required this.falseWallPromotions,
    required this.seasonChecked,
    required this.seasonRight,
  });

  /// 分桶名。
  final String bucket;

  /// 样本总数。
  final int total;

  /// 通过数。
  final int passed;

  /// 自动绑定精确命中数（含正确拒绝绑定）。
  final int autoRight;

  /// 待复核但 Top-1 命中数。
  final int reviewHit;

  /// 漏绑或漏拆数。
  final int miss;

  /// 错绑数（红线指标）。
  final int wrongBind;

  /// 发生非正片噪音泄漏的条目数。
  final int extraLeaks;

  /// 纯特典误上墙数（红线指标）。
  final int falseWallPromotions;

  /// 参与季号考评条目数。
  final int seasonChecked;

  /// 季号命中条目数。
  final int seasonRight;

  /// 通过率百分比（0.0 ~ 100.0）。
  double get accuracyPct => total == 0 ? 0.0 : (passed * 100.0 / total);

  /// 导出可序列化 JSON。
  Map<String, Object?> toJson() => {
    'bucket': bucket,
    'total': total,
    'passed': passed,
    'accuracyPct': double.parse(accuracyPct.toStringAsFixed(2)),
    'autoRight': autoRight,
    'reviewHit': reviewHit,
    'miss': miss,
    'wrongBind': wrongBind,
    'extraLeaks': extraLeaks,
    'falseWallPromotions': falseWallPromotions,
    'seasonChecked': seasonChecked,
    'seasonRight': seasonRight,
  };
}

/// Fanart.tv + TMDB 整包艺术图协同与四通道上墙统计摘要。
class ArtworkAndWallSummary {
  /// 创建统计摘要。
  const ArtworkAndWallSummary({
    required this.evaluatedWorks,
    required this.wallChannels,
    required this.logoSourceCounts,
    required this.logoLanguageCounts,
    required this.logoHitCount,
    required this.logoUpgradedByFanartCount,
    required this.backdropSuboptimalCount,
    required this.backdropUpgradedByFanartCount,
    required this.posterNeedsFallbackCount,
    required this.posterFilledByFanartCount,
    required this.tvWorksCount,
    required this.tvdbSourceCounts,
    required this.fanartQueriedCount,
  });

  /// 参与统计的归组作品总数。
  final int evaluatedWorks;

  /// 四通道上墙计数（`tmdb` / `bgm_only` / `cover_fallback` / `block`）。
  final Map<String, int> wallChannels;

  /// 透明徽标来源分布（`tmdb` / `fanart` / `none`）。
  final Map<String, int> logoSourceCounts;

  /// 透明徽标语言档位分布（`zh_cn` / `zh_tw` / `ja` / `en` / `neutral` / `other` / `none`）。
  final Map<String, int> logoLanguageCounts;

  /// 命中有效透明徽标的作品数。
  final int logoHitCount;

  /// 由 Fanart.tv 跨源升级胜出的透明徽标数。
  final int logoUpgradedByFanartCount;

  /// TMDB 背景被判欠佳（缺图/低清/带字）的作品数。
  final int backdropSuboptimalCount;

  /// 成功由 Fanart.tv 无字 1080p 横图升级的作品数。
  final int backdropUpgradedByFanartCount;

  /// TMDB 与 Bangumi 均缺封面的作品数。
  final int posterNeedsFallbackCount;

  /// 成功由 Fanart.tv 竖版海报救回的作品数。
  final int posterFilledByFanartCount;

  /// 匹配为 TV 剧集的作品总数（用于计算 `tvdbId` 供给率）。
  final int tvWorksCount;

  /// TV 作品 `tvdbId` 来源计数（`tmdb_external_ids` / `offline_map_v2` / `missing`）。
  final Map<String, int> tvdbSourceCounts;

  /// 实际发起 Fanart 整包查询的作品数。
  final int fanartQueriedCount;

  /// 透明徽标总命中率（百分比）。
  double get logoHitPct =>
      evaluatedWorks == 0 ? 0.0 : (logoHitCount * 100.0 / evaluatedWorks);

  /// 导出可序列化 JSON。
  Map<String, Object?> toJson() => {
    'evaluatedWorks': evaluatedWorks,
    'wallChannels': wallChannels,
    'logoHitCount': logoHitCount,
    'logoHitPct': double.parse(logoHitPct.toStringAsFixed(2)),
    'logoSourceCounts': logoSourceCounts,
    'logoLanguageCounts': logoLanguageCounts,
    'logoUpgradedByFanartCount': logoUpgradedByFanartCount,
    'backdropSuboptimalCount': backdropSuboptimalCount,
    'backdropUpgradedByFanartCount': backdropUpgradedByFanartCount,
    'posterNeedsFallbackCount': posterNeedsFallbackCount,
    'posterFilledByFanartCount': posterFilledByFanartCount,
    'tvWorksCount': tvWorksCount,
    'tvdbSourceCounts': tvdbSourceCounts,
    'fanartQueriedCount': fanartQueriedCount,
  };
}

/// 单次评测完整汇总（评分、艺术图统计、根因聚类与基线差异）。
class EvalRunReport {
  /// 创建汇总报告。
  const EvalRunReport({
    required this.runId,
    required this.mode,
    required this.artworkMode,
    required this.sourceKind,
    required this.mappingInfo,
    required this.elapsedMs,
    required this.recordsCount,
    required this.verdicts,
    required this.buckets,
    required this.structureStats,
    required this.artworkSummary,
    required this.rootCauseClusters,
    required this.networkStatsJson,
    required this.recordsByFolderKey,
  });

  /// 本次运行唯一标识。
  final String runId;

  /// 运行模式名称。
  final String mode;

  /// 艺术图探测档位名称。
  final String artworkMode;

  /// 模拟媒体源类型。
  final String sourceKind;

  /// 当前生效离线映射表摘要。
  final String mappingInfo;

  /// 总耗时（毫秒）。
  final int elapsedMs;

  /// 实际评测的归组作品总数。
  final int recordsCount;

  /// 黄金集逐条判定明细（无黄金集时为空）。
  final List<CaseEvalVerdict> verdicts;

  /// 六维分桶汇总表。
  final Map<String, BucketScoreSummary> buckets;

  /// 物理目录拆簇结构准确率统计。
  final ({int checkedRoots, int exactSplitRoots, int splitMissed, int splitOver})
  structureStats;

  /// 艺术图协同与四通道上墙统计。
  final ArtworkAndWallSummary artworkSummary;

  /// 按根因聚类后的异常代表列表（根因码 -> 代表项列表）。
  final Map<String, List<String>> rootCauseClusters;

  /// 网络缓存与限流统计 JSON。
  final Map<String, Object?> networkStatsJson;

  /// 按 `folderKey` 索引的紧凑结果摘要（供无黄金集场景做 `--parse-only` Diff）。
  final Map<String, Map<String, Object?>> recordsByFolderKey;

  /// 导出供落盘 `summary.json` 与 `baseline.json` 的完整结构。
  Map<String, Object?> toJson() => {
    'runId': runId,
    'mode': mode,
    'artworkMode': artworkMode,
    'sourceKind': sourceKind,
    'mappingInfo': mappingInfo,
    'elapsedMs': elapsedMs,
    'recordsCount': recordsCount,
    'structure': {
      'checkedRoots': structureStats.checkedRoots,
      'exactSplitRoots': structureStats.exactSplitRoots,
      'splitMissed': structureStats.splitMissed,
      'splitOver': structureStats.splitOver,
    },
    'buckets': {for (final e in buckets.entries) e.key: e.value.toJson()},
    'artworkAndWall': artworkSummary.toJson(),
    'rootCauseCounts': {
      for (final e in rootCauseClusters.entries) e.key: e.value.length,
    },
    'network': networkStatsJson,
    'verdicts': {for (final v in verdicts) v.caseItem.caseId: v.toJson()},
    'records': recordsByFolderKey,
  };
}

/// 评测计分、根因聚类、基线对比与精简 Markdown 汇报生成器。
abstract final class EvalScorerAndReporter {
  /// 汇总单次运行的所有分桶指标与艺术图协同统计。
  static EvalRunReport evaluate({
    required String runId,
    required EvalMode mode,
    required EvalArtworkMode artworkMode,
    required EvalSourceKind sourceKind,
    required String mappingInfo,
    required int elapsedMs,
    required List<EvalClusterRecord> records,
    required List<GoldenCase> goldenCases,
    required Map<String, Object?> networkStatsJson,
  }) {
    final byRoot = <String, List<EvalClusterRecord>>{};
    final compactRecords = <String, Map<String, Object?>>{};
    for (final r in records) {
      byRoot.putIfAbsent(r.physicalRoot, () => <EvalClusterRecord>[]).add(r);
      compactRecords[r.folderKey] = {
        'physicalRoot': r.physicalRoot,
        'title': r.cleanTitle,
        'movie': r.isMovieHint,
        'season': r.matchedSeason ?? r.seasonHint,
        'mainCount': r.mainVideoCount,
        'extraCount': r.extraVideoCount,
        'leaks': r.suspectedExtraLeakPaths.length,
        'level': r.matchLevel,
        'tmdb': r.bestTmdbKey,
        'bgm': r.bestBangumiId,
        'wall': r.wallChannel,
        'logoSource': r.logoSource,
        'logoLang': r.logoLanguage,
      };
    }

    final expectedByRoot = <String, List<GoldenCase>>{};
    for (final c in goldenCases) {
      expectedByRoot.putIfAbsent(c.physicalRoot, () => <GoldenCase>[]).add(c);
    }

    var checkedRoots = 0;
    var exactSplitRoots = 0;
    var splitMissed = 0;
    var splitOver = 0;

    final verdicts = <CaseEvalVerdict>[];
    final rootCauses = <String, List<String>>{};
    void addCause(String code, String sample) {
      if (code.isEmpty) return;
      rootCauses.putIfAbsent(code, () => <String>[]).add(sample);
    }

    for (final entry in expectedByRoot.entries) {
      final root = entry.key;
      final expectedList = entry.value;
      final actualList = byRoot[root] ?? const <EvalClusterRecord>[];
      checkedRoots++;
      if (actualList.length == expectedList.length) {
        exactSplitRoots++;
      } else if (actualList.length < expectedList.length) {
        splitMissed++;
      } else {
        splitOver++;
      }

      final usedIndices = <int>{};
      for (final caseItem in expectedList) {
        final matchedIdx = _matchClusterForCase(
          caseItem,
          actualList,
          usedIndices,
        );
        final matchedRecord = matchedIdx == null
            ? null
            : actualList[matchedIdx];
        if (matchedIdx != null) {
          usedIndices.add(matchedIdx);
        }
        final verdict = _scoreCase(
          caseItem: caseItem,
          record: matchedRecord,
          mode: mode,
        );
        verdicts.add(verdict);
        if (!verdict.passed) {
          addCause(
            verdict.rootCause,
            '${caseItem.caseId} [${caseItem.physicalRoot}] ${verdict.detail}',
          );
        }
      }
    }

    // 无黄金集（如 --parse-only）时，仍基于解析异常与网络错误做全量根因聚类。
    if (goldenCases.isEmpty) {
      for (final r in records) {
        if (r.suspectedExtraLeakPaths.isNotEmpty) {
          addCause(
            'extra_leaked_to_main',
            '${r.folderKey} (${r.suspectedExtraLeakPaths.first})',
          );
        }
        if (r.networkError != null && r.networkError!.isNotEmpty) {
          addCause('network_or_429', '${r.folderKey}: ${r.networkError}');
        }
        if (r.bestTmdbKey != null &&
            r.bestTmdbKey!.startsWith('tv:') &&
            r.tvdbId == null &&
            artworkMode != EvalArtworkMode.off) {
          addCause('missing_tvdb_id', '${r.folderKey} (${r.bestTmdbKey})');
        }
      }
    }

    final bucketOrder = <String>[
      'tv',
      'mixed_movie',
      'ova_sp',
      'noise_extra',
      'pure_noise',
      'remake_multi',
    ];
    final groupedVerdicts = <String, List<CaseEvalVerdict>>{};
    for (final v in verdicts) {
      groupedVerdicts
          .putIfAbsent(v.caseItem.bucket, () => <CaseEvalVerdict>[])
          .add(v);
    }
    final bucketSummaries = <String, BucketScoreSummary>{};
    for (final b in [
      ...bucketOrder,
      ...groupedVerdicts.keys.where((k) => !bucketOrder.contains(k)),
    ]) {
      final list = groupedVerdicts[b];
      if (list == null || list.isEmpty) continue;
      bucketSummaries[b] = _summarizeBucket(b, list);
    }
    if (verdicts.isNotEmpty) {
      bucketSummaries['ALL'] = _summarizeBucket('ALL', verdicts);
    }

    final artworkSummary = _summarizeArtworkAndWall(records);

    return EvalRunReport(
      runId: runId,
      mode: mode.name,
      artworkMode: artworkMode.name,
      sourceKind: sourceKind.name,
      mappingInfo: mappingInfo,
      elapsedMs: elapsedMs,
      recordsCount: records.length,
      verdicts: verdicts,
      buckets: bucketSummaries,
      structureStats: (
        checkedRoots: checkedRoots,
        exactSplitRoots: exactSplitRoots,
        splitMissed: splitMissed,
        splitOver: splitOver,
      ),
      artworkSummary: artworkSummary,
      rootCauseClusters: rootCauses,
      networkStatsJson: networkStatsJson,
      recordsByFolderKey: compactRecords,
    );
  }

  /// 更新错题本 `local_eval/failed_keys.json`（保留当前错题与本次新修复项供 `--only-failed` 回归）。
  static void writeFailedKeys({
    required File file,
    required EvalRunReport report,
    Map<String, Object?>? baselineJson,
  }) {
    final failedRoots = <String>{};
    final fixedRoots = <String>{};
    final prevVerdicts = baselineJson?['verdicts'] is Map
        ? (baselineJson!['verdicts'] as Map).cast<String, Object?>()
        : const <String, Object?>{};

    for (final v in report.verdicts) {
      if (!v.passed) {
        failedRoots.add(v.caseItem.physicalRoot);
      } else {
        final prev = prevVerdicts[v.caseItem.caseId];
        if (prev is Map && prev['passed'] == false) {
          fixedRoots.add(v.caseItem.physicalRoot);
        }
      }
    }

    if (report.verdicts.isEmpty) {
      for (final r in report.recordsByFolderKey.values) {
        final leaks = (r['leaks'] as num?)?.toInt() ?? 0;
        if (leaks > 0) {
          final root = (r['physicalRoot'] ?? '').toString();
          if (root.isNotEmpty) failedRoots.add(root);
        }
      }
    }

    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
        'runId': report.runId,
        'failedPhysicalRoots': failedRoots.toList()..sort(),
        'recentlyFixedRoots': fixedRoots.toList()..sort(),
      }),
      flush: true,
    );
  }

  /// 渲染精简高信噪比 Markdown 对比报告（严禁全量铺陈数千行明细）。
  static String renderDiffMarkdown({
    required EvalRunReport report,
    Map<String, Object?>? baselineJson,
  }) {
    final buf = StringBuffer();
    final net = report.networkStatsJson;
    final hits = (net['totalCacheHits'] as num?)?.toInt() ?? 0;
    final misses = (net['totalCacheMisses'] as num?)?.toInt() ?? 0;
    final reqs = (net['totalNetworkRequests'] as num?)?.toInt() ?? 0;
    final rate429 = (net['totalHttp429'] as num?)?.toInt() ?? 0;
    final hitRate = (hits + misses) == 0
        ? '100.0%'
        : '${(hits * 100.0 / (hits + misses)).toStringAsFixed(1)}%';

    buf.writeln('# Konata 刮削评测差异报告 (`${report.runId}`)');
    buf.writeln();
    buf.writeln(
      '- **模式**：`${report.mode}` ｜ **艺术图档位**：`${report.artworkMode}` ｜ **模拟源**：`${report.sourceKind}`',
    );
    buf.writeln(
      '- **映射表**：${report.mappingInfo} ｜ **归组作品**：`${report.recordsCount}` ｜ **耗时**：`${(report.elapsedMs / 1000).toStringAsFixed(1)}s`',
    );
    buf.writeln(
      '- **网络与 VCR 缓存**：命中 `$hits` / 未命中 `$misses`（命中率 `$hitRate`）｜ 真实外部请求 `$reqs` ｜ `429` 限流 `$rate429`',
    );
    buf.writeln();

    final prevBuckets = baselineJson?['buckets'] is Map
        ? (baselineJson!['buckets'] as Map).cast<String, Object?>()
        : const <String, Object?>{};

    if (report.buckets.isNotEmpty) {
      final verifiedCount = report.verdicts
          .where((v) => v.caseItem.verified)
          .length;
      buf.writeln(
        '## 一、六维分桶正确率与基线变化（黄金集 `${report.verdicts.length}` 条，已人工核定 `$verifiedCount` 条）',
      );
      buf.writeln();
      final s = report.structureStats;
      final splitPct = s.checkedRoots == 0
          ? '0.0%'
          : '${(s.exactSplitRoots * 100.0 / s.checkedRoots).toStringAsFixed(1)}%';
      buf.writeln(
        '- **结构拆簇与归组**：精确匹配 `${s.exactSplitRoots}/${s.checkedRoots}` (`$splitPct`) ｜ 漏拆 `${s.splitMissed}` ｜ 过拆 `${s.splitOver}`',
      );
      buf.writeln();
      buf.writeln(
        '| 分桶 | 样本 | 通过率 (Δ) | 精确命中 | 复核Top1 | 漏绑/漏拆 | 错绑(红线) | 噪音泄漏 | 误上墙(红线) |',
      );
      buf.writeln('| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |');
      for (final entry in report.buckets.entries) {
        final b = entry.value;
        final prevAcc = _prevDouble(prevBuckets[entry.key], 'accuracyPct');
        final deltaStr = prevAcc == null
            ? '-'
            : _formatDelta(b.accuracyPct - prevAcc);
        buf.writeln(
          '| ${_bucketDisplayLabel(b.bucket)} | ${b.total} | '
          '${b.accuracyPct.toStringAsFixed(1)}% ($deltaStr) | '
          '${b.autoRight} | ${b.reviewHit} | ${b.miss} | '
          '${b.wrongBind} | ${b.extraLeaks} | ${b.falseWallPromotions} |',
        );
      }
      buf.writeln();
    }

    // 艺术图协同与四通道独立上墙统计
    final art = report.artworkSummary;
    buf.writeln('## 二、海报墙独立上墙与 Fanart.tv 整包艺术图协同');
    buf.writeln();
    buf.writeln(
      '- **四通道上墙分布**：TMDB `${art.wallChannels['tmdb'] ?? 0}` ｜ '
      '仅 Bangumi+Fanart `${art.wallChannels['bgm_only'] ?? 0}` ｜ '
      '封面兜底 `${art.wallChannels['cover_fallback'] ?? 0}` ｜ '
      '拦截/未上墙 `${art.wallChannels['block'] ?? 0}`',
    );
    if (report.artworkMode != EvalArtworkMode.off.name) {
      final prevArt = baselineJson?['artworkAndWall'] is Map
          ? (baselineJson!['artworkAndWall'] as Map).cast<String, Object?>()
          : const <String, Object?>{};
      final prevLogoPct = (prevArt['logoHitPct'] as num?)?.toDouble();
      final logoDelta = prevLogoPct == null
          ? '-'
          : _formatDelta(art.logoHitPct - prevLogoPct);
      buf.writeln(
        '- **透明徽标（ClearLogo）**：命中 `${art.logoHitCount}/${art.evaluatedWorks}` '
        '(` ${art.logoHitPct.toStringAsFixed(1)}%`, Δ `$logoDelta`) ｜ '
        '来源：`tmdb=${art.logoSourceCounts['tmdb'] ?? 0}`, '
        '`fanart=${art.logoSourceCounts['fanart'] ?? 0}`, '
        '`none=${art.logoSourceCounts['none'] ?? 0}` ｜ '
        '**Fanart 跨源升级**：`${art.logoUpgradedByFanartCount}` 部',
      );
      buf.writeln(
        '- **徽标语言分布**：`简中=${art.logoLanguageCounts['zh_cn'] ?? 0}`, '
        '`繁中=${art.logoLanguageCounts['zh_tw'] ?? 0}`, '
        '`日文=${art.logoLanguageCounts['ja'] ?? 0}`, '
        '`英文=${art.logoLanguageCounts['en'] ?? 0}`, '
        '`无语言=${art.logoLanguageCounts['neutral'] ?? 0}`, '
        '`其他=${art.logoLanguageCounts['other'] ?? 0}`',
      );
      buf.writeln(
        '- **无字 1080p 背景图**：TMDB 欠佳触发 `${art.backdropSuboptimalCount}` 部 → '
        'Fanart 成功升级 `${art.backdropUpgradedByFanartCount}` 部',
      );
      buf.writeln(
        '- **封面救回与 Fanart 请求**：缺封面 `${art.posterNeedsFallbackCount}` → '
        'Fanart 救回 `${art.posterFilledByFanartCount}` ｜ 实际查 Fanart `${art.fanartQueriedCount}` 部',
      );
      buf.writeln(
        '- **TV `tvdbId` 供给健康度**（TV 共 `${art.tvWorksCount}` 部）：'
        '`tmdb_external_ids=${art.tvdbSourceCounts['tmdb_external_ids'] ?? 0}`, '
        '`offline_map_v2=${art.tvdbSourceCounts['offline_map_v2'] ?? 0}`, '
        '`missing=${art.tvdbSourceCounts['missing'] ?? 0}`',
      );
    }
    buf.writeln();

    // 基线对比 Diff：退化项 / 修复项 / 变动新项
    buf.writeln('## 三、与基线差异明细');
    buf.writeln();
    if (report.verdicts.isNotEmpty) {
      _writeGoldenDiffSection(buf, report.verdicts, baselineJson);
    } else {
      _writeParseDiffSection(buf, report.recordsByFolderKey, baselineJson);
    }

    // 根因聚类 Top 桶
    buf.writeln('## 四、失败与异常根因聚类');
    buf.writeln();
    if (report.rootCauseClusters.isEmpty) {
      buf.writeln('- 无失败或异常聚类项。');
    } else {
      final sortedCauses = report.rootCauseClusters.entries.toList()
        ..sort((a, b) => b.value.length.compareTo(a.value.length));
      for (final entry in sortedCauses) {
        buf.writeln(
          '- **`${entry.key}`（${entry.value.length} 项）**',
        );
        for (final sample in entry.value.take(5)) {
          buf.writeln('  - `$sample`');
        }
      }
    }
    return buf.toString();
  }

  static void _writeGoldenDiffSection(
    StringBuffer buf,
    List<CaseEvalVerdict> verdicts,
    Map<String, Object?>? baselineJson,
  ) {
    final prevVerdicts = baselineJson?['verdicts'] is Map
        ? (baselineJson!['verdicts'] as Map).cast<String, Object?>()
        : const <String, Object?>{};

    final regressions = <String>[];
    final fixes = <String>[];
    final changedOrNew = <String>[];

    for (final v in verdicts) {
      final prev = prevVerdicts[v.caseItem.caseId];
      if (prev is! Map) {
        if (!v.passed) {
          changedOrNew.add(
            '`${v.caseItem.caseId}` [${v.caseItem.physicalRoot}] 新项未过：${v.rootCause} (${v.detail})',
          );
        }
        continue;
      }
      final prevPassed = prev['passed'] == true;
      final prevTmdb = prev['actualTmdb']?.toString() ?? 'none';
      final curTmdb = v.record?.bestTmdbKey ?? 'none';
      if (prevPassed && !v.passed) {
        regressions.add(
          '`${v.caseItem.caseId}` [${v.caseItem.physicalRoot}] 原对现错：'
          '`$prevTmdb` → `$curTmdb` ｜ `${v.rootCause}`（${v.detail}）',
        );
      } else if (!prevPassed && v.passed) {
        fixes.add(
          '`${v.caseItem.caseId}` [${v.caseItem.physicalRoot}] 原错现对：'
          '`$prevTmdb` → `$curTmdb`',
        );
      } else if (prevTmdb != curTmdb ||
          prev['actualWall'] != v.record?.wallChannel ||
          prev['logoSource'] != v.record?.logoSource) {
        changedOrNew.add(
          '`${v.caseItem.caseId}` [${v.caseItem.physicalRoot}] 输出变动：'
          'tmdb `$prevTmdb`→`$curTmdb`, wall `${prev['actualWall']}`→`${v.record?.wallChannel}`, '
          'logo `${prev['logoSource']}`→`${v.record?.logoSource}`',
        );
      }
    }

    buf.writeln('### 🔴 退化项（原对现错：${regressions.length}）');
    if (regressions.isEmpty) {
      buf.writeln('- 无退化项。');
    } else {
      for (final line in regressions) {
        buf.writeln('- $line');
      }
    }
    buf.writeln();

    buf.writeln('### 🟢 修复项（原错现对：${fixes.length}）');
    if (fixes.isEmpty) {
      buf.writeln('- 无新增修复项。');
    } else {
      for (final line in fixes.take(30)) {
        buf.writeln('- $line');
      }
      if (fixes.length > 30) {
        buf.writeln('- （其余 ${fixes.length - 30} 项已省略，详见本次 `results.jsonl`）');
      }
    }
    buf.writeln();

    buf.writeln('### 🟡 结果变动 / 未标定新项（${changedOrNew.length}）');
    if (changedOrNew.isEmpty) {
      buf.writeln('- 无其余结果变动。');
    } else {
      for (final line in changedOrNew.take(20)) {
        buf.writeln('- $line');
      }
      if (changedOrNew.length > 20) {
        buf.writeln('- （其余 ${changedOrNew.length - 20} 项已省略）');
      }
    }
    buf.writeln();
  }

  static void _writeParseDiffSection(
    StringBuffer buf,
    Map<String, Map<String, Object?>> currentRecords,
    Map<String, Object?>? baselineJson,
  ) {
    final prevRecords = baselineJson?['records'] is Map
        ? (baselineJson!['records'] as Map).cast<String, Object?>()
        : const <String, Object?>{};
    if (prevRecords.isEmpty) {
      buf.writeln('- 当前尚无历史基线（确认结果后可执行 `-Mode AcceptBaseline` 锁定基线）。');
      buf.writeln();
      return;
    }

    final added = <String>[];
    final removed = <String>[];
    final changed = <String>[];

    for (final key in currentRecords.keys) {
      final cur = currentRecords[key]!;
      final prev = prevRecords[key];
      if (prev is! Map) {
        added.add('`$key` (title=`${cur['title']}`, main=${cur['mainCount']})');
        continue;
      }
      if (prev['title'] != cur['title'] ||
          prev['movie'] != cur['movie'] ||
          prev['season'] != cur['season'] ||
          prev['mainCount'] != cur['mainCount'] ||
          prev['leaks'] != cur['leaks']) {
        changed.add(
          '`$key`：title `${prev['title']}`→`${cur['title']}`, '
          'season `${prev['season']}`→`${cur['season']}`, '
          'main `${prev['mainCount']}`→`${cur['mainCount']}`, '
          'leaks `${prev['leaks']}`→`${cur['leaks']}`',
        );
      }
    }
    for (final key in prevRecords.keys) {
      if (!currentRecords.containsKey(key)) {
        removed.add('`$key`');
      }
    }

    buf.writeln(
      '- **离线解析差异汇总**：新增分组 `${added.length}` ｜ 消失分组 `${removed.length}` ｜ 解析字段变动 `${changed.length}`',
    );
    for (final line in changed.take(25)) {
      buf.writeln('  - 变动：$line');
    }
    for (final line in added.take(15)) {
      buf.writeln('  - 新增：$line');
    }
    for (final line in removed.take(15)) {
      buf.writeln('  - 消失：$line');
    }
    buf.writeln();
  }

  static int? _matchClusterForCase(
    GoldenCase caseItem,
    List<EvalClusterRecord> actualList,
    Set<int> usedIndices,
  ) {
    if (actualList.isEmpty) return null;
    final hint = caseItem.clusterHint.trim();
    if (hint.isEmpty || hint == '*') {
      for (var i = 0; i < actualList.length; i++) {
        if (!usedIndices.contains(i)) return i;
      }
      return null;
    }
    final pattern = RegExp(hint, caseSensitive: false);
    for (var i = 0; i < actualList.length; i++) {
      if (usedIndices.contains(i)) continue;
      final r = actualList[i];
      if (pattern.hasMatch(r.cleanTitle) ||
          pattern.hasMatch(r.folderKey) ||
          pattern.hasMatch(r.folderName)) {
        return i;
      }
    }
    return null;
  }

  static CaseEvalVerdict _scoreCase({
    required GoldenCase caseItem,
    required EvalClusterRecord? record,
    required EvalMode mode,
  }) {
    if (record == null) {
      return CaseEvalVerdict(
        caseItem: caseItem,
        passed: false,
        outcome: 'split_missed',
        rootCause: 'split_missed',
        detail: '目录未命中或混放合集漏拆（hint=${caseItem.clusterHint}）',
      );
    }

    final hasLeak =
        caseItem.forbiddenExtraLeak &&
        record.suspectedExtraLeakPaths.isNotEmpty;
    if (hasLeak) {
      return CaseEvalVerdict(
        caseItem: caseItem,
        passed: false,
        outcome: 'noise_fail',
        rootCause: 'extra_leaked_to_main',
        record: record,
        hasExtraLeak: true,
        detail: '疑似特典混入正片: ${record.suspectedExtraLeakPaths.first}',
      );
    }

    // 零网络解析模式仅考评结构、正片集数与非正片噪音过滤。
    if (mode == EvalMode.parseOnly) {
      final countOk =
          caseItem.expectedMainCount == null ||
          _effectiveMainCount(record) == caseItem.expectedMainCount;
      return CaseEvalVerdict(
        caseItem: caseItem,
        passed: countOk,
        outcome: countOk ? 'auto_right' : 'noise_fail',
        rootCause: countOk ? '' : 'main_count_mismatch',
        record: record,
        detail: countOk
            ? ''
            : '正片数期望 ${caseItem.expectedMainCount} 实际 ${_effectiveMainCount(record)}',
      );
    }

    // 0 正片纯特典防误上墙红线校验。
    if (caseItem.expectedWall == 'block' && record.wallChannel != 'block') {
      return CaseEvalVerdict(
        caseItem: caseItem,
        passed: false,
        outcome: 'wrong_bind',
        rootCause: 'false_wall_promotion',
        record: record,
        isWrongBind: true,
        isFalseWallPromotion: true,
        detail: '纯特典/噪音目录被误上墙(wall=${record.wallChannel})',
      );
    }

    // TMDB 匹配考评（支持 `none` 拒绝绑定与 `|` 可接受集合）。
    final acceptedTmdb = caseItem.acceptedTmdbKeys;
    final actualTmdb = record.bestTmdbKey?.toLowerCase();
    final isAutoBind = record.matchLevel == 'autoBind';
    final isReview = record.matchLevel == 'reviewRequired';

    if (acceptedTmdb.isNotEmpty) {
      final expectNoneOnly =
          acceptedTmdb.length == 1 && acceptedTmdb.contains('none');
      if (expectNoneOnly) {
        if (isAutoBind && actualTmdb != null) {
          return CaseEvalVerdict(
            caseItem: caseItem,
            passed: false,
            outcome: 'wrong_bind',
            rootCause: 'wrong_bind_work',
            record: record,
            isWrongBind: true,
            detail: '期望不绑定(none)，实际错绑 $actualTmdb',
          );
        }
      } else {
        final tmdbHit = actualTmdb != null && acceptedTmdb.contains(actualTmdb);
        if (!tmdbHit) {
          if (actualTmdb == null || (!isAutoBind && !isReview)) {
            final cause = record.networkError != null
                ? 'network_or_429'
                : (record.primaryReason == 'no_candidates'
                      ? 'no_candidates'
                      : 'unmatched_miss');
            return CaseEvalVerdict(
              caseItem: caseItem,
              passed: false,
              outcome: 'miss',
              rootCause: cause,
              record: record,
              detail: '期望 $acceptedTmdb，实际未命中(${record.primaryReason})',
            );
          }
          final wantTypes = {
            for (final k in acceptedTmdb)
              if (k.contains(':')) k.substring(0, k.indexOf(':')),
          };
          final gotType = actualTmdb.contains(':')
              ? actualTmdb.substring(0, actualTmdb.indexOf(':'))
              : '';
          final cause =
              (wantTypes.isNotEmpty && !wantTypes.contains(gotType))
              ? 'wrong_bind_type'
              : (isReview ? 'low_margin_ambiguous' : 'wrong_bind_work');
          return CaseEvalVerdict(
            caseItem: caseItem,
            passed: false,
            outcome: isAutoBind ? 'wrong_bind' : 'miss',
            rootCause: cause,
            record: record,
            isWrongBind: isAutoBind,
            detail: '期望 $acceptedTmdb，实际 ${record.matchLevel}:$actualTmdb',
          );
        }
        if (isReview) {
          return CaseEvalVerdict(
            caseItem: caseItem,
            passed: false,
            outcome: 'review_hit',
            rootCause: 'low_margin_ambiguous',
            record: record,
            detail: 'Top-1 命中 $actualTmdb 但落在待复核(${record.primaryReason})',
          );
        }
      }
    }

    // 季号考评（仅对填写了整数季号的条目严格校验）。
    var seasonChecked = false;
    var seasonRight = false;
    final wantSeasonInt = int.tryParse(caseItem.expectedSeason.trim());
    if (wantSeasonInt != null) {
      seasonChecked = true;
      seasonRight = record.matchedSeason == wantSeasonInt;
      if (!seasonRight) {
        return CaseEvalVerdict(
          caseItem: caseItem,
          passed: false,
          outcome: 'wrong_bind',
          rootCause: 'wrong_season',
          record: record,
          isWrongBind: true,
          seasonChecked: true,
          seasonRight: false,
          detail: 'TMDB 季号错误：期望 S$wantSeasonInt，实际 S${record.matchedSeason}',
        );
      }
    }

    // Bangumi 考评（无 TMDB 时作为主考评，有 TMDB 时作跨源辅考评）。
    final acceptedBgm = caseItem.acceptedBangumiKeys;
    if (acceptedBgm.isNotEmpty && acceptedTmdb.isEmpty) {
      final actualBgm = record.bestBangumiId?.toString();
      final expectNone = acceptedBgm.length == 1 && acceptedBgm.contains('none');
      if (expectNone && actualBgm != null && record.wallChannel != 'block') {
        return CaseEvalVerdict(
          caseItem: caseItem,
          passed: false,
          outcome: 'wrong_bind',
          rootCause: 'wrong_bind_work',
          record: record,
          isWrongBind: true,
          detail: '期望 Bangumi=none，实际命中 bgm:$actualBgm',
        );
      }
      if (!expectNone && (actualBgm == null || !acceptedBgm.contains(actualBgm))) {
        return CaseEvalVerdict(
          caseItem: caseItem,
          passed: false,
          outcome: actualBgm == null ? 'miss' : 'wrong_bind',
          rootCause: actualBgm == null ? 'unmatched_miss' : 'wrong_bind_work',
          record: record,
          isWrongBind: actualBgm != null,
          detail: '期望 Bangumi $acceptedBgm，实际 ${actualBgm ?? 'none'}',
        );
      }
    }

    // 上墙通道考评。
    final wantWall = caseItem.expectedWall.trim().toLowerCase();
    if (wantWall.isNotEmpty && record.wallChannel != wantWall) {
      return CaseEvalVerdict(
        caseItem: caseItem,
        passed: false,
        outcome: 'miss',
        rootCause: 'wrong_wall_channel',
        record: record,
        seasonChecked: seasonChecked,
        seasonRight: seasonRight,
        detail: '上墙通道期望 $wantWall，实际 ${record.wallChannel}',
      );
    }

    return CaseEvalVerdict(
      caseItem: caseItem,
      passed: true,
      outcome: acceptedTmdb.contains('none') ? 'correct_none' : 'auto_right',
      rootCause: '',
      record: record,
      seasonChecked: seasonChecked,
      seasonRight: seasonRight,
    );
  }

  static int _effectiveMainCount(EvalClusterRecord r) =>
      r.mainEpisodeNumbers.isNotEmpty
      ? r.mainEpisodeNumbers.toSet().length
      : r.mainVideoCount;

  static BucketScoreSummary _summarizeBucket(
    String bucket,
    List<CaseEvalVerdict> list,
  ) {
    var passed = 0;
    var autoRight = 0;
    var reviewHit = 0;
    var miss = 0;
    var wrongBind = 0;
    var leaks = 0;
    var falseWalls = 0;
    var seasonChecked = 0;
    var seasonRight = 0;

    for (final v in list) {
      if (v.passed) passed++;
      switch (v.outcome) {
        case 'auto_right' || 'correct_none':
          autoRight++;
        case 'review_hit':
          reviewHit++;
        case 'miss' || 'split_missed':
          miss++;
        case 'wrong_bind':
          wrongBind++;
      }
      if (v.hasExtraLeak) leaks++;
      if (v.isFalseWallPromotion) falseWalls++;
      if (v.seasonChecked) {
        seasonChecked++;
        if (v.seasonRight) seasonRight++;
      }
    }

    return BucketScoreSummary(
      bucket: bucket,
      total: list.length,
      passed: passed,
      autoRight: autoRight,
      reviewHit: reviewHit,
      miss: miss,
      wrongBind: wrongBind,
      extraLeaks: leaks,
      falseWallPromotions: falseWalls,
      seasonChecked: seasonChecked,
      seasonRight: seasonRight,
    );
  }

  static ArtworkAndWallSummary _summarizeArtworkAndWall(
    List<EvalClusterRecord> records,
  ) {
    final wallChannels = <String, int>{
      'tmdb': 0,
      'bgm_only': 0,
      'cover_fallback': 0,
      'block': 0,
    };
    final logoSources = <String, int>{'tmdb': 0, 'fanart': 0, 'none': 0};
    final logoLangs = <String, int>{
      'zh_cn': 0,
      'zh_tw': 0,
      'ja': 0,
      'en': 0,
      'neutral': 0,
      'other': 0,
      'none': 0,
    };
    final tvdbSources = <String, int>{
      'tmdb_external_ids': 0,
      'offline_map_v2': 0,
      'missing': 0,
    };

    var logoHit = 0;
    var logoUpgraded = 0;
    var bgSuboptimal = 0;
    var bgUpgraded = 0;
    var posterNeeds = 0;
    var posterFilled = 0;
    var tvWorks = 0;
    var fanartQueried = 0;

    for (final r in records) {
      wallChannels[r.wallChannel] = (wallChannels[r.wallChannel] ?? 0) + 1;
      logoSources[r.logoSource] = (logoSources[r.logoSource] ?? 0) + 1;
      logoLangs[r.logoLanguage] = (logoLangs[r.logoLanguage] ?? 0) + 1;
      if (r.logoSource != 'none') logoHit++;
      if (r.logoUpgradedByFanart) logoUpgraded++;
      if (r.backdropSuboptimal) bgSuboptimal++;
      if (r.backdropUpgradedByFanart) bgUpgraded++;
      if (r.posterNeedsFallback) posterNeeds++;
      if (r.posterFilledByFanart) posterFilled++;
      if (r.fanartQueried) fanartQueried++;
      if (r.bestTmdbKey != null && r.bestTmdbKey!.startsWith('tv:')) {
        tvWorks++;
        tvdbSources[r.tvdbIdSource] = (tvdbSources[r.tvdbIdSource] ?? 0) + 1;
      }
    }

    return ArtworkAndWallSummary(
      evaluatedWorks: records.length,
      wallChannels: wallChannels,
      logoSourceCounts: logoSources,
      logoLanguageCounts: logoLangs,
      logoHitCount: logoHit,
      logoUpgradedByFanartCount: logoUpgraded,
      backdropSuboptimalCount: bgSuboptimal,
      backdropUpgradedByFanartCount: bgUpgraded,
      posterNeedsFallbackCount: posterNeeds,
      posterFilledByFanartCount: posterFilled,
      tvWorksCount: tvWorks,
      tvdbSourceCounts: tvdbSources,
      fanartQueriedCount: fanartQueried,
    );
  }

  static double? _prevDouble(Object? raw, String field) {
    if (raw is! Map) return null;
    return (raw[field] as num?)?.toDouble();
  }

  static String _formatDelta(double delta) {
    final sign = delta > 0 ? '+' : '';
    return '$sign${delta.toStringAsFixed(1)}%';
  }

  static String _bucketDisplayLabel(String bucket) => switch (bucket) {
    'tv' => 'TV 正片',
    'mixed_movie' => '剧场版/混放拆分',
    'ova_sp' => 'OVA/OAD/SP 归属',
    'noise_extra' => 'BDrip 特典过滤',
    'pure_noise' => '纯特典防误上墙',
    'remake_multi' => '多季/重名重制',
    'ALL' => '**合计 (ALL)**',
    _ => bucket,
  };
}
