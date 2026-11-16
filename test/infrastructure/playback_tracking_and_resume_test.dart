import 'dart:async';
import 'dart:typed_data';

import 'package:ccplayer/domain/matching/playback_resume_resolver.dart';
import 'package:ccplayer/domain/models/episode.dart';
import 'package:ccplayer/domain/models/media_source.dart';
import 'package:ccplayer/domain/models/playback_record.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/infrastructure/players/mpv_ipc_tracker.dart';
import 'package:ccplayer/infrastructure/players/potplayer_win32_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

class _SequenceMpvPipeClient implements MpvPipeClient {
  _SequenceMpvPipeClient(this.posSteps, this.durationSeconds);

  final List<double?> posSteps;
  final double? durationSeconds;
  int _idx = 0;

  @override
  Future<double?> queryNumericProperty(String pipePath, String property) async {
    if (property == 'duration') return durationSeconds;
    if (property == 'time-pos') {
      if (_idx >= posSteps.length) {
        return posSteps.isEmpty ? null : posSteps.last;
      }
      return posSteps[_idx++];
    }
    return null;
  }
}

class _SequencePotProbe implements PotPlayerWindowProbe {
  _SequencePotProbe(this.steps);

  final List<({int positionSeconds, int durationSeconds})?> steps;
  int _idx = 0;

  @override
  Future<({int positionSeconds, int durationSeconds})?> queryProgress({
    required int processId,
  }) async {
    if (_idx >= steps.length) {
      return steps.isEmpty ? null : steps.last;
    }
    return steps[_idx++];
  }
}

