import 'dart:typed_data';

import 'package:engine_playback/engine_playback.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

/// 音频列表循环模式。
enum AudioLoopMode {
  /// 顺序播放至队尾停止。
  sequence,

  /// 列表整体循环。
  loopAll,

  /// 单曲循环。
  loopOne;

  /// 按名称解析循环模式，未知值回退列表循环。
  static AudioLoopMode parse(Object? raw) {
    if (raw is String) {
      for (final mode in values) {
        if (mode.name == raw) return mode;
      }
    }
    return AudioLoopMode.loopAll;
  }
}

/// 专辑封面来源密封类型（严格区分内存内嵌图/目录图与托管海报回退）。
sealed class AudioCoverSource {
  /// 构造封面来源基类。
  const AudioCoverSource();
}

/// 来自音轨内嵌封面或同目录专辑封面图片的字节流。
final class MemoryAudioCover extends AudioCoverSource {
  /// 使用原始图片字节构造封面来源。
  const MemoryAudioCover(this.bytes);

  /// 原始编码图片字节。
  final Uint8List bytes;
}

/// 回退使用作品管理海报引用或远端海报链接。
final class ManagedPosterAudioCover extends AudioCoverSource {
  /// 构造托管海报回退封面。
  const ManagedPosterAudioCover({
    this.artworkRef,
    this.fallbackUrl,
  });

  /// 契约级作品海报引用。
  final ArtworkRef? artworkRef;

  /// 兜底 URL 或本地路径。
  final String? fallbackUrl;
}

/// 无可用封面时的空白占位标记（避免渲染任何错误图标）。
final class EmptyAudioCover extends AudioCoverSource {
  /// 构造空封面占位。
  const EmptyAudioCover();
}

/// 队列抽屉与分组列表项行类型。
enum AudioQueueDisplayRowKind {
  /// 普通独立音轨条目。
  singleTrack,

  /// 整轨分轨清单折叠标题头。
  cueHeader,

  /// 已展开清单下的虚拟音轨子项。
  cueTrack,
}

/// 用于界面渲染的队列视图行描述。
class AudioQueueDisplayRow {
  /// 创建队列渲染行模型。
  const AudioQueueDisplayRow({
    required this.kind,
    required this.queueIndex,
    required this.item,
    this.isActive = false,
  });

  /// 行类型（普通音轨 / 清单头 / 清单子轨）。
  final AudioQueueDisplayRowKind kind;

  /// 对应控制器物理播放队列中的索引（非展开清单头时指向代表索引）。
  final int queueIndex;

  /// 关联曲目条目。
  final AudioQueueItem item;

  /// 是否为当前正在播放的活动曲目。
  final bool isActive;
}

/// 音频播放队列单项领域模型（支持普通音轨与动态 `.cue` 分轨）。
class AudioQueueItem {
  /// 创建队列条目。
  const AudioQueueItem({
    required this.itemId,
    required this.workId,
    required this.sourceId,
    required this.variantId,
    required this.title,
    required this.artist,
    required this.album,
    required this.albumKey,
    required this.fileName,
    required this.relativePath,
    required this.source,
    required this.variant,
    this.isCueTrack = false,
    this.cueSheetPath,
    this.cueTrackIndex,
    this.cueTrackTitle,
    this.startSeconds = 0.0,
    this.endSeconds,
    this.durationSeconds = 0.0,
    this.knownFileSize,
    this.cueExpanded = false,
    this.posterRef,
    this.posterFallback,
    this.bangumiSubjectId,
    this.embeddedLrcText,
  });

  /// 全队列唯一定位键（普通文件为变体标识，分轨附加清单路径与轨号）。
  final String itemId;

  /// 所属作品标识。
  final WorkId workId;

  /// 所属媒体源标识。
  final SourceId sourceId;

  /// 对应音轨文件变体标识。
  final VariantId variantId;

  /// 展示曲名。
  final String title;

  /// 演出者或作曲名。
  final String artist;

  /// 所属专辑名称。
  final String album;

  /// 用于多碟芯片过滤的稳定专辑键。
  final String albumKey;

