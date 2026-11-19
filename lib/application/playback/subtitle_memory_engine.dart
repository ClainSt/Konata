import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../domain/playback/subtitle_content_processor.dart';
import '../../domain/playback/subtitle_timeline_remapper.dart';
import '../../domain/playback/track_preferences.dart';
import '../../domain/text/multibyte_text_decoder.dart';
import '../../infrastructure/players/libmpv_ffi.dart';
import 'unified_playback_engine.dart';

/// 单个字幕槽位（主字幕或副字幕）的权威挂载目标描述。
class SubtitleSlotRequest {
  /// 创建基于现有底层轨道编号的字幕槽位请求（无需内存直注）。
  const SubtitleSlotRequest.existingTrack(
    int trackId, {
    this.displayTitle,
  }) : existingTrackId = trackId,
       localFilePath = null,
       loadBytes = null,
       fileName = null,
       openCcMode = SubtitleOpenCcMode.none,
       forceOverrideSubsetGuard = false,
       timelineTransform = SubtitleTimelineTransform.identity,
       enableCloudSubset = false;

  /// 创建基于本地文件或异步原始字节加载器的内存直注字幕槽位请求。
  const SubtitleSlotRequest.memory({
    this.localFilePath,
    this.loadBytes,
    this.fileName,
    this.displayTitle,
    this.openCcMode = SubtitleOpenCcMode.none,
    this.forceOverrideSubsetGuard = false,
    this.timelineTransform = SubtitleTimelineTransform.identity,
    this.enableCloudSubset = false,
  }) : existingTrackId = null;

  /// 已挂载在 `libmpv` 中的轨道 ID（若设置则直接选轨，不重复注入）。
  final int? existingTrackId;

  /// 本地原始字幕文件路径（与 [loadBytes] 二选一）。
  final String? localFilePath;

  /// 异步原始字幕字节加载器（便于远程流加载与并发确定性测试）。
  final Future<Uint8List> Function()? loadBytes;

  /// 原始文件名（用于辅助判定 ASS / SRT / VTT 格式）。
  final String? fileName;

  /// 注入 `libmpv` `track-list` 时显示的轨道标题。
  final String? displayTitle;

  /// 目标 OpenCC 繁简转换模式。
  final SubtitleOpenCcMode openCcMode;

  /// 是否强制绕过不透明混淆子集保护（自动模式默认严格为 `false`）。
  final bool forceOverrideSubsetGuard;

  /// 离线分段线性时间轴重映射参数（非恒等变换时自动同步归零 `sub-delay`）。
  final SubtitleTimelineTransform timelineTransform;

  /// 是否允许在启用且已授权时对 ASS/SSA 字幕触发可选云端字体子集化。
  final bool enableCloudSubset;

  /// 是否包含非恒等时间轴离线重映射。
  bool get hasTimelineRemap => !timelineTransform.isIdentity;
}

/// 经单一串行通道执行的权威字幕意图。
class AuthoritativeSubtitleIntent {
  /// 创建权威字幕意图。
  const AuthoritativeSubtitleIntent({
    this.primary,
    this.secondary,
    this.updateSecondary = false,
    this.instantSubDelaySeconds,
  });

  /// 关闭主字幕意图（若 [alsoDisableSecondary] 为真则同时关闭副字幕）。
  const AuthoritativeSubtitleIntent.disable({bool alsoDisableSecondary = false})
    : primary = null,
      secondary = null,
      updateSecondary = alsoDisableSecondary,
      instantSubDelaySeconds = null;

  /// 主字幕槽位目标；为 `null` 时设置 `sid = no`。
  final SubtitleSlotRequest? primary;

  /// 副字幕槽位目标；当 [updateSecondary] 为真且本字段为 `null` 时设置 `secondary-sid = no`。
  final SubtitleSlotRequest? secondary;

  /// 是否在本次原子提交中同步写入 `secondary-sid`。
  final bool updateSecondary;

  /// 可选同步写入的瞬时 `sub-delay`（秒）；若本次挂载了离线重映射轨则自动强制归零 `0.0`。
  final double? instantSubDelaySeconds;
}

