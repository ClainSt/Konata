part of 'embedded_mpv_session.dart';

/// `EmbeddedMpvSession` 外挂字幕/音轨发现、流令牌租约登记与轨道选择扩展。
extension EmbeddedMpvSessionSidecars on EmbeddedMpvSession {
  Future<
    ({
      String mediaTarget,
      List<String> subtitlePaths,
      List<String> audioTargets,
    })
  >
  _prepareMediaAndSidecars(EmbeddedVideoLoadRequest request) async {
    final source = request.source;
    final variant = request.variant;

    if (source == null || source.kind == MediaSourceKind.local) {
      if (source == null) {
        return (
          mediaTarget: variant.relativePath,
          subtitlePaths: variant.externalSubtitles,
          audioTargets: const <String>[],
        );
      }
      final gw = LocalSourceGateway(rootPath: source.location);
      final mediaAbs = gw.resolveAbsolutePath(variant.relativePath);
      final candidates = <String>[];
      try {
        final parentRel = SubtitleAndAudioChoices.parentDirOf(
          variant.relativePath,
        );
        final entries = await gw.listDirectory(parentRel);
        for (final entry in entries) {
          if (!entry.isDirectory) candidates.add(entry.relativePath);
        }
        final audioSubRel = parentRel.isEmpty ? 'Audio' : '$parentRel/Audio';
        try {
          final subEntries = await gw.listDirectory(audioSubRel);
          for (final entry in subEntries) {
            if (!entry.isDirectory) candidates.add(entry.relativePath);
          }
        } catch (e) {
          logStore?.record('mpv-sidecar', '枚举本地 Audio 子目录忽略：$e');
        }
      } catch (e) {
        logStore?.record('mpv-sidecar', '枚举本地同级目录失败：$e', isError: true);
      }

      final matchedSubs = SubtitleMatcher.matchForVideo(
        videoRelativePath: variant.relativePath,
        allSubtitleRelativePaths: {
          ...candidates,
          ...variant.externalSubtitles,
        }.toList(),
      );
      final absSubs = <String>[];
      for (final rel in {
        ...matchedSubs.subtitlePaths,
        ...variant.externalSubtitles,
      }) {
        final abs = gw.resolveAbsolutePath(rel);
        if (await File(abs).exists()) absSubs.add(abs);
      }

      final matchedAudioRel =
          SubtitleAndAudioChoices.findMatchingExternalAudioPaths(
            videoRelativePath: variant.relativePath,
            candidatePaths: candidates,
          );
      final absAudio = <String>[];
      for (final rel in matchedAudioRel) {
        final abs = gw.resolveAbsolutePath(rel);
        if (await File(abs).exists()) absAudio.add(abs);
      }

      return (
        mediaTarget: mediaAbs,
        subtitlePaths: absSubs,
        audioTargets: absAudio,
      );
    }

    // WebDAV / SMB 远程流式透传：注册主媒体流并交由统一引擎登记主流租约，秒速调用 loadfile
    final mainGw = await gatewayFactory.create(source);
    if (mainGw is! ByteRangeReadableGateway) {
      await mainGw.close();
      throw UnsupportedError('媒体源 ${source.kind.name} 不支持流式透传播放');
    }
    final byteGw = mainGw as ByteRangeReadableGateway;
    final mainReg = await streamBridge.registerSession(
      gateway: byteGw,
      relativePath: variant.relativePath,
      fileName: variant.fileName,
      knownLength: variant.fileSize > 0 ? variant.fileSize : null,
      ownsGateway: true,
    );
    _activeStreamTokens.add(mainReg.token);
    final displacedLease = onBindMainStreamLease?.call(mainReg.token);
    if (displacedLease != null && displacedLease.isNotEmpty) {
      unawaited(_unregisterTokens(<String>[displacedLease]));
    }

    final cachedSubs = await streamBridge.resolveExistingCachedSubtitles(
      workId: request.workId,
      sourceId: source.id,
      subtitleRelativePaths: variant.externalSubtitles,
    );
    return (
      mediaTarget: mainReg.url.toString(),
      subtitlePaths: cachedSubs,
      audioTargets: const <String>[],
    );
  }

