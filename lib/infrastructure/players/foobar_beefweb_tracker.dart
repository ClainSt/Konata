import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/models/external_audio_relay_models.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/models/playback_record.dart';

part 'foobar_beefweb_protocol.dart';

/// 外部音频单轨进度持久化回调签名（保留供旧单轨通道兼容）。
typedef FoobarPersistCallback =
    Future<void> Function(
      int positionSeconds,
      int durationSeconds, {
      required bool isFinal,
    });

/// 基于 `foobar2000`（`foo_beefweb` 本地回环接口）的专辑队列装填、子轨精准续播与跨轨秒级回写控制器。
class FoobarBeefwebTracker {
  const FoobarBeefwebTracker._();

  /// 默认 `Beefweb` 本地回环地址。
  static const String defaultBaseUrl = 'http://127.0.0.1:8880';

  /// 检测给定可执行文件路径是否为 `foobar2000` 并返回组件安装与实时连通状态。
  static Future<FoobarComponentStatusSnapshot> inspectStatus({
    required String executablePath,
    int port = FoobarBeefwebConfig.defaultPort,
    String? appDataDirOverride,
    bool verifyExecutableExists = true,
  }) async {
    final trimmed = executablePath.trim();
    final safePort = port.clamp(1, 65535);
    if (trimmed.isEmpty) {
      return FoobarComponentStatusSnapshot(
        state: FoobarComponentState.unconfigured,
        port: safePort,
      );
    }

    final hasSep = trimmed.contains('\\') || trimmed.contains('/');
    if (verifyExecutableExists && hasSep && !await File(trimmed).exists()) {
      return FoobarComponentStatusSnapshot(
        state: FoobarComponentState.unconfigured,
        executablePath: trimmed,
        port: safePort,
      );
    }

    if (!isFoobarExecutable(trimmed)) {
      return FoobarComponentStatusSnapshot(
        state: FoobarComponentState.notFoobar,
        executablePath: trimmed,
        port: safePort,
      );
    }

    final baseUrl = FoobarBeefwebConfig.buildLoopbackBaseUrl(safePort);
    final client = _createDirectClient();
    try {
      final live = await _BeefwebProtocol.queryPlayerState(client, baseUrl);
      if (live != null) {
        return FoobarComponentStatusSnapshot(
          state: FoobarComponentState.connected,
          executablePath: trimmed,
          port: safePort,
        );
      }
    } finally {
      client.close(force: true);
    }

    final installedOnDisk = await _hasInstalledBeefwebDll(
      executablePath: trimmed,
      appDataDirOverride: appDataDirOverride,
    );
    return FoobarComponentStatusSnapshot(
      state: installedOnDisk
          ? FoobarComponentState.installedPendingStart
          : FoobarComponentState.missingComponent,
      executablePath: trimmed,
      port: safePort,
    );
  }

  /// 判断可执行文件路径是否属于 `foobar2000`。
  static bool isFoobarExecutable(String executablePath) {
    final normalized = executablePath.replaceAll('/', '\\').toLowerCase();
    final base = p.windows.basename(normalized);
    return base.contains('foobar');
  }

  /// 若 `foobar2000` 当前正停留在 `Konata` 专属播放列表会话中，发送 `stop` 释放独占声卡并避免双声道叠音。
  static Future<bool> stopKonataSessionIfActive({
    int port = FoobarBeefwebConfig.defaultPort,
    String? baseUrlOverride,
  }) async {
    final baseUrl =
        baseUrlOverride ?? FoobarBeefwebConfig.buildLoopbackBaseUrl(port);
    final client = _createDirectClient();
    try {
      final snap = await _BeefwebProtocol.queryPlayerState(client, baseUrl);
      if (snap == null ||
          (snap.playbackState != 'playing' && snap.playbackState != 'paused')) {
        return false;
      }
      final konataPlaylistId = await _BeefwebProtocol.findPlaylistIdByTitle(
        client,
        baseUrl,
        FoobarBeefwebConfig.dedicatedPlaylistTitle,
      );
      if (konataPlaylistId == null ||
          snap.playlistId != konataPlaylistId) {
        return false;
      }
      await _BeefwebProtocol.postStop(client, baseUrl);
      return true;
    } finally {
      client.close(force: true);
    }
  }

