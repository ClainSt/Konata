part of 'video_playback_controller.dart';

/// `VideoPlaybackController` 内存字幕增强引擎、双语副字幕与音画实时配置扩展。
extension VideoPlaybackControllerSubtitles on VideoPlaybackController {
  SubtitleMemoryEngine _ensureSubtitleMemoryEngine() {
    return _subtitleMemoryEngine ??= SubtitleMemoryEngine(
      clientSupplier: () => _session?.activeClient,
      playbackEngine: _engine,
      legacyCodePageDecoder: _ref.read(legacyCodePageDecoderProvider),
      onTrackStateChanged: () => _session?.refreshMetadata(),
    );
  }

  /// 经单一串行权威通道执行内存级无副作用字幕挂载（多编码归一 / OpenCC / 离线调轴）。
  Future<SubtitleMemoryApplyResult> applyMemorySubtitleIntent(
    AuthoritativeSubtitleIntent intent,
  ) async {
    final result = await _ensureSubtitleMemoryEngine().applyIntent(intent);
    if (mounted && result.applied && result.zeroedInstantSubDelay) {
      _state = _state.copyWith(subtitleDelaySeconds: 0.0);
    }
    return result;
  }

  static bool _isTextSubtitlePath(String? rawPath) {
    if (rawPath == null) return false;
    final trimmed = rawPath.trim();
    if (trimmed.isEmpty || trimmed.startsWith('memory://')) return false;
    final ext = p.extension(trimmed.split('?').first).toLowerCase();
    return ext == '.ass' || ext == '.ssa' || ext == '.srt' || ext == '.vtt';
  }

  SubtitleChoice? get _selectedSubtitleChoice {
    for (final s in _state.subtitles) {
      if (s.selected) return s;
    }
    return null;
  }

  String? _resolveActiveExternalTextSubtitlePath() {
    final cached = _activeExternalSubtitleSourcePath;
    if (_isTextSubtitlePath(cached)) {
      return cached!.trim();
    }
    final active = _selectedSubtitleChoice;
    if (active != null && _isTextSubtitlePath(active.externalPath)) {
      return active.externalPath!.trim();
    }
    return null;
  }

  /// 当前激活主字幕是否具备可进行内存直注繁简转换或离线时间轴固化的外挂文本源。
  bool get hasExternalTextSubtitleSource =>
      _resolveActiveExternalTextSubtitlePath() != null;

  String _buildMemoryTrackTitle(
    String sourcePath, {
    required SubtitleOpenCcMode mode,
    bool remapped = false,
  }) {
    final base = (_activeExternalSubtitleTitle ?? p.basename(sourcePath)).trim();
    final suffix = <String>[
      if (mode == SubtitleOpenCcMode.toSimplified) '简',
      if (mode == SubtitleOpenCcMode.toTraditional) '繁',
      if (remapped) '调轴',
    ];
    return suffix.isEmpty ? base : '$base [${suffix.join('·')}]';
  }

  /// 通过内存直注无副作用字幕引擎切换主字幕 OpenCC 繁简模式（受三态子集保护门禁约束）。
  Future<SubtitleMemoryApplyResult?> setSubtitleOpenCcMode(
    SubtitleOpenCcMode mode,
  ) async {
    final sourcePath = _resolveActiveExternalTextSubtitlePath();
    final sourceExists = sourcePath != null && await File(sourcePath).exists();
    if (!sourceExists) {
      if (mode == SubtitleOpenCcMode.none &&
          _activeOriginalSubtitleTrackId != null) {
        final restored = await applyMemorySubtitleIntent(
          AuthoritativeSubtitleIntent(
            primary: SubtitleSlotRequest.existingTrack(
              _activeOriginalSubtitleTrackId!,
            ),
            instantSubDelaySeconds: _state.subtitleDelaySeconds,
          ),
        );
        if (mounted && restored.applied) {
          _state = _state.copyWith(
            subtitleOpenCcMode: SubtitleOpenCcMode.none,
            clearActiveSubtitleSubsetState: true,
          );
        }
        return restored;
      }
      showTransientBanner('当前内封或图形字幕暂不支持内存繁简转换，请选择外挂文本字幕');
      return null;
    }

    _activeExternalSubtitleSourcePath = sourcePath;
    final result = await applyMemorySubtitleIntent(
      AuthoritativeSubtitleIntent(
        primary: SubtitleSlotRequest.memory(
          localFilePath: sourcePath,
          fileName: p.basename(sourcePath),
          displayTitle: _buildMemoryTrackTitle(sourcePath, mode: mode),
          openCcMode: mode,
        ),
        instantSubDelaySeconds: _state.subtitleDelaySeconds,
      ),
    );
    if (!mounted || !result.applied) return result;

    _state = _state.copyWith(
      subtitleOpenCcMode: mode,
      activeSubtitleSubsetState: result.primarySubsetState,
      clearActiveSubtitleSubsetState: result.primarySubsetState == null,
    );
    if (result.primaryOpenCcSkipReason ==
        'opaque_obfuscated_subset_protected') {
      showTransientBanner('检测到混淆子集字体，已自动保护原文防乱码');
    } else if (mode == SubtitleOpenCcMode.toSimplified) {
      showTransientBanner('已通过内存直注切换为简体字幕');
    } else if (mode == SubtitleOpenCcMode.toTraditional) {
      showTransientBanner('已通过内存直注切换为繁体字幕');
    } else {
      showTransientBanner('已恢复字幕原文');
    }
    return result;
  }

