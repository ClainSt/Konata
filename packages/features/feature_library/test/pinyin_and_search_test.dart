import 'dart:io';
import 'dart:typed_data';

import 'package:engine_scraping/engine_scraping.dart';
import 'package:feature_library/feature_library.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart' show AssetDataLoaderPort;

final class _FileLoader implements AssetDataLoaderPort {
  int calls = 0;

  @override
  Future<Uint8List> loadBytes(String path) {
    calls++;
    expect(path, 'assets/data/pinyin.bin.gz');
    return File('../../../apps/konata/$path').readAsBytes();
  }
}

void main() {
  group('ChinesePinyinCollator 与 LibrarySearchMatcher 核心算法', () {
    test('拼音表在排序需要时并发合并读取并支持释放', () async {
      final loader = _FileLoader();
      ChinesePinyinCollator.configure(loader);
      addTearDown(() {
        ChinesePinyinCollator.release();
        ChinesePinyinCollator.configure(null);
      });
      expect(ChinesePinyinCollator.isLoaded, isFalse);
      expect(ChinesePinyinCollator.compareNames('Air 2', 'Air 10'), lessThan(0));
      expect(loader.calls, 0);

      await Future.wait([
        ChinesePinyinCollator.prepare(),
        ChinesePinyinCollator.prepare(),
      ]);
      expect(ChinesePinyinCollator.pinyinInitialOfRune('轻'.runes.first), 'q');
      expect(loader.calls, 1);
      ChinesePinyinCollator.release();
      expect(ChinesePinyinCollator.isLoaded, isFalse);
    });

    test('完整覆盖 20902 个标准基本汉字并输出有效拼音首字母与排位', () {
      var covered = 0;
      for (var cp = 0x4E00; cp <= 0x9FA5; cp++) {
        final initial = ChinesePinyinCollator.pinyinInitialOfRune(cp);
        final rank = ChinesePinyinCollator.pinyinRankOfRune(cp);
        expect(initial, isNotNull, reason: '码位 0x${cp.toRadixString(16)} 缺失拼音');
        expect(rank, inInclusiveRange(0, 252));
        covered++;
      }
      expect(covered, 20902);
      expect(ChinesePinyinCollator.pinyinInitialOfRune('啊'.runes.first), 'a');
      expect(ChinesePinyinCollator.pinyinInitialOfRune('轻'.runes.first), 'q');
      expect(ChinesePinyinCollator.pinyinInitialOfRune('Z'.runes.first), isNull);
    });

    test('遵循「符号 -> 自然数字 -> 英文 -> 中文拼音」并支持自然数字序', () {
      final raw = <String>[
        '轻音少女',
        '孤独摇滚！',
        '第 10 话',
        '第 2 话',
        'Air',
        '18号',
        '[OVA]',
      ];
      final sorted = List<String>.of(raw)
        ..sort(ChinesePinyinCollator.compareNames);

      expect(sorted, [
        '[OVA]',
        '18号',
        'Air',
        '第 2 话',
        '第 10 话',
        '孤独摇滚！',
        '轻音少女',
      ]);
    });

    test('支持全角折半角、精确前缀与相关性分层排序', () {
      const kon = Work(
        id: 'w1',
        title: '轻音少女',
        originalTitle: 'けいおん!',
        year: 2009,
        tmdbId: 31132,
        bangumiId: 1424,
      );
      const kon2 = Work(
        id: 'w2',
        title: '剧场版 轻音少女',
        originalTitle: '映画 けいおん！',
        year: 2011,
        tmdbId: 84092,
        bangumiId: 12650,
      );
      const bocchi = Work(
        id: 'w3',
        title: '孤独摇滚！',
        originalTitle: 'ぼっち・ざ・ろっく！',
        year: 2022,
        tmdbId: 201552,
        bangumiId: 328609,
      );

      final items = <({Work work, List<String> groups})>[
        (work: kon2, groups: ['VCB-Studio']),
        (work: kon, groups: ['KissSub', 'VCB-Studio']),
        (work: bocchi, groups: ['喵萌奶茶屋']),
      ];

      // 前缀 tmdb: 与 bgm:
      final byTmdb = LibrarySearchMatcher.filterAndRank(
        items: items,
        workOf: (e) => e.work,
        releaseGroupsOf: (e) => e.groups,
        rawQuery: 'ＴＭＤＢ:31132',
      );
      expect(byTmdb.map((e) => e.work.id), ['w1']);

      final byBgm = LibrarySearchMatcher.filterAndRank(
        items: items,
        workOf: (e) => e.work,
        releaseGroupsOf: (e) => e.groups,
        rawQuery: 'bgm-328609',
      );
      expect(byBgm.map((e) => e.work.id), ['w3']);

      // 压制组精确检索
      final byGroup = LibrarySearchMatcher.filterAndRank(
        items: items,
        workOf: (e) => e.work,
        releaseGroupsOf: (e) => e.groups,
        rawQuery: '压制组:喵萌奶茶屋',
      );
      expect(byGroup.map((e) => e.work.id), ['w3']);

      // 前缀标题命中权重大于中间包含命中
      final byTitle = LibrarySearchMatcher.filterAndRank(
        items: items,
        workOf: (e) => e.work,
        releaseGroupsOf: (e) => e.groups,
        rawQuery: '轻音',
      );
      expect(byTitle.map((e) => e.work.id), ['w1', 'w2']);
    });
  });
}
