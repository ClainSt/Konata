import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ccplayer/application/playback/audio_playback_notifier.dart';
import 'package:ccplayer/domain/lyrics/lyric_candidate.dart';
import 'package:ccplayer/domain/lyrics/lyric_candidate_scorer.dart';
import 'package:ccplayer/domain/lyrics/lyric_search_query.dart';
import 'package:ccplayer/domain/playback/audiophile_safety_policy.dart';
import 'package:ccplayer/domain/playback/cue_and_lrc_parser.dart';
import 'package:ccplayer/domain/playback/cue_variant_resolver.dart';
import 'package:ccplayer/domain/playback/lyric_version_matcher.dart';
import 'package:ccplayer/domain/playback/playback_probe_stats.dart';
import 'package:ccplayer/domain/playback/track_preferences.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/infrastructure/players/libmpv_ffi.dart';
import 'package:ccplayer/infrastructure/players/mpv_ipc_tracker.dart';
import 'package:ccplayer/infrastructure/players/mpv_quality_profile.dart';
import 'package:ccplayer/presentation/theme/konata_theme.dart';
import 'package:ccplayer/presentation/widgets/playback/konata_cached_artwork_backdrop.dart';

class _RecordingAudioMpvClient implements LibMpvClient {
  final Map<String, String> properties = {};
  final List<({String name, String value})> writes = [];
  final StreamController<MpvClientEvent> _events =
      StreamController<MpvClientEvent>.broadcast();

  @override
  int get handleAddress => 0;

  @override
  bool get isInitialized => true;

  @override
  bool get isDisposed => false;

  @override
  String errorString(int code) => 'ok($code)';

  @override
  int setOptionString(String name, String value) {
    properties[name] = value;
    return 0;
  }

  @override
  int initialize() => 0;

  @override
  int setPropertyString(String name, String value) {
    properties[name] = value;
    writes.add((name: name, value: value));
    return 0;
  }

  @override
  int setPropertyFlag(String name, bool value) => 0;

  @override
  int setPropertyInt64(String name, int value) => 0;

  @override
  int setPropertyDouble(String name, double value) => 0;

  @override
  String? getPropertyString(String name) => properties[name];

  @override
  bool? getPropertyFlag(String name) => false;

  @override
  int? getPropertyInt64(String name) => null;

  @override
  double? getPropertyDouble(String name) => null;

  @override
  List<MpvTrackInfo> readTrackList() => const [];

  @override
  List<PlaybackChapter> readChapterList({double? totalDurationSeconds}) =>
      const [];

  @override
  List<MpvAudioDevice> readAudioDeviceList() => const [];

  @override
  List<MpvSeekableRange> readDemuxerSeekableRanges() => const [];

  @override
  int observeProperty(int replyUserdata, String name, int format) => 0;

  @override
  int requestLogMessages(String minLevel) => 0;

  @override
  int command(List<String> args) => 0;

  @override
  int commandAsync(int replyUserdata, List<String> args) => command(args);

  @override
  Stream<MpvClientEvent> get events => _events.stream;

  @override
  Future<void> dispose() async {
    await _events.close();
  }
}