/// 内存直注字幕引擎单次意图执行结果。
class SubtitleMemoryApplyResult {
  /// 创建执行结果快照。
  const SubtitleMemoryApplyResult({
    required this.applied,
    required this.staleAborted,
    this.primaryTrackId,
    this.secondaryTrackId,
    this.primaryContentSha1,
    this.primaryDecodedCharset,
    this.primarySubsetState,
    this.primaryOpenCcSkipReason,
    this.usedCachedMemoryTrack = false,
    this.zeroedInstantSubDelay = false,
    this.cloudSubsetApplied = false,
    this.elapsedMicros = 0,
  });

  /// 意图是否成功原子提交至 `libmpv`。
  final bool applied;

  /// 是否因中途被更新意图、切集或关播取代而主动静默中止（0 写回）。
  final bool staleAborted;

  /// 最终生效的主字幕轨道 ID（关闭时为 `null`）。
  final int? primaryTrackId;

  /// 最终生效的副字幕轨道 ID（未启用或未修改时为 `null`）。
  final int? secondaryTrackId;

  /// 本次主字幕处理后文本的 SHA-1 摘要。
  final String? primaryContentSha1;

  /// 本次主字幕探测到的原始字符集。
  final DetectedTextCharset? primaryDecodedCharset;

  /// 本次主字幕探测到的三态子集分类。
  final SubtitleSubsetState? primarySubsetState;

  /// 若自动模式下因三态子集保护跳过 OpenCC，则记录跳过原因。
  final String? primaryOpenCcSkipReason;

  /// 本次是否直接命中已注入内存轨去重复用（0 次重复 `sub-add`）。
  final bool usedCachedMemoryTrack;

  /// 本次挂载重映射轨时是否同步归零了瞬时 `sub-delay`。
  final bool zeroedInstantSubDelay;

  /// 本次是否成功应用了经语义校验的云端字体子集化正文。
  final bool cloudSubsetApplied;

  /// 端到端处理与内存挂载耗时（微秒）。
  final int elapsedMicros;
}

class _PreparedMemorySlot {
  const _PreparedMemorySlot({
    this.existingTrackId,
    this.sourceFilePath,
    this.processedContent,
    this.contentSha1,
    this.decodedCharset,
    this.subsetState,
    this.openCcSkipReason,
    this.displayTitle,
    this.hasTimelineRemap = false,
    this.cloudSubsetApplied = false,
  });

  final int? existingTrackId;
  final String? sourceFilePath;
  final String? processedContent;
  final String? contentSha1;
  final DetectedTextCharset? decodedCharset;
  final SubtitleSubsetState? subsetState;
  final String? openCcSkipReason;
  final String? displayTitle;
  final bool hasTimelineRemap;
  final bool cloudSubsetApplied;
}

/// 内存级无副作用字幕引擎（`memory://` 零落盘直注 + 单一串行权威意图通道）。
///
/// 核心并发与无副作用不变量：
/// 1. 使用全仓唯一 `MultibyteTextDecoder` 在内存统一归一为 UTF-8，绝不修改 `libmpv` 全局 `sub-codepage`；
/// 2. 统一通过 `sub-add memory://<content> cached <title>` 静默入轨并由权威通道显式绑定 `sid`/`secondary-sid`，
///    彻底杜绝 `sub-auto=fuzzy` 下的自动抢选轨副作用，并按内容 SHA-1 去重复用，全过程零临时磁盘文件；
/// 3. 起播自动外挂字幕、侧栏选轨、手动加字幕、OpenCC、云端子集化与离线调轴共享单调递增意图代数与单一串行提交通道；
///    任一异步边界后若意图过时或物理媒体代数已推进，立即中止并保证对 `libmpv` **0 写回**。
class SubtitleMemoryEngine {
  /// 创建内存级字幕引擎实例。
  SubtitleMemoryEngine({
    required this.clientSupplier,
    UnifiedPlaybackEngine? playbackEngine,
    this.legacyCodePageDecoder,
    this.cloudSubsetTransform,
    this.onAssContentPrepared,
    this.onTrackStateChanged,
  }) : _playbackEngine = playbackEngine,
       _activePhysicalEpoch = playbackEngine?.physicalMediaEpoch ?? 0;

  /// 提供当前活跃 `libmpv` 客户端的只读回调。
  final LibMpvClient? Function() clientSupplier;
  final UnifiedPlaybackEngine? _playbackEngine;

