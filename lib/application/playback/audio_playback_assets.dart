part of 'audio_playback_notifier.dart';

/// `AudioPlaybackNotifier` 专辑封面三级回退、歌词附属加载、Android 媒体会话与进度持久化扩展。
extension AudioPlaybackAssets on AudioPlaybackNotifier {
  void _bindAndroidMediaSessionCallbacks() {
    _mediaSessionBridge.bindCallbacks(
      onPlay: () {
        if (mounted && _state.isActive) {
          unawaited(setPlaying(true));
        }
      },
      onPause: () {
        if (mounted && _state.isActive) {
          unawaited(setPlaying(false));
        }
      },
      onTogglePlayPause: () {
        if (mounted && _state.isActive) {
          unawaited(togglePlayPause());
        }
      },
      onPrevious: () {
        if (mounted && _state.isActive) {
          unawaited(previous());
        }
      },
      onNext: () {
        if (mounted && _state.isActive) {
          unawaited(next());
        }
      },
      onSeekToSeconds: (seconds) {
        if (mounted && _state.isActive) {
          unawaited(seekRelativeTrackSeconds(seconds));
        }
      },
      onStop: () {
        if (mounted && _state.isActive) {
          unawaited(stopAndClose());
        }
      },
    );
  }

  void _syncAndroidMediaSession({bool forcePositionSync = false}) {
    if (!KonataPlatform.isAndroid) return;
    _bindAndroidMediaSessionCallbacks();
    final item = _state.currentItem;
    if (!_state.isActive || item == null) {
      unawaited(_mediaSessionBridge.stopSession());
      return;
    }

    String coverKey = '';
    Uint8List? coverBytes;
    switch (_state.cover) {
      case MemoryAudioCover(:final bytes):
        if (bytes.isNotEmpty) {
          coverKey = 'mem_${(_state.cover as MemoryAudioCover).contentHash}';
          coverBytes = bytes;
        }
      case ManagedPosterAudioCover(:final url, :final workId, :final revision):
        final candidateKey = 'poster_${workId}_${url}_$revision';
        final cachedBytes = _posterNotificationBytesCache[candidateKey];
        if (cachedBytes != null && cachedBytes.isNotEmpty) {
          coverKey = candidateKey;
          coverBytes = cachedBytes;
        } else {
          _warmPosterBytesForNotification(candidateKey, url);
        }
      case EmptyAudioCover():
        coverKey = '';
    }

    final artistParts = <String>[
      if (item.performer.trim().isNotEmpty) item.performer.trim(),
      if (item.work.title.trim().isNotEmpty &&
          item.work.title.trim() != item.performer.trim())
        item.work.title.trim(),
    ];
    final artistLabel = artistParts.isNotEmpty
        ? artistParts.join(' · ')
        : item.work.title.trim();
    final albumLabel = item.albumTitle.trim().isNotEmpty
        ? item.albumTitle.trim()
        : item.work.title.trim();

    unawaited(
      _mediaSessionBridge.syncSession(
        trackId: item.id,
        title: item.title,
        artist: artistLabel,
        album: albumLabel,
        durationSeconds: _state.durationSeconds,
        positionSeconds: _state.positionSeconds,
        isPlaying: _state.isPlaying,
        coverKey: coverKey,
        coverBytes: coverBytes,
        forcePositionSync: forcePositionSync,
      ),
    );
  }

  void _warmPosterBytesForNotification(String cacheKey, String url) {
    if (url.isEmpty || _loadingPosterNotificationKeys.contains(cacheKey)) {
      return;
    }
    _loadingPosterNotificationKeys.add(cacheKey);
    unawaited(() async {
      try {
        final loader = _ref.read(tmdbImageLoaderProvider);
        final bytes = await loader(url, targetWidth: 512);
        if (bytes.isEmpty || !mounted) return;
        _posterNotificationBytesCache.remove(cacheKey);
        _posterNotificationBytesCache[cacheKey] = bytes;
        while (_posterNotificationBytesCache.length > 16) {
          _posterNotificationBytesCache.remove(
            _posterNotificationBytesCache.keys.first,
          );
        }
        _syncAndroidMediaSession();
      } catch (e) {
        _logStore.record('AUDIO', '预热媒体通知海报失败：$e');
      } finally {
        _loadingPosterNotificationKeys.remove(cacheKey);
      }
    }());
  }

