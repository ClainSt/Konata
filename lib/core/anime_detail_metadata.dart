import 'dart:convert';

/// Normalizes provider-specific metadata for the personal anime detail page.
abstract final class AnimeDetailMetadata {
  static const int maxTags = 8;

  static Map<String, dynamic> fromWork(Map<String, Object?> work) {
    try {
      final decoded = jsonDecode(work['metadata_json']?.toString() ?? '{}');
      return decoded is Map<String, dynamic> ? decoded : const {};
    } catch (_) {
      return const {};
    }
  }

  static String? year(Map<String, Object?> work) {
    final metadata = fromWork(work);
    final bangumi = metadata['bangumi'] is Map
        ? metadata['bangumi'] as Map
        : const {};
    final candidates = <Object?>[
      metadata['first_air_date'],
      metadata['release_date'],
      metadata['date'],
      bangumi['air_date'],
      bangumi['airDate'],
      work['work_key'],
    ];
    for (final candidate in candidates) {
      final match = RegExp(
        r'(?<!\d)((?:19|20)\d{2})(?!\d)',
      ).firstMatch('$candidate');
      if (match != null) return match.group(1);
    }
    return null;
  }

  /// Uses one order and one limit for every provider. Dandanplay stores tags
  /// under `bangumi.tags`, while Bangumi/TMDB stores them at the top level.
  static List<String> tags(Map<String, Object?> work) {
    final metadata = fromWork(work);
    final bangumi = metadata['bangumi'] is Map
        ? metadata['bangumi'] as Map
        : const {};
    final values = <Object?>[
      ..._list(metadata['tags']),
      ..._list(bangumi['tags']),
      ..._list(metadata['genres']),
    ];
    final rawTags = values
        .map(
          (value) =>
              value is Map ? value['name']?.toString() : value?.toString(),
        )
        .map(_normalizeTag)
        .whereType<String>()
        .where((value) => !_isDateTag(value))
        .toList(growable: false);
    final result = <String>[];
    final seen = <String>{};

    final format =
        _firstOrNull(rawTags.map(_canonicalFormat).whereType<String>()) ??
        _formatType(
          (bangumi['typeDescription'] ?? metadata['typeDescription'])
              ?.toString(),
        );
    final company =
        _firstOrNull(rawTags.where(_looksLikeCompany)) ??
        _structuredCompany(metadata, bangumi);
    final adaptation = _firstOrNull(
      rawTags.where((tag) => _adaptationKind(tag) != null),
    );

    _addTag(result, seen, format);
    _addTag(result, seen, company);
    _addTag(result, seen, adaptation);

    for (final value in rawTags) {
      if (result.length >= maxTags) break;
      if (_canonicalFormat(value) != null ||
          _looksLikeCompany(value) ||
          _adaptationKind(value) != null) {
        continue;
      }
      _addTag(result, seen, value);
    }
    return result.take(maxTags).toList(growable: false);
  }

  static Iterable<Object?> _list(Object? value) =>
      value is List ? value : const [];

  static T? _firstOrNull<T>(Iterable<T> values) {
    for (final value in values) {
      return value;
    }
    return null;
  }

  static void _addTag(List<String> result, Set<String> seen, String? raw) {
    final value = _normalizeTag(raw);
    if (value == null || value.isEmpty || _isDateTag(value)) return;
    final key = _tagKey(value);
    if (!seen.add(key)) return;
    result.add(value);
  }

  static String? _normalizeTag(String? raw) {
    final value = raw?.trim().replaceAll(RegExp(r'\s+'), ' ');
    return value == null || value.isEmpty ? null : value;
  }

