import '../models/episode.dart';
import '../models/media_variant.dart';
import '../models/tmdb_models.dart';
import '../parsing/bdrip_parser.dart';
import '../scraping/bangumi_models.dart';
import 'directory_grouper.dart';

/// 正片顺序流中穿插的特别篇 / 总集篇槽位重映射信息。
class InterspersedSpecialMapping {
  /// 创建穿插特别篇槽位信息。
  const InterspersedSpecialMapping({
    this.tmdbSpecialEpisodeNumber,
    this.bangumiEpisode,
    this.fallbackTitle,
  });

  /// 协同命中 TMDB `Season 0` 时的目标特别篇集号。
  final int? tmdbSpecialEpisodeNumber;

  /// 协同命中的 Bangumi SP / 总集篇分集元数据（含中文标题与播出日期）。
  final BangumiEpisodeEntry? bangumiEpisode;

  /// 当 TMDB / Bangumi 均无标题可用时的干净兜底标题。
  final String? fallbackTitle;
}

/// 跨季绝对集号与 TMDB 季内集号重映射计划（含 Bangumi 穿插特别篇校准）。
class EpisodeRemapPlan {
  /// 创建重映射计划。
  const EpisodeRemapPlan({
    required this.remappedSlots,
    required this.referencedSeasons,
    this.specialSlots = const {},
    this.hasInterspersedSpecialCandidate = false,
  });

  /// 本地 `'rawSeason:rawEpisode'` 到目标 TMDB `(seasonNumber, episodeNumber)` 的映射表。
  final Map<String, ({int seasonNumber, int episodeNumber})> remappedSlots;

  /// 本地 `'rawSeason:rawEpisode'` 识别为穿插特别篇/总集篇时的 `Season 0` / Bangumi SP 映射。
  final Map<String, InterspersedSpecialMapping> specialSlots;

  /// 实际需要拉取分集元数据的 TMDB 季号集合（含重映射目标季与 `Season 0`）。
  final Set<int> referencedSeasons;

  /// 是否检测到本地正片数超出 TMDB 季集数或存在穿插特别篇线索（触发拉取 `Season 0` 与 Bangumi SP）。
  final bool hasInterspersedSpecialCandidate;

  /// 查询指定原始季/集号对应的最终 TMDB 季/集槽位；无需重映射时返回 `null`。
  ({int seasonNumber, int episodeNumber})? resolve(int season, int episode) =>
      remappedSlots['$season:$episode'];

  /// 查询指定原始季/集号是否被判定为穿插特别篇/总集篇。
  InterspersedSpecialMapping? resolveSpecial(int season, int episode) =>
      specialSlots['$season:$episode'];
}

/// 跨季绝对集号与 Bangumi 穿插特别篇自动对齐器（纯函数，零 IO）。
///
/// 典型适用场景：
/// 1. 文件夹标明 `第二季`/`第三季`，但文件继续使用全局连续编号（如 `Re:Zero 第三季 [51..66]`）；
/// 2. 未标注分季的跨季连续编号目录（如 `EP26..EP50` 超出 TMDB S1 集数上限），按前序季累计集数顺延分配；
/// 3. 正片顺序编号中包含穿插特别篇 / 总集篇（如 `[Moozzi2] Wake Up, Girls! Shin Shou - 07 [ Wug Ban Special ]`
///    + `08..13`），结合 Bangumi 播出顺序与 TMDB `Season 0` 精准移出特别篇并对其后正片执行 `-1` 顺延。
class EpisodeRemapper {
  const EpisodeRemapper._();

  static final RegExp _interspersedMarker = RegExp(
    r'(?:^|[\s._\-\[(])(?:special|recap|summary|digest|intermission|omake|tokubetsu|wug\s*ban)(?=$|[\s._\-\])])|'
    r'总集篇|総集編|总集|特別編|特别篇|番外|特番',
    caseSensitive: false,
  );

  static final RegExp _promoSpTitlePattern = RegExp(
    r'^(?:PV|CM|TVCM|BDCM|Menu|NCOP|NCED|Trailer|Teaser|予告|预告|宣伝|宣传)\b',
    caseSensitive: false,
  );

  static final RegExp _techNoiseBracket = RegExp(
    r'^[\[\(（【].*?[\]\)）】]$',
  );

  static final RegExp _tokenSeparator = RegExp(r'[\s._\-!?！？:：()\[\]【】/\\+]+');

