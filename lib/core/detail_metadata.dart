import 'bangumi_links.dart';
import 'metadata_servers.dart';
import 'metadata_http.dart';
import 'dart:convert';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import 'metadata.dart';
import 'cloud_media_asset_presentation.dart';
import 'anime_detail_metadata.dart';
import 'work_season.dart';
import 'work_matcher.dart';
import 'personal_filename_parser.dart';
import 'personal_scraper.dart';
import 'app_language.dart';

/// Standalone adaptation of NipaPlay Personal's basic Bangumi and TMDB
/// episode-artwork pipeline. No dependency on NipaPlay's providers or players.
class DetailMetadataService {
  static const schemaVersion = 16;
  DetailMetadataService({
    http.Client? client,
    this.tmdbRequest,
    this.bangumiBase = 'https://api.bgm.tv',
  }) : _client = client ?? MetadataHttp(),
       _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;
  final String bangumiBase;
  final Future<Map<String, dynamic>?> Function(
    String path,
    Map<String, String> params,
  )?
  tmdbRequest;
  static const _userAgent = 'Konata/0.1 (personal anime library)';

  void close() {
    if (_ownsClient) _client.close();
  }

  Future<Map<String, String>> bangumiPart(int id, String language) async {
    final body = await _getBangumi('/v0/subjects/$id');
    if (body is! Map || body['id'] != id) return {};
    final localized = body['name_cn']?.toString().trim();
    final original = body['name']?.toString().trim();
    final name = language.startsWith('zh') && localized?.isNotEmpty == true
        ? localized
        : original;
    final images = body['images'];
    final poster = images is Map ? images['large'] ?? images['common'] : null;
    return {
      if (name?.isNotEmpty == true) 'label': name!,
      if (poster is String && MetadataServers.imageResource(poster)?.$1 == 3)
        'poster': poster,
      if (AppLanguage.bangumiSynopsis(body['summary'], language)
          case final String summary)
        'summary': summary,
    };
  }

  /// A sequel may occupy the remainder of a single TMDB season. Require
  /// complete regular-episode lists before using its independent artwork.
  Future<List<Map<String, String>>> bangumiSplitParts(
    int first,
    List<String> tmdbDates,
    String language,
  ) async {
    Future<dynamic> episodes(int id) =>
        _getBangumi('/v0/episodes?subject_id=$id&type=0&limit=100');
    final responses = await Future.wait([
      episodes(first),
      _getBangumi('/v0/subjects/$first/subjects'),
    ]);
    final relations = responses[1];
    if (relations is! List) return [];
    final sequel = relations
        .whereType<Map>()
        .where(
          (row) =>
              row['relation'] == '续集' &&
              row['type'] == 2 &&
              row['id'] is int &&
              (row['id'] as int) > 0 &&
              row['id'] != first,
        )
        .singleOrNull;
    if (sequel == null) return [];
    final second = sequel['id'] as int;
    List<DateTime>? dates(dynamic value, int subject) {
      if (value is! Map || value['data'] is! List) return null;
      final rows = value['data'] as List;
      if (rows.length < 3 || rows.length != value['total']) return null;
      final result = <DateTime>[];
      for (final row in rows) {
        if (row is! Map ||
            row['type'] != 0 ||
            row['subject_id'] != null && row['subject_id'] != subject)
          return null;
        final date = DateTime.tryParse('${row['airdate']}');
        if (date == null || result.isNotEmpty && !date.isAfter(result.last))
          return null;
        result.add(date);
      }
      return result;
    }

    final head = dates(responses[0], first);
    if (head == null || head.length + 3 > tmdbDates.length) return [];
    bool agrees(DateTime date, String other) {
      final parsed = DateTime.tryParse(other);
      return parsed != null &&
          parsed.difference(date).abs() <= const Duration(days: 1);
    }

    if (!head.indexed.every((e) => agrees(e.$2, tmdbDates[e.$1]))) return [];
    final tail = dates(await episodes(second), second);
    if (tail == null ||
        head.length + tail.length != tmdbDates.length ||
        tail.first.difference(head.last) < const Duration(days: 45) ||
        !tail.indexed.every((e) => agrees(e.$2, tmdbDates[head.length + e.$1])))
      return [];
    final parts = await Future.wait([
      bangumiPart(first, language),
      bangumiPart(second, language),
    ]);
    return parts.every((part) => part['label'] != null) ? parts : [];
  }

  Future<String?> localizedSpecialTitle(
    int series,
    int episode,
    int chapter,
    String language,
  ) async {
    final season = await _tmdb('/tv/$series/season/0', {'language': language});
    final row = (season?['episodes'] as List? ?? [])
        .whereType<Map>()
        .where(
          (row) =>
              row['id'] == chapter &&
              row['season_number'] == 0 &&
              row['episode_number'] == episode,
        )
        .singleOrNull;
    final name = row?['name']?.toString().trim();
    return name == null ||
            name.isEmpty ||
            language.startsWith('zh') &&
                !RegExp(r'[\u3400-\u9fff]').hasMatch(name)
        ? null
        : name;
  }

  static String? image(String? path, {String size = 'w780'}) {
    if (path == null || path.isEmpty) return null;
    if (path.startsWith('https://')) return path;
    if (path.startsWith('/')) return MetadataServers.tmdbImage(path, size);
    return null;
  }

