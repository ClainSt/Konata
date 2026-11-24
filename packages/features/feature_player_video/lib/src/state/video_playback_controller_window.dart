part of 'video_playback_controller.dart';

/// 视频控制器进度落盘、完播事件发布、宿主窗口与外置播放器接力扩展。
extension VideoPlaybackControllerWindowAndPersistence on VideoPlaybackController {
  void _checkCompletionTransition(double posSeconds) {
    if (_hasCompletedCurrentEpisode) return;
    final durSeconds = _state.durationSeconds;
    if (durSeconds <= 0) return;

    final trackedCompleted = _watchedTracker?.isCompleted(durSeconds) ?? false;
    final helperCompleted = PlaybackRecordHelper.computeCompleted(
      positionSeconds: posSeconds.round(),
      durationSeconds: durSeconds.round(),
    );
    if (!trackedCompleted && !helperCompleted) {
      return;
    }

    _hasCompletedCurrentEpisode = true;
    _setState(_state.copyWith(isCompletedCurrentEpisode: true));
    unawaited(persistProgressNow(forceCompleted: true));
  }

  /// 持久化当前播放位置与完播状态，仅在完播状态首次达成时发布领域事件。
  Future<void> persistProgressNow({bool forceCompleted = false}) async {
    final work = _state.currentWork;
    if (work == null || !_state.hasPlayableMedia) return;

    final episode = _state.currentEpisode;
    final variant = _state.currentVariant;
    final source = _state.currentBundle?.sourcesById[variant.sourceId];

    final posInt = (positionNotifier.value.inMilliseconds / 1000.0).round();
    final durInt = _state.durationSeconds.round();
    final computedCompleted =
        forceCompleted ||
        _hasCompletedCurrentEpisode ||
        PlaybackRecordHelper.computeCompleted(
          positionSeconds: posInt,
          durationSeconds: durInt,
        );

    if (!forceCompleted &&
        !computedCompleted &&
        (_lastSavedPosSeconds - posInt).abs() < 1.0) {
      return;
    }
    _lastSavedPosSeconds = posInt.toDouble();

    final now = (env.nowMs ?? () => DateTime.now().millisecondsSinceEpoch)();
    final recordId = '${work.id.value}::${episode.id.value}';
    final entity = PlaybackRecordEntity(
      id: recordId,
      workId: work.id,
      episodeId: episode.id,
      variantId: variant.id,
      seasonNumber: episode.seasonNumber,
      episodeNumber: episode.episodeNumber,
      episodeTitle: EpisodeTitleFormatter.formatCardTitle(
        episode: episode.toSummaryView(),
        workTitle: work.title,
        workMediaType: work.tmdbMediaType,
        mainEpisodeCount: _state.currentBundle?.mainEpisodes.length,
      ),
      sourceKind: source?.kind ?? MediaSourceKind.local,
      playedAtMs: now,
      positionSeconds: posInt < 0 ? 0 : posInt,
      durationSeconds: durInt < 0 ? 0 : durInt,
      isCompleted: computedCompleted,
      updatedAtMs: now,
      sourceDeviceId: env.sourceDeviceId,
    );

    env.databases.userState.playbackRecords.upsert(entity);

    if (computedCompleted && _emittedCompletedEpisodes.add(episode.id.value)) {
      _hasCompletedCurrentEpisode = true;
      if (!_state.isCompletedCurrentEpisode) {
        _setState(_state.copyWith(isCompletedCurrentEpisode: true));
      }
      env.domainEventBus.publish(
        EpisodeCompletionChangedEvent(
          workId: work.id,
          episodeId: episode.id,
          completed: true,
          occurredAtMs: now,
        ),
      );
    }
  }

