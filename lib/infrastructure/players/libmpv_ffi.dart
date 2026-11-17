import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import '../../domain/playback/cue_and_lrc_parser.dart';
import '../../domain/playback/playback_probe_stats.dart';
import '../../domain/playback/track_preferences.dart';

/// libmpv C API 标准错误码。
abstract final class MpvError {
  static const int success = 0;
  static const int optionNotFound = -5;
  static const int propertyNotFound = -8;
  static const int propertyFormat = -9;
  static const int propertyUnavailable = -10;
  static const int aoInitFailed = -14;
  static const int voInitFailed = -15;
}

/// libmpv `mpv_format` 枚举常量。
abstract final class MpvFormat {
  static const int none = 0;
  static const int string = 1;
  static const int osdString = 2;
  static const int flag = 3;
  static const int int64 = 4;
  static const int double_ = 5;
  static const int node = 6;
  static const int nodeArray = 7;
  static const int nodeMap = 8;
  static const int byteArray = 9;
}

/// libmpv `mpv_event_id` 枚举常量。
abstract final class MpvEventId {
  static const int none = 0;
  static const int shutdown = 1;
  static const int logMessage = 2;
  static const int startFile = 6;
  static const int endFile = 7;
  static const int fileLoaded = 8;
  static const int videoReconfig = 17;
  static const int audioReconfig = 18;
  static const int seek = 20;
  static const int playbackRestart = 21;
  static const int propertyChange = 22;
}

/// libmpv `mpv_end_file_reason` 枚举常量。
abstract final class MpvEndFileReason {
  static const int eof = 0;
  static const int stop = 2;
  static const int quit = 3;
  static const int error = 4;
  static const int redirect = 5;
}

/// 强类型 libmpv 客户端事件密封类层级。
sealed class MpvClientEvent {
  const MpvClientEvent();
}

/// 属性变化通知事件（`MPV_EVENT_PROPERTY_CHANGE`）。
class MpvPropertyChangeEvent extends MpvClientEvent {
  const MpvPropertyChangeEvent({
    required this.name,
    required this.replyUserdata,
    required this.format,
    this.stringValue,
    this.boolValue,
    this.intValue,
    this.doubleValue,
  });

  final String name;
  final int replyUserdata;
  final int format;
  final String? stringValue;
  final bool? boolValue;
  final int? intValue;
  final double? doubleValue;
}

/// 内部日志事件（`MPV_EVENT_LOG_MESSAGE`）。
class MpvLogMessageEvent extends MpvClientEvent {
  const MpvLogMessageEvent({
    required this.prefix,
    required this.level,
    required this.text,
  });

  final String prefix;
  final String level;
  final String text;
}

/// 文件开始加载事件（`MPV_EVENT_START_FILE`）。
class MpvStartFileEvent extends MpvClientEvent {
  const MpvStartFileEvent(this.playlistEntryId);

  final int playlistEntryId;
}

/// 文件装载完成事件（`MPV_EVENT_FILE_LOADED`）。
class MpvFileLoadedEvent extends MpvClientEvent {
  const MpvFileLoadedEvent();
}

/// 播放结束事件（`MPV_EVENT_END_FILE`）。
class MpvEndFileEvent extends MpvClientEvent {
  const MpvEndFileEvent({
    required this.reason,
    required this.errorCode,
    required this.playlistEntryId,
  });

  final int reason;
  final int errorCode;
  final int playlistEntryId;
}

/// 视频分辨率或像素格式重协商事件（`MPV_EVENT_VIDEO_RECONFIG`）。
class MpvVideoReconfigEvent extends MpvClientEvent {
  const MpvVideoReconfigEvent();
}

/// 音频重配置事件（`MPV_EVENT_AUDIO_RECONFIG`）。
class MpvAudioReconfigEvent extends MpvClientEvent {
  const MpvAudioReconfigEvent();
}

/// Seek 开始事件（`MPV_EVENT_SEEK`）。
class MpvSeekEvent extends MpvClientEvent {
  const MpvSeekEvent();
}

/// 跳转后帧同步重启动事件（`MPV_EVENT_PLAYBACK_RESTART`）。
class MpvPlaybackRestartEvent extends MpvClientEvent {
  const MpvPlaybackRestartEvent();
}

/// 客户端退出事件（`MPV_EVENT_SHUTDOWN`）。
class MpvShutdownEvent extends MpvClientEvent {
  const MpvShutdownEvent();
}

/// `demuxer-cache-state` 中的单个已缓存可零等待 Seek 时间区间（秒）。
class MpvSeekableRange {
  /// 创建可 Seek 内存缓存时间区间。
  const MpvSeekableRange({required this.start, required this.end});

  /// 缓存区间起始秒数。
  final double start;

  /// 缓存区间结束秒数。
  final double end;

  /// 判断目标时间点 [targetSeconds] 是否已命中任一已缓存区间（允许微幅容差）。
  static bool isPositionCached(
    double targetSeconds,
    List<MpvSeekableRange> ranges, {
    double toleranceSeconds = 0.35,
  }) {
    if (!targetSeconds.isFinite || targetSeconds < 0) return false;
    for (final range in ranges) {
      if (targetSeconds >= (range.start - toleranceSeconds) &&
          targetSeconds <= (range.end + toleranceSeconds)) {
        return true;
      }
    }
    return false;
  }
}

/// libmpv 客户端抽象接口，供会话控制器与单测替身共用。
abstract interface class LibMpvClient {
  /// 原生 `mpv_handle*` 指针整数地址（纯测试替身返回 0）。
  int get handleAddress;

  /// 是否已执行 `mpv_initialize`。
  bool get isInitialized;

  /// 是否已销毁。
  bool get isDisposed;

  /// 将错误码转换为可读描述文本。
  String errorString(int code);

  /// 在 `initialize()` 前设置启动选项。
  int setOptionString(String name, String value);

  /// 完成 `mpv_initialize()` 初始化并激活唤醒回调。
  int initialize();

  /// 设置字符串属性。
  int setPropertyString(String name, String value);

  /// 设置布尔开关属性。
  int setPropertyFlag(String name, bool value);

  /// 设置整数属性。
  int setPropertyInt64(String name, int value);

  /// 设置双精度浮点属性。
  int setPropertyDouble(String name, double value);

  /// 读取字符串属性。
  String? getPropertyString(String name);

  /// 读取布尔属性。
  bool? getPropertyFlag(String name);

  /// 读取 64 位整数属性。
  int? getPropertyInt64(String name);

  /// 读取双精度浮点属性。
  double? getPropertyDouble(String name);

