part of 'video_playback_controller.dart';

/// 视频控制器分集导航、版本切换、系列切换与智能跳过扩展。
extension VideoPlaybackControllerEpisodes on VideoPlaybackController {
  /// 当前作品排好序的可播剧集清单。
  List<EpisodeRecord> get orderedEpisodes =>
      _state.currentBundle?.episodes ?? const <EpisodeRecord>[];

  int get _currentEpisodeIndex {
    final list = orderedEpisodes;
    for (var i = 0; i < list.length; i++) {
      if (list[i].id == _state.currentEpisode.id) {
        return i;
      }
    }
    return -1;
  }

  /// 是否存在上一话可切换剧集。
  bool get hasPreviousEpisode => _currentEpisodeIndex > 0;

  /// 是否存在下一话可切换剧集。
  bool get hasNextEpisode {
    final idx = _currentEpisodeIndex;
    return idx >= 0 && idx + 1 < orderedEpisodes.length;
  }

  /// 切换播放上一话剧集。
  Future<void> playPreviousEpisode() async {
    final idx = _currentEpisodeIndex;
    if (idx <= 0) return;
    await switchEpisode(orderedEpisodes[idx - 1]);
  }

  /// 切换播放下一话剧集。
  Future<void> playNextEpisode() async {
    final idx = _currentEpisodeIndex;
    if (idx < 0 || idx + 1 >= orderedEpisodes.length) return;
    await switchEpisode(orderedEpisodes[idx + 1]);
  }

  /// 切换至当前作品的指定剧集及可选指定物理版本。
  Future<void> switchEpisode(
    EpisodeRecord episode, {
    MediaVariantRecord? preferredVariant,
  }) async {
    final bundle = _state.currentBundle;
    if (_disposed || _closing || bundle == null) return;

    await persistProgressNow();
    if (_disposed || _closing) return;

    final variants = bundle.variantsForEpisode(episode.id);
    if (variants.isEmpty) {
      showTransientNotice('该分集暂无关联视频文件', isError: true);
      return;
    }

    final variant = preferredVariant ?? variants.first;
    final source = bundle.sourcesById[variant.sourceId];
    final record =
        bundle.playbackByEpisodeId[episode.id.value] ??
        env.databases.userState.playbackRecords.findLatestByEpisode(episode.id);
    final completed = record?.isCompleted ?? false;
    final startSec =
        (record != null && !completed && record.positionSeconds >= 6)
        ? record.positionSeconds.toDouble()
        : 0.0;

    _hasCompletedCurrentEpisode = completed;
    if (completed) {
      _emittedCompletedEpisodes.add(episode.id.value);
    }
    _watchedTracker = WatchedTracker();
    _skipPlan = null;
    _autoSkippedOpeningForEpisode = false;
    _autoSkippedEndingForEpisode = false;
    _lastSavedPosSeconds = startSec;

    positionNotifier.value = Duration(milliseconds: (startSec * 1000).round());
    durationNotifier.value = (record != null && record.durationSeconds > 0)
        ? Duration(seconds: record.durationSeconds)
        : Duration.zero;
    bufferedNotifier.value = Duration.zero;

    final prefs = env.preferencesStore.read();
    final quality = _resolveEffectiveQualityConfig(prefs.qualityConfig, variant);
    final safety = _evaluateVariantHwdecSafety(variant);

    _setState(
      _state.copyWith(
        currentEpisode: episode,
        currentVariant: variant,
        isBuffering: env.libMpvClientFactory != null,
        hasFirstFrame: env.libMpvClientFactory == null,
        durationSeconds: durationNotifier.value.inSeconds.toDouble(),
        chapters: const <PlaybackChapter>[],
        subtitles: const <SubtitleChoice>[],
        audioTracks: const <AudioTrackChoice>[],
        clearSkipWindow: true,
        clearSecondarySubtitleTrackId: true,
        clearActiveSubtitleSubsetState: true,
        subtitleDelaySeconds: 0.0,
        audioDelaySeconds: 0.0,
        subtitleOpenCcMode: SubtitleOpenCcMode.none,
        isCompletedCurrentEpisode: completed,
        hwdecForcedSoftwareReason: safety.allowHardwareDecode
            ? null
            : safety.reason,
        clearHwdecReason: safety.allowHardwareDecode,
      ),
    );

    if (env.libMpvClientFactory == null &&
        Platform.environment.containsKey('FLUTTER_TEST')) {
      return;
    }

    await _startOrReloadSession(
      bundle: bundle,
      episode: episode,
      variant: variant,
      source: source?.toReadView(),
      qualityConfig: quality,
      startSeconds: startSec,
      volume100: _state.volume,
    );
  }