  /// 手动标记指定分集的看完或未看完状态，并向领域总线发布同步事件。
  Future<void> markEpisodeCompleted(
    EpisodeId episodeId, {
    bool completed = true,
  }) async {
    final work = _state.currentWork;
    if (work == null) return;

    final targetEp =
        _state.currentBundle?.episodes.cast<EpisodeRecord?>().firstWhere(
          (e) => e?.id == episodeId,
          orElse: () => null,
        ) ??
        _state.currentEpisode;
    final targetVariant =
        _state.currentBundle?.variantsForEpisode(episodeId).firstOrNull ??
        _state.currentVariant;
    final existing = env.databases.userState.playbackRecords.findLatestByEpisode(
      episodeId,
    );
    final now = (env.nowMs ?? () => DateTime.now().millisecondsSinceEpoch)();

    final posInt = episodeId == _state.currentEpisode.id
        ? (positionNotifier.value.inMilliseconds / 1000.0).round()
        : (existing?.positionSeconds ?? 0);
    final durInt = episodeId == _state.currentEpisode.id
        ? _state.durationSeconds.round()
        : (existing?.durationSeconds ?? 0);

    final entity = PlaybackRecordEntity(
      id: '${work.id.value}::${episodeId.value}',
      workId: work.id,
      episodeId: episodeId,
      variantId: targetVariant.id,
      seasonNumber: targetEp.seasonNumber,
      episodeNumber: targetEp.episodeNumber,
      episodeTitle: EpisodeTitleFormatter.formatCardTitle(
        episode: targetEp.toSummaryView(),
        workTitle: work.title,
        workMediaType: work.tmdbMediaType,
        mainEpisodeCount: _state.currentBundle?.mainEpisodes.length,
      ),
      sourceKind:
          _state.currentBundle?.sourcesById[targetVariant.sourceId]?.kind ??
          MediaSourceKind.local,
      playedAtMs: now,
      positionSeconds: posInt,
      durationSeconds: durInt,
      isCompleted: completed,
      updatedAtMs: now,
      sourceDeviceId: env.sourceDeviceId,
    );
    env.databases.userState.playbackRecords.upsert(entity);

    if (completed) {
      _emittedCompletedEpisodes.add(episodeId.value);
    } else {
      _emittedCompletedEpisodes.remove(episodeId.value);
    }

    if (episodeId == _state.currentEpisode.id) {
      _hasCompletedCurrentEpisode = completed;
      _setState(_state.copyWith(isCompletedCurrentEpisode: completed));
    }

    env.domainEventBus.publish(
      EpisodeCompletionChangedEvent(
        workId: work.id,
        episodeId: episodeId,
        completed: completed,
        occurredAtMs: now,
      ),
    );
  }

  /// 切换桌面全屏与窗口还原状态（一律委托宿主窗口控制端口执行）。
  Future<void> toggleFullscreen() async {
    if (_disposed || _closing) return;
    final next = !_state.isFullscreen;
    await env.hostWindow.setFullScreen(next);
    if (!_disposed) {
      _setState(_state.copyWith(isFullscreen: next));
    }
  }

  /// 进入可拖拽悬浮小窗或桌面迷你窗口模式并保存画中画断点恢复快照。
  ///
  /// [desktopAlwaysOnTop] 为 `true` 时同步将桌面窗口收拢为置顶迷你窗；
  /// 为 `false` 时仅在应用窗口内部挂载跨页可拖拽 16:9 悬浮视频小窗，不缩放宿主窗口。
  Future<void> enterMiniPlayer({
    double width = 360.0,
    double height = 202.5,
    bool desktopAlwaysOnTop = true,
  }) async {
    if (_disposed || _closing) return;
    await persistPipRecoverySnapshot();
    if (desktopAlwaysOnTop && env.platform == KonataPlatform.windows) {
      await env.hostWindow.enterDesktopMiniWindow(
        width: width,
        height: height,
      );
      await env.hostWindow.setAlwaysOnTop(true);
    } else if (env.platform != KonataPlatform.windows) {
      await env.hostWindow.setPreferredLandscape(false);
    }
    _setState(_state.copyWith(isMiniPlayer: true, sideSheetOpen: false));
  }

  /// 从悬浮小窗或桌面迷你窗回弹恢复至正常全屏播放舞台。
  Future<void> exitMiniPlayerToStage({bool enterFullscreen = false}) async {
    if (_disposed || _closing) return;
    if (env.platform == KonataPlatform.windows) {
      await env.hostWindow.setAlwaysOnTop(false);
      await env.hostWindow.exitDesktopMiniWindow();
      if (enterFullscreen) {
        await env.hostWindow.setFullScreen(true);
      }
    } else {
      await env.hostWindow.setPreferredLandscape(true);
    }
    await env.pipRecoveryStore.clear();
    _setState(
      _state.copyWith(
        isMiniPlayer: false,
        isFullscreen: enterFullscreen ? true : _state.isFullscreen,
      ),
    );
  }

  /// 写入当前进度的画中画可恢复快照。
  Future<void> persistPipRecoverySnapshot() async {
    final work = _state.currentWork;
    if (work == null || !_state.hasPlayableMedia) return;
    final posInt = (positionNotifier.value.inMilliseconds / 1000.0).round();
    final now = (env.nowMs ?? () => DateTime.now().millisecondsSinceEpoch)();
    await env.pipRecoveryStore.saveSnapshot(
      PipPlaybackRecoverySnapshot(
        workId: work.id.value,
        episodeId: _state.currentEpisode.id.value,
        variantId: _state.currentVariant.id.value,
        positionSeconds: posInt < 0 ? 0 : posInt,
        isPlaying: _state.isPlaying,
        updatedAtMs: now,
      ),
    );
  }

  /// 检查并读取最近有效的画中画异常中断恢复快照。
  Future<PipPlaybackRecoverySnapshot?> checkRecoverablePipSnapshot() =>
      env.pipRecoveryStore.readFreshSnapshot(
        now: env.nowMs != null
            ? DateTime.fromMillisecondsSinceEpoch(env.nowMs!())
            : null,
      );

