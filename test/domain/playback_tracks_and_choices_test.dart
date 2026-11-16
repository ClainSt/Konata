import 'package:flutter_test/flutter_test.dart';

import 'package:ccplayer/domain/models/episode.dart';
import 'package:ccplayer/domain/playback/playback_formatters.dart';
import 'package:ccplayer/domain/playback/subtitle_and_audio_choices.dart';
import 'package:ccplayer/domain/playback/track_preferences.dart';
import 'package:ccplayer/domain/playback/watched_tracker.dart';

void main() {
  group('TrackPreferences 与 CrossEpisodeTrackMemory 测试', () {
    const prefs = TrackPreferences();

    test('优先选择日语无损原声音轨且降权评论副音轨', () {
      const tracks = [
        MpvTrackInfo(
          id: 1,
          type: MpvTrackType.audio,
          lang: 'eng',
          title: 'English Dub',
          codec: 'aac',
          isDefault: true,
        ),
        MpvTrackInfo(
          id: 2,
          type: MpvTrackType.audio,
          lang: 'jpn',
          title: 'Main Japanese 2.0',
          codec: 'flac',
        ),
        MpvTrackInfo(
          id: 3,
          type: MpvTrackType.audio,
          lang: 'jpn',
          title: 'Staff Commentary 副音轨',
          codec: 'aac',
        ),
      ];

      final picked = prefs.pickBestAudioTrack(tracks);
      expect(picked?.id, equals(2));
    });

    test('简中 ASS 外挂/内封字幕优先于繁中、纯标题符号轨与英文字幕', () {
      const tracks = [
        MpvTrackInfo(
          id: 1,
          type: MpvTrackType.subtitle,
          lang: 'eng',
          title: 'Signs & Songs',
          codec: 'ass',
          isDefault: true,
        ),
        MpvTrackInfo(
          id: 2,
          type: MpvTrackType.subtitle,
          lang: 'cht',
          title: 'SweetSub 繁日雙語',
          codec: 'ass',
        ),
        MpvTrackInfo(
          id: 3,
          type: MpvTrackType.subtitle,
          lang: 'chs',
          title: 'SweetSub 简日双语',
          codec: 'ass',
          isExternal: true,
        ),
      ];

      final picked = prefs.pickBestSubtitleTrack(tracks);
      expect(picked?.id, equals(3));
    });

    test('CrossEpisodeTrackMemory 精准继承跨话手动音轨/字幕选择与关闭记忆', () {
      const memory = CrossEpisodeTrackMemory();
      final remember = memory
          .rememberAudio(
            const MpvTrackInfo(
              id: 4,
              type: MpvTrackType.audio,
              lang: 'chi',
              title: '国语配音',
              codec: 'aac',
            ),
          )
          .rememberSubtitle(
            const MpvTrackInfo(
              id: 5,
              type: MpvTrackType.subtitle,
              lang: 'cht',
              title: '桜都字幕组 繁中',
              codec: 'ass',
              isExternal: true,
            ),
          );

      const nextEpTracks = [
        MpvTrackInfo(
          id: 1,
          type: MpvTrackType.audio,
          lang: 'jpn',
          title: 'Japanese',
          codec: 'flac',
        ),
        MpvTrackInfo(
          id: 2,
          type: MpvTrackType.audio,
          lang: 'chi',
          title: '国语配音',
          codec: 'aac',
        ),
        MpvTrackInfo(
          id: 3,
          type: MpvTrackType.subtitle,
          lang: 'chs',
          title: '简体',
          codec: 'srt',
        ),
        MpvTrackInfo(
          id: 4,
          type: MpvTrackType.subtitle,
          lang: 'cht',
          title: '桜都字幕组 繁中',
          codec: 'ass',
          isExternal: true,
        ),
      ];

      expect(remember.resolveAudioTrack(nextEpTracks)?.id, equals(2));
      expect(remember.resolveSubtitleTrack(nextEpTracks)?.id, equals(4));

      final disabledMem = remember.rememberSubtitle(null);
      expect(disabledMem.resolveSubtitleTrack(nextEpTracks), isNull);
    });
  });

  group('SubtitleAndAudioChoices 外挂音轨匹配测试', () {
    test('按同目录及 Audio/ 子目录精准匹配同主干名 .mka / .flac 音轨', () {
      final matched = SubtitleAndAudioChoices.findMatchingExternalAudioPaths(
        videoRelativePath: 'Season 1/[VCB] Show [01].mkv',
        candidatePaths: const [
          'Season 1/[VCB] Show [01].mka',
          'Season 1/Audio/[VCB] Show [01].Commentary.flac',
          'Season 1/[VCB] Show [02].mka',
          'Season 1/[VCB] Show [01].sc.ass',
          'Season 2/[VCB] Show [01].mka',
        ],
      );

      expect(matched, hasLength(2));
      expect(matched, contains('Season 1/[VCB] Show [01].mka'));
      expect(matched, contains('Season 1/Audio/[VCB] Show [01].Commentary.flac'));
    });
  });

  group('WatchedTracker 观看区间追踪与 PlaybackFormatters 测试', () {
    test('拖拽跳段不计入有效观看区间，累计达到阈值判定完播，结尾 1% 复位续播位置', () {
      var nowMs = 0;
      final tracker = WatchedTracker(
        monotonicClockMs: () => nowMs,
        completionThreshold: 0.85,
      );

      // 连续观看 0s -> 90s（每步 1s）
      for (var t = 0; t <= 90; t++) {
        tracker.sample(
          positionSeconds: t.toDouble(),
          durationSeconds: 100.0,
          isPlaying: true,
        );
        nowMs += 1000;
      }
      expect(tracker.isCompleted(100.0), isTrue);
      expect(tracker.watchedRatio(100.0), greaterThanOrEqualTo(0.85));

      // 另设追踪器验证快进跳转不累加中间空段
      nowMs = 0;
      final seekTracker = WatchedTracker(monotonicClockMs: () => nowMs);
      seekTracker.sample(
        positionSeconds: 0.0,
        durationSeconds: 100.0,
        isPlaying: true,
      );
      nowMs += 1000;
      seekTracker.sample(
        positionSeconds: 1.0,
        durationSeconds: 100.0,
        isPlaying: true,
      );
      // 用户直接拖拽到 99.5s（最后 1%）
      seekTracker.notifySeek();
      nowMs += 1000;
      seekTracker.sample(
        positionSeconds: 99.5,
        durationSeconds: 100.0,
        isPlaying: true,
      );
      expect(seekTracker.isCompleted(100.0), isFalse);
      expect(
        seekTracker.resolvePersistedPositionSeconds(
          positionSeconds: 99.5,
          durationSeconds: 100.0,
        ),
        equals(0),
      );
    });

    test('PlaybackFormatters 时长、码率与采样率统一格式化', () {
      expect(PlaybackFormatters.formatMediaDuration(75), equals('01:15'));
      expect(PlaybackFormatters.formatMediaDuration(3665), equals('01:01:05'));
      expect(PlaybackFormatters.formatBitrate(12500000), equals('12.5 Mbps'));
      expect(PlaybackFormatters.formatSampleRate(44100), equals('44.1 kHz'));
      expect(PlaybackFormatters.formatSampleRate(96000), equals('96 kHz'));
      expect(PlaybackFormatters.formatCacheBytes(15 * 1024 * 1024), equals('15.0 MB'));
    });
  });

  group('字幕语言语义提炼与选集正片置顶排序测试', () {
    test('准确识别 sc/tc/jp/en/chs/cht/jpsc/jptc 及 comment/sign/字幕组并免疫 % 异常文件名', () {
      final merged = SubtitleAndAudioChoices.mergeSubtitles(
        mpvTracks: const [
          MpvTrackInfo(
            id: 1,
            type: MpvTrackType.subtitle,
            lang: 'chi',
            title: '[SweetSub] 简日双语',
            codec: 'ass',
            selected: true,
          ),
          MpvTrackInfo(
            id: 2,
            type: MpvTrackType.subtitle,
            lang: 'eng',
            title: 'Commentary',
            codec: 'ass',
          ),
        ],
        discoveredExternalPaths: const [
          'D:/Anime/[SweetSub] Frieren [01].jpsc.ass',
          'D:/Anime/[ANi] Frieren [01].jptc.ass',
          'D:/Anime/[VCB-Studio] Frieren [01].chs_jpn.ass',
          'D:/Anime/[LoliHouse] Frieren [01].jpn_cht.ass',
          'D:/Anime/[Nekomoe] Frieren [01].sc.ass',
          'D:/Anime/[KTXP] Frieren [01].tc.srt',
          'D:/Anime/[Raw] Frieren [01].jpn.ass',
          'D:/Anime/[SubGroup] Frieren [01].sign.en.ass',
          'D:/Anime/[Group] 100% Paschal [01].zh-hans.ass',
        ],
      );

      expect(merged.first.sourceFormatBadge, equals('内封 ASS'));
      expect(merged.first.primaryTitle, contains('简日双语'));
      expect(merged.first.primaryTitle, contains('SweetSub'));
      expect(merged.first.selected, isTrue);

      final byPath = {
        for (final c in merged)
          if (c.externalPath != null) c.externalPath!: c,
      };
      expect(byPath['D:/Anime/[SweetSub] Frieren [01].jpsc.ass']!.primaryTitle, equals('简日双语 · SweetSub'));
      expect(byPath['D:/Anime/[SweetSub] Frieren [01].jpsc.ass']!.sourceFormatBadge, equals('外挂 ASS'));
      expect(byPath['D:/Anime/[SweetSub] Frieren [01].jpsc.ass']!.rawTooltip, equals('[SweetSub] Frieren [01].jpsc.ass'));
      expect(byPath['D:/Anime/[ANi] Frieren [01].jptc.ass']!.primaryTitle, equals('繁日双语 · ANi'));
      expect(byPath['D:/Anime/[VCB-Studio] Frieren [01].chs_jpn.ass']!.primaryTitle, equals('简日双语 · VCB-Studio'));
      expect(byPath['D:/Anime/[LoliHouse] Frieren [01].jpn_cht.ass']!.primaryTitle, equals('繁日双语 · LoliHouse'));
      expect(byPath['D:/Anime/[Nekomoe] Frieren [01].sc.ass']!.primaryTitle, equals('简体中文 · Nekomoe'));
      expect(byPath['D:/Anime/[KTXP] Frieren [01].tc.srt']!.primaryTitle, equals('繁体中文 · KTXP'));
      expect(byPath['D:/Anime/[KTXP] Frieren [01].tc.srt']!.sourceFormatBadge, equals('外挂 SRT'));
      expect(byPath['D:/Anime/[Raw] Frieren [01].jpn.ass']!.primaryTitle, equals('日语 · Raw'));
      expect(byPath['D:/Anime/[SubGroup] Frieren [01].sign.en.ass']!.primaryTitle, equals('英语 · 屏幕字 · SubGroup'));
      expect(byPath['D:/Anime/[Group] 100% Paschal [01].zh-hans.ass']!.primaryTitle, equals('简体中文 · Group'));

      final commTrack = merged.firstWhere((c) => c.mpvTrackId == 2);
      expect(commTrack.primaryTitle, equals('英语 · 评论'));
    });

    test('Episode.sortMainFirst 强制所有正片按季与集号升序置顶，特典置于正片之后', () {
      const episodes = [
        Episode(
          id: 'sp_pv',
          workId: 'w1',
          seasonNumber: 0,
          episodeNumber: 1,
          title: 'Character PV',
          category: EpisodeCategory.extra,
          extraType: ExtraKind.pv,
        ),
        Episode(
          id: 'ep_02',
          workId: 'w1',
          seasonNumber: 1,
          episodeNumber: 2,
          category: EpisodeCategory.main,
        ),
        Episode(
          id: 'sp_nced',
          workId: 'w1',
          seasonNumber: 0,
          episodeNumber: 2,
          title: 'NCED',
          category: EpisodeCategory.extra,
          extraType: ExtraKind.nced,
        ),
        Episode(
          id: 'ep_01',
          workId: 'w1',
          seasonNumber: 1,
          episodeNumber: 1,
          category: EpisodeCategory.main,
        ),
        Episode(
          id: 'sp_menu',
          workId: 'w1',
          seasonNumber: 0,
          episodeNumber: 3,
          title: 'MENU',
          category: EpisodeCategory.extra,
          extraType: ExtraKind.menu,
        ),
      ];

      final sorted = Episode.sortMainFirst(episodes);
      expect(
        sorted.map((e) => e.id).toList(),
        equals(['ep_01', 'ep_02', 'sp_nced', 'sp_pv', 'sp_menu']),
      );
      expect(sorted.take(2).every((e) => e.category == EpisodeCategory.main), isTrue);
      expect(sorted.skip(2).every((e) => e.category == EpisodeCategory.extra), isTrue);
    });
  });
}
