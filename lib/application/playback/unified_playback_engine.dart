import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  /// 队列连续物理坏文件触发熔断的上限阈值。
  static const int maxConsecutiveBadFiles = 3;

  /// 认定音频已证实有效播放推进的最小时长阈值（毫秒）。
  static const int effectiveAudioProgressThresholdMs = 500;

  int _physicalMediaEpoch = 0;
  int _nativeInstanceId = 0;
  int? _currentPlaylistEntryId;
  int _logicalTrackEpoch = 0;
  int _audioOutputEpoch = 0;

  final Map<PlaybackTaskDomain, int> _domainGenerations = {
    for (final domain in PlaybackTaskDomain.values) domain: 0,
  };

  PlaybackStreamLease? _mainLease;
  PlaybackStreamLease? _prefetchLease;

  bool _fileLoadedInCurrentEpoch = false;
  bool _effectiveProgressConfirmed = false;
  int _consecutiveBadFiles = 0;

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

  /// 登记重建底层原生播放器实例，返回新的实例编号。
  int attachNativeInstance() {
    _nativeInstanceId += 1;
    _currentPlaylistEntryId = null;
    return _nativeInstanceId;
  }

  /// 开启新的物理媒体装载周期，递增物理与逻辑代数并重置本周期有效进展标记。
  ///
  /// 若 [preservePrefetchLease] 为真，则保留独立预取租约待无缝晋升。
  int beginPhysicalMedia({
    int? nativeInstanceId,
    bool preservePrefetchLease = false,
  }) {
    if (nativeInstanceId != null && nativeInstanceId > _nativeInstanceId) {
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
  List<String> resetSession() {
    final tokens = <String>[];
    if (_mainLease != null) tokens.add(_mainLease!.leaseToken);
    if (_prefetchLease != null &&
        _prefetchLease!.leaseToken != _mainLease?.leaseToken) {
      tokens.add(_prefetchLease!.leaseToken);
    }
    _mainLease = null;
    _prefetchLease = null;
    _physicalMediaEpoch += 1;
    _logicalTrackEpoch += 1;
    _currentPlaylistEntryId = null;
    _fileLoadedInCurrentEpoch = false;
    _effectiveProgressConfirmed = false;
    for (final domain in PlaybackTaskDomain.values) {
      _domainGenerations[domain] = (_domainGenerations[domain] ?? 0) + 1;
    }
    return tokens;
  }
}

/// 全局唯一音视频播放协调内核 Provider（全端共享四维代数与熔断状态）。
final unifiedPlaybackEngineProvider = Provider<UnifiedPlaybackEngine>((ref) {
  return UnifiedPlaybackEngine();
});
