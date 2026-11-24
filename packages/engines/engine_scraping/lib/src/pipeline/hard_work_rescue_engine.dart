import '../matching/directory_grouper.dart';
import '../matching/work_matcher.dart';
import '../models/tmdb_models.dart';
import '../models/work.dart';
import '../scraping/bangumi_models.dart';
import '../scraping/bangumi_tmdb_index.dart';
import '../scraping/directory_analyzer.dart';
import '../scraping/match_difficulty_classifier.dart';
import '../scraping/scrape_domain_adapter.dart';
import '../scraping/title_normalizer.dart';
import '../scraping/work_matcher.dart' as legacy;
import 'scrape_candidate_fetcher.dart';
import 'scrape_compute_worker.dart';

/// 第二套困难目录专属救援引擎的尝试结果。
class HardRescueOutcome {
  /// 创建困难救援结果。
  const HardRescueOutcome({
    required this.adopted,
    required this.rescuedToAutoBind,
    required this.decision,
    required this.bangumiCandidates,
    required this.candidates,
    this.networkError,
  });

  /// 是否采纳了二轮救援产出（升格为自动绑定，或由未命中提升为高质量待复核）。
  final bool adopted;

  /// 是否成功由未命中/待复核升格为高置信自动绑定。
  final bool rescuedToAutoBind;

  /// 救援后的最终决策。
  final MatchDecision decision;

  /// 合并后的全量 Bangumi 候选。
  final List<BangumiSubjectCandidate> bangumiCandidates;

  /// 合并后的全量 TMDB 候选。
  final List<TmdbWorkDetail> candidates;

  /// 救援期间遇到的瞬时网络异常（若有）。
  final Object? networkError;
}

/// 困难目录第二套专属救援规则引擎（Pass 2）。
///
/// 仅在首轮常规匹配未能达成 [MatchLevel.autoBind] 时按需触发，常规首轮即命中的简单/中等目录
/// 零开销、零干预；内置四段专属策略与防误绑安全门禁：
/// 1. 深度剥离目录整理/编码/特别篇噪声（`SP00`、`10bit`、`Club`、`テレビアニメ`、`系列` 等）；
/// 2. 文件名主干接管（当目录名为整理简称/噪声且文件名主干更精准且非纯载体词时接管主标题）；
/// 3. 增量多语种/分段查询补搜与 Bangumi 离线映射定向补拉；
/// 4. 严格动画类型、有效评分数与原片名锚定验证门禁，杜绝同人/无条目资源错绑无关动画。
class HardWorkRescueEngine {
  /// 创建困难目录专属救援引擎。
  const HardWorkRescueEngine({
    required this._fetcher,
    this._mappingIndex,
  });

  final ScrapeCandidateFetcher _fetcher;
  final BangumiTmdbIndex? _mappingIndex;

  static final RegExp _cjkPattern = RegExp(r'[\u3040-\u9fff]');
  static final RegExp _wsPattern = RegExp(r'\s+');
  static final RegExp _subClausePattern = RegExp(r'[:：～~—/]|(?:\s+-\s+)');
  static final RegExp _leadingSepPattern = RegExp(r'^[\s\-–—:：_·・]+');
  static final RegExp _trailingSepPattern = RegExp(r'[\s\-–—:：_·・]+$');

  static final RegExp _pass2SpecialMarker = RegExp(
    r'(?<![a-z0-9])(?:sp\d+|ova\d*|oads?|oav\d*|tvsp|extra)(?![a-z0-9])',
    caseSensitive: false,
  );

  static final RegExp _tvAnimePrefixMarker = RegExp(
    r'(?:^|\s)(?:テレビアニメ|TVアニメ|电视动画)\s*',
    caseSensitive: false,
  );

  static final RegExp _organizerSuffixMarker = RegExp(
    r'(?:\s*(?:系列|作品集|合集|全集|特典集?)\s*$)|'
    r'(?:(?<![a-z0-9])(?:collection|selection|extra|club|edition|video|bonus|invitation)(?![a-z0-9]))',
    caseSensitive: false,
  );

