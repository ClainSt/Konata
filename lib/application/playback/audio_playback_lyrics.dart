part of 'audio_playback_notifier.dart';

/// `AudioPlaybackNotifier` 歌词用户控制扩展：三级偏移实时调校、换候选、手动重搜、恢复自动与队列分级预取。
extension AudioPlaybackLyrics on AudioPlaybackNotifier {
  /// 构造单曲物理缓存键。
  String _buildTrackLyricKey(AudioQueueItem item) {
    return LyricsResolver.buildTrackKey(
      physicalFileKey: item.physicalFileKey,
      fileSize: item.variant.fileSize,
      cueStartSeconds: item.cueStartSeconds,
    );
  }

  /// 构造单曲在线歌词解析请求（携带专辑键、Bangumi 主条目 ID 与轨号）。
  LyricResolveRequest _buildLyricResolveRequest(
    AudioQueueItem item, {
    double? durationOverrideSeconds,
    String? titleOverride,
    String? artistOverride,
  }) {
    final durationSec =
        durationOverrideSeconds ??
        (item.resolvedDuration > Duration.zero
            ? item.resolvedDuration.inMilliseconds / 1000.0
            : null);
    return LyricResolveRequest(
      trackKey: _buildTrackLyricKey(item),
      albumKey: item.albumCacheKey,
      bangumiSubjectId: item.work.bangumiId,
      trackNumber: item.trackNumber,
      query: LyricSearchQuery(
        title: titleOverride ?? item.title,
        artist: artistOverride ?? item.performer,
        album: item.albumTitle,
        fileName: item.effectiveFileName,
        durationSeconds: durationSec,
      ),
    );
  }

  /// 结合当前活跃输出路由（有线 / 蓝牙）与用户偏好，拼装完整三级偏移快照。
  LyricOffsetSnapshot _buildCurrentRouteOffsetSnapshot({
    int trackOffsetMillis = 0,
    int albumOffsetMillis = 0,
    bool userOffsetLocked = false,
  }) {
    final prefs = _ref.read(playbackPreferencesProvider);
    final coordinator = _safetyCoordinatorInstance;
    final routeKind = LyricOffsetResolver.classifyAudioRoute(
      deviceName: coordinator?.activeOutputDeviceName,
      deviceFingerprint: coordinator?.deviceSafetyState.deviceFingerprint,
    );
    final routeMs = routeKind == LyricAudioRouteKind.bluetooth
        ? prefs.lyricBluetoothOffsetMillis
        : prefs.lyricWiredOffsetMillis;
    return LyricOffsetSnapshot(
      trackOffsetMillis: LyricOffsetSnapshot.clampTrackOrAlbum(
        trackOffsetMillis,
      ),
      albumOffsetMillis: LyricOffsetSnapshot.clampTrackOrAlbum(
        albumOffsetMillis,
      ),
      routeOffsetMillis: LyricOffsetSnapshot.clampRoute(routeMs),
      activeRouteKind: routeKind,
      userOffsetLocked: userOffsetLocked,
    );
  }

  /// 监听音频输出路由变更或全局路由延迟偏好变更时，实时同步当前生效的路由偏移。
  void _syncActiveRouteLyricOffset() {
    if (!mounted || !_state.isActive) return;
    final cur = _state.lyricOffset;
    final next = _buildCurrentRouteOffsetSnapshot(
      trackOffsetMillis: cur.trackOffsetMillis,
      albumOffsetMillis: cur.albumOffsetMillis,
      userOffsetLocked: cur.userOffsetLocked,
    );
    if (next == cur) return;
    _applyUpdatedLyricOffset(next);
  }

  /// 异步回填当前曲目持久化的单曲偏移与专辑偏移（同时支持外挂 `.lrc` 与在线歌词）。
  Future<void> _hydratePersistedLyricOffsets(
    AudioQueueItem item, {
    required int generation,
  }) async {
    final resolver = _ref.read(lyricsResolverProvider);
    final persisted = await resolver.readPersistedOffsets(
      trackKey: _buildTrackLyricKey(item),
      albumKey: item.albumCacheKey,
    );
    if (!mounted || generation != _loadGeneration) return;
    final next = _buildCurrentRouteOffsetSnapshot(
      trackOffsetMillis: persisted.trackOffsetMillis,
      albumOffsetMillis: persisted.albumOffsetMillis,
      userOffsetLocked: persisted.userOffsetLocked,
    );
    if (next != _state.lyricOffset) {
      _applyUpdatedLyricOffset(next);
    }
  }

  void _applyUpdatedLyricOffset(LyricOffsetSnapshot nextOffset) {
    final doc = _state.lrcDocument;
    final nextIndex = doc == null
        ? _state.activeLyricIndex
        : doc.activeIndexAt(
            currentPositionSeconds + nextOffset.totalOffsetSeconds,
          );
    _state = _state.copyWith(
      lyricOffset: nextOffset,
      activeLyricIndex: nextIndex,
    );
  }