void main() {
  group('Step 6.1 整数光盘扇区单流 CUE、越权 FILE 拦截与高精度外部启动定位', () {
    test('CUE 全程保留整数光盘扇区（1/75s）并拦截越权路径穿越/盘符/UNC', () {
      const cue = '''
PERFORMER "Evan Call"
TITLE "Frieren OST"
FILE "Disc1.flac" WAVE
  TRACK 01 AUDIO
    TITLE "Track 1"
    INDEX 01 00:00:00
  TRACK 02 AUDIO
    TITLE "Track 2"
    INDEX 00 03:10:15
    INDEX 01 03:12:37
  TRACK 03 AUDIO
    TITLE "Track 3"
    INDEX 01 06:00:74
''';
      final sheet = CueParser.parseText(cue, totalDurationSeconds: 500.0);
      expect(sheet.rejectedUnsafeFileCount, equals(0));
      expect(sheet.tracks, hasLength(3));

      // 验证整数光盘扇区零舍入误差：03:12:37 -> (3*60+12)*75+37 = 14437
      expect(sheet.tracks[0].startSectorFrames, equals(0));
      expect(sheet.tracks[0].endSectorFrames, equals((3 * 60 + 10) * 75 + 15));
      expect(sheet.tracks[1].startSectorFrames, equals(14437));
      expect(sheet.tracks[1].startSeconds, closeTo(14437 / 75.0, 1e-12));
      expect(sheet.tracks[1].endSectorFrames, equals(6 * 60 * 75 + 74));

      // 外部 MPV 启动参数精确携带分数秒 --start=+192.493，严禁 .round() 整秒截断。
      final args = MpvIpcTracker.buildLaunchArguments(
        targetUrlOrPath: 'D:/Music/Disc1.flac',
        pipePath: r'\\.\pipe\konata_test',
        startSeconds: sheet.tracks[1].startSeconds.floor(),
        exactStartSeconds: sheet.tracks[1].startSeconds,
      );
      expect(args, contains('--start=+192.493'));

      // 恶意越权 FILE 路径（../、绝对路径、Windows 盘符、UNC）全部拦截。
      const unsafeCue = '''
FILE "../../secret.flac" WAVE
  TRACK 01 AUDIO
    TITLE "Escape1"
    INDEX 01 00:00:00
FILE "C:\\Windows\\system.ini" WAVE
  TRACK 02 AUDIO
    TITLE "Escape2"
    INDEX 01 00:00:00
FILE "\\\\evil-host\\share\\x.flac" WAVE
  TRACK 03 AUDIO
    TITLE "Escape3"
    INDEX 01 00:00:00
''';
      final blocked = CueParser.parseText(unsafeCue);
      expect(blocked.rejectedUnsafeFileCount, equals(3));
      expect(blocked.tracks, isEmpty);

      // CueVariantResolver 同步拒绝带盘符的越权 FILE 引用。
      final dummyCue = MediaVariant(
        id: 'v_cue',
        workId: 'w1',
        sourceId: 's1',
        relativePath: 'CD/Disc.cue',
        fileName: 'Disc.cue',
        fileSize: 100,
        assetKind: AssetKind.cdAlbum,
      );
      final badTrack = CueTrack(
        trackNumber: 1,
        title: 'Bad',
        fileName: r'D:\Outside\secret.flac',
        startSectorFrames: 0,
      );
      expect(
        CueVariantResolver.resolve(
          cueVariant: dummyCue,
          cueTrack: badTrack,
          audioVariantsInDir: const [],
          fallbackInitial: dummyCue,
        ),
        isNull,
      );
    });
  });

  group('Step 6.2 双无缝队列、ab-loop/end 原子清零与末级 -12 dBFS 防炸耳策略', () {
    test('非直通路径强制施加末级 -12 dBFS 限幅与 150ms S 型微淡入，HDMI spdif 严格互斥软 DSP', () {
      // 1. S 型微淡入单调平滑（起点 0、中点 0.5、终点 1.0）。
      expect(AudiophileSafetyPolicy.sCurveFadeGain(elapsedMs: 0), equals(0.0));
      expect(
        AudiophileSafetyPolicy.sCurveFadeGain(elapsedMs: 75, durationMs: 150),
        closeTo(0.5, 1e-6),
      );
      expect(
        AudiophileSafetyPolicy.sCurveFadeGain(elapsedMs: 150, durationMs: 150),
        equals(1.0),
      );

      // 2. 未获硬件电平仪实证的后端，即使尝试解锁也默认强制锁定关闭满幅档。
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
      expect(sharedPlan.prefetchPlaylist, isTrue);
      expect(sharedPlan.safetyLimiterEngaged, isTrue);
      expect(sharedPlan.microFadeInDurationMs, equals(150));
      expect(
        sharedPlan.audioFilterString,
        endsWith(AudiophileSafetyPolicy.postDspSafetyLimiterFilter),
      );
      expect(
        sharedPlan.audioFilterString,
        startsWith('equalizer=f=60:width_type=q:w=1:g=6,'),
      );
      expect(sharedPlan.fullScaleLockNotice, isNotNull);

      // 3. 已实证后端解锁当次会话后，新插外设必须自动恢复安全衰减起步。
      const verified = AudioDeviceSafetyState(
        deviceFingerprint: 'dac_a',
        isBackendMeterVerified: true,
      );
      final unlocked = verified.confirmSessionFullScaleUnlock();
      expect(unlocked.allowFullScaleBypass, isTrue);
      final bitPerfectPlan = AudiophileSafetyPolicy.buildPlan(
        requestedMode: AudioOutputRouteMode.androidBitPerfectUsb,
        safetyState: unlocked,
      );
      expect(bitPerfectPlan.safetyLimiterEngaged, isFalse);
      expect(bitPerfectPlan.audioFilterString, isEmpty);

      final swappedDevice = unlocked.onDeviceChanged('dac_b_new');
      expect(swappedDevice.allowFullScaleBypass, isFalse);

      // 4. HDMI audio-spdif 与任何软 DSP 严格互斥。
      final spdifPlan = AudiophileSafetyPolicy.buildPlan(
        requestedMode: AudioOutputRouteMode.bitstreamPassthrough,
        safetyState: unverified,
        upstreamDspFilters: const ['equalizer=f=100:g=4'],
      );
      expect(spdifPlan.audioFilterString, isEmpty);
      expect(spdifPlan.audioSpdifCodecs, isNotEmpty);

      // 5. libmpv 底层属性下发与 ab-loop/end 原子清零验证。
      final client = _RecordingAudioMpvClient();
      MpvQualityProfile.applyAudiophileSafetyChain(client, plan: spdifPlan);
      expect(client.properties['gapless-audio'], equals('weak'));
      expect(client.properties['af'], equals(''));
      expect(client.properties['audio-spdif'], equals(spdifPlan.audioSpdifCodecs));

      MpvQualityProfile.resetAudioRangeAndLoopProperties(client);
      expect(client.properties['end'], equals('none'));
      expect(client.properties['ab-loop-a'], equals('no'));
      expect(client.properties['ab-loop-b'], equals('no'));
    });
  });

  group('Step 6.3 版本消歧和声歌词与 0 MB 显存 GPU 径向流光舞台', () {
    test('伴奏先行短路、TV Size/Live 版本时长消歧与 Active Span Set 主唱和声并行扫光', () {
      expect(
        LyricVersionMatcher.isInstrumentalTrack(title: '勇者 (Instrumental)'),
        isTrue,
      );
      expect(
        LyricVersionMatcher.isInstrumentalTrack(
          title: 'アイドル',
          fileName: '04. アイドル - Off Vocal.flac',
        ),
        isTrue,
      );
      expect(LyricVersionMatcher.isInstrumentalTrack(title: '勇者'), isFalse);

      final query = LyricSearchQuery(
        title: '勇者 (TV Size)',
        artist: 'YOASOBI',
        durationSeconds: 90.0,
      );
      LyricCandidate candidate(String id, String title, double duration) {
        return LyricCandidate(
          source: LyricSource.lrclib,
          sourceId: id,
          title: title,
          artist: 'YOASOBI',
          durationSeconds: duration,
          lrcContent:
              '[00:01.00]$title ライン一\n[00:05.00]$title ライン二\n[00:10.00]$title ライン三',
        );
      }

      final scored = <String, double?>{
        for (final c in [
          candidate('full', '勇者 (Full Ver.)', 194.0),
          candidate('live', '勇者 (Live)', 92.0),
          candidate('tv', '勇者 (TV Size)', 89.5),
        ])
          c.sourceId: LyricCandidateScorer.score(query, c),
      };
      // Full 版时长差超过 25 秒直接淘汰；Live 版因版本冲突被重罚；TV Size 胜出并达到自动采用阈值。
      expect(scored['full'], isNull);
      expect(scored['tv']!, greaterThan(scored['live']!));
      expect(scored['tv']!, greaterThanOrEqualTo(LyricMatchThresholds.autoAccept));
      expect(scored['live']!, lessThan(LyricMatchThresholds.autoAccept));

      // Active Span Set：同一时刻主唱与和声并行激活且各自计算独立扫光进度。
      const duetLrc = '''
[00:10.00]<00:10.00>光<00:10.80>の<00:11.60>旅
[00:10.00]bg:<00:10.20>Ah~<00:11.20>La~
''';
      final lines = LyricVersionMatcher.parseActiveSpanLines(duetLrc);
      expect(lines, hasLength(1));
      final activeAt105 = lines.first.activeSpansAt(10.5);
      expect(activeAt105, hasLength(2));
      expect(activeAt105.any((s) => !s.isHarmony && s.text == '光'), isTrue);
      expect(activeAt105.any((s) => s.isHarmony && s.text == 'Ah~'), isTrue);
      final leadSpan = activeAt105.firstWhere((s) => !s.isHarmony);
      expect(leadSpan.sweepProgressAt(10.4), closeTo(0.5, 1e-6));
    });

    testWidgets('KonataCachedArtworkBackdrop 使用纯 GPU CustomPaint 径向着色场，0 模糊位图且 800ms 后停钟', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: KonataTheme.darkTheme(),
            home: const Scaffold(
              body: SizedBox(
                width: 400,
                height: 300,
                child: KonataCachedArtworkBackdrop(
                  cover: EmptyAudioCover(),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 确认无离屏模糊 RawImage / ImageFiltered，且由 CustomPaint 渲染径向着色场。
      expect(find.byType(RawImage), findsNothing);
      expect(find.byType(ImageFiltered), findsNothing);
      expect(
        find.descendant(
          of: find.byType(KonataCachedArtworkBackdrop),
          matching: find.byType(CustomPaint),
        ),
        findsOneWidget,
      );
      // 有限 800ms 过渡到位后立即停钟，零闲置常驻 Ticker。
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  });
}
