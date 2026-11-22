import 'dart:async';
import 'dart:collection';
import 'dart:developer' as developer;

import 'package:path/path.dart' as p;

import '../../domain/matching/directory_grouper.dart';
import '../../domain/matching/supplementary_folder_rules.dart';
import '../../domain/models/media_extensions.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/playback/subtitle_and_audio_choices.dart';
import '../../domain/repositories/file_system_gateway.dart';
import '../../domain/scraping/personal_filename_parser.dart';
import 'directory_scan_snapshot.dart';
import 'scan_throttle_policy.dart';
import 'source_access_error.dart';
import 'subtitle_matcher.dart';

/// 目录扫描结果。
class DirectoryScanResult {
  /// 创建扫描结果实例。
  const DirectoryScanResult({
    required this.files,
    required this.nfoByFolder,
    required this.scannedDirectories,
    this.localCoverByFolder = const {},
    this.folderVideoCounts = const {},
    this.cancelled = false,
    this.reusedDirectories = 0,
    this.resumedFromCheckpoint = false,
    this.snapshot,
  });

  /// 已归类与关联外挂字幕后的媒体文件输入列表。
  final List<ScannedFileInput> files;

  /// 目录相对路径到 `.nfo` 文本内容的映射。
  final Map<String, String> nfoByFolder;

  /// 仅限本地磁盘源扫描时顺手识别的目录封面相对路径（优先级：`poster` > `cover` > `folder`，绝不扫描本地 Logo）。
  final Map<String, String> localCoverByFolder;

  /// 本次遍历的目录总数（含快照直接复用的目录）。
  final int scannedDirectories;

  /// 各已遍历目录对应的视频文件计数。
  final Map<String, int> folderVideoCounts;

  /// 本次遍历是否因用户取消而提前中断。
  final bool cancelled;

  /// 本次扫描通过目录快照验证标识命中或断点恢复免网络请求的目录数。
  final int reusedDirectories;

  /// 本次扫描是否自未完成断点检查点续扫恢复。
  final bool resumedFromCheckpoint;

  /// 本次扫描产出的完整目录树快照或中途断点检查点。
  final DirectoryScanSnapshot? snapshot;
}

/// 扫描进度回调。
typedef DirectoryScanProgressCallback =
    void Function(
      String currentDirectory,
      int scannedDirectories,
      int foundFiles,
    );

/// 单目录枚举完成回调。
typedef DirectoryFolderVisitedCallback =
    void Function(String folderPath, int videoCount, bool completed);

/// 周期性与收尾目录快照持久化回调。
typedef DirectoryScanCheckpointCallback =
    Future<void> Function(DirectoryScanSnapshot snapshot);

/// 统一异步只读目录扫描器（支持分协议自适应并发、云盘 AIMD 防风控起搏与显式 ID 免读 NFO）。
///
/// 基于 [MediaSourceGateway] 遍历本地、WebDAV 与 SMB 目录树，仅读取目录项元数据与必要的
/// `.nfo` 文本文件，绝不读取视频流字节。
class DirectoryScanner {
  /// 创建目录扫描器实例；可选注入自定义 [profile] 覆盖默认协议并发与起搏策略。
  const DirectoryScanner({this.profile});

  /// 可选显式扫描并发与起搏档案（为 `null` 时按网关协议自动匹配）。
  final DirectoryScanProfile? profile;

  /// 无媒体垃圾与蓝光原盘非视频子目录剪枝集合（严格保留 `bdmv`/`stream` 以便识别蓝光正片）。
  static const Set<String> _ignoredDirNames = {
    '@eadir',
    '\$recycle.bin',
    'system volume information',
    'fonts',
    'font',
    '.git',
    '.@__thumb',
    '#recycle',
    '@recycle',
    '#snapshot',
    '@transcode',
    '__macosx',
    'lost+found',
    'thumbs',
    'auxdata',
    'backup',
    'clipinf',
    'jar',
    'meta',
    'playlist',
    'certificate',
  };

  /// 扫描收尾纯计算阶段单个时间片上限（约半帧），超出即让出事件循环。
  static const Duration _yieldSlice = Duration(milliseconds: 8);

