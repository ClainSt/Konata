part of 'audio_playback_notifier.dart';

/// `AudioPlaybackNotifier` 底层流装填、主流/预取租约晋升、四维事件过滤与熔断恢复扩展。
extension AudioPlaybackTransport on AudioPlaybackNotifier {
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
    if (index < 0 || index >= _state.queue.length || !mounted) return;
    if (!isRetryAttempt) {
      _trackRetryCount = 0;
    }
    final previousItem = previousItemOverride ?? _state.currentItem;
    final reconciledIndex = await _reconcileCueWindowForTarget(
      index,
      generation: generation,
      selectLastOnExpand: selectLastOnCueExpand,
    );
    if (reconciledIndex == null ||
        reconciledIndex < 0 ||
        reconciledIndex >= _state.queue.length ||
        generation != _loadGeneration ||
        !mounted) {
      return;
    }
    index = reconciledIndex;
    final item = _state.queue[index];
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

    _state = _state.copyWith(
      isActive: true,
      currentIndex: index,
      isBuffering: !canSeekInsideLoadedCue,
      positionSeconds: clampedInitialOffset,
      durationSeconds: initialDuration,
      activeLyricIndex: -1,
      clearLrcDocument: true,
      cover: initialCover,
      audioCodecLabel: canSeekInsideLoadedCue ? _state.audioCodecLabel : '',
      sampleRateAndBitDepthLabel: canSeekInsideLoadedCue
          ? _state.sampleRateAndBitDepthLabel
          : '',
      bitrateLabel: canSeekInsideLoadedCue ? _state.bitrateLabel : '',
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
          logStore: _logStore,
        );
        _pendingSeekRawTargetSeconds = start;
        _pendingSeekGuardUntil = DateTime.now().add(
          AudioPlaybackNotifier._cueSeekDebounceWindow,
        );
        client.setPropertyFlag('pause', false);
        client.command(['seek', start.toStringAsFixed(3), 'absolute', 'exact']);
        _syncAudioSpecBadges();
        if (mounted) {
          final lyricIdx =
              _state.lrcDocument?.activeIndexAt(clampedInitialOffset) ?? -1;
          _state = _state.copyWith(
            isBuffering: false,
            isPlaying: true,
            positionSeconds: clampedInitialOffset,
            activeLyricIndex: lyricIdx,
          );
          _startMicroFadeInRamp(client);
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

      // 若下一曲已完成远程流预取租约且物理键命中，则原子晋升预取租约为主流（零重注册）；
      // 否则先释放旧预取租约再注册目标主流。
      final prefetched = _prefetchedNextTrack;
      final hitPrefetch =
          !isRetryAttempt &&
          prefetched != null &&
          prefetched.physicalFileKey == physicalKey;
      final ({String target, String? streamToken}) resolved;
      String? displacedMainToken;

      if (hitPrefetch) {
        _prefetchedNextTrack = null;
        resolved = (
          target: prefetched.target,
          streamToken: prefetched.streamToken,
        );
        displacedMainToken = _engine.promotePrefetchLeaseToMain();
        _boundPhysicalEpoch = _engine.physicalMediaEpoch;
      } else {
        await _releasePrefetchLeaseIfAny();
        resolved = await _resolvePlaybackTarget(item);
        if (generation != _loadGeneration || !mounted) {
          if (resolved.streamToken != null) {
            unawaited(_unregisterStreamToken(resolved.streamToken!));
          }
          return;
        }
        _boundPhysicalEpoch = _engine.beginPhysicalMedia(
          nativeInstanceId: _boundNativeInstanceId,
        );
        final previousActive = _activeStreamToken;
        if (resolved.streamToken != null) {
          displacedMainToken =
              _engine.bindMainStreamLease(resolved.streamToken!) ??
              previousActive;
        } else {
          displacedMainToken = previousActive;
        }
      }

      MpvQualityProfile.applyRuntimeStreamProfile(
        client,
        isRemoteStream: isRemote,
        isAudio: true,
        config: _ref.read(playbackPreferencesProvider).qualityConfig,
        logStore: _logStore,
      );

      _activeStreamToken = resolved.streamToken;
      if (_currentMpvPlaylistEntryId > _retiredMpvPlaylistEntryId) {
        _retiredMpvPlaylistEntryId = _currentMpvPlaylistEntryId;
      }
      _loadedPhysicalKey = physicalKey;
      _activeCommandedGeneration = generation;
      _trackProgressBaselineSeconds = clampedInitialOffset;
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
      if (displacedMainToken != null &&
          displacedMainToken != resolved.streamToken) {
        unawaited(_unregisterStreamToken(displacedMainToken));
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

  /// 当前远程音轨装载成功后，按独立预取租约静默准备下一物理文件（严禁覆盖当前主流租约）。
  Future<void> _scheduleGaplessNextTrackPrefetch({
    required int generation,
  }) async {
    if (!mounted || !_state.isActive || generation != _loadGeneration) return;
    if (_state.loopMode == AudioLoopMode.loopOne || _state.queue.length < 2) {
      return;
    }
    final nextIdx = _state.currentIndex + 1 < _state.queue.length
        ? _state.currentIndex + 1
        : (_state.loopMode == AudioLoopMode.loopAll ? 0 : -1);
    if (nextIdx < 0 || nextIdx >= _state.queue.length) return;
    final current = _state.currentItem;
    final nextItem = _state.queue[nextIdx];
    if (current == null || nextItem.physicalFileKey == current.physicalFileKey) {
      return;
    }
    final nextSource = nextItem.source;
    if (nextSource == null || nextSource.kind == MediaSourceKind.local) {
      return;
    }
    if (_prefetchedNextTrack?.physicalFileKey == nextItem.physicalFileKey) {
      return;
    }
    try {
      final resolved = await _resolvePlaybackTarget(nextItem);
      if (!mounted ||
          !_state.isActive ||
          generation != _loadGeneration ||
          resolved.streamToken == null) {
        if (resolved.streamToken != null) {
          unawaited(_unregisterStreamToken(resolved.streamToken!));
        }
        return;
      }
      final displacedPrefetch = _engine.bindPrefetchStreamLease(
        resolved.streamToken!,
      );
      _prefetchedNextTrack = (
        physicalFileKey: nextItem.physicalFileKey,
        target: resolved.target,
        streamToken: resolved.streamToken!,
      );
      if (displacedPrefetch != null &&
          displacedPrefetch != resolved.streamToken) {
        unawaited(_unregisterStreamToken(displacedPrefetch));
      }
    } catch (e) {
      _logStore.record('AUDIO', '预取下一远程曲目流租约忽略：$e');
    }
  }

  Future<void> _releasePrefetchLeaseIfAny() async {
    final prefetched = _prefetchedNextTrack;
    _prefetchedNextTrack = null;
    final released = _engine.releasePrefetchLease() ?? prefetched?.streamToken;
    if (released != null && released != _activeStreamToken) {
      await _unregisterStreamToken(released);
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
    final reg = await _streamBridge.registerSession(
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
      await _streamBridge.unregisterSession(token);
    } catch (e) {
      _logStore.record('AUDIO', '注销音频流令牌 $token 失败：$e');
    }
  }

  Future<void> _releaseActiveStreamSession() async {
    final token = _activeStreamToken;
    _activeStreamToken = null;
    final prefetched = _prefetchedNextTrack;
    _prefetchedNextTrack = null;
    final tokens = <String>{
      ?token,
      ?prefetched?.streamToken,
      ..._engine.resetSession(),
    };
    for (final t in tokens) {
      await _unregisterStreamToken(t);
    }
  }

  void _applyRawFileDuration(double rawDur) {
    if (rawDur <= 0 || !mounted) return;
    _rawFileDurationSeconds = rawDur;
    final loadedKey = _loadedPhysicalKey ?? _state.currentItem?.physicalFileKey;
    if (loadedKey != null) {
      _rawDurationByPhysicalKey[loadedKey] = rawDur;
    }

    var queueChanged = false;
    final updatedQueue = <AudioQueueItem>[
      for (final q in _state.queue)
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

    final current = _state.currentItem;
    double nextDurationSeconds = _state.durationSeconds;
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

    if (queueChanged || nextDurationSeconds != _state.durationSeconds) {
      _state = _state.copyWith(
        queue: queueChanged ? updatedQueue : _state.queue,
        durationSeconds: nextDurationSeconds,
      );
    }
  }

  void _handleMpvEvent(MpvClientEvent event) {
    if (!mounted) return;
    switch (event) {
      case MpvStartFileEvent(:final playlistEntryId):
        if (playlistEntryId > 0) {
          _currentMpvPlaylistEntryId = playlistEntryId;
          _engine.bindPlaylistEntryId(playlistEntryId);
        }
      case MpvFileLoadedEvent():
        if (!_engine.matchesPhysicalEvent(
          physicalMediaEpoch: _boundPhysicalEpoch,
          nativeInstanceId: _boundNativeInstanceId,
        )) {
          return;
        }
        // CUE 起始偏移已在 loadfile 前通过 mpv `start` 属性直达起播，加载完成后复位避免切曲串台。
        // 严禁在 FILE_LOADED 提前清零连续坏文件熔断计数，仅在证实有效音频推进 >= 500ms 或手动点选时清零。
        _client?.setPropertyString('start', 'none');
        _trackRetryCount = 0;
        _engine.recordFileLoaded();
        _state = _state.copyWith(isBuffering: false, isPlaying: true);
        if (_client != null && !_client!.isDisposed) {
          _startMicroFadeInRamp(_client!);
        }
        _refreshProbeFromClient();
        final auxJob = _pendingRemoteAuxJob;
        if (auxJob != null && auxJob.generation == _loadGeneration) {
          _pendingRemoteAuxJob = null;
          unawaited(
            _loadAuxiliaryAssets(auxJob.item, generation: auxJob.generation),
          );
        }
        unawaited(
          _scheduleGaplessNextTrackPrefetch(generation: _loadGeneration),
        );
      case MpvAudioReconfigEvent():
      case MpvPlaybackRestartEvent():
        if (!_engine.matchesPhysicalEvent(
          physicalMediaEpoch: _boundPhysicalEpoch,
          nativeInstanceId: _boundNativeInstanceId,
        )) {
          return;
        }
        _suppressBufferingUntil = null;
        _state = _state.copyWith(isBuffering: false);
        _refreshProbeFromClient();
      case MpvPropertyChangeEvent():
        _handlePropertyChange(event);
      case MpvEndFileEvent():
        _handleEndFile(event);
      case MpvLogMessageEvent():
        final lvl = event.level.toLowerCase();
        if (lvl == 'error' || lvl == 'fatal') {
          _logStore.record(
            'mpv-audio',
            '[${event.prefix}] ${event.text.trim()}',
            isError: true,
          );
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
      case AudioPlaybackNotifier._propTimePos:
        final rawPos = e.doubleValue;
        if (rawPos == null) return;
        _updateTrackProgress(rawPos);
      case AudioPlaybackNotifier._propDuration:
        final rawDur = e.doubleValue;
        if (rawDur == null || rawDur <= 0) return;
        _applyRawFileDuration(rawDur);
      case AudioPlaybackNotifier._propPause:
        final paused = e.boolValue;
        if (paused != null) {
          _state = _state.copyWith(isPlaying: !paused);
        }
      case AudioPlaybackNotifier._propCoreIdle:
        final idle = e.boolValue ?? false;
        if (idle && (_client?.getPropertyFlag('eof-reached') ?? false)) {
          _onNaturalTrackEofReached();
          return;
        }
        final suppressed =
            _suppressBufferingUntil != null &&
            DateTime.now().isBefore(_suppressBufferingUntil!);
        _state = _state.copyWith(
          isBuffering:
              !suppressed &&
              _state.isPlaying &&
              idle &&
              _loadedPhysicalKey != null,
        );
      case AudioPlaybackNotifier._propAudioCodec:
        _rawCodec = e.stringValue ?? '';
        _syncAudioSpecBadges();
      case AudioPlaybackNotifier._propSampleRate:
        _rawSampleRateHz = e.intValue;
        _syncAudioSpecBadges();
      case AudioPlaybackNotifier._propAudioFormat:
        _rawAudioFormat = e.stringValue ?? '';
        _syncAudioSpecBadges();
      case AudioPlaybackNotifier._propAudioBitrate:
        final bps = e.intValue;
        _state = _state.copyWith(
          bitrateLabel: bps != null && bps > 0
              ? PlaybackFormatters.formatBitrate(bps)
              : '',
        );
      case AudioPlaybackNotifier._propEofReached:
        final eof = e.boolValue ?? false;
        if (eof) {
          _onNaturalTrackEofReached();
        }
      case AudioPlaybackNotifier._propAudioDeviceList:
      case AudioPlaybackNotifier._propAudioDevice:
        final client = _client;
        if (client != null && !client.isDisposed && client.isInitialized) {
          _safetyCoordinator.handleWindowsAudioDevicesChanged(
            devices: client.readAudioDeviceList(),
            currentAudioDevice: client.getPropertyString('audio-device'),
          );
        }
    }
  }

  void _updateTrackProgress(double rawPositionSeconds) {
    final item = _state.currentItem;
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
      if (!_state.isPlaying) {
        return;
      }
      final nextIdx = _state.currentIndex + 1;
      final canNaturalCueStep =
          _state.loopMode != AudioLoopMode.loopOne &&
          nextIdx < _state.queue.length &&
          _state.queue[nextIdx].physicalFileKey == item.physicalFileKey &&
          _state.queue[nextIdx].isCueTrack &&
          ((_state.queue[nextIdx].cueStartSeconds ?? 0.0) - cueEnd).abs() <= 0.5;
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

    final relPos = _state.durationSeconds > 0
        ? (rawPositionSeconds - cueStart).clamp(0.0, _state.durationSeconds)
        : math.max(0.0, rawPositionSeconds - cueStart);
    final advancedMs = ((relPos - _trackProgressBaselineSeconds) * 1000)
        .round();
    if (advancedMs >= UnifiedPlaybackEngine.effectiveAudioProgressThresholdMs) {
      if (_engine.recordEffectiveProgress(audioAdvancedMs: advancedMs)) {
        _consecutiveFailedTracks = 0;
      }
    }
    final lyricIdx = _state.lrcDocument?.activeIndexAt(relPos) ?? -1;
    _state = _state.copyWith(positionSeconds: relPos, activeLyricIndex: lyricIdx);
    unawaited(
      _persistAudioProgress(
        item,
        positionSeconds: relPos,
        durationSeconds: _state.durationSeconds,
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
        positionSeconds: _state.durationSeconds,
        durationSeconds: _state.durationSeconds,
        completed: true,
        force: true,
      ),
    );
    final nextItem = _state.queue[nextIndex];
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

    _state = _state.copyWith(
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

  /// 统一按当前活跃装填世代与 `UnifiedPlaybackEngine` 校验去重处理音轨自然完播。
  void _onNaturalTrackEofReached({int playlistEntryId = 0}) {
    if (!mounted || !_state.isActive) return;
    if (!_engine.matchesPhysicalEvent(
      physicalMediaEpoch: _boundPhysicalEpoch,
      nativeInstanceId: _boundNativeInstanceId,
      playlistEntryId: playlistEntryId > 0 ? playlistEntryId : null,
    )) {
      return;
    }
    if (playlistEntryId > 0) {
      if (playlistEntryId <= _retiredMpvPlaylistEntryId) return;
      if (playlistEntryId == _eofHandledMpvEntryId) return;
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
    if (!_engine.matchesPhysicalEvent(
      physicalMediaEpoch: _boundPhysicalEpoch,
      nativeInstanceId: _boundNativeInstanceId,
      playlistEntryId: event.playlistEntryId > 0 ? event.playlistEntryId : null,
    )) {
      return;
    }
    if (event.reason == MpvEndFileReason.eof) {
      _onNaturalTrackEofReached(playlistEntryId: event.playlistEntryId);
    } else if (event.reason == MpvEndFileReason.error) {
      if (event.playlistEntryId > 0 &&
          event.playlistEntryId <= _retiredMpvPlaylistEntryId) {
        return;
      }
      if (_activeCommandedGeneration <= 0 ||
          _activeCommandedGeneration != _loadGeneration) {
        return;
      }
      _loadedPhysicalKey = null;
      _isTransitioningCueBoundary = false;
      _client?.setPropertyString('start', 'none');
      final curItem = _state.currentItem;
      final bridgeDiag = _streamBridge.describeLastError(
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

  /// 处理单曲装填或解复用异常：对偶发错误最多静默重试 3 次，连续 3 首物理坏文件立即熔断停播。
  Future<void> _handleTrackLoadFailure({
    required int generation,
    required AudioQueueItem? failedItem,
    required String reasonMessage,
    required bool retryable,
  }) async {
    if (!mounted || !_state.isActive || generation != _loadGeneration) {
      return;
    }

    if (retryable &&
        _trackRetryCount < AudioPlaybackNotifier.maxSilentRetries &&
        _state.currentIndex >= 0 &&
        _state.currentIndex < _state.queue.length) {
      final attempt = ++_trackRetryCount;
      final delay = retryDelayBuilder != null
          ? retryDelayBuilder!(attempt)
          : (Platform.environment.containsKey('FLUTTER_TEST')
                ? Duration.zero
                : Duration(milliseconds: 120 * attempt));
      if (delay > Duration.zero) {
        await Future<void>.delayed(delay);
      }
      if (!mounted || !_state.isActive || generation != _loadGeneration) {
        return;
      }
      final retryGen = ++_loadGeneration;
      await _startTrackAtIndex(
        _state.currentIndex,
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
        (_state.cover is EmptyAudioCover && failedItem != null)
        ? _resolvePosterFallback(failedItem.work)
        : _state.cover;

    final rawNextIdx = _state.currentIndex + 1;
    final canAdvance =
        !circuitBreakerTripped &&
        _state.queue.length > 1 &&
        _consecutiveFailedTracks < _state.queue.length &&
        (rawNextIdx < _state.queue.length ||
            _state.loopMode == AudioLoopMode.loopAll);

    if (canAdvance) {
      final targetIdx = rawNextIdx % _state.queue.length;
      final titlePrefix = (failedItem != null && failedItem.title.isNotEmpty)
          ? '「${failedItem.title}」'
          : '当前曲目';
      _state = _state.copyWith(
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
      _state = _state.copyWith(
        isPlaying: false,
        isBuffering: false,
        cover: fallbackCover,
        errorMessage:
            '连续 ${UnifiedPlaybackEngine.maxConsecutiveBadFiles} 个音频文件加载异常（$reasonMessage），已熔断停播',
      );
      return;
    }

    _state = _state.copyWith(
      isPlaying: false,
      isBuffering: false,
      cover: fallbackCover,
      errorMessage: reasonMessage,
    );
  }

  Future<void> _advanceOnTrackCompleted() async {
    if (!mounted || _state.queue.isEmpty || !_state.isActive) return;
    final finishedItem = _state.currentItem;
    final finishedDuration = _state.durationSeconds > 0
        ? _state.durationSeconds
        : _state.positionSeconds;
    if (finishedItem != null) {
      unawaited(
        _persistAudioProgress(
          finishedItem,
          positionSeconds: finishedDuration,
          durationSeconds: _state.durationSeconds,
          completed: true,
          force: true,
        ),
      );
    }
    if (_state.loopMode == AudioLoopMode.loopOne) {
      final currentIdx = _state.currentIndex;
      if (currentIdx >= 0 && currentIdx < _state.queue.length) {
        final gen = ++_loadGeneration;
        await _startTrackAtIndex(currentIdx, generation: gen);
      }
      return;
    }
    final nextIdx = _state.currentIndex + 1;
    if (nextIdx < _state.queue.length) {
      final gen = ++_loadGeneration;
      await _startTrackAtIndex(nextIdx, generation: gen);
    } else if (_state.loopMode == AudioLoopMode.loopAll) {
      final gen = ++_loadGeneration;
      await _startTrackAtIndex(0, generation: gen);
    } else {
      _isTransitioningCueBoundary = false;
      final c = _client;
      if (c != null && !c.isDisposed) {
        c.setPropertyFlag('pause', true);
      }
      if (mounted) {
        _state = _state.copyWith(
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
    _state = _state.copyWith(
      audioCodecLabel: codecShort,
      sampleRateAndBitDepthLabel: summary,
      bitrateLabel: bitrateBps != null && bitrateBps > 0
          ? PlaybackFormatters.formatBitrate(bitrateBps)
          : _state.bitrateLabel,
    );
  }
}