  /// 将当前字幕延迟或倍率偏移离线重映射至内存直注轨道，并原子归零瞬时 `sub-delay`。
  Future<SubtitleMemoryApplyResult?> bakeSubtitleTimelineOffset({
    double rateScale = 1.0,
  }) async {
    final transform = SubtitleTimelineTransform(
      rateScale: rateScale,
      offsetSeconds: _state.subtitleDelaySeconds,
      isPausedAlignment: !_state.isPlaying,
    );
    if (transform.isIdentity) {
      showTransientBanner('当前字幕延迟为 0，无需固化时间轴');
      return null;
    }
    final sourcePath = _resolveActiveExternalTextSubtitlePath();
    final sourceExists = sourcePath != null && await File(sourcePath).exists();
    if (!sourceExists) {
      showTransientBanner('仅外挂文本字幕支持离线时间轴固化');
      return null;
    }

    _activeExternalSubtitleSourcePath = sourcePath;
    final result = await applyMemorySubtitleIntent(
      AuthoritativeSubtitleIntent(
        primary: SubtitleSlotRequest.memory(
          localFilePath: sourcePath,
          fileName: p.basename(sourcePath),
          displayTitle: _buildMemoryTrackTitle(
            sourcePath,
            mode: _state.subtitleOpenCcMode,
            remapped: true,
          ),
          openCcMode: _state.subtitleOpenCcMode,
          timelineTransform: transform,
        ),
      ),
    );
    if (mounted && result.applied) {
      _state = _state.copyWith(
        activeSubtitleSubsetState: result.primarySubsetState,
        clearActiveSubtitleSubsetState: result.primarySubsetState == null,
      );
      showTransientBanner('已通过内存直注固化字幕时间轴并归零延迟');
    }
    return result;
  }

  /// 经单一串行权威通道独立挂载或关闭双语副字幕（`secondary-sid`），绝不干扰当前主字幕槽位。
  Future<SubtitleMemoryApplyResult> selectSecondarySubtitle(
    SubtitleChoice? choice,
  ) async {
    final currentPrimary = _selectedSubtitleChoice;
    final primarySlot = currentPrimary?.mpvTrackId != null
        ? SubtitleSlotRequest.existingTrack(currentPrimary!.mpvTrackId!)
        : null;

    SubtitleSlotRequest? secondarySlot;
    if (choice != null) {
      if (choice.mpvTrackId != null) {
        secondarySlot = SubtitleSlotRequest.existingTrack(
          choice.mpvTrackId!,
          displayTitle: choice.primaryTitle,
        );
      } else if (_isTextSubtitlePath(choice.externalPath)) {
        final filePath = choice.externalPath!.trim();
        if (await File(filePath).exists()) {
          secondarySlot = SubtitleSlotRequest.memory(
            localFilePath: filePath,
            fileName: p.basename(filePath),
            displayTitle: choice.primaryTitle,
          );
        }
      }
    }

    final result = await applyMemorySubtitleIntent(
      AuthoritativeSubtitleIntent(
        primary: primarySlot,
        secondary: secondarySlot,
        updateSecondary: true,
      ),
    );
    if (mounted && result.applied) {
      _state = _state.copyWith(
        secondarySubtitleTrackId: result.secondaryTrackId,
        clearSecondarySubtitleTrackId: result.secondaryTrackId == null,
      );
      showTransientBanner(
        result.secondaryTrackId == null
            ? '已关闭双语副字幕'
            : '已启用双语副字幕：${choice?.primaryTitle ?? ''}',
      );
    }
    return result;
  }