  /// 按增量微调当前单曲歌词偏移（毫秒，典型值 `±100` / `±500`，实时生效并持久化锁定）。
  Future<void> adjustTrackLyricOffsetMillis(int deltaMillis) {
    final next = LyricOffsetSnapshot.clampTrackOrAlbum(
      _state.lyricOffset.trackOffsetMillis + deltaMillis,
    );
    return setTrackLyricOffsetMillis(next);
  }

  /// 设置当前单曲歌词偏移（毫秒，正值歌词提前、负值延后），实时生效并持久化。
  Future<void> setTrackLyricOffsetMillis(
    int offsetMillis, {
    bool userOffsetLocked = true,
  }) async {
    final item = _state.currentItem;
    if (item == null || !mounted) return;
    final clamped = LyricOffsetSnapshot.clampTrackOrAlbum(offsetMillis);
    final locked = userOffsetLocked && clamped != 0;
    final nextOffset = _state.lyricOffset.copyWith(
      trackOffsetMillis: clamped,
      userOffsetLocked: locked,
    );
    _applyUpdatedLyricOffset(nextOffset);
    await _ref
        .read(lyricsResolverProvider)
        .saveTrackOffset(
          _buildTrackLyricKey(item),
          offsetMillis: clamped,
          userOffsetLocked: locked,
        );
  }

  /// 设置当前专辑统一歌词偏移（毫秒），作用于同专辑所有曲目并持久化。
  Future<void> setAlbumLyricOffsetMillis(int offsetMillis) async {
    final item = _state.currentItem;
    if (item == null || !mounted) return;
    final clamped = LyricOffsetSnapshot.clampTrackOrAlbum(offsetMillis);
    final nextOffset = _state.lyricOffset.copyWith(albumOffsetMillis: clamped);
    _applyUpdatedLyricOffset(nextOffset);
    await _ref
        .read(lyricsResolverProvider)
        .saveAlbumOffset(item.albumCacheKey, clamped);
  }

  /// 一键将当前“单曲 + 专辑”合成偏移提升为整张专辑统一偏移，同时归零单曲偏移（当前曲目总偏移零跳变）。
  Future<void> promoteCurrentOffsetToAlbum() async {
    final item = _state.currentItem;
    if (item == null || !mounted) return;
    final combinedAlbumMs = LyricOffsetSnapshot.clampTrackOrAlbum(
      _state.lyricOffset.albumOffsetMillis +
          _state.lyricOffset.trackOffsetMillis,
    );
    final nextOffset = _state.lyricOffset.copyWith(
      trackOffsetMillis: 0,
      userOffsetLocked: false,
      albumOffsetMillis: combinedAlbumMs,
    );
    _applyUpdatedLyricOffset(nextOffset);
    final resolver = _ref.read(lyricsResolverProvider);
    await resolver.saveAlbumOffset(item.albumCacheKey, combinedAlbumMs);
    await resolver.saveTrackOffset(
      _buildTrackLyricKey(item),
      offsetMillis: 0,
      userOffsetLocked: false,
    );
  }

  /// 设置指定输出路由（有线/扬声器 或 蓝牙）的全局歌词延迟（毫秒），立即联动当前活跃路由并持久化。
  Future<void> setRouteLyricOffsetMillis(
    LyricAudioRouteKind routeKind,
    int offsetMillis,
  ) async {
    final clamped = LyricOffsetSnapshot.clampRoute(offsetMillis);
    final prefsNotifier = _ref.read(playbackPreferencesProvider.notifier);
    if (routeKind == LyricAudioRouteKind.bluetooth) {
      await prefsNotifier.setLyricBluetoothOffsetMillis(clamped);
    } else {
      await prefsNotifier.setLyricWiredOffsetMillis(clamped);
    }
    if (mounted && _state.lyricOffset.activeRouteKind == routeKind) {
      _applyUpdatedLyricOffset(
        _state.lyricOffset.copyWith(routeOffsetMillis: clamped),
      );
    }
  }

  /// 手动输入曲名/歌手重搜全部已启用在线歌词源，返回候选列表供用户自由挑选。
  Future<List<ScoredLyricCandidate>> searchLyricCandidatesManual({
    required String title,
    String artist = '',
  }) async {
    final item = _state.currentItem;
    if (item == null || !mounted) return const [];
    final gen = _loadGeneration;
    final cleanTitle = title.trim().isEmpty ? item.title : title.trim();
    final durationSec = _state.durationSeconds > 0
        ? _state.durationSeconds
        : (item.resolvedDuration > Duration.zero
              ? item.resolvedDuration.inMilliseconds / 1000.0
              : null);
    final query = LyricSearchQuery(
      title: cleanTitle,
      artist: artist.trim(),
      album: item.albumTitle,
      fileName: item.effectiveFileName,
      durationSeconds: durationSec,
    );
    final candidates = await _ref
        .read(lyricsResolverProvider)
        .searchCandidatesManual(query, trackKey: _buildTrackLyricKey(item));
    if (mounted && gen == _loadGeneration) {
      _state = _state.copyWith(lyricCandidates: candidates);
    }
    return candidates;
  }

