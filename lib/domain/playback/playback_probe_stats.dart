/// 播放状态探针使用的章节结构（已将负时间戳归零校准）。
class PlaybackChapter {
  /// 创建章节实例。
  const PlaybackChapter({
    required this.index,
    required this.title,
    required this.startSeconds,
    this.endSeconds,
  });

  /// 章节序号（从 0 开始）。
  final int index;

  /// 章节标题（可能为空或通用名称如 `Chapter 01`）。
  final String title;

  /// 校准后的章节起始秒数（永不为负）。
  final double startSeconds;

  /// 校准后的章节结束秒数（若可推导）。
  final double? endSeconds;

  /// 章节持续时长（秒）；若结束时间未知则返回 null。
  double? get durationSeconds {
    if (endSeconds == null) return null;
    final diff = endSeconds! - startSeconds;
    return diff > 0 ? diff : 0;
  }
}

/// libmpv 枚举到的可用音频输出设备描述。
class MpvAudioDevice {
  /// 创建音频设备描述。
  const MpvAudioDevice({required this.name, required this.description});

  /// 设备标识符（如 `wasapi/{...}` 或 `auto`）。
  final String name;

  /// 人类可读设备名称。
  final String description;
}

/// 播放器实时音画与缓存遥测快照（40+ 项指标强类型建模）。
///
/// 严格纯领域对象，仅通过控制器/服务层推送给界面探针面板与规格徽标。
class PlaybackProbeStats {
  /// 创建实时音画遥测快照。
  const PlaybackProbeStats({
    this.mpvVersion = '',
    this.ffmpegVersion = '',
    this.voBackend = '',
    this.hwdecCurrent = '',
    this.hwdecInterop = '',
    this.gpuApi = '',
    this.videoCodec = '',
    this.videoProfile = '',
    this.videoPixelFormat = '',
    this.videoHwPixelFormat = '',
    this.videoBitrateBps,
    this.containerFormat = '',
    this.videoWidth,
    this.videoHeight,
    this.displayWidth,
    this.displayHeight,
    this.targetWidth,
    this.targetHeight,
    this.pixelAspect,
    this.rotationDegrees,
    this.containerFps,
    this.estimatedVfFps,
    this.displayFps,
    this.avSyncMs,
    this.droppedFramesDecoder,
    this.droppedFramesVo,
    this.delayedFrames,
    this.mistimedFrames,
    this.colorPrimaries = '',
    this.colorGamma = '',
    this.colorMatrix = '',
    this.colorRange = '',
    this.colorLevels = '',
    this.hdrPeakNits,
    this.sigPeak,
    this.toneMapping = '',
    this.debandEnabled = false,
    this.scaleFilter = '',
    this.cscaleFilter = '',
    this.dscaleFilter = '',
    this.ditherDepth = '',
    this.activeShaderNames = const [],
    this.audioCodec = '',
    this.audioSampleRateHz,
    this.audioChannelCount,
    this.audioChannelLayout = '',
    this.audioBitrateBps,
    this.audioFormat = '',
    this.audioOutBackend = '',
    this.audioDeviceName = '',
    this.audioExclusive = false,
    this.demuxerCacheSeconds,
    this.demuxerCacheBytes,
    this.cacheSpeedBps,
    this.cachePercent,
    this.pausedForCache = false,
    this.isSeeking = false,
    this.positionSeconds = 0,
    this.durationSeconds = 0,
    this.speed = 1.0,
    this.chapterIndex,
    this.chapterCount = 0,
    this.subtitleDelaySeconds = 0,
    this.audioDelaySeconds = 0,
  });

  /// libmpv 运行时版本字符串。
  final String mpvVersion;

  /// 内嵌 FFmpeg 版本字符串。
  final String ffmpegVersion;

  /// 视频输出驱动名称（如 `libmpv` / `gpu`）。
  final String voBackend;

  /// 当前激活硬解模式（如 `d3d11va` / `mediacodec` / `no`）。
  final String hwdecCurrent;

  /// 硬解互操作模式。
  final String hwdecInterop;

  /// 图形渲染 API（如 `d3d11` / `sw` / `android-surface`）。
  final String gpuApi;

  /// 视频编码器名称（如 `hevc` / `h264` / `av1`）。
  final String videoCodec;

  /// 视频编码 Profile（如 `Main 10`）。
  final String videoProfile;

  /// 解码像素格式（如 `yuv420p10le`）。
  final String videoPixelFormat;

  /// 硬件表面像素格式（如 `p010` / `nv12`）。
  final String videoHwPixelFormat;

  /// 视频码率（bps）。
  final int? videoBitrateBps;

  /// 容器封装格式（如 `matroska,webm` / `flac`）。
  final String containerFormat;

  /// 原始视频宽度（px）。
  final int? videoWidth;

  /// 原始视频高度（px）。
  final int? videoHeight;

  /// 显示缩放宽度（px）。
  final int? displayWidth;

  /// 显示缩放高度（px）。
  final int? displayHeight;

  /// 渲染目标宽度（px）。
  final int? targetWidth;

  /// 渲染目标高度（px）。
  final int? targetHeight;