  /// 控制技术探针浮层开关，关闭时立即终止后台轮询定时器。
  void setProbeOverlayVisible(bool visible) {
    if (_state.probeOverlayVisible == visible) return;
    _setState(_state.copyWith(probeOverlayVisible: visible));
    if (visible) {
      refreshProbeOnce();
    }
    _syncTimersForActivity();
  }

  /// 打开或收起右侧毛玻璃参数侧栏。
  void setSideSheetOpen(bool open) {
    if (_state.sideSheetOpen == open) return;
    _setState(_state.copyWith(sideSheetOpen: open));
  }

  /// 调整移动端虚拟亮度预览值（0.0 到 1.0）。
  void setWindowBrightness(double brightness) {
    final clamped = brightness.clamp(0.05, 1.0).toDouble();
    _setState(_state.copyWith(windowBrightness: clamped));
  }

  /// 同步桌面端底层直通视频输出宿主的物理像素矩形视口与圆角裁切。
  Future<void> syncWindowsUnderlayViewport({
    required int leftPx,
    required int topPx,
    required int rightPx,
    required int bottomPx,
    double cornerRadiusPx = 0.0,
    bool visible = true,
  }) async {
    await _session?.setWindowsUnderlayViewport(
      leftPx: leftPx,
      topPx: topPx,
      rightPx: rightPx,
      bottomPx: bottomPx,
      cornerRadiusPx: cornerRadiusPx,
      visible: visible,
    );
  }

  /// 动态调整桌面共享纹理目标分辨率（在悬浮小窗收放期间节流缩降像素负载）。
  Future<void> resizeDesktopSurfaceTarget(int width, int height) async {
    await _session?.resizeDesktopSurfaceTarget(width, height);
  }

  /// 在运行期动态绑定或热重绑移动平台视频硬件表面控制端口。
  Future<void> attachAndroidSurface(AndroidVideoSurfacePort surfacePort) async {
    await _session?.attachOrRebindAndroidSurface(surfacePort);
  }

  /// 移动平台画中画状态切换后原地重绑当前视频表面。
  Future<void> rebindAndroidSurface() async {
    await _session?.rebindCurrentAndroidSurface();
  }

  /// 通过外部桌面播放器网关接力播放当前视频分集并回写观看进度。
  Future<LaunchPlaybackResult> launchExternalVideoPlayer({
    String? targetId,
    String? preferredKindKey,
  }) async {
    final relay = env.desktopRelayGateway;
    final work = _state.currentWork;
    if (relay == null || work == null || !_state.hasPlayableMedia) {
      return const LaunchPlaybackResult(
        launched: false,
        message: '当前平台未配置桌面外部播放器接力服务',
      );
    }
    await setPlaying(false);
    final posSec = (positionNotifier.value.inMilliseconds / 1000.0).round();
    final variant = _state.currentVariant;
    final source = _state.currentBundle?.sourcesById[variant.sourceId];

    final result = await relay.launchVideo(
      work: work,
      episode: _state.currentEpisode.toSummaryView(),
      variant: variant,
      source: source?.toReadView(),
      targetId: targetId,
      preferredKindKey: preferredKindKey,
      startSeconds: posSec,
      mainEpisodeCount: _state.currentBundle?.mainEpisodes.length,
      onProgressUpdate:
          (positionSeconds, durationSeconds, {required isFinal}) async {
            handleDurationUpdate(durationSeconds.toDouble());
            handlePositionUpdate(positionSeconds.toDouble());
            if (isFinal) {
              await persistProgressNow();
            }
          },
    );
    showTransientNotice(result.message, isError: !result.launched);
    return result;
  }

  /// 安全停止全部定时器、释放渲染表面与原生播放器会话（退出页面时调用）。
  Future<void> closeSession() async {
    if (_closing) return;
    _closing = true;
    _cancelAllTimers();
    _currentSubtitleHudLiftPercent = 0.0;
    _session?.setSubtitleHudLiftPercent(0.0);
    _setState(_state.copyWith(isClosing: true, isPlaying: false));
    await persistProgressNow();
    if (_state.isMiniPlayer) {
      await env.pipRecoveryStore.clear();
    }
    if (env.platform == KonataPlatform.windows && _state.isMiniPlayer) {
      await env.hostWindow.setAlwaysOnTop(false);
      await env.hostWindow.exitDesktopMiniWindow();
    }
    await env.hostWindow.setKeepScreenOn(false);
    await env.hostWindow.setPreferredLandscape(false);
    env.audiophileCoordinator.detachSession(this);
    _session?.silenceAndDetachForClose();
    await _session?.dispose();
    _session = null;
    await thumbnailService.release();
    env.playbackEngine.resetSession();
  }
}
