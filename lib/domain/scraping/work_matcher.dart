import 'directory_analyzer.dart';
import 'title_normalizer.dart';
part 'work_matcher_models.dart';

/// 确定性多信号作品匹配打分器：全部特征权重集中定义于此，
/// 便于单点调参并通过离线基准测试集统一验证精度。
abstract final class WorkMatcher {
  static const _highScore = 70.0, _mediumScore = 50.0;
  static const _highMargin = 15.0, _mediumMargin = 8.0;

  static final _movieWord = RegExp(
    r'剧场版|劇場版|映画|gekijou?ban|movie|film',
    caseSensitive: false,
  );

  static final _sequelOrSpinoffSuffix = RegExp(
    r'^(?:ii|iii|iv|2|3|4|2nd|3rd|s2|s3|season2|season3|'
    r'第[234二三四](?:部分|部|季|期|クール)|part[234]|cour[234]|(?:2nd|3rd|4th)cour|'
    r'新章|shinshou|two|通|续|続|续篇|続編|後半|后半|後篇|後編|'
    r'break|burst|try|next|plus|kai|改|z|zoo|revolution|rebellion)s?$',
    caseSensitive: false,
  );

  static final _remasterPattern = RegExp(
    r'(?:HD\s*)?(?:重制版|重製版|Remaster(?:ed)?)|リマスター',
    caseSensitive: false,
  );

  static final _genericSeasonName = RegExp(
    r'^(?:season\s*\d+|series\s*\d+|specials?|第\s*[0-9一二三四五六七八九十百]+\s*[季期部]|特别篇|特典)$',
    caseSensitive: false,
  );

  static final _latinMediaCarrier = RegExp(
    r'(?<![a-z0-9])(?:oad|ova|ona|sp|specials?|ex\d{0,2}|the\s+movie|movie|tv|bd|dvd|rip)(?![a-z0-9])',
    caseSensitive: false,
  );

  static final _exTagPattern = RegExp(
    r'(?<![a-z0-9])ex(?:\d{1,2})?(?![a-z0-9])',
    caseSensitive: false,
  );

  static final _cjkPattern = RegExp(r'[\u3040-\u9fff]');

  /// 生成罗马音篇章名与中文/日文篇章后缀之间的双向扩展查询候选。
  /// (e.g. "Danganronpa 3 - Mirai Hen" <-> "Danganronpa 3 未来篇").
  static List<String> expandRomajiArcQueries(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return const [];
    final out = <String>[];
    final seen = <String>{trimmed.toLowerCase()};
    void add(String candidate) {
      final clean = candidate.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (clean.isEmpty) return;
      if (seen.add(clean.toLowerCase())) out.add(clean);
    }

    for (final (romaji, queryArc, cjkNorms) in _romajiArcBridges) {
      final stem = romaji.endsWith('hen')
          ? romaji.substring(0, romaji.length - 3)
          : '';
      final romajiRegex = _romajiArcPattern(romaji, stem);
      if (romajiRegex.hasMatch(trimmed)) {
        add(trimmed.replaceAll(romajiRegex, ' $queryArc '));
        add(queryArc);
      }
      for (final cjk in cjkNorms) {
        if (trimmed.contains(cjk)) {
          final spacedRomaji = stem.isNotEmpty
              ? '${stem[0].toUpperCase()}${stem.substring(1)} Hen'
              : romaji;
          add(trimmed.replaceAll(cjk, ' $spacedRomaji '));
        }
      }
    }
    return out;
  }

  static RegExp _romajiArcPattern(String romaji, String stem) =>
      stem.isNotEmpty
      ? RegExp(
          '(?<![a-z0-9])${RegExp.escape(stem)}[\\s\\-]*hen(?![a-z0-9])',
          caseSensitive: false,
        )
      : RegExp(
          '(?<![a-z0-9])${RegExp.escape(romaji)}(?![a-z0-9])',
          caseSensitive: false,
        );

  /// 提取与 `[raw]` 中罗马音篇章词汇相对应的规范中日文篇章后缀（如 `未来篇`、`未来編`）。
  /// 提升带有罗马音副标题资源的线上检索命中率。
  static List<String> romajiArcSuffixesFor(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return const [];
    final out = <String>{};
    for (final (romaji, queryArc, cjkNorms) in _romajiArcBridges) {
      final stem = romaji.endsWith('hen')
          ? romaji.substring(0, romaji.length - 3)
          : '';
      if (_romajiArcPattern(romaji, stem).hasMatch(trimmed)) {
        out.add(queryArc);
        out.addAll(cjkNorms);
      }
    }
    return out.toList();
  }

  static String _canonCjk(String value) {
    if (value.isEmpty) return value;
    final buf = StringBuffer();
    for (var i = 0; i < value.length; i++) {
      final ch = value[i];
      buf.write(_cjkCanonMap[ch] ?? ch);
    }
    return buf.toString();
  }

  static List<String> _expandNormArcs(String norm) {
    final canon = _canonCjk(norm);
    final out = <String>{norm, canon};
    for (final (romaji, _, cjkNorms) in _romajiArcBridges) {
      if (canon.contains(romaji)) {
        for (final cjk in cjkNorms) {
          out.add(canon.replaceAll(romaji, _canonCjk(cjk)));
        }
      }
      for (final cjk in cjkNorms) {
        final cc = _canonCjk(cjk);
        if (canon.contains(cc)) {
          out.add(canon.replaceAll(cc, romaji));
        }
      }
    }
    return out.toList();
  }

  static String? _romanArabicVariant(String raw, String norm) {
    const romanMap = <String, String>{
      'Ⅰ': '1',
      'Ⅱ': '2',
      'Ⅲ': '3',
      'Ⅳ': '4',
      'Ⅴ': '5',
      'Ⅵ': '6',
      'Ⅶ': '7',
      'Ⅷ': '8',
      'Ⅸ': '9',
      'Ⅹ': '10',
      'ⅰ': '1',
      'ⅱ': '2',
      'ⅲ': '3',
      'ⅳ': '4',
      'ⅴ': '5',
      'ⅵ': '6',
      'ⅶ': '7',
      'ⅷ': '8',
      'ⅸ': '9',
      'ⅹ': '10',
    };
    const asciiRomanMap = <String, String>{
      'i': '1',
      'ii': '2',
      'iii': '3',
      'iv': '4',
      'v': '5',
      'vi': '6',
      'vii': '7',
      'viii': '8',
      'ix': '9',
      'x': '10',
    };
    var replaced = raw;
    var changed = false;
    romanMap.forEach((k, v) {
      if (replaced.contains(k)) {
        replaced = replaced.replaceAll(k, ' $v ');
        changed = true;
      }
    });
    replaced = replaced.replaceAllMapped(
      RegExp(
        r'(?:^|(?<=[\s\u3040-\u9fff\-:：]))(II|III|IV|VI{0,3}|IX|V|X)(?=$|[\s\u3040-\u9fff\-:：])',
      ),
      (m) {
        final mapped = asciiRomanMap[m.group(1)!.toLowerCase()];
        if (mapped == null) return m.group(0)!;
        changed = true;
        return ' $mapped ';
      },
    );
    if (!changed) return null;
    final out = DirectoryAnalyzer.normalize(replaced);
    return out.isNotEmpty && out != norm ? out : null;
  }

  static List<String> _significantLatinTokens(String raw) {
    final cleaned = raw
        .replaceAll(RegExp(r'\{[^}]*\}'), ' ')
        .replaceAll(RegExp(r'\(\s*(?:19|20)\d{2}\s*\)'), ' ')
        .replaceAll(_latinMediaCarrier, ' ')
        .toLowerCase();
    final out = <String>[];
    final seen = <String>{};
    for (final tok in cleaned.split(RegExp(r'[^a-z0-9]+'))) {
      if (tok.length < 3) continue;
      if (RegExp(r'^\d+$').hasMatch(tok)) continue;
      if (_latinStopwords.contains(tok)) continue;
      if (seen.add(tok)) out.add(tok);
    }
    return out;
  }

  static Set<String> _rawLatinTokens(String raw) => {
    for (final t in raw.toLowerCase().split(RegExp(r'[^a-z0-9]+')))
      if (t.length >= 2) t,
  };

  static bool _latinMatchesToken(
    String candCompact,
    Set<String> candTokens,
    String token,
  ) {
    if (candTokens.contains(token) || candCompact.contains(token)) return true;
    if (token.length >= 6) {
      final stem = token.substring(0, 5);
      if (candCompact.contains(stem)) return true;
    }
    for (final ct in candTokens) {
      if (ct.length >= 5 && token.startsWith(ct)) return true;
    }
    return false;
  }

  static bool _hasSharedCjk(String a, String b) {
    final ac = _canonCjk(a).replaceAll(RegExp(r'[^\u3040-\u9fff]'), '');
    final bc = _canonCjk(b).replaceAll(RegExp(r'[^\u3040-\u9fff]'), '');
    if (ac.length < 2 || bc.length < 2) return false;
    final grams = <String>{};
    for (var i = 0; i < ac.length - 1; i++) {
      grams.add(ac.substring(i, i + 2));
    }
    for (var i = 0; i < bc.length - 1; i++) {
      if (grams.contains(bc.substring(i, i + 2))) return true;
    }
    return false;
  }

  static bool _inventoryHasExTag(DirectoryInventory inventory) =>
      _exTagPattern.hasMatch(inventory.title) ||
      inventory.titleHints.any(_exTagPattern.hasMatch);

