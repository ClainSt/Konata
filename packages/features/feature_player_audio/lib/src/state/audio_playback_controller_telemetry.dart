part of 'audio_playback_controller.dart';

extension _AudioPlaybackControllerTelemetry on AudioPlaybackController {
  /// 仅在切歌、列表更新或初始装配（低频）时通知可选 `LyricDisplayPort` 拉取歌词与预取队列。
  void _syncLyricsForActiveTrack() {
    final lyricPort = _lyricPort;
    if (lyricPort == null) return;

    final snap = _snapshotNotifier.value;
    final item = snap.currentItem;
    if (item == null) {
      lyricPort.clearActive();
      return;
    }

    final resolvedDur = currentTrackDurationSeconds > 0
        ? currentTrackDurationSeconds
        : item.durationSeconds;
    unawaited(
      lyricPort.resolveForTrack(
        item.toLyricTrackQuery(resolvedDurationSeconds: resolvedDur),
      ),
    );

    final upcoming = <LyricTrackQuery>[];
    if (snap.playOrder.isNotEmpty) {
      final startPos = snap.playOrderPos >= 0 ? snap.playOrderPos : 0;
      for (var step = 1; step <= 3; step++) {
        final nextPos = startPos + step;
        if (nextPos >= snap.playOrder.length) break;
        final candidate = snap.queue[snap.playOrder[nextPos]];
        if (candidate.isUnexpandedCueManifest) continue;
        upcoming.add(candidate.toLyricTrackQuery());
      }
    }
    if (upcoming.isNotEmpty) {
      unawaited(lyricPort.prefetchQueue(upcoming));
    }
  }

  /// 停播或清空会话时通知可选歌词端口清理活动上下文。
  void _clearLyrics() {
    _lyricPort?.clearActive();
  }

  /// 异步解析封面字节并提取内嵌或同目录 `.lrc` 文本；若探测到新歌词则补发一次低频同步。
  void _scheduleAuxiliaryLoad(AudioQueueItem item) {
    final token = _engine.acquireTaskToken(PlaybackTaskDomain.artworkColor);
    unawaited(
      _assets
          .resolveTrackAuxiliary(
            item: item,
            gatewayFactory: _gatewayFactory,
            photosStorage: _photosStorage,
            artworkCacheStore: _artworkCacheStore,
            probeLyrics: true,
          )
          .then((resolved) {
            if (_disposed || !_engine.isTaskAlive(token)) return;
            final current = _snapshotNotifier.value.currentItem;
            if (current == null || current.itemId != item.itemId) return;

            final newCoverTag = resolved.coverCacheKey ?? item.itemId;
            var nextQueue = _snapshotNotifier.value.queue;
            final hasNewLyrics =
                resolved.extractedLyricsText != null &&
                resolved.extractedLyricsText!.trim().isNotEmpty &&
                resolved.extractedLyricsText != current.embeddedLrcText;

            if (hasNewLyrics) {
              final updatedItem = current.copyWith(
                embeddedLrcText: resolved.extractedLyricsText,
              );
              nextQueue = List<AudioQueueItem>.from(nextQueue);
              nextQueue[_snapshotNotifier.value.currentIndex] = updatedItem;
            }

            _updateSnapshot(
              _snapshotNotifier.value.copyWith(
                queue: nextQueue,
                cover: resolved.cover,
                coverVariantTag: newCoverTag,
              ),
            );

            if (hasNewLyrics && _lyricPort != null) {
              final updated = _snapshotNotifier.value.currentItem;
              if (updated != null) {
                unawaited(
                  _lyricPort.resolveForTrack(
                    updated.toLyricTrackQuery(
                      resolvedDurationSeconds: currentTrackDurationSeconds > 0
                          ? currentTrackDurationSeconds
                          : updated.durationSeconds,
                    ),
                  ),
                );
              }
            }
          })
          .catchError((Object error, StackTrace stackTrace) {
            _recordError(
              code: 'AUDIO_AUXILIARY_LOAD_FAIL',
              message: '音轨辅助封面或内嵌歌词读取失败',
              error: error,
              stackTrace: stackTrace,
            );
          }),
    );
  }

