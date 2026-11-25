import '../models/media_variant.dart';
import '../models/tmdb_models.dart';
import '../models/work.dart';
import '../parsing/bdrip_parser.dart';
import '../parsing/title_normalizer.dart';
import '../scraping/bangumi_models.dart';
import '../scraping/directory_analyzer.dart';
import 'directory_grouper.dart';

/// 绑定至 TMDB `Season 0`（特别篇季）的独立作品正片与 `Season 0` 分集列表的语义对齐器（纯函数，零 IO）。
///
/// 适用场景：
/// - TMDB 将同一系列全部特别篇/OVA 扁平收纳在 `Season 0`（如《少女福尔摩斯》`S00E02 Alternative ONE`、
///   `S00E03 Alternative TWO`、《加速世界》小剧场与 `EX1/EX2` 混排、《高达 W 无尽的华尔兹》`S00E05..E07`），
///   独立作品的本地集号 `01`/`02` 或无集号单文件绝不能盲按 `1:1` 错绑，必须综合播出日期、专属词干、
///   单调集序、高频迷你短片前缀隔离与连续块锚点偏移进行精准定位。
abstract final class SeasonZeroMainMatcher {
  static final RegExp _bracketPattern = RegExp(r'\[[^\]]*\]|\([^)]*\)|【[^】]*】');
  static final RegExp _extPattern = RegExp(r'\.[^.]+$');
  static final RegExp _tokenSplit = RegExp(
    r'[\s._\-!?！？:：()\[\]【】/\\+~～・·,，。、「」『』]+',
  );
  static final RegExp _cjkRun = RegExp(r'[\u4e00-\u9fff\u3040-\u30ff]+');
  static final RegExp _altOnePattern = RegExp(
    r'\balternative[\s._\-]*(?:one|0*1)(?![0-9a-z])',
    caseSensitive: false,
  );
  static final RegExp _altTwoPattern = RegExp(
    r'\balternative[\s._\-]*(?:two|0*2)(?![0-9a-z])',
    caseSensitive: false,
  );
  static final RegExp _ovaNumPattern = RegExp(
    r'(?<![a-z0-9])(?:ova|oad|sp|ex)[\s._\-]*0*(\d{1,2})(?![0-9])',
    caseSensitive: false,
  );
  static final RegExp _trailingIndexPattern = RegExp(
    r'(?:[\s._\-:#＃第]+0*\d{1,3}(?:\s*[话話集回巻卷])?|\s+\d{1,2})\s*$',
    caseSensitive: false,
  );
  static const Set<String> _noiseTokens = {
    'bdrip',
    'dvdrip',
    'webrip',
    '1080p',
    '720p',
    '2160p',
    '4k',
    'x264',
    'x265',
    'hevc',
    'avc',
    'flac',
    'aac',
    'ac3',
    'dts',
    '10bit',
    '8bit',
    'ma10p',
    'hi10p',
    'mkv',
    'mp4',
    'avi',
    'the',
    'and',
    'for',
    'with',
    'from',
    'no',
    'to',
    'of',
  };

