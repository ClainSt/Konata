import '../matching/supplementary_subclassifier.dart';
import '../matching/work_matcher.dart';
import 'cloud_media_file_classifier.dart';
import 'personal_filename_parser.dart';

/// 文件名解析词条仅用于元数据匹配及生成简洁特典展示标签。
class CloudMediaAssetPresentation {
  /// 在剧集型目录清单中，为无集号主正片识别显式剧场版/电影标签。
  static bool isIndependentMovie(Map<String, Object?> asset) {
    if (asset['category'] != 'main' ||
        asset['episode'] != null ||
        asset['manual_mapping'] == true) {
      return false;
    }
    final name = asset['name']?.toString() ?? '';
    if (_filmLabel.hasMatch(name)) return true;
    final path = asset['relative_path']?.toString() ?? '';
    final segments = path.replaceAll('\\', '/').split('/');
    return segments.take(segments.length - 1).any(_tvAndFilmFolder.hasMatch);
  }

  static final _filmLabel = RegExp(
    r'(?<![a-z0-9])(?:the[ ._-]+)?movie(?![a-z0-9])|劇場版|剧场版',
    caseSensitive: false,
  );
  static final _tvAndFilmFolder = RegExp(
    r'\b(?:tv\s*[+&＆]\s*movie|movie\s*[+&＆]\s*tv)\b',
    caseSensitive: false,
  );

  static final _technicalTag = RegExp(
    r'\b(?:\d{3,4}p|\d{3,4}x\d{3,4}|[248]k|ma10p|hi10p|(?:8|10|12)bits?|x26[45]|h[ .]?26[45]|hevc\d*|avc\d*|av1|yuv\w*|\d*aac(?:x\d+)?|\d*flac(?:x\d+)?|opus|dts(?:hd)?|ac3|eac3|ddp|truehd|atmos|l?pcm|alac|bdrip|bdremux|bdmv|bluray|blu-ray|web-?dl|webrip|hdr\d*|chs|cht|jpsc|jptc|jpchs|jpcht|raws)\b',
    caseSensitive: false,
  );

  static final _technicalBracketToken = RegExp(
    r'^(?:\d{3,4}p|\d{3,4}x\d{3,4}|[248]k|(?:ma|hi)(?:\d{1,3}-)?(?:8|10|12)p|\d{1,2}bits?|yuv\w*|x26[45]|h\.?26[45]|hevc\d*|avc\d*|av1|\d*flac(?:x\d+)?|\d*aac(?:x\d+)?|opus|dts(?:hd)?|ac3|eac3|ddp|truehd|atmos|l?pcm|alac|mp3|ogg|\d\.\d|bd|bdrip|bdremux|bdmv|bluray|blu-ray|uhd|web-?dl|webrip|web|dvd|dvdrip|tvrip|remux|raw|raws|hdr\d*|sdr|dv|chs|cht|gb|big5|sc|tc|jp|jpn|chi|eng|sub|subs|ass|ssa|srt|sup|pgs|jpsc|jptc|jpchs|jpcht|简日|繁日|双语|雙語|内嵌|内封|v\d+|\d+(?:\.\d+)?fps)$',
    caseSensitive: false,
  );

  static final _releaseBracketGroup = RegExp(
    r'(?:字幕组|字幕組|压制组|壓製組|VCB-Studio|SweetSub|Moozzi2|Snow-Raws|Lilith-Raws|LoliHouse|AI-Raws|ANK-Raws|U2-Rip|ReinForce|Kamigami|BeanSub|KTXP|Nekomoe|TXXZ|.*[-_ ](?:Raws?|Subs?|Subtitles?|Rip|Encode|Studio)$)',
    caseSensitive: false,
  );

  static final _alternateEndingPattern = RegExp(
    r'(?<![a-z])(?:alter(?:nate|native)?|another|true|different|epilogue)'
    r'(?:[ ._-]*end(?:ing)?|[ ._-]+ed)(?![a-z])',
    caseSensitive: false,
  );

  static bool _isTechnicalOrReleaseSegment(String rawValue) {
    final trimmed = rawValue.trim();
    if (trimmed.isEmpty) return true;
    if (_reHot1.hasMatch(trimmed)) return true;
    if (_releaseBracketGroup.hasMatch(trimmed)) return true;
    final tokens = trimmed.split(_reHot2).where((t) => t.isNotEmpty).toList();
    if (tokens.isEmpty) return true;
    return tokens.every(_technicalBracketToken.hasMatch);
  }

  /// 仅用于展示层的标签清洗：完整保留内容类型标识与原始编号。
  static String cleanedExtraFilename(Map<String, Object?> asset) {
    final original = asset['name']?.toString().trim();
    final path =
        (original?.isNotEmpty == true
                ? original!
                : asset['relative_path']?.toString() ?? '')
            .replaceAll('\\', '/')
            .split('/')
            .last;
    final base = path.replaceFirst(_reHot3, '');
    var name = base.replaceAllMapped(_reHot4, (match) {
      final value = match.group(1) ?? match.group(2) ?? match.group(3)!;
      final release = _reHot5.hasMatch(value);
      final checksum = _reHot1.hasMatch(value.trim());
      return _technicalTag.hasMatch(value.replaceAll('_', ' ')) ||
              _isTechnicalOrReleaseSegment(value) ||
              release ||
              checksum
          ? ' '
          : ' $value ';
    });
    name = name
        .replaceAll(_reHot6, ' ')
        .replaceAll(_technicalTag, ' ')
        .replaceAll(_reHot7, ' ')
        .trim()
        .replaceAll(_reHot8, '');
    return name.isEmpty ? base : name;
  }

  static const _matchableSpecialTypes = {'OVA', 'OAD', 'SP', 'EX'};
  static const _matchableSpecialFamilies = {'OVA', 'SP', 'OVA_SP'};
  static final _noCreditToken = RegExp(
    r'(?:creditless|textless|non[ ._-]?telop|non[ ._-]?credit|'
    r'ノンクレジット|ノンクレ|ノンテロップ)[ ._:-]*'
    r'(opening|ending|OP|ED)[ ._-]*(\d{1,3}(?:[ ._-]?(?!v\d|ver\b)[a-z])?)?',
    caseSensitive: false,
  );
  static final _extraToken = RegExp(
    r'(^|[^a-z])(NCOPED|NCOP|NCED|MENU(?:[ ._-]*EX)?|MUSIC[ ._-]*(?:VIDEO|CLIP)|MV[ ._-]*MAKING|OVA|OAD|PV|CM|SP|MV|LOGO|RL|'
    r'INFORMATION|INFO|INTERVIEW|MAKING|DIGEST|TRAILER|TEASER|PROMOTION|EVENT|'
    r'EYECATCH|ARTWORK|SPOT|OAB|EX)(?:[ ._-]*(\d+(?:[ ._-]?[a-z])?))?'
    r'(?=[^a-z0-9]|$)',
    caseSensitive: false,
  );
  static final _promoOverrideToken = RegExp(
    r'(^|[^a-z0-9])(PVCM|TV[ ._-]*CM|BD[ ._-]*CM|CM|PV)'
    r'(?:[ ._-]*(\d+(?:[ ._-]?[a-z])?))?(?=[^a-z0-9]|$)',
    caseSensitive: false,
  );

  // 部分压制组（如 Moozzi2）习惯用 `[SP02]` 或 `- SP07 [OVA - 01]` 作为光盘或片段索引
  // 置于括号内容说明前；若仅有裸 `[SP01]` 而无额外描述，则仍保留为 SP。
  static String? _groupedSpecialContent(String name) {
    var bracketedGroup = true;
    var group = _reHot9.firstMatch(name);
    if (group == null) {
      bracketedGroup = false;
      group = _reHot10.firstMatch(name);
    }
    if (group == null) return null;
    final rawSuffix = name.substring(group.end).replaceFirst(_reHot11, '');
    final bracketPattern = _reHot4;
    final bracketContents = <String>[
      for (final m in bracketPattern.allMatches(rawSuffix))
        (m.group(1) ?? m.group(2) ?? m.group(3) ?? '').trim(),
    ];
    final outsideBrackets = rawSuffix
        .replaceAll(bracketPattern, ' ')
        .replaceAll(_reHot12, '')
        .trim();
    if (!_reHot13.hasMatch(outsideBrackets) &&
        bracketContents.isNotEmpty &&
        bracketContents.every(_isTechnicalOrReleaseSegment)) {
      return null;
    }

    final suffix = rawSuffix
        .replaceAll(_reHot14, '')
        .replaceAll(_reHot15, '')
        .replaceAll(_reHot16, '')
        .replaceAll(_reHot12, '')
        .trim();
    if (!_reHot13.hasMatch(suffix)) {
      return null;
    }
    // 仅包含编码参数信息的尾部标签不能代表独立特典条目。
    final cleaned = cleanedExtraFilename({'name': '$suffix.mkv'});
    if (cleaned.trim().isEmpty) return null;
    if (!bracketedGroup &&
        !CloudMediaFileClassifier.isPreview(cleaned) &&
        _noCreditLabel(cleaned) == null &&
        !_extraToken.hasMatch(cleaned) &&
        !_promoOverrideToken.hasMatch(cleaned) &&
        !_alternateEndingPattern.hasMatch(cleaned)) {
      return null;
    }
    return cleaned;
  }

  static const _ignoredTechPrefixes = <String>{
    'H',
    'X',
    'AV',
    'AVC',
    'HEVC',
    'HI',
    'HI10P',
    'AAC',
    'FLAC',
    'DTS',
    'AC',
    'DD',
    'CH',
    'PCM',
    'VP',
    'CRC',
    'BD',
    'BDRIP',
    'WEB',
    'WEBRIP',
    'VOL',
    'DISC',
    'DVD',
  };

  static final RegExp _explicitTrailingOpEd = RegExp(
    r'(?:\s*[-–—]\s*|[\[(（【]\s*)(OP|ED)\s*(\d{1,2}(?:(?!v\d|ver\b)[a-z])?)(?=$|[\s._\-\])）】\(])',
    caseSensitive: false,
  );