  Future<void> _discoverAndAttachRemoteSidecars(
    EmbeddedVideoLoadRequest request, {
    required int generation,
  }) async {
    final source = request.source;
    final variant = request.variant;
    if (_disposed ||
        generation != _loadGeneration ||
        source == null ||
        source.kind == MediaSourceKind.local) {
      return;
    }

    final sidecarGw = await gatewayFactory.create(source);
    if (sidecarGw is! ByteRangeReadableGateway) {
      await sidecarGw.close();
      return;
    }
    final byteGw = sidecarGw as ByteRangeReadableGateway;
    final stagedAudioTokens = <String>[];

    try {
      final siblingPaths = <String>[...variant.externalSubtitles];
      try {
        final parentRel = SubtitleAndAudioChoices.parentDirOf(
          variant.relativePath,
        );
        final cachedSnapshot = subtitleDirectoryIndex?.lookup(
          source.id,
          parentRel,
        );
        if (cachedSnapshot != null && !cachedSnapshot.incompleteForSimplified) {
          siblingPaths.addAll(cachedSnapshot.siblingPaths);
        } else if (cachedSnapshot != null &&
            cachedSnapshot.incompleteForSimplified &&
            cachedSnapshot.unscannedSubdirs.isNotEmpty) {
          // 已有快照仅在前 4 个子目录命中非简中字幕且仍有未扫目录：续扫剩余子目录，不写假阴性负缓存。
          final mergedPaths = <String>[...cachedSnapshot.siblingPaths];
          var extraScanned = 0;
          for (final subDir in cachedSnapshot.unscannedSubdirs) {
            if (_disposed || generation != _loadGeneration) return;
            extraScanned += 1;
            try {
              final subEntries = await sidecarGw.listDirectory(subDir);
              for (final sub in subEntries) {
                if (!sub.isDirectory) mergedPaths.add(sub.relativePath);
              }
            } catch (e) {
              logStore?.record('mpv-sidecar', '续扫远程字幕子目录 $subDir 失败：$e');
            }
          }
          subtitleDirectoryIndex?.put(
            sourceId: source.id,
            dirRelativePath: parentRel,
            siblingPaths: mergedPaths,
            hasUnscannedSubdirs: false,
            scannedSubdirCount:
                cachedSnapshot.scannedSubdirCount + extraScanned,
            unscannedSubdirs: const [],
          );
          siblingPaths.addAll(mergedPaths);
        } else {
          final entries = await sidecarGw.listDirectory(parentRel);
          if (_disposed || generation != _loadGeneration) return;

          final discoveredPaths = <String>[];
          final candidateSubdirs = <String>[];
          for (final entry in entries) {
            if (!entry.isDirectory) {
              discoveredPaths.add(entry.relativePath);
            } else {
              final lowerName = entry.name.toLowerCase();
              if (lowerName == 'subs' ||
                  lowerName == 'subtitles' ||
                  lowerName == '字幕' ||
                  lowerName == 'audio' ||
                  lowerName == 'sp audio') {
                candidateSubdirs.add(entry.relativePath);
              }
            }
          }
          var scannedSubdirs = 0;
          for (final subDir in candidateSubdirs) {
            if (scannedSubdirs >=
                SubtitleDirectoryIndex.maxAutoSubdirScanCount) {
              break;
            }
            scannedSubdirs += 1;
            try {
              final subEntries = await sidecarGw.listDirectory(subDir);
              for (final sub in subEntries) {
                if (!sub.isDirectory) discoveredPaths.add(sub.relativePath);
              }
            } catch (e) {
              logStore?.record('mpv-sidecar', '扫描远程字幕子目录 $subDir 失败：$e');
            }
          }
          final remainingSubdirs = scannedSubdirs < candidateSubdirs.length
              ? candidateSubdirs.sublist(scannedSubdirs)
              : const <String>[];
          subtitleDirectoryIndex?.put(
            sourceId: source.id,
            dirRelativePath: parentRel,
            siblingPaths: discoveredPaths,
            hasUnscannedSubdirs: remainingSubdirs.isNotEmpty,
            scannedSubdirCount: scannedSubdirs,
            unscannedSubdirs: remainingSubdirs,
          );
          siblingPaths.addAll(discoveredPaths);
        }
      } catch (e) {
        logStore?.record('mpv-sidecar', '拉取远程同级目录清单失败：$e', isError: true);
      }

      if (_disposed || generation != _loadGeneration) return;

      final matchedSubs = SubtitleMatcher.matchForVideo(
        videoRelativePath: variant.relativePath,
        allSubtitleRelativePaths: siblingPaths,
      );
      final localSubs = await streamBridge.materializeRemoteSubtitles(
        gateway: byteGw,
        workId: request.workId,
        sourceId: source.id,
        subtitleRelativePaths: {
          ...matchedSubs.subtitlePaths,
          ...variant.externalSubtitles,
        }.toList(),
      );
      if (_disposed || generation != _loadGeneration) return;

      final matchedAudioRel =
          SubtitleAndAudioChoices.findMatchingExternalAudioPaths(
            videoRelativePath: variant.relativePath,
            candidatePaths: siblingPaths,
          );
      final audioUrls = <String>[];
      for (final audioRel in matchedAudioRel) {
        if (_disposed || generation != _loadGeneration) {
          await _unregisterTokens(stagedAudioTokens);
          return;
        }
        try {
          final extGw = await gatewayFactory.create(source);
          if (extGw is! ByteRangeReadableGateway) {
            await extGw.close();
            continue;
          }
          final reg = await streamBridge.registerSession(
            gateway: extGw as ByteRangeReadableGateway,
            relativePath: audioRel,
            fileName: p.basename(audioRel),
            ownsGateway: true,
          );
          stagedAudioTokens.add(reg.token);
          audioUrls.add(reg.url.toString());
        } catch (e) {
          logStore?.record(
            'mpv-sidecar',
            '注册远程外挂音轨流失败（$audioRel）：$e',
            isError: true,
          );
        }
      }

      if (_disposed || generation != _loadGeneration) {
        await _unregisterTokens(stagedAudioTokens);
        return;
      }

      _activeStreamTokens.addAll(stagedAudioTokens);
      _pendingExternalSubtitles = localSubs;
      _pendingExternalAudioPaths = audioUrls;
      if (_fileLoadedForCurrentGen) {
        _mountSidecarsAndResolveTracks();
      }
    } finally {
      await sidecarGw.close().catchError((Object e) {
        logStore?.record('mpv-sidecar', '关闭远程辅流网关异常：$e');
      });
    }
  }