  /// 为 `work.matchedSeason == 0` 作品的正片视频文件在 [seasonZeroEpisodes] 中查找最佳唯一匹配。
  ///
  /// 返回 `variant.relativePath -> TmdbEpisodeDetail` 映射；缺乏正向语义证据时不强绑，
  /// 彻底避免因年份或集号巧合误贴同系列无关小剧场或短片。
  static Map<String, TmdbEpisodeDetail> match({
    required Work work,
    required GroupedWorkFolder folder,
    required List<MediaVariant> mainVariants,
    required List<TmdbEpisodeDetail> seasonZeroEpisodes,
    List<BangumiEpisodeEntry> bangumiEpisodes = const [],
  }) {
    if (work.matchedSeason != 0 ||
        mainVariants.isEmpty ||
        seasonZeroEpisodes.isEmpty) {
      return const {};
    }

    // 优先使用 Bangumi 正片分集（type == 0）；部分电视特别篇在 Bangumi 仅登记为 SP（type == 1）时允许回退。
    var bgmMain = bangumiEpisodes.where((e) => e.type == 0).toList();
    if (bgmMain.isEmpty) {
      bgmMain = bangumiEpisodes.where((e) => e.type == 1).toList();
    }
    bgmMain.sort((a, b) {
      final sa = a.ep ?? a.sort ?? 9999;
      final sb = b.ep ?? b.sort ?? 9999;
      return sa.compareTo(sb);
    });
    final bgmByEp = <int, BangumiEpisodeEntry>{};
    for (final e in bgmMain) {
      final n = (e.ep ?? e.sort)?.round();
      if (n != null && n > 0) bgmByEp.putIfAbsent(n, () => e);
    }

    final s0ByEp = <int, TmdbEpisodeDetail>{
      for (final s0 in seasonZeroEpisodes) s0.episodeNumber: s0,
    };
    final s0CountByYear = <int, int>{};
    final s0Dates = <int, DateTime?>{};
    final s0TokensByEp = <int, Set<String>>{};
    final tokenDocFreq = <String, int>{};
    final seriesPrefixCount = <String, int>{};
    final s0SeriesPrefix = <int, String>{};
    for (final s0 in seasonZeroEpisodes) {
      final d = _parseAirDate(s0.airDate);
      s0Dates[s0.episodeNumber] = d;
      if (d != null) {
        s0CountByYear.update(d.year, (v) => v + 1, ifAbsent: () => 1);
      }
      final toks = _extractTokens(s0.title);
      s0TokensByEp[s0.episodeNumber] = toks;
      for (final t in toks) {
        tokenDocFreq.update(t, (v) => v + 1, ifAbsent: () => 1);
      }
      final prefixKey = _extractRepeatedPrefixKey(s0.title);
      if (prefixKey.length >= 2) {
        s0SeriesPrefix[s0.episodeNumber] = prefixKey;
        seriesPrefixCount.update(prefixKey, (v) => v + 1, ifAbsent: () => 1);
      }
    }

    // 识别 Season 0 内高频重复出现的子短片系列前缀（同前缀 >= 3 集，如 `小加速世界 1..8`），用于防跨族误吸。
    final repeatedPrefixClusters = <String>{
      for (final entry in seriesPrefixCount.entries)
        if (entry.value >= 3) entry.key,
    };

    // 过滤在绝大多数 Season 0 标题中都出现的通用系列母名词，突出真正区分各特别篇的专属词。
    final commonThreshold = seasonZeroEpisodes.length >= 3
        ? (seasonZeroEpisodes.length * 0.6).ceil()
        : seasonZeroEpisodes.length + 1;

    final buckets =
        <
          String,
          ({
            int? localEp,
            int? rawFileEp,
            String cleanStem,
            List<MediaVariant> variants,
          })
        >{};
    for (final v in mainVariants) {
      final preSlot = folder.slotAssignmentsByPath[v.relativePath];
      final parsed = BdripParser.parseFileName(
        v.fileName,
        relativePath: v.relativePath,
        folderTitle: folder.cleanTitle,
        folderSeasonHint: folder.seasonHint,
      );
      final localEp = preSlot?.episodeNumber ?? parsed.episode;
      final rawFileEp = parsed.episode;
      final cleanStem = _cleanFileStem(v.fileName);
      final normStem = DirectoryAnalyzer.normalize(cleanStem);
      final bucketKey = localEp != null
          ? 'ep:$localEp'
          : (normStem.isNotEmpty ? 'stem:$normStem' : 'path:${v.relativePath}');
      final bucket = buckets.putIfAbsent(
        bucketKey,
        () => (
          localEp: localEp,
          rawFileEp: rawFileEp,
          cleanStem: cleanStem,
          variants: <MediaVariant>[],
        ),
      );
      bucket.variants.add(v);
    }
    final orderedBuckets = buckets.values.toList()
      ..sort((a, b) {
        final ea = a.localEp ?? 999999;
        final eb = b.localEp ?? 999999;
        if (ea != eb) return ea.compareTo(eb);
        return a.variants.first.relativePath.compareTo(
          b.variants.first.relativePath,
        );
      });

    final singleMain = orderedBuckets.length == 1;
    final mixedSeasonZero = seasonZeroEpisodes.length > orderedBuckets.length;
    final claimed = <int>{};
    final result = <String, TmdbEpisodeDetail>{};
    final matchedByBucketIndex = <int, ({TmdbEpisodeDetail ep, double score})>{};

    // 阶段 1：逐集语义打分（严格要求混排 Season 0 具备正向语义证据，并维持多集单调递增序）。
    int? highestNumberedS0Claimed;
    for (var idx = 0; idx < orderedBuckets.length; idx++) {
      final bucket = orderedBuckets[idx];
      final localEp = bucket.localEp;
      final bgmEp = singleMain && bgmMain.length == 1
          ? bgmMain.single
          : (localEp != null ? bgmByEp[localEp] : null);
      final bgmDate = _parseAirDate(bgmEp?.airDate);
      final targetYear = bgmDate?.year ?? work.year ?? folder.year;

      final cleanFileStem = bucket.cleanStem;
      final localTexts = <String>[
        for (final item in bucket.variants) ...[
          _cleanFileStem(item.fileName),
          item.fileName,
        ],
        if (singleMain) ...[
          work.title,
          if (work.originalTitle != null) work.originalTitle!,
          folder.cleanTitle,
          ...folder.titleHints,
        ],
        if (bgmEp != null) ...[bgmEp.nameCn, bgmEp.name],
      ].map((s) => s.trim()).where((s) => s.isNotEmpty).toList(growable: false);

      final combinedLocal = localTexts.join(' ');
      final wantsAltOne = _altOnePattern.hasMatch(combinedLocal);
      final wantsAltTwo = _altTwoPattern.hasMatch(combinedLocal);
      final localOvaNum = _extractOvaOrdinal(cleanFileStem);
      final localTokens = <String>{
        for (final text in localTexts) ..._extractTokens(text),
      };
      final combinedLocalNorm = DirectoryAnalyzer.normalize(combinedLocal);

      TmdbEpisodeDetail? best;
      var bestScore = double.negativeInfinity;
      var bestSemantic = 0.0;
      var secondScore = double.negativeInfinity;

      for (final s0 in seasonZeroEpisodes) {
        if (claimed.contains(s0.episodeNumber)) continue;
        // 多集有序正片禁止后集倒挂到比前集更靠前的 Season 0 槽位（如 EX1->S0E3 时禁止 EX2->S0E2）。
        if (!singleMain &&
            localEp != null &&
            highestNumberedS0Claimed != null &&
            s0.episodeNumber < highestNumberedS0Claimed) {
          continue;
        }

        var semanticScore = 0.0;
        var auxScore = 0.0;
        final s0Date = s0Dates[s0.episodeNumber];
        final s0Title = s0.title.trim();

        // 1. 精准播出日期与年份维度（跨语种译名完全不同时最具区分力，如 派对之夜 vs 有趣的珍珠之夜）。
        if (bgmDate != null && s0Date != null) {
          final diffDays = bgmDate.difference(s0Date).inDays.abs();
          if (diffDays <= 3) {
            semanticScore += 65;
          } else if (diffDays <= 14) {
            semanticScore += 45;
          } else if (diffDays <= 45) {
            semanticScore += 20;
          } else if ((bgmDate.year - s0Date.year).abs() >= 2) {
            auxScore -= 30;
          } else {
            auxScore -= 15;
          }
        } else if (targetYear != null && s0Date != null) {
          final diffYears = (s0Date.year - targetYear).abs();
          if (diffYears == 0) {
            auxScore += 18;
            if ((s0CountByYear[targetYear] ?? 0) == 1) {
              // 该年份整个 Season 0 仅播出此唯一特别篇，本身构成强日期唯一性证据。
              semanticScore += 20;
            }
          } else if (diffYears == 1) {
            auxScore += 4;
          } else {
            auxScore -= 25;
          }
        }

        // 2. Alternative ONE / TWO 强序数护栏。
        final s0IsAltOne = _altOnePattern.hasMatch(s0Title);
        final s0IsAltTwo = _altTwoPattern.hasMatch(s0Title);
        if (wantsAltOne && !wantsAltTwo) {
          if (s0IsAltOne) semanticScore += 55;
          if (s0IsAltTwo) semanticScore -= 45;
        } else if (wantsAltTwo && !wantsAltOne) {
          if (s0IsAltTwo) semanticScore += 55;
          if (s0IsAltOne) semanticScore -= 45;
        }

        // 3. 显式 OVA / EX 序号匹配。
        final s0OvaNum = _extractOvaOrdinal(s0Title);
        if (localOvaNum != null && s0OvaNum != null) {
          if (localOvaNum == s0OvaNum) {
            semanticScore += 22;
          } else {
            semanticScore -= 18;
          }
        }

        // 4. 专属词干重叠与假名罗马音相似度。
        final s0Tokens = s0TokensByEp[s0.episodeNumber] ?? const <String>{};
        final distinctiveS0 = s0Tokens
            .where((t) => (tokenDocFreq[t] ?? 0) < commonThreshold)
            .toSet();
        if (distinctiveS0.isNotEmpty) {
          var hits = 0;
          for (final tok in distinctiveS0) {
            if (localTokens.contains(tok)) {
              hits++;
            }
          }
          if (hits > 0) {
            final coverage = hits / distinctiveS0.length;
            semanticScore += 18 + coverage * 32;
          }
        }

        var bestPhonetic = 0.0;
        final s0Norm = DirectoryAnalyzer.normalize(s0Title);
        if (s0Norm.length >= 2) {
          for (final lt in localTexts) {
            final ln = DirectoryAnalyzer.normalize(lt);
            if (ln.length >= 4 &&
                (ln.contains(s0Norm) || s0Norm.contains(ln))) {
              if (bestPhonetic < 0.85) bestPhonetic = 0.85;
            }
            final sim = TitleNormalizer.matchingRomajiKanaSimilarity(lt, s0Title);
            if (sim > bestPhonetic) bestPhonetic = sim;
          }
        }
        if (bestPhonetic >= 0.55) {
          semanticScore += bestPhonetic * 35;
        }

        // 5. 隔离高频迷你短片族：当候选属于 Season 0 中重复 >= 3 次的子系列前缀（如 `小加速世界`），
        // 且本地名称未出现该前缀时，禁止仅靠年份或序号巧合误吸。
        final s0Prefix = s0SeriesPrefix[s0.episodeNumber];
        final isForeignMiniCluster =
            s0Prefix != null &&
            repeatedPrefixClusters.contains(s0Prefix) &&
            !combinedLocalNorm.contains(s0Prefix);
        if (isForeignMiniCluster && semanticScore < 30) {
          continue;
        }

        // 6. 多集 OVA 在年份兼容时的局部序号温和加权（仅作为平分或有语义佐证时的辅助，不可独立成绑）。
        if (!singleMain && localEp != null && s0.episodeNumber == localEp) {
          final yearFar =
              targetYear != null &&
              s0Date != null &&
              (s0Date.year - targetYear).abs() >= 2;
          if (!yearFar) {
            auxScore += 14;
          }
        }

        final score = semanticScore + auxScore;
        if (score > bestScore) {
          secondScore = bestScore;
          bestScore = score;
          bestSemantic = semanticScore;
          best = s0;
        } else if (score > secondScore) {
          secondScore = score;
        }
      }

      if (best == null) continue;
      // 混排 Season 0 严禁零语义证据强绑（杜绝同年份 + 集号巧合错贴小剧场）。
      if (mixedSeasonZero && bestSemantic <= 0) continue;

      final minAccept = singleMain ? 30.0 : (mixedSeasonZero ? 22.0 : 14.0);
      final clearMargin =
          secondScore == double.negativeInfinity ||
          bestScore - secondScore >= 6.0 ||
          bestScore >= 55.0;
      if (bestScore >= minAccept && clearMargin) {
        claimed.add(best.episodeNumber);
        matchedByBucketIndex[idx] = (ep: best, score: bestScore);
        if (localEp != null &&
            (highestNumberedS0Claimed == null ||
                best.episodeNumber > highestNumberedS0Claimed)) {
          highestNumberedS0Claimed = best.episodeNumber;
        }
        for (final item in bucket.variants) {
          result[item.relativePath] = best;
        }
      }
    }

    // 阶段 2A：多集连续 OVA 锚点偏移传播（例如《无尽的华尔兹》02 高置信命中 S0E6 时，将 01/03 对齐至 S0E5/S0E7）。
    if (!singleMain &&
        matchedByBucketIndex.isNotEmpty &&
        matchedByBucketIndex.length < orderedBuckets.length &&
        _areConsecutiveNumberedBuckets(orderedBuckets)) {
      _propagateContiguousBlockFromAnchors(
        orderedBuckets: orderedBuckets,
        matchedByBucketIndex: matchedByBucketIndex,
        s0ByEp: s0ByEp,
        s0Dates: s0Dates,
        s0SeriesPrefix: s0SeriesPrefix,
        repeatedPrefixClusters: repeatedPrefixClusters,
        claimed: claimed,
        result: result,
        fallbackYear: work.year ?? folder.year,
      );
    }

    // 阶段 2B：原始文件连续绝对集号块对齐（如 `Slayers OVA [1998] - 04/05/06` 被拆簇归一成 1/2/3 后，
    // 按原始集号 4/5/6 与 1998 年份精准回对齐至 Season 0 的 S0E4..S0E6）。
    if (!singleMain && matchedByBucketIndex.isEmpty) {
      _tryAlignByRawFileContiguousBlock(
        orderedBuckets: orderedBuckets,
        s0ByEp: s0ByEp,
        s0Dates: s0Dates,
        s0SeriesPrefix: s0SeriesPrefix,
        repeatedPrefixClusters: repeatedPrefixClusters,
        claimed: claimed,
        result: result,
        work: work,
        folder: folder,
      );
    }

    return result;
  }