  static final RegExp _pass2StripNoise = RegExp(
    r'(?<![a-z0-9])(?:sp\d+|10bit|8bit|hi10p|hevc|avc|x264|x265|club|extra|edition|'
    r'collection|selection|video|bonus|invitation|tvsp|ova\d*|oads?|oav\d*)(?![a-z0-9])|'
    r'(?:(?<!alternative\s)(?:bd|dvd)\s*)?(?<![a-z0-9])vol(?:ume)?\.?\s*0*\d{1,2}\s*$|'
    r'第\s*[0-9一二三四五六七八九十]+\s*[卷巻]\s*$|'
    r'テレビアニメ|TVアニメ|电视动画|ゲーム|系列$|作品集$|合集$',
    caseSensitive: false,
  );

  static final RegExp _genericCarrierOnly = RegExp(
    r'^(?:the\s+)?(?:movie|film|ova|oad|sp|special|extra|edition|collection|'
    r'selection|video|mv|live|club|part|vol|disc|disk|episode|ep|\d+|\s|[-_:])+$',
    caseSensitive: false,
  );

  /// 纯函数构造第二套规则用的深度净化虚拟目录（便于单元测试直接验证）。
  static ({
    GroupedWorkFolder folder,
    bool changed,
    List<String> anchorSeeds,
  })
  buildRescuedFolder(GroupedWorkFolder original) {
    final inv = original.inventory;
    final rawTitle = original.cleanTitle.trim();
    final hasTvAnimeTag = _tvAnimePrefixMarker.hasMatch(rawTitle);
    final hasSpecialTag =
        _pass2SpecialMarker.hasMatch(rawTitle) ||
        _pass2SpecialMarker.hasMatch(original.folderName);
    final hasOrganizerTag = _organizerSuffixMarker.hasMatch(rawTitle);

    final strippedTitle = _deepStripNoise(rawTitle);
    final effectiveFolderTitle = _isMeaningfulCore(strippedTitle)
        ? strippedTitle
        : rawTitle;

    final cleanedFiles = <String>[];
    final seenFileKeys = <String>{};
    for (final fh in original.fileHints) {
      final raw = fh.trim();
      if (raw.isEmpty || _isGenericCarrierOnly(raw)) continue;
      final stripped = _deepStripNoise(raw);
      final chosen = _isMeaningfulCore(stripped) ? stripped : raw;
      if (_isGenericCarrierOnly(chosen)) continue;
      final k = DirectoryAnalyzer.normalize(chosen);
      if (k.length >= 2 && seenFileKeys.add(k)) {
        cleanedFiles.add(chosen);
      }
      if (stripped != raw && _isMeaningfulCore(raw)) {
        final rk = DirectoryAnalyzer.normalize(raw);
        if (rk.length >= 2 && seenFileKeys.add(rk)) {
          cleanedFiles.add(raw);
        }
      }
    }

    final primaryFile = cleanedFiles.isEmpty ? null : cleanedFiles.first;
    final folderNorm = DirectoryAnalyzer.normalize(effectiveFolderTitle);
    final fileNorm = primaryFile == null
        ? ''
        : DirectoryAnalyzer.normalize(primaryFile);
    final folderHasCjk = _cjkPattern.hasMatch(effectiveFolderTitle);
    final fileHasCjk = primaryFile != null && _cjkPattern.hasMatch(primaryFile);
    final sameScriptLongerFile =
        folderHasCjk == fileHasCjk &&
        fileNorm.length >= folderNorm.length + 2 &&
        !folderNorm.contains(fileNorm);
    final fileIsMoreSpecific =
        primaryFile != null &&
        fileNorm.isNotEmpty &&
        fileNorm != folderNorm &&
        (hasOrganizerTag ||
            DirectoryAnalyzer.isGenericOrIrregularFolderName(
              original.folderName,
            ) ||
            sameScriptLongerFile);

    final primaryTitle = fileIsMoreSpecific
        ? primaryFile
        : effectiveFolderTitle;
    final newTitleHints = <String>[];
    final seenHints = <String>{};
    void addHint(String value) {
      final t = value.replaceAll(_wsPattern, ' ').trim();
      if (t.isEmpty || _isGenericCarrierOnly(t)) return;
      final k = DirectoryAnalyzer.normalize(t);
      if (k.length < 2 || !seenHints.add(k)) return;
      newTitleHints.add(t);
    }

    addHint(primaryTitle);
    addHint(effectiveFolderTitle);
    for (final cf in cleanedFiles.take(3)) {
      addHint(cf);
    }
    for (final h in original.titleHints) {
      final sh = _deepStripNoise(h);
      if (_isMeaningfulCore(sh)) addHint(sh);
    }

    final resolvedYear =
        (fileIsMoreSpecific && inv?.fileYear != null)
        ? inv!.fileYear
        : original.year;
    final dropFalseMovieHint =
        original.isMovieHint &&
        !(inv?.folderMovieMarker ?? false) &&
        !(inv?.fileMovieMarker ?? false) &&
        (hasSpecialTag || hasTvAnimeTag);
    final resolvedMovieHint = dropFalseMovieHint ? false : original.isMovieHint;
    final resolvedSeason =
        original.seasonHint ??
        ((hasSpecialTag && !resolvedMovieHint && original.mainEpisodeNumbers.length <= 4)
            ? 0
            : null);

    final changed =
        DirectoryAnalyzer.normalize(primaryTitle) !=
            DirectoryAnalyzer.normalize(rawTitle) ||
        resolvedMovieHint != original.isMovieHint ||
        resolvedSeason != original.seasonHint ||
        resolvedYear != original.year ||
        fileIsMoreSpecific;

    final rebuiltInv = inv == null
        ? null
        : DirectoryInventory.synthetic(
            folder: inv.folder,
            title: primaryTitle,
            year: resolvedYear,
            fileYear: inv.fileYear,
            tmdbId: inv.tmdbId,
            tmdbType: inv.tmdbType,
            bangumiId: inv.bangumiId,
            season: resolvedSeason,
            folderMovieMarker: dropFalseMovieHint
                ? false
                : inv.folderMovieMarker,
            fileMovieMarker: dropFalseMovieHint ? false : inv.fileMovieMarker,
            main: inv.main,
            extras: inv.extras,
            shape: inv.shape,
            titleHints: newTitleHints,
            fileHints: cleanedFiles.isNotEmpty ? cleanedFiles : inv.fileHints,
          );

    final rescuedFolder = GroupedWorkFolder(
      folderRelativePath: original.folderRelativePath,
      folderName: original.folderName,
      cleanTitle: primaryTitle,
      explicitTmdbId: original.explicitTmdbId,
      explicitMediaType: original.explicitMediaType,
      year: resolvedYear,
      seasonHint: resolvedSeason,
      mainEpisodeNumbers: original.mainEpisodeNumbers,
      isMovieHint: resolvedMovieHint,
      variants: original.variants,
      inventory: rebuiltInv,
      slotAssignmentsByPath: original.slotAssignmentsByPath,
      physicalRootFolder: original.physicalRootFolder,
      isSplitCluster: original.isSplitCluster,
      titleHints: List.unmodifiable(newTitleHints),
      fileHints: List.unmodifiable(
        cleanedFiles.isNotEmpty ? cleanedFiles : original.fileHints,
      ),
      extraSearchQueries: original.extraSearchQueries,
      parentTmdbId: original.parentTmdbId,
      parentTmdbType: original.parentTmdbType,
      allowParentTmdbCandidate: original.allowParentTmdbCandidate,
      ignoreExplicitTmdb: original.ignoreExplicitTmdb,
      assetScopesByPath: original.assetScopesByPath,
      localPosterPath: original.localPosterPath,
      matchDifficulty: MatchDifficulty.hard,
    );

    final anchorSeeds = <String>[
      ...newTitleHints,
      ...cleanedFiles,
    ];
    return (folder: rescuedFolder, changed: changed, anchorSeeds: anchorSeeds);
  }

