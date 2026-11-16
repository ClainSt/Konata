import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'win32_ffi_bindings.dart';

/// 后台 Isolate 向主 Isolate 回传的播放器进度快照（秒级整型）。
typedef IsolatedPlaybackSnapshot = ({
  int positionSeconds,
  int durationSeconds,
});

/// 后台工作 Isolate 控制句柄，用于向轮询隔离区发送停止指令并回收端口资源。
class PlayerTrackingIsolateHandle {
  PlayerTrackingIsolateHandle._({
    required Isolate isolate,
    required ReceivePort receivePort,
    required StreamSubscription<Object?> subscription,
    required SendPort? Function() controlPortGetter,
  }) : this._raw(isolate, receivePort, subscription, controlPortGetter);

  PlayerTrackingIsolateHandle._raw(
    this._isolate,
    this._receivePort,
    this._subscription,
    this._controlPortGetter,
  );

  final Isolate _isolate;
  final ReceivePort _receivePort;
  final StreamSubscription<Object?> _subscription;
  final SendPort? Function() _controlPortGetter;
  var _disposed = false;

  /// 优雅通知后台工作 Isolate 停止轮询并释放资源（超时时强制终止，防止僵尸线程）。
  Future<void> stop() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    try {
      _controlPortGetter()?.send('stop');
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 80));
    await _subscription.cancel();
    _receivePort.close();
    _isolate.kill(priority: Isolate.immediate);
  }
}

/// 在独立后台 Isolate 中执行单次 MPV 命名管道属性查询（确保主线程零 Win32 FFI 阻塞）。
Future<double?> queryMpvNumericInBackgroundIsolate(
  String pipePath,
  String property,
) {
  return Isolate.run(() => _queryMpvNumericInIsolate(pipePath, property));
}

/// 在独立后台 Isolate 中执行单次 PotPlayer Win32 窗口查询（确保主线程零阻塞）。
Future<IsolatedPlaybackSnapshot?> queryPotPlayerInBackgroundIsolate(
  int processId,
) {
  return Isolate.run(() => Future<IsolatedPlaybackSnapshot?>.value(_queryPotPlayerOnce(processId)));
}

/// 启动独立的后台工作 Isolate 轮询 MPV Win32 命名管道 `\\.\pipe\...`，
/// 彻底避免同步 `CreateFileW` / `ReadFile` 阻塞主 Isolate 上的 UI 与本地 HTTP 网桥。
Future<PlayerTrackingIsolateHandle> startMpvPipePollingIsolate({
  required String pipePath,
  required Duration pollInterval,
  required void Function(IsolatedPlaybackSnapshot snapshot) onSnapshot,
}) async {
  return _spawnTrackingIsolate(
    entryPoint: _mpvPipeIsolateMain,
    bootPayload: <Object>[pipePath, pollInterval.inMilliseconds],
    onSnapshot: onSnapshot,
  );
}

/// 启动独立的后台工作 Isolate 轮询 PotPlayer Win32 窗口控制消息 (`WM_USER`)，
/// 彻底避免同步 `EnumWindows` / `SendMessageW` 阻塞主 Isolate。
Future<PlayerTrackingIsolateHandle> startPotPlayerPollingIsolate({
  required int processId,
  required Duration pollInterval,
  required void Function(IsolatedPlaybackSnapshot snapshot) onSnapshot,
}) async {
  return _spawnTrackingIsolate(
    entryPoint: _potPlayerIsolateMain,
    bootPayload: <Object>[processId, pollInterval.inMilliseconds],
    onSnapshot: onSnapshot,
  );
}

Future<PlayerTrackingIsolateHandle> _spawnTrackingIsolate({
  required void Function(List<Object> args) entryPoint,
  required List<Object> bootPayload,
  required void Function(IsolatedPlaybackSnapshot snapshot) onSnapshot,
}) async {
  final receivePort = ReceivePort();
  SendPort? controlPort;

  final subscription = receivePort.listen((message) {
    if (message is SendPort) {
      controlPort = message;
      return;
    }
    if (message is List && message.length == 2) {
      final pos = message[0];
      final dur = message[1];
      if (pos is int && dur is int && dur > 0) {
        onSnapshot((positionSeconds: pos, durationSeconds: dur));
      }
    }
  });

  final isolate = await Isolate.spawn<List<Object>>(
    entryPoint,
    <Object>[receivePort.sendPort, ...bootPayload],
    debugName: 'konata_player_tracker',
  );

  return PlayerTrackingIsolateHandle._(
    isolate: isolate,
    receivePort: receivePort,
    subscription: subscription,
    controlPortGetter: () => controlPort,
  );
}

Future<void> _mpvPipeIsolateMain(List<Object> args) async {
  final replyPort = args[0] as SendPort;
  final pipePath = args[1] as String;
  final pollMs = (args[2] as int).clamp(200, 10000);

  final controlPort = ReceivePort();
  replyPort.send(controlPort.sendPort);

  var stopped = false;
  final sub = controlPort.listen((msg) {
    if (msg == 'stop') {
      stopped = true;
    }
  });

  while (!stopped) {
    final pos = await _queryMpvNumericInIsolate(pipePath, 'time-pos');
    if (stopped) {
      break;
    }
    final dur = pos != null
        ? await _queryMpvNumericInIsolate(pipePath, 'duration')
        : null;
    if (pos != null && dur != null) {
      final posSec = pos.round().clamp(0, 86400 * 10);
      final durSec = dur.round().clamp(0, 86400 * 10);
      if (durSec > 0) {
        replyPort.send(<int>[posSec, durSec]);
      }
    }
    await _interruptibleWait(pollMs, () => stopped);
  }

  await sub.cancel();
  controlPort.close();
}