  static bool _areConsecutiveNumberedBuckets(
    List<
      ({
        int? localEp,
        int? rawFileEp,
        String cleanStem,
        List<MediaVariant> variants,
      })
    >
    buckets,
  ) {
    if (buckets.length < 2) return false;
    int? prev;
    for (final b in buckets) {
      final ep = b.localEp;
      if (ep == null || ep <= 0) return false;
      if (prev != null && ep != prev + 1) return false;
      prev = ep;
    }
    return true;
  }

  static void _propagateContiguousBlockFromAnchors({
    required List<
      ({
        int? localEp,
        int? rawFileEp,
        String cleanStem,
        List<MediaVariant> variants,
      })
    >
    orderedBuckets,
    required Map<int, ({TmdbEpisodeDetail ep, double score})>
    matchedByBucketIndex,
    required Map<int, TmdbEpisodeDetail> s0ByEp,
    required Map<int, DateTime?> s0Dates,
    required Map<int, String> s0SeriesPrefix,
    required Set<String> repeatedPrefixClusters,
    required Set<int> claimed,
    required Map<String, TmdbEpisodeDetail> result,
    required int? fallbackYear,
  }) {
    // 选取最高置信度锚点计算偏移量 `delta = anchorS0 - anchorLocalEp`。
    int? bestAnchorIdx;
    var bestAnchorScore = -1.0;
    for (final entry in matchedByBucketIndex.entries) {
      if (entry.value.score > bestAnchorScore) {
        bestAnchorScore = entry.value.score;
        bestAnchorIdx = entry.key;
      }
    }
    if (bestAnchorIdx == null || bestAnchorScore < 40.0) return;

    final anchorBucket = orderedBuckets[bestAnchorIdx];
    final anchorLocal = anchorBucket.localEp;
    if (anchorLocal == null) return;
    final anchorS0 = matchedByBucketIndex[bestAnchorIdx]!.ep;
    final delta = anchorS0.episodeNumber - anchorLocal;
    final anchorPrefix = s0SeriesPrefix[anchorS0.episodeNumber];
    final anchorYear = s0Dates[anchorS0.episodeNumber]?.year ?? fallbackYear;

    // 校验所有已有锚点偏移一致，避免多散集误走连续块传播。
    for (final entry in matchedByBucketIndex.entries) {
      final lEp = orderedBuckets[entry.key].localEp;
      if (lEp == null || entry.value.ep.episodeNumber - lEp != delta) {
        return;
      }
    }

    final proposed = <int, TmdbEpisodeDetail>{};
    for (var i = 0; i < orderedBuckets.length; i++) {
      if (matchedByBucketIndex.containsKey(i)) continue;
      final localEp = orderedBuckets[i].localEp!;
      final targetS0Num = localEp + delta;
      if (claimed.contains(targetS0Num)) return;
      final candidate = s0ByEp[targetS0Num];
      if (candidate == null) return;

      // 严禁跨入与锚点不同的高频迷你短片族（如 EX1=S0E3 时，S0E4 属 `小加速世界` 族必须拒绝）。
      final candPrefix = s0SeriesPrefix[targetS0Num];
      if (candPrefix != null &&
          repeatedPrefixClusters.contains(candPrefix) &&
          candPrefix != anchorPrefix) {
        return;
      }
      final candDate = s0Dates[targetS0Num];
      if (anchorYear != null &&
          candDate != null &&
          (candDate.year - anchorYear).abs() > 1) {
        return;
      }
      proposed[i] = candidate;
    }

    for (final entry in proposed.entries) {
      final bucket = orderedBuckets[entry.key];
      final target = entry.value;
      claimed.add(target.episodeNumber);
      for (final item in bucket.variants) {
        result[item.relativePath] = target;
      }
    }
  }

