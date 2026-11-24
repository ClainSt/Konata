part of 'audio_playback_controller.dart';

extension _AudioPlaybackControllerTransport on AudioPlaybackController {
  Future<void> _playQueueIndexInternal(
    int index, {
    double? initialTrackSeconds,
    required bool manualSelection,
  }) async {
    if (_disposed) return;
    var snap = _snapshotNotifier.value;
    if (index < 0 || index >= snap.queue.length) return;

    if (manualSelection) {
      _engine.recordManualSelection();
    }

    // 若目标条目属于尚未展开的 `.cue` 清单头或伴随 `.cue` 索引，先解析扩展后再装载真实物理流。
    var targetItem = snap.queue[index];
    if (targetItem.cueSheetPath != null && !targetItem.isCueTrack) {
      final expandedCount = await expandCueAtQueueIndex(index);
      snap = _snapshotNotifier.value;
      if (index >= snap.queue.length) return;
      if (expandedCount > 0) {
        targetItem = snap.queue[index];
      }
    }

    if (AudioPlaybackQueueBuilder.isCueManifestPath(targetItem.relativePath) &&
        targetItem.isUnexpandedCueManifest) {
      _updateSnapshot(
        snap.copyWith(
          status: AudioPlaybackStatus.error,
          isBuffering: false,
          errorMessage: '未能在同目录定位到 .cue 清单对应的音频物理文件',
        ),
      );
      return;
    }

    final previousItem = snap.currentItem;
    final seekOffset = math.max(0.0, initialTrackSeconds ?? 0.0);
    final absStart = targetItem.startSeconds + seekOffset;

    // 1. 若属于同一个 `.cue` 整轨物理文件（同源且同路径）且已有存活客户端，仅推进逻辑轨代数并无感定位。
    final client = _client;
    final samePhysicalCue =
        client != null &&
        !client.isDisposed &&
        client.isInitialized &&
        previousItem != null &&
        (previousItem.isCueTrack || targetItem.isCueTrack) &&
        AudioPlaybackQueueBuilder.isSamePhysicalStream(previousItem, targetItem);

    if (samePhysicalCue && manualSelection) {
      _engine.advanceLogicalTrack(resetLyricsDomain: true);
      _microFadeDriver.cancel();
      final prefs = _preferences.read();
      final plan = _safetyCoordinator.compilePlan(
        _effectiveAudiophilePrefs(prefs),
        upstreamDspFilters: _buildUpstreamDspFilters(prefs),
      );
      if (!plan.safetyLimiterEngaged && plan.microFadeInDurationMs > 0) {
        client.setPropertyDouble('volume', 0.0);
      }
      client.command(<String>['seek', absStart.toStringAsFixed(3), 'absolute']);
      client.setPropertyFlag('pause', false);
      _positionNotifier.value = Duration(
        milliseconds: (seekOffset * 1000.0).round(),
      );
      _playingNotifier.value = true;
      _applyLogicalTrackDuration(targetItem);

      final playOrderPos = snap.playOrder.indexOf(index);
      _updateSnapshot(
        snap.copyWith(
          status: AudioPlaybackStatus.playing,
          isActive: true,
          isBuffering: false,
          currentIndex: index,
          playOrderPos: playOrderPos >= 0 ? playOrderPos : snap.playOrderPos,
          audiophilePlan: plan,
          clearErrorMessage: true,
        ),
      );
      _applyVolumeWithSafetyFade(client: client, plan: plan, useMicroFade: true);
      _reconcileClockObservation();
      _armCueBoundaryWatchdog();
      _syncLyricsForActiveTrack();
      _scheduleAuxiliaryLoad(targetItem);
      _syncAndroidMediaSession(forcePosition: true);
      return;
    }

    // 2. 新物理媒体装载：推进物理代数并注册网关流/本地文件。
    _cueBoundaryTimer?.cancel();
    _cueBoundaryTimer = null;
    _microFadeDriver.cancel();

    final prefs = _preferences.read();
    final effectiveAudiophile = _effectiveAudiophilePrefs(prefs);
    final upstreamDsp = _buildUpstreamDspFilters(prefs);
    final openSeq = ++_mediaOpenSeq;
    final activeClient = await _ensureExclusiveClient(
      isRemoteStream: targetItem.source.kind != MediaSourceKind.local,
      prefs: prefs,
    );
    if (_disposed || activeClient == null || openSeq != _mediaOpenSeq) return;

    final epoch = _engine.beginPhysicalMedia(
      stage: PlaybackStageKind.audio,
      nativeInstanceId: _clientNativeInstanceId,
      preservePrefetchLease: false,
    );
    _clearPrefetchTracking(releaseBridge: true);

    final playOrderPos = snap.playOrder.indexOf(index);
    _rawDurationSeconds = targetItem.durationSeconds;
    _lastConfirmedAudioPosSeconds = absStart;
    _positionNotifier.value = Duration(
      milliseconds: (seekOffset * 1000.0).round(),
    );
    _applyLogicalTrackDuration(targetItem);

    _updateSnapshot(
      snap.copyWith(
        status: AudioPlaybackStatus.loading,
        isActive: true,
        isBuffering: true,
        currentIndex: index,
        playOrderPos: playOrderPos >= 0 ? playOrderPos : snap.playOrderPos,
        clearErrorMessage: true,
      ),
    );

    try {
      final targetUri = await _resolveMediaTargetAndBindLease(
        item: targetItem,
        isPrefetch: false,
      );
      if (_disposed ||
          openSeq != _mediaOpenSeq ||
          !_engine.matchesPhysicalEvent(physicalMediaEpoch: epoch)) {
        return;
      }

      final appliedPlan = _safetyCoordinator.applyToClient(
        activeClient,
        prefs: effectiveAudiophile,
        upstreamDspFilters: upstreamDsp,
      );
      _applyReplayGainOptions(
        client: activeClient,
        prefs: prefs,
        plan: appliedPlan,
      );

      if (absStart > 0.05) {
        activeClient.setPropertyDouble('start', absStart);
      } else {
        activeClient.setPropertyString('start', 'none');
      }
      if (!appliedPlan.safetyLimiterEngaged &&
          appliedPlan.microFadeInDurationMs > 0) {
        activeClient.setPropertyDouble('volume', 0.0);
      }

      activeClient.setPropertyFlag('pause', false);
      final rc = activeClient.command(<String>['loadfile', targetUri, 'replace']);
      if (rc < 0) {
        throw StateError(
          '音频文件装载命令返回异常 ($rc: ${activeClient.errorString(rc)})',
        );
      }

      if (!_engine.matchesPhysicalEvent(physicalMediaEpoch: epoch)) return;
      _playingNotifier.value = true;
      _updateSnapshot(
        _snapshotNotifier.value.copyWith(
          status: AudioPlaybackStatus.playing,
          audiophilePlan: appliedPlan,
          audiophileSafetyState: _safetyCoordinator.deviceSafetyState,
        ),
      );
      _applyVolumeWithSafetyFade(
        client: activeClient,
        plan: appliedPlan,
        useMicroFade: true,
      );
      _reconcileClockObservation();
      _armCueBoundaryWatchdog();
      _syncLyricsForActiveTrack();
      _scheduleAuxiliaryLoad(targetItem);
      _syncAndroidMediaSession(forcePosition: true);
    } catch (error, stackTrace) {
      if (!_engine.matchesPhysicalEvent(physicalMediaEpoch: epoch)) return;
      await _handlePhysicalLoadFailure(
        message: '加载音频流失败：${targetItem.title}',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// 解析并展开指定下标处的 `.cue` 分轨清单，返回新增后的子轨数量。
  Future<int> expandCueAtQueueIndex(int index) async {
    final snap = _snapshotNotifier.value;
    if (index < 0 || index >= snap.queue.length) return 0;
    final item = snap.queue[index];
    final cuePath = item.cueSheetPath;
    final work = _activeWork;
    if (cuePath == null || work == null || item.isCueTrack) return 0;

    final sheet = await _assets.loadCueSheet(
      source: item.source,
      cueRelativePath: cuePath,
      gatewayFactory: _gatewayFactory,
      knownFileSize: item.knownFileSize,
    );
    if (_disposed || sheet == null || sheet.tracks.isEmpty) return 0;

    final currentSnap = _snapshotNotifier.value;
    final resolvedIndex = currentSnap.queue.indexWhere(
      (q) => q.itemId == item.itemId,
    );
    if (resolvedIndex < 0) return 0;

    AudioQueueItem hostItem = currentSnap.queue[resolvedIndex];
    if (AudioPlaybackQueueBuilder.isCueManifestPath(hostItem.relativePath)) {
      final candidatePaths =
          AudioPlaybackQueueBuilder.extractDirectCueSiblingPaths(
            sheet,
            cuePath,
          );
      if (candidatePaths.isEmpty) return 0;
      hostItem = AudioQueueItem(
        itemId: hostItem.itemId,
        workId: hostItem.workId,
        sourceId: hostItem.sourceId,
        variantId: hostItem.variantId,
        title: hostItem.title,
        artist: hostItem.artist,
        album: hostItem.album,
        albumKey: hostItem.albumKey,
        fileName: p.posix.basename(candidatePaths.first),
        relativePath: candidatePaths.first,
        source: hostItem.source,
        variant: MediaVariantRecord(
          id: hostItem.variant.id,
          workId: hostItem.variant.workId,
          sourceId: hostItem.variant.sourceId,
          relativePath: candidatePaths.first,
          fileName: p.posix.basename(candidatePaths.first),
          fileSize: hostItem.variant.fileSize,
          assetKind: AssetKind.cdAlbum,
        ),
        cueSheetPath: cuePath,
        knownFileSize: hostItem.knownFileSize,
        posterRef: hostItem.posterRef,
        posterFallback: hostItem.posterFallback,
        bangumiSubjectId: hostItem.bangumiSubjectId,
      );
    }

    final expanded = AudioPlaybackQueueBuilder.expandCueTracksInQueue(
      queue: currentSnap.queue,
      targetIndex: resolvedIndex,
      work: work,
      resolvedAudioHost: hostItem,
      sheet: sheet,
      cueRelativePath: cuePath,
    );
    if (expanded.insertedCount <= 0) return 0;

    final updatedExpandedPaths = Set<String>.from(currentSnap.expandedCuePaths)
      ..add(
        AudioPlaybackQueueBuilder.normalizeQueuePath(cuePath).toLowerCase(),
      );
    final nextCurrentIndex = currentSnap.currentIndex > resolvedIndex
        ? currentSnap.currentIndex + expanded.insertedCount - 1
        : currentSnap.currentIndex;
    final nextOrder = AudioPlaybackQueueBuilder.buildPlayOrder(
      length: expanded.queue.length,
      currentIndex: nextCurrentIndex,
      shuffle: currentSnap.shuffleEnabled,
    );
    final nextOrderPos = nextCurrentIndex >= 0
        ? nextOrder.indexOf(nextCurrentIndex)
        : -1;

    _updateSnapshot(
      currentSnap.copyWith(
        queue: expanded.queue,
        currentIndex: nextCurrentIndex,
        playOrder: nextOrder,
        playOrderPos: nextOrderPos,
        expandedCuePaths: updatedExpandedPaths,
      ),
    );
    return expanded.insertedCount;
  }

  /// 将已展开的 `.cue` 分轨群组重新折叠为单条清单代表行。
  Future<void> collapseCueGroup(String cueRelativePath) async {
    final currentSnap = _snapshotNotifier.value;
    final norm = AudioPlaybackQueueBuilder.normalizeQueuePath(
      cueRelativePath,
    ).toLowerCase();
    if (!currentSnap.expandedCuePaths.contains(norm)) return;

    final activeItem = currentSnap.currentItem;
    final activeInThisCue =
        activeItem != null &&
        activeItem.isCueTrack &&
        AudioPlaybackQueueBuilder.normalizeQueuePath(
              activeItem.cueSheetPath ?? '',
            ).toLowerCase() ==
            norm;
    if (activeInThisCue) {
      return;
    }

    final collapsed = AudioPlaybackQueueBuilder.collapseCueTracksInQueue(
      queue: currentSnap.queue,
      currentIndex: currentSnap.currentIndex,
      cueRelativePath: cueRelativePath,
    );
    final updatedExpanded = Set<String>.from(currentSnap.expandedCuePaths)
      ..remove(norm);
    final nextOrder = AudioPlaybackQueueBuilder.buildPlayOrder(
      length: collapsed.queue.length,
      currentIndex: collapsed.newCurrentIndex,
      shuffle: currentSnap.shuffleEnabled,
    );
    final nextOrderPos = collapsed.newCurrentIndex >= 0
        ? nextOrder.indexOf(collapsed.newCurrentIndex)
        : -1;

    _updateSnapshot(
      currentSnap.copyWith(
        queue: collapsed.queue,
        currentIndex: collapsed.newCurrentIndex,
        playOrder: nextOrder,
        playOrderPos: nextOrderPos,
        expandedCuePaths: updatedExpanded,
      ),
    );
  }

  Future<void> _handleNaturalTrackCompletion({
    required bool fromCueBoundary,
  }) async {
    final snap = _snapshotNotifier.value;
    if (snap.audioTrackEndActionPending || snap.queue.isEmpty) return;
    _updateSnapshot(snap.copyWith(audioTrackEndActionPending: true));
    try {
      await _persistPlaybackHistory(force: true, markCompleted: true);

      if (snap.loopMode == AudioLoopMode.loopOne) {
        final item = snap.currentItem;
        if (item != null) {
          await seekRelativeTrackSeconds(0.0);
          if (!_playingNotifier.value) {
            await setPlaying(true);
          }
        }
        return;
      }

      final nextOrderPos = _resolveNextPlayOrderPos(manual: false);
      if (nextOrderPos == null) {
        _cueBoundaryTimer?.cancel();
        _cueBoundaryTimer = null;
        _microFadeDriver.cancel();
        _client?.setPropertyFlag('pause', true);
        _playingNotifier.value = false;
        _updateSnapshot(
          _snapshotNotifier.value.copyWith(
            status: AudioPlaybackStatus.paused,
            audioTrackEndActionPending: false,
          ),
        );
        _reconcileClockObservation();
        return;
      }

      final nextQueueIdx = snap.playOrder[nextOrderPos];
      final currentItem = snap.currentItem;
      final nextItem = snap.queue[nextQueueIdx];

      // 物理连续的同整轨 `.cue` 下一分轨：仅推进逻辑轨代数并刷新标题/时长/歌词，不重开文件流。
      final isContiguousCueStep =
          fromCueBoundary &&
          currentItem != null &&
          AudioPlaybackQueueBuilder.isSamePhysicalStream(
            currentItem,
            nextItem,
          ) &&
          (nextItem.startSeconds - (currentItem.endSeconds ?? 0.0)).abs() <= 0.6;

      if (isContiguousCueStep) {
        _engine.advanceLogicalTrack(resetLyricsDomain: true);
        _positionNotifier.value = Duration.zero;
        _applyLogicalTrackDuration(
          nextItem,
          probedTotalSeconds: _rawDurationSeconds,
        );
        _updateSnapshot(
          _snapshotNotifier.value.copyWith(
            currentIndex: nextQueueIdx,
            playOrderPos: nextOrderPos,
            audioTrackEndActionPending: false,
            clearErrorMessage: true,
          ),
        );
        _armCueBoundaryWatchdog();
        _syncLyricsForActiveTrack();
        _scheduleAuxiliaryLoad(nextItem);
        _syncAndroidMediaSession(forcePosition: true);
        return;
      }

      _updateSnapshot(
        _snapshotNotifier.value.copyWith(
          playOrderPos: nextOrderPos,
          audioTrackEndActionPending: false,
        ),
      );
      await _playQueueIndexInternal(nextQueueIdx, manualSelection: false);
    } finally {
      if (!_disposed && _snapshotNotifier.value.audioTrackEndActionPending) {
        _updateSnapshot(
          _snapshotNotifier.value.copyWith(audioTrackEndActionPending: false),
        );
      }
    }
  }

  Future<void> _handlePhysicalLoadFailure({
    required String message,
    required Object error,
    StackTrace? stackTrace,
  }) async {
    _recordError(
      code: 'AUDIO_PLAYBACK_FAILURE',
      message: message,
      error: error,
      stackTrace: stackTrace,
    );
    final shouldBreak = _engine.recordPhysicalMediaFailure();
    if (!shouldBreak) {
      final nextPos = _resolveNextPlayOrderPos(manual: false);
      if (nextPos != null) {
        final nextQueueIdx = _snapshotNotifier.value.playOrder[nextPos];
        _updateSnapshot(
          _snapshotNotifier.value.copyWith(
            playOrderPos: nextPos,
            errorMessage: '$message，正在尝试下一曲…',
          ),
        );
        await _playQueueIndexInternal(nextQueueIdx, manualSelection: false);
        return;
      }
    }
    _playingNotifier.value = false;
    _reconcileClockObservation();
    _updateSnapshot(
      _snapshotNotifier.value.copyWith(
        status: AudioPlaybackStatus.error,
        isBuffering: false,
        errorMessage: shouldBreak
            ? '连续 ${UnifiedPlaybackEngine.maxConsecutiveBadFiles} 首曲目读取失败，已熔断自动切歌：$message'
            : message,
      ),
    );
  }

  Future<String> _resolveMediaTargetAndBindLease({
    required AudioQueueItem item,
    required bool isPrefetch,
    int? prefetchPlaylistEntryId,
  }) async {
    final physicalPath = AudioPlaybackQueueBuilder.resolvePhysicalMediaPath(item);
    final gateway = await _gatewayFactory.create(item.source);
    if (gateway is LocalSourceGateway) {
      try {
        final absPath = gateway.resolveAbsolutePath(physicalPath);
        return absPath;
      } finally {
        await gateway.close();
      }
    }
    if (gateway is! ByteRangeReadableGateway) {
      await gateway.close();
      throw StateError('媒体源网关不支持按区间流式读取: ${item.source.label}');
    }
    final byteGateway = gateway as ByteRangeReadableGateway;
    final registered = await _streamBridge.registerSession(
      gateway: byteGateway,
      relativePath: physicalPath,
      fileName: item.fileName,
      knownLength: item.knownFileSize,
      ownsGateway: true,
      sourceKind: item.source.kind,
    );
    if (isPrefetch) {
      _prefetchedStreamToken = registered.token;
      final oldPrefetch = _engine.bindPrefetchStreamLease(
        registered.token,
        playlistEntryId: prefetchPlaylistEntryId,
      );
      if (oldPrefetch != null) {
        unawaited(_streamBridge.unregisterSession(oldPrefetch));
      }
    } else {
      final oldMain = _engine.bindMainStreamLease(registered.token);
      if (oldMain != null) {
        unawaited(_streamBridge.unregisterSession(oldMain));
      }
    }
    return registered.url.toString();
  }

  Future<void> _prefetchNextTrackIfPossible() async {
    final snap = _snapshotNotifier.value;
    if (snap.loopMode == AudioLoopMode.loopOne || snap.queue.length <= 1) {
      return;
    }
    final nextOrderPos = _resolveNextPlayOrderPos(manual: false);
    if (nextOrderPos == null) return;
    final nextIdx = snap.playOrder[nextOrderPos];
    final nextItem = snap.queue[nextIdx];
    final currentItem = snap.currentItem;
    if (currentItem == null ||
        nextItem.isUnexpandedCueManifest ||
        AudioPlaybackQueueBuilder.isSamePhysicalStream(currentItem, nextItem)) {
      return;
    }
    if (_prefetchedItemId == nextItem.itemId) return;

    final client = _client;
    if (client == null || client.isDisposed || !client.isInitialized) return;

    _clearPrefetchTracking(releaseBridge: true);
    _prefetchedItemId = nextItem.itemId;

    try {
      final targetUri = await _resolveMediaTargetAndBindLease(
        item: nextItem,
        isPrefetch: true,
      );
      if (_disposed || _prefetchedItemId != nextItem.itemId) return;
      final token = _prefetchedStreamToken;
      if (token != null) {
        unawaited(
          _streamBridge.prewarmSessionMetadata(
            token,
            headBytes: 256 * 1024,
            tailBytes: 128 * 1024,
          ),
        );
      }
      if (_snapshotNotifier.value.currentItem?.endSeconds == null) {
        final appendRc = client.command(<String>['loadfile', targetUri, 'append']);
        if (appendRc >= 0) {
          _expectedAppendPlaylistEntryId =
              (_engine.currentPlaylistEntryId ?? 0) + 1;
        }
      }
    } catch (_) {}
  }

  void _promotePrefetchedTrack({required int playlistEntryId}) {
    final snap = _snapshotNotifier.value;
    final prefetchedId = _prefetchedItemId;
    if (prefetchedId == null) return;
    final targetIdx = snap.queue.indexWhere((q) => q.itemId == prefetchedId);
    if (targetIdx < 0) return;

    final oldMain = _engine.promotePrefetchLeaseToMain(
      playlistEntryId: playlistEntryId,
    );
    if (oldMain != null) {
      unawaited(_streamBridge.unregisterSession(oldMain));
    }
    _clearPrefetchTracking(releaseBridge: false);

    final nextItem = snap.queue[targetIdx];
    final playOrderPos = snap.playOrder.indexOf(targetIdx);
    _positionNotifier.value = Duration.zero;
    _applyLogicalTrackDuration(nextItem);

    _updateSnapshot(
      snap.copyWith(
        currentIndex: targetIdx,
        playOrderPos: playOrderPos >= 0 ? playOrderPos : snap.playOrderPos,
        clearErrorMessage: true,
      ),
    );
    _syncLyricsForActiveTrack();
    _scheduleAuxiliaryLoad(nextItem);
    _syncAndroidMediaSession(forcePosition: true);
  }

  void _clearPrefetchTracking({required bool releaseBridge}) {
    if (releaseBridge) {
      final oldPrefetch = _engine.releasePrefetchLease();
      if (oldPrefetch != null) {
        unawaited(_streamBridge.unregisterSession(oldPrefetch));
      } else if (_prefetchedStreamToken != null) {
        unawaited(_streamBridge.unregisterSession(_prefetchedStreamToken!));
      }
    }
    _prefetchedItemId = null;
    _prefetchedStreamToken = null;
    _expectedAppendPlaylistEntryId = null;
  }

  int? _resolveNextPlayOrderPos({required bool manual}) {
    final snap = _snapshotNotifier.value;
    if (snap.playOrder.isEmpty) return null;
    final currentPos = snap.playOrderPos >= 0 ? snap.playOrderPos : 0;
    if (snap.loopMode == AudioLoopMode.loopOne && manual) {
      return (currentPos + 1) % snap.playOrder.length;
    }
    if (currentPos + 1 < snap.playOrder.length) {
      return currentPos + 1;
    }
    if (snap.loopMode == AudioLoopMode.loopAll ||
        (manual && snap.loopMode == AudioLoopMode.loopOne)) {
      return 0;
    }
    return null;
  }

  int? _resolvePreviousPlayOrderPos() {
    final snap = _snapshotNotifier.value;
    if (snap.playOrder.isEmpty) return null;
    final currentPos = snap.playOrderPos >= 0 ? snap.playOrderPos : 0;
    if (currentPos - 1 >= 0) {
      return currentPos - 1;
    }
    if (snap.loopMode == AudioLoopMode.loopAll) {
      return snap.playOrder.length - 1;
    }
    return null;
  }

  void _applyVolumeWithSafetyFade({
    required LibMpvClient client,
    required AudioSafetyChainPlan plan,
    required bool useMicroFade,
  }) {
    final targetVolume = _snapshotNotifier.value.volume;
    final isMuted = _snapshotNotifier.value.isMuted;
    client.setPropertyFlag('mute', isMuted);
    if (isMuted) return;

    if (useMicroFade &&
        !plan.safetyLimiterEngaged &&
        plan.microFadeInDurationMs > 0) {
      final aliveEpoch = _engine.physicalMediaEpoch;
      _microFadeDriver.start(
        client: client,
        plan: plan,
        targetVolume: targetVolume,
        isMuted: isMuted,
        isAlive: () =>
            !_disposed &&
            _playingNotifier.value &&
            _engine.physicalMediaEpoch == aliveEpoch,
      );
      return;
    }
    _microFadeDriver.cancel();
    client.setPropertyDouble('volume', targetVolume);
  }

  void _applyReplayGainOptions({
    required LibMpvClient client,
    required AudioPlaybackPrefsData prefs,
    required AudioSafetyChainPlan plan,
  }) {
    if (plan.routeMode == AudioOutputRouteMode.bitstreamPassthrough) {
      client.setPropertyString('replaygain', 'no');
      return;
    }
    final rgMode = switch (prefs.replayGainMode) {
      AudioReplayGainMode.none => 'no',
      AudioReplayGainMode.track => 'track',
      AudioReplayGainMode.album => 'album',
    };
    client.setPropertyString('replaygain', rgMode);
    final clampedPreamp =
        (prefs.audiophileSafetyLimiterEnabled && !plan.safetyLimiterEngaged)
        ? math.min(0.0, prefs.replayGainPreampDb)
        : prefs.replayGainPreampDb;
    client.setPropertyDouble('replaygain-preamp', clampedPreamp);
  }

  void _applyLogicalTrackDuration(
    AudioQueueItem item, {
    double? probedTotalSeconds,
  }) {
    double dur = item.durationSeconds;
    if (item.endSeconds != null && item.endSeconds! > item.startSeconds) {
      dur = item.endSeconds! - item.startSeconds;
    } else if (probedTotalSeconds != null && probedTotalSeconds > 0) {
      dur = math.max(0.0, probedTotalSeconds - item.startSeconds);
    }
    if (dur > 0) {
      _durationNotifier.value = Duration(milliseconds: (dur * 1000.0).round());
    }
  }

  void _refreshAudioStreamMetadataFromClient() {
    final client = _client;
    if (client == null || client.isDisposed || !client.isInitialized) return;
    final sr = client.getPropertyInt64('audio-params/samplerate') ?? 0;
    final fmt = client.getPropertyString('audio-params/format') ?? '';
    final depth = _parseAudioBitDepthFromFormat(fmt);
    final ch = client.getPropertyInt64('audio-params/channel-count') ?? 0;
    final codec = client.getPropertyString('audio-codec-name') ?? '';
    final bps = client.getPropertyInt64('audio-bitrate') ?? 0;
    _updateSnapshot(
      _snapshotNotifier.value.copyWith(
        sampleRateHz: sr > 0 ? sr : _snapshotNotifier.value.sampleRateHz,
        bitDepth: depth > 0 ? depth : _snapshotNotifier.value.bitDepth,
        channelCount: ch > 0 ? ch : _snapshotNotifier.value.channelCount,
        audioCodecName: codec.isNotEmpty
            ? codec
            : _snapshotNotifier.value.audioCodecName,
        bitrateKbps: bps > 0
            ? (bps / 1000.0).round()
            : _snapshotNotifier.value.bitrateKbps,
      ),
    );
  }
}
