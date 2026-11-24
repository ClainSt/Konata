import '../models/episode.dart';
import '../models/media_variant.dart';
import '../models/tmdb_models.dart';
import '../parsing/bdrip_parser.dart';
import '../scraping/bangumi_models.dart';
import '../scraping/title_normalizer.dart';
import 'directory_grouper.dart';

/// 单集元数据对齐目标（保留本地 BD 正片集号不变，仅重定位 TMDB 剧照/标题查找槽位）。
class EpisodeMetadataOverride {
  /// 创建单集元数据重定位目标。
  const EpisodeMetadataOverride({
    this.tmdbSeasonNumber,
    this.tmdbEpisodeNumber,
    this.preferBangumiTitle = false,
  });

  /// 对齐后的 TMDB 目标季号；为 `null` 表示本地该集在 TMDB 中无对应分集，禁止回落按原集号错查。
  final int? tmdbSeasonNumber;

  /// 对齐后的 TMDB 目标集号；为 `null` 时仅使用 Bangumi 分集标题。
  final int? tmdbEpisodeNumber;

  /// 仅命中半集/合集切片或 TMDB 无对应条目时，优先保留完整 Bangumi 分集标题。
  final bool preferBangumiTitle;
}

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
    this.metadataOverrides = const {},
    this.hasInterspersedSpecialCandidate = false,
  });

  /// 本地 `'rawSeason:rawEpisode'` 到目标 TMDB `(seasonNumber, episodeNumber)` 的映射表。
  final Map<String, ({int seasonNumber, int episodeNumber})> remappedSlots;

  /// 本地 `'rawSeason:rawEpisode'` 识别为穿插特别篇/总集篇时的 `Season 0` / Bangumi SP 映射。
  final Map<String, InterspersedSpecialMapping> specialSlots;

  /// 本地 `'season:episode'` 保留集号不变时的 TMDB 元数据重定位表（用于 BD/TV 集序或合集切片分歧对齐）。
  final Map<String, EpisodeMetadataOverride> metadataOverrides;

  /// 实际需要拉取分集元数据的 TMDB 季号集合（含重映射目标季与 `Season 0`）。
  final Set<int> referencedSeasons;

  /// 是否检测到本地正片数超出 TMDB 季集数或存在穿插特别篇线索（触发拉取 `Season 0` 与 Bangumi SP）。
  final bool hasInterspersedSpecialCandidate;

  /// 查询指定原始季/集号对应的最终 TMDB 季/集槽位；无需重映射时返回 `null`。
  ({int seasonNumber, int episodeNumber})? resolve(int season, int episode) =>
      remappedSlots['$season:$episode'];

  /// 查询指定本地季/集号是否需要重定位 TMDB 元数据查询槽位。
  EpisodeMetadataOverride? resolveMetadataTarget(int season, int episode) =>
      metadataOverrides['$season:$episode'];

  /// 解析多集合并文件区间 `[start, end]` 重映射后的结束集号。
  ///
  /// - 区间两端都不需要重映射时，原样返回 [end]；
  /// - 起始集被重映射，且结束集映射到同一目标季、集号严格大于起始集映射结果时，返回映射后的结束集；
  /// - 任一端映射失败、跨季，或区间内命中穿插特别篇时返回 `null`，调用方应退化为只保留起始集的单集。
  int? resolveEpisodeEnd(int season, int start, int end) {
    for (var ep = start; ep <= end; ep++) {
      if (resolveSpecial(season, ep) != null) return null;
    }
    final first = resolve(season, start);
    if (first == null) {
      for (var ep = start + 1; ep <= end; ep++) {
        if (resolve(season, ep) != null) return null;
      }
      return end;
    }
    final last = resolve(season, end);
    if (last == null ||
        last.seasonNumber != first.seasonNumber ||
        last.episodeNumber <= first.episodeNumber) {
      return null;
    }
    return last.episodeNumber;
  }

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

  static final RegExp _techNoiseBracket = RegExp(r'^[\[\(（【].*?[\]\)）】]$');

  static final RegExp _tokenSeparator = RegExp(r'[\s._\-!?！？:：()\[\]【】/\\+]+');

  /// 判断当前作品是否需要额外拉取 Bangumi 分集列表用于对齐或补全标题。
  static bool shouldFetchBangumiEpisodes({
    required int? matchedSeason,
    required List<TmdbEpisodeDetail> tmdbEpisodes,
    EpisodeRemapPlan? preRemap,
  }) {
    if (preRemap?.hasInterspersedSpecialCandidate ?? false) {
      return true;
    }
    if (matchedSeason == 0 &&
        tmdbEpisodes.where((e) => e.seasonNumber == 0).length > 1) {
      return true;
    }
    if (tmdbEpisodes.isEmpty) {
      return true;
    }
    return tmdbEpisodes.any((e) => e.title.trim().isEmpty);
  }

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
        final season =
            slot?.seasonNumber ??
            (matchedSeason != null && matchedSeason >= 0
                ? matchedSeason
                : parsed.season);
        final effectiveSeason = matchedSeason != null && matchedSeason >= 0
            ? matchedSeason
            : (season > 0 ? season : 1);
        final ep = slot?.episodeNumber ?? parsed.episode;
        final epEnd = slot?.episodeNumber == null ? null : slot?.episodeEnd;
        rawSeasons.add(effectiveSeason);
        if (ep != null && ep > 0) {
          final covered = mainBySeason.putIfAbsent(effectiveSeason, () => {})
            ..add(ep);
          // 多集合并文件覆盖的后续集号同样参与绝对集号判定与重映射。
          if (epEnd != null) {
            for (var e = ep + 1; e <= epEnd; e++) {
              covered.add(e);
            }
          }
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
        (matchedSeason != null && matchedSeason >= 0)
            ? matchedSeason
            : (folder.seasonHint ?? 1),
      );
    }

    final remappedSlots =
        Map<String, ({int seasonNumber, int episodeNumber})>.from(
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

    final alignedOrder = _computeBangumiAlignedOrder(
      tmdbSeasons: tmdbSeasons,
      mainBySeason: mainBySeason,
      alreadyRemapped: remappedSlots,
      specialSlots: specialResult.specialSlots,
      tmdbEpisodes: tmdbEpisodes,
      bangumiEpisodes: bangumiEpisodes,
    );

    final targetSeasons = <int>{...rawSeasons};
    for (final mapped in remappedSlots.values) {
      targetSeasons.add(mapped.seasonNumber);
    }
    for (final meta in alignedOrder.metadataOverrides.values) {
      if (meta.tmdbSeasonNumber != null) {
        targetSeasons.add(meta.tmdbSeasonNumber!);
      }
    }
    if (hasExtra ||
        specialResult.hasCandidate ||
        specialResult.specialSlots.isNotEmpty ||
        alignedOrder.hasCandidate ||
        alignedOrder.metadataOverrides.isNotEmpty) {
      targetSeasons.add(0);
    }

    return EpisodeRemapPlan(
      remappedSlots: Map.unmodifiable(remappedSlots),
      specialSlots: Map.unmodifiable(specialResult.specialSlots),
      metadataOverrides: Map.unmodifiable(alignedOrder.metadataOverrides),
      referencedSeasons: Set.unmodifiable(targetSeasons),
      hasInterspersedSpecialCandidate:
          specialResult.hasCandidate ||
          specialResult.specialSlots.isNotEmpty ||
          alignedOrder.hasCandidate,
    );
  }

  /// 基于 TMDB 各季集数累计偏移，计算绝对集号重映射表。
  static Map<String, ({int seasonNumber, int episodeNumber})> computeRemapping({
    required List<TmdbSeasonSummary> tmdbSeasons,
    required Map<int, Set<int>> mainEpisodesBySeason,
  }) {
    final validSeasons =
        tmdbSeasons
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
  })
  _computeInterspersedSpecials({
    required GroupedWorkFolder folder,
    required List<TmdbSeasonSummary> tmdbSeasons,
    required Map<int, Set<int>> mainBySeason,
    required Map<String, List<MediaVariant>> variantsBySeasonEp,
    required Map<String, ({int seasonNumber, int episodeNumber})>
    alreadyRemapped,
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

      final seasonMainEps =
          tmdbEpisodes.where((e) => e.seasonNumber == season).toList()
            ..sort((a, b) => a.episodeNumber.compareTo(b.episodeNumber));
      final summaryCount =
          tmdbSeasons
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
      final candidates =
          <
            ({
              int rawEp,
              double score,
              String? fileHint,
              BangumiEpisodeEntry? bgmEp,
              TmdbEpisodeDetail? tmdbS0,
            })
          >[];

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

    final mainEps = bangumiEpisodes.where((e) => e.type == 0).toList()
      ..sort((a, b) {
        final sa = a.sort ?? a.ep ?? 9999;
        final sb = b.sort ?? b.ep ?? 9999;
        return sa.compareTo(sb);
      });
    if (mainEps.isEmpty) return const [];

    final datedMain =
        mainEps
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

    final merged =
        <({BangumiEpisodeEntry episode, bool isSp, DateTime? date})>[
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
    final prevDate = _parseAirDate(
      seasonMainEps[indexInLocalSequence - 1].airDate,
    );
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

  static const double _alignMinSim = 0.50;
  static final RegExp _halfEpisodeSplit = RegExp(r'\s*[/／]\s*');
  static final RegExp _cjkOrKana = RegExp(r'[\u4e00-\u9fff\u3040-\u30ff]');
  static final RegExp _nonWordTitle = RegExp(
    r'[^a-z0-9\u4e00-\u9fff\u3040-\u30ff]+',
  );

  /// 基于 Bangumi 正片标题语义与 TMDB 季内/`Season 0` 分集列表执行保序对齐，
  /// 解决 BD 完整集序与 TMDB 电视放送版（拆并半集、未放送回落入 `Season 0` 或放送乱序）错位问题。
  ///
  /// 仅重定位每集查询 TMDB 剧照/简介的目标槽位，严格保持用户本地 BD 逻辑集号与正片集数不变。
  static ({
    bool hasCandidate,
    Map<String, EpisodeMetadataOverride> metadataOverrides,
  })
  _computeBangumiAlignedOrder({
    required List<TmdbSeasonSummary> tmdbSeasons,
    required Map<int, Set<int>> mainBySeason,
    required Map<String, ({int seasonNumber, int episodeNumber})>
    alreadyRemapped,
    required Map<String, InterspersedSpecialMapping> specialSlots,
    required List<TmdbEpisodeDetail> tmdbEpisodes,
    required List<BangumiEpisodeEntry> bangumiEpisodes,
  }) {
    var hasCandidate = false;
    final overrides = <String, EpisodeMetadataOverride>{};
    final seasonZeroEps =
        tmdbEpisodes.where((e) => e.seasonNumber == 0).toList()
          ..sort((a, b) => a.episodeNumber.compareTo(b.episodeNumber));

    for (final entry in mainBySeason.entries) {
      final season = entry.key;
      if (season <= 0) continue;

      final eps = entry.value.toList()..sort();
      if (eps.length < 4 || eps.first != 1 || eps.last != eps.length) {
        continue;
      }
      final seasonTouched = eps.any(
        (ep) =>
            alreadyRemapped.containsKey('$season:$ep') ||
            specialSlots.containsKey('$season:$ep'),
      );
      if (seasonTouched) continue;

      final seasonMainEps =
          tmdbEpisodes.where((e) => e.seasonNumber == season).toList()
            ..sort((a, b) => a.episodeNumber.compareTo(b.episodeNumber));
      final summaryCount =
          tmdbSeasons
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
      if (overflow > 0 && overflow <= 6) {
        hasCandidate = true;
      }

      if (seasonMainEps.isEmpty || bangumiEpisodes.isEmpty) continue;

      final bgmMain = bangumiEpisodes.where((e) => e.type == 0).toList()
        ..sort((a, b) {
          final sa = a.ep ?? a.sort ?? 9999;
          final sb = b.ep ?? b.sort ?? 9999;
          return sa.compareTo(sb);
        });
      if (bgmMain.length != eps.length) continue;

      final m = eps.length;
      final n = seasonMainEps.length;
      final simMatrix = List.generate(m, (_) => List<double>.filled(n, 0.0));
      final partialMatrix = List.generate(m, (_) => List<bool>.filled(n, false));
      for (var i = 0; i < m; i++) {
        for (var j = 0; j < n; j++) {
          final res = _episodeTitleSimilarity(bgmMain[i], seasonMainEps[j]);
          simMatrix[i][j] = res.score;
          partialMatrix[i][j] = res.isPartialComposite;
        }
      }

      // 统计按本地原始集号直连 TMDB 的直接命中质量。
      final tmdbMainIdxByEp = <int, int>{
        for (var j = 0; j < n; j++) seasonMainEps[j].episodeNumber: j,
      };
      var directStrong = 0;
      var directTotal = 0.0;
      for (var i = 0; i < m; i++) {
        final j = tmdbMainIdxByEp[eps[i]];
        if (j == null) continue;
        final s = simMatrix[i][j];
        if (s >= _alignMinSim) {
          directStrong++;
          directTotal += s;
        }
      }

      // 第一阶段：带权单调保序动态规划，在 TMDB 主季分集中寻找最大总相似度的保序配对。
      final dp = List.generate(m + 1, (_) => List<double>.filled(n + 1, 0.0));
      final choice = List.generate(m + 1, (_) => List<int>.filled(n + 1, 0));
      for (var i = 1; i <= m; i++) {
        for (var j = 1; j <= n; j++) {
          var best = dp[i - 1][j];
          var dir = 1; // 跳过本地第 i 集
          if (dp[i][j - 1] > best) {
            best = dp[i][j - 1];
            dir = 2; // 跳过 TMDB 第 j 集
          }
          final sim = simMatrix[i - 1][j - 1];
          if (sim >= _alignMinSim) {
            final identityBonus =
                eps[i - 1] == seasonMainEps[j - 1].episodeNumber ? 0.01 : 0.0;
            final diag = dp[i - 1][j - 1] + sim + identityBonus;
            if (diag > best) {
              best = diag;
              dir = 3; // 配对 (i - 1, j - 1)
            }
          }
          dp[i][j] = best;
          choice[i][j] = dir;
        }
      }

      final matchedMainByIdx = <int, int>{};
      final claimedMainJ = <int>{};
      var ci = m;
      var cj = n;
      while (ci > 0 && cj > 0) {
        final dir = choice[ci][cj];
        if (dir == 3) {
          matchedMainByIdx[ci - 1] = cj - 1;
          claimedMainJ.add(cj - 1);
          ci--;
          cj--;
        } else if (dir == 1) {
          ci--;
        } else {
          cj--;
        }
      }

      // 第二阶段：对未在主季配对的本地集，优先在 TMDB Season 0 中按标题检索未放送/OVA 回，
      // 其次在未占用的主季分集中兜底处理乱序放送回。
      final matchedS0ByIdx =
          <int, ({TmdbEpisodeDetail ep, double score, bool partial})>{};
      final claimedS0 = <int>{};
      for (var i = 0; i < m; i++) {
        if (matchedMainByIdx.containsKey(i)) continue;
        TmdbEpisodeDetail? bestS0;
        var bestS0Score = 0.0;
        var bestS0Partial = false;
        for (final s0 in seasonZeroEps) {
          if (claimedS0.contains(s0.episodeNumber)) continue;
          final res = _episodeTitleSimilarity(bgmMain[i], s0);
          if (res.score >= _alignMinSim && res.score > bestS0Score) {
            bestS0Score = res.score;
            bestS0Partial = res.isPartialComposite;
            bestS0 = s0;
          }
        }
        if (bestS0 != null) {
          claimedS0.add(bestS0.episodeNumber);
          final multiSegBgm =
              _splitEpisodeSegments(bgmMain[i].nameCn).length > 1 ||
              _splitEpisodeSegments(bgmMain[i].name).length > 1;
          final singleSegS0 = _splitEpisodeSegments(bestS0.title).length <= 1;
          matchedS0ByIdx[i] = (
            ep: bestS0,
            score: bestS0Score,
            partial: bestS0Partial || (multiSegBgm && singleSegS0),
          );
          continue;
        }

        int? bestUnclaimedJ;
        var bestUnclaimedScore = 0.0;
        for (var j = 0; j < n; j++) {
          if (claimedMainJ.contains(j)) continue;
          final s = simMatrix[i][j];
          if (s >= 0.55 && s > bestUnclaimedScore) {
            bestUnclaimedScore = s;
            bestUnclaimedJ = j;
          }
        }
        if (bestUnclaimedJ != null) {
          matchedMainByIdx[i] = bestUnclaimedJ;
          claimedMainJ.add(bestUnclaimedJ);
        }
      }

      var alignedStrong = 0;
      var alignedTotal = 0.0;
      var hasDifference = false;
      for (var i = 0; i < m; i++) {
        final mainJ = matchedMainByIdx[i];
        if (mainJ != null) {
          alignedStrong++;
          alignedTotal += simMatrix[i][mainJ];
          if (seasonMainEps[mainJ].episodeNumber != eps[i] ||
              partialMatrix[i][mainJ]) {
            hasDifference = true;
          }
        } else if (matchedS0ByIdx[i] case final s0Pick?) {
          alignedStrong++;
          alignedTotal += s0Pick.score;
          hasDifference = true;
        } else if (eps[i] <= tmdbCount) {
          hasDifference = true;
        }
      }

      final accepted =
          hasDifference &&
          alignedStrong >= 3 &&
          (eps.length > seasonMainEps.length
              ? (alignedStrong > directStrong &&
                    alignedTotal >= directTotal + 1.2)
              : (eps.length == seasonMainEps.length
                    ? (directStrong * 2 < eps.length &&
                          alignedStrong >= (eps.length * 0.65).ceil() &&
                          alignedTotal >= directTotal + 2.5)
                    : (alignedStrong > directStrong &&
                          alignedTotal >= directTotal + 1.5)));
      if (!accepted) continue;

      for (var i = 0; i < m; i++) {
        final slotKey = '$season:${eps[i]}';
        final mainJ = matchedMainByIdx[i];
        if (mainJ != null) {
          overrides[slotKey] = EpisodeMetadataOverride(
            tmdbSeasonNumber: season,
            tmdbEpisodeNumber: seasonMainEps[mainJ].episodeNumber,
            preferBangumiTitle: partialMatrix[i][mainJ],
          );
        } else if (matchedS0ByIdx[i] case final s0Pick?) {
          overrides[slotKey] = EpisodeMetadataOverride(
            tmdbSeasonNumber: 0,
            tmdbEpisodeNumber: s0Pick.ep.episodeNumber,
            preferBangumiTitle: s0Pick.partial,
          );
        } else {
          overrides[slotKey] = const EpisodeMetadataOverride(
            preferBangumiTitle: true,
          );
        }
      }
    }

    return (hasCandidate: hasCandidate, metadataOverrides: overrides);
  }

  static ({double score, bool isPartialComposite}) _episodeTitleSimilarity(
    BangumiEpisodeEntry bgm,
    TmdbEpisodeDetail tmdb,
  ) {
    final tmdbTitle = tmdb.title.trim();
    if (tmdbTitle.isEmpty) {
      return (score: 0.0, isPartialComposite: false);
    }
    final tmdbSegs = _splitEpisodeSegments(tmdbTitle);
    final candidates = <String>[
      if (bgm.nameCn.trim().isNotEmpty) bgm.nameCn.trim(),
      if (bgm.name.trim().isNotEmpty) bgm.name.trim(),
    ];
    if (candidates.isEmpty) {
      return (score: 0.0, isPartialComposite: false);
    }

    var bestScore = 0.0;
    var bestPartial = false;
    for (final rawBgm in candidates) {
      final bgmSegs = _splitEpisodeSegments(rawBgm);
      final fullSim = _singleEpisodeTitleSim(rawBgm, tmdbTitle);
      var candScore = fullSim;
      var candPartial = false;

      if (bgmSegs.length > 1 || tmdbSegs.length > 1) {
        var matchedPairs = 0;
        var sumMatched = 0.0;
        var maxSegSim = 0.0;
        final usedTmdb = <int>{};
        for (final bs in bgmSegs) {
          var bestIdx = -1;
          var bestS = 0.0;
          for (var ti = 0; ti < tmdbSegs.length; ti++) {
            if (usedTmdb.contains(ti)) continue;
            final s = _singleEpisodeTitleSim(bs, tmdbSegs[ti]);
            if (s > bestS) {
              bestS = s;
              bestIdx = ti;
            }
          }
          if (bestS > maxSegSim) maxSegSim = bestS;
          if (bestIdx >= 0 && bestS >= 0.55) {
            usedTmdb.add(bestIdx);
            matchedPairs++;
            sumMatched += bestS;
          }
        }
        final fullPairCount = bgmSegs.length > tmdbSegs.length
            ? bgmSegs.length
            : tmdbSegs.length;
        if (matchedPairs == fullPairCount && fullPairCount > 0) {
          final avg = sumMatched / matchedPairs;
          if (avg > candScore) candScore = avg;
          candPartial = false;
        } else if (matchedPairs >= 1 && maxSegSim >= 0.65) {
          final partialScore = maxSegSim * 0.85;
          if (partialScore >= candScore) {
            candScore = partialScore;
            candPartial = true;
          }
        }
      }

      if (candScore > bestScore) {
        bestScore = candScore;
        bestPartial = candPartial;
      }
    }

    // 播出日期精确吻合时仅作温和加分，不能脱离标题相似性单独生效。
    if (bestScore >= 0.45) {
      final bgmDate = _parseAirDate(bgm.airDate);
      final tmdbDate = _parseAirDate(tmdb.airDate);
      if (bgmDate != null &&
          tmdbDate != null &&
          bgmDate.difference(tmdbDate).inDays.abs() <= 2) {
        bestScore = (bestScore + 0.08).clamp(0.0, 1.0);
      }
    }

    return (score: bestScore, isPartialComposite: bestPartial);
  }

  static List<String> _splitEpisodeSegments(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return const [];
    final parts = trimmed
        .split(_halfEpisodeSplit)
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    return parts.isEmpty ? [trimmed] : parts;
  }

  static double _singleEpisodeTitleSim(String a, String b) {
    final na = a.toLowerCase().replaceAll(_nonWordTitle, '');
    final nb = b.toLowerCase().replaceAll(_nonWordTitle, '');
    if (na.length < 2 || nb.length < 2) return 0.0;
    if (na == nb) return 1.0;

    var score = 0.0;
    final minLen = na.length < nb.length ? na.length : nb.length;
    final maxLen = na.length > nb.length ? na.length : nb.length;
    if (minLen >= 3 && (na.contains(nb) || nb.contains(na))) {
      score = 0.78 + 0.22 * (minLen / maxLen);
    }

    final dice = _bigramDice(na, nb);
    if (dice > score) score = dice;

    if (_cjkOrKana.hasMatch(a) || _cjkOrKana.hasMatch(b)) {
      final phonetic = TitleNormalizer.romajiKanaSimilarity(a, b);
      if (phonetic > score) score = phonetic;
    }
    return score;
  }

  static double _bigramDice(String a, String b) {
    if (a.length < 2 || b.length < 2) return 0.0;
    final aCounts = <String, int>{};
    for (var i = 0; i < a.length - 1; i++) {
      final bg = a.substring(i, i + 2);
      aCounts.update(bg, (v) => v + 1, ifAbsent: () => 1);
    }
    var intersection = 0;
    for (var i = 0; i < b.length - 1; i++) {
      final bg = b.substring(i, i + 2);
      final remain = aCounts[bg] ?? 0;
      if (remain > 0) {
        intersection++;
        aCounts[bg] = remain - 1;
      }
    }
    final total = (a.length - 1) + (b.length - 1);
    return total == 0 ? 0.0 : (2.0 * intersection) / total;
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