  /// 向 `foo_beefweb` 的 `Konata` 专属播放列表装填专辑/分轨条目、起播目标子轨并跳转至断点秒数，
  /// 成功后返回后台持续运行的跨轨追踪任务 `Future<bool>`（返回值表示结束时是否可立即注销远程流）。
  static Future<({bool attachedToBeefweb, Future<bool> trackingDone})>
  attachAlbumAndTrack({
    required List<String> playlistLoadItems,
    String? fallbackSingleStreamItem,
    required List<ExternalAudioTrackDescriptor> tracks,
    required int initialTrackIndex,
    required int startSeconds,
    required ExternalAudioProgressCallback? onTrackProgress,
    Future<int>? processExitFuture,
    bool Function()? isCancelled,
    void Function()? onHeartbeat,
    bool keepRemoteSessionAlive = false,
    String baseUrl = defaultBaseUrl,
    Duration pollInterval = const Duration(milliseconds: 1200),
    Duration persistInterval = const Duration(seconds: 4),
    Duration startupWaitTimeout = const Duration(seconds: 5),
  }) async {
    final launchedAt = DateTime.now();
    var processExited = false;
    var exitedFast = false;
    if (processExitFuture != null) {
      unawaited(
        processExitFuture
            .then((_) {
              processExited = true;
              exitedFast =
                  DateTime.now().difference(launchedAt) <
                  const Duration(seconds: 4);
            })
            .catchError((Object error) {
              processExited = true;
              developer.log(
                '外部音频子进程退出异常已记录',
                name: 'konata.foobar_beefweb_tracker',
                error: error,
              );
            }),
      );
    }

    final setupClient = _createDirectClient();
    String? playlistId;
    var singleStreamCueFallback = false;
    var targetPlaylistIdx = 0;
    final safeTrackIdx = initialTrackIndex.clamp(0, tracks.length - 1);
    final initialTrack = tracks[safeTrackIdx];

    try {
      final ready = await _waitUntilBeefwebReady(
        setupClient,
        baseUrl,
        timeout: startupWaitTimeout,
        isCancelled: isCancelled,
        hasProcessExitedSlowly: () => processExited && !exitedFast,
      );
      if (!ready) {
        return (
          attachedToBeefweb: false,
          trackingDone: _finishWithoutBeefweb(
            processExitFuture: processExitFuture,
            launchedAt: launchedAt,
            processExited: processExited,
            exitedFast: exitedFast,
            keepRemoteSessionAlive: keepRemoteSessionAlive,
          ),
        );
      }

      playlistId = await _BeefwebProtocol.ensureDedicatedPlaylist(
        setupClient,
        baseUrl,
        FoobarBeefwebConfig.dedicatedPlaylistTitle,
      );
      await _BeefwebProtocol.replacePlaylistItems(
        setupClient,
        baseUrl,
        playlistId: playlistId,
        items: playlistLoadItems,
      );

      final loadedItems = await _BeefwebProtocol.queryPlaylistItems(
        setupClient,
        baseUrl,
        playlistId: playlistId,
        maxCount: (tracks.length + 16).clamp(32, 500),
      );

      final expectsMultiCueSubtracks =
          tracks.length >= 2 &&
          tracks.first.isCueSubtrack &&
          fallbackSingleStreamItem != null;

      if (expectsMultiCueSubtracks && loadedItems.length < 2) {
        singleStreamCueFallback = true;
        if (loadedItems.isEmpty) {
          await _BeefwebProtocol.replacePlaylistItems(
            setupClient,
            baseUrl,
            playlistId: playlistId,
            items: <String>[fallbackSingleStreamItem],
          );
        }
        targetPlaylistIdx = 0;
      } else if (loadedItems.isEmpty && fallbackSingleStreamItem != null) {
        singleStreamCueFallback = initialTrack.isCueSubtrack;
        await _BeefwebProtocol.replacePlaylistItems(
          setupClient,
          baseUrl,
          playlistId: playlistId,
          items: <String>[fallbackSingleStreamItem],
        );
        targetPlaylistIdx = 0;
      } else {
        targetPlaylistIdx = _resolvePlaylistIndexForTrack(
          loadedItems: loadedItems,
          targetTrack: initialTrack,
          fallbackIndex: safeTrackIdx,
        );
      }

      await _BeefwebProtocol.postPlayItem(
        setupClient,
        baseUrl,
        playlistId: playlistId,
        index: targetPlaylistIdx,
      );

      final targetSeekSec = singleStreamCueFallback
          ? ((initialTrack.cueStartSeconds ?? 0.0) + startSeconds).round()
          : startSeconds;
      if (targetSeekSec > 0) {
        await _applyInitialSeekWhenReady(
          setupClient,
          baseUrl,
          playlistId: playlistId,
          targetSeekSeconds: targetSeekSec,
          isCancelled: isCancelled,
        );
      }
    } finally {
      setupClient.close(force: true);
    }

    final resolvedPlaylistId = playlistId;
    final trackingFuture = _runAlbumTrackingLoop(
      baseUrl: baseUrl,
      playlistId: resolvedPlaylistId,
      tracks: tracks,
      initialTrack: initialTrack,
      initialRelativeSeconds: startSeconds > 0 ? startSeconds : 0,
      singleStreamCueFallback: singleStreamCueFallback,
      expectedItemSet: <String>{
        ...playlistLoadItems.map(_normalizeComparable),
        if (fallbackSingleStreamItem != null)
          _normalizeComparable(fallbackSingleStreamItem),
      },
      onTrackProgress: onTrackProgress,
      isCancelled: isCancelled,
      onHeartbeat: onHeartbeat,
      hasProcessExitedSlowly: () => processExited && !exitedFast,
      pollInterval: pollInterval,
      persistInterval: persistInterval,
    );

    return (attachedToBeefweb: true, trackingDone: trackingFuture);
  }