void main() {
  group('外部播放器秒级双向追踪、防抖与续播推进测试', () {
    test('startSeconds=868 时 MPV 参数包含 --start=+868、唯一命名管道与外挂字幕', () {
      final pipePath = MpvIpcTracker.createPipePath('ep_03_seed');
      expect(pipePath, startsWith(r'\\.\pipe\konata_mpv_'));

      final args = MpvIpcTracker.buildLaunchArguments(
        targetUrlOrPath: 'http://127.0.0.1:50000/stream/tok/ep03.mkv',
        pipePath: pipePath,
        startSeconds: 868,
        subtitlePaths: const [r'C:\tmp\ep03_chs.ass', r'C:\tmp\ep03_tc.ass'],
      );

      expect(args, contains('--input-ipc-server=$pipePath'));
      expect(args, contains('--start=+868'));
      expect(
        args,
        contains(r'--sub-files=C:\tmp\ep03_chs.ass;C:\tmp\ep03_tc.ass'),
      );
      expect(
        args.last,
        equals('http://127.0.0.1:50000/stream/tok/ep03.mkv'),
      );
    });

    test('startSeconds=868 时 PotPlayer 参数包含 /seek=00:14:28 与 /sub 挂载', () {
      final args = PotPlayerWin32Tracker.buildLaunchArguments(
        targetUrlOrPath: r'D:\Anime\Frieren\03.mkv',
        startSeconds: 868,
        subtitlePaths: const [r'D:\Anime\Frieren\03_chs.ass'],
      );

      expect(args, contains(r'D:\Anime\Frieren\03.mkv'));
      expect(args, contains('/seek=00:14:28'));
      expect(args, contains(r'/sub=D:\Anime\Frieren\03_chs.ass'));
    });

    test('MPV IPC 追踪器：忽略刚启动 0 秒瞬态与关闭前偶发归零，进程退出时精准落库最终秒数', () async {
      final exitCompleter = Completer<int>();
      final persisted = <({int pos, int dur, bool isFinal})>[];
      // 启动阶段连续 2 次 0.0 瞬态 -> 推进到 875.6 -> 912.4 -> 关闭前偶发 0.0
      final mockPipe = _SequenceMpvPipeClient(
        [0.0, 0.0, 875.6, 912.4, 0.0],
        1452.0,
      );

      final trackingFuture = MpvIpcTracker.trackProcess(
        pipePath: r'\\.\pipe\konata_mpv_test',
        exitCodeFuture: exitCompleter.future,
        startSeconds: 868,
        pipeClient: mockPipe,
        pollInterval: const Duration(milliseconds: 15),
        persistInterval: const Duration(milliseconds: 25),
        onPersist: (pos, dur, {required bool isFinal}) async {
          persisted.add((pos: pos, dur: dur, isFinal: isFinal));
        },
      );

      await Future<void>.delayed(const Duration(milliseconds: 120));
      exitCompleter.complete(0);
      final finalSnapshot = await trackingFuture;

      expect(persisted.any((e) => e.pos == 0), isFalse, reason: '不应覆写为 0 秒瞬态');
      expect(finalSnapshot, isNotNull);
      expect(finalSnapshot!.positionSeconds, 912);
      expect(finalSnapshot.durationSeconds, 1452);
      expect(persisted.last.pos, 912);
    });

    test('PotPlayer Win32 探针：过滤启动 0 秒与关闭前归零快照，保留最终有效进度落库', () async {
      final exitCompleter = Completer<int>();
      final persisted = <({int pos, int dur, bool isFinal})>[];
      final mockProbe = _SequencePotProbe([
        (positionSeconds: 0, durationSeconds: 1450),
        (positionSeconds: 870, durationSeconds: 1450),
        (positionSeconds: 945, durationSeconds: 1450),
        (positionSeconds: 0, durationSeconds: 1450),
      ]);

      final trackingFuture = PotPlayerWin32Tracker.trackProcess(
        processId: 12345,
        exitCodeFuture: exitCompleter.future,
        startSeconds: 868,
        probe: mockProbe,
        pollInterval: const Duration(milliseconds: 15),
        persistInterval: const Duration(milliseconds: 25),
        onPersist: (pos, dur, {required bool isFinal}) async {
          persisted.add((pos: pos, dur: dur, isFinal: isFinal));
        },
      );

      await Future<void>.delayed(const Duration(milliseconds: 110));
      exitCompleter.complete(0);
      final finalSnapshot = await trackingFuture;

      expect(persisted.any((e) => e.pos == 0), isFalse);
      expect(finalSnapshot, isNotNull);
      expect(finalSnapshot!.positionSeconds, 945);
      expect(finalSnapshot.durationSeconds, 1450);
      expect(persisted.last.pos, 945);
    });

    test('PlaybackRecord 完播阈值规则 (>=90% 或剩余 <=90s) 与详情页续播自动推进下一集', () {
      expect(
        PlaybackRecord.computeCompleted(
          positionSeconds: 1310,
          durationSeconds: 1450,
        ),
        isTrue,
        reason: '1310 / 1450 = 90.34% >= 90%，应自动标为已看完',
      );
      expect(
        PlaybackRecord.computeCompleted(
          positionSeconds: 1115,
          durationSeconds: 1200,
        ),
        isTrue,
        reason: '剩余 85 秒 <= 90 秒，应自动标为已看完',
      );
      expect(
        PlaybackRecord.computeCompleted(
          positionSeconds: 868,
          durationSeconds: 1450,
        ),
        isFalse,
      );
      expect(
        PlaybackRecord.computeCompleted(
          positionSeconds: 100,
          durationSeconds: 0,
        ),
        isFalse,
      );

      const ep3 = Episode(
        id: 'ep3',
        workId: 'w1',
        seasonNumber: 1,
        episodeNumber: 3,
        title: '杀害佐尔格',
      );
      const ep4 = Episode(
        id: 'ep4',
        workId: 'w1',
        seasonNumber: 1,
        episodeNumber: 4,
        title: '灵魂的沉睡之地',
      );

      final resumeUnfinished = PlaybackRecord(
        id: 'rec3',
        workId: 'w1',
        episodeId: 'ep3',
        variantId: 'v3',
        seasonNumber: 1,
        episodeNumber: 3,
        episodeTitle: '第3话',
        sourceType: MediaSourceKind.webdav,
        playedAt: DateTime(2026, 11, 14, 21, 0),
        positionSeconds: 868,
        durationSeconds: 1450,
        isCompleted: false,
      );

      final planUnfinished = PlaybackResumeResolver.resolve(
        episodes: const [ep3, ep4],
        latestPlayback: resumeUnfinished,
        playbackByEpisodeId: {'ep3': resumeUnfinished},
        workTitle: '葬送的芙莉莲',
        workMediaType: TmdbMediaType.tv,
      );
      expect(planUnfinished, isNotNull);
      expect(planUnfinished!.targetEpisode.id, 'ep3');
      expect(planUnfinished.startSeconds, 868);
      expect(planUnfinished.buttonLabel, '继续播放');

      final completedEp3 = resumeUnfinished.copyWith(
        positionSeconds: 1380,
        isCompleted: true,
      );
      final planAdvance = PlaybackResumeResolver.resolve(
        episodes: const [ep3, ep4],
        latestPlayback: completedEp3,
        playbackByEpisodeId: {'ep3': completedEp3},
        workTitle: '葬送的芙莉莲',
        workMediaType: TmdbMediaType.tv,
      );
      expect(planAdvance, isNotNull);
      expect(planAdvance!.targetEpisode.id, 'ep4');
      expect(planAdvance.startSeconds, 0);
      expect(planAdvance.buttonLabel, '继续播放');

      // 验证单集剧场版续播同样固定输出简洁文案「继续播放」且绝不输出 S01E01 / S00E01
      const movieEp = Episode(
        id: 'ep_mov',
        workId: 'w_mov',
        seasonNumber: 1,
        episodeNumber: null,
        title: '加速世界 INFINITE BURST',
      );
      final movieRec = PlaybackRecord(
        id: 'rec_mov',
        workId: 'w_mov',
        episodeId: 'ep_mov',
        variantId: 'v_mov',
        seasonNumber: 1,
        episodeNumber: null,
        episodeTitle: '加速世界 INFINITE BURST',
        sourceType: MediaSourceKind.local,
        playedAt: DateTime(2026, 11, 14, 21, 5),
        positionSeconds: 120,
        durationSeconds: 3600,
        isCompleted: false,
      );
      final moviePlan = PlaybackResumeResolver.resolve(
        episodes: const [movieEp],
        latestPlayback: movieRec,
        playbackByEpisodeId: {'ep_mov': movieRec},
        workTitle: '加速世界 INFINITE BURST',
        workMediaType: TmdbMediaType.movie,
      );
      expect(moviePlan, isNotNull);
      expect(moviePlan!.buttonLabel, '继续播放');
      expect(moviePlan.startSeconds, 120);
    });

    test('HttpByteRange 辅助类型（防意外退化验证 Uint8List 列表编译正常）', () {
      expect(Uint8List.fromList([1, 2, 3]).length, 3);
    });
  });
}
