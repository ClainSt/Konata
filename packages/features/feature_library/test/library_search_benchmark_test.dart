import 'dart:convert';
import 'dart:io';

import 'package:engine_scraping/engine_scraping.dart';
import 'package:feature_library/feature_library.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('5000 部作品连续搜索五轮基准及顺序保护', () {
    final items = List.generate(
      5000,
      (i) => (
        work: Work(
          id: 'work-$i',
          title: i % 3 == 0 ? '轻音少女 第 $i 话' : '剧场版 动画作品 $i',
          originalTitle: 'Ａｎｉｍｅ Series $i',
          year: 2000 + i % 25,
          tmdbId: 100000 + i,
          bangumiId: 200000 + i,
        ),
        groups: i.isEven ? ['VCB-Studio', '喵萌奶茶屋'] : ['KissSub'],
      ),
    );
    const queries = [
      '轻',
      '轻音',
      '轻音少女',
      '轻音少女 2022',
      'Ａｎｉｍｅ',
      'anime series 12',
      'group:VCB',
      '压制组:喵萌',
      'ＴＭＤＢ:100123',
      'bgm-200456',
      '不存在的作品',
      '',
    ];
    List<String> reference(String query) => LibrarySearchMatcher.filterAndRank(
      items: items,
      workOf: (item) => item.work,
      releaseGroupsOf: (item) => item.groups,
      rawQuery: query,
    ).map((item) => item.work.id).toList();
    final expected = [for (final query in queries) reference(query)];
    final cold = Stopwatch()..start();
    final index = LibrarySearchIndex(
      items: items,
      workOf: (item) => item.work,
      releaseGroupsOf: (item) => item.groups,
    );
    List<String> run(String query) =>
        index.search(query).map((item) => item.work.id).toList();
    final first = [for (final query in queries) run(query)];
    cold.stop();
    expect(first, expected);
    expect(expected[8], ['work-123']);
    expect(expected[9], ['work-456']);
    expect(expected[10], isEmpty);
    expect(expected[11], hasLength(5000));
    final times = <int>[];
    for (var i = 0; i < 5; i++) {
      final timer = Stopwatch()..start();
      final actual = [for (final query in queries) run(query)];
      timer.stop();
      times.add(timer.elapsedMicroseconds);
      expect(actual, expected);
    }
    // 保存每个查询的完整有序身份，供优化前后精确对照。
    stdout.writeln(
      'SEARCH_BENCHMARK ${jsonEncode({'works': items.length, 'queries': queries.length, 'counts': expected.map((rows) => rows.length).toList(), 'search_us': times, 'cold_us': cold.elapsedMicroseconds})}',
    );
    stdout.writeln('SEARCH_ORDER ${jsonEncode(expected)}');
  });
}
