part of 'scrape_rules.dart';

final RegExp _parenYearPattern = RegExp(r'[（(]\s*((?:19|20)\d{2})\s*[）)]');

/// 构建遵循 `feat/scrape-pipeline` 多波次检索策略的去重搜索词表（最多 10 个；支持 Bangumi 交叉词救回）。
List<String> buildSearchQueries(
  GroupedWorkFolder folder, {
  ScoredBangumiCandidate? bangumiCandidate,
  List<String> extraQueries = const [],
}) {
  final inv = folder.matchingInventory;
  final seen = <String>{};
  final out = <String>[];

  void addSingle(String raw, {bool allowGroupHomonym = false}) {
    final stripped = raw
        .replaceAll(_reHot8, ' ')
        .replaceAll(_reHot9, ' ')
        .replaceAll(_reHot10, ' ')
        .replaceAll(_reHot11, ' ')
        .trim();
    final sanitized = SearchQuerySanitizer.sanitize(
      _cutTechnicalTail(stripped),
    );
    final clean = sanitized.isNotEmpty ? sanitized : stripped;
    if (clean.isEmpty ||
        _isJunkQuery(clean, allowGroupHomonym: allowGroupHomonym) ||
        _isJunkQuery(stripped, allowGroupHomonym: allowGroupHomonym)) {
      return;
    }
    final key = clean.toLowerCase().replaceAll(_reHot12, '');
    if (key.isEmpty || !seen.add(key)) return;
    out.add(clean);
  }

  final deferredFallbacks = <String>[];

  void add(
    String raw, {
    bool expandVariants = true,
    bool allowGroupHomonym = false,
    bool immediateSpecialFallback = false,
  }) {
    addSingle(raw, allowGroupHomonym: allowGroupHomonym);
    if (!expandVariants) return;
    void emitFallback(String term) {
      if (immediateSpecialFallback) {
        addSingle(term, allowGroupHomonym: allowGroupHomonym);
      } else {
        deferredFallbacks.add(term);
      }
    }

    // 根目录仅附带蓝光单卷标签（如 `孤独摇滚 Vol.1`、`葬送的芙莉莲 第1卷`，排除 `Alternative Vol.1`/`OVA Vol.1` 独立卷）时，
    // 立即补充剥离分卷后的纯净母剧名检索词，避免单卷先扫时在线检索漏召回。
    if (!_reHot13.hasMatch(raw)) {
      final volTail = _reHot14.firstMatch(raw.trim());
      final baseNoVol = volTail?.group(1)?.trim() ?? '';
      if (baseNoVol.length >= 2) {
        addSingle(baseNoVol, allowGroupHomonym: allowGroupHomonym);
      }
    }
    // 剥离尾部或中置 OVA/OAD/OADs/OVA1/TVSP/The Movie 及其后副标题，提炼母系列检索词。
    final beforeSpecial = _reHot15.firstMatch(raw.trim());
    if (beforeSpecial != null) {
      final baseSeries = beforeSpecial
          .group(1)!
          .replaceFirst(_reHot16, '')
          .trim();
      if (baseSeries.length >= 4 || _hasCjk(baseSeries)) {
        emitFallback(baseSeries);
      }
    }
    // 罗马音 + 日文假名双语拼接文件名（如 `Yowamushi Pedal 弱虫ペダル`、`Himouto! Umaru chan 干物妹! うまるちゃん`、`Yuyushiki ゆゆ式`）：
    // 仅当日文段含平/片假名时拆出拉丁段与日文段，绝不误拆 `Code Geass 亡国的阿基德` 这类单语中英混合正式片名。
    final bilingual = _reHot17.firstMatch(raw.trim());
    if (bilingual != null && _reHot18.hasMatch(bilingual.group(2)!)) {
      final latinSeg = bilingual.group(1)!.trim();
      final cjkSeg = bilingual.group(2)!.split(_reHot19).first.trim();
      if (latinSeg.length >= 4) {
        emitFallback(latinSeg);
      }
      if (cjkSeg.length >= 2 &&
          (_reHot20.hasMatch(cjkSeg) || cjkSeg.length >= 5)) {
        emitFallback(cjkSeg);
      }
    }
    final withoutInfixOva = raw
        .replaceAll(_reHot21, ' ')
        .replaceAll(_reHot11, ' ')
        .trim();
    if (withoutInfixOva != raw && withoutInfixOva.length >= 4) {
      addSingle(withoutInfixOva);
    }
    for (final rv in _romanNumeralVariants(raw)) {
      addSingle(rv);
    }
    for (final arc in WorkMatcher.expandRomajiArcQueries(raw)) {
      addSingle(arc);
    }
  }

  // 跨源救回：使用 Bangumi 官方中日文名补搜本地同义译名在 TMDB 零命中的条目。
  if (bangumiCandidate != null) {
    final bgm = bangumiCandidate.subject;
    if (bgm.displayTitle.isNotEmpty) {
      add(bgm.displayTitle);
      final strippedRemasterBgm = _stripRemasterTag(bgm.displayTitle);
      if (strippedRemasterBgm != bgm.displayTitle &&
          strippedRemasterBgm.isNotEmpty) {
        add(strippedRemasterBgm);
      }
    }
    if (bgm.name.trim().isNotEmpty) {
      add(bgm.name.trim());
    }
    for (final a in bgm.aliases.take(2)) {
      add(a);
    }
    final base = bgm.displayTitle.split(_reHot22).first.trim();
    if (base.isNotEmpty && _isSafeFirstToken(base, bgm.displayTitle)) {
      add(base, expandVariants: false);
    }
  }

  final hints = inv.titleHints.isNotEmpty
      ? inv.titleHints
      : [folder.cleanTitle];
  // 当首条一致文件名主干与目录名明显不同（常见于不规范目录名如 `阿伟推荐/` 内含规范番剧文件）时，
  // 将一致文件名主干紧随目录主名置入第 2 检索位，确保首波（前 3 词）必然同时召回文件主干对应作品。
  final divergentPrimaryFile =
      inv.fileHints.isNotEmpty &&
      WorkMatcher.similarity(
            DirectoryAnalyzer.normalize(hints.first),
            DirectoryAnalyzer.normalize(inv.fileHints.first),
          ) <
          0.50;
  for (var i = 0; i < hints.length; i++) {
    final hint = hints[i];
    add(hint, expandVariants: i == 0, allowGroupHomonym: i == 0);
    if (i == 0 && divergentPrimaryFile) {
      add(
        inv.fileHints.first,
        expandVariants: true,
        allowGroupHomonym: true,
        // 仅当目录主提示单一（典型于乱目录名，如 `阿伟推荐的神作2`）时立即展开双语/去后缀兜底词进第一波；
        // 规范中文目录（如 `飙速宅男 OAD`）已含去后缀主名 `hints[1]`，避免挤占第一波槽位。
        immediateSpecialFallback: hints.length == 1,
      );
    }
    final strippedPart = WorkSeason.withoutPart(hint);
    if (strippedPart != hint) add(strippedPart, expandVariants: false);
    final strippedMultiSeason = hint.replaceFirst(_reHot23, '').trim();
    if (strippedMultiSeason != hint && strippedMultiSeason.isNotEmpty) {
      add(strippedMultiSeason, expandVariants: false);
    }
    final strippedRemaster = _stripRemasterTag(hint);
    if (strippedRemaster != hint && strippedRemaster.isNotEmpty) {
      add(strippedRemaster, expandVariants: false);
    }
  }

  for (final eq in [...folder.extraSearchQueries, ...extraQueries]) {
    add(eq, expandVariants: true);
  }

  if (_reHot24.hasMatch(inv.title) &&
      !_reHot25.hasMatch(inv.titleHints.join(' ')) &&
      (inv.episodeCount <= 2 || inv.featureCount <= 2)) {
    add('${inv.title} ONE');
    add('${inv.title} TWO');
  }

  for (var i = 0; i < inv.fileHints.length; i++) {
    final fh = inv.fileHints[i];
    add(fh, allowGroupHomonym: i == 0);
    final strippedRemaster = _stripRemasterTag(fh);
    if (strippedRemaster != fh && strippedRemaster.isNotEmpty) {
      add(strippedRemaster, expandVariants: false);
    }
  }

  // 父级系列目录提示（如 `动画-多作品/XX 作品集/XX 篇章名` -> `XX`）。
  final physPath = (folder.physicalRootFolder ?? folder.folderRelativePath)
      .replaceAll('\\', '/');
  final parts = physPath
      .split('/')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  if (parts.length >= 2) {
    for (
      var idx = parts.length - 2;
      idx >= 0 && idx >= parts.length - 3;
      idx--
    ) {
      final parent = parts[idx].replaceFirst(_reHot26, '').trim();
      if (parent.isNotEmpty &&
          !_categoryFolderPattern.hasMatch(parent) &&
          !_genericSeasonName.hasMatch(parent)) {
        add(parent, expandVariants: false);
      }
    }
  }

  // 主系列词干与尾部副标题剥离（如 `系列名：副标题` / `前辈 主标题`）。
  for (final base in [...inv.titleHints.take(2), ...inv.fileHints.take(2)]) {
    final beforePunct = base.split(_reHot27).first.trim();
    if (beforePunct.isNotEmpty &&
        beforePunct != base &&
        (_hasCjk(beforePunct)
            ? beforePunct.length >= 2
            : beforePunct.length >= 4)) {
      add(beforePunct, expandVariants: false);
    }
    final tokens = base.split(_reHot22).where((t) => t.isNotEmpty).toList();
    if (tokens.length >= 2) {
      final first = tokens.first.trim();
      if (first != base && _isSafeFirstToken(first, base)) {
        add(first, expandVariants: false);
      }
      final tail = tokens.skip(1).join(' ').trim();
      if (tail != base &&
          first.length <= 6 &&
          (_hasCjk(tail) ? tail.length >= 2 : tail.length >= 4)) {
        add(tail, expandVariants: false);
      }
    }
  }

  for (final fb in deferredFallbacks) {
    addSingle(fb);
  }

  // 极短真片名兜底（如 `W'Z`、`86`、`K`、`C`）：避免全部候选词被长度门限滤空导致零检索。
  if (out.isEmpty) {
    final rawFallback = (inv.title.isNotEmpty ? inv.title : folder.cleanTitle)
        .replaceAll(_reHot8, ' ')
        .replaceAll(_reHot9, ' ')
        .replaceAll(_reHot11, ' ')
        .trim();
    final cleanFallback = SearchQuerySanitizer.sanitize(rawFallback);
    final chosen = cleanFallback.isNotEmpty ? cleanFallback : rawFallback;
    if (chosen.isNotEmpty && !_genericQueryWord.hasMatch(chosen)) {
      out.add(chosen);
    }
  }

  return out.take(10).toList(growable: false);
}