  /// 原地切换同一分集下的不同压制组或清晰度物理版本，尽量接续当前进度。
  Future<void> switchVariant(MediaVariantRecord variant) async {
    final bundle = _state.currentBundle;
    if (_disposed || _closing || bundle == null) return;
    if (variant.id == _state.currentVariant.id) return;

    final currentSec = positionNotifier.value.inMilliseconds / 1000.0;
    final source = bundle.sourcesById[variant.sourceId];
    final prefs = env.preferencesStore.read();
    final quality = _resolveEffectiveQualityConfig(prefs.qualityConfig, variant);

    _setState(
      _state.copyWith(
        currentVariant: variant,
        isBuffering: env.libMpvClientFactory != null,
        hasFirstFrame: env.libMpvClientFactory == null,
      ),
    );

    if (env.libMpvClientFactory == null &&
        Platform.environment.containsKey('FLUTTER_TEST')) {
      return;
    }

    await _startOrReloadSession(
      bundle: bundle,
      episode: _state.currentEpisode,
      variant: variant,
      source: source?.toReadView(),
      qualityConfig: quality,
      startSeconds: currentSec,
      volume100: _state.volume,
    );
  }

  /// 在播放器内直接切换至同系列另一季或剧场版作品。
  Future<void> switchSeriesWork(WorkId workId) async {
    if (_disposed || _closing || workId == _state.currentWork?.id) return;
    await persistProgressNow();
    await initialize(VideoLaunchRequest(workId: workId));
  }

  /// 跳转至指定章节的起始时间点。
  Future<void> seekToChapter(PlaybackChapter chapter) async {
    await seekToSeconds(chapter.startSeconds);
  }

  /// 执行当前激活的跳过片头或片尾章节动作。
  Future<void> triggerActiveSkipWindow() async {
    final window = _state.activeSkipWindow;
    if (window == null) return;
    switch (window.kind) {
      case SkipActionKind.skipOp:
        _autoSkippedOpeningForEpisode = true;
        await seekToSeconds(window.endSeconds);
        showTransientNotice('已跳过片头');
      case SkipActionKind.skipEdToCPart:
        _autoSkippedEndingForEpisode = true;
        await seekToSeconds(window.endSeconds);
        showTransientNotice('已跳过片尾曲，继续正片彩蛋');
      case SkipActionKind.skipEdToNextEpisode:
        _autoSkippedEndingForEpisode = true;
        if (hasNextEpisode) {
          showTransientNotice('已跳过片尾，切入下一集');
          await playNextEpisode();
        } else {
          await seekToSeconds(window.endSeconds);
        }
    }
  }

  void _recomputeChapterSkipPlan() {
    final chapters = _state.chapters;
    final dur = _state.durationSeconds;
    if (chapters.isEmpty || dur <= 0) {
      _skipPlan = null;
      if (_state.activeSkipWindow != null) {
        _setState(_state.copyWith(clearSkipWindow: true));
      }
      return;
    }
    _skipPlan = ChapterSkipAnalyzer.analyze(
      rawChapters: chapters,
      totalDurationSeconds: dur,
      hasNextEpisode: hasNextEpisode,
    );
    _updateSkipWindowForPosition(positionNotifier.value.inMilliseconds / 1000.0);
  }