  void selectSubtitle(SubtitleChoice? choice) {
    _subtitleMemoryEngine?.invalidatePendingIntents();
    _session?.selectSubtitle(choice);
    if (choice == null) {
      _activeExternalSubtitleSourcePath = null;
      _activeOriginalSubtitleTrackId = null;
      _activeExternalSubtitleTitle = null;
    } else if (_isTextSubtitlePath(choice.externalPath)) {
      _activeExternalSubtitleSourcePath = choice.externalPath!.trim();
      _activeOriginalSubtitleTrackId = choice.mpvTrackId;
      _activeExternalSubtitleTitle = choice.primaryTitle;
    } else {
      _activeExternalSubtitleSourcePath = null;
      _activeOriginalSubtitleTrackId = choice.mpvTrackId;
      _activeExternalSubtitleTitle = null;
    }
    final nextMemory = _state.trackMemory.rememberSubtitle(
      choice == null || choice.mpvTrackId == null
          ? (choice == null
                ? null
                : MpvTrackInfo(
                    id: -1,
                    type: MpvTrackType.subtitle,
                    title: choice.title,
                    lang: choice.language,
                    codec: choice.codec,
                    isExternal: true,
                    externalFilename: choice.externalPath,
                  ))
          : MpvTrackInfo(
              id: choice.mpvTrackId!,
              type: MpvTrackType.subtitle,
              title: choice.title,
              lang: choice.language,
              codec: choice.codec,
              isExternal: choice.isExternal,
              externalFilename: choice.externalPath,
            ),
    );
    _state = _state.copyWith(
      trackMemory: nextMemory,
      subtitleOpenCcMode: SubtitleOpenCcMode.none,
      clearActiveSubtitleSubsetState: true,
    );
  }

  void addExternalSubtitleFile(String path) {
    _subtitleMemoryEngine?.invalidatePendingIntents();
    _session?.addExternalSubtitleFile(path);
    showTransientBanner('已加载外挂字幕');
  }

  void selectAudioTrack(AudioTrackChoice choice) {
    _session?.selectAudioTrack(choice);
    final nextMemory = _state.trackMemory.rememberAudio(
      MpvTrackInfo(
        id: choice.mpvTrackId ?? -1,
        type: MpvTrackType.audio,
        title: choice.title,
        lang: choice.language,
        codec: choice.codec,
        isExternal: choice.isExternal,
        externalFilename: choice.externalPath,
      ),
    );
    _state = _state.copyWith(trackMemory: nextMemory);
  }

  void setSubtitleDelay(double delaySeconds) {
    _subtitleMemoryEngine?.invalidatePendingIntents();
    final clamped = double.parse(
      delaySeconds.clamp(-60.0, 60.0).toStringAsFixed(2),
    );
    _session?.setSubtitleDelay(clamped);
    _state = _state.copyWith(subtitleDelaySeconds: clamped);
  }

  void setAudioDelay(double delaySeconds) {
    final clamped = double.parse(
      delaySeconds.clamp(-60.0, 60.0).toStringAsFixed(2),
    );
    _session?.setAudioDelay(clamped);
    _state = _state.copyWith(audioDelaySeconds: clamped);
  }

  Future<void> updateLiveQuality(
    PlaybackQualityConfig Function(PlaybackQualityConfig) updater,
  ) async {
    await _ref
        .read(playbackPreferencesProvider.notifier)
        .updateQualityConfig(updater);
    final nextConfig = _ref.read(playbackPreferencesProvider).qualityConfig;
    _session?.applyLiveQualityConfig(nextConfig);
  }

  /// 一键重置字幕延迟、OpenCC 繁简模式、字号、底部边距与 ASS 样式覆写模式为标准默认值。
  Future<void> resetSubtitleAdjustments() async {
    setSubtitleDelay(0);
    if (_state.subtitleOpenCcMode != SubtitleOpenCcMode.none) {
      await setSubtitleOpenCcMode(SubtitleOpenCcMode.none);
    }
    await updateLiveQuality(
      (c) => c.copyWith(
        subFontSize: PlaybackQualityConfig.defaultSubFontSize,
        subBottomMargin: PlaybackQualityConfig.defaultSubBottomMargin,
        subOverrideMode: SubtitleAssOverrideMode.preserveAss,
      ),
    );
  }
}
