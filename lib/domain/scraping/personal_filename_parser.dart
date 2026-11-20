import 'package:path/path.dart' as p;
import '../models/media_extensions.dart';
import 'cloud_media_file_classifier.dart';
import '../parsing/release_groups.dart';

/// 从常见番组发布文件名中提取更适合搜索的关键词。
///
/// 目标：尽量去掉字幕组/压制组、清晰度、编码等信息，同时保留番名本体（含数字番名）。
class PersonalFilenameParser {
  PersonalFilenameParser._();

  static const identityPunctuation = [
    "'",
    '’',
    '‘',
    '‐',
    '‑',
    '‒',
    '﹘',
    '﹣',
    '－',
  ];
  static String unifyIdentityPunctuation(String value) {
    for (final mark in identityPunctuation) {
      value = value.replaceAll(mark, '');
    }
    return value;
  }

  static String normalizeIdentity(String title) =>
      unifyIdentityPunctuation(title)
          .toLowerCase()
          .replaceAll(RegExp(r'\{tmdb-\d+\}', caseSensitive: false), ' ')
          .replaceAll(RegExp(r'\((?:19|20)\d{2}\)'), ' ')
          .replaceAll(RegExp(r'[\s\-_—–:：.()（）\[\]【】{}!?！？・·,，、]'), '')
          .trim();

  static final _tmdbMarkers = [
    RegExp(
      r'\{\s*tmdb(?:tv|movie|id)?\s*[-=:_]\s*(\d+)\s*\}',
      caseSensitive: false,
    ),
    RegExp(
      r'\[\s*tmdb(?:tv|movie|id)?\s*[-=:_]\s*(\d+)\s*\]',
      caseSensitive: false,
    ),
    RegExp(r'\{\s*\[\s*tmdbid\s*=\s*(\d+)[^\]]*\]\s*\}', caseSensitive: false),
  ];
  static Set<int> tmdbIds(String title) => {
    for (final pattern in _tmdbMarkers)
      for (final match in pattern.allMatches(title))
        if ((int.tryParse(match.group(1)!) ?? 0) > 0)
          int.parse(match.group(1)!),
  };
  static int? tmdbId(String title) {
    final ids = tmdbIds(title);
    return ids.length == 1 ? ids.single : null;
  }

  static String? tmdbType(String title) {
    final types = tmdbTypes(title);
    return types.length == 1 ? types.single : null;
  }

  static Set<String> tmdbTypes(String title) => {
    if (RegExp(
      r'tmdbmovie\s*[-=:]|type\s*=\s*(movie|film)',
      caseSensitive: false,
    ).hasMatch(title))
      'movie',
    if (RegExp(
      r'tmdbtv\s*[-=:]|type\s*=\s*tv',
      caseSensitive: false,
    ).hasMatch(title))
      'tv',
  };

  static String withoutTmdbMarkers(String title) {
    var result = title;
    for (final pattern in _tmdbMarkers.reversed) {
      result = result.replaceAll(pattern, ' ');
    }
    return result;
  }

  static String baseNameWithoutExtension(String pathOrName) {
    final trimmed = pathOrName.trim();
    if (trimmed.isEmpty) return '';
    final base = p.posix.basename(trimmed.replaceAll('\\', '/'));
    return p.basenameWithoutExtension(base).trim();
  }

  static final _groupLikeSuffix = RegExp(
    r'(?:[-_ .]raws?|[-_ .]sub(?:s|bers)?|sub(?:s)?|字幕组|字幕組|字幕社|汉化组|漢化組|压制组|壓制組|'
    r'(?<![a-z])studio|fansubs?|[-_]rip)$',
    caseSensitive: false,
  );

  /// 驼峰式 `XxxRaws`/`XXXRAW` 组名后缀（区分大小写，避免误伤 `Draw` 这类普通单词）。
  static final _camelRawSuffix = RegExp(r'(?<=[A-Za-z0-9])(?:Raws|RAWS?|Raw)$');

