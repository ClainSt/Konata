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
      if (_androidMediaSessionStarted) {
        _androidMediaSessionStarted = false;
        unawaited(_mediaSessionBridge.stopSession());
      }
      return;
    }

    // 曲目尚未真正载入且未进入播放态（如远程建连阶段或首曲立即失败）时，
    // 不提前启动 Android 前台媒体服务，避免瞬停触发系统前台服务超时崩溃。
    if (!_state.isPlaying && !_engine.fileLoadedInCurrentEpoch) {
      if (_androidMediaSessionStarted) {
        _androidMediaSessionStarted = false;
        unawaited(_mediaSessionBridge.stopSession());
      }
      return;
    }
    _androidMediaSessionStarted = true;

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
    final source = item.source;
    if (source != null) {
      final sharedBytes = _ref
          .read(artworkMemoryCachesProvider)
          .findAudioAlbumCover(
            sourceId: source.id,
            relativePath: item.effectiveRelativePath,
            variantId: item.variant.id,
          );
      if (sharedBytes != null && sharedBytes.isNotEmpty) {
        final cover = MemoryAudioCover(sharedBytes);
        _cacheAlbumCover(
          item.albumCacheKey,
          cover,
          hasDedicatedCover: true,
          item: item,
          persistToDisk: false,
        );
        return cover;
      }
    }
    if (previousItem != null &&
        previousItem.albumCacheKey == item.albumCacheKey &&
        _state.cover is MemoryAudioCover) {
      return _state.cover;
    }
    if (source == null) {
      return _resolvePosterFallback(item.work);
    }
    // 未确认目录/音频均无专属封面之前，严禁先闪现 work.posterUrl 兜底海报
    return const EmptyAudioCover();
  }

  /// 曲目切换瞬间先从本地 `photos/<作品>/thumbnails/` 磁盘缓存回填专辑封面（纯本地读盘，不争抢远程流锁）。
  Future<void> _hydrateAlbumCoverFromDisk(
    AudioQueueItem item, {
    required int generation,
  }) async {
    final source = item.source;
    if (source == null || !mounted || generation != _loadGeneration) return;
    if (_state.cover is! EmptyAudioCover) return;
    try {
      final photos = _ref.read(photosStorageProvider);
      final diskKey = ArtworkMemoryCaches.albumCoverDiskFileKey(
        source.id,
        item.effectiveRelativePath,
      );
      final bytes = await photos.readArtwork(
        workId: item.work.id,
        title: item.work.title,
        subfolder: PhotoSubfolder.thumbnails,
        fileKey: diskKey,
      );
      if (bytes == null || bytes.isEmpty) return;
      if (!mounted || generation != _loadGeneration) return;
      final cover = MemoryAudioCover(bytes);
      _cacheAlbumCover(
        item.albumCacheKey,
        cover,
        hasDedicatedCover: true,
        item: item,
        persistToDisk: false,
      );
      if (_state.cover is EmptyAudioCover) {
        _state = _state.copyWith(cover: cover);
      }
    } catch (e) {
      _logStore.record('AUDIO', '读取本地专辑封面缓存忽略：$e');
    }
  }

  void _cacheAlbumCover(
    String albumKey,
    AudioCoverSource cover, {
    required bool hasDedicatedCover,
    AudioQueueItem? item,
    bool persistToDisk = true,
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
    final source = item?.source;
    if (hasDedicatedCover &&
        item != null &&
        source != null &&
        cover is MemoryAudioCover &&
        cover.bytes.isNotEmpty) {
      _ref
          .read(artworkMemoryCachesProvider)
          .putAudioAlbumCoverForDir(
            sourceId: source.id,
            relativePath: item.effectiveRelativePath,
            variantId: item.variant.id,
            bytes: cover.bytes,
          );
      if (persistToDisk) {
        final diskKey = ArtworkMemoryCaches.albumCoverDiskFileKey(
          source.id,
          item.effectiveRelativePath,
        );
        final workId = item.work.id;
        final workTitle = item.work.title;
        final rawCoverBytes = cover.bytes;
        final photos = _ref.read(photosStorageProvider);
        unawaited(() async {
          try {
            final compactBytes = await AlbumCoverCompactor.compactForDisk(
              rawCoverBytes,
            );
            await photos.writeArtwork(
              workId: workId,
              title: workTitle,
              subfolder: PhotoSubfolder.thumbnails,
              fileKey: diskKey,
              bytes: compactBytes,
            );
          } on Object catch (error) {
            _logStore.record('AUDIO', '落盘持久化专辑封面忽略：$error');
          }
        }());
      }
    }
  }

  /// 解析当前曲目在线歌词（缓存优先、多来源并行竞速）；本地外挂歌词已上屏时丢弃在线结果。从不抛出异常。
  Future<void> _resolveTrackLyrics(
    AudioQueueItem item, {
    required int generation,
  }) async {
    final LyricResolveOutcome outcome;
    try {
      final resolver = _ref.read(lyricsResolverProvider);
      final durationSec = _state.durationSeconds > 0
          ? _state.durationSeconds
          : (item.resolvedDuration > Duration.zero
                ? item.resolvedDuration.inMilliseconds / 1000.0
                : null);
      outcome = await resolver.resolve(
        LyricResolveRequest(
          trackKey: LyricsResolver.buildTrackKey(
            physicalFileKey: item.physicalFileKey,
            fileSize: item.variant.fileSize,
            cueStartSeconds: item.cueStartSeconds,
          ),
          query: LyricSearchQuery(
            title: item.title,
            artist: item.performer,
            album: item.albumTitle,
            fileName: item.effectiveFileName,
            durationSeconds: durationSec,
          ),
        ),
        onNetworkLookupStarted: () {
          if (generation == _loadGeneration &&
              mounted &&
              _localLyricGeneration != generation) {
            _state = _state.copyWith(isLyricLookupInFlight: true);
          }
        },
      );
    } on Object catch (e) {
      _logStore.record('AUDIO-LYRIC', '在线歌词解析异常已忽略：$e');
      if (generation == _loadGeneration && mounted) {
        _state = _state.copyWith(isLyricLookupInFlight: false);
      }
      return;
    }
    if (generation != _loadGeneration || !mounted || outcome.staleAborted) {
      return;
    }
    if (_localLyricGeneration == generation) return;
    final resolvedLrc = outcome.lrcDocument;
    if (resolvedLrc == null || resolvedLrc.lines.isEmpty) {
      if (_state.isLyricLookupInFlight) {
        _state = _state.copyWith(isLyricLookupInFlight: false);
      }
      return;
    }
    final activeIdx = resolvedLrc.activeIndexAt(_state.positionSeconds);
    _state = _state.copyWith(
      lrcDocument: resolvedLrc,
      activeSpanLines: outcome.activeSpanLines,
      activeLyricIndex: activeIdx,
      activeLyricSource: outcome.source,
      isLyricLookupInFlight: false,
    );
  }

  Future<void> _loadAuxiliaryAssets(
    AudioQueueItem item, {
    required int generation,
  }) async {
    final source = item.source;
    if (source == null) {
      await _resolveTrackLyrics(item, generation: generation);
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

    // 在线歌词与封面/外挂歌词探测并行启动，不再等待内嵌封面与目录图读取；
    // 仅当已缓存的同目录列表中存在 `.lrc` 时才先等待本地外挂结果，避免无谓联网。
    final dirMayHaveLocalLrc =
        cachedSiblings != null &&
        cachedSiblings.any(
          (e) => !e.isDirectory && e.name.toLowerCase().endsWith('.lrc'),
        );
    final onlineLyricTask = dirMayHaveLocalLrc
        ? null
        : _resolveTrackLyrics(item, generation: generation);

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
        _cacheAlbumCover(
          albumKey,
          resolvedCover,
          hasDedicatedCover: true,
          item: item,
        );
      } else if (cachedCoverEntry != null) {
        resolvedCover = cachedCoverEntry.cover;
      } else if (aux.folderCover != null && aux.folderCover!.isNotEmpty) {
        resolvedCover = MemoryAudioCover(aux.folderCover!);
        _cacheAlbumCover(
          albumKey,
          resolvedCover,
          hasDedicatedCover: true,
          item: item,
        );
      } else {
        // 仅当异步探测最终确认内嵌封面与同目录封面均不存在时才回退作品海报
        resolvedCover = _resolvePosterFallback(item.work);
        _cacheAlbumCover(
          albumKey,
          resolvedCover,
          hasDedicatedCover: false,
          item: item,
        );
      }

      final lrc = aux.lrc;
      final hasLocalLrc = lrc != null && lrc.lines.isNotEmpty;
      if (hasLocalLrc) {
        _localLyricGeneration = generation;
        _state = _state.copyWith(
          cover: resolvedCover,
          lrcDocument: lrc,
          activeSpanLines: aux.activeSpanLines,
          activeLyricIndex: lrc.activeIndexAt(_state.positionSeconds),
          activeLyricSource: LyricSource.local,
          isLyricLookupInFlight: false,
        );
      } else {
        _state = _state.copyWith(cover: resolvedCover);
      }

      if (onlineLyricTask != null) {
        await onlineLyricTask;
      } else if (!hasLocalLrc) {
        await _resolveTrackLyrics(item, generation: generation);
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
      if (onlineLyricTask != null) {
        await onlineLyricTask;
      } else {
        await _resolveTrackLyrics(item, generation: generation);
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

  void _persistCompletedCurrentTrack() {
    final finishedItem = _state.currentItem;
    if (finishedItem == null) return;
    final finishedDuration = _state.durationSeconds > 0
        ? _state.durationSeconds
        : currentPositionSeconds;
    unawaited(
      _persistAudioProgress(
        finishedItem,
        positionSeconds: finishedDuration,
        durationSeconds: _state.durationSeconds,
        completed: true,
        force: true,
      ),
    );
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
            isAudio: true,
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