  /// 可选平台代码页桥接（Windows 组装根注入 `WindowsCodePageDecoder.decode`）。
  final LegacyCodePageDecoder? legacyCodePageDecoder;

  /// 可选云端 ASS 字体子集化处理回调（由上层串联 `CloudSubsetCoordinator.runCloudSubset`）。
  final Future<String?> Function(String originalAssContent)?
  cloudSubsetTransform;

  /// ASS 正文解码或云端子集化就绪后的回调（用于提取 `[Fonts]` UUE 字体入池并刷新 `sub-fonts-dir`）。
  final Future<void> Function(String assContent)? onAssContentPrepared;

  /// 选轨或延迟原子提交完成后触发的通知回调（供会话刷新 UI 轨道快照）。
  final void Function()? onTrackStateChanged;

  int _latestIntentVersion = 0;
  int _activePhysicalEpoch;
  bool _disposed = false;
  Future<void> _serialCommitChain = Future<void>.value();

  /// 当前物理媒体周期内已通过 `memory://` 静默挂载的轨道去重映射（`contentSha1 -> trackId`）。
  final Map<String, int> _mountedMemoryTracksBySha1 = {};

  /// 当前物理媒体周期内已挂载的外部字幕源路径与底层 `trackId` 的映射表（便于原轨复用与反查源路径）。
  final Map<String, int> _mountedTrackIdBySourcePath = {};
  final Map<int, String> _sourcePathByMountedTrackId = {};

  /// 当前最新权威意图版本（用于诊断与测试）。
  int get latestIntentVersion => _latestIntentVersion;

  /// 当前已挂载去重的内存轨道数量。
  int get mountedMemoryTrackCount => _mountedMemoryTracksBySha1.length;

  /// 根据已挂载的 `memory://` 轨道 ID 反查原始外挂字幕文件路径（供 OpenCC / 调轴 / 云端子集回溯）。
  String? lookupSourcePathForTrackId(int trackId) =>
      _sourcePathByMountedTrackId[trackId];

  /// 根据原始外挂字幕文件路径查询当前物理周期已挂载的轨道 ID。
  int? lookupTrackIdForSourcePath(String filePath) =>
      _mountedTrackIdBySourcePath[_normalizePathKey(filePath)];

  /// 推进意图代数，令一切尚未提交的在途异步字幕加载/转换任务立即失效（0 写回）。
  int invalidatePendingIntents() {
    _latestIntentVersion += 1;
    _playbackEngine?.cancelTaskDomain(PlaybackTaskDomain.rawSubtitleFetch);
    return _latestIntentVersion;
  }

  /// 在物理媒体切换（换集/重播）时重置内存轨去重表并取消上一集全部在途任务。
  void resetForPhysicalMediaEpoch([int? nextEpoch]) {
    _activePhysicalEpoch =
        nextEpoch ??
        (_playbackEngine?.physicalMediaEpoch ?? (_activePhysicalEpoch + 1));
    _latestIntentVersion += 1;
    _mountedMemoryTracksBySha1.clear();
    _mountedTrackIdBySourcePath.clear();
    _sourcePathByMountedTrackId.clear();
  }

  /// 同步更新瞬时 `sub-delay` 并同步推进权威意图代数，防止在途异步选轨覆盖新延迟。
  void setInstantSubtitleDelay(double seconds) {
    if (_disposed) return;
    invalidatePendingIntents();
    final client = _activeUsableClient();
    if (client == null) return;
    _writeSubDelay(client, seconds);
    onTrackStateChanged?.call();
  }