  Future<Map<String, dynamic>> fetch(
    Map<String, Object?> work, {
    List<Map<String, Object?>> assets = const [],
  }) async {
    final language = AppLanguage.instance.metadataLanguage;
    final mainSeasons = assets
        .where((a) => a['category'] == 'main' && a['season'] is int)
        .map((a) => a['season'] as int)
        .toSet();
    final isStandaloneSpecialWork =
        mainSeasons.isNotEmpty && mainSeasons.every((s) => s == 0);
    final hasBangumiLinks = BangumiLinks.ids(work).isNotEmpty;
    var specialEntries = <Map<String, dynamic>>[];
    final tmdbType = work['tmdb_type'] == 'movie' ? 'movie' : 'tv';
    Map<String, dynamic>? tmdbOverview;
    List<Map> tmdbSeasonList = const [];
    final tmdbCounts = <String, int>{};
    final tmdbSeasonsSnapshot = <String, Map<String, Map<String, dynamic>>>{};
    int? multiSeasonEndSeason;
    int? multiSeasonTotalEpisodes;
    int? lockedSingleSeason;
    var lockedPriorEpisodeOffset = 0;
    final result = <String, dynamic>{
      'schemaVersion': schemaVersion,
      'overview_language': language,
      'seasonEpisodes': <String, dynamic>{},
      'seasonEpisodeCounts': <String, dynamic>{},
      'specialAssets': <String, dynamic>{},
      'mainSpecialAssets': <String, dynamic>{},
      'episodes': <String, dynamic>{},
      'specials': <String, dynamic>{},
      'tags': <String>[],
      'errors': <String>[],
    };
    final tmdbId = work['tmdb_id'] as int?;
    if (tmdbId != null &&
        (tmdbRequest != null || Metadata.credentials.isConfigured)) {
      final type = tmdbType;
      try {
        final overview = await _tmdb('/$type/$tmdbId', {'language': language});
        tmdbOverview = overview;
        if (overview != null) {
          final genres = (overview['genres'] as List? ?? []).whereType<Map>();
          final animation =
              genres.any((g) => g['id'] == 16) ||
              (genres.isEmpty && BangumiLinks.ids(work).isNotEmpty);
          result['isAnimation'] = animation;
          result['original_language'] = overview['original_language'];
          result['origin_country'] = overview['origin_country'];
          final seriesTitle = overview['name']?.toString().trim() ?? '';
          final seasons = (overview['seasons'] as List? ?? []).whereType<Map>();
          final singleFirstSeason =
              seasons
                      .where((s) => (s['season_number'] as num? ?? 0) > 0)
                      .length ==
                  1 &&
              seasons.any((s) => s['season_number'] == 1);
          if (work['manual_lock'] != 1 &&
              type == 'tv' &&
              seriesTitle.isNotEmpty &&
              singleFirstSeason &&
              !WorkSeason.showSeasonInTitle(work, seasons) &&
              work['title'] == '$seriesTitle 第1季') {
            result['automaticSeriesTitle'] = seriesTitle;
          }
          if (animation &&
              singleFirstSeason &&
              !WorkSeason.multiple(work) &&
              (WorkSeason.explicit(work) ?? 1) == 1 &&
              work['manual_lock'] != 1 &&
              work['bangumi_link_info'] == null &&
              BangumiLinks.ids(work).isEmpty &&
              seriesTitle.isNotEmpty) {
            // A previously indexed title can have a TMDB match but no Bangumi metadata association.
            try {
              final match =
                  await PersonalMetadataScraper(
                    client: _client,
                    bangumiBase: bangumiBase,
                  ).matchBangumi(
                    seriesTitle,
                    WorkSeason.year(work),
                    tmdbId: tmdbId,
                  );
              final id = match?['id'];
              if (id is int && id > 0) {
                result['automaticBangumiId'] = id;
                work = {...work, 'bangumi_id': id};
              }
            } catch (_) {
              (result['errors'] as List<String>).add('Bangumi 关联暂时不可用');
            }
          }
          result['backdrop'] = image(
            overview['backdrop_path']?.toString(),
            size: 'w1280',
          );
          if (!(isStandaloneSpecialWork && hasBangumiLinks)) {
            result['poster'] = image(
              overview['poster_path']?.toString(),
              size: 'w500',
            );
            result['episodeCount'] = overview['number_of_episodes'];
            result['overview'] = overview['overview'];
            result['year'] =
                (overview['first_air_date'] ?? overview['release_date'])
                    ?.toString();
          }
          result['score'] = (overview['vote_average'] as num?)?.toDouble();
          result['tags'] = (overview['genres'] as List? ?? [])
              .whereType<Map>()
              .map((g) => g['name']?.toString() ?? '')
              .where((t) => t.isNotEmpty)
              .toList();
          result['companies'] = overview['production_companies'];
          result['source'] = 'TMDB';
        }
        if (type == 'movie') {
          // Personal uses landscape work artwork for a movie's main feature.
          // Movies have no TV season/episode still endpoint; missing artwork may
          // still be backfilled from parent TV Season 0 after Bangumi relations load.
          final artwork = await _movieStill(tmdbId, overview);
          result['movieStill'] = artwork;
          result['backdrop'] ??= artwork;
        }
        if (type == 'tv') {
          final seasonList = (overview?['seasons'] as List? ?? [])
              .whereType<Map>()
              .toList();
          tmdbSeasonList = seasonList;
          result['seasonMappingAmbiguous'] =
              (mainSeasons.length == 1 && mainSeasons.single != 1)
              ? false
              : WorkSeason.ambiguousYear(work, seasonList);
          // Unlike the initial prototype, episode artwork is keyed by
          // TMDB season AND episode number, not only season 1.
          final counts = <String, int>{};
          for (final season in (overview?['seasons'] as List? ?? [])) {
            if (season is! Map) continue;
            final number = (season['season_number'] as num?)?.toInt();
            final count = (season['episode_count'] as num?)?.toInt();
            if (number != null && number > 0 && count != null && count > 0) {
              counts[number.toString()] = count;
            }
          }
          tmdbCounts.addAll(counts);
          result['seasonEpisodeCounts'] = counts;

          final explicitWorkSeason = WorkSeason.explicit(work);
          final requested = <int>{1, 0};
          var maxUnseasoned = 0;
          var minUnseasoned = 999999;
          final allMainEpNums = <int>[];
          final explicitAssetSeasons = <int>{};
          for (final asset in assets) {
            final n = asset['episode'] as int? ?? 0;
            if (n <= 0) continue;
            final isMain = asset['category'] == 'main';
            final explicit = CloudMediaAssetPresentation.explicitSeasonNumber({
              ...asset,
              'episode_number': n,
              'work_title': WorkSeason.directoryTitle(work),
            });
            if (isMain && explicit != null) explicitAssetSeasons.add(explicit);
            final season = (asset['season'] as int? ?? 1);
            if (isMain && asset['manual_mapping'] != true) {
              allMainEpNums.add(n);
            }
            if (asset['manual_mapping'] == true) {
              requested.add(season);
            } else if (explicit != null) {
              requested.add(explicit);
            } else if (season > 1) {
              requested.add(season);
            } else if (season == 0) {
              requested.add(0);
            } else if (n > 0) {
              if (n > maxUnseasoned) maxUnseasoned = n;
              if (n < minUnseasoned) minUnseasoned = n;
            }
          }

          // Rule 1A: Continuous unseasoned episodes 1..M matching sum of R>=2
          // consecutive regular TMDB seasons resolve ambiguity cleanly.
          if (explicitWorkSeason == null &&
              maxUnseasoned > 0 &&
              minUnseasoned == 1 &&
              (mainSeasons.isEmpty || mainSeasons.every((s) => s == 1))) {
            var sum = 0;
            var spanSeasons = 0;
            for (var s = 1; s <= counts.length; s++) {
              final c = counts['$s'];
              if (c == null || c <= 0) break;
              sum += c;
              spanSeasons = s;
              if (sum == maxUnseasoned &&
                  spanSeasons >= 2 &&
                  (counts['1'] ?? 0) < maxUnseasoned) {
                multiSeasonEndSeason = spanSeasons;
                multiSeasonTotalEpisodes = sum;
                result['seasonMappingAmbiguous'] = false;
                break;
              }
              if (sum >= maxUnseasoned) break;
            }
          }

          // Rule 1B: Locked to season K > 1 while local files keep cumulative numbers A..B.
          final candidateLocked = explicitWorkSeason ??
              (mainSeasons.length == 1 ? mainSeasons.single : null) ??
              (explicitAssetSeasons.length == 1
                  ? explicitAssetSeasons.single
                  : null);
          if (candidateLocked != null && candidateLocked > 1) {
            requested.add(candidateLocked);
            final targetCount = counts['$candidateLocked'] ?? 0;
            var priorSum = 0;
            var validPrior = targetCount > 0;
            for (var s = 1; s < candidateLocked; s++) {
              final c = counts['$s'];
              if (c == null || c <= 0) {
                validPrior = false;
                break;
              }
              priorSum += c;
            }
            if (validPrior &&
                priorSum > 0 &&
                allMainEpNums.isNotEmpty &&
                allMainEpNums.any((n) => n > targetCount) &&
                allMainEpNums.every(
                  (n) => n > priorSum && n <= priorSum + targetCount,
                )) {
              lockedSingleSeason = candidateLocked;
              lockedPriorEpisodeOffset = priorSum;
              result['seasonMappingAmbiguous'] = false;
            }
          }

          if (multiSeasonEndSeason != null) {
            for (var s = 1; s <= multiSeasonEndSeason; s++) {
              requested.add(s);
            }
          } else if (maxUnseasoned > 0) {
            var sum = 0;
            final sorted = counts.keys.map(int.parse).toList()..sort();
            for (final season in sorted) {
              sum += counts['$season']!;
              requested.add(season);
              if (sum >= maxUnseasoned) break;
            }
          }
          final seasons = <String, dynamic>{};
          // Sequential bounded calls avoid flooding TMDB for large libraries.
          for (final number in (requested.toList()..sort())) {
            try {
              final payload = await _tmdb('/tv/$tmdbId/season/$number', {
                'language': language,
              });
              final items = <String, dynamic>{};
              for (final episode in (payload?['episodes'] as List? ?? [])) {
                if (episode is! Map) continue;
                final raw = episode['episode_number'];
                if (raw is! num) continue;
                final n = raw.toInt();
                items[n.toString()] = {
                  'name': episode['name'],
                  if (number == 0) 'special_number': n,
                  'overview': episode['overview'],
                  'still': image(
                    episode['still_path']?.toString(),
                    size: 'w500',
                  ),
                  'air_date': episode['air_date'],
                };
                if (number == 0) {
                  specialEntries.add(Map<String, dynamic>.from(episode));
                }
              }
              tmdbSeasonsSnapshot[number.toString()] = {
                for (final e in items.entries)
                  e.key: Map<String, dynamic>.from(e.value as Map),
              };
              if (lockedSingleSeason == number &&
                  lockedPriorEpisodeOffset > 0) {
                for (final entry in items.entries.toList()) {
                  final rel = int.tryParse(entry.key);
                  if (rel != null && rel >= 1) {
                    items.putIfAbsent(
                      '${rel + lockedPriorEpisodeOffset}',
                      () => Map<String, dynamic>.from(entry.value as Map),
                    );
                  }
                }
              }
              seasons[number.toString()] = items;
              if (number == 1) result['episodes'] = items;
              if (number == 0) result['specials'] = items;
            } catch (_) {
              /* Optional episode metadata must not block the library. */
            }
          }
          result['seasonEpisodes'] = seasons;
          if (specialEntries.isNotEmpty &&
              assets.any((a) => a['category'] == 'extra')) {
            final targetSeasonForSpecials = explicitWorkSeason ??
                lockedSingleSeason ??
                (mainSeasons.length == 1 ? mainSeasons.single : null) ??
                (seasonList.length == 1
                    ? (seasonList.single['season_number'] as num?)?.toInt()
                    : null);
            final matchedSeasonMeta = targetSeasonForSpecials == null
                ? null
                : seasonList
                      .where(
                        (s) =>
                            (s['season_number'] as num?)?.toInt() ==
                            targetSeasonForSpecials,
                      )
                      .firstOrNull;
            final yearHint = work['year']?.toString() ??
                matchedSeasonMeta?['air_date']?.toString() ??
                WorkSeason.directoryTitle(work);
            final dirTitle = WorkSeason.directoryTitle(work);
            final workTitle = dirTitle.isNotEmpty
                ? dirTitle
                : work['title']?.toString();
            final matched = CloudMediaAssetPresentation.mapSpecialEpisodes(
              assets: assets,
              specials: specialEntries,
              yearHint: yearHint,
              workTitle: workTitle,
              seasonNumber: targetSeasonForSpecials,
              seasonName: matchedSeasonMeta?['name']?.toString(),
            );
            result['specialAssets'] = {
              for (final entry in matched.entries)
                entry.key: {
                  'name': entry.value['name'],
                  'special_number': entry.value['episode_number'],
                  'overview': entry.value['overview'],
                  'still': image(
                    entry.value['still_path']?.toString(),
                    size: 'w500',
                  ),
                },
            };
          }
        }
      } catch (_) {
        (result['errors'] as List<String>).add('TMDB 暂时不可用');
      }
    }
    var bangumiOffset = 0;
    String? bangumiOverview;
    final bangumiSubjects = <Map<String, dynamic>>[];
    final bangumiEpisodeDates = <DateTime?>[];
    final bangumiSpecialEpisodes = <Map<String, dynamic>>[];
    final epZeroBgmCandidates = <Map<String, dynamic>>[];
    final epZeroAssets = !isStandaloneSpecialWork
        ? assets
              .where(
                (a) =>
                    a['category'] == 'main' &&
                    a['episode'] == 0 &&
                    a['manual_mapping'] != true,
              )
              .toList()
        : const <Map<String, Object?>>[];
    final maxMainEp = assets
        .where((a) => a['category'] == 'main' && a['manual_mapping'] != true)
        .map((a) => a['episode'] as int? ?? 0)
        .fold<int>(0, math.max);
    var recapApplied = false;
    final bangumiIds = BangumiLinks.ids(work);

    for (final bangumiId in bangumiIds) {
      Map<String, dynamic>? currentSubject;
      try {
        final subject = await _getBangumi('/v0/subjects/$bangumiId');
        if (subject is Map<String, dynamic>) {
          currentSubject = subject;
          bangumiSubjects.add(subject);
          final rating = subject['rating'] is Map
              ? subject['rating'] as Map
              : null;
          if (rating?['score'] is num) {
            result['score'] = (rating!['score'] as num).toDouble();
          }
          final tags = (subject['tags'] as List? ?? [])
              .whereType<Map>()
              .map((t) => t['name']?.toString() ?? '')
              .where((t) => t.isNotEmpty)
              .toList();
          if (tags.isNotEmpty) result['tags'] = tags;
          result['origin_tags'] = tags;
          result['infobox'] = subject['infobox'];
          result['bangumiType'] = subject['type'];
          result['episodeCount'] ??=
              subject['total_episodes'] ?? subject['eps'];
          result['year'] ??= subject['date']?.toString();
          bangumiOverview ??= AppLanguage.bangumiSynopsis(
            subject['summary'],
            language,
          );
          result['poster'] ??= (subject['images'] is Map)
              ? (subject['images'] as Map)['large']?.toString()
              : null;
          result['source'] = result['source'] == null
              ? 'Bangumi'
              : 'TMDB + Bangumi';
        }
      } catch (_) {
        (result['errors'] as List<String>).add('Bangumi 资料暂时不可用');
      }
      try {
        if (result['seasonMappingAmbiguous'] == true) continue;
        final episodes = await _getBangumi(
          '/v0/episodes?subject_id=$bangumiId&type=0&limit=100',
        );
        var rows = episodes is Map
            ? (episodes['data'] as List? ?? []).whereType<Map>().toList()
            : <Map>[];
        if (isStandaloneSpecialWork && rows.isEmpty) {
          final spEpisodes = await _getBangumi(
            '/v0/episodes?subject_id=$bangumiId&type=1&limit=100',
          );
          if (spEpisodes is Map && spEpisodes['data'] is List) {
            rows = (spEpisodes['data'] as List).whereType<Map>().toList();
          }
        }
        for (final item in rows) {
          final rawDate = item['airdate']?.toString();
          final sortNum = (item['sort'] as num?)?.toInt();
          final epNum = (item['ep'] as num?)?.toInt();
          if (epNum == 0 || sortNum == 0) {
            epZeroBgmCandidates.add({
              ...item,
              'subject_id': bangumiId,
              'episode_type': 0,
            });
          }
          if (epNum == null || epNum >= 1 || (sortNum != null && sortNum >= 1)) {
            bangumiEpisodeDates.add(
              DateTime.tryParse(rawDate ?? '') ??
                  DateTime.tryParse(currentSubject?['date']?.toString() ?? ''),
            );
          }
        }
        if (rows.isEmpty && currentSubject != null) {
          bangumiEpisodeDates.add(
            DateTime.tryParse(currentSubject['date']?.toString() ?? ''),
          );
        }
        final fallbackSeason =
            WorkSeason.explicit(work) ??
            lockedSingleSeason ??
            (mainSeasons.length == 1 ? mainSeasons.single : 1);
        if (fallbackSeason == 0) {
          // Retain per-episode metadata for standalone Season 0 works so
          // _resolveMainSpecialAssets can match multi-episode OVAs cleanly.
          for (final item in rows) {
            bangumiSpecialEpisodes.add({
              ...Map<String, dynamic>.from(item),
              'subject_id': bangumiId,
            });
          }
          continue;
        }
        final bySeason = Map<String, dynamic>.from(
          result['seasonEpisodes'] as Map? ?? {},
        );

        // Rule 1A: Multi-season continuous distribution (e.g. 50 == 25 + 25).
        if (multiSeasonEndSeason != null && multiSeasonTotalEpisodes != null) {
          final allRows = <({Map row, int offset})>[
            for (final r in rows) (row: r, offset: bangumiOffset),
          ];
          var totalCollected =
              bangumiOffset +
              rows
                  .where((e) => (e['ep'] as num? ?? e['sort'] as num? ?? 0) >= 1)
                  .length;
          if (bangumiIds.length == 1 &&
              totalCollected < multiSeasonTotalEpisodes) {
            var curSubjectId = bangumiId;
            final visited = <int>{bangumiId};
            for (var hop = 1; hop < multiSeasonEndSeason; hop++) {
              if (totalCollected >= multiSeasonTotalEpisodes) break;
              try {
                final rels = await _getBangumi(
                  '/v0/subjects/$curSubjectId/subjects',
                );
                if (rels is! List) break;
                final sequel = rels
                    .whereType<Map>()
                    .where(
                      (r) =>
                          r['relation'] == '续集' &&
                          r['type'] == 2 &&
                          r['id'] is int &&
                          !visited.contains(r['id'] as int),
                    )
                    .firstOrNull;
                if (sequel == null) break;
                final nextId = sequel['id'] as int;
                visited.add(nextId);
                curSubjectId = nextId;
                final nextEps = await _getBangumi(
                  '/v0/episodes?subject_id=$nextId&type=0&limit=100',
                );
                final nextRows = nextEps is Map
                    ? (nextEps['data'] as List? ?? []).whereType<Map>().toList()
                    : const <Map>[];
                if (nextRows.isEmpty) break;
                for (final r in nextRows) {
                  allRows.add((row: r, offset: totalCollected));
                }
                totalCollected += nextRows
                    .where((e) =>
                        (e['ep'] as num? ?? e['sort'] as num? ?? 0) >= 1)
                    .length;
              } catch (_) {
                break;
              }
            }
          }

          final targetEndSeason = multiSeasonEndSeason;
          ({int season, int ep})? splitCoords(int globalNum) {
            var remaining = globalNum;
            for (var s = 1; s <= targetEndSeason; s++) {
              final count = tmdbCounts['$s'] ?? 0;
              if (count <= 0) break;
              if (remaining <= count) return (season: s, ep: remaining);
              remaining -= count;
            }
            return null;
          }

          for (final entry in allRows) {
            final item = entry.row;
            final sortNum = (item['sort'] as num?)?.toInt();
            final epNum = (item['ep'] as num?)?.toInt();
            final relNum = (epNum != null && epNum >= 1) ? epNum : sortNum;
            if (relNum == null || relNum < 1) continue;
            final globalNum = (epNum == null &&
                    sortNum != null &&
                    sortNum > entry.offset)
                ? sortNum
                : relNum + entry.offset;
            final coords = splitCoords(globalNum);
            if (coords == null) continue;
            final sKey = '${coords.season}';
            final eKey = '${coords.ep}';
            final seasonMap = Map<String, dynamic>.from(
              bySeason[sKey] as Map? ?? {},
            );
            final old = seasonMap[eKey] is Map
                ? Map<String, dynamic>.from(seasonMap[eKey] as Map)
                : <String, dynamic>{};
            final bangumiName =
                (item['name_cn']?.toString().trim().isNotEmpty == true
                        ? item['name_cn']
                        : item['name'])
                    ?.toString();
            if (old['name']?.toString().trim().isNotEmpty != true &&
                bangumiName?.isNotEmpty == true) {
              old['name'] = bangumiName;
            }
            seasonMap[eKey] = old;
            bySeason[sKey] = seasonMap;
          }
          result['seasonEpisodes'] = bySeason;
          if (bySeason['1'] is Map) result['episodes'] = bySeason['1'];
          bangumiOffset += rows
              .where((e) => e['sort'] is num && (e['sort'] as num) > 0)
              .length;
          continue;
        }

        final episodeMap = Map<String, dynamic>.from(
          fallbackSeason == 1
              ? result['episodes'] as Map
              : bySeason['$fallbackSeason'] as Map? ?? {},
        );

        // Rule 1B: Locked to season K > 1 with cumulative episode numbers.
        if (lockedSingleSeason == fallbackSeason &&
            lockedPriorEpisodeOffset > 0) {
          final targetCount = tmdbCounts['$fallbackSeason'] ?? 0;
          for (final item in rows) {
            final sortNum = (item['sort'] as num?)?.toInt();
            final epNum = (item['ep'] as num?)?.toInt();
            final relNum = (epNum != null && epNum >= 1) ? epNum : sortNum;
            int? seasonEp;
            if (epNum != null &&
                epNum >= 1 &&
                (targetCount <= 0 || epNum <= targetCount)) {
              seasonEp = epNum;
            } else if (sortNum != null &&
                sortNum > lockedPriorEpisodeOffset &&
                (targetCount <= 0 ||
                    sortNum <= lockedPriorEpisodeOffset + targetCount)) {
              seasonEp = sortNum - lockedPriorEpisodeOffset;
            } else if (relNum != null &&
                relNum >= 1 &&
                (targetCount <= 0 || relNum <= targetCount)) {
              seasonEp = relNum;
            }
            if (seasonEp == null || seasonEp < 1) continue;
            final bangumiName =
                (item['name_cn']?.toString().trim().isNotEmpty == true
                        ? item['name_cn']
                        : item['name'])
                    ?.toString();
            final relKey = '$seasonEp';
            final merged = episodeMap[relKey] is Map
                ? Map<String, dynamic>.from(episodeMap[relKey] as Map)
                : <String, dynamic>{};
            if (merged['name']?.toString().trim().isNotEmpty != true &&
                bangumiName?.isNotEmpty == true) {
              merged['name'] = bangumiName;
            }
            episodeMap[relKey] = merged;
            episodeMap['${seasonEp + lockedPriorEpisodeOffset}'] =
                Map<String, dynamic>.from(merged);
          }
          bySeason['$fallbackSeason'] = episodeMap;
          result['seasonEpisodes'] = bySeason;
          if (fallbackSeason == 1) result['episodes'] = episodeMap;
          continue;
        }

        // Rule 2A: Bangumi recap / cross-season Season 0 air-date alignment.
        final tmdbSeasonCount = tmdbCounts['$fallbackSeason'] ?? 0;
        if (!recapApplied &&
            tmdbType == 'tv' &&
            specialEntries.isNotEmpty &&
            tmdbSeasonCount > 0 &&
            bangumiIds.length == 1 &&
            maxMainEp > tmdbSeasonCount) {
          final mainSpecialAssets = Map<String, dynamic>.from(
            result['mainSpecialAssets'] as Map? ?? {},
          );
          final aligned = _tryApplyRecapAlignment(
            targetSeason: fallbackSeason,
            tmdbSnapshot:
                tmdbSeasonsSnapshot['$fallbackSeason'] ?? const {},
            tmdbCount: tmdbSeasonCount,
            bangumiRows: rows,
            specialEntries: specialEntries,
            assets: assets,
            maxMainEp: maxMainEp,
            episodeMap: episodeMap,
            mainSpecialAssets: mainSpecialAssets,
          );
          if (aligned) {
            recapApplied = true;
            bySeason['$fallbackSeason'] = episodeMap;
            result['seasonEpisodes'] = bySeason;
            result['mainSpecialAssets'] = mainSpecialAssets;
            if (fallbackSeason == 1) result['episodes'] = episodeMap;
            continue;
          }
        }

        for (final item in rows) {
          final sortNum = (item['sort'] as num?)?.toInt();
          final epNum = (item['ep'] as num?)?.toInt();
          final relNum = (epNum != null && epNum >= 1) ? epNum : sortNum;
          if (relNum == null || relNum < 1) continue;
          final bangumiName =
              (item['name_cn']?.toString().trim().isNotEmpty == true
                      ? item['name_cn']
                      : item['name'])
                  ?.toString();
          void mergeKey(String key) {
            final old = episodeMap[key] is Map
                ? Map<String, dynamic>.from(episodeMap[key] as Map)
                : <String, dynamic>{};
            if (old['name']?.toString().trim().isNotEmpty != true &&
                bangumiName?.isNotEmpty == true) {
              old['name'] = bangumiName;
            }
            episodeMap[key] = old;
          }

          final primaryKey = (relNum + bangumiOffset).toString();
          mergeKey(primaryKey);
          // Dual-track ep/sort indexing for split-cour seasons (e.g. ep 1..12, sort 13..24).
          if (bangumiOffset == 0 &&
              sortNum != null &&
              sortNum >= 1 &&
              sortNum != relNum &&
              episodeMap[sortNum.toString()] is! Map) {
            final copied = Map<String, dynamic>.from(
              episodeMap[primaryKey] as Map,
            );
            episodeMap[sortNum.toString()] = copied;
          }
        }
        bySeason['$fallbackSeason'] = episodeMap;
        result['seasonEpisodes'] = bySeason;
        if (fallbackSeason == 1) result['episodes'] = episodeMap;
        bangumiOffset += rows
            .where((e) => e['sort'] is num && (e['sort'] as num) > 0)
            .length;
      } catch (_) {
        /* Optional fallback episode names. */
      }
    }

    // Rule 2B: Resolve episode == 0 main assets (e.g. "#00 <subtitle>").
    if (epZeroAssets.isNotEmpty && tmdbType == 'tv') {
      final targetSeason = WorkSeason.explicit(work) ??
          lockedSingleSeason ??
          (mainSeasons.length == 1 ? mainSeasons.single : 1);
      if (epZeroBgmCandidates.isEmpty && bangumiIds.isNotEmpty) {
        try {
          final spPayload = await _getBangumi(
            '/v0/episodes?subject_id=${bangumiIds.first}&type=1&limit=100',
          );
          if (spPayload is Map && spPayload['data'] is List) {
            for (final item in (spPayload['data'] as List).whereType<Map>()) {
              epZeroBgmCandidates.add({
                ...Map<String, dynamic>.from(item),
                'subject_id': bangumiIds.first,
                'episode_type': 1,
              });
            }
          }
        } catch (_) {
          /* Optional Bangumi ep 0 fallback. */
        }
      }
      final seasonAirDate = tmdbSeasonList
          .where((s) => (s['season_number'] as num?)?.toInt() == targetSeason)
          .firstOrNull?['air_date']
          ?.toString();
      await _resolveEpisodeZeroAssets(
        work: work,
        targetSeason: targetSeason,
        seasonFirstAirDate: seasonAirDate,
        epZeroAssets: epZeroAssets,
        epZeroBgmCandidates: epZeroBgmCandidates,
        specialEntries: specialEntries,
        result: result,
      );
    }

    // Rule 3: Backfill missing landscape still for standalone animation movie/OVA
    // from parent TV series Season 0 when _movieStill returns null.
    if (tmdbType == 'movie' &&
        tmdbId != null &&
        result['movieStill'] == null &&
        (result['isAnimation'] == true ||
            bangumiSubjects.isNotEmpty ||
            bangumiIds.isNotEmpty)) {
      await _backfillAnimationMovieStill(
        work: work,
        tmdbId: tmdbId,
        movieOverview: tmdbOverview,
        bangumiIds: bangumiIds,
        bangumiSubjects: bangumiSubjects,
        bangumiEpisodeDates: bangumiEpisodeDates,
        language: language,
        result: result,
      );
    }

    if (isStandaloneSpecialWork) {
      result['mainSpecialAssets'] = _resolveMainSpecialAssets(
        work: work,
        assets: assets,
        specialEntries: specialEntries,
        bangumiSubjects: bangumiSubjects,
        bangumiEpisodeDates: bangumiEpisodeDates,
        bangumiSpecialEpisodes: bangumiSpecialEpisodes,
        language: language,
      );
      if (bangumiOverview == null) {
        final firstMapped = (result['mainSpecialAssets'] as Map).values
            .whereType<Map>()
            .firstOrNull;
        final specialOverview = firstMapped?['overview']?.toString().trim();
        if (specialOverview != null && specialOverview.isNotEmpty) {
          result['overview'] = specialOverview;
        }
      }
    }
    if (bangumiOverview != null) result['overview'] = bangumiOverview;
    // Same stable tag precedence as NipaPlay Personal:
    // format -> studio -> adaptation -> up to 8 remaining tags.
    result['tags'] = AnimeDetailMetadata.tags({
      'metadata_json': jsonEncode({
        'tags': result['tags'],
        // TMDB movie is a storage type, not proof of a theatrical release.
        'typeDescription': work['tmdb_type'] == 'movie' ? null : 'TV',
        'production_companies': result['companies'],
        'infobox': result['infobox'],
      }),
    });
    return result;
  }