  /// 根据工作目录视频、TMDB 季摘要及可选的分集/Bangumi 元数据生成确定性重映射计划。
  static EpisodeRemapPlan buildPlan({
    required GroupedWorkFolder folder,
    required List<TmdbSeasonSummary> tmdbSeasons,
    int? matchedSeason,
    List<TmdbEpisodeDetail> tmdbEpisodes = const [],
    List<BangumiEpisodeEntry> bangumiEpisodes = const [],
  }) {
    final mainBySeason = <int, Set<int>>{};
    final variantsBySeasonEp = <String, List<MediaVariant>>{};
    final rawSeasons = <int>{};
    var hasExtra = false;

    for (final variant in folder.variants) {
      if (variant.assetKind != AssetKind.video) continue;
      final slot = folder.slotAssignmentsByPath[variant.relativePath];
      final parsed = BdripParser.parseFileName(
        variant.fileName,
        relativePath: variant.relativePath,
        folderTitle: folder.cleanTitle,
        folderSeasonHint: folder.seasonHint,
      );
      final category = slot?.category ?? parsed.category;
      if (category == EpisodeCategory.main) {
        final season = slot?.seasonNumber ??
            (matchedSeason != null && matchedSeason > 0
                ? matchedSeason
                : parsed.season);
        final effectiveSeason = matchedSeason != null && matchedSeason > 0
            ? matchedSeason
            : (season > 0 ? season : 1);
        final ep = slot?.episodeNumber ?? parsed.episode;
        rawSeasons.add(effectiveSeason);
        if (ep != null && ep > 0) {
          mainBySeason.putIfAbsent(effectiveSeason, () => {}).add(ep);
          variantsBySeasonEp
              .putIfAbsent('$effectiveSeason:$ep', () => [])
              .add(variant);
        }
      } else {
        hasExtra = true;
      }
    }

    if (rawSeasons.isEmpty) {
      rawSeasons.add(
        (matchedSeason != null && matchedSeason > 0)
            ? matchedSeason
            : (folder.seasonHint ?? 1),
      );
    }

    final remappedSlots = Map<String, ({int seasonNumber, int episodeNumber})>.from(
      computeRemapping(
        tmdbSeasons: tmdbSeasons,
        mainEpisodesBySeason: mainBySeason,
      ),
    );

    final specialResult = _computeInterspersedSpecials(
      folder: folder,
      tmdbSeasons: tmdbSeasons,
      mainBySeason: mainBySeason,
      variantsBySeasonEp: variantsBySeasonEp,
      alreadyRemapped: remappedSlots,
      tmdbEpisodes: tmdbEpisodes,
      bangumiEpisodes: bangumiEpisodes,
    );

    remappedSlots.addAll(specialResult.remappedMain);

    final targetSeasons = <int>{...rawSeasons};
    for (final mapped in remappedSlots.values) {
      targetSeasons.add(mapped.seasonNumber);
    }
    if (hasExtra ||
        specialResult.hasCandidate ||
        specialResult.specialSlots.isNotEmpty) {
      targetSeasons.add(0);
    }

    return EpisodeRemapPlan(
      remappedSlots: Map.unmodifiable(remappedSlots),
      specialSlots: Map.unmodifiable(specialResult.specialSlots),
      referencedSeasons: Set.unmodifiable(targetSeasons),
      hasInterspersedSpecialCandidate:
          specialResult.hasCandidate || specialResult.specialSlots.isNotEmpty,
    );
  }

