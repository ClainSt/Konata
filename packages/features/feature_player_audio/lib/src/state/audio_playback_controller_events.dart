part of 'audio_playback_controller.dart';

extension _AudioPlaybackControllerEvents on AudioPlaybackController {
  Future<LibMpvClient?> _ensureExclusiveClient({
    required bool isRemoteStream,
    required AudioPlaybackPrefsData prefs,
  }) async {
    final existing = _client;
    if (existing != null && !existing.isDisposed && existing.isInitialized) {
      return existing;
    }

    final lease = await _engine.acquireExclusiveNativeClient(
      stage: PlaybackStageKind.audio,
      factoryOverride: _mpvClientFactoryOverride,
      onEvicted: () async {
        await _releaseCurrentClient(fromEviction: true);
      },
    );
    if (_disposed) {
      await _engine.releaseNativeClient(lease.client);
      return null;
    }

    final client = lease.client;
    _client = client;
    _clientNativeInstanceId = lease.nativeInstanceId;

    Directory configDir;
    if (_storageRoot != null) {
      configDir = await PlaybackStoragePaths.ensureMpvConfigDir(_storageRoot);
    } else {
      configDir = Directory.systemTemp;
    }

    MpvQualityProfile.applyPreInitAudioOptions(
      client,
      config: prefs.toAudiophilePreferences().qualityConfig,
      mpvConfigDir: configDir,
      isRemoteStream: isRemoteStream,
      isWindowsOverride: _isWindowsOverride,
      desktopDelegate: _desktopMpvDelegate,
      logStore: _logPort,
    );
    client.setOptionString(
      'demuxer-lavf-o',
      MpvQualityProfile.remoteStreamLavfOptions,
    );

    final initRc = client.initialize();
    if (initRc < 0) {
      await _releaseCurrentClient();
      throw StateError('音频内核初始化失败 ($initRc: ${client.errorString(initRc)})');
    }

    _attachClientListeners(client);
    await refreshAudioDevices();
    return client;
  }

  void _attachClientListeners(LibMpvClient client) {
    unawaited(_clientEventSub?.cancel());
    _clientEventSub = null;
    _timePosObserved = false;
    _timePosObserveId = null;
    client.observeProperty(_allocateObserveId(), 'duration', MpvFormat.double_);
    client.observeProperty(
      _allocateObserveId(),
      'core-idle',
      MpvFormat.flag,
    );
    client.observeProperty(
      _allocateObserveId(),
      'audio-params/samplerate',
      MpvFormat.int64,
    );
    client.observeProperty(
      _allocateObserveId(),
      'audio-params/format',
      MpvFormat.string,
    );
    client.observeProperty(
      _allocateObserveId(),
      'audio-params/channel-count',
      MpvFormat.int64,
    );
    client.observeProperty(
      _allocateObserveId(),
      'audio-codec-name',
      MpvFormat.string,
    );
    client.observeProperty(
      _allocateObserveId(),
      'audio-bitrate',
      MpvFormat.int64,
    );

    _clientEventSub = client.events.listen(_handleMpvEvent);
    _reconcileClockObservation();
  }

  int _allocateObserveId() => _nextObserveId++;

  void _reconcileClockObservation() {
    final client = _client;
    if (client == null || client.isDisposed || !client.isInitialized) {
      _timePosObserved = false;
      _cueBoundaryTimer?.cancel();
      _cueBoundaryTimer = null;
      return;
    }
    final shouldObserve =
        _playingNotifier.value && !_progressObservationHidden;
    if (shouldObserve && !_timePosObserved) {
      final obsId = _allocateObserveId();
      _timePosObserveId = obsId;
      client.observeProperty(obsId, 'time-pos', MpvFormat.double_);
      _timePosObserved = true;
    } else if (!shouldObserve && _timePosObserved) {
      if (client is LibMpvUnobservable && _timePosObserveId != null) {
        (client as LibMpvUnobservable).unobserveProperty(_timePosObserveId!);
      }
      _timePosObserved = false;
      _timePosObserveId = null;
    }
    if (!_playingNotifier.value) {
      _cueBoundaryTimer?.cancel();
      _cueBoundaryTimer = null;
    }
  }