  Future<String?> localizedTmdbOverview(
    int id,
    String type,
    int? season,
    String language,
  ) async {
    final path = '/$type/$id';
    if (type == 'tv' && season != null && season > 0) {
      final scoped = await _tmdb('$path/season/$season', {
        'language': language,
      });
      final overview = scoped?['overview']?.toString().trim();
      if (scoped?['season_number'] == season && overview?.isNotEmpty == true) {
        return overview;
      }
      if (season != 1) return null;
    }
    final work = await _tmdb(path, {'language': language});
    if (work == null || work['id'] != id) return null;
    return work['overview']?.toString().trim();
  }

  Future<String?> fetchMovieStill(int movieId) async {
    final overview = await _tmdb('/movie/$movieId', {
      'language': AppLanguage.instance.metadataLanguage,
    });
    if (overview == null || overview['id'] != movieId) return null;
    return _movieStill(movieId, overview);
  }

  Future<String?> _movieStill(
    int movieId,
    Map<String, dynamic>? overview,
  ) async {
    final primary = image(overview?['backdrop_path']?.toString(), size: 'w780');
    if (primary != null) return primary;
    final images = await _tmdb('/movie/$movieId/images', {
      'include_image_language': 'zh,ja,en,null',
    });
    final backdrops = (images?['backdrops'] as List? ?? [])
        .whereType<Map>()
        .where((entry) => image(entry['file_path']?.toString()) != null)
        .toList();
    backdrops.sort((a, b) {
      final score = (num.tryParse('${b['vote_average']}') ?? 0).compareTo(
        num.tryParse('${a['vote_average']}') ?? 0,
      );
      if (score != 0) return score;
      return (num.tryParse('${b['width']}') ?? 0).compareTo(
        num.tryParse('${a['width']}') ?? 0,
      );
    });
    return image(backdrops.firstOrNull?['file_path']?.toString(), size: 'w780');
  }