  /// 基于 TMDB 各季集数累计偏移，计算绝对集号重映射表。
  static Map<String, ({int seasonNumber, int episodeNumber})> computeRemapping({
    required List<TmdbSeasonSummary> tmdbSeasons,
    required Map<int, Set<int>> mainEpisodesBySeason,
  }) {
    final validSeasons = tmdbSeasons
        .where((s) => s.seasonNumber >= 1 && s.episodeCount > 0)
        .toList()
      ..sort((a, b) => a.seasonNumber.compareTo(b.seasonNumber));
    if (validSeasons.isEmpty || mainEpisodesBySeason.isEmpty) {
      return const {};
    }

    final priorOffsetBySeason = <int, int>{};
    final countBySeason = <int, int>{};
    final cumulativeRanges = <({int season, int start, int end, int offset})>[];
    var runningTotal = 0;
    for (final s in validSeasons) {
      priorOffsetBySeason[s.seasonNumber] = runningTotal;
      countBySeason[s.seasonNumber] = s.episodeCount;
      cumulativeRanges.add((
        season: s.seasonNumber,
        start: runningTotal + 1,
        end: runningTotal + s.episodeCount,
        offset: runningTotal,
      ));
      runningTotal += s.episodeCount;
    }

    final result = <String, ({int seasonNumber, int episodeNumber})>{};

    for (final entry in mainEpisodesBySeason.entries) {
      final rawSeason = entry.key;
      final eps = entry.value;
      if (eps.isEmpty) continue;

      final epCount = countBySeason[rawSeason];
      final offset = priorOffsetBySeason[rawSeason] ?? 0;

      // 情形 1：本地已明确分季（如 S2/S3），验证是否全季采用“含前序季累计”的绝对集号。
      if (epCount != null && offset > 0) {
        final rawHits = eps.where((e) => e >= 1 && e <= epCount).length;
        final shiftedHits = eps
            .where((e) => (e - offset) >= 1 && (e - offset) <= epCount)
            .length;
        final minRequired = (eps.length * 0.6).ceil();
        if (rawHits * 3 < eps.length &&
            shiftedHits > rawHits &&
            shiftedHits >= minRequired) {
          for (final ep in eps) {
            final localEp = ep - offset;
            if (localEp >= 1 && localEp <= epCount) {
              result['$rawSeason:$ep'] = (
                seasonNumber: rawSeason,
                episodeNumber: localEp,
              );
            }
          }
          continue;
        }
      }

      // 情形 2：未标注分季导致归入 S1，但部分或全部集号顺延落在后续正片季范围内。
      if (rawSeason == 1 && validSeasons.length > 1) {
        final s1Count = countBySeason[1] ?? 0;
        final overflowEps = eps.where((e) => e > s1Count).toList();
        if (overflowEps.isNotEmpty) {
          var rangeHits = 0;
          for (final ep in overflowEps) {
            if (cumulativeRanges.any((r) => ep >= r.start && ep <= r.end)) {
              rangeHits++;
            }
          }
          if (rangeHits >= (overflowEps.length * 0.6).ceil()) {
            for (final ep in overflowEps) {
              for (final r in cumulativeRanges) {
                if (ep >= r.start && ep <= r.end) {
                  result['1:$ep'] = (
                    seasonNumber: r.season,
                    episodeNumber: ep - r.offset,
                  );
                  break;
                }
              }
            }
          }
        }
      }
    }

    return result;
  }

