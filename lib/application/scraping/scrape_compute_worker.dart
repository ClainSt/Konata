import 'dart:isolate';

import '../../domain/matching/directory_grouper.dart';
import '../../domain/matching/work_matcher.dart';
import '../../domain/models/tmdb_models.dart';
import '../../domain/scraping/bangumi_models.dart';
import '../../domain/scraping/scrape_domain_adapter.dart';
import '../../domain/scraping/work_matcher.dart' as legacy;

/// 后台 Isolate 纯计算工作器。
///
/// 将耗时较大的目录聚合、合集拆簇、BDRip 词法解析与候选打分放入独立 Isolate 执行，避免阻塞 UI 线程。
class ScrapeComputeWorker {
  /// 创建计算工作器实例。
  const ScrapeComputeWorker({this.useIsolate = true});

  /// 是否启用独立 Isolate 执行；单元测试中也可按需切换。
  final bool useIsolate;

  /// 在后台 Isolate 中执行目录抗碎裂归拢、多作品合集拆簇与槽位预解析。
  Future<List<GroupedWorkFolder>> groupFiles({
    required String sourceId,
    required List<ScannedFileInput> files,
    Map<String, String> nfoByFolder = const {},
  }) {
    if (!useIsolate) {
      return Future.value(
        ScrapeDomainAdapter.groupAndSplitFiles(
          sourceId: sourceId,
          files: files,
          nfoByFolder: nfoByFolder,
        ),
      );
    }
    return Isolate.run(
      () => ScrapeDomainAdapter.groupAndSplitFiles(
        sourceId: sourceId,
        files: files,
        nfoByFolder: nfoByFolder,
      ),
    );
  }

  /// 在后台 Isolate 中执行 Bangumi 候选多维打分。
  Future<({
    legacy.MatchTier tier,
    ScoredBangumiCandidate? best,
    List<ScoredBangumiCandidate> topCandidates,
  })>
  evaluateBangumiMatch(
    GroupedWorkFolder folder,
    List<BangumiSubjectCandidate> candidates,
  ) async {
    if (!useIsolate) {
      final res = ScrapeDomainAdapter.evaluateBangumiMatch(folder, candidates);
      return (
        tier: res.tier,
        best: res.best,
        topCandidates: res.topCandidates,
      );
    }
    return Isolate.run(() {
      final res = ScrapeDomainAdapter.evaluateBangumiMatch(folder, candidates);
      return (
        tier: res.tier,
        best: res.best,
        topCandidates: res.topCandidates,
      );
    });
  }

  /// 在后台 Isolate 中执行作品候选多维打分、季级身份消歧与漏斗决策（含 Bangumi 联合互证）。
  Future<MatchDecision> evaluateMatch(
    GroupedWorkFolder folder,
    List<TmdbWorkDetail> candidates, {
    List<BangumiSubjectCandidate> bangumiCandidates = const [],
  }) {
    if (!useIsolate) {
      return Future.value(
        ScrapeDomainAdapter.evaluateMatch(
          folder,
          candidates,
          bangumiCandidates: bangumiCandidates,
        ),
      );
    }
    return Isolate.run(
      () => ScrapeDomainAdapter.evaluateMatch(
        folder,
        candidates,
        bangumiCandidates: bangumiCandidates,
      ),
    );
  }
}