  /// 像素纵横比。
  final double? pixelAspect;

  /// 视频旋转角度（度）。
  final int? rotationDegrees;

  /// 容器声明帧率（fps）。
  final double? containerFps;

  /// 视频滤镜链输出估算帧率（fps）。
  final double? estimatedVfFps;

  /// 显示器刷新率（Hz）。
  final double? displayFps;

  /// 音画同步偏差（毫秒）。
  final double? avSyncMs;

  /// 解码器丢帧计数。
  final int? droppedFramesDecoder;

  /// 视频输出丢帧计数。
  final int? droppedFramesVo;

  /// 延迟帧计数。
  final int? delayedFrames;

  /// 错帧计数。
  final int? mistimedFrames;

  /// 原色域标准（如 `bt.709` / `bt.2020`）。
  final String colorPrimaries;

  /// 传递函数（如 `bt.1886` / `pq` / `hlg`）。
  final String colorGamma;

  /// 色彩矩阵（如 `bt.709` / `bt.2020-ncl`）。
  final String colorMatrix;

  /// 色彩量化范围（`limited` / `full`）。
  final String colorRange;

  /// 输入电平标记。
  final String colorLevels;

  /// HDR 信号峰值亮度（nits）。
  final double? hdrPeakNits;

  /// 相对亮度峰值比。
  final double? sigPeak;

  /// HDR 色调映射算法。
  final String toneMapping;

  /// 是否开启去色带。
  final bool debandEnabled;

  /// 亮度上采样核（如 `ewa_lanczossharp` / `spline36`）。
  final String scaleFilter;

  /// 色度上采样核。
  final String cscaleFilter;

  /// 下采样核。
  final String dscaleFilter;

  /// 抖动位深配置。
  final String ditherDepth;

  /// 当前激活的着色器名称列表。
  final List<String> activeShaderNames;

  /// 音频编码器（如 `flac` / `aac` / `opus`）。
  final String audioCodec;

  /// 音频采样率（Hz）。
  final int? audioSampleRateHz;

  /// 声道数量。
  final int? audioChannelCount;

  /// 声道布局（如 `stereo` / `5.1`）。
  final String audioChannelLayout;

  /// 音频码率（bps）。
  final int? audioBitrateBps;

  /// 音频输出采样格式（如 `float` / `s24` / `s16`）。
  final String audioFormat;

  /// 音频输出后端（如 `wasapi` / `aaudio`）。
  final String audioOutBackend;

  /// 当前激活音频输出设备。
  final String audioDeviceName;

  /// 是否以独占模式开启。
  final bool audioExclusive;

  /// 解复用器前向缓冲秒数。
  final double? demuxerCacheSeconds;

  /// 解复用器当前占用内存字节数。
  final int? demuxerCacheBytes;

  /// 当前缓存拉流速度（bytes/s）。
  final int? cacheSpeedBps;

  /// 缓冲百分比（0-100）。
  final int? cachePercent;

  /// 是否正在因缓存不足而等待。
  final bool pausedForCache;

  /// 是否正处于跳转定位状态。
  final bool isSeeking;

  /// 当前播放位置（秒，已校准负 PTS）。
  final double positionSeconds;

  /// 总时长（秒）。
  final double durationSeconds;

  /// 当前播放倍速。
  final double speed;

  /// 当前所处章节索引。
  final int? chapterIndex;

  /// 总章节数量。
  final int chapterCount;

  /// 字幕时间偏移（秒）。
  final double subtitleDelaySeconds;

  /// 音频时间偏移（秒）。
  final double audioDelaySeconds;

  /// 校准 BDRip 等封装首章/首帧可能携带的微负 PTS（如 `-0.08s`）为 `0.0`。
  static double clampChapterZeroPts(double rawSeconds) {
    if (!rawSeconds.isFinite || rawSeconds <= 0.0) {
      return 0.0;
    }
    return rawSeconds;
  }

  /// 对整组章节列表执行首章负 PTS 归零并补充后章推算结束时间。
  static List<PlaybackChapter> normalizeChapters(
    List<PlaybackChapter> rawChapters, {
    double? totalDurationSeconds,
  }) {
    if (rawChapters.isEmpty) return const [];
    final sorted = List<PlaybackChapter>.from(rawChapters)
      ..sort((a, b) => a.index.compareTo(b.index));

    final normalized = <PlaybackChapter>[];
    for (var i = 0; i < sorted.length; i++) {
      final current = sorted[i];
      final start = clampChapterZeroPts(current.startSeconds);
      double? end = current.endSeconds;
      if (end != null) {
        end = clampChapterZeroPts(end);
      } else if (i + 1 < sorted.length) {
        end = clampChapterZeroPts(sorted[i + 1].startSeconds);
      } else if (totalDurationSeconds != null &&
          totalDurationSeconds.isFinite &&
          totalDurationSeconds > start) {
        end = totalDurationSeconds;
      }
      normalized.add(
        PlaybackChapter(
          index: current.index,
          title: current.title,
          startSeconds: start,
          endSeconds: end,
        ),
      );
    }
    return normalized;
  }
}
