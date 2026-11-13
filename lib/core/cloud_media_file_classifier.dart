/// Conservative filename and directory classification shared by scans and
/// repair passes. Provider IDs are optional; media semantics come first.
abstract final class CloudMediaFileClassifier {
  static final _supplementaryDirectory = RegExp(
    r'^(?:sp|sps|special|specials|extra|extras|bonus|nc|ncop|nced|pv|cm|'
    r'menu|menus|samples?|(?:eizou[\s._-]+)?tokuten|creditless|textless|interviews?|events?|making|'
    r'trailers?|previews?|promos?|promotion|tv[\s._-]*spots?|tvcm|bdcm|'
    r'effects?|fan[\s._-]*disc|fandisc|.*pvd.*|reviews?|'
    r'logo|logos|voices?|ost|soundtrack|gallery|artwork|特典|映像特典|'
    r'特典映像|花絮|幕后|访谈|预告|預告|宣传|聲優|声优|'
    r'(?:op|ed)(?:[\s._&-]*(?:op|ed))*)$',
    caseSensitive: false,
  );

  static final _preview = RegExp(
    r'予告|預告|预告|(^|[^a-z])(trailer|teaser|preview)(?=[^a-z]|$)',
    caseSensitive: false,
  );

  static final _noCredit = RegExp(
    r'creditless|textless|no[ ._-]?credit|non[ ._-]?telop|'
    r'non[ ._-]?credit|ノンクレジット|ノクレジット|ノンクレ|ノンテロップ',
    caseSensitive: false,
  );

  static final delimitedEpisode = RegExp(
    r'[\s_]+[-–—][\s_]+(\d{1,3})(?:v\d+)?[\s_]+[-–—][\s_]+(?=\S)',
    caseSensitive: false,
  );

  static final _supplementaryTag = RegExp(
    r'[\[【]\s*(?:メニュ[ー一][ ._-]*\d*|drama[ ._-]*cd)\s*[\]】]',
    caseSensitive: false,
  );

  static final _releaseSample = RegExp(
    r'\b(?:\d{3,4}p|bdrip|bluray|webrip|web[._-]?dl)\b.*[._-]sample\.[^.]+$',
    caseSensitive: false,
  );

  static final _discAppendix = RegExp(
    r'(?<=\d)[ ._-]+appendix(?=\s*(?:[\[(（【]|\.[^.]+$))|'
    r'[ ._]+[-–—][ ._]+(?:hyakka|百科)[ ._-]*0?[1-9]\d?'
    r'(?=\s*(?:[\[(（【]|\.[^.]+$))',
    caseSensitive: false,
  );

  static final numberedSupplementLabel = RegExp(
    r'(?<=\d)\s+(?:after[ ._-]+phase|post[ ._-]+credits(?:[ ._-]+scene)?)'
    r'(?=\s*(?:\[|\(|\.[a-z0-9]+$))',
    caseSensitive: false,
  );

  static final _videoExtensionSuffix =
      r'\.(?:mkv|mp4|avi|mov|wmv|flv|webm|m4v|ts|m2ts)$';

  static final _crc32Bracket = RegExp(
    r'[\[(（【［]\s*[0-9a-fA-F]{8}\s*[\])）】］]',
  );

  static final _frameRateMarker = RegExp(
    r'(?<![a-z0-9.])\d+(?:\.\d+)?\s*fps(?![a-z0-9])',
    caseSensitive: false,
  );

  static final _standaloneResolution = RegExp(
    r'(?<![a-z0-9])\d{3,4}x\d{3,4}[pi]?(?![a-z0-9])',
    caseSensitive: false,
  );

  static final _bracketBlock = RegExp(
    r'[\[(（【［]([^\]\)）】］]*)[\])）】］]',
  );

  static final _coreTechToken = RegExp(
    r'^(?:'
    r'\d{3,4}x\d{3,4}[pi]?|\d{3,4}[pi]|[248]k|'
    r'\d+(?:\.\d+)?fps|vfr|cfr|'
    r'[xh]\.?26[45]|hevc|avc|av1|vp9|xvid|divx|mpeg[24]?|'
    r'yuv\d{3}p(?:\d{1,2})?|rgb\d*|hdr(?:10(?:\+)?)?|dovi|'
    r'(?:ma|hi)\d{1,2}p|\d{1,2}-?bit'
    r')$',
    caseSensitive: false,
  );