  /// 动画压制组/字幕组常用名（FileBot 组名词典以欧美组为主，此处补充动画领域高频组名，统一小写比较）。
  static const _animeReleaseGroups = <String>{
    'vcb-s',
    'vcb-studio',
    'dmg',
    'airota',
    'nekomoe kissaten',
    'lolihouse',
    'sakurato',
    'flsnow',
    'wbx',
    'kamigami',
    'uha-wings',
    'liuyun',
    'ktxp',
    'popgo',
    'fzsd',
    'hakugetsu',
    'mh',
    'yydm',
    'mabors',
    'caso',
    'kagura',
    'moozzi2',
    'reinforce',
    'todokoi',
    'sergey_krs',
    'orion origin',
    'tamersunion',
    'nyamazing',
    't.h.x',
    'suzu-kaze',
    'hyakuhuyu',
    'jojo',
    'sumisora',
    'emd',
    'stk',
    'mmzy-sub',
    'yui-7',
    'enkanrec',
    'tsdm',
    'makarihoshiyume',
    'rath',
    'xspitfire911',
    'aikatsufans',
    'neo·qsw',
    'u2-rip',
    'cxraw',
    'judas',
    'erai-raws',
    'subsplease',
    'horriblesubs',
    'ohys-raws',
    'leopard-raws',
    'nc-raws',
    'lilith-raws',
    'ani',
    'skymoon-raws',
    'sweetsub',
    'beansub',
    'comicat',
    'mingy',
    'philosophy-raws',
  };

  /// 中文组名在联合发布标签中常以 `社`/`组` 收尾（如 `粉羽社&超古代`），仅用于联合标签的分段判定。
  static final _cjkGroupSuffix = RegExp(r'[社组組]$');

  static bool _looksLikeGroupName(String value) =>
      ReleaseGroups.contains(value) ||
      _animeReleaseGroups.contains(value.trim().toLowerCase()) ||
      _groupLikeSuffix.hasMatch(value) ||
      _camelRawSuffix.hasMatch(value);

  static final _groupJoiner = RegExp(
    r'(?<!\s)[&＆](?!\s)|\s+[&＆]\s+|[ _.]feat[ _.]+|×',
    caseSensitive: false,
  );

  /// 判断方括号标签是否为压制组/字幕组：命中组名词典、带典型组名后缀（`-Raws`、`Sub`、`Studio`、`字幕组` 等），
  /// 或由 `&`/`feat.` 连接且至少一段可识别为组名的联合发布标签（如 `ANK&VCB-Studio`、`FLsnow_feat.AO`）。
  static bool isReleaseGroupTag(String tag) {
    final trimmed = tag.trim();
    if (trimmed.isEmpty) return false;
    if (_looksLikeGroupName(trimmed)) return true;
    final parts = trimmed
        .split(_groupJoiner)
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    if (parts.length < 2) return false;
    bool groupPart(String part) =>
        _looksLikeGroupName(part) || _cjkGroupSuffix.hasMatch(part);
    // 带空格的 ` & ` 多见于片名（`TIGER & BUNNY`），要求每段都像组名；紧贴的 `A&B` 只需任一段可识别。
    return RegExp(r'\s[&＆]\s').hasMatch(trimmed)
        ? parts.every(groupPart)
        : parts.any(groupPart);
  }

  static final _bracketBlockPattern = RegExp(r'\[([^\]]*)\]|【([^】]*)】');

  static final _episodeLikeBlock = RegExp(
    r'^(?:s\d{1,2}[ ._-]?e\d{1,4}|(?:ep?|episode|#|bd|vol|第)?[ ._-]*\d{1,4}(?:\.\d)?(?:v\d+)?'
    r'(?:\s*[-~&+]\s*\d{1,4}(?:v\d+)?)?(?:[ ._-]*(?:end|fin|final|[话話集]))?)$',
    caseSensitive: false,
  );

  static final _genericMarkerBlock = RegExp(
    r'^(?:ova|oad|oav|sps?|specials?|(?:the[ ._-]+)?movie|剧场版|劇場版|tv版?|extras?|bonus|'
    r'menus?|pvs?|cms?|ncop|nced|live)$',
    caseSensitive: false,
  );

  static final _languageOrPackageToken = RegExp(
    r'^(?:简体|繁体|简繁|繁简|简日|繁日|简中|繁中|中日|双语|雙語|内嵌|內嵌|内封|內封|外挂|外掛|'
    r'中字|中文字幕|生肉|gb|big5|chs|cht|jpsc|jptc|cn|jp|tvrip|dvdrip|bdrip|webrip|bd|dvd|web|tv|'
    r'mp4|mkv|avi|\d{3,4}|\d{3,4}p|v\d+)$',
    caseSensitive: false,
  );

