part of 'audio_playback_controller.dart';

extension _AudioPlaybackControllerSafety on AudioPlaybackController {
  Future<HardwareRouteVerificationResult>
  _verifyAudiophileHardwareRouteImpl() async {
    final prefs = _effectiveAudiophilePrefs(_preferences.read());
    final client = _client;
    if (!_activeNotifier.value ||
        client == null ||
        client.isDisposed ||
        !client.isInitialized) {
      return HardwareRouteVerificationResult(
        verified: false,
        deviceFingerprint:
            _safetyCoordinator.deviceSafetyState.deviceFingerprint,
        detail: '未检测到正在运行的音频会话，请先播放音频后重新检测。',
      );
    }
    final result = await _safetyCoordinator.verifyActiveHardwareRoute(prefs);
    // 重新检测可能撤销原有解锁，须同步实际滤镜而非仅更新徽标。
    if (!identical(_client, client) || client.isDisposed) {
      return HardwareRouteVerificationResult(
        verified: false,
        deviceFingerprint:
            _safetyCoordinator.deviceSafetyState.deviceFingerprint,
        detail: '播放会话已变更，请重新检测。',
      );
    }
    await syncPreferencesFromStore();
    return result;
  }

  Future<AudioSafetyChainPlan> _confirmFullScaleUnlockImpl() async {
    final currentPrefs = _preferences.read();
    final effectivePrefs = _effectiveAudiophilePrefs(currentPrefs);
    final mode = _safetyCoordinator.resolveRouteMode(effectivePrefs);
    final client = _client;
    final direct =
        mode == AudioOutputRouteMode.exclusiveAudioOutput ||
        mode == AudioOutputRouteMode.androidBitPerfectUsb;
    // 解锁不能隐式执行检测，也不能接管其他舞台的活跃句柄。
    if (!_activeNotifier.value ||
        client == null ||
        client.isDisposed ||
        !client.isInitialized ||
        !direct ||
        !_safetyCoordinator.deviceSafetyState.isBackendMeterVerified) {
      return _snapshotNotifier.value.audiophilePlan;
    }
    await _safetyCoordinator.confirmSessionFullScaleUnlock(effectivePrefs);
    if (!identical(_client, client) || client.isDisposed) {
      return _snapshotNotifier.value.audiophilePlan;
    }
    // 会话门锁由协调器维护，不把临时解锁持久化成下次播放的默认值。
    await syncPreferencesFromStore();
    return _snapshotNotifier.value.audiophilePlan;
  }

  Future<void> _setAudiophileSafetyLimiterEnabledImpl(bool enabled) async {
    if (!enabled) {
      await _confirmFullScaleUnlockImpl();
      return;
    }
    final nextPrefs = _preferences.update(
      (p) => p.copyWith(audiophileSafetyLimiterEnabled: true),
    );
    _safetyCoordinator.handleExternalDeviceChanged(
      _snapshotNotifier.value.audiophileSafetyState.deviceFingerprint,
      isBackendMeterVerified: false,
    );
    await syncPreferencesFromStore(overridePrefs: nextPrefs);
  }

  Future<List<MpvAudioDevice>> _refreshAudioDevicesImpl() async {
    final client = _client;
    if (client == null || client.isDisposed || !client.isInitialized) {
      return _snapshotNotifier.value.availableAudioDevices;
    }
    final devices = client.readAudioDeviceList();
    _updateSnapshot(
      _snapshotNotifier.value.copyWith(availableAudioDevices: devices),
    );
    return devices;
  }

  Future<void> _selectAudioDeviceImpl(String deviceName) async {
    final clean = deviceName.trim().isEmpty
        ? PlaybackQualityConfig.defaultAudioDevice
        : deviceName.trim();
    final nextPrefs = _preferences.update(
      (p) => p.copyWith(audioDevice: clean),
    );
    _safetyCoordinator.handleExternalDeviceChanged(
      clean,
      isBackendMeterVerified: false,
    );
    final client = _client;
    if (client != null && !client.isDisposed && client.isInitialized) {
      client.setPropertyString('audio-device', clean);
    }
    await syncPreferencesFromStore(overridePrefs: nextPrefs);
  }