  static final _auxTechToken = RegExp(
    r'^(?:'
    r'bd|bdmv|bdrip|bluray|blu|ray|dvd|dvdrip|web|webrip|webdl|'
    r'tvrip|uhd|fhd|hd|sd|remux|raw|raws|hdr|sdr|dv|nvenc|rip|dl|'
    r'\d*x?(?:flac|aac|opus|ac3|eac3|ddp?|dd|dts|hdma|ma|truehd|'
    r'lpcm|pcm|mp3|vorbis|alac|atmos)(?:x?\d+(?:\.\d+)?)?|'
    r'audio|dual|multi|lossless|\d+(?:\.\d+)?ch|2\.0|5\.1|7\.1|'
    r'chs|cht|chi|zh|cn|jp|jpn|jap|en|eng|sub|subs|softsub|hardsub|'
    r'gb|big5|(?:ass|ssa|srt|pgs|sup)(?:x\d+)?|vobsub|mkv|mp4|v\d+|'
    r'[0-9a-f]{8}'
    r')$',
    caseSensitive: false,
  );

  /// Strips CRC32 checksum brackets, technical spec bracket blocks
  /// (resolution/codec/bit-depth/audio), and frame-rate tags before extra
  /// classification or episode extraction.
  static String stripTechnicalNoise(String name) {
    var result = name
        .replaceAll(_crc32Bracket, ' ')
        .replaceAll(_frameRateMarker, ' ');
    result = result.replaceAllMapped(_bracketBlock, (match) {
      final inner = match.group(1)!.trim();
      if (inner.isEmpty || _isTechnicalBracketContent(inner)) {
        return ' ';
      }
      return match.group(0)!;
    });
    result = result.replaceAll(_standaloneResolution, ' ');
    return result
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAllMapped(
          RegExp(
            r'\s+(\.(?:mkv|mp4|avi|mov|wmv|flv|webm|m4v|ts|m2ts))$',
            caseSensitive: false,
          ),
          (m) => m.group(1)!,
        )
        .trim();
  }

  static bool _isTechnicalBracketContent(String content) {
    final normalized = _normalizeName(content).trim();
    if (normalized.isEmpty) return true;
    final rawTokens = normalized
        .split(RegExp(r'[\s_,|/\\+&]+'))
        .where((t) => t.isNotEmpty)
        .toList(growable: false);
    if (rawTokens.isEmpty) return false;
    var hasCoreTech = false;
    for (final token in rawTokens) {
      final parts = token.contains('-')
          ? token.split('-').where((p) => p.isNotEmpty)
          : <String>[token];
      for (final part in parts) {
        if (_coreTechToken.hasMatch(part)) {
          hasCoreTech = true;
          continue;
        }
        if (_auxTechToken.hasMatch(part)) {
          continue;
        }
        return false;
      }
    }
    return hasCoreTech;
  }