  static bool _isLanguageOrPackageBlock(String block) {
    final parts = block
        .split(RegExp(r'[\s_+,&/|-]+'))
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    return parts.isNotEmpty &&
        parts.every(
          (part) =>
              _languageOrPackageToken.hasMatch(part) ||
              _technicalPart.hasMatch(part),
        );
  }

  /// 拆解全方括号文件名（`[组名][片名][副标题][集号][规格]`）：返回片名块与集号块之前的附加限定块文本。
  /// 优先在集号块之前的候选块中取片名：候选不少于两个时首块为压制组位，仅一个时即片名；
  /// 集号块之后的块（如 `[on air format]`、`[LIVE]`）只是版本或附加标签，不参与片名选择。
  /// 非全方括号命名返回 `null`。
  static ({String title, String qualifier})? _allBracketParts(String name) {
    if (name.replaceAll(_bracketBlockPattern, '').trim().isNotEmpty) {
      return null;
    }
    final before = <String>[];
    final after = <String>[];
    var seenEpisode = false;
    for (final m in _bracketBlockPattern.allMatches(name)) {
      final block = (m[1] ?? m[2]!).trim();
      if (block.isEmpty || _isLanguageOrPackageBlock(block)) continue;
      if (_episodeLikeBlock.hasMatch(block)) {
        seenEpisode = true;
        continue;
      }
      (seenEpisode ? after : before).add(block);
    }
    final pool = before.isNotEmpty ? before : after;
    if (pool.isEmpty) return null;
    var titleIndex = 0;
    if (pool.length >= 2 &&
        (isReleaseGroupTag(pool.first) ||
            !_genericMarkerBlock.hasMatch(pool[1]))) {
      titleIndex = 1;
    }
    final qualifier = identical(pool, before)
        ? pool.skip(titleIndex + 1).join(' ')
        : '';
    return (title: pool[titleIndex], qualifier: qualifier);
  }

  /// 全方括号命名中片名块之后、集号块之前的附加限定文本（如衍生短篇名 `Understanding ... in 5 Minutes`），
  /// 用于区分同一目录内不同系列主干；非全方括号命名或无限定块时返回空串。
  static String bracketSeriesQualifier(String fileName) {
    var name = withoutTmdbMarkers(baseNameWithoutExtension(fileName));
    name = _stripTechnicalBrackets(name.replaceAll(_crc32Bracket, ' '));
    final parts = _allBracketParts(name);
    if (parts == null) return '';
    return parts.qualifier
        .replaceAll(RegExp(r'[\s._-]*\d{1,4}(?:v\d+)?\s*$'), '')
        .replaceAll('_', ' ')
        .trim();
  }

  /// 提供额外的候选片名线索供搜索比对，绝不破坏原始文件名语义。
  /// 仅命中字幕组词典不足以直接作为作品身份依据。
  static String? withoutKnownReleaseGroups(String filename) {
    final base = baseNameWithoutExtension(filename);
    var stripped = base.replaceAllMapped(RegExp(r'\[([^\]]+)\]|【([^】]+)】'), (
      m,
    ) {
      final tag = (m[1] ?? m[2]!).trim();
      return isReleaseGroupTag(tag) ? ' ' : m[0]!;
    }).trim();
    final separators = RegExp(r'-').allMatches(stripped).toList();
    // 限制尾缀探测深度；部分字幕组名内部自带连字符，须保持名称整体性。
    for (final match in separators.skip(
      separators.length > 8 ? separators.length - 8 : 0,
    )) {
      if (ReleaseGroups.contains(stripped.substring(match.end))) {
        stripped = stripped.substring(0, match.start).trimRight();
        break;
      }
    }
    if (stripped.isEmpty || stripped == base) return null;
    return '$stripped${p.extension(filename)}';
  }