  /// 解析当前 `track-list` 节点为强类型轨道列表。
  List<MpvTrackInfo> readTrackList();

  /// 解析当前 `chapter-list` 节点并应用首章负 PTS 校准。
  List<PlaybackChapter> readChapterList({double? totalDurationSeconds});

  /// 解析当前 `audio-device-list` 节点为强类型音频设备列表。
  List<MpvAudioDevice> readAudioDeviceList();

  /// 读取当前 `demuxer-cache-state/seekable-ranges` 内存环形缓存区间。
  List<MpvSeekableRange> readDemuxerSeekableRanges();

  /// 订阅属性变更通知。
  int observeProperty(int replyUserdata, String name, int format);

  /// 启用 libmpv 内部日志抓取等级（如 `warn`、`info`、`no`）。
  int requestLogMessages(String minLevel);

  /// 同步执行 mpv 命令。
  int command(List<String> args);

  /// 异步执行 mpv 命令。
  int commandAsync(int replyUserdata, List<String> args);

  /// 实时事件流。
  Stream<MpvClientEvent> get events;

  /// 在后台 Isolate 异步销毁底层 `mpv_handle`，永不阻塞 UI 线程。
  Future<void> dispose();
}

/// 支持无窗口软件渲染抽帧的 `libmpv` 扩展能力接口（供后台缩略图会话使用）。
abstract interface class LibMpvSoftwareFrameSource {
  /// 将离屏软件渲染尺寸严格钳位并向下对齐至 4 像素边界（防 `repack.c:887` 奇数行/宽断言崩溃）。
  static int alignDimension(int value) => math.max(16, value & ~3);

  /// 初始化 `MPV_RENDER_API_TYPE_SW` 离屏软件渲染上下文与对齐像素缓冲。
  bool initSoftwareRenderer({int width = 192, int height = 108});

  /// 新帧就绪唤醒流（`mpv_render_context_set_update_callback`）。
  Stream<void> get softwareRenderUpdates;

  /// 检查是否有待渲染新帧（对应 `MPV_RENDER_UPDATE_FRAME`）。
  bool pollSoftwareFrameReady();

  /// 将当前最新视频帧渲染为轻量 24-bit 无压缩 BMP 字节（`width x height`）。
  Uint8List? renderSoftwareFrameBmp({int width = 192, int height = 108});

  /// 释放 `mpv_render_context` 及离屏像素缓冲（必须在 `mpv_terminate_destroy` 前调用）。
  void releaseSoftwareRenderer();
}

// ============================================================================
// libmpv C 结构体 ABI 绑定定义（对齐原生头文件 client.h）。
// ============================================================================

final class _MpvByteArrayNative extends Struct {
  external Pointer<Uint8> data;

  @Size()
  external int size;
}

final class _MpvNodeListNative extends Struct {
  @Int32()
  external int num;

  external Pointer<_MpvNodeNative> values;
  external Pointer<Pointer<Utf8>> keys;
}

final class _MpvNodeUnion extends Union {
  external Pointer<Utf8> string;

  @Int32()
  external int flag;

  @Int64()
  external int int64;

  @Double()
  external double double_;

  external Pointer<_MpvNodeListNative> list;
  external Pointer<_MpvByteArrayNative> ba;
}

final class _MpvNodeNative extends Struct {
  external _MpvNodeUnion u;

  @Int32()
  external int format;
}

final class _MpvEventPropertyNative extends Struct {
  external Pointer<Utf8> name;

  @Int32()
  external int format;

  external Pointer<Void> data;
}

final class _MpvEventLogMessageNative extends Struct {
  external Pointer<Utf8> prefix;
  external Pointer<Utf8> level;
  external Pointer<Utf8> text;
}

final class _MpvEventStartFileNative extends Struct {
  @Int64()
  external int playlistEntryId;
}

final class _MpvEventEndFileNative extends Struct {
  @Int32()
  external int reason;

  @Int32()
  external int error;

  @Int64()
  external int playlistEntryId;
}

final class _MpvEventNative extends Struct {
  @Int32()
  external int eventId;

  @Int32()
  external int error;

  @Uint64()
  external int replyUserdata;

  external Pointer<Void> data;
}

typedef _MpvErrorStringNative = Pointer<Utf8> Function(Int32 error);
typedef _MpvErrorStringDart = Pointer<Utf8> Function(int error);

typedef _MpvCreateNative = Pointer<Void> Function();
typedef _MpvCreateDart = Pointer<Void> Function();

typedef _MpvInitializeNative = Int32 Function(Pointer<Void> ctx);
typedef _MpvInitializeDart = int Function(Pointer<Void> ctx);

typedef _MpvTerminateDestroyNative = Void Function(Pointer<Void> ctx);
typedef _MpvTerminateDestroyDart = void Function(Pointer<Void> ctx);

typedef _MpvFreeNative = Void Function(Pointer<Void> data);
typedef _MpvFreeDart = void Function(Pointer<Void> data);

typedef _MpvFreeNodeContentsNative = Void Function(Pointer<_MpvNodeNative> node);
typedef _MpvFreeNodeContentsDart = void Function(Pointer<_MpvNodeNative> node);

typedef _MpvSetOptionStringNative =
    Int32 Function(Pointer<Void> ctx, Pointer<Utf8> name, Pointer<Utf8> data);
typedef _MpvSetOptionStringDart =
    int Function(Pointer<Void> ctx, Pointer<Utf8> name, Pointer<Utf8> data);

typedef _MpvSetPropertyNative =
    Int32 Function(
      Pointer<Void> ctx,
      Pointer<Utf8> name,
      Int32 format,
      Pointer<Void> data,
    );
typedef _MpvSetPropertyDart =
    int Function(
      Pointer<Void> ctx,
      Pointer<Utf8> name,
      int format,
      Pointer<Void> data,
    );

typedef _MpvSetPropertyStringNative =
    Int32 Function(Pointer<Void> ctx, Pointer<Utf8> name, Pointer<Utf8> data);
typedef _MpvSetPropertyStringDart =
    int Function(Pointer<Void> ctx, Pointer<Utf8> name, Pointer<Utf8> data);

typedef _MpvGetPropertyNative =
    Int32 Function(
      Pointer<Void> ctx,
      Pointer<Utf8> name,
      Int32 format,
      Pointer<Void> data,
    );
typedef _MpvGetPropertyDart =
    int Function(
      Pointer<Void> ctx,
      Pointer<Utf8> name,
      int format,
      Pointer<Void> data,
    );

