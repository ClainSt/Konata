import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:ccplayer/core/subtitle_choices.dart';
import 'package:ccplayer/core/track_preferences.dart';

void main() {
  test(
    'loaded external track merges with sidecar while retaining active ID',
    () {
      final choices = SubtitleChoices.merge(
        [
          SubtitleTrack.auto(),
          SubtitleTrack.no(),
          const SubtitleTrack('5', 'Episode.chs.ass', 'zho', codec: 'ass'),
        ],
        [
          SubtitleTrack.uri('http://localhost/token', title: 'Episode.chs.ass'),
          SubtitleTrack.uri('http://localhost/other', title: 'Episode.cht.ssa'),
        ],
        {
          '5': {
            'external': 'yes',
            'external-filename': 'http://localhost/token',
          },
        },
      );
      expect(choices.length, 2);
      expect(choices.first.track.id, '5');
      expect(
        choices.first.aliases,
        containsAll(['5', 'http://localhost/token']),
      );
      expect(choices.first.external, true);
      expect(choices.first.format, 'ass');
      expect(choices.last.format, 'ssa');
    },
  );
  test(
    'muxed subtitles are kept; format aliases and bilingual markers resolve',
    () {
      final choices = SubtitleChoices.merge(
        [const SubtitleTrack('1', 'SC', 'zh-Hans', codec: 'subrip')],
        [],
        {},
      );
      expect(choices.single.external, false);
      expect(choices.single.format, 'srt');
      expect(SubtitleChoices.format('ass', 'external.ssa'), 'ssa');
      expect(
        TrackPreferences.subtitleLanguage(null, 'Show.CHS_JPN.ass'),
        SubtitleLanguage.simplified,
      );
      expect(
        TrackPreferences.subtitleLanguage(null, '繁日双语'),
        SubtitleLanguage.traditional,
      );
    },
  );
}
