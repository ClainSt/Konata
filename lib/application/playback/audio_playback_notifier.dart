import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../composition/platform_composition.dart';
import '../../domain/models/media_source.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/models/playback_record.dart';
import '../../domain/models/work.dart';
import '../../domain/matching/supplementary_subclassifier.dart';
import '../../domain/playback/audiophile_safety_policy.dart';
import '../../domain/playback/cue_and_lrc_parser.dart';
import '../../domain/playback/cue_variant_resolver.dart';
import '../../domain/playback/playback_formatters.dart';
import '../../domain/repositories/file_system_gateway.dart';
import '../../infrastructure/players/android/android_audio_route_bridge.dart';
import '../../infrastructure/players/android/android_media_session_bridge.dart';
import '../../infrastructure/players/audio_art_extractor.dart';
import '../../infrastructure/players/libmpv_ffi.dart';
import '../../infrastructure/players/mpv_quality_profile.dart';
import '../../infrastructure/sources/byte_stream_source_gateway.dart';
import '../../infrastructure/sources/local_source_gateway.dart';
import '../../infrastructure/sources/source_access_error.dart';
import '../../infrastructure/sources/source_gateway_factory.dart';
import '../../infrastructure/storage/storage_root_provider.dart';
import '../providers/artwork_provider.dart';
import '../providers/diagnostics_providers.dart';
import '../providers/library_providers.dart';
import '../providers/platform_capability.dart';
import '../providers/playback_providers.dart';
import 'playback_preferences_provider.dart';
import 'unified_playback_coordinator.dart';
import 'unified_playback_engine.dart';

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
      activeLyricIndex: activeLyricIndex ?? this.activeLyricIndex,
      audioCodecLabel: audioCodecLabel ?? this.audioCodecLabel,
      sampleRateAndBitDepthLabel:
          sampleRateAndBitDepthLabel ?? this.sampleRateAndBitDepthLabel,
      bitrateLabel: bitrateLabel ?? this.bitrateLabel,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

/// 基于独立保活 `libmpv`（`vid=no`, `vo=null`, `soxr`）的 CD / 无损音频播放器控制器。
class AudioPlaybackNotifier extends StateNotifier<AudioPlaybackState> {
  AudioPlaybackNotifier(
    this._ref, {
    this.clientFactory,
    this.gatewayFactory = const MediaSourceGatewayFactory(),
    this.retryDelayBuilder,
    AndroidMediaSessionBridge? mediaSessionBridge,
  }) : _mediaSessionBridge =
           mediaSessionBridge ??
           AndroidMediaSessionBridge(
             isSupported: () => KonataPlatform.isAndroid,
           ),
       super(const AudioPlaybackState()) {
    _bindAndroidMediaSessionCallbacks();
  }

  /// 非致命流加载异常的最大静默重试次数。
  static const int maxSilentRetries = 3;

  static const int _propTimePos = 101;
  static const int _propDuration = 102;
  static const int _propPause = 103;
  static const int _propCoreIdle = 104;
  static const int _propAudioCodec = 105;
  static const int _propSampleRate = 106;
  static const int _propAudioFormat = 107;
  static const int _propAudioBitrate = 108;
  static const int _propEofReached = 109;

  final Ref _ref;
  final LibMpvClient Function()? clientFactory;
  final MediaSourceGatewayFactory gatewayFactory;
  final Duration Function(int attempt)? retryDelayBuilder;
  final AndroidMediaSessionBridge _mediaSessionBridge;
  final Map<String, Uint8List> _posterNotificationBytesCache = {};
  final Set<String> _loadingPosterNotificationKeys = {};

  /// 暴露媒体会话通信桥实例供集成与单元测试观测。
  AndroidMediaSessionBridge get mediaSessionBridge => _mediaSessionBridge;

  void _bindAndroidMediaSessionCallbacks() {
    _mediaSessionBridge.bindCallbacks(
      onPlay: () {
        if (mounted && state.isActive) {
          unawaited(setPlaying(true));
        }
      },
      onPause: () {
        if (mounted && state.isActive) {
          unawaited(setPlaying(false));
        }
      },
      onTogglePlayPause: () {
        if (mounted && state.isActive) {
          unawaited(togglePlayPause());
        }
      },
      onPrevious: () {
        if (mounted && state.isActive) {
          unawaited(previous());
        }
      },
      onNext: () {
        if (mounted && state.isActive) {
          unawaited(next());
        }
      },
      onSeekToSeconds: (seconds) {
        if (mounted && state.isActive) {
          unawaited(seekRelativeTrackSeconds(seconds));
        }
      },
      onStop: () {
        if (mounted && state.isActive) {
          unawaited(stopAndClose());
        }
      },
    );
  }

  @override
  set state(AudioPlaybackState value) {
    super.state = value;
    _syncAndroidMediaSession();
  }

  void _syncAndroidMediaSession({bool forcePositionSync = false}) {
    if (!KonataPlatform.isAndroid) return;
    _bindAndroidMediaSessionCallbacks();
    final item = state.currentItem;
    if (!state.isActive || item == null) {
      unawaited(_mediaSessionBridge.stopSession());
      return;
    }

    String coverKey = '';
    Uint8List? coverBytes;
    switch (state.cover) {
      case MemoryAudioCover(:final bytes):
        if (bytes.isNotEmpty) {
          coverKey = 'mem_${(state.cover as MemoryAudioCover).contentHash}';
          coverBytes = bytes;
        }
      case ManagedPosterAudioCover(:final url, :final workId, :final revision):
        final candidateKey = 'poster_${workId}_${url}_$revision';
        final cachedBytes = _posterNotificationBytesCache[candidateKey];
        if (cachedBytes != null && cachedBytes.isNotEmpty) {
          coverKey = candidateKey;
          coverBytes = cachedBytes;
        } else {
          _warmPosterBytesForNotification(candidateKey, url);
        }
      case EmptyAudioCover():
        coverKey = '';
    }

    final artistParts = <String>[
      if (item.performer.trim().isNotEmpty) item.performer.trim(),
      if (item.work.title.trim().isNotEmpty &&
          item.work.title.trim() != item.performer.trim())
        item.work.title.trim(),
    ];
    final artistLabel = artistParts.isNotEmpty
        ? artistParts.join(' · ')
        : item.work.title.trim();
    final albumLabel = item.albumTitle.trim().isNotEmpty
        ? item.albumTitle.trim()
        : item.work.title.trim();

    unawaited(
      _mediaSessionBridge.syncSession(
        trackId: item.id,
        title: item.title,
        artist: artistLabel,
        album: albumLabel,
        durationSeconds: state.durationSeconds,
        positionSeconds: state.positionSeconds,
        isPlaying: state.isPlaying,
        coverKey: coverKey,
        coverBytes: coverBytes,
        forcePositionSync: forcePositionSync,
      ),
    );
  }

  void _warmPosterBytesForNotification(String cacheKey, String url) {
    if (url.isEmpty || _loadingPosterNotificationKeys.contains(cacheKey)) {
      return;
    }
    _loadingPosterNotificationKeys.add(cacheKey);
    unawaited(() async {
      try {
        final loader = _ref.read(tmdbImageLoaderProvider);
        final bytes = await loader(url, targetWidth: 512);
        if (bytes.isEmpty || !mounted) return;
        _posterNotificationBytesCache.remove(cacheKey);
        _posterNotificationBytesCache[cacheKey] = bytes;
        while (_posterNotificationBytesCache.length > 16) {
          _posterNotificationBytesCache.remove(
            _posterNotificationBytesCache.keys.first,
          );
        }
        _syncAndroidMediaSession();
      } catch (_) {
      } finally {
        _loadingPosterNotificationKeys.remove(cacheKey);
      }
    }());
  }

  static const Duration _cueSeekDebounceWindow = Duration(milliseconds: 900);
  static const int _maxAlbumCacheEntries = 32;

  LibMpvClient? _client;
  StreamSubscription<MpvClientEvent>? _eventSub;
  String? _activeStreamToken;
  String? _loadedPhysicalKey;
  int _loadGeneration = 0;
  bool _isTransitioningCueBoundary = false;
  int _activeCommandedGeneration = 0;
  int _completedGeneration = -1;
  int _currentMpvPlaylistEntryId = 0;
  int _retiredMpvPlaylistEntryId = 0;
  int _eofHandledMpvEntryId = -1;
  int _trackRetryCount = 0;
  int _consecutiveFailedTracks = 0;
  double _trackProgressBaselineSeconds = 0.0;

  UnifiedPlaybackEngine get _engine => _ref.read(unifiedPlaybackEngineProvider);

  double? _pendingSeekRawTargetSeconds;
  DateTime? _pendingSeekGuardUntil;
  DateTime? _lastAudioPersistAt;
  bool _persistInFlight = false;
  DateTime? _suppressBufferingUntil;
  ({AudioQueueItem item, int generation})? _pendingRemoteAuxJob;

  final Map<String, double> _rawDurationByPhysicalKey = {};
  final Map<String, ({AudioCoverSource cover, bool hasDedicatedCover})>
  _albumCoverCache = {};
  final Map<String, List<RemoteEntry>> _siblingsByDirCache = {};
  final Set<String> _checkedEmbeddedCoverPhysicalKeys = {};
  final Map<String, int> _workPosterRevisions = {};
  final Map<String, String> _lastKnownPosterByWorkId = {};

  List<MediaVariant> _sessionAllCdVariants = const [];
  Map<String, MediaSource> _sessionSourcesById = const {};
  final Map<String, AudioQueueItem> _unexpandedMasterByCueId = {};
  final Map<String, List<AudioQueueItem>> _expandedTracksByCueId = {};
  final Set<String> _nonExpandableCueIds = {};

  String _rawCodec = '';
  int? _rawSampleRateHz;
  String _rawAudioFormat = '';
  double _rawFileDurationSeconds = 0.0;
  double? _volumeBeforeDuck;

  /// 判断文件名是否为受支持的音频物理轨。
  static bool isPlayableAudioFile(String fileName) =>
      CueVariantResolver.isPlayableAudioFile(fileName);

  /// 判断文件名是否为 `.cue` 分轨清单。
  static bool isCueSheetFile(String fileName) =>
      CueVariantResolver.isCueSheetFile(fileName);

