part of 'video_playback_controller.dart';

/// 视频控制器内存字幕引擎、音轨选择、着色器热更新与原画截图扩展。
extension VideoPlaybackControllerSubtitles on VideoPlaybackController {
  /// 计算底部播控胶囊显隐对应的常规字幕上抬百分比（隐藏或无效视口返回 `0.0`）。
  static double computeSubtitleHudLiftPercent({
    required bool hudVisible,
    required double bottomCapsuleOccupiedHeight,
    required double viewportHeight,
  }) {
    if (!hudVisible ||
        !bottomCapsuleOccupiedHeight.isFinite ||
        !viewportHeight.isFinite ||
        bottomCapsuleOccupiedHeight <= 0 ||
        viewportHeight <= 0) {
      return 0.0;
    }
    return ((bottomCapsuleOccupiedHeight / viewportHeight) * 100.0)
        .clamp(0.0, 45.0)
        .toDouble();
  }

  /// 按底部播控胶囊真实占高同步 `libmpv` 字幕垂直上抬比例，隐藏瞬间立即归零复原。
  ///
  /// 底层在保真模式临时使用等倍率 scale 使 sub-pos 生效，
  /// 隐藏时恢复用户模式，不强制覆盖原 ASS 样式。
  double updateHudSubtitleLift({
    required bool hudVisible,
    required double bottomCapsuleOccupiedHeight,
    required double viewportHeight,
  }) {
    if (_disposed) return 0.0;
    final targetPercent = _closing
        ? 0.0
        : computeSubtitleHudLiftPercent(
            hudVisible: hudVisible,
            bottomCapsuleOccupiedHeight: bottomCapsuleOccupiedHeight,
            viewportHeight: viewportHeight,
          );
    final changed =
        (_currentSubtitleHudLiftPercent - targetPercent).abs() >= 0.05 ||
        (targetPercent == 0.0 && _currentSubtitleHudLiftPercent != 0.0);
    if (changed) {
      _currentSubtitleHudLiftPercent = targetPercent;
      _session?.setSubtitleHudLiftPercent(targetPercent);
    }
    return _currentSubtitleHudLiftPercent;
  }

  SubtitleMemoryEngine _ensureSubtitleMemoryEngine() {
    return _subtitleMemoryEngine ??= SubtitleMemoryEngine(
      clientSupplier: () => _session?.activeClient,
      playbackEngine: env.playbackEngine,
      legacyCodePageDecoder: env.legacyCodePageDecoder,
      cloudSubsetTransform: _tryCloudSubsetAssContent,
      onAssContentPrepared: _ingestAssEmbeddedFontsIfPresent,
      onTrackStateChanged: () => _session?.refreshMetadata(),
    );
  }