  bool _tryApplyRecapAlignment({
    required int targetSeason,
    required Map<String, Map<String, dynamic>> tmdbSnapshot,
    required int tmdbCount,
    required List<Map> bangumiRows,
    required List<Map<String, dynamic>> specialEntries,
    required List<Map<String, Object?>> assets,
    required int maxMainEp,
    required Map<String, dynamic> episodeMap,
    required Map<String, dynamic> mainSpecialAssets,
  }) {
    final regulars = <({int localEp, Map row, DateTime? date})>[];
    for (final item in bangumiRows) {
      final sortNum = (item['sort'] as num?)?.toInt();
      final epNum = (item['ep'] as num?)?.toInt();
      final relNum = (epNum != null && epNum >= 1) ? epNum : sortNum;
      if (relNum == null || relNum < 1) continue;
      regulars.add((
        localEp: relNum,
        row: item,
        date: DateTime.tryParse(item['airdate']?.toString() ?? ''),
      ));
    }
    regulars.sort((a, b) => a.localEp.compareTo(b.localEp));
    final totalRegulars = regulars.length;
    final extraCount = totalRegulars - tmdbCount;
    if (tmdbCount <= 0 || extraCount <= 0 || maxMainEp < totalRegulars) {
      return false;
    }

    int countAgreements(Set<int> skippedIndices) {
      final shifted = <({int localEp, Map row, DateTime? date})>[
        for (var i = 0; i < regulars.length; i++)
          if (!skippedIndices.contains(i)) regulars[i],
      ];
      if (shifted.length != tmdbCount) return 0;
      var hits = 0;
      for (var k = 0; k < tmdbCount; k++) {
        final bDate = shifted[k].date;
        final tDate = DateTime.tryParse(
          tmdbSnapshot['${k + 1}']?['air_date']?.toString() ?? '',
        );
        if (bDate != null &&
            tDate != null &&
            bDate.difference(tDate).inDays.abs() <= 7) {
          hits++;
        }
      }
      return hits;
    }

    var unshiftedAgreements = 0;
    var tmdbRegularDateCount = 0;
    for (var k = 0; k < tmdbCount && k < regulars.length; k++) {
      final tDate = DateTime.tryParse(
        tmdbSnapshot['${k + 1}']?['air_date']?.toString() ?? '',
      );
      if (tDate != null) {
        tmdbRegularDateCount++;
        final bDate = regulars[k].date;
        if (bDate != null && bDate.difference(tDate).inDays.abs() <= 7) {
          unshiftedAgreements++;
        }
      }
    }

    final recapPattern = RegExp(
      r'総集編|总集篇|回顾|回顧|回忆|特別編|特别篇|recap|special|summary',
      caseSensitive: false,
    );
    final candidates =
        <({
          int bgmIdx,
          int localEp,
          Map<String, dynamic> s0Entry,
          int s0Ep,
          int diffDays,
          bool keywordHit,
        })>[];
    for (var i = 0; i < regulars.length; i++) {
      final bDate = regulars[i].date;
      if (bDate == null) continue;
      final bgmTitle =
          '${regulars[i].row['name_cn'] ?? ''} ${regulars[i].row['name'] ?? ''}';
      for (final s0 in specialEntries) {
        final s0Ep = (s0['episode_number'] as num?)?.toInt();
        final s0Date = DateTime.tryParse(s0['air_date']?.toString() ?? '');
        if (s0Ep == null || s0Date == null) continue;
        final diff = bDate.difference(s0Date).inDays.abs();
        if (diff <= 4) {
          final hit = recapPattern.hasMatch('${s0['name'] ?? ''} $bgmTitle');
          candidates.add((
            bgmIdx: i,
            localEp: regulars[i].localEp,
            s0Entry: s0,
            s0Ep: s0Ep,
            diffDays: diff,
            keywordHit: hit,
          ));
        }
      }
    }
    if (candidates.isEmpty) return false;

    final matchedRecapByLocalEp = <int, Map<String, dynamic>>{};
    if (extraCount == 1) {
      ({
        int bgmIdx,
        int localEp,
        Map<String, dynamic> s0Entry,
        int s0Ep,
        int diffDays,
        bool keywordHit,
      })? best;
      var bestScore = -10000;
      for (final c in candidates) {
        final shiftedAgreements = countAgreements({c.bgmIdx});
        if (tmdbRegularDateCount >= 2 &&
            shiftedAgreements <= unshiftedAgreements &&
            shiftedAgreements < tmdbRegularDateCount) {
          continue;
        }
        final score =
            shiftedAgreements * 100 +
            (4 - c.diffDays) * 10 +
            (c.keywordHit ? 25 : 0);
        if (score > bestScore) {
          bestScore = score;
          best = c;
        }
      }
      if (best == null) return false;
      matchedRecapByLocalEp[best.localEp] = best.s0Entry;
    } else {
      final sorted = [...candidates]
        ..sort((a, b) {
          if (a.keywordHit != b.keywordHit) return a.keywordHit ? -1 : 1;
          return a.diffDays.compareTo(b.diffDays);
        });
      final usedBgm = <int>{};
      final usedS0 = <int>{};
      for (final c in sorted) {
        if (matchedRecapByLocalEp.length >= extraCount) break;
        if (usedBgm.contains(c.bgmIdx) || usedS0.contains(c.s0Ep)) continue;
        usedBgm.add(c.bgmIdx);
        usedS0.add(c.s0Ep);
        matchedRecapByLocalEp[c.localEp] = c.s0Entry;
      }
      if (matchedRecapByLocalEp.length != extraCount) return false;
      final shiftedAgreements = countAgreements(usedBgm);
      if (tmdbRegularDateCount >= 2 &&
          shiftedAgreements <= unshiftedAgreements) {
        return false;
      }
    }

    var tmdbCursor = 1;
    for (final item in regulars) {
      final localEp = item.localEp;
      final bangumiName =
          (item.row['name_cn']?.toString().trim().isNotEmpty == true
                  ? item.row['name_cn']
                  : item.row['name'])
              ?.toString();
      final matchedS0 = matchedRecapByLocalEp[localEp];
      if (matchedS0 != null) {
        final s0Ep = (matchedS0['episode_number'] as num?)?.toInt();
        final payload = <String, dynamic>{
          'name': bangumiName?.isNotEmpty == true
              ? bangumiName
              : matchedS0['name'],
          'special_number': ?s0Ep,
          'overview': matchedS0['overview'],
          'still': image(matchedS0['still_path']?.toString(), size: 'w500'),
          'air_date': matchedS0['air_date'] ?? item.row['airdate'],
        };
        episodeMap['$localEp'] = payload;
        for (final asset in assets) {
          if (asset['category'] == 'main' &&
              asset['manual_mapping'] != true &&
              asset['episode'] == localEp) {
            final path = asset['relative_path']?.toString() ?? '';
            if (path.isNotEmpty) {
              mainSpecialAssets[path] = Map<String, dynamic>.from(payload);
            }
          }
        }
      } else if (tmdbCursor <= tmdbCount) {
        final base = tmdbSnapshot['$tmdbCursor'];
        final merged = base != null
            ? Map<String, dynamic>.from(base)
            : <String, dynamic>{};
        if (merged['name']?.toString().trim().isNotEmpty != true &&
            bangumiName?.isNotEmpty == true) {
          merged['name'] = bangumiName;
        }
        episodeMap['$localEp'] = merged;
        if (localEp != tmdbCursor || localEp > tmdbCount) {
          for (final asset in assets) {
            if (asset['category'] == 'main' &&
                asset['manual_mapping'] != true &&
                asset['episode'] == localEp) {
              final path = asset['relative_path']?.toString() ?? '';
              if (path.isNotEmpty) {
                mainSpecialAssets[path] = Map<String, dynamic>.from(merged);
              }
            }
          }
        }
        tmdbCursor++;
      }
    }
    return true;
  }