  /// 以指定曲目（支持单轨物理音频与 `.cue` 按需动态拆轨）开启 CD 播放队列。
  Future<void> playCdCollection({
    required Work work,
    required List<MediaVariant> cdVariants,
    required MediaVariant initialVariant,
    required Map<String, MediaSource> sourcesById,
    int? initialCueTrackNumber,
  }) async {
    final generation = ++_loadGeneration;
    final built = await _buildQueueItems(
      work: work,
      cdVariants: cdVariants,
      initialVariant: initialVariant,
      sourcesById: sourcesById,
      initialCueTrackNumber: initialCueTrackNumber,
    );
    if (generation != _loadGeneration || !mounted) return;
    final items = built.items;
    if (items.isEmpty) {
      _activeCommandedGeneration = 0;
      _loadedPhysicalKey = null;
      state = state.copyWith(
        isActive: true,
        isPlaying: false,
        errorMessage: '未找到可播放的 CD 音频轨道',
      );
      return;
    }

    final previousItem = state.currentItem;
    if (KonataPlatform.isAndroid) {
      unawaited(
        AndroidPlaybackWindowBridge.applyVideoOrientationAndWindow(
          landscape: false,
          hideSystemBars: false,
        ),
      );
    }
    final initialVol = _ref.read(playbackPreferencesProvider).defaultVolume;
    _trackRetryCount = 0;
    _consecutiveFailedTracks = 0;
    _engine.recordManualSelection();
    state = state.copyWith(
      isActive: true,
      queue: items,
      currentIndex: built.targetIndex,
      volume: state.isActive ? state.volume : initialVol,
      clearError: true,
    );

    await _startTrackAtIndex(
      built.targetIndex,
      generation: generation,
      previousItemOverride: previousItem,
    );
  }

  Future<({List<AudioQueueItem> items, int targetIndex})> _buildQueueItems({
    required Work work,
    required List<MediaVariant> cdVariants,
    required MediaVariant initialVariant,
    required Map<String, MediaSource> sourcesById,
    int? initialCueTrackNumber,
  }) async {
    _sessionAllCdVariants = List<MediaVariant>.unmodifiable(cdVariants);
    _sessionSourcesById = Map<String, MediaSource>.unmodifiable(sourcesById);
    _unexpandedMasterByCueId.clear();
    _expandedTracksByCueId.clear();
    _nonExpandableCueIds.clear();

    final playableVariants = cdVariants
        .where((v) => isPlayableAudioFile(v.fileName))
        .toList(growable: false);
    final cueVariants = cdVariants
        .where((v) => isCueSheetFile(v.fileName))
        .toList(growable: false);

    // 兜底：若集合中仅存在孤立 .cue 而数据库未收录同名物理音频文件，直接按 CUE 引用虚拟展开
    if (playableVariants.isEmpty && cueVariants.isNotEmpty) {
      final targetCue = isCueSheetFile(initialVariant.fileName)
          ? initialVariant
          : cueVariants.first;
      final src = sourcesById[targetCue.sourceId];
      if (src != null) {
        final folderName = p.posix.basename(
          p.posix.dirname(targetCue.relativePath.replaceAll('\\', '/')),
        );
        final dummyMaster = AudioQueueItem(
          id: targetCue.id,
          work: work,
          variant: targetCue,
          source: src,
          title: p.basenameWithoutExtension(targetCue.fileName),
          albumTitle: (folderName.isNotEmpty && folderName != '.')
              ? folderName
              : work.title,
          pairedCueVariant: targetCue,
        );
        final subTracks = await _resolveExpandedCueTracks(
          dummyMaster,
          forceSingleTrackExpand: true,
        );
        if (subTracks != null && subTracks.isNotEmpty) {
          var idx = 0;
          if (initialCueTrackNumber != null) {
            final hit = subTracks.indexWhere(
              (e) => e.trackNumber == initialCueTrackNumber,
            );
            if (hit >= 0) idx = hit;
          }
          return (items: subTracks, targetIndex: idx);
        }
      }
      return (items: const <AudioQueueItem>[], targetIndex: 0);
    }

    final cuesByDir = <String, List<MediaVariant>>{};
    for (final c in cueVariants) {
      final d =
          '${c.sourceId}::${p.posix.dirname(c.relativePath.replaceAll('\\', '/'))}';
      cuesByDir.putIfAbsent(d, () => <MediaVariant>[]).add(c);
    }
    final audiosByDir = <String, List<MediaVariant>>{};
    for (final a in playableVariants) {
      final d =
          '${a.sourceId}::${p.posix.dirname(a.relativePath.replaceAll('\\', '/'))}';
      audiosByDir.putIfAbsent(d, () => <MediaVariant>[]).add(a);
    }

    final cdSummary = SupplementarySubclassifier.groupCdVariants(
      playableVariants,
    );
    final distinctAlbums = <String>{};
    final drafts =
        <
          ({
            MediaVariant variant,
            MediaSource? source,
            String cleanTitle,
            int? trackNumber,
            String albumLabel,
            MediaVariant? pairedCue,
          })
        >[];

    for (final v in playableVariants) {
      final src = sourcesById[v.sourceId];
      final rawStem = p.basenameWithoutExtension(v.fileName);
      final parsedTrack =
          SupplementarySubclassifier.stripAudioTrackNumberPrefix(rawStem);
      final group = cdSummary.byVariantId[v.id];
      final folderName = p.posix.basename(
        p.posix.dirname(v.relativePath.replaceAll('\\', '/')),
      );
      final resolvedAlbum =
          (group != null &&
              group.chipLabel.isNotEmpty &&
              group.chipLabel != 'CD')
          ? group.chipLabel
          : ((folderName.isNotEmpty && folderName != '.')
                ? folderName
                : work.title);
      distinctAlbums.add(resolvedAlbum);

      final dirKey =
          '${v.sourceId}::${p.posix.dirname(v.relativePath.replaceAll('\\', '/'))}';
      final pairedCue = CueVariantResolver.matchCueVariantForAudio(
        audioVariant: v,
        cueVariantsInDir: cuesByDir[dirKey] ?? const [],
        audioVariantsInDir: audiosByDir[dirKey] ?? const [],
      );
      final effectiveTitle =
          (CueVariantResolver.isGenericDiscImageStem(rawStem) &&
              resolvedAlbum.isNotEmpty)
          ? resolvedAlbum
          : parsedTrack.cleanTitle;

      drafts.add((
        variant: v,
        source: src,
        cleanTitle: effectiveTitle,
        trackNumber: pairedCue != null ? null : parsedTrack.trackNumber,
        albumLabel: resolvedAlbum,
        pairedCue: pairedCue,
      ));
    }

    final showSub = distinctAlbums.length >= 2 || drafts.isNotEmpty;
    final items = <AudioQueueItem>[
      for (final d in drafts)
        () {
          final physKey =
              '${d.source?.id ?? 'local'}::${d.variant.relativePath.replaceAll('\\', '/')}';
          final knownDur = _rawDurationByPhysicalKey[physKey] ?? 0.0;
          return AudioQueueItem(
            id: d.variant.id,
            work: work,
            variant: d.variant,
            source: d.source,
            title: d.cleanTitle,
            trackNumber: d.trackNumber,
            albumTitle: d.albumLabel,
            showAlbumSubtitle: showSub,
            pairedCueVariant: d.pairedCue,
            duration: knownDur > 0
                ? Duration(milliseconds: (knownDur * 1000).round())
                : Duration.zero,
          );
        }(),
    ];

    if (items.isEmpty) {
      return (items: items, targetIndex: 0);
    }

    var masterIdx = -1;
    if (isCueSheetFile(initialVariant.fileName)) {
      masterIdx = items.indexWhere(
        (e) => e.pairedCueVariant?.id == initialVariant.id,
      );
      if (masterIdx < 0) {
        final initDir = p.posix.dirname(
          initialVariant.relativePath.replaceAll('\\', '/'),
        );
        masterIdx = items.indexWhere(
          (e) =>
              e.variant.sourceId == initialVariant.sourceId &&
              p.posix.dirname(e.variant.relativePath.replaceAll('\\', '/')) ==
                  initDir,
        );
      }
    } else {
      masterIdx = items.indexWhere((e) => e.variant.id == initialVariant.id);
    }
    if (masterIdx < 0) masterIdx = 0;

    final targetMaster = items[masterIdx];
    final cueVar = targetMaster.pairedCueVariant;
    if (cueVar != null) {
      final forceExpand =
          isCueSheetFile(initialVariant.fileName) ||
          initialCueTrackNumber != null;
      final subTracks = await _resolveExpandedCueTracks(
        targetMaster,
        forceSingleTrackExpand: forceExpand,
      );
      if (subTracks != null && subTracks.isNotEmpty) {
        _unexpandedMasterByCueId[cueVar.id] = targetMaster;
        items.replaceRange(masterIdx, masterIdx + 1, subTracks);
        var subIdx = 0;
        if (initialCueTrackNumber != null) {
          final matched = subTracks.indexWhere(
            (e) => e.trackNumber == initialCueTrackNumber,
          );
          if (matched >= 0) subIdx = matched;
        }
        return (items: items, targetIndex: masterIdx + subIdx);
      }
    }

    return (items: items, targetIndex: masterIdx);
  }