  static int? _installmentSlotNumber(Iterable<String> texts) {
    final slots = <int>{};
    final exStageRe = RegExp(
      r'(?:^|[\s:：._\-/\[(\【])(?:ex|stage)[\s:：._\-#]*0*([1-9])(?![0-9])',
      caseSensitive: false,
    );
    final altWordRe = RegExp(
      r'(?:alternative|オルタナティブ|アルタネイティヴ)[\s:：._-]*(one|1|Ⅰ|two|2|Ⅱ)(?![a-z0-9])',
      caseSensitive: false,
    );
    for (final raw in texts) {
      if (raw.trim().isEmpty) continue;
      final cleaned = raw
          .replaceAll(RegExp(r'\{[^}]*\}'), ' ')
          .replaceAll(RegExp(r'\(\s*(?:19|20)\d{2}\s*\)'), ' ');
      for (final m in exStageRe.allMatches(cleaned)) {
        final n = int.tryParse(m.group(1)!);
        if (n != null) slots.add(n);
      }
      for (final m in altWordRe.allMatches(cleaned)) {
        final token = m.group(1)!.toLowerCase();
        if (token == 'one' || token == '1' || token == 'Ⅰ') {
          slots.add(1);
        } else if (token == 'two' || token == '2' || token == 'Ⅱ') {
          slots.add(2);
        }
      }
    }
    return slots.length == 1 ? slots.single : null;
  }

  static int? _explicitSequelNumber(String raw) {
    final cleaned = raw
        .replaceAll(RegExp(r'\{[^}]*\}'), ' ')
        .replaceAll(RegExp(r'\(\s*(?:19|20)\d{2}\s*\)'), ' ')
        .replaceAll(RegExp(r'（\s*(?:19|20)\d{2}\s*）'), ' ')
        .replaceAll(RegExp(r'\[[^\]]*\]'), ' ')
        .replaceAll(RegExp(r'\b\d+\.\d+\b'), ' ')
        .replaceAll(RegExp(r'\bs\d{1,2}e\d{1,3}\b', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'\bex\d{1,2}\b', caseSensitive: false), ' ')
        .trim();
    if (cleaned.isEmpty) return null;

    final cleanedTitle = cleaned
        .replaceAll(RegExp(r'第\s*[2-9]\s*季'), ' ')
        .replaceAll(
          RegExp(r'(?:^|[\s\-:：])(?:season|s)\s*0*[1-9](?![0-9a-z])', caseSensitive: false),
          ' ',
        )
        .trim();
    if (cleanedTitle.isEmpty) return null;

    final zhPart = RegExp(
      r'第\s*([2-9])\s*(?:部分|部|幕|期|クール)',
    ).firstMatch(cleanedTitle);
    if (zhPart != null) return int.tryParse(zhPart.group(1)!);

    final enPart = RegExp(
      r'(?:^|[\s:：\-～~])(?:part\s*([2-9])|cour\s*([2-9])|([2-9])(?:nd|rd|th)?\s*cour)(?=[\s:：\-～~]|$)',
      caseSensitive: false,
    ).firstMatch(cleanedTitle);
    if (enPart != null) {
      return int.tryParse(enPart.group(1) ?? enPart.group(2) ?? enPart.group(3)!);
    }

    if (RegExp(r'(?:^|[\s\-–—])(?:後半|后半)$').hasMatch(cleanedTitle)) {
      return 2;
    }

    const romanMap = <String, int>{
      'Ⅱ': 2,
      'Ⅲ': 3,
      'Ⅳ': 4,
      'Ⅴ': 5,
      'II': 2,
      'III': 3,
      'IV': 4,
      'V': 5,
    };
    final romanMatch = RegExp(
      r'(?:^|[\s:：\-～~])(Ⅱ|Ⅲ|Ⅳ|Ⅴ|II|III|IV|V)(?=[\s:：\-～~]|$)',
    ).firstMatch(cleanedTitle);
    if (romanMatch != null) {
      final n = romanMap[romanMatch.group(1)!];
      if (n != null) return n;
    }

    final split = DirectoryAnalyzer.splitSeasonSuffix(
      cleanedTitle,
      isSeries: true,
    );
    if (split.season != null && split.season! >= 2 && split.season! <= 9) {
      return split.season;
    }

    final cjkDigit = RegExp(
      r'(?<=[\u3040-\u9fff])([2-9])(?=$|[\s:：\-～~]|[^\d.a-zA-Z年月日话集枚人名点倍回章卷季期%])',
    ).firstMatch(cleanedTitle);
    if (cjkDigit != null) return int.tryParse(cjkDigit.group(1)!);

    const excludedPreWords = <String>{
      'ep',
      'episode',
      'ex',
      'sp',
      'ova',
      'oad',
      'cm',
      'pv',
      'menu',
      'ncop',
      'nced',
      'track',
      'disc',
      'cd',
      'stage',
      'part',
      'vol',
      'alternative',
    };
    for (final m in RegExp(
      r'([a-z]{3,})\s+([2-9])(?![a-z0-9.])(?=$|\s*[-:：～~]|\s+[\u3040-\u9fffA-Za-z])',
      caseSensitive: false,
    ).allMatches(cleanedTitle)) {
      if (!excludedPreWords.contains(m.group(1)!.toLowerCase())) {
        return int.tryParse(m.group(2)!);
      }
    }
    return null;
  }

  static int? _inventorySequelNumber(DirectoryInventory inventory) {
    final direct = _explicitSequelNumber(inventory.title);
    if (direct != null) return direct;
    for (final hint in inventory.titleHints) {
      final n = _explicitSequelNumber(hint);
      if (n != null) return n;
    }
    return null;
  }

  static bool _namesHaveSequelNumber(int seq, Iterable<String> names) {
    const romanByNum = <int, List<String>>{
      2: ['Ⅱ', 'II'],
      3: ['Ⅲ', 'III'],
      4: ['Ⅳ', 'IV'],
      5: ['Ⅴ', 'V'],
    };
    const zhByNum = <int, String>{
      2: '二|两',
      3: '三',
      4: '四',
      5: '五',
      6: '六',
      7: '七',
      8: '八',
      9: '九',
    };
    final digitRe = RegExp('(?<![\\d.])$seq(?![\\d.])');
    final romans = romanByNum[seq] ?? const [];
    final romanRe = romans.isEmpty
        ? null
        : RegExp(
            '(?:^|[\\s:：\\-～~\\u3040-\\u9fff])'
            '(?:${romans.map(RegExp.escape).join('|')})'
            r'(?=[\s:：\-～~\u3040-\u9fff]|$)',
          );
    final zh = zhByNum[seq];
    final zhRe = zh == null ? null : RegExp('第?(?:$zh)(?:季|部|幕|期)');

    for (final raw in names) {
      if (raw.trim().isEmpty) continue;
      if (digitRe.hasMatch(raw)) return true;
      if (romanRe != null && romanRe.hasMatch(raw)) return true;
      if (zhRe != null && zhRe.hasMatch(raw)) return true;
    }
    return false;
  }

  static bool _candidateHasExTag(MatchCandidate candidate) =>
      _exTagPattern.hasMatch(candidate.title) ||
      candidate.aliases.any(_exTagPattern.hasMatch);

  static bool _candidateHasSharedCjkWithInventory(
    DirectoryInventory inventory,
    MatchCandidate candidate,
  ) {
    final invAll = '${inventory.title} ${inventory.titleHints.join(' ')}';
    if (!_cjkPattern.hasMatch(invAll)) return false;
    final candAll = '${candidate.title} ${candidate.aliases.join(' ')}';
    return _hasSharedCjk(invAll, candAll);
  }

  static bool _candidateSharesRomajiArcCjk(
    DirectoryInventory inventory,
    MatchCandidate candidate,
  ) {
    final candCanon = _canonCjk(
      '${candidate.title} ${candidate.aliases.join(' ')}',
    );
    for (final raw in [inventory.title, ...inventory.titleHints]) {
      for (final arc in romajiArcSuffixesFor(raw)) {
        if (candCanon.contains(_canonCjk(arc))) return true;
      }
    }
    return false;
  }

  static final List<String> _canonCjkArcSuffixes = List<String>.unmodifiable(() {
    final out = <String>{
      for (final (_, queryArc, cjkNorms) in _romajiArcBridges) ...[
        _canonCjk(queryArc),
        for (final c in cjkNorms) _canonCjk(c),
      ],
    }.toList()..sort((a, b) => b.length.compareTo(a.length));
    return out;
  }());

  static final List<String> _allArcSuffixes = List<String>.unmodifiable(() {
    final out = <String>{
      ..._canonCjkArcSuffixes,
      for (final (romaji, _, _) in _romajiArcBridges) romaji,
    }.toList()..sort((a, b) => b.length.compareTo(a.length));
    return out;
  }());

  static String? _extractTrailingCanonArc(String normOrCanon) {
    final canon = _canonCjk(normOrCanon);
    for (final arc in _canonCjkArcSuffixes) {
      if (canon.endsWith(arc)) return arc;
    }
    return null;
  }

  static bool _hasRemasterTag(String value) => _remasterPattern.hasMatch(value);

  static bool _hasRemasterInInventory(DirectoryInventory inventory) =>
      _hasRemasterTag(inventory.title) ||
      inventory.titleHints.any(_hasRemasterTag);

  static bool _hasRemasterInCandidate(MatchCandidate candidate) =>
      _hasRemasterTag(candidate.title) ||
      candidate.aliases.any(_hasRemasterTag);