  /// 原始文件名。
  final String fileName;

  /// 音轨在媒体源内的标准化相对路径。
  final String relativePath;

  /// 媒体源只读视图。
  final MediaSourceView source;

  /// 数据库媒体变体实体。
  final MediaVariantRecord variant;

  /// 是否属于 `.cue` 虚拟分轨条目。
  final bool isCueTrack;

  /// 若关联分轨清单，存储对应 `.cue` 文件相对路径。
  final String? cueSheetPath;

  /// 轨号（从 1 开始；未展开前或单文件可为空）。
  final int? cueTrackIndex;

  /// 清单内解析出的独立轨名。
  final String? cueTrackTitle;

  /// 物理流起播秒数偏移。
  final double startSeconds;

  /// 物理流结束秒数上限（为空表示直至物理流末尾）。
  final double? endSeconds;

  /// 本逻辑曲目的有效估算时长（秒）。
  final double durationSeconds;

  /// 已知物理文件字节长度。
  final int? knownFileSize;

  /// 清单条目是否已在队列中展开出子轨。
  final bool cueExpanded;

  /// 所属作品封面引用。
  final ArtworkRef? posterRef;

  /// 所属作品封面兜底链接。
  final String? posterFallback;

  /// 关联 Bangumi 条目编号。
  final int? bangumiSubjectId;

  /// 已探测到的内嵌或随附歌词文本（供切歌低频同步给歌词端口）。
  final String? embeddedLrcText;

  /// 当前曲目是否属于未解析展开的 `.cue` 清单头。
  bool get isUnexpandedCueManifest =>
      cueSheetPath != null && !isCueTrack && cueTrackIndex == null;

  /// 复制并按需替换局部属性。
  AudioQueueItem copyWith({
    String? title,
    String? artist,
    String? album,
    double? durationSeconds,
    double? endSeconds,
    bool? cueExpanded,
    String? embeddedLrcText,
  }) {
    return AudioQueueItem(
      itemId: itemId,
      workId: workId,
      sourceId: sourceId,
      variantId: variantId,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      albumKey: albumKey,
      fileName: fileName,
      relativePath: relativePath,
      source: source,
      variant: variant,
      isCueTrack: isCueTrack,
      cueSheetPath: cueSheetPath,
      cueTrackIndex: cueTrackIndex,
      cueTrackTitle: cueTrackTitle,
      startSeconds: startSeconds,
      endSeconds: endSeconds ?? this.endSeconds,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      knownFileSize: knownFileSize,
      cueExpanded: cueExpanded ?? this.cueExpanded,
      posterRef: posterRef,
      posterFallback: posterFallback,
      bangumiSubjectId: bangumiSubjectId,
      embeddedLrcText: embeddedLrcText ?? this.embeddedLrcText,
    );
  }

  /// 构造低频传递给歌词端口的曲目检索查询对象。
  LyricTrackQuery toLyricTrackQuery({
    double? resolvedDurationSeconds,
    String? overrideEmbeddedLrcText,
  }) {
    return LyricTrackQuery(
      trackKey: itemId,
      title: title,
      workId: workId,
      variantId: variantId,
      sourceId: sourceId,
      artist: artist,
      album: album,
      albumKey: albumKey,
      fileName: fileName,
      relativePath: relativePath,
      durationSeconds: (resolvedDurationSeconds ?? durationSeconds) > 0
          ? (resolvedDurationSeconds ?? durationSeconds)
          : 0.0,
      bangumiSubjectId: bangumiSubjectId,
      embeddedLrcText: overrideEmbeddedLrcText ?? embeddedLrcText,
      cueTrackIndex: cueTrackIndex,
    );
  }
}

/// 音频会话宏观运行态。
enum AudioPlaybackStatus {
  /// 尚未激活或已销毁会话。
  idle,

  /// 正在拉取媒体流或解析清单。
  loading,

  /// 正在稳定播放。
  playing,

  /// 已暂停。
  paused,

  /// 当前曲目遇到不可恢复读取或解码错误。
  error,
}