typedef _MpvGetPropertyStringNative =
    Pointer<Utf8> Function(Pointer<Void> ctx, Pointer<Utf8> name);
typedef _MpvGetPropertyStringDart =
    Pointer<Utf8> Function(Pointer<Void> ctx, Pointer<Utf8> name);

typedef _MpvObservePropertyNative =
    Int32 Function(
      Pointer<Void> mpv,
      Uint64 replyUserdata,
      Pointer<Utf8> name,
      Int32 format,
    );
typedef _MpvObservePropertyDart =
    int Function(
      Pointer<Void> mpv,
      int replyUserdata,
      Pointer<Utf8> name,
      int format,
    );

typedef _MpvCommandNative =
    Int32 Function(Pointer<Void> ctx, Pointer<Pointer<Utf8>> args);
typedef _MpvCommandDart =
    int Function(Pointer<Void> ctx, Pointer<Pointer<Utf8>> args);

typedef _MpvCommandAsyncNative =
    Int32 Function(
      Pointer<Void> ctx,
      Uint64 replyUserdata,
      Pointer<Pointer<Utf8>> args,
    );
typedef _MpvCommandAsyncDart =
    int Function(
      Pointer<Void> ctx,
      int replyUserdata,
      Pointer<Pointer<Utf8>> args,
    );

typedef _MpvRequestLogMessagesNative =
    Int32 Function(Pointer<Void> ctx, Pointer<Utf8> minLevel);
typedef _MpvRequestLogMessagesDart =
    int Function(Pointer<Void> ctx, Pointer<Utf8> minLevel);

typedef _MpvWakeupNative = Void Function(Pointer<Void> d);
typedef _MpvSetWakeupCallbackNative =
    Void Function(
      Pointer<Void> ctx,
      Pointer<NativeFunction<_MpvWakeupNative>> cb,
      Pointer<Void> d,
    );
typedef _MpvSetWakeupCallbackDart =
    void Function(
      Pointer<Void> ctx,
      Pointer<NativeFunction<_MpvWakeupNative>> cb,
      Pointer<Void> d,
    );

typedef _MpvWaitEventNative =
    Pointer<_MpvEventNative> Function(Pointer<Void> ctx, Double timeout);
typedef _MpvWaitEventDart =
    Pointer<_MpvEventNative> Function(Pointer<Void> ctx, double timeout);

final class _MpvRenderParamNative extends Struct {
  @Int32()
  external int type;

  external Pointer<Void> data;
}

typedef _MpvRenderContextCreateNative =
    Int32 Function(
      Pointer<Pointer<Void>> res,
      Pointer<Void> mpv,
      Pointer<_MpvRenderParamNative> params,
    );
typedef _MpvRenderContextCreateDart =
    int Function(
      Pointer<Pointer<Void>> res,
      Pointer<Void> mpv,
      Pointer<_MpvRenderParamNative> params,
    );

typedef _MpvRenderContextSetUpdateCallbackNative =
    Void Function(
      Pointer<Void> ctx,
      Pointer<NativeFunction<_MpvWakeupNative>> cb,
      Pointer<Void> cbCtx,
    );
typedef _MpvRenderContextSetUpdateCallbackDart =
    void Function(
      Pointer<Void> ctx,
      Pointer<NativeFunction<_MpvWakeupNative>> cb,
      Pointer<Void> cbCtx,
    );

typedef _MpvRenderContextUpdateNative = Uint64 Function(Pointer<Void> ctx);
typedef _MpvRenderContextUpdateDart = int Function(Pointer<Void> ctx);

typedef _MpvRenderContextRenderNative =
    Int32 Function(Pointer<Void> ctx, Pointer<_MpvRenderParamNative> params);
typedef _MpvRenderContextRenderDart =
    int Function(Pointer<Void> ctx, Pointer<_MpvRenderParamNative> params);

typedef _MpvRenderContextFreeNative = Void Function(Pointer<Void> ctx);
typedef _MpvRenderContextFreeDart = void Function(Pointer<Void> ctx);

/// 将 `MPV_RENDER_API_TYPE_SW` 输出的 `rgb0` 像素帧封装为轻量 24-bit 无压缩 BMP 字节流。
Uint8List encodeRgb0ToBmp(Uint8List rgb0, int width, int height) {
  if (width <= 0 || height <= 0 || rgb0.length < width * height * 4) {
    return Uint8List(0);
  }
  final rowBytes = width * 3;
  final rowStride = ((rowBytes + 3) ~/ 4) * 4;
  final pixelDataSize = rowStride * height;
  final fileSize = 54 + pixelDataSize;
  final bmp = Uint8List(fileSize);
  final view = ByteData.sublistView(bmp);

  // 位图文件头 BITMAPFILEHEADER（14 字节）
  bmp[0] = 0x42; // 'B'
  bmp[1] = 0x4D; // 'M'
  view.setUint32(2, fileSize, Endian.little);
  view.setUint32(10, 54, Endian.little);

  // 位图信息头 BITMAPINFOHEADER（40 字节）
  view.setUint32(14, 40, Endian.little);
  view.setInt32(18, width, Endian.little);
  view.setInt32(22, height, Endian.little);
  view.setUint16(26, 1, Endian.little);
  view.setUint16(28, 24, Endian.little);
  view.setUint32(34, pixelDataSize, Endian.little);

  final srcStride = width * 4;
  for (var y = 0; y < height; y++) {
    final srcRowOffset = (height - 1 - y) * srcStride;
    final dstRowOffset = 54 + y * rowStride;
    for (var x = 0; x < width; x++) {
      final si = srcRowOffset + x * 4;
      final di = dstRowOffset + x * 3;
      bmp[di] = rgb0[si + 2]; // B
      bmp[di + 1] = rgb0[si + 1]; // G
      bmp[di + 2] = rgb0[si]; // R
    }
  }
  return bmp;
}