  static String _stripRemaster(String value) => value
      .replaceAll(_remasterPattern, ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static MatchResult bangumi(
    DirectoryInventory inventory,
    List<MatchCandidate> candidates,
  ) {
    if (inventory.shape == WorkShape.empty) return MatchResult.empty;
    final localIsRemaster = _hasRemasterInInventory(inventory);
    final localIsEx =
        _inventoryHasExTag(inventory) &&
        (inventory.shape == WorkShape.feature || inventory.episodeCount <= 4);
    final invSeq = _inventorySequelNumber(inventory);
    final primaryLatinTokens = _significantLatinTokens(inventory.title);
    final invHasCjk = _cjkPattern.hasMatch(inventory.title);
    final ranking = <ScoredCandidate>[];
    for (final candidate in candidates) {
      final scored = ScoredCandidate(candidate);
      if (inventory.bangumiId != null) {
        scored.add(inventory.bangumiId == candidate.id ? 60 : -60, 'marker');
      }
      final titleSim = _title(inventory, candidate);
      scored.add(45 * titleSim, 'title');
      if (primaryLatinTokens.length >= 2 &&
          !invHasCjk &&
          !_candidateHasSharedCjkWithInventory(inventory, candidate) &&
          !_candidateSharesRomajiArcCjk(inventory, candidate) &&
          _coveredLatinTokens(primaryLatinTokens, candidate) < 2) {
        scored.add(-18, 'partial latin token match');
      }
      if (localIsRemaster && _hasRemasterInCandidate(candidate)) {
        scored.add(10, 'remaster match');
      }
      if (titleSim < 0.9) {
        scored.add(
          _subtitleConflictPenalty(inventory, candidate),
          'conflicting subtitle',
        );
      }
      _year(scored, inventory.year, candidate.year);
      if (inventory.shape == WorkShape.series &&
          candidate.seasons.isNotEmpty &&
          inventory.episodeCount > 0) {
        final remoteEps = candidate.seasons.first.count;
        final localEps = inventory.episodeCount;
        if (remoteEps > 0) {
          if (remoteEps == localEps) {
            scored.add(8, 'episode count');
          } else if ((remoteEps - localEps).abs() == 1 && localEps >= 6) {
            scored.add(4, 'episode count ~');
          } else if (localEps >= 6 &&
              (remoteEps - localEps).abs() >= 8 &&
              remoteEps != localEps * 2) {
            scored.add(-8, 'episode count mismatch');
          } else if (localEps <= 4 &&
              remoteEps >= 11 &&
              _hasConflictingCjkTitle(inventory.title, candidate.title)) {
            scored.add(-18, 'short ova vs long tv');
          }
        }
      } else if (inventory.shape == WorkShape.feature &&
          candidate.seasons.isNotEmpty &&
          inventory.featureCount > 0) {
        final remoteEps = candidate.seasons.first.count;
        if (remoteEps > 0) {
          if (remoteEps == inventory.featureCount) {
            scored.add(6, 'feature episode count');
          } else if (inventory.featureCount == 1 && remoteEps == 2) {
            scored.add(4, 'ova pair count');
          } else if (inventory.featureCount == 1 &&
              remoteEps >= 11 &&
              (inventory.folderMovieMarker ||
                  inventory.fileMovieMarker ||
                  _hasConflictingCjkTitle(inventory.title, candidate.title))) {
            scored.add(-12, 'feature vs long tv');
          }
        }
      }
      final names = [candidate.title, ...candidate.aliases];
      final localInst = _installmentSlotNumber([
        inventory.title,
        ...inventory.titleHints,
      ]);
      final candInst = _installmentSlotNumber(names);
      if (localInst != null && candInst != null) {
        if (localInst == candInst) {
          scored.add(8, 'installment slot $localInst');
        } else {
          scored.add(-28, 'installment slot conflict $localInst vs $candInst');
        }
      }
      if (localIsEx &&
          !_candidateHasExTag(candidate) &&
          !(localInst != null && localInst == candInst)) {
        final remoteEps =
            candidate.seasons.isEmpty ? 0 : candidate.seasons.first.count;
        final localEps = inventory.shape == WorkShape.feature
            ? inventory.featureCount
            : inventory.episodeCount;
        if (localEps <= 3 && remoteEps >= 4) {
          scored.add(-24, 'short ex vs multi-ep non-ex');
        } else {
          scored.add(-12, 'missing ex marker');
        }
      }
      if (inventory.season != null &&
          inventory.season! > 1 &&
          titleSim < 0.92 &&
          !_candidateHasSequelSignal(inventory, names)) {
        scored.add(-16, 'base entry vs sequel');
      }
      if (invSeq != null &&
          inventory.bangumiId != candidate.id &&
          !_namesHaveSequelNumber(invSeq, names)) {
        scored.add(-32, 'missing sequel number $invSeq');
      }
      if (invSeq == null &&
          (inventory.season == null || inventory.season! <= 1) &&
          inventory.bangumiId != candidate.id) {
        final candSeq = _explicitSequelNumber(candidate.title);
        final localNorm = DirectoryAnalyzer.normalize(inventory.title);
        final candNorm = DirectoryAnalyzer.normalize(candidate.title);
        if (candSeq != null && candSeq >= 2 && localNorm != candNorm) {
          scored.add(-24, 'unrequested sequel/part $candSeq');
        }
        if (inventory.episodes.contains(1) &&
            candidate.firstEpisodeSort != null &&
            candidate.firstEpisodeSort! > 1.5) {
          scored.add(
            -26,
            'episodes start after ep 1 (sort=${candidate.firstEpisodeSort})',
          );
        }
      }
      if (inventory.folderMovieMarker && !names.any(_movieWord.hasMatch)) {
        scored.add(-30, 'folder says movie');
      }
      if (inventory.shape == WorkShape.anthology) {
        scored.add(-40, 'anthology');
      }
      ranking.add(scored);
    }
    // Bangumi 条目体系无嵌套季度树，此处直接综合片名、年份及话数信号评分决策。
    final baseDecision = _decide(ranking, high: 45, medium: 36);
    if (baseDecision.tier != MatchTier.high) {
      final multiPart = _resolveBangumiMultiPartTie(inventory, ranking);
      if (multiPart != null) return multiPart;
      if (baseDecision.tier == MatchTier.medium &&
          inventory.year == null &&
          ranking.isNotEmpty) {
        final top = ranking.first;
        final margin = ranking.length < 2
            ? double.infinity
            : top.score - ranking[1].score;
        if (top.score >= 44.5 &&
            margin >= 12.0 &&
            DirectoryAnalyzer.normalize(inventory.title) ==
                DirectoryAnalyzer.normalize(top.candidate.title)) {
          return MatchResult(MatchTier.high, ranking);
        }
      }
    }
    return baseDecision;
  }

  static MatchResult tmdb(
    DirectoryInventory inventory,
    List<MatchCandidate> candidates, {
    MatchResult? bangumi,
    ({String key, int? season})? mappedTarget,
    bool ignoreTmdbMarker = false,
  }) {
    if (inventory.shape == WorkShape.empty) return MatchResult.empty;
    final linked = bangumi?.candidate;
    final year = inventory.year ?? linked?.year;
    // 从 Bangumi 借用的年份可能因 TV/OVA 版本发行差异存在偏差，此处采用柔和惩罚。
    final borrowed = inventory.year == null;
    final matchedBgm =
        bangumi != null && bangumi.tier != MatchTier.none ? linked : null;
    final invSeq = _inventorySequelNumber(inventory);
    final primaryLatinTokens = _significantLatinTokens(inventory.title);
    final invHasCjk = _cjkPattern.hasMatch(inventory.title);
    final ranking = <ScoredCandidate>[];
    for (final candidate in candidates) {
      final scored = ScoredCandidate(candidate);
      if (inventory.tmdbId != null && !ignoreTmdbMarker) {
        if (inventory.tmdbId == candidate.id) {
          scored.add(30, 'marker');
          if (inventory.tmdbType != null &&
              inventory.tmdbType != candidate.type) {
            scored.add(-80, 'marker type');
          }
        } else {
          scored.add(-30, 'other than marker');
        }
      }
      final isMapped =
          mappedTarget != null && mappedTarget.key == candidate.key;
      if (isMapped) {
        scored.add(20, 'bangumi-tmdb mapping');
      }
      var titleSim = _title(inventory, candidate);
      final verifiedBgm = bangumi?.tier == MatchTier.high ? linked : null;
      final parentTvSpecial =
          verifiedBgm != null &&
          _isParentTvForBangumiSpecial(inventory, candidate, verifiedBgm);
      if (titleSim < 0.85 && verifiedBgm != null) {
        final bridged = _bridgedTitle(verifiedBgm, candidate) * 0.85;
        if (bridged > titleSim) titleSim = bridged;
      }
      if (parentTvSpecial && titleSim < 0.80) {
        titleSim = 0.80;
      }
      scored.add(45 * titleSim, 'title');
      if (!parentTvSpecial &&
          primaryLatinTokens.length >= 2 &&
          !invHasCjk &&
          !_candidateHasSharedCjkWithInventory(inventory, candidate) &&
          !_candidateSharesRomajiArcCjk(inventory, candidate) &&
          _coveredLatinTokens(primaryLatinTokens, candidate) < 2) {
        scored.add(-18, 'partial latin token match');
      }
      if (candidate.type == 'movie') {
        if (!isMapped && !parentTvSpecial && titleSim < 0.9) {
          scored.add(
            _subtitleConflictPenalty(
              inventory,
              candidate,
              verifiedBangumi: verifiedBgm,
            ),
            'conflicting subtitle',
          );
        }
        _movie(scored, inventory);
        _year(scored, year, candidate.year, borrowed: borrowed);
        if (invSeq != null &&
            !(inventory.tmdbId == candidate.id && !ignoreTmdbMarker) &&
            !_namesHaveSequelNumber(invSeq, [
              candidate.title,
              ...candidate.aliases,
            ])) {
          scored.add(-35, 'missing sequel number $invSeq');
        }
      } else {
        _tv(
          scored,
          inventory,
          year,
          borrowed,
          mappedSeason: isMapped ? mappedTarget.season : null,
          verifiedBangumi: verifiedBgm,
          matchedBangumi: matchedBgm,
          parentTvSpecial: parentTvSpecial,
          titleSim: titleSim,
          ignoreTmdbMarker: ignoreTmdbMarker,
        );
        if (scored.seasonNameMatched && titleSim < 0.85) {
          scored.add(45 * (0.85 - titleSim), 'season name');
        }
        if (!isMapped &&
            !parentTvSpecial &&
            titleSim < 0.9 &&
            !scored.seasonNameMatched &&
            !scored.tmdbMarkerSeasonMatched) {
          scored.add(
            _subtitleConflictPenalty(
              inventory,
              candidate,
              verifiedBangumi: verifiedBgm,
            ),
            'conflicting subtitle',
          );
        }
      }
      if (linked != null) {
        _linked(scored, linked, parentTvSpecial: parentTvSpecial);
      }
      if (candidate.genreIds.isNotEmpty && !candidate.genreIds.contains(16)) {
        scored.add(-35, 'non-animation genre');
      }
      ranking.add(scored);
    }
    final decision = _decide(ranking);
    if (decision.tier == MatchTier.medium &&
        year == null &&
        ranking.isNotEmpty &&
        inventory.shape != WorkShape.anthology) {
      final top = ranking.first;
      final margin = ranking.length < 2
          ? double.infinity
          : top.score - ranking[1].score;
      var cumulativeWithoutYear = false;
      if (top.candidate.type == 'tv' &&
          top.season != null &&
          top.season! > 0 &&
          inventory.episodes.isNotEmpty) {
        final matchedSeason = top.candidate.seasons
            .where((s) => s.number == top.season)
            .firstOrNull;
        final maxEp = inventory.episodes.reduce((a, b) => a > b ? a : b);
        if (matchedSeason != null &&
            matchedSeason.count > 0 &&
            maxEp > matchedSeason.count) {
          cumulativeWithoutYear = true;
        }
      }
      if (!cumulativeWithoutYear && top.score >= 59.5 && margin >= 20.0) {
        return MatchResult(MatchTier.high, ranking);
      }
    }
    return decision;
  }

  static void _movie(ScoredCandidate scored, DirectoryInventory inventory) {
    switch (inventory.shape) {
      case WorkShape.feature:
        scored.add(inventory.featureCount == 1 ? 15 : 5, 'feature');
        if (inventory.folderMovieMarker) {
          scored.add(5, 'folder says movie');
        } else if (inventory.fileMovieMarker) {
          scored.add(5, 'file says movie');
        }
      case WorkShape.series:
        // 少数显式短集数区间（例如 `IGLOO S03E01-03`）在 TMDB 下仍可能对应电影条目。
        scored.add(inventory.episodeCount <= 3 ? -5 : -35, 'series vs movie');
      case WorkShape.anthology:
        scored.add(-80, 'anthology');
      case WorkShape.empty:
        break;
    }
  }

  static void _tv(
    ScoredCandidate scored,
    DirectoryInventory inventory,
    int? year,
    bool borrowed, {
    int? mappedSeason,
    MatchCandidate? verifiedBangumi,
    MatchCandidate? matchedBangumi,
    bool parentTvSpecial = false,
    double titleSim = 0,
    bool ignoreTmdbMarker = false,
  }) {
    final candidate = scored.candidate;
    final regular = candidate.seasons.where((s) => s.number > 0).toList();
    final specials = candidate.seasons.where((s) => s.number == 0).toList();
    final episodes = inventory.episodeCount;
    final local = inventory.shape == WorkShape.series
        ? episodes
        : inventory.featureCount;
    int? yearOf = candidate.year;
    final bridgedSpecial =
        parentTvSpecial ||
        (verifiedBangumi != null &&
            !inventory.folderMovieMarker &&
            (_bridgedTitle(verifiedBangumi, candidate) >= 0.60 ||
                (specials.isNotEmpty &&
                    specials.first.count >= local &&
                    _hasSharedCjk(verifiedBangumi.title, candidate.title) &&
                    candidate.seasons.any(
                      (s) =>
                          s.number >= 2 &&
                          s.year != null &&
                          verifiedBangumi.year != null &&
                          (s.year! - verifiedBangumi.year!).abs() <= 1,
                    ))));
    final localIsRemaster =
        _hasRemasterInInventory(inventory) ||
        (matchedBangumi != null && _hasRemasterInCandidate(matchedBangumi));

    if (inventory.shape == WorkShape.anthology) {
      scored.add(-40, 'anthology');
    }
    if (inventory.shape == WorkShape.series) {
      final epsSet = inventory.episodes;
      final minEp = epsSet.isEmpty
          ? null
          : epsSet.reduce((a, b) => a < b ? a : b);
      final maxEp = epsSet.isEmpty
          ? null
          : epsSet.reduce((a, b) => a > b ? a : b);
      if (!parentTvSpecial &&
          inventory.season != 0 &&
          !(matchedBangumi?.isSpecialFormat ?? false) &&
          episodes <= 4 &&
          regular.isNotEmpty &&
          regular.every((s) => s.count >= 11) &&
          _hasConflictingCjkTitle(inventory.title, candidate.title)) {
        scored.add(-18, 'short ova vs long tv');
      }
      final seasonPick = _season(
        inventory,
        candidate,
        regular,
        year,
        mappedSeason: mappedSeason,
        linkedBangumi: matchedBangumi,
        localIsRemaster: localIsRemaster,
        ignoreTmdbMarker: ignoreTmdbMarker,
      );
      final maxSpecialEps = inventory.season == 0
          ? (specials.isNotEmpty ? specials.first.count : 0)
          : ((mappedSeason == 0 || (matchedBangumi?.isSpecialFormat ?? false))
                ? 12
                : 4);
      final allowSpecialSeason =
          inventory.season == 0 ||
          mappedSeason == 0 ||
          parentTvSpecial ||
          (bridgedSpecial &&
              DirectoryAnalyzer.normalize(inventory.title).length >=
                  DirectoryAnalyzer.normalize(candidate.title).length + 2);
      final sortedRegular = [...regular]
        ..sort((a, b) => a.number.compareTo(b.number));
      if (seasonPick != null) {
        final season = seasonPick.season;
        scored.season = season.number;
        scored.cumulativeOffsetMatched = seasonPick.cumulativeOffset;
        scored.seasonNameMatched = seasonPick.nameMatched;
        scored.tmdbMarkerSeasonMatched = seasonPick.tmdbMarkerMatched;
        yearOf = season.year ?? yearOf;
        scored.add(season.count == episodes ? 15 : 8, 'season count');
        if (seasonPick.cumulativeOffset) {
          scored.add(6, 'cumulative offset');
        }
      } else if (episodes > 0 &&
          episodes <= maxSpecialEps &&
          specials.isNotEmpty &&
          specials.first.count >= episodes &&
          allowSpecialSeason) {
        final s0 = specials.first;
        scored.season = 0;
        yearOf = s0.year ?? yearOf;
        scored.add(
          parentTvSpecial || inventory.season == 0 ? 12 : 10,
          'special season',
        );
      } else if (regular.isNotEmpty &&
          (regular.fold<int>(0, (n, s) => n + s.count) == episodes ||
              (minEp == 1 &&
                  sortedRegular.length >= 2 &&
                  _matchesConsecutivePrefixSum(sortedRegular, episodes)))) {
        scored.add(15, 'all seasons count');
      } else if (regular.isEmpty) {
        scored.add(episodes >= 10 ? 10 : 5, 'series');
      } else if (regular.any((s) => s.count >= episodes) || episodes > 30) {
        scored.add(5, 'series');
      }

      if (!scored.cumulativeOffsetMatched && minEp != null && minEp > 1 && maxEp != null) {
        final totalRegular = regular.fold<int>(0, (n, s) => n + s.count);
        if (regular.length == 1 &&
            totalRegular > 0 &&
            (minEp > 2 ? totalRegular < maxEp : totalRegular < maxEp - 1)) {
          scored.add(-16, 'incomplete season vs offset');
        } else if (regular.length > 1 &&
            seasonPick == null &&
            totalRegular > 0 &&
            totalRegular < maxEp - 1) {
          scored.add(-12, 'insufficient seasons vs offset');
        }
      }
    } else if (inventory.shape == WorkShape.feature) {
      if ((inventory.season == 0 || mappedSeason == 0 || parentTvSpecial) &&
          specials.isNotEmpty) {
        final s0 = specials.first;
        scored.season = 0;
        yearOf = s0.year ?? yearOf;
        scored.add(12, 'mapped special season');
      } else {
        // 特别篇或 OVA 合集可能挂在 TMDB 第 0 季或独立短季下方。
        final small = [...specials, ...regular.where((s) => s.count <= 3)]
            .where((s) {
              final diff = _yearDiff(year, s.year);
              if (s.count < local) return false;
              if (diff <= 1 || diff == 99) return true;
              if (s.number == 0 &&
                  s.count >= 2 &&
                  bridgedSpecial &&
                  year != null &&
                  s.year != null &&
                  year >= s.year! - 1) {
                return true;
              }
              return false;
            });
        if (small.isNotEmpty) {
          final match = small.first;
          scored.season = match.number;
          yearOf = match.year ?? yearOf;
          scored.add(
            regular.isEmpty && specials.isEmpty ? 0 : 10,
            'special/short season',
          );
        } else if (inventory.folderMovieMarker || inventory.fileMovieMarker) {
          scored.add(-35, 'movie vs tv');
        } else if (candidate.seasons.isNotEmpty) {
          scored.add(-20, 'feature vs tv');
        } else {
          scored.add(-10, 'feature vs tv');
        }
      }
    }
    final localIsEx =
        _inventoryHasExTag(inventory) &&
        (inventory.shape == WorkShape.feature || episodes <= 4);
    if (localIsEx && !_candidateHasExTag(candidate)) {
      final validS0ForEx =
          scored.season == 0 &&
          (parentTvSpecial ||
              bridgedSpecial ||
              mappedSeason == 0 ||
              inventory.season == 0 ||
              scored.seasonNameMatched);
      if (!validS0ForEx) {
        scored.add(-20, 'ex special missing ex/s0');
      }
    }
    final invSeq = _inventorySequelNumber(inventory);
    if (invSeq != null &&
        !(inventory.tmdbId == candidate.id && !ignoreTmdbMarker) &&
        !_namesHaveSequelNumber(invSeq, [
          candidate.title,
          ...candidate.aliases,
        ])) {
      final chosen = scored.season;
      final chosenSeasonObj = chosen == null
          ? null
          : candidate.seasons.where((s) => s.number == chosen).firstOrNull;
      final chosenHasSeq =
          chosenSeasonObj?.name != null &&
          _namesHaveSequelNumber(invSeq, [chosenSeasonObj!.name!]);
      final mergedContinuousSequel =
          chosen == 1 &&
          regular.length == 1 &&
          regular.single.count >= episodes + 12 &&
          episodes > 0 &&
          invSeq >= 2 &&
          (year == null || yearOf == null || year >= yearOf);
      final validSequelSeason =
          (chosen != null && chosen >= 2) ||
          (chosen == 0 &&
              (parentTvSpecial ||
                  bridgedSpecial ||
                  matchedBangumi != null ||
                  scored.seasonNameMatched ||
                  chosenHasSeq)) ||
          (chosen == 1 &&
              (scored.seasonNameMatched ||
                  chosenHasSeq ||
                  mappedSeason == 1 ||
                  mergedContinuousSequel));
      if (!validSequelSeason) {
        scored.add(-35, 'missing sequel number $invSeq');
      }
    }
    final mergedContinuousSequelYear =
        scored.season == 1 &&
        regular.length == 1 &&
        regular.single.count >= episodes + 12 &&
        episodes > 0 &&
        (invSeq ?? 0) >= 2 &&
        (year == null || yearOf == null || year >= yearOf);
    if (localIsRemaster &&
        titleSim >= 0.80 &&
        year != null &&
        yearOf != null &&
        year > yearOf &&
        !_hasRemasterInCandidate(candidate)) {
      scored.add(4, 'remaster -> original year');
    } else if (inventory.season == 0 &&
        scored.season == 0 &&
        _yearDiff(year, yearOf) > 1 &&
        _yearDiff(year, candidate.year) <= 1) {
      _year(scored, year, candidate.year, borrowed: borrowed);
    } else if (scored.season == 0 &&
        bridgedSpecial &&
        (parentTvSpecial
            ? (year == null || yearOf == null || year >= yearOf - 1)
            : (year != null && yearOf != null && year > yearOf + 1))) {
      scored.add(
        _yearDiff(year, yearOf) == 0 ? 15 : 8,
        'franchise special year',
      );
    } else if (mergedContinuousSequelYear) {
      scored.add(8, 'merged single-season sequel year');
    } else {
      _year(scored, year, yearOf, borrowed: borrowed);
    }
  }

  static bool _matchesConsecutivePrefixSum(
    List<SeasonInfo> sortedRegular,
    int episodes,
  ) {
    if (episodes <= 0) return false;
    var sum = 0;
    for (var i = 0; i < sortedRegular.length; i++) {
      final c = sortedRegular[i].count;
      if (c <= 0) return false;
      sum += c;
      if (i >= 1 && sum == episodes) return true;
      if (sum > episodes) return false;
    }
    return false;
  }

  static double _seasonNameMatchScore(
    DirectoryInventory inventory,
    MatchCandidate candidate,
    SeasonInfo season, {
    MatchCandidate? linkedBangumi,
  }) {
    final rawName = season.name?.trim() ?? '';
    if (rawName.isEmpty || _genericSeasonName.hasMatch(rawName)) return 0.0;
    final sNorm = _canonCjk(DirectoryAnalyzer.normalize(rawName));
    if (sNorm.length < 2) return 0.0;
    final baseNorm = _canonCjk(
      DirectoryAnalyzer.normalize(_stripRemaster(candidate.title)),
    );
    final seasonResidual =
        baseNorm.isNotEmpty &&
            sNorm.startsWith(baseNorm) &&
            sNorm.length > baseNorm.length + 1
        ? sNorm.substring(baseNorm.length)
        : sNorm;
    final combinedNorm =
        baseNorm.isNotEmpty && !sNorm.startsWith(baseNorm)
        ? '$baseNorm$sNorm'
        : sNorm;

    final primaryNorm = _canonCjk(
      DirectoryAnalyzer.normalize(_stripRemaster(inventory.title)),
    );
    final localResidual =
        baseNorm.isNotEmpty &&
            primaryNorm.startsWith(baseNorm) &&
            primaryNorm.length >= baseNorm.length + 2
        ? primaryNorm.substring(baseNorm.length)
        : '';

    final localNorms = <String>{
      if (primaryNorm.isNotEmpty) primaryNorm,
      for (final h in inventory.titleHints)
        _canonCjk(DirectoryAnalyzer.normalize(_stripRemaster(h))),
      for (final f in inventory.fileHints.take(2))
        _canonCjk(DirectoryAnalyzer.normalize(_stripRemaster(f))),
      if (linkedBangumi != null) ...[
        _canonCjk(DirectoryAnalyzer.normalize(_stripRemaster(linkedBangumi.title))),
        for (final a in linkedBangumi.aliases.take(2))
          _canonCjk(DirectoryAnalyzer.normalize(_stripRemaster(a))),
      ],
    }..removeWhere((s) => s.isEmpty);

    final sArc = _extractTrailingCanonArc(sNorm);
    var best = 0.0;
    if (sArc != null) {
      for (final l in localNorms) {
        for (final lv in _expandNormArcs(l)) {
          if (_extractTrailingCanonArc(lv) == sArc) {
            if (best < 0.92) best = 0.92;
          }
        }
      }
    }
    if (localResidual.isNotEmpty && sNorm != baseNorm) {
      for (final lv in _expandNormArcs(localResidual)) {
        for (final sv in _expandNormArcs(seasonResidual)) {
          final sim = similarity(lv, sv);
          if (sim > best) best = sim;
        }
        for (final sv in _expandNormArcs(sNorm)) {
          final simRaw = similarity(lv, sv);
          if (simRaw > best) best = simRaw;
        }
      }
    }
    for (final local in localNorms) {
      if (sNorm == baseNorm &&
          local.length > baseNorm.length + 1 &&
          local.startsWith(baseNorm)) {
        continue;
      }
      if (local == baseNorm &&
          sNorm.length > baseNorm.length + 1 &&
          sNorm.startsWith(baseNorm)) {
        continue;
      }
      for (final lv in _expandNormArcs(local)) {
        for (final cv in _expandNormArcs(combinedNorm)) {
          final s1 = similarity(lv, cv);
          if (s1 > best) best = s1;
        }
        if (sNorm.length >= 3 || lv == sNorm) {
          for (final sv in _expandNormArcs(sNorm)) {
            final s2 = similarity(lv, sv);
            if (s2 > best) best = s2;
          }
        }
      }
    }
    return best;
  }

  static ({
    SeasonInfo season,
    bool cumulativeOffset,
    bool nameMatched,
    bool tmdbMarkerMatched,
  })?
  _season(
    DirectoryInventory inventory,
    MatchCandidate candidate,
    List<SeasonInfo> regular,
    int? year, {
    int? mappedSeason,
    MatchCandidate? linkedBangumi,
    bool localIsRemaster = false,
    bool ignoreTmdbMarker = false,
  }) {
    if (regular.isEmpty) return null;
    final rawExplicit =
        inventory.season ??
        (inventory.main.map((i) => i.season).whereType<int>().toSet().length ==
                1
            ? inventory.main.map((i) => i.season).whereType<int>().first
            : null);
    if (rawExplicit == 0) return null;
    final invSeq = _inventorySequelNumber(inventory);
    final candHasSeq =
        invSeq == null ||
        _namesHaveSequelNumber(invSeq, [
          candidate.title,
          ...candidate.aliases,
        ]);
    final explicit =
        (invSeq != null &&
            !candHasSeq &&
            rawExplicit == 1 &&
            inventory.season == null)
        ? null
        : rawExplicit;
    final localArcs = <String>{
      for (final raw in [
        inventory.title,
        ...inventory.titleHints,
        if (linkedBangumi != null) linkedBangumi.title,
      ])
        for (final lv in _expandNormArcs(
          _canonCjk(DirectoryAnalyzer.normalize(_stripRemaster(raw))),
        ))
          ?_extractTrailingCanonArc(lv),
    };
    final epsSet = inventory.episodes;
    final episodes = epsSet.length;
    final minEp = epsSet.isEmpty
        ? null
        : epsSet.reduce((a, b) => a < b ? a : b);
    final maxEp = epsSet.isEmpty
        ? null
        : epsSet.reduce((a, b) => a > b ? a : b);
    final sortedRegular = [...regular]
      ..sort((a, b) => a.number.compareTo(b.number));
    final bgmAirDate = _parseFullDate(linkedBangumi?.airDate);
    final nameScores = <int, double>{
      for (final s in sortedRegular)
        s.number: _seasonNameMatchScore(
          inventory,
          candidate,
          s,
          linkedBangumi: linkedBangumi,
        ),
    };
    final bestNameScore = nameScores.values.fold<double>(
      0.0,
      (m, v) => v > m ? v : m,
    );

    if (explicit == null &&
        mappedSeason == null &&
        minEp == 1 &&
        sortedRegular.length >= 2 &&
        bestNameScore < 0.72) {
      final allSum = sortedRegular.fold<int>(0, (n, s) => n + s.count);
      final singleExactMatch = sortedRegular.any(
        (s) =>
            s.count == episodes &&
            (_yearDiff(year, s.year) == 0 || (nameScores[s.number] ?? 0) >= 0.72),
      );
      if (!singleExactMatch &&
          ((allSum > 0 && episodes == allSum) ||
              (_matchesConsecutivePrefixSum(sortedRegular, episodes) &&
                  (year == null ||
                      _yearDiff(year, sortedRegular.first.year) <= 1)))) {
        return null;
      }
    }

    final exactBareBase =
        explicit == null &&
        mappedSeason == null &&
        year == null &&
        minEp == 1 &&
        DirectoryAnalyzer.normalize(inventory.title) ==
            DirectoryAnalyzer.normalize(candidate.title);

    SeasonInfo? best;
    var bestScore = 0, tie = false;
    var bestCumOffset = false, bestNameHit = false, bestMarkerMatched = false;
    var priorCount = 0;
    for (final season in sortedRegular) {
      final isMergedContinuousS1 =
          season.number == 1 &&
          sortedRegular.length == 1 &&
          invSeq != null &&
          invSeq >= 2 &&
          !candHasSeq &&
          episodes > 0 &&
          season.count >= episodes + 12;
      if (invSeq != null &&
          !candHasSeq &&
          season.number == 1 &&
          mappedSeason != 1 &&
          !isMergedContinuousS1) {
        final s1NameScore = nameScores[1] ?? 0.0;
        final s1HasSeq =
            season.name != null &&
            _namesHaveSequelNumber(invSeq, [season.name!]);
        if (s1NameScore < 0.72 && !s1HasSeq) {
          if (season.count > 0) priorCount += season.count;
          continue;
        }
      }
      var score = 0;
      if (mappedSeason != null) {
        score += season.number == mappedSeason ? 8 : -6;
      }
      if (explicit != null) {
        score += season.number == explicit
            ? 6
            : (isMergedContinuousS1 ? 0 : -6);
      }
      if (isMergedContinuousS1) {
        score += 6;
      }
      if (localArcs.isNotEmpty && season.name != null) {
        final sArc = _extractTrailingCanonArc(
          DirectoryAnalyzer.normalize(season.name!),
        );
        if (sArc != null && !localArcs.contains(sArc)) {
          score -= 10;
        }
      }
      if (season.count == episodes) {
        score += 3;
      } else if ((season.count - episodes).abs() <= 1) {
        score += 2;
      } else if (localIsRemaster &&
          season.count >= episodes &&
          season.count - episodes <= 4) {
        score += 2;
      }
      // 分割放送作品常沿用累计集号编码（例如第 2 季文件仍从 13 编至 24 话）。
      var cumOffset = false;
      if (priorCount > 0 &&
          minEp != null &&
          maxEp != null &&
          minEp == priorCount + 1) {
        final span = maxEp - minEp + 1;
        if (season.count > 0 && maxEp == priorCount + season.count) {
          score += 9;
          cumOffset = true;
        } else if (season.count >= span &&
            maxEp <= priorCount + season.count + 1) {
          score += 6;
          cumOffset = true;
        }
      }
      final diff = _yearDiff(year, season.year);
      if (diff == 0) {
        score += 2;
      } else if (diff >= 2 && diff < 99) {
        if (!(localIsRemaster &&
                year != null &&
                season.year != null &&
                year > season.year!) &&
            !(isMergedContinuousS1 &&
                year != null &&
                season.year != null &&
                year > season.year!)) {
          score -= 2;
        }
      }
      final markerMatched =
          !ignoreTmdbMarker &&
          inventory.tmdbId == candidate.id &&
          diff == 0 &&
          season.count == episodes;
      if (markerMatched) score += 2;

      final nScore = nameScores[season.number] ?? 0.0;
      final nameHit = nScore >= 0.72;
      if (nScore >= 0.88) {
        score += 8;
      } else if (nScore >= 0.72) {
        score += 5;
      }

      final sAirDate = _parseFullDate(season.airDate);
      if (bgmAirDate != null && sAirDate != null) {
        final days = bgmAirDate.difference(sAirDate).inDays.abs();
        if (days <= 7) {
          score += 7;
        } else if (days <= 35) {
          score += 5;
        } else if (bgmAirDate.year == sAirDate.year && days > 120) {
          score -= 2;
        }
      }

      if (exactBareBase && season.number == 1 && season.count == episodes) {
        score += 1;
      }
      if (score > bestScore) {
        best = season;
        bestScore = score;
        tie = false;
        bestCumOffset = cumOffset;
        bestNameHit = nameHit;
        bestMarkerMatched = markerMatched;
      } else if (score == bestScore && score > 0) {
        tie = true;
      }
      if (season.count > 0) priorCount += season.count;
    }
    if (tie || best == null || bestScore < 2) return null;
    return (
      season: best,
      cumulativeOffset: bestCumOffset,
      nameMatched: bestNameHit,
      tmdbMarkerMatched: bestMarkerMatched,
    );
  }

  static void _year(
    ScoredCandidate scored,
    int? local,
    int? remote, {
    bool borrowed = false,
  }) {
    final diff = _yearDiff(local, remote);
    if (diff == 99) return;
    scored.add(switch (diff) {
      0 => 15,
      1 => 4,
      2 => -5,
      3 || 4 when borrowed => -10,
      _ => -25,
    }, borrowed ? 'year (via Bangumi)' : 'year');
  }

  static int _yearDiff(int? a, int? b) =>
      a == null || b == null ? 99 : (a - b).abs();

  /// 跨源一致性加分：TMDB 候选条目命中了已匹配的 Bangumi 原版日文片名。
  static void _linked(
    ScoredCandidate scored,
    MatchCandidate bangumi, {
    bool parentTvSpecial = false,
  }) {
    final remote = {
      for (final name in [scored.candidate.title, ...scored.candidate.aliases])
        DirectoryAnalyzer.normalize(name),
    }..remove('');
    final original = bangumi.aliases.isEmpty
        ? ''
        : DirectoryAnalyzer.normalize(bangumi.aliases.first);
    var bonus = original.isNotEmpty && remote.contains(original) ? 12.0 : 0.0;
    var others = 0;
    for (final name in {bangumi.title, ...bangumi.aliases.skip(1)}) {
      final key = DirectoryAnalyzer.normalize(name);
      if (key.isNotEmpty && key != original && remote.contains(key)) others++;
    }
    bonus += (others * 5).clamp(0, 10).toDouble();
    if (bonus == 0 && parentTvSpecial && scored.season == 0) {
      bonus = 10.0;
    }
    scored.add(bonus, 'bangumi agrees');
  }

  /// 判断已验证的短篇 Bangumi OVA/特别篇条目是否隶属于当前 TMDB 多集正片系列
  /// （适用于在第 0 季统一托管特别篇的 TMDB 长篇剧集候选 `[candidate]`）。
  static bool _isParentTvForBangumiSpecial(
    DirectoryInventory inventory,
    MatchCandidate candidate,
    MatchCandidate verifiedBangumi,
  ) {
    if (candidate.type != 'tv') return false;
    if ((inventory.season != null && inventory.season != 0) ||
        inventory.folderMovieMarker ||
        inventory.fileMovieMarker) {
      return false;
    }
    final localCount = inventory.shape == WorkShape.series
        ? inventory.episodeCount
        : inventory.shape == WorkShape.feature
        ? inventory.featureCount
        : 0;
    final maxCount =
        verifiedBangumi.isSpecialFormat || inventory.season == 0 ? 12 : 4;
    if (localCount < 1 || localCount > maxCount) return false;
    if ((verifiedBangumi.seasons.firstOrNull?.count ?? 0) > maxCount) {
      return false;
    }

    final specials = candidate.seasons.where((s) => s.number == 0).toList();
    if (specials.isEmpty || specials.first.count < localCount) return false;
    // 若短篇 TV 季条目已与当前本地集数精确吻合，则禁止反向劫持归并至其他季度。
    final regular = candidate.seasons.where((s) => s.number > 0).toList();
    if (inventory.season != 0 &&
        regular.any(
          (s) =>
              (s.count - localCount).abs() <= 1 &&
              (!verifiedBangumi.isSpecialFormat ||
                  _yearDiff(verifiedBangumi.year, s.year) <= 1),
        )) {
      return false;
    }

    final candNorms = [candidate.title, ...candidate.aliases]
        .map(DirectoryAnalyzer.normalize)
        .where(
          (s) =>
              RegExp(r'[\u3040-\u9fff]').allMatches(s).length >= 4 ||
              s.length >= 8,
        )
        .toList();
    if (candNorms.isEmpty) return false;

    final bgmTitle = DirectoryAnalyzer.normalize(verifiedBangumi.title);
    final bgmOrig = verifiedBangumi.aliases.isEmpty
        ? ''
        : DirectoryAnalyzer.normalize(verifiedBangumi.aliases.first);
    final localNorm = DirectoryAnalyzer.normalize(inventory.title);

    final bgmMatchesPrefix = candNorms.any(
      (c) =>
          (bgmOrig.startsWith(c) && bgmOrig.length > c.length) ||
          (bgmTitle.startsWith(c) && bgmTitle.length > c.length),
    );
    if (!bgmMatchesPrefix) return false;

    return candNorms.any(
          (c) => localNorm.startsWith(c) && localNorm.length > c.length,
        ) ||
        _bridgedTitle(verifiedBangumi, candidate) >= 0.60;
  }

  static bool _candidateHasSequelSignal(
    DirectoryInventory inventory,
    List<String> names,
  ) {
    final fullNorm = DirectoryAnalyzer.normalize(inventory.title);
    for (final name in names) {
      final norm = DirectoryAnalyzer.normalize(name);
      if (norm == fullNorm) return true;
      final split = DirectoryAnalyzer.splitSeasonSuffix(name, isSeries: true);
      if (split.season != null && split.season == inventory.season) return true;
    }
    return false;
  }

  /// 当候选条目在共享主标题前缀之后的副标题与本地冲突时予以扣分，
  /// with the local folder's explicit subtitle (e.g. "快盗天使双胞胎~心跳不已~"
  /// vs "快盗天使BREAK", or "Wake Up, Girls! 七人的偶像" vs "Wake Up, Girls! 新章").
  static double _subtitleConflictPenalty(
    DirectoryInventory inventory,
    MatchCandidate candidate, {
    MatchCandidate? verifiedBangumi,
  }) {
    if (verifiedBangumi != null &&
        _bridgedTitle(verifiedBangumi, candidate) >= 0.70) {
      return 0;
    }
    final localPrimary = DirectoryAnalyzer.normalize(
      _stripRemaster(inventory.title.replaceAll(_movieWord, ' ')),
    );
    if (localPrimary.length < 4) return 0;

    final remoteNames = [
      candidate.title,
      ...candidate.aliases,
      if (candidate.type == 'tv')
        for (final s in candidate.seasons)
          if (s.name != null &&
              s.name!.trim().isNotEmpty &&
              !_genericSeasonName.hasMatch(s.name!.trim())) ...[
            s.name!.trim(),
            '${candidate.title} ${s.name!.trim()}',
          ],
    ]
        .map(
          (n) => DirectoryAnalyzer.normalize(
            _stripRemaster(n.replaceAll(_movieWord, ' ')),
          ),
        )
        .where((n) => n.isNotEmpty)
        .toList();
    if (remoteNames.any((r) => similarity(localPrimary, r) >= 0.80)) {
      return 0;
    }

    // 若文件名携带了明确的副标题且与某候选别名高度一致（且不附带单边续作后缀），
    // 即使文件夹名与 TMDB 中译存在跨语言翻译差异也不再扣分。
    // 保障文件名自带副标题的高置信精准绑定不受目录译名差异影响。
    for (final fh in inventory.fileHints.take(2)) {
      final fn = DirectoryAnalyzer.normalize(fh.replaceAll(_movieWord, ' '));
      if (fn.length < 6) continue;
      for (final rn in remoteNames) {
        if (rn.startsWith(fn) &&
            rn.length > fn.length &&
            _sequelOrSpinoffSuffix.hasMatch(rn.substring(fn.length))) {
          continue;
        }
        if (similarity(fn, rn) >= 0.70) return 0;
      }
    }

    final candPrimary = DirectoryAnalyzer.normalize(
      _stripRemaster(candidate.title.replaceAll(_movieWord, ' ')),
    );
    if (candPrimary.length < 4 || localPrimary == candPrimary) return 0;

    var prefixLen = 0;
    final limit = localPrimary.length < candPrimary.length
        ? localPrimary.length
        : candPrimary.length;
    while (prefixLen < limit &&
        localPrimary.codeUnitAt(prefixLen) ==
            candPrimary.codeUnitAt(prefixLen)) {
      prefixLen++;
    }
    final prefix = localPrimary.substring(0, prefixLen);
    final hasCjkPrefix =
        RegExp(r'[\u3040-\u9fff]').allMatches(prefix).length >= 3;
    if (!hasCjkPrefix && prefixLen < 6) return 0;

    var localRem = localPrimary.substring(prefixLen);
    var candRem = candPrimary.substring(prefixLen);
    while (localRem.isNotEmpty &&
        candRem.isNotEmpty &&
        localRem.codeUnitAt(localRem.length - 1) ==
            candRem.codeUnitAt(candRem.length - 1)) {
      localRem = localRem.substring(0, localRem.length - 1);
      candRem = candRem.substring(0, candRem.length - 1);
    }
    if (candidate.provider == 'bangumi' &&
        candRem.isEmpty &&
        localRem.length >= 2 &&
        inventory.season == null &&
        (inventory.shape == WorkShape.feature || inventory.episodeCount <= 4) &&
        !RegExp(
          r'^(?:ova|oad|sp|specials?)$',
          caseSensitive: false,
        ).hasMatch(localRem)) {
      return -18;
    }
    if (localRem.length < 2 || candRem.length < 2) return 0;
    if (candidate.provider == 'tmdb' &&
        prefixLen >= 7 &&
        prefixLen >= localPrimary.length * 0.65) {
      return 0;
    }

    if (similarity(localRem, candRem) < 0.25) {
      return -25;
    }
    return 0;
  }

  static bool _hasConflictingCjkTitle(String localTitle, String candTitle) {
    String cjkOnly(String s) => RegExp(
      r'[\u4e00-\u9fff]+',
    ).allMatches(s).map((m) => m.group(0)!).join();
    final a = cjkOnly(localTitle);
    final b = cjkOnly(candTitle);
    if (a.length < 4 || b.length < 4) return false;
    return a != b && similarity(a, b) < 0.85;
  }

  static int? _partIndexFromSuffix(String suffix) {
    final trimmed = suffix.trim();
    if (trimmed.isEmpty) return null;
    const prefix = r'(?:stage|ova|oad|vol|volume|ep|part|act|chapter|第)?0*';
    const tail = r'(?:部|巻|卷|话|話|期|幕|章|[^a-z0-9]|$)';
    final patterns = <(RegExp, int)>[
      (RegExp('^$prefix(?:one|1(?!\\d)|i|前篇|前編|上篇?|前章)$tail', caseSensitive: false), 1),
      (RegExp('^$prefix(?:two|2(?!\\d)|ii|后篇|後編|下篇?|后章|後章)$tail', caseSensitive: false), 2),
      (RegExp('^$prefix(?:three|3(?!\\d)|iii|中篇?)$tail', caseSensitive: false), 3),
      (RegExp('^$prefix(?:four|4(?!\\d)|iv)$tail', caseSensitive: false), 4),
    ];
    for (final (re, part) in patterns) {
      if (re.hasMatch(trimmed)) return part;
    }
    return null;
  }

  static MatchResult? _resolveBangumiMultiPartTie(
    DirectoryInventory inventory,
    List<ScoredCandidate> ranking,
  ) {
    final k = inventory.episodeCount;
    if (inventory.shape != WorkShape.series || k < 2 || k > 4) return null;
    if (ranking.length < k) return null;
    final normLocal = DirectoryAnalyzer.normalize(inventory.title);
    if (normLocal.length < 5) return null;

    final sorted = [...ranking]..sort((a, b) => b.score.compareTo(a.score));
    final topScore = sorted.first.score;
    if (topScore < 36) return null;

    final partsByIndex = <int, ScoredCandidate>{};
    final partIds = <int>{};
    for (final item in sorted) {
      if (topScore - item.score > 6.0) break;
      for (final rawName in [item.candidate.title, ...item.candidate.aliases]) {
        final normCand = DirectoryAnalyzer.normalize(rawName);
        if (!normCand.startsWith(normLocal) ||
            normCand.length <= normLocal.length) {
          continue;
        }
        final part = _partIndexFromSuffix(normCand.substring(normLocal.length));
        if (part != null && part <= k && !partsByIndex.containsKey(part)) {
          partsByIndex[part] = item;
          partIds.add(item.candidate.id);
          break;
        }
      }
    }
    if (partsByIndex.length != k) return null;
    for (var i = 1; i <= k; i++) {
      if (!partsByIndex.containsKey(i)) return null;
    }
    final bestOutsider = sorted
        .where((s) => !partIds.contains(s.candidate.id))
        .firstOrNull;
    if (bestOutsider != null && topScore - bestOutsider.score < 10.0) {
      return null;
    }
    final orderedParts = [for (var i = 1; i <= k; i++) partsByIndex[i]!];
    final rest = sorted.where((s) => !partIds.contains(s.candidate.id));
    return MatchResult(
      MatchTier.high,
      [...orderedParts, ...rest],
      siblingIds: [for (final p in orderedParts) p.candidate.id],
    );
  }

  static int _coveredLatinTokens(
    List<String> sigTokens,
    MatchCandidate candidate,
  ) {
    final candAll = '${candidate.title} ${candidate.aliases.join(' ')}';
    final candCompact = DirectoryAnalyzer.normalize(candAll);
    final candTokens = _rawLatinTokens(candAll);
    final romajiRuns = [
      for (final raw in [candidate.title, ...candidate.aliases])
        if (TitleNormalizer.containsKana(raw))
          TitleNormalizer.kanaToRomaji(raw),
    ].join(' ');
    final romajiWords = RegExp(r'[a-z0-9]{2,}')
        .allMatches(romajiRuns.toLowerCase())
        .map((m) => m.group(0)!)
        .toList();
    final kanaLatin = romajiWords.join(' ');
    final romajiFolded = TitleNormalizer.phoneticLatinFold(kanaLatin);
    final romajiSkeleton = TitleNormalizer.phoneticSkeleton(kanaLatin);
    var covered = 0;
    for (final t in sigTokens) {
      if (_latinMatchesToken(candCompact, candTokens, t) ||
          (romajiFolded.isNotEmpty &&
              TitleNormalizer.phoneticTokenCovered(
                t,
                romajiFolded: romajiFolded,
                romajiSkeleton: romajiSkeleton,
                romajiWords: romajiWords,
              ))) {
        covered++;
      }
    }
    return covered;
  }

  /// 计算本地片名列表与远程候选别名间的最优相似度（`0..1`）；
  /// 其中目录推导名称的权重信任度高于文件名推导名称。
  static double _title(DirectoryInventory inventory, MatchCandidate candidate) {
    final primaryNorm = DirectoryAnalyzer.normalize(inventory.title);
    final baseCandNorm = DirectoryAnalyzer.normalize(candidate.title);
    final sharesBase =
        baseCandNorm.length >= 2 && primaryNorm.contains(baseCandNorm);
    final remoteRaw = <String>[
      candidate.title,
      ...candidate.aliases,
      if (candidate.type == 'tv')
        for (final s in candidate.seasons)
          if (s.name != null &&
              s.name!.trim().isNotEmpty &&
              !_genericSeasonName.hasMatch(s.name!.trim())) ...[
            '${candidate.title} ${s.name!.trim()}',
            if (DirectoryAnalyzer.normalize(s.name!.trim()).length >= 4 ||
                sharesBase)
              s.name!.trim(),
          ],
    ];
    final remote = <String>{};
    for (final name in remoteRaw) {
      final norm = DirectoryAnalyzer.normalize(name);
      if (norm.isEmpty) continue;
      remote.addAll(_expandNormArcs(norm));
      final arabic = _romanArabicVariant(name, norm);
      if (arabic != null) remote.addAll(_expandNormArcs(arabic));
    }
    remote.removeWhere((name) => name.isEmpty);

    final regularSeasons = candidate.seasons.where((s) => s.number > 0).toList();
    final multiSeasonTv =
        candidate.provider == 'tmdb' &&
        candidate.type == 'tv' &&
        inventory.season != null &&
        regularSeasons.length >= inventory.season!;
    final mergedSingleSeasonTv =
        candidate.provider == 'tmdb' &&
        candidate.type == 'tv' &&
        inventory.season != null &&
        inventory.season! >= 2 &&
        regularSeasons.length == 1 &&
        inventory.episodeCount > 0 &&
        regularSeasons.single.count >= inventory.episodeCount + 12;
    final localHasSequel =
        inventory.season != null && inventory.season! > 1 ||
        DirectoryAnalyzer.splitSeasonSuffix(
              inventory.title,
              isSeries: true,
            ).season !=
            null;
    final localIsEx =
        _inventoryHasExTag(inventory) &&
        (inventory.shape == WorkShape.feature || inventory.episodeCount <= 4);
    final candHasEx = _candidateHasExTag(candidate);
    final candHasCjkOverlap = _candidateHasSharedCjkWithInventory(
      inventory,
      candidate,
    );

    var best = 0.0;
    void check(Iterable<String> hints, double weight) {
      for (final hint in hints) {
        final localNorm = DirectoryAnalyzer.normalize(hint);
        if (localNorm.isEmpty) continue;
        // 剥离季度后的基础名称提示主要用于召回辅助：在多季或单季连续 TMDB 剧集保持全权重，
        // 而在按单季分条建档的 Bangumi 候选中予以权重折减以防季号串台。
        var effectiveWeight = weight;
        if (inventory.season != null &&
            inventory.season! > 1 &&
            primaryNorm.startsWith(localNorm) &&
            localNorm.length < primaryNorm.length) {
          effectiveWeight =
              weight * ((multiSeasonTv || mergedSingleSeasonTv) ? 1.0 : 0.80);
        }
        final hintHasEx = _exTagPattern.hasMatch(hint);
        final sigTokens = _significantLatinTokens(hint);
        final hintHasCjk = _cjkPattern.hasMatch(hint);
        final latinPrefixOnly =
            sigTokens.length >= 2 &&
            !hintHasCjk &&
            !candHasCjkOverlap &&
            _coveredLatinTokens(sigTokens, candidate) < 2;
        if (!hintHasCjk && !latinPrefixOnly) {
          for (final raw in remoteRaw) {
            final rSim = TitleNormalizer.romajiKanaSimilarity(hint, raw);
            if (rSim > 0) {
              var bounded = rSim;
              if (localIsEx && !candHasEx && !hintHasEx && bounded > 0.72) {
                bounded = 0.72;
              }
              final weighted = bounded * effectiveWeight;
              if (weighted > best) best = weighted;
            }
          }
        }
        final arabicHint = _romanArabicVariant(hint, localNorm);
        final localVariants = <String>{
          ..._expandNormArcs(localNorm),
          if (arabicHint != null) ..._expandNormArcs(arabicHint),
        };
        for (final local in localVariants) {
          String? localArc;
          String? localPrefix;
          for (final arc in _allArcSuffixes) {
            if (local.endsWith(arc) && local.length >= arc.length + 4) {
              localArc = arc;
              localPrefix = local.substring(0, local.length - arc.length);
              break;
            }
          }
          for (final name in remote) {
            var pairSim = similarity(local, name);
            if (!localHasSequel &&
                name.startsWith(local) &&
                name.length > local.length &&
                _sequelOrSpinoffSuffix.hasMatch(
                  name.substring(local.length),
                )) {
              pairSim *= 0.62;
            } else if (inventory.shape == WorkShape.feature &&
                inventory.featureCount == 1 &&
                weight == 1.0 &&
                local == primaryNorm &&
                RegExp(r'[\u3040-\u9fff]').allMatches(local).length >= 5 &&
                name.startsWith(local) &&
                name.length > local.length &&
                !_sequelOrSpinoffSuffix.hasMatch(
                  name.substring(local.length),
                ) &&
                (candidate.type == 'movie' ||
                    (candidate.provider == 'bangumi' &&
                        (candidate.seasons.isEmpty ||
                            candidate.seasons.first.count <= 2)))) {
              if (pairSim < 0.94) pairSim = 0.94;
            }
            if (localArc != null &&
                localPrefix != null &&
                name.startsWith(localPrefix) &&
                name.endsWith(localArc) &&
                pairSim < 0.90) {
              pairSim = 0.90;
            }
            if (localIsEx && !candHasEx && !hintHasEx && pairSim > 0.72) {
              pairSim = 0.72;
            }
            if (latinPrefixOnly && pairSim > 0.34) {
              pairSim = 0.34;
            }
            final value = pairSim * effectiveWeight;
            if (value > best) best = value;
          }
        }
      }
    }

    check(inventory.titleHints, 1);
    check(inventory.fileHints, 0.92);
    if (candidate.provider == 'tmdb' &&
        _hasRemasterInInventory(inventory) &&
        !_hasRemasterInCandidate(candidate)) {
      check([for (final h in inventory.titleHints) _stripRemaster(h)], 0.95);
    }
    return best;
  }

  static double _bridgedTitle(
    MatchCandidate bangumi,
    MatchCandidate tmdbCandidate,
  ) {
    final remote = <String>{};
    for (final name in [tmdbCandidate.title, ...tmdbCandidate.aliases]) {
      final norm = DirectoryAnalyzer.normalize(name);
      if (norm.isEmpty) continue;
      remote.addAll(_expandNormArcs(norm));
      final av = _romanArabicVariant(name, norm);
      if (av != null) remote.addAll(_expandNormArcs(av));
    }
    remote.removeWhere((name) => name.isEmpty);

    final trusted = <String>{};
    for (final raw in [
      bangumi.title,
      if (bangumi.aliases.isNotEmpty) bangumi.aliases.first,
    ]) {
      final norm = DirectoryAnalyzer.normalize(raw);
      if (norm.isEmpty) continue;
      trusted.addAll(_expandNormArcs(norm));
      final av = _romanArabicVariant(raw, norm);
      if (av != null) trusted.addAll(_expandNormArcs(av));
    }
    trusted.removeWhere((name) => name.isEmpty);

    var best = 0.0;
    for (final b in trusted) {
      String? bArc;
      String? bPrefix;
      for (final arc in _allArcSuffixes) {
        if (b.endsWith(arc) && b.length >= arc.length + 4) {
          bArc = arc;
          bPrefix = b.substring(0, b.length - arc.length);
          break;
        }
      }
      for (final r in remote) {
        var sim = similarity(b, r);
        if (bArc != null &&
            bPrefix != null &&
            r.startsWith(bPrefix) &&
            r.endsWith(bArc) &&
            sim < 0.90) {
          sim = 0.90;
        }
        if (sim > best) best = sim;
      }
    }
    return best;
  }

  /// 完全一致返回 `1.0`；包含关系按长度比例缩放；其余情况退化计算二元字符集 Dice 系数。
  /// 完全一致返回 `1.0`；包含关系按长度比例缩放；其余情况退化计算二元字符集 Dice 系数。
  static double similarity(String a, String b) => _wmSimilarity(a, b);

  static MatchResult _decide(
    List<ScoredCandidate> ranking, {
    double high = _highScore,
    double medium = _mediumScore,
  }) {
    if (ranking.isEmpty) return MatchResult.empty;
    ranking.sort((a, b) => b.score.compareTo(a.score));
    final top = ranking.first.score;
    final margin = ranking.length < 2
        ? double.infinity
        : top - ranking[1].score;
    final tier = top >= high && margin >= _highMargin
        ? MatchTier.high
        : top >= medium && margin >= _mediumMargin
        ? MatchTier.medium
        : MatchTier.none;
    return MatchResult(tier, ranking);
  }
}
