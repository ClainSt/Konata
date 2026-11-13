import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

/// Version 1 of open-ani/bangumi-tmdb. These are source relations, never proof
/// that a local file belongs to an episode. See docs/ANIME_MAPPING_SOURCE.md.
class AnimeMapping {
  AnimeMapping(this.subject, this.targets, this.episodes, this.excluded);
  final int subject;
  final List<Map<String, dynamic>> targets;
  final Map<int, List<Map<String, dynamic>>> episodes;
  final Set<int> excluded;
  static int integer(dynamic value, {int minimum = 1}) {
    if (value is! int || value < minimum || value > 2147483647) {
      throw const FormatException('Invalid mapping integer');
    }
    return value;
  }

  static List<Map<String, dynamic>> targetList(
    dynamic raw, {
    bool episode = false,
  }) {
    if (raw is! List || raw.length > 64) {
      throw const FormatException('Invalid targets');
    }
    final result = <Map<String, dynamic>>[];
    for (final item in raw) {
      if (item is! Map || !['tv', 'movie'].contains(item['type'])) {
        throw const FormatException('Invalid target type');
      }
      final row = <String, dynamic>{
        'type': item['type'],
        'id': integer(item['id']),
      };
      if (item['type'] == 'movie') {
        if (item.keys.any((k) => !['type', 'id'].contains(k))) {
          throw const FormatException('Movie target scope');
        }
      } else {
        for (final key in ['season', 'episode', 'episodeEnd']) {
          if (item[key] != null) {
            row[key] = integer(item[key], minimum: key == 'season' ? 0 : 1);
          }
        }
        if (item.keys.any(
              (k) => ![
                'type',
                'id',
                'season',
                'episode',
                'episodeEnd',
              ].contains(k),
            ) ||
            (row['episode'] != null && row['season'] == null) ||
            (row['episodeEnd'] != null &&
                (row['episode'] == null ||
                    row['episodeEnd'] < row['episode'])) ||
            (episode &&
                (row['season'] == null ||
                    row['episode'] == null ||
                    row['episodeEnd'] != null))) {
          throw const FormatException('Invalid TV scope');
        }
      }
      result.add(row);
    }
    result.sort((a, b) => jsonEncode(a).compareTo(jsonEncode(b)));
    if (result.map(jsonEncode).toSet().length != result.length) {
      throw const FormatException('Duplicate target');
    }
    return result;
  }

  static AnimeMapping detail(Map<String, dynamic> data) {
    if (data['schemaVersion'] != 1 ||
        data['episodes'] is! List ||
        data['rules'] is! List ||
        data['overrides'] is! List) {
      throw const FormatException('Unsupported mapping schema');
    }
    final subject = integer(data['bangumiId']);
    final targets = targetList(data['targets']);
    final rawEpisodes = data['episodes'] as List;
    if (rawEpisodes.length > 10000 ||
        (data['rules'] as List).length > 10000 ||
        (data['overrides'] as List).length > 10000) {
      throw const FormatException('Mapping entry limit');
    }
    final known = <int, Map>{};
    for (final raw in rawEpisodes) {
      if (raw is! Map ||
          raw['sort'] is! num ||
          !(raw['sort'] as num).isFinite ||
          raw['sort'] < 0 ||
          raw['sort'] > 1000000) {
        throw const FormatException('Invalid episode');
      }
      final id = integer(raw['id']);
      integer(raw['type'], minimum: 0);
      if (known.containsKey(id)) {
        throw const FormatException('Duplicate episode');
      }
      known[id] = raw;
    }
    final overrides = <int, List<Map<String, dynamic>>>{};
    for (final raw in data['overrides']) {
      if (raw is! Map) throw const FormatException('Invalid override');
      final id = integer(raw['bangumiEpisodeId']);
      if (!known.containsKey(id) || overrides.containsKey(id)) {
        throw const FormatException('Invalid override episode');
      }
      overrides[id] = targetList(raw['targets'], episode: true);
    }
    final rules = <Map>[];
    for (final rule in data['rules']) {
      if (rule is! Map ||
          rule.keys.any(
            (k) => ![
              'bangumiType',
              'start',
              'end',
              'episodeStart',
              'season',
              'tmdbId',
            ].contains(k),
          )) {
        throw const FormatException('Unsupported rule');
      }
      for (final k in [
        'bangumiType',
        'start',
        'end',
        'episodeStart',
        'season',
        'tmdbId',
      ]) {
        integer(
          rule[k],
          minimum: ['bangumiType', 'season'].contains(k) ? 0 : 1,
        );
      }
      if (rule['end'] < rule['start']) {
        throw const FormatException('Invalid rule range');
      }
      rules.add(rule);
    }
    final rows = <int, List<Map<String, dynamic>>>{};
    final excluded = <int>{};
    for (final entry in known.entries) {
      if (overrides.containsKey(entry.key)) {
        final values = overrides[entry.key]!;
        if (values.isEmpty) {
          excluded.add(entry.key);
        } else {
          rows[entry.key] = values;
        }
        continue;
      }
      final sort = entry.value['sort'] as num;
      if (sort != sort.roundToDouble()) continue;
      final matches = rules
          .where(
            (r) =>
                r['bangumiType'] == entry.value['type'] &&
                sort >= r['start'] &&
                sort <= r['end'],
          )
          .toList();
      if (matches.length > 1) throw const FormatException('Overlapping rules');
      if (matches.isNotEmpty) {
        final rule = matches.single;
        rows[entry.key] = targetList([
          {
            'type': 'tv',
            'id': rule['tmdbId'],
            'season': rule['season'],
            'episode': rule['episodeStart'] + sort.toInt() - rule['start'],
          },
        ], episode: true);
      }
    }
    validateEpisodeTargets(rows);
    return AnimeMapping(subject, targets, rows, excluded);
  }