  /// 对首轮未达成 [MatchLevel.autoBind] 的作品执行第二套困难目录专属救援。
  Future<HardRescueOutcome> rescue({
    required GroupedWorkFolder originalFolder,
    required MatchDecision pass1Decision,
    required List<BangumiSubjectCandidate> existingBangumi,
    required List<TmdbWorkDetail> existingTmdb,
    required ScrapeComputeWorker computeWorker,
    void Function(Object error)? onNetworkError,
  }) async {
    if (pass1Decision.level == MatchLevel.autoBind ||
        originalFolder.inventory?.shape == WorkShape.anthology) {
      return HardRescueOutcome(
        adopted: false,
        rescuedToAutoBind: false,
        decision: pass1Decision,
        bangumiCandidates: existingBangumi,
        candidates: existingTmdb,
      );
    }

    final built = buildRescuedFolder(originalFolder);
    final rescuedFolder = built.folder;
    final pass1Queries = ScrapeDomainAdapter.buildSearchQueries(originalFolder);
    final deepQueries = _collectNovelDeepQueries(
      rescuedFolder: rescuedFolder,
      pass1Queries: pass1Queries,
      allowSpeculativeSplit: existingTmdb.isEmpty,
      onlyCleanedCore: !built.changed && existingTmdb.isNotEmpty,
    );

    // 若既无深度净化变化又无全新补充查询词，直接快速返回，避免无意义重复打分与网络请求。
    if (!built.changed && deepQueries.isEmpty) {
      return HardRescueOutcome(
        adopted: false,
        rescuedToAutoBind: false,
        decision: pass1Decision,
        bangumiCandidates: existingBangumi,
        candidates: existingTmdb,
      );
    }

    Object? netErr;
    void recordError(Object err) {
      netErr ??= err;
    }

    var mergedBgm = existingBangumi;
    var mergedTmdb = existingTmdb;

    if (deepQueries.isNotEmpty) {
      final sup = await _fetcher.fetchHardRescueSupplements(
        rescuedFolder,
        newQueries: deepQueries,
        existingBangumi: existingBangumi,
        existingTmdb: existingTmdb,
        onNetworkError: (err) {
          recordError(err);
          onNetworkError?.call(err);
        },
      );
      if (sup.bangumiCandidates.isNotEmpty) {
        mergedBgm = <int, BangumiSubjectCandidate>{
          for (final b in existingBangumi) b.id: b,
          for (final b in sup.bangumiCandidates) b.id: b,
        }.values.toList(growable: false);
      }
      if (sup.tmdbDetails.isNotEmpty) {
        mergedTmdb = <String, TmdbWorkDetail>{
          for (final d in existingTmdb) '${d.mediaType.name}:${d.tmdbId}': d,
          for (final d in sup.tmdbDetails) '${d.mediaType.name}:${d.tmdbId}': d,
        }.values.toList(growable: false);
      }
    }

    // 跨源映射补拉：若深度净化后的 Bangumi 候选达到可信度并指向尚未入池的 TMDB 条目，直接按 ID 补拉。
    if (netErr == null && mergedBgm.isNotEmpty && _mappingIndex != null) {
      final bgmEval = await computeWorker.evaluateBangumiMatch(
        rescuedFolder,
        mergedBgm,
      );
      final bgmBest = bgmEval.best;
      final bgmTitleScore = bgmBest == null
          ? 0.0
          : bgmBest.reasons
                .where((r) => r.endsWith(' title'))
                .map((r) => double.tryParse(r.split(' ').first) ?? 0.0)
                .fold<double>(0.0, (m, v) => v > m ? v : m);
      final trustworthyBgm =
          bgmBest != null &&
          (bgmEval.tier == legacy.MatchTier.high ||
              (bgmEval.tier == legacy.MatchTier.medium &&
                  bgmTitleScore >= 34.0));
      if (trustworthyBgm) {
        final mapped = BangumiTmdbIndex.resolveTargets(
          bgmBest.subject.id,
          index: _mappingIndex,
        );
        final missing = <({TmdbMediaType type, int id})>[
          for (final t in mapped.take(2))
            if (!mergedTmdb.any(
              (c) => c.mediaType == t.type && c.tmdbId == t.id,
            ))
              (type: t.type, id: t.id),
        ];
        if (missing.isNotEmpty) {
          final extra = await _fetcher.fetchDetailsByIds(
            missing,
            includeImages: false,
            onNetworkError: (err) {
              recordError(err);
              onNetworkError?.call(err);
            },
          );
          if (extra.isNotEmpty) {
            mergedTmdb = <String, TmdbWorkDetail>{
              for (final d in mergedTmdb) '${d.mediaType.name}:${d.tmdbId}': d,
              for (final d in extra) '${d.mediaType.name}:${d.tmdbId}': d,
            }.values.toList(growable: false);
          }
        }
      }
    }

    final pass2Decision = await computeWorker.evaluateMatch(
      rescuedFolder,
      mergedTmdb,
      bangumiCandidates: mergedBgm,
      mappingIndex: _mappingIndex,
    );

    if (_isSafeRescuedAutoBind(
      originalFolder: originalFolder,
      rescuedDecision: pass2Decision,
      anchorSeeds: built.anchorSeeds,
    )) {
      return HardRescueOutcome(
        adopted: true,
        rescuedToAutoBind: true,
        decision: pass2Decision,
        bangumiCandidates: mergedBgm,
        candidates: mergedTmdb,
        networkError: netErr,
      );
    }

    // 未能安全升格自动绑定，但从无候选/未命中提升为有效动画待复核候选时，保留更优复核列表供一键确认。
    if (pass1Decision.level == MatchLevel.unmatched &&
        pass2Decision.level == MatchLevel.reviewRequired &&
        pass2Decision.best != null &&
        _passesAnchorGuard(pass2Decision.best!.detail, built.anchorSeeds)) {
      return HardRescueOutcome(
        adopted: true,
        rescuedToAutoBind: false,
        decision: pass2Decision,
        bangumiCandidates: mergedBgm,
        candidates: mergedTmdb,
        networkError: netErr,
      );
    }

    return HardRescueOutcome(
      adopted: false,
      rescuedToAutoBind: false,
      decision: pass1Decision,
      bangumiCandidates: mergedBgm,
      candidates: mergedTmdb,
      networkError: netErr,
    );
  }

