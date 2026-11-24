import 'package:konata_contracts/konata_contracts.dart';

/// 媒体源目录拓扑与附属子目录判定纯函数集合（与上层刮削/播放引擎解耦）。
abstract final class SourcePathRules {
  static final RegExp _extraVideoDir = RegExp(
    r'^(?:'
    r'sps?|specials?|ova|oad|oav|extras?|bonus(?:[ ._-]*disc)?|privilege[ ._-]*dis[ck]|pvs?|cms?|'
    r'menus?(?:[ ._-]*ex)?\d*|nc|ncop(?:ed)?|nced|trailers?|teasers?|previews?|'
    r'promos?|promotion|making|interviews?|events?|commentary|creditless|textless|'
    r'tv[ ._-]*spots?|tvcm|bdcm|fan[ ._-]*disc|fandisc|'
    r'(?:eizou[ ._-]+)?tokuten|'
    r'特典|映像特典|特典映像|特典视频|花絮|幕后|访谈|预告|預告|预览|宣传'
    r')(?:[ ._-]*\d+)?$',
    caseSensitive: false,
  );

  static final RegExp _supplementaryDirectory = RegExp(
    r'^(?:sp|sps|special|specials|extra|extras|bonus|nc|ncop|nced|pv|cm|'
    r'menu|menus|music|music[\s._-]*videos?|mvs?|samples?|(?:eizou[\s._-]+)?tokuten|creditless|textless|interviews?|events?|making|'
    r'trailers?|previews?|promos?|promotion|tv[\s._-]*spots?|tvcm|bdcm|'
    r'effects?|fan[\s._-]*disc|fandisc|privilege[\s._-]*dis[ck]|.*pvd.*|reviews?|'
    r'logo|logos|voices?|cds|ost|soundtrack|gallery|artwork|特典|映像特典|'
    r'特典映像|花絮|幕后|访谈|预告|預告|宣传|聲優|声优|'
    r'tv[\s._-]*スポット|プロモーション映像|(?:ミュージック|ミコージック)[・·\s._-]*クリップ|'
    r'劇場アナウンス|アナウンス|ピクチャードラマ|スペシャル映像|'
    r'(?:op|ed)(?:[\s._&-]*(?:op|ed))*)$',
    caseSensitive: false,
  );

  static final RegExp _explicitSeasonOnlyDir = RegExp(
    r'^(?:'
    r'(?:\d{1,2}(?:st|nd|rd|th)[ ._-]+)?seasons?(?:[ ._-]*\d{1,2})?|'
    r's\d{1,2}|'
    r'第[0-9一二三四五六七八九十百]+[季期]'
    r')$',
    caseSensitive: false,
  );

  static final RegExp _volumeOrSeasonDir = RegExp(
    r'^(?:'
    r'(?:\d{1,2}(?:st|nd|rd|th)[ ._-]+)?seasons?(?:[ ._-]*\d{1,2})?|'
    r's\d{1,2}|'
    r'vol(?:ume)?[ ._-]*\d{1,3}|v\d{1,2}|'
    r'bd[ ._-]*\d{1,2}|bd(?:rip|[ ._-]*box)?|bdrip[ ._-]*\d{1,2}|'
    r'dis[ck][ ._-]*\d{1,2}|'
    r'part[ ._-]*\d{1,2}|'
    r'第[0-9一二三四五六七八九十百]+[季期卷巻篇]|'
    r'正片|main(?:[ ._-]*feature)?'
    r')$',
    caseSensitive: false,
  );

  static final RegExp _audioOrScanDir = RegExp(
    r'^(?:'
    r'cds?|cd[ ._-]*\d{1,2}|ost|soundtracks?|original[ ._-]*soundtracks?|music|'
    r'(?:special[ ._-]*)?drama[ ._-]*cds?|audio[ ._-]*drama|'
    r'(?:official[ ._-]*)?radio|character[ ._-]*songs?|chara[ ._-]*songs?|'
    r'vocals?|op|ed|op[ ._-]*&[ ._-]*ed|themes?|'
    r'scans?|booklets?|bk|artworks?|gallery|illustrations?|endcards?|'
    r'角色歌|广播剧|原声[集带帶]?|扫图|畫冊|画册|设定集'
    r')(?:[ ._-]*\d{1,2})?$',
    caseSensitive: false,
  );

  static final RegExp _supplementaryPhrase = RegExp(
    r'\b(?:special[ ._-]+drama[ ._-]+cd|drama[ ._-]+cd|character[ ._-]+song|'
    r'original[ ._-]+soundtrack|soundtrack|official[ ._-]+radio|bonus[ ._-]+cd|'
    r'bonus[ ._-]+disc|bonus[ ._-]+track|picture[ ._-]+drama|audio[ ._-]+commentary|'
    r'映像特典|特典映像|特典cd|原声集|角色歌|广播剧)\b',
    caseSensitive: false,
  );