  static final _supplementaryName = RegExp(
    r'(?<![a-z0-9])(?:'
    r'ncoped|ncop|nced|menus?(?:[ ._-]*ex)?\d*|pv|pvcm|cm|mv|ova(?:v\d+)?|oad|sp|'
    r'logo|rl|info|websp|extras?\d*|'
    r'interview|making|'
    r"supporters?(?:['’]s?)?[\s._-]+gathering(?:[\s._-]*(?:19|20)\d{2})?|"
    r'digest|trailer|teaser|preview|promo|promotion|commentary|recitation|'
    r'picture[\s._-]*collection|eyecatch|artwork|gallery|spot|tv[\s._-]*cm|'
    r'bd[\s._-]*cm|bd[\s._-]*menu\d*|'
    r'music[\s._-]*(?:video|clip)|musical[\s._-]*clip|'
    r'mini[\s._-]*(?:anime|series|story|episode)s?|'
    r'short[\s._-]*(?:story|episode|anime|animation|film|special)s?|'
    r'character[\s._-]*(?:short|song|video|clip|movie)s?|'
    r'(?:opening|ending)(?:[\s._-]*(?:movie|video|clip|special|ver\.?|\d+))*|'
    r'specials?|featurettes?|prologue|epilogue|lite|'
    r'eng(?:lish)?[\s._-]*credits?|'
    r'anniversary|congrats(?:ulations)?[\s._-]*messages?|'
    r'true[\s._-]*end[\s._-]*episode|remix(?:[\s._-]*v?\d+)?|'
    r'arcadian[\s._-]*memory|events?|ng[\s._-]*cuts|'
    r'tokubetsu[\s._-]*hen|zenyasai|twi[\s._-]*yaba|'
    r'insert(?:song)?\d+|another[\s._-]*world|'
    r'one[\s._-]*more[\s._-]*time|true[\s._-]*birth[\s._-]*edition|'
    r'previously|shinka[\s._-]*scene|magical[\s._-]*festa|'
    r'karaoke|with[\s._-]*credits|record[\s._-]*(?:19|20)\d{2}|'
    r'pv(?:cm|tri)\d*|reviews?|'
    r'ex[\s._-]*season|pre[\s._-]*show|reminder|prototype|'
    r'side[\s._-]*(?:galo|lio)|gomband|'
    r'transformation|attack[\s._-]*scene|'
    r'panel|discussion|summary|recap|extra[\s._-]*episode|short[\s._-]*track|'
    r'oab|ex[ ._-]*\d+|ex(?=$|[\]）】#])|#[ ._-]*ex'
    r')(?=[^a-z]|$)|'
    r'(?:[\[(【]\s*(?<![a-z0-9])(?:op|ed)(?:v?\d{1,2})?(?![a-z0-9])\s*[\]）】]|'
    r'(?<![a-z0-9])(?:op|ed)(?:v?\d{1,2})?(?![a-z0-9])'
    '(?=\\s*(?:[\\[(（【]|$_videoExtensionSuffix|\$))|'
    r'(?<![a-z0-9])(?:op|ed)v?\d{1,2}(?![a-z0-9])'
    r'(?=\s*(?:[\[(（【._-]|$)))|'
    r'予告|預告|预告|特報|映像特典|特典|インタビュー|メイキング|座談会|'
    r'舞台|イベント|番宣|コメンタリー|放送前|発売前|宣伝|スポット|'
    r'プロモーションビデオ|オープニング|エンディング|ピクチャー|アイキャッチ|'
    r'トーク|特番|ラジオ|キャスト|アフレコ|制作|現場|パイロット|'
    r'ダイジェスト|総集編|ステージ|ライブ|未公開|メイキング|指南|'
    r'感謝祭|上映会|試写会|ミュージッククリップ|イラスト|エンドカード|'
    r'ミニアニメ|ショートエピソード|ショートアニメ|短編|短片|'
    r'番外編|番外篇|番外|特別編|特别篇|特別版|特别版|'
    r'特別企画|特别企划|放送直前|新作アニメーション|引退記念|'
    r'ミュージカルパート|挿入歌|キャラクターソング|キャラソン|'
    r'イメージボード|ラッシュビデオ|ガイド|講座|讲座|'
    r'映像|本編制作',
    caseSensitive: false,
  );

  static final _opEdExtra = RegExp(
    r'[\[(【（]\s*(?<![a-z0-9])(?:nc(?:oped|op|ed)|op|ed)(?:[ ._-]*v?\d{1,2})?(?![a-z0-9])\s*[\])】）]|'
    r'(?<![a-z0-9])nc(?:oped|op|ed)(?:[ ._-]*v?\d{1,2})?(?![a-z0-9])|'
    r'(?<![a-z0-9])(?:op|ed)(?:v?\d{1,2})?(?![a-z0-9])'
    '(?=\\s*(?:[\\[(（【]|$_videoExtensionSuffix|\$))|'
    r'(?<![a-z0-9])(?:op|ed)v?\d{1,2}(?![a-z0-9])'
    r'(?=\s*(?:[\[(（【._-]|$))',
    caseSensitive: false,
  );

  static final _strongSupplementaryName = RegExp(
    r'(?<![a-z0-9])(?:'
    r'ncoped|ncop|nced|pv(?:cm|tri)?\d*|tv[\s._-]*cm|bd[\s._-]*cm|cm|'
    r'bd[\s._-]*menu\w*|menus?(?:[ ._-]*ex)?\d*|making|commentary|eyecatch|karaoke|'
    r'trailers?|teasers?|previews?|promos?|promotion|samples?|'
    r'drama[\s._-]*cd|picture[\s._-]*collection|artwork|gallery|'
    r'creditless|textless'
    r')(?![a-z0-9])|'
    r'予告|預告|预告|特報|メニュ[ー一]?|メイキング|映像特典|ノンクレ',
    caseSensitive: false,
  );

  /// Whether [name] is a standalone OP/ED extra token (strict alphanumeric boundaries).
  static bool isOpEdExtra(String name) =>
      _opEdExtra.hasMatch(stripTechnicalNoise(name));