  static List<String> _collectNovelDeepQueries({
    required GroupedWorkFolder rescuedFolder,
    required List<String> pass1Queries,
    required bool allowSpeculativeSplit,
    required bool onlyCleanedCore,
  }) {
    if (onlyCleanedCore) return const [];
    final seen = <String>{
      for (final q in pass1Queries) DirectoryAnalyzer.normalize(q),
    }..remove('');
    final out = <String>[];
    void tryAdd(String raw) {
      final clean = raw.replaceAll(_wsPattern, ' ').trim();
      if (!_isMeaningfulCore(clean) || _isGenericCarrierOnly(clean)) return;
      final key = DirectoryAnalyzer.normalize(clean);
      if (key.length < 2 || !seen.add(key)) return;
      out.add(clean);
    }

    tryAdd(rescuedFolder.cleanTitle);
    for (final q in ScrapeDomainAdapter.buildSearchQueries(rescuedFolder).take(3)) {
      tryAdd(q);
    }
    if (!allowSpeculativeSplit) {
      return out;
    }
    for (final seed in [
      rescuedFolder.cleanTitle,
      ...rescuedFolder.fileHints.take(2),
    ]) {
      final parts = seed
          .split(_subClausePattern)
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty);
      for (final part in parts) {
        tryAdd(part);
      }
      final tokens = seed
          .split(_wsPattern)
          .where((t) => t.isNotEmpty)
          .toList(growable: false);
      if (tokens.length >= 3 && !_cjkPattern.hasMatch(seed)) {
        tryAdd(tokens.skip(1).join(' '));
        tryAdd(tokens.take(tokens.length - 1).join(' '));
      }
    }
    return out;
  }

  bool _isSafeRescuedAutoBind({
    required GroupedWorkFolder originalFolder,
    required MatchDecision rescuedDecision,
    required List<String> anchorSeeds,
  }) {
    if (rescuedDecision.level != MatchLevel.autoBind) return false;
    final best = rescuedDecision.best;
    if (best == null) {
      // 仅 Bangumi 自动绑定场景：要求 Bangumi 本身具备强锚定。
      final bgm = rescuedDecision.bestBangumi;
      if (bgm == null) return false;
      final bgmNames = [bgm.subject.name, bgm.subject.nameCn, ...bgm.subject.aliases];
      return _matchesAnyName(bgmNames, anchorSeeds);
    }
    final detail = best.detail;
    // 原标题显式标注电视动画（`テレビアニメ`/`TVアニメ`）或特别篇（`SP\d+`/`OVA`/`OAD`/`Extra`）且无剧场版标记时，
    // 禁止二轮救援将其误绑到同名剧场版条目。
    final inv = originalFolder.inventory;
    final noMovieMarker =
        !(inv?.folderMovieMarker ?? false) && !(inv?.fileMovieMarker ?? false);
    if (detail.mediaType == TmdbMediaType.movie &&
        noMovieMarker &&
        (_tvAnimePrefixMarker.hasMatch(originalFolder.cleanTitle) ||
            _pass2SpecialMarker.hasMatch(originalFolder.cleanTitle) ||
            _pass2SpecialMarker.hasMatch(originalFolder.folderName))) {
      return false;
    }
    if (detail.genreIds.isNotEmpty && !detail.genreIds.contains(16)) {
      return false;
    }
    if ((detail.voteCount ?? 1) <= 0) {
      return false;
    }
    if (_passesAnchorGuard(detail, anchorSeeds)) {
      return true;
    }
    // 若存在已验证的 Bangumi 离线映射精准指向该 TMDB 条目，亦视作安全跨源锚定。
    final bgm = rescuedDecision.bestBangumi;
    if (bgm != null && _mappingIndex != null) {
      final mapped = BangumiTmdbIndex.resolveTargets(
        bgm.subject.id,
        index: _mappingIndex,
      );
      final targetKey = '${detail.mediaType.name}:${detail.tmdbId}';
      if (mapped.any((t) => t.key == targetKey)) {
        final bgmNames = [
          bgm.subject.name,
          bgm.subject.nameCn,
          ...bgm.subject.aliases,
        ];
        if (_matchesAnyName(bgmNames, anchorSeeds)) {
          return true;
        }
      }
    }
    return false;
  }

  static bool _passesAnchorGuard(
    TmdbWorkDetail detail,
    List<String> anchorSeeds,
  ) {
    final candNames = <String>[
      detail.title,
      if (detail.originalTitle != null) detail.originalTitle!,
      ...detail.aliases,
      for (final s in detail.seasons)
        if (s.name.trim().isNotEmpty) s.name.trim(),
    ];
    return _matchesAnyName(candNames, anchorSeeds);
  }

  static bool _matchesAnyName(List<String> candNames, List<String> seeds) {
    final candNorms = [
      for (final n in candNames)
        if (DirectoryAnalyzer.normalize(n).length >= 2)
          DirectoryAnalyzer.normalize(n),
    ];
    for (final rawSeed in seeds) {
      if (!_isMeaningfulCore(rawSeed) || _isGenericCarrierOnly(rawSeed)) {
        continue;
      }
      final sNorm = DirectoryAnalyzer.normalize(rawSeed);
      if (sNorm.length < 2) continue;
      for (final cn in candNorms) {
        if (legacy.WorkMatcher.similarity(sNorm, cn) >= 0.72) {
          return true;
        }
      }
      if (!_cjkPattern.hasMatch(rawSeed)) {
        for (final rawCand in candNames) {
          if (TitleNormalizer.romajiKanaSimilarity(rawSeed, rawCand) >= 0.72) {
            return true;
          }
        }
      }
    }
    return false;
  }

  static String _deepStripNoise(String raw) {
    var out = raw
        .replaceAll(_tvAnimePrefixMarker, ' ')
        .replaceAll(_pass2StripNoise, ' ')
        .replaceAll(_wsPattern, ' ')
        .trim();
    out = out
        .replaceFirst(_leadingSepPattern, '')
        .replaceFirst(_trailingSepPattern, '')
        .trim();
    return out;
  }

  static bool _isMeaningfulCore(String raw) {
    final norm = DirectoryAnalyzer.normalize(raw);
    if (norm.isEmpty) return false;
    final cjkCount = _cjkPattern.allMatches(norm).length;
    if (cjkCount >= 2) return true;
    return norm.length >= 4;
  }

  static bool _isGenericCarrierOnly(String raw) =>
      _genericCarrierOnly.hasMatch(raw.trim());
}
