import 'package:flutter_test/flutter_test.dart';
import 'package:ccplayer/ui/source_browser_page.dart';

void main() {
  final data = <BrowserEntry>[
    const BrowserEntry(
      '16bit的感动 ANOTHER LAYER (2023) {tmdb-217512}',
      '动画-单作品/16bit的感动 ANOTHER LAYER (2023) {tmdb-217512}',
      true,
      null,
    ),
    const BrowserEntry(
      '86 -不存在的战区- (2021) {tmdb-100565}',
      '动画-单作品/86 -不存在的战区- (2021) {tmdb-100565}',
      true,
      null,
    ),
    const BrowserEntry('DEEMO 樱花之音', '动画-单作品/DEEMO 樱花之音', true, null),
    const BrowserEntry('sample01.mkv', '动画-单作品/sample01.mkv', false, 3429),
  ];
  test('local folders and WebDAV folders use the SAME filter', () {
    final local = List<BrowserEntry>.from(data);
    final webdav = List<BrowserEntry>.from(data);
    for (final source in [local, webdav]) {
      expect(
        SourceBrowserSearch.filter(source, '16bit').map((e) => e.name),
        contains('16bit的感动 ANOTHER LAYER (2023) {tmdb-217512}'),
      );
      expect(
        SourceBrowserSearch.filter(source, 'tmdb-100565').single.name,
        startsWith('86'),
      );
      expect(
        SourceBrowserSearch.filter(source, 'deemo').single.name,
        startsWith('DEEMO'),
      );
      expect(
        SourceBrowserSearch.filter(source, 'SAMPLE').single.name,
        'sample01.mkv',
      );
      expect(SourceBrowserSearch.filter(source, '  ').length, 4);
      expect(SourceBrowserSearch.filter(source, 'not-here'), isEmpty);
      expect(
        source.length,
        4,
        reason: 'Filtering must not remove source files',
      );
    }
  });
  test(
    'search is only for current directory, not a bogus global recursion',
    () {
      const child = BrowserEntry(
        'README.txt',
        'other/16bit/README.txt',
        false,
        12,
      );
      expect(SourceBrowserSearch.filter([child], '16bit'), isEmpty);
      expect(SourceBrowserSearch.filter([child], 'readme').length, 1);
    },
  );
}
