part of 'audio_playback_notifier.dart';

/// CD 音频播放循环模式。
enum AudioLoopMode {
  sequence('顺序播放'),
  loopAll('列表循环'),
  loopOne('单曲循环');

  const AudioLoopMode(this.label);
  final String label;

  AudioLoopMode nextMode() => switch (this) {
    AudioLoopMode.sequence => AudioLoopMode.loopAll,
    AudioLoopMode.loopAll => AudioLoopMode.loopOne,
    AudioLoopMode.loopOne => AudioLoopMode.sequence,
  };
}

/// 三级回退专辑封面源密封类型。
sealed class AudioCoverSource {
  const AudioCoverSource();
}

/// 优先级 1/2：内存解析出的音轨内嵌封面或 CD 目录封面图。
class MemoryAudioCover extends AudioCoverSource {
  const MemoryAudioCover(this.bytes);
  final Uint8List bytes;

  /// 计算轻量内容指纹（避免同图不同 Uint8List 实例触发流光背景与封面重复闪烁）。
  int get contentHash {
    final len = bytes.length;
    if (len == 0) return 0;
    var hash = 0x811C9DC5 ^ len;
    final step = len <= 64 ? 1 : len ~/ 64;
    for (var i = 0; i < len; i += step) {
      hash = ((hash ^ bytes[i]) * 0x01000193) & 0x7FFFFFFF;
    }
    hash = ((hash ^ bytes[len - 1]) * 0x01000193) & 0x7FFFFFFF;
    return hash;
  }

  /// 判断两份字节封面是否包含完全一致的字节签名。
  static bool sameContent(Uint8List a, Uint8List b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    final len = a.length;
    if (len == 0) return true;
    final step = len <= 64 ? 1 : len ~/ 64;
    for (var i = 0; i < len; i += step) {
      if (a[i] != b[i]) return false;
    }
    return a[len - 1] == b[len - 1];
  }
}

/// 优先级 3：作品海报或 Bangumi 封面兜底。
class ManagedPosterAudioCover extends AudioCoverSource {
  const ManagedPosterAudioCover({
    required this.url,
    required this.workId,
    this.revision = 0,
  });
  final String url;
  final String workId;
  final int revision;
}

/// 无封面兜底状态。
class EmptyAudioCover extends AudioCoverSource {
  const EmptyAudioCover();
}

/// 播放队列视觉展示行类型（供全屏流光页与迷你栏曲目浮层同源渲染）。
enum AudioQueueDisplayRowKind {
  /// 普通单曲或尚未展开的整轨 CD（左侧显示连续主序号）。
  standalone,

  /// 当前轮到播放并已拆开分轨的整轨 CD 主标题行（左侧显示连续主序号）。
  cueParent,

  /// 整轨 CD 正下方拆开显示的子单曲行（左侧缩进且不显示数字序号）。
  cueSubTrack,
}

/// 播放队列视觉展示行投影。
class AudioQueueDisplayRow {
  const AudioQueueDisplayRow({
    required this.id,
    required this.kind,
    required this.trackPrefix,
    required this.title,
    required this.subtitle,
    required this.duration,
    required this.targetQueueIndex,
    required this.isActiveTrack,
    this.isExpandedParent = false,
  });

  final String id;
  final AudioQueueDisplayRowKind kind;
  final String trackPrefix;
  final String title;
  final String subtitle;
  final Duration duration;
  final int targetQueueIndex;
  final bool isActiveTrack;
  final bool isExpandedParent;
}

/// 统一 CD / 无损音频播放队列条目（同时支持单曲物理文件与 `.cue` 虚拟分轨）。
class AudioQueueItem {
  const AudioQueueItem({
    required this.id,
    required this.work,
    required this.variant,
    this.source,
    required this.title,
    this.performer = '',
    this.albumTitle = '',
    this.trackNumber,
    this.cueStartSeconds,
    this.cueEndSeconds,
    this.targetAudioRelativePath,
    this.duration = Duration.zero,
    this.versionBadge = '',
    this.showAlbumSubtitle = false,
    this.pairedCueVariant,
    this.cueDiscTitle = '',
  });

  final String id;
  final Work work;
  final MediaVariant variant;
  final MediaSource? source;
  final String title;
  final String performer;
  final String albumTitle;
  final int? trackNumber;
  final double? cueStartSeconds;
  final double? cueEndSeconds;
  final String? targetAudioRelativePath;
  final Duration duration;
  final String versionBadge;
  final bool showAlbumSubtitle;

  /// 同目录配对的 `.cue` 清单变体（用于轮到该整轨 CD 时按需展开与离开时折叠）。
  final MediaVariant? pairedCueVariant;

  /// 整轨 CD 拆开子单曲后对应的母碟主行展示名称。
  final String cueDiscTitle;

  bool get isCueTrack => cueStartSeconds != null;
  String get effectiveRelativePath =>
      targetAudioRelativePath ?? variant.relativePath;
  String get effectiveFileName => p.basename(effectiveRelativePath);