  String _extractAssetSubtitleHint(
    Map<String, Object?> asset,
    Map<String, Object?> work,
  ) {
    var text = CloudMediaAssetPresentation.cleanedExtraFilename(asset);
    final workTitles = <String>[
      WorkSeason.directoryTitle(work),
      work['title']?.toString() ?? '',
    ]..removeWhere((t) => t.trim().isEmpty);

    for (final wt in workTitles) {
      final cleanWt = wt
          .replaceAll(RegExp(r'\{tmdb-\d+\}', caseSensitive: false), '')
          .replaceAll(RegExp(r'\((?:19|20)\d{2}\)'), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (cleanWt.isNotEmpty &&
          text.toLowerCase().startsWith(cleanWt.toLowerCase())) {
        final rest = text
            .substring(cleanWt.length)
            .replaceFirst(RegExp(r'^[\s\-–—:：~～]+'), '')
            .trim();
        if (rest.isNotEmpty) {
          text = rest;
          break;
        }
      }
    }
    // Strip leading #00 / 00 / E00 markers while keeping any actual subtitle.
    final strippedEp = text
        .replaceFirst(
          RegExp(
            r'^(?:#|EP?\.?\s*|OVA\s*|第)?\s*0*\d{1,3}(?:[集話话])?[\s\-–—:：~～]*',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
    return strippedEp.isNotEmpty ? strippedEp : text.trim();
  }

  Future<void> _resolveEpisodeZeroAssets({
    required Map<String, Object?> work,
    required int targetSeason,
    required String? seasonFirstAirDate,
    required List<Map<String, Object?>> epZeroAssets,
    required List<Map<String, dynamic>> epZeroBgmCandidates,
    required List<Map<String, dynamic>> specialEntries,
    required Map<String, dynamic> result,
  }) async {
    bool isGenericZeroTitle(String? t) {
      final trimmed = t?.trim() ?? '';
      return trimmed.isEmpty ||
          RegExp(
            r'^(?:第\s*0+\s*[集话話]|episode\s*0+|ep\.?\s*0+|#?0+)$',
            caseSensitive: false,
          ).hasMatch(trimmed);
    }

    final premiereDate = DateTime.tryParse(seasonFirstAirDate ?? '');
    final mainSpecialAssets = Map<String, dynamic>.from(
      result['mainSpecialAssets'] as Map? ?? {},
    );
    final bySeason = Map<String, dynamic>.from(
      result['seasonEpisodes'] as Map? ?? {},
    );
    final seasonMap = Map<String, dynamic>.from(
      bySeason['$targetSeason'] as Map? ?? {},
    );

    for (final asset in epZeroAssets) {
      final path = asset['relative_path']?.toString() ?? '';
      final subtitleHint = _extractAssetSubtitleHint(asset, work);
      final usableSub = isGenericZeroTitle(subtitleHint) ? '' : subtitleHint;

      Map<String, dynamic>? matchedBgm;
      var bestBgmScore = -1.0;
      for (final c in epZeroBgmCandidates) {
        final epNum = (c['ep'] as num?)?.toInt();
        final sortNum = (c['sort'] as num?)?.toInt();
        var score = (epNum == 0 || sortNum == 0) ? 50.0 : 0.0;
        final bgmNames = <String>[
          if (c['name_cn']?.toString().trim().isNotEmpty == true)
            c['name_cn'].toString().trim(),
          if (c['name']?.toString().trim().isNotEmpty == true)
            c['name'].toString().trim(),
        ];
        if (usableSub.isNotEmpty) {
          for (final bn in bgmNames) {
            final sim = CloudMediaAssetPresentation.subtitleSimilarity(
              usableSub,
              bn,
            );
            if (sim * 80 > score - 50) score += sim * 80;
          }
        }
        if (score > bestBgmScore) {
          bestBgmScore = score;
          matchedBgm = c;
        }
      }
      if (bestBgmScore <= 0) matchedBgm = null;

      final titleClues = <String>[
        if (usableSub.isNotEmpty) usableSub,
        if (matchedBgm?['name_cn']?.toString().trim().isNotEmpty == true)
          matchedBgm!['name_cn'].toString().trim(),
        if (matchedBgm?['name']?.toString().trim().isNotEmpty == true)
          matchedBgm!['name'].toString().trim(),
      ];
      final bgmDate = DateTime.tryParse(
        matchedBgm?['airdate']?.toString() ?? '',
      );

      Map<String, dynamic>? bestS0;
      var bestS0Score = -1.0;
      for (final entry in specialEntries) {
        final entryName = entry['name']?.toString() ?? '';
        final entryOverview = entry['overview']?.toString() ?? '';
        final entryDate = DateTime.tryParse(
          entry['air_date']?.toString() ?? '',
        );
        var score = 0.0;
        var maxSim = 0.0;
        for (final clue in titleClues) {
          final sim = CloudMediaAssetPresentation.subtitleSimilarity(
            clue,
            entryName,
          );
          if (sim > maxSim) maxSim = sim;
        }
        score += maxSim * 80.0;

        if (usableSub.isNotEmpty &&
            entryOverview.toLowerCase().contains(usableSub.toLowerCase())) {
          score += 25.0;
        }
        if (bgmDate != null && entryDate != null) {
          final diff = entryDate.difference(bgmDate).inDays.abs();
          if (diff <= 4) {
            score += 75.0;
          } else if (diff <= 14) {
            score += 45.0;
          } else if (diff <= 45) {
            score += 15.0;
          }
        }
        if (premiereDate != null && entryDate != null) {
          final daysBefore = premiereDate.difference(entryDate).inDays;
          if (daysBefore >= 0 && daysBefore <= 35) score += 25.0;
        }
        if (RegExp(
          r'(?:^|\b)(?:episode\s*0+|ep\s*0+|#0+|prologue)|第\s*0+\s*[話话集]|序章|前日譚',
          caseSensitive: false,
        ).hasMatch('$entryName $entryOverview')) {
          score += 30.0;
        }
        if (score > bestS0Score) {
          bestS0Score = score;
          bestS0 = entry;
        }
      }

      if (bestS0Score < 30.0) bestS0 = null;
      if (bestS0 == null &&
          specialEntries.length == 1 &&
          (bgmDate != null || premiereDate != null)) {
        final sole = specialEntries.single;
        final soleDate = DateTime.tryParse(sole['air_date']?.toString() ?? '');
        final refDate = bgmDate ?? premiereDate!;
        if (soleDate != null && soleDate.difference(refDate).inDays.abs() <= 45) {
          bestS0 = sole;
        }
      }

      final bgmTitleCn = matchedBgm?['name_cn']?.toString().trim();
      final bgmTitleRaw = matchedBgm?['name']?.toString().trim();
      final s0Title = bestS0?['name']?.toString().trim();
      final resolvedTitle = !isGenericZeroTitle(bgmTitleCn)
          ? bgmTitleCn!
          : !isGenericZeroTitle(bgmTitleRaw)
          ? bgmTitleRaw!
          : !isGenericZeroTitle(s0Title)
          ? s0Title!
          : (usableSub.isNotEmpty ? usableSub : null);

      if (resolvedTitle == null && bestS0 == null) continue;
      final epNum = (bestS0?['episode_number'] as num?)?.toInt();
      final resolvedMap = <String, dynamic>{
        'name': ?resolvedTitle,
        'special_number': ?epNum,
        if (bestS0?['overview'] != null || matchedBgm?['desc'] != null)
          'overview': bestS0?['overview'] ?? matchedBgm?['desc'],
        if (bestS0?['still_path'] != null)
          'still': image(bestS0!['still_path']?.toString(), size: 'w500'),
        if (bestS0?['air_date'] != null || matchedBgm?['airdate'] != null)
          'air_date': bestS0?['air_date'] ?? matchedBgm?['airdate'],
      };
      if (path.isNotEmpty) {
        mainSpecialAssets[path] = Map<String, dynamic>.from(resolvedMap);
      }
      seasonMap['0'] = Map<String, dynamic>.from(resolvedMap);
    }

    if (mainSpecialAssets.isNotEmpty) {
      result['mainSpecialAssets'] = mainSpecialAssets;
    }
    if (seasonMap.containsKey('0')) {
      bySeason['$targetSeason'] = seasonMap;
      result['seasonEpisodes'] = bySeason;
      if (targetSeason == 1) result['episodes'] = seasonMap;
    }
  }

  Future<void> _backfillAnimationMovieStill({
    required Map<String, Object?> work,
    required int tmdbId,
    required Map<String, dynamic>? movieOverview,
    required List<int> bangumiIds,
    required List<Map<String, dynamic>> bangumiSubjects,
    required List<DateTime?> bangumiEpisodeDates,
    required String language,
    required Map<String, dynamic> result,
  }) async {
    final movieTitles = <String>[
      if (movieOverview?['title']?.toString().trim().isNotEmpty == true)
        movieOverview!['title'].toString().trim(),
      if (movieOverview?['original_title']?.toString().trim().isNotEmpty ==
          true)
        movieOverview!['original_title'].toString().trim(),
      if (WorkSeason.directoryTitle(work).isNotEmpty)
        WorkSeason.directoryTitle(work),
      if (work['title']?.toString().trim().isNotEmpty == true)
        work['title'].toString().trim(),
      for (final s in bangumiSubjects) ...[
        if (s['name_cn']?.toString().trim().isNotEmpty == true)
          s['name_cn'].toString().trim(),
        if (s['name']?.toString().trim().isNotEmpty == true)
          s['name'].toString().trim(),
      ],
    ];

    final targetDate =
        DateTime.tryParse(movieOverview?['release_date']?.toString() ?? '') ??
        DateTime.tryParse(
          bangumiSubjects.firstOrNull?['date']?.toString() ?? '',
        ) ??
        bangumiEpisodeDates.whereType<DateTime>().firstOrNull;

    final queryPriority = <String>[];
    final seenQueries = <String>{};
    void addQuery(String? q) {
      final clean = q?.trim() ?? '';
      if (clean.length < 2) return;
      final key = clean.toLowerCase();
      if (seenQueries.add(key)) queryPriority.add(clean);
    }

    // 1. Prefer Bangumi linked main story / prequel subjects (type == 2).
    const relOrder = ['主线故事', '前传', '番外篇', '总集篇', '全集'];
    for (final bgmId in bangumiIds) {
      try {
        final relations = await _getBangumi('/v0/subjects/$bgmId/subjects');
        if (relations is! List) continue;
        final candidates = relations
            .whereType<Map>()
            .where((r) => r['type'] == 2)
            .toList()
          ..sort((a, b) {
            final idxA = relOrder.indexOf('${a['relation']}');
            final idxB = relOrder.indexOf('${b['relation']}');
            final normA = idxA < 0 ? 99 : idxA;
            final normB = idxB < 0 ? 99 : idxB;
            return normA.compareTo(normB);
          });
        for (final rel in candidates) {
          addQuery(rel['name_cn']?.toString());
          addQuery(rel['name']?.toString());
        }
      } catch (_) {
        /* Optional relation lookup. */
      }
    }

    // 2. Fall back to main title stem extraction.
    for (final t in movieTitles) {
      final stem = PersonalFilenameParser.extractAnimeTitleKeyword(t);
      addQuery(stem);
      final split = t
          .split(
            RegExp(
              r'\s*(?:[:：]|[-–—]\s|～|\b(?:OVA|OAD|The\s+Movie)\b|劇場版|剧场版)',
              caseSensitive: false,
            ),
          )
          .first
          .trim();
      addQuery(split);
      addQuery(t);
    }

    if (queryPriority.isEmpty) return;

    final candidateTvIds = <int>[];
    final seenTvIds = <int>{tmdbId};
    for (final q in queryPriority.take(3)) {
      if (candidateTvIds.length >= 4) break;
      try {
        final search = await _tmdb('/search/tv', {
          'query': q,
          'language': language,
        });
        for (final row in (search?['results'] as List? ?? []).whereType<Map>()) {
          final id = row['id'];
          if (id is! int || id <= 0 || !seenTvIds.add(id)) continue;
          final gIds = (row['genre_ids'] as List? ?? []).whereType<int>().toList();
          if (gIds.isNotEmpty && !gIds.contains(16)) continue;
          candidateTvIds.add(id);
          if (candidateTvIds.length >= 4) break;
        }
      } catch (_) {
        /* Try remaining queries. */
      }
    }

    if (candidateTvIds.isEmpty) return;

    // Also strip shared parent stem from movieTitles for pure subtitle matching.
    final titleStems = <String>[...movieTitles];
    for (final q in queryPriority.take(2)) {
      final normQ = q.toLowerCase();
      for (final mt in movieTitles) {
        if (mt.toLowerCase().startsWith(normQ) && mt.length > normQ.length + 2) {
          final sub = mt
              .substring(normQ.length)
              .replaceFirst(RegExp(r'^[\s\-–—:：~～/]+'), '')
              .trim();
          if (sub.isNotEmpty) titleStems.add(sub);
        }
      }
    }

    Map<String, dynamic>? bestEntry;
    var bestScore = -1.0;

    for (final tvId in candidateTvIds) {
      try {
        final s0Payload = await _tmdb('/tv/$tvId/season/0', {
          'language': language,
        });
        for (final ep in (s0Payload?['episodes'] as List? ?? []).whereType<Map>()) {
          final stillPath = ep['still_path']?.toString().trim() ?? '';
          if (image(stillPath, size: 'w780') == null) continue;
          final epName = ep['name']?.toString() ?? '';
          final epDate = DateTime.tryParse(ep['air_date']?.toString() ?? '');
          final diffDays = (targetDate != null && epDate != null)
              ? epDate.difference(targetDate).inDays.abs()
              : null;

          var bestSim = 0.0;
          for (final clue in titleStems) {
            final sim = CloudMediaAssetPresentation.subtitleSimilarity(
              clue,
              epName,
            );
            if (sim > bestSim) bestSim = sim;
          }

          final dateMatches = diffDays != null && diffDays <= 14;
          final subtitleMatches = bestSim >= 0.70;
          if (!dateMatches && !subtitleMatches) continue;

          var score = 0.0;
          if (dateMatches) score += 100.0 - diffDays * 2.0;
          if (subtitleMatches) score += bestSim * 90.0;
          if (score > bestScore) {
            bestScore = score;
            bestEntry = Map<String, dynamic>.from(ep);
          }
        }
      } catch (_) {
        /* Try remaining TV candidates. */
      }
    }

    if (bestEntry != null && bestScore >= 60.0) {
      final artwork = image(
        bestEntry['still_path']?.toString(),
        size: 'w780',
      );
      if (artwork != null) {
        result['movieStill'] = artwork;
        result['backdrop'] ??= artwork;
      }
    }
  }

  Map<String, dynamic> _resolveMainSpecialAssets({
    required Map<String, Object?> work,
    required List<Map<String, Object?>> assets,
    required List<Map<String, dynamic>> specialEntries,
    required List<Map<String, dynamic>> bangumiSubjects,
    required List<DateTime?> bangumiEpisodeDates,
    List<Map<String, dynamic>> bangumiSpecialEpisodes = const [],
    required String language,
  }) {
    final mainAssets =
        assets
            .where(
              (a) =>
                  a['category'] == 'main' &&
                  (a['season'] as int?) == 0 &&
                  a['manual_mapping'] != true,
            )
            .toList()
          ..sort((a, b) {
            final epA = (a['episode'] as int?) ?? 999999;
            final epB = (b['episode'] as int?) ?? 999999;
            if (epA != epB) return epA.compareTo(epB);
            return '${a['relative_path']}'.compareTo('${b['relative_path']}');
          });
    if (mainAssets.isEmpty) return const {};
    final mapped = <String, dynamic>{};
    final claimed = <int>{};
    final workYear = WorkSeason.year(work);

    final workTitleList = <String>[
      if (work['title']?.toString().trim().isNotEmpty == true)
        work['title'].toString().trim(),
      if (WorkSeason.directoryTitle(work).isNotEmpty)
        WorkSeason.directoryTitle(work),
    ];

    double bestSubtitleSim(List<String> titles, String entryName) {
      var best = 0.0;
      for (final t in titles) {
        if (t.trim().isEmpty) continue;
        final sim = CloudMediaAssetPresentation.subtitleSimilarity(
          t,
          entryName,
        );
        if (sim > best) best = sim;
      }
      return best;
    }

    bool overviewStrongMatch(List<String> clues, String? overview, String? bgmDesc) {
      final ov = overview?.trim() ?? '';
      if (ov.isEmpty) return false;
      final ovLower = ov.toLowerCase();
      for (final c in clues) {
        final normC = CloudMediaAssetPresentation.normalizeWithNumerals(c);
        if (normC.length >= 4 && ovLower.contains(normC)) return true;
        final words = normC
            .split(' ')
            .where(
              (w) =>
                  w.length >= 3 ||
                  RegExp(r'[\u3040-\u9fff]{2,}').hasMatch(w),
            )
            .toList();
        if (words.length >= 2 && words.every(ovLower.contains)) return true;
      }
      final desc = bgmDesc?.trim() ?? '';
      if (desc.length >= 8) {
        final normOv = PersonalFilenameParser.normalizeIdentity(ov);
        final normDesc = PersonalFilenameParser.normalizeIdentity(desc);
        if (normOv.isNotEmpty &&
            normDesc.isNotEmpty &&
            WorkMatcher.similarity(normDesc, normOv) >= 0.65) {
          return true;
        }
      }
      return false;
    }

    // Precompute per-asset context so exclusive-subtitle pairs lock cleanly
    // regardless of filesystem sort order.
    final ctxList = <({
      int idx,
      Map<String, Object?> asset,
      String path,
      Map<String, dynamic>? subject,
      Map<String, dynamic>? bgmEp,
      DateTime? targetDate,
      String cleanedFile,
      String extractedSub,
      List<String> assetSpecificTitles,
      List<String> workFallbackTitles,
      bool isClipCompilation,
    })>[];

    for (var i = 0; i < mainAssets.length; i++) {
      final asset = mainAssets[i];
      final path = asset['relative_path']?.toString() ?? '';
      if (path.isEmpty) continue;
      final subject = bangumiSubjects.length == mainAssets.length
          ? bangumiSubjects[i]
          : (bangumiSubjects.isNotEmpty ? bangumiSubjects.first : null);
      final assetEpNum = asset['episode'] as int?;
      Map<String, dynamic>? bgmEp;
      if (bangumiSpecialEpisodes.isNotEmpty) {
        if (assetEpNum != null && assetEpNum >= 1) {
          bgmEp = bangumiSpecialEpisodes
              .where((e) => (e['ep'] as num?)?.toInt() == assetEpNum || (e['sort'] as num?)?.toInt() == assetEpNum)
              .firstOrNull;
        }
        bgmEp ??= i < bangumiSpecialEpisodes.length
            ? bangumiSpecialEpisodes[i]
            : null;
      }
      final targetDate = bangumiSubjects.length == mainAssets.length
          ? DateTime.tryParse(subject?['date']?.toString() ?? '')
          : (DateTime.tryParse(bgmEp?['airdate']?.toString() ?? '') ??
                (i < bangumiEpisodeDates.length
                    ? bangumiEpisodeDates[i]
                    : DateTime.tryParse(subject?['date']?.toString() ?? '')));
      final cleanedFile = CloudMediaAssetPresentation.cleanedExtraFilename(asset);
      final extractedSub = _extractAssetSubtitleHint(asset, work);
      final assetSpecificTitles = <String>[
        if (extractedSub.isNotEmpty &&
            !RegExp(r'^(?:EP?\.?\s*)?\d{1,3}$', caseSensitive: false)
                .hasMatch(extractedSub))
          extractedSub,
        if (cleanedFile.isNotEmpty && cleanedFile != extractedSub) cleanedFile,
        if (bgmEp?['name_cn']?.toString().trim().isNotEmpty == true)
          bgmEp!['name_cn'].toString().trim(),
        if (bgmEp?['name']?.toString().trim().isNotEmpty == true)
          bgmEp!['name'].toString().trim(),
        if (bangumiSubjects.length == mainAssets.length) ...[
          if (subject?['name_cn']?.toString().trim().isNotEmpty == true)
            subject!['name_cn'].toString().trim(),
          if (subject?['name']?.toString().trim().isNotEmpty == true)
            subject!['name'].toString().trim(),
        ],
      ];
      final workFallbackTitles = <String>[
        if (bangumiSubjects.length != mainAssets.length) ...[
          if (subject?['name_cn']?.toString().trim().isNotEmpty == true)
            subject!['name_cn'].toString().trim(),
          if (subject?['name']?.toString().trim().isNotEmpty == true)
            subject!['name'].toString().trim(),
        ],
        ...workTitleList,
      ];
      final isClipCompilation = RegExp(
        r'\b(?:digest|recap|summary|digest\s*edit)\b',
        caseSensitive: false,
      ).hasMatch(cleanedFile);

      ctxList.add((
        idx: i,
        asset: asset,
        path: path,
        subject: subject,
        bgmEp: bgmEp,
        targetDate: targetDate,
        cleanedFile: cleanedFile,
        extractedSub: extractedSub,
        assetSpecificTitles: assetSpecificTitles,
        workFallbackTitles: workFallbackTitles,
        isClipCompilation: isClipCompilation,
      ));
    }

    // Pass A: High-confidence exclusive subtitle / overview global pairing
    // (exempt from diff > 35/45 and |year - workYear| > 1 cutoffs).
    final highConfPairs =
        <({int ctxIdx, int epNum, Map<String, dynamic> entry, double score})>[];
    for (var ci = 0; ci < ctxList.length; ci++) {
      final ctx = ctxList[ci];
      if (ctx.assetSpecificTitles.isEmpty) continue;
      final bgmDesc =
          ctx.bgmEp?['desc']?.toString() ?? ctx.subject?['summary']?.toString();
      for (final entry in specialEntries) {
        final epNum = (entry['episode_number'] as num?)?.toInt();
        if (epNum == null) continue;
        final entryName = entry['name']?.toString() ?? '';
        final assetSim = bestSubtitleSim(ctx.assetSpecificTitles, entryName);
        final ovHit = overviewStrongMatch(
          ctx.assetSpecificTitles,
          entry['overview']?.toString(),
          bgmDesc,
        );
        final entryDate = DateTime.tryParse(entry['air_date']?.toString() ?? '');
        final dateDiff = (ctx.targetDate != null && entryDate != null)
            ? entryDate.difference(ctx.targetDate!).inDays.abs()
            : null;
        final strongTitle = assetSim >= 0.72;
        final exactDateWithTitleOrOv =
            dateDiff != null && dateDiff <= 7 && (assetSim >= 0.45 || ovHit);
        if (!strongTitle && !ovHit && !exactDateWithTitleOrOv) continue;

        var score = assetSim * 140.0 + (ovHit ? 40.0 : 0.0);
        if (dateDiff != null) {
          score += math.max(0.0, 45.0 - dateDiff * 0.5);
        } else if (workYear != null && entryDate != null) {
          score += math.max(0.0, 20.0 - (entryDate.year - workYear).abs() * 5.0);
        }
        highConfPairs.add((
          ctxIdx: ci,
          epNum: epNum,
          entry: entry,
          score: score,
        ));
      }
    }
    highConfPairs.sort((a, b) {
      final cmp = b.score.compareTo(a.score);
      if (cmp != 0) return cmp;
      return a.epNum.compareTo(b.epNum);
    });
    final lockedCtx = <int>{};
    for (final pair in highConfPairs) {
      if (lockedCtx.contains(pair.ctxIdx) || claimed.contains(pair.epNum)) {
        continue;
      }
      final ctx = ctxList[pair.ctxIdx];
      lockedCtx.add(pair.ctxIdx);
      claimed.add(pair.epNum);
      mapped[ctx.path] = {
        'name': pair.entry['name'],
        'special_number': pair.epNum,
        'overview': pair.entry['overview'],
        'still': image(pair.entry['still_path']?.toString(), size: 'w500'),
        'air_date': pair.entry['air_date'],
      };
    }

    // Pass B: Remaining assets (date-window <= 45 days for cross-New-Year,
    // overview matching, contiguous sequence alignment for multi-ep OVAs).
    int? lastSequentialEp;
    DateTime? lastSequentialDate;
    for (var ci = 0; ci < ctxList.length; ci++) {
      final ctx = ctxList[ci];
      if (lockedCtx.contains(ci)) {
        final entry = mapped[ctx.path] as Map<String, dynamic>?;
        lastSequentialEp = entry?['special_number'] as int?;
        lastSequentialDate = DateTime.tryParse(
          entry?['air_date']?.toString() ?? '',
        );
        continue;
      }

      final bgmDesc =
          ctx.bgmEp?['desc']?.toString() ?? ctx.subject?['summary']?.toString();
      Map<String, dynamic>? bestEntry;
      var bestScore = -1000.0;

      for (final entry in specialEntries) {
        final epNum = (entry['episode_number'] as num?)?.toInt();
        if (epNum == null || claimed.contains(epNum)) continue;
        final entryDate = DateTime.tryParse(
          entry['air_date']?.toString() ?? '',
        );
        final entryName = entry['name']?.toString() ?? '';
        final assetSim = bestSubtitleSim(ctx.assetSpecificTitles, entryName);
        final ovHit = overviewStrongMatch(
          [...ctx.assetSpecificTitles, ...ctx.workFallbackTitles],
          entry['overview']?.toString(),
          bgmDesc,
        );
        final strongMatch = assetSim >= 0.72 || ovHit;

        // Protect distinct compilation clips (e.g. "Digest") from stealing
        // an unrelated special via shared series title alone.
        if (ctx.isClipCompilation &&
            !RegExp(
              r'digest|recap|summary|総集編|总集篇',
              caseSensitive: false,
            ).hasMatch('$entryName ${entry['overview'] ?? ''}') &&
            assetSim < 0.55) {
          continue;
        }
        final hasSubstantiveSub = ctx.assetSpecificTitles.isNotEmpty &&
            ctx.extractedSub.isNotEmpty &&
            !RegExp(r'^(?:EP?\.?\s*)?\d{1,3}$', caseSensitive: false)
                .hasMatch(ctx.extractedSub);

        var score = 0.0;
        var dateWithinWindow = false;
        if (ctx.targetDate != null && entryDate != null) {
          final diff = entryDate.difference(ctx.targetDate!).inDays.abs();
          if (!strongMatch && diff > 45) continue;
          dateWithinWindow = diff <= 45;
          score += diff <= 45 ? (100.0 - diff * 1.8) : 0.0;
        } else if (workYear != null && entryDate != null) {
          final yearDiff = (entryDate.year - workYear).abs();
          if (!strongMatch && yearDiff > 1) continue;
          score += yearDiff == 0 ? 45.0 : (yearDiff == 1 ? 20.0 : 0.0);
        }

        score += assetSim * 80.0;
        if (ovHit) score += 35.0;

        // Only add generic workTitle similarity when the asset does NOT carry
        // an unmatched substantive subtitle (or when airdate agrees closely).
        if (!hasSubstantiveSub || dateWithinWindow || assetSim >= 0.4) {
          final workSim = bestSubtitleSim(ctx.workFallbackTitles, entryName);
          score += workSim * 35.0;
        }

        if (lastSequentialEp != null && epNum == lastSequentialEp + 1) {
          if (lastSequentialDate == null ||
              entryDate == null ||
              entryDate.difference(lastSequentialDate).inDays.abs() <= 120) {
            score += 25.0;
          }
        }

        if (score > bestScore) {
          bestScore = score;
          bestEntry = entry;
        }
      }

      if (bestEntry != null && bestScore >= 25.0) {
        final epNum = (bestEntry['episode_number'] as num).toInt();
        claimed.add(epNum);
        lastSequentialEp = epNum;
        lastSequentialDate = DateTime.tryParse(
          bestEntry['air_date']?.toString() ?? '',
        );
        mapped[ctx.path] = {
          'name': bestEntry['name'],
          'special_number': epNum,
          'overview': bestEntry['overview'],
          'still': image(bestEntry['still_path']?.toString(), size: 'w500'),
          'air_date': bestEntry['air_date'],
        };
      } else if (ctx.subject != null &&
          bangumiSubjects.length == mainAssets.length) {
        final localized = ctx.subject!['name_cn']?.toString().trim();
        final original = ctx.subject!['name']?.toString().trim();
        final fallbackName =
            language.startsWith('zh') && localized?.isNotEmpty == true
            ? localized
            : (original?.isNotEmpty == true ? original : localized);
        if (fallbackName != null && fallbackName.isNotEmpty) {
          mapped[ctx.path] = {
            'name': fallbackName,
            'overview': AppLanguage.bangumiSynopsis(
              ctx.subject!['summary'],
              language,
            ),
            'air_date': ctx.subject!['date'],
          };
        }
      } else if (ctx.cleanedFile.isNotEmpty) {
        // Unmatched compilation/clip (e.g. "Digest") retains its cleaned
        // filename title without stealing another special's still artwork.
        mapped[ctx.path] = {
          'name': ctx.cleanedFile,
        };
      }
    }
    return mapped;
  }

  Future<Map<String, dynamic>?> _tmdb(
    String resource,
    Map<String, String> params,
  ) async {
    if (tmdbRequest != null) return tmdbRequest!(resource, params);
    final credentials = Metadata.credentials;
    if (!credentials.isConfigured) return null;
    final response = await _client.get(
      credentials.uri(resource, params),
      headers: credentials.headers,
    );
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw StateError('TMDB HTTP ${response.statusCode}');
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  Future<dynamic> _getBangumi(String path) async {
    final response = await _client.get(
      Uri.parse('$bangumiBase$path'),
      headers: {'User-Agent': _userAgent, 'Accept': 'application/json'},
    );
    if (response.statusCode != 200) {
      throw StateError('Bangumi HTTP ${response.statusCode}');
    }
    return jsonDecode(utf8.decode(response.bodyBytes));
  }
}