  /// 经单一串行权威通道静默批量挂载起播发现的外挂文本字幕（`cached`），并按偏好原子选轨。
  Future<SubtitleMemoryApplyResult> mountDiscoveredExternalSubtitles({
    required List<String> textSubtitlePaths,
    required CrossEpisodeTrackMemory trackMemory,
    required TrackPreferences trackPreferences,
    bool enableCloudSubsetForSelected = false,
  }) async {
    final stopwatch = Stopwatch()..start();
    if (_disposed) {
      return SubtitleMemoryApplyResult(
        applied: false,
        staleAborted: true,
        elapsedMicros: stopwatch.elapsedMicroseconds,
      );
    }

    final targetVersion = ++_latestIntentVersion;
    final targetEpoch = _currentPhysicalEpoch();
    final taskToken = _playbackEngine?.acquireTaskToken(
      PlaybackTaskDomain.rawSubtitleFetch,
    );

    bool isStillCurrent() {
      if (_disposed) return false;
      if (targetVersion != _latestIntentVersion) return false;
      if (targetEpoch != _currentPhysicalEpoch()) return false;
      if (taskToken != null &&
          !(_playbackEngine?.isTaskAlive(taskToken) ?? false)) {
        return false;
      }
      return true;
    }

    // 1. 异步解码所有外挂文本字幕至 UTF-8（彻底杜绝 GBK/Big5/Shift-JIS 裸路径直传乱码）。
    final preparedSlots = <_PreparedMemorySlot>[];
    for (final rawPath in textSubtitlePaths) {
      if (!isStillCurrent()) {
        return SubtitleMemoryApplyResult(
          applied: false,
          staleAborted: true,
          elapsedMicros: stopwatch.elapsedMicroseconds,
        );
      }
      final trimmed = rawPath.trim();
      if (trimmed.isEmpty) continue;
      try {
        final slot = await _prepareSlot(
          SubtitleSlotRequest.memory(
            localFilePath: trimmed,
            fileName: p.basename(trimmed),
            displayTitle: p.basename(trimmed),
            enableCloudSubset: enableCloudSubsetForSelected,
          ),
        );
        preparedSlots.add(slot);
      } on Object {
        // 单个外挂字幕读取失败不影响其余可用字幕挂载。
      }
    }

    if (!isStillCurrent()) {
      return SubtitleMemoryApplyResult(
        applied: false,
        staleAborted: true,
        elapsedMicros: stopwatch.elapsedMicroseconds,
      );
    }

    // 2. 入串行权威提交锁：静默 `cached` 挂载全部文本轨并显式解析写入最终 `sid`。
    final completer = Completer<SubtitleMemoryApplyResult>();
    final op = _serialCommitChain.then((_) {
      if (!isStillCurrent()) {
        completer.complete(
          SubtitleMemoryApplyResult(
            applied: false,
            staleAborted: true,
            elapsedMicros: stopwatch.elapsedMicroseconds,
          ),
        );
        return;
      }
      final client = _activeUsableClient();
      if (client == null) {
        completer.complete(
          SubtitleMemoryApplyResult(
            applied: false,
            staleAborted: true,
            elapsedMicros: stopwatch.elapsedMicroseconds,
          ),
        );
        return;
      }

      for (final slot in preparedSlots) {
        _ensureMountedTrack(client, slot);
      }

      if (!isStillCurrent()) {
        completer.complete(
          SubtitleMemoryApplyResult(
            applied: false,
            staleAborted: true,
            elapsedMicros: stopwatch.elapsedMicroseconds,
          ),
        );
        return;
      }

      int? selectedTrackId;
      if (trackMemory.subtitleDisabled) {
        client.setPropertyString('sid', 'no');
      } else {
        final refreshed = client.readTrackList();
        final chosenSub = trackMemory.resolveSubtitleTrack(
          refreshed,
          fallback: trackPreferences,
        );
        if (chosenSub != null) {
          selectedTrackId = chosenSub.id;
          if (!chosenSub.selected) {
            final rc = client.setPropertyInt64('sid', chosenSub.id);
            if (rc < 0) {
              client.setPropertyString('sid', '${chosenSub.id}');
            }
          }
        }
      }

      onTrackStateChanged?.call();
      stopwatch.stop();
      completer.complete(
        SubtitleMemoryApplyResult(
          applied: true,
          staleAborted: false,
          primaryTrackId: selectedTrackId,
          elapsedMicros: stopwatch.elapsedMicroseconds,
        ),
      );
    });
    _serialCommitChain = op.catchError((Object _, StackTrace _) {});
    return completer.future;
  }