  /// 从原始文件名与相对路径解析特典标题（纯字符串直调，零 Map 分配）。
  static String? extraTitleFromName(String original, {String? relativePath}) {
    final fractional = _reHot17.firstMatch(original);
    if (fractional != null) return 'SP${fractional[1]}';
    final content = _groupedSpecialContent(original);
    final name = content ?? original;
    final qualified = SupplementarySubclassifier.extractQualifiedExtraTitle(
      name,
      relativePath: relativePath,
    );
    if (qualified != null) return qualified;
    if (CloudMediaFileClassifier.isPreview(name)) return null;
    final noCredit = _noCreditLabel(name);
    if (noCredit != null) return noCredit;
    // 片名自身含 OVA（如 `... OVA - ED1.mkv`）时，优先提取末尾或括号内的明确 OP/ED 编号，防止被误标为泛化 `OVA`。
    final trailingOpEd = _explicitTrailingOpEd.firstMatch(name);
    if (trailingOpEd != null) {
      return '${trailingOpEd.group(1)!.toUpperCase()}${trailingOpEd.group(2)!.toUpperCase()}';
    }
    final match = _extraToken.firstMatch(name);
    if (match == null) {
      final interview = _reHot18.firstMatch(name);
      if (interview != null) return 'IV${interview.group(3)}';
      // 仅采信独立且明确的内容发布标签；压制组名、CRC32 校验码与编码分辨率标签绝不能
      // 充当未识别特典的显示标题。
      final labels = _reHot19.allMatches(name);
      for (final label in labels) {
        final rawToken = label.group(0)!;
        final inner = rawToken.substring(1, rawToken.length - 1).trim();
        if (_isTechnicalOrReleaseSegment(inner)) {
          continue;
        }
        final prefix = label.group(1)!.toUpperCase();
        if (_ignoredTechPrefixes.contains(prefix)) {
          continue;
        }
        return '$prefix${label.group(2)!.toUpperCase()}';
      }
      return content;
    }
    final number = (match.group(3) ?? '').replaceAll(_reHot20, '');
    final type = match.group(2)!.toUpperCase();
    if (_matchableSpecialTypes.contains(type)) {
      final promo = _promoOverrideToken.firstMatch(name);
      if (promo != null) {
        if (content != null) return content;
        final promoRaw = promo.group(2)!.toUpperCase();
        final promoType = promoRaw == 'PV' ? 'PV' : 'CM';
        final promoNum = (promo.group(3) ?? '').replaceAll(_reHot20, '');
        return '$promoType$promoNum';
      }
    }
    return '${type == 'INFORMATION' ? 'INFO' : type}$number';
  }

  static String? extraTitle(Map<String, Object?> asset) => extraTitleFromName(
    asset['name']?.toString() ?? '',
    relativePath: asset['relative_path']?.toString(),
  );

  static String extraDisplayTitle(Map<String, Object?> asset) {
    final extracted = extraTitle(asset);
    if (extracted != null) return extracted;
    final original = asset['name']?.toString();
    if (original != null && original.trim().isNotEmpty) return original;
    final path = asset['relative_path']?.toString().replaceAll('\\', '/');
    return path
            ?.split('/')
            .lastWhere((part) => part.isNotEmpty, orElse: () => '未命名视频') ??
        '未命名视频';
  }