Future<void> _potPlayerIsolateMain(List<Object> args) async {
  final replyPort = args[0] as SendPort;
  final processId = args[1] as int;
  final pollMs = (args[2] as int).clamp(200, 10000);

  final controlPort = ReceivePort();
  replyPort.send(controlPort.sendPort);

  var stopped = false;
  final sub = controlPort.listen((msg) {
    if (msg == 'stop') {
      stopped = true;
    }
  });

  while (!stopped) {
    final snapshot = _queryPotPlayerOnce(processId);
    if (snapshot != null) {
      replyPort.send(<int>[snapshot.positionSeconds, snapshot.durationSeconds]);
    }
    await _interruptibleWait(pollMs, () => stopped);
  }

  await sub.cancel();
  controlPort.close();
}

IsolatedPlaybackSnapshot? _queryPotPlayerOnce(int processId) {
  const wmUser = 0x0400;
  const potGetTotalTime = 0x5002;
  const potGetCurrentTime = 0x5004;

  final bindings = Win32FfiBindings.instance;
  if (bindings == null) {
    return null;
  }
  final hwnd = bindings.findPotPlayerWindow(targetPid: processId);
  if (hwnd == 0 || bindings.isWindow(hwnd) == 0) {
    return null;
  }

  final totalMs = bindings.sendMessageW(hwnd, wmUser, potGetTotalTime, 0);
  if (totalMs <= 0) {
    return null;
  }
  final currentMs = bindings.sendMessageW(
    hwnd,
    wmUser,
    potGetCurrentTime,
    0,
  );
  if (currentMs < 0) {
    return null;
  }

  final durSec = (totalMs / 1000).round().clamp(1, 86400 * 10);
  final posSec = (currentMs / 1000).round().clamp(0, durSec);
  return (positionSeconds: posSec, durationSeconds: durSec);
}

Future<void> _interruptibleWait(int totalMs, bool Function() isStopped) async {
  var remaining = totalMs;
  while (remaining > 0 && !isStopped()) {
    final step = remaining > 150 ? 150 : remaining;
    await Future<void>.delayed(Duration(milliseconds: step));
    remaining -= step;
  }
}

/// 在工作 Isolate 内部通过 Win32 Named Pipe 查询 MPV 单项浮点属性（`time-pos` / `duration`）。
Future<double?> _queryMpvNumericInIsolate(
  String pipePath,
  String property,
) async {
  final bindings = Win32FfiBindings.instance;
  if (bindings == null) {
    return null;
  }

  final pipeNamePtr = pipePath.toNativeUtf16();
  var handle = 0;
  try {
    handle = bindings.createFileW(
      pipeNamePtr,
      Win32FfiBindings.genericReadWrite,
      0,
      nullptr,
      Win32FfiBindings.openExisting,
      0,
      0,
    );
    if (handle == 0 || handle == -1) {
      return null;
    }

    final cmdBytes = utf8.encode(
      '${jsonEncode({
        'command': ['get_property', property],
      })}\n',
    );
    final writeBuf = calloc<Uint8>(cmdBytes.length);
    final writtenPtr = calloc<Uint32>();
    try {
      writeBuf.asTypedList(cmdBytes.length).setAll(0, cmdBytes);
      final okWrite = bindings.writeFile(
        handle,
        writeBuf,
        cmdBytes.length,
        writtenPtr,
        nullptr,
      );
      if (okWrite == 0) {
        return null;
      }
    } finally {
      calloc.free(writeBuf);
      calloc.free(writtenPtr);
    }

    final availPtr = calloc<Uint32>();
    var available = 0;
    try {
      for (var i = 0; i < 8; i++) {
        final okPeek = bindings.peekNamedPipe(
          handle,
          nullptr,
          0,
          nullptr,
          availPtr,
          nullptr,
        );
        if (okPeek == 0) {
          return null;
        }
        available = availPtr.value;
        if (available > 0) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 15));
      }
    } finally {
      calloc.free(availPtr);
    }
    if (available <= 0) {
      return null;
    }

    final cap = available.clamp(128, 4096);
    final readBuf = calloc<Uint8>(cap);
    final readCountPtr = calloc<Uint32>();
    try {
      final okRead = bindings.readFile(
        handle,
        readBuf,
        cap,
        readCountPtr,
        nullptr,
      );
      if (okRead == 0 || readCountPtr.value <= 0) {
        return null;
      }
      final text = utf8.decode(
        readBuf.asTypedList(readCountPtr.value),
        allowMalformed: true,
      );
      for (final line in LineSplitter.split(text)) {
        if (line.trim().isEmpty) {
          continue;
        }
        final decoded = jsonDecode(line);
        if (decoded is Map && decoded['data'] is num) {
          return (decoded['data'] as num).toDouble();
        }
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      calloc.free(readBuf);
      calloc.free(readCountPtr);
    }
  } finally {
    calloc.free(pipeNamePtr);
    if (handle != 0 && handle != -1) {
      bindings.closeHandle(handle);
    }
  }
}