  static void _tryAlignByRawFileContiguousBlock({
    required List<
      ({
        int? localEp,
        int? rawFileEp,
        String cleanStem,
        List<MediaVariant> variants,
      })
    >
    orderedBuckets,
    required Map<int, TmdbEpisodeDetail> s0ByEp,
    required Map<int, DateTime?> s0Dates,
    required Map<int, String> s0SeriesPrefix,
    required Set<String> repeatedPrefixClusters,
    required Set<int> claimed,
    required Map<String, TmdbEpisodeDetail> result,
    required Work work,
    required GroupedWorkFolder folder,
  }) {
    final targetYear = work.year ?? folder.year;
    if (targetYear == null) return;
    final rawEps = <int>[];
    var differsFromLocal = false;
    for (final b in orderedBuckets) {
      final raw = b.rawFileEp;
      if (raw == null || raw <= 0) return;
      if (b.localEp != null && raw != b.localEp) {
        differsFromLocal = true;
      }
      rawEps.add(raw);
    }
    if (!differsFromLocal) return;
    for (var i = 1; i < rawEps.length; i++) {
      if (rawEps[i] != rawEps[i - 1] + 1) return;
    }

    final combinedWorkNorm = DirectoryAnalyzer.normalize(
      '${work.title} ${folder.cleanTitle}',
    );
    var exactYearHits = 0;
    final proposed = <int, TmdbEpisodeDetail>{};
    for (var i = 0; i < orderedBuckets.length; i++) {
      final raw = rawEps[i];
      if (claimed.contains(raw)) return;
      final candidate = s0ByEp[raw];
      if (candidate == null) return;
      final candPrefix = s0SeriesPrefix[raw];
      if (candPrefix != null &&
          repeatedPrefixClusters.contains(candPrefix) &&
          !combinedWorkNorm.contains(candPrefix)) {
        return;
      }
      final candDate = s0Dates[raw];
      if (candDate != null) {
        final diff = (candDate.year - targetYear).abs();
        if (diff > 1) return;
        if (diff == 0) exactYearHits++;
      }
      proposed[i] = candidate;
    }
    if (exactYearHits == 0) return;

    for (final entry in proposed.entries) {
      final bucket = orderedBuckets[entry.key];
      final target = entry.value;
      claimed.add(target.episodeNumber);
      for (final item in bucket.variants) {
        result[item.relativePath] = target;
      }
    }
  }