/// 基于 `dart:ffi` 与 `NativeCallable.listener` 的真实 libmpv 客户端封装。
class FfiLibMpvClient implements LibMpvClient, LibMpvSoftwareFrameSource {
  FfiLibMpvClient._({
    required this._libraryPath,
    required this._library,
    required this._handle,
  }) {
    _mpvErrorString = _library.lookupFunction<_MpvErrorStringNative, _MpvErrorStringDart>(
      'mpv_error_string',
    );
    _mpvInitialize = _library.lookupFunction<_MpvInitializeNative, _MpvInitializeDart>(
      'mpv_initialize',
    );
    _mpvFree = _library.lookupFunction<_MpvFreeNative, _MpvFreeDart>(
      'mpv_free',
    );
    _mpvFreeNodeContents = _library
        .lookupFunction<_MpvFreeNodeContentsNative, _MpvFreeNodeContentsDart>(
          'mpv_free_node_contents',
        );
    _mpvSetOptionString = _library
        .lookupFunction<_MpvSetOptionStringNative, _MpvSetOptionStringDart>(
          'mpv_set_option_string',
        );
    _mpvSetProperty = _library
        .lookupFunction<_MpvSetPropertyNative, _MpvSetPropertyDart>(
          'mpv_set_property',
        );
    _mpvSetPropertyString = _library
        .lookupFunction<_MpvSetPropertyStringNative, _MpvSetPropertyStringDart>(
          'mpv_set_property_string',
        );
    _mpvGetProperty = _library
        .lookupFunction<_MpvGetPropertyNative, _MpvGetPropertyDart>(
          'mpv_get_property',
        );
    _mpvGetPropertyString = _library
        .lookupFunction<_MpvGetPropertyStringNative, _MpvGetPropertyStringDart>(
          'mpv_get_property_string',
        );
    _mpvObserveProperty = _library
        .lookupFunction<_MpvObservePropertyNative, _MpvObservePropertyDart>(
          'mpv_observe_property',
        );
    _mpvCommand = _library.lookupFunction<_MpvCommandNative, _MpvCommandDart>(
      'mpv_command',
    );
    _mpvCommandAsync = _library
        .lookupFunction<_MpvCommandAsyncNative, _MpvCommandAsyncDart>(
          'mpv_command_async',
        );
    _mpvRequestLogMessages = _library
        .lookupFunction<_MpvRequestLogMessagesNative, _MpvRequestLogMessagesDart>(
          'mpv_request_log_messages',
        );
    _mpvSetWakeupCallback = _library
        .lookupFunction<_MpvSetWakeupCallbackNative, _MpvSetWakeupCallbackDart>(
          'mpv_set_wakeup_callback',
        );
    _mpvWaitEvent = _library
        .lookupFunction<_MpvWaitEventNative, _MpvWaitEventDart>(
          'mpv_wait_event',
        );
  }

  /// 创建尚未执行 `mpv_initialize()` 的原生 `libmpv` 客户端。
  factory FfiLibMpvClient.create({String? preferredLibraryPath}) {
    final resolved = _openLibMpv(preferredLibraryPath: preferredLibraryPath);
    final mpvCreate = resolved.library
        .lookupFunction<_MpvCreateNative, _MpvCreateDart>('mpv_create');
    final handle = mpvCreate();
    if (handle == nullptr) {
      throw StateError('mpv_create() returned nullptr (${resolved.path})');
    }
    return FfiLibMpvClient._(
      libraryPath: resolved.path,
      library: resolved.library,
      handle: handle,
    );
  }

  final String _libraryPath;
  final DynamicLibrary _library;
  Pointer<Void> _handle;
  bool _initialized = false;
  bool _disposed = false;

  final StreamController<MpvClientEvent> _eventsController =
      StreamController<MpvClientEvent>.broadcast();
  NativeCallable<_MpvWakeupNative>? _wakeupCallable;

  final StreamController<void> _renderUpdatesController =
      StreamController<void>.broadcast();
  Pointer<Void> _renderCtx = nullptr;
  NativeCallable<_MpvWakeupNative>? _renderWakeupCallable;
  Pointer<Uint8>? _swPixelRawBuffer;
  int _swPixelBufferCapacity = 0;
  _MpvRenderContextUpdateDart? _mpvRenderUpdate;
  _MpvRenderContextRenderDart? _mpvRenderRender;
  _MpvRenderContextFreeDart? _mpvRenderFree;
  _MpvRenderContextSetUpdateCallbackDart? _mpvRenderSetUpdateCb;

  late final _MpvErrorStringDart _mpvErrorString;
  late final _MpvInitializeDart _mpvInitialize;
  late final _MpvFreeDart _mpvFree;
  late final _MpvFreeNodeContentsDart _mpvFreeNodeContents;
  late final _MpvSetOptionStringDart _mpvSetOptionString;
  late final _MpvSetPropertyDart _mpvSetProperty;
  late final _MpvSetPropertyStringDart _mpvSetPropertyString;
  late final _MpvGetPropertyDart _mpvGetProperty;
  late final _MpvGetPropertyStringDart _mpvGetPropertyString;
  late final _MpvObservePropertyDart _mpvObserveProperty;
  late final _MpvCommandDart _mpvCommand;
  late final _MpvCommandAsyncDart _mpvCommandAsync;
  late final _MpvRequestLogMessagesDart _mpvRequestLogMessages;
  late final _MpvSetWakeupCallbackDart _mpvSetWakeupCallback;
  late final _MpvWaitEventDart _mpvWaitEvent;

  @override
  int get handleAddress => _disposed ? 0 : _handle.address;

  @override
  bool get isInitialized => _initialized;

  @override
  bool get isDisposed => _disposed;

  @override
  Stream<MpvClientEvent> get events => _eventsController.stream;

  /// 解析当前可用 `libmpv` 动态库路径（Windows 优先可执行文件同目录，支持测试工作区回退）。
  static ({String path, DynamicLibrary library}) _openLibMpv({
    String? preferredLibraryPath,
  }) {
    final candidates = <String>[];
    if (preferredLibraryPath != null && preferredLibraryPath.trim().isNotEmpty) {
      candidates.add(preferredLibraryPath.trim());
    }
    if (Platform.isWindows) {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      candidates.add(p.join(exeDir, 'libmpv-2.dll'));
      final cwd = Directory.current.path;
      candidates.add(
        p.join(cwd, 'native', 'konata-native', 'windows', 'libmpv-2.dll'),
      );
      candidates.add('libmpv-2.dll');
      candidates.add('mpv-2.dll');
    } else if (Platform.isAndroid || Platform.isLinux) {
      candidates.add('libmpv.so');
      candidates.add('libmpv.so.2');
    }

    Object? lastError;
    for (final candidate in candidates) {
      try {
        final isBareName =
            !candidate.contains('\\') && !candidate.contains('/');
        if (!isBareName && !File(candidate).existsSync()) {
          continue;
        }
        final lib = DynamicLibrary.open(candidate);
        return (path: candidate, library: lib);
      } catch (e) {
        lastError = e;
      }
    }
    throw StateError(
      'Unable to load libmpv dynamic library (candidates: $candidates): $lastError',
    );
  }

  @override
  String errorString(int code) {
    final ptr = _mpvErrorString(code);
    if (ptr == nullptr) return 'mpv_error($code)';
    return ptr.toDartString();
  }