  /// 通过单一串行权威通道提交字幕意图（支持主/副双槽、`memory://` 直注与离线调轴）。
  Future<SubtitleMemoryApplyResult> applyIntent(
    AuthoritativeSubtitleIntent intent,
  ) async {
    final stopwatch = Stopwatch()..start();
    if (_disposed) {
      return SubtitleMemoryApplyResult(
        applied: false,
        staleAborted: true,
        elapsedMicros: stopwatch.elapsedMicroseconds,
      );
    }

    final targetVersion = ++_latestIntentVersion;
    final targetEpoch = _currentPhysicalEpoch();
    final taskToken = _playbackEngine?.acquireTaskToken(
      PlaybackTaskDomain.rawSubtitleFetch,
    );

    bool isStillCurrent() {
      if (_disposed) return false;
      if (targetVersion != _latestIntentVersion) return false;
      if (targetEpoch != _currentPhysicalEpoch()) return false;
      if (taskToken != null &&
          !(_playbackEngine?.isTaskAlive(taskToken) ?? false)) {
        return false;
      }
      return true;
    }

    // 1. 异步阶段在串行提交锁外并发准备字节解码、云端子集化、OpenCC 片段转换与离线调轴，避免阻塞较新意图抢占代数。
    _PreparedMemorySlot? preparedPrimary;
    _PreparedMemorySlot? preparedSecondary;
    try {
      if (intent.primary != null) {
        preparedPrimary = await _prepareSlot(intent.primary!);
      }
      if (!isStillCurrent()) {
        return SubtitleMemoryApplyResult(
          applied: false,
          staleAborted: true,
          elapsedMicros: stopwatch.elapsedMicroseconds,
        );
      }
      if (intent.updateSecondary && intent.secondary != null) {
        preparedSecondary = await _prepareSlot(intent.secondary!);
      }
      if (!isStillCurrent()) {
        return SubtitleMemoryApplyResult(
          applied: false,
          staleAborted: true,
          elapsedMicros: stopwatch.elapsedMicroseconds,
        );
      }
    } on Object {
      return SubtitleMemoryApplyResult(
        applied: false,
        staleAborted: !isStillCurrent(),
        elapsedMicros: stopwatch.elapsedMicroseconds,
      );
    }

    // 2. 串行原子提交安全空窗：入队后再次校验意图版本与物理代数，过时任务直接 0 写回退出。
    final completer = Completer<SubtitleMemoryApplyResult>();
    final op = _serialCommitChain.then((_) {
      if (!isStillCurrent()) {
        completer.complete(
          SubtitleMemoryApplyResult(
            applied: false,
            staleAborted: true,
            elapsedMicros: stopwatch.elapsedMicroseconds,
          ),
        );
        return;
      }
      final client = _activeUsableClient();
      if (client == null) {
        completer.complete(
          SubtitleMemoryApplyResult(
            applied: false,
            staleAborted: true,
            elapsedMicros: stopwatch.elapsedMicroseconds,
          ),
        );
        return;
      }

      var usedCached = false;
      int? primaryTrackId;
      int? secondaryTrackId;

      if (preparedPrimary != null) {
        final mount = _ensureMountedTrack(client, preparedPrimary);
        if (mount == null) {
          completer.complete(
            SubtitleMemoryApplyResult(
              applied: false,
              staleAborted: false,
              elapsedMicros: stopwatch.elapsedMicroseconds,
            ),
          );
          return;
        }
        primaryTrackId = mount.trackId;
        usedCached = mount.reused;
      }

      if (intent.updateSecondary && preparedSecondary != null) {
        final mount = _ensureMountedTrack(client, preparedSecondary);
        if (mount != null) {
          secondaryTrackId = mount.trackId;
        }
      }

      // 再次核验安全空窗后执行原子选轨与延迟同步归零。
      if (!isStillCurrent()) {
        completer.complete(
          SubtitleMemoryApplyResult(
            applied: false,
            staleAborted: true,
            elapsedMicros: stopwatch.elapsedMicroseconds,
          ),
        );
        return;
      }

      final hasRemappedTrack =
          (preparedPrimary?.hasTimelineRemap ?? false) ||
          (preparedSecondary?.hasTimelineRemap ?? false);
      var zeroedDelay = false;
      if (hasRemappedTrack) {
        _writeSubDelay(client, 0.0, refreshIfPaused: false);
        zeroedDelay = true;
      } else if (intent.instantSubDelaySeconds != null) {
        _writeSubDelay(
          client,
          intent.instantSubDelaySeconds!,
          refreshIfPaused: false,
        );
      }

      if (primaryTrackId == null) {
        client.setPropertyString('sid', 'no');
      } else {
        final rc = client.setPropertyInt64('sid', primaryTrackId);
        if (rc < 0) {
          client.setPropertyString('sid', '$primaryTrackId');
        }
      }

      if (intent.updateSecondary) {
        if (secondaryTrackId == null) {
          client.setPropertyString('secondary-sid', 'no');
        } else {
          final rc = client.setPropertyInt64('secondary-sid', secondaryTrackId);
          if (rc < 0) {
            client.setPropertyString('secondary-sid', '$secondaryTrackId');
          }
        }
      }

      if (hasRemappedTrack && (client.getPropertyFlag('pause') ?? false)) {
        client.command(['seek', '0', 'relative', 'exact']);
      }

      onTrackStateChanged?.call();
      stopwatch.stop();
      completer.complete(
        SubtitleMemoryApplyResult(
          applied: true,
          staleAborted: false,
          primaryTrackId: primaryTrackId,
          secondaryTrackId: secondaryTrackId,
          primaryContentSha1: preparedPrimary?.contentSha1,
          primaryDecodedCharset: preparedPrimary?.decodedCharset,
          primarySubsetState: preparedPrimary?.subsetState,
          primaryOpenCcSkipReason: preparedPrimary?.openCcSkipReason,
          usedCachedMemoryTrack: usedCached,
          zeroedInstantSubDelay: zeroedDelay,
          cloudSubsetApplied: preparedPrimary?.cloudSubsetApplied ?? false,
          elapsedMicros: stopwatch.elapsedMicroseconds,
        ),
      );
    });
    _serialCommitChain = op.catchError((Object _, StackTrace _) {});
    return completer.future;
  }