  /// 提取分集标题去除尾部集号后的规范前缀，用于识别高频迷你短片族（如 `小加速世界 1..8` -> `小加速世界`）。
  static String _extractRepeatedPrefixKey(String title) {
    final stripped = title.trim().replaceFirst(_trailingIndexPattern, '').trim();
    return DirectoryAnalyzer.normalize(stripped);
  }

  static String _cleanFileStem(String fileName) {
    return fileName
        .replaceFirst(_extPattern, '')
        .replaceAll(_bracketPattern, ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static int? _extractOvaOrdinal(String text) {
    final m = _ovaNumPattern.firstMatch(text);
    if (m == null) return null;
    return int.tryParse(m.group(1)!);
  }

  static Set<String> _extractTokens(String raw) {
    final out = <String>{};
    final lower = raw.toLowerCase();
    for (final part in lower.split(_tokenSplit)) {
      final t = part.trim();
      if (t.length < 2 || _noiseTokens.contains(t)) continue;
      out.add(t);
      // 对中文连续短语提取双字片，提升简繁与略微意译的召回。
      for (final m in _cjkRun.allMatches(t)) {
        final run = m.group(0)!;
        if (run.length >= 2) {
          out.add(run);
          if (run.length >= 4) {
            for (var i = 0; i <= run.length - 2; i++) {
              out.add(run.substring(i, i + 2));
            }
          }
        }
      }
    }
    return out;
  }

  static DateTime? _parseAirDate(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    return DateTime.tryParse(raw.trim());
  }
}