/// 提取高置信度目录括号年份提示（用于 TMDB 首波精确年份检索）；
/// 当目录分析器已主动清空通用乱目录伪年份时不再从路径中强行复活该伪年份；
/// 当目录名与文件主干显著偏离且文件自身携带一致发行年份时，优先采用文件年份。
int? extractSearchYear(GroupedWorkFolder folder) {
  final inv = folder.inventory;
  if (inv != null && inv.year == null) {
    return null;
  }
  if (inv != null && inv.fileYear != null && inv.fileHints.isNotEmpty) {
    final sim = WorkMatcher.similarity(
      DirectoryAnalyzer.normalize(inv.title),
      DirectoryAnalyzer.normalize(inv.fileHints.first),
    );
    if (sim < 0.45) {
      return inv.fileYear;
    }
  }
  final physPath = (folder.physicalRootFolder ?? folder.folderRelativePath)
      .replaceAll('\\', '/');
  final segments = physPath
      .split('/')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  for (var i = segments.length - 1; i >= 0; i--) {
    final m = _parenYearPattern.firstMatch(segments[i]);
    if (m != null) return int.tryParse(m.group(1)!);
  }
  return folder.year;
}

String _stripRemasterTag(String value) =>
    value.replaceAll(_remasterPattern, ' ').replaceAll(_reHot11, ' ').trim();