  /// 归属物理母文件的唯一流标识（供 CUE 尾轨时长回填与同母文件无损过界判定）。
  String get physicalFileKey =>
      '${source?.id ?? 'local'}::${effectiveRelativePath.replaceAll('\\', '/')}';

  /// 专辑 / 音频父目录内存缓存键（供同专辑切歌同步零闪烁继承封面与流光色板）。
  String get albumCacheKey {
    final dir = p.posix.dirname(effectiveRelativePath.replaceAll('\\', '/'));
    final normalizedDir = dir == '.' ? '' : dir;
    return '${work.id}::${source?.id ?? 'local'}::$normalizedDir';
  }

  /// 解析当前曲目的已知时长（优先返回已回填的 [duration]，其次按 CUE 首尾差计算）。
  Duration get resolvedDuration {
    if (duration > Duration.zero) return duration;
    if (cueStartSeconds != null &&
        cueEndSeconds != null &&
        cueEndSeconds! > cueStartSeconds!) {
      return Duration(
        milliseconds: ((cueEndSeconds! - cueStartSeconds!) * 1000).round(),
      );
    }
    return Duration.zero;
  }

  AudioQueueItem copyWith({
    Work? work,
    Duration? duration,
    double? cueEndSeconds,
    MediaVariant? pairedCueVariant,
    String? cueDiscTitle,
  }) {
    return AudioQueueItem(
      id: id,
      work: work ?? this.work,
      variant: variant,
      source: source,
      title: title,
      performer: performer,
      albumTitle: albumTitle,
      trackNumber: trackNumber,
      cueStartSeconds: cueStartSeconds,
      cueEndSeconds: cueEndSeconds ?? this.cueEndSeconds,
      targetAudioRelativePath: targetAudioRelativePath,
      duration: duration ?? this.duration,
      versionBadge: versionBadge,
      showAlbumSubtitle: showAlbumSubtitle,
      pairedCueVariant: pairedCueVariant ?? this.pairedCueVariant,
      cueDiscTitle: cueDiscTitle ?? this.cueDiscTitle,
    );
  }

  String get displaySubtitle {
    final parts = <String>[];
    if (performer.trim().isNotEmpty) {
      parts.add(performer.trim());
    }
    if (albumTitle.trim().isNotEmpty) {
      parts.add(albumTitle.trim());
    } else if (work.title.trim().isNotEmpty) {
      parts.add(work.title.trim());
    }
    return parts.join(' · ');
  }
}

/// 全局纯音频（`vid=no`, `vo=null`）播放状态模型。
class AudioPlaybackState {
  const AudioPlaybackState({
    this.isActive = false,
    this.isPlaying = false,
    this.isBuffering = false,
    this.queue = const [],
    this.currentIndex = -1,
    this.positionSeconds = 0.0,
    this.durationSeconds = 0.0,
    this.volume = 100.0,
    this.isMuted = false,
    this.loopMode = AudioLoopMode.loopAll,
    this.cover = const EmptyAudioCover(),
    this.lrcDocument,
    this.activeSpanLines = const [],
    this.activeLyricIndex = -1,
    this.audioCodecLabel = '',
    this.sampleRateAndBitDepthLabel = '',
    this.bitrateLabel = '',
    this.errorMessage,
  });

  final bool isActive;
  final bool isPlaying;
  final bool isBuffering;
  final List<AudioQueueItem> queue;
  final int currentIndex;
  final double positionSeconds;
  final double durationSeconds;
  final double volume;
  final bool isMuted;
  final AudioLoopMode loopMode;
  final AudioCoverSource cover;
  final LrcDocument? lrcDocument;

  /// 主唱与和声并行逐字扫光歌词行（仅当当前 LRC 含逐字时间标签或 `bg:` 和声层时非空）。
  final List<ActiveSpanLyricLine> activeSpanLines;
  final int activeLyricIndex;
  final String audioCodecLabel;
  final String sampleRateAndBitDepthLabel;
  final String bitrateLabel;
  final String? errorMessage;

  AudioQueueItem? get currentItem =>
      (currentIndex >= 0 && currentIndex < queue.length)
      ? queue[currentIndex]
      : null;

  String? get currentLyricLineText {
    final doc = lrcDocument;
    if (doc == null ||
        activeLyricIndex < 0 ||
        activeLyricIndex >= doc.lines.length) {
      return null;
    }
    return doc.lines[activeLyricIndex].primaryText;
  }

