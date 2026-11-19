part of 'video_playback_controller.dart';

/// `VideoPlaybackController` 跨季连播、连续坏文件熔断、章节跳过、缩略图预热与进度落库扩展。
extension VideoPlaybackControllerEpisodes on VideoPlaybackController {
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

  void _scheduleThumbnailWarmup() {
    _thumbnailWarmupTimer?.cancel();
    final gen = ++_thumbnailGeneration;
    _thumbnailWarmupTimer = Timer(MpvThumbnailService.defaultWarmupDelay, () {
      if (!mounted ||
          _state.isClosing ||
          _closedCleanly ||
          gen != _thumbnailGeneration) {
        return;
      }
      final variant = _state.currentVariant;
      final source =
          activeBundle.sourcesById[variant.sourceId] ?? request.source;
      var svc = _thumbnailService;
      if (svc == null) {
        svc = MpvThumbnailService(
          streamBridge: _streamBridge,
          gatewayFactory: _ref.read(mediaSourceGatewayFactoryProvider),
          logStore: _logStore,
        );
        svc.addListener(_onThumbnailUpdated);
        _thumbnailService = svc;
      }
      unawaited(
        svc.warmUp(
          variant: variant,
          source: source,
          chapters: _state.chapters,
          durationSeconds: _state.durationSeconds > 0
              ? _state.durationSeconds
              : null,
        ),
      );
    });
  }

  void _onThumbnailUpdated() {
    if (mounted) {
      _thumbnailRevision.value += 1;
    }
  }

  Future<void> _releaseThumbnailService({required bool disposeNotifier}) async {
    ++_thumbnailGeneration;
    _thumbnailWarmupTimer?.cancel();
    _thumbnailWarmupTimer = null;
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
      final tripped = _engine.recordPhysicalMediaFailure();
      final detail = '播放意外中断 (code: $errorCode)';
      _logStore.record('VIDEO', detail, isError: true);
      if (tripped) {
        _state = _state.copyWith(
          isBuffering: false,
          isPlaying: false,
          errorMessage:
              '连续 ${UnifiedPlaybackEngine.maxConsecutiveBadFiles} 个视频文件加载异常（$detail），已熔断停播',
        );
        return;
      }
      final prefs = _ref.read(playbackPreferencesProvider);
      if (prefs.autoNextEpisode && hasNextEpisodeAny) {
        showTransientBanner('当前分集加载异常，自动尝试下一话');
        unawaited(goToNextEpisode(isAutoAdvance: true));
        return;
      }
      _state = _state.copyWith(
        isBuffering: false,
        isPlaying: false,
        errorMessage: detail,
      );
    }
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
        ? 'EP${_state.currentEpisode.episodeNumber.toString().padLeft(2, '0')}'
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

  /// 一键热接力至外部播放器：携带精确当前秒数退出内置播放页并在外部播放器续播回写。
  Future<LaunchPlaybackResult> relayToExternalPlayer([
    ExternalPlayerConfig? targetPlayer,
  ]) async {
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
          player: targetPlayer,
          startSeconds: relayPos,
          mainEpisodeCount: orderedMainEpisodes.length,
        );
  }

  Future<void> _persistProgress({required bool isFinal}) async {
    final work = activeWork;
    final bundle = activeBundle;
    final ep = _state.currentEpisode;
    final variant = _state.currentVariant;
    final durDouble = _state.durationSeconds;
    final posDouble = _hudProgressActive
        ? currentPositionSeconds
        : (_session?.readCurrentPositionSeconds() ?? currentPositionSeconds);
    _latestPositionSeconds = posDouble;
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

    final repo = _ref.read(libraryRepositoryProvider);
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
              ? '第 ${ep.episodeNumber} 话'
              : (ep.category == EpisodeCategory.extra
                    ? (ep.extraType?.name.toUpperCase() ?? '特典')
                    : work.title)),
      sourceType: src?.kind ?? MediaSourceKind.local,
      playedAt: DateTime.now(),
      positionSeconds: persistedPos,
      durationSeconds: durSeconds,
      isCompleted: completed,
    );

    await repo.recordPlayback(record);
    _alreadyPersistedCompleted = completed;

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
    if (mounted && activeWork.id == work.id) {
      _state = _state.copyWith(currentBundle: updatedBundle);
    }

    if (mounted) {
      _ref.invalidate(playbackHistoryProvider);
      _ref.invalidate(workDetailBundleProvider(work.id));
    }
  }
}
