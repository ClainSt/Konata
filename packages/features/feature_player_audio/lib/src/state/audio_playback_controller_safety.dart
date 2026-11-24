part of 'audio_playback_controller.dart';

extension _AudioPlaybackControllerSafety on AudioPlaybackController {
  Future<HardwareRouteVerificationResult> _verifyAudiophileHardwareRouteImpl() async {
    final prefs = _effectiveAudiophilePrefs(_preferences.read());
    final result = await _safetyCoordinator.verifyActiveHardwareRoute(prefs);
    final plan = _safetyCoordinator.compilePlan(
      prefs,
      upstreamDspFilters: _buildUpstreamDspFilters(_preferences.read()),
    );
    _updateSnapshot(
      _snapshotNotifier.value.copyWith(
        audiophileSafetyState: _safetyCoordinator.deviceSafetyState,
        audiophilePlan: plan,
      ),
    );
    return result;
  }

  Future<AudioSafetyChainPlan> _confirmFullScaleUnlockImpl() async {
    final currentPrefs = _preferences.read();
    final updated = _preferences.update(
      (p) => p.copyWith(audiophileSafetyLimiterEnabled: false),
    );
    final effectivePrefs = _effectiveAudiophilePrefs(updated);
    final verifiedBefore =
        _safetyCoordinator.deviceSafetyState.isBackendMeterVerified;
    if (!verifiedBefore &&
        currentPrefs.audiophileSafetyLimiterEnabled &&
        (updated.exclusiveAudioOutput || updated.androidBitPerfectUsb)) {
      await _safetyCoordinator.verifyActiveHardwareRoute(effectivePrefs);
    }
    final unlocked = await _safetyCoordinator.confirmSessionFullScaleUnlock(
      effectivePrefs,
    );
    final plan = _safetyCoordinator.compilePlan(
      effectivePrefs,
      upstreamDspFilters: _buildUpstreamDspFilters(updated),
    );
    if (!unlocked) {
      _preferences.update(
        (p) => p.copyWith(audiophileSafetyLimiterEnabled: true),
      );
    }
    _updateSnapshot(
      _snapshotNotifier.value.copyWith(
        audiophileSafetyState: _safetyCoordinator.deviceSafetyState,
        audiophilePlan: plan,
      ),
    );
    return plan;
  }

  Future<void> _setAudiophileSafetyLimiterEnabledImpl(bool enabled) async {
    final nextPrefs = _preferences.update(
      (p) => p.copyWith(audiophileSafetyLimiterEnabled: enabled),
    );
    if (enabled) {
      _safetyCoordinator.handleExternalDeviceChanged(
        _snapshotNotifier.value.audiophileSafetyState.deviceFingerprint,
        isBackendMeterVerified: false,
      );
    }
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
    final nextPrefs = _preferences.update((p) => p.copyWith(audioDevice: clean));
    _safetyCoordinator.handleExternalDeviceChanged(clean);
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
          loopMode: prefs.loopMode,
          shuffleEnabled: prefs.shuffleEnabled,
        ),
      );
      return;
    }

    _updateSnapshot(
      _snapshotNotifier.value.copyWith(
        audiophileSafetyState: _safetyCoordinator.deviceSafetyState,
        audiophilePlan: plan,
        loopMode: prefs.loopMode,
        shuffleEnabled: prefs.shuffleEnabled,
      ),
    );
  }

  Future<LaunchPlaybackResult?> _relayActiveToDesktopImpl({
    String? targetId,
  }) async {
    final gateway = _desktopRelayGateway;
    final snap = _snapshotNotifier.value;
    final work = _activeWork;
    final item = snap.currentItem;
    if (gateway == null || work == null || item == null) return null;

    await setPlaying(false);
    final prefs = _preferences.read();
    final effectiveTargetId = targetId ?? prefs.preferredRelayTargetId;
    return gateway.launchAudio(
      work: work,
      episode: EpisodeSummaryView(
        id: EpisodeId('${PlaybackRecordHelper.audioEpisodePrefix}${item.itemId}'),
        workId: work.id,
        seasonNumber: 1,
        category: EpisodeCategory.extra,
        episodeNumber: item.cueTrackIndex ?? (snap.currentIndex + 1),
        title: item.title,
      ),
      variant: item.variant,
      source: item.source,
      targetId: effectiveTargetId,
      startSeconds: currentTrackPositionSeconds.round(),
      exactStartSeconds: item.startSeconds + currentTrackPositionSeconds,
    );
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