  /// Whether a video carries strong extra markers (NCOP/NCED/PV/CM/Menu/Preview/
  /// OP/ED/Making/Sample/Supplementary directory) as opposed to weak notes such
  /// as `[Special]`, `Recap`, or `総集編`.
  static bool isStrongSupplementary(String directory, String name) {
    if (isSupplementaryDirectory(directory)) return true;
    if (_releaseSample.hasMatch(name)) return true;
    final cleanName = stripTechnicalNoise(name);
    return _preview.hasMatch(cleanName) ||
        _noCredit.hasMatch(cleanName) ||
        _supplementaryTag.hasMatch(cleanName) ||
        _discAppendix.hasMatch(cleanName) ||
        _strongSupplementaryName.hasMatch(cleanName) ||
        _opEdExtra.hasMatch(cleanName) ||
        _isFractionalEpisode(cleanName);
  }

  static bool isPreview(String name) =>
      _preview.hasMatch(stripTechnicalNoise(name));

  static bool isNoCredit(String name) =>
      _noCredit.hasMatch(stripTechnicalNoise(name));

  /// Whether a video is clearly side content without needing directory-wide
  /// counts. Scanners use this to identify the remaining unnumbered main
  /// candidate in a directory that also contains trailers, menus and events.
  static bool isClearlySupplementary(String directory, String name) {
    if (isSupplementaryDirectory(directory)) return true;
    if (_releaseSample.hasMatch(name)) return true;
    final cleanName = stripTechnicalNoise(name);
    return _preview.hasMatch(cleanName) ||
        _noCredit.hasMatch(cleanName) ||
        _supplementaryTag.hasMatch(cleanName) ||
        _discAppendix.hasMatch(cleanName) ||
        _supplementaryName.hasMatch(cleanName) ||
        _opEdExtra.hasMatch(cleanName) ||
        _isFractionalEpisode(cleanName);
  }

  static bool isSupplementaryDirectory(String path) {
    final segments = path
        .replaceAll('\\', '/')
        .split('/')
        .map((segment) => segment.trim())
        .where((segment) => segment.isNotEmpty);
    return segments.any(_supplementaryDirectory.hasMatch);
  }

  static String classifyAsset(
    String directory,
    String name,
    String kind, {
    int? videoCount,
    int? numberedVideoCount,
    int? unresolvedUnnumberedVideoCount,
  }) {
    if (kind != 'video') return 'metadata';
    if (isClearlySupplementary(directory, name)) return 'extra';

    final episodeNumber = episodeNumberFromNameInDirectory(directory, name);
    if (episodeNumber != null) return 'episode';

    // A movie or one-part work often has no episode token. Treat an otherwise
    // unclassified video as main content when it is the only video in its
    // directory or when the work name explicitly says movie.
    if (_isMovieContext(directory, name)) return 'episode';
    if (RegExp(r'\{tmdb-\d+\}', caseSensitive: false).hasMatch(name)) {
      return 'episode';
    }
    if (_isYearVariantFeature(
      directory,
      name,
      videoCount,
      numberedVideoCount,
    )) {
      return 'episode';
    }
    if ((videoCount ?? 0) == 1 || unresolvedUnnumberedVideoCount == 1) {
      return 'episode';
    }
    return 'review';
  }

  static bool _looksLikeTitleNumber(
    String directory,
    String name,
    int episodeNumber,
  ) {
    final meaningfulDirectory = directory
        .replaceAll('\\', '/')
        .split('/')
        .where((segment) => segment.trim().isNotEmpty)
        .where(
          (segment) => !RegExp(
            r'^(?:s\d{1,2}|season[ ._-]*\d{1,2}|'
            r'第[0-9一二三四五六七八九十百]+[季期]|'
            r'episodes?|tv[ ._-]*ver|sp|sps|extras?|bonus|nc)$',
            caseSensitive: false,
          ).hasMatch(segment.trim()),
        )
        .join('/');
    final directoryNumbers = RegExp(r'(?<!\d)(\d{1,4})(?!\d)')
        .allMatches(meaningfulDirectory)
        .map((match) => int.tryParse(match.group(1)!))
        .whereType<int>()
        .toSet();
    if (!directoryNumbers.contains(episodeNumber)) return false;
    final nameNumbers =
        RegExp(r'(?<![a-z0-9])(\d{1,4})(?!\d)', caseSensitive: false)
            .allMatches(name)
            .map((match) => int.tryParse(match.group(1)!))
            .whereType<int>()
            .where((value) => value != 1080 && value != 720 && value != 480)
            .toSet();
    return nameNumbers.length <= 1;
  }

