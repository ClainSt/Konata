import 'dart:convert';
import 'dart:typed_data';

import 'package:engine_playback/engine_playback.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';
import 'package:test/test.dart';

void main() {
  group('HwdecSafetyPolicy Hi10P 与 HEVC Rext 拦截策略', () {
    test('精确拦截 AVC Hi10P 与 HEVC Rext / 12-bit，放行标准 8/10-bit 4:2:0', () {
      final hi10Android = HwdecSafetyPolicy.evaluate(
        platform: HwdecPlatformKind.android,
        videoCodec: 'h264',
        videoProfile: 'High 10',
        pixelFormat: 'yuv420p10le',
      );
      expect(hi10Android.allowHardwareDecode, isFalse);
      expect(hi10Android.matchedRule, equals('avc_hi10p'));

      final hevcRextAndroid = HwdecSafetyPolicy.evaluate(
        platform: HwdecPlatformKind.android,
        videoCodec: 'hevc',
        videoProfile: 'Rext',
        pixelFormat: 'yuv422p10le',
      );
      expect(hevcRextAndroid.allowHardwareDecode, isFalse);
      expect(hevcRextAndroid.matchedRule, equals('hevc_rext_android'));

      final hevcMain10Android = HwdecSafetyPolicy.evaluate(
        platform: HwdecPlatformKind.android,
        videoCodec: 'hevc',
        videoProfile: 'Main 10',
        pixelFormat: 'yuv420p10le',
      );
      expect(hevcMain10Android.allowHardwareDecode, isTrue);

      final h264Part10Desc = HwdecSafetyPolicy.evaluate(
        platform: HwdecPlatformKind.windows,
        videoCodec: 'h264 (H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10)',
        videoProfile: 'h264 (H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10)',
        pixelFormat: 'yuv420p',
      );
      expect(h264Part10Desc.allowHardwareDecode, isTrue);

      final hevc12Win = HwdecSafetyPolicy.evaluate(
        platform: HwdecPlatformKind.windows,
        videoCodec: 'hevc',
        videoProfile: 'Main 12',
        pixelFormat: 'yuv420p12le',
      );
      expect(hevc12Win.allowHardwareDecode, isFalse);
      expect(hevc12Win.matchedRule, equals('hevc_gt10bit'));

      final preloadHi10 = HwdecSafetyPolicy.evaluateVariantMetadata(
        platform: HwdecPlatformKind.windows,
        videoCodec: 'H264',
        bitDepth: '10bit',
      );
      expect(preloadHi10.allowHardwareDecode, isFalse);
    });
  });

  group('AudiophileSafetyPolicy 发烧音频安全链策略', () {
    test('未实证外设锁定 -12 dBFS（25.0%）、支持 S 型微淡入与 HDMI DSP 互斥', () {
      expect(AudiophileSafetyPolicy.sCurveFadeGain(elapsedMs: 0), equals(0.0));
      expect(
        AudiophileSafetyPolicy.sCurveFadeGain(elapsedMs: 75, durationMs: 150),
        closeTo(0.5, 1e-6),
      );
      expect(
        AudiophileSafetyPolicy.sCurveFadeGain(elapsedMs: 150, durationMs: 150),
        equals(1.0),
      );

      const unverified = AudioDeviceSafetyState(
        deviceFingerprint: 'usb_dac_1',
        isBackendMeterVerified: false,
      );
      final attemptedUnlock = unverified.confirmSessionFullScaleUnlock();
      expect(attemptedUnlock.allowFullScaleBypass, isFalse);

      final sharedPlan = AudiophileSafetyPolicy.buildPlan(
        requestedMode: AudioOutputRouteMode.sharedResampled,
        safetyState: attemptedUnlock,
        upstreamDspFilters: const ['equalizer=f=60:width_type=q:w=1:g=6'],
      );
      expect(sharedPlan.gaplessAudioMode, equals('weak'));
      expect(AudiophileSafetyPolicy.safetyCeilingDbfs, equals(-12.0));
      expect(AudiophileSafetyPolicy.safetyCeilingLinear, equals(0.251));
      expect(sharedPlan.safetyLimiterEngaged, isTrue);
      expect(
        sharedPlan.audioFilterString,
        endsWith(AudiophileSafetyPolicy.postDspSafetyLimiterFilter),
      );
      expect(
        sharedPlan.audioFilterString,
        startsWith('equalizer=f=60:width_type=q:w=1:g=6,'),
      );
      expect(sharedPlan.fullScaleLockNotice, isNotNull);

      const verified = AudioDeviceSafetyState(
        deviceFingerprint: 'dac_a',
        isBackendMeterVerified: true,
      );
      final unlocked = verified.confirmSessionFullScaleUnlock();
      expect(unlocked.allowFullScaleBypass, isTrue);
      final swapped = unlocked.onDeviceChanged('dac_b_new');
      expect(swapped.allowFullScaleBypass, isFalse);

      final spdifPlan = AudiophileSafetyPolicy.buildPlan(
        requestedMode: AudioOutputRouteMode.bitstreamPassthrough,
        safetyState: unverified,
        upstreamDspFilters: const ['equalizer=f=100:g=4'],
      );
      expect(spdifPlan.audioFilterString, isEmpty);
      expect(spdifPlan.audioSpdifCodecs, isNotEmpty);
    });
  });

  group('CueParser、LrcParser 与 CueVariantResolver 领域核心测试', () {
    test('精准解析 CUE 整数光盘扇区（1/75s）并拦截越权路径穿越', () {
      const cueContent = '''
PERFORMER "Evan Call"
TITLE "Frieren Original Soundtrack Disc 1"
FILE "Disc1.flac" WAVE
  TRACK 01 AUDIO
    TITLE "Journey of a Lifetime"
    PERFORMER "Evan Call"
    INDEX 01 00:00:00
  TRACK 02 AUDIO
    TITLE "The End of One Journey"
    INDEX 00 03:10:00
    INDEX 01 03:12:37
  TRACK 03 AUDIO
    TITLE "Zoltraak"
    INDEX 01 06:00:00
''';
      final bytes = Uint8List.fromList([
        0xEF,
        0xBB,
        0xBF,
        ...utf8.encode(cueContent),
      ]);
      final sheet = CueParser.parseBytes(bytes, totalDurationSeconds: 540.0);

      expect(sheet.title, equals('Frieren Original Soundtrack Disc 1'));
      expect(sheet.tracks, hasLength(3));
      expect(sheet.tracks[1].startSectorFrames, equals((3 * 60 + 12) * 75 + 37));
      expect(sheet.tracks[1].startSeconds, closeTo(192.493, 0.01));
      expect(sheet.tracks[2].endSeconds, closeTo(540.0, 0.001));

      expect(CueTrack.isSafeRelativeFileReference('../secret.flac'), isFalse);
      expect(CueTrack.isSafeRelativeFileReference(r'C:\audio.flac'), isFalse);
      expect(
        CueTrack.isSafeRelativeFileReference(r'\\server\share\a.flac'),
        isFalse,
      );
      expect(CueTrack.isSafeRelativeFileReference('Disc1.flac'), isTrue);
    });

    test('LrcParser 合并同时间戳原文与翻译，支持 [offset:] 偏移与二分高亮查找', () {
      const lrc = '''
[ti:勇者]
[ar:YOASOBI]
[al:THE BOOK]
[offset:500]
[00:10.00]まるで御伽の話
[00:10.00]宛如童话般的故事
[00:20.00][01:05.50]終わらない旅
''';
      final doc = LrcParser.parseText(lrc);
      expect(doc.title, equals('勇者'));
      expect(doc.offsetMillis, equals(500));
      expect(doc.lines, hasLength(3));
      expect(doc.lines[0].startSeconds, closeTo(9.5, 0.001));
      expect(doc.lines[0].secondaryLines, equals(['宛如童话般的故事']));
      expect(doc.activeIndexAt(5.0), equals(-1));
      expect(doc.activeIndexAt(15.0), equals(0));
      expect(doc.activeIndexAt(70.0), equals(2));
    });

    test('CueVariantResolver 正确映射物理 FLAC 并拒绝多音频无匹配回落', () {
      const cue = MediaVariantRecord(
        id: VariantId.trusted('cue-1'),
        workId: WorkId.trusted('accel'),
        sourceId: SourceId.trusted('dav'),
        relativePath: '加速世界/CDs/01/album.cue',
        fileName: 'album.cue',
        fileSize: 400,
        assetKind: AssetKind.cdAlbum,
      );
      const flac = MediaVariantRecord(
        id: VariantId.trusted('flac-1'),
        workId: WorkId.trusted('accel'),
        sourceId: SourceId.trusted('dav'),
        relativePath: '加速世界/CDs/01/ドラマ CD.flac',
        fileName: 'ドラマ CD.flac',
        fileSize: 300000000,
        assetKind: AssetKind.cdAlbum,
      );
      const extra = MediaVariantRecord(
        id: VariantId.trusted('flac-2'),
        workId: WorkId.trusted('accel'),
        sourceId: SourceId.trusted('dav'),
        relativePath: '加速世界/CDs/01/another.flac',
        fileName: 'another.flac',
        fileSize: 10000,
        assetKind: AssetKind.cdAlbum,
      );

      expect(
        CueVariantResolver.resolve(
          cueVariant: cue,
          cueTrack: const CueTrack(
            trackNumber: 1,
            title: 'Track 1',
            fileName: r'subfolder\\ドラマ CD.flac',
          ),
          audioVariantsInDir: const [flac],
          fallbackInitial: cue,
        )?.id,
        equals(flac.id),
      );

      expect(
        CueVariantResolver.resolve(
          cueVariant: cue,
          cueTrack: const CueTrack(
            trackNumber: 1,
            title: 'Missing',
            fileName: 'missing.flac',
          ),
          audioVariantsInDir: const [flac, extra],
          fallbackInitial: cue,
        ),
        isNull,
      );
    });
  });

  group('ChapterSkipAnalyzer、WatchedTracker、Timeline 与 Resume 测试', () {
    test('ChapterSkipAnalyzer 精准识别层级一 OP/ED/C-Part 与层级二冷开场避让', () {
      final planWithCPart = ChapterSkipAnalyzer.analyze(
        totalDurationSeconds: 1420.0,
        hasNextEpisode: true,
        rawChapters: const [
          PlaybackChapter(index: 0, title: 'Avant', startSeconds: 0, endSeconds: 70),
          PlaybackChapter(index: 1, title: 'OP', startSeconds: 70, endSeconds: 160),
          PlaybackChapter(index: 2, title: 'Part A', startSeconds: 160, endSeconds: 700),
          PlaybackChapter(index: 3, title: 'Ending', startSeconds: 1290, endSeconds: 1380),
          PlaybackChapter(index: 4, title: 'Next Preview', startSeconds: 1380, endSeconds: 1420),
        ],
      );
      expect(planWithCPart.opening?.kind, equals(SkipActionKind.skipOp));
      expect(planWithCPart.ending?.kind, equals(SkipActionKind.skipEdToCPart));
      expect(planWithCPart.activeWindowAt(95.0)?.label, equals('跳过 OP'));

      const ep02Chapters = [
        PlaybackChapter(index: 0, title: 'Chapter 01', startSeconds: 0.0),
        PlaybackChapter(index: 1, title: 'Chapter 02', startSeconds: 89.006),
        PlaybackChapter(index: 2, title: 'Chapter 03', startSeconds: 179.054),
        PlaybackChapter(index: 3, title: 'Chapter 04', startSeconds: 531.072),
        PlaybackChapter(index: 4, title: 'Chapter 05', startSeconds: 1173.13),
        PlaybackChapter(index: 5, title: 'Chapter 06', startSeconds: 1263.053),
        PlaybackChapter(index: 6, title: 'Chapter 07', startSeconds: 1415.08),
      ];
      final ep02Plan = ChapterSkipAnalyzer.analyze(
        rawChapters: ep02Chapters,
        totalDurationSeconds: 1421.09,
        hasNextEpisode: true,
      );
      expect(ep02Plan.opening, isNull);
      expect(ep02Plan.ending?.startSeconds, closeTo(1173.13, 0.001));
    });

    test('WatchedTracker 区间合并与 PlaybackRecordHelper 完播阈值校验', () {
      var nowMs = 0;
      final tracker = WatchedTracker(
        monotonicClockMs: () => nowMs,
        completionThreshold: 0.90,
      );
      for (var t = 0.0; t <= 10.0; t += 1.0) {
        tracker.sample(
          positionSeconds: t,
          durationSeconds: 20.0,
          isPlaying: true,
        );
        nowMs += 1000;
      }
      expect(tracker.timeline.totalWatchedSeconds, closeTo(10.0, 0.1));
      expect(tracker.isCompleted(20.0), isFalse);

      // 跳过一段（拖拽不计入有效观看时长），随后连续播满达标
      tracker.notifySeek();
      for (var t = 11.0; t <= 19.5; t += 1.0) {
        tracker.sample(
          positionSeconds: t,
          durationSeconds: 20.0,
          isPlaying: true,
        );
        nowMs += 1000;
      }
      expect(tracker.isCompleted(20.0), isTrue);

      expect(
        PlaybackRecordHelper.computeCompleted(
          positionSeconds: 1296,
          durationSeconds: 1440,
        ),
        isTrue,
      );
      expect(
        PlaybackRecordHelper.computeCompleted(
          positionSeconds: 100,
          durationSeconds: 180,
          isAudio: true,
        ),
        isFalse,
      );
    });

    test('PlaybackHistoryTimelineBuilder 与 PlaybackResumeResolver 契约验证', () {
      PlaybackRecordEntity makeRecord({
        required String id,
        required String workId,
        required DateTime playedAt,
        int? episodeNumber = 1,
      }) {
        return PlaybackRecordEntity(
          id: id,
          workId: WorkId(workId),
          episodeId: const EpisodeId.trusted('ep_1'),
          variantId: VariantId('var_$id'),
          seasonNumber: 1,
          episodeNumber: episodeNumber,
          episodeTitle: '第 1 话',
          sourceKind: MediaSourceKind.local,
          playedAtMs: playedAt.toUtc().millisecondsSinceEpoch,
          positionSeconds: 300,
          durationSeconds: 1440,
        );
      }

      final sections = PlaybackHistoryTimelineBuilder.build([
        makeRecord(id: 'r1', workId: 'w1', playedAt: DateTime(2026, 7, 8, 21, 10)),
        makeRecord(
          id: 'r2',
          workId: 'w1',
          episodeNumber: 2,
          playedAt: DateTime(2026, 7, 8, 21, 45),
        ),
        makeRecord(
          id: 'r3',
          workId: 'w2',
          episodeNumber: 12,
          playedAt: DateTime(2026, 7, 10, 17, 52),
        ),
      ]);
      expect(sections, hasLength(2));
      expect(sections.first.dateLabel, equals('2026.07.10'));
      expect(sections.last.works.first.entryCount, equals(2));

      const episodes = [
        EpisodeSummaryView(
          id: EpisodeId.trusted('ep_1'),
          workId: WorkId.trusted('w1'),
          seasonNumber: 1,
          episodeNumber: 1,
          category: EpisodeCategory.main,
        ),
        EpisodeSummaryView(
          id: EpisodeId.trusted('ep_2'),
          workId: WorkId.trusted('w1'),
          seasonNumber: 1,
          episodeNumber: 2,
          category: EpisodeCategory.main,
        ),
      ];
      final plan = PlaybackResumeResolver.resolve(
        episodes: episodes,
        latestPlayback: PlaybackResumeView(
          workId: const WorkId.trusted('w1'),
          episodeId: const EpisodeId.trusted('ep_1'),
          variantId: const VariantId.trusted('v1'),
          positionSeconds: 1400,
          durationSeconds: 1440,
          completed: true,
          playedAtMs: DateTime(2026, 7, 10).millisecondsSinceEpoch,
        ),
      );
      expect(plan?.targetEpisode.id.value, equals('ep_2'));
      expect(plan?.buttonLabel, equals('继续播放'));
    });

    test('TrackPreferences、CrossEpisodeTrackMemory 与 SubtitleAndAudioChoices 语义去重', () {
      const prefs = TrackPreferences();
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
      expect(prefs.pickBestSubtitleTrack(tracks)?.id, equals(3));

      const memory = CrossEpisodeTrackMemory();
      final nextMem = memory.rememberSubtitle(tracks[1]);
      expect(nextMem.resolveSubtitleTrack(tracks)?.id, equals(2));

      final merged = SubtitleAndAudioChoices.mergeSubtitles(
        mpvTracks: const [
          MpvTrackInfo(
            id: 1,
            type: MpvTrackType.subtitle,
            lang: 'chs',
            title: '[SweetSub] 简日双语',
            codec: 'ass',
            selected: true,
          ),
        ],
        discoveredExternalPaths: const [
          'D:/Anime/[SweetSub] Frieren [01].jpsc.ass',
          'D:/Anime/[KTXP] Frieren [01].tc.srt',
        ],
      );
      expect(merged.first.sourceFormatBadge, equals('内封 ASS'));
      expect(merged.last.sourceFormatBadge, equals('外挂 SRT'));
    });
  });
}
