part of 'video_playback_controller.dart';

/// `VideoPlaybackController` 跨季连播、连续坏文件熔断、章节跳过、缩略图预热与进度落库扩展。
extension VideoPlaybackControllerEpisodes on VideoPlaybackController {
  /// 根据信息探针面板显隐按需选择全量 65 项或轻量 5 项属性采集，避免起播期 FFI 锁竞争。
  PlaybackProbeStats _collectAppropriateProbeStats(EmbeddedMpvSession session) {
    return _state.probeOverlayVisible
        ? session.collectProbeStats()
        : session.collectLightProbeStats(previous: _state.probeStats);
  }

  /// 在后台并行发现可用 GLSL 着色器并回填侧栏，不阻塞视频首帧起播。
  Future<void> _discoverAvailableShadersInBackground(
    StorageRootService storageRoot,
  ) async {
    try {
      final shadersDir = await storageRoot.ensureShadersDir();
      final shaders = await MpvQualityProfile.discoverShaderFiles(shadersDir);
      if (mounted && !_state.isClosing && !_closedCleanly) {
        _state = _state.copyWith(availableShaders: shaders);
      }
    } catch (e) {
      _logStore.record('VIDEO', '后台扫描着色器目录忽略：$e');
    }
  }

  void _handleMetadataUpdated({
    required List<SubtitleChoice> subtitles,
    required List<AudioTrackChoice> audioTracks,
    required List<PlaybackChapter> chapters,
    required List<MpvAudioDevice> audioDevices,
  }) {
    if (!mounted) return;
    final activeSession = _session;
    final stats = activeSession == null
        ? _state.probeStats
        : _collectAppropriateProbeStats(activeSession);
    final silentHidden =
        !_hudProgressActive &&
        !_state.probeOverlayVisible &&
        !_state.sideSheetOpen;
    if (silentHidden &&
        subtitles.length == _state.subtitles.length &&
        audioTracks.length == _state.audioTracks.length &&
        chapters.length == _state.chapters.length &&
        stats.videoWidth == _state.probeStats.videoWidth &&
        stats.videoHeight == _state.probeStats.videoHeight &&
        stats.hwdecCurrent == _state.probeStats.hwdecCurrent) {
      _pendingMetadataUiRefresh = true;
      return;
    }
    _pendingMetadataUiRefresh = false;
    _state = _state.copyWith(
      subtitles: subtitles,
      audioTracks: audioTracks,
      chapters: chapters,
      availableAudioDevices: audioDevices,
      probeStats: stats,
    );
    if (KonataPlatform.isAndroid &&
        !_state.audioOnlyMode &&
        (stats.videoWidth ?? 0) > 0 &&
        _ref.read(activeVideoSessionProvider).isExpanded) {
      unawaited(
        AndroidPlaybackWindowBridge.applyVideoOrientationAndWindow(
          landscape: true,
          hideSystemBars: true,
        ),
      );
    }
    _recomputeChapterSkipPlan();
    _thumbnailService?.updateChapters(
      chapters,
      durationSeconds: _state.durationSeconds > 0
          ? _state.durationSeconds
          : null,
    );
  }

  /// 读取或按需拉取并缓存同系列其他成员的完整详情包（供选集浏览与跨季连播复用）。
  Future<WorkDetailBundle?> loadSeriesWorkBundle(String workId) async {
    final cached = _bundleCacheByWorkId[workId];
    if (cached != null) return cached;
    try {
      final fetched = await _ref.read(workDetailBundleProvider(workId).future);
      if (fetched != null) {
        _bundleCacheByWorkId[workId] = fetched;
      }
      return fetched;
    } catch (e) {
      _logStore.record('VIDEO', '拉取同系列作品 $workId 详情包失败：$e', isError: true);
      return null;
    }
  }

  Future<void> _preloadAdjacentSeriesBundles() async {
    final members = orderedSeriesMembers;
    if (members.length < 2) return;
    final idx = members.indexWhere((m) => m.id == activeWork.id);
    if (idx < 0) return;
    if (idx + 1 < members.length) {
      await loadSeriesWorkBundle(members[idx + 1].id);
    }
    if (idx - 1 >= 0) {
      await loadSeriesWorkBundle(members[idx - 1].id);
    }
  }

  List<Episode> _playableMainEpisodesFor(WorkDetailBundle bundle) {
    return Episode.sortMainFirst(
      bundle.episodes.where(
        (e) =>
            e.category == EpisodeCategory.main &&
            bundle.variantsForEpisode(e.id).isNotEmpty,
      ),
    );
  }

  List<Episode> _playableExtraEpisodesFor(WorkDetailBundle bundle) {
    return Episode.sortMainFirst(
      bundle.episodes.where(
        (e) =>
            e.category == EpisodeCategory.extra &&
            bundle.variantsForEpisode(e.id).isNotEmpty,
      ),
    );
  }

  /// 有序同作品正片剧集列表（严格正片集号升序，特典置于正片之后）。
  List<Episode> get orderedMainEpisodes => Episode.sortMainFirst(
    activeBundle.episodes.where((e) => e.category == EpisodeCategory.main),
  );

  /// 当前分集的展示标题。
  String get currentEpisodeTitle {
    return EpisodeTitleFormatter.formatCardTitle(
      episode: _state.currentEpisode,
      workTitle: activeWork.title,
      workMediaType: activeWork.tmdbMediaType,
      mainEpisodeCount: orderedMainEpisodes.length,
    );
  }