/// 音频播放控制器对外暴露的低频不可变状态快照。
///
/// 高频播放位置与总时长刻意分离到独立叶子 `ValueNotifier<Duration>`，
/// 避免每秒计时更新触发整页级组件重建。
class AudioPlaybackSnapshot {
  /// 创建不可变音频会话状态快照。
  const AudioPlaybackSnapshot({
    this.status = AudioPlaybackStatus.idle,
    this.isActive = false,
    this.isBuffering = false,
    this.queue = const [],
    this.currentIndex = -1,
    this.playOrder = const [],
    this.playOrderPos = -1,
    this.loopMode = AudioLoopMode.loopAll,
    this.shuffleEnabled = false,
    this.cover = const EmptyAudioCover(),
    this.coverVariantTag,
    this.volume = 85.0,
    this.isMuted = false,
    this.errorMessage,
    this.sampleRateHz = 0,
    this.bitDepth = 0,
    this.channelCount = 0,
    this.audioCodecName = '',
    this.bitrateKbps = 0,
    this.audiophileSafetyState = const AudioDeviceSafetyState(),
    this.audiophilePlan = const AudioSafetyChainPlan(
      routeMode: AudioOutputRouteMode.sharedResampled,
      gaplessAudioMode: AudiophileSafetyPolicy.unifiedGaplessMode,
      prefetchPlaylist: true,
      audioFilterString: AudiophileSafetyPolicy.postDspSafetyLimiterFilter,
      audioSpdifCodecs: '',
      safetyLimiterEngaged: true,
      microFadeInDurationMs: AudiophileSafetyPolicy.defaultMicroFadeInMs,
    ),
    this.availableAudioDevices = const [],
    this.expandedCuePaths = const {},
    this.isDesktopMiniWindow = false,
    this.audioTrackEndActionPending = false,
  });

  /// 当前会话状态枚举。
  final AudioPlaybackStatus status;

  /// 是否存在激活中的音频播放会话。
  final bool isActive;

  /// 当前网络或解码管线是否处于缓冲等待。
  final bool isBuffering;

  /// 当前全部队列条目（含待展开或已展开分轨）。
  final List<AudioQueueItem> queue;

  /// 当前播放索引（在 [queue] 中的下标；无曲目时为 `-1`）。
  final int currentIndex;

  /// 当前循环与随机模式对应的逻辑播放次序索引表。
  final List<int> playOrder;

  /// 当前曲目在 [playOrder] 中的位置。
  final int playOrderPos;

  /// 循环模式。
  final AudioLoopMode loopMode;

  /// 是否开启随机乱序模式。
  final bool shuffleEnabled;

  /// 当前生效的封面图来源。
  final AudioCoverSource cover;

  /// 当前封面所属版本标识（用于流光缓存隔离）。
  final String? coverVariantTag;

  /// 当前目标音量百分比（0 ~ 100）。
  final double volume;

  /// 当前是否静音。
  final bool isMuted;

  /// 最近一次可读失败提示信息。
  final String? errorMessage;

  /// 探测到的当前音频采样率（Hz）。
  final int sampleRateHz;

  /// 探测到的当前量化位深（bit）。
  final int bitDepth;

  /// 探测到的当前声道数。
  final int channelCount;

  /// 探测到的编码格式名称。
  final String audioCodecName;

  /// 探测到的码率（kbps）。
  final int bitrateKbps;

  /// 发烧安全链硬件态与Session解锁状态。
  final AudioDeviceSafetyState audiophileSafetyState;

  /// 发烧安全链当下生效输出方案（含 `-12 dBFS` 限幅天花板标牌）。
  final AudioSafetyChainPlan audiophilePlan;

  /// 底层探测到的系统输出设备清单。
  final List<MpvAudioDevice> availableAudioDevices;

  /// 已经展开为虚拟音轨的 `.cue` 清单标准化路径集合。
  final Set<String> expandedCuePaths;

  /// 桌面端当前是否处于顶置小窗形态。
  final bool isDesktopMiniWindow;

  /// 是否正在处理曲末自动切换动作。
  final bool audioTrackEndActionPending;