  static final RegExp _datedReleaseDir = RegExp(
    r'^\s*[\[【(]\s*(?:19|20)?\d{2}[01]\d[0-3]\d\s*[\]】)]',
  );

  static final RegExp _jpCatalogNumberDir = RegExp(
    r'^\s*[A-Z]{3,5}-\d{3,5}(?:\b|~|-|$)',
  );

  static final RegExp _mediaFormatPackageSuffix = RegExp(
    r'[\[(（【]\s*(?:flac|aac|mp3|wav|ape|tta|tak|opus|ogg|alac|m4a|webp|jpg|jpeg|png)'
    r'(?:\s*[+&/／,，_-]\s*(?:flac|aac|mp3|wav|ape|tta|tak|opus|ogg|alac|m4a|webp|jpg|jpeg|png|cue|bk|scans?|booklet|rr\d*))*\s*[\])）】]\s*$',
    caseSensitive: false,
  );

  static final RegExp _leadingGroupBracket = RegExp(r'^\s*[\[【]');
  static final RegExp _leadingBracketTag = RegExp(
    r'^\s*(?:\[[^\]]*\]|【[^】]*】)\s*',
  );
  static final RegExp _trailingBracketTag = RegExp(
    r'\s*(?:\[[^\]]*\]|【[^】]*】|\([^)]*\)|（[^）]*）)\s*$',
  );
  static final RegExp _lastBracketBlock = RegExp(
    r'[\[(（【]([^\[\]()（）【】]*)[\])）】]\s*$',
  );

  static const Set<String> _subtitleSubdirExactNames = <String>{
    'sub',
    'subs',
    'subtitle',
    'subtitles',
    '字幕',
  };

  static const Set<String> _audioSidecarSubdirExactNames = <String>{
    'audio',
    'sp audio',
    'mka',
  };

  static final RegExp _subtitleSubdirTokenRegex = RegExp(
    r'^(?:subs?|subtitles?)(?:[\s._\-]?\d+|[\s._\-](?:chs|cht|sc|tc|jp|jpn|eng|zh|bilingual|all|extra))?$',
    caseSensitive: false,
  );

  static final List<RegExp> _tmdbMarkers = <RegExp>[
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

  static String _stripOuterBracketTags(String segment) {
    var stripped = segment.trim();
    for (var i = 0; i < 2; i++) {
      final m = _leadingBracketTag.firstMatch(stripped);
      if (m == null) break;
      final next = stripped.substring(m.end).trim();
      if (next.isEmpty) break;
      stripped = next;
    }
    while (_trailingBracketTag.hasMatch(stripped)) {
      final next = stripped.replaceFirst(_trailingBracketTag, '').trim();
      if (next == stripped || next.isEmpty) break;
      stripped = next;
    }
    return stripped;
  }

  static bool _endsWithVolumeBlock(String segment) {
    final m = _lastBracketBlock.firstMatch(segment.trim());
    if (m == null) return false;
    final inner = m.group(1)!.trim();
    return inner.isNotEmpty &&
        !_explicitSeasonOnlyDir.hasMatch(inner) &&
        _volumeOrSeasonDir.hasMatch(inner) &&
        RegExp(r'\d').hasMatch(inner);
  }

  /// 判断单个目录段名是否属于分卷或季度子目录（非特典、CD 或扫图）。
  static bool isSeasonOrVolumeSegment(String segment) {
    final trimmed = segment.trim();
    if (trimmed.isEmpty) return false;
    if (_volumeOrSeasonDir.hasMatch(trimmed) || _endsWithVolumeBlock(trimmed)) {
      return true;
    }
    var stripped = trimmed;
    while (_trailingBracketTag.hasMatch(stripped)) {
      final next = stripped.replaceFirst(_trailingBracketTag, '').trim();
      if (next == stripped || next.isEmpty) break;
      stripped = next;
      if (_volumeOrSeasonDir.hasMatch(stripped)) return true;
    }
    final outerStripped = _stripOuterBracketTags(trimmed);
    if (outerStripped.isNotEmpty &&
        outerStripped != trimmed &&
        _volumeOrSeasonDir.hasMatch(outerStripped)) {
      return true;
    }
    return false;
  }

  /// 判断单个目录段名是否属于附属、分卷、音乐或扫图子目录。
  static bool isSupplementarySegment(String segment) {
    final trimmed = segment.trim();
    if (trimmed.isEmpty) return false;

    if (_datedReleaseDir.hasMatch(trimmed) ||
        _jpCatalogNumberDir.hasMatch(trimmed) ||
        _mediaFormatPackageSuffix.hasMatch(trimmed) ||
        _supplementaryPhrase.hasMatch(trimmed)) {
      return true;
    }

    if (_extraVideoDir.hasMatch(trimmed) ||
        _volumeOrSeasonDir.hasMatch(trimmed) ||
        _audioOrScanDir.hasMatch(trimmed) ||
        _endsWithVolumeBlock(trimmed)) {
      return true;
    }

    if (!_leadingGroupBracket.hasMatch(trimmed) &&
        _supplementaryDirectory.hasMatch(trimmed)) {
      return true;
    }

    var stripped = trimmed;
    while (_trailingBracketTag.hasMatch(stripped)) {
      final next = stripped.replaceFirst(_trailingBracketTag, '').trim();
      if (next == stripped || next.isEmpty) break;
      stripped = next;
      if (_extraVideoDir.hasMatch(stripped) ||
          _volumeOrSeasonDir.hasMatch(stripped) ||
          _audioOrScanDir.hasMatch(stripped)) {
        return true;
      }
    }

    final outerStripped = _stripOuterBracketTags(trimmed);
    if (outerStripped.isNotEmpty &&
        outerStripped != trimmed &&
        (_extraVideoDir.hasMatch(outerStripped) ||
            _volumeOrSeasonDir.hasMatch(outerStripped) ||
            _audioOrScanDir.hasMatch(outerStripped))) {
      return true;
    }
    return false;
  }

  /// 判断目录路径的任意段是否明显属于音频 CD、广播剧或扫图资产容器目录。
  static bool isAudioOrScanPath(String folderPath) {
    final segments = folderPath
        .replaceAll('\\', '/')
        .split('/')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty);
    for (final seg in segments) {
      final outerStripped = _stripOuterBracketTags(seg);
      if (_audioOrScanDir.hasMatch(seg) ||
          (outerStripped.isNotEmpty && _audioOrScanDir.hasMatch(outerStripped)) ||
          _datedReleaseDir.hasMatch(seg) ||
          _jpCatalogNumberDir.hasMatch(seg) ||
          _mediaFormatPackageSuffix.hasMatch(seg) ||
          _supplementaryPhrase.hasMatch(seg)) {
        return true;
      }
    }
    return false;
  }