  void _updateSkipWindowForPosition(double posSeconds) {
    final window = _skipPlan?.activeWindowAt(posSeconds);
    if (window == _state.activeSkipWindow) {
      return;
    }
    _setState(
      _state.copyWith(
        activeSkipWindow: window,
        clearSkipWindow: window == null,
      ),
    );
    if (window == null) return;

    final autoSkipEnabled = env.preferencesStore.read().autoSkipChapters;
    if (!autoSkipEnabled || !window.allowsAutoSkip || !_state.isPlaying) {
      return;
    }

    if (window.kind == SkipActionKind.skipOp && !_autoSkippedOpeningForEpisode) {
      _autoSkippedOpeningForEpisode = true;
      unawaited(triggerActiveSkipWindow());
    } else if ((window.kind == SkipActionKind.skipEdToCPart ||
            window.kind == SkipActionKind.skipEdToNextEpisode) &&
        !_autoSkippedEndingForEpisode) {
      _autoSkippedEndingForEpisode = true;
      unawaited(triggerActiveSkipWindow());
    }
  }

  /// 切换播放与暂停状态，并在暂停时立即落盘当前进度及停表节流。
  Future<void> togglePlayPause() async {
    await setPlaying(!_state.isPlaying);
  }

  /// 显式设定播放进行状态。
  Future<void> setPlaying(bool playing) async {
    if (_disposed || _closing) return;
    _session?.setPlaying(playing);
    _handlePlayingChanged(playing);
  }

  /// 跳转至指定绝对时间点（秒）。
  Future<void> seekToSeconds(double targetSeconds) async {
    if (_disposed || _closing || !targetSeconds.isFinite) return;
    final dur = _state.durationSeconds;
    final clamped = dur > 0
        ? targetSeconds.clamp(0.0, dur).toDouble()
        : (targetSeconds < 0 ? 0.0 : targetSeconds);
    _watchedTracker?.notifySeek();
    _session?.seekAbsolute(clamped);
    handlePositionUpdate(clamped);
    await persistProgressNow();
  }

  /// 按相对偏移秒数快进或快退。
  Future<void> seekRelativeSeconds(double deltaSeconds) async {
    if (_disposed || _closing || !deltaSeconds.isFinite) return;
    _watchedTracker?.notifySeek();
    _session?.seekRelative(deltaSeconds);
    final currentSec = positionNotifier.value.inMilliseconds / 1000.0;
    final dur = _state.durationSeconds;
    final nextSec = dur > 0
        ? (currentSec + deltaSeconds).clamp(0.0, dur).toDouble()
        : ((currentSec + deltaSeconds) < 0 ? 0.0 : currentSec + deltaSeconds);
    handlePositionUpdate(nextSec);
    await persistProgressNow();
  }

  /// 步进至下一帧或上一帧（自动暂停以便逐帧查看）。
  void stepFrame({required bool forward}) {
    if (_disposed || _closing) return;
    if (forward) {
      _session?.stepFrameForward();
    } else {
      _session?.stepFrameBackward();
    }
    _handlePlayingChanged(false);
  }

  /// 调整长期默认播放倍速（非临时长按加速状态）。
  void setPlaybackSpeed(double speed) {
    final clamped = speed.clamp(0.25, 4.0).toDouble();
    _speedBeforeBoost = clamped;
    _session?.setSpeed(clamped);
    _setState(_state.copyWith(speed: clamped, isSpeedBoostActive: false));
    env.preferencesStore.updateQualityConfig(
      (q) => q.copyWith(defaultSpeed: clamped),
    );
  }

  /// 进入或退出临时长按两倍速快放状态。
  void setTemporarySpeedBoost(bool active) {
    if (_disposed || _closing) return;
    if (active && !_state.isSpeedBoostActive) {
      _speedBeforeBoost = _state.speed;
      const boostSpeed = 2.0;
      _session?.setSpeed(boostSpeed);
      _setState(_state.copyWith(speed: boostSpeed, isSpeedBoostActive: true));
    } else if (!active && _state.isSpeedBoostActive) {
      _session?.setSpeed(_speedBeforeBoost);
      _setState(
        _state.copyWith(speed: _speedBeforeBoost, isSpeedBoostActive: false),
      );
    }
  }

