import 'dart:async';

import 'player_tracking_isolates.dart';

/// 进度持久化回调签名。
typedef PlaybackProgressPersistCallback =
    Future<void> Function(
      int positionSeconds,
      int durationSeconds, {
      required bool isFinal,
    });

/// MPV 命名管道查询客户端抽象（默认走后台 Isolate Win32 FFI，单元测试可注入轻量 Mock）。
abstract interface class MpvPipeClient {
  /// 向命名管道发送 `get_property` 指令并读取浮点属性秒值；失败返回 `null`。
  Future<double?> queryNumericProperty(String pipePath, String property);
}

/// 基于后台工作 Isolate 的 Windows 命名管道 `\\.\pipe\...` IPC 非阻塞客户端。
class Win32MpvPipeClient implements MpvPipeClient {
  /// 创建 Win32 MPV 命名管道客户端。
  const Win32MpvPipeClient();

  @override
  Future<double?> queryNumericProperty(String pipePath, String property) {
    return queryMpvNumericInBackgroundIsolate(pipePath, property);
  }
}

/// 播放器秒级进度采样防抖、定期节流落库与退出最终快照状态机（MPV / PotPlayer 共用）。
class PlaybackProgressStabilizer {
  /// 创建进度防抖状态机。
  PlaybackProgressStabilizer({
    required this.startSeconds,
    required this.persistInterval,
    required this.onPersist,
  }) : _seekSettled = startSeconds <= 5;

  /// 起播跳转秒数（>5 秒时用于启用前 5 次 0 秒瞬态保护窗口）。
  final int startSeconds;

  /// 中途周期性落库最小间隔。
  final Duration persistInterval;

  /// 持久化回调。
  final PlaybackProgressPersistCallback onPersist;

  var _pollCount = 0;
  bool _seekSettled;
  int? _lastValidPos;
  var _lastValidDur = 0;
  var _lastPersistedPos = -1;
  var _lastPersistAt = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> _persistChain = Future<void>.value();

  /// 接收并过滤一次采样结果（忽略刚起播未 Seek 到位与退出瞬间的 0 秒归零）。
  Future<void> accept(int rawPosSeconds, int rawDurationSeconds) async {
    _pollCount += 1;
    if (rawDurationSeconds <= 0) {
      return;
    }

    final pos = rawPosSeconds.clamp(0, 86400 * 10);
    final dur = rawDurationSeconds.clamp(1, 86400 * 10);

    // 刚启动或尚未 Seek 到目标位置前偶发返回 0 秒，前 5 轮采样内予以忽略保护。
    if (!_seekSettled) {
      if (pos >= 2) {
        _seekSettled = true;
      } else if (_pollCount <= 5) {
        return;
      } else {
        _seekSettled = true;
      }
    }

    // 播放器退出瞬间卸除媒体轨道可能误报 0 秒，保护已建立的有效正值进度。
    if (pos == 0 && _lastValidPos != null && _lastValidPos! > 5) {
      return;
    }

    _lastValidPos = pos;
    _lastValidDur = dur;

    final now = DateTime.now();
    if (pos != _lastPersistedPos &&
        now.difference(_lastPersistAt) >= persistInterval) {
      _lastPersistedPos = pos;
      _lastPersistAt = now;
      await _enqueuePersist(pos, dur, isFinal: false);
    }
  }

  /// 进程退出后冲刷尚未写入的最后一条有效秒级进度。
  Future<({int positionSeconds, int durationSeconds})?> flushFinal() async {
    await _persistChain;
    final finalPos = _lastValidPos;
    if (finalPos != null && _lastValidDur > 0) {
      if (finalPos != _lastPersistedPos) {
        _lastPersistedPos = finalPos;
        await onPersist(finalPos, _lastValidDur, isFinal: true);
      }
      return (positionSeconds: finalPos, durationSeconds: _lastValidDur);
    }
    return null;
  }

  Future<void> _enqueuePersist(
    int pos,
    int dur, {
    required bool isFinal,
  }) {
    final next = _persistChain.then(
      (_) => onPersist(pos, dur, isFinal: isFinal),
    );
    _persistChain = next.catchError((_) {});
    return next;
  }
}