  Future<void> _releaseCurrentClient({bool fromEviction = false}) async {
    _cueBoundaryTimer?.cancel();
    _cueBoundaryTimer = null;
    _microFadeDriver.cancel();
    await _clientEventSub?.cancel();
    _clientEventSub = null;
    _timePosObserved = false;
    _timePosObserveId = null;

    final client = _client;
    _client = null;
    _clientNativeInstanceId = 0;
    if (client != null) {
      await _engine.releaseNativeClient(client);
    }
    if (fromEviction && !_disposed) {
      _playingNotifier.value = false;
      _updateSnapshot(
        _snapshotNotifier.value.copyWith(
          status: AudioPlaybackStatus.paused,
          isBuffering: false,
        ),
      );
    }
  }

  void _handleMpvEvent(MpvClientEvent event) {
    if (_disposed) return;
    switch (event) {
      case MpvStartFileEvent(:final playlistEntryId):
        if (_expectedAppendPlaylistEntryId != null &&
            playlistEntryId == _expectedAppendPlaylistEntryId) {
          _promotePrefetchedTrack(playlistEntryId: playlistEntryId);
        } else {
          _engine.bindPlaylistEntryId(playlistEntryId);
        }
      case MpvFileLoadedEvent():
        _engine.recordFileLoaded();
        _updateSnapshot(_snapshotNotifier.value.copyWith(isBuffering: false));
        unawaited(_prefetchNextTrackIfPossible());
      case MpvAudioReconfigEvent():
        _refreshAudioStreamMetadataFromClient();
      case MpvEndFileEvent(:final reason, :final errorCode):
        _onMpvEndFile(reason: reason, errorCode: errorCode);
      case MpvPropertyChangeEvent():
        _onMpvPropertyChange(event);
      case MpvLogMessageEvent(:final level, :final text):
        if (level == 'error' || level == 'fatal') {
          _recordLog(
            code: 'AUDIO_MPV_INTERNAL_LOG',
            message: text,
            severity: DiagnosticSeverity.warn,
          );
        }
      default:
        break;
    }
  }

  void _onMpvPropertyChange(MpvPropertyChangeEvent event) {
    final client = _client;
    if (client == null || client.isDisposed) return;

    switch (event.name) {
      case 'time-pos':
        final rawSec = event.doubleValue;
        if (rawSec != null && rawSec.isFinite) {
          _onTimePosUpdate(rawSec);
        }
      case 'duration':
        final rawDur = event.doubleValue;
        if (rawDur != null && rawDur.isFinite && rawDur > 0) {
          _rawDurationSeconds = rawDur;
          final currentItem = _snapshotNotifier.value.currentItem;
          if (currentItem != null) {
            _applyLogicalTrackDuration(currentItem, probedTotalSeconds: rawDur);
          }
        }
      case 'core-idle':
        final idle = event.boolValue;
        if (idle != null && _snapshotNotifier.value.isBuffering != idle) {
          _updateSnapshot(
            _snapshotNotifier.value.copyWith(
              isBuffering: idle && _playingNotifier.value,
            ),
          );
        }
      case 'audio-params/samplerate':
        final sr = event.intValue;
        if (sr != null && sr > 0 && sr != _snapshotNotifier.value.sampleRateHz) {
          _updateSnapshot(
            _snapshotNotifier.value.copyWith(sampleRateHz: sr),
          );
        }
      case 'audio-params/format':
        final fmt = event.stringValue ?? '';
        final depth = _parseAudioBitDepthFromFormat(fmt);
        if (depth > 0 && depth != _snapshotNotifier.value.bitDepth) {
          _updateSnapshot(_snapshotNotifier.value.copyWith(bitDepth: depth));
        }
      case 'audio-params/channel-count':
        final ch = event.intValue;
        if (ch != null && ch > 0 && ch != _snapshotNotifier.value.channelCount) {
          _updateSnapshot(
            _snapshotNotifier.value.copyWith(channelCount: ch),
          );
        }
      case 'audio-codec-name':
        final codec = event.stringValue ?? '';
        if (codec.isNotEmpty &&
            codec != _snapshotNotifier.value.audioCodecName) {
          _updateSnapshot(
            _snapshotNotifier.value.copyWith(audioCodecName: codec),
          );
        }
      case 'audio-bitrate':
        final bps = event.intValue;
        if (bps != null && bps > 0) {
          final kbps = (bps / 1000.0).round();
          if (kbps != _snapshotNotifier.value.bitrateKbps) {
            _updateSnapshot(
              _snapshotNotifier.value.copyWith(bitrateKbps: kbps),
            );
          }
        }
    }
  }

