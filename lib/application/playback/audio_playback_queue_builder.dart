part of 'audio_playback_notifier.dart';

/// `AudioPlaybackNotifier` 队列构建与 `.cue` 按需动态拆轨/折叠扩展。
extension AudioPlaybackQueueBuilder on AudioPlaybackNotifier {
  Future<({List<AudioQueueItem> items, int targetIndex})> _buildQueueItems({
    required Work work,
    required List<MediaVariant> cdVariants,
    required MediaVariant initialVariant,
    required Map<String, MediaSource> sourcesById,
    int? initialCueTrackNumber,
  }) async {
    _sessionAllCdVariants = List<MediaVariant>.unmodifiable(cdVariants);
    _sessionSourcesById = Map<String, MediaSource>.unmodifiable(sourcesById);
    _unexpandedMasterByCueId.clear();
    _expandedTracksByCueId.clear();
    _nonExpandableCueIds.clear();

    final playableVariants = cdVariants
        .where((v) => AudioPlaybackNotifier.isPlayableAudioFile(v.fileName))
        .toList(growable: false);
    final cueVariants = cdVariants
        .where((v) => AudioPlaybackNotifier.isCueSheetFile(v.fileName))
        .toList(growable: false);

    // 兜底：若集合中仅存在孤立 .cue 而数据库未收录同名物理音频文件，直接按 CUE 引用虚拟展开
    if (playableVariants.isEmpty && cueVariants.isNotEmpty) {
      final targetCue =
          AudioPlaybackNotifier.isCueSheetFile(initialVariant.fileName)
          ? initialVariant
          : cueVariants.first;
      final src = sourcesById[targetCue.sourceId];
      if (src != null) {
        final folderName = p.posix.basename(
          p.posix.dirname(targetCue.relativePath.replaceAll('\\', '/')),
        );
        final dummyMaster = AudioQueueItem(
          id: targetCue.id,
          work: work,
          variant: targetCue,
          source: src,
          title: p.basenameWithoutExtension(targetCue.fileName),
          albumTitle: (folderName.isNotEmpty && folderName != '.')
              ? folderName
              : work.title,
          pairedCueVariant: targetCue,
        );
        final subTracks = await _resolveExpandedCueTracks(
          dummyMaster,
          forceSingleTrackExpand: true,
        );
        if (subTracks != null && subTracks.isNotEmpty) {
          var idx = 0;
          if (initialCueTrackNumber != null) {
            final hit = subTracks.indexWhere(
              (e) => e.trackNumber == initialCueTrackNumber,
            );
            if (hit >= 0) idx = hit;
          }
          return (items: subTracks, targetIndex: idx);
        }
      }
      return (items: const <AudioQueueItem>[], targetIndex: 0);
    }

    final cuesByDir = <String, List<MediaVariant>>{};
    for (final c in cueVariants) {
      final d =
          '${c.sourceId}::${p.posix.dirname(c.relativePath.replaceAll('\\', '/'))}';
      cuesByDir.putIfAbsent(d, () => <MediaVariant>[]).add(c);
    }
    final audiosByDir = <String, List<MediaVariant>>{};
    for (final a in playableVariants) {
      final d =
          '${a.sourceId}::${p.posix.dirname(a.relativePath.replaceAll('\\', '/'))}';
      audiosByDir.putIfAbsent(d, () => <MediaVariant>[]).add(a);
    }

    final cdSummary = SupplementarySubclassifier.groupCdVariants(
      playableVariants,
    );
    final distinctAlbums = <String>{};
    final drafts =
        <
          ({
            MediaVariant variant,
            MediaSource? source,
            String cleanTitle,
            int? trackNumber,
            String albumLabel,
            MediaVariant? pairedCue,
          })
        >[];

    for (final v in playableVariants) {
      final src = sourcesById[v.sourceId];
      final rawStem = p.basenameWithoutExtension(v.fileName);
      final parsedTrack =
          SupplementarySubclassifier.stripAudioTrackNumberPrefix(rawStem);
      final group = cdSummary.byVariantId[v.id];
      final folderName = p.posix.basename(
        p.posix.dirname(v.relativePath.replaceAll('\\', '/')),
      );
      final resolvedAlbum =
          (group != null &&
              group.chipLabel.isNotEmpty &&
              group.chipLabel != 'CD')
          ? group.chipLabel
          : ((folderName.isNotEmpty && folderName != '.')
                ? folderName
                : work.title);
      distinctAlbums.add(resolvedAlbum);

      final dirKey =
          '${v.sourceId}::${p.posix.dirname(v.relativePath.replaceAll('\\', '/'))}';
      final pairedCue = CueVariantResolver.matchCueVariantForAudio(
        audioVariant: v,
        cueVariantsInDir: cuesByDir[dirKey] ?? const [],
        audioVariantsInDir: audiosByDir[dirKey] ?? const [],
      );
      final effectiveTitle =
          (CueVariantResolver.isGenericDiscImageStem(rawStem) &&
              resolvedAlbum.isNotEmpty)
          ? resolvedAlbum
          : parsedTrack.cleanTitle;

      drafts.add((
        variant: v,
        source: src,
        cleanTitle: effectiveTitle,
        trackNumber: pairedCue != null ? null : parsedTrack.trackNumber,
        albumLabel: resolvedAlbum,
        pairedCue: pairedCue,
      ));
    }

    final showSub = distinctAlbums.length >= 2 || drafts.isNotEmpty;
    final items = <AudioQueueItem>[
      for (final d in drafts)
        () {
          final physKey =
              '${d.source?.id ?? 'local'}::${d.variant.relativePath.replaceAll('\\', '/')}';
          final knownDur = _rawDurationByPhysicalKey[physKey] ?? 0.0;
          return AudioQueueItem(
            id: d.variant.id,
            work: work,
            variant: d.variant,
            source: d.source,
            title: d.cleanTitle,
            trackNumber: d.trackNumber,
            albumTitle: d.albumLabel,
            showAlbumSubtitle: showSub,
            pairedCueVariant: d.pairedCue,
            duration: knownDur > 0
                ? Duration(milliseconds: (knownDur * 1000).round())
                : Duration.zero,
          );
        }(),
    ];

    if (items.isEmpty) {
      return (items: items, targetIndex: 0);
    }

    var masterIdx = -1;
    if (AudioPlaybackNotifier.isCueSheetFile(initialVariant.fileName)) {
      masterIdx = items.indexWhere(
        (e) => e.pairedCueVariant?.id == initialVariant.id,
      );
      if (masterIdx < 0) {
        final initDir = p.posix.dirname(
          initialVariant.relativePath.replaceAll('\\', '/'),
        );
        masterIdx = items.indexWhere(
          (e) =>
              e.variant.sourceId == initialVariant.sourceId &&
              p.posix.dirname(e.variant.relativePath.replaceAll('\\', '/')) ==
                  initDir,
        );
      }
    } else {
      masterIdx = items.indexWhere((e) => e.variant.id == initialVariant.id);
    }
    if (masterIdx < 0) masterIdx = 0;

    final targetMaster = items[masterIdx];
    final cueVar = targetMaster.pairedCueVariant;
    if (cueVar != null) {
      final forceExpand =
          AudioPlaybackNotifier.isCueSheetFile(initialVariant.fileName) ||
          initialCueTrackNumber != null;
      final subTracks = await _resolveExpandedCueTracks(
        targetMaster,
        forceSingleTrackExpand: forceExpand,
      );
      if (subTracks != null && subTracks.isNotEmpty) {
        _unexpandedMasterByCueId[cueVar.id] = targetMaster;
        items.replaceRange(masterIdx, masterIdx + 1, subTracks);
        var subIdx = 0;
        if (initialCueTrackNumber != null) {
          final matched = subTracks.indexWhere(
            (e) => e.trackNumber == initialCueTrackNumber,
          );
          if (matched >= 0) subIdx = matched;
        }
        return (items: items, targetIndex: masterIdx + subIdx);
      }
    }

    return (items: items, targetIndex: masterIdx);
  }