  /// 手动切换至指定歌词候选并持久化锁定（`userEdited = true`，永不被自动流程与升级覆盖）。
  Future<bool> selectLyricCandidate(ScoredLyricCandidate selected) async {
    final item = _state.currentItem;
    if (item == null || !mounted) return false;
    final gen = _loadGeneration;
    final req = _buildLyricResolveRequest(
      item,
      durationOverrideSeconds: _state.durationSeconds > 0
          ? _state.durationSeconds
          : null,
    );
    final outcome = await _ref
        .read(lyricsResolverProvider)
        .applyManualCandidate(
          trackKey: req.trackKey,
          songKey: req.query.songKey,
          selected: selected,
        );
    if (outcome == null ||
        outcome.lrcDocument == null ||
        !mounted ||
        gen != _loadGeneration) {
      return false;
    }
    _pendingLyricUpgrade = null;
    final doc = outcome.lrcDocument!;
    final mergedCandidates = _state.lyricCandidates.any(
          (c) =>
              c.candidate.source == selected.candidate.source &&
              c.candidate.sourceId == selected.candidate.sourceId,
        )
        ? _state.lyricCandidates
        : <ScoredLyricCandidate>[selected, ..._state.lyricCandidates];
    _state = _state.copyWith(
      lrcDocument: doc,
      activeSpanLines: outcome.activeSpanLines,
      activeLyricIndex: doc.activeIndexAt(
        currentPositionSeconds + _state.lyricOffset.totalOffsetSeconds,
      ),
      activeLyricSource: outcome.source,
      activeLyricSourceId: outcome.sourceId,
      isLyricLookupInFlight: false,
      isLyricUserEdited: true,
      lyricCandidates: mergedCandidates,
    );
    return true;
  }

  /// 解除当前曲目的手动歌词锁定并重新执行自动多源竞速匹配（保留已锁定的单曲与专辑偏移）。
  Future<void> resetToAutoLyricMatch() async {
    final item = _state.currentItem;
    if (item == null || !mounted) return;
    final gen = _loadGeneration;
    _pendingLyricUpgrade = null;
    await _ref
        .read(lyricsResolverProvider)
        .unlockUserEdit(_buildTrackLyricKey(item));
    if (!mounted || gen != _loadGeneration) return;
    _state = _state.copyWith(isLyricUserEdited: false);
    await _resolveTrackLyrics(item, generation: gen, bypassCache: true);
  }

  /// 根据当前播放队列与循环模式，提取后续待预取曲目并按网络类型分级预取（Wi-Fi 2 首，移动网络 1 首）。
  Future<void> _scheduleQueueLyricPrefetch({required int generation}) async {
    if (!mounted || generation != _loadGeneration) return;
    final queue = _state.queue;
    final curIdx = _state.currentIndex;
    if (queue.length <= 1 || curIdx < 0 || curIdx >= queue.length) return;
    if (_state.loopMode == AudioLoopMode.loopOne) return;

    final upcoming = <LyricResolveRequest>[];
    final seenKeys = <String>{_buildTrackLyricKey(queue[curIdx])};
    for (var step = 1; step <= LyricsResolver.wifiPrefetchCount; step++) {
      final int targetIdx;
      if (curIdx + step < queue.length) {
        targetIdx = curIdx + step;
      } else if (_state.loopMode == AudioLoopMode.loopAll) {
        targetIdx = (curIdx + step) % queue.length;
      } else {
        break;
      }
      final nextItem = queue[targetIdx];
      // 跳过尚未展开的整轨母碟占位，待展开后按真实子曲目预取。
      if (nextItem.pairedCueVariant != null && !nextItem.isCueTrack) continue;
      final req = _buildLyricResolveRequest(nextItem);
      if (seenKeys.add(req.trackKey)) {
        upcoming.add(req);
      }
    }
    if (upcoming.isEmpty) return;
    await _ref.read(lyricsResolverProvider).prefetchUpcomingTracks(upcoming);
  }

  /// 关闭播放器时中止一切在途在线歌词检索与后台队列预取。
  void _cancelLyricTasksOnClose() {
    _ref.read(lyricsResolverProvider).cancelPendingLookups();
  }

  /// 循环模式切换时联动队列歌词预取（单曲循环立即取消，其余模式按新顺序补预取）。
  void _onLoopModeChangedForLyrics(AudioLoopMode nextMode) {
    if (nextMode == AudioLoopMode.loopOne) {
      _ref.read(lyricsResolverProvider).cancelPrefetch();
    } else {
      unawaited(_scheduleQueueLyricPrefetch(generation: _loadGeneration));
    }
  }
}