  static ({
    bool hasCandidate,
    Map<String, InterspersedSpecialMapping> specialSlots,
    Map<String, ({int seasonNumber, int episodeNumber})> remappedMain,
  }) _computeInterspersedSpecials({
    required GroupedWorkFolder folder,
    required List<TmdbSeasonSummary> tmdbSeasons,
    required Map<int, Set<int>> mainBySeason,
    required Map<String, List<MediaVariant>> variantsBySeasonEp,
    required Map<String, ({int seasonNumber, int episodeNumber})> alreadyRemapped,
    required List<TmdbEpisodeDetail> tmdbEpisodes,
    required List<BangumiEpisodeEntry> bangumiEpisodes,
  }) {
    final specialSlots = <String, InterspersedSpecialMapping>{};
    final remappedMain = <String, ({int seasonNumber, int episodeNumber})>{};
    var hasCandidate = false;

    final seasonZeroEps = tmdbEpisodes
        .where((e) => e.seasonNumber == 0)
        .toList(growable: false);

    for (final entry in mainBySeason.entries) {
      final season = entry.key;
      if (season <= 0) continue;

      final eps = entry.value.toList()..sort();
      if (eps.length < 3 || eps.first != 1) continue;
      if (eps.any((ep) => alreadyRemapped.containsKey('$season:$ep'))) {
        continue;
      }

      final seasonMainEps = tmdbEpisodes
          .where((e) => e.seasonNumber == season)
          .toList()
        ..sort((a, b) => a.episodeNumber.compareTo(b.episodeNumber));
      final summaryCount = tmdbSeasons
              .where((s) => s.seasonNumber == season)
              .firstOrNull
              ?.episodeCount ??
          0;
      final tmdbCount = seasonMainEps.isNotEmpty
          ? (summaryCount > seasonMainEps.length
                ? summaryCount
                : seasonMainEps.length)
          : summaryCount;
      if (tmdbCount <= 0) continue;

      final overflow = eps.length - tmdbCount;
      if (overflow <= 0 || overflow > 3) continue;

      hasCandidate = true;

      // 构造 Bangumi 播出时间轴与特殊标题线索。
      final bgmTimeline = _buildBangumiBroadcastTimeline(bangumiEpisodes);
      final claimedS0 = <int>{};
      final candidates = <({
        int rawEp,
        double score,
        String? fileHint,
        BangumiEpisodeEntry? bgmEp,
        TmdbEpisodeDetail? tmdbS0,
      })>[];

      for (var i = 0; i < eps.length; i++) {
        final rawEp = eps[i];
        final variants = variantsBySeasonEp['$season:$rawEp'] ?? const [];
        final fileHint = _extractInterspersedHintFromVariants(
          variants,
          folderTitle: folder.cleanTitle,
        );

        var score = 0.0;
        if (fileHint != null) {
          score += 60;
        }

        BangumiEpisodeEntry? bgmSlot;
        if (bgmTimeline.length >= eps.length) {
          final timelineEntry = bgmTimeline[i];
          if (timelineEntry.isInterspersedSpecial) {
            score += 65;
            bgmSlot = timelineEntry.episode;
          }
        } else if (fileHint != null && bangumiEpisodes.isNotEmpty) {
          bgmSlot = _matchBangumiSpByHint(fileHint, bangumiEpisodes);
        }

        final gapS0 = _findAirDateGapSpecial(
          indexInLocalSequence: i,
          seasonMainEps: seasonMainEps,
          seasonZeroEps: seasonZeroEps,
        );
        if (gapS0 != null) {
          score += 35;
        }

        if (score >= 40) {
          final bestS0 = _matchTmdbSeasonZero(
            fileHint: fileHint,
            bgmEp: bgmSlot,
            gapCandidate: gapS0,
            seasonZeroEps: seasonZeroEps,
            claimedS0: claimedS0,
          );
          candidates.add((
            rawEp: rawEp,
            score: score,
            fileHint: fileHint,
            bgmEp: bgmSlot,
            tmdbS0: bestS0,
          ));
        }
      }

      if (candidates.isEmpty) continue;
      candidates.sort((a, b) {
        final cmp = b.score.compareTo(a.score);
        return cmp != 0 ? cmp : a.rawEp.compareTo(b.rawEp);
      });

      final chosen = candidates.take(overflow).toList()
        ..sort((a, b) => a.rawEp.compareTo(b.rawEp));
      final chosenSet = <int>{};

      for (final pick in chosen) {
        final s0 = _matchTmdbSeasonZero(
          fileHint: pick.fileHint,
          bgmEp: pick.bgmEp,
          gapCandidate: null,
          seasonZeroEps: seasonZeroEps,
          claimedS0: claimedS0,
          preferred: pick.tmdbS0,
        );
        if (s0 != null) claimedS0.add(s0.episodeNumber);
        chosenSet.add(pick.rawEp);
        specialSlots['$season:${pick.rawEp}'] = InterspersedSpecialMapping(
          tmdbSpecialEpisodeNumber: s0?.episodeNumber,
          bangumiEpisode: pick.bgmEp,
          fallbackTitle: pick.fileHint,
        );
      }

      if (chosenSet.isEmpty) continue;
      for (final rawEp in eps) {
        if (chosenSet.contains(rawEp)) continue;
        final shift = chosenSet.where((spEp) => spEp < rawEp).length;
        if (shift <= 0) continue;
        final shiftedEp = rawEp - shift;
        if (shiftedEp >= 1 && shiftedEp <= tmdbCount) {
          remappedMain['$season:$rawEp'] = (
            seasonNumber: season,
            episodeNumber: shiftedEp,
          );
        }
      }
    }

    return (
      hasCandidate: hasCandidate,
      specialSlots: specialSlots,
      remappedMain: remappedMain,
    );
  }