  Future<void> _unregisterTokens(List<String> tokens) async {
    for (final token in tokens) {
      try {
        await streamBridge.unregisterSession(token);
      } catch (e) {
        logStore?.record('mpv-stream', '注销流令牌 $token 异常：$e');
      }
    }
  }

  void _mountSidecarsAndResolveTracks() {
    final client = _client;
    if (client == null || client.isDisposed) return;

    final existingTracks = client.readTrackList();
    final mountedNames = <String>{};
    for (final t in existingTracks) {
      final f = t.externalFilename;
      if (f != null && f.isNotEmpty) {
        mountedNames.add(p.basename(f.split('?').first).toLowerCase());
      }
    }

    // 挂载额外扫描到的外挂字幕与 .mka/.flac 外挂音轨
    final idxStems = _pendingExternalSubtitles
        .where((s) => SubtitleAndAudioChoices.extensionOf(s) == '.idx')
        .map((s) => s.replaceAll('\\', '/').toLowerCase())
        .toSet();
    for (final sub in _pendingExternalSubtitles) {
      final base = p.basename(sub.split('?').first).toLowerCase();
      if (mountedNames.contains(base)) continue;
      if (SubtitleAndAudioChoices.extensionOf(sub) == '.sub') {
        final stem = '${sub.substring(0, sub.length - 4)}.idx'
            .replaceAll('\\', '/')
            .toLowerCase();
        if (idxStems.contains(stem)) continue;
      }
      client.command(['sub-add', sub, 'auto']);
      mountedNames.add(base);
    }

    for (final aud in _pendingExternalAudioPaths) {
      final base = p.basename(aud.split('?').first).toLowerCase();
      if (mountedNames.contains(base)) continue;
      client.command(['audio-add', aud, 'auto']);
      mountedNames.add(base);
    }

    // 基于 CrossEpisodeTrackMemory 或默认简中/日语偏好锁定轨道
    final refreshedTracks = client.readTrackList();
    final chosenAudio = _trackMemory.resolveAudioTrack(
      refreshedTracks,
      fallback: _trackPreferences,
    );
    if (chosenAudio != null && !chosenAudio.selected) {
      client.setPropertyInt64('aid', chosenAudio.id);
    }

    if (_trackMemory.subtitleDisabled) {
      client.setPropertyString('sid', 'no');
    } else {
      final chosenSub = _trackMemory.resolveSubtitleTrack(
        refreshedTracks,
        fallback: _trackPreferences,
      );
      if (chosenSub != null && !chosenSub.selected) {
        client.setPropertyInt64('sid', chosenSub.id);
      }
    }

    _emitMediaMetadataSnapshot();
  }