  /// 低频持久化音频播放历史至 `playback_records`，严格以 `cd::` 隔离视频续播列表。
  Future<void> _persistPlaybackHistory({
    required bool force,
    bool markCompleted = false,
  }) async {
    final dao = _playbackRecordDao;
    final snap = _snapshotNotifier.value;
    final item = snap.currentItem;
    if (dao == null || item == null) return;

    final posSec = currentTrackPositionSeconds.floor().clamp(0, 864000);
    final durSec = currentTrackDurationSeconds.floor().clamp(0, 864000);
    if (!force && posSec < 2) return;

    final now = DateTime.now().toUtc();
    _lastHistoryPersistAt = DateTime.now();
    final nowMs = now.millisecondsSinceEpoch;
    final completed =
        markCompleted ||
        PlaybackRecordHelper.computeCompleted(
          positionSeconds: posSec,
          durationSeconds: durSec,
          isAudio: true,
        );

    final recordId =
        '${PlaybackRecordHelper.audioEpisodePrefix}${item.workId.value}::${item.itemId}';
    final episodeId = EpisodeId(
      '${PlaybackRecordHelper.audioEpisodePrefix}${item.itemId}',
    );

    try {
      dao.upsert(
        PlaybackRecordEntity(
          id: recordId,
          workId: item.workId,
          episodeId: episodeId,
          variantId: item.variantId,
          playedAtMs: nowMs,
          seasonNumber: 1,
          episodeNumber: item.cueTrackIndex ?? (snap.currentIndex + 1),
          episodeTitle: item.title,
          sourceKind: item.source.kind,
          positionSeconds: posSec,
          durationSeconds: durSec,
          isCompleted: completed,
          updatedAtMs: nowMs,
        ),
      );
    } catch (error, stackTrace) {
      _recordError(
        code: 'AUDIO_HISTORY_UPSERT_FAIL',
        message: '写入音频播放历史失败',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _bindAndroidMediaSessionCallbacks() {
    final mediaSession = _androidMediaSessionPort;
    if (mediaSession == null) return;
    mediaSession.bindCallbacks(
      onPlay: () => unawaited(setPlaying(true)),
      onPause: () => unawaited(setPlaying(false)),
      onTogglePlayPause: () => unawaited(togglePlayPause()),
      onPrevious: () => unawaited(previous()),
      onNext: () => unawaited(next(manual: true)),
      onSeekToSeconds: (sec) => unawaited(seekRelativeTrackSeconds(sec)),
      onStop: () => unawaited(stopAndClose()),
    );
  }

  void _syncAndroidMediaSession({bool forcePosition = false}) {
    final mediaSession = _androidMediaSessionPort;
    final snap = _snapshotNotifier.value;
    final item = snap.currentItem;
    if (mediaSession == null || item == null) return;

    _lastMediaSessionSyncAt = DateTime.now();
    final cover = snap.cover;
    final coverBytes = cover is MemoryAudioCover ? cover.bytes : null;
    unawaited(
      mediaSession.syncSession(
        trackId: item.itemId,
        title: item.title,
        artist: item.artist.isNotEmpty ? item.artist : item.album,
        album: item.album,
        durationSeconds: currentTrackDurationSeconds,
        positionSeconds: currentTrackPositionSeconds,
        isPlaying: _playingNotifier.value,
        coverKey: snap.coverVariantTag ?? item.itemId,
        coverBytes: coverBytes,
        forcePositionSync: forcePosition,
      ),
    );
  }

  void _recordLog({
    required String code,
    required String message,
    DiagnosticSeverity severity = DiagnosticSeverity.info,
  }) {
    _logPort?.logEvent(
      subsystem: DiagnosticSubsystem.audio,
      code: code,
      message: message,
      severity: severity,
      source: 'feature_player_audio',
    );
  }

  void _recordError({
    required String code,
    required String message,
    required Object error,
    StackTrace? stackTrace,
  }) {
    _logPort?.logError(
      subsystem: DiagnosticSubsystem.audio,
      code: code,
      message: message,
      error: error,
      stackTrace: stackTrace,
      source: 'feature_player_audio',
    );
  }
}