  @override
  int setOptionString(String name, String value) {
    if (_disposed) return -1;
    return using((arena) {
      return _mpvSetOptionString(
        _handle,
        name.toNativeUtf8(allocator: arena),
        value.toNativeUtf8(allocator: arena),
      );
    });
  }

  @override
  int initialize() {
    if (_disposed) return -1;
    if (_initialized) return MpvError.success;
    final rc = _mpvInitialize(_handle);
    if (rc >= 0) {
      _initialized = true;
      _attachWakeupCallback();
    }
    return rc;
  }

  void _attachWakeupCallback() {
    _wakeupCallable?.close();
    _wakeupCallable = NativeCallable<_MpvWakeupNative>.listener(_onMpvWakeup);
    _mpvSetWakeupCallback(
      _handle,
      _wakeupCallable!.nativeFunction,
      nullptr,
    );
  }

  void _onMpvWakeup(Pointer<Void> _) {
    drainEvents();
  }

  /// 非阻塞排空待处理 libmpv 事件队列。
  void drainEvents() {
    if (_disposed || _handle == nullptr) return;
    while (!_disposed && _handle != nullptr) {
      final evPtr = _mpvWaitEvent(_handle, 0.0);
      if (evPtr == nullptr) break;
      final ev = evPtr.ref;
      if (ev.eventId == MpvEventId.none) {
        break;
      }
      final parsed = _parseEvent(ev);
      if (parsed != null && !_eventsController.isClosed) {
        _eventsController.add(parsed);
      }
      if (ev.eventId == MpvEventId.shutdown) {
        break;
      }
    }
  }

  MpvClientEvent? _parseEvent(_MpvEventNative ev) {
    switch (ev.eventId) {
      case MpvEventId.shutdown:
        return const MpvShutdownEvent();
      case MpvEventId.fileLoaded:
        return const MpvFileLoadedEvent();
      case MpvEventId.videoReconfig:
        return const MpvVideoReconfigEvent();
      case MpvEventId.audioReconfig:
        return const MpvAudioReconfigEvent();
      case MpvEventId.seek:
        return const MpvSeekEvent();
      case MpvEventId.playbackRestart:
        return const MpvPlaybackRestartEvent();
      case MpvEventId.startFile:
        if (ev.data == nullptr) return const MpvStartFileEvent(0);
        final sf = ev.data.cast<_MpvEventStartFileNative>().ref;
        return MpvStartFileEvent(sf.playlistEntryId);
      case MpvEventId.endFile:
        if (ev.data == nullptr) {
          return const MpvEndFileEvent(
            reason: MpvEndFileReason.stop,
            errorCode: 0,
            playlistEntryId: 0,
          );
        }
        final ef = ev.data.cast<_MpvEventEndFileNative>().ref;
        return MpvEndFileEvent(
          reason: ef.reason,
          errorCode: ef.error,
          playlistEntryId: ef.playlistEntryId,
        );
      case MpvEventId.logMessage:
        if (ev.data == nullptr) return null;
        final msg = ev.data.cast<_MpvEventLogMessageNative>().ref;
        return MpvLogMessageEvent(
          prefix: _safeReadUtf8(msg.prefix),
          level: _safeReadUtf8(msg.level),
          text: _safeReadUtf8(msg.text).trimRight(),
        );
      case MpvEventId.propertyChange:
        if (ev.data == nullptr) return null;
        final prop = ev.data.cast<_MpvEventPropertyNative>().ref;
        final name = _safeReadUtf8(prop.name);
        String? strVal;
        bool? boolVal;
        int? intVal;
        double? dblVal;
        if (prop.data != nullptr) {
          switch (prop.format) {
            case MpvFormat.string:
            case MpvFormat.osdString:
              final ptr = prop.data.cast<Pointer<Utf8>>().value;
              if (ptr != nullptr) strVal = _safeReadUtf8(ptr);
            case MpvFormat.flag:
              boolVal = prop.data.cast<Int32>().value != 0;
            case MpvFormat.int64:
              intVal = prop.data.cast<Int64>().value;
            case MpvFormat.double_:
              dblVal = prop.data.cast<Double>().value;
          }
        }
        return MpvPropertyChangeEvent(
          name: name,
          replyUserdata: ev.replyUserdata,
          format: prop.format,
          stringValue: strVal,
          boolValue: boolVal,
          intValue: intVal,
          doubleValue: dblVal,
        );
      default:
        return null;
    }
  }

  @override
  int setPropertyString(String name, String value) {
    if (_disposed) return -1;
    return using((arena) {
      return _mpvSetPropertyString(
        _handle,
        name.toNativeUtf8(allocator: arena),
        value.toNativeUtf8(allocator: arena),
      );
    });
  }

  @override
  int setPropertyFlag(String name, bool value) {
    if (_disposed) return -1;
    return using((arena) {
      final flagPtr = arena<Int32>();
      flagPtr.value = value ? 1 : 0;
      return _mpvSetProperty(
        _handle,
        name.toNativeUtf8(allocator: arena),
        MpvFormat.flag,
        flagPtr.cast<Void>(),
      );
    });
  }

  @override
  int setPropertyInt64(String name, int value) {
    if (_disposed) return -1;
    return using((arena) {
      final intPtr = arena<Int64>();
      intPtr.value = value;
      return _mpvSetProperty(
        _handle,
        name.toNativeUtf8(allocator: arena),
        MpvFormat.int64,
        intPtr.cast<Void>(),
      );
    });
  }

  @override
  int setPropertyDouble(String name, double value) {
    if (_disposed) return -1;
    return using((arena) {
      final dblPtr = arena<Double>();
      dblPtr.value = value;
      return _mpvSetProperty(
        _handle,
        name.toNativeUtf8(allocator: arena),
        MpvFormat.double_,
        dblPtr.cast<Void>(),
      );
    });
  }

  @override
  String? getPropertyString(String name) {
    if (_disposed) return null;
    return using((arena) {
      final ptr = _mpvGetPropertyString(
        _handle,
        name.toNativeUtf8(allocator: arena),
      );
      if (ptr == nullptr) return null;
      try {
        return _safeReadUtf8(ptr);
      } finally {
        _mpvFree(ptr.cast<Void>());
      }
    });
  }

  @override
  bool? getPropertyFlag(String name) {
    if (_disposed) return null;
    return using((arena) {
      final outPtr = arena<Int32>();
      final rc = _mpvGetProperty(
        _handle,
        name.toNativeUtf8(allocator: arena),
        MpvFormat.flag,
        outPtr.cast<Void>(),
      );
      if (rc < 0) return null;
      return outPtr.value != 0;
    });
  }