  Future<void> _syncPreferencesFromStoreImpl({
    AudioPlaybackPrefsData? overridePrefs,
  }) async {
    final prefs = overridePrefs ?? _preferences.read();
    _applyLoopMode(prefs.loopMode);
    final effective = _effectiveAudiophilePrefs(prefs);
    final upstream = _buildUpstreamDspFilters(prefs);
    final plan = _safetyCoordinator.compilePlan(
      effective,
      upstreamDspFilters: upstream,
    );

    final client = _client;
    if (client != null && !client.isDisposed && client.isInitialized) {
      final applied = _safetyCoordinator.applyToClient(
        client,
        prefs: effective,
        preferredSampleRateHz: _snapshotNotifier.value.sampleRateHz > 0
            ? _snapshotNotifier.value.sampleRateHz
            : null,
        upstreamDspFilters: upstream,
      );
      _applyReplayGainOptions(client: client, prefs: prefs, plan: applied);
      if (prefs.audioDevice.trim().isNotEmpty) {
        client.setPropertyString('audio-device', prefs.audioDevice);
      }
      _updateSnapshot(
        _snapshotNotifier.value.copyWith(
          audiophileSafetyState: _safetyCoordinator.deviceSafetyState,
          audiophilePlan: applied,
        ),
      );
      return;
    }

    _updateSnapshot(
      _snapshotNotifier.value.copyWith(
        audiophileSafetyState: _safetyCoordinator.deviceSafetyState,
        audiophilePlan: plan,
      ),
    );
  }

  Future<LaunchPlaybackResult?> _relayActiveToDesktopImpl({
    String? targetId,
    required bool allowWithoutBeefweb,
    WorkRecord? launchWork,
    List<AudioQueueItem>? launchQueue,
    int? launchIndex,
    double? launchStartSeconds,
  }) async {
    final gateway = _desktopRelayGateway;
    final snap = _snapshotNotifier.value;
    final fresh = launchWork != null;
    final queue = launchQueue ?? snap.queue;
    final work = launchWork ?? _activeWork;
    final item = fresh ? queue[launchIndex!] : snap.currentItem;
    final previousItemId = snap.currentItem?.itemId;
    if (gateway == null || work == null || item == null) {
      return const LaunchPlaybackResult(launched: false, message: '没有可接力的活动曲目');
    }
    if (_desktopRelayInProgress) {
      return const LaunchPlaybackResult(launched: false, message: '正在移交播放器');
    }
    _desktopRelayInProgress = true;
    final epoch = ++_desktopRelayEpoch;
    final wasPlaying = _playingNotifier.value;
    final prefs = _preferences.read();
    var paused = false;
    var handedOff = false;
    var ready = false;
    final pending = <void Function()>[];
    try {
      CueSheet? sheet;
      var items = queue
          .where(
            (entry) =>
                entry.workId == item.workId &&
                entry.sourceId == item.sourceId &&
                entry.albumKey == item.albumKey &&
                (item.isCueTrack
                    ? entry.isCueTrack &&
                          entry.cueSheetPath == item.cueSheetPath
                    : !entry.isCueTrack && entry.cueSheetPath == null),
          )
          .toList(growable: false);
      if (item.isCueTrack) {
        final path = item.cueSheetPath;
        if (path == null) {
          return const LaunchPlaybackResult(
            launched: false,
            message: 'CUE 清单不存在',
          );
        }
        sheet = await _assets.loadCueSheet(
          source: item.source,
          cueRelativePath: path,
          gatewayFactory: _gatewayFactory,
        );
        final numbers = items.map((entry) => entry.cueTrackIndex).toSet();
        if (sheet == null ||
            sheet.rejectedUnsafeFileCount > 0 ||
            items.length != sheet.tracks.length ||
            !sheet.tracks.every((track) {
              if (!numbers.contains(track.trackNumber)) return false;
              final mapped = items.firstWhere(
                (entry) => entry.cueTrackIndex == track.trackNumber,
              );
              // 当前队列仅能可靠表达已解析的物理映射；多 FILE 清单不能错指同一母轨。
              final cueDir = p.posix.dirname(
                AudioPlaybackQueueBuilder.normalizeQueuePath(path),
              );
              final expectedPath = p.posix.normalize(
                p.posix.join(cueDir, track.fileName.replaceAll('\\', '/')),
              );
              final actualPath = p.posix.normalize(
                AudioPlaybackQueueBuilder.normalizeQueuePath(
                  mapped.relativePath,
                ),
              );
              return expectedPath.toLowerCase() == actualPath.toLowerCase();
            })) {
          return const LaunchPlaybackResult(
            launched: false,
            message: 'CUE 分轨未完整关联，不能安全移交专辑',
          );
        }
        items = [...items]
          ..sort((a, b) => a.cueTrackIndex!.compareTo(b.cueTrackIndex!));
      }
      final initialIndex = items.indexWhere(
        (entry) => entry.itemId == item.itemId,
      );
      if (initialIndex < 0 ||
          _disposed ||
          (!fresh &&
              _snapshotNotifier.value.currentItem?.itemId != item.itemId)) {
        return const LaunchPlaybackResult(
          launched: false,
          message: '曲目已变更或尚未完整加载，请重试',
        );
      }
      final tracks = [
        for (final entry in items)
          ExternalAudioTrackDescriptor(
            recordId:
                '${PlaybackRecordHelper.audioEpisodePrefix}${entry.workId.value}::${entry.itemId}',
            episodeId: EpisodeId(
              '${PlaybackRecordHelper.audioEpisodePrefix}${entry.itemId}',
            ),
            variant: entry.variant,
            title: entry.title,
            performer: entry.artist,
            albumTitle: entry.album,
            trackNumber: entry.cueTrackIndex ?? (queue.indexOf(entry) + 1),
            isCueSubtrack: entry.isCueTrack,
            cueStartSeconds: entry.isCueTrack ? entry.startSeconds : null,
            cueEndSeconds: entry.endSeconds,
            knownDurationSeconds: entry.durationSeconds > 0
                ? entry.durationSeconds.round()
                : null,
          ),
      ];
      final start = launchStartSeconds ?? currentTrackPositionSeconds;
      await setPlaying(false);
      paused = true;
      final result = await gateway.launchAudioAlbum(
        ExternalAudioAlbumRelayRequest(
          work: work,
          tracks: tracks,
          source: item.source,
          initialTrackIndex: initialIndex,
          parsedCueSheet: sheet,
          startSeconds: start.round(),
          exactStartSeconds: start,
          targetId: targetId ?? prefs.preferredRelayTargetId,
          beefwebPort: prefs.foobarBeefwebPort,
          allowWithoutBeefweb:
              allowWithoutBeefweb || prefs.skipFoobarBeefwebPrompt,
        ),
        onTrackProgress:
            (
              track,
              position,
              duration, {
              required isCompleted,
              required isFinal,
            }) async {
              if (_disposed ||
                  epoch != _desktopRelayEpoch ||
                  duration <= 0 ||
                  position < 0) {
                return;
              }
              void persist() {
                if (_disposed || epoch != _desktopRelayEpoch) return;
                final now = DateTime.now().millisecondsSinceEpoch;
                _playbackRecordDao?.upsert(
                  PlaybackRecordEntity(
                    id: track.recordId,
                    workId: work.id,
                    episodeId: track.episodeId,
                    variantId: track.variant.id,
                    seasonNumber: 1,
                    episodeNumber: track.trackNumber,
                    episodeTitle: track.title,
                    sourceKind: item.source.kind,
                    playedAtMs: now,
                    positionSeconds: position.clamp(0, duration),
                    durationSeconds: duration,
                    isCompleted: isCompleted,
                    updatedAtMs: now,
                  ),
                );
              }

              // 先让旧内置会话完成最后一次历史写入，再应用外部进度。
              if (ready) {
                persist();
              } else {
                pending.add(persist);
              }
            },
      );
      if (!result.launched) return result;
      handedOff = true;
      _externalRelayActive = true;
      if (!_disposed &&
          _activeNotifier.value &&
          _snapshotNotifier.value.currentItem?.itemId == previousItemId) {
        await stopAndClose();
      }
      ready = true;
      for (final persist in pending) {
        persist();
      }
      pending.clear();
      return result;
    } finally {
      if (!handedOff) {
        pending.clear();
        _desktopRelayEpoch++;
        if (paused &&
            wasPlaying &&
            !_disposed &&
            _snapshotNotifier.value.currentItem?.itemId == previousItemId) {
          await setPlaying(true);
        }
      }
      _desktopRelayInProgress = false;
    }
  }