  /// 全括号风格文件名通常依次包含字幕组、多语译名、集号与编码规格信息；
  /// 解析时将潜在标题均保留交由刮削源核验，
  /// 切勿仅凭方括号位置武断区分字幕组与正片标题。
  static List<String> bracketTitleCandidates(String filename) {
    final base = baseNameWithoutExtension(filename);
    final pattern = RegExp(r'\[([^\]]+)\]|【([^】]+)】');
    if (base
        .replaceAll(pattern, '')
        .replaceAll(RegExp(r'[\s._-]'), '')
        .isNotEmpty) {
      return const [];
    }
    final blocks = pattern
        .allMatches(base)
        .map((m) => (m[1] ?? m[2]!).trim())
        .toList();
    final result = <String>[];
    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];
      if (block.isEmpty ||
          tmdbIds('[$block]').isNotEmpty ||
          RegExp(
            r'^(?:S\d{1,2}(?:E\d{1,3})?|EP?\d{1,3})$',
            caseSensitive: false,
          ).hasMatch(block)) {
        continue;
      }
      if (RegExp(r'^\d{1,4}(?:v\d+)?$', caseSensitive: false).hasMatch(block)) {
        // 仅当后续紧跟另一组数字标签块时，才保留前方纯数字块作为数字片名（如 `[86]`）。
        if (!blocks.skip(i + 1).any((b) => RegExp(r'^\d{1,3}$').hasMatch(b))) {
          continue;
        }
      }
      // 压制组/字幕组块、纯技术或语言封装块、集号块与通用类型块（`[OVA]`、`[Live]`）都不是片名候选。
      if (isReleaseGroupTag(block) ||
          _isLanguageOrPackageBlock(block) ||
          _episodeLikeBlock.hasMatch(block) ||
          _genericMarkerBlock.hasMatch(block) ||
          block
              .split(RegExp(r'[\s_+.,/|&-]+'))
              .where((s) => s.isNotEmpty)
              .every(_technicalPart.hasMatch)) {
        continue;
      }
      final technical = block.toLowerCase().split(RegExp(r'[\s_+,-]+'));
      if (technical.every(
        (part) => RegExp(
          r'^(?:\d{3,4}[pi]|\d{3,5}x\d{3,5}|[248]k|(?:ma|hi)?\d{1,2}p|(?:x|h)\.?26[45]|hevc|avc|av1|(?:aac|flac|opus|ac3|eac3|dts|truehd|ass|ssa|srt)(?:x\d+)?|yuv(?:420|422|444)p?\d*|\d{1,2}\.\d|10bit|8bit|bdrip|bluray|web-?dl|webrip|jpsc|jptc|chs|cht|gb|big5|mp4|mkv|[0-9a-f]{8})$',
        ).hasMatch(part),
      )) {
        continue;
      }
      result.add(block);
    }
    return result;
  }

  static ({String title, int episode})? bareEpisode(String filename) {
    final base = _stripTrailingTags(
      _stripLeadingGroupTags(baseNameWithoutExtension(filename)),
    );
    final match = RegExp(
      r'^(.+\S)\s+(\d{1,3})(?:v\d+)?$',
      caseSensitive: false,
    ).firstMatch(base);
    if (match == null || RegExp(r'[-_#]$').hasMatch(match[1]!)) return null;
    return (title: match[1]!.trim(), episode: int.parse(match[2]!));
  }

  static Set<String> sequentialEpisodePrefixes(Iterable<String> filenames) {
    final numbers = <String, Set<int>>{};
    for (final filename in filenames.expand(
      (name) => [name, ?withoutKnownReleaseGroups(name)],
    )) {
      final parsed = bareEpisode(filename);
      if (parsed != null) {
        (numbers[parsed.title.toLowerCase()] ??= {}).add(parsed.episode);
      }
    }
    return {
      for (final entry in numbers.entries)
        if (entry.value.any(
          (n) => entry.value.contains(n + 1) && entry.value.contains(n + 2),
        ))
          entry.key,
    };
  }

  /// 生成在线元数据搜索的标题候选；保留数字番名和括号中的作品名。
  static String extractAnimeTitleKeyword(String pathOrName) {
    final cleaned = pathOrName.replaceAllMapped(
      RegExp(r'\[([^\]]+)\]|【([^】]+)】'),
      (tag) {
        return isReleaseGroupTag((tag[1] ?? tag[2]!).trim()) ? ' ' : tag[0]!;
      },
    );
    if (cleaned != pathOrName) {
      final candidate = _extractAnimeTitleKeyword(cleaned);
      // 部分已知字幕组短名也可能与真实作品标题重名（如 `WAR`），
      // 需保留该候选供上层结合已确认目录别名复核。
      if (candidate.isNotEmpty && !RegExp(r'^\d+$').hasMatch(candidate)) {
        return candidate;
      }
    }
    return _extractAnimeTitleKeyword(pathOrName);
  }

  static final _crc32Bracket = RegExp(
    r'[\[(【（]\s*[0-9a-f]{8}\s*[\])】）]',
    caseSensitive: false,
  );

  static final _technicalPart = RegExp(
    r'^(?:\d{3,4}[pi]|\d{3,5}x\d{3,5}|[248]k|(?:ma|hi)?\d{1,2}p|'
    r'(?:x|h)\.?26[45]|hevc|avc|av1|vp9|mpeg[24]|'
    r'(?:aac|flac|opus|ac3|eac3|dts(?:-?hd)?|truehd|alac|lpcm|mp3|ass|ssa|srt|sup|pgs)(?:x\d+)?|'
    r'\d\.\d(?:ch)?|\dch|yuv(?:420|422|444)p?\d*|12bits?|10bits?|8bits?|10bpp|8bpp|main\d{0,2}p?|als|'
    r'hdr10\+?|hdr|dv|sdr|'
    '${KonataMediaExtensions.sourceTagAlternation}|'
    r'jpsc|jptc|jpchs|jpcht|chs|cht|sc|tc|gb|big5|jap|jpn|eng|dual[-_]?audio|multi[-_]?subs?|'
    '${KonataMediaExtensions.videoExtensionAlternation}|'
    r'[0-9a-f]{8})$',
    caseSensitive: false,
  );

  static String _stripTechnicalBrackets(String input) => input.replaceAllMapped(
    RegExp(r'\[([^\]]+)\]|【([^】]+)】|\(([^)]+)\)|（([^）]+)）'),
    (m) {
      final raw = (m[1] ?? m[2] ?? m[3] ?? m[4] ?? '').trim();
      if (raw.isEmpty) return ' ';
      final parts = raw
          .split(RegExp(r'[\s_+.,/|+&-]+'))
          .where((s) => s.isNotEmpty)
          .toList();
      if (parts.isNotEmpty && parts.every(_technicalPart.hasMatch)) {
        return ' ';
      }
      return m[0]!;
    },
  );

  /// 剥离场景发布文件名中未加括号的技术参数与附着于其后的 `-ReleaseGroup` 后缀，
  /// 如 `... 2010 1080p BluRay x264 10bit FLAC-Shiniori`。
  static String stripUnbracketedTechTokens(String input) {
    final explicitSources = KonataMediaExtensions.explicitSourceTagAlternation;
    final hasTechCue = RegExp(
      r'(?<![a-z0-9])(?:'
      r'(?:2160|1440|1080|720|576|480)[pi]|'
      '$explicitSources|web[ ._-]?dl|'
      r'[xh]\.?26[45]|hevc|avc|10bit|12bit|hi10p|ma10p|main12|ddp?(?:\d+(?:\.\d+)?)?|ac3|eac3'
      r')(?![a-z0-9])',
      caseSensitive: false,
    ).hasMatch(input);
    if (!hasTechCue) return input;

    var s = input.replaceFirst(
      RegExp(
        r'(?<=(?:2160|1440|1080|720|576|480)[pi]|'
        '$explicitSources|web[ ._-]?dl|'
        r'[xh]\.?26[45]|hevc|avc|av1|10bit|12bit|8bit|hi10p|ma10p|main12|'
        r'flac|aac|alac|ddp?(?:\d+(?:\.\d+)?)?|ac3|eac3|dts(?:-?hd)?|opus|truehd)'
        r'-[a-z0-9][a-z0-9._-]{1,24}$',
        caseSensitive: false,
      ),
      '',
    );
    s = s.replaceAll(
      RegExp(
        r'(?<![a-z0-9])(?:'
        r'(?:2160|1440|1080|720|576|480)[pi]|(?:1920|1280)x(?:1080|720)|[248]k|'
        '$explicitSources|web[ ._-]?dl|'
        r'[xh]\.?26[45]|hevc|avc|av1|vp9|'
        r'10bit|12bit|8bit|hi10p|ma10p|main12|hdr10\+?|hdr|sdr|dv|yuv\d{3}p?\d*|'
        r'flac|aac|alac|ddp?\d*(?:\.\d+)?|ac3|eac3|dts(?:-?hd)?|opus|truehd|lpcm|mp3|'
        r'(?:2\.0|5\.1|7\.1)(?:ch)?'
        r')(?![a-z0-9])',
        caseSensitive: false,
      ),
      ' ',
    );
    return s
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceFirst(RegExp(r'[\s._-]+$'), '')
        .trim();
  }

  static String _extractAnimeTitleKeyword(String pathOrName) {
    var name = withoutTmdbMarkers(baseNameWithoutExtension(pathOrName));
    if (name.isEmpty) return '';

    // 阶段一（Anitomy 式消去）：先剥离 8 位 CRC32 校验码与纯技术参数括号块，
    // 防止压制标签干扰右侧集数定界，同时保留标题内括号与数字番名。
    name = name.replaceAll(_crc32Bracket, ' ');
    name = _stripTechnicalBrackets(name);

    // 常见分隔符归一化（保留 12.5 这类半集小数点）
    name = name.replaceAll(RegExp(r'_|(?<!\d)\.|\.(?!5\b)'), ' ').trim();

    // 全方括号命名直接取片名块，避免把首块压制组名当作片名。
    final bracketParts = _allBracketParts(name);
    if (bracketParts != null) name = bracketParts.title;

    // 去掉开头的字幕组/压制组标识（可能存在多个）
    name = _stripLeadingGroupTags(name);

    // 去掉末尾的编码/分辨率等标签（可能存在多个）
    name = _stripTrailingTags(name);

    // 阶段二：从右侧集数定界符切分，左侧数字番名（86、Mob Psycho 100、Steins;Gate 0）自然保留
    final episodeMarker = RegExp(
      r'[／/]?\s*\b(?:S\d{1,2}E\d{1,3}(?:\.5)?(?:v\d+)?|EP?\s*\d{1,3}(?:\.5)?(?:v\d+)?)\b|'
      r'第\s*\d{1,3}(?:\.5)?\s*[话話集]',
      caseSensitive: false,
    ).firstMatch(name);
    if (episodeMarker != null) {
      name = name.substring(0, episodeMarker.start).trim();
    }
    final delimitedEpisode = CloudMediaFileClassifier.delimitedEpisode
        .firstMatch(name);
    if (delimitedEpisode != null) {
      name = name.substring(0, delimitedEpisode.start).trim();
    }

    // 去掉常见季/集标识（仅影响搜索关键词，不做全局数字清理）
    name = name.replaceAll(
      RegExp(r'\bS\d{1,2}E\d{1,3}(?:\.5)?(?:v\d+)?\b', caseSensitive: false),
      ' ',
    );
    name = name.replaceAll(
      RegExp(
        r'\bS\d{1,2}(?:\s*[+&~～]\s*S\d{1,2})+\b|\bS\d{1,2}\b',
        caseSensitive: false,
      ),
      ' ',
    );
    name = name.replaceAll(
      RegExp(r'\b(?:EP|Ep|ep)\s*\d{1,3}(?:\.5)?(?:v\d+)?\b'),
      ' ',
    );
    name = name.replaceAll(
      RegExp(r'\bE\d{1,3}(?:\.5)?(?:v\d+)?\b', caseSensitive: false),
      ' ',
    );

    // 中文/日文“第X话/集/期”
    name = name.replaceAll(RegExp(r'第\s*\d{1,3}(?:\.5)?\s*[话話集期]'), ' ');
    name = name.replaceAll(RegExp(r'\d{1,3}(?:\.5)?\s*[话話集期]\b'), ' ');

    // 形如 [01] / [01v2] / [12.5] / [01-02] 的独立集数方括号块（避免误删番名中的数字）
    final numericTitle = RegExp(
      r'^[\[【]\s*\d{1,3}(?:\.5)?(?:v\d+)?\s*[\]】]$',
      caseSensitive: false,
    ).hasMatch(name);
    if (!numericTitle) {
      name = name.replaceAll(
        RegExp(
          r'[\[【]\s*\d{1,3}(?:\.5)?(?:v\d+)?(?:\s*[-–—~&+]\s*\d{1,3}(?:v\d+)?)?\s*[\]】]',
          caseSensitive: false,
        ),
        ' ',
      );
    }

    // 形如 " - 01" / " - 02v2" / " - 12.5" / " - 01-02" 的结尾集数
    // 最多剥离一次年份或尾缀；连续多次剥离会把如 `Animation 12 - 01`
    // 误削为 `Animation`，从而抹掉真实片名组成部分。
    name = name.replaceFirst(
      RegExp(
        r'(?:(?:\s+[-_]\s*\d{1,3}(?:\.5)?|\s+0\d{1,2}(?:\.5)?|\s*#\s*\d{1,3}(?:\.5)?)(?:v\d+)?'
        r'(?:(?:[-–—]|\s*[&+~]\s*)\d{1,3}(?:v\d+)?)+|'
        r'(?:\s*[-_#]\s*\d{1,3}(?:\.5)?|\s+0\d{1,2}(?:\.5)?)(?:v\d+)?)'
        r'(?:\s*[- ]*(?:END|FINAL|FIN))?$',
        caseSensitive: false,
      ),
      ' ',
    );

    // 清理残留括号/多余空白
    name = name.replaceAll(RegExp(r'[\[\]【】()（）{}]'), ' ');
    name = name.replaceAll(RegExp(r'\s+'), ' ').trim();
    return name;
  }

  /// 在常规标题提取结果上进一步去掉集数、分辨率、编码和字幕语言标签。
  ///
  /// 用于在线名称搜索，不读取视频或计算哈希。调用方仍应保留
  /// [extractAnimeTitleKeyword] 作为更保守的候选，避免数字属于作品名时丢失信息。
  static String extractAnimeSearchKeyword(
    String pathOrName, {
    int? episodeNumber,
  }) {
    final title = extractAnimeTitleKeyword(pathOrName);
    if (title.isEmpty) return '';

    final technicalToken = RegExp(
      r'^(?:'
      r'\d{3,4}p|[248]k|'
      r'x26[45]|h26[45]|hevc|avc|av1|'
      r'aac|flac|opus|ac3|eac3|dts|'
      r'web-?dl|webrip|bluray|bdrip|brrip|hdtv|'
      r'hdr10\+?|hdr|dolby|vision|dv|'
      r'jptc|jpchs|jpcht|chs|cht|gb|big5|'
      r'mp4|mkv'
      r')$',
      caseSensitive: false,
    );
    var removedEpisode = false;
    final kept = <String>[];

    for (final token in title.split(RegExp(r'\s+'))) {
      final normalized = token.replaceAll(
        RegExp(r'^[\[\]【】()（）{}]+|[\[\]【】()（）{}]+$'),
        '',
      );
      if (normalized.isEmpty || technicalToken.hasMatch(normalized)) {
        continue;
      }

      if (!removedEpisode && episodeNumber != null) {
        final numericToken = int.tryParse(normalized);
        if (numericToken == episodeNumber) {
          removedEpisode = true;
          continue;
        }
      }
      kept.add(normalized);
    }

    return kept.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String _stripLeadingGroupTags(String name) {
    // 括号标题后若仅跟集号或技术规格标签，必须完整保留该标题；
    // 对相邻未知方括号区块不做不可靠的主从切分猜测。
    final outside = name
        .replaceAll(RegExp(r'\[[^\]]*\]|【[^】]*】'), ' ')
        .replaceAll(
          RegExp(r'\b(?:S\d+E\d+|EP?\d+|\d+)\b', caseSensitive: false),
          ' ',
        )
        .replaceAll(
          RegExp(
            r'\b(?:\d{3,4}p|x26[45]|h26[45]|hevc|avc|flac|aac|bdrip|bluray|chs|cht)\b',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(RegExp(r'[\s._-]+'), '');
    if (outside.isEmpty) return name;
    var result = name.trimLeft();
    while (true) {
      if (result.startsWith('[')) {
        final end = result.indexOf(']');
        if (end > 0) {
          result = result.substring(end + 1).trimLeft();
          continue;
        }
      }
      if (result.startsWith('【')) {
        final end = result.indexOf('】');
        if (end > 0) {
          result = result.substring(end + 1).trimLeft();
          continue;
        }
      }
      break;
    }
    return result;
  }

  static String _stripTrailingTags(String name) {
    var result = name.trimRight();
    final block = RegExp(r'\s*(?:\[[^\]]*\]|【[^】]*】|\([^)]*\)|（[^）]*）)\s*$');
    while (true) {
      final match = block.firstMatch(result);
      if (match == null) break;
      final before = result.substring(0, match.start).trimRight();
      if (before.isEmpty) break;
      result = before;
    }
    return result.trim();
  }
}
