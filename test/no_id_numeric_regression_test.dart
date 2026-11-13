import 'package:flutter_test/flutter_test.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/personal_scraper.dart';
import 'package:ccplayer/core/work_season.dart';

void main() {
  test('search hints retain title numbers while removing explicit release years', () {
    expect(PersonalMetadataScraper.queries('NIGHT HEAD 2041'), ['NIGHT HEAD 2041']);
    final hints = PersonalMetadataScraper.queries('NIGHT HEAD 2041 (2021)');
    expect(hints, contains('NIGHT HEAD 2041'));
    expect(hints, isNot(contains('NIGHT HEAD')));
    final parsed = PersonalMetadataScraper.filenameWork('Series (2020) - 01.mkv')!;
    expect(parsed['title'], 'Series');
    expect(parsed['year'], 2020);
  });
  test('reviewed compound group preserves bracketed titles and unknown names', () {
    final cases = {
      '[TxxZ&A.I.R.nesSub][Soukyuu_no_Fafner_Exodus][01][Full_Size][BDRIP][1920x1080][HEVC_Ma10P_FLAC].mkv': 'Soukyuu no Fafner Exodus',
      '[TxxZ&A.I.R.nesSub][009_RE_CYBORG][2D][BDRIP][1080p][AVC-10bpp_FLACx2_AC3x2_PGSx2].mkv': '009 RE CYBORG',
      '[Unknown&Title][01][1080p].mkv': 'Unknown&Title',
      '[WAR][01].mkv': 'WAR',
      '[TxxZ&A.I.R.nesSub][01].mkv': 'TxxZ&A I R nesSub',
    };
    for (final entry in cases.entries) {
      expect(PersonalMetadataScraper.filenameWork(entry.key)!['title'], entry.value, reason: entry.key);
    }
  });
  test('real combined episode suffixes do not become work title digits', () {
    final cases = {
      '[Kagura] Urusei Yatsura - 001&002 [BDRip 1280x960 x264 Hi10P FLAC].mkv': 'Urusei Yatsura',
      '[Yousei-raws] Gintama 001-002 [DVDrip 760x576 x264 FLAC].mkv': 'Gintama',
      '[G] Animation 12 - 01.mkv': 'Animation 12',
      '[G] 22／7 - 01.mkv': '22／7',
      '[G] NIGHT HEAD 2041 - 01.mkv': 'NIGHT HEAD 2041',
      '[Shiniori-Raws] R-15 - 01 (BD 1920x1080 x265 10bit FLAC).mkv': 'R-15',
      '[SweetSub&LoliHouse] Fujimoto Tatsuki 17-26 - 01 [WebRip 1080p HEVC-10bit AAC ASSx2].mkv': 'Fujimoto Tatsuki 17-26',
    };
    for (final entry in cases.entries) {
      expect(PersonalMetadataScraper.filenameWork(entry.key)!['title'], entry.value, reason: entry.key);
    }
  });
  // Filename syntax from the private inventory, not asserted provider identities.
  test('bracket title digits cannot outrank a complete episode token', () {
    expect(Catalog.episode('[Nekomoe kissaten][180-kimimimi][01][1080p][JPSC].mp4'), 1);
    expect(Catalog.episode('[VCB-Studio] 2.5-jigen no Ririsa [01][Ma10p_1080p][x265_flac].mkv'), 1);
    expect(Catalog.episode('[LoliHouse] 22／7 - 01 [BDRip 1080p AVC-10bit AAC FLAC].mkv'), 1);
    expect(Catalog.episode('[G] Title [01-02][1080p].mkv'), 1);
    expect(Catalog.episode('[G] Title [02v2][1080p].mkv'), 2);
    expect(Catalog.episode('[G] EIGHTY SIX [17.5(Visual Commentary)][1080p].mkv'), 17);
    expect(Catalog.episode('[G] Title [09 Preview][1080p].mkv'), 9);
  });
  test('numeric title is not a filename release year', () {
    const name = '[AI-Raws] NIGHT HEAD 2041 #00 (BD HEVC 1920x1080 FLAC)[AFC9B2CA].mkv';
    final parsed = PersonalMetadataScraper.filenameWork(name)!;
    expect(parsed['title'], 'NIGHT HEAD 2041');
    expect(parsed['year'], isNull);
    expect(WorkSeason.year(parsed), isNull);
    expect(WorkSeason.year({...parsed, 'year': 2021}), 2021);
    final conflict = PersonalMetadataScraper.filenameWork('Series (2020) (2021) - 01.mkv')!;
    expect(WorkSeason.conflictingYears(conflict), isTrue);
    expect(WorkSeason.year({...conflict, 'year': 2020}), isNull);
    expect(Catalog.episode(name), 0);
    expect(PersonalMetadataScraper.filenameWork('[G] NIGHT HEAD 2041 (2021) - 01.mkv')!['year'], 2021);
    expect(PersonalMetadataScraper.filenameWork('Series (2020) (2021) - 01.mkv')!['year'], isNull);
  });
}