  Future<Uri?> _resolveAuthorizedCloudSubsetEndpoint() async {
    final prefs = env.preferencesStore.read();
    if (!prefs.enableCloudSubset) return null;
    final raw = prefs.fontInAssEndpoint.trim();
    if (raw.isEmpty) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty) {
      return null;
    }
    final origin = CloudSubsetOrigin.fromUri(uri);
    final coordinator = env.cloudSubsetCoordinator;
    if (coordinator == null || uri.userInfo.isNotEmpty) return null;
    if (!prefs.authorizedCloudSubsetOrigins.contains(origin.key) &&
        !prefs.authorizedCloudSubsetOrigins.contains(raw)) {
      return null;
    }
    await coordinator.cloudClient.authorizationStore.ensureHydrated();
    final latest = env.preferencesStore.read();
    if (!latest.enableCloudSubset ||
        latest.fontInAssEndpoint.trim() != raw ||
        (!latest.authorizedCloudSubsetOrigins.contains(origin.key) &&
            !latest.authorizedCloudSubsetOrigins.contains(raw)) ||
        !coordinator.cloudClient.authorizationStore.isAuthorized(uri)) {
      return null;
    }
    return uri;
  }

  Future<String?> _tryCloudSubsetAssContent(String originalAssContent) async {
    if (originalAssContent.contains('[Fonts]')) {
      return null;
    }
    final endpointUri = await _resolveAuthorizedCloudSubsetEndpoint();
    final coordinator = env.cloudSubsetCoordinator;
    if (endpointUri == null || coordinator == null) return null;
    try {
      final result = await coordinator.runCloudSubset(
        endpointUri: endpointUri,
        originalAssContent: originalAssContent,
      );
      PlaybackLogHelper.record(
        env.diagnosticLog,
        'mpv-cloud-subset',
        '云端字体子集化命中 ${result.origin.key}（缓存复用=${result.fromLocalCache}）',
      );
      final latest = env.preferencesStore.read();
      if (_disposed ||
          _closing ||
          !latest.enableCloudSubset ||
          Uri.tryParse(latest.fontInAssEndpoint.trim()) != endpointUri ||
          !coordinator.cloudClient.authorizationStore.isAuthorized(
            endpointUri,
          )) {
        return null;
      }
      return result.subsettedAssContent;
    } on CloudSubsetCancelledException {
      return null;
    } on Object catch (error) {
      PlaybackLogHelper.record(
        env.diagnosticLog,
        'mpv-cloud-subset',
        '云端字体子集化降级回退本地正文：$error',
      );
      return null;
    }
  }

  Future<void> _ingestAssEmbeddedFontsIfPresent(String assContent) async {
    try {
      final pool =
          env.fontPoolManager ??
          (_ownedFontPoolManager ??= SubtitleFontPoolManager(
            storageRoot: env.storageRoot,
          ));
      final resolved = await pool.ingestAssEmbeddedFonts(assContent);
      if (resolved != null && !_disposed && !_closing) {
        if (_state.isApplyingCloudSubset) {
          _lastIngestedCloudSubsetFontsDir = resolved.directoryPath;
        } else {
          _session?.applySubFontsDir(
            resolved.directoryPath,
            isCloudSubsetOverride: false,
          );
        }
        PlaybackLogHelper.record(
          env.diagnosticLog,
          'mpv-fonts',
          '字幕内嵌字库入池成功（${resolved.fontCount} 个字体，复用=${resolved.reusedFromLease}）',
        );
      }
    } on Object catch (error) {
      PlaybackLogHelper.record(
        env.diagnosticLog,
        'mpv-fonts',
        '提取内嵌字库忽略：$error',
      );
    }
  }

  Map<int, String> _readMountedSubtitleSourcePaths() =>
      _subtitleMemoryEngine?.mountedSourcePathsSnapshot ??
      const <int, String>{};

  Set<int> _readMountedCloudSubsetTrackIds() =>
      _subtitleMemoryEngine?.cloudSubsetTrackIdsSnapshot ?? const <int>{};

  Future<void> _mountDiscoveredExternalTextSubtitles(
    List<String> textSubtitlePaths,
    CrossEpisodeTrackMemory trackMemory,
    TrackPreferences trackPreferences,
  ) async {
    if (_disposed || _closing || textSubtitlePaths.isEmpty) return;
    final engine = _ensureSubtitleMemoryEngine();
    final res = await engine.mountDiscoveredExternalSubtitles(
      textSubtitlePaths: textSubtitlePaths,
      trackMemory: trackMemory,
      trackPreferences: trackPreferences,
    );
    if (_disposed || _closing || !res.applied || res.staleAborted) return;
    _setState(
      _state.copyWith(
        activeSubtitleSubsetState: res.primarySubsetState,
        clearActiveSubtitleSubsetState: res.primarySubsetState == null,
      ),
    );
  }

  /// 切换主字幕轨道或关闭主字幕显示。
  Future<void> selectSubtitleChoice(SubtitleChoice? choice) async {
    if (_disposed || _closing) return;
    final engine = _ensureSubtitleMemoryEngine();

    if (choice == null) {
      final res = await engine.applyIntent(
        AuthoritativeSubtitleIntent.disable(
          beforeSelectPrimary: (_) {
            _session?.restoreBaselineSubFontsDir();
          },
        ),
      );
      if (_disposed || _closing || !res.applied || res.staleAborted) return;
      _setState(
        _state.copyWith(
          trackMemory: CrossEpisodeTrackMemory(
            audioLang: _state.trackMemory.audioLang,
            audioTitle: _state.trackMemory.audioTitle,
            audioCodec: _state.trackMemory.audioCodec,
            audioExternal: _state.trackMemory.audioExternal,
            subtitleDisabled: true,
          ),
          subtitleOpenCcMode: SubtitleOpenCcMode.none,
          clearActiveSubtitleSubsetState: true,
        ),
      );
      return;
    }

    final memoryTarget = choice.mpvTrackId != null
        ? SubtitleSlotRequest.existingTrack(
            choice.mpvTrackId!,
            displayTitle: choice.title,
          )
        : (choice.externalPath != null
              ? SubtitleSlotRequest.memory(
                  localFilePath: choice.externalPath,
                  fileName: p.basename(choice.externalPath!),
                  displayTitle: choice.title,
                  openCcMode: _state.subtitleOpenCcMode,
                )
              : null);
    if (memoryTarget == null) return;

    final nextMemory = CrossEpisodeTrackMemory(
      audioLang: _state.trackMemory.audioLang,
      audioTitle: _state.trackMemory.audioTitle,
      audioCodec: _state.trackMemory.audioCodec,
      audioExternal: _state.trackMemory.audioExternal,
      subtitleDisabled: false,
      subLang: choice.language.trim().toLowerCase(),
      subTitle: choice.title.trim(),
      subCodec: choice.codec.trim().toLowerCase(),
      subExternal: choice.isExternal,
    );
    final res = await engine.applyIntent(
      AuthoritativeSubtitleIntent(
        primary: memoryTarget,
        beforeSelectPrimary: (trackId) {
          if (trackId != null && engine.isCloudSubsetTrackId(trackId)) {
            final dir = engine.lookupCloudSubsetFontsDirForTrackId(trackId);
            if (dir != null) {
              _session?.applySubFontsDir(dir, isCloudSubsetOverride: true);
            }
          } else {
            _session?.restoreBaselineSubFontsDir();
          }
        },
      ),
    );
    if (_disposed || _closing || !res.applied || res.staleAborted) return;
    _setState(
      _state.copyWith(
        trackMemory: nextMemory,
        activeSubtitleSubsetState: res.primarySubsetState,
        clearActiveSubtitleSubsetState: res.primarySubsetState == null,
      ),
    );
  }

  /// 切换当前主字幕的内存即时繁简转换模式。
  Future<void> setSubtitleOpenCcMode(SubtitleOpenCcMode mode) async {
    if (_disposed || _closing) return;
    final currentPrimary = _state.subtitles.cast<SubtitleChoice?>().firstWhere(
      (s) => s?.selected ?? false,
      orElse: () => null,
    );
    if (currentPrimary == null) {
      _setState(_state.copyWith(subtitleOpenCcMode: mode));
      return;
    }

    final trackId = currentPrimary.mpvTrackId;
    final rawSourcePath =
        (trackId != null
            ? _ensureSubtitleMemoryEngine().lookupSourcePathForTrackId(trackId)
            : null) ??
        currentPrimary.externalPath;
    if (rawSourcePath == null || rawSourcePath.trim().isEmpty) {
      showTransientNotice('仅外挂文本字幕支持即时繁简转换');
      return;
    }

    final engine = _ensureSubtitleMemoryEngine();
    final res = await engine.applyIntent(
      AuthoritativeSubtitleIntent(
        primary: SubtitleSlotRequest.memory(
          localFilePath: rawSourcePath,
          fileName: p.basename(rawSourcePath),
          displayTitle: currentPrimary.title,
          openCcMode: mode,
        ),
      ),
    );
    if (_disposed || _closing || !res.applied || res.staleAborted) return;
    _setState(
      _state.copyWith(
        subtitleOpenCcMode: mode,
        activeSubtitleSubsetState: res.primarySubsetState,
        clearActiveSubtitleSubsetState: res.primarySubsetState == null,
      ),
    );
    if (res.primaryOpenCcSkipReason != null &&
        res.primaryOpenCcSkipReason!.isNotEmpty) {
      showTransientNotice(res.primaryOpenCcSkipReason!);
    }
  }

  /// 对当前外挂字幕应用离线分段线性时间轴重映射并归零瞬时延迟。
  Future<void> applySubtitleTimelineRemap(
    SubtitleTimelineTransform transform,
  ) async {
    if (_disposed || _closing) return;
    final currentPrimary = _state.subtitles.cast<SubtitleChoice?>().firstWhere(
      (s) => s?.selected ?? false,
      orElse: () => null,
    );
    final trackId = currentPrimary?.mpvTrackId;
    final rawSourcePath =
        (trackId != null
            ? _ensureSubtitleMemoryEngine().lookupSourcePathForTrackId(trackId)
            : null) ??
        currentPrimary?.externalPath;
    if (currentPrimary == null ||
        rawSourcePath == null ||
        rawSourcePath.trim().isEmpty) {
      showTransientNotice('请先选中外挂文本字幕再应用离线调轴');
      return;
    }

    final engine = _ensureSubtitleMemoryEngine();
    final res = await engine.applyIntent(
      AuthoritativeSubtitleIntent(
        primary: SubtitleSlotRequest.memory(
          localFilePath: rawSourcePath,
          fileName: p.basename(rawSourcePath),
          displayTitle: currentPrimary.title,
          openCcMode: _state.subtitleOpenCcMode,
          timelineTransform: transform,
        ),
      ),
    );
    if (_disposed || _closing || !res.applied || res.staleAborted) return;
    _setState(
      _state.copyWith(
        subtitleDelaySeconds: res.zeroedInstantSubDelay
            ? 0.0
            : _state.subtitleDelaySeconds,
      ),
    );
    showTransientNotice('已生成时间轴校准后的内存字幕');
  }

  /// 对当前选中的 ASS 外挂字幕主动触发按域云端字体子集化对比轨道挂载。
  Future<void> applyCloudSubsetToCurrentSubtitle() async {
    if (_disposed || _closing || _state.isApplyingCloudSubset) return;
    final currentPrimary = _state.subtitles.cast<SubtitleChoice?>().firstWhere(
      (s) => s?.selected ?? false,
      orElse: () => null,
    );
    final trackId = currentPrimary?.mpvTrackId;
    final rawSourcePath =
        (trackId != null
            ? _ensureSubtitleMemoryEngine().lookupSourcePathForTrackId(trackId)
            : null) ??
        currentPrimary?.externalPath;
    if (currentPrimary == null ||
        rawSourcePath == null ||
        rawSourcePath.trim().isEmpty) {
      showTransientNotice('当前仅支持对外挂 ASS 字幕执行云端字体子集化');
      return;
    }

    _lastIngestedCloudSubsetFontsDir = null;
    _setState(_state.copyWith(isApplyingCloudSubset: true));
    try {
      final engine = _ensureSubtitleMemoryEngine();
      final res = await engine.applyIntent(
        AuthoritativeSubtitleIntent(
          primary: SubtitleSlotRequest.memory(
            localFilePath: rawSourcePath,
            fileName: p.basename(rawSourcePath),
            displayTitle: currentPrimary.title,
            openCcMode: _state.subtitleOpenCcMode,
            enableCloudSubset: true,
          ),
          forceRebindPrimaryDecoder: true,
          beforeSelectPrimary: (mountedTrackId) {
            final fontsDir = _lastIngestedCloudSubsetFontsDir;
            if (mountedTrackId != null && fontsDir != null) {
              engine.registerCloudSubsetFontsDir(mountedTrackId, fontsDir);
              _session?.applySubFontsDir(fontsDir, isCloudSubsetOverride: true);
            }
          },
        ),
      );
      if (!_disposed && !_closing && res.applied && !res.staleAborted) {
        if (res.cloudSubsetApplied) {
          showTransientNotice('云端字体子集化轨道已挂载并激活');
        } else {
          showTransientNotice('当前字幕未触发云端子集化或已保留原字库');
        }
      }
    } finally {
      if (!_disposed) {
        _setState(_state.copyWith(isApplyingCloudSubset: false));
      }
    }
  }

  /// 通过注入的跨平台文件选择端口选取本地外挂字幕并直注挂载。
  Future<void> pickAndAddExternalSubtitle() async {
    if (_disposed || _closing) return;
    final pickedPath = await env.filePicker.pickSubtitleFile(
      dialogTitle: '选择外挂字幕文件',
    );
    if (_disposed ||
        _closing ||
        pickedPath == null ||
        pickedPath.trim().isEmpty) {
      return;
    }
    final trimmed = pickedPath.trim();
    final engine = _ensureSubtitleMemoryEngine();
    final res = await engine.applyIntent(
      AuthoritativeSubtitleIntent(
        primary: SubtitleSlotRequest.memory(
          localFilePath: trimmed,
          fileName: p.basename(trimmed),
          displayTitle: p.basename(trimmed),
          openCcMode: _state.subtitleOpenCcMode,
        ),
      ),
    );
    if (_disposed || _closing) return;
    if (res.applied && !res.staleAborted) {
      showTransientNotice('已载入外挂字幕：${p.basename(trimmed)}');
    } else {
      _session?.addExternalSubtitleFile(trimmed);
    }
  }

  /// 设定字幕瞬时时间偏移（秒）。
  void setSubtitleDelay(double delaySeconds) {
    final clamped = delaySeconds.clamp(-60.0, 60.0).toDouble();
    _ensureSubtitleMemoryEngine().setInstantSubtitleDelay(clamped);
    _setState(_state.copyWith(subtitleDelaySeconds: clamped));
  }

  /// 步进微调字幕瞬时时间偏移（秒）。
  void adjustSubtitleDelay(double deltaSeconds) {
    setSubtitleDelay(_state.subtitleDelaySeconds + deltaSeconds);
  }

  /// 切换音频轨道并记录跨集语言记忆偏好。
  Future<void> selectAudioTrack(AudioTrackChoice choice) async {
    if (_disposed || _closing) return;
    _session?.selectAudioTrack(choice);
    if (choice.mpvTrackId != null) {
      _setState(
        _state.copyWith(
          trackMemory: CrossEpisodeTrackMemory(
            audioLang: choice.language.trim().toLowerCase(),
            audioTitle: choice.title.trim(),
            audioCodec: choice.codec.trim().toLowerCase(),
            audioExternal: choice.isExternal,
            subtitleDisabled: _state.trackMemory.subtitleDisabled,
            subLang: _state.trackMemory.subLang,
            subTitle: _state.trackMemory.subTitle,
            subCodec: _state.trackMemory.subCodec,
            subExternal: _state.trackMemory.subExternal,
          ),
        ),
      );
    }
  }

  /// 设定音频延迟（秒）。
  void setAudioDelay(double delaySeconds) {
    final clamped = delaySeconds.clamp(-10.0, 10.0).toDouble();
    _session?.setAudioDelay(clamped);
    _setState(_state.copyWith(audioDelaySeconds: clamped));
  }

  /// 热切换桌面音频输出设备并持久化写入偏好切片。
  Future<void> selectAudioDevice(String deviceName) async {
    final trimmed = deviceName.trim();
    if (trimmed.isEmpty) return;
    env.preferencesStore.updateQualityConfig(
      (q) => q.copyWith(audioDevice: trimmed),
    );
    await env.audiophileCoordinator.reapplyAll(
      env.preferencesStore.read().audiophilePreferences,
    );
  }

  /// 切换视频画面填充与比例模式。
  void setAspectMode(VideoAspectMode mode) {
    if (_state.aspectMode == mode) return;
    _session?.applyAspectMode(mode);
    _setState(_state.copyWith(aspectMode: mode));
  }

  /// 切换仅听声音熄屏省电模式。
  void toggleAudioOnlyMode() {
    final next = !_state.audioOnlyMode;
    _session?.setVideoTrackEnabled(!next);
    _setState(_state.copyWith(audioOnlyMode: next));
    showTransientNotice(next ? '已开启纯音频模式' : '已恢复视频画面输出');
  }

  /// 热切换单个自定义着色器脚本的启用状态并即时生效。
  void toggleShaderPath(String shaderPath, bool enabled) {
    env.preferencesStore.toggleShaderPath(shaderPath, enabled);
    final updatedConfig = env.preferencesStore.read().qualityConfig;
    _session?.applyLiveQualityConfig(updatedConfig);
  }

  /// 触发当前播放画面无界面原画截图落盘。
  Future<ScreenshotCaptureResult?> captureScreenshot({
    ScreenshotCaptureMode mode = ScreenshotCaptureMode.pureVideo,
  }) async {
    final session = _session;
    final work = _state.currentWork;
    if (_disposed || _closing || session == null || work == null) {
      return null;
    }
    final workPhotoDir = await PlaybackStoragePaths.resolveWorkScreenshotDir(
      env.storageRoot,
      work.id.value,
    );
    final result = await session.captureScreenshot(
      workPhotoDir: workPhotoDir,
      episodeTag: PlaybackRecordHelper.formatEpisodeTag(
        _state.currentEpisode.seasonNumber,
        _state.currentEpisode.episodeNumber,
      ),
      mode: mode,
    );
    if (result != null) {
      showTransientNotice('截图已保存：${result.displayLabel}');
    } else {
      showTransientNotice('原画截图失败或当前画面尚未就绪', isError: true);
    }
    return result;
  }
}