  /// 读取并构建指定整轨条目的 CUE 子单曲列表（内置内存缓存，同会话重复切回零 IO）。
  Future<List<AudioQueueItem>?> _resolveExpandedCueTracks(
    AudioQueueItem masterItem, {
    bool forceSingleTrackExpand = false,
  }) async {
    final cueVariant = masterItem.pairedCueVariant;
    final source =
        masterItem.source ?? _sessionSourcesById[masterItem.variant.sourceId];
    if (cueVariant == null || source == null) return null;

    final cached = _expandedTracksByCueId[cueVariant.id];
    if (cached != null) {
      return _refreshCueTrackDurations(cached);
    }
    if (_nonExpandableCueIds.contains(cueVariant.id)) {
      return null;
    }

    final cueSheet = await AudioAssetExtractor.loadCueSheet(
      source: source,
      cueRelativePath: cueVariant.relativePath,
      gatewayFactory: gatewayFactory,
      knownFileSize: cueVariant.fileSize > 0 ? cueVariant.fileSize : null,
      legacyDecoder: _ref.read(legacyCodePageDecoderProvider),
    );
    if (cueSheet == null || cueSheet.tracks.isEmpty) {
      _nonExpandableCueIds.add(cueVariant.id);
      return null;
    }

    // 单轨无分章整碟若标题与母碟相同，保持单行整轨播放不重复挂子项
    if (!forceSingleTrackExpand && cueSheet.tracks.length == 1) {
      final rawOnlyTitle = cueSheet.tracks.first.title.trim();
      final strippedOnly =
          SupplementarySubclassifier.stripAudioTrackNumberPrefix(
            rawOnlyTitle,
          ).cleanTitle.trim();
      final isGenericTrack1 = RegExp(
        r'^track\s*0*1$',
        caseSensitive: false,
      ).hasMatch(rawOnlyTitle);
      if (strippedOnly.isEmpty ||
          isGenericTrack1 ||
          strippedOnly.toLowerCase() == masterItem.title.trim().toLowerCase()) {
        _nonExpandableCueIds.add(cueVariant.id);
        return null;
      }
    }

    final cueDir = p.posix.dirname(
      cueVariant.relativePath.replaceAll('\\', '/'),
    );
    final audioVariantsInDir = _sessionAllCdVariants
        .where((v) {
          if (v.sourceId != cueVariant.sourceId ||
              !isPlayableAudioFile(v.fileName)) {
            return false;
          }
          return p.posix.dirname(v.relativePath.replaceAll('\\', '/')) ==
              cueDir;
        })
        .toList(growable: false);

    final built = <AudioQueueItem>[];
    for (final track in cueSheet.tracks) {
      final targetAudio = CueVariantResolver.resolve(
        cueVariant: cueVariant,
        cueTrack: track,
        audioVariantsInDir: audioVariantsInDir,
        fallbackInitial: masterItem.variant,
      );
      if (targetAudio == null) continue;
      final src = _sessionSourcesById[targetAudio.sourceId] ?? source;
      final rawTrackTitle = track.title.trim();
      final strippedTitle =
          SupplementarySubclassifier.stripAudioTrackNumberPrefix(
            rawTrackTitle,
          ).cleanTitle.trim();
      final cleanTrackTitle = strippedTitle.isNotEmpty
          ? strippedTitle
          : (rawTrackTitle.isNotEmpty
                ? rawTrackTitle
                : '曲目 ${track.trackNumber}');

      built.add(
        AudioQueueItem(
          id: '${cueVariant.id}::track_${track.trackNumber}',
          work: masterItem.work,
          variant: targetAudio,
          source: src,
          title: cleanTrackTitle,
          performer: track.performer.isNotEmpty
              ? track.performer
              : cueSheet.performer,
          albumTitle: masterItem.albumTitle.isNotEmpty
              ? masterItem.albumTitle
              : (cueSheet.title.isNotEmpty
                    ? cueSheet.title
                    : masterItem.work.title),
          trackNumber: track.trackNumber,
          cueStartSeconds: track.startSeconds,
          cueEndSeconds: track.endSeconds,
          targetAudioRelativePath: targetAudio.relativePath,
          showAlbumSubtitle: masterItem.showAlbumSubtitle,
          pairedCueVariant: cueVariant,
          cueDiscTitle: masterItem.title,
        ),
      );
    }

    if (built.isEmpty) {
      _nonExpandableCueIds.add(cueVariant.id);
      return null;
    }
    final refreshed = _refreshCueTrackDurations(built);
    _expandedTracksByCueId[cueVariant.id] = refreshed;
    return refreshed;
  }

  List<AudioQueueItem> _refreshCueTrackDurations(List<AudioQueueItem> tracks) {
    return <AudioQueueItem>[
      for (final t in tracks)
        () {
          final knownRawDur =
              _rawDurationByPhysicalKey[t.physicalFileKey] ?? 0.0;
          final start = t.cueStartSeconds ?? 0.0;
          final end = t.cueEndSeconds;
          if (end != null && end > start) {
            return t.copyWith(
              duration: Duration(milliseconds: ((end - start) * 1000).round()),
            );
          }
          if (end == null && knownRawDur > start) {
            return t.copyWith(
              duration: Duration(
                milliseconds: ((knownRawDur - start) * 1000).round(),
              ),
            );
          }
          return t;
        }(),
    ];
  }

  /// 切换曲目时自动收起已离开的旧整轨 CD 子单曲，并按需拆开新轮到的整轨 CD 子单曲。
  Future<int?> _reconcileCueWindowForTarget(
    int targetIndex, {
    required int generation,
    bool selectLastOnExpand = false,
  }) async {
    if (targetIndex < 0 || targetIndex >= state.queue.length || !mounted) {
      return null;
    }
    var workingQueue = List<AudioQueueItem>.of(state.queue);
    var adjustedIndex = targetIndex;
    final targetCueId = workingQueue[adjustedIndex].pairedCueVariant?.id;

    // 1. 折叠非当前目标的已展开整轨 CD
    var queueMutated = false;
    var scan = 0;
    while (scan < workingQueue.length) {
      final item = workingQueue[scan];
      final cueId = item.pairedCueVariant?.id;
      if (item.isCueTrack &&
          cueId != null &&
          cueId != targetCueId &&
          _unexpandedMasterByCueId.containsKey(cueId)) {
        var groupEnd = scan;
        while (groupEnd + 1 < workingQueue.length &&
            workingQueue[groupEnd + 1].isCueTrack &&
            workingQueue[groupEnd + 1].pairedCueVariant?.id == cueId) {
          groupEnd++;
        }
        var master = _unexpandedMasterByCueId[cueId]!;
        final knownDur =
            _rawDurationByPhysicalKey[master.physicalFileKey] ?? 0.0;
        if (knownDur > 0 && master.duration == Duration.zero) {
          master = master.copyWith(
            duration: Duration(milliseconds: (knownDur * 1000).round()),
          );
          _unexpandedMasterByCueId[cueId] = master;
        }
        final removedExtra = groupEnd - scan;
        workingQueue.replaceRange(scan, groupEnd + 1, <AudioQueueItem>[master]);
        if (adjustedIndex > groupEnd) {
          adjustedIndex -= removedExtra;
        } else if (adjustedIndex >= scan) {
          adjustedIndex = scan;
        }
        queueMutated = true;
        scan++;
        continue;
      }
      scan++;
    }

    if (queueMutated) {
      state = state.copyWith(queue: workingQueue, currentIndex: adjustedIndex);
    }

    // 2. 若当前轮到的目标条目是尚未展开的整轨 CD，按需解析并在其下方拆出单曲
    final activeCandidate = workingQueue[adjustedIndex];
    final candidateCue = activeCandidate.pairedCueVariant;
    if (!activeCandidate.isCueTrack &&
        candidateCue != null &&
        !_nonExpandableCueIds.contains(candidateCue.id)) {
      if (!_expandedTracksByCueId.containsKey(candidateCue.id)) {
        state = state.copyWith(currentIndex: adjustedIndex, isBuffering: true);
      }
      final subTracks = await _resolveExpandedCueTracks(activeCandidate);
      if (generation != _loadGeneration || !mounted) return null;
      if (subTracks != null && subTracks.isNotEmpty) {
        final latestQueue = List<AudioQueueItem>.of(state.queue);
        final livePos = latestQueue.indexWhere(
          (e) => e.id == activeCandidate.id,
        );
        if (livePos >= 0) {
          _unexpandedMasterByCueId[candidateCue.id] = activeCandidate;
          latestQueue.replaceRange(livePos, livePos + 1, subTracks);
          final nextIdx = selectLastOnExpand
              ? (livePos + subTracks.length - 1)
              : livePos;
          state = state.copyWith(queue: latestQueue, currentIndex: nextIdx);
          return nextIdx;
        }
      }
    }

    return adjustedIndex;
  }

  Future<void> _ensureClientInitialized({bool isRemoteStream = false}) async {
    if (_client != null && !_client!.isDisposed && _client!.isInitialized) {
      return;
    }
    final client = clientFactory != null
        ? clientFactory!()
        : FfiLibMpvClient.create();
    final storageRoot = _ref.read(storageRootProvider);
    final mpvDir = await storageRoot.ensureMpvConfigDir();
    final prefs = _ref.read(playbackPreferencesProvider);
    final logStore = _ref.read(diagnosticsLogStoreProvider);

    MpvQualityProfile.applyPreInitAudioOptions(
      client,
      config: prefs.qualityConfig,
      mpvConfigDir: mpvDir,
      isRemoteStream: isRemoteStream,
      logStore: logStore,
    );
    client.setOptionString('keep-open', 'no');
    final rc = client.initialize();
    if (rc < 0) {
      await client.dispose();
      throw StateError('纯音频引擎初始化失败: ${client.errorString(rc)}');
    }

    client.setPropertyDouble('volume', state.isMuted ? 0.0 : state.volume);
    client.setPropertyString('keep-open', 'no');
    client.setPropertyString('loop-file', 'no');
    client.setPropertyString('loop-playlist', 'no');
    client.setPropertyFlag('mute', state.isMuted);
    final qualityConfig = _ref.read(playbackPreferencesProvider).qualityConfig;
    final safetyPlan = AudiophileSafetyPolicy.buildPlan(
      requestedMode: qualityConfig.wasapiExclusive
          ? AudioOutputRouteMode.wasapiExclusive
          : AudioOutputRouteMode.sharedResampled,
      safetyState: _deviceSafetyState,
    );
    MpvQualityProfile.applyAudiophileSafetyChain(
      client,
      plan: safetyPlan,
      logStore: _ref.read(diagnosticsLogStoreProvider),
    );
    AndroidAudioRouteBridge.bindRouteListeners(
      onOutputDeviceRemoved: (_) => _handleAudioDeviceRemovedTransientMute(),
      onOutputDeviceAdded: (fingerprint) {
        _deviceSafetyState = _deviceSafetyState.onDeviceChanged(fingerprint);
        _engine.advanceAudioOutputRoute();
      },
    );
    client.requestLogMessages('warn');
    client.observeProperty(_propTimePos, 'time-pos', MpvFormat.double_);
    client.observeProperty(_propDuration, 'duration', MpvFormat.double_);
    client.observeProperty(_propPause, 'pause', MpvFormat.flag);
    client.observeProperty(_propCoreIdle, 'core-idle', MpvFormat.flag);
    client.observeProperty(
      _propAudioCodec,
      'audio-codec-name',
      MpvFormat.string,
    );
    client.observeProperty(
      _propSampleRate,
      'audio-params/samplerate',
      MpvFormat.int64,
    );
    client.observeProperty(
      _propAudioFormat,
      'audio-params/format',
      MpvFormat.string,
    );
    client.observeProperty(_propAudioBitrate, 'audio-bitrate', MpvFormat.int64);
    client.observeProperty(_propEofReached, 'eof-reached', MpvFormat.flag);

    _client = client;
    _eventSub = client.events.listen(_handleMpvEvent);
  }

