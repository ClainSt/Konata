import 'cloud_media_file_classifier.dart';
import 'personal_filename_parser.dart';
import 'work_matcher.dart';

/// Filename tokens are used only for matching and short extra labels.
class CloudMediaAssetPresentation {
  /// Explicit film labels on unnumbered main files in a television inventory.
  static bool isIndependentMovie(Map<String, Object?> asset) {
    if (asset['category'] != 'main' ||
        asset['episode'] != null ||
        asset['manual_mapping'] == true)
      return false;
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
    if (RegExp(r'^[A-Fa-f0-9]{8}$').hasMatch(trimmed)) return true;
    if (_releaseBracketGroup.hasMatch(trimmed)) return true;
    final tokens = trimmed
        .split(RegExp(r'[\s_./,+&-]+'))
        .where((t) => t.isNotEmpty)
        .toList();
    if (tokens.isEmpty) return true;
    return tokens.every(_technicalBracketToken.hasMatch);
  }

  /// Display-only cleanup: keep content labels and numbering intact.
  static String cleanedExtraFilename(Map<String, Object?> asset) {
    final original = asset['name']?.toString().trim();
    final path =
        (original?.isNotEmpty == true
                ? original!
                : asset['relative_path']?.toString() ?? '')
            .replaceAll('\\', '/')
            .split('/')
            .last;
    final base = path.replaceFirst(
      RegExp(r'\.(?:mkv|mp4|avi|mov|m4v|ts|m2ts|webm)$', caseSensitive: false),
      '',
    );
    var name = base.replaceAllMapped(
      RegExp(r'\[([^\]]*)\]|【([^】]*)】|\(([^)]*)\)'),
      (match) {
        final value = match.group(1) ?? match.group(2) ?? match.group(3)!;
        final release = RegExp(
          r'(?:字幕组|字幕組|压制组|壓製組|VCB-Studio|SweetSub|sub(?:s)?\b|Encode|Rip)',
          caseSensitive: false,
        ).hasMatch(value);
        final checksum = RegExp(r'^[A-Fa-f0-9]{8}$').hasMatch(value.trim());
        return _technicalTag.hasMatch(value.replaceAll('_', ' ')) ||
                _isTechnicalOrReleaseSegment(value) ||
                release ||
                checksum
            ? ' '
            : ' $value ';
      },
    );
    name = name
        .replaceAll(RegExp(r'_|(?<!\d)\.|\.(?!\d)'), ' ')
        .replaceAll(_technicalTag, ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .replaceAll(RegExp(r'^[\s-]+|[\s-]+$'), '');
    return name.isEmpty ? base : name;
  }

  static const _matchableSpecialTypes = {'OVA', 'OAD', 'SP'};
  static const _matchableSpecialFamilies = {'OVA', 'SP', 'OVA_SP'};
  static final _noCreditToken = RegExp(
    r'(?:creditless|textless|non[ ._-]?telop|non[ ._-]?credit|'
    r'ノンクレジット|ノンクレ|ノンテロップ)[ ._:-]*'
    r'(opening|ending|OP|ED)[ ._-]*(\d{1,3})?',
    caseSensitive: false,
  );
  static final _extraToken = RegExp(
    r'(^|[^a-z])(NCOPED|NCOP|NCED|MENU|OVA|OAD|PV|CM|SP|MV|LOGO|RL|'
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

  // Releases such as Moozzi2 use [SP02] or "- SP07 [OVA - 01]" as a disc/clip
  // index before a descriptive bracketed content label. A bare [SP01] stays SP.
  static String? _groupedSpecialContent(String name) {
    var bracketedGroup = true;
    var group = RegExp(r'\[SP\d{1,3}\]', caseSensitive: false).firstMatch(name);
    if (group == null) {
      bracketedGroup = false;
      group = RegExp(
        r'(?:^|[\s._\-–—])SP\d{1,3}\s*(?=\[)',
        caseSensitive: false,
      ).firstMatch(name);
    }
    if (group == null) return null;
    final rawSuffix = name
        .substring(group.end)
        .replaceFirst(
          RegExp(
            r'\.(?:mkv|mp4|avi|mov|m4v|ts|m2ts|webm|png|jpe?g)$',
            caseSensitive: false,
          ),
          '',
        );
    final bracketPattern = RegExp(r'\[([^\]]*)\]|【([^】]*)】|\(([^)]*)\)');
    final bracketContents = <String>[
      for (final m in bracketPattern.allMatches(rawSuffix))
        (m.group(1) ?? m.group(2) ?? m.group(3) ?? '').trim(),
    ];
    final outsideBrackets = rawSuffix
        .replaceAll(bracketPattern, ' ')
        .replaceAll(RegExp(r'^[\s_-]+|[\s_-]+$'), '')
        .trim();
    if (!RegExp(r'[a-z\u3040-\u9fff]', caseSensitive: false).hasMatch(outsideBrackets) &&
        bracketContents.isNotEmpty &&
        bracketContents.every(_isTechnicalOrReleaseSegment)) {
      return null;
    }

    final suffix = rawSuffix
        .replaceAll(
          RegExp(
            r'\([^)]*(?:\bBD\b|1080|1920|x\.?26[45]|Flac)[^)]*\)',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(RegExp(r'\[\s*(?:PNG|JPEG)\s*\]', caseSensitive: false), '')
        .replaceAll(
          RegExp(
            r'\[(?:\d{3,4}p|HEVC\d*|FLAC\d*|Hi10p|x26[45])\]',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(RegExp(r'^[\s_-]+|[\s_-]+$'), '')
        .trim();
    if (!RegExp(r'[a-z\u3040-\u9fff]', caseSensitive: false).hasMatch(suffix)) {
      return null;
    }
    // Codec-only trailing tags do not describe a separate content item.
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

  static String? extraTitle(Map<String, Object?> asset) {
    final original = asset['name']?.toString() ?? '';
    final fractional = RegExp(
      r'\[(\d{1,3}\.\d{1,2})(?=\]|\()',
    ).firstMatch(original);
    if (fractional != null) return 'SP${fractional[1]}';
    final content = _groupedSpecialContent(original);
    final name = content ?? original;
    if (CloudMediaFileClassifier.isPreview(name)) return null;
    final noCredit = _noCreditLabel(name);
    if (noCredit != null) return noCredit;
    final match = _extraToken.firstMatch(name);
    if (match == null) {
      final interview = RegExp(
        r'(^|[^a-z0-9])(IV)[ ._-]?(\d{1,3})(?=[^a-z0-9]|$)',
        caseSensitive: false,
      ).firstMatch(name);
      if (interview != null) return 'IV${interview.group(3)}';
      // Only accept an isolated release label. Codec/resolution tags must
      // never become the title of an otherwise unidentified extra.
      final labels = RegExp(
        r'\[([a-z]{1,8})[ ._-]?(\d{1,3}[a-z]?)\]',
        caseSensitive: false,
      ).allMatches(name);
      for (final label in labels) {
        final prefix = label.group(1)!.toUpperCase();
        if (const {
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
        }.contains(prefix)) {
          continue;
        }
        return '$prefix${label.group(2)!.toUpperCase()}';
      }
      return content;
    }
    final number = (match.group(3) ?? '').replaceAll(RegExp(r'[ ._-]'), '');
    final type = match.group(2)!.toUpperCase();
    if (_matchableSpecialTypes.contains(type)) {
      final promo = _promoOverrideToken.firstMatch(name);
      if (promo != null) {
        if (content != null) return content;
        final promoRaw = promo.group(2)!.toUpperCase();
        final promoType = promoRaw == 'PV' ? 'PV' : 'CM';
        final promoNum = (promo.group(3) ?? '').replaceAll(
          RegExp(r'[ ._-]'),
          '',
        );
        return '$promoType$promoNum';
      }
    }
    return '${type == 'INFORMATION' ? 'INFO' : type}$number';
  }

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

  static bool _isNarrativeSpecialDirAsset(Map<String, Object?> asset, String name) {
    final path = '${asset['relative_path'] ?? ''}'.replaceAll('\\', '/');
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.length <= 1) return false;
    final parentDirs = segments.sublist(0, segments.length - 1);
    final inSpecialDir = parentDirs.any(
      (seg) => RegExp(r'^specials?$', caseSensitive: false).hasMatch(seg),
    );
    if (!inSpecialDir) return false;
    if (CloudMediaFileClassifier.isPreview(name) || _noCreditLabel(name) != null) {
      return false;
    }
    if (_alternateEndingPattern.hasMatch(name)) {
      return !RegExp(
        r'(?<![a-z])(?:ncop(?:ed)?|nced|opening|menu|pv|cm|tvcm|bdcm|pvcm|trailer|preview|teaser)(?![a-z])',
        caseSensitive: false,
      ).hasMatch(name);
    }
    return !RegExp(
      r'(?<![a-z0-9])(?:ncop(?:ed)?|nced|op\d*|ed\d*|opening\d*|ending\d*|menu\d*|pv\d*|cm\d*|tvcm|bdcm|pvcm|spot|trailer|preview|teaser|making|interview|promotion|promo|info|information|logo|eyecatch|artwork|digest|creditless|textless|mv|live|voice|audio|drama|commentary)(?![a-z0-9])',
      caseSensitive: false,
    ).hasMatch(name);
  }

  static String extraType(Map<String, Object?> asset) {
    final original = asset['name']?.toString() ?? '';
    if (RegExp(r'\[\d{1,3}\.\d{1,2}(?=\]|\()').hasMatch(original)) return 'SP';
    final content = _groupedSpecialContent(original);
    final name = content ?? original;
    if (CloudMediaFileClassifier.isPreview(name)) {
      return '预告';
    }
    final noCredit = _noCreditLabel(name);
    if (noCredit != null) return noCredit;
    final match = _extraToken.firstMatch(name);
    if (match != null) {
      final type = match.group(2)!.toUpperCase();
      if (_matchableSpecialTypes.contains(type)) {
        final promo = _promoOverrideToken.firstMatch(name);
        if (promo != null) {
          return promo.group(2)!.toUpperCase() == 'PV' ? 'PV' : 'CM';
        }
      }
      return type == 'INFORMATION' ? 'INFO' : type;
    }
    if (_alternateEndingPattern.hasMatch(name) &&
        !RegExp(
          r'(?<![a-z])(?:ncop(?:ed)?|nced|opening|menu|pv|cm|tvcm|bdcm|pvcm|trailer|preview|teaser)(?![a-z])',
          caseSensitive: false,
        ).hasMatch(name)) {
      return 'SP';
    }
    if (_isNarrativeSpecialDirAsset(asset, name)) return 'SP';
    if (content != null) return '其他';
    final path = '${asset['relative_path'] ?? ''}'.replaceAll('\\', '/');
    if (RegExp(r'(^|/)menus?(/|$)', caseSensitive: false).hasMatch(path)) {
      return 'MENU';
    }
    for (final entry in const {
      'bonus': 'BONUS',
      'extra': 'EXTRA',
      'extras': 'EXTRA',
      'voices': 'VOICE',
      'voice': 'VOICE',
      'live part': 'LIVE',
      'creditless': 'CREDITLESS',
      '映像特典': '映像特典',
      '特典': '特典',
    }.entries) {
      if (RegExp(
        '(^|/)${RegExp.escape(entry.key)}(/|\$)',
        caseSensitive: false,
      ).hasMatch(path)) {
        return entry.value;
      }
    }
    return '其他';
  }

  static String? _noCreditLabel(String name) {
    final match = _noCreditToken.firstMatch(name);
    if (match == null) return null;
    final type = switch (match.group(1)!.toLowerCase()) {
      'opening' => 'OP',
      'ending' => 'ED',
      final value => value.toUpperCase(),
    };
    return 'NC$type${match.group(2) ?? ''}';
  }

  static String category(Map<String, Object?> asset) {
    if (extraType(asset) == 'MENU') return 'extra';
    final category = '${asset['category']}';
    // Legacy/ambiguous videos remain editable as "review" in association
    // management, but the detail page places them under extras so no playable
    // file disappears from the UI.
    return category == 'review' ? 'extra' : category;
  }

  static int seasonNumber(Map<String, Object?> asset) =>
      explicitSeasonNumber(asset) ?? 1;

  static int? explicitSeasonNumber(Map<String, Object?> asset) {
    final explicit = int.tryParse('${asset['season_number'] ?? ''}');
    if (explicit != null) return explicit;
    // A relative asset path can omit the selected library root, so retain
    // the work identity as a fallback. Never infer a season from a bare
    // number: it may be an episode, release year, or resolution.
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
    // A collection marker such as S1+S2 or S01-S02 describes several
    // seasons, not a per-file season. Continue checking other sources so
    // an explicit filename S02E01 still wins over its collection directory.
    if (RegExp(
          r'(?<![a-z0-9])S(\d{1,2})[ ._]*(?:[+&~～]|[-–—])[ ._]*S?(\d{1,2})(?![a-z0-9])',
          caseSensitive: false,
        )
        .allMatches(text)
        .any(
          (match) => int.parse(match.group(1)!) != int.parse(match.group(2)!),
        )) {
      return null;
    }
    final patterns = [
      RegExp(
        r'(?<![a-z0-9])S(\d{1,2})(?=E\d|[^a-z0-9]|$)',
        caseSensitive: false,
      ),
      RegExp(r'(?<![a-z])Season[ ._-]*(\d{1,2})(?!\d)', caseSensitive: false),
      RegExp(
        r'(?<![a-z0-9])(\d{1,2})(?:st|nd|rd|th)[ ._-]+Season\b',
        caseSensitive: false,
      ),
      RegExp(r'第[ ._-]*([0-9一二三四五六七八九十两]+)[ ._-]*[季期]'),
    ];
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

  /// Only unseasoned files may use absolute numbering across consecutive
  /// TMDB seasons. Explicit SxxExx/folder seasons align cumulative numbers
  /// when locked onto season K > 1.
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
      if (targetSeason <= 1 || asset['manual_mapping'] == true || counts is! Map) {
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

  static Map? episode(
    Map<String, Object?> asset,
    Map<String, dynamic> seasons,
  ) {
    if (category(asset) != 'episode') return null;
    final coordinates = episodeCoordinates(asset, seasons);
    if (coordinates == null) return null;
    final entries = seasons['${coordinates.season}'];
    if (entries is! List) return null;
    for (final entry in entries.whereType<Map>()) {
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
    // A later promotional token overrides an earlier OVA/OAD label.
    // Match complete tokens so titles such as "Acme" remain eligible.
    if (RegExp(
      r'(^|[^a-z0-9])(?:tvcm|bdcm|pvcm|cm|pv)(?:[\s._-]*\d+)?(?=[^a-z0-9]|$)',
    ).hasMatch(name)) {
      return false;
    }
    if (RegExp(
      r'menu|trailer|preview|teaser|opening|ncop|nced',
    ).hasMatch(name)) {
      return false;
    }
    if (name.contains('ending') && !_alternateEndingPattern.hasMatch(name)) {
      return false;
    }
    return true;
  }

  static int? explicitSpecialNumber(Map<String, Object?> asset) {
    final original = asset['name']?.toString() ?? '';
    final content = _groupedSpecialContent(original);
    final name = content ?? original;
    final patterns = <RegExp>[
      RegExp(
        r'\b(?:OVA|OAD|SP)(?:[\s._]*[-–—][\s._]*|[\s._-]+|\s*)(\d{1,3})\b',
        caseSensitive: false,
      ),
      RegExp(
        r'[\[(](?:OVA|OAD|SP)(?:[\s._]*[-–—][\s._]*|[\s._-]+|\s*)(\d{1,3})[\])]',
        caseSensitive: false,
      ),
      RegExp(
        r'[\[(]\d+\((?:OVA|OAD|SP)[\s._-]*(\d{1,3})\)[\])]',
        caseSensitive: false,
      ),
    ];
    for (final pattern in patterns) {
      final number = int.tryParse(pattern.firstMatch(name)?.group(1) ?? '');
      if (number != null && number > 0) return number;
    }
    if (RegExp(r'\b(?:OVA|OAD)\b', caseSensitive: false).hasMatch(name)) {
      final bonus = RegExp(
        r'(?:Special|映像特典|特典)[\s._-]*(\d{1,3})(?![\d])',
        caseSensitive: false,
      ).firstMatch(name);
      final number = int.tryParse(bonus?.group(1) ?? '');
      if (number != null && number > 0 && number < 1900) return number;
    }
    return null;
  }

  static int? _specialAirYear(Map<String, dynamic> entry) => int.tryParse(
    RegExp(
          r'^((?:19|20)\d{2})',
        ).firstMatch(entry['air_date']?.toString() ?? '')?.group(1) ??
        '',
  );

  /// Normalizes English/Roman part numerals (`I..X`, `ONE..SIX`) to Arabic digits
  /// while keeping word boundaries so subtitle comparisons handle `Stage I` == `Stage 1`.
  static String normalizeWithNumerals(String value) {
    var text = PersonalFilenameParser.unifyIdentityPunctuation(value)
        .replaceAll(RegExp(r'\{tmdb-\d+\}', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'\((?:19|20)\d{2}\)'), ' ');
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
        RegExp(
          '(?<![a-z0-9])${entry.key}(?![a-z0-9])',
          caseSensitive: false,
        ),
        entry.value,
      );
    }
    const singleMap = {'I': '1', 'V': '5', 'X': '10'};
    // Context-guarded Roman numerals I/V/X after title keywords or trailing boundaries.
    text = text.replaceAllMapped(
      RegExp(
        r'\b(stage|part|pt|vol|volume|act|phase|chapter|season|series|ova|oad|sp|special|disc|disk|episode|ep|alternative|alter|story|arc|movie|film)\s+(I|V|X)\b',
        caseSensitive: false,
      ),
      (m) => '${m.group(1)} ${singleMap[m.group(2)!.toUpperCase()]!}',
    );
    text = text.replaceAllMapped(
      RegExp(r'(?:^|\s)(I|V|X)(?=\s*(?:$|[:\-–—~()\[\]/／]))'),
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
    text = text.replaceAllMapped(
      RegExp(
        r'\b(stage|part|pt|vol|volume|act|phase|chapter|season|series|ova|oad|sp|special|disc|disk|episode|ep|alternative|alter)\s+(?:one|first)\b',
      ),
      (m) => '${m.group(1)} 1',
    );
    text = text.replaceAll(RegExp(r'\b(?:one|first)\s*$'), '1');
    return text
        .replaceAll(RegExp(r'[\-_—–:：.()（）\[\]【】{}!?！？・·,，、/／|]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static List<int> _partNumbersFromNormalized(String normalized) {
    final numbers = <int>[];
    for (final match in RegExp(r'(?<!\d)(\d{1,2})(?!\d)').allMatches(normalized)) {
      final n = int.tryParse(match.group(1)!);
      if (n != null && n >= 1 && n <= 30) numbers.add(n);
    }
    return numbers;
  }

  /// Compares two subtitles using numeral equivalence, part-number conflict guards,
  /// and stopword-trimmed token containment (`Part I` -> `Part`,
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

    // First installment often omits "1" / "I" (e.g. "Side Story I" vs "Side Story").
    if ((numsA.isNotEmpty && numsB.isEmpty && numsA.last == 1) ||
        (numsB.isNotEmpty && numsA.isEmpty && numsB.last == 1)) {
      final strippedA =
          numsA.isNotEmpty ? normA.replaceFirst(RegExp(r'\b1\b\s*$'), '').trim() : normA;
      final strippedB =
          numsB.isNotEmpty ? normB.replaceFirst(RegExp(r'\b1\b\s*$'), '').trim() : normB;
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
        'the', 'a', 'an', 'of', 'to', 'in', 'on', 'at', 'for', 'with', 'way',
        'no', 'and', 'or', 'ova', 'oad', 'sp', 'special', 'extra',
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
        final longer = identical(shorter, tokensA) ? tokensB.toSet() : tokensA.toSet();
        final matched = shorter.where(longer.contains).length;
        final hasSubstantive = shorter.any(
          (t) =>
              t.length >= 2 ||
              RegExp(r'[\u3040-\u9fff]').hasMatch(t) ||
              (shorter.length >= 2 && matched == shorter.length),
        );
        if (hasSubstantive && matched == shorter.length) {
          final containScore =
              0.76 + 0.19 * (shorter.length / longer.length);
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
    'ova', 'oad', 'sp', 'special', 'specials', 'extra', 'extras', 'bonus',
    'disc', 'disk', 'vol', 'volume', 'part', 'pt', 'episode', 'ep',
    'chapter', 'movie', 'film', 'animation', 'anime', 'tv', 'bd', 'dvd',
    'bdrip', 'dvdrip', 'bluray', 'web', 'webrip', 'remux', 'digest', 'recap',
    'summary', 'commentary', 'drama', 'audio', 'preview', 'teaser', 'trailer',
    'opening', 'ending', 'menu', 'ncop', 'nced', 'pv', 'cm', 'the', 'a', 'an',
    'of', 'in', 'on', 'at', 'to', 'for', 'with', 'no', 'and', 'or', 'ver',
    'version', 'edition', 'complete', 'collection', 'hevc', 'avc', 'x264',
    'x265', 'flac', 'aac', 'opus', 'ma10p', 'hi10p', '10bit', '8bit', '1080p',
    '720p', '2160p', 'chs', 'cht', 'jpsc', 'jptc', 'sub', 'subs',
  };

  static const _endingStopTokens = <String>{
    'alter', 'alternate', 'alternative', 'another', 'true', 'different',
    'epilogue', 'end', 'ending', 'ed',
  };

  static Set<String> _tokensFromText(String text) => normalizeWithNumerals(text)
      .split(' ')
      .where((t) => t.isNotEmpty)
      .toSet();

  static List<String> _exclusiveSubtitleTokens(
    Map<String, Object?> asset,
    Set<String> workBaseTokens,
  ) {
    final original = asset['name']?.toString() ?? '';
    final content = _groupedSpecialContent(original);
    final prefixStrip = <String>{...workBaseTokens};
    if (content != null) {
      final spGroup = RegExp(
        r'(?:\[SP\d{1,3}\]|(?:^|[\s._\-–—])SP\d{1,3}\s*(?=\[))',
        caseSensitive: false,
      ).firstMatch(original);
      if (spGroup != null) {
        final prefix = cleanedExtraFilename({
          'name': '${original.substring(0, spGroup.start)}.mkv',
        });
        prefixStrip.addAll(_tokensFromText(prefix));
      }
    }
    final text = content ?? cleanedExtraFilename(asset);
    if (prefixStrip.isEmpty && content == null) {
      // Without a known work title or grouped subtitle block, do not treat
      // the main show stem before [OVA]/[SP] as an exclusive subtitle.
      return const [];
    }
    final normalized = normalizeWithNumerals(text);
    final result = <String>[];
    for (final raw in normalized.split(' ')) {
      final token = raw.trim();
      if (token.isEmpty) continue;
      if (RegExp(r'^\d+$').hasMatch(token)) continue;
      if (RegExp(r'^(?:ova|oad|sp)\d+$').hasMatch(token)) continue;
      if (_genericSubtitleTokens.contains(token)) continue;
      if (prefixStrip.contains(token)) continue;
      result.add(token);
    }
    return result;
  }

  static bool _hasExplicitOadOrOvaVolumeTag(Map<String, Object?> asset) {
    final name = (_groupedSpecialContent(asset['name']?.toString() ?? '') ??
            asset['name']?.toString() ??
            '')
        .toLowerCase();
    return RegExp(
      r'(?:^|[^a-z])(?:oad|ova)(?:[^a-z]|$)',
      caseSensitive: false,
    ).hasMatch(name);
  }

  static String _specialAssetSubfamily(Map<String, Object?> asset) {
    final baseType = specialType(asset);
    final family = _specialFamily(baseType);
    if (family != 'OVA' && family != 'SP') return family;
    final original = asset['name']?.toString() ?? '';
    final effective = _groupedSpecialContent(original) ?? original;
    final hasOvaInText = RegExp(
      r'(?:^|[^a-z])(?:OVA|OAD)(?=[^a-z]|$)',
      caseSensitive: false,
    ).hasMatch(effective);
    final hasSpInText = RegExp(
      r'(?:^|[^a-z])(?:SP|Specials?)(?=[^a-z0-9]|$)|\bSP\d+\b|映像特典|特典',
      caseSensitive: false,
    ).hasMatch(effective);
    if (hasOvaInText && hasSpInText) return 'OVA_SP';
    if (family == 'SP') {
      final path = '${asset['relative_path'] ?? ''}'.replaceAll('\\', '/');
      final segments = path.split('/');
      final parentDirs =
          segments.length > 1 ? segments.sublist(0, segments.length - 1) : const <String>[];
      if (parentDirs.any(
        (s) => RegExp(r'(?:^|[^a-z])(?:OVA|OAD)(?=[^a-z]|$)', caseSensitive: false)
            .hasMatch(s),
      )) {
        return 'OVA_SP';
      }
    }
    return family;
  }

  static String _specialEntrySubfamily(Map<String, dynamic> entry) {
    final name = entry['name']?.toString() ?? '';
    final hasOva = RegExp(
      r'(?:^|[^a-z])(?:OVA|OAD)(?=[^a-z]|$)',
      caseSensitive: false,
    ).hasMatch(name);
    final hasSp = RegExp(
      r'(?:^|[^a-z])(?:SP|Specials?)(?=[^a-z0-9]|$)|\bSP\d+\b|映像特典|特典',
      caseSensitive: false,
    ).hasMatch(name);
    if (hasOva && hasSp) return 'OVA_SP';
    if (hasOva) return 'OVA';
    if (hasSp) return 'SP';
    final combined = '$name ${entry['overview'] ?? ''}';
    if (_alternateEndingPattern.hasMatch(combined)) return 'SP';
    return '';
  }

  static int? _extractEpisodeClueFromSpecialAsset(Map<String, Object?> asset) {
    final original = asset['name']?.toString() ?? '';
    var text = _groupedSpecialContent(original) ?? cleanedExtraFilename(asset);
    text = text
        .replaceAll(RegExp(r'\b(?:19|20)\d{2}\b'), ' ')
        .replaceAll(RegExp(r'\b(?:OVA|OAD|SP)[ ._-]*\d+\b', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'\bv\d+\b', caseSensitive: false), ' ');
    final match = RegExp(r'(?<!\d)(\d{1,3})(?!\d)').firstMatch(text);
    final value = int.tryParse(match?.group(1) ?? '');
    if (value == null || value <= 0 || value >= 1900) return null;
    return value;
  }

  static int? _parseChineseOrArabicSeasonNumber(String token) {
    final numeric = int.tryParse(token);
    if (numeric != null) return numeric;
    const digits = {
      '一': 1, '二': 2, '两': 2, '三': 3, '四': 4, '五': 5,
      '六': 6, '七': 7, '八': 8, '九': 9, 'Ⅰ': 1, 'Ⅱ': 2, 'Ⅲ': 3, 'Ⅳ': 4,
    };
    return digits[token];
  }

  static Set<int> _explicitSeasonMarkersInMetadata(String text) {
    final found = <int>{};
    final patterns = <RegExp>[
      RegExp(r'\bSeason[ ._-]*(\d{1,2})\b', caseSensitive: false),
      RegExp(r'(?<![a-z0-9])S(\d{1,2})(?![a-z0-9])', caseSensitive: false),
      RegExp(r'\b(\d{1,2})(?:st|nd|rd|th)[ ._-]+Season\b', caseSensitive: false),
      RegExp(r'第[ ._-]*([0-9一二三四五六七八九]+)[ ._-]*[期季]'),
      RegExp(r'(?<!\d)(\d{1,2})期(?![\d])'),
    ];
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
    if (rawSeasonName.isNotEmpty &&
        !RegExp(
          r'^(?:Season\s*\d+|第\s*[0-9一二三四五六七八九十]+\s*[季期]|Specials?|特別編)$',
          caseSensitive: false,
        ).hasMatch(rawSeasonName)) {
      final tokens = _tokensFromText(rawSeasonName)
          .where(
            (t) =>
                !_genericSubtitleTokens.contains(t) &&
                (t.length >= 3 || RegExp(r'[\u3040-\u9fff]').hasMatch(t)),
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
        .replaceAll(RegExp(r'\bSeason[ ._-]*\d{1,2}\b', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'\b\d{1,2}(?:st|nd|rd|th)[ ._-]+Season\b', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'第[ ._-]*[0-9一二三四五六七八九]+[ ._-]*[期季]'), ' ')
        .replaceAll(RegExp(r'\b\d{1,2}期\b'), ' ');
    return explicitSpecialNumber({'name': stripped});
  }

  /// Uses the explicit OVA/SP number first, then subtitle/semantic/season
  /// alignment and stable same-type ordering.
  /// The computed mapping is stored with the TMDB cache and never renames a
  /// cloud file.
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
      RegExp(
            r'(?<!\d)((?:19|20)\d{2})(?!\d)',
          ).firstMatch(yearHint ?? '')?.group(1) ??
          '',
    );
    final effectiveSeason =
        seasonNumber ?? _seasonFromText('${workTitle ?? ''} ${yearHint ?? ''}');

    final workBaseTokens = <String>{
      if (workTitle != null && workTitle.trim().isNotEmpty)
        ..._tokensFromText(workTitle),
      if (yearHint != null && yearHint.trim().isNotEmpty)
        ..._tokensFromText(
          yearHint
              .replaceAll(RegExp(r'\{tmdb-\d+\}', caseSensitive: false), ' ')
              .replaceAll(RegExp(r'\((?:19|20)\d{2}\)'), ' ')
              .replaceAll(RegExp(r'\bSeason[ ._-]*\d+\b', caseSensitive: false), ' ')
              .replaceAll(RegExp(r'第[ ._-]*[0-9一二三四五六七八九十]+[ ._-]*[季期]'), ' '),
        ),
    };

    bool isRecap(Map<String, dynamic> entry) => RegExp(
      r'総集編|总集篇|recap|summary|digest',
      caseSensitive: false,
    ).hasMatch('${entry['name'] ?? ''}');

    bool inYearWindow(Map<String, dynamic> entry) {
      if (yearInt == null) return true;
      final airYear = _specialAirYear(entry);
      return airYear == null || (airYear - yearInt).abs() <= 1;
    }

    // Pass 1: Exclusive subtitle high-confidence binding (allows cross-year spin-off
    // matches like "[SP07] [Show Evol OVA]" while blocking generic "Show [OVA].mkv").
    final allCandidates = assets.where(isSpecialMappingCandidate).toList()
      ..sort((a, b) => assetKey(a).compareTo(assetKey(b)));
    for (final asset in allCandidates) {
      final exclusive = _exclusiveSubtitleTokens(asset, workBaseTokens);
      final distinctive = exclusive
          .where((t) => !_endingStopTokens.contains(t))
          .toList();
      if (distinctive.isEmpty) continue;
      final hasSubstantiveToken = distinctive.any(
        (t) => t.length >= 3 || RegExp(r'[\u3040-\u9fff]').hasMatch(t),
      );
      if (!hasSubstantiveToken) continue;

      final original = asset['name']?.toString() ?? '';
      final assetSub = _groupedSpecialContent(original) ?? cleanedExtraFilename(asset);
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
              (t.length >= 3 || RegExp(r'[\u3040-\u9fff]').hasMatch(t)),
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

      final chosen = bestInYear ?? (bestCrossYearScore >= 0.7 ? bestCrossYear : null);
      if (chosen != null) {
        final key = assetKey(asset);
        claimed.add(_specialOrder(chosen));
        matchedPaths.add(key);
        result[key] = chosen;
      }
    }

    // Pass 2: Group remaining assets by subfamily (OVA -> SP -> OVA_SP).
    final assetsByType = <String, List<Map<String, Object?>>>{};
    for (final asset in allCandidates) {
      if (matchedPaths.contains(assetKey(asset))) continue;
      assetsByType
          .putIfAbsent(_specialAssetSubfamily(asset), () => [])
          .add(asset);
    }

    int compareWithSeasonAffinity(Map<String, dynamic> a, Map<String, dynamic> b) {
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
          (effectiveSeason == null && (seasonName == null || seasonName.trim().isEmpty))) {
        return pool;
      }
      final preferred = pool
          .where((e) => _entrySeasonAffinity(e, effectiveSeason, seasonName) > 0)
          .toList();
      if (preferred.length >= minCount) return preferred;
      final compatible = pool
          .where((e) => _entrySeasonAffinity(e, effectiveSeason, seasonName) >= 0)
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

      // In multi-season sub-pools (e.g. Season 2's S0E07..S0E12 named "SP1..SP6"),
      // check whether entries carry distinct relative title numbers matching the asset.
      final useRelativeTitleNumbers =
          !allowDirectEpisodeMatch &&
          group.any((a) => explicitSpecialNumber(a) != null) &&
          sortedPool.any((e) {
            final rel = _relativeSpecialNumberFromTitle(e['name']?.toString() ?? '');
            return rel != null && rel != _specialOrder(e);
          });

      for (final asset in group) {
        final key = assetKey(asset);
        if (matchedPaths.contains(key)) continue;
        final explicit = explicitSpecialNumber(asset);
        var selected = -1;
        if (allowDirectEpisodeMatch && explicit != null) {
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
            if (_relativeSpecialNumberFromTitle(entry['name']?.toString() ?? '') ==
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

      double semanticScore(Map<String, Object?> asset, Map<String, dynamic> entry) {
        final original = asset['name']?.toString() ?? '';
        final assetText = _groupedSpecialContent(original) ?? cleanedExtraFilename(asset);
        final epClue = _extractEpisodeClueFromSpecialAsset(asset);
        final isAltEnd = _alternateEndingPattern.hasMatch(assetText);

        final entryName = entry['name']?.toString() ?? '';
        final entryOverview = entry['overview']?.toString() ?? '';
        final entryCombined = '$entryName $entryOverview';
        var score = _entrySeasonAffinity(entry, effectiveSeason, seasonName).toDouble();

        if (epClue != null) {
          final strippedCombined = entryCombined.replaceAll(
            RegExp(r'\b(?:19|20)\d{2}\b'),
            ' ',
          );
          final epRegex = RegExp(
            '(?:\\b(?:episode|ep|special|#)\\s*0?$epClue\\b|第\\s*0?$epClue\\s*[话話集]|(?<!\\d)0?$epClue(?!\\d))',
            caseSensitive: false,
          );
          if (epRegex.hasMatch(strippedCombined)) {
            score += 80;
          } else {
            final otherEp = RegExp(
              r'(?:\b(?:episode|ep|special)\s*0?(\d{1,3})\b|第\s*0?(\d{1,3})\s*[话話集])',
              caseSensitive: false,
            ).firstMatch(strippedCombined);
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
              RegExp(
                r'(?:another|alter|alternative|true|別|アナザー).{0,16}(?:end|ending|結末|结局)|ending|結末|结局',
                caseSensitive: false,
              ).hasMatch(entryCombined)) {
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

      // Check whether assets have semantic/episode clues needing best-score pairing.
      final hasClues = group.any((a) {
        final original = a['name']?.toString() ?? '';
        final text = _groupedSpecialContent(original) ?? cleanedExtraFilename(a);
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
        final epCmp = _specialOrder(remainingPool[a.entryIdx])
            .compareTo(_specialOrder(remainingPool[b.entryIdx]));
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

      // Preempt numbered slots ONLY for OVA bundles with an explicit standalone
      // OAD/OVA volume label (e.g. Show OAD + OVA 01..06).
      // For SP bundles (e.g. SP1..2 + 03 alter-end, 04 alter-end), numbered SPs
      // must lock slots 1..2 first so alternate endings align semantically after them.
      final preemptStandaloneOad =
          family == 'OVA' &&
          unnumberedAssets.isNotEmpty &&
          numberedAssets.length >= 2 &&
          unnumberedAssets.any(_hasExplicitOadOrOvaVolumeTag);

      if (preemptStandaloneOad) {
        final standaloneOads =
            unnumberedAssets.where(_hasExplicitOadOrOvaVolumeTag).toList();
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
            yearInt == null && numberedPool.length == allTypeSpecials.length;
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
            allowDirect = exactYear.length == allTypeSpecials.length;
          } else if (nearYears.length >= numberedAssets.length) {
            numberedPool = narrowBySeasonAffinity(
              nearYears,
              numberedAssets.length,
            );
            allowDirect = nearYears.length == allTypeSpecials.length;
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

      // Remaining unnumbered assets run AFTER numbered assets lock their slots.
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
        // For SPs with alternate-ending/episode clues, also check unclaimed Season 0
        // entries inside yearInt ± 1 whose overview mentions endings/episodes.
        if (family == 'SP' && unnumberedPool.length < remainingUnnumbered.length) {
          final extraCandidates = specials.where((e) {
            if (claimed.contains(_specialOrder(e)) || isRecap(e)) return false;
            final sub = _specialEntrySubfamily(e);
            if (sub == 'OVA') return false;
            if (!inYearWindow(e)) return false;
            return !unnumberedPool.any((u) => _specialOrder(u) == _specialOrder(e));
          }).toList();
          unnumberedPool = narrowBySeasonAffinity(
            [...unnumberedPool, ...extraCandidates],
            remainingUnnumbered.length,
          );
        }
        assignUnnumberedWithSemantics(remainingUnnumbered, unnumberedPool);
      }

      // OVA_SP fallback: if dedicated OVA_SP Season 0 entries are absent/exhausted,
      // fall back to unclaimed SP entries (matching year/season/OVA overview cues).
      if (family == 'OVA_SP') {
        final leftOver = typeAssets
            .where((a) => !matchedPaths.contains(assetKey(a)))
            .toList();
        if (leftOver.isNotEmpty) {
          final fallbackPool = specials.where((e) {
            if (claimed.contains(_specialOrder(e)) || isRecap(e)) return false;
            final sub = _specialEntrySubfamily(e);
            if (sub != 'SP' && sub.isNotEmpty) return false;
            return inYearWindow(e);
          }).toList()
            ..sort((a, b) {
              final ovaHintA = RegExp(
                r'OVA|OAD|映像特典|特典',
                caseSensitive: false,
              ).hasMatch('${a['name'] ?? ''} ${a['overview'] ?? ''}')
                  ? 1
                  : 0;
              final ovaHintB = RegExp(
                r'OVA|OAD|映像特典|特典',
                caseSensitive: false,
              ).hasMatch('${b['name'] ?? ''} ${b['overview'] ?? ''}')
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

  static Map? specialEpisode(
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
    for (final entry in entries.whereType<Map>()) {
      if (int.tryParse('${entry['episode_number']}') == explicit) {
        return entry;
      }
    }
    return null;
  }

  static String? specialTypeFromTitle(String value) {
    final match = RegExp(
      r'(^|[^a-z])(OVA|OAD|SP)(?=[^a-z]|$)',
      caseSensitive: false,
    ).firstMatch(value);
    return match?.group(2)?.toUpperCase();
  }

  /// Filename scanners commonly call an OVA what TMDB names an OAD (and vice
  /// versa). They share the same specials pool, while SP stays independent.
  static String _specialFamily(String? type) =>
      type == 'OVA' || type == 'OAD' ? 'OVA' : type ?? '';

  static int _specialOrder(Map<String, dynamic> entry) =>
      int.tryParse('${entry['episode_number']}') ?? 999999;

  static int _compareSpecialEpisode(
    Map<String, dynamic> a,
    Map<String, dynamic> b,
  ) => _specialOrder(a).compareTo(_specialOrder(b));
}
