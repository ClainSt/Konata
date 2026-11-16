import 'package:flutter_test/flutter_test.dart';

import 'package:ccplayer/domain/formatting/media_display_formatter.dart';

void main() {
  group('MediaDisplayFormatter', () {
    test('formatBytes handles empty fallbacks and B/KB/MB/GB/TB boundaries', () {
      expect(MediaDisplayFormatter.formatBytes(null), '');
      expect(MediaDisplayFormatter.formatBytes(0), '');
      expect(
        MediaDisplayFormatter.formatBytes(-5, emptyFallback: '0 B'),
        '0 B',
      );
      expect(MediaDisplayFormatter.formatBytes(512), '512 B');
      expect(MediaDisplayFormatter.formatBytes(2048), '2 KB');
      expect(MediaDisplayFormatter.formatBytes(100 * 1024 * 1024), '100.0 MB');
      expect(
        MediaDisplayFormatter.formatBytes(2 * 1024 * 1024 * 1024),
        '2.00 GB',
      );
      expect(
        MediaDisplayFormatter.formatBytes(3 * 1024 * 1024 * 1024 * 1024),
        '3.00 TB',
      );
    });

    test('fileExtensionUpper extracts upper-case suffix safely', () {
      expect(MediaDisplayFormatter.fileExtensionUpper('track01.flac'), 'FLAC');
      expect(
        MediaDisplayFormatter.fileExtensionUpper('booklet.001.webp'),
        'WEBP',
      );
      expect(MediaDisplayFormatter.fileExtensionUpper('README'), '');
      expect(MediaDisplayFormatter.fileExtensionUpper('.hidden'), '');
      expect(MediaDisplayFormatter.fileExtensionUpper('trailing.'), '');
    });

    test('formatDateTimeMinute formats zero-padded timestamp', () {
      expect(
        MediaDisplayFormatter.formatDateTimeMinute(
          DateTime(2026, 4, 5, 7, 9),
        ),
        '2026-04-05 07:09',
      );
    });

    test('formatWrappableFileName inserts break opportunities for dense BDRip names', () {
      expect(
        MediaDisplayFormatter.formatWrappableFileName('Episode 01.mkv'),
        'Episode 01.mkv',
      );
      expect(
        MediaDisplayFormatter.formatWrappableFileName('short_name.mkv'),
        'short_\u200Bname.\u200Bmkv',
      );
      expect(
        MediaDisplayFormatter.formatWrappableFileName(
          '[SubGroup][AnimeName][01][BDRIP_1080P_HEVC].mkv',
        ),
        '[SubGroup]\u200B[AnimeName]\u200B[01]\u200B[BDRIP_\u200B1080P_\u200BHEVC].\u200Bmkv',
      );
    });
  });
}