  AudioCoverSource _resolveInitialCoverForTrack(
    AudioQueueItem item, {
    AudioQueueItem? previousItem,
  }) {
    final cached = _albumCoverCache[item.albumCacheKey];
    if (cached != null) {
      return cached.cover;
    }
    if (previousItem != null &&
        previousItem.albumCacheKey == item.albumCacheKey &&
        state.cover is MemoryAudioCover) {
      return state.cover;
    }
    if (item.source == null) {
      return _resolvePosterFallback(item.work);
    }
    // 未确认目录/音频均无专属封面之前，严禁先闪现 work.posterUrl 兜底海报
    return const EmptyAudioCover();
  }

  void _cacheAlbumCover(
    String albumKey,
    AudioCoverSource cover, {
    required bool hasDedicatedCover,
  }) {
    _albumCoverCache.remove(albumKey);
    _albumCoverCache[albumKey] = (
      cover: cover,
      hasDedicatedCover: hasDedicatedCover,
    );
    while (_albumCoverCache.length > _maxAlbumCacheEntries) {
      _albumCoverCache.remove(_albumCoverCache.keys.first);
    }
  }

  double _resolveTrackDurationSeconds(
    AudioQueueItem item,
    double rawFileDuration,
  ) {
    final cachedSpan = item.resolvedDuration;
    if (cachedSpan > Duration.zero) {
      return cachedSpan.inMilliseconds / 1000.0;
    }
    if (item.isCueTrack && rawFileDuration > 0) {
      final start = item.cueStartSeconds ?? 0.0;
      final end = item.cueEndSeconds ?? rawFileDuration;
      if (end > start) return end - start;
    }
    if (!item.isCueTrack && rawFileDuration > 0) {
      return rawFileDuration;
    }
    return 0.0;
  }

  Future<void> _startTrackAtIndex(
    int index, {
    required int generation,
    AudioQueueItem? previousItemOverride,
    double initialTrackOffsetSeconds = 0.0,
    bool selectLastOnCueExpand = false,
    bool isRetryAttempt = false,
    bool preserveErrorToast = false,
  }) async {
    if (index < 0 || index >= state.queue.length || !mounted) return;
    if (!isRetryAttempt) {
      _trackRetryCount = 0;
    }
    final previousItem = previousItemOverride ?? state.currentItem;
    final reconciledIndex = await _reconcileCueWindowForTarget(
      index,
      generation: generation,
      selectLastOnExpand: selectLastOnCueExpand,
    );
    if (reconciledIndex == null ||
        reconciledIndex < 0 ||
        reconciledIndex >= state.queue.length ||
        generation != _loadGeneration ||
        !mounted) {
      return;
    }
    index = reconciledIndex;
    final item = state.queue[index];
    _isTransitioningCueBoundary = false;
    var clampedInitialOffset = initialTrackOffsetSeconds > 0
        ? initialTrackOffsetSeconds
        : 0.0;

    final physicalKey = item.physicalFileKey;
    final cachedRawDuration =
        _rawDurationByPhysicalKey[physicalKey] ??
        (_loadedPhysicalKey == physicalKey ? _rawFileDurationSeconds : 0.0);
    if (cachedRawDuration > 0 && clampedInitialOffset > 0) {
      final baseCueStart = item.cueStartSeconds ?? 0.0;
      if (baseCueStart + clampedInitialOffset >= cachedRawDuration - 0.1) {
        clampedInitialOffset = 0.0;
      }
    }
    final canSeekInsideLoadedCue =
        !isRetryAttempt &&
        item.isCueTrack &&
        _loadedPhysicalKey == physicalKey &&
        _client != null &&
        !_client!.isDisposed &&
        _client!.isInitialized;

    final initialCover = _resolveInitialCoverForTrack(
      item,
      previousItem: previousItem,
    );
    final initialDuration = _resolveTrackDurationSeconds(
      item,
      cachedRawDuration,
    );

    state = state.copyWith(
      isActive: true,
      currentIndex: index,
      isBuffering: !canSeekInsideLoadedCue,
      positionSeconds: clampedInitialOffset,
      durationSeconds: initialDuration,
      activeLyricIndex: -1,
      clearLrcDocument: true,
      cover: initialCover,
      audioCodecLabel: canSeekInsideLoadedCue ? state.audioCodecLabel : '',
      sampleRateAndBitDepthLabel: canSeekInsideLoadedCue
          ? state.sampleRateAndBitDepthLabel
          : '',
      bitrateLabel: canSeekInsideLoadedCue ? state.bitrateLabel : '',
      clearError: !preserveErrorToast,
    );

    final isRemote =
        item.source != null && item.source!.kind != MediaSourceKind.local;
    try {
      await _ensureAudioFocus();
      await _ensureClientInitialized(isRemoteStream: isRemote);
      if (generation != _loadGeneration || !mounted) return;
      final client = _client!;

      if (canSeekInsideLoadedCue) {
        final cueStart = item.cueStartSeconds ?? 0.0;
        if (cachedRawDuration > 0 && cueStart >= cachedRawDuration - 0.1) {
          throw const _CueTrackBoundsException('CUE 分轨起点超出音频文件总时长');
        }
        final start = cueStart + clampedInitialOffset;
        _activeCommandedGeneration = generation;
        _trackProgressBaselineSeconds = clampedInitialOffset;
        _engine.advanceLogicalTrack();
        MpvQualityProfile.resetAudioRangeAndLoopProperties(
          client,
          logStore: _ref.read(diagnosticsLogStoreProvider),
        );
        _pendingSeekRawTargetSeconds = start;
        _pendingSeekGuardUntil = DateTime.now().add(_cueSeekDebounceWindow);
        client.setPropertyFlag('pause', false);
        client.command(['seek', start.toStringAsFixed(3), 'absolute', 'exact']);
        _syncAudioSpecBadges();
        if (mounted) {
          final lyricIdx =
              state.lrcDocument?.activeIndexAt(clampedInitialOffset) ?? -1;
          state = state.copyWith(
            isBuffering: false,
            isPlaying: true,
            positionSeconds: clampedInitialOffset,
            activeLyricIndex: lyricIdx,
          );
        }
        unawaited(
          _persistAudioProgress(
            item,
            positionSeconds: clampedInitialOffset,
            durationSeconds: initialDuration,
            force: true,
          ),
        );
        unawaited(_loadAuxiliaryAssets(item, generation: generation));
        return;
      }

      if (cachedRawDuration > 0 &&
          item.cueStartSeconds != null &&
          item.cueStartSeconds! >= cachedRawDuration - 0.1) {
        throw const _CueTrackBoundsException('CUE 分轨起点超出音频文件总时长');
      }

      _pendingSeekRawTargetSeconds = null;
      _pendingSeekGuardUntil = null;
      _suppressBufferingUntil = null;
      _pendingRemoteAuxJob = null;

      // 先注册新曲目流地址，再执行原子 loadfile 替换后异步回收旧流令牌，
      // 严禁在异步空窗期提前销毁旧流引发 libmpv 读取中断误抛 -16。
      final resolved = await _resolvePlaybackTarget(item);
      if (generation != _loadGeneration || !mounted) {
        if (resolved.streamToken != null) {
          unawaited(_unregisterStreamToken(resolved.streamToken!));
        }
        return;
      }

      MpvQualityProfile.applyRuntimeStreamProfile(
        client,
        isRemoteStream: isRemote,
        isAudio: true,
        config: _ref.read(playbackPreferencesProvider).qualityConfig,
        logStore: _ref.read(diagnosticsLogStoreProvider),
      );

      final previousStreamToken = _activeStreamToken;
      _activeStreamToken = resolved.streamToken;
      if (_currentMpvPlaylistEntryId > _retiredMpvPlaylistEntryId) {
        _retiredMpvPlaylistEntryId = _currentMpvPlaylistEntryId;
      }
      _loadedPhysicalKey = physicalKey;
      _activeCommandedGeneration = generation;
      _rawFileDurationSeconds = cachedRawDuration;
      _rawCodec = '';
      _rawSampleRateHz = null;
      _rawAudioFormat = '';

      final effectiveStartSeconds =
          (item.cueStartSeconds ?? 0.0) + clampedInitialOffset;
      if (effectiveStartSeconds > 0) {
        client.setPropertyDouble('start', effectiveStartSeconds);
      } else {
        client.setPropertyString('start', 'none');
      }
      client.setPropertyFlag('pause', false);
      final cmdRc = client.command(['loadfile', resolved.target, 'replace']);
      if (previousStreamToken != null &&
          previousStreamToken != resolved.streamToken) {
        unawaited(_unregisterStreamToken(previousStreamToken));
      }
      if (cmdRc < 0) {
        _loadedPhysicalKey = null;
        client.setPropertyString('start', 'none');
        throw StateError(client.errorString(cmdRc));
      }
      unawaited(
        _persistAudioProgress(
          item,
          positionSeconds: clampedInitialOffset,
          durationSeconds: initialDuration,
          force: true,
        ),
      );
      // 本地音频立即加载封面与歌词；远程 WebDAV/SMB 延后至 MpvFileLoadedEvent 起播后再拉取，严防与主音频流争抢单文件锁。
      if (!isRemote || Platform.environment.containsKey('FLUTTER_TEST')) {
        unawaited(_loadAuxiliaryAssets(item, generation: generation));
      } else {
        _pendingRemoteAuxJob = (item: item, generation: generation);
      }
    } catch (e) {
      _client?.setPropertyString('start', 'none');
      if (generation == _loadGeneration && mounted) {
        final isDeterministicError =
            SourceAccessErrorClassifier.isNonTransientError(e) ||
            e is _CueTrackBoundsException ||
            e is UnsupportedError;
        final friendly = switch (e) {
          SourceAccessException(:final message) => message,
          _CueTrackBoundsException(:final message) => message,
          _ => '音频加载失败：$e',
        };
        unawaited(
          _handleTrackLoadFailure(
            generation: generation,
            failedItem: item,
            reasonMessage: friendly,
            retryable: !isDeterministicError,
          ),
        );
      }
    }
  }

