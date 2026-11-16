import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../domain/models/media_source.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/models/playback_record.dart';
import '../../domain/models/work.dart';
import '../../domain/playback/cue_and_lrc_parser.dart';
import '../../domain/playback/playback_formatters.dart';
import '../../domain/repositories/file_system_gateway.dart';
import '../../infrastructure/players/audio_art_extractor.dart';
import '../../infrastructure/players/libmpv_ffi.dart';
import '../../infrastructure/players/mpv_quality_profile.dart';
import '../../infrastructure/sources/byte_stream_source_gateway.dart';
import '../../infrastructure/sources/local_source_gateway.dart';
import '../../infrastructure/sources/source_gateway_factory.dart';
import '../../infrastructure/storage/storage_root_provider.dart';
import '../providers/diagnostics_providers.dart';
import '../providers/library_providers.dart';
import '../providers/playback_providers.dart';
import 'playback_preferences_provider.dart';

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
  }) : super(const AudioPlaybackState());

  static const Set<String> _audioExts = {
    '.flac',
    '.ape',
    '.wav',
    '.wv',
    '.tak',
    '.alac',
    '.m4a',
    '.aac',
    '.mp3',
    '.ogg',
    '.opus',
    '.dsf',
    '.dff',
  };

  static const int _propTimePos = 101;
  static const int _propDuration = 102;
  static const int _propPause = 103;
  static const int _propCoreIdle = 104;
  static const int _propAudioCodec = 105;
  static const int _propSampleRate = 106;
  static const int _propAudioFormat = 107;
  static const int _propAudioBitrate = 108;

  final Ref _ref;
  final LibMpvClient Function()? clientFactory;
  final MediaSourceGatewayFactory gatewayFactory;

  static const Duration _cueSeekDebounceWindow = Duration(milliseconds: 900);
  static const int _maxAlbumCacheEntries = 32;

  LibMpvClient? _client;
  StreamSubscription<MpvClientEvent>? _eventSub;
  String? _activeStreamToken;
  String? _loadedPhysicalKey;
  int _loadGeneration = 0;
  bool _isTransitioningCueBoundary = false;

  double? _pendingSeekRawTargetSeconds;
  DateTime? _pendingSeekGuardUntil;
  DateTime? _lastAudioPersistAt;
  bool _persistInFlight = false;
  DateTime? _suppressBufferingUntil;

  final Map<String, double> _rawDurationByPhysicalKey = {};
  final Map<String, ({AudioCoverSource cover, bool hasDedicatedCover})>
  _albumCoverCache = {};
  final Map<String, List<RemoteEntry>> _siblingsByDirCache = {};
  final Set<String> _checkedEmbeddedCoverPhysicalKeys = {};
  final Map<String, int> _workPosterRevisions = {};
  final Map<String, String> _lastKnownPosterByWorkId = {};

  String _rawCodec = '';
  int? _rawSampleRateHz;
  String _rawAudioFormat = '';
  double _rawFileDurationSeconds = 0.0;

  /// 判断文件名是否为受支持的音频物理轨。
  static bool isPlayableAudioFile(String fileName) {
    final ext = p.extension(fileName.trim()).toLowerCase();
    return _audioExts.contains(ext);
  }

  /// 判断文件名是否为 `.cue` 分轨清单。
  static bool isCueSheetFile(String fileName) {
    return p.extension(fileName.trim()).toLowerCase() == '.cue';
  }

  /// 以指定曲目（支持单轨物理音频与 `.cue` 虚拟分轨）开启 CD 播放队列。
  Future<void> playCdCollection({
    required Work work,
    required List<MediaVariant> cdVariants,
    required MediaVariant initialVariant,
    required Map<String, MediaSource> sourcesById,
    int? initialCueTrackNumber,
  }) async {
    final generation = ++_loadGeneration;
    final items = await _buildQueueItems(
      work: work,
      cdVariants: cdVariants,
      initialVariant: initialVariant,
      sourcesById: sourcesById,
    );
    if (generation != _loadGeneration || !mounted) return;
    if (items.isEmpty) {
      state = state.copyWith(
        isActive: true,
        isPlaying: false,
        errorMessage: '未找到可播放的 CD 音频轨道',
      );
      return;
    }

    var targetIndex = 0;
    if (initialCueTrackNumber != null) {
      final matched = items.indexWhere(
        (e) => e.trackNumber == initialCueTrackNumber,
      );
      if (matched >= 0) targetIndex = matched;
    } else {
      final matched = items.indexWhere(
        (e) => e.variant.id == initialVariant.id,
      );
      if (matched >= 0) targetIndex = matched;
    }

    final previousItem = state.currentItem;
    final initialVol = _ref.read(playbackPreferencesProvider).defaultVolume;
    state = state.copyWith(
      isActive: true,
      queue: items,
      currentIndex: targetIndex,
      volume: state.isActive ? state.volume : initialVol,
      clearError: true,
    );

    await _startTrackAtIndex(
      targetIndex,
      generation: generation,
      previousItemOverride: previousItem,
    );
  }

  Future<List<AudioQueueItem>> _buildQueueItems({
    required Work work,
    required List<MediaVariant> cdVariants,
    required MediaVariant initialVariant,
    required Map<String, MediaSource> sourcesById,
  }) async {
    final initialNameLower = initialVariant.fileName.toLowerCase();
    final initialSource = sourcesById[initialVariant.sourceId];

    // 1. 优先判定用户是否点击了 .cue 或同目录存在匹配的同名 .cue
    MediaVariant? cueVariant;
    if (isCueSheetFile(initialNameLower)) {
      cueVariant = initialVariant;
    } else {
      final dir = p.posix.dirname(
        initialVariant.relativePath.replaceAll('\\', '/'),
      );
      final stem = p.basenameWithoutExtension(initialNameLower);
      for (final candidate in cdVariants) {
        if (!isCueSheetFile(candidate.fileName)) continue;
        final cDir = p.posix.dirname(
          candidate.relativePath.replaceAll('\\', '/'),
        );
        final cStem = p.basenameWithoutExtension(
          candidate.fileName.toLowerCase(),
        );
        if (cDir == dir && (cStem == stem || stem.startsWith(cStem))) {
          cueVariant = candidate;
          break;
        }
      }
    }

    if (cueVariant != null && initialSource != null) {
      final cueSheet = await AudioAssetExtractor.loadCueSheet(
        source: initialSource,
        cueRelativePath: cueVariant.relativePath,
        gatewayFactory: gatewayFactory,
      );
      if (cueSheet != null && cueSheet.tracks.isNotEmpty) {
        final cueDir = p.posix.dirname(
          cueVariant.relativePath.replaceAll('\\', '/'),
        );
        final audioVariantsInDir = cdVariants.where((v) {
          if (!isPlayableAudioFile(v.fileName)) return false;
          final vDir = p.posix.dirname(v.relativePath.replaceAll('\\', '/'));
          return vDir == cueDir;
        }).toList();

        final result = <AudioQueueItem>[];
        for (final track in cueSheet.tracks) {
          final targetAudio = _resolveCueTargetVariant(
            cueVariant: cueVariant,
            cueTrack: track,
            audioVariantsInDir: audioVariantsInDir,
            fallbackInitial: initialVariant,
          );
          if (targetAudio == null) continue;
          final src = sourcesById[targetAudio.sourceId] ?? initialSource;
          final physKey =
              '${src.id}::${targetAudio.relativePath.replaceAll('\\', '/')}';
          final knownRawDur = _rawDurationByPhysicalKey[physKey] ?? 0.0;
          final trackEnd = track.endSeconds;
          Duration initialDuration = Duration.zero;
          if (trackEnd != null && trackEnd > track.startSeconds) {
            initialDuration = Duration(
              milliseconds: ((trackEnd - track.startSeconds) * 1000).round(),
            );
          } else if (trackEnd == null && knownRawDur > track.startSeconds) {
            initialDuration = Duration(
              milliseconds: ((knownRawDur - track.startSeconds) * 1000).round(),
            );
          }
          result.add(
            AudioQueueItem(
              id: '${cueVariant.id}::track_${track.trackNumber}',
              work: work,
              variant: targetAudio,
              source: src,
              title: track.title.isNotEmpty
                  ? track.title
                  : 'Track ${track.trackNumber.toString().padLeft(2, '0')}',
              performer: track.performer.isNotEmpty
                  ? track.performer
                  : cueSheet.performer,
              albumTitle: cueSheet.title.isNotEmpty
                  ? cueSheet.title
                  : work.title,
              trackNumber: track.trackNumber,
              cueStartSeconds: track.startSeconds,
              cueEndSeconds: track.endSeconds,
              targetAudioRelativePath: targetAudio.relativePath,
              duration: initialDuration,
            ),
          );
        }
        if (result.isNotEmpty) return result;
      }
    }

    // 2. 常规物理音轨集合（屏蔽 .log/.cue/.jpg/.lrc 辅助文件）
    final audioItems = <AudioQueueItem>[];
    for (final v in cdVariants) {
      if (!isPlayableAudioFile(v.fileName)) continue;
      final src = sourcesById[v.sourceId];
      final trackTitle = p.basenameWithoutExtension(v.fileName);
      final folderName = p.posix.basename(
        p.posix.dirname(v.relativePath.replaceAll('\\', '/')),
      );
      audioItems.add(
        AudioQueueItem(
          id: v.id,
          work: work,
          variant: v,
          source: src,
          title: trackTitle,
          albumTitle: (folderName.isNotEmpty && folderName != '.')
              ? folderName
              : work.title,
        ),
      );
    }
    return audioItems;
  }

  MediaVariant? _resolveCueTargetVariant({
    required MediaVariant cueVariant,
    required CueTrack cueTrack,
    required List<MediaVariant> audioVariantsInDir,
    required MediaVariant fallbackInitial,
  }) {
    final declared = cueTrack.fileName.trim().toLowerCase();
    if (declared.isNotEmpty) {
      for (final candidate in audioVariantsInDir) {
        if (candidate.fileName.toLowerCase() == declared) {
          return candidate;
        }
      }
      final declaredStem = p.basenameWithoutExtension(declared);
      for (final candidate in audioVariantsInDir) {
        if (p.basenameWithoutExtension(candidate.fileName.toLowerCase()) ==
            declaredStem) {
          return candidate;
        }
      }
    }
    if (isPlayableAudioFile(fallbackInitial.fileName)) {
      return fallbackInitial;
    }
    if (audioVariantsInDir.isNotEmpty) {
      return audioVariantsInDir.first;
    }
    // 即使数据库未收录整轨音频条目，也按 CUE 同目录下同名相对路径构造虚拟目标引用
    if (cueTrack.fileName.trim().isNotEmpty) {
      final dir = p.posix.dirname(
        cueVariant.relativePath.replaceAll('\\', '/'),
      );
      final rel = dir == '.'
          ? cueTrack.fileName.trim()
          : '$dir/${cueTrack.fileName.trim()}';
      return MediaVariant(
        id: '${cueVariant.id}::audio_file',
        workId: cueVariant.workId,
        sourceId: cueVariant.sourceId,
        relativePath: rel,
        fileName: p.basename(cueTrack.fileName.trim()),
        fileSize: 0,
        assetKind: cueVariant.assetKind,
      );
    }
    return null;
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
    final rc = client.initialize();
    if (rc < 0) {
      await client.dispose();
      throw StateError('纯音频引擎初始化失败: ${client.errorString(rc)}');
    }

    client.setPropertyDouble('volume', state.isMuted ? 0.0 : state.volume);
    client.setPropertyFlag('mute', state.isMuted);
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
  }) async {
    if (index < 0 || index >= state.queue.length || !mounted) return;
    final previousItem = previousItemOverride ?? state.currentItem;
    final item = state.queue[index];
    _isTransitioningCueBoundary = false;

    final physicalKey = item.physicalFileKey;
    final cachedRawDuration =
        _rawDurationByPhysicalKey[physicalKey] ??
        (_loadedPhysicalKey == physicalKey ? _rawFileDurationSeconds : 0.0);
    final canSeekInsideLoadedCue =
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
      positionSeconds: 0.0,
      durationSeconds: initialDuration,
      activeLyricIndex: -1,
      clearLrcDocument: true,
      cover: initialCover,
      audioCodecLabel: canSeekInsideLoadedCue ? state.audioCodecLabel : '',
      sampleRateAndBitDepthLabel: canSeekInsideLoadedCue
          ? state.sampleRateAndBitDepthLabel
          : '',
      bitrateLabel: canSeekInsideLoadedCue ? state.bitrateLabel : '',
      clearError: true,
    );

    final isRemote =
        item.source != null && item.source!.kind != MediaSourceKind.local;
    try {
      await _ensureClientInitialized(isRemoteStream: isRemote);
      if (generation != _loadGeneration || !mounted) return;
      final client = _client!;

      if (canSeekInsideLoadedCue) {
        final start = item.cueStartSeconds ?? 0.0;
        _pendingSeekRawTargetSeconds = start;
        _pendingSeekGuardUntil = DateTime.now().add(_cueSeekDebounceWindow);
        client.setPropertyFlag('pause', false);
        client.command(['seek', start.toStringAsFixed(3), 'absolute', 'exact']);
        _syncAudioSpecBadges();
        if (mounted) {
          state = state.copyWith(isBuffering: false, isPlaying: true);
        }
        unawaited(
          _persistAudioProgress(
            item,
            positionSeconds: 0,
            durationSeconds: initialDuration,
            force: true,
          ),
        );
        unawaited(_loadAuxiliaryAssets(item, generation: generation));
        return;
      }

      _pendingSeekRawTargetSeconds = null;
      _pendingSeekGuardUntil = null;
      _suppressBufferingUntil = null;
      await _releaseActiveStreamSession();
      final mediaTarget = await _resolvePlaybackTarget(item);
      if (generation != _loadGeneration || !mounted) return;

      MpvQualityProfile.applyRuntimeStreamProfile(
        client,
        isRemoteStream: isRemote,
        isAudio: true,
        config: _ref.read(playbackPreferencesProvider).qualityConfig,
        logStore: _ref.read(diagnosticsLogStoreProvider),
      );

      _loadedPhysicalKey = physicalKey;
      _rawFileDurationSeconds = cachedRawDuration;
      _rawCodec = '';
      _rawSampleRateHz = null;
      _rawAudioFormat = '';

      if (item.cueStartSeconds != null && item.cueStartSeconds! > 0) {
        client.setPropertyDouble('start', item.cueStartSeconds!);
      } else {
        client.setPropertyString('start', 'none');
      }
      client.setPropertyFlag('pause', false);
      final cmdRc = client.command(['loadfile', mediaTarget, 'replace']);
      if (cmdRc < 0) {
        throw StateError(client.errorString(cmdRc));
      }
      unawaited(
        _persistAudioProgress(
          item,
          positionSeconds: 0,
          durationSeconds: initialDuration,
          force: true,
        ),
      );
      // 音频起播命令下发完成后再异步拉取封面与 LRC 歌词，避免与首段音频流争抢连接
      unawaited(_loadAuxiliaryAssets(item, generation: generation));
    } catch (e) {
      if (generation == _loadGeneration && mounted) {
        state = state.copyWith(
          isBuffering: false,
          isPlaying: false,
          errorMessage: '音频加载失败: $e',
        );
      }
    }
  }

  Future<String> _resolvePlaybackTarget(AudioQueueItem item) async {
    final source = item.source;
    if (source == null || source.kind == MediaSourceKind.local) {
      if (source != null) {
        final gw = LocalSourceGateway(rootPath: source.location);
        return gw.resolveAbsolutePath(item.effectiveRelativePath);
      }
      return item.effectiveRelativePath;
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
    );
    _activeStreamToken = reg.token;
    return reg.url.toString();
  }

  Future<void> _releaseActiveStreamSession() async {
    final token = _activeStreamToken;
    if (token == null) return;
    _activeStreamToken = null;
    try {
      await _ref.read(localStreamBridgeProvider).unregisterSession(token);
    } catch (_) {}
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
        _client?.setPropertyString('start', 'none');
        state = state.copyWith(isBuffering: false, isPlaying: true);
        _refreshProbeFromClient();
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
      case MpvStartFileEvent():
      case MpvVideoReconfigEvent():
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
        final suppressed =
            _suppressBufferingUntil != null &&
            DateTime.now().isBefore(_suppressBufferingUntil!);
        state = state.copyWith(
          isBuffering: (!suppressed && state.isPlaying && idle),
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
        rawPositionSeconds >= cueEnd - 0.08 &&
        !_isTransitioningCueBoundary) {
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
      unawaited(_advanceOnTrackCompleted());
      return;
    }

    final relPos = state.durationSeconds > 0
        ? (rawPositionSeconds - cueStart).clamp(0.0, state.durationSeconds)
        : math.max(0.0, rawPositionSeconds - cueStart);
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
    _isTransitioningCueBoundary = false;

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

  void _handleEndFile(MpvEndFileEvent event) {
    if (event.reason == MpvEndFileReason.eof) {
      unawaited(_advanceOnTrackCompleted());
    } else if (event.reason == MpvEndFileReason.error) {
      state = state.copyWith(
        isPlaying: false,
        isBuffering: false,
        errorMessage: '音频解码中断 (${event.errorCode})',
      );
    }
  }

  Future<void> _advanceOnTrackCompleted() async {
    if (!mounted || state.queue.isEmpty) return;
    final finishedItem = state.currentItem;
    if (finishedItem != null) {
      unawaited(
        _persistAudioProgress(
          finishedItem,
          positionSeconds: state.durationSeconds,
          durationSeconds: state.durationSeconds,
          completed: true,
          force: true,
        ),
      );
    }
    if (state.loopMode == AudioLoopMode.loopOne) {
      await seekRelativeTrackSeconds(0.0);
      await setPlaying(true);
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
      await setPlaying(false);
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

  /// 显式设置播放状态。
  Future<void> setPlaying(bool playing) async {
    final c = _client;
    if (c == null || c.isDisposed) return;
    c.setPropertyFlag('pause', !playing);
    state = state.copyWith(isPlaying: playing);
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
    if (state.positionSeconds > 4.0) {
      await seekRelativeTrackSeconds(0.0);
      return;
    }
    final target = state.currentIndex > 0
        ? state.currentIndex - 1
        : state.queue.length - 1;
    final gen = ++_loadGeneration;
    await _startTrackAtIndex(target, generation: gen);
  }

  /// 切换下一首。
  Future<void> next() async {
    if (state.queue.isEmpty) return;
    final target = (state.currentIndex + 1) % state.queue.length;
    final gen = ++_loadGeneration;
    await _startTrackAtIndex(target, generation: gen);
  }

  /// 跳转队列中指定索引曲目。
  Future<void> playQueueIndex(int index) async {
    if (index < 0 || index >= state.queue.length) return;
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

  /// 停止音频播放、释放本地流并关闭迷你栏与沉浸页。
  Future<void> stopAndClose() async {
    final closingItem = state.currentItem;
    final closingPos = state.positionSeconds;
    final closingDur = state.durationSeconds;
    ++_loadGeneration;
    _loadedPhysicalKey = null;
    _isTransitioningCueBoundary = false;
    _pendingSeekRawTargetSeconds = null;
    _pendingSeekGuardUntil = null;
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
      c.command(['stop']);
    }
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
    unawaited(_eventSub?.cancel());
    _eventSub = null;
    unawaited(_releaseActiveStreamSession());
    final c = _client;
    _client = null;
    if (c != null && !c.isDisposed) {
      unawaited(c.dispose());
    }
    super.dispose();
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