  /// 普通瞬时故障（非 429）的重试退避间隔。
  static const List<Duration> _transientRetryDelays = [
    Duration(milliseconds: 500),
    Duration(milliseconds: 1500),
  ];

  static final RegExp _explicitBangumiMarker = RegExp(
    r'[\[{]\s*(?:bgm|bangumi)(?:id)?\s*[-=:_]\s*\d+\s*[\]}]',
    caseSensitive: false,
  );

  static const Set<String> _videoExts = KonataMediaExtensions.video;

  static const Set<String> _subtitleExts = KonataMediaExtensions.subtitle;

  static const Set<String> _audioExts = KonataMediaExtensions.scannableAudio;

  static const Set<String> _scanImageExts = KonataMediaExtensions.scanImage;

  static final RegExp _cdDirRegex = RegExp(
    r'(?:^|[\s._\-\[\]()])(?:cd|cds|ost|soundtrack|music|radio|drama|disc\s*\d+)(?=$|[\s._\-\[\]()0-9])',
    caseSensitive: false,
  );

  static final RegExp _scanDirRegex = RegExp(
    r'(?:^|[\s._\-\[\]()])(?:scans?|booklets?|bk|artwork|gallery|illustrations?)(?=$|[\s._\-\[\]()0-9])',
    caseSensitive: false,
  );

  static final RegExp _trimSlashesPattern = RegExp(r'^/+|/+$');

  /// 断点续扫周期落盘阈值：每新完成指定数量实盘列举目录即刷新一次检查点。
  static const int _checkpointFlushInterval = 128;
  static const Duration _checkpointMinimumInterval = Duration(seconds: 5);