/// 剥离用户模板里手写包裹的双引号，并分离外置选项与目标媒体 URL。
List<String> sanitizeAndOrderPlayerArguments({
  required List<String> leadingOptions,
  required String argumentsTemplate,
  required String targetUrlOrPath,
}) {
  final ordered = <String>[...leadingOptions];
  final trimmedTpl = argumentsTemplate.trim();
  if (trimmedTpl.isEmpty || trimmedTpl == '{url}' || trimmedTpl == '"{url}"') {
    ordered.add(targetUrlOrPath);
    return ordered;
  }

  String? embeddedUrlArg;
  for (final rawToken in trimmedTpl.split(RegExp(r'\s+'))) {
    final token = _stripOuterQuotes(rawToken.trim());
    if (token.isEmpty) {
      continue;
    }
    if (token == '{url}') {
      continue;
    }
    if (token.contains('{url}')) {
      embeddedUrlArg = token.replaceAll('{url}', targetUrlOrPath);
    } else {
      ordered.add(token);
    }
  }
  ordered.add(embeddedUrlArg ?? targetUrlOrPath);
  return ordered;
}

String _stripOuterQuotes(String value) {
  if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
    return value.substring(1, value.length - 1);
  }
  return value;
}

/// MPV 精确到秒双向同步追踪器。
class MpvIpcTracker {
  /// 生成唯一 Win32 命名管道路径。
  static String createPipePath(String sessionSeed) {
    final safe = sessionSeed.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
    return r'\\.\pipe\konata_mpv_' + safe;
  }

  /// 生成携带断点定位 `--start=+N`、干净显示标题与外挂字幕的 MPV 启动参数（选项严格前置）。
  static List<String> buildLaunchArguments({
    required String targetUrlOrPath,
    required String pipePath,
    String? displayTitle,
    int startSeconds = 0,
    List<String> subtitlePaths = const [],
    String argumentsTemplate = '{url}',
  }) {
    final cleanTitle = displayTitle?.trim();
    final options = <String>[
      '--input-ipc-server=$pipePath',
      if (cleanTitle != null && cleanTitle.isNotEmpty) ...[
        '--force-media-title=$cleanTitle',
        '--title=$cleanTitle',
      ],
      if (startSeconds > 0) '--start=+$startSeconds',
      if (subtitlePaths.isNotEmpty) '--sub-files=${subtitlePaths.join(';')}',
    ];

    return sanitizeAndOrderPlayerArguments(
      leadingOptions: options,
      argumentsTemplate: argumentsTemplate,
      targetUrlOrPath: targetUrlOrPath,
    );
  }

  /// 后台轮询 MPV JSON IPC 直到进程退出，实时节流与最终落库秒级播放进度。
  ///
  /// 真实 Win32 场景使用独立的后台 `Isolate.spawn` 运行管道查询，彻底零阻塞主 Isolate。
  static Future<({int positionSeconds, int durationSeconds})?> trackProcess({
    required String pipePath,
    required Future<int> exitCodeFuture,
    required PlaybackProgressPersistCallback onPersist,
    int startSeconds = 0,
    MpvPipeClient pipeClient = const Win32MpvPipeClient(),
    Duration pollInterval = const Duration(seconds: 2),
    Duration persistInterval = const Duration(seconds: 5),
  }) async {
    final stabilizer = PlaybackProgressStabilizer(
      startSeconds: startSeconds,
      persistInterval: persistInterval,
      onPersist: onPersist,
    );

    if (pipeClient is Win32MpvPipeClient) {
      PlayerTrackingIsolateHandle? handle;
      try {
        handle = await startMpvPipePollingIsolate(
          pipePath: pipePath,
          pollInterval: pollInterval,
          onSnapshot: (snap) {
            unawaited(
              stabilizer.accept(snap.positionSeconds, snap.durationSeconds),
            );
          },
        );
        await exitCodeFuture;
      } finally {
        await handle?.stop();
      }
      return stabilizer.flushFinal();
    }

    // 单元测试注入轻量内存替身时的同步定时轮询通道。
    var running = true;
    final timer = Timer.periodic(pollInterval, (_) {
      if (!running) return;
      unawaited(() async {
        final rawPos = await pipeClient.queryNumericProperty(
          pipePath,
          'time-pos',
        );
        final rawDur = await pipeClient.queryNumericProperty(
          pipePath,
          'duration',
        );
        if (rawPos == null || rawDur == null) return;
        await stabilizer.accept(rawPos.round(), rawDur.round());
      }());
    });

    await exitCodeFuture;
    running = false;
    timer.cancel();
    return stabilizer.flushFinal();
  }
}