  /// 兼容单文件外部音频进度追踪入口。
  static Future<bool> trackProcess({
    required String targetUrlOrPath,
    required Future<int> exitCodeFuture,
    required FoobarPersistCallback onPersist,
    int startSeconds = 0,
    bool keepRemoteSessionAlive = false,
    String baseUrl = defaultBaseUrl,
  }) async {
    final dummyVariantTrack = ExternalAudioTrackDescriptor(
      recordId: 'single',
      episodeId: 'single',
      variant: _placeholderVariant(targetUrlOrPath),
      title: p.basename(targetUrlOrPath),
    );
    final res = await attachAlbumAndTrack(
      playlistLoadItems: <String>[targetUrlOrPath],
      tracks: <ExternalAudioTrackDescriptor>[dummyVariantTrack],
      initialTrackIndex: 0,
      startSeconds: startSeconds,
      processExitFuture: exitCodeFuture,
      keepRemoteSessionAlive: keepRemoteSessionAlive,
      baseUrl: baseUrl,
      startupWaitTimeout: const Duration(seconds: 2),
      onTrackProgress: (_, pos, dur, {required isCompleted, required isFinal}) {
        return onPersist(pos, dur, isFinal: isFinal);
      },
    );
    return res.trackingDone;
  }

  static Future<bool> _runAlbumTrackingLoop({
    required String baseUrl,
    required String playlistId,
    required List<ExternalAudioTrackDescriptor> tracks,
    required ExternalAudioTrackDescriptor initialTrack,
    required int initialRelativeSeconds,
    required bool singleStreamCueFallback,
    required Set<String> expectedItemSet,
    required ExternalAudioProgressCallback? onTrackProgress,
    required bool Function()? isCancelled,
    required void Function()? onHeartbeat,
    required bool Function() hasProcessExitedSlowly,
    required Duration pollInterval,
    required Duration persistInterval,
  }) async {
    final client = _createDirectClient();
    var currentTrack = initialTrack;
    var lastRelPos = initialRelativeSeconds;
    var lastRelDur = initialTrack.resolvedDurationSeconds;
    var hasObservedPlaying = false;
    var consecutiveMisses = 0;
    var lastPersistAt = DateTime.fromMillisecondsSinceEpoch(0);
    var settledOnClose = false;

    Future<void> emitProgress(
      ExternalAudioTrackDescriptor track,
      int pos,
      int dur, {
      required bool completed,
      required bool isFinal,
    }) async {
      if (onTrackProgress == null || dur <= 0) return;
      final autoDone =
          completed ||
          PlaybackRecord.computeCompleted(
            positionSeconds: pos,
            durationSeconds: dur,
            isAudio: true,
          );
      await onTrackProgress(
        track,
        autoDone ? dur : pos,
        dur,
        isCompleted: autoDone,
        isFinal: isFinal,
      );
    }

    try {
      while (true) {
        if (isCancelled != null && isCancelled()) {
          break;
        }

        final snap = await _BeefwebProtocol.queryPlayerState(client, baseUrl);
        if (snap == null) {
          consecutiveMisses += 1;
          if (consecutiveMisses >= 3 || hasProcessExitedSlowly()) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 450));
          continue;
        }
        consecutiveMisses = 0;

        final state = snap.playbackState;
        final inOurSession = _belongsToKonataSession(
          snap: snap,
          playlistId: playlistId,
          expectedItemSet: expectedItemSet,
        );

        if ((state == 'playing' || state == 'paused') && inOurSession) {
          hasObservedPlaying = true;
          onHeartbeat?.call();

          final resolved = _mapSnapshotToTrackProgress(
            snap: snap,
            tracks: tracks,
            fallbackCurrent: currentTrack,
            singleStreamCueFallback: singleStreamCueFallback,
          );

          if (resolved.track.recordId != currentTrack.recordId) {
            // 检测到跨轨切换：先结算上一首曲目的完成或离开断点，再切换当前追踪曲目。
            if (lastRelDur > 0) {
              final nearEnd = (lastRelDur - lastRelPos).abs() <= 6;
              await emitProgress(
                currentTrack,
                nearEnd ? lastRelDur : lastRelPos,
                lastRelDur,
                completed: nearEnd,
                isFinal: true,
              );
            }
            currentTrack = resolved.track;
            lastRelPos = resolved.relativePosition;
            lastRelDur = resolved.relativeDuration;
            lastPersistAt = DateTime.now();
            await emitProgress(
              currentTrack,
              lastRelPos,
              lastRelDur,
              completed: false,
              isFinal: false,
            );
          } else {
            // 防护刚起播 Seek 尚未生效前读到 0 秒瞬态覆盖既有断点。
            final isTransientZeroAtStart =
                resolved.relativePosition <= 1 &&
                initialRelativeSeconds > 3 &&
                trackEqualsInitial(currentTrack, initialTrack) &&
                lastRelPos == initialRelativeSeconds;
            if (!isTransientZeroAtStart && resolved.relativePosition >= 0) {
              lastRelPos = resolved.relativePosition;
            }
            if (resolved.relativeDuration > 0) {
              lastRelDur = resolved.relativeDuration;
            }

            final now = DateTime.now();
            if (lastRelDur > 0 &&
                now.difference(lastPersistAt) >= persistInterval) {
              lastPersistAt = now;
              await emitProgress(
                currentTrack,
                lastRelPos,
                lastRelDur,
                completed: false,
                isFinal: false,
              );
            }
          }
        } else if (hasObservedPlaying) {
          if (state == 'stopped') {
            if (lastRelDur > 0) {
              final nearEnd = (lastRelDur - lastRelPos).abs() <= 6;
              await emitProgress(
                currentTrack,
                nearEnd ? lastRelDur : lastRelPos,
                lastRelDur,
                completed: nearEnd,
                isFinal: true,
              );
              settledOnClose = true;
            }
            break;
          }
          if (!inOurSession && snap.path.isNotEmpty) {
            break;
          }
        }

        if (hasProcessExitedSlowly()) {
          break;
        }
        await Future<void>.delayed(pollInterval);
      }

      if (hasObservedPlaying && !settledOnClose && lastRelDur > 0) {
        await emitProgress(
          currentTrack,
          lastRelPos,
          lastRelDur,
          completed: false,
          isFinal: true,
        );
      }
      return true;
    } finally {
      client.close(force: true);
    }
  }

  static bool trackEqualsInitial(
    ExternalAudioTrackDescriptor a,
    ExternalAudioTrackDescriptor b,
  ) => a.recordId == b.recordId;
}