  /// 将底层可播放音轨队列映射为「主 CD 带序号、在播整轨 CD 下方拆开无序号单曲」的视觉行列表。
  List<AudioQueueDisplayRow> buildDisplayRows({
    bool includeDetailedSubtitle = false,
  }) {
    if (queue.isEmpty) return const [];
    final isLegacyFlatCue = queue.every(
      (e) => e.isCueTrack && e.cueDiscTitle.isEmpty,
    );
    final rows = <AudioQueueDisplayRow>[];
    var topNumber = 0;

    var i = 0;
    while (i < queue.length) {
      final item = queue[i];
      if (item.isCueTrack && item.cueDiscTitle.trim().isNotEmpty) {
        final discTitle = item.cueDiscTitle.trim();
        final groupCueId = item.pairedCueVariant?.id;
        final physKey = item.physicalFileKey;
        var endIdx = i;
        while (endIdx + 1 < queue.length) {
          final next = queue[endIdx + 1];
          final sameGroup = groupCueId != null
              ? next.pairedCueVariant?.id == groupCueId
              : (next.physicalFileKey == physKey &&
                    next.cueDiscTitle.trim() == discTitle);
          if (!next.isCueTrack || !sameGroup) break;
          endIdx++;
        }

        topNumber++;
        final prefix = topNumber.toString().padLeft(2, '0');
        final parentActive = currentIndex >= i && currentIndex <= endIdx;
        final tail = queue[endIdx];
        Duration totalDiscDuration = Duration.zero;
        if (tail.cueEndSeconds != null && tail.cueEndSeconds! > 0) {
          totalDiscDuration = Duration(
            milliseconds: (tail.cueEndSeconds! * 1000).round(),
          );
        } else if (tail.resolvedDuration > Duration.zero) {
          final totalSec =
              (tail.cueStartSeconds ?? 0.0) +
              (tail.resolvedDuration.inMilliseconds / 1000.0);
          totalDiscDuration = Duration(milliseconds: (totalSec * 1000).round());
        }

        final parentSubParts = <String>[
          if (item.showAlbumSubtitle &&
              item.albumTitle.trim().isNotEmpty &&
              item.albumTitle.trim() != discTitle)
            item.albumTitle.trim(),
        ];
        rows.add(
          AudioQueueDisplayRow(
            id: 'cue_parent_${groupCueId ?? physKey}_$i',
            kind: AudioQueueDisplayRowKind.cueParent,
            trackPrefix: prefix,
            title: discTitle,
            subtitle: parentSubParts.join(' · '),
            duration: totalDiscDuration,
            targetQueueIndex: i,
            isActiveTrack: false,
            isExpandedParent: parentActive,
          ),
        );

        for (var k = i; k <= endIdx; k++) {
          final sub = queue[k];
          rows.add(
            AudioQueueDisplayRow(
              id: sub.id,
              kind: AudioQueueDisplayRowKind.cueSubTrack,
              trackPrefix: '',
              title: sub.title,
              subtitle: sub.performer.trim(),
              duration: sub.resolvedDuration,
              targetQueueIndex: k,
              isActiveTrack: k == currentIndex,
            ),
          );
        }

        i = endIdx + 1;
        continue;
      }

      topNumber++;
      final seqNum = isLegacyFlatCue
          ? (item.trackNumber ?? (i + 1))
          : topNumber;
      final subtitle = includeDetailedSubtitle
          ? item.displaySubtitle
          : <String>[
              if (item.performer.trim().isNotEmpty) item.performer.trim(),
              if (item.showAlbumSubtitle && item.albumTitle.trim().isNotEmpty)
                item.albumTitle.trim(),
            ].join(' · ');

      rows.add(
        AudioQueueDisplayRow(
          id: item.id,
          kind: AudioQueueDisplayRowKind.standalone,
          trackPrefix: seqNum.toString().padLeft(2, '0'),
          title: item.title,
          subtitle: subtitle,
          duration: item.resolvedDuration,
          targetQueueIndex: i,
          isActiveTrack: i == currentIndex,
        ),
      );
      i++;
    }
    return rows;
  }

  AudioPlaybackState copyWith({
    bool? isActive,
    bool? isPlaying,
    bool? isBuffering,
    List<AudioQueueItem>? queue,
    int? currentIndex,
    double? positionSeconds,
    double? durationSeconds,
    double? volume,
    bool? isMuted,
    AudioLoopMode? loopMode,
    AudioCoverSource? cover,
    LrcDocument? lrcDocument,
    List<ActiveSpanLyricLine>? activeSpanLines,
    bool clearLrcDocument = false,
    int? activeLyricIndex,
    String? audioCodecLabel,
    String? sampleRateAndBitDepthLabel,
    String? bitrateLabel,
    String? errorMessage,
    bool clearError = false,
  }) {
    return AudioPlaybackState(
      isActive: isActive ?? this.isActive,
      isPlaying: isPlaying ?? this.isPlaying,
      isBuffering: isBuffering ?? this.isBuffering,
      queue: queue ?? this.queue,
      currentIndex: currentIndex ?? this.currentIndex,
      positionSeconds: positionSeconds ?? this.positionSeconds,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      volume: volume ?? this.volume,
      isMuted: isMuted ?? this.isMuted,
      loopMode: loopMode ?? this.loopMode,
      cover: cover ?? this.cover,
      lrcDocument: clearLrcDocument ? null : (lrcDocument ?? this.lrcDocument),
      activeSpanLines: clearLrcDocument
          ? const []
          : (activeSpanLines ?? this.activeSpanLines),
      activeLyricIndex: activeLyricIndex ?? this.activeLyricIndex,
      audioCodecLabel: audioCodecLabel ?? this.audioCodecLabel,
      sampleRateAndBitDepthLabel:
          sampleRateAndBitDepthLabel ?? this.sampleRateAndBitDepthLabel,
      bitrateLabel: bitrateLabel ?? this.bitrateLabel,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}