  /// 设置当前播放音量（0.0 到 100.0 之间）并自动写回持久化切片。
  void setVolume(double volume100) {
    final clamped = volume100.clamp(0.0, 100.0).toDouble();
    final muted = clamped <= 0.001 ? _state.isMuted : false;
    _session?.setVolume(clamped);
    if (muted != _state.isMuted) {
      _session?.setMute(muted);
    }
    _setState(_state.copyWith(volume: clamped, isMuted: muted));
    env.preferencesStore.setVolumeAndMute(
      volume: clamped / 100.0,
      isMuted: muted,
    );
  }

  /// 切换静音状态并保存至配置仓储。
  void toggleMute() {
    final nextMuted = !_state.isMuted;
    _session?.setMute(nextMuted);
    _setState(_state.copyWith(isMuted: nextMuted));
    env.preferencesStore.setVolumeAndMute(isMuted: nextMuted);
  }

  ({EpisodeRecord episode, MediaVariantRecord variant})
  _resolveInitialEpisodeAndVariant(
    VideoWorkBundle bundle,
    VideoLaunchRequest request,
  ) {
    final targetVariantId = request.variantId;
    if (targetVariantId != null) {
      for (final v in bundle.variants) {
        if (v.id == targetVariantId) {
          final matchedEp = bundle.episodes.cast<EpisodeRecord?>().firstWhere(
                (e) => e?.id == v.episodeId,
                orElse: () => null,
              );
          if (matchedEp != null) {
            return (episode: matchedEp, variant: v);
          }
        }
      }
    }

    final targetEpisodeId =
        request.episodeId ?? bundle.latestPlayback?.episodeId;
    if (targetEpisodeId != null) {
      final matchedEp = bundle.episodes.cast<EpisodeRecord?>().firstWhere(
            (e) => e?.id == targetEpisodeId,
            orElse: () => null,
          );
      if (matchedEp != null) {
        final vars = bundle.variantsForEpisode(matchedEp.id);
        if (vars.isNotEmpty) {
          final latestVarId = bundle.latestPlayback?.variantId;
          final preferredVar = vars.cast<MediaVariantRecord?>().firstWhere(
                (v) => v?.id == latestVarId,
                orElse: () => vars.first,
              );
          return (episode: matchedEp, variant: preferredVar!);
        }
      }
    }

    for (final ep in bundle.episodes) {
      final vars = bundle.variantsForEpisode(ep.id);
      if (vars.isNotEmpty) {
        return (episode: ep, variant: vars.first);
      }
    }

    final fallbackVar = bundle.variants.first;
    final fallbackEp =
        bundle.episodes.firstOrNull ??
        EpisodeRecord(
          id: fallbackVar.episodeId ??
              EpisodeId.trusted('ep:${fallbackVar.id.value}'),
          workId: bundle.work.id,
          seasonNumber: 1,
        );
    return (episode: fallbackEp, variant: fallbackVar);
  }

  HwdecSafetyDecision _evaluateVariantHwdecSafety(MediaVariantRecord variant) {
    return HwdecSafetyPolicy.evaluateVariantMetadata(
      platform: _toHwdecPlatform(),
      videoCodec: variant.videoCodec,
      bitDepth: variant.bitDepth,
    );
  }

  PlaybackQualityConfig _resolveEffectiveQualityConfig(
    PlaybackQualityConfig base,
    MediaVariantRecord variant,
  ) {
    final safety = _evaluateVariantHwdecSafety(variant);
    if (!safety.allowHardwareDecode && base.hardwareDecode) {
      return base.copyWith(hardwareDecode: false);
    }
    return base;
  }

  HwdecPlatformKind _toHwdecPlatform() => switch (env.platform) {
    KonataPlatform.windows => HwdecPlatformKind.windows,
    KonataPlatform.androidPhone ||
    KonataPlatform.androidTablet => HwdecPlatformKind.android,
  };
}