  @override
  int? getPropertyInt64(String name) {
    if (_disposed) return null;
    return using((arena) {
      final outPtr = arena<Int64>();
      final rc = _mpvGetProperty(
        _handle,
        name.toNativeUtf8(allocator: arena),
        MpvFormat.int64,
        outPtr.cast<Void>(),
      );
      if (rc < 0) return null;
      return outPtr.value;
    });
  }

  @override
  double? getPropertyDouble(String name) {
    if (_disposed) return null;
    return using((arena) {
      final outPtr = arena<Double>();
      final rc = _mpvGetProperty(
        _handle,
        name.toNativeUtf8(allocator: arena),
        MpvFormat.double_,
        outPtr.cast<Void>(),
      );
      if (rc < 0) return null;
      return outPtr.value;
    });
  }

  @override
  List<MpvTrackInfo> readTrackList() {
    if (_disposed) return const [];
    return _withNodeProperty('track-list', (node) {
      if (node.format != MpvFormat.nodeArray || node.u.list == nullptr) {
        return const <MpvTrackInfo>[];
      }
      final list = node.u.list.ref;
      final tracks = <MpvTrackInfo>[];
      for (var i = 0; i < list.num; i++) {
        final item = list.values[i];
        final fields = _readNodeMapFields(item);
        if (fields == null) continue;
        final typeRaw = _asString(fields['type']);
        final trackType = switch (typeRaw) {
          'video' => MpvTrackType.video,
          'audio' => MpvTrackType.audio,
          'sub' => MpvTrackType.subtitle,
          _ => null,
        };
        if (trackType == null) continue;
        final id = _asInt(fields['id']) ?? 0;
        if (id <= 0) continue;

        final extFile = _asString(fields['external-filename']);
        tracks.add(
          MpvTrackInfo(
            id: id,
            type: trackType,
            title: _asString(fields['title']),
            lang: _asString(fields['lang']),
            codec: _asString(fields['codec']),
            channelCount: _asInt(fields['demux-channel-count']),
            sampleRateHz: _asInt(fields['demux-samplerate']),
            isDefault: _asBool(fields['default']),
            isForced: _asBool(fields['forced']),
            isExternal: _asBool(fields['external']),
            externalFilename: extFile.isEmpty ? null : extFile,
            selected: _asBool(fields['selected']),
          ),
        );
      }
      return tracks;
    }) ?? const [];
  }

  @override
  List<PlaybackChapter> readChapterList({double? totalDurationSeconds}) {
    if (_disposed) return const [];
    final rawChapters = _withNodeProperty('chapter-list', (node) {
      if (node.format != MpvFormat.nodeArray || node.u.list == nullptr) {
        return const <PlaybackChapter>[];
      }
      final list = node.u.list.ref;
      final chapters = <PlaybackChapter>[];
      for (var i = 0; i < list.num; i++) {
        final fields = _readNodeMapFields(list.values[i]);
        if (fields == null) continue;
        final title = _asString(fields['title']);
        final time = _asDouble(fields['time']) ?? 0.0;
        chapters.add(
          PlaybackChapter(
            index: i,
            title: title,
            startSeconds: PlaybackProbeStats.clampChapterZeroPts(time),
          ),
        );
      }
      return chapters;
    }) ?? const [];
    return PlaybackProbeStats.normalizeChapters(
      rawChapters,
      totalDurationSeconds: totalDurationSeconds,
    );
  }

  @override
  List<MpvAudioDevice> readAudioDeviceList() {
    if (_disposed) return const [];
    return _withNodeProperty('audio-device-list', (node) {
      if (node.format != MpvFormat.nodeArray || node.u.list == nullptr) {
        return const <MpvAudioDevice>[];
      }
      final list = node.u.list.ref;
      final devices = <MpvAudioDevice>[];
      for (var i = 0; i < list.num; i++) {
        final fields = _readNodeMapFields(list.values[i]);
        if (fields == null) continue;
        final name = _asString(fields['name']);
        if (name.isEmpty) continue;
        final desc = _asString(fields['description']);
        devices.add(
          MpvAudioDevice(
            name: name,
            description: desc.isNotEmpty ? desc : name,
          ),
        );
      }
      return devices;
    }) ?? const [];
  }

  @override
  List<MpvSeekableRange> readDemuxerSeekableRanges() {
    if (_disposed) return const [];
    return _withNodeProperty('demuxer-cache-state', (node) {
          if (node.format != MpvFormat.nodeMap || node.u.list == nullptr) {
            return const <MpvSeekableRange>[];
          }
          final mapList = node.u.list.ref;
          for (var i = 0; i < mapList.num; i++) {
            final keyPtr = mapList.keys[i];
            if (keyPtr == nullptr) continue;
            final key = _safeReadUtf8(keyPtr);
            if (key != 'seekable-ranges') continue;
            final rangesNode = mapList.values[i];
            if (rangesNode.format != MpvFormat.nodeArray ||
                rangesNode.u.list == nullptr) {
              return const <MpvSeekableRange>[];
            }
            final arr = rangesNode.u.list.ref;
            final ranges = <MpvSeekableRange>[];
            for (var j = 0; j < arr.num; j++) {
              final fields = _readNodeMapFields(arr.values[j]);
              if (fields == null) continue;
              final start = _asDouble(fields['start']);
              final end = _asDouble(fields['end']);
              if (start != null && end != null && end >= start) {
                ranges.add(MpvSeekableRange(start: start, end: end));
              }
            }
            return ranges;
          }
          return const <MpvSeekableRange>[];
        }) ??
        const [];
  }

  T? _withNodeProperty<T>(String name, T Function(_MpvNodeNative node) reader) {
    return using((arena) {
      final nodePtr = arena<_MpvNodeNative>();
      final rc = _mpvGetProperty(
        _handle,
        name.toNativeUtf8(allocator: arena),
        MpvFormat.node,
        nodePtr.cast<Void>(),
      );
      if (rc < 0) return null;
      try {
        return reader(nodePtr.ref);
      } finally {
        _mpvFreeNodeContents(nodePtr);
      }
    });
  }

  Map<String, Object?>? _readNodeMapFields(_MpvNodeNative node) {
    if (node.format != MpvFormat.nodeMap || node.u.list == nullptr) {
      return null;
    }
    final list = node.u.list.ref;
    final out = <String, Object?>{};
    for (var i = 0; i < list.num; i++) {
      final keyPtr = list.keys[i];
      if (keyPtr == nullptr) continue;
      final key = _safeReadUtf8(keyPtr);
      out[key] = _readPrimitiveNodeValue(list.values[i]);
    }
    return out;
  }

