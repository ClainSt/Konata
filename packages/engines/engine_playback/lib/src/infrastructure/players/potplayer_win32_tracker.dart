import 'dart:async';

import '../../domain/models/playback_record_helpers.dart';
import 'mpv_ipc_tracker.dart';
import 'player_tracking_isolates.dart';

/// PotPlayer Win32 窗口控制消息探针抽象（可注入测试桩）。
abstract interface class PotPlayerWindowProbe {
  /// 查询当前运行中的 PotPlayer 视频精确秒数与总时长；若窗口未就绪或无有效媒体返回 `null`。
  Future<({int positionSeconds, int durationSeconds})?> queryProgress({
    required int processId,
  });
}

/// 基于后台工作 Isolate 与 Windows `user32.dll` (`EnumWindows` + `SendMessageW WM_USER`) 的非阻塞 PotPlayer 探针。
class Win32PotPlayerWindowProbe implements PotPlayerWindowProbe {
  /// 创建 Win32 PotPlayer 探针。
  const Win32PotPlayerWindowProbe();

  @override
  Future<({int positionSeconds, int durationSeconds})?> queryProgress({
    required int processId,
  }) {
    return queryPotPlayerInBackgroundIsolate(processId);
  }
}

/// PotPlayer 精确到秒双向同步追踪器。
class PotPlayerWin32Tracker {
  /// 生成携带 `/seek=HH:MM:SS` 与 `/sub=...` 的 PotPlayer 官方命令行启动参数（自动去除模板手写引号）。
  static List<String> buildLaunchArguments({
    required String targetUrlOrPath,
    int startSeconds = 0,
    List<String> subtitlePaths = const [],
    String argumentsTemplate = '{url}',
  }) {
    final options = <String>[
      if (startSeconds > 0) '/seek=${PlaybackRecordHelper.formatHms(startSeconds)}',
      if (subtitlePaths.isNotEmpty) '/sub=${subtitlePaths.first}',
    ];
    return sanitizeAndOrderPlayerArguments(
      leadingOptions: options,
      argumentsTemplate: argumentsTemplate,
      targetUrlOrPath: targetUrlOrPath,
    );
  }

  /// 后台每 800ms 读取 PotPlayer 窗口播放进度；含 0 秒瞬态防抖、单实例窗口接管与退出快照落库。
  static Future<({int positionSeconds, int durationSeconds})?> trackProcess({
    required int processId,
    required Future<int> exitCodeFuture,
    required PlaybackProgressPersistCallback onPersist,
    int startSeconds = 0,
    PotPlayerWindowProbe probe = const Win32PotPlayerWindowProbe(),
    Duration pollInterval = const Duration(milliseconds: 800),
    Duration persistInterval = const Duration(seconds: 4),
  }) async {
    final stabilizer = PlaybackProgressStabilizer(
      startSeconds: startSeconds,
      persistInterval: persistInterval,
      onPersist: onPersist,
    );

    if (probe is Win32PotPlayerWindowProbe) {
      final startedAt = DateTime.now();
      final windowClosedCompleter = Completer<void>();
      PlayerTrackingIsolateHandle? handle;
      try {
        handle = await startPotPlayerPollingIsolate(
          processId: processId,
          pollInterval: pollInterval,
          startSeconds: startSeconds,
          onSnapshot: (snap) {
            unawaited(
              stabilizer.accept(snap.positionSeconds, snap.durationSeconds),
            );
          },
          onWindowClosed: () {
            if (!windowClosedCompleter.isCompleted) {
              windowClosedCompleter.complete();
            }
          },
        );
        await exitCodeFuture;
        // 若启动子进程在 4 秒内迅速退出，说明 PotPlayer 处于单实例转发模式，继续追踪已存在的真实窗口直至其关闭
        if (DateTime.now().difference(startedAt) < const Duration(seconds: 4) &&
            !windowClosedCompleter.isCompleted) {
          final alive = await hasAnyPotPlayerWindowInBackgroundIsolate();
          if (alive && !windowClosedCompleter.isCompleted) {
            await windowClosedCompleter.future;
          }
        }
      } finally {
        await handle?.stop();
      }
      return stabilizer.flushFinal();
    }

    // 单元测试注入轻量内存替身时的同步定时轮询通道。
    var running = true;
    final timer = Timer.periodic(pollInterval, (_) {
      if (!running) {
        return;
      }
      unawaited(() async {
        final snapshot = await probe.queryProgress(processId: processId);
        if (snapshot == null) {
          return;
        }
        await stabilizer.accept(
          snapshot.positionSeconds,
          snapshot.durationSeconds,
        );
      }());
    });

    await exitCodeFuture;
    running = false;
    timer.cancel();
    return stabilizer.flushFinal();
  }
}
