import 'package:flutter_test/flutter_test.dart';
import 'package:ccplayer/core/catalog.dart';

void main() {
  test('TMDB ID and year are extracted from directory', () {
    expect(Catalog.tmdbId('86 (2021) {tmdb-100565}'), 100565);
    expect(Catalog.year('86 (2021) {tmdb-100565}'), 2021);
    expect(Catalog.cleanTitle('86 (2021) {tmdb-100565}'), '86');
  });
  test('BDRip episode numbering and video types', () {
    expect(Catalog.episode('[01].mkv'), 1);
    expect(Catalog.episode('86 - 12 [1080p].mkv'), 12);
    expect(Catalog.episode('Show.S02E04.mkv'), 4);
    expect(Catalog.episode('91 Days.mkv'), null);
    expect(Catalog.isVideo('video.mkv'), true);
    expect(Catalog.isVideo('video.ass'), false);
    expect(Catalog.isSubtitle('video.tc.ass'), true);
  });
  test('Extras identified', () {
    expect(Catalog.isExtra('86/SPs/NCOP01.mkv'), true);
    expect(Catalog.isExtra('86/[01].mkv'), false);
  });
}