  /// Resolves a filename episode number with directory-aware title-number
  /// suppression. Callers that build indexes should use this variant so a
  /// numeric work title does not inflate the directory's numbered-video count.
  static int? episodeNumberFromNameInDirectory(String directory, String name) {
    final cleanName = stripTechnicalNoise(name);
    final episodeNumber = episodeNumberFromName(cleanName);
    if (episodeNumber == null ||
        _hasExplicitEpisodeMarker(cleanName) ||
        !_looksLikeTitleNumber(directory, cleanName, episodeNumber)) {
      return episodeNumber;
    }
    return null;
  }

  /// Explicit markers are authoritative even when the work title contains the
  /// same number. Title-number suppression is only for loose fallback matches.
  static bool _hasExplicitEpisodeMarker(String name) {
    final searchable = _withoutSeasonAndPartMarkers(
      _normalizeName(stripTechnicalNoise(name)),
    );
    if (RegExp(
      r'(?<![a-z0-9])s\d{1,2}[ ._+-]*e(?:p)?[ ._-]*\d{1,4}',
      caseSensitive: false,
    ).hasMatch(searchable)) {
      return true;
    }
    if (RegExp(
      r'(?<![a-z0-9])(?:episode|ep)(?![a-z])[ ._-]*\d{1,4}',
      caseSensitive: false,
    ).hasMatch(searchable)) {
      return true;
    }
    if (RegExp(
      r'(?<![a-z0-9])e(?![a-z])[ ._-]*\d{1,3}(?![a-z0-9])',
      caseSensitive: false,
    ).hasMatch(searchable)) {
      return true;
    }
    if (RegExp(
      r'第[ ._-]*(?:[0-9]+|[一二三四五六七八九十百〇零壱弐参伍拾]+)'
      r'[ ._-]*(?:话|話|集|回)',
    ).hasMatch(searchable)) {
      return true;
    }
    if (RegExp(
      r'(?<![a-z0-9])stage[ ._-]*\d{1,4}(?![a-z0-9])',
      caseSensitive: false,
    ).hasMatch(searchable)) {
      return true;
    }
    if (RegExp(
      r'(?<![a-z0-9])(?:19|20)\d{2}[ ._-]+-[ ._-]*\d{1,4}(?=\s+\S)',
    ).hasMatch(searchable)) {
      return true;
    }
    if (RegExp(
      r'[#＃][ ._-]*\d{1,4}(?:[ ._-]*(?:end|fin|final|完))?',
      caseSensitive: false,
    ).hasMatch(searchable)) {
      return true;
    }
    if (_episodeFromBrackets(searchable) != null) return true;
    if (delimitedEpisode.hasMatch(searchable)) return true;
    if (RegExp(
      r'(?:^|[\s\]】)])\s*\d{1,4}'
      r'(?:[-–—]\d{1,4}|\s*[&~]\s*\d{1,4})'
      '(?=\\s*(?:[\\[(（【]|$_videoExtensionSuffix|\$))',
      caseSensitive: false,
    ).hasMatch(searchable)) {
      return true;
    }
    if (RegExp(
      r'(?:^|[\s\]】)])\d*\s*[-–—._]\s*(?!\d{3,4}[pi](?![a-z0-9]))\d{1,4}(?:[ ._-]*[a-z])?'
      '(?=\\s*(?:[\\[(（【「]|$_videoExtensionSuffix|v\\d+\\b|end\\b|fin\\b|final\\b|完|\$))',
      caseSensitive: false,
    ).hasMatch(searchable)) {
      return true;
    }
    return RegExp(
      r'(?:^|[\s\]】)])\s*\d{1,4}(?:[ ._-]*[a-z])?'
      r'(?=\s*(?:[-–—._]|[\[(（【「]|v\d+\b|end\b|fin\b|final\b|'
      r'(?:tv|theatre|theater|encore|uncensored|nc)[ ._-]*ver|完|$))',
      caseSensitive: false,
    ).hasMatch(searchable);
  }