  List<String> _buildUpstreamDspFilters(AudioPlaybackPrefsData prefs) {
    final filters = <String>[];
    if (prefs.replayGainPreampDb > 0.05 && !prefs.bitstreamPassthrough) {
      filters.add(
        'lavfi=[volume=${prefs.replayGainPreampDb.toStringAsFixed(1)}dB]',
      );
    } else if (prefs.audiophileSafetyLimiterEnabled &&
        !prefs.bitstreamPassthrough &&
        (prefs.exclusiveAudioOutput || prefs.androidBitPerfectUsb)) {
      filters.add('lavfi=[volume=0.0dB]');
    }
    return filters;
  }

  void _handleSafetyCoordinatorTransientMute(String reason) {
    if (_disposed) return;
    _microFadeDriver.cancel();
    _playingNotifier.value = false;
    _reconcileClockObservation();
    _updateSnapshot(
      _snapshotNotifier.value.copyWith(
        status: AudioPlaybackStatus.paused,
        audiophileSafetyState: _safetyCoordinator.deviceSafetyState,
        audiophilePlan: _safetyCoordinator.activePlan,
      ),
    );
    _recordLog(
      code: 'AUDIO_HOTPLUG_TRANSIENT_PAUSE',
      message: '音频输出路由变化触发防爆耳瞬态暂停：$reason',
      severity: DiagnosticSeverity.warn,
    );
  }
}