  /// 读取并构建指定整轨条目的 CUE 子单曲列表（内置内存缓存，同会话重复切回零 IO）。
  Future<List<AudioQueueItem>?> _resolveExpandedCueTracks(
    AudioQueueItem masterItem, {
    bool forceSingleTrackExpand = false,
  }) async {
    final cueVariant = masterItem.pairedCueVariant;
    final source =
        masterItem.source ?? _sessionSourcesById[masterItem.variant.sourceId];
    if (cueVariant == null || source == null) return null;

    final cached = _expandedTracksByCueId[cueVariant.id];
    if (cached != null) {
      return _refreshCueTrackDurations(cached);
    }
    if (_nonExpandableCueIds.contains(cueVariant.id)) {
      return null;
    }

    final cueSheet = await AudioAssetExtractor.loadCueSheet(
      source: source,
      cueRelativePath: cueVariant.relativePath,
      gatewayFactory: gatewayFactory,
      knownFileSize: cueVariant.fileSize > 0 ? cueVariant.fileSize : null,
      legacyDecoder: _ref.read(legacyCodePageDecoderProvider),
    );
    if (cueSheet == null || cueSheet.tracks.isEmpty) {
      _nonExpandableCueIds.add(cueVariant.id);
      return null;
    }

    // 单轨无分章整碟若标题与母碟相同，保持单行整轨播放不重复挂子项
    if (!forceSingleTrackExpand && cueSheet.tracks.length == 1) {
      final rawOnlyTitle = cueSheet.tracks.first.title.trim();
      final strippedOnly =
          SupplementarySubclassifier.stripAudioTrackNumberPrefix(
            rawOnlyTitle,
          ).cleanTitle.trim();
      final isGenericTrack1 = RegExp(
        r'^track\s*0*1$',
        caseSensitive: false,
      ).hasMatch(rawOnlyTitle);
      if (strippedOnly.isEmpty ||
          isGenericTrack1 ||
          strippedOnly.toLowerCase() == masterItem.title.trim().toLowerCase()) {
        _nonExpandableCueIds.add(cueVariant.id);
        return null;
      }
    }

    final cueDir = p.posix.dirname(
      cueVariant.relativePath.replaceAll('\\', '/'),
    );
    final audioVariantsInDir = _sessionAllCdVariants
        .where((v) {
          if (v.sourceId != cueVariant.sourceId ||
              !AudioPlaybackNotifier.isPlayableAudioFile(v.fileName)) {
            return false;
          }
          return p.posix.dirname(v.relativePath.replaceAll('\\', '/')) ==
              cueDir;
        })
        .toList(growable: false);

    final built = <AudioQueueItem>[];
    for (final track in cueSheet.tracks) {
      final targetAudio = CueVariantResolver.resolve(
        cueVariant: cueVariant,
        cueTrack: track,
        audioVariantsInDir: audioVariantsInDir,
        fallbackInitial: masterItem.variant,
      );
      if (targetAudio == null) continue;
      final src = _sessionSourcesById[targetAudio.sourceId] ?? source;
      final rawTrackTitle = track.title.trim();
      final strippedTitle =
          SupplementarySubclassifier.stripAudioTrackNumberPrefix(
            rawTrackTitle,
          ).cleanTitle.trim();
      final cleanTrackTitle = strippedTitle.isNotEmpty
          ? strippedTitle
          : (rawTrackTitle.isNotEmpty
                ? rawTrackTitle
                : '曲目 ${track.trackNumber}');

      built.add(
        AudioQueueItem(
          id: '${cueVariant.id}::track_${track.trackNumber}',
          work: masterItem.work,
          variant: targetAudio,
          source: src,
          title: cleanTrackTitle,
          performer: track.performer.isNotEmpty
              ? track.performer
              : cueSheet.performer,
          albumTitle: masterItem.albumTitle.isNotEmpty
              ? masterItem.albumTitle
              : (cueSheet.title.isNotEmpty
                    ? cueSheet.title
                    : masterItem.work.title),
          trackNumber: track.trackNumber,
          cueStartSeconds: track.startSeconds,
          cueEndSeconds: track.endSeconds,
          targetAudioRelativePath: targetAudio.relativePath,
          showAlbumSubtitle: masterItem.showAlbumSubtitle,
          pairedCueVariant: cueVariant,
          cueDiscTitle: masterItem.title,
        ),
      );
    }

    if (built.isEmpty) {
      _nonExpandableCueIds.add(cueVariant.id);
      return null;
    }
    final refreshed = _refreshCueTrackDurations(built);
    _expandedTracksByCueId[cueVariant.id] = refreshed;
    return refreshed;
  }