/// 场景式命名在标题后紧跟合理发行年份（1950~2029）、分辨率、编码或季集标记，搜索词从首个此类标记处截断（标记不在开头时）；
/// 科幻片名自带的未来年份（如 `Demon Lord 2099`）不被截断。
final RegExp _queryTechnicalTail = RegExp(
  r'(?<![a-z0-9぀-鿿])(?:(?:19[5-9]\d|20[0-2]\d)|s\d{1,2}e\d{1,4}|tvsp\d{1,3}|\d{3,4}[pi]|[248]k|x26[45]|h\.?26[45]|'
  r'hevc|avc|flac|aac|ac3|dual[ ._-]?audio|10bits?|8bits?|bdrip|dvdrip|webrip|web[ ._-]?dl|blu[ ._-]?ray)(?![a-z0-9])',
  caseSensitive: false,
);

String _cutTechnicalTail(String query) {
  final m = _queryTechnicalTail.firstMatch(query);
  if (m == null || m.start == 0) {
    return query.replaceAll(_reHot42, ' ').replaceAll(_reHot11, ' ').trim();
  }
  return query.substring(0, m.start).trim();
}

/// 压制组名、纯技术/语言标签、通用类型词与过短的版本号片段都不是有效作品搜索词。
final RegExp _genericQueryWord = RegExp(
  r'^(?:电影|映画|剧场版|劇場版|the[ ._-]+movie|movie|film|(?:ova|oad|oav|oab|ona|sp|special)\d*|sps|specials|tv|'
  r'dts[ ._-]*hd(?:ma)?|'
  r'完结篇|完結編|前篇|前編|后篇|後編|中篇|中編|上篇|下篇|'
  r'特典|特别篇|特別編|总集篇|総集編|extras?|bonus|bd|dvd|web|v\d+|\d{1,2}d)$',
  caseSensitive: false,
);

