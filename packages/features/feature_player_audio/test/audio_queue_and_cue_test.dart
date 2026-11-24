import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:engine_playback/engine_playback.dart';
import 'package:feature_player_audio/feature_player_audio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import 'test_fakes.dart';

void main() {
  const sampleCue = '''
PERFORMER "結束バンド"
TITLE "結束バンド (CD)"
FILE "album.flac" WAVE
  TRACK 01 AUDIO
    TITLE "青春コンプレックス"
    INDEX 01 00:00:00
  TRACK 02 AUDIO
    TITLE "ひとりぼっち東京"
    INDEX 01 03:23:00
  TRACK 03 AUDIO
    TITLE "Distortion!!"
    INDEX 01 07:15:00
''';

  group('AudioPlaybackQueueBuilder 纯队列与 CUE 构建测试', () {
    test('支持过滤非 CD 资产、配对整轨 .cue、自动展开虚拟分轨与安全折叠', () {
      final work = makeTestWork();
      final source = makeTestSource();
      final variants = [
        MediaVariantRecord(
          id: VariantId('v_vid'),
          workId: work.id,
          sourceId: source.id,
          relativePath: 'EP01.mkv',
          fileName: 'EP01.mkv',
          fileSize: 1024,
          assetKind: AssetKind.video,
        ),
        makeTestCdVariant(id: 'v_album', relativePath: 'CD/album.flac'),
        makeTestCdVariant(id: 'v_cue', relativePath: 'CD/album.cue'),
        makeTestCdVariant(id: 'v_single', relativePath: 'Disc 2/04. Bonus.flac'),
      ];

      final initialCue = CueParser.parseText(sampleCue);
      final queue = AudioPlaybackQueueBuilder.buildInitialQueue(
        work: work,
        variants: variants,
        sourceById: {source.id.value: source},
        initialVariant: variants[1],
        initialCueSheet: initialCue,
        initialCueTrackIndex: 2,
      );

      // album.flac 配对的 .cue 应被自动展开为 3 条分轨 + 1 条单曲。
      expect(queue.length, 4);
      expect(queue[0].isCueTrack, isTrue);
      expect(queue[0].title, '青春コンプレックス');
      expect(queue[1].cueTrackIndex, 2);
      expect(queue[1].startSeconds, closeTo(203.0, 0.05));
      expect(queue[1].endSeconds, closeTo(435.0, 0.05));
      expect(queue[3].isCueTrack, isFalse);
      expect(queue[3].title, 'Bonus');

      final targetIdx = AudioPlaybackQueueBuilder.resolveTargetQueueIndex(
        queue: queue,
        initialVariant: variants[1],
        initialCueTrackIndex: 2,
      );
      expect(targetIdx, 1);

      final rows = AudioPlaybackQueueBuilder.buildDisplayRows(
        queue: queue,
        currentIndex: targetIdx,
      );
      expect(rows.first.kind, AudioQueueDisplayRowKind.cueHeader);
      expect(
        rows.where((r) => r.kind == AudioQueueDisplayRowKind.cueTrack).length,
        3,
      );

      // 当前正播第 4 首单曲时，可以安全折叠前 3 条 .cue 分轨并修正 currentIndex。
      final collapsed = AudioPlaybackQueueBuilder.collapseCueTracksInQueue(
        queue: queue,
        currentIndex: 3,
        cueRelativePath: 'CD/album.cue',
      );
      expect(collapsed.queue.length, 2);
      expect(collapsed.newCurrentIndex, 1);
      expect(collapsed.queue[0].isCueTrack, isFalse);
      expect(collapsed.queue[0].cueSheetPath, 'CD/album.cue');
    });

    test('随机洗牌播放序始终将当前曲目锁定在首位以防止切歌闪烁', () {
      final order = AudioPlaybackQueueBuilder.buildPlayOrder(
        length: 6,
        currentIndex: 4,
        shuffle: true,
        random: math.Random(42),
      );
      expect(order.length, 6);
      expect(order.first, 4);
      expect(order.toSet().length, 6);
    });
  });

  group('AudioPlaybackController 队列、CUE 无感切轨与连续坏文件熔断测试', () {
    late KonataDatabaseBundle db;
    late ScopedPrefsStore store;
    late UnifiedPlaybackEngine engine;
    late AudiophileSafetyCoordinator safetyCoordinator;
    late List<FakeLibMpvClient> spawnedClients;

    setUp(() {
      db = KonataDatabaseBundle.openInMemory();
      store = ScopedPrefsStore(db.userState);
      engine = UnifiedPlaybackEngine();
      safetyCoordinator = AudiophileSafetyCoordinator(
        engine: engine,
        isWindowsOverride: true,
      );
      spawnedClients = <FakeLibMpvClient>[];
    });

    tearDown(() async {
      await db.close();
    });

    AudioPlaybackController buildController({
      required Map<String, Uint8List> files,
      bool failLoadFile = false,
      LyricDisplayPort? lyricPort,
    }) {
      return AudioPlaybackController(
        preferences: AudioPlaybackPreferences(store: store),
        assets: AudioPlaybackAssets(),
        engine: engine,
        safetyCoordinator: safetyCoordinator,
        gatewayFactory: FakeGatewayFactory(files),
        streamBridge: FakeStreamBridge(),
        lyricPort: lyricPort,
        playbackRecordDao: db.userState.playbackRecords,
        isWindowsOverride: true,
        mpvClientFactoryOverride: () {
          final client = FakeLibMpvClient(failLoadFile: failLoadFile);
          spawnedClients.add(client);
          return client;
        },
      );
    }

    test('同物理流 .cue 自然跨轨前进不重新调用 loadfile 且实时更新曲目索引与时长', () async {
      final files = <String, Uint8List>{
        'CD/album.cue': Uint8List.fromList(utf8.encode(sampleCue)),
        'CD/album.flac': Uint8List.fromList(List<int>.filled(1024, 1)),
      };
      final controller = buildController(files: files);
      addTearDown(controller.dispose);

      final work = makeTestWork();
      final source = makeTestSource();
      final vCue = makeTestCdVariant(id: 'v_cue', relativePath: 'CD/album.cue');
      final vAudio = makeTestCdVariant(
        id: 'v_audio',
        relativePath: 'CD/album.flac',
      );

      await controller.playCdCollection(
        work: work,
        variants: [vAudio, vCue],
        sources: [source],
        initialVariant: vCue,
      );

      expect(controller.snapshot.queue.length, 3);
      expect(controller.snapshot.currentIndex, 0);
      expect(controller.snapshot.currentItem!.title, '青春コンプレックス');
      expect(spawnedClients.length, 1);

      final mpv = spawnedClients.single;
      final loadCommandsBefore = mpv.commands
          .where((c) => c.first == 'loadfile')
          .length;
      expect(loadCommandsBefore, 1);

      // 模拟跨过第一轨结束边界（203.0 秒），应自动无缝推进至第 2 轨而不再发起 loadfile。
      mpv.emitDuration(600.0);
      mpv.emitTimePos(203.0);
      await pumpEventQueue();

      expect(controller.snapshot.currentIndex, 1);
      expect(controller.snapshot.currentItem!.title, 'ひとりぼっち東京');
      expect(
        mpv.commands.where((c) => c.first == 'loadfile').length,
        loadCommandsBefore,
      );
      expect(
        controller.durationListenable.value.inSeconds,
        closeTo(232, 1),
      );
    });

    test('支持循环模式切换、随机播放及超过 3 秒按上一曲优先归零重听', () async {
      final files = <String, Uint8List>{
        'CD/01. One.flac': Uint8List.fromList([1, 2, 3]),
        'CD/02. Two.flac': Uint8List.fromList([4, 5, 6]),
      };
      final controller = buildController(files: files);
      addTearDown(controller.dispose);

      final work = makeTestWork();
      final source = makeTestSource();
      await controller.playCdCollection(
        work: work,
        variants: [
          makeTestCdVariant(id: 'v1', relativePath: 'CD/01. One.flac'),
          makeTestCdVariant(id: 'v2', relativePath: 'CD/02. Two.flac'),
        ],
        sources: [source],
      );

      expect(controller.snapshot.loopMode, AudioLoopMode.loopAll);
      controller.cycleLoopMode();
      expect(controller.snapshot.loopMode, AudioLoopMode.loopOne);
      controller.cycleLoopMode();
      expect(controller.snapshot.loopMode, AudioLoopMode.sequence);

      final mpv = spawnedClients.single;
      mpv.emitDuration(180.0);
      mpv.emitTimePos(12.0);
      await pumpEventQueue();
      expect(controller.currentTrackPositionSeconds, closeTo(12.0, 0.01));

      await controller.previous();
      expect(controller.currentTrackPositionSeconds, closeTo(0.0, 0.01));
      expect(controller.snapshot.currentIndex, 0);

      controller.toggleShuffle();
      expect(controller.snapshot.shuffleEnabled, isTrue);
    });

    test('连续 3 首读取失败触发断路熔断保护并进入明确错误态', () async {
      final files = <String, Uint8List>{
        'CD/01.flac': Uint8List.fromList([1]),
        'CD/02.flac': Uint8List.fromList([2]),
        'CD/03.flac': Uint8List.fromList([3]),
        'CD/04.flac': Uint8List.fromList([4]),
      };
      final controller = buildController(files: files, failLoadFile: true);
      addTearDown(controller.dispose);

      await controller.playCdCollection(
        work: makeTestWork(),
        variants: [
          makeTestCdVariant(id: 'v1', relativePath: 'CD/01.flac'),
          makeTestCdVariant(id: 'v2', relativePath: 'CD/02.flac'),
          makeTestCdVariant(id: 'v3', relativePath: 'CD/03.flac'),
          makeTestCdVariant(id: 'v4', relativePath: 'CD/04.flac'),
        ],
        sources: [makeTestSource()],
      );

      expect(controller.snapshot.status, AudioPlaybackStatus.error);
      expect(engine.isCircuitBreakerTripped, isTrue);
      expect(controller.snapshot.errorMessage, contains('熔断'));
    });

    test('clusterAuroraPaletteArgb 提取四象限高饱和低明度丝绒流光色点', () {
      const width = 4;
      const height = 4;
      final bytes = Uint8List(width * height * 4);
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          final offset = (y * width + x) * 4;
          if (y < 2 && x < 2) {
            // 左上：鲜红。
            bytes[offset] = 240;
            bytes[offset + 1] = 40;
            bytes[offset + 2] = 45;
          } else if (y < 2 && x >= 2) {
            // 右上：宝蓝。
            bytes[offset] = 45;
            bytes[offset + 1] = 110;
            bytes[offset + 2] = 245;
          } else if (y >= 2 && x < 2) {
            // 左下：翡翠绿。
            bytes[offset] = 40;
            bytes[offset + 1] = 215;
            bytes[offset + 2] = 110;
          } else {
            // 右下：紫罗兰。
            bytes[offset] = 195;
            bytes[offset + 1] = 55;
            bytes[offset + 2] = 225;
          }
          bytes[offset + 3] = 255;
        }
      }

      final palette = clusterAuroraPaletteArgb(bytes, width, height);
      final qSet = <int>{
        palette.quadrantTopLeftArgb,
        palette.quadrantTopRightArgb,
        palette.quadrantBottomLeftArgb,
        palette.quadrantBottomRightArgb,
      };
      expect(qSet.length, 4);
      // 基底微染色维持低明度电影感暗光域。
      final tintR = (palette.surfaceTintArgb >> 16) & 0xFF;
      final tintG = (palette.surfaceTintArgb >> 8) & 0xFF;
      final tintB = palette.surfaceTintArgb & 0xFF;
      final tintLuma = (0.299 * tintR + 0.587 * tintG + 0.114 * tintB) / 255.0;
      expect(tintLuma, lessThan(0.22));
    });
  });
}