  /// Extracts the first episode represented by a filename. Range files such
  /// as 01-04 and 003&004 map to their first episode; the original filename is
  /// retained by the catalog for playback and display.
  static int? episodeNumberFromName(String name) {
    final normalized = _normalizeName(stripTechnicalNoise(name));
    final normalizedStem = normalized.replaceFirst(
      RegExp(
        r'\.(?:mkv|mp4|avi|mov|wmv|flv|webm|m4v|ts|m2ts)$',
        caseSensitive: false,
      ),
      '',
    );
    if (RegExp(r'^\s*\d+\s*[/／]\s*\d+\s*$').hasMatch(normalizedStem)) {
      return null;
    }
    final searchable = _withoutSeasonAndPartMarkers(normalized).replaceAll(
      RegExp(r'(?<![a-z0-9])\d{1,2}\.\d{1,2}\s*ch\b', caseSensitive: false),
      ' ',
    );

    var match = RegExp(
      r'(?<![a-z0-9])s\d{1,2}[ ._+-]*e(?:p)?[ ._-]*(\d{1,4})',
      caseSensitive: false,
    ).firstMatch(searchable);
    final seasonEpisode = _number(match?.group(1));
    if (seasonEpisode != null) return seasonEpisode;

    match = RegExp(
      r'(?<![a-z0-9])(?:episode|ep)(?![a-z])[ ._-]*(\d{1,4})',
      caseSensitive: false,
    ).firstMatch(searchable);
    final explicitEpisode = _number(match?.group(1));
    if (explicitEpisode != null) return explicitEpisode;

    match = RegExp(
      r'(?<![a-z0-9])e(?![a-z])[ ._-]*(\d{1,3})(?![a-z0-9])',
      caseSensitive: false,
    ).firstMatch(searchable);
    final shortEpisode = _number(match?.group(1));
    if (shortEpisode != null) return shortEpisode;

    match = RegExp(
      r'(?<![a-z0-9])stage[ ._-]*(\d{1,4})(?![a-z0-9])',
      caseSensitive: false,
    ).firstMatch(searchable);
    final stage = _number(match?.group(1));
    if (stage != null) return stage;

    match = RegExp(
      r'(?<![a-z0-9])(?:19|20)\d{2}[ ._-]+-[ ._-]*(\d{1,4})'
      r'(?=\s+\S)',
    ).firstMatch(searchable);
    final datedEpisode = _number(match?.group(1));
    if (datedEpisode != null) return datedEpisode;

    match = RegExp(
      r'第[ ._-]*([0-9]+|[一二三四五六七八九十百〇零壱弐参伍拾]+)'
      r'[ ._-]*(?:话|話|集|回)',
    ).firstMatch(searchable);
    final localized = _number(match?.group(1));
    if (localized != null) return localized;

    match = RegExp(
      r'[#＃][ ._-]*(\d{1,4})(?:[ ._-]*(?:end|fin|final|完))?',
      caseSensitive: false,
    ).firstMatch(searchable);
    final hash = _number(match?.group(1));
    if (hash != null) return hash;

    final bracketed = _episodeFromBrackets(searchable);
    if (bracketed != null) return bracketed;

    final delimited = _number(
      delimitedEpisode.firstMatch(searchable)?.group(1),
    );
    if (delimited != null) return delimited;

    match = RegExp(
      r'(?:^|[\s\]】)])\s*(\d{1,4})'
      r'(?:[-–—]\d{1,4}|\s*[&~]\s*\d{1,4})'
      '(?=\\s*(?:[\\[(（【]|$_videoExtensionSuffix|\$))',
      caseSensitive: false,
    ).firstMatch(searchable);
    final rangeStart = _number(match?.group(1));
    if (rangeStart != null) return rangeStart;

    match = RegExp(
      r'(?:^|[\s\]】)])\d*\s*[-–—._]\s*(?!\d{3,4}[pi](?![a-z0-9]))(\d{1,4})(?:[ ._-]*[a-z])?'
      '(?=\\s*(?:[\\[(（【「]|$_videoExtensionSuffix|v\\d+\\b|end\\b|fin\\b|final\\b|完|\$))',
      caseSensitive: false,
    ).firstMatch(searchable);
    final separated = _number(match?.group(1), rejectYears: false);
    if (separated != null) return separated;

    match = RegExp(
      r'(?:^|[\s\]】)])\s*(\d{1,4})(?:[ ._-]*[a-z])?'
      r'(?=\s*(?:[-–—._]|[\[(（【「]|v\d+\b|end\b|fin\b|final\b|'
      r'(?:tv|theatre|theater|encore|uncensored|nc)[ ._-]*ver|完|$))',
      caseSensitive: false,
    ).firstMatch(searchable);
    final trailing = _number(match?.group(1));
    if (trailing != null) return trailing;

    match = RegExp(r'\((\d{1,4})\)').firstMatch(searchable);
    final parenthesized = _number(match?.group(1));
    if (parenthesized != null) return parenthesized;

    match = RegExp(
      r'[^\x00-\x7f]\s*(\d{1,4})'
      r'(?=\s*(?:[\[(（]|\.(?:mkv|mp4|avi|mov|wmv|flv|webm|m4v|ts|m2ts)$|$))',
    ).firstMatch(searchable);
    final adjacentLocalized = _number(match?.group(1));
    if (adjacentLocalized != null) return adjacentLocalized;

    match = RegExp(
      r'^[ ._-]*(\d{1,4})(?:[ ._-]*[a-z])?'
      r'(?=\s*(?:\.(?:mkv|mp4|avi|mov|wmv|flv|webm|m4v|ts|m2ts)$|[-–—._]))',
      caseSensitive: false,
    ).firstMatch(searchable);
    final leading = _number(match?.group(1));
    if (leading != null) return leading;
    return _looseEpisodeNumber(searchable);
  }

