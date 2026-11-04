import 'cloud_media_file_classifier.dart';

/// Filename tokens are used only for matching and short extra labels.
class CloudMediaAssetPresentation {
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
    final technical = RegExp(
      r'\b(?:\d{3,4}p|\d{3,4}x\d{3,4}|[248]k|ma10p|hi10p|10bit|8bit|x26[45]|h[ .]?26[45]|hevc|avc|av1|aac|flac|opus|dts|ac3|eac3|bdrip|bluray|web-?dl|webrip|hdr10|chs|cht|jpsc|jptc|jpchs|jpcht)\b',
      caseSensitive: false,
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
        return technical.hasMatch(value.replaceAll('_', ' ')) ||
                release ||
                checksum
            ? ' '
            : ' $value ';
      },
    );
    name = name
        .replaceAll(RegExp(r'[_.]+'), ' ')
        .replaceAll(technical, ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .replaceAll(RegExp(r'^[\s-]+|[\s-]+$'), '');
    return name.isEmpty ? base : name;
  }

  static const _matchableSpecialTypes = {'OVA', 'OAD', 'SP'};
  static const _matchableSpecialFamilies = {'OVA', 'SP'};
  static final _noCreditToken = RegExp(
    r'(?:creditless|textless|non[ ._-]?telop|non[ ._-]?credit|'
    r'ノンクレジット|ノンクレ|ノンテロップ)[ ._:-]*'
    r'(opening|ending|OP|ED)[ ._-]*(\d{1,3})?',
    caseSensitive: false,
  );
  static final _extraToken = RegExp(
    r'(^|[^a-z])(NCOPED|NCOP|NCED|MENU|OVA|OAD|PV|CM|SP|MV|LOGO|RL|'
    r'INFO|INTERVIEW|MAKING|DIGEST|TRAILER|TEASER|PROMOTION|EVENT|'
    r'EYECATCH|ARTWORK|SPOT|OAB|EX)(?:[ ._-]?(\d+(?:[ ._-]?[a-z])?))?'
    r'(?=[^a-z0-9]|$)',
    caseSensitive: false,
  );

  static String? extraTitle(Map<String, Object?> asset) {
    final name = asset['name']?.toString() ?? '';
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
      return null;
    }
    final number = (match.group(3) ?? '').replaceAll(RegExp(r'[ ._-]'), '');
    return '${match.group(2)}$number'.toUpperCase();
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

  static String extraType(Map<String, Object?> asset) {
    final name = asset['name']?.toString() ?? '';
    if (CloudMediaFileClassifier.isPreview(name)) {
      return '预告';
    }
    final noCredit = _noCreditLabel(name);
    if (noCredit != null) return noCredit;
    final match = _extraToken.firstMatch(name);
    if (match != null) return match.group(2)!.toUpperCase();
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
  /// TMDB seasons. Explicit SxxExx/folder seasons keep their local numbers.
  static ({int season, int number})? episodeCoordinates(
    Map<String, Object?> asset,
    Map<String, dynamic> seasons,
  ) {
    final number = int.tryParse('${asset['episode_number'] ?? ''}');
    if (number == null || number <= 0) return null;
    final explicit = explicitSeasonNumber(asset);
    if (explicit != null) return (season: explicit, number: number);
    final counts = seasons['season_episode_counts'];
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
    final name = asset['name']?.toString().toLowerCase() ?? '';
    return !RegExp(
      r'menu|trailer|preview|teaser|opening|ending|ncop|nced',
    ).hasMatch(name);
  }

  static int? explicitSpecialNumber(Map<String, Object?> asset) {
    final name = asset['name']?.toString() ?? '';
    final patterns = <RegExp>[
      RegExp(r'\b(?:OVA|OAD|SP)[\s._-]*(\d{1,3})\b', caseSensitive: false),
      RegExp(
        r'[\[(](?:OVA|OAD|SP)[\s._-]*(\d{1,3})[\])]',
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
    return null;
  }

  /// Uses the explicit OVA/SP number first, then a stable same-type ordering.
  /// The computed mapping is stored with the TMDB cache and never renames a
  /// cloud file.
  static Map<String, Map<String, dynamic>> mapSpecialEpisodes({
    required List<Map<String, Object?>> assets,
    required List<Map<String, dynamic>> specials,
    String? yearHint,
  }) {
    final result = <String, Map<String, dynamic>>{};
    final claimed = <int>{};
    final assetsByType = <String, List<Map<String, Object?>>>{};
    for (final asset in assets.where(isSpecialMappingCandidate)) {
      assetsByType
          .putIfAbsent(_specialFamily(specialType(asset)!), () => [])
          .add(asset);
    }

    for (final family in _matchableSpecialFamilies) {
      final typeAssets = assetsByType[family];
      if (typeAssets == null || typeAssets.isEmpty) continue;
      var typeSpecials = specials
          .where(
            (entry) =>
                _specialFamily(
                  _specialTypeFromTitle(entry['name']?.toString() ?? ''),
                ) ==
                family,
          )
          .toList();
      final year = RegExp(
        r'(?<!\d)((?:19|20)\d{2})(?!\d)',
      ).firstMatch(yearHint ?? '')?.group(1);
      if (year != null) {
        final yearSpecials = typeSpecials
            .where(
              (entry) => entry['air_date']?.toString().startsWith(year) == true,
            )
            .toList();
        if (yearSpecials.isNotEmpty) typeSpecials = yearSpecials;
        final hasExplicitNumbers = typeAssets.any(
          (asset) => explicitSpecialNumber(asset) != null,
        );
        if (yearSpecials.isEmpty) {
          if (!hasExplicitNumbers) continue;
          final explicitTypes = typeAssets
              .where((asset) => explicitSpecialNumber(asset) != null)
              .map(specialType)
              .whereType<String>()
              .toSet();
          final sameSubtype = typeSpecials
              .where(
                (entry) => explicitTypes.contains(
                  _specialTypeFromTitle(entry['name']?.toString() ?? ''),
                ),
              )
              .toList();
          if (sameSubtype.isNotEmpty) typeSpecials = sameSubtype;
        }
      }
      if (typeSpecials.isEmpty) continue;
      typeSpecials.sort(_compareSpecialEpisode);
      typeAssets.sort((a, b) {
        final x = explicitSpecialNumber(a) ?? 999999;
        final y = explicitSpecialNumber(b) ?? 999999;
        if (x != y) return x.compareTo(y);
        return '${a['relative_path']}'.compareTo('${b['relative_path']}');
      });

      var nextIndex = 0;
      for (final asset in typeAssets) {
        final explicit = explicitSpecialNumber(asset);
        var selected = -1;
        if (explicit != null) {
          selected = typeSpecials.indexWhere(
            (entry) =>
                int.tryParse('${entry['episode_number']}') == explicit &&
                !claimed.contains(_specialOrder(entry)),
          );
        }
        if (selected < 0) {
          while (nextIndex < typeSpecials.length &&
              claimed.contains(_specialOrder(typeSpecials[nextIndex]))) {
            nextIndex++;
          }
          if (nextIndex < typeSpecials.length) selected = nextIndex;
        }
        if (selected < 0) continue;
        final entry = typeSpecials[selected];
        claimed.add(_specialOrder(entry));
        result[asset['relative_path']?.toString() ??
                asset['name']?.toString() ??
                ''] =
            entry;
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

  static String? _specialTypeFromTitle(String value) {
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
