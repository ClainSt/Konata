part of 'libmpv_ffi.dart';

/// libmpv C API 标准错误码。
abstract final class MpvError {
  static const int success = 0;
  static const int optionNotFound = -5;
  static const int propertyNotFound = -8;
  static const int propertyFormat = -9;
  static const int propertyUnavailable = -10;
  static const int loadingFailed = -13;
  static const int aoInitFailed = -14;
  static const int voInitFailed = -15;
  static const int nothingToPlay = -16;

  /// 将 libmpv 结束错误码转译为准确的简体中文音频诊断说明。
  static String describeAudioError(int errorCode) {
    return switch (errorCode) {
      nothingToPlay => '未找到可播放音轨或音频流未被选中 (code: $nothingToPlay)',
      loadingFailed => '音频流打开或解复用失败 (code: $loadingFailed)',
      aoInitFailed => '音频输出设备初始化失败 (code: $aoInitFailed)',
      _ => '音频加载或播放异常 (code: $errorCode)',
    };
  }
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

/// 支持动态退订已监听属性的 `libmpv` 扩展接口（用于 OSD 隐藏稳态期挂起 `time-pos` 零唤醒）。
abstract interface class LibMpvUnobservable {
  /// 取消指定 `replyUserdata` 对应的属性订阅（底层调用 `mpv_unobserve_property`）。
  int unobserveProperty(int registeredReplyUserdata);
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

typedef _MpvUnobservePropertyNative =
    Int32 Function(Pointer<Void> mpv, Uint64 registeredReplyUserdata);
typedef _MpvUnobservePropertyDart =
    int Function(Pointer<Void> mpv, int registeredReplyUserdata);

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

typedef _MediaKitGetJavaVmNative = Pointer<Void> Function();
typedef _MediaKitGetJavaVmDart = Pointer<Void> Function();

typedef _AvJniSetJavaVmNative =
    Int32 Function(Pointer<Void> vm, Pointer<Void> logCtx);
typedef _AvJniSetJavaVmDart =
    int Function(Pointer<Void> vm, Pointer<Void> logCtx);

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

  // 位图文件头 BITMAPFILEHEADER（14 字节，魔数为 BM）
  bmp[0] = 0x42;
  bmp[1] = 0x4D;
  view.setUint32(2, fileSize, Endian.little);
  view.setUint32(10, 54, Endian.little);

  // 位图信息头 BITMAPINFOHEADER（40 字节）
  view.setUint32(14, 40, Endian.little);
  view.setInt32(18, width, Endian.little);
  view.setInt32(22, height, Endian.little);
  view.setUint16(26, 1, Endian.little);
  view.setUint16(28, 24, Endian.little);
  view.setUint32(34, pixelDataSize, Endian.little);

  // 将 rgb0 像素序重排为 BMP 所需的倒置蓝绿红字节序
  final srcStride = width * 4;
  for (var y = 0; y < height; y++) {
    final srcRowOffset = (height - 1 - y) * srcStride;
    final dstRowOffset = 54 + y * rowStride;
    for (var x = 0; x < width; x++) {
      final si = srcRowOffset + x * 4;
      final di = dstRowOffset + x * 3;
      bmp[di] = rgb0[si + 2];
      bmp[di + 1] = rgb0[si + 1];
      bmp[di + 2] = rgb0[si];
    }
  }
  return bmp;
}