  Future<({String target, String? streamToken})> _resolvePlaybackTarget(
    AudioQueueItem item,
  ) async {
    final source = item.source;
    if (source == null || source.kind == MediaSourceKind.local) {
      if (source != null) {
        final gw = LocalSourceGateway(rootPath: source.location);
        final absPath = gw.resolveAbsolutePath(item.effectiveRelativePath);
        if (!await File(absPath).exists()) {
          throw SourceAccessException(
            SourceAccessProblemKind.path,
            '本地音频文件不存在或路径已变更（${item.effectiveRelativePath}），请检查磁盘挂载或重新扫描媒体源',
          );
        }
        return (target: absPath, streamToken: null);
      }
      return (target: item.effectiveRelativePath, streamToken: null);
    }

    final gateway = await gatewayFactory.create(source);
    if (gateway is! ByteRangeReadableGateway) {
      await gateway.close();
      throw UnsupportedError('媒体源 ${source.kind.name} 不支持流式字节范围读取');
    }
    final bridge = _ref.read(localStreamBridgeProvider);
    final reg = await bridge.registerSession(
      gateway: gateway as ByteRangeReadableGateway,
      relativePath: item.effectiveRelativePath,
      fileName: item.effectiveFileName,
      knownLength: item.variant.fileSize > 0 ? item.variant.fileSize : null,
      ownsGateway: true,
      sourceKind: source.kind,
    );
    return (target: reg.url.toString(), streamToken: reg.token);
  }

  Future<void> _unregisterStreamToken(String token) async {
    try {
      await _ref.read(localStreamBridgeProvider).unregisterSession(token);
    } catch (_) {}
  }

  Future<void> _releaseActiveStreamSession() async {
    final token = _activeStreamToken;
    if (token == null) return;
    _activeStreamToken = null;
    await _unregisterStreamToken(token);
  }

  Future<void> _loadAuxiliaryAssets(
    AudioQueueItem item, {
    required int generation,
  }) async {
    final source = item.source;
    if (source == null) return;
    final albumKey = item.albumCacheKey;
    final physicalKey = item.physicalFileKey;
    final dirRelRaw = p.posix.dirname(
      item.effectiveRelativePath.replaceAll('\\', '/'),
    );
    final dirCacheKey = '${source.id}::${dirRelRaw == '.' ? '' : dirRelRaw}';

    final cachedCoverEntry = _albumCoverCache[albumKey];
    final cachedSiblings = _siblingsByDirCache[dirCacheKey];
    final alreadyCheckedEmbedded = _checkedEmbeddedCoverPhysicalKeys.contains(
      physicalKey,
    );
    final needFolderCoverProbe = cachedCoverEntry == null;
    final needEmbeddedProbe = !alreadyCheckedEmbedded;

    try {
      final probeVariant = item.targetAudioRelativePath == null
          ? item.variant
          : MediaVariant(
              id: item.variant.id,
              workId: item.variant.workId,
              sourceId: item.variant.sourceId,
              relativePath: item.effectiveRelativePath,
              fileName: item.effectiveFileName,
              fileSize: item.variant.fileSize,
              assetKind: item.variant.assetKind,
            );
      final aux = await AudioAssetExtractor.loadTrackAuxiliaryAssets(
        source: source,
        variant: probeVariant,
        gatewayFactory: gatewayFactory,
        cueTrackTitle: item.isCueTrack ? item.title : null,
        probeEmbeddedCover: needEmbeddedProbe,
        probeFolderCover: needFolderCoverProbe,
        cachedSiblings: cachedSiblings,
        legacyDecoder: _ref.read(legacyCodePageDecoderProvider),
      );
      if (aux.siblings != null && cachedSiblings == null) {
        _siblingsByDirCache[dirCacheKey] = aux.siblings!;
      }
      if (needEmbeddedProbe) {
        _checkedEmbeddedCoverPhysicalKeys.add(physicalKey);
      }

      if (generation != _loadGeneration || !mounted) return;

      AudioCoverSource resolvedCover;
      final existingCover = state.cover;
      if (aux.embeddedCover != null && aux.embeddedCover!.isNotEmpty) {
        if (existingCover is MemoryAudioCover &&
            MemoryAudioCover.sameContent(
              existingCover.bytes,
              aux.embeddedCover!,
            )) {
          resolvedCover = existingCover;
        } else if (cachedCoverEntry != null &&
            cachedCoverEntry.cover is MemoryAudioCover &&
            MemoryAudioCover.sameContent(
              (cachedCoverEntry.cover as MemoryAudioCover).bytes,
              aux.embeddedCover!,
            )) {
          resolvedCover = cachedCoverEntry.cover;
        } else {
          resolvedCover = MemoryAudioCover(aux.embeddedCover!);
        }
        _cacheAlbumCover(albumKey, resolvedCover, hasDedicatedCover: true);
      } else if (cachedCoverEntry != null) {
        resolvedCover = cachedCoverEntry.cover;
      } else if (aux.folderCover != null && aux.folderCover!.isNotEmpty) {
        resolvedCover = MemoryAudioCover(aux.folderCover!);
        _cacheAlbumCover(albumKey, resolvedCover, hasDedicatedCover: true);
      } else {
        // 仅当异步探测最终确认内嵌封面与同目录封面均不存在时才回退作品海报
        resolvedCover = _resolvePosterFallback(item.work);
        _cacheAlbumCover(albumKey, resolvedCover, hasDedicatedCover: false);
      }

      final lrc = aux.lrc;
      final activeLyric = lrc != null
          ? lrc.activeIndexAt(state.positionSeconds)
          : -1;
      state = state.copyWith(
        cover: resolvedCover,
        lrcDocument: lrc,
        clearLrcDocument: lrc == null,
        activeLyricIndex: activeLyric,
      );
    } catch (_) {
      if (generation == _loadGeneration &&
          mounted &&
          _albumCoverCache[albumKey] == null &&
          state.cover is EmptyAudioCover) {
        final fallback = _resolvePosterFallback(item.work);
        _cacheAlbumCover(albumKey, fallback, hasDedicatedCover: false);
        state = state.copyWith(cover: fallback);
      }
    }
  }

  AudioCoverSource _resolvePosterFallback(Work work) {
    final url = (work.posterPath?.trim().isNotEmpty == true)
        ? work.posterPath!.trim()
        : (work.bangumiPosterPath?.trim().isNotEmpty == true)
        ? work.bangumiPosterPath!.trim()
        : (work.posterFallback?.trim() ?? '');
    if (url.isEmpty) return const EmptyAudioCover();
    return ManagedPosterAudioCover(
      url: url,
      workId: work.id,
      revision: _workPosterRevisions[work.id] ?? 0,
    );
  }

  void _applyRawFileDuration(double rawDur) {
    if (rawDur <= 0 || !mounted) return;
    _rawFileDurationSeconds = rawDur;
    final loadedKey = _loadedPhysicalKey ?? state.currentItem?.physicalFileKey;
    if (loadedKey != null) {
      _rawDurationByPhysicalKey[loadedKey] = rawDur;
    }

    var queueChanged = false;
    final updatedQueue = <AudioQueueItem>[
      for (final q in state.queue)
        if (loadedKey != null &&
            q.physicalFileKey == loadedKey &&
            q.duration == Duration.zero)
          () {
            if (q.isCueTrack) {
              if (q.cueEndSeconds != null) return q;
              final start = q.cueStartSeconds ?? 0.0;
              final span = rawDur - start;
              if (span <= 0) return q;
              queueChanged = true;
              return q.copyWith(
                duration: Duration(milliseconds: (span * 1000).round()),
              );
            } else {
              queueChanged = true;
              return q.copyWith(
                duration: Duration(milliseconds: (rawDur * 1000).round()),
              );
            }
          }()
        else
          q,
    ];

    final current = state.currentItem;
    double nextDurationSeconds = state.durationSeconds;
    if (current != null) {
      if (current.isCueTrack) {
        final start = current.cueStartSeconds ?? 0.0;
        final end = current.cueEndSeconds ?? rawDur;
        final span = end - start;
        nextDurationSeconds = span > 0 ? span : 0.0;
      } else {
        nextDurationSeconds = rawDur;
      }
    }

    if (queueChanged || nextDurationSeconds != state.durationSeconds) {
      state = state.copyWith(
        queue: queueChanged ? updatedQueue : state.queue,
        durationSeconds: nextDurationSeconds,
      );
    }
  }

  void _handleMpvEvent(MpvClientEvent event) {
    if (!mounted) return;
    switch (event) {
      case MpvFileLoadedEvent():
        // CUE 起始偏移已在 loadfile 前通过 mpv `start` 属性直达起播，加载完成后复位避免切曲串台。
        // 严禁在 FILE_LOADED 提前清零连续坏文件熔断计数，仅在证实有效音频推进 >= 500ms 或手动点选时清零。
        _client?.setPropertyString('start', 'none');
        _trackRetryCount = 0;
        _engine.recordFileLoaded();
        state = state.copyWith(isBuffering: false, isPlaying: true);
        _refreshProbeFromClient();
        final auxJob = _pendingRemoteAuxJob;
        if (auxJob != null && auxJob.generation == _loadGeneration) {
          _pendingRemoteAuxJob = null;
          unawaited(
            _loadAuxiliaryAssets(auxJob.item, generation: auxJob.generation),
          );
        }
      case MpvAudioReconfigEvent():
      case MpvPlaybackRestartEvent():
        _suppressBufferingUntil = null;
        state = state.copyWith(isBuffering: false);
        _refreshProbeFromClient();
      case MpvPropertyChangeEvent():
        _handlePropertyChange(event);
      case MpvEndFileEvent():
        _handleEndFile(event);
      case MpvLogMessageEvent():
        final lvl = event.level.toLowerCase();
        if (lvl == 'error' || lvl == 'fatal') {
          _ref
              .read(diagnosticsLogStoreProvider)
              .record(
                'mpv-audio',
                '[${event.prefix}] ${event.text.trim()}',
                isError: true,
              );
        }
      case MpvStartFileEvent(:final playlistEntryId):
        if (playlistEntryId > 0) {
          _currentMpvPlaylistEntryId = playlistEntryId;
          _engine.bindPlaylistEntryId(playlistEntryId);
        }
      case MpvVideoReconfigEvent():
        break;
      case MpvSeekEvent():
        _pendingSeekRawTargetSeconds = null;
        _pendingSeekGuardUntil = null;
      case MpvShutdownEvent():
        break;
    }
  }