  List<AudioQueueItem> _refreshCueTrackDurations(List<AudioQueueItem> tracks) {
    return <AudioQueueItem>[
      for (final t in tracks)
        () {
          final knownRawDur =
              _rawDurationByPhysicalKey[t.physicalFileKey] ?? 0.0;
          final start = t.cueStartSeconds ?? 0.0;
          final end = t.cueEndSeconds;
          if (end != null && end > start) {
            return t.copyWith(
              duration: Duration(milliseconds: ((end - start) * 1000).round()),
            );
          }
          if (end == null && knownRawDur > start) {
            return t.copyWith(
              duration: Duration(
                milliseconds: ((knownRawDur - start) * 1000).round(),
              ),
            );
          }
          return t;
        }(),
    ];
  }

  /// 切换曲目时自动收起已离开的旧整轨 CD 子单曲，并按需拆开新轮到的整轨 CD 子单曲。
  Future<int?> _reconcileCueWindowForTarget(
    int targetIndex, {
    required int generation,
    bool selectLastOnExpand = false,
  }) async {
    if (targetIndex < 0 || targetIndex >= _state.queue.length || !mounted) {
      return null;
    }
    var workingQueue = List<AudioQueueItem>.of(_state.queue);
    var adjustedIndex = targetIndex;
    final targetCueId = workingQueue[adjustedIndex].pairedCueVariant?.id;

    // 1. 折叠非当前目标的已展开整轨 CD
    var queueMutated = false;
    var scan = 0;
    while (scan < workingQueue.length) {
      final item = workingQueue[scan];
      final cueId = item.pairedCueVariant?.id;
      if (item.isCueTrack &&
          cueId != null &&
          cueId != targetCueId &&
          _unexpandedMasterByCueId.containsKey(cueId)) {
        var groupEnd = scan;
        while (groupEnd + 1 < workingQueue.length &&
            workingQueue[groupEnd + 1].isCueTrack &&
            workingQueue[groupEnd + 1].pairedCueVariant?.id == cueId) {
          groupEnd++;
        }
        var master = _unexpandedMasterByCueId[cueId]!;
        final knownDur =
            _rawDurationByPhysicalKey[master.physicalFileKey] ?? 0.0;
        if (knownDur > 0 && master.duration == Duration.zero) {
          master = master.copyWith(
            duration: Duration(milliseconds: (knownDur * 1000).round()),
          );
          _unexpandedMasterByCueId[cueId] = master;
        }
        final removedExtra = groupEnd - scan;
        workingQueue.replaceRange(scan, groupEnd + 1, <AudioQueueItem>[master]);
        if (adjustedIndex > groupEnd) {
          adjustedIndex -= removedExtra;
        } else if (adjustedIndex >= scan) {
          adjustedIndex = scan;
        }
        queueMutated = true;
        scan++;
        continue;
      }
      scan++;
    }

    if (queueMutated) {
      _state = _state.copyWith(queue: workingQueue, currentIndex: adjustedIndex);
    }

    // 2. 若当前轮到的目标条目是尚未展开的整轨 CD，按需解析并在其下方拆出单曲
    final activeCandidate = workingQueue[adjustedIndex];
    final candidateCue = activeCandidate.pairedCueVariant;
    if (!activeCandidate.isCueTrack &&
        candidateCue != null &&
        !_nonExpandableCueIds.contains(candidateCue.id)) {
      if (!_expandedTracksByCueId.containsKey(candidateCue.id)) {
        _state = _state.copyWith(currentIndex: adjustedIndex, isBuffering: true);
      }
      final subTracks = await _resolveExpandedCueTracks(activeCandidate);
      if (generation != _loadGeneration || !mounted) return null;
      if (subTracks != null && subTracks.isNotEmpty) {
        final latestQueue = List<AudioQueueItem>.of(_state.queue);
        final livePos = latestQueue.indexWhere(
          (e) => e.id == activeCandidate.id,
        );
        if (livePos >= 0) {
          _unexpandedMasterByCueId[candidateCue.id] = activeCandidate;
          latestQueue.replaceRange(livePos, livePos + 1, subTracks);
          final nextIdx = selectLastOnExpand
              ? (livePos + subTracks.length - 1)
              : livePos;
          _state = _state.copyWith(queue: latestQueue, currentIndex: nextIdx);
          return nextIdx;
        }
      }
    }

    return adjustedIndex;
  }
}