  /// 当前正在播放的队列曲目对象（无有效索引时返回 `null`）。
  AudioQueueItem? get currentItem {
    if (currentIndex < 0 || currentIndex >= queue.length) {
      return null;
    }
    return queue[currentIndex];
  }

  /// 生成用于展示的规范音质规格徽标文本（如 `FLAC · 24bit/96kHz`）。
  String get formattedAudioSpec {
    final codec = audioCodecName.trim().toUpperCase();
    final parts = <String>[];
    if (codec.isNotEmpty) {
      parts.add(codec);
    }
    if (bitDepth > 0 && sampleRateHz > 0) {
      final khz = sampleRateHz % 1000 == 0
          ? '${sampleRateHz ~/ 1000}kHz'
          : '${(sampleRateHz / 1000.0).toStringAsFixed(1)}kHz';
      parts.add('${bitDepth}bit/$khz');
    } else if (sampleRateHz > 0) {
      final khz = sampleRateHz % 1000 == 0
          ? '${sampleRateHz ~/ 1000}kHz'
          : '${(sampleRateHz / 1000.0).toStringAsFixed(1)}kHz';
      parts.add(khz);
    }
    if (bitrateKbps > 0 && bitDepth <= 0) {
      parts.add('${bitrateKbps}kbps');
    }
    return parts.join(' · ');
  }

  /// 复制并局部更新状态快照。
  AudioPlaybackSnapshot copyWith({
    AudioPlaybackStatus? status,
    bool? isActive,
    bool? isBuffering,
    List<AudioQueueItem>? queue,
    int? currentIndex,
    List<int>? playOrder,
    int? playOrderPos,
    AudioLoopMode? loopMode,
    bool? shuffleEnabled,
    AudioCoverSource? cover,
    String? coverVariantTag,
    bool clearCoverVariantTag = false,
    double? volume,
    bool? isMuted,
    String? errorMessage,
    bool clearErrorMessage = false,
    int? sampleRateHz,
    int? bitDepth,
    int? channelCount,
    String? audioCodecName,
    int? bitrateKbps,
    AudioDeviceSafetyState? audiophileSafetyState,
    AudioSafetyChainPlan? audiophilePlan,
    List<MpvAudioDevice>? availableAudioDevices,
    Set<String>? expandedCuePaths,
    bool? isDesktopMiniWindow,
    bool? audioTrackEndActionPending,
  }) {
    return AudioPlaybackSnapshot(
      status: status ?? this.status,
      isActive: isActive ?? this.isActive,
      isBuffering: isBuffering ?? this.isBuffering,
      queue: queue ?? this.queue,
      currentIndex: currentIndex ?? this.currentIndex,
      playOrder: playOrder ?? this.playOrder,
      playOrderPos: playOrderPos ?? this.playOrderPos,
      loopMode: loopMode ?? this.loopMode,
      shuffleEnabled: shuffleEnabled ?? this.shuffleEnabled,
      cover: cover ?? this.cover,
      coverVariantTag: clearCoverVariantTag
          ? null
          : (coverVariantTag ?? this.coverVariantTag),
      volume: volume ?? this.volume,
      isMuted: isMuted ?? this.isMuted,
      errorMessage: clearErrorMessage
          ? null
          : (errorMessage ?? this.errorMessage),
      sampleRateHz: sampleRateHz ?? this.sampleRateHz,
      bitDepth: bitDepth ?? this.bitDepth,
      channelCount: channelCount ?? this.channelCount,
      audioCodecName: audioCodecName ?? this.audioCodecName,
      bitrateKbps: bitrateKbps ?? this.bitrateKbps,
      audiophileSafetyState:
          audiophileSafetyState ?? this.audiophileSafetyState,
      audiophilePlan: audiophilePlan ?? this.audiophilePlan,
      availableAudioDevices:
          availableAudioDevices ?? this.availableAudioDevices,
      expandedCuePaths: expandedCuePaths ?? this.expandedCuePaths,
      isDesktopMiniWindow: isDesktopMiniWindow ?? this.isDesktopMiniWindow,
      audioTrackEndActionPending:
          audioTrackEndActionPending ?? this.audioTrackEndActionPending,
    );
  }
}