  /// 释放字幕引擎并作废所有尚未完成的在途意图。
  void dispose() {
    _disposed = true;
    _latestIntentVersion += 1;
    _mountedMemoryTracksBySha1.clear();
    _mountedTrackIdBySourcePath.clear();
    _sourcePathByMountedTrackId.clear();
  }

  int _currentPhysicalEpoch() {
    return _playbackEngine?.physicalMediaEpoch ?? _activePhysicalEpoch;
  }

  LibMpvClient? _activeUsableClient() {
    final client = clientSupplier();
    if (_disposed ||
        client == null ||
        client.isDisposed ||
        !client.isInitialized) {
      return null;
    }
    return client;
  }

  static String _normalizePathKey(String rawPath) =>
      rawPath.trim().replaceAll('\\', '/').toLowerCase();

  Future<_PreparedMemorySlot> _prepareSlot(SubtitleSlotRequest request) async {
    if (request.existingTrackId != null) {
      return _PreparedMemorySlot(
        existingTrackId: request.existingTrackId,
        displayTitle: request.displayTitle,
      );
    }

    Uint8List rawBytes;
    final trimmedLocalPath = request.localFilePath?.trim();
    if (request.loadBytes != null) {
      rawBytes = await request.loadBytes!();
    } else if (trimmedLocalPath != null && trimmedLocalPath.isNotEmpty) {
      rawBytes = await File(trimmedLocalPath).readAsBytes();
    } else {
      throw StateError('字幕槽位既未指定轨道 ID，也未提供字节加载源');
    }

    final decoded = MultibyteTextDecoder.decodeWithInfo(
      rawBytes,
      legacyDecoder: legacyCodePageDecoder,
    );
    var workingText = decoded.text;
    var cloudApplied = false;

    final detectedFormat = SubtitleTimelineRemapper.detectFormat(
      workingText,
      fileName: request.fileName ?? trimmedLocalPath,
    );

    // 若启用云端子集化且目标源已授权，仅对未含 [Fonts] 的 ASS/SSA 正文发起按域云端子集化。
    if (request.enableCloudSubset &&
        detectedFormat == SubtitleTextFormat.ass &&
        cloudSubsetTransform != null) {
      final subsetted = await cloudSubsetTransform!(workingText);
      if (subsetted != null && subsetted.isNotEmpty) {
        workingText = subsetted;
        cloudApplied = true;
      }
    }

    // 检测到 ASS 内嵌 `[Fonts]` UUE 块时，自动提取校验并入单级哈希池刷新 `sub-fonts-dir`。
    if (detectedFormat == SubtitleTextFormat.ass &&
        onAssContentPrepared != null &&
        workingText.contains('[Fonts]')) {
      await onAssContentPrepared!(workingText);
    }

    final processed = SubtitleContentProcessor.process(
      content: workingText,
      mode: request.openCcMode,
      forceOverrideSubsetGuard: request.forceOverrideSubsetGuard,
    );
    final remapped = SubtitleTimelineRemapper.remap(
      content: processed.content,
      transform: request.timelineTransform,
      format: detectedFormat,
      fileName: request.fileName ?? trimmedLocalPath,
    );
    final contentSha1 = sha1.convert(utf8.encode(remapped)).toString();

    return _PreparedMemorySlot(
      sourceFilePath: trimmedLocalPath,
      processedContent: remapped,
      contentSha1: contentSha1,
      decodedCharset: decoded.charset,
      subsetState: processed.subsetState,
      openCcSkipReason: processed.skipReason,
      displayTitle: request.displayTitle ?? request.fileName,
      hasTimelineRemap: request.hasTimelineRemap,
      cloudSubsetApplied: cloudApplied,
    );
  }

