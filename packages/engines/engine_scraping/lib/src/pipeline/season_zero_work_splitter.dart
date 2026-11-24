import 'dart:developer' as developer;

import 'package:konata_contracts/konata_contracts.dart';

import '../matching/directory_grouper.dart';
import '../models/media_variant.dart';
import '../models/tmdb_models.dart';
import '../network/bangumi_service.dart';
import '../parsing/bdrip_parser.dart';
import '../scraping/bangumi_models.dart';
import '../scraping/bangumi_tmdb_index.dart';
import '../scraping/directory_analyzer.dart';
import 'scrape_work_persister.dart';

/// 单条由 Bangumi 独立条目驱动拆分出的 Season 0 单集特别篇作业切片。
class SeasonZeroSplitSlice {
  /// 创建单个拆作切片。
  const SeasonZeroSplitSlice({
    required this.ordinal,
    required this.workId,
    required this.folder,
    required this.bangumiCandidate,
  });

  /// 本地正片序号（从 1 起）。
  final int ordinal;

  /// 目标作品 ID（首个切片沿用主 workId，其余切片使用稳定确定性 ID）。
  final String workId;

  /// 仅含该单集正片及对应序号特典（如 `MenuEX1` / `MenuEX2`）的子目录包。
  final GroupedWorkFolder folder;

  /// 该独立单集特别篇对应的 Bangumi 条目候选。
  final ScoredBangumiCandidate bangumiCandidate;
}

/// Bangumi 驱动的 `Season 0` 多部独立单集特别篇自动拆作规划器。
///
/// 适用场景：
/// - 同一合集目录中打包了多部在 Bangumi 上各自拥有独立封面、评分、简介与单话条目的 OVA/EX
///   （如《加速世界》根目录中的 `[EX1]` 对应 `Stage:01 -银翼的觉醒-`、`[EX2]` 对应 `Stage:02 -加速的顶点-`）；
/// - 严格守住零误拆底线：仅当命中的 Bangumi 首条目明确为 **1 话**（`totalEpisodes == 1`）且能从
///   Bangumi 搜索候选、离线映射表同 `Season 0` 反查或 Bangumi 关联条目中定位到与本地集数一一对应的
///   同族独立 1 话条目时才拆作；真正的多话 OVA（如 2 话《创星的大天使》、3 话《秀逗魔导士 SPECIAL》、
///   5 话《我的女神 OVA》）因 `totalEpisodes >= 2` 绝不触发拆作。
abstract final class SeasonZeroWorkSplitter {
  static final RegExp _stageOrPartOrdinalPattern = RegExp(
    r'(?:stage|ex|ova|oad|vol(?:ume)?|part|alternative)[\s:：._\-]*0*(\d{1,2})(?![0-9])',
    caseSensitive: false,
  );
  static final RegExp _altWordOrdinalPattern = RegExp(
    r'\balternative[\s:：._\-]*(one|two|three|four)\b',
    caseSensitive: false,
  );
  static final RegExp _extraOrdinalPattern = RegExp(
    r'(?:menu[\s._\-]*ex|ex|ova|oad|vol(?:ume)?)[\s:：._\-]*0*(\d{1,2})(?![0-9])',
    caseSensitive: false,
  );
  static final RegExp _subtitleSplitPattern = RegExp(r'[\-—～~:：]');
  static const Set<String> _siblingRelations = {
    '续集',
    '續集',
    '前传',
    '前傳',
    '番外篇',
    '相同世界观',
    '衍生',
  };