  AudioCoverSource _resolveInitialCoverForTrack(
    AudioQueueItem item, {
    AudioQueueItem? previousItem,
  }) {
    final cached = _albumCoverCache[item.albumCacheKey];
    if (cached != null) {
      return cached.cover;
    }
    if (previousItem != null &&
        previousItem.albumCacheKey == item.albumCacheKey &&
        _state.cover is MemoryAudioCover) {
      return _state.cover;
    }
    if (item.source == null) {
      return _resolvePosterFallback(item.work);
    }
    // 未确认目录/音频均无专属封面之前，严禁先闪现 work.posterUrl 兜底海报
    return const EmptyAudioCover();
  }

  void _cacheAlbumCover(
    String albumKey,
    AudioCoverSource cover, {
    required bool hasDedicatedCover,
  }) {
    _albumCoverCache.remove(albumKey);
    _albumCoverCache[albumKey] = (
      cover: cover,
      hasDedicatedCover: hasDedicatedCover,
    );
    while (_albumCoverCache.length >
        AudioPlaybackNotifier._maxAlbumCacheEntries) {
      _albumCoverCache.remove(_albumCoverCache.keys.first);
    }
  }

  /// 用户在移动计量网络下确认后，继续拉取 AMLL 逐字歌词索引并更新当前曲目歌词。
  Future<void> confirmMobileAmllLyricLookup() async {
    _mobileAmllLyricConfirmed = true;
    final current = _state.currentItem;
    if (!mounted || current == null) return;
    _state = _state.copyWith(needsMobileAmllLyricConfirmation: false);
    await _runFourTierLyricLookup(
      current,
      generation: _loadGeneration,
      localLrc: _state.lrcDocument,
      localActiveSpans: _state.activeSpanLines,
    );
  }

  Future<void> _runFourTierLyricLookup(
    AudioQueueItem item, {
    required int generation,
    LrcDocument? localLrc,
    List<ActiveSpanLyricLine> localActiveSpans = const [],
  }) async {
    final coordinator = _ref.read(lyricLookupCoordinatorProvider);
    final durationSec = _state.durationSeconds > 0
        ? _state.durationSeconds
        : (item.resolvedDuration > Duration.zero
              ? item.resolvedDuration.inMilliseconds / 1000.0
              : null);
    final outcome = await coordinator.lookupForTrack(
      trackTitle: item.title,
      fileName: item.effectiveFileName,
      artist: item.performer,
      durationSeconds: durationSec,
      localLrc: localLrc,
      localActiveSpans: localActiveSpans,
      mobileAmllConfirmed: _mobileAmllLyricConfirmed,
    );
    if (generation != _loadGeneration || !mounted || outcome.staleAborted) {
      return;
    }
    if (outcome.needsMobileAmllConfirmation) {
      _state = _state.copyWith(needsMobileAmllLyricConfirmation: true);
      return;
    }
    final resolvedLrc = outcome.lrcDocument;
    if (resolvedLrc == null || resolvedLrc.lines.isEmpty) {
      if (_state.needsMobileAmllLyricConfirmation) {
        _state = _state.copyWith(needsMobileAmllLyricConfirmation: false);
      }
      return;
    }
    final activeIdx = resolvedLrc.activeIndexAt(_state.positionSeconds);
    _state = _state.copyWith(
      lrcDocument: resolvedLrc,
      activeSpanLines: outcome.activeSpanLines,
      activeLyricIndex: activeIdx,
      activeLyricTier: outcome.matchedTier,
      needsMobileAmllLyricConfirmation: false,
    );
  }

