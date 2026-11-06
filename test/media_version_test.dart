import 'package:ccplayer/core/media_version.dart';
import 'package:ccplayer/core/personal_filename_parser.dart';
import 'package:ccplayer/core/personal_scraper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'search keeps bracketed titles and numbers instead of stripping them as groups',
    () {
      for (final entry in {
        '[86] [01][1080p].mkv': '86',
        '【作品名】 S01E01.mkv': '作品名',
        '[91 Days] - 01.mkv': '91 Days',
        '[UHA-WINGS&VCB-Studio] EIGHTY SIX [01][Ma10p_1080p][x265_flac_aac].mkv':
            'EIGHTY SIX',
      }.entries) {
        expect(
          PersonalFilenameParser.extractAnimeTitleKeyword(entry.key),
          entry.value,
        );
      }
      expect(
        PersonalMetadataScraper.titleHints('未命名文件夹', ['[91 Days] - 01.mkv']),
        contains('91 Days'),
      );
    },
  );
  test(
    'BDRip example preserves joint release label without inventing roles',
    () {
      final info = MediaVersion.parse(
        '[UHA-WINGS&VCB-Studio] EIGHTY SIX [01][Ma10p_1080p][x265_flac_aac].mkv',
      );
      expect(info.releaseTags, ['UHA-WINGS&VCB-Studio']);
      expect(info.encoderTags, isEmpty);
      expect(info.subtitleGroups, isEmpty);
      expect(info.resolution, '1080p');
      expect(info.videoCodecs, ['HEVC / x265']);
      expect(info.bitDepth, '10-bit');
      expect(info.audioCodecs, ['FLAC', 'AAC']);
      expect(info.subtitleHints, isEmpty);
    },
  );
  test('explicit roles and suffix group labels remain raw with Unicode', () {
    final info = MediaVersion.parse(
      '作品 [桜字幕组][测试压制组][2160p][HEVC][12bit][HDR10+][DTS-HD MA][CHT][VCB-Studio].mkv',
    );
    expect(info.subtitleGroups, ['桜字幕组']);
    expect(info.encoderTags, ['测试压制组']);
    expect(info.releaseTags, ['VCB-Studio']);
    expect(info.bitDepth, '12-bit');
    expect(info.hdrFormats, ['HDR10+']);
    expect(info.audioCodecs, ['DTS-HD MA']);
    expect(info.subtitleHints, ['繁體字幕標記']);
  });
  test('unknown Unicode groups are retained without assigning a role', () {
    final info = MediaVersion.parse('[未知组][不明團隊] 作品 - 01.mkv');
    expect(info.releaseTags, ['未知组', '不明團隊']);
    expect(info.encoderTags, isEmpty);
    expect(info.subtitleGroups, isEmpty);
  });
  test('bracketed numeric and Japanese titles are not group evidence', () {
    for (final name in [
      '[86] [01][1080p].mkv',
      '【作品名】 S01E01.mkv',
      '[91 Days] - 01.mkv',
      '22-7.mkv',
    ]) {
      final info = MediaVersion.parse(name);
      expect(info.releaseTags, isEmpty, reason: name);
    }
  });
  test('technical leading tags and checksums do not become group labels', () {
    final info = MediaVersion.parse(
      '[1080p] [DEADBEEF] Title [01][AV1][SDR][Opus].mkv',
    );
    expect(info.releaseTags, isEmpty);
    expect(info.videoCodecs, ['AV1']);
    expect(info.hdrFormats, ['SDR']);
    expect(info.audioCodecs, ['Opus']);
  });
  test(
    'Windows paths are parsed using basename only, unknowns stay unknown',
    () {
      final info = MediaVersion.parse(r'D:\[WrongGroup] 2160p\No metadata.mkv');
      expect(info.releaseTags, isEmpty);
      expect(info.resolution, isNull);
      expect(info.videoCodecs, isEmpty);
      expect(MediaVersion.fileSize(null), isNull);
      expect(MediaVersion.fileSize(-1), isNull);
      expect(MediaVersion.fileSize(0), '0 B');
      expect(MediaVersion.fileSize(1073741824), '1.00 GiB');
    },
  );
}