  void _emitMediaMetadataSnapshot() {
    final client = _client;
    if (client == null || client.isDisposed || !client.isInitialized) return;
    final tracks = client.readTrackList();
    final subs = SubtitleAndAudioChoices.mergeSubtitles(
      mpvTracks: tracks,
      discoveredExternalPaths: _pendingExternalSubtitles,
    );
    final audios = SubtitleAndAudioChoices.mergeAudioTracks(
      mpvTracks: tracks,
      discoveredExternalAudioPaths: _pendingExternalAudioPaths,
    );
    final chapters = client.readChapterList(
      totalDurationSeconds: _totalDurationSeconds > 0
          ? _totalDurationSeconds
          : null,
    );
    final devices = client.readAudioDeviceList();
    onMediaMetadataUpdated?.call(
      subtitles: subs,
      audioTracks: audios,
      chapters: chapters,
      audioDevices: devices,
    );
  }

  /// 调整外挂或内封字幕延迟（暂停态自动执行零位移精确定位以立即刷新静态帧字幕）。
  void setSubtitleDelay(double seconds) {
    final client = _client;
    if (_disposed || client == null || client.isDisposed) return;
    final rc = client.setPropertyDouble('sub-delay', seconds);
    if (rc < 0) {
      client.setPropertyString('sub-delay', seconds.toStringAsFixed(2));
    }
    if (client.getPropertyFlag('pause') ?? false) {
      client.command(['seek', '0', 'relative', 'exact']);
    }
  }

  /// 调整音频延迟秒数。
  void setAudioDelay(double seconds) {
    final client = _client;
    if (_disposed || client == null || client.isDisposed) return;
    final rc = client.setPropertyDouble('audio-delay', seconds);
    if (rc < 0) {
      client.setPropertyString('audio-delay', seconds.toStringAsFixed(2));
    }
  }

  /// 切换当前主字幕轨道或关闭字幕。
  void selectSubtitle(SubtitleChoice? choice) {
    final client = _client;
    if (client == null || client.isDisposed) return;
    if (choice == null) {
      client.setPropertyString('sid', 'no');
    } else if (choice.mpvTrackId != null) {
      final trackId = choice.mpvTrackId!;
      final rc = client.setPropertyInt64('sid', trackId);
      if (rc < 0) {
        client.setPropertyString('sid', '$trackId');
      }
    } else if (choice.externalPath != null && choice.externalPath!.isNotEmpty) {
      client.command(['sub-add', choice.externalPath!, 'select']);
    }
    _emitMediaMetadataSnapshot();
  }

  /// 挂载并选中指定外挂字幕路径。
  void addExternalSubtitleFile(String absolutePath) {
    final client = _client;
    if (client == null || client.isDisposed || absolutePath.trim().isEmpty) {
      return;
    }
    client.command(['sub-add', absolutePath.trim(), 'select']);
    _emitMediaMetadataSnapshot();
  }

  /// 切换或挂载音轨。
  void selectAudioTrack(AudioTrackChoice choice) {
    final client = _client;
    if (client == null || client.isDisposed) return;
    if (choice.mpvTrackId != null) {
      final trackId = choice.mpvTrackId!;
      final rc = client.setPropertyInt64('aid', trackId);
      if (rc < 0) {
        client.setPropertyString('aid', '$trackId');
      }
    } else if (choice.externalPath != null && choice.externalPath!.isNotEmpty) {
      client.command(['audio-add', choice.externalPath!, 'select']);
    }
    _emitMediaMetadataSnapshot();
  }
}