  Future<void> _loadAuxiliaryAssets(
    AudioQueueItem item, {
    required int generation,
  }) async {
    final source = item.source;
    if (source == null) {
      await _runFourTierLyricLookup(item, generation: generation);
      return;
    }
    final albumKey = item.albumCacheKey;
    final physicalKey = item.physicalFileKey;
    final dirRelRaw = p.posix.dirname(
      item.effectiveRelativePath.replaceAll('\\', '/'),
    );
    final dirCacheKey = '${source.id}::${dirRelRaw == '.' ? '' : dirRelRaw}';

    final cachedCoverEntry = _albumCoverCache[albumKey];
    final cachedSiblings = _siblingsByDirCache[dirCacheKey];
    final alreadyCheckedEmbedded = _checkedEmbeddedCoverPhysicalKeys.contains(
      physicalKey,
    );
    final needFolderCoverProbe = cachedCoverEntry == null;
    final needEmbeddedProbe = !alreadyCheckedEmbedded;

    try {
      final probeVariant = item.targetAudioRelativePath == null
          ? item.variant
          : MediaVariant(
              id: item.variant.id,
              workId: item.variant.workId,
              sourceId: item.variant.sourceId,
              relativePath: item.effectiveRelativePath,
              fileName: item.effectiveFileName,
              fileSize: item.variant.fileSize,
              assetKind: item.variant.assetKind,
            );
      final aux = await AudioAssetExtractor.loadTrackAuxiliaryAssets(
        source: source,
        variant: probeVariant,
        gatewayFactory: gatewayFactory,
        cueTrackTitle: item.isCueTrack ? item.title : null,
        probeEmbeddedCover: needEmbeddedProbe,
        probeFolderCover: needFolderCoverProbe,
        cachedSiblings: cachedSiblings,
        legacyDecoder: _ref.read(legacyCodePageDecoderProvider),
      );
      if (aux.siblings != null && cachedSiblings == null) {
        _siblingsByDirCache[dirCacheKey] = aux.siblings!;
      }
      if (needEmbeddedProbe) {
        _checkedEmbeddedCoverPhysicalKeys.add(physicalKey);
      }

      if (generation != _loadGeneration || !mounted) return;

      AudioCoverSource resolvedCover;
      final existingCover = _state.cover;
      if (aux.embeddedCover != null && aux.embeddedCover!.isNotEmpty) {
        if (existingCover is MemoryAudioCover &&
            MemoryAudioCover.sameContent(
              existingCover.bytes,
              aux.embeddedCover!,
            )) {
          resolvedCover = existingCover;
        } else if (cachedCoverEntry != null &&
            cachedCoverEntry.cover is MemoryAudioCover &&
            MemoryAudioCover.sameContent(
              (cachedCoverEntry.cover as MemoryAudioCover).bytes,
              aux.embeddedCover!,
            )) {
          resolvedCover = cachedCoverEntry.cover;
        } else {
          resolvedCover = MemoryAudioCover(aux.embeddedCover!);
        }
        _cacheAlbumCover(albumKey, resolvedCover, hasDedicatedCover: true);
      } else if (cachedCoverEntry != null) {
        resolvedCover = cachedCoverEntry.cover;
      } else if (aux.folderCover != null && aux.folderCover!.isNotEmpty) {
        resolvedCover = MemoryAudioCover(aux.folderCover!);
        _cacheAlbumCover(albumKey, resolvedCover, hasDedicatedCover: true);
      } else {
        // 仅当异步探测最终确认内嵌封面与同目录封面均不存在时才回退作品海报
        resolvedCover = _resolvePosterFallback(item.work);
        _cacheAlbumCover(albumKey, resolvedCover, hasDedicatedCover: false);
      }

      final lrc = aux.lrc;
      final activeLyric = lrc != null
          ? lrc.activeIndexAt(_state.positionSeconds)
          : -1;
      _state = _state.copyWith(
        cover: resolvedCover,
        lrcDocument: lrc,
        activeSpanLines: aux.activeSpanLines,
        clearLrcDocument: lrc == null,
        activeLyricIndex: activeLyric,
        activeLyricTier: lrc != null ? LyricLookupTier.localSidecar : null,
      );

      // 本地同级未命中歌词时，自动进入四级开源歌词检索协调器（含伴奏短路、版本消歧与移动网络 AMLL 保护）。
      if (lrc == null || lrc.lines.isEmpty) {
        await _runFourTierLyricLookup(item, generation: generation);
      }
    } catch (e) {
      _logStore.record('AUDIO', '加载曲目附属封面/歌词异常：$e');
      if (generation == _loadGeneration &&
          mounted &&
          _albumCoverCache[albumKey] == null &&
          _state.cover is EmptyAudioCover) {
        final fallback = _resolvePosterFallback(item.work);
        _cacheAlbumCover(albumKey, fallback, hasDedicatedCover: false);
        _state = _state.copyWith(cover: fallback);
      }
    }
  }

  AudioCoverSource _resolvePosterFallback(Work work) {
    final url = (work.posterPath?.trim().isNotEmpty == true)
        ? work.posterPath!.trim()
        : (work.bangumiPosterPath?.trim().isNotEmpty == true)
        ? work.bangumiPosterPath!.trim()
        : (work.posterFallback?.trim() ?? '');
    if (url.isEmpty) return const EmptyAudioCover();
    return ManagedPosterAudioCover(
      url: url,
      workId: work.id,
      revision: _workPosterRevisions[work.id] ?? 0,
    );
  }