bool _isJunkQuery(String query, {bool allowGroupHomonym = false}) {
  final trimmed = query.trim();
  if (_genericQueryWord.hasMatch(trimmed)) return true;
  if (!allowGroupHomonym &&
      PersonalFilenameParser.isReleaseGroupTag(trimmed) &&
      !_hasCjk(trimmed.replaceAll(_reHot43, ''))) {
    return true;
  }
  final letters = trimmed.replaceAll(_reHot44, '');
  if (!_hasCjk(trimmed) && letters.length <= 2) return true;
  return false;
}

bool _isSafeFirstToken(String firstToken, String fullQuery) {
  if (_hasCjk(firstToken)) return firstToken.length >= 2;
  final stripped = fullQuery.replaceAll(_reHot45, ' ').toLowerCase();
  final latinWords = stripped
      .split(_reHot39)
      .where((w) => w.length >= 3)
      .toList();
  return latinWords.length <= 1 && firstToken.length >= 4;
}

List<String> _romanNumeralVariants(String raw) {
  const unicodeToAscii = <String, String>{
    'Ⅰ': 'I',
    'Ⅱ': 'II',
    'Ⅲ': 'III',
    'Ⅳ': 'IV',
    'Ⅴ': 'V',
    'Ⅵ': 'VI',
    'Ⅶ': 'VII',
    'Ⅷ': 'VIII',
    'Ⅸ': 'IX',
    'Ⅹ': 'X',
    'ⅰ': 'I',
    'ⅱ': 'II',
    'ⅲ': 'III',
    'ⅳ': 'IV',
    'ⅴ': 'V',
    'ⅵ': 'VI',
    'ⅶ': 'VII',
    'ⅷ': 'VIII',
    'ⅸ': 'IX',
    'ⅹ': 'X',
  };
  const unicodeToArabic = <String, String>{
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
  const asciiToArabic = <String, String>{
    'II': '2',
    'III': '3',
    'IV': '4',
    'V': '5',
    'VI': '6',
    'VII': '7',
    'VIII': '8',
    'IX': '9',
    'X': '10',
  };

  var ascii = raw;
  var asciiChanged = false;
  unicodeToAscii.forEach((k, v) {
    if (ascii.contains(k)) {
      ascii = ascii.replaceAll(k, ' $v ');
      asciiChanged = true;
    }
  });

  var arabic = raw;
  var arabicChanged = false;
  unicodeToArabic.forEach((k, v) {
    if (arabic.contains(k)) {
      arabic = arabic.replaceAll(k, ' $v ');
      arabicChanged = true;
    }
  });
  arabic = arabic.replaceAllMapped(_reHot55, (m) {
    final rep = asciiToArabic[m.group(1)!];
    if (rep == null) return m.group(0)!;
    arabicChanged = true;
    return ' $rep ';
  });

  final out = <String>[];
  if (asciiChanged) {
    final clean = ascii.replaceAll(_reHot11, ' ').trim();
    if (clean.isNotEmpty) out.add(clean);
  }
  if (arabicChanged) {
    final clean = arabic.replaceAll(_reHot11, ' ').trim();
    if (clean.isNotEmpty && !out.contains(clean)) out.add(clean);
  }
  return out;
}

final RegExp _reHot12 = RegExp(r'[\s:：\-～~·・･/—]+');

final RegExp _reHot13 = RegExp(
  r'(?<![a-z0-9])(?:alternative|ova|oad|oav|sp\d*|special)(?![a-z0-9])',
  caseSensitive: false,
);

final RegExp _reHot14 = RegExp(
  r'^(.*?)\s*(?:[-–—:：]\s*|\s+)(?:(?:bd|dvd)\s*)?(?:vol(?:ume)?\.?\s*0*\d{1,2}|第\s*[0-9一二三四五六七八九十]+\s*[卷巻])\s*$',
  caseSensitive: false,
);

final RegExp _reHot15 = RegExp(
  r'^(.+?)\s+(?:the\s+movie|movie|ova\d*|oads?|oav\d*|tvsp|sp\d+|special\s+ride)\b',
  caseSensitive: false,
);

final RegExp _reHot16 = RegExp(r'\s+the\s+animation$', caseSensitive: false);

final RegExp _reHot17 = RegExp(
  r'^([A-Za-z0-9][A-Za-z0-9\s!\-’\x27.,]{3,}?)\s+([\u3040-\u9fff][^\r\n]{1,})$',
);

final RegExp _reHot18 = RegExp(r'[\u3040-\u30ff]');

final RegExp _reHot19 = RegExp(
  r'\s+(?:ova\d*|oads?|oab|sp\d*|special|「|『)',
  caseSensitive: false,
);

final RegExp _reHot20 = RegExp(r'[\u4e00-\u9fff]');

final RegExp _reHot21 = RegExp(
  r'(?<=\s)(?:OVA|OAD|OAV)(?=\s+\S)',
  caseSensitive: false,
);

final RegExp _reHot22 = RegExp(r'\s+|[:：～~—\-/·・･]+');

final RegExp _reHot23 = RegExp(
  r'\s+s\d{1,2}(?:\s*[+&~～\-]\s*(?:s?\d{1,2}|ova|oad|sp|movie))+\s*$',
  caseSensitive: false,
);

final RegExp _reHot26 = RegExp(
  r'\s*(?:系列|作品集|合集|全集|Series|Collection)$',
  caseSensitive: false,
);

final RegExp _reHot27 = RegExp(r'[:：～~—/·・･]+');

final RegExp _reHot42 = RegExp(
  r'(?<![a-z0-9])(?:\d{3,4}[pi]|[248]k)(?![a-z0-9])',
  caseSensitive: false,
);

final RegExp _reHot43 = RegExp(r'字幕[组組社]|[汉漢]化[组組]|[压壓]制[组組]');

final RegExp _reHot44 = RegExp(r'[\W_]+', unicode: true);

final RegExp _reHot45 = RegExp(
  r'(?<![a-z0-9])(?:oad|ova|ona|sp|specials?|ex\d{0,2}|the\s+movie|movie|tv)(?![a-z0-9])',
  caseSensitive: false,
);

final RegExp _reHot55 = RegExp(
  r'(?:^|(?<=[\s\u3040-\u9fff\-:：]))(II|III|IV|VI{0,3}|IX|V|X)(?=$|[\s\u3040-\u9fff\-:：])',
);
