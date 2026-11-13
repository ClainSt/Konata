import 'dart:convert';
import 'dart:io';

import 'package:ccplayer/core/directory_analyzer.dart';
import 'package:ccplayer/core/work_matcher.dart';
import 'package:flutter_test/flutter_test.dart';

/// Offline benchmark on the real r7 acceptance library (182 works, saved
/// TMDB/Bangumi candidates). Measures the decision layer only: works whose
/// correct entry was never among the saved candidates can at best stay unbound.
void main() {
  final fixture =
      jsonDecode(
            File('test/fixtures/r7_scrape_benchmark.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  final works = (fixture['works'] as List).cast<Map<String, dynamic>>();

  test('r7 benchmark: accuracy, wrong binds and speed', () {
    final stats = <String, Map<String, int>>{
      'tmdb': {},
      'bangumi': {},
      'season': {},
      'r7': {},
    };
    void count(String group, String key) =>
        stats[group]!.update(key, (n) => n + 1, ifAbsent: () => 1);
    final failures = <String>[];
    final clock = Stopwatch()..start();
    final results =
        <
          (Map<String, dynamic>, DirectoryInventory, MatchResult, MatchResult)
        >[];
    for (final work in works) {
      final inventory = DirectoryAnalyzer.analyze(work['path'] as String, [
        for (final file in work['files'] as List)
          (path: file[0] as String, size: (file[1] as num?)?.toInt()),
      ]);
      List<MatchCandidate> candidates(String provider) => [
        for (final row in work[provider] as List)
          MatchCandidate.fromJson(provider, row as Map<String, dynamic>),
      ];
      final bangumi = WorkMatcher.bangumi(inventory, candidates('bangumi'));
      final tmdb = WorkMatcher.tmdb(
        inventory,
        candidates('tmdb'),
        bangumi: bangumi,
      );
      results.add((work, inventory, tmdb, bangumi));
    }
    clock.stop();

    for (final (work, inventory, tmdb, bangumi) in results) {
      final expect = work['expect'] as Map<String, dynamic>;
      final r7 = work['r7'] as Map<String, dynamic>;
      for (final provider in ['tmdb', 'bangumi']) {
        if (!expect.containsKey(provider)) {
          count(provider, 'unlabelled');
          continue;
        }
        final want = expect[provider];
        final wantKey = want == null
            ? null
            : provider == 'tmdb'
            ? want as String
            : 'anime:$want';
        final result = provider == 'tmdb' ? tmdb : bangumi;
        final got = result.candidate?.key;
        final offered = (work[provider] as List).any(
          (c) => '${c['type'] ?? 'anime'}:${c['id']}' == wantKey,
        );
        final r7Got = '${r7[provider] ?? ''}'.startsWith('confirmed')
            ? '${r7[provider]}'.split(':').skip(2).join(':')
            : null;
        if (wantKey != null && r7Got == wantKey ||
            wantKey == null && r7Got == null) {
          count('r7', '$provider correct');
        } else if (r7Got != null) {
          count('r7', '$provider wrong');
        }
        String outcome;
        if (got == wantKey && got != null) {
          outcome = result.tier == MatchTier.high ? 'auto' : 'adopt';
        } else if (got == null && wantKey == null) {
          outcome = 'correct none';
        } else if (got == null) {
          outcome = offered ? 'missed' : 'not offered';
        } else {
          outcome = 'WRONG';
        }
        count(provider, outcome);
        if (outcome == 'WRONG' || outcome == 'missed') {
          failures.add(
            '$outcome $provider ${work['path']}\n'
            '   want=$wantKey got=$got\n   $inventory\n   $result',
          );
        }
        if (provider == 'tmdb' &&
            got == wantKey &&
            got != null &&
            expect['season'] != null) {
          final season = tmdb.season;
          count(
            'season',
            season == expect['season']
                ? 'right'
                : season == null
                ? 'unresolved'
                : 'WRONG',
          );
          if (season != null && season != expect['season']) {
            failures.add(
              'WRONG season ${work['path']} want=${expect['season']} got=$season\n   $tmdb',
            );
          }
        }
      }
    }
    // ignore: avoid_print
    print(
      'r7 benchmark: ${works.length} works in ${clock.elapsedMilliseconds} ms\n'
      '${stats.entries.map((e) => '  ${e.key}: ${e.value}').join('\n')}\n'
      '${failures.join('\n')}',
    );
    expect(stats['tmdb']!['WRONG'] ?? 0, 0);
    expect(stats['bangumi']!['WRONG'] ?? 0, 0);
    expect(stats['season']!['WRONG'] ?? 0, 0);
    // Regression floors (measured 2026-11-13: TMDB 145 bound, Bangumi 156).
    int bound(String p) => (stats[p]!['auto'] ?? 0) + (stats[p]!['adopt'] ?? 0);
    expect(bound('tmdb'), greaterThanOrEqualTo(145));
    expect(bound('bangumi'), greaterThanOrEqualTo(156));
  });

  DirectoryInventory inv(String folder, List<String> files) =>
      DirectoryAnalyzer.analyze(folder, [
        for (final f in files) (path: f, size: null),
      ]);

  test('1080p SDR and 2160p HDR encodes are one feature', () {
    final i = inv('机动战士高达 逆袭的夏亚 (1988) {tmdb-16157}', [
      '[AI-Raws] 機動戦士ガンダム 逆襲のシャア (UHD HEVC 1920x1040 SDR FLAC)[B9D71299].mkv',
      '[AI-Raws] 機動戦士ガンダム 逆襲のシャア (UHD HEVC 3840x2080 HDR FLAC)[AB077724].mkv',
      '[AI-Raws] 機動戦士ガンダム 逆襲のシャア 予告編 (BD)[11111111].mkv',
    ]);
    expect(i.shape, WorkShape.feature);
    expect(i.featureCount, 1);
    expect(i.year, 1988);
    expect(i.tmdbId, 16157);
  });

  test('a single numbered movie file is not episode N', () {
    final i = inv('头文字D Legend1 -觉醒- (2014) {tmdb-271709}', [
      '[AI-Raws&ANK-Raws] New Initial D the Movie Legend 01 - Awakening - (BDRip 1920x1080 x265)[AB28C44F].mkv',
    ]);
    expect(i.shape, WorkShape.feature);
    expect(i.episodeCount, 0);
  });

  test('OVA-only folder promotes OVA files, never trailers or menus', () {
    final i = inv('新机动战记高达W 无尽的华尔兹 (1997)', [
      '[Sub][Gundam_W_Endless_Waltz][OVA][01][BDRIP][1440x1080].mkv',
      '[Sub][Gundam_W_Endless_Waltz][OVA][02][BDRIP][1440x1080].mkv',
      '[Sub][Gundam_W_Endless_Waltz][OVA][03][BDRIP][1440x1080].mkv',
      '[Sub][Gundam_W_Endless_Waltz][NCED][BDRIP].mkv',
      '[Sub][Gundam_W_Endless_Waltz][Menu][BDRIP].mkv',
    ]);
    expect(i.shape, WorkShape.series);
    expect(i.episodeCount, 3);
    expect(i.extras.length, 2);
  });

  test('a Sample folder has no main content', () {
    final i = inv('圣斗士星矢 圣域传说/Sample', [
      'Saint.Seiya.Legend.Of.Sanctuary.2014.1080p.BluRay.x264.DTS-WiKi.Sample.mkv',
    ]);
    expect(i.shape, WorkShape.empty);
  });

  test('untyped TMDB ID resolves to the type that fits the folder', () {
    final i = inv('机动战士高达 逆袭的夏亚 (1988) {tmdb-16157}', [
      '[AI-Raws] 機動戦士ガンダム 逆襲のシャア (UHD 1920x1040 SDR)[B9D71299].mkv',
      '[AI-Raws] 機動戦士ガンダム 逆襲のシャア (UHD 3840x2080 HDR)[AB077724].mkv',
    ]);
    final result = WorkMatcher.tmdb(i, const [
      MatchCandidate(
        provider: 'tmdb',
        id: 16157,
        type: 'tv',
        title: 'Amores de Fin de Siglo',
        year: 1995,
        seasons: [SeasonInfo(1, 133, 1995)],
      ),
      MatchCandidate(
        provider: 'tmdb',
        id: 16157,
        type: 'movie',
        title: '机动战士高达 逆袭的夏亚',
        year: 1988,
        aliases: ['機動戦士ガンダム 逆襲のシャア'],
      ),
    ]);
    expect(result.tier, MatchTier.high);
    expect(result.candidate?.key, 'movie:16157');
  });

  test('same-year seasons resolve by episode count', () {
    const show = MatchCandidate(
      provider: 'tmdb',
      id: 64163,
      type: 'tv',
      title: '新妹魔王的契约者',
      year: 2015,
      aliases: ['Shinmai Maou no Testament', 'Shinmai Maou no Testament BURST'],
      seasons: [
        SeasonInfo(0, 13, 2015),
        SeasonInfo(1, 12, 2015),
        SeasonInfo(2, 10, 2015),
      ],
    );
    final burst = inv('新妹魔王的契约者 BURST', [
      for (var e = 1; e <= 10; e++)
        '[VCB-Studio] Shinmai Maou no Testament BURST [${'$e'.padLeft(2, '0')}][Ma10p_1080p][x265_flac].mkv',
    ]);
    expect(WorkMatcher.tmdb(burst, const [show]).season, 2);
  });

  test('anthology folder is never bound to one movie', () {
    final i = inv('机动战士SD高达 (1988) {tmdb-508108}', [
      for (final part in ['Mk1', 'Mk2', 'Mk3', 'Mk4', 'Gaiden'])
        for (var e = 1; e <= 3; e++)
          '[Inka-Subs] Mobile Suit SD Gundam $part - Episode 0$e [1080p].mkv',
    ]);
    expect(i.shape, WorkShape.anthology);
    final result = WorkMatcher.tmdb(i, const [
      MatchCandidate(
        provider: 'tmdb',
        id: 508108,
        type: 'movie',
        title: '机动战士SD高达',
        year: 1988,
      ),
    ]);
    expect(result.tier, MatchTier.none);
  });
}