  static void validateEpisodeTargets(
    Map<int, List<Map<String, dynamic>>> rows,
  ) {
    final tv = <String>{};
    for (final targets in rows.values) {
      for (final t in targets) {
        if (t['type'] == 'tv' && !tv.add(jsonEncode(t))) {
          throw const FormatException('Duplicate TV destination');
        }
      }
    }
  }

  String get digest => sha256
      .convert(
        utf8.encode(
          jsonEncode({
            'targets': targets,
            'episodes': {
              for (final id in (episodes.keys.toList()..sort()))
                '$id': episodes[id],
            },
          }),
        ),
      )
      .toString();
}

/// Strict streaming reader for the published v1 envelope. At most one row and
/// a small UTF-8 chunk are retained; malformed/truncated tails never activate.
Stream<Map<String, dynamic>> mappingRows(File file, String field) async* {
  var prefix = '', tail = '', row = StringBuffer();
  var started = false,
      ended = false,
      inString = false,
      escape = false,
      schemaFirst = true;
  var depth = 0, rowLength = 0;
  var expectValue = true, allowEnd = true;
  final header = RegExp(
    '^\\s*\\{\\s*"schemaVersion"\\s*:\\s*1\\s*,\\s*"$field"\\s*:\\s*\\[\\s*\$',
  );
  await for (final chunk in file.openRead().transform(utf8.decoder)) {
    for (final unit in chunk.codeUnits) {
      final c = String.fromCharCode(unit);
      if (!started) {
        prefix += c;
        if (prefix.length > 1024) {
          throw const FormatException('Invalid mapping envelope');
        }
        if (c == '[') {
          schemaFirst = header.hasMatch(prefix);
          if (!schemaFirst &&
              !RegExp('^\\s*\\{\\s*"$field"\\s*:\\s*\\[\$').hasMatch(prefix)) {
            throw const FormatException('Unsupported published schema');
          }
          started = true;
        }
        continue;
      }
      if (ended) {
        tail += c;
        if (tail.length > 1024) {
          throw const FormatException('Invalid mapping tail');
        }
        continue;
      }
      if (depth == 0) {
        if (c.trim().isEmpty) continue;
        if (c == ']' && allowEnd) {
          ended = true;
          continue;
        }
        if (!expectValue && c == ',') {
          expectValue = true;
          allowEnd = false;
          continue;
        }
        if (!expectValue || c != '{') {
          throw const FormatException('Invalid mapping array');
        }
        row = StringBuffer();
        rowLength = 0;
        depth = 1;
        inString = false;
        escape = false;
        row.write(c);
        continue;
      }
      row.write(c);
      if (++rowLength > 512 * 1024) {
        throw const FormatException('Mapping row limit');
      }
      if (inString) {
        if (escape) {
          escape = false;
        } else if (c == '\\') {
          escape = true;
        } else if (c == '"') {
          inString = false;
        }
      } else if (c == '"') {
        inString = true;
      } else if (c == '{' || c == '[') {
        depth++;
      } else if (c == '}' || c == ']') {
        depth--;
      }
      if (depth == 0) {
        final value = jsonDecode(row.toString());
        if (value is! Map<String, dynamic>) {
          throw const FormatException('Invalid mapping row');
        }
        yield value;
        expectValue = false;
        allowEnd = true;
      }
    }
  }
  if (!started ||
      !ended ||
      depth != 0 ||
      (schemaFirst
          ? tail.trim() != '}'
          : !RegExp(
              r'^\s*,\s*"schemaVersion"\s*:\s*1\s*}\s*$',
            ).hasMatch(tail))) {
    throw const FormatException('Incomplete mapping asset');
  }
}