  void _onTimePosUpdate(double rawSec) {
    final deltaMs = ((rawSec - _lastConfirmedAudioPosSeconds).abs() * 1000.0)
        .round();
    if (_playingNotifier.value && deltaMs > 0) {
      _engine.recordEffectiveProgress(audioAdvancedMs: deltaMs);
      _lastConfirmedAudioPosSeconds = rawSec;
    }

    final currentItem = _snapshotNotifier.value.currentItem;
    if (currentItem == null) return;

    final relPos = math.max(0.0, rawSec - currentItem.startSeconds);
    final trackDur = currentTrackDurationSeconds;
    final clampedRel = trackDur > 0 ? relPos.clamp(0.0, trackDur) : relPos;
    _positionNotifier.value = Duration(
      milliseconds: (clampedRel * 1000.0).round(),
    );

    final endSec = currentItem.endSeconds;
    if (endSec != null &&
        _playingNotifier.value &&
        rawSec >= (endSec - 0.04) &&
        !_snapshotNotifier.value.audioTrackEndActionPending) {
      unawaited(_handleNaturalTrackCompletion(fromCueBoundary: true));
      return;
    }

    final now = DateTime.now();
    if (_lastHistoryPersistAt == null ||
        now.difference(_lastHistoryPersistAt!).inSeconds >= 10) {
      unawaited(_persistPlaybackHistory(force: false));
    }
    if (_lastMediaSessionSyncAt == null ||
        now.difference(_lastMediaSessionSyncAt!).inSeconds >= 3) {
      _syncAndroidMediaSession();
    }
  }

  void _armCueBoundaryWatchdog() {
    _cueBoundaryTimer?.cancel();
    _cueBoundaryTimer = null;
    final item = _snapshotNotifier.value.currentItem;
    if (item == null || item.endSeconds == null || !_playingNotifier.value) {
      return;
    }
    _cueBoundaryTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (_disposed || !_playingNotifier.value) {
        _cueBoundaryTimer?.cancel();
        _cueBoundaryTimer = null;
        return;
      }
      final client = _client;
      if (client == null || client.isDisposed) return;
      final cur = client.getPropertyDouble('time-pos');
      if (cur != null && cur.isFinite) {
        _onTimePosUpdate(cur);
      }
    });
  }

  void _onMpvEndFile({required int reason, required int errorCode}) {
    if (reason == MpvEndFileReason.stop || reason == MpvEndFileReason.quit) {
      return;
    }
    if (reason == MpvEndFileReason.error || errorCode < 0) {
      final snap = _snapshotNotifier.value;
      final item = snap.currentItem;
      final token = _engine.mainStreamLease?.leaseToken;
      final bridgeMsg = token != null
          ? _streamBridge.describeLastError(
              token: token,
              relativePath: item?.relativePath,
            )
          : null;
      unawaited(
        _handlePhysicalLoadFailure(
          message: bridgeMsg ?? '音频播放遇到解码或网络读取异常',
          error: StateError('mpv end-file errorCode=$errorCode'),
        ),
      );
      return;
    }
    if (reason == MpvEndFileReason.eof) {
      unawaited(_handleNaturalTrackCompletion(fromCueBoundary: false));
    }
  }

}

int _parseAudioBitDepthFromFormat(String format) {
  final lower = format.trim().toLowerCase();
  if (lower.contains('s32') ||
      lower.contains('flt') ||
      lower.contains('dbl')) {
    return lower.contains('dbl') ? 64 : 32;
  }
  if (lower.contains('s24')) return 24;
  if (lower.contains('s16')) return 16;
  if (lower.contains('u8') || lower.contains('s8')) return 8;
  return 0;
}
