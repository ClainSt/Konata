import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../infrastructure/players/libmpv_ffi.dart';

/// 统一播放内核当前托管的活跃舞台类型。
enum PlaybackStageKind {
  /// 空闲无活跃物理会话。
  none,

  /// 音频 / CD 音乐舞台。
  audio,

  /// 内置视频舞台。
  video,
}

/// 暂挂舞台的物理会话快照（用于视频打断暂停音频后，音频恢复播放时原子重绑代数与流租约）。
@immutable
class SuspendedPhysicalSession {
  /// 创建暂挂物理会话快照。
  const SuspendedPhysicalSession({
    required this.stage,
    required this.nativeInstanceId,
    this.playlistEntryId,
    this.mainStreamLeaseToken,
    this.prefetchStreamLeaseToken,
    this.fileLoaded = false,
    this.effectiveProgressConfirmed = false,
  });

  /// 暂挂舞台分类。
  final PlaybackStageKind stage;

  /// 该舞台关联的底层 libmpv 实例编号。
  final int nativeInstanceId;

  /// 该舞台暂挂前绑定的 mpv 播放列表项编号。
  final int? playlistEntryId;

  /// 该舞台暂挂前的主流网桥租约令牌。
  final String? mainStreamLeaseToken;

  /// 该舞台暂挂前的预取流网桥租约令牌。
  final String? prefetchStreamLeaseToken;

  /// 暂挂前是否已收到 `FILE_LOADED`。
  final bool fileLoaded;

  /// 暂挂前是否已证实有效播放推进。
  final bool effectiveProgressConfirmed;
}

/// 播放异步任务的四域隔离分类。
///
/// 任一域主动取消或刷新任务代数时，严禁误杀其余域正在进行的后台任务。
enum PlaybackTaskDomain {
  /// 原始外挂字幕拉取与原子落盘。
  rawSubtitleFetch,

  /// 可选云端字幕字体子集化。
  cloudSubset,

  /// 同步歌词与多源版本消歧检索。
  lyricLookup,

  /// 封面主色提取与舞台色板计算。
  artworkColor,
}

/// 媒体流租约归属类别（区分主流与无缝预取流，严禁预取误杀当前播放流）。
enum PlaybackStreamLeaseKind {
  /// 当前正在播放的物理媒体主流。
  main,

  /// 下一曲目或下一分集的独立预取流。
  prefetch,
}

/// 受按域代数隔离保护的异步任务令牌快照。
@immutable
class ScopedTaskToken {
  /// 创建分域异步任务令牌。
  const ScopedTaskToken({
    required this.domain,
    required this.domainGeneration,
    required this.physicalMediaEpoch,
    required this.logicalTrackEpoch,
  });

  /// 所属隔离域。
  final PlaybackTaskDomain domain;

  /// 该域内单调递增的任务代数。
  final int domainGeneration;

  /// 创建令牌时的物理媒体代数。
  final int physicalMediaEpoch;

  /// 创建令牌时的逻辑曲目代数。
  final int logicalTrackEpoch;

  @override
  bool operator ==(Object other) {
    return other is ScopedTaskToken &&
        other.domain == domain &&
        other.domainGeneration == domainGeneration &&
        other.physicalMediaEpoch == physicalMediaEpoch &&
        other.logicalTrackEpoch == logicalTrackEpoch;
  }

  @override
  int get hashCode => Object.hash(
    domain,
    domainGeneration,
    physicalMediaEpoch,
    logicalTrackEpoch,
  );
}

/// 物理媒体流租约描述（与主流、预取流分别隔离）。
@immutable
class PlaybackStreamLease {
  /// 创建流租约描述。
  const PlaybackStreamLease({
    required this.leaseToken,
    required this.kind,
    required this.physicalMediaEpoch,
    required this.nativeInstanceId,
    this.playlistEntryId,
  });

  /// 网桥回环流令牌。
  final String leaseToken;

  /// 主流或预取流分类。
  final PlaybackStreamLeaseKind kind;

  /// 所属物理媒体代数。
  final int physicalMediaEpoch;

  /// 所属底层 libmpv 原生实例标识。
  final int nativeInstanceId;

  /// 对应的 mpv 播放列表项标识。
  final int? playlistEntryId;
}