  /// 尝试将当前绑定至 `Season 0` 的多文件特别篇目录拆分为若干独立单集作品切片。
  ///
  /// 不满足严格拆作条件时返回 `null`，由调用方按常规单作品流程处理。
  static Future<List<SeasonZeroSplitSlice>?> tryPlanSplit({
    required String sourceId,
    required String primaryWorkId,
    required GroupedWorkFolder folder,
    required TmdbWorkDetail detail,
    required int? matchedSeason,
    required ScoredBangumiCandidate? bangumiCandidate,
    required BangumiService? bangumiService,
    List<BangumiSubjectCandidate> knownBangumiCandidates = const [],
    BangumiTmdbIndex? mappingIndex,
    Map<int, List<BangumiRelatedSubject>>? relationCache,
    Map<int, String>? existingWorkIdByBangumiId,
    RequestPriority priority = RequestPriority.background,
  }) async {
    if (matchedSeason != 0 ||
        detail.mediaType != TmdbMediaType.tv ||
        bangumiCandidate == null ||
        bangumiService == null) {
      return null;
    }

    // 1. 提取主视频正片并按局部序号分桶；仅处理 2..4 集连续编号特别篇合集。
    final mainByOrdinal = <int, List<MediaVariant>>{};
    final extraEntries = <({MediaVariant variant, ParsedBdripRelease parsed, int? preEp})>[];
    final otherAssets = <MediaVariant>[];
    for (final v in folder.variants) {
      if (v.assetKind != AssetKind.video) {
        otherAssets.add(v);
        continue;
      }
      final preSlot = folder.slotAssignmentsByPath[v.relativePath];
      final parsed = BdripParser.parseFileName(
        v.fileName,
        relativePath: v.relativePath,
        folderTitle: folder.cleanTitle,
        folderSeasonHint: folder.seasonHint,
      );
      final category = preSlot?.category ?? parsed.category;
      if (category == EpisodeCategory.extra) {
        extraEntries.add((
          variant: v,
          parsed: parsed,
          preEp: preSlot?.episodeNumber,
        ));
        continue;
      }
      final epNum = preSlot?.episodeNumber ?? parsed.episode;
      if (epNum == null || epNum <= 0) {
        return null;
      }
      mainByOrdinal.putIfAbsent(epNum, () => <MediaVariant>[]).add(v);
    }

    final extraVariants = <MediaVariant>[];
    // 交互刷新从单作既有变体重建目录时，[EX1]/[EX2]/[OVA1]/[OVA2] 可能尚未被目录预升格为 main；
    // 当目录无常规正片时，仅将 SP/OVA 类有序正片升格分桶，保留 Menu/NCOP/NCED/PV 等附属特典。
    if (mainByOrdinal.isEmpty && extraEntries.isNotEmpty) {
      for (final entry in extraEntries) {
        final kind = entry.parsed.extraType;
        final epNum = entry.preEp ?? entry.parsed.episode;
        if ((kind == ExtraKind.sp || kind == ExtraKind.ova) &&
            epNum != null &&
            epNum > 0) {
          mainByOrdinal.putIfAbsent(epNum, () => <MediaVariant>[]).add(
            entry.variant,
          );
        } else {
          extraVariants.add(entry.variant);
        }
      }
    } else {
      for (final entry in extraEntries) {
        extraVariants.add(entry.variant);
      }
    }

    final ordinals = mainByOrdinal.keys.toList()..sort();
    if (ordinals.length < 2 || ordinals.length > 4) {
      return null;
    }
    for (var i = 0; i < ordinals.length; i++) {
      if (ordinals[i] != i + 1) return null;
    }
    final sliceCount = ordinals.length;

    // 2. 校验主 Bangumi 条目自身必须是 1 话独立条目（真正多话 OVA 如 2 话/3 话/5 话立即跳过）。
    var rootSubject = bangumiCandidate.subject;
    if (rootSubject.totalEpisodes == null ||
        (rootSubject.airDate?.trim().isEmpty ?? true) ||
        (rootSubject.posterUrl?.trim().isEmpty ?? true) ||
        (rootSubject.summary?.trim().isEmpty ?? true)) {
      try {
        rootSubject =
            await bangumiService.getSubjectDetail(
              rootSubject.id,
              priority: priority,
            ) ??
            rootSubject;
      } catch (error) {
        developer.log(
          '拆作前补拉主 Bangumi 详情失败，跳过独立特别篇拆作',
          name: 'konata.season_zero_work_splitter',
          error: error,
        );
      }
    }
    if (rootSubject.totalEpisodes != 1 || !_isEligibleStandaloneSpecial(rootSubject)) {
      return null;
    }

    // 3. 按优先级（Bangumi 关联 > 离线映射同 Season 0 反查 > 内存候选）汇集同系列候选 ID。
    final hydratedById = <int, BangumiSubjectCandidate>{
      rootSubject.id: rootSubject,
    };
    final directRelationIds = <int>{};
    final reverseIndexIds = <int>{};
    final knownCandidateIds = <int>{};

    List<BangumiRelatedSubject> relations;
    final cachedRelations = relationCache?[rootSubject.id];
    if (cachedRelations != null) {
      relations = cachedRelations;
    } else {
      try {
        relations = await bangumiService.getRelatedSubjects(
          rootSubject.id,
          priority: priority,
        );
        relationCache?[rootSubject.id] = relations;
      } catch (error) {
        developer.log(
          '查询 Bangumi 关联条目失败，继续利用其余来源评估 Season 0 拆作',
          name: 'konata.season_zero_work_splitter',
          error: error,
        );
        relations = const [];
      }
    }
    for (final rel in relations) {
      if (rel.id <= 0 || rel.id == rootSubject.id) continue;
      if (_siblingRelations.contains(rel.relation.trim())) {
        directRelationIds.add(rel.id);
      }
    }

    if (mappingIndex != null && mappingIndex.isNotEmpty) {
      final reverseMatches = mappingIndex.lookupBangumiIdsByTmdb(
        mediaType: TmdbMediaType.tv,
        tmdbId: detail.tmdbId,
        season: 0,
        strictSeason: true,
      );
      for (final m in reverseMatches) {
        if (m.bangumiId > 0 && m.bangumiId != rootSubject.id) {
          reverseIndexIds.add(m.bangumiId);
        }
      }
    }

    for (final c in knownBangumiCandidates) {
      if (c.id <= 0 || c.id == rootSubject.id) continue;
      if (c.totalEpisodes != null && c.totalEpisodes != 1) continue;
      if (c.totalEpisodes == 1) {
        hydratedById.putIfAbsent(c.id, () => c);
      }
      knownCandidateIds.add(c.id);
    }

    final prioritizedIds = <int>[
      ...directRelationIds,
      for (final id in reverseIndexIds)
        if (!directRelationIds.contains(id)) id,
      for (final id in knownCandidateIds)
        if (!directRelationIds.contains(id) && !reverseIndexIds.contains(id))
          id,
    ];

    var fetchedCount = 0;
    for (final id in prioritizedIds) {
      final existing = hydratedById[id];
      if (existing != null &&
          existing.totalEpisodes != null &&
          (existing.airDate?.trim().isNotEmpty ?? false) &&
          (existing.posterUrl?.trim().isNotEmpty ?? false)) {
        continue;
      }
      if (fetchedCount >= 6) break;
      fetchedCount++;
      try {
        final full = await bangumiService.getSubjectDetail(
          id,
          priority: priority,
        );
        if (full != null) {
          hydratedById[id] = full;
        }
      } catch (error) {
        developer.log(
          '补拉同系列 Bangumi 候选详情失败（id=$id）',
          name: 'konata.season_zero_work_splitter',
          error: error,
        );
      }
    }

    // 4. 筛选同族 1 话独立特别篇（共享子系列词干或同 Season 0 显式序数/直接续集关联，严防混入无关特别篇）。
    final rootStem = _extractSubSeriesStem(rootSubject);
    final rootOrdinal = _extractSubjectOrdinal(rootSubject);
    final familySubjects = <BangumiSubjectCandidate>[rootSubject];
    for (final subj in hydratedById.values) {
      if (subj.id == rootSubject.id) continue;
      if (subj.totalEpisodes != 1 || !_isEligibleStandaloneSpecial(subj)) {
        continue;
      }
      final subjStem = _extractSubSeriesStem(subj);
      final subjOrdinal = _extractSubjectOrdinal(subj);
      final sameSubSeries =
          rootStem.length >= 3 &&
          subjStem.length >= 3 &&
          (subjStem == rootStem ||
              subjStem.startsWith(rootStem) ||
              rootStem.startsWith(subjStem));
      final sharesFranchise = _sharesFranchisePrefix(rootSubject, subj);
      final distinctOrdinalPair =
          rootOrdinal != null &&
          subjOrdinal != null &&
          subjOrdinal != rootOrdinal;
      final ordinalPaired =
          distinctOrdinalPair &&
          (sameSubSeries ||
              (reverseIndexIds.contains(subj.id) && sharesFranchise));
      final directSequelPair =
          directRelationIds.contains(subj.id) && sharesFranchise;
      if (ordinalPaired ||
          (sameSubSeries &&
              (distinctOrdinalPair || directRelationIds.contains(subj.id))) ||
          directSequelPair) {
        familySubjects.add(subj);
      }
    }

    if (familySubjects.length < sliceCount) {
      return null;
    }

    // 5. 按显式序数与首播日期排序，并要求与本地 1..N 一一对应。
    familySubjects.sort((a, b) {
      final oa = _extractSubjectOrdinal(a) ?? 999;
      final ob = _extractSubjectOrdinal(b) ?? 999;
      if (oa != ob) return oa.compareTo(ob);
      final da = a.airDate?.trim() ?? '${a.year ?? 9999}-99-99';
      final db = b.airDate?.trim() ?? '${b.year ?? 9999}-99-99';
      final byDate = da.compareTo(db);
      return byDate != 0 ? byDate : a.id.compareTo(b.id);
    });

    final selected = <BangumiSubjectCandidate>[];
    final byOrdinal = <int, BangumiSubjectCandidate>{};
    for (final subj in familySubjects) {
      final ord = _extractSubjectOrdinal(subj);
      if (ord != null && ord >= 1 && ord <= sliceCount) {
        byOrdinal.putIfAbsent(ord, () => subj);
      }
    }
    if (byOrdinal.length == sliceCount) {
      for (var k = 1; k <= sliceCount; k++) {
        selected.add(byOrdinal[k]!);
      }
    } else if (familySubjects.length == sliceCount) {
      selected.addAll(familySubjects);
    } else {
      return null;
    }

    if (!selected.any((s) => s.id == rootSubject.id)) {
      return null;
    }

    // 6. 按序号分派特典（如 MenuEX1 -> 切片 1，MenuEX2 -> 切片 2），无序号特典归属切片 1。
    final extrasByOrdinal = <int, List<MediaVariant>>{
      for (var k = 1; k <= sliceCount; k++) k: <MediaVariant>[],
    };
    for (final extra in extraVariants) {
      final extraOrd = _extractExtraOrdinal(extra.fileName);
      if (extraOrd != null && extrasByOrdinal.containsKey(extraOrd)) {
        extrasByOrdinal[extraOrd]!.add(extra);
      } else {
        extrasByOrdinal[1]!.add(extra);
      }
    }

    final slices = <SeasonZeroSplitSlice>[];
    final reservedIds = <String>{
      if (existingWorkIdByBangumiId != null)
        ...existingWorkIdByBangumiId.values,
    };
    final usedSliceWorkIds = <String>{};
    for (var i = 0; i < sliceCount; i++) {
      final ord = i + 1;
      final subj = selected[i];
      final mains = mainByOrdinal[ord]!;
      final extras = extrasByOrdinal[ord]!;
      final sliceVariants = <MediaVariant>[
        ...mains,
        ...extras,
        if (i == 0) ...otherAssets,
      ];
      final sliceSlots = <String, EpisodeSlotAssignment>{
        for (final m in mains)
          m.relativePath: const EpisodeSlotAssignment(
            category: EpisodeCategory.main,
            seasonNumber: 0,
            episodeNumber: null,
          ),
        for (final ex in extras)
          if (folder.slotAssignmentsByPath[ex.relativePath] != null)
            ex.relativePath: folder.slotAssignmentsByPath[ex.relativePath]!,
      };
      final titleText = subj.displayTitle.trim().isNotEmpty
          ? subj.displayTitle.trim()
          : folder.cleanTitle;
      final sliceFolder = GroupedWorkFolder(
        folderRelativePath: '${folder.folderRelativePath}::s0_bgm_${subj.id}',
        folderName: titleText,
        cleanTitle: titleText,
        explicitTmdbId: detail.tmdbId,
        explicitMediaType: TmdbMediaType.tv,
        year: subj.year ?? folder.year,
        seasonHint: 0,
        mainEpisodeNumbers: const [],
        isMovieHint: false,
        variants: sliceVariants,
        slotAssignmentsByPath: sliceSlots,
        titleHints: [
          titleText,
          if (subj.name.trim().isNotEmpty) subj.name.trim(),
        ],
        physicalRootFolder:
            folder.physicalRootFolder ?? folder.folderRelativePath,
        localPosterPath: i == 0 ? folder.localPosterPath : null,
      );
      var sliceWorkId = existingWorkIdByBangumiId?[subj.id];
      if (sliceWorkId != null && usedSliceWorkIds.contains(sliceWorkId)) {
        sliceWorkId = null;
      }
      if (sliceWorkId == null &&
          i == 0 &&
          !reservedIds.contains(primaryWorkId) &&
          !usedSliceWorkIds.contains(primaryWorkId)) {
        sliceWorkId = primaryWorkId;
      }
      sliceWorkId ??= ScrapeWorkPersister.deterministicId(
        '$sourceId::s0split::${subj.id}::${mains.first.relativePath}',
      );
      usedSliceWorkIds.add(sliceWorkId);
      slices.add(
        SeasonZeroSplitSlice(
          ordinal: ord,
          workId: sliceWorkId,
          folder: sliceFolder,
          bangumiCandidate: ScoredBangumiCandidate(
            subject: subj,
            score: i == 0 ? bangumiCandidate.score : 95.0,
            reasons: i == 0
                ? bangumiCandidate.reasons
                : const ['season_zero_sibling_split'],
          ),
        ),
      );
    }
    return slices;
  }

