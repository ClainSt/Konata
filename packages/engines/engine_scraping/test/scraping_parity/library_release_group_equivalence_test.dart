import 'dart:convert';
import 'dart:io';

import 'package:engine_scraping/engine_scraping.dart';
import 'package:test/test.dart';

void main() {
  test('历史命名夹具的压制组按需解析与完整解析一致', () {
    final root =
        jsonDecode(
              File(
                'test/scraping_parity/fixtures/r7_scrape_benchmark.json',
              ).readAsStringSync(),
            )
            as Map<String, Object?>;
    final videoExtension = RegExp(
      r'\.(mkv|mp4|avi|m2ts|ts|webm|mov|wmv)$',
      caseSensitive: false,
    );
    var count = 0;
    for (final work
        in (root['works'] as List<Object?>).cast<Map<String, Object?>>()) {
      final path = work['path'] as String;
      final title = path.split('/').last;
      for (final entry
          in (work['files'] as List<Object?>).cast<List<Object?>>()) {
        final relative = entry[0] as String;
        if (!videoExtension.hasMatch(relative)) continue;
        final name = relative.split(RegExp(r'[/\\]')).last;
        final full = BdripParser.parseFileName(
          name,
          relativePath: '$path/$relative',
          folderTitle: title,
        );
        final fast = BdripParser.parseFileName(
          name,
          relativePath: '$path/$relative',
          folderTitle: title,
          resolveEpisode: false,
          resolveExtraClassification: false,
          resolveTitleAndSeason: false,
        );
        expect(fast.releaseGroup, full.releaseGroup, reason: name);
        count++;
      }
    }
    expect(count, greaterThanOrEqualTo(4399));
  });
}