/// 音视频一体化单一播放协调内核（四维代数隔离 + 连续坏文件熔断器）。
///
/// 四维代数边界：
/// 1. `physicalMediaEpoch` + `nativeInstanceId` + `playlistEntryId`：隔离底层物理文件解码与主流/预取租约；
/// 2. `logicalTrackEpoch`：隔离 CUE 同母文件跨轨元信息与歌词，推进时不中断物理流；
/// 3. `audioOutputEpoch`：隔离音频输出设备切换与 `ao-reload`，推进时不误杀底层媒体流；
/// 4. `ScopedTaskToken`：按四域独立取消异步后台任务，互不牵连。
class UnifiedPlaybackEngine {
  /// 创建统一播放内核，由内核唯一托管全进程单个活跃底层 `LibMpvClient` 实例。
  UnifiedPlaybackEngine({LibMpvClient Function()? defaultClientFactory})
    : _defaultClientFactory = defaultClientFactory ?? FfiLibMpvClient.create;

  /// 队列连续物理坏文件触发熔断的上限阈值。
  static const int maxConsecutiveBadFiles = 3;

  /// 认定音频已证实有效播放推进的最小时长阈值（毫秒）。
  static const int effectiveAudioProgressThresholdMs = 500;

  final LibMpvClient Function() _defaultClientFactory;
  Future<void> _clientLeaseChain = Future<void>.value();
  int _liveNativeClientCount = 0;
  Future<void> Function()? _activeNativeClientEvictor;

  int _physicalMediaEpoch = 0;
  int _nativeInstanceId = 0;
  int? _currentPlaylistEntryId;
  int _logicalTrackEpoch = 0;
  int _audioOutputEpoch = 0;
  PlaybackStageKind _activeStage = PlaybackStageKind.none;
  LibMpvClient? _activeNativeClient;
  final Map<PlaybackStageKind, SuspendedPhysicalSession> _suspendedSessions =
      {};

  final Map<PlaybackTaskDomain, int> _domainGenerations = {
    for (final domain in PlaybackTaskDomain.values) domain: 0,
  };

  PlaybackStreamLease? _mainLease;
  PlaybackStreamLease? _prefetchLease;

  bool _fileLoadedInCurrentEpoch = false;
  bool _effectiveProgressConfirmed = false;
  int _consecutiveBadFiles = 0;

  /// 当前进程内由内核托管的活跃底层 `LibMpvClient` 活体计数（严格保证 `<= 1`）。
  int get liveNativeClientCount => _liveNativeClientCount;

  /// 当前由内核托管的活跃播放舞台类型。
  PlaybackStageKind get activeStage => _activeStage;

  /// 当前由内核托管的活跃底层 libmpv 实例引用。
  LibMpvClient? get activeNativeClient => _activeNativeClient;