  /// 当媒体库作品海报被编辑、裁剪或重绑时，实时刷新 CD 回退封面缓存与当前在播封面。
  void syncUpdatedWorks(Iterable<Work> works, {String? forcedWorkId}) {
    if (!mounted) return;
    final changedWorks = <String, Work>{};
    for (final w in works) {
      final effectivePoster = (w.posterPath?.trim().isNotEmpty == true)
          ? w.posterPath!.trim()
          : (w.bangumiPosterPath?.trim().isNotEmpty == true)
          ? w.bangumiPosterPath!.trim()
          : (w.posterFallback?.trim() ?? '');
      final prev = _lastKnownPosterByWorkId[w.id];
      _lastKnownPosterByWorkId[w.id] = effectivePoster;
      if (forcedWorkId == w.id || (prev != null && prev != effectivePoster)) {
        _workPosterRevisions[w.id] = (_workPosterRevisions[w.id] ?? 0) + 1;
        changedWorks[w.id] = w;
      } else if (prev == null &&
          _state.queue.any(
            (q) => q.work.id == w.id && q.work.posterPath != w.posterPath,
          )) {
        _workPosterRevisions[w.id] = (_workPosterRevisions[w.id] ?? 0) + 1;
        changedWorks[w.id] = w;
      }
    }
    if (changedWorks.isEmpty) return;

    for (final entry in changedWorks.entries) {
      final wid = entry.key;
      final newFallback = _resolvePosterFallback(entry.value);
      final keysToRefresh = [
        for (final kv in _albumCoverCache.entries)
          if (kv.key.startsWith('$wid::') && !kv.value.hasDedicatedCover)
            kv.key,
      ];
      for (final k in keysToRefresh) {
        _albumCoverCache[k] = (cover: newFallback, hasDedicatedCover: false);
      }
    }

    if (_state.queue.isEmpty) return;
    var queueUpdated = false;
    final nextQueue = <AudioQueueItem>[
      for (final q in _state.queue)
        if (changedWorks.containsKey(q.work.id))
          () {
            queueUpdated = true;
            return q.copyWith(work: changedWorks[q.work.id]);
          }()
        else
          q,
    ];

    AudioCoverSource nextCover = _state.cover;
    final current =
        (_state.currentIndex >= 0 && _state.currentIndex < nextQueue.length)
        ? nextQueue[_state.currentIndex]
        : null;
    if (current != null && changedWorks.containsKey(current.work.id)) {
      final cachedEntry = _albumCoverCache[current.albumCacheKey];
      final usesFallback =
          (cachedEntry != null && !cachedEntry.hasDedicatedCover) ||
          _state.cover is ManagedPosterAudioCover ||
          _state.cover is EmptyAudioCover;
      if (usesFallback) {
        nextCover = _resolvePosterFallback(current.work);
      }
    }

    if (queueUpdated || !identical(nextCover, _state.cover)) {
      _state = _state.copyWith(queue: nextQueue, cover: nextCover);
    }
  }

  /// 供封面选择器保存后主动强制刷新指定作品的 CD 回退封面。
  Future<void> refreshWorkPosterById(String workId) async {
    try {
      final items = await _ref.read(libraryItemsProvider.future);
      if (!mounted) return;
      syncUpdatedWorks([for (final e in items) e.work], forcedWorkId: workId);
    } catch (e) {
      _logStore.record('AUDIO', '刷新作品海报回退缓存失败：$e');
    }
  }

  Future<void> _persistAudioProgress(
    AudioQueueItem item, {
    required double positionSeconds,
    required double durationSeconds,
    bool completed = false,
    bool force = false,
  }) async {
    final now = DateTime.now();
    if (!force &&
        _lastAudioPersistAt != null &&
        now.difference(_lastAudioPersistAt!) < const Duration(seconds: 5)) {
      return;
    }
    if (_persistInFlight && !force) return;
    _persistInFlight = true;
    _lastAudioPersistAt = now;
    try {
      final repo = _ref.read(libraryRepositoryProvider);
      final posSec = positionSeconds > 0 ? positionSeconds.round() : 0;
      final durSec = durationSeconds > 0 ? durationSeconds.round() : 0;
      final isDone =
          completed ||
          PlaybackRecord.computeCompleted(
            positionSeconds: posSec,
            durationSeconds: durSec,
          );
      final recordId = '${PlaybackRecord.audioEpisodePrefix}${item.id}';
      await repo.recordPlayback(
        PlaybackRecord(
          id: recordId,
          workId: item.work.id,
          episodeId: recordId,
          variantId: item.variant.id,
          seasonNumber: 0,
          episodeNumber: item.trackNumber,
          episodeTitle: item.title,
          sourceType: item.source?.kind ?? MediaSourceKind.local,
          playedAt: now,
          positionSeconds: posSec,
          durationSeconds: durSec,
          isCompleted: isDone,
        ),
      );
      if (mounted) {
        _ref.invalidate(playbackHistoryProvider);
      }
    } catch (e) {
      _logStore.record('AUDIO', '持久化音频播放进度忽略：$e');
    } finally {
      _persistInFlight = false;
    }
  }
}