  static bool _isFractionalEpisode(String name) =>
      RegExp(r'(?:^|[\[(_【\s])\d{1,3}\.\d(?=[\])）._\s]|$)').hasMatch(name);

  static bool _isMovieContext(String directory, String name) {
    final dot = name.lastIndexOf('.');
    final stem = dot < 0 ? name : name.substring(0, dot);
    return RegExp(
      r'电影|剧场版|劇場版|映画|movie|film|gekijouban|'
      r'the[\s._-]*final|活動写真|活动写真|終局特異点|终局特异点|'
      r'[\[(（]\s*m\d{1,2}\s*[\]）)]|'
      r'main[\s._-]*(?:movie|feature)?',
      caseSensitive: false,
    ).hasMatch('$directory/$stem');
  }

  static bool _isYearVariantFeature(
    String directory,
    String name,
    int? videoCount,
    int? numberedVideoCount,
  ) {
    if ((videoCount ?? 0) < 2) return false;
    final stem = name.replaceFirst(
      RegExp(
        r'\.(?:mkv|mp4|avi|mov|wmv|flv|webm|m4v|ts|m2ts)$',
        caseSensitive: false,
      ),
      '',
    );
    final nameYears = RegExp(
      r'(?<![\dx])(?:19|20)\d{2}(?![\dx])',
    ).allMatches(stem).map((match) => match.group(0)!).toSet();
    final directoryYears = RegExp(
      r'(?<![\dx])(?:19|20)\d{2}(?![\dx])',
    ).allMatches(directory).map((match) => match.group(0)!).toSet();
    return nameYears.isNotEmpty && directoryYears.isNotEmpty;
  }

  static int? _episodeFromBrackets(String name, {bool completeOnly = true}) {
    for (final bracket in RegExp(r'[\[【]([^\]】]+)[\]】]').allMatches(name)) {
      final content = bracket.group(1)!.trim();
      if (content.isEmpty ||
          RegExp(
            r'^(?:\d{3,4}p|[248]k|[xh][ ._-]?26[45]|hevc|avc|av1|ma10p|'
            r'flac|aac|opus|ac3|eac3|dts|10bit|hi10p|web|bd|dvd)',
            caseSensitive: false,
          ).hasMatch(content)) {
        continue;
      }
      final suffix = completeOnly
          ? r'(?=\s*(?:$|[-–—&~]\s*\d|\([^)]*\)\s*$)|\s+(?:Ma\d+p|\d{3,4}p|BDRip|WEB|HEVC|AVC|[xh][ ._-]?26[45])(?=$|[^a-z0-9]))'
          : r'(?![a-z0-9])';
      final match = RegExp(
        r'^(?:(?:movie|tv|episode|ep|part|act|final[ ._-]*act|chapter|'
        r'record|vol(?:ume)?|disc)[ ._-]*)?(\d{1,4})(?:v\d+)?'
        '(?:[ ._-]*(?:end|fin|final))?$suffix',
        caseSensitive: false,
      ).firstMatch(content);
      var group = 1;
      var entryMatch = match;
      if (!completeOnly &&
          entryMatch == null &&
          RegExp(r'[\u3400-\u9fff]').hasMatch(content) &&
          content.length <= 40) {
        entryMatch = RegExp(r'(\d{1,4})\s*$').firstMatch(content);
        group = 1;
      }
      final number = _number(entryMatch?.group(group));
      if (number != null && !_technicalNumber(number)) return number;
    }
    // Prefer complete episode evidence anywhere before legacy annotated tokens.
    return completeOnly
        ? _episodeFromBrackets(name, completeOnly: false)
        : null;
  }