  void _handlePropertyChange(MpvPropertyChangeEvent e) {
    switch (e.replyUserdata) {
      case _propTimePos:
        final rawPos = e.doubleValue;
        if (rawPos == null) return;
        _updateTrackProgress(rawPos);
      case _propDuration:
        final rawDur = e.doubleValue;
        if (rawDur == null || rawDur <= 0) return;
        _applyRawFileDuration(rawDur);
      case _propPause:
        final paused = e.boolValue;
        if (paused != null) {
          state = state.copyWith(isPlaying: !paused);
        }
      case _propCoreIdle:
        final idle = e.boolValue ?? false;
        if (idle && (_client?.getPropertyFlag('eof-reached') ?? false)) {
          _onNaturalTrackEofReached();
          return;
        }
        final suppressed =
            _suppressBufferingUntil != null &&
            DateTime.now().isBefore(_suppressBufferingUntil!);
        state = state.copyWith(
          isBuffering:
              !suppressed &&
              state.isPlaying &&
              idle &&
              _loadedPhysicalKey != null,
        );
      case _propAudioCodec:
        _rawCodec = e.stringValue ?? '';
        _syncAudioSpecBadges();
      case _propSampleRate:
        _rawSampleRateHz = e.intValue;
        _syncAudioSpecBadges();
      case _propAudioFormat:
        _rawAudioFormat = e.stringValue ?? '';
        _syncAudioSpecBadges();
      case _propAudioBitrate:
        final bps = e.intValue;
        state = state.copyWith(
          bitrateLabel: bps != null && bps > 0
              ? PlaybackFormatters.formatBitrate(bps)
              : '',
        );
      case _propEofReached:
        final eof = e.boolValue ?? false;
        if (eof) {
          _onNaturalTrackEofReached();
        }
    }
  }

  void _updateTrackProgress(double rawPositionSeconds) {
    final item = state.currentItem;
    if (item == null) return;

    // 手动 seek / 点歌跳转瞬态防抖：丢弃旧分轨残余 time-pos，避免误触发新分轨边界回跳
    final pendingTarget = _pendingSeekRawTargetSeconds;
    if (pendingTarget != null) {
      final deadline = _pendingSeekGuardUntil;
      final reached = (rawPositionSeconds - pendingTarget).abs() <= 2.5;
      final expired = deadline != null && DateTime.now().isAfter(deadline);
      if (!reached && !expired) {
        return;
      }
      _pendingSeekRawTargetSeconds = null;
      _pendingSeekGuardUntil = null;
    }

    final cueStart = item.cueStartSeconds ?? 0.0;
    final cueEnd = item.cueEndSeconds;

    if (cueEnd != null &&
        rawPositionSeconds >= cueEnd &&
        !_isTransitioningCueBoundary) {
      if (!state.isPlaying) {
        return;
      }
      final nextIdx = state.currentIndex + 1;
      final canNaturalCueStep =
          state.loopMode != AudioLoopMode.loopOne &&
          nextIdx < state.queue.length &&
          state.queue[nextIdx].physicalFileKey == item.physicalFileKey &&
          state.queue[nextIdx].isCueTrack &&
          ((state.queue[nextIdx].cueStartSeconds ?? 0.0) - cueEnd).abs() <= 0.5;
      if (canNaturalCueStep) {
        _advanceNaturalCueTrack(
          nextIdx,
          previousItem: item,
          rawPositionSeconds: rawPositionSeconds,
        );
        return;
      }
      _isTransitioningCueBoundary = true;
      _completedGeneration = _activeCommandedGeneration;
      unawaited(_advanceOnTrackCompleted());
      return;
    }

    final relPos = state.durationSeconds > 0
        ? (rawPositionSeconds - cueStart).clamp(0.0, state.durationSeconds)
        : math.max(0.0, rawPositionSeconds - cueStart);
    final advancedMs = ((relPos - _trackProgressBaselineSeconds) * 1000).round();
    if (advancedMs >= UnifiedPlaybackEngine.effectiveAudioProgressThresholdMs) {
      if (_engine.recordEffectiveProgress(audioAdvancedMs: advancedMs)) {
        _consecutiveFailedTracks = 0;
      }
    }
    final lyricIdx = state.lrcDocument?.activeIndexAt(relPos) ?? -1;
    state = state.copyWith(positionSeconds: relPos, activeLyricIndex: lyricIdx);
    unawaited(
      _persistAudioProgress(
        item,
        positionSeconds: relPos,
        durationSeconds: state.durationSeconds,
      ),
    );
  }

  /// 同母文件自然播放跨越 CUE 分轨边界时直接原子推进状态，严禁调用 seek/loadfile 引发爆音卡顿。
  void _advanceNaturalCueTrack(
    int nextIndex, {
    required AudioQueueItem previousItem,
    required double rawPositionSeconds,
  }) {
    unawaited(
      _persistAudioProgress(
        previousItem,
        positionSeconds: state.durationSeconds,
        durationSeconds: state.durationSeconds,
        completed: true,
        force: true,
      ),
    );
    final nextItem = state.queue[nextIndex];
    final nextGen = ++_loadGeneration;
    _activeCommandedGeneration = nextGen;
    _isTransitioningCueBoundary = false;
    _trackProgressBaselineSeconds = 0.0;
    _engine.advanceLogicalTrack();

    final nextDuration = _resolveTrackDurationSeconds(
      nextItem,
      _rawFileDurationSeconds,
    );
    final start = nextItem.cueStartSeconds ?? 0.0;
    final relPos = nextDuration > 0
        ? (rawPositionSeconds - start).clamp(0.0, nextDuration)
        : math.max(0.0, rawPositionSeconds - start);
    final nextCover = _resolveInitialCoverForTrack(
      nextItem,
      previousItem: previousItem,
    );

    state = state.copyWith(
      currentIndex: nextIndex,
      positionSeconds: relPos,
      durationSeconds: nextDuration,
      isPlaying: true,
      isBuffering: false,
      cover: nextCover,
      activeLyricIndex: -1,
      clearLrcDocument: true,
      clearError: true,
    );

    unawaited(
      _persistAudioProgress(
        nextItem,
        positionSeconds: relPos,
        durationSeconds: nextDuration,
        force: true,
      ),
    );
    unawaited(_loadAuxiliaryAssets(nextItem, generation: nextGen));
  }

  /// 统一按当前活跃装填世代去重处理音轨自然完播（兼容 `end-file=eof` 与 `eof-reached=true` 双通道）。
  void _onNaturalTrackEofReached({int playlistEntryId = 0}) {
    if (!mounted || !state.isActive) return;
    if (playlistEntryId > 0) {
      if (playlistEntryId <= _retiredMpvPlaylistEntryId) return;
      if (playlistEntryId == _eofHandledMpvEntryId) return;
      if (_currentMpvPlaylistEntryId > 0 &&
          playlistEntryId != _currentMpvPlaylistEntryId) {
        return;
      }
    }
    if (_activeCommandedGeneration <= 0 ||
        _activeCommandedGeneration != _loadGeneration ||
        _completedGeneration == _activeCommandedGeneration) {
      return;
    }
    _completedGeneration = _activeCommandedGeneration;
    final handledEntry = playlistEntryId > 0
        ? playlistEntryId
        : _currentMpvPlaylistEntryId;
    if (handledEntry > 0) {
      _eofHandledMpvEntryId = handledEntry;
    }
    _loadedPhysicalKey = null;
    _isTransitioningCueBoundary = false;
    unawaited(_advanceOnTrackCompleted());
  }

  void _handleEndFile(MpvEndFileEvent event) {
    if (event.reason == MpvEndFileReason.eof) {
      _onNaturalTrackEofReached(playlistEntryId: event.playlistEntryId);
    } else if (event.reason == MpvEndFileReason.error) {
      if (event.playlistEntryId > 0) {
        if (event.playlistEntryId <= _retiredMpvPlaylistEntryId) {
          return;
        }
        if (_currentMpvPlaylistEntryId > 0 &&
            event.playlistEntryId != _currentMpvPlaylistEntryId) {
          return;
        }
      }
      if (_activeCommandedGeneration <= 0 ||
          _activeCommandedGeneration != _loadGeneration) {
        return;
      }
      _loadedPhysicalKey = null;
      _isTransitioningCueBoundary = false;
      _client?.setPropertyString('start', 'none');
      final curItem = state.currentItem;
      final bridgeDiag = _ref
          .read(localStreamBridgeProvider)
          .describeLastError(
            token: _activeStreamToken,
            relativePath: curItem?.effectiveRelativePath,
          );
      final reasonMessage =
          bridgeDiag ?? MpvError.describeAudioError(event.errorCode);
      unawaited(
        _handleTrackLoadFailure(
          generation: _activeCommandedGeneration,
          failedItem: curItem,
          reasonMessage: reasonMessage,
          retryable: true,
        ),
      );
    }
  }