  static bool _isEligibleStandaloneSpecial(BangumiSubjectCandidate subject) {
    final plat = (subject.platform?.trim() ?? '').toUpperCase();
    if (plat == '剧场版' || plat == 'MOVIE') return false;
    return true;
  }

  static int? _extractSubjectOrdinal(BangumiSubjectCandidate subject) {
    for (final raw in [subject.nameCn, subject.name, ...subject.aliases]) {
      final m = _stageOrPartOrdinalPattern.firstMatch(raw);
      if (m != null) return int.tryParse(m.group(1)!);
      final w = _altWordOrdinalPattern.firstMatch(raw);
      if (w != null) {
        return switch (w.group(1)!.toLowerCase()) {
          'one' => 1,
          'two' => 2,
          'three' => 3,
          'four' => 4,
          _ => null,
        };
      }
    }
    return null;
  }

  static String _extractSubSeriesStem(BangumiSubjectCandidate subject) {
    final raw = subject.displayTitle.trim();
    if (raw.isEmpty) return '';
    var cleaned = raw.replaceAll(_stageOrPartOrdinalPattern, ' ');
    cleaned = cleaned.replaceAll(_altWordOrdinalPattern, ' ');
    final subIdx = cleaned.indexOf(_subtitleSplitPattern);
    if (subIdx > 2) {
      cleaned = cleaned.substring(0, subIdx);
    }
    return DirectoryAnalyzer.normalize(cleaned);
  }

  static bool _sharesFranchisePrefix(
    BangumiSubjectCandidate a,
    BangumiSubjectCandidate b,
  ) {
    final na = DirectoryAnalyzer.normalize(a.displayTitle);
    final nb = DirectoryAnalyzer.normalize(b.displayTitle);
    if (na.length < 3 || nb.length < 3) return false;
    var common = 0;
    final limit = na.length < nb.length ? na.length : nb.length;
    while (common < limit && na.codeUnitAt(common) == nb.codeUnitAt(common)) {
      common++;
    }
    return common >= 3;
  }

  static int? _extractExtraOrdinal(String fileName) {
    final m = _extraOrdinalPattern.firstMatch(fileName);
    if (m == null) return null;
    return int.tryParse(m.group(1)!);
  }
}