  static List<({BangumiEpisodeEntry episode, bool isInterspersedSpecial})>
  _buildBangumiBroadcastTimeline(List<BangumiEpisodeEntry> bangumiEpisodes) {
    if (bangumiEpisodes.isEmpty) return const [];

    final mainEps =
        bangumiEpisodes.where((e) => e.type == 0).toList()
          ..sort((a, b) {
            final sa = a.sort ?? a.ep ?? 9999;
            final sb = b.sort ?? b.ep ?? 9999;
            return sa.compareTo(sb);
          });
    if (mainEps.isEmpty) return const [];

    final datedMain = mainEps
        .map((e) => _parseAirDate(e.airDate))
        .whereType<DateTime>()
        .toList()
      ..sort();
    final minMainDate = datedMain.isNotEmpty ? datedMain.first : null;
    final maxMainDate = datedMain.isNotEmpty ? datedMain.last : null;

    final spEps = bangumiEpisodes.where((e) => e.type != 0).where((sp) {
      final spDate = _parseAirDate(sp.airDate);
      if (spDate == null || minMainDate == null || maxMainDate == null) {
        return false;
      }
      if (spDate.isBefore(minMainDate) || spDate.isAfter(maxMainDate)) {
        return false;
      }
      final title = '${sp.nameCn} ${sp.name}'.trim();
      if (_promoSpTitlePattern.hasMatch(title) &&
          !_interspersedMarker.hasMatch(title)) {
        return false;
      }
      return true;
    }).toList();

    if (spEps.isEmpty) {
      // 部分番剧在 Bangumi 直接将总集篇/特别篇收入 type=0 正片序列，检查其标题标记。
      return [
        for (final m in mainEps)
          (
            episode: m,
            isInterspersedSpecial: _interspersedMarker.hasMatch(
              '${m.nameCn} ${m.name}',
            ),
          ),
      ];
    }

    final merged = <({BangumiEpisodeEntry episode, bool isSp, DateTime? date})>[
      for (final m in mainEps)
        (episode: m, isSp: false, date: _parseAirDate(m.airDate)),
      for (final sp in spEps)
        (episode: sp, isSp: true, date: _parseAirDate(sp.airDate)),
    ]..sort((a, b) {
        if (a.date != null && b.date != null) {
          final cmp = a.date!.compareTo(b.date!);
          if (cmp != 0) return cmp;
        }
        if (a.isSp != b.isSp) return a.isSp ? 1 : -1;
        final sa = a.episode.sort ?? a.episode.ep ?? 9999;
        final sb = b.episode.sort ?? b.episode.ep ?? 9999;
        return sa.compareTo(sb);
      });

    return [
      for (final item in merged)
        (episode: item.episode, isInterspersedSpecial: item.isSp),
    ];
  }

  static String? _extractInterspersedHintFromVariants(
    List<MediaVariant> variants, {
    required String folderTitle,
  }) {
    final normFolder = _normalizeAlphaNum(folderTitle);
    for (final v in variants) {
      final strippedTitle = normFolder.isEmpty
          ? v.fileName
          : v.fileName.replaceAll(
              RegExp(RegExp.escape(folderTitle), caseSensitive: false),
              ' ',
            );
      final bracketMatches = RegExp(
        r'\[([^\]]+)\]|\(([^)]+)\)|【([^】]+)】',
      ).allMatches(strippedTitle);
      for (final m in bracketMatches) {
        final raw = (m.group(1) ?? m.group(2) ?? m.group(3) ?? '').trim();
        if (raw.isEmpty) continue;
        if (_interspersedMarker.hasMatch(raw)) {
          return raw;
        }
      }
      final stem = strippedTitle
          .replaceFirst(RegExp(r'\.[^.]+$'), '')
          .replaceAll(RegExp(r'\[[^\]]+\]|\([^)]+\)'), ' ')
          .trim();
      if (stem.isNotEmpty && _interspersedMarker.hasMatch(stem)) {
        return stem;
      }
    }
    return null;
  }

  static BangumiEpisodeEntry? _matchBangumiSpByHint(
    String hint,
    List<BangumiEpisodeEntry> bangumiEpisodes,
  ) {
    final hintTokens = _tokenize(hint);
    if (hintTokens.isEmpty) return null;

    BangumiEpisodeEntry? best;
    var bestScore = 0;
    for (final bgm in bangumiEpisodes.where((e) => e.type != 0)) {
      final score = _tokenOverlapScore(hintTokens, '${bgm.nameCn} ${bgm.name}');
      if (score > bestScore) {
        bestScore = score;
        best = bgm;
      }
    }
    return bestScore >= 2 ? best : null;
  }