  /// 互斥申请全进程唯一的底层 `LibMpvClient` 句柄。
  ///
  /// 若当前存在其他舞台或旧实例存活，先严格串行执行驱逐回调并完整释放旧原生句柄，
  /// 确保任意时刻进程内存与 FFI 层最多仅存在 1 个 `LibMpvClient` 实例。
  Future<({LibMpvClient client, int nativeInstanceId})>
  acquireExclusiveNativeClient({
    required PlaybackStageKind stage,
    LibMpvClient Function()? factoryOverride,
    Future<void> Function()? onEvicted,
  }) {
    final completer = Completer<({LibMpvClient client, int nativeInstanceId})>();
    _clientLeaseChain = _clientLeaseChain.catchError((Object _) {}).then((_) async {
      try {
        final existing = _activeNativeClient;
        final existingEvictor = _activeNativeClientEvictor;
        if (existing != null) {
          if (_activeStage != PlaybackStageKind.none &&
              stage != PlaybackStageKind.none &&
              _activeStage != stage &&
              _nativeInstanceId > 0) {
            suspendStage(_activeStage);
          }
          _activeNativeClient = null;
          _activeNativeClientEvictor = null;
          if (existingEvictor != null) {
            await existingEvictor();
          }
          if (!existing.isDisposed) {
            await existing.dispose();
          }
          _liveNativeClientCount = 0;
        }
        final created = (factoryOverride ?? _defaultClientFactory)();
        _activeNativeClient = created;
        _activeNativeClientEvictor = onEvicted;
        _liveNativeClientCount = 1;
        final instanceId = attachNativeInstance(stage: stage, client: created);
        completer.complete((client: created, nativeInstanceId: instanceId));
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  /// 通过统一内核安全回收并注销指定的底层 `LibMpvClient` 句柄。
  Future<void> releaseNativeClient(LibMpvClient? client) {
    if (client == null) return Future<void>.value();
    final completer = Completer<void>();
    _clientLeaseChain = _clientLeaseChain.catchError((Object _) {}).then((_) async {
      try {
        if (identical(_activeNativeClient, client)) {
          _activeNativeClient = null;
          _activeNativeClientEvictor = null;
          _liveNativeClientCount = 0;
        }
        if (!client.isDisposed) {
          await client.dispose();
        }
        completer.complete();
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  /// 当前物理媒体代数。
  int get physicalMediaEpoch => _physicalMediaEpoch;

  /// 当前底层原生播放器实例编号。
  int get nativeInstanceId => _nativeInstanceId;

  /// 当前绑定的 mpv 播放列表项编号。
  int? get currentPlaylistEntryId => _currentPlaylistEntryId;

  /// 当前逻辑曲目代数（CUE 跨轨时单独递增）。
  int get logicalTrackEpoch => _logicalTrackEpoch;

  /// 当前音频输出路由代数（切换设备或重载音频后端时单独递增）。
  int get audioOutputEpoch => _audioOutputEpoch;

  /// 当前主流租约。
  PlaybackStreamLease? get mainStreamLease => _mainLease;

  /// 当前独立预取流租约。
  PlaybackStreamLease? get prefetchStreamLease => _prefetchLease;

  /// 当前是否已收到当前物理代数的 `FILE_LOADED` 事件。
  bool get fileLoadedInCurrentEpoch => _fileLoadedInCurrentEpoch;

  /// 当前物理代数是否已证实有效播放推进（首帧上屏或音频推进 >= 500ms）。
  bool get effectiveProgressConfirmed => _effectiveProgressConfirmed;

  /// 当前连续物理坏文件计数。
  int get consecutiveBadFiles => _consecutiveBadFiles;

  /// 当前是否已触发连续坏文件熔断。
  bool get isCircuitBreakerTripped =>
      _consecutiveBadFiles >= maxConsecutiveBadFiles;

  /// 登记重建底层原生播放器实例，返回新的实例编号；若正在切换不同舞台则自动保存原舞台暂挂快照。
  int attachNativeInstance({
    PlaybackStageKind stage = PlaybackStageKind.none,
    LibMpvClient? client,
  }) {
    if (_activeStage != PlaybackStageKind.none &&
        stage != PlaybackStageKind.none &&
        _activeStage != stage &&
        _nativeInstanceId > 0) {
      suspendStage(_activeStage);
    }
    _nativeInstanceId += 1;
    _currentPlaylistEntryId = null;
    if (stage != PlaybackStageKind.none) {
      _activeStage = stage;
      _suspendedSessions.remove(stage);
    }
    if (client != null) {
      _activeNativeClient = client;
    }
    return _nativeInstanceId;
  }

  /// 更新当前活跃舞台持有的底层 `LibMpvClient` 引用。
  void bindActiveNativeClient(
    LibMpvClient? client, {
    required PlaybackStageKind stage,
  }) {
    if (_activeStage == stage || _activeStage == PlaybackStageKind.none) {
      _activeStage = stage;
      _activeNativeClient = client;
    }
  }

  /// 将指定活跃舞台的物理实例、播放列表项与流租约快照暂挂（例如视频拉起时暂停背景音频）。
  void suspendStage(PlaybackStageKind stage) {
    if (stage == PlaybackStageKind.none ||
        _activeStage != stage ||
        _nativeInstanceId <= 0) {
      return;
    }
    _suspendedSessions[stage] = SuspendedPhysicalSession(
      stage: stage,
      nativeInstanceId: _nativeInstanceId,
      playlistEntryId: _currentPlaylistEntryId,
      mainStreamLeaseToken: _mainLease?.leaseToken,
      prefetchStreamLeaseToken: _prefetchLease?.leaseToken,
      fileLoaded: _fileLoadedInCurrentEpoch,
      effectiveProgressConfirmed: _effectiveProgressConfirmed,
    );
  }

  /// 原子恢复或重绑被其他舞台打断的物理会话，推进权威物理代数并恢复实例编号、播放列表项与流租约。
  int resumeOrRebindStage(
    PlaybackStageKind stage, {
    required int nativeInstanceId,
    LibMpvClient? client,
    int? fallbackPlaylistEntryId,
    String? fallbackMainStreamLeaseToken,
    String? fallbackPrefetchStreamLeaseToken,
  }) {
    if (_activeStage != PlaybackStageKind.none &&
        _activeStage != stage &&
        _nativeInstanceId > 0) {
      suspendStage(_activeStage);
    }
    final saved = _suspendedSessions.remove(stage);
    _activeStage = stage;
    if (client != null) {
      _activeNativeClient = client;
    }
    _nativeInstanceId = saved?.nativeInstanceId ?? nativeInstanceId;
    _physicalMediaEpoch += 1;
    _currentPlaylistEntryId = saved?.playlistEntryId ?? fallbackPlaylistEntryId;
    _fileLoadedInCurrentEpoch = saved?.fileLoaded ?? true;
    _effectiveProgressConfirmed = saved?.effectiveProgressConfirmed ?? false;

    final mainToken =
        saved?.mainStreamLeaseToken ?? fallbackMainStreamLeaseToken;
    _mainLease = mainToken == null
        ? null
        : PlaybackStreamLease(
            leaseToken: mainToken,
            kind: PlaybackStreamLeaseKind.main,
            physicalMediaEpoch: _physicalMediaEpoch,
            nativeInstanceId: _nativeInstanceId,
            playlistEntryId: _currentPlaylistEntryId,
          );

    final prefetchToken =
        saved?.prefetchStreamLeaseToken ?? fallbackPrefetchStreamLeaseToken;
    _prefetchLease = prefetchToken == null
        ? null
        : PlaybackStreamLease(
            leaseToken: prefetchToken,
            kind: PlaybackStreamLeaseKind.prefetch,
            physicalMediaEpoch: _physicalMediaEpoch,
            nativeInstanceId: _nativeInstanceId,
            playlistEntryId: null,
          );
    return _physicalMediaEpoch;
  }

  /// 开启新的物理媒体装载周期，递增物理与逻辑代数并重置本周期有效进展标记。
  ///
  /// 若 [preservePrefetchLease] 为真，则保留独立预取租约待无缝晋升。
  int beginPhysicalMedia({
    int? nativeInstanceId,
    PlaybackStageKind? stage,
    bool preservePrefetchLease = false,
  }) {
    if (stage != null &&
        stage != PlaybackStageKind.none &&
        _activeStage != PlaybackStageKind.none &&
        _activeStage != stage &&
        _nativeInstanceId > 0) {
      suspendStage(_activeStage);
    }
    if (stage != null && stage != PlaybackStageKind.none) {
      _activeStage = stage;
      _suspendedSessions.remove(stage);
    }
    if (nativeInstanceId != null && nativeInstanceId > 0) {
      _nativeInstanceId = nativeInstanceId;
    }
    _physicalMediaEpoch += 1;
    _logicalTrackEpoch += 1;
    _currentPlaylistEntryId = null;
    _fileLoadedInCurrentEpoch = false;
    _effectiveProgressConfirmed = false;
    _mainLease = null;
    if (!preservePrefetchLease) {
      _prefetchLease = null;
    }
    for (final domain in PlaybackTaskDomain.values) {
      _domainGenerations[domain] = (_domainGenerations[domain] ?? 0) + 1;
    }
    return _physicalMediaEpoch;
  }

  /// 绑定当前物理媒体对应的 mpv `playlist_entry_id`。
  void bindPlaylistEntryId(int entryId) {
    _currentPlaylistEntryId = entryId;
    final lease = _mainLease;
    if (lease != null) {
      _mainLease = PlaybackStreamLease(
        leaseToken: lease.leaseToken,
        kind: lease.kind,
        physicalMediaEpoch: lease.physicalMediaEpoch,
        nativeInstanceId: lease.nativeInstanceId,
        playlistEntryId: entryId,
      );
    }
  }

  /// CUE 同母文件跨 `INDEX 01` 切换逻辑曲目：仅递增逻辑曲目代数与歌词任务域，
  /// 保持 `physicalMediaEpoch` 与主流租约持续存活不断流。
  int advanceLogicalTrack({bool resetLyricsDomain = true}) {
    _logicalTrackEpoch += 1;
    if (resetLyricsDomain) {
      cancelTaskDomain(PlaybackTaskDomain.lyricLookup);
    }
    return _logicalTrackEpoch;
  }

  /// 切换音频输出设备或触发 `ao-reload`：仅递增音频路由代数，
  /// 严禁触碰物理媒体代数或中断底层正在读取的网桥媒体流。
  int advanceAudioOutputRoute() {
    _audioOutputEpoch += 1;
    return _audioOutputEpoch;
  }

  /// 绑定当前物理主流的网桥租约，返回被替换的旧主流令牌供调用方按需回收。
  String? bindMainStreamLease(String leaseToken) {
    final previous = _mainLease?.leaseToken;
    _mainLease = PlaybackStreamLease(
      leaseToken: leaseToken,
      kind: PlaybackStreamLeaseKind.main,
      physicalMediaEpoch: _physicalMediaEpoch,
      nativeInstanceId: _nativeInstanceId,
      playlistEntryId: _currentPlaylistEntryId,
    );
    return previous == leaseToken ? null : previous;
  }

  /// 绑定下一项无缝预取的独立网桥租约（绝不覆盖当前主流租约）。
  String? bindPrefetchStreamLease(
    String leaseToken, {
    int? playlistEntryId,
  }) {
    final previous = _prefetchLease?.leaseToken;
    _prefetchLease = PlaybackStreamLease(
      leaseToken: leaseToken,
      kind: PlaybackStreamLeaseKind.prefetch,
      physicalMediaEpoch: _physicalMediaEpoch,
      nativeInstanceId: _nativeInstanceId,
      playlistEntryId: playlistEntryId,
    );
    return previous == leaseToken ? null : previous;
  }

  /// 当预取队列项无缝晋升为当前播放项时，将预取租约原子切换为主流租约。
  ///
  /// 返回需回收的旧主流令牌（若无则返回 `null`）。
  String? promotePrefetchLeaseToMain({int? playlistEntryId}) {
    final oldMain = _mainLease?.leaseToken;
    final promoted = _prefetchLease;
    _physicalMediaEpoch += 1;
    _logicalTrackEpoch += 1;
    _currentPlaylistEntryId = playlistEntryId ?? promoted?.playlistEntryId;
    _fileLoadedInCurrentEpoch = false;
    _effectiveProgressConfirmed = false;
    _prefetchLease = null;
    if (promoted != null) {
      _mainLease = PlaybackStreamLease(
        leaseToken: promoted.leaseToken,
        kind: PlaybackStreamLeaseKind.main,
        physicalMediaEpoch: _physicalMediaEpoch,
        nativeInstanceId: _nativeInstanceId,
        playlistEntryId: _currentPlaylistEntryId,
      );
    } else {
      _mainLease = null;
    }
    return oldMain == _mainLease?.leaseToken ? null : oldMain;
  }

  /// 显式释放预取流租约而不影响正在播放的主流。
  String? releasePrefetchLease() {
    final token = _prefetchLease?.leaseToken;
    _prefetchLease = null;
    return token;
  }

  /// 校验底层异步事件是否归属于当前活跃物理媒体代数、实例与播放列表项。
  bool matchesPhysicalEvent({
    required int physicalMediaEpoch,
    int? nativeInstanceId,
    int? playlistEntryId,
  }) {
    if (physicalMediaEpoch != _physicalMediaEpoch) return false;
    if (nativeInstanceId != null && nativeInstanceId != _nativeInstanceId) {
      return false;
    }
    if (playlistEntryId != null &&
        _currentPlaylistEntryId != null &&
        playlistEntryId != _currentPlaylistEntryId) {
      return false;
    }
    return true;
  }

  /// 申请指定隔离域的任务令牌（自动递增该域代数，不影响其余三个域）。
  ScopedTaskToken acquireTaskToken(PlaybackTaskDomain domain) {
    final nextGen = (_domainGenerations[domain] ?? 0) + 1;
    _domainGenerations[domain] = nextGen;
    return ScopedTaskToken(
      domain: domain,
      domainGeneration: nextGen,
      physicalMediaEpoch: _physicalMediaEpoch,
      logicalTrackEpoch: _logicalTrackEpoch,
    );
  }

  /// 仅取消指定域内全部在途任务，其余域的任务令牌保持存活。
  void cancelTaskDomain(PlaybackTaskDomain domain) {
    _domainGenerations[domain] = (_domainGenerations[domain] ?? 0) + 1;
  }

  /// 校验指定域任务令牌是否仍有效。
  bool isTaskAlive(ScopedTaskToken token) {
    if (token.physicalMediaEpoch != _physicalMediaEpoch) return false;
    if (token.domain == PlaybackTaskDomain.lyricLookup &&
        token.logicalTrackEpoch != _logicalTrackEpoch) {
      return false;
    }
    return _domainGenerations[token.domain] == token.domainGeneration;
  }

  /// 记录收到 `FILE_LOADED` 事件：严禁在此处提前清零连续坏文件计数。
  void recordFileLoaded() {
    _fileLoadedInCurrentEpoch = true;
  }

  /// 记录用户显式手动点选曲目或分集：允许清零连续坏文件熔断计数。
  void recordManualSelection() {
    _consecutiveBadFiles = 0;
  }

  /// 记录已证实的有效播放进展：仅当首帧上屏或音频实际推进满 500 ms 时清零坏文件计数。
  bool recordEffectiveProgress({
    bool firstFrameRendered = false,
    int audioAdvancedMs = 0,
  }) {
    if (!firstFrameRendered &&
        audioAdvancedMs < effectiveAudioProgressThresholdMs) {
      return false;
    }
    _effectiveProgressConfirmed = true;
    _consecutiveBadFiles = 0;
    return true;
  }

  /// 记录一次物理媒体坏文件错误；达到连续 3 次时返回 `true` 触发熔断停播。
  bool recordPhysicalMediaFailure() {
    _consecutiveBadFiles += 1;
    return isCircuitBreakerTripped;
  }

  /// 关闭当前播放会话并递增全部代数，返回需清理的主流与预取流令牌列表。
  ///
  /// 传入 [stage] 时仅清理该舞台持有的租约，绝不误清其余已暂挂舞台的快照与流租约。
  List<String> resetSession({PlaybackStageKind? stage}) {
    final tokens = <String>{};
    if (stage != null) {
      final suspended = _suspendedSessions.remove(stage);
      if (suspended != null) {
        if (suspended.mainStreamLeaseToken != null) {
          tokens.add(suspended.mainStreamLeaseToken!);
        }
        if (suspended.prefetchStreamLeaseToken != null) {
          tokens.add(suspended.prefetchStreamLeaseToken!);
        }
      }
      if (_activeStage != PlaybackStageKind.none && _activeStage != stage) {
        return tokens.toList(growable: false);
      }
    } else {
      for (final suspended in _suspendedSessions.values) {
        if (suspended.mainStreamLeaseToken != null) {
          tokens.add(suspended.mainStreamLeaseToken!);
        }
        if (suspended.prefetchStreamLeaseToken != null) {
          tokens.add(suspended.prefetchStreamLeaseToken!);
        }
      }
      _suspendedSessions.clear();
    }

    if (_mainLease != null) tokens.add(_mainLease!.leaseToken);
    if (_prefetchLease != null) {
      tokens.add(_prefetchLease!.leaseToken);
    }
    _mainLease = null;
    _prefetchLease = null;
    _activeStage = PlaybackStageKind.none;
    _activeNativeClient = null;
    _physicalMediaEpoch += 1;
    _logicalTrackEpoch += 1;
    _currentPlaylistEntryId = null;
    _fileLoadedInCurrentEpoch = false;
    _effectiveProgressConfirmed = false;
    for (final domain in PlaybackTaskDomain.values) {
      _domainGenerations[domain] = (_domainGenerations[domain] ?? 0) + 1;
    }
    return tokens.toList(growable: false);
  }
}

/// 全局唯一音视频播放协调内核 Provider（全端共享四维代数与熔断状态）。
final unifiedPlaybackEngineProvider = Provider<UnifiedPlaybackEngine>((ref) {
  return UnifiedPlaybackEngine();
});