  Object? _readPrimitiveNodeValue(_MpvNodeNative node) {
    switch (node.format) {
      case MpvFormat.string:
      case MpvFormat.osdString:
        return node.u.string == nullptr ? '' : _safeReadUtf8(node.u.string);
      case MpvFormat.flag:
        return node.u.flag != 0;
      case MpvFormat.int64:
        return node.u.int64;
      case MpvFormat.double_:
        return node.u.double_;
      case MpvFormat.byteArray:
        if (node.u.ba == nullptr) return null;
        final ba = node.u.ba.ref;
        if (ba.data == nullptr || ba.size <= 0) return Uint8List(0);
        return Uint8List.fromList(ba.data.asTypedList(ba.size));
      default:
        return null;
    }
  }

  @override
  int observeProperty(int replyUserdata, String name, int format) {
    if (_disposed) return -1;
    return using((arena) {
      return _mpvObserveProperty(
        _handle,
        replyUserdata,
        name.toNativeUtf8(allocator: arena),
        format,
      );
    });
  }

  @override
  int requestLogMessages(String minLevel) {
    if (_disposed) return -1;
    return using((arena) {
      return _mpvRequestLogMessages(
        _handle,
        minLevel.toNativeUtf8(allocator: arena),
      );
    });
  }

  @override
  int command(List<String> args) {
    if (_disposed || args.isEmpty) return -1;
    return using((arena) {
      final argv = arena<Pointer<Utf8>>(args.length + 1);
      for (var i = 0; i < args.length; i++) {
        argv[i] = args[i].toNativeUtf8(allocator: arena);
      }
      argv[args.length] = nullptr;
      return _mpvCommand(_handle, argv);
    });
  }

  @override
  int commandAsync(int replyUserdata, List<String> args) {
    if (_disposed || args.isEmpty) return -1;
    return using((arena) {
      final argv = arena<Pointer<Utf8>>(args.length + 1);
      for (var i = 0; i < args.length; i++) {
        argv[i] = args[i].toNativeUtf8(allocator: arena);
      }
      argv[args.length] = nullptr;
      return _mpvCommandAsync(_handle, replyUserdata, argv);
    });
  }

  static const int _renderParamInvalid = 0;
  static const int _renderParamApiType = 1;
  static const int _renderParamBlockForTargetTime = 12;
  static const int _renderParamSwSize = 17;
  static const int _renderParamSwFormat = 18;
  static const int _renderParamSwStride = 19;
  static const int _renderParamSwPointer = 20;
  static const int _renderUpdateFrame = 1;

  @override
  Stream<void> get softwareRenderUpdates => _renderUpdatesController.stream;

  @override
  bool initSoftwareRenderer({int width = 192, int height = 108}) {
    if (_disposed || !_initialized || _handle == nullptr) return false;
    if (_renderCtx != nullptr) return true;
    final safeW = LibMpvSoftwareFrameSource.alignDimension(width);
    final safeH = LibMpvSoftwareFrameSource.alignDimension(height);

    try {
      final renderCreate = _library.lookupFunction<
          _MpvRenderContextCreateNative, _MpvRenderContextCreateDart>(
        'mpv_render_context_create',
      );
      _mpvRenderSetUpdateCb ??= _library.lookupFunction<
          _MpvRenderContextSetUpdateCallbackNative,
          _MpvRenderContextSetUpdateCallbackDart>(
        'mpv_render_context_set_update_callback',
      );
      _mpvRenderUpdate ??= _library.lookupFunction<
          _MpvRenderContextUpdateNative, _MpvRenderContextUpdateDart>(
        'mpv_render_context_update',
      );
      _mpvRenderRender ??= _library.lookupFunction<
          _MpvRenderContextRenderNative, _MpvRenderContextRenderDart>(
        'mpv_render_context_render',
      );
      _mpvRenderFree ??= _library.lookupFunction<
          _MpvRenderContextFreeNative, _MpvRenderContextFreeDart>(
        'mpv_render_context_free',
      );

      final ctxOut = using((arena) {
        final outPtr = arena<Pointer<Void>>();
        final apiStr = 'sw'.toNativeUtf8(allocator: arena);
        final params = arena<_MpvRenderParamNative>(2);
        params[0].type = _renderParamApiType;
        params[0].data = apiStr.cast<Void>();
        params[1].type = _renderParamInvalid;
        params[1].data = nullptr;
        final rc = renderCreate(outPtr, _handle, params);
        return rc >= 0 ? outPtr.value : nullptr;
      });
      if (ctxOut == nullptr) return false;

      _renderCtx = ctxOut;
      _ensureSwPixelBuffer(safeW, safeH);
      _renderWakeupCallable?.close();
      _renderWakeupCallable = NativeCallable<_MpvWakeupNative>.listener(
        _onRenderFrameUpdate,
      );
      _mpvRenderSetUpdateCb!(
        _renderCtx,
        _renderWakeupCallable!.nativeFunction,
        nullptr,
      );
      return true;
    } catch (_) {
      releaseSoftwareRenderer();
      return false;
    }
  }

  void _onRenderFrameUpdate(Pointer<Void> _) {
    if (_disposed || _renderCtx == nullptr || _renderUpdatesController.isClosed) {
      return;
    }
    _renderUpdatesController.add(null);
  }

  Pointer<Uint8> _ensureSwPixelBuffer(int width, int height) {
    final safeW = LibMpvSoftwareFrameSource.alignDimension(width);
    final safeH = LibMpvSoftwareFrameSource.alignDimension(height);
    final needed = safeW * safeH * 4 + 64;
    final current = _swPixelRawBuffer;
    if (current != null &&
        current != nullptr &&
        _swPixelBufferCapacity >= needed) {
      final alignedAddr = (current.address + 63) & ~63;
      return Pointer<Uint8>.fromAddress(alignedAddr);
    }
    if (current != null && current != nullptr) {
      calloc.free(current);
      _swPixelRawBuffer = null;
    }
    final allocated = calloc<Uint8>(needed);
    _swPixelRawBuffer = allocated;
    _swPixelBufferCapacity = needed;
    final alignedAddr = (allocated.address + 63) & ~63;
    return Pointer<Uint8>.fromAddress(alignedAddr);
  }

  @override
  bool pollSoftwareFrameReady() {
    if (_disposed || _renderCtx == nullptr || _mpvRenderUpdate == null) {
      return false;
    }
    final flags = _mpvRenderUpdate!(_renderCtx);
    return (flags & _renderUpdateFrame) != 0;
  }