  static TmdbEpisodeDetail? _findAirDateGapSpecial({
    required int indexInLocalSequence,
    required List<TmdbEpisodeDetail> seasonMainEps,
    required List<TmdbEpisodeDetail> seasonZeroEps,
  }) {
    if (seasonZeroEps.isEmpty ||
        seasonMainEps.length < 2 ||
        indexInLocalSequence <= 0 ||
        indexInLocalSequence >= seasonMainEps.length) {
      return null;
    }
    final prevDate = _parseAirDate(seasonMainEps[indexInLocalSequence - 1].airDate);
    final nextDate = _parseAirDate(seasonMainEps[indexInLocalSequence].airDate);
    if (prevDate == null || nextDate == null) return null;
    if (nextDate.difference(prevDate).inDays < 10) return null;

    for (final s0 in seasonZeroEps) {
      final s0Date = _parseAirDate(s0.airDate);
      if (s0Date == null) continue;
      if (s0Date.isAfter(prevDate) && s0Date.isBefore(nextDate)) {
        return s0;
      }
    }
    return null;
  }

  static TmdbEpisodeDetail? _matchTmdbSeasonZero({
    required String? fileHint,
    required BangumiEpisodeEntry? bgmEp,
    required TmdbEpisodeDetail? gapCandidate,
    required List<TmdbEpisodeDetail> seasonZeroEps,
    required Set<int> claimedS0,
    TmdbEpisodeDetail? preferred,
  }) {
    if (preferred != null && !claimedS0.contains(preferred.episodeNumber)) {
      return preferred;
    }
    if (seasonZeroEps.isEmpty) return null;

    final bgmDate = _parseAirDate(bgmEp?.airDate);
    final queryTokens = <String>{
      if (fileHint != null) ..._tokenize(fileHint),
      if (bgmEp != null) ..._tokenize('${bgmEp.nameCn} ${bgmEp.name}'),
    };
    final compactQuery = _normalizeAlphaNum(
      '${fileHint ?? ''} ${bgmEp?.nameCn ?? ''} ${bgmEp?.name ?? ''}',
    );

    TmdbEpisodeDetail? best;
    var bestScore = 0;

    for (final s0 in seasonZeroEps) {
      if (claimedS0.contains(s0.episodeNumber)) continue;
      var score = 0;

      if (gapCandidate != null &&
          s0.episodeNumber == gapCandidate.episodeNumber) {
        score += 35;
      }

      final s0Date = _parseAirDate(s0.airDate);
      if (bgmDate != null && s0Date != null) {
        final diffDays = (s0Date.difference(bgmDate).inDays).abs();
        if (diffDays == 0) {
          score += 60;
        } else if (diffDays <= 3) {
          score += 45;
        }
      }

      if (queryTokens.isNotEmpty) {
        final titleOverlap = _tokenOverlapScore(
          queryTokens,
          '${s0.title} ${s0.overview ?? ''}',
        );
        score += titleOverlap * 20;
      }

      final compactS0 = _normalizeAlphaNum(s0.title);
      if (compactS0.length >= 4 && compactQuery.contains(compactS0)) {
        score += 45;
      } else {
        // 去除后缀后比对核心词串（例如 `wugban` 命中 `wugbannewchapter`）
        final prefixWords = compactQuery
            .replaceAll('special', '')
            .replaceAll('recap', '')
            .trim();
        if (prefixWords.length >= 5 && compactS0.contains(prefixWords)) {
          score += 45;
        }
      }

      if (score > bestScore) {
        bestScore = score;
        best = s0;
      }
    }

    return bestScore >= 35 ? best : null;
  }

  static DateTime? _parseAirDate(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final m = RegExp(r'(\d{4})-(\d{1,2})-(\d{1,2})').firstMatch(raw.trim());
    if (m == null) return null;
    final y = int.tryParse(m.group(1)!);
    final mo = int.tryParse(m.group(2)!);
    final d = int.tryParse(m.group(3)!);
    if (y == null || mo == null || d == null) return null;
    return DateTime.utc(y, mo, d);
  }

  static Set<String> _tokenize(String text) {
    const stopWords = {'special', 'the', 'of', 'new', 'chapter', '特别篇', '总集篇'};
    return text
        .toLowerCase()
        .split(_tokenSeparator)
        .map((t) => t.trim())
        .where(
          (t) =>
              t.length >= 2 &&
              !_techNoiseBracket.hasMatch(t) &&
              !stopWords.contains(t),
        )
        .toSet();
  }

  static int _tokenOverlapScore(Set<String> queryTokens, String targetText) {
    final targetNorm = _normalizeAlphaNum(targetText);
    var hits = 0;
    for (final q in queryTokens) {
      if (targetNorm.contains(_normalizeAlphaNum(q))) {
        hits++;
      }
    }
    return hits;
  }

  static String _normalizeAlphaNum(String raw) =>
      raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fff]+'), '');
}