  /// 处理单曲装填或解复用异常：对偶发错误最多静默重试 3 次，仍失败时自动跳至下一首并提示。
  Future<void> _handleTrackLoadFailure({
    required int generation,
    required AudioQueueItem? failedItem,
    required String reasonMessage,
    required bool retryable,
  }) async {
    if (!mounted || !state.isActive || generation != _loadGeneration) {
      return;
    }

    if (retryable &&
        _trackRetryCount < maxSilentRetries &&
        state.currentIndex >= 0 &&
        state.currentIndex < state.queue.length) {
      final attempt = ++_trackRetryCount;
      final delay = retryDelayBuilder != null
          ? retryDelayBuilder!(attempt)
          : (Platform.environment.containsKey('FLUTTER_TEST')
                ? Duration.zero
                : Duration(milliseconds: 120 * attempt));
      if (delay > Duration.zero) {
        await Future<void>.delayed(delay);
      }
      if (!mounted || !state.isActive || generation != _loadGeneration) {
        return;
      }
      final retryGen = ++_loadGeneration;
      await _startTrackAtIndex(
        state.currentIndex,
        generation: retryGen,
        initialTrackOffsetSeconds: 0.0,
        isRetryAttempt: true,
      );
      return;
    }

    _trackRetryCount = 0;
    _consecutiveFailedTracks += 1;
    final circuitBreakerTripped = _engine.recordPhysicalMediaFailure();
    _loadedPhysicalKey = null;
    final fallbackCover =
        (state.cover is EmptyAudioCover && failedItem != null)
        ? _resolvePosterFallback(failedItem.work)
        : state.cover;

    final rawNextIdx = state.currentIndex + 1;
    final canAdvance =
        !circuitBreakerTripped &&
        state.queue.length > 1 &&
        _consecutiveFailedTracks < state.queue.length &&
        (rawNextIdx < state.queue.length ||
            state.loopMode == AudioLoopMode.loopAll);

    if (canAdvance) {
      final targetIdx = rawNextIdx % state.queue.length;
      final titlePrefix = (failedItem != null && failedItem.title.isNotEmpty)
          ? '「${failedItem.title}」'
          : '当前曲目';
      state = state.copyWith(
        cover: fallbackCover,
        errorMessage: '$titlePrefix无法播放（$reasonMessage），已跳至下一首',
      );
      final nextGen = ++_loadGeneration;
      await _startTrackAtIndex(
        targetIdx,
        generation: nextGen,
        preserveErrorToast: true,
      );
      return;
    }

    if (circuitBreakerTripped) {
      state = state.copyWith(
        isPlaying: false,
        isBuffering: false,
        cover: fallbackCover,
        errorMessage:
            '连续 ${UnifiedPlaybackEngine.maxConsecutiveBadFiles} 个音频文件加载异常（$reasonMessage），已熔断停播',
      );
      return;
    }

    state = state.copyWith(
      isPlaying: false,
      isBuffering: false,
      cover: fallbackCover,
      errorMessage: reasonMessage,
    );
  }

  Future<void> _advanceOnTrackCompleted() async {
    if (!mounted || state.queue.isEmpty || !state.isActive) return;
    final finishedItem = state.currentItem;
    final finishedDuration = state.durationSeconds > 0
        ? state.durationSeconds
        : state.positionSeconds;
    if (finishedItem != null) {
      unawaited(
        _persistAudioProgress(
          finishedItem,
          positionSeconds: finishedDuration,
          durationSeconds: state.durationSeconds,
          completed: true,
          force: true,
        ),
      );
    }
    if (state.loopMode == AudioLoopMode.loopOne) {
      final currentIdx = state.currentIndex;
      if (currentIdx >= 0 && currentIdx < state.queue.length) {
        final gen = ++_loadGeneration;
        await _startTrackAtIndex(currentIdx, generation: gen);
      }
      return;
    }
    final nextIdx = state.currentIndex + 1;
    if (nextIdx < state.queue.length) {
      final gen = ++_loadGeneration;
      await _startTrackAtIndex(nextIdx, generation: gen);
    } else if (state.loopMode == AudioLoopMode.loopAll) {
      final gen = ++_loadGeneration;
      await _startTrackAtIndex(0, generation: gen);
    } else {
      _isTransitioningCueBoundary = false;
      final c = _client;
      if (c != null && !c.isDisposed) {
        c.setPropertyFlag('pause', true);
      }
      if (mounted) {
        state = state.copyWith(
          isPlaying: false,
          isBuffering: false,
          positionSeconds: finishedDuration,
        );
      }
    }
  }

  void _refreshProbeFromClient() {
    final c = _client;
    if (c == null || c.isDisposed) return;
    _rawCodec = c.getPropertyString('audio-codec-name') ?? _rawCodec;
    _rawSampleRateHz =
        c.getPropertyInt64('audio-params/samplerate') ?? _rawSampleRateHz;
    _rawAudioFormat =
        c.getPropertyString('audio-params/format') ?? _rawAudioFormat;
    final dur = c.getPropertyDouble('duration');
    if (dur != null && dur > 0) {
      _applyRawFileDuration(dur);
    }
    final bps = c.getPropertyInt64('audio-bitrate');
    _syncAudioSpecBadges(bitrateBps: bps);
  }

  void _syncAudioSpecBadges({int? bitrateBps}) {
    final codecShort = PlaybackFormatters.formatCodecShortLabel(_rawCodec);
    final summary = PlaybackFormatters.formatAudioSpecSummary(
      sampleRateHz: _rawSampleRateHz,
      audioFormat: _rawAudioFormat,
    );
    state = state.copyWith(
      audioCodecLabel: codecShort,
      sampleRateAndBitDepthLabel: summary,
      bitrateLabel: bitrateBps != null && bitrateBps > 0
          ? PlaybackFormatters.formatBitrate(bitrateBps)
          : state.bitrateLabel,
    );
  }

  /// 切换暂停 / 播放状态。
  Future<void> togglePlayPause() => setPlaying(!state.isPlaying);

  Future<void> _ensureAudioFocus() async {
    if (!KonataPlatform.isAndroid) return;
    await AndroidPlaybackWindowBridge.requestAudioFocus(
      onLoss: () {
        if (!mounted || !state.isActive) return;
        _volumeBeforeDuck = null;
        if (state.isPlaying) {
          unawaited(setPlaying(false));
        }
      },
      onDuck: () {
        if (!mounted || !state.isActive || !state.isPlaying) return;
        _volumeBeforeDuck ??= state.volume;
        final ducked = (_volumeBeforeDuck! * 0.25).clamp(0.0, 100.0);
        _client?.setPropertyDouble('volume', ducked);
      },
      onGain: () {
        if (!mounted || !state.isActive) return;
        final restore = _volumeBeforeDuck;
        _volumeBeforeDuck = null;
        if (restore != null) {
          _client?.setPropertyDouble('volume', state.isMuted ? 0.0 : restore);
        }
      },
    );
  }

  /// 显式设置播放状态（若已完播卸载或停在曲末，点击播放自动从头重载起播）。
  Future<void> setPlaying(bool playing) async {
    if (playing) {
      _volumeBeforeDuck = null;
      _client?.setPropertyDouble('volume', state.isMuted ? 0.0 : state.volume);
      await _ensureAudioFocus();
      if (state.isActive &&
          state.currentIndex >= 0 &&
          state.currentIndex < state.queue.length) {
        final atTrackEnd =
            state.durationSeconds > 0 &&
            state.positionSeconds >= state.durationSeconds - 0.15;
        if (_loadedPhysicalKey == null || atTrackEnd) {
          final resumeOffset = atTrackEnd ? 0.0 : state.positionSeconds;
          final gen = ++_loadGeneration;
          await _startTrackAtIndex(
            state.currentIndex,
            generation: gen,
            initialTrackOffsetSeconds: resumeOffset,
          );
          return;
        }
      }
    }
    final c = _client;
    if (c == null || c.isDisposed) return;
    c.setPropertyFlag('pause', !playing);
    state = state.copyWith(
      isPlaying: playing,
      isBuffering: playing ? state.isBuffering : false,
    );
    final item = state.currentItem;
    if (!playing && item != null) {
      unawaited(
        _persistAudioProgress(
          item,
          positionSeconds: state.positionSeconds,
          durationSeconds: state.durationSeconds,
          force: true,
        ),
      );
    }
  }

  /// 视频播放启动时自动暂停当前音乐（保留队列与进度）。
  Future<void> pauseForVideoSession() async {
    if (state.isActive && state.isPlaying) {
      await setPlaying(false);
    }
  }

  /// 在当前曲目（已自动叠加 `.cue` 起点偏移）内精确 Seek。
  Future<void> seekRelativeTrackSeconds(double trackSeconds) async {
    final item = state.currentItem;
    final c = _client;
    if (item == null || c == null || c.isDisposed) return;
    _isTransitioningCueBoundary = false;

    final clamped = state.durationSeconds > 0
        ? trackSeconds.clamp(0.0, state.durationSeconds)
        : math.max(0.0, trackSeconds);

    if (_loadedPhysicalKey == null &&
        state.currentIndex >= 0 &&
        state.currentIndex < state.queue.length) {
      final gen = ++_loadGeneration;
      await _startTrackAtIndex(
        state.currentIndex,
        generation: gen,
        initialTrackOffsetSeconds: clamped,
      );
      return;
    }

    if (_completedGeneration == _activeCommandedGeneration &&
        (state.durationSeconds <= 0 ||
            clamped < state.durationSeconds - 0.15)) {
      _completedGeneration = -1;
    }
    final rawTarget = (item.cueStartSeconds ?? 0.0) + clamped;
    final ranges = c.readDemuxerSeekableRanges();
    final cachedHit = MpvSeekableRange.isPositionCached(rawTarget, ranges);
    if (cachedHit) {
      _suppressBufferingUntil = DateTime.now().add(
        const Duration(milliseconds: 900),
      );
    } else {
      _suppressBufferingUntil = null;
    }
    _pendingSeekRawTargetSeconds = rawTarget;
    _pendingSeekGuardUntil = DateTime.now().add(_cueSeekDebounceWindow);
    c.command(['seek', rawTarget.toStringAsFixed(3), 'absolute', 'exact']);
    final lyricIdx = state.lrcDocument?.activeIndexAt(clamped) ?? -1;
    state = state.copyWith(
      positionSeconds: clamped,
      activeLyricIndex: lyricIdx,
      isBuffering: cachedHit ? false : state.isBuffering,
    );
    _syncAndroidMediaSession(forcePositionSync: true);
    unawaited(
      _persistAudioProgress(
        item,
        positionSeconds: clamped,
        durationSeconds: state.durationSeconds,
        force: true,
      ),
    );
  }

  /// 切换上一首。
  Future<void> previous() async {
    if (state.queue.isEmpty) return;
    _consecutiveFailedTracks = 0;
    _engine.recordManualSelection();
    if (state.positionSeconds > 4.0) {
      await seekRelativeTrackSeconds(0.0);
      return;
    }
    final target = state.currentIndex > 0
        ? state.currentIndex - 1
        : state.queue.length - 1;
    final gen = ++_loadGeneration;
    await _startTrackAtIndex(
      target,
      generation: gen,
      selectLastOnCueExpand: true,
    );
  }

  /// 切换下一首。
  Future<void> next() async {
    if (state.queue.isEmpty) return;
    _consecutiveFailedTracks = 0;
    _engine.recordManualSelection();
    final target = (state.currentIndex + 1) % state.queue.length;
    final gen = ++_loadGeneration;
    await _startTrackAtIndex(target, generation: gen);
  }

