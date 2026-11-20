part of 'video_playback_controller.dart';

/// `VideoPlaybackController` 内存字幕增强引擎、字库入池联动、云端子集化与音画实时配置扩展。
extension VideoPlaybackControllerSubtitles on VideoPlaybackController {
  SubtitleMemoryEngine _ensureSubtitleMemoryEngine() {
    return _subtitleMemoryEngine ??= SubtitleMemoryEngine(
      clientSupplier: () => _session?.activeClient,
      playbackEngine: _engine,
      legacyCodePageDecoder: _ref.read(legacyCodePageDecoderProvider),
      cloudSubsetTransform: _tryCloudSubsetAssContent,
      onAssContentPrepared: _ingestAssEmbeddedFontsIfPresent,
      onTrackStateChanged: () => _session?.refreshMetadata(),
    );
  }

  Future<Uri?> _resolveAuthorizedCloudSubsetEndpoint() async {
    final prefs = _ref.read(playbackPreferencesProvider);
    if (!prefs.cloudSubsetEnabled) return null;
    final raw = prefs.cloudSubsetEndpoint.trim();
    if (raw.isEmpty) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty) {
      return null;
    }
    final authStore = _ref.read(cloudSubsetAuthorizationStoreProvider);
    await authStore.ensureHydrated();
    if (!authStore.isAuthorized(uri)) return null;
    return uri;
  }

  Future<String?> _tryCloudSubsetAssContent(String originalAssContent) async {
    if (originalAssContent.contains('[Fonts]')) {
      return null;
    }
    final endpointUri = await _resolveAuthorizedCloudSubsetEndpoint();
    if (endpointUri == null) return null;
    try {
      final result = await _ref
          .read(cloudSubsetCoordinatorProvider)
          .runCloudSubset(
            endpointUri: endpointUri,
            originalAssContent: originalAssContent,
          );
      _logStore.record(
        'mpv-cloud-subset',
        '云端字体子集化命中 ${result.origin.key}（缓存复用=${result.fromLocalCache}）',
      );
      return result.subsettedAssContent;
    } on CloudSubsetCancelledException {
      return null;
    } on Object catch (e) {
      _logStore.record('mpv-cloud-subset', '云端字体子集化降级回退本地正文：$e');
      return null;
    }
  }

  Future<void> _ingestAssEmbeddedFontsIfPresent(String assContent) async {
    try {
      final pool = _ref.read(subtitleFontPoolManagerProvider);
      final resolved = await pool.ingestAssEmbeddedFonts(assContent);
      if (resolved != null && mounted && !(_state.isClosing)) {
        _session?.applySubFontsDir(resolved.directoryPath);
        _logStore.record(
          'mpv-fonts',
          'ASS [Fonts] 内嵌字库入池成功（${resolved.fontCount} 个字体，复用=${resolved.reusedFromLease}）',
        );
      }
    } on Object catch (e) {
      _logStore.record('mpv-fonts', '提取 ASS [Fonts] 字体忽略：$e');
    }
  }

  Map<int, String> _readMountedSubtitleSourcePaths() {
    return _subtitleMemoryEngine?.mountedSourcePathsSnapshot ??
        const <int, String>{};
  }

  /// 起播自动发现的外挂文本字幕统一经单一串行 `SubtitleMemoryEngine` 通道编码归一与 `cached` 挂载选轨。
  Future<void> _mountDiscoveredExternalTextSubtitles(
    List<String> textSubtitlePaths,
    CrossEpisodeTrackMemory trackMemory,
    TrackPreferences trackPreferences,
  ) async {
    if (!mounted || _state.isClosing || textSubtitlePaths.isEmpty) return;
    final endpoint = await _resolveAuthorizedCloudSubsetEndpoint();
    final result = await _ensureSubtitleMemoryEngine()
        .mountDiscoveredExternalSubtitles(
          textSubtitlePaths: textSubtitlePaths,
          trackMemory: trackMemory,
          trackPreferences: trackPreferences,
          enableCloudSubsetForSelected: endpoint != null,
        );
    if (!mounted || !result.applied) return;
    final primaryId = result.primaryTrackId;
    if (primaryId != null) {
      final srcPath = _ensureSubtitleMemoryEngine().lookupSourcePathForTrackId(
        primaryId,
      );
      if (srcPath != null && _isTextSubtitlePath(srcPath)) {
        _activeExternalSubtitleSourcePath = srcPath;
        _activeOriginalSubtitleTrackId = primaryId;
        _activeExternalSubtitleTitle = p.basename(srcPath);
      }
    }
  }

  /// 经单一串行权威通道执行内存级无副作用字幕挂载（多编码归一 / 云端子集 / OpenCC / 离线调轴）。
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
    return KonataMediaExtensions.isTextSubtitleFile(trimmed.split('?').first);
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
    if (active != null) {
      if (_isTextSubtitlePath(active.externalPath)) {
        return active.externalPath!.trim();
      }
      if (active.mpvTrackId != null) {
        final mapped = _subtitleMemoryEngine?.lookupSourcePathForTrackId(
          active.mpvTrackId!,
        );
        if (_isTextSubtitlePath(mapped)) {
          return mapped!.trim();
        }
      }
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
    bool cloudSubset = false,
  }) {
    final base = (_activeExternalSubtitleTitle ?? p.basename(sourcePath)).trim();
    final suffix = <String>[
      if (mode == SubtitleOpenCcMode.toSimplified) '简',
      if (mode == SubtitleOpenCcMode.toTraditional) '繁',
      if (remapped) '调轴',
      if (cloudSubset) '子集',
    ];
    return suffix.isEmpty ? base : '$base [${suffix.join('·')}]';
  }

  /// 对当前激活外挂 ASS 字幕手动触发一次已授权云端字体子集化并直注内存轨道。
  Future<SubtitleMemoryApplyResult?> applyCloudSubsetToActiveSubtitle() async {
    final endpoint = await _resolveAuthorizedCloudSubsetEndpoint();
    if (endpoint == null) {
      showTransientBanner('请先在设置中启用并授权云端子集化服务 Origin');
      return null;
    }
    final sourcePath = _resolveActiveExternalTextSubtitlePath();
    final sourceExists = sourcePath != null && await File(sourcePath).exists();
    if (!sourceExists) {
      showTransientBanner('当前字幕并非本地外挂 ASS 文本源');
      return null;
    }
    final result = await applyMemorySubtitleIntent(
      AuthoritativeSubtitleIntent(
        primary: SubtitleSlotRequest.memory(
          localFilePath: sourcePath,
          fileName: p.basename(sourcePath),
          displayTitle: _buildMemoryTrackTitle(
            sourcePath,
            mode: _state.subtitleOpenCcMode,
            cloudSubset: true,
          ),
          openCcMode: _state.subtitleOpenCcMode,
          enableCloudSubset: true,
        ),
        instantSubDelaySeconds: _state.subtitleDelaySeconds,
      ),
    );
    if (mounted && result.applied) {
      showTransientBanner(
        result.cloudSubsetApplied ? '已应用经语义核验的云端子集化字库' : '当前字幕已含字体或云端子集化未生效',
      );
    }
    return result;
  }

  /// 通过内存直注无副作用字幕引擎切换主字幕 OpenCC 繁简模式（受三态子集保护门禁约束）。
  Future<SubtitleMemoryApplyResult?> setSubtitleOpenCcMode(
    SubtitleOpenCcMode mode,
  ) async {
    if (mode == _state.subtitleOpenCcMode) {
      return null;
    }
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
    _activeExternalSubtitleTitle = p.basename(sourcePath);
    final originalTrackId = mode == SubtitleOpenCcMode.none
        ? _ensureSubtitleMemoryEngine().lookupOriginalTrackIdForSourcePath(
            sourcePath,
          )
        : null;
    final slot = originalTrackId != null
        ? SubtitleSlotRequest.existingTrack(
            originalTrackId,
            displayTitle: p.basename(sourcePath),
          )
        : SubtitleSlotRequest.memory(
            localFilePath: sourcePath,
            fileName: p.basename(sourcePath),
            displayTitle: _buildMemoryTrackTitle(sourcePath, mode: mode),
            openCcMode: mode,
            enableCloudSubset: true,
          );
    final result = await applyMemorySubtitleIntent(
      AuthoritativeSubtitleIntent(
        primary: slot,
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
          enableCloudSubset: true,
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

  /// 经单一串行权威通道切换当前主字幕（所有外挂文本字幕一律经 `SubtitleMemoryEngine` 编码归一与 `cached` 挂载）。
  void selectSubtitle(SubtitleChoice? choice) {
    if (choice == null) {
      _activeExternalSubtitleSourcePath = null;
      _activeOriginalSubtitleTrackId = null;
      _activeExternalSubtitleTitle = null;
      unawaited(
        applyMemorySubtitleIntent(const AuthoritativeSubtitleIntent.disable()),
      );
    } else if (_isTextSubtitlePath(choice.externalPath)) {
      final path = choice.externalPath!.trim();
      final memEngine = _ensureSubtitleMemoryEngine();
      final originalMountedId = memEngine.lookupOriginalTrackIdForSourcePath(
        path,
      );
      _activeExternalSubtitleSourcePath = path;
      _activeOriginalSubtitleTrackId = originalMountedId ?? choice.mpvTrackId;
      _activeExternalSubtitleTitle = p.basename(path);
      final existingMountedId =
          originalMountedId ??
          choice.mpvTrackId ??
          memEngine.lookupTrackIdForSourcePath(path);
      final slot = existingMountedId != null
          ? SubtitleSlotRequest.existingTrack(
              existingMountedId,
              displayTitle: p.basename(path),
            )
          : SubtitleSlotRequest.memory(
              localFilePath: path,
              fileName: p.basename(path),
              displayTitle: p.basename(path),
              enableCloudSubset: true,
            );
      unawaited(
        applyMemorySubtitleIntent(
          AuthoritativeSubtitleIntent(
            primary: slot,
            instantSubDelaySeconds: _state.subtitleDelaySeconds,
          ),
        ),
      );
    } else if (choice.mpvTrackId != null) {
      final mappedSource = _subtitleMemoryEngine?.lookupSourcePathForTrackId(
        choice.mpvTrackId!,
      );
      _activeExternalSubtitleSourcePath = mappedSource;
      _activeOriginalSubtitleTrackId = choice.mpvTrackId;
      _activeExternalSubtitleTitle = mappedSource != null
          ? choice.primaryTitle
          : null;
      unawaited(
        applyMemorySubtitleIntent(
          AuthoritativeSubtitleIntent(
            primary: SubtitleSlotRequest.existingTrack(
              choice.mpvTrackId!,
              displayTitle: choice.primaryTitle,
            ),
            instantSubDelaySeconds: _state.subtitleDelaySeconds,
          ),
        ),
      );
    } else {
      // 仅对二进制图形外挂字幕（.sup / .idx）走原生文件挂载兜底。
      _activeExternalSubtitleSourcePath = null;
      _activeOriginalSubtitleTrackId = null;
      _activeExternalSubtitleTitle = null;
      _subtitleMemoryEngine?.invalidatePendingIntents();
      _session?.selectSubtitle(choice);
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

  /// 手动加载外挂字幕文件（所有文本字幕统一经单一串行 `SubtitleMemoryEngine` 编码归一、字库入池与 `memory://` 直注）。
  void addExternalSubtitleFile(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return;
    if (_isTextSubtitlePath(trimmed)) {
      _activeExternalSubtitleSourcePath = trimmed;
      _activeExternalSubtitleTitle = p.basename(trimmed);
      unawaited(
        applyMemorySubtitleIntent(
          AuthoritativeSubtitleIntent(
            primary: SubtitleSlotRequest.memory(
              localFilePath: trimmed,
              fileName: p.basename(trimmed),
              displayTitle: p.basename(trimmed),
              enableCloudSubset: true,
            ),
            instantSubDelaySeconds: _state.subtitleDelaySeconds,
          ),
        ),
      );
      showTransientBanner('已通过内存直注加载外挂字幕');
      return;
    }
    _subtitleMemoryEngine?.invalidatePendingIntents();
    _session?.addExternalSubtitleFile(trimmed);
    showTransientBanner('已加载图形外挂字幕');
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
    final clamped = double.parse(
      delaySeconds.clamp(-60.0, 60.0).toStringAsFixed(2),
    );
    if (_session?.activeClient != null) {
      _ensureSubtitleMemoryEngine().setInstantSubtitleDelay(clamped);
    } else {
      _subtitleMemoryEngine?.invalidatePendingIntents();
      _session?.setSubtitleDelay(clamped);
    }
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