  /// 异步递归扫描媒体源根目录或用户勾选的 [scanRoots]，返回可供后台 Isolate 归组的文件清单。
  ///
  /// - 自动按协议选择并发与防风控起搏（WebDAV 采用冷热感知 AIMD 并发 2~4 + 429 乘性降窗）；
  /// - 目录路径已含显式 TMDB / Bangumi 编号时跳过 `.nfo` 远程 `GET`，大幅降低云盘直链签发风控；
  /// - 支持通过 [previousSnapshot] 对未变更叶目录与静态附属子树免网络列举复用，并在中断后自断点恢复；
  /// - 仅当 [detectLocalCovers] 为 `true`（仅本地磁盘源启用）时顺手记录同级常规封面文件。
  Future<DirectoryScanResult> scan(
    MediaSourceGateway gateway, {
    List<String> scanRoots = const [],
    bool detectLocalCovers = false,
    DirectoryScanProgressCallback? onProgress,
    DirectoryFolderVisitedCallback? onFolderVisited,
    bool Function()? isCancelled,
    DirectoryScanProfile? profileOverride,
    String sourceId = '',
    DirectoryScanSnapshot? previousSnapshot,
    bool enableSnapshotReuse = true,
    bool enableCheckpointResume = true,
    DirectoryScanCheckpointCallback? onCheckpoint,
    DateTime? clockNow,
  }) async {
    final effectiveNow = (clockNow ?? DateTime.now()).toUtc();
    final effectiveProfile =
        profileOverride ?? profile ?? DirectoryScanProfile.forGateway(gateway);
    final controller = AdaptiveScanController(effectiveProfile);
    final normalizedRoots = normalizeScanRoots(scanRoots);
    final trackSnapshot = sourceId.isNotEmpty;
    final queue = ListQueue<String>();
    final visitedDirs = <String>{};
    final inFlightDirs = <String>{};
    final rawFiles = <RemoteEntry>[];
    final subtitlesByFolder = <String, List<RemoteEntry>>{};
    final nfoByFolder = <String, String>{};
    final localCoverByFolder = <String, String>{};
    final localCoverRankByFolder = <String, int>{};
    final folderVideoCounts = <String, int>{};
    final snapshotNodes = <String, DirectoryScanSnapshotNode>{};
    final validatorsByDir = <String, String>{};
    final staticSuppDirFlags = <String, bool>{};
    var scannedDirectories = 0;
    var reusedDirectories = 0;
    var liveCompletedSinceCheckpoint = 0;
    var resumedFromCheckpoint = false;
    var cancelled = false;
    var inFlight = 0;
    Object? fatalError;
    StackTrace? fatalStackTrace;
    Future<void>? checkpointWrite;
    final checkpointClock = Stopwatch()..start();
    var startedAt = effectiveNow;
    var lastFullScanAt = effectiveNow;
    final done = Completer<void>();

    void ingestSnapshotNode(
      DirectoryScanSnapshotNode node, {
      required bool countAsReused,
    }) {
      final dirPath = node.relativePath;
      snapshotNodes[dirPath] = node;
      if (node.cacheValidator != null && node.cacheValidator!.isNotEmpty) {
        validatorsByDir[dirPath] = node.cacheValidator!;
      }
      scannedDirectories++;
      if (countAsReused) {
        reusedDirectories++;
      }
      var dirVideoCount = 0;
      for (final entry in node.fileEntries) {
        final lowerName = entry.name.toLowerCase();
        final ext = p.posix.extension(lowerName);
        if (_subtitleExts.contains(ext)) {
          subtitlesByFolder.putIfAbsent(dirPath, () => []).add(entry);
          continue;
        }
        final kind = _classifyAssetKind(dirPath, ext);
        if (kind != null) {
          rawFiles.add(entry);
          if (kind == AssetKind.video) {
            dirVideoCount++;
          }
        }
      }
      if (node.nfoText != null && node.nfoText!.trim().isNotEmpty) {
        nfoByFolder[dirPath] = node.nfoText!;
      }
      if (detectLocalCovers &&
          node.localCoverPath != null &&
          node.localCoverPath!.isNotEmpty) {
        localCoverByFolder[dirPath] = node.localCoverPath!;
      }
      folderVideoCounts[dirPath] = dirVideoCount;
      onFolderVisited?.call(dirPath, dirVideoCount, true);
      onProgress?.call(dirPath, scannedDirectories, rawFiles.length);
    }

    bool inferIsStaticSupplementaryPath(String dirPath) {
      if (dirPath.isEmpty) return false;
      var inStatic = false;
      for (final seg in dirPath.split('/')) {
        if (seg.isEmpty) continue;
        inStatic = DirectoryScanSnapshot.isStaticSupplementaryChildDir(
          seg,
          parentIsStaticSupplementary: inStatic,
        );
      }
      return inStatic;
    }

    DirectoryScanSnapshot buildSnapshot({required bool isComplete}) {
      final pending = <String>[];
      final pendingSeen = <String>{};
      if (!isComplete) {
        for (final dir in inFlightDirs) {
          if (!snapshotNodes.containsKey(dir) && pendingSeen.add(dir)) {
            pending.add(dir);
          }
        }
        for (final dir in queue) {
          if (!snapshotNodes.containsKey(dir) && pendingSeen.add(dir)) {
            pending.add(dir);
          }
        }
      }
      final pendingValidators = <String, String>{
        for (final dir in pending)
          if (validatorsByDir[dir] case final v? when v.isNotEmpty) dir: v,
      };
      return DirectoryScanSnapshot(
        sourceId: sourceId,
        scanRoots: normalizedRoots,
        detectLocalCovers: detectLocalCovers,
        startedAt: startedAt,
        lastFullScanAt: lastFullScanAt,
        isComplete: isComplete,
        nodes: Map<String, DirectoryScanSnapshotNode>.unmodifiable(
          snapshotNodes,
        ),
        pendingQueue: List<String>.unmodifiable(pending),
        pendingValidators: Map<String, String>.unmodifiable(pendingValidators),
      );
    }

    Future<void> saveSnapshot(DirectoryScanSnapshot snapshot) async {
      try {
        await onCheckpoint?.call(snapshot);
      } catch (error, stackTrace) {
        developer.log(
          '保存目录扫描快照失败',
          name: 'konata.directory_scanner',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    void scheduleCheckpointFlush() {
      if (onCheckpoint == null ||
          !trackSnapshot ||
          checkpointWrite != null ||
          liveCompletedSinceCheckpoint < _checkpointFlushInterval ||
          checkpointClock.elapsed < _checkpointMinimumInterval) {
        return;
      }
      final checkpoint = buildSnapshot(isComplete: false);
      if (checkpoint.pendingQueue.isEmpty) return;
      liveCompletedSinceCheckpoint = 0;
      checkpointClock.reset();
      checkpointWrite = saveSnapshot(checkpoint).whenComplete(() {
        checkpointWrite = null;
      });
    }

    final reusableCompleteSnapshot =
        trackSnapshot &&
            enableSnapshotReuse &&
            previousSnapshot != null &&
            previousSnapshot.sourceId == sourceId &&
            previousSnapshot.isComplete &&
            previousSnapshot.isFresh(now: effectiveNow)
        ? previousSnapshot
        : null;
    if (reusableCompleteSnapshot != null) {
      lastFullScanAt = reusableCompleteSnapshot.lastFullScanAt;
    }

    if (trackSnapshot &&
        enableCheckpointResume &&
        previousSnapshot != null &&
        previousSnapshot.sourceId == sourceId &&
        previousSnapshot.canResumeCheckpoint(
          normalizedRoots: normalizedRoots,
          requireLocalCovers: detectLocalCovers,
          now: effectiveNow,
        )) {
      resumedFromCheckpoint = true;
      startedAt = previousSnapshot.startedAt;
      lastFullScanAt = previousSnapshot.lastFullScanAt;
      validatorsByDir.addAll(previousSnapshot.pendingValidators);
      for (final node in previousSnapshot.nodes.values) {
        if (visitedDirs.add(node.relativePath)) {
          ingestSnapshotNode(node, countAsReused: true);
        }
      }
      for (final pendingDir in previousSnapshot.pendingQueue) {
        final normPending = _normalizeDirectory(pendingDir);
        if (!visitedDirs.contains(normPending)) {
          staticSuppDirFlags[normPending] = inferIsStaticSupplementaryPath(
            normPending,
          );
          queue.addLast(normPending);
        }
      }
    } else {
      for (final root in normalizedRoots) {
        staticSuppDirFlags[root] = false;
        queue.addLast(root);
      }
    }

    void maybeFinish() {
      if (done.isCompleted) return;
      if (inFlight == 0 && (cancelled || fatalError != null || queue.isEmpty)) {
        done.complete();
      }
    }

    Future<void> visitDirectory(String normalizedCurrent) async {
      try {
        if (isCancelled?.call() ?? false) {
          cancelled = true;
          return;
        }
        scannedDirectories++;
        folderVideoCounts.putIfAbsent(normalizedCurrent, () => 0);
        onFolderVisited?.call(normalizedCurrent, 0, false);
        onProgress?.call(
          normalizedCurrent,
          scannedDirectories,
          rawFiles.length,
        );

        final entries = await _listWithAdaptiveRetry(
          gateway,
          normalizedCurrent,
          controller: controller,
          isCancelled: isCancelled,
        );
        if (isCancelled?.call() ?? false) {
          cancelled = true;
          return;
        }

        var dirVideoCount = 0;
        RemoteEntry? preferredNfo;
        var preferredNfoRank = 0;
        final skipNfoDownload = _pathHasExplicitExternalId(normalizedCurrent);
        final parentIsStaticSupp =
            staticSuppDirFlags[normalizedCurrent] ?? false;
        final children = <RemoteEntry>[];
        final childDirs = <String>[];
        final nodeFileEntries = <RemoteEntry>[];
        var hasNonSupplementarySubdir = false;

        for (final entry in entries) {
          if (entry.isDirectory) {
            if (_shouldSkipDirectory(entry.name)) continue;
            if (trackSnapshot) {
              children.add(entry);
            } else {
              final child = _normalizeDirectory(entry.relativePath);
              if (child.isNotEmpty && !visitedDirs.contains(child)) {
                queue.addLast(child);
              }
            }
            continue;
          }

          final lowerName = entry.name.toLowerCase();
          final ext = p.posix.extension(lowerName);
          if (ext == '.nfo') {
            if (!skipNfoDownload &&
                !nfoByFolder.containsKey(normalizedCurrent)) {
              final rank = _nfoPriority(lowerName);
              if (rank > preferredNfoRank) {
                preferredNfoRank = rank;
                preferredNfo = entry;
              }
            }
            continue;
          }

          if (_subtitleExts.contains(ext)) {
            subtitlesByFolder
                .putIfAbsent(normalizedCurrent, () => [])
                .add(entry);
            if (trackSnapshot) nodeFileEntries.add(entry);
            continue;
          }

          if (detectLocalCovers) {
            final coverRank = _localCoverPriority(lowerName, ext);
            if (coverRank > 0) {
              final prevRank = localCoverRankByFolder[normalizedCurrent] ?? 0;
              if (coverRank > prevRank) {
                localCoverRankByFolder[normalizedCurrent] = coverRank;
                localCoverByFolder[normalizedCurrent] = entry.relativePath
                    .trim()
                    .replaceAll('\\', '/');
              }
            }
          }

          final kind = _classifyAssetKind(normalizedCurrent, ext);
          if (kind != null) {
            rawFiles.add(entry);
            if (trackSnapshot) nodeFileEntries.add(entry);
            if (kind == AssetKind.video) {
              dirVideoCount++;
            }
          }
        }

        if (preferredNfo != null &&
            !nfoByFolder.containsKey(normalizedCurrent) &&
            !(isCancelled?.call() ?? false)) {
          final nfoText = await _readNfoWithAdaptiveRetry(
            gateway,
            preferredNfo.relativePath,
            controller: controller,
            isCancelled: isCancelled,
          );
          if (nfoText != null && nfoText.trim().isNotEmpty) {
            nfoByFolder[normalizedCurrent] = nfoText;
          }
        }

        if (isCancelled?.call() ?? false) {
          cancelled = true;
          return;
        }
        if (trackSnapshot) {
          for (final entry in children) {
            final normChild = _normalizeDirectory(entry.relativePath);
            if (normChild.isEmpty) continue;
            childDirs.add(normChild);
            final childIsStaticSupp =
                DirectoryScanSnapshot.isStaticSupplementaryChildDir(
                  entry.name,
                  parentIsStaticSupplementary: parentIsStaticSupp,
                );
            staticSuppDirFlags[normChild] = childIsStaticSupp;
            if (!childIsStaticSupp) {
              hasNonSupplementarySubdir = true;
            }
            final childValidator = _snapshotValidator(
              entry,
              isArchive: childIsStaticSupp,
            );
            if (childValidator != null && childValidator.isNotEmpty) {
              validatorsByDir[normChild] = childValidator;
            }
            if (reusableCompleteSnapshot != null &&
                reusableCompleteSnapshot.canReuseSubtree(
                  normChild,
                  expectedValidator: childValidator,
                  allowArchiveReuse: childIsStaticSupp,
                  requireLocalCovers: detectLocalCovers,
                )) {
              final cachedNodes = reusableCompleteSnapshot.collectSubtreeNodes(
                normChild,
              );
              for (final cachedNode in cachedNodes) {
                if (visitedDirs.add(cachedNode.relativePath)) {
                  ingestSnapshotNode(cachedNode, countAsReused: true);
                }
              }
            } else if (!visitedDirs.contains(normChild)) {
              queue.addLast(normChild);
            }
          }
          snapshotNodes[normalizedCurrent] = DirectoryScanSnapshotNode(
            relativePath: normalizedCurrent,
            cacheValidator: validatorsByDir[normalizedCurrent],
            childDirs: List<String>.unmodifiable(childDirs),
            hasNonSupplementarySubdir: hasNonSupplementarySubdir,
            fileEntries: List<RemoteEntry>.unmodifiable(nodeFileEntries),
            nfoText: nfoByFolder[normalizedCurrent],
            localCoverPath: localCoverByFolder[normalizedCurrent],
          );
          inFlightDirs.remove(normalizedCurrent);
          liveCompletedSinceCheckpoint++;
          scheduleCheckpointFlush();
        }

        folderVideoCounts[normalizedCurrent] = dirVideoCount;
        onFolderVisited?.call(normalizedCurrent, dirVideoCount, true);
        onProgress?.call(
          normalizedCurrent,
          scannedDirectories,
          rawFiles.length,
        );
      } catch (error, stackTrace) {
        if (isCancelled?.call() ?? false) {
          cancelled = true;
        } else {
          fatalError ??= error;
          fatalStackTrace ??= stackTrace;
        }
      }
    }

    void pump() {
      if (done.isCompleted) return;
      if (isCancelled?.call() ?? false) {
        cancelled = true;
      }
      while (!cancelled &&
          fatalError == null &&
          queue.isNotEmpty &&
          inFlight < controller.currentConcurrency) {
        final rawDir = queue.removeFirst();
        final normalizedCurrent = _normalizeDirectory(rawDir);
        if (!visitedDirs.add(normalizedCurrent)) {
          continue;
        }
        if (trackSnapshot) inFlightDirs.add(normalizedCurrent);
        inFlight++;
        unawaited(
          visitDirectory(normalizedCurrent).whenComplete(() {
            inFlight--;
            pump();
          }),
        );
      }
      maybeFinish();
    }

    pump();
    await done.future;
    await checkpointWrite;

    Future<DirectoryScanSnapshot?> savePartial() async {
      if (!trackSnapshot || snapshotNodes.isEmpty) return null;
      final partial = buildSnapshot(isComplete: false);
      if (partial.pendingQueue.isEmpty) return null;
      await saveSnapshot(partial);
      return partial;
    }

    if (fatalError != null) {
      await savePartial();
      Error.throwWithStackTrace(fatalError!, fatalStackTrace!);
    }

    if (cancelled || (isCancelled?.call() ?? false)) {
      return DirectoryScanResult(
        files: const [],
        nfoByFolder: nfoByFolder,
        scannedDirectories: scannedDirectories,
        folderVideoCounts: Map.unmodifiable(folderVideoCounts),
        cancelled: true,
        reusedDirectories: reusedDirectories,
        resumedFromCheckpoint: resumedFromCheckpoint,
        snapshot: await savePartial(),
      );
    }

    final finalSnapshot = trackSnapshot
        ? buildSnapshot(isComplete: true)
        : null;
    if (finalSnapshot != null) await saveSnapshot(finalSnapshot);

    // 并发枚举完成顺序可能因 RTT 不同交错，按规范相对路径稳定排序，保证下游归组 100% 确定性。
    rawFiles.sort((a, b) => a.relativePath.compareTo(b.relativePath));

    // 字幕只可能挂到同一逻辑目录（含 `Subs/` 子目录折叠）的视频上：按逻辑目录分桶并逐条预处理一次，
    // 避免全库逐视频遍历，以及同目录内每个视频重复剥离语言后缀、重复解析字幕文件名。
    final subtitlesByLogicalDir = <String, List<PreparedSubtitle>>{};
    for (final entry in subtitlesByFolder.entries) {
      final logicalDir = SubtitleAndAudioChoices.logicalParentDirOfSubtitleDir(
        entry.key,
      );
      subtitlesByLogicalDir
          .putIfAbsent(logicalDir, () => <PreparedSubtitle>[])
          .addAll(
            SubtitleMatcher.prepare(entry.value.map((s) => s.relativePath)),
          );
    }

    // 汇总阶段为纯计算：按时间片主动让出事件循环，大目录扫描收尾时界面不卡顿。
    final slice = Stopwatch()..start();
    final outputs = <ScannedFileInput>[];
    for (final entry in rawFiles) {
      if (slice.elapsed >= _yieldSlice) {
        await Future<void>.delayed(Duration.zero);
        slice.reset();
      }
      final folder = _parentPosixDir(entry.relativePath);
      final ext = p.posix.extension(entry.name.toLowerCase());
      final kind = _classifyAssetKind(folder, ext);
      if (kind == null) continue;

      final subtitleMatch = kind == AssetKind.video
          ? SubtitleMatcher.matchPrepared(
              videoRelativePath: entry.relativePath,
              subtitles:
                  subtitlesByLogicalDir[folder] ?? const <PreparedSubtitle>[],
            )
          : null;

      outputs.add(
        ScannedFileInput(
          relativePath: entry.relativePath,
          fileName: entry.name,
          fileSize: entry.size,
          assetKind: kind,
          externalSubtitles: subtitleMatch?.subtitlePaths ?? const <String>[],
          subtitleGroupHint: subtitleMatch?.subtitleGroupHint,
        ),
      );
    }

    return DirectoryScanResult(
      files: outputs,
      nfoByFolder: nfoByFolder,
      localCoverByFolder: Map.unmodifiable(localCoverByFolder),
      scannedDirectories: scannedDirectories,
      folderVideoCounts: Map.unmodifiable(folderVideoCounts),
      reusedDirectories: reusedDirectories,
      resumedFromCheckpoint: resumedFromCheckpoint,
      snapshot: finalSnapshot,
    );
  }

  /// 列目录遇瞬时故障或云盘限流（429/503/509）时经由 [AdaptiveScanController] 退避降速重试；
  /// 认证、权限、路径等确定性错误立即抛出，取消扫描时立即中断。
  static Future<List<RemoteEntry>> _listWithAdaptiveRetry(
    MediaSourceGateway gateway,
    String relativePath, {
    required AdaptiveScanController controller,
    bool Function()? isCancelled,
  }) async {
    var transientAttempts = 0;
    var rateLimitAttempts = 0;
    while (true) {
      if (isCancelled?.call() ?? false) return const <RemoteEntry>[];
      await controller.acquireSlot(isCancelled: isCancelled);
      if (isCancelled?.call() ?? false) return const <RemoteEntry>[];
      final sw = Stopwatch()..start();
      try {
        final entries = await gateway.listDirectory(relativePath);
        sw.stop();
        controller.recordSuccess(sw.elapsed);
        return entries;
      } catch (error) {
        sw.stop();
        if (isCancelled?.call() ?? false) {
          return const <RemoteEntry>[];
        }
        if (SourceAccessErrorClassifier.isRateLimitError(error)) {
          if (rateLimitAttempts >= controller.profile.maxRateLimitRetries) {
            rethrow;
          }
          rateLimitAttempts++;
          final wait = controller.recordRateLimit(
            retryAfter: SourceAccessErrorClassifier.extractRetryAfter(error),
          );
          await Future<void>.delayed(wait);
          continue;
        }
        if (transientAttempts >= controller.profile.maxTransientRetries ||
            SourceAccessErrorClassifier.isNonTransientError(error)) {
          rethrow;
        }
        controller.recordTransientError();
        final delayIdx = transientAttempts < _transientRetryDelays.length
            ? transientAttempts
            : _transientRetryDelays.length - 1;
        transientAttempts++;
        await Future<void>.delayed(_transientRetryDelays[delayIdx]);
      }
    }
  }

  /// 读取 `.nfo` 同样经过平滑起搏与 429 降速保护；单条 `.nfo` 读取失败时安全降级跳过，不中断整次扫描。
  static Future<String?> _readNfoWithAdaptiveRetry(
    MediaSourceGateway gateway,
    String relativePath, {
    required AdaptiveScanController controller,
    bool Function()? isCancelled,
  }) async {
    var rateLimitAttempts = 0;
    while (true) {
      if (isCancelled?.call() ?? false) return null;
      await controller.acquireSlot(isCancelled: isCancelled);
      if (isCancelled?.call() ?? false) return null;
      final sw = Stopwatch()..start();
      try {
        final text = await gateway.readTextFile(relativePath);
        sw.stop();
        controller.recordSuccess(sw.elapsed);
        return text;
      } catch (error) {
        sw.stop();
        if (isCancelled?.call() ?? false) return null;
        if (SourceAccessErrorClassifier.isRateLimitError(error)) {
          if (rateLimitAttempts >= 2) return null;
          rateLimitAttempts++;
          final wait = controller.recordRateLimit(
            retryAfter: SourceAccessErrorClassifier.extractRetryAfter(error),
          );
          await Future<void>.delayed(wait);
          continue;
        }
        return null;
      }
    }
  }

  /// 检查目录自身或其任意祖先目录名是否已携带显式 TMDB / Bangumi 编号（已有 ID 时免读 `.nfo`）。
  static bool _pathHasExplicitExternalId(String normalizedFolderPath) {
    if (normalizedFolderPath.isEmpty) return false;
    for (final segment in normalizedFolderPath.split('/')) {
      if (segment.isEmpty) continue;
      if (PersonalFilenameParser.tmdbId(segment) != null ||
          _explicitBangumiMarker.hasMatch(segment)) {
        return true;
      }
    }
    return false;
  }

  /// 同一目录存在多个 `.nfo` 时的读取优先级：`tvshow.nfo` / `movie.nfo` 优先于分集 `.nfo`。
  static int _nfoPriority(String lowerFileName) {
    if (lowerFileName == 'tvshow.nfo' || lowerFileName == 'movie.nfo') {
      return 3;
    }
    if (lowerFileName == 'season.nfo') return 1;
    return 2;
  }

  /// 规范化勾选目录，并剔除被祖先目录覆盖的重复子目录。
  static List<String> normalizeScanRoots(List<String> scanRoots) {
    final cleaned = <String>{
      for (final raw in scanRoots)
        raw.replaceAll('\\', '/').replaceAll(_trimSlashesPattern, ''),
    }.toList()..sort();

    if (cleaned.isEmpty || cleaned.contains('')) {
      return [''];
    }

    final deduped = <String>[];
    for (final candidate in cleaned) {
      final covered = deduped.any(
        (parent) => candidate == parent || candidate.startsWith('$parent/'),
      );
      if (!covered) {
        deduped.add(candidate);
      }
    }
    return deduped;
  }

  static String _normalizeDirectory(String path) =>
      path.trim().replaceAll('\\', '/').replaceAll(_trimSlashesPattern, '');

  static String? _snapshotValidator(
    RemoteEntry entry, {
    required bool isArchive,
  }) {
    final etag = entry.etag?.trim();
    final modified = entry.modifiedAt?.microsecondsSinceEpoch;
    // 普通目录仅采用强版本标记，归档附属目录允许用修改时间短期复用。
    if (etag != null && etag.isNotEmpty && !etag.startsWith('W/')) {
      return 'etag:$etag;mtime:$modified';
    }
    return isArchive && modified != null ? 'mtime:$modified' : null;
  }

  bool _shouldSkipDirectory(String name) {
    final lower = name.trim().toLowerCase();
    if (lower.isEmpty || lower.startsWith('.')) return true;
    return _ignoredDirNames.contains(lower);
  }

  AssetKind? _classifyAssetKind(String folderPath, String ext) {
    if (_videoExts.contains(ext)) {
      return AssetKind.video;
    }
    final dirSegments = folderPath.split('/');
    final inAudioOrPackDir =
        dirSegments.any(_cdDirRegex.hasMatch) ||
        SupplementaryFolderRules.isAudioOrScanPath(folderPath);
    if (ext == '.cue' || (inAudioOrPackDir && _audioExts.contains(ext))) {
      return AssetKind.cdAlbum;
    }
    final inScanDir =
        dirSegments.any(_scanDirRegex.hasMatch) ||
        SupplementaryFolderRules.isAudioOrScanPath(folderPath);
    if (inScanDir && _scanImageExts.contains(ext)) {
      return AssetKind.scanGallery;
    }
    return null;
  }

  static int _localCoverPriority(String lowerFileName, String ext) {
    if (ext != '.jpg' && ext != '.jpeg' && ext != '.png' && ext != '.webp') {
      return 0;
    }
    final stem = p.posix.basenameWithoutExtension(lowerFileName);
    return switch (stem) {
      'poster' => 3,
      'cover' => 2,
      'folder' => 1,
      _ => 0,
    };
  }

  String _parentPosixDir(String relativePath) {
    final parent = p.posix.dirname(relativePath);
    return parent == '.' ? '' : parent;
  }
}