  /// 查找当前作品内部的下一集（正片只找正片、特典只找特典）。
  Episode? findNextEpisode() {
    final ep = _state.currentEpisode;
    final list = ep.category == EpisodeCategory.main
        ? _playableMainEpisodesFor(activeBundle)
        : _playableExtraEpisodesFor(activeBundle);
    final idx = list.indexWhere((e) => e.id == ep.id);
    if (idx < 0 || idx + 1 >= list.length) return null;
    return list[idx + 1];
  }

  /// 查找当前作品内部的上一集（正片只找正片、特典只找特典）。
  Episode? findPreviousEpisode() {
    final ep = _state.currentEpisode;
    final list = ep.category == EpisodeCategory.main
        ? _playableMainEpisodesFor(activeBundle)
        : _playableExtraEpisodesFor(activeBundle);
    final idx = list.indexWhere((e) => e.id == ep.id);
    if (idx <= 0) return null;
    return list[idx - 1];
  }

  /// 是否存在可切换的下一集实现（含跨季正片连播越过本季特典）。
  bool _hasNextEpisodeAnyImpl() {
    if (findNextEpisode() != null) return true;
    if (_state.currentEpisode.category != EpisodeCategory.main) return false;
    final members = orderedSeriesMembers;
    final currentIdx = members.indexWhere((m) => m.id == activeWork.id);
    if (currentIdx < 0 || currentIdx + 1 >= members.length) return false;
    for (var i = currentIdx + 1; i < members.length; i++) {
      final cached = _bundleCacheByWorkId[members[i].id];
      if (cached == null || _playableMainEpisodesFor(cached).isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  /// 是否存在可切换的上一集实现（含跨季回退至上一季末集正片）。
  bool _hasPreviousEpisodeAnyImpl() {
    if (findPreviousEpisode() != null) return true;
    if (_state.currentEpisode.category != EpisodeCategory.main) return false;
    final members = orderedSeriesMembers;
    final currentIdx = members.indexWhere((m) => m.id == activeWork.id);
    if (currentIdx <= 0) return false;
    for (var i = currentIdx - 1; i >= 0; i--) {
      final cached = _bundleCacheByWorkId[members[i].id];
      if (cached == null || _playableMainEpisodesFor(cached).isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  /// 跨季越过特典状态机解析下一目标集。
  Future<({WorkDetailBundle bundle, Episode episode, bool isCrossSeason})?>
  resolveNextEpisodeTarget() async {
    final intraNext = findNextEpisode();
    if (intraNext != null) {
      return (bundle: activeBundle, episode: intraNext, isCrossSeason: false);
    }
    if (_state.currentEpisode.category != EpisodeCategory.main) {
      return null;
    }

    final members = orderedSeriesMembers;
    final currentIdx = members.indexWhere((m) => m.id == activeWork.id);
    if (currentIdx < 0 || currentIdx + 1 >= members.length) {
      return null;
    }

    for (var i = currentIdx + 1; i < members.length; i++) {
      final nextBundle = await loadSeriesWorkBundle(members[i].id);
      if (nextBundle == null) continue;
      final mains = _playableMainEpisodesFor(nextBundle);
      if (mains.isNotEmpty) {
        return (bundle: nextBundle, episode: mains.first, isCrossSeason: true);
      }
    }
    return null;
  }

  /// 对称跨季解析上一目标集（下一季第 01 集 `正片` 对称回退至上一季末集 `正片`）。
  Future<({WorkDetailBundle bundle, Episode episode, bool isCrossSeason})?>
  resolvePreviousEpisodeTarget() async {
    final intraPrev = findPreviousEpisode();
    if (intraPrev != null) {
      return (bundle: activeBundle, episode: intraPrev, isCrossSeason: false);
    }
    if (_state.currentEpisode.category != EpisodeCategory.main) {
      return null;
    }

    final members = orderedSeriesMembers;
    final currentIdx = members.indexWhere((m) => m.id == activeWork.id);
    if (currentIdx <= 0) {
      return null;
    }

    for (var i = currentIdx - 1; i >= 0; i--) {
      final prevBundle = await loadSeriesWorkBundle(members[i].id);
      if (prevBundle == null) continue;
      final mains = _playableMainEpisodesFor(prevBundle);
      if (mains.isNotEmpty) {
        return (bundle: prevBundle, episode: mains.last, isCrossSeason: true);
      }
    }
    return null;
  }

  /// 跳转并原地播放下一集实现（支持跨季无缝切换并显示描边连播提示）。
  Future<bool> _goToNextEpisodeImpl({bool isAutoAdvance = false}) async {
    final target = await resolveNextEpisodeTarget();
    if (target == null || !mounted || _state.isClosing) return false;
    await switchToEpisode(
      target.episode,
      targetBundle: target.bundle,
      startSeconds: 0,
      isAutoAdvance: isAutoAdvance,
      isCrossSeason: target.isCrossSeason,
    );
    return true;
  }

  /// 跳转并原地回退上一集实现（支持上一季末集正片对称回退）。
  Future<bool> _goToPreviousEpisodeImpl() async {
    final target = await resolvePreviousEpisodeTarget();
    if (target == null || !mounted || _state.isClosing) return false;
    await switchToEpisode(
      target.episode,
      targetBundle: target.bundle,
      startSeconds: 0,
      isAutoAdvance: false,
      isCrossSeason: target.isCrossSeason,
    );
    return true;
  }

  /// 派发全站居中毛玻璃胶囊提示（报错时传 `isError: true` 以红色胶囊区分）。
  void showTransientBanner(
    String message, {
    bool isError = false,
    Duration duration = const Duration(seconds: 4),
  }) {
    if (!mounted) return;
    final trimmed = message.trim();
    if (trimmed.isEmpty) return;
    _state = _state.copyWith(
      transientNotice: (
        seq: ++_transientNoticeSeq,
        message: trimmed,
        isError: isError,
        duration: duration,
      ),
    );
  }

  void previousChapterOrEpisode() {
    final chapters = _state.chapters;
    final pos =
        _session?.readCurrentPositionSeconds() ?? currentPositionSeconds;
    if (chapters.isNotEmpty) {
      PlaybackChapter? prev;
      for (final ch in chapters) {
        if (ch.startSeconds < pos - 2.0) {
          prev = ch;
        }
      }
      if (prev != null) {
        seekAbsolute(prev.startSeconds);
        showTransientBanner(
          prev.title.isNotEmpty ? '章节：${prev.title}' : '上一章节',
        );
        return;
      }
    }
    unawaited(() async {
      final moved = await goToPreviousEpisode();
      if (!moved) {
        seekAbsolute(0);
      }
    }());
  }

  void nextChapterOrEpisode() {
    final chapters = _state.chapters;
    final pos =
        _session?.readCurrentPositionSeconds() ?? currentPositionSeconds;
    if (chapters.isNotEmpty) {
      for (final ch in chapters) {
        if (ch.startSeconds > pos + 1.0) {
          seekAbsolute(ch.startSeconds);
          showTransientBanner(ch.title.isNotEmpty ? '章节：${ch.title}' : '下一章节');
          return;
        }
      }
    }
    unawaited(goToNextEpisode());
  }

  void _requestThumbnailPreviewLazy(double? seconds) {
    if (!mounted || _state.isClosing || _closedCleanly) return;
    if (seconds == null || !seconds.isFinite) {
      _thumbnailService?.requestPreview(null);
      return;
    }
    if (!_state.hasFirstFrame) return;

    var svc = _thumbnailService;
    if (svc == null) {
      svc = MpvThumbnailService(
        streamBridge: _streamBridge,
        gatewayFactory: _ref.read(mediaSourceGatewayFactoryProvider),
        logStore: _logStore,
        clientFactory: () => _engine.createAuxiliaryNativeClient(),
      );
      svc.addListener(_onThumbnailUpdated);
      _thumbnailService = svc;
    }

    svc.requestPreview(seconds);
    if (!svc.isWarmedUp && !svc.isWarmingUp) {
      final variant = _state.currentVariant;
      final source =
          activeBundle.sourcesById[variant.sourceId] ?? request.source;
      final gen = ++_thumbnailGeneration;
      unawaited(() async {
        if (!mounted ||
            _state.isClosing ||
            _closedCleanly ||
            gen != _thumbnailGeneration) {
          return;
        }
        await svc!.warmUp(
          variant: variant,
          source: source,
          chapters: _state.chapters,
          durationSeconds: _state.durationSeconds > 0
              ? _state.durationSeconds
              : null,
          preserveCache: true,
          preservePendingUserRequest: true,
        );
      }());
    }
  }

  void _onThumbnailUpdated() {
    if (!mounted) return;
    if (!_hudProgressActive) {
      _pendingThumbnailRevisionFlush = true;
      return;
    }
    _thumbnailRevision.value += 1;
  }

  Future<void> _releaseThumbnailService({required bool disposeNotifier}) async {
    ++_thumbnailGeneration;
    final svc = _thumbnailService;
    if (svc != null) {
      svc.removeListener(_onThumbnailUpdated);
      if (disposeNotifier) {
        _thumbnailService = null;
        await svc.release();
        svc.dispose();
      } else {
        await svc.release();
        _thumbnailService = null;
      }
    }
  }

  void _recomputeChapterSkipPlan() {
    if (_state.durationSeconds <= 0 || _state.chapters.isEmpty) {
      _skipPlan = const ChapterSkipPlan();
      _chapterSkipWakeTimer?.cancel();
      _chapterSkipWakeTimer = null;
      if (_state.activeSkipWindow != null) {
        _skipFadeTimer?.cancel();
        _state = _state.copyWith(clearSkipWindow: true);
      }
      return;
    }
    _skipPlan = ChapterSkipAnalyzer.analyze(
      rawChapters: _state.chapters,
      totalDurationSeconds: _state.durationSeconds,
      hasNextEpisode: hasNextEpisodeAny,
    );
    final active = _skipPlan.activeWindowAt(currentPositionSeconds);
    if (active == null && _state.activeSkipWindow != null) {
      _skipFadeTimer?.cancel();
      _state = _state.copyWith(clearSkipWindow: true);
    }
    if (!_hudProgressActive) {
      _scheduleNextChapterSkipWake();
    }
  }

  /// OSD 静默期使用单次精确计时器按需唤醒 OP/ED 跳过判定，彻底避免高频轮询。
  void _scheduleNextChapterSkipWake() {
    _chapterSkipWakeTimer?.cancel();
    _chapterSkipWakeTimer = null;
    if (!mounted || _hudProgressActive || !_state.isPlaying) return;
    final pos = _latestPositionSeconds;
    final candidates = <DetectedSkipWindow>[
      if (_skipPlan.opening != null) _skipPlan.opening!,
      if (_skipPlan.ending != null) _skipPlan.ending!,
    ];
    if (candidates.isEmpty) return;

    double? nextDeltaSeconds;
    for (final w in candidates) {
      if (w.containsPosition(pos)) {
        nextDeltaSeconds = 0.0;
        break;
      }
      if (w.startSeconds > pos) {
        final delta = w.startSeconds - pos;
        if (nextDeltaSeconds == null || delta < nextDeltaSeconds) {
          nextDeltaSeconds = delta;
        }
      }
    }
    if (nextDeltaSeconds == null) return;
    final effectiveSpeed = _state.speed > 0.1 ? _state.speed : 1.0;
    final waitMs = ((nextDeltaSeconds / effectiveSpeed) * 1000).ceil().clamp(
      50,
      3600 * 1000,
    );
    _chapterSkipWakeTimer = Timer(Duration(milliseconds: waitMs), () {
      if (!mounted || _hudProgressActive) return;
      final sampled = _session?.readCurrentPositionSeconds();
      if (sampled != null && sampled.isFinite) {
        _latestPositionSeconds = sampled;
        _evaluateChapterSkipWindow(sampled);
      }
      _scheduleNextChapterSkipWake();
    });
  }

  void _evaluateChapterSkipWindow(double posSeconds) {
    final prefs = _ref.read(playbackPreferencesProvider);
    final active = _skipPlan.activeWindowAt(posSeconds);
    if (active == null) {
      _dismissedSkipWindow = null;
      if (_state.activeSkipWindow != null) {
        _skipFadeTimer?.cancel();
        _state = _state.copyWith(clearSkipWindow: true);
      }
      return;
    }

    if (_dismissedSkipWindow == active) return;

    // 严格遵守防误判红线：无名 ~90s 层级二启发式候选（allowsAutoSkip == false）绝不自动跳过，仅展示手动胶囊。
    if (prefs.autoSkipChapter && active.allowsAutoSkip) {
      _dismissedSkipWindow = active;
      unawaited(executeSkipWindow(active));
      showTransientBanner('已自动${active.label}');
      return;
    }

    if ((prefs.promptChapterSkip ||
            (prefs.autoSkipChapter && !active.allowsAutoSkip)) &&
        _state.activeSkipWindow != active) {
      _state = _state.copyWith(activeSkipWindow: active);
      _skipFadeTimer?.cancel();
      _skipFadeTimer = Timer(
        PlaybackQualityConfig.skipPillAutoFadeDuration,
        () {
          if (!mounted) return;
          _dismissedSkipWindow = active;
          _state = _state.copyWith(clearSkipWindow: true);
        },
      );
    }
  }

  /// 执行智能跳过动作（OP / ED 跳 C-Part / ED 直接跳下一话或下一季第 01 话正片）。
  Future<void> executeSkipWindow(DetectedSkipWindow window) async {
    _dismissedSkipWindow = window;
    _skipFadeTimer?.cancel();
    _state = _state.copyWith(clearSkipWindow: true);
    if (window.kind == SkipActionKind.skipEdToNextEpisode) {
      final advanced = await goToNextEpisode();
      if (advanced) return;
    }
    seekAbsolute(window.endSeconds);
  }

  /// 当前报错是否适合提供「外部播放器打开」兜底（媒体源离线、鉴权失败或本地文件缺失时严禁误导打开外部播放器）。
  bool get errorAllowsExternalRelay {
    final msg = _state.errorMessage;
    if (msg == null || msg.isEmpty) return false;
    final bridgeKind = _streamBridge.lastErrorKind(
      token: _engine.mainStreamLease?.leaseToken,
      relativePath: _state.currentVariant.relativePath,
    );
    if (bridgeKind != null) return false;
    const accessHints = <String>[
      '不存在',
      '路径已变更',
      '盘符',
      '无法连接',
      '未开启',
      '网络不可达',
      '连接超时',
      '认证失败',
      '鉴权',
      '权限不足',
      'HTTP 401',
      'HTTP 403',
      'HTTP 404',
      '媒体源',
    ];
    for (final hint in accessHints) {
      if (msg.contains(hint)) return false;
    }
    return true;
  }

  /// 重新加载当前报错的分集（清零熔断计数并原地重试）。
  Future<void> retryCurrentEpisode() async {
    if (!mounted || _state.isClosing) return;
    _engine.recordManualSelection();
    await switchToEpisode(
      _state.currentEpisode,
      targetBundle: activeBundle,
      specificVariant: _state.currentVariant,
      startSeconds: currentPositionSeconds > 3 ? currentPositionSeconds : 0.0,
      isAutoAdvance: false,
    );
  }

  void _handleEndOfFile(int reason, int errorCode) {
    if (!mounted || _state.isClosing) return;
    if (reason == MpvEndFileReason.eof) {
      final prefs = _ref.read(playbackPreferencesProvider);
      if (prefs.autoNextEpisode) {
        unawaited(goToNextEpisode(isAutoAdvance: true));
      } else {
        unawaited(_persistProgress(isFinal: true));
      }
    } else if (reason == MpvEndFileReason.error) {
      unawaited(_handleEndOfFileError(errorCode));
    }
  }

  Future<({String message, bool deterministicSourceFailure})>
  _diagnoseVideoError(String fallbackMessage) async {
    final currentVariant = _state.currentVariant;
    final currentSource =
        activeBundle.sourcesById[currentVariant.sourceId] ?? request.source;
    final token = _engine.mainStreamLease?.leaseToken;
    final bridgeDiag = _streamBridge.describeLastError(
      token: token,
      relativePath: currentVariant.relativePath,
    );
    final bridgeKind = _streamBridge.lastErrorKind(
      token: token,
      relativePath: currentVariant.relativePath,
    );
    if (bridgeDiag != null && bridgeDiag.isNotEmpty) {
      return (message: bridgeDiag, deterministicSourceFailure: bridgeKind != null);
    }
    if (currentSource != null && currentSource.kind == MediaSourceKind.local) {
      final rootClean = currentSource.location.replaceAll(
        RegExp(r'[\\/]+$'),
        '',
      );
      final relClean = currentVariant.relativePath
          .replaceAll('\\', '/')
          .replaceAll(RegExp(r'^/+'), '')
          .split('/')
          .join(Platform.pathSeparator);
      final localPath = relClean.isEmpty
          ? currentSource.location
          : '$rootClean${Platform.pathSeparator}$relClean';
      if (!await File(localPath).exists()) {
        return (
          message:
              '本地视频文件不存在或磁盘未挂载（${currentVariant.relativePath}），请检查媒体源路径或重新扫描',
          deterministicSourceFailure: true,
        );
      }
    }
    return (message: fallbackMessage, deterministicSourceFailure: false);
  }

  Future<void> _handleEndOfFileError(int errorCode) async {
    if (!mounted || _state.isClosing) return;
    final diag = await _diagnoseVideoError(
      MpvError.describeVideoError(errorCode),
    );
    if (!mounted || _state.isClosing) return;
    _logStore.record('VIDEO', diag.message, isError: true);

    // 属于媒体源离线/连接拒绝/鉴权失败/本地文件缺失等确定性故障时，立即按真实原因停播报错，绝不盲目连跳 3 集。
    if (diag.deterministicSourceFailure) {
      _state = _state.copyWith(
        isInitializing: false,
        isBuffering: false,
        isPlaying: false,
        errorMessage: diag.message,
      );
      return;
    }

    final tripped = _engine.recordPhysicalMediaFailure();
    if (tripped) {
      _state = _state.copyWith(
        isInitializing: false,
        isBuffering: false,
        isPlaying: false,
        errorMessage:
            '连续 ${UnifiedPlaybackEngine.maxConsecutiveBadFiles} 个视频文件加载异常（${diag.message}），已熔断停播',
      );
      return;
    }
    final prefs = _ref.read(playbackPreferencesProvider);
    if (prefs.autoNextEpisode && hasNextEpisodeAny) {
      showTransientBanner(
        '当前分集加载异常（${diag.message}），自动尝试下一话',
        isError: true,
      );
      unawaited(goToNextEpisode(isAutoAdvance: true));
      return;
    }
    _state = _state.copyWith(
      isInitializing: false,
      isBuffering: false,
      isPlaying: false,
      errorMessage: diag.message,
    );
  }

  /// 无缝切换同作品或同系列下一季剧集/变体（先保存旧分集进度，递增物理媒体代数后热替换流）。
  Future<void> switchToEpisode(
    Episode episode, {
    WorkDetailBundle? targetBundle,
    MediaVariant? specificVariant,
    double? startSeconds,
    bool isAutoAdvance = false,
    bool isCrossSeason = false,
  }) async {
    final session = _session;
    if (session == null || !mounted || _state.isClosing) return;

    await _releaseThumbnailService(disposeNotifier: true);
    if (mounted) {
      _thumbnailRevision.value += 1;
    }

    // 关键交接顺序：切换上下文前先以旧 workId / episodeId 完成进度与完播态持久化。
    await _persistProgress(isFinal: true);
    if (!mounted || _state.isClosing) return;

    final resolvedBundle =
        targetBundle ??
        (episode.workId == activeWork.id
            ? activeBundle
            : await loadSeriesWorkBundle(episode.workId)) ??
        activeBundle;
    if (!mounted || _state.isClosing) return;

    final variants = resolvedBundle.variantsForEpisode(episode.id);
    if (variants.isEmpty) return;

    final oldWorkId = activeWork.id;
    final switchingWork = resolvedBundle.work.id != oldWorkId;
    _trackMemoryByWorkId[oldWorkId] = _state.trackMemory;
    final nextTrackMemory = switchingWork
        ? (_trackMemoryByWorkId[resolvedBundle.work.id] ??
              const CrossEpisodeTrackMemory())
        : _state.trackMemory;

    final nextVariant = specificVariant ?? variants.first;
    final nextSource = resolvedBundle.sourcesById[nextVariant.sourceId];

    final saved = resolvedBundle.playbackByEpisodeId[episode.id];
    _alreadyPersistedCompleted = saved?.isCompleted ?? false;
    _watchedTracker.reset();
    _skipPlan = const ChapterSkipPlan();
    _dismissedSkipWindow = null;

    final resumePos =
        startSeconds ??
        ((saved != null && !saved.isCompleted && saved.positionSeconds > 5)
            ? saved.positionSeconds.toDouble()
            : 0.0);

    _latestPositionSeconds = resumePos;
    _activeExternalSubtitleSourcePath = null;
    _activeOriginalSubtitleTrackId = null;
    _activeExternalSubtitleTitle = null;
    _prewarmAttemptedForEpisodeId = null;
    final adoptedPrewarm = _takePrewarmedTargetFor(episode.id, nextVariant.id);
    _state = _state.copyWith(
      currentWork: resolvedBundle.work,
      currentBundle: resolvedBundle,
      currentEpisode: episode,
      currentVariant: nextVariant,
      trackMemory: nextTrackMemory,
      isBuffering: true,
      hasFirstFrame: false,
      positionSeconds: resumePos.toDouble(),
      durationSeconds: 0.0,
      subtitleDelaySeconds: 0.0,
      audioDelaySeconds: 0.0,
      subtitleOpenCcMode: SubtitleOpenCcMode.none,
      clearSecondarySubtitleTrackId: true,
      clearActiveSubtitleSubsetState: true,
      chapters: const [],
      clearSkipWindow: true,
      clearError: true,
    );

    if (switchingWork) {
      unawaited(_preloadAdjacentSeriesBundles());
    }

    // 换集时严格推进统一内核物理媒体代数；仅用户主动点选时清零连续坏文件熔断计数。
    _boundPhysicalEpoch = _engine.beginPhysicalMedia(
      nativeInstanceId: _boundNativeInstanceId,
      stage: PlaybackStageKind.video,
    );
    if (!isAutoAdvance) {
      _engine.recordManualSelection();
    }

    unawaited(ensureAudioFocus());
    _subtitleMemoryEngine?.resetForPhysicalMediaEpoch();
    await session.loadMediaVariant(
      EmbeddedVideoLoadRequest(
        workId: resolvedBundle.work.id,
        variant: nextVariant,
        source: nextSource,
        startSeconds: resumePos,
        prewarmedStreamToken: adoptedPrewarm?.streamToken,
        prewarmedMediaTarget: adoptedPrewarm?.mediaTarget,
      ),
      trackMemory: nextTrackMemory,
      trackPreferences: const TrackPreferences(),
    );

    if ((isAutoAdvance || isCrossSeason) && mounted) {
      final epLabel = EpisodeTitleFormatter.formatCardTitle(
        episode: episode,
        workTitle: resolvedBundle.work.title,
        workMediaType: resolvedBundle.work.tmdbMediaType,
        mainEpisodeCount: orderedMainEpisodes.length,
      );
      final notice = isCrossSeason
          ? '已跨季连播：${SeriesSeasonFormatter.formatMemberLabel(resolvedBundle.work, orderedSeriesMembers, seriesGroup: resolvedBundle.seriesGroup)} · $epLabel'
          : '已自动连播：$epLabel';
      showTransientBanner(
        notice,
        duration: PlaybackQualityConfig.autoNextEpisodeToastDuration,
      );
    }
  }

  /// 双模原画截图内部实现（返回桌面文件或 Android `MediaStore` 相册 URI）。
  Future<ScreenshotCaptureResult?> _captureScreenshotImpl({
    ScreenshotCaptureMode mode = ScreenshotCaptureMode.pureVideo,
  }) async {
    final session = _session;
    if (session == null) return null;
    final work = activeWork;
    final photos = _ref.read(photosStorageProvider);
    final workDir = await photos.resolveWorkDirectory(
      work.id,
      title: work.title,
    );
    final epTag = _state.currentEpisode.episodeNumber != null
        ? 'EP${EpisodeTitleFormatter.formatEpisodeNumberLabel(_state.currentEpisode.episodeNumber!, _state.currentEpisode.episodeNumberEnd)}'
        : null;
    final res = await session.captureScreenshot(
      workPhotoDir: workDir,
      episodeTag: epTag,
      mode: mode,
      albumName: 'Konata',
    );
    if (res != null) {
      showTransientBanner('已保存${res.mode.label}截图：${res.displayLabel}');
    }
    return res;
  }

  /// 一键热接力至桌面接力程序：携带精确当前秒数退出内置播放页并在外部程序续播回写。
  Future<LaunchPlaybackResult> relayToDesktopPlayer([String? targetId]) async {
    final relayPos =
        (_session?.readCurrentPositionSeconds() ?? currentPositionSeconds)
            .round();
    final work = activeWork;
    final bundle = activeBundle;
    final ep = _state.currentEpisode;
    final variant = _state.currentVariant;
    final src = bundle.sourcesById[variant.sourceId];

    await closeAndRelease();

    return _ref
        .read(playbackCoordinatorProvider)
        .playVariant(
          work: work,
          episode: ep,
          variant: variant,
          sourceType: src?.kind ?? MediaSourceKind.local,
          source: src,
          targetId: targetId,
          startSeconds: relayPos,
          mainEpisodeCount: orderedMainEpisodes.length,
        );
  }

  Future<void> _persistProgress({
    required bool isFinal,
    VideoPlaybackState? snapshotOverride,
    double? positionOverride,
    LibraryRepository? repoOverride,
    BangumiSyncController? bangumiSyncOverride,
  }) async {
    final snap = snapshotOverride ?? (mounted ? _state : null);
    if (snap == null) return;
    final work = snap.currentWork ?? request.work;
    final bundle = snap.currentBundle ?? request.bundle;
    final ep = snap.currentEpisode;
    final variant = snap.currentVariant;
    final durDouble = snap.durationSeconds;
    final posDouble =
        positionOverride ??
        (_hudProgressActive
            ? currentPositionSeconds
            : (_session?.readCurrentPositionSeconds() ?? currentPositionSeconds));
    _latestPositionSeconds = posDouble;
    if (!isFinal) {
      _maybeScheduleNextEpisodePrewarm(posDouble);
    }
    final durSeconds = durDouble > 0 ? durDouble.round() : 0;
    final persistedPos = _watchedTracker.resolvePersistedPositionSeconds(
      positionSeconds: posDouble,
      durationSeconds: durDouble,
    );
    final completed =
        _alreadyPersistedCompleted ||
        (durDouble > 0 && _watchedTracker.isCompleted(durDouble)) ||
        PlaybackRecord.computeCompleted(
          positionSeconds: persistedPos,
          durationSeconds: durSeconds,
        );

    if (posDouble < 1.0 && !completed && !isFinal) return;

    final repo =
        repoOverride ?? (mounted ? _ref.read(libraryRepositoryProvider) : null);
    if (repo == null) return;
    final src = bundle.sourcesById[variant.sourceId];
    final recordId = '${work.id}::${ep.id}';
    final record = PlaybackRecord(
      id: recordId,
      workId: work.id,
      episodeId: ep.id,
      variantId: variant.id,
      seasonNumber: ep.seasonNumber,
      episodeNumber: ep.episodeNumber,
      episodeTitle:
          ep.title ??
          (ep.episodeNumber != null
              ? '第 ${ep.episodeNumberEnd == null ? '${ep.episodeNumber}' : '${ep.episodeNumber}-${ep.episodeNumberEnd}'} 话'
              : (ep.category == EpisodeCategory.extra
                    ? (ep.extraType?.name.toUpperCase() ?? '特典')
                    : work.title)),
      sourceType: src?.kind ?? MediaSourceKind.local,
      playedAt: DateTime.now(),
      positionSeconds: persistedPos,
      durationSeconds: durSeconds,
      isCompleted: completed,
    );

    final newlyCompleted = !_alreadyPersistedCompleted && completed;
    await repo.recordPlayback(record);
    _alreadyPersistedCompleted = completed;
    if (newlyCompleted) {
      final bangumiSync =
          bangumiSyncOverride ??
          (mounted ? _ref.read(bangumiSyncControllerProvider.notifier) : null);
      if (bangumiSync != null) {
        unawaited(bangumiSync.notifyEpisodeCompleted(work: work, episode: ep));
      }
    }

    final cachedBundle = _bundleCacheByWorkId[work.id] ?? bundle;
    final updatedPlaybackMap = Map<String, PlaybackRecord>.of(
      cachedBundle.playbackByEpisodeId,
    )..[ep.id] = record;
    final updatedBundle = WorkDetailBundle(
      work: cachedBundle.work,
      episodes: cachedBundle.episodes,
      variants: cachedBundle.variants,
      sourcesById: cachedBundle.sourcesById,
      latestPlayback: record,
      playbackByEpisodeId: updatedPlaybackMap,
      seriesGroup: cachedBundle.seriesGroup,
      seriesMembers: cachedBundle.seriesMembers,
      cdVariants: cachedBundle.cdVariants,
      scanVariants: cachedBundle.scanVariants,
      editableSupplementaryItems: cachedBundle.editableSupplementaryItems,
    );
    _bundleCacheByWorkId[work.id] = updatedBundle;
    if (!isFinal && !_hudProgressActive) {
      _pendingPersistedBundleWorkId = work.id;
      return;
    }
    _pendingPersistedBundleWorkId = null;
    if (mounted && activeWork.id == work.id) {
      _state = _state.copyWith(currentBundle: updatedBundle);
    }

    if (mounted) {
      _ref.invalidate(playbackHistoryProvider);
      _ref.invalidate(workDetailBundleProvider(work.id));
    }
  }

  /// 处理底层播放会话致命错误（区分本地文件缺失、网桥诊断与连续坏文件熔断）。
  Future<void> _handleFatalSessionError(String msg) async {
    if (!mounted || _state.isClosing) return;
    final diag = await _diagnoseVideoError(msg);
    if (!mounted || _state.isClosing) return;
    _logStore.logEvent(
      subsystem: DiagnosticSubsystem.playback,
      severity: DiagnosticSeverity.error,
      code: diag.deterministicSourceFailure
          ? 'VIDEO_SOURCE_FATAL'
          : 'VIDEO_SESSION_FATAL',
      message: '视频播放致命错误：${diag.message}',
      source:
          'lib/application/playback/video_playback_controller_episodes.dart:_handleFatalSessionError',
      context: <String, Object?>{
        'workId': _state.currentWork?.id ?? request.work.id,
        'episodeId': _state.currentEpisode.id,
        'variantId': _state.currentVariant.id,
        'sourceId': _state.currentVariant.sourceId,
        'rawError': msg,
        'deterministicSourceFailure': diag.deterministicSourceFailure,
      },
    );
    if (diag.deterministicSourceFailure) {
      _state = _state.copyWith(
        isInitializing: false,
        isBuffering: false,
        isPlaying: false,
        errorMessage: diag.message,
      );
      return;
    }
    final tripped = _engine.recordPhysicalMediaFailure();
    _state = _state.copyWith(
      isInitializing: false,
      isBuffering: false,
      isPlaying: false,
      errorMessage: tripped
          ? '连续 ${UnifiedPlaybackEngine.maxConsecutiveBadFiles} 个视频文件加载异常（${diag.message}），已熔断停播'
          : diag.message,
    );
  }

  /// 切换全屏或 Android 横屏全屏模式（Windows 绝不触碰 `flutter_acrylic` 窗体材质防 DWM 黑闪）。
  Future<void> toggleFullscreen() async {
    final next = !_state.isFullscreen;
    if (KonataPlatform.isWindows) {
      await _ref.read(konataWindowHostProvider).setFullScreen(next);
      if (mounted) {
        _state = _state.copyWith(isFullscreen: next);
      }
      return;
    }
    if (KonataPlatform.isAndroid) {
      await AndroidPlaybackWindowBridge.setLandscapePreferred(next);
      await AndroidPlaybackWindowBridge.setSystemBarsHidden(next);
      if (mounted) {
        _state = _state.copyWith(isFullscreen: next);
      }
    }
  }

  /// 当前分集播放进入后段（>= 75% 或剩余 <= 90 秒）时，在后台静默预热下一集远程流首尾元数据与外挂字幕。
  void _maybeScheduleNextEpisodePrewarm(double posSeconds) {
    if (!mounted ||
        _state.isClosing ||
        _closedCleanly ||
        !_state.isPlaying ||
        _state.isBuffering) {
      return;
    }
    final dur = _state.durationSeconds;
    if (dur <= 60.0) return;
    final currentEpId = _state.currentEpisode.id;
    if (_prewarmAttemptedForEpisodeId == currentEpId) return;
    final remaining = dur - posSeconds;
    if (posSeconds / dur < 0.75 && remaining > 90.0) return;
    _prewarmAttemptedForEpisodeId = currentEpId;
    final gen = ++_prewarmGeneration;
    unawaited(_prewarmNextEpisodeInBackground(currentEpId, generation: gen));
  }

  Future<void> _prewarmNextEpisodeInBackground(
    String sourceEpisodeId, {
    required int generation,
  }) async {
    try {
      final target = await resolveNextEpisodeTarget();
      if (target == null ||
          !mounted ||
          _state.isClosing ||
          _closedCleanly ||
          generation != _prewarmGeneration ||
          _state.currentEpisode.id != sourceEpisodeId) {
        return;
      }
      final variants = target.bundle.variantsForEpisode(target.episode.id);
      if (variants.isEmpty) return;
      final nextVariant = variants.first;
      final nextSource = target.bundle.sourcesById[nextVariant.sourceId];
      if (nextSource == null || nextSource.kind == MediaSourceKind.local) {
        return;
      }
      final gw = await _ref
          .read(mediaSourceGatewayFactoryProvider)
          .create(nextSource);
      if (gw is! ByteRangeReadableGateway) {
        await gw.close();
        return;
      }
      final byteGw = gw as ByteRangeReadableGateway;
      if (!mounted ||
          _state.isClosing ||
          _closedCleanly ||
          generation != _prewarmGeneration) {
        await byteGw.close();
        return;
      }
      final reg = await _streamBridge.registerSession(
        gateway: byteGw,
        relativePath: nextVariant.relativePath,
        fileName: nextVariant.fileName,
        knownLength: nextVariant.fileSize > 0 ? nextVariant.fileSize : null,
        ownsGateway: true,
        sourceKind: nextSource.kind,
      );
      if (!mounted ||
          _state.isClosing ||
          _closedCleanly ||
          generation != _prewarmGeneration ||
          _state.currentEpisode.id != sourceEpisodeId) {
        await _streamBridge.unregisterSession(reg.token);
        return;
      }
      final old = _prewarmedNextEpisode;
      _prewarmedNextEpisode = (
        episodeId: target.episode.id,
        variantId: nextVariant.id,
        streamToken: reg.token,
        mediaTarget: reg.url.toString(),
      );
      if (old != null && old.streamToken != reg.token) {
        unawaited(
          _streamBridge.unregisterSession(old.streamToken).catchError((
            Object e,
          ) {
            _logStore.record('VIDEO', '释放旧预热流会话失败：$e');
          }),
        );
      }
      await _streamBridge.prewarmSessionMetadata(reg.token);
      if (!mounted ||
          _state.isClosing ||
          _closedCleanly ||
          generation != _prewarmGeneration) {
        return;
      }
      if (nextVariant.externalSubtitles.isNotEmpty) {
        await _streamBridge.materializeRemoteSubtitles(
          gateway: byteGw,
          workId: target.bundle.work.id,
          sourceId: nextSource.id,
          subtitleRelativePaths: nextVariant.externalSubtitles,
        );
      }
    } catch (e) {
      _logStore.record('VIDEO', '后台静默预热下一集忽略：$e');
    }
  }

  ({
    String episodeId,
    String variantId,
    String streamToken,
    String mediaTarget,
  })?
  _takePrewarmedTargetFor(String episodeId, String variantId) {
    final pending = _prewarmedNextEpisode;
    if (pending == null) return null;
    if (pending.episodeId == episodeId && pending.variantId == variantId) {
      _prewarmedNextEpisode = null;
      ++_prewarmGeneration;
      return pending;
    }
    _disposePrewarmedNextEpisode();
    return null;
  }

  void _disposePrewarmedNextEpisode() {
    ++_prewarmGeneration;
    final pending = _prewarmedNextEpisode;
    _prewarmedNextEpisode = null;
    if (pending != null) {
      unawaited(
        _streamBridge.unregisterSession(pending.streamToken).catchError((
          Object e,
        ) {
          _logStore.record('VIDEO', '释放预热流会话失败：$e');
        }),
      );
    }
  }
}