  static String _tagKey(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[\s._\-:/]+'), '');

  static bool _isDateTag(String value) {
    final compact = value.replaceAll(RegExp(r'\s+'), '');
    return RegExp(
      r'^(?:19|20)\d{2}(?:年(?:\d{1,2}月?)?|[-_/.]\d{1,2})?$',
    ).hasMatch(compact);
  }

  static String? _formatType(String? description) {
    final value = description?.trim() ?? '';
    if (value.isEmpty) return null;
    final lower = value.toLowerCase();
    if (lower.contains('剧场版') || lower.contains('movie')) return '剧场版';
    if (lower.contains('ova')) return 'OVA';
    if (lower.contains('oad')) return 'OAD';
    if (lower.contains('tv') || lower.contains('电视')) return 'TV';
    if (lower.contains('web') || lower.contains('网络')) return 'Web';
    return value;
  }

  static String? _canonicalFormat(String value) {
    final key = _tagKey(value);
    if (key == 'tv' || key == 'tv动画' || key == '电视动画') return 'TV';
    if (key == 'web' || key == 'web动画' || key == '网络动画' || key == 'ona') {
      return 'Web';
    }
    if (key == '剧场版' || key == '动画电影' || key == 'movie') {
      return '剧场版';
    }
    if (key == 'ova') return 'OVA';
    if (key == 'oad') return 'OAD';
    return null;
  }

  static String? _adaptationKind(String value) {
    final key = _tagKey(value);
    if (key.contains('原创')) return '原创';
    if (key.contains('漫画改') || key == '漫改') return value;
    if (key.contains('轻小说改') || key.contains('小说改') || key == '轻改') {
      return value;
    }
    if (key.contains('galgame改') ||
        key.contains('游戏改') ||
        key == 'gal改' ||
        key.contains('视觉小说改')) {
      return value;
    }
    return null;
  }

  static bool _looksLikeCompany(String value) {
    final lower = value.toLowerCase();
    final key = _tagKey(value);
    if (const {
      '日本动画',
      '中国动画',
      '美国动画',
      '动画',
      '动画电影',
      '电视动画',
      'animation',
      'anime',
      'studio',
      'works',
      'pictures',
      'staff',
      'film',
    }.contains(key)) {
      return false;
    }
    return key == 'drive' ||
        lower.startsWith('st.') ||
        lower.startsWith('st ') ||
        lower.contains('studio') ||
        lower.contains('pictures') ||
        lower.contains('animation') ||
        lower.contains('staff') ||
        lower.contains('works') ||
        lower.contains('film') ||
        const {
          'mappa',
          'ufotable',
          'bones',
          'madhouse',
          'shaft',
          'trigger',
          'sunrise',
          'wit',
          'productionig',
          'polygonpictures',
        }.contains(key) ||
        lower.contains('动画制作') ||
        lower.contains('动画工房') ||
        lower.contains('京阿尼');
  }

  static String? _structuredCompany(
    Map<String, dynamic> metadata,
    Map bangumi,
  ) {
    final companies = _list(metadata['production_companies']);
    for (final company in companies) {
      final name = company is Map
          ? company['name']?.toString()
          : company?.toString();
      final normalized = _normalizeTag(name);
      if (normalized != null) return normalized;
    }

    for (final source in [metadata['infobox'], bangumi['infobox']]) {
      for (final item in _list(source)) {
        if (item is! Map) continue;
        final key = item['key']?.toString().trim() ?? '';
        if (!key.contains('动画制作') && !key.contains('制作公司')) continue;
        final value = _infoboxValue(item['value']);
        if (value != null) return value;
      }
    }

    for (final source in [metadata['metadata'], bangumi['metadata']]) {
      for (final item in _list(source)) {
        final line = _normalizeTag(item?.toString());
        if (line == null) continue;
        final match = RegExp(r'^(?:动画制作|制作公司)\s*[:：]\s*(.+)$').firstMatch(line);
        if (match != null) return _normalizeTag(match.group(1));
      }
    }
    return null;
  }

  static String? _infoboxValue(Object? value) {
    if (value is String) return _normalizeTag(value);
    if (value is List) {
      final values = value
          .whereType<Map>()
          .map((entry) => _normalizeTag(entry['v']?.toString()))
          .whereType<String>();
      return _firstOrNull(values);
    }
    if (value is Map) return _normalizeTag(value['v']?.toString());
    return null;
  }
}