  ({int trackId, bool reused})? _ensureMountedTrack(
    LibMpvClient client,
    _PreparedMemorySlot slot,
  ) {
    if (slot.existingTrackId != null) {
      return (trackId: slot.existingTrackId!, reused: true);
    }
    final content = slot.processedContent;
    final contentSha1 = slot.contentSha1;
    if (content == null || contentSha1 == null) return null;

    final existingTracks = client.readTrackList();
    final existingSubIds = <int>{
      for (final track in existingTracks)
        if (track.type == MpvTrackType.subtitle) track.id,
    };

    // 命中当前物理周期已挂载且仍在 track-list 中的同内容内存轨，直接去重复用。
    final cachedId = _mountedMemoryTracksBySha1[contentSha1];
    if (cachedId != null && existingSubIds.contains(cachedId)) {
      if (slot.sourceFilePath != null && slot.sourceFilePath!.isNotEmpty) {
        _mountedTrackIdBySourcePath[_normalizePathKey(slot.sourceFilePath!)] =
            cachedId;
        _sourcePathByMountedTrackId[cachedId] = slot.sourceFilePath!;
      }
      return (trackId: cachedId, reused: true);
    }

    final title =
        (slot.displayTitle != null && slot.displayTitle!.trim().isNotEmpty)
        ? slot.displayTitle!.trim()
        : 'KonataMem_${contentSha1.substring(0, 8)}';

    // 统一使用 `cached` 静默载入 `track-list`，即使开启 `sub-auto=fuzzy` 亦绝不自动抢选 `sid`，
    // 由单一串行权威意图通道显式提交最终 `sid` / `secondary-sid`。
    final rc = client.command([
      'sub-add',
      'memory://$content',
      'cached',
      title,
    ]);
    if (rc < 0) return null;

    final refreshedTracks = client.readTrackList();
    int? mountedId;
    for (final track in refreshedTracks) {
      if (track.type == MpvTrackType.subtitle &&
          !existingSubIds.contains(track.id)) {
        mountedId = track.id;
      }
    }
    if (mountedId == null) {
      for (final track in refreshedTracks.reversed) {
        if (track.type == MpvTrackType.subtitle && track.title == title) {
          mountedId = track.id;
          break;
        }
      }
    }
    if (mountedId == null) return null;
    _mountedMemoryTracksBySha1[contentSha1] = mountedId;
    if (slot.sourceFilePath != null && slot.sourceFilePath!.isNotEmpty) {
      _mountedTrackIdBySourcePath[_normalizePathKey(slot.sourceFilePath!)] =
          mountedId;
      _sourcePathByMountedTrackId[mountedId] = slot.sourceFilePath!;
    }
    return (trackId: mountedId, reused: false);
  }

  void _writeSubDelay(
    LibMpvClient client,
    double seconds, {
    bool refreshIfPaused = true,
  }) {
    final rc = client.setPropertyDouble('sub-delay', seconds);
    if (rc < 0) {
      client.setPropertyString('sub-delay', seconds.toStringAsFixed(2));
    }
    if (refreshIfPaused && (client.getPropertyFlag('pause') ?? false)) {
      client.command(['seek', '0', 'relative', 'exact']);
    }
  }
}