  static bool _isNarrativeSpecialDirAssetPath(String path, String name) {
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.length <= 1) return false;
    final parentDirs = segments.sublist(0, segments.length - 1);
    final inSpecialDir = parentDirs.any((seg) => _reHot21.hasMatch(seg));
    if (!inSpecialDir) return false;
    if (CloudMediaFileClassifier.isPreview(name) ||
        _noCreditLabel(name) != null) {
      return false;
    }
    if (_alternateEndingPattern.hasMatch(name)) {
      return !_reHot22.hasMatch(name);
    }
    return !_reHot23.hasMatch(name);
  }

  static const _dirExtraTypeMap = <String, String>{
    'music': 'MV',
    'music video': 'MV',
    'music videos': 'MV',
    'mv': 'MV',
    'mvs': 'MV',
    'bonus': 'BONUS',
    'extra': 'EXTRA',
    'extras': 'EXTRA',
    'voices': 'VOICE',
    'voice': 'VOICE',
    'live part': 'LIVE',
    'creditless': 'CREDITLESS',
    '映像特典': '映像特典',
    '特典': '特典',
  };

  /// 从原始文件名与相对路径解析特典分类（纯字符串直调，零 Map 分配）。
  static String extraTypeFromName(String original, {String? relativePath}) {
    if (_reHot24.hasMatch(original)) return 'SP';
    final content = _groupedSpecialContent(original);
    final name = content ?? original;
    if (CloudMediaFileClassifier.isPreview(name)) {
      return '预告';
    }
    final noCredit = _noCreditLabel(name);
    if (noCredit != null) return noCredit;
    final bundledExtra = _reHot25.firstMatch(name);
    if (bundledExtra != null) {
      final raw = bundledExtra.group(1)!.toUpperCase();
      return raw == 'SPECIAL' ? 'SP' : raw;
    }
    final match = _extraToken.firstMatch(name);
    if (match != null) {
      final type = match.group(2)!.toUpperCase();
      if (_matchableSpecialTypes.contains(type)) {
        final promo = _promoOverrideToken.firstMatch(name);
        if (promo != null) {
          return promo.group(2)!.toUpperCase() == 'PV' ? 'PV' : 'CM';
        }
      }
      if (type.startsWith('MENU')) return 'MENU';
      if (type.startsWith('MUSIC') || type.startsWith('MV')) return 'MV';
      return type == 'INFORMATION' ? 'INFO' : type;
    }
    if (_alternateEndingPattern.hasMatch(name) && !_reHot26.hasMatch(name)) {
      return 'SP';
    }
    final path = (relativePath ?? '').replaceAll('\\', '/');
    if (_isNarrativeSpecialDirAssetPath(path, name)) return 'SP';
    if (content != null) return '其他';
    if (_reHot27.hasMatch(path)) {
      return 'MENU';
    }
    final segments = path.split('/');
    for (final seg in segments) {
      final mapped = _dirExtraTypeMap[seg.trim().toLowerCase()];
      if (mapped != null) return mapped;
    }
    return '其他';
  }

  static String extraType(Map<String, Object?> asset) => extraTypeFromName(
    asset['name']?.toString() ?? '',
    relativePath: asset['relative_path']?.toString(),
  );

  static String? _noCreditLabel(String name) {
    final match = _noCreditToken.firstMatch(name);
    if (match == null) return null;
    final type = switch (match.group(1)!.toLowerCase()) {
      'opening' => 'OP',
      'ending' => 'ED',
      final value => value.toUpperCase(),
    };
    final rawSuffix = (match.group(2) ?? '')
        .replaceAll(_reHot28, '')
        .toLowerCase();
    return 'NC$type$rawSuffix';
  }

  static String category(Map<String, Object?> asset) {
    if (extraType(asset) == 'MENU') return 'extra';
    final category = '${asset['category']}';
    // 历史或语义模糊的视频在关联管理页中保留“待确认”以便手动调整；
    // 但详情页会统一归入特典标签页，确保任何可播文件都不会从界面消失。
    // 详情页归类兜底，防止局部影片遗漏展示。
    return category == 'review' ? 'extra' : category;
  }

  static int seasonNumber(Map<String, Object?> asset) =>
      explicitSeasonNumber(asset) ?? 1;

  static int? explicitSeasonNumber(Map<String, Object?> asset) {
    final explicit = int.tryParse('${asset['season_number'] ?? ''}');
    if (explicit != null) return explicit;
    // 相对资源路径可能不含所选媒体库根目录，因此保留作品身份作为兜底；
    // 绝不能根据裸数字反推季号：该数字可能是集数、发行年份或分辨率。
    // 避免将集号、年份或清晰度误判为季度编号。
    for (final value in [
      asset['name'],
      asset['relative_path'],
      asset['work_key'],
      asset['work_title'],
    ]) {
      final season = _seasonFromText('$value');
      if (season != null) return season;
    }
    return null;
  }

  static int? _seasonFromText(String value) {
    final text = value.replaceAll('\\', '/');
    // 如 `S1+S2`、`S01-S02` 等合集标识涵盖多个季度，而非单文件所属季号；
    // 此处需继续检索其余线索，确保文件名中显式的 `S02E01` 仍能
    // 优先覆盖外层合集目录标记。
    if (_reHot29
        .allMatches(text)
        .any(
          (match) => int.parse(match.group(1)!) != int.parse(match.group(2)!),
        )) {
      return null;
    }
    final patterns = [_reHot30, _reHot31, _reHot32, _reHot33];
    for (final pattern in patterns) {
      final token = pattern.firstMatch(text)?.group(1);
      if (token == null) continue;
      final numeric = int.tryParse(token);
      if (numeric != null) return numeric;
      const digits = {
        '一': 1,
        '二': 2,
        '两': 2,
        '三': 3,
        '四': 4,
        '五': 5,
        '六': 6,
        '七': 7,
        '八': 8,
        '九': 9,
      };
      if (digits.containsKey(token)) return digits[token];
      final parts = token.split('十');
      if (parts.length == 2) {
        final tens = parts.first.isEmpty ? 1 : digits[parts.first];
        final units = parts.last.isEmpty ? 0 : digits[parts.last];
        if (tens != null && units != null) return tens * 10 + units;
      }
    }
    return null;
  }

  /// 仅未标记季度的文件允许跨连续 TMDB 季度使用绝对集号；
  /// 当文件已通过 `SxxExx` 或目录锁定到 `K > 1` 季时，
  /// 需按季度偏移将累计集号对齐至当季局部集号。
  static ({int season, int number})? episodeCoordinates(
    Map<String, Object?> asset,
    Map<String, dynamic> seasons,
  ) {
    final number = int.tryParse(
      '${asset['episode_number'] ?? asset['episode'] ?? ''}',
    );
    if (number == null || number <= 0) return null;
    final counts =
        seasons['season_episode_counts'] ?? seasons['seasonEpisodeCounts'];
    int? alignCumulative(int targetSeason) {
      if (targetSeason <= 1 ||
          asset['manual_mapping'] == true ||
          counts is! Map) {
        return null;
      }
      final targetCount = int.tryParse('${counts['$targetSeason'] ?? ''}');
      if (targetCount == null || targetCount <= 0) return null;
      var priorSum = 0;
      for (var s = 1; s < targetSeason; s++) {
        final count = int.tryParse('${counts['$s'] ?? ''}');
        if (count == null || count <= 0) return null;
        priorSum += count;
      }
      if (number > priorSum && number <= priorSum + targetCount) {
        return number - priorSum;
      }
      return null;
    }

    final explicit = explicitSeasonNumber(asset);
    if (explicit != null) {
      final aligned = alignCumulative(explicit);
      return (season: explicit, number: aligned ?? number);
    }
    final rawSeason = int.tryParse('${asset['season'] ?? ''}');
    if (rawSeason != null && rawSeason > 1) {
      final aligned = alignCumulative(rawSeason);
      return (season: rawSeason, number: aligned ?? number);
    }
    if (counts is Map) {
      var remaining = number;
      for (var season = 1; season <= counts.length; season++) {
        final count = int.tryParse('${counts['$season'] ?? ''}');
        if (count == null || count <= 0) break;
        if (remaining <= count) return (season: season, number: remaining);
        remaining -= count;
      }
    }
    return (season: 1, number: number);
  }

  static Map<Object?, Object?>? episode(
    Map<String, Object?> asset,
    Map<String, dynamic> seasons,
  ) {
    if (category(asset) != 'episode') return null;
    final coordinates = episodeCoordinates(asset, seasons);
    if (coordinates == null) return null;
    final entries = seasons['${coordinates.season}'];
    if (entries is! List) return null;
    for (final entry in entries.whereType<Map<Object?, Object?>>()) {
      if (entry['episode_number'] == coordinates.number) return entry;
    }
    return null;
  }

  static String? specialType(Map<String, Object?> asset) {
    final type = extraType(asset);
    return _matchableSpecialTypes.contains(type) ? type : null;
  }

  static bool isSpecialMappingCandidate(Map<String, Object?> asset) {
    if (category(asset) != 'extra' || specialType(asset) == null) return false;
    final original = asset['name']?.toString() ?? '';
    final name = (_groupedSpecialContent(original) ?? original).toLowerCase();
    // 靠后出现的宣传片词条权重覆盖先前的 OVA/OAD 标签。
    // 严格按完整单词边界匹配词条，防止误伤含 `CM` 等子串的标题。
    if (_reHot34.hasMatch(name)) {
      return false;
    }
    if (_reHot35.hasMatch(name)) {
      return false;
    }
    if (name.contains('ending') && !_alternateEndingPattern.hasMatch(name)) {
      return false;
    }
    return true;
  }

  /// 从原始文件名直接解析显式特典编号（纯字符串直调，零 Map 分配）。
  static int? explicitSpecialNumberFromName(String original) {
    final content = _groupedSpecialContent(original);
    final name = content ?? original;
    final m1 = _reHot36.firstMatch(name);
    if (m1 != null) {
      final number = int.tryParse(m1.group(1) ?? '');
      if (number != null && number > 0) return number;
    }
    final m2 = _reHot37.firstMatch(name);
    if (m2 != null) {
      final number = int.tryParse(m2.group(1) ?? '');
      if (number != null && number > 0) return number;
    }
    final m3 = _reHot38.firstMatch(name);
    if (m3 != null) {
      final number = int.tryParse(m3.group(1) ?? '');
      if (number != null && number > 0) return number;
    }
    if (_reHot39.hasMatch(name)) {
      final bonus = _reHot40.firstMatch(name);
      final number = int.tryParse(bonus?.group(1) ?? '');
      if (number != null && number > 0 && number < 1900) return number;
    }
    if (!_reHot41.hasMatch(name)) {
      final m4 = _reHot42.firstMatch(name);
      if (m4 != null) {
        final number = int.tryParse(m4.group(1) ?? '');
        if (number != null && number > 0 && number < 100) return number;
      }
      final m5 = _reHot43.firstMatch(name);
      if (m5 != null) {
        final number = int.tryParse(m5.group(1) ?? '');
        if (number != null && number > 0 && number < 100) return number;
      }
    }
    return null;
  }

  static int? explicitSpecialNumber(Map<String, Object?> asset) =>
      explicitSpecialNumberFromName(asset['name']?.toString() ?? '');

  static int? _specialAirYear(Map<String, dynamic> entry) => int.tryParse(
    _reHot44.firstMatch(entry['air_date']?.toString() ?? '')?.group(1) ?? '',
  );

  /// 将英文与罗马篇章数字（`I..X`、`ONE..SIX`）归一化为阿拉伯数字，
  /// 同时保持词边界校验，使副标题比对能正确等价 `Stage I` 与 `Stage 1`。
  static String normalizeWithNumerals(String value) {
    var text = PersonalFilenameParser.unifyIdentityPunctuation(
      value,
    ).replaceAll(_reHot45, ' ').replaceAll(_reHot46, ' ');
    const multiRomans = {
      'VIII': '8',
      'VII': '7',
      'III': '3',
      'VI': '6',
      'IV': '4',
      'IX': '9',
      'II': '2',
    };
    for (final entry in multiRomans.entries) {
      text = text.replaceAll(
        RegExp('(?<![a-z0-9])${entry.key}(?![a-z0-9])', caseSensitive: false),
        entry.value,
      );
    }
    const singleMap = {'I': '1', 'V': '5', 'X': '10'};
    // 对紧跟在标题关键词后或位于末尾边界的罗马数字 `I/V/X` 做上下文保护归一化。
    text = text.replaceAllMapped(
      _reHot47,
      (m) => '${m.group(1)} ${singleMap[m.group(2)!.toUpperCase()]!}',
    );
    text = text.replaceAllMapped(
      _reHot48,
      (m) => ' ${singleMap[m.group(1)!]!}',
    );
    text = text.toLowerCase();
    const wordNumerals = {
      'sixth': '6',
      'fifth': '5',
      'fourth': '4',
      'third': '3',
      'second': '2',
      'six': '6',
      'five': '5',
      'four': '4',
      'three': '3',
      'two': '2',
    };
    for (final entry in wordNumerals.entries) {
      text = text.replaceAll(
        RegExp('\\b${entry.key}\\b', caseSensitive: false),
        entry.value,
      );
    }
    text = text.replaceAllMapped(_reHot49, (m) => '${m.group(1)} 1');
    text = text.replaceAll(_reHot50, '1');
    return text.replaceAll(_reHot51, ' ').replaceAll(_reHot7, ' ').trim();
  }

  static List<int> _partNumbersFromNormalized(String normalized) {
    final numbers = <int>[];
    for (final match in _reHot52.allMatches(normalized)) {
      final n = int.tryParse(match.group(1)!);
      if (n != null && n >= 1 && n <= 30) numbers.add(n);
    }
    return numbers;
  }

  /// 综合数字等价归一化、篇目编号冲突保护以及停用词裁剪后的词元包含关系
  /// （例如将 `Part I` 规范化后比对）来判定两段副标题是否指向同一作品内容。
  /// `The Way to Finale` -> `Finale`).
  static double subtitleSimilarity(String a, String b) {
    final normA = normalizeWithNumerals(a);
    final normB = normalizeWithNumerals(b);
    if (normA.isEmpty || normB.isEmpty) return 0;
    final compactA = normA.replaceAll(' ', '');
    final compactB = normB.replaceAll(' ', '');
    if (compactA == compactB) return 1.0;

    final numsA = _partNumbersFromNormalized(normA);
    final numsB = _partNumbersFromNormalized(normB);
    final hasConflict =
        (numsA.isNotEmpty && numsB.isNotEmpty && numsA.last != numsB.last) ||
        (numsA.isNotEmpty && numsB.isEmpty && numsA.last >= 2) ||
        (numsB.isNotEmpty && numsA.isEmpty && numsB.last >= 2);

    var best = WorkMatcher.similarity(compactA, compactB);

    // 系列首作常省略编号 `1` / `I`（如 `Side Story I` 与 `Side Story` 视为同指）。
    if ((numsA.isNotEmpty && numsB.isEmpty && numsA.last == 1) ||
        (numsB.isNotEmpty && numsA.isEmpty && numsB.last == 1)) {
      final strippedA = numsA.isNotEmpty
          ? normA.replaceFirst(_reHot53, '').trim()
          : normA;
      final strippedB = numsB.isNotEmpty
          ? normB.replaceFirst(_reHot53, '').trim()
          : normB;
      final stemSim = WorkMatcher.similarity(
        strippedA.replaceAll(' ', ''),
        strippedB.replaceAll(' ', ''),
      );
      if (stemSim >= 0.85) {
        final adjusted = (stemSim * 0.92).clamp(0.0, 0.94);
        if (adjusted > best) best = adjusted;
      }
    }

    if (!hasConflict) {
      const stopWords = {
        'the',
        'a',
        'an',
        'of',
        'to',
        'in',
        'on',
        'at',
        'for',
        'with',
        'way',
        'no',
        'and',
        'or',
        'ova',
        'oad',
        'sp',
        'special',
        'extra',
      };
      final tokensA = normA
          .split(' ')
          .where((t) => t.isNotEmpty && !stopWords.contains(t))
          .toList();
      final tokensB = normB
          .split(' ')
          .where((t) => t.isNotEmpty && !stopWords.contains(t))
          .toList();
      if (tokensA.isNotEmpty && tokensB.isNotEmpty) {
        final shorter = tokensA.length <= tokensB.length ? tokensA : tokensB;
        final longer = identical(shorter, tokensA)
            ? tokensB.toSet()
            : tokensA.toSet();
        final matched = shorter.where(longer.contains).length;
        final hasSubstantive = shorter.any(
          (t) =>
              t.length >= 2 ||
              _reHot54.hasMatch(t) ||
              (shorter.length >= 2 && matched == shorter.length),
        );
        if (hasSubstantive && matched == shorter.length) {
          final containScore = 0.76 + 0.19 * (shorter.length / longer.length);
          if (containScore > best) best = containScore;
        }
      }
    }

    if (hasConflict) {
      return best > 0.22 ? 0.22 : best;
    }
    return best;
  }

  static const _genericSubtitleTokens = <String>{
    'ova',
    'oad',
    'sp',
    'ex',
    'special',
    'specials',
    'extra',
    'extras',
    'bonus',
    'disc',
    'disk',
    'vol',
    'volume',
    'part',
    'pt',
    'episode',
    'ep',
    'chapter',
    'movie',
    'film',
    'animation',
    'anime',
    'tv',
    'bd',
    'dvd',
    'bdrip',
    'dvdrip',
    'bluray',
    'web',
    'webrip',
    'remux',
    'digest',
    'recap',
    'summary',
    'commentary',
    'drama',
    'audio',
    'preview',
    'teaser',
    'trailer',
    'opening',
    'ending',
    'menu',
    'ncop',
    'nced',
    'pv',
    'cm',
    'the',
    'a',
    'an',
    'of',
    'in',
    'on',
    'at',
    'to',
    'for',
    'with',
    'no',
    'and',
    'or',
    'ver',
    'version',
    'edition',
    'complete',
    'collection',
    'hevc',
    'avc',
    'x264',
    'x265',
    'flac',
    'aac',
    'opus',
    'ma10p',
    'hi10p',
    '10bit',
    '8bit',
    '1080p',
    '720p',
    '2160p',
    'chs',
    'cht',
    'jpsc',
    'jptc',
    'sub',
    'subs',
  };

  static const _endingStopTokens = <String>{
    'alter',
    'alternate',
    'alternative',
    'another',
    'true',
    'different',
    'epilogue',
    'end',
    'ending',
    'ed',
  };

  static Set<String> _tokensFromText(String text) =>
      normalizeWithNumerals(text).split(' ').where((t) => t.isNotEmpty).toSet();

  static List<String> _exclusiveSubtitleTokens(
    Map<String, Object?> asset,
    Set<String> workBaseTokens,
  ) {
    final original = asset['name']?.toString() ?? '';
    final content = _groupedSpecialContent(original);
    final prefixStrip = <String>{...workBaseTokens};
    if (content != null) {
      final spGroup = _reHot55.firstMatch(original);
      if (spGroup != null) {
        final prefix = cleanedExtraFilename({
          'name': '${original.substring(0, spGroup.start)}.mkv',
        });
        prefixStrip.addAll(_tokensFromText(prefix));
      }
    }
    final text = content ?? cleanedExtraFilename(asset);
    if (prefixStrip.isEmpty && content == null) {
      // 在缺乏已知作品名或成组副标题块的前提下，
      // 不将 `[OVA]`/`[SP]` 前方的主体词干视为独占副标题。
      return const [];
    }
    final normalized = normalizeWithNumerals(text);
    final result = <String>[];
    for (final raw in normalized.split(' ')) {
      final token = raw.trim();
      if (token.isEmpty) continue;
      if (_reHot56.hasMatch(token)) continue;
      if (_reHot57.hasMatch(token)) continue;
      if (_genericSubtitleTokens.contains(token)) continue;
      if (prefixStrip.contains(token)) continue;
      result.add(token);
    }
    return result;
  }

  static bool _hasExplicitOadOrOvaVolumeTag(Map<String, Object?> asset) {
    final name =
        (_groupedSpecialContent(asset['name']?.toString() ?? '') ??
                asset['name']?.toString() ??
                '')
            .toLowerCase();
    return _reHot58.hasMatch(name);
  }

  static String _specialAssetSubfamily(Map<String, Object?> asset) {
    final baseType = specialType(asset);
    final family = _specialFamily(baseType);
    if (family != 'OVA' && family != 'SP') return family;
    final original = asset['name']?.toString() ?? '';
    final effective = _groupedSpecialContent(original) ?? original;
    final hasOvaInText = _reHot59.hasMatch(effective);
    final hasSpInText = _reHot60.hasMatch(effective);
    if (hasOvaInText && hasSpInText) return 'OVA_SP';
    if (!hasSpInText &&
        !_reHot41.hasMatch(effective) &&
        _reHot61.hasMatch(effective)) {
      return 'OVA';
    }
    if (family == 'SP') {
      final path = '${asset['relative_path'] ?? ''}'.replaceAll('\\', '/');
      final segments = path.split('/');
      final parentDirs = segments.length > 1
          ? segments.sublist(0, segments.length - 1)
          : const <String>[];
      if (parentDirs.any((s) => _reHot62.hasMatch(s))) {
        return 'OVA_SP';
      }
    }
    return family;
  }

  static String _specialEntrySubfamily(Map<String, dynamic> entry) {
    final name = entry['name']?.toString() ?? '';
    final hasOva = _reHot59.hasMatch(name);
    final hasSp = _reHot60.hasMatch(name);
    if (hasOva && hasSp) return 'OVA_SP';
    if (hasOva) return 'OVA';
    if (hasSp) return 'SP';
    final runtime = (entry['runtime'] as num?)?.toInt() ?? 0;
    final overviewText = entry['overview']?.toString() ?? '';
    if (runtime >= 15 && _reHot63.hasMatch(overviewText)) {
      return 'OVA';
    }
    final combined = '$name ${entry['overview'] ?? ''}';
    if (_alternateEndingPattern.hasMatch(combined)) return 'SP';
    return '';
  }

  static int? _extractEpisodeClueFromSpecialAsset(Map<String, Object?> asset) {
    final original = asset['name']?.toString() ?? '';
    var text = _groupedSpecialContent(original) ?? cleanedExtraFilename(asset);
    text = text
        .replaceAll(_reHot64, ' ')
        .replaceAll(_reHot65, ' ')
        .replaceAll(_reHot66, ' ');
    final match = _reHot67.firstMatch(text);
    final value = int.tryParse(match?.group(1) ?? '');
    if (value == null || value <= 0 || value >= 1900) return null;
    return value;
  }

  static int? _parseChineseOrArabicSeasonNumber(String token) {
    final numeric = int.tryParse(token);
    if (numeric != null) return numeric;
    const digits = {
      '一': 1,
      '二': 2,
      '两': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
      'Ⅰ': 1,
      'Ⅱ': 2,
      'Ⅲ': 3,
      'Ⅳ': 4,
    };
    return digits[token];
  }

  static Set<int> _explicitSeasonMarkersInMetadata(String text) {
    final found = <int>{};
    final patterns = <RegExp>[_reHot68, _reHot69, _reHot70, _reHot71, _reHot72];
    for (final p in patterns) {
      for (final m in p.allMatches(text)) {
        final parsed = _parseChineseOrArabicSeasonNumber(m.group(1)!);
        if (parsed != null && parsed > 0 && parsed <= 20) found.add(parsed);
      }
    }
    return found;
  }

  static int _entrySeasonAffinity(
    Map<String, dynamic> entry,
    int? targetSeason,
    String? seasonName,
  ) {
    final name = entry['name']?.toString() ?? '';
    final overview = entry['overview']?.toString() ?? '';
    final combined = '$name $overview';
    var score = 0;
    if (targetSeason != null && targetSeason > 0) {
      final markers = _explicitSeasonMarkersInMetadata(combined);
      if (markers.contains(targetSeason)) {
        score += 40;
      } else if (markers.isNotEmpty) {
        score -= 80;
      }
    }
    final rawSeasonName = seasonName?.trim() ?? '';
    if (rawSeasonName.isNotEmpty && !_reHot73.hasMatch(rawSeasonName)) {
      final tokens = _tokensFromText(rawSeasonName)
          .where(
            (t) =>
                !_genericSubtitleTokens.contains(t) &&
                (t.length >= 3 || _reHot54.hasMatch(t)),
          )
          .toList();
      if (tokens.isNotEmpty) {
        final entryTokens = _tokensFromText(combined);
        final hits = tokens.where(entryTokens.contains).length;
        if (hits == tokens.length || (hits >= 1 && hits * 2 >= tokens.length)) {
          score += 35;
        }
      }
    }
    return score;
  }

  static int? _relativeSpecialNumberFromTitle(String title) {
    final stripped = title
        .replaceAll(_reHot74, ' ')
        .replaceAll(_reHot75, ' ')
        .replaceAll(_reHot76, ' ')
        .replaceAll(_reHot77, ' ');
    return explicitSpecialNumber({'name': stripped});
  }

  /// 优先匹配显式 `OVA/SP` 编号，其次综合副标题、语义关键词与季度对齐，
  /// 最后按同类型稳定顺序分配；计算得到的映射结果仅写入 TMDB 缓存，
  /// 绝不会重命名任何媒体源中的原始文件。
  /// 仅更新本地缓存映射表以保证媒体源只读安全。
  static Map<String, Map<String, dynamic>> mapSpecialEpisodes({
    required List<Map<String, Object?>> assets,
    required List<Map<String, dynamic>> specials,
    String? yearHint,
    String? workTitle,
    int? seasonNumber,
    String? seasonName,
  }) {
    final result = <String, Map<String, dynamic>>{};
    final claimed = <int>{};
    final matchedPaths = <String>{};

    String assetKey(Map<String, Object?> asset) =>
        asset['relative_path']?.toString() ?? asset['name']?.toString() ?? '';

    final yearInt = int.tryParse(
      _reHot78.firstMatch(yearHint ?? '')?.group(1) ?? '',
    );
    final effectiveSeason =
        seasonNumber ?? _seasonFromText('${workTitle ?? ''} ${yearHint ?? ''}');

    final workBaseTokens = <String>{
      if (workTitle != null && workTitle.trim().isNotEmpty)
        ..._tokensFromText(workTitle),
      if (yearHint != null && yearHint.trim().isNotEmpty)
        ..._tokensFromText(
          yearHint
              .replaceAll(_reHot45, ' ')
              .replaceAll(_reHot46, ' ')
              .replaceAll(_reHot79, ' ')
              .replaceAll(_reHot80, ' '),
        ),
    };

    bool isRecap(Map<String, dynamic> entry) =>
        _reHot81.hasMatch('${entry['name'] ?? ''}');

    bool inYearWindow(Map<String, dynamic> entry) {
      if (yearInt == null) return true;
      final airYear = _specialAirYear(entry);
      return airYear == null || (airYear - yearInt).abs() <= 1;
    }

    // 第一轮：独占副标题高置信绑定（支持跨年份外传匹配如 `[SP07] [Show Evol OVA]`，
    // 同时拦截泛化文件名 `Show [OVA].mkv` 发生误绑）。
    final allCandidates = assets.where(isSpecialMappingCandidate).toList()
      ..sort((a, b) => assetKey(a).compareTo(assetKey(b)));
    for (final asset in allCandidates) {
      final exclusive = _exclusiveSubtitleTokens(asset, workBaseTokens);
      final distinctive = exclusive
          .where((t) => !_endingStopTokens.contains(t))
          .toList();
      if (distinctive.isEmpty) continue;
      final hasSubstantiveToken = distinctive.any(
        (t) => t.length >= 3 || _reHot54.hasMatch(t),
      );
      if (!hasSubstantiveToken) continue;

      final original = asset['name']?.toString() ?? '';
      final assetSub =
          _groupedSpecialContent(original) ?? cleanedExtraFilename(asset);
      final subfamily = _specialAssetSubfamily(asset);

      Map<String, dynamic>? bestInYear;
      var bestInYearScore = 0.0;
      Map<String, dynamic>? bestCrossYear;
      var bestCrossYearScore = 0.0;

      for (final entry in specials) {
        if (claimed.contains(_specialOrder(entry)) || isRecap(entry)) continue;
        final entryFamily = _specialEntrySubfamily(entry);
        if (subfamily == 'OVA' && entryFamily == 'SP') continue;
        if (subfamily == 'SP' && entryFamily == 'OVA') continue;

        final entryName = entry['name']?.toString() ?? '';
        final entryTokens = _tokensFromText(entryName);
        final hits = distinctive.where(entryTokens.contains).length;
        final hasSubstantiveHit = distinctive.any(
          (t) =>
              entryTokens.contains(t) &&
              (t.length >= 3 || _reHot54.hasMatch(t)),
        );
        final sim = subtitleSimilarity(assetSub, entryName);
        final coverage = hits / distinctive.length;
        if (!hasSubstantiveHit && sim < 0.78) continue;
        if (coverage < 0.7 && sim < 0.72) continue;

        final combinedScore = coverage * 0.6 + sim * 0.4;
        final affinityBonus =
            _entrySeasonAffinity(entry, effectiveSeason, seasonName) * 0.002;
        final totalScore = combinedScore + affinityBonus;

        if (inYearWindow(entry)) {
          if (totalScore > bestInYearScore) {
            bestInYearScore = totalScore;
            bestInYear = entry;
          }
        } else {
          if (totalScore > bestCrossYearScore) {
            bestCrossYearScore = totalScore;
            bestCrossYear = entry;
          }
        }
      }

      final chosen =
          bestInYear ?? (bestCrossYearScore >= 0.7 ? bestCrossYear : null);
      if (chosen != null) {
        final key = assetKey(asset);
        claimed.add(_specialOrder(chosen));
        matchedPaths.add(key);
        result[key] = chosen;
      }
    }

    // 第二轮：按子类别分组处理剩余特典资源（顺序：`OVA -> SP -> OVA_SP`）。
    final assetsByType = <String, List<Map<String, Object?>>>{};
    for (final asset in allCandidates) {
      if (matchedPaths.contains(assetKey(asset))) continue;
      assetsByType
          .putIfAbsent(_specialAssetSubfamily(asset), () => [])
          .add(asset);
    }

    int compareWithSeasonAffinity(
      Map<String, dynamic> a,
      Map<String, dynamic> b,
    ) {
      final affA = _entrySeasonAffinity(a, effectiveSeason, seasonName);
      final affB = _entrySeasonAffinity(b, effectiveSeason, seasonName);
      if (affA != affB) return affB.compareTo(affA);
      return _compareSpecialEpisode(a, b);
    }

    List<Map<String, dynamic>> narrowBySeasonAffinity(
      List<Map<String, dynamic>> pool,
      int minCount,
    ) {
      if (pool.length <= minCount ||
          (effectiveSeason == null &&
              (seasonName == null || seasonName.trim().isEmpty))) {
        return pool;
      }
      final preferred = pool
          .where(
            (e) => _entrySeasonAffinity(e, effectiveSeason, seasonName) > 0,
          )
          .toList();
      if (preferred.length >= minCount) return preferred;
      final compatible = pool
          .where(
            (e) => _entrySeasonAffinity(e, effectiveSeason, seasonName) >= 0,
          )
          .toList();
      if (compatible.length >= minCount) return compatible;
      return pool;
    }

    void assignAssets(
      List<Map<String, Object?>> group,
      List<Map<String, dynamic>> pool, {
      required bool allowDirectEpisodeMatch,
    }) {
      if (group.isEmpty || pool.isEmpty) return;
      final sortedPool = [...pool]..sort(compareWithSeasonAffinity);
      var nextIndex = 0;

      // 检测第 0 季中连续编号的短篇子系列（便于成段按序对齐）。
      // "小加速世界 1..8" spanning S00E01,02,04..07,09,10 around interleaved OVAs).
      final prefixBuckets = <String, Map<int, List<Map<String, dynamic>>>>{};
      final prefixRegex = _reHot82;
      for (final e in sortedPool) {
        if (claimed.contains(_specialOrder(e))) continue;
        final name = e['name']?.toString().trim() ?? '';
        final m = prefixRegex.firstMatch(name);
        if (m == null) continue;
        final normPrefix = m.group(1)!.toLowerCase().replaceAll(_reHot83, '');
        final numVal = int.tryParse(m.group(2)!);
        if (normPrefix.isEmpty || numVal == null) continue;
        (prefixBuckets.putIfAbsent(normPrefix, () => {})[numVal] ??= []).add(e);
      }
      final assetExplicitNums = {
        for (final a in group)
          if (explicitSpecialNumber(a) != null) explicitSpecialNumber(a)!,
      };
      Map<int, Map<String, dynamic>>? subSeriesByNum;
      if (assetExplicitNums.length >= 3) {
        for (final entry in prefixBuckets.entries) {
          final byNum = entry.value;
          if (byNum.length < 3) continue;
          final hasShiftedOrder = byNum.entries.any(
            (kv) => kv.value.any((e) => _specialOrder(e) != kv.key),
          );
          final overlap = assetExplicitNums.where(byNum.containsKey).length;
          if (hasShiftedOrder && overlap >= 3) {
            subSeriesByNum = {
              for (final kv in byNum.entries) kv.key: kv.value.first,
            };
            break;
          }
        }
      }

      // 在多季共享特别篇池中（例如第 2 季对应 S0E07..S0E12 且命名为 `SP1..SP6`），
      // 核验条目标题是否携带与当前资源一致的相对编号。
      final useRelativeTitleNumbers =
          !allowDirectEpisodeMatch &&
          group.any((a) => explicitSpecialNumber(a) != null) &&
          sortedPool.any((e) {
            final rel = _relativeSpecialNumberFromTitle(
              e['name']?.toString() ?? '',
            );
            return rel != null && rel != _specialOrder(e);
          });

      for (final asset in group) {
        final key = assetKey(asset);
        if (matchedPaths.contains(key)) continue;
        final explicit = explicitSpecialNumber(asset);
        var selected = -1;
        if (subSeriesByNum != null && explicit != null) {
          final subEntry = subSeriesByNum[explicit];
          if (subEntry != null && !claimed.contains(_specialOrder(subEntry))) {
            selected = sortedPool.indexOf(subEntry);
          }
        }
        if (selected < 0 && allowDirectEpisodeMatch && explicit != null) {
          selected = sortedPool.indexWhere(
            (entry) =>
                int.tryParse('${entry['episode_number']}') == explicit &&
                !claimed.contains(_specialOrder(entry)),
          );
        } else if (useRelativeTitleNumbers && explicit != null) {
          final matches = <int>[];
          for (var i = 0; i < sortedPool.length; i++) {
            final entry = sortedPool[i];
            if (claimed.contains(_specialOrder(entry))) continue;
            if (_relativeSpecialNumberFromTitle(
                  entry['name']?.toString() ?? '',
                ) ==
                explicit) {
              matches.add(i);
            }
          }
          if (matches.length == 1) {
            selected = matches.single;
          }
        }
        if (selected < 0) {
          while (nextIndex < sortedPool.length &&
              claimed.contains(_specialOrder(sortedPool[nextIndex]))) {
            nextIndex++;
          }
          if (nextIndex < sortedPool.length) selected = nextIndex;
        }
        if (selected < 0) continue;
        final entry = sortedPool[selected];
        claimed.add(_specialOrder(entry));
        matchedPaths.add(key);
        result[key] = entry;
      }
    }

    void assignUnnumberedWithSemantics(
      List<Map<String, Object?>> group,
      List<Map<String, dynamic>> pool,
    ) {
      if (group.isEmpty || pool.isEmpty) return;
      final remainingPool =
          pool.where((e) => !claimed.contains(_specialOrder(e))).toList()
            ..sort(compareWithSeasonAffinity);
      if (remainingPool.isEmpty) return;

      double semanticScore(
        Map<String, Object?> asset,
        Map<String, dynamic> entry,
      ) {
        final original = asset['name']?.toString() ?? '';
        final assetText =
            _groupedSpecialContent(original) ?? cleanedExtraFilename(asset);
        final epClue = _extractEpisodeClueFromSpecialAsset(asset);
        final isAltEnd = _alternateEndingPattern.hasMatch(assetText);

        final entryName = entry['name']?.toString() ?? '';
        final entryOverview = entry['overview']?.toString() ?? '';
        final entryCombined = '$entryName $entryOverview';
        var score = _entrySeasonAffinity(
          entry,
          effectiveSeason,
          seasonName,
        ).toDouble();

        if (epClue != null) {
          final strippedCombined = entryCombined.replaceAll(_reHot64, ' ');
          final epRegex = RegExp(
            '(?:\\b(?:episode|ep|special|#)\\s*0?$epClue\\b|第\\s*0?$epClue\\s*[话話集]|(?<!\\d)0?$epClue(?!\\d))',
            caseSensitive: false,
          );
          if (epRegex.hasMatch(strippedCombined)) {
            score += 80;
          } else {
            final otherEp = _reHot84.firstMatch(strippedCombined);
            final foundEp = int.tryParse(
              otherEp?.group(1) ?? otherEp?.group(2) ?? '',
            );
            if (foundEp != null && foundEp != epClue) {
              score -= 60;
            }
          }
        }

        if (isAltEnd) {
          if (_alternateEndingPattern.hasMatch(entryCombined) ||
              _reHot85.hasMatch(entryCombined)) {
            score += 70;
          }
        }

        score += subtitleSimilarity(assetText, entryName) * 50;
        if (yearInt != null) {
          final airYear = _specialAirYear(entry);
          if (airYear == yearInt) {
            score += 15;
          } else if (airYear == yearInt + 1) {
            score += 10;
          } else if (airYear == yearInt - 1) {
            score += 5;
          }
        }
        return score;
      }

      // 检查资源是否包含语义或集数线索，决定是否需按最高分最优配对。
      final hasClues = group.any((a) {
        final original = a['name']?.toString() ?? '';
        final text =
            _groupedSpecialContent(original) ?? cleanedExtraFilename(a);
        return _extractEpisodeClueFromSpecialAsset(a) != null ||
            _alternateEndingPattern.hasMatch(text);
      });

      if (!hasClues) {
        assignAssets(group, remainingPool, allowDirectEpisodeMatch: false);
        return;
      }

      final usedEntries = <int>{};
      final pairs = <({int assetIdx, int entryIdx, double score})>[];
      for (var i = 0; i < group.length; i++) {
        for (var j = 0; j < remainingPool.length; j++) {
          pairs.add((
            assetIdx: i,
            entryIdx: j,
            score: semanticScore(group[i], remainingPool[j]),
          ));
        }
      }
      pairs.sort((a, b) {
        final cmp = b.score.compareTo(a.score);
        if (cmp != 0) return cmp;
        final epCmp = _specialOrder(
          remainingPool[a.entryIdx],
        ).compareTo(_specialOrder(remainingPool[b.entryIdx]));
        if (epCmp != 0) return epCmp;
        return a.assetIdx.compareTo(b.assetIdx);
      });

      final matchedAssets = <int>{};
      for (final pair in pairs) {
        if (matchedAssets.contains(pair.assetIdx) ||
            usedEntries.contains(pair.entryIdx)) {
          continue;
        }
        final asset = group[pair.assetIdx];
        final entry = remainingPool[pair.entryIdx];
        final key = assetKey(asset);
        matchedAssets.add(pair.assetIdx);
        usedEntries.add(pair.entryIdx);
        claimed.add(_specialOrder(entry));
        matchedPaths.add(key);
        result[key] = entry;
      }
    }

    List<Map<String, dynamic>> unnumberedPoolForYear(
      List<Map<String, dynamic>> allTypeSpecials,
      int targetYear,
      int neededCount,
    ) {
      final combined = <Map<String, dynamic>>[];
      for (final candidateYear in [
        targetYear,
        targetYear + 1,
        targetYear - 1,
      ]) {
        final bucket = allTypeSpecials
            .where(
              (entry) =>
                  !claimed.contains(_specialOrder(entry)) &&
                  _specialAirYear(entry) == candidateYear,
            )
            .toList();
        if (bucket.isNotEmpty) {
          combined.addAll(bucket);
          if (neededCount <= 1 && combined.isNotEmpty) {
            return narrowBySeasonAffinity(combined, neededCount);
          }
        }
      }
      return narrowBySeasonAffinity(combined, neededCount);
    }

    final hasShortSpecials = specials.any((e) {
      final r = (e['runtime'] as num?)?.toInt() ?? 0;
      return r > 0 && r <= 12;
    });
    final hasFullSpecials = specials.any((e) {
      final r = (e['runtime'] as num?)?.toInt() ?? 0;
      return r >= 18;
    });
    final hasMixedShortAndFullRuntime = hasShortSpecials && hasFullSpecials;
    bool isUnshiftedOneBasedPrefix(List<Map<String, dynamic>> pool) {
      if (pool.isEmpty) return false;
      for (var i = 0; i < pool.length; i++) {
        if (_specialOrder(pool[i]) != i + 1) return false;
      }
      return true;
    }

    for (final family in _matchableSpecialFamilies) {
      final typeAssets = assetsByType[family];
      if (typeAssets == null || typeAssets.isEmpty) continue;

      final allTypeSpecials = specials
          .where(
            (entry) =>
                !claimed.contains(_specialOrder(entry)) &&
                _specialEntrySubfamily(entry) == family,
          )
          .toList();
      if (family == 'OVA' &&
          (hasMixedShortAndFullRuntime ||
              allTypeSpecials.length < typeAssets.length)) {
        final seenOrders = {
          for (final entry in allTypeSpecials) _specialOrder(entry),
        };
        for (final entry in specials) {
          final order = _specialOrder(entry);
          final runtime = (entry['runtime'] as num?)?.toInt() ?? 0;
          if (!claimed.contains(order) &&
              !seenOrders.contains(order) &&
              !isRecap(entry) &&
              _specialEntrySubfamily(entry).isEmpty &&
              runtime >= 18) {
            allTypeSpecials.add(entry);
            seenOrders.add(order);
          }
        }
        allTypeSpecials.sort(_compareSpecialEpisode);
      } else if (family == 'SP' && allTypeSpecials.length < typeAssets.length) {
        final seenOrders = {
          for (final entry in allTypeSpecials) _specialOrder(entry),
        };
        for (final entry in specials) {
          final order = _specialOrder(entry);
          final runtime = (entry['runtime'] as num?)?.toInt() ?? 0;
          if (!claimed.contains(order) &&
              !seenOrders.contains(order) &&
              !isRecap(entry) &&
              _specialEntrySubfamily(entry).isEmpty &&
              !(hasMixedShortAndFullRuntime && runtime >= 18)) {
            allTypeSpecials.add(entry);
            seenOrders.add(order);
          }
        }
        allTypeSpecials.sort(_compareSpecialEpisode);
      }

      final numberedAssets =
          typeAssets.where((a) => explicitSpecialNumber(a) != null).toList()
            ..sort((a, b) {
              final x = explicitSpecialNumber(a) ?? 999999;
              final y = explicitSpecialNumber(b) ?? 999999;
              if (x != y) return x.compareTo(y);
              return assetKey(a).compareTo(assetKey(b));
            });
      final unnumberedAssets =
          typeAssets.where((a) => explicitSpecialNumber(a) == null).toList()
            ..sort((a, b) => assetKey(a).compareTo(assetKey(b)));

      // 仅当 OVA 合集明确附带独立 `OAD/OVA` 卷标时，允许其优先占位数号槽位
      // （例如主 OVA 附带 OAD + OVA 01..06）；
      // 对于 SP 组合（例如 `SP1..2 + 03/04` 分支结局），必须先锁定编号 `1..2` 的槽位，
      // 再让无标准编号的分支结局随后按语义对齐。
      final preemptStandaloneOad =
          family == 'OVA' &&
          unnumberedAssets.isNotEmpty &&
          numberedAssets.length >= 2 &&
          unnumberedAssets.any(_hasExplicitOadOrOvaVolumeTag);

      if (preemptStandaloneOad) {
        final standaloneOads = unnumberedAssets
            .where(_hasExplicitOadOrOvaVolumeTag)
            .toList();
        final standalonePool = yearInt != null
            ? unnumberedPoolForYear(
                allTypeSpecials,
                yearInt,
                standaloneOads.length,
              )
            : narrowBySeasonAffinity(allTypeSpecials, standaloneOads.length);
        assignAssets(
          standaloneOads,
          standalonePool,
          allowDirectEpisodeMatch: false,
        );
      }

      if (numberedAssets.isNotEmpty) {
        var numberedPool = allTypeSpecials
            .where((e) => !claimed.contains(_specialOrder(e)))
            .toList();
        numberedPool = narrowBySeasonAffinity(
          numberedPool,
          numberedAssets.length,
        );
        var allowDirect =
            yearInt == null &&
            numberedPool.length == allTypeSpecials.length &&
            isUnshiftedOneBasedPrefix(numberedPool);
        if (yearInt != null) {
          final exactYear = numberedPool
              .where((e) => _specialAirYear(e) == yearInt)
              .toList();
          final nearYears = numberedPool
              .where(
                (e) =>
                    _specialAirYear(e) == yearInt ||
                    _specialAirYear(e) == yearInt + 1,
              )
              .toList();
          if (exactYear.length >= numberedAssets.length) {
            numberedPool = narrowBySeasonAffinity(
              exactYear,
              numberedAssets.length,
            );
            allowDirect =
                exactYear.length == allTypeSpecials.length &&
                isUnshiftedOneBasedPrefix(numberedPool);
          } else if (nearYears.length >= numberedAssets.length) {
            numberedPool = narrowBySeasonAffinity(
              nearYears,
              numberedAssets.length,
            );
            allowDirect =
                nearYears.length == allTypeSpecials.length &&
                isUnshiftedOneBasedPrefix(numberedPool);
          } else if (numberedAssets.length >= 2) {
            final yearRun = specials
                .where(
                  (e) =>
                      !claimed.contains(_specialOrder(e)) &&
                      _specialEntrySubfamily(e) !=
                          (family == 'OVA' ? 'SP' : 'OVA') &&
                      (_specialAirYear(e) == yearInt ||
                          _specialAirYear(e) == yearInt + 1) &&
                      !isRecap(e),
                )
                .toList();
            if (yearRun.length >= numberedAssets.length) {
              numberedPool = narrowBySeasonAffinity(
                yearRun,
                numberedAssets.length,
              );
              allowDirect = false;
            } else {
              final explicitTypes = numberedAssets
                  .map(specialType)
                  .whereType<String>()
                  .toSet();
              final sameSubtype = numberedPool
                  .where(
                    (e) => explicitTypes.contains(
                      specialTypeFromTitle(e['name']?.toString() ?? ''),
                    ),
                  )
                  .toList();
              if (sameSubtype.isNotEmpty) numberedPool = sameSubtype;
            }
          } else if (exactYear.isEmpty) {
            final explicitTypes = numberedAssets
                .map(specialType)
                .whereType<String>()
                .toSet();
            final sameSubtype = numberedPool
                .where(
                  (e) => explicitTypes.contains(
                    specialTypeFromTitle(e['name']?.toString() ?? ''),
                  ),
                )
                .toList();
            if (sameSubtype.isNotEmpty) numberedPool = sameSubtype;
          } else {
            numberedPool = exactYear;
          }
        }
        assignAssets(
          numberedAssets,
          numberedPool,
          allowDirectEpisodeMatch: allowDirect,
        );
      }

      // 所有未编号资源统一安排在已编号资源锁定槽位之后再执行匹配。
      final remainingUnnumbered = unnumberedAssets
          .where((a) => !matchedPaths.contains(assetKey(a)))
          .toList();
      if (remainingUnnumbered.isNotEmpty) {
        var unnumberedPool = yearInt != null
            ? unnumberedPoolForYear(
                allTypeSpecials,
                yearInt,
                remainingUnnumbered.length,
              )
            : narrowBySeasonAffinity(
                allTypeSpecials
                    .where((e) => !claimed.contains(_specialOrder(e)))
                    .toList(),
                remainingUnnumbered.length,
              );
        // 对于带有分支结局或特典集线索的 SP，额外检索 `yearInt ± 1` 区间内
        // 尚未被认领且简介提及结局或对应话数的第 0 季条目。
        if (family == 'SP' &&
            unnumberedPool.length < remainingUnnumbered.length) {
          final extraCandidates = specials.where((e) {
            if (claimed.contains(_specialOrder(e)) || isRecap(e)) return false;
            final sub = _specialEntrySubfamily(e);
            if (sub == 'OVA') return false;
            if (!inYearWindow(e)) return false;
            return !unnumberedPool.any(
              (u) => _specialOrder(u) == _specialOrder(e),
            );
          }).toList();
          unnumberedPool = narrowBySeasonAffinity([
            ...unnumberedPool,
            ...extraCandidates,
          ], remainingUnnumbered.length);
        }
        assignUnnumberedWithSemantics(remainingUnnumbered, unnumberedPool);
      }

      // 混合特典兜底：若第 0 季专属条目缺失或已用尽，
      // 回退至未被占用的 SP 条目并结合年份/季度/简介线索匹配。
      if (family == 'OVA_SP') {
        final leftOver = typeAssets
            .where((a) => !matchedPaths.contains(assetKey(a)))
            .toList();
        if (leftOver.isNotEmpty) {
          final fallbackPool =
              specials.where((e) {
                if (claimed.contains(_specialOrder(e)) || isRecap(e)) {
                  return false;
                }
                final sub = _specialEntrySubfamily(e);
                if (sub != 'SP' && sub.isNotEmpty) return false;
                return inYearWindow(e);
              }).toList()..sort((a, b) {
                final ovaHintA =
                    _reHot86.hasMatch(
                      '${a['name'] ?? ''} ${a['overview'] ?? ''}',
                    )
                    ? 1
                    : 0;
                final ovaHintB =
                    _reHot86.hasMatch(
                      '${b['name'] ?? ''} ${b['overview'] ?? ''}',
                    )
                    ? 1
                    : 0;
                if (ovaHintA != ovaHintB) return ovaHintB.compareTo(ovaHintA);
                return compareWithSeasonAffinity(a, b);
              });
          assignAssets(
            leftOver,
            narrowBySeasonAffinity(fallbackPool, leftOver.length),
            allowDirectEpisodeMatch: false,
          );
        }
      }
    }
    return result;
  }

  static Map<Object?, Object?>? specialEpisode(
    Map<String, Object?> asset,
    Map<String, dynamic> seasons,
  ) {
    if (!isSpecialMappingCandidate(asset)) return null;
    final key =
        asset['relative_path']?.toString() ?? asset['name']?.toString() ?? '';
    final mapped = seasons['special_assets'];
    if (mapped is Map && mapped[key] is Map) {
      return Map<String, dynamic>.from(mapped[key] as Map);
    }
    final explicit = explicitSpecialNumber(asset);
    if (explicit == null) return null;
    final entries = seasons['0'];
    if (entries is! List) return null;
    for (final entry in entries.whereType<Map<Object?, Object?>>()) {
      if (int.tryParse('${entry['episode_number']}') == explicit) {
        return entry;
      }
    }
    return null;
  }

  static String? specialTypeFromTitle(String value) {
    final match = _reHot87.firstMatch(value);
    return match?.group(2)?.toUpperCase();
  }

  /// 压制组命名常将 TMDB 标注的 `OAD` 称为 `OVA`（反之亦然），
  /// 二者共享同一特别篇候选池，而 `SP` 序列保持独立。
  static String _specialFamily(String? type) =>
      type == 'OVA' || type == 'OAD' || type == 'EX' ? 'OVA' : type ?? '';

  static int _specialOrder(Map<String, dynamic> entry) =>
      int.tryParse('${entry['episode_number']}') ?? 999999;

  static int _compareSpecialEpisode(
    Map<String, dynamic> a,
    Map<String, dynamic> b,
  ) => _specialOrder(a).compareTo(_specialOrder(b));

  /// 预编译热点正则表达式（避免在逐文件遍历与归组打分热路径中重复编译）。
  static final RegExp _reHot1 = RegExp(r'^[A-Fa-f0-9]{8}$');
  static final RegExp _reHot2 = RegExp(r'[\s_./,+&-]+');
  static final RegExp _reHot3 = RegExp(
    r'\.(?:mkv|mp4|avi|mov|m4v|ts|m2ts|webm)$',
    caseSensitive: false,
  );
  static final RegExp _reHot4 = RegExp(r'\[([^\]]*)\]|【([^】]*)】|\(([^)]*)\)');
  static final RegExp _reHot5 = RegExp(
    r'(?:字幕组|字幕組|压制组|壓製組|VCB-Studio|SweetSub|sub(?:s)?\b|Encode|Rip)',
    caseSensitive: false,
  );
  static final RegExp _reHot6 = RegExp(r'_|(?<!\d)\.|\.(?!\d)');
  static final RegExp _reHot7 = RegExp(r'\s+');
  static final RegExp _reHot8 = RegExp(r'^[\s-]+|[\s-]+$');
  static final RegExp _reHot9 = RegExp(r'\[SP\d{1,3}\]', caseSensitive: false);
  static final RegExp _reHot10 = RegExp(
    r'(?:^|[\s._\-–—])SP\d{1,3}\s*(?=\[)',
    caseSensitive: false,
  );
  static final RegExp _reHot11 = RegExp(
    r'\.(?:mkv|mp4|avi|mov|m4v|ts|m2ts|webm|png|jpe?g)$',
    caseSensitive: false,
  );
  static final RegExp _reHot12 = RegExp(r'^[\s_-]+|[\s_-]+$');
  static final RegExp _reHot13 = RegExp(
    r'[a-z\u3040-\u9fff]',
    caseSensitive: false,
  );
  static final RegExp _reHot14 = RegExp(
    r'\([^)]*(?:\bBD\b|1080|1920|x\.?26[45]|Flac)[^)]*\)',
    caseSensitive: false,
  );
  static final RegExp _reHot15 = RegExp(
    r'\[\s*(?:PNG|JPEG)\s*\]',
    caseSensitive: false,
  );
  static final RegExp _reHot16 = RegExp(
    r'\[(?:\d{3,4}p|HEVC\d*|FLAC\d*|Hi10p|x26[45])\]',
    caseSensitive: false,
  );
  static final RegExp _reHot17 = RegExp(r'\[(\d{1,3}\.\d{1,2})(?=\]|\()');
  static final RegExp _reHot18 = RegExp(
    r'(^|[^a-z0-9])(IV)[ ._-]?(\d{1,3})(?=[^a-z0-9]|$)',
    caseSensitive: false,
  );
  static final RegExp _reHot19 = RegExp(
    r'\[([a-z]{1,8})[ ._-]?(\d{1,3}[a-z]?)\]',
    caseSensitive: false,
  );
  static final RegExp _reHot20 = RegExp(r'[ ._-]');
  static final RegExp _reHot21 = RegExp(r'^specials?$', caseSensitive: false);
  static final RegExp _reHot22 = RegExp(
    r'(?<![a-z])(?:ncop(?:ed)?|nced|opening|menu|pv|cm|tvcm|bdcm|pvcm|trailer|preview|teaser)(?![a-z])',
    caseSensitive: false,
  );
  static final RegExp _reHot23 = RegExp(
    r'(?<![a-z0-9])(?:ncop(?:ed)?|nced|op\d*|ed\d*|opening\d*|ending\d*|menu\d*|pv\d*|cm\d*|tvcm|bdcm|pvcm|spot|trailer|preview|teaser|making|interview|promotion|promo|info|information|logo|eyecatch|artwork|digest|creditless|textless|mv|live|voice|audio|drama|commentary)(?![a-z0-9])',
    caseSensitive: false,
  );
  static final RegExp _reHot24 = RegExp(r'\[\d{1,3}\.\d{1,2}(?=\]|\()');
  static final RegExp _reHot25 = RegExp(
    r'\[\s*\d{1,3}\s*[\(（]\s*(OAD|OVA|SP|Special)\s*[\)）]\s*\]',
    caseSensitive: false,
  );
  static final RegExp _reHot26 = RegExp(
    r'(?<![a-z])(?:ncop(?:ed)?|nced|opening|menu|pv|cm|tvcm|bdcm|pvcm|trailer|preview|teaser)(?![a-z])',
    caseSensitive: false,
  );
  static final RegExp _reHot27 = RegExp(
    r'(^|/)menus?(/|$)',
    caseSensitive: false,
  );
  static final RegExp _reHot28 = RegExp(r'[ ._-]+');
  static final RegExp _reHot29 = RegExp(
    r'(?<![a-z0-9])S(\d{1,2})[ ._]*(?:[+&~～]|[-–—])[ ._]*S?(\d{1,2})(?![a-z0-9])',
    caseSensitive: false,
  );
  static final RegExp _reHot30 = RegExp(
    r'(?<![a-z0-9])S(\d{1,2})(?=E\d|[^a-z0-9]|$)',
    caseSensitive: false,
  );
  static final RegExp _reHot31 = RegExp(
    r'(?<![a-z])Season[ ._-]*(\d{1,2})(?!\d)',
    caseSensitive: false,
  );
  static final RegExp _reHot32 = RegExp(
    r'(?<![a-z0-9])(\d{1,2})(?:st|nd|rd|th)[ ._-]+Season\b',
    caseSensitive: false,
  );
  static final RegExp _reHot33 = RegExp(
    r'第[ ._-]*([0-9一二三四五六七八九十两]+)[ ._-]*[季期]',
  );
  static final RegExp _reHot34 = RegExp(
    r'(^|[^a-z0-9])(?:tvcm|bdcm|pvcm|cm|pv)(?:[\s._-]*\d+)?(?=[^a-z0-9]|$)',
  );
  static final RegExp _reHot35 = RegExp(
    r'menu|trailer|preview|teaser|opening|ncop|nced',
  );
  static final RegExp _reHot36 = RegExp(
    r'\b(?:OVA|OAD|SP)(?:[\s._]*[-–—][\s._]*|[\s._-]+|\s*)(\d{1,3})\b',
    caseSensitive: false,
  );
  static final RegExp _reHot37 = RegExp(
    r'[\[(](?:OVA|OAD|SP)(?:[\s._]*[-–—][\s._]*|[\s._-]+|\s*)(\d{1,3})[\])]',
    caseSensitive: false,
  );
  static final RegExp _reHot38 = RegExp(
    r'[\[(]\d+\((?:OVA|OAD|SP)[\s._-]*(\d{1,3})\)[\])]',
    caseSensitive: false,
  );
  static final RegExp _reHot39 = RegExp(
    r'\b(?:OVA|OAD)\b',
    caseSensitive: false,
  );
  static final RegExp _reHot40 = RegExp(
    r'(?:Special|映像特典|特典)[\s._-]*(\d{1,3})(?![\d])',
    caseSensitive: false,
  );
  static final RegExp _reHot41 = RegExp(r'menu[._-]*ex', caseSensitive: false);
  static final RegExp _reHot42 = RegExp(
    r'[\[(（【]\s*ex(?:[\s._]*[-–—][\s._]*|[\s._-]+|\s*)0*(\d{1,2})\s*[\])）】]',
    caseSensitive: false,
  );
  static final RegExp _reHot43 = RegExp(
    r'\bex(?:[\s._]*[-–—][\s._]*|[\s._-]+|\s*)0*(\d{1,2})(?![a-z0-9])',
    caseSensitive: false,
  );
  static final RegExp _reHot44 = RegExp(r'^((?:19|20)\d{2})');
  static final RegExp _reHot45 = RegExp(r'\{tmdb-\d+\}', caseSensitive: false);
  static final RegExp _reHot46 = RegExp(r'\((?:19|20)\d{2}\)');
  static final RegExp _reHot47 = RegExp(
    r'\b(stage|part|pt|vol|volume|act|phase|chapter|season|series|ova|oad|sp|special|disc|disk|episode|ep|alternative|alter|story|arc|movie|film)\s+(I|V|X)\b',
    caseSensitive: false,
  );
  static final RegExp _reHot48 = RegExp(
    r'(?:^|\s)(I|V|X)(?=\s*(?:$|[:\-–—~()\[\]/／]))',
  );
  static final RegExp _reHot49 = RegExp(
    r'\b(stage|part|pt|vol|volume|act|phase|chapter|season|series|ova|oad|sp|special|disc|disk|episode|ep|alternative|alter)\s+(?:one|first)\b',
  );
  static final RegExp _reHot50 = RegExp(r'\b(?:one|first)\s*$');
  static final RegExp _reHot51 = RegExp(r'[\-_—–:：.()（）\[\]【】{}!?！？・·,，、/／|]+');
  static final RegExp _reHot52 = RegExp(r'(?<!\d)(\d{1,2})(?!\d)');
  static final RegExp _reHot53 = RegExp(r'\b1\b\s*$');
  static final RegExp _reHot54 = RegExp(r'[\u3040-\u9fff]');
  static final RegExp _reHot55 = RegExp(
    r'(?:\[SP\d{1,3}\]|(?:^|[\s._\-–—])SP\d{1,3}\s*(?=\[))',
    caseSensitive: false,
  );
  static final RegExp _reHot56 = RegExp(r'^\d+$');
  static final RegExp _reHot57 = RegExp(r'^(?:ova|oad|sp|ex)\d+$');
  static final RegExp _reHot58 = RegExp(
    r'(?:^|[^a-z])(?:oad|ova)(?:[^a-z]|$)',
    caseSensitive: false,
  );
  static final RegExp _reHot59 = RegExp(
    r'(?:^|[^a-z])(?:OVA|OAD)(?=[^a-z]|$)',
    caseSensitive: false,
  );
  static final RegExp _reHot60 = RegExp(
    r'(?:^|[^a-z])(?:SP|Specials?)(?=[^a-z0-9]|$)|\bSP\d+\b|映像特典|特典',
    caseSensitive: false,
  );
  static final RegExp _reHot61 = RegExp(
    r'(?:^|[^a-z0-9])ex(?:[\s._-]*0*\d{1,2})?(?=[^a-z0-9]|$)',
    caseSensitive: false,
  );
  static final RegExp _reHot62 = RegExp(
    r'(?:^|[^a-z])(?:OVA|OAD)(?=[^a-z]|$)',
    caseSensitive: false,
  );
  static final RegExp _reHot63 = RegExp(
    r'(?:^|[^a-z])(?:OVA|OAD)(?=[^a-z]|$)',
    caseSensitive: false,
  );
  static final RegExp _reHot64 = RegExp(r'\b(?:19|20)\d{2}\b');
  static final RegExp _reHot65 = RegExp(
    r'\b(?:OVA|OAD|SP)[ ._-]*\d+\b',
    caseSensitive: false,
  );
  static final RegExp _reHot66 = RegExp(r'\bv\d+\b', caseSensitive: false);
  static final RegExp _reHot67 = RegExp(r'(?<!\d)(\d{1,3})(?!\d)');
  static final RegExp _reHot68 = RegExp(
    r'\bSeason[ ._-]*(\d{1,2})\b',
    caseSensitive: false,
  );
  static final RegExp _reHot69 = RegExp(
    r'(?<![a-z0-9])S(\d{1,2})(?![a-z0-9])',
    caseSensitive: false,
  );
  static final RegExp _reHot70 = RegExp(
    r'\b(\d{1,2})(?:st|nd|rd|th)[ ._-]+Season\b',
    caseSensitive: false,
  );
  static final RegExp _reHot71 = RegExp(
    r'第[ ._-]*([0-9一二三四五六七八九]+)[ ._-]*[期季]',
  );
  static final RegExp _reHot72 = RegExp(r'(?<!\d)(\d{1,2})期(?![\d])');
  static final RegExp _reHot73 = RegExp(
    r'^(?:Season\s*\d+|第\s*[0-9一二三四五六七八九十]+\s*[季期]|Specials?|特別編)$',
    caseSensitive: false,
  );
  static final RegExp _reHot74 = RegExp(
    r'\bSeason[ ._-]*\d{1,2}\b',
    caseSensitive: false,
  );
  static final RegExp _reHot75 = RegExp(
    r'\b\d{1,2}(?:st|nd|rd|th)[ ._-]+Season\b',
    caseSensitive: false,
  );
  static final RegExp _reHot76 = RegExp(r'第[ ._-]*[0-9一二三四五六七八九]+[ ._-]*[期季]');
  static final RegExp _reHot77 = RegExp(r'\b\d{1,2}期\b');
  static final RegExp _reHot78 = RegExp(r'(?<!\d)((?:19|20)\d{2})(?!\d)');
  static final RegExp _reHot79 = RegExp(
    r'\bSeason[ ._-]*\d+\b',
    caseSensitive: false,
  );
  static final RegExp _reHot80 = RegExp(r'第[ ._-]*[0-9一二三四五六七八九十]+[ ._-]*[季期]');
  static final RegExp _reHot81 = RegExp(
    r'総集編|总集篇|recap|summary|digest',
    caseSensitive: false,
  );
  static final RegExp _reHot82 = RegExp(
    r'^(.+?)\s*[#＃第]?\s*0*([1-9]\d?)\s*[話话集]?$',
  );
  static final RegExp _reHot83 = RegExp(r'[^a-z0-9\u3040-\u9fff]+');
  static final RegExp _reHot84 = RegExp(
    r'(?:\b(?:episode|ep|special)\s*0?(\d{1,3})\b|第\s*0?(\d{1,3})\s*[话話集])',
    caseSensitive: false,
  );
  static final RegExp _reHot85 = RegExp(
    r'(?:another|alter|alternative|true|別|アナザー).{0,16}(?:end|ending|結末|结局)|ending|結末|结局',
    caseSensitive: false,
  );
  static final RegExp _reHot86 = RegExp(
    r'OVA|OAD|映像特典|特典',
    caseSensitive: false,
  );
  static final RegExp _reHot87 = RegExp(
    r'(^|[^a-z])(OVA|OAD|SP)(?=[^a-z]|$)',
    caseSensitive: false,
  );
}