  @override
  Uint8List? renderSoftwareFrameBmp({int width = 192, int height = 108}) {
    if (_disposed || _renderCtx == nullptr || _mpvRenderRender == null) {
      return null;
    }
    if (width <= 0 || height <= 0) return null;
    final safeW = LibMpvSoftwareFrameSource.alignDimension(width);
    final safeH = LibMpvSoftwareFrameSource.alignDimension(height);

    final alignedBuf = _ensureSwPixelBuffer(safeW, safeH);
    final strideBytes = safeW * 4;
    final rc = using((arena) {
      final sizeArr = arena<Int32>(2);
      sizeArr[0] = safeW;
      sizeArr[1] = safeH;
      final fmtStr = 'rgb0'.toNativeUtf8(allocator: arena);
      final stridePtr = arena<Size>();
      stridePtr.value = strideBytes;
      final blockPtr = arena<Int32>();
      blockPtr.value = 0;

      final params = arena<_MpvRenderParamNative>(6);
      params[0].type = _renderParamSwSize;
      params[0].data = sizeArr.cast<Void>();
      params[1].type = _renderParamSwFormat;
      params[1].data = fmtStr.cast<Void>();
      params[2].type = _renderParamSwStride;
      params[2].data = stridePtr.cast<Void>();
      params[3].type = _renderParamSwPointer;
      params[3].data = alignedBuf.cast<Void>();
      params[4].type = _renderParamBlockForTargetTime;
      params[4].data = blockPtr.cast<Void>();
      params[5].type = _renderParamInvalid;
      params[5].data = nullptr;
      return _mpvRenderRender!(_renderCtx, params);
    });
    if (rc < 0) return null;

    final copy = Uint8List.fromList(
      alignedBuf.asTypedList(safeW * safeH * 4),
    );
    return encodeRgb0ToBmp(copy, safeW, safeH);
  }

  @override
  void releaseSoftwareRenderer() {
    final ctx = _renderCtx;
    _renderCtx = nullptr;
    if (ctx != nullptr) {
      try {
        _mpvRenderSetUpdateCb?.call(ctx, nullptr, nullptr);
      } catch (_) {}
      try {
        _mpvRenderFree?.call(ctx);
      } catch (_) {}
    }
    _renderWakeupCallable?.close();
    _renderWakeupCallable = null;
    final rawBuf = _swPixelRawBuffer;
    _swPixelRawBuffer = null;
    _swPixelBufferCapacity = 0;
    if (rawBuf != null && rawBuf != nullptr) {
      calloc.free(rawBuf);
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    // 必须先释放 mpv_render_context 再销毁 mpv_handle，遵循 render.h 生命周期约束
    releaseSoftwareRenderer();
    if (!_renderUpdatesController.isClosed) {
      await _renderUpdatesController.close();
    }

    final ptrAddress = _handle.address;
    if (_initialized && ptrAddress != 0) {
      _mpvSetWakeupCallback(_handle, nullptr, nullptr);
    }
    _wakeupCallable?.close();
    _wakeupCallable = null;
    _handle = nullptr;

    if (!_eventsController.isClosed) {
      await _eventsController.close();
    }

    if (ptrAddress == 0) return;

    final libraryPath = _libraryPath;
    await Isolate.run(() {
      final lib = DynamicLibrary.open(libraryPath);
      final terminateDestroy = lib
          .lookupFunction<_MpvTerminateDestroyNative, _MpvTerminateDestroyDart>(
            'mpv_terminate_destroy',
          );
      terminateDestroy(Pointer<Void>.fromAddress(ptrAddress));
    });
  }

  static String _safeReadUtf8(Pointer<Utf8> ptr) {
    if (ptr == nullptr) return '';
    try {
      return ptr.toDartString();
    } catch (_) {
      final bytes = ptr.cast<Uint8>();
      final buf = <int>[];
      var i = 0;
      while (i < 65536) {
        final b = bytes[i];
        if (b == 0) break;
        buf.add(b);
        i++;
      }
      return String.fromCharCodes(buf);
    }
  }

  static String _asString(Object? value) => value is String ? value : '';
  static bool _asBool(Object? value) => value is bool ? value : false;
  static int? _asInt(Object? value) => value is int
      ? value
      : (value is double ? value.round() : null);
  static double? _asDouble(Object? value) => value is double
      ? value
      : (value is int ? value.toDouble() : null);
}

typedef _MultiByteToWideCharNative =
    Int32 Function(
      Uint32 codePage,
      Uint32 dwFlags,
      Pointer<Uint8> lpMultiByteStr,
      Int32 cbMultiByte,
      Pointer<Uint16> lpWideCharStr,
      Int32 cchWideChar,
    );
typedef _MultiByteToWideCharDart =
    int Function(
      int codePage,
      int dwFlags,
      Pointer<Uint8> lpMultiByteStr,
      int cbMultiByte,
      Pointer<Uint16> lpWideCharStr,
      int cchWideChar,
    );

/// 基于 Windows `kernel32.dll` (`MultiByteToWideChar`) 的高精度 CP932/CP936 解码器，
/// 为纯领域层 [CueParser] / [LrcParser] 注入完整 Shift-JIS 汉字与 GBK 解码能力。
class WindowsCodePageDecoder {
  WindowsCodePageDecoder._();

  static _MultiByteToWideCharDart? _cachedFn;

  /// 将原始字节通过 Windows 代码页解码为 UTF-16 字符串（非 Windows 环境返回 null）。
  static String? decode(List<int> bytes, LegacyTextEncoding encoding) {
    if (!Platform.isWindows || bytes.isEmpty) return null;
    final fn = _cachedFn ??= DynamicLibrary.open('kernel32.dll')
        .lookupFunction<_MultiByteToWideCharNative, _MultiByteToWideCharDart>(
          'MultiByteToWideChar',
        );
    final codePage = switch (encoding) {
      LegacyTextEncoding.shiftJis => 932,
      LegacyTextEncoding.gbk => 936,
    };

    return using((arena) {
      final src = arena<Uint8>(bytes.length);
      src.asTypedList(bytes.length).setAll(0, bytes);
      final needed = fn(codePage, 0, src, bytes.length, nullptr, 0);
      if (needed <= 0) return null;
      final dst = arena<Uint16>(needed);
      final written = fn(codePage, 0, src, bytes.length, dst, needed);
      if (written <= 0) return null;
      return String.fromCharCodes(dst.asTypedList(written));
    });
  }
}