  /// 判断目录名是否属于外挂字幕子目录（如 `Subs`、`Subtitles`、`字幕`）。
  static bool isSubtitleSubdirName(String rawName) {
    final lower = rawName.trim().toLowerCase();
    if (lower.isEmpty) return false;
    if (_subtitleSubdirExactNames.contains(lower)) return true;
    if (lower.contains('字幕')) return true;
    return _subtitleSubdirTokenRegex.hasMatch(lower);
  }

  /// 判断目录名是否属于外挂音轨子目录（如 `Audio`、`SP Audio`）。
  static bool isAudioSidecarSubdirName(String rawName) {
    final lower = rawName.trim().toLowerCase();
    return _audioSidecarSubdirExactNames.contains(lower);
  }

  /// 判断目录名是否属于媒体附属子目录（涵盖字幕与音轨子目录）。
  static bool isSidecarSubdirName(String rawName) {
    return isSubtitleSubdirName(rawName) || isAudioSidecarSubdirName(rawName);
  }

  /// 若目录尾段为字幕子目录，返回其逻辑父目录；否则原样返回。
  static String logicalParentDirOfSubtitleDir(String posixDir) {
    final normalized = posixDir
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'^/+|/+$'), '');
    if (normalized.isEmpty) return '';
    final slash = normalized.lastIndexOf('/');
    final tail = slash < 0 ? normalized : normalized.substring(slash + 1);
    if (!isSubtitleSubdirName(tail)) return normalized;
    return slash < 0 ? '' : normalized.substring(0, slash);
  }

  /// 提取标准化父目录路径。
  static String parentDirOf(String pathOrName) {
    final normalized = pathOrName.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    if (slash < 0) return '';
    return normalized.substring(0, slash);
  }

  /// 检查名称中是否包含唯一显式 TMDB 编号标记。
  static int? extractExplicitTmdbId(String title) {
    final ids = <int>{
      for (final pattern in _tmdbMarkers)
        for (final match in pattern.allMatches(title))
          if ((int.tryParse(match.group(1)!) ?? 0) > 0)
            int.parse(match.group(1)!),
    };
    return ids.length == 1 ? ids.single : null;
  }

  /// 提取轻量季集语义（内置兜底，无须依赖完整刮削解析器）。
  static ({EpisodeCategory category, int season, int? episode})
  parseLightweightEpisodeProbe(String fileName, {String? relativePath}) {
    final normalizedPath = (relativePath ?? fileName).replaceAll('\\', '/');
    final segments = normalizedPath
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList();
    final parentDir = segments.length >= 2 ? segments[segments.length - 2] : '';

    if (_isLikelyExtra(fileName, parentDir)) {
      return (category: EpisodeCategory.extra, season: 0, episode: null);
    }

    var season = _extractSeasonFromSegments(segments) ?? 1;
    final stem = _stripKnownExtension(fileName);
    final shielded = _shieldTechnicalNoise(stem);

    final sxeMatch = RegExp(
      r'(?:^|[\s._\-\[\(【])S(\d{1,2})[\s._-]*E(\d{1,4})(?:v\d+)?(?=$|[\s._\-\]\)】])',
      caseSensitive: false,
    ).firstMatch(shielded);
    if (sxeMatch != null) {
      season = int.tryParse(sxeMatch.group(1) ?? '') ?? season;
      final ep = int.tryParse(sxeMatch.group(2) ?? '');
      if (ep != null && ep > 0 && ep <= 2000) {
        return (category: EpisodeCategory.main, season: season, episode: ep);
      }
    }

    final patterns = <RegExp>[
      RegExp(
        r'(?:Episode|EP|E)[.\s_-]*0*(\d{1,4})(?:v\d+)?(?=$|[\s._\-\]\)】])',
        caseSensitive: false,
      ),
      RegExp(r'第\s*0*(\d{1,4})\s*[話话集回]'),
      RegExp(
        r'[\[\(【]\s*0*(\d{1,4})(?:v\d+)?(?:\s*(?:END|FIN|FINAL))?\s*[\]\)】]',
        caseSensitive: false,
      ),
      RegExp(
        r'(?:[\s._]+-[\s._]*|_)0*(\d{1,4})(?:v\d+)?(?=$|[\s._\-\[\(【])',
      ),
      RegExp(r'#0*(\d{1,4})(?:v\d+)?(?=$|[\s._\-\]\)】])'),
      RegExp(r'(?:^|\s)0*(\d{2,3})(?:v\d+)?(?:\s+(?:END|FIN))?$'),
    ];

    for (final pattern in patterns) {
      for (final match in pattern.allMatches(shielded)) {
        final ep = int.tryParse(match.group(1) ?? '');
        if (ep != null && ep > 0 && ep <= 2000 && !_isYearLike(ep)) {
          return (category: EpisodeCategory.main, season: season, episode: ep);
        }
      }
    }

    return (category: EpisodeCategory.main, season: season, episode: null);
  }

  static bool _isLikelyExtra(String fileName, String parentDir) {
    final extraToken = RegExp(
      r'(?<![a-z0-9])(?:ncop|nced|nc|pv|cm|ova|oad|oav|sp|special|menu|trailer|teaser|preview|making|interview|bonus|tokuten|omake)(?:\d+)?(?![a-z0-9])|特典|映像特典|予告|預告|预告',
      caseSensitive: false,
    );
    if (extraToken.hasMatch(fileName)) return true;
    if (parentDir.isNotEmpty &&
        !isSubtitleSubdirName(parentDir) &&
        !isSeasonOrVolumeSegment(parentDir) &&
        (_extraVideoDir.hasMatch(parentDir) || extraToken.hasMatch(parentDir))) {
      return true;
    }
    return false;
  }

  static int? _extractSeasonFromSegments(List<String> segments) {
    final seasonPattern = RegExp(
      r'^(?:seasons?[ ._-]*(\d{1,2})|s(\d{1,2})|第(\d{1,2})[季期])$',
      caseSensitive: false,
    );
    for (final seg in segments) {
      final match = seasonPattern.firstMatch(seg.trim());
      if (match != null) {
        final raw = match.group(1) ?? match.group(2) ?? match.group(3);
        final parsed = raw == null ? null : int.tryParse(raw);
        if (parsed != null && parsed >= 0 && parsed <= 99) {
          return parsed;
        }
      }
    }
    return null;
  }

  static String _stripKnownExtension(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot <= 0) return fileName;
    final ext = fileName.substring(dot).toLowerCase();
    if (KonataMediaExtensions.video.contains(ext) ||
        KonataMediaExtensions.subtitle.contains(ext)) {
      return fileName.substring(0, dot);
    }
    return fileName;
  }

  static String _shieldTechnicalNoise(String stem) {
    return stem
        .replaceAll(
          RegExp(r'[\[(（【]\s*[0-9a-fA-F]{8}\s*[\])）】]'),
          ' ',
        )
        .replaceAll(
          RegExp(
            r'\b(?:\d{3,4}x\d{3,4}|\d{3,4}[pi]|x26[45]|h\.?26[45]|hevc|avc|av1|ma\d+p|\d{1,2}bit|10bit|8bit|12bit)\b',
            caseSensitive: false,
          ),
          ' ',
        );
  }

  static bool _isYearLike(int value) => value >= 1980 && value <= 2039;
}