  static int? _looseEpisodeNumber(String name) {
    final stem = name.replaceFirst(
      RegExp(
        r'\.(?:mkv|mp4|avi|mov|wmv|flv|webm|m4v|ts|m2ts)$',
        caseSensitive: false,
      ),
      '',
    );
    if (RegExp(r'^\s*\d+\s*[/／]\d+\s*$').hasMatch(stem)) return null;
    final candidates = <int>[];
    for (final match in RegExp(
      r'(?<![a-z0-9])(\d{1,4})(?:v\d+)?(?![a-z0-9])',
      caseSensitive: false,
    ).allMatches(name)) {
      final value = _number(match.group(1));
      if (value == null || _technicalNumber(value)) continue;
      if (match.start > 0 && '/／'.contains(name[match.start - 1])) {
        continue;
      }
      final tail = name.substring(match.end);
      if (RegExp(
        r'^\s*[._-]*\s*(?:[\[(（【]|\.(?:mkv|mp4|avi|mov|wmv|flv|webm|m4v|ts|m2ts)$|'
        r'(?:\d{3,4}p|bd|web|dvd|tv|hevc|avc|[xh][ ._-]?26[45]|flac|aac|'
        r'opus|ac3|dts|end|fin|final|premiere|early[\s._-]*screening|'
        r'screening)\b)',
        caseSensitive: false,
      ).hasMatch(tail)) {
        candidates.add(value);
      }
    }
    return candidates.isEmpty ? null : candidates.last;
  }

  static bool _technicalNumber(int value) =>
      value >= 1800 && value <= 2200 ||
      const {
        240,
        360,
        480,
        540,
        576,
        720,
        848,
        960,
        1080,
        1280,
        1440,
        1920,
        2160,
        3840,
        4096,
      }.contains(value);

  static int? _number(String? raw, {bool rejectYears = true}) {
    if (raw == null || raw.isEmpty) return null;
    final arabic = int.tryParse(raw);
    final value = arabic ?? _localizedNumber(raw);
    if (value == null || value < 0) return null;
    if (rejectYears && value >= 1800 && value <= 2200) return null;
    return value;
  }

  static int? _localizedNumber(String raw) {
    const digits = <String, int>{
      '〇': 0,
      '零': 0,
      '一': 1,
      '壱': 1,
      '二': 2,
      '弐': 2,
      '三': 3,
      '参': 3,
      '四': 4,
      '五': 5,
      '伍': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
      '十': 10,
      '拾': 10,
      '百': 100,
    };
    if (raw.isEmpty) return null;
    var total = 0;
    var current = 0;
    for (final character in raw.split('')) {
      final value = digits[character];
      if (value == null) return null;
      if (value == 10 || value == 100) {
        total += (current == 0 ? 1 : current) * value;
        current = 0;
      } else {
        current = value;
      }
    }
    return total + current;
  }

  static String _normalizeName(String name) => name
      .replaceAllMapped(
        RegExp('[０-９]'),
        (match) => String.fromCharCode(match.group(0)!.codeUnitAt(0) - 0xfee0),
      )
      .replaceAll('（', '(')
      .replaceAll('）', ')')
      .replaceAll('［', '[')
      .replaceAll('］', ']')
      .replaceAll('：', ':');

  static String _withoutSeasonAndPartMarkers(String name) => name.replaceAll(
    RegExp(
      r'(?<![a-z0-9])s\d{1,2}(?![a-z0-9])|'
      r'(?<![a-z0-9])season[ ._]*\d{1,2}(?![a-z0-9])|'
      r'\d{1,2}(?:st|nd|rd|th)[ ._-]*season|'
      r'第[ ._-]*[0-9一二三四五六七八九十百]+[ ._-]*[季期]|'
      r'(?<![a-z0-9])part[ ._-]*\d{1,2}(?![a-z0-9])|'
      r'(?<![a-z0-9])\d{1,3}[ ._-]*sai(?![a-z0-9])|'
      r'(?<!\d)\d{1,3}\s*(?:歳|岁|周年)(?!\d)|'
      r'(?<![a-z0-9])\d{1,3}[ ._-]*bit(?![a-z0-9])|'
      r'(?<![a-z0-9])[xh][ ._-]?26[45](?![a-z0-9])',
      caseSensitive: false,
    ),
    ' ',
  );
}