  /// 跳转队列中指定索引曲目。
  Future<void> playQueueIndex(int index) async {
    if (index < 0 || index >= state.queue.length) return;
    _consecutiveFailedTracks = 0;
    _engine.recordManualSelection();
    final gen = ++_loadGeneration;
    await _startTrackAtIndex(index, generation: gen);
  }

  /// 调整音量（0 ~ 100）。
  void setVolume(double volume) {
    final clamped = volume.clamp(0.0, 100.0);
    _client?.setPropertyDouble('volume', clamped);
    if (clamped > 0 && state.isMuted) {
      _client?.setPropertyFlag('mute', false);
      state = state.copyWith(volume: clamped, isMuted: false);
    } else {
      state = state.copyWith(volume: clamped);
    }
    unawaited(
      _ref.read(playbackPreferencesProvider.notifier).setDefaultVolume(clamped),
    );
  }

  /// 切换静音。
  void toggleMute() {
    final nextMuted = !state.isMuted;
    _client?.setPropertyFlag('mute', nextMuted);
    state = state.copyWith(isMuted: nextMuted);
  }

  /// 当媒体库作品海报被编辑、裁剪或重绑时，实时刷新 CD 回退封面缓存与当前在播封面。
  void syncUpdatedWorks(Iterable<Work> works, {String? forcedWorkId}) {
    if (!mounted) return;
    final changedWorks = <String, Work>{};
    for (final w in works) {
      final effectivePoster = (w.posterPath?.trim().isNotEmpty == true)
          ? w.posterPath!.trim()
          : (w.bangumiPosterPath?.trim().isNotEmpty == true)
          ? w.bangumiPosterPath!.trim()
          : (w.posterFallback?.trim() ?? '');
      final prev = _lastKnownPosterByWorkId[w.id];
      _lastKnownPosterByWorkId[w.id] = effectivePoster;
      if (forcedWorkId == w.id || (prev != null && prev != effectivePoster)) {
        _workPosterRevisions[w.id] = (_workPosterRevisions[w.id] ?? 0) + 1;
        changedWorks[w.id] = w;
      } else if (prev == null &&
          state.queue.any(
            (q) => q.work.id == w.id && q.work.posterPath != w.posterPath,
          )) {
        _workPosterRevisions[w.id] = (_workPosterRevisions[w.id] ?? 0) + 1;
        changedWorks[w.id] = w;
      }
    }
    if (changedWorks.isEmpty) return;

    for (final entry in changedWorks.entries) {
      final wid = entry.key;
      final newFallback = _resolvePosterFallback(entry.value);
      final keysToRefresh = [
        for (final kv in _albumCoverCache.entries)
          if (kv.key.startsWith('$wid::') && !kv.value.hasDedicatedCover)
            kv.key,
      ];
      for (final k in keysToRefresh) {
        _albumCoverCache[k] = (cover: newFallback, hasDedicatedCover: false);
      }
    }

    if (state.queue.isEmpty) return;
    var queueUpdated = false;
    final nextQueue = <AudioQueueItem>[
      for (final q in state.queue)
        if (changedWorks.containsKey(q.work.id))
          () {
            queueUpdated = true;
            return q.copyWith(work: changedWorks[q.work.id]);
          }()
        else
          q,
    ];

    AudioCoverSource nextCover = state.cover;
    final current =
        (state.currentIndex >= 0 && state.currentIndex < nextQueue.length)
        ? nextQueue[state.currentIndex]
        : null;
    if (current != null && changedWorks.containsKey(current.work.id)) {
      final cachedEntry = _albumCoverCache[current.albumCacheKey];
      final usesFallback =
          (cachedEntry != null && !cachedEntry.hasDedicatedCover) ||
          state.cover is ManagedPosterAudioCover ||
          state.cover is EmptyAudioCover;
      if (usesFallback) {
        nextCover = _resolvePosterFallback(current.work);
      }
    }

    if (queueUpdated || !identical(nextCover, state.cover)) {
      state = state.copyWith(queue: nextQueue, cover: nextCover);
    }
  }

  /// 供封面选择器保存后主动强制刷新指定作品的 CD 回退封面。
  Future<void> refreshWorkPosterById(String workId) async {
    try {
      final items = await _ref.read(libraryItemsProvider.future);
      if (!mounted) return;
      syncUpdatedWorks([for (final e in items) e.work], forcedWorkId: workId);
    } catch (_) {}
  }

  /// 循环切换单曲/列表/顺序播放模式。
  void cycleLoopMode() {
    state = state.copyWith(loopMode: state.loopMode.nextMode());
  }

  /// 手动关闭当前音频错误提示横幅。
  void dismissError() {
    if (state.errorMessage != null) {
      state = state.copyWith(clearError: true);
    }
  }

  /// 停止音频播放、释放本地流并关闭迷你栏与沉浸页。
  Future<void> stopAndClose() async {
    final closingItem = state.currentItem;
    final closingPos = state.positionSeconds;
    final closingDur = state.durationSeconds;
    ++_loadGeneration;
    _engine.resetSession();
    _activeCommandedGeneration = 0;
    _completedGeneration = -1;
    if (_currentMpvPlaylistEntryId > _retiredMpvPlaylistEntryId) {
      _retiredMpvPlaylistEntryId = _currentMpvPlaylistEntryId;
    }
    _trackRetryCount = 0;
    _consecutiveFailedTracks = 0;
    _loadedPhysicalKey = null;
    _isTransitioningCueBoundary = false;

    _pendingSeekRawTargetSeconds = null;
    _pendingSeekGuardUntil = null;
    _pendingRemoteAuxJob = null;
    _sessionAllCdVariants = const [];
    _sessionSourcesById = const {};
    _unexpandedMasterByCueId.clear();
    _expandedTracksByCueId.clear();
    _nonExpandableCueIds.clear();
    if (closingItem != null) {
      await _persistAudioProgress(
        closingItem,
        positionSeconds: closingPos,
        durationSeconds: closingDur,
        force: true,
      );
    }
    final c = _client;
    if (c != null && !c.isDisposed) {
      MpvQualityProfile.resetAudioRangeAndLoopProperties(
        c,
        logStore: _ref.read(diagnosticsLogStoreProvider),
      );
      c.command(['stop']);
    }
    _volumeBeforeDuck = null;
    await _mediaSessionBridge.stopSession();
    await AndroidPlaybackWindowBridge.abandonAudioFocus();
    await _releaseActiveStreamSession();
    _ref.read(immersiveAudioExpandedProvider.notifier).state = false;
    if (mounted) {
      state = const AudioPlaybackState();
    }
  }

  Future<void> _persistAudioProgress(
    AudioQueueItem item, {
    required double positionSeconds,
    required double durationSeconds,
    bool completed = false,
    bool force = false,
  }) async {
    final now = DateTime.now();
    if (!force &&
        _lastAudioPersistAt != null &&
        now.difference(_lastAudioPersistAt!) < const Duration(seconds: 5)) {
      return;
    }
    if (_persistInFlight && !force) return;
    _persistInFlight = true;
    _lastAudioPersistAt = now;
    try {
      final repo = _ref.read(libraryRepositoryProvider);
      final posSec = positionSeconds > 0 ? positionSeconds.round() : 0;
      final durSec = durationSeconds > 0 ? durationSeconds.round() : 0;
      final isDone =
          completed ||
          PlaybackRecord.computeCompleted(
            positionSeconds: posSec,
            durationSeconds: durSec,
          );
      final recordId = '${PlaybackRecord.audioEpisodePrefix}${item.id}';
      await repo.recordPlayback(
        PlaybackRecord(
          id: recordId,
          workId: item.work.id,
          episodeId: recordId,
          variantId: item.variant.id,
          seasonNumber: 0,
          episodeNumber: item.trackNumber,
          episodeTitle: item.title,
          sourceType: item.source?.kind ?? MediaSourceKind.local,
          playedAt: now,
          positionSeconds: posSec,
          durationSeconds: durSec,
          isCompleted: isDone,
        ),
      );
      if (mounted) {
        _ref.invalidate(playbackHistoryProvider);
      }
    } catch (_) {
      // 忽略单测或未挂载数据库上下文时的持久化异常
    } finally {
      _persistInFlight = false;
    }
  }

  @override
  void dispose() {
    ++_loadGeneration;
    unawaited(_mediaSessionBridge.stopSession());
    _mediaSessionBridge.dispose();
    unawaited(_eventSub?.cancel());
    _eventSub = null;
    unawaited(_releaseActiveStreamSession());
    AndroidAudioRouteBridge.unbindRouteListeners();
    final c = _client;
    _client = null;
    if (c != null && !c.isDisposed) {
      unawaited(c.dispose());
    }
    super.dispose();
  }

  AudioDeviceSafetyState _deviceSafetyState = const AudioDeviceSafetyState();

  /// 外设热拔出双通道瞬态静音：仅推进音频输出路由代数，绝不中断底层正在读取的网桥媒体流。
  void _handleAudioDeviceRemovedTransientMute() {
    _engine.advanceAudioOutputRoute();
    _deviceSafetyState = _deviceSafetyState.onDeviceChanged('builtin_fallback');
    final client = _client;
    if (client != null && !client.isDisposed && client.isInitialized) {
      client.setPropertyFlag('mute', true);
      client.setPropertyFlag('pause', true);
    }
    if (mounted) {
      state = state.copyWith(isPlaying: false, isMuted: true);
    }
  }
}

/// 全局持久 CD 纯音频播放器 Provider。
final audioPlaybackProvider =
    StateNotifierProvider<AudioPlaybackNotifier, AudioPlaybackState>((ref) {
      final notifier = AudioPlaybackNotifier(
        ref,
        gatewayFactory: ref.read(mediaSourceGatewayFactoryProvider),
      );
      ref.listen<bool>(videoPlaybackActiveProvider, (_, isVideoActive) {
        if (isVideoActive) {
          unawaited(notifier.pauseForVideoSession());
        }
      });
      ref.listen<AsyncValue<List<WorkLibraryItem>>>(libraryItemsProvider, (
        _,
        next,
      ) {
        final items = next.valueOrNull;
        if (items != null) {
          notifier.syncUpdatedWorks([for (final e in items) e.work]);
        }
      });
      return notifier;
    });

class _CueTrackBoundsException implements Exception {
  const _CueTrackBoundsException(this.message);
  final String message;

  @override
  String toString() => message;
}
