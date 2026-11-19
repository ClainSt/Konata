part of 'embedded_mpv_session.dart';

/// `EmbeddedMpvSession` 外挂字幕/音轨发现、远程字库入池、流令牌租约登记与轨道选择扩展。
extension EmbeddedMpvSessionSidecars on EmbeddedMpvSession {
  static bool _isTextSubtitlePath(String rawPath) =>
      KonataMediaExtensions.isTextSubtitleFile(rawPath.split('?').first);

  static bool _isFontsZipName(String fileName) {
    final lower = fileName.trim().toLowerCase();
    return lower == 'fonts.zip' ||
        lower == 'font.zip' ||
        (lower.endsWith('.zip') && lower.contains('font'));
  }

  static bool _isFontsDirName(String dirName) {
    final lower = dirName.trim().toLowerCase();
    return lower == 'fonts' || lower == 'font';
  }

  /// 本地媒体字体解析：先尝试同级/父级 `Fonts/` 原位只读直挂，缺失时自动解包同级/父级 `Fonts.zip` 入单级哈希池。
  Future<String?> _resolveLocalFontPackDir(String localMediaAbsPath) async {
    final inPlace = await _fontPoolManager.resolveInPlaceSiblingFontsDir(
      localMediaAbsPath,
    );
    if (inPlace != null) {
      return inPlace.directoryPath;
    }
    final trimmed = localMediaAbsPath.trim();
    if (trimmed.isEmpty || !p.isAbsolute(trimmed)) return null;
    try {
      final videoDir = Directory(p.dirname(trimmed));
      if (!await videoDir.exists()) return null;
      final parents = <Directory>[
        videoDir,
        if (videoDir.parent.path != videoDir.path) videoDir.parent,
      ];
      const directZipNames = ['Fonts.zip', 'fonts.zip', 'Font.zip', 'font.zip'];
      final candidates = <File>[
        for (final parent in parents)
          for (final zipName in directZipNames)
            File(p.join(parent.path, zipName)),
      ];
      final existsList = await Future.wait(candidates.map((f) => f.exists()));
      final seenPaths = <String>{};
      for (var i = 0; i < candidates.length; i++) {
        if (!existsList[i]) continue;
        final candidate = candidates[i];
        if (!seenPaths.add(candidate.path.toLowerCase())) continue;
        final len = await candidate.length();
        if (len <= 22 || len > SubtitleFontPoolManager.maxTotalExtractBytes) {
          continue;
        }
        try {
          final zipBytes = await candidate.readAsBytes();
          final ingested = await _fontPoolManager.ingestFontZipBytes(zipBytes);
          return ingested.directoryPath;
        } on Object catch (e) {
          logStore?.record(
            'mpv-fonts',
            '解析本地字体压缩包 ${p.basename(candidate.path)} 失败：$e',
          );
        }
      }
    } on Object catch (e) {
      logStore?.record('mpv-fonts', '检索本地 Fonts.zip 忽略：$e');
    }
    return null;
  }

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
          if (!entry.isDirectory) {
            candidates.add(entry.relativePath);
          } else if (SubtitleAndAudioChoices.isSidecarSubdirName(entry.name)) {
            try {
              final subEntries = await gw.listDirectory(entry.relativePath);
              for (final sub in subEntries) {
                if (!sub.isDirectory) candidates.add(sub.relativePath);
              }
            } on Object catch (e) {
              logStore?.record(
                'mpv-sidecar',
                '枚举本地附属子目录 ${entry.name} 忽略：$e',
              );
            }
          }
        }
      } on Object catch (e) {
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

    // WebDAV / SMB 远程流式透传：注册主媒体流并交由统一引擎登记主流租约，秒速调用 loadfile。
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
      sourceKind: source.kind,
    );
    _activeStreamTokens.add(mainReg.token);
    final displacedLease = onBindMainStreamLease?.call(mainReg.token);
    if (displacedLease != null && displacedLease.isNotEmpty) {
      unawaited(_unregisterTokens(<String>[displacedLease]));
    }

    final parentRel = SubtitleAndAudioChoices.parentDirOf(variant.relativePath);
    final cachedSnapshot = subtitleDirectoryIndex?.lookup(source.id, parentRel);
    final cachedSubs = await streamBridge.resolveExistingCachedSubtitles(
      workId: request.workId,
      sourceId: source.id,
      subtitleRelativePaths: variant.externalSubtitles,
      validatorsByPath: cachedSnapshot?.validatorsByPath,
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
      final validatorsByPath = <String, String>{};
      String? remoteFontsZipRelPath;
      String? remoteFontsDirRelPath;

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
          validatorsByPath.addAll(cachedSnapshot.validatorsByPath);
          for (final rel in cachedSnapshot.siblingPaths) {
            if (remoteFontsZipRelPath == null &&
                _isFontsZipName(p.posix.basename(rel))) {
              remoteFontsZipRelPath = rel;
            }
          }
        } else if (cachedSnapshot != null &&
            cachedSnapshot.incompleteForSimplified &&
            cachedSnapshot.unscannedSubdirs.isNotEmpty) {
          // 已有快照仅在前 4 个子目录命中非简中字幕且仍有未扫目录：续扫剩余子目录，不写假阴性负缓存。
          final mergedPaths = <String>[...cachedSnapshot.siblingPaths];
          final mergedValidators = <String, String>{
            ...cachedSnapshot.validatorsByPath,
          };
          var extraScanned = 0;
          for (final subDir in cachedSnapshot.unscannedSubdirs) {
            if (_disposed || generation != _loadGeneration) return;
            extraScanned += 1;
            try {
              final subEntries = await sidecarGw.listDirectory(subDir);
              for (final sub in subEntries) {
                if (!sub.isDirectory) {
                  mergedPaths.add(sub.relativePath);
                  final validator = sub.cacheValidator;
                  if (validator != null) {
                    mergedValidators[sub.relativePath] = validator;
                  }
                }
              }
            } on Object catch (e) {
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
            validatorsByPath: mergedValidators,
          );
          siblingPaths.addAll(mergedPaths);
          validatorsByPath.addAll(mergedValidators);
        } else {
          final entries = await sidecarGw.listDirectory(parentRel);
          if (_disposed || generation != _loadGeneration) return;

          final discoveredPaths = <String>[];
          final discoveredValidators = <String, String>{};
          final candidateSubdirs = <String>[];
          for (final entry in entries) {
            if (!entry.isDirectory) {
              discoveredPaths.add(entry.relativePath);
              final validator = entry.cacheValidator;
              if (validator != null) {
                discoveredValidators[entry.relativePath] = validator;
              }
              if (remoteFontsZipRelPath == null &&
                  _isFontsZipName(entry.name)) {
                remoteFontsZipRelPath = entry.relativePath;
              }
            } else {
              if (remoteFontsDirRelPath == null &&
                  _isFontsDirName(entry.name)) {
                remoteFontsDirRelPath = entry.relativePath;
              } else if (SubtitleAndAudioChoices.isSidecarSubdirName(
                entry.name,
              )) {
                candidateSubdirs.add(entry.relativePath);
              }
            }
          }
          var scannedSubdirs = 0;
          for (final subDir in candidateSubdirs) {
            if (_disposed || generation != _loadGeneration) return;
            if (scannedSubdirs >=
                SubtitleDirectoryIndex.maxAutoSubdirScanCount) {
              break;
            }
            scannedSubdirs += 1;
            try {
              final subEntries = await sidecarGw.listDirectory(subDir);
              for (final sub in subEntries) {
                if (!sub.isDirectory) {
                  discoveredPaths.add(sub.relativePath);
                  final validator = sub.cacheValidator;
                  if (validator != null) {
                    discoveredValidators[sub.relativePath] = validator;
                  }
                }
              }
            } on Object catch (e) {
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
            validatorsByPath: discoveredValidators,
          );
          siblingPaths.addAll(discoveredPaths);
          validatorsByPath.addAll(discoveredValidators);
        }
      } on Object catch (e) {
        logStore?.record('mpv-sidecar', '拉取远程同级目录清单失败：$e', isError: true);
      }

      if (_disposed || generation != _loadGeneration) return;

      // 优先拉取远程 Fonts.zip 或 Fonts/ 目录入单级哈希池，并实时更新 sub-fonts-dir。
      await _ingestRemoteFontPackIfPresent(
        gateway: sidecarGw,
        byteGateway: byteGw,
        remoteFontsZipRelPath: remoteFontsZipRelPath,
        remoteFontsDirRelPath: remoteFontsDirRelPath,
        generation: generation,
      );
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
        validatorsByPath: validatorsByPath,
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
            sourceKind: source.kind,
          );
          stagedAudioTokens.add(reg.token);
          audioUrls.add(reg.url.toString());
        } on Object catch (e) {
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

  Future<void> _ingestRemoteFontPackIfPresent({
    required dynamic gateway,
    required ByteRangeReadableGateway byteGateway,
    required String? remoteFontsZipRelPath,
    required String? remoteFontsDirRelPath,
    required int generation,
  }) async {
    if (remoteFontsZipRelPath != null) {
      try {
        final zipBytes = await _downloadCappedBytes(
          byteGateway,
          remoteFontsZipRelPath,
          maxBytes: SubtitleFontPoolManager.maxTotalExtractBytes,
          generation: generation,
        );
        if (zipBytes != null &&
            zipBytes.length > 22 &&
            !_disposed &&
            generation == _loadGeneration) {
          final resolved = await _fontPoolManager.ingestFontZipBytes(zipBytes);
          applySubFontsDir(resolved.directoryPath);
          return;
        }
      } on Object catch (e) {
        logStore?.record('mpv-fonts', '拉取远程字体压缩包失败：$e');
      }
    }

    if (remoteFontsDirRelPath != null) {
      try {
        final entries = await gateway.listDirectory(remoteFontsDirRelPath);
        if (_disposed || generation != _loadGeneration) return;
        final fontBytesByName = <String, Uint8List>{};
        var totalBytes = 0;
        for (final entry in entries) {
          if (_disposed || generation != _loadGeneration) return;
          if (entry.isDirectory) continue;
          if (!AssUueFontDecoder.isSupportedFontFileName(entry.name)) continue;
          if (fontBytesByName.length >= 16) break;
          final remaining =
              SubtitleFontPoolManager.maxTotalExtractBytes - totalBytes;
          if (remaining <= 0) break;
          final singleCap = remaining < SubtitleFontPoolManager.maxSingleFontBytes
              ? remaining
              : SubtitleFontPoolManager.maxSingleFontBytes;
          final bytes = await _downloadCappedBytes(
            byteGateway,
            entry.relativePath,
            maxBytes: singleCap,
            generation: generation,
          );
          if (bytes != null && bytes.isNotEmpty) {
            totalBytes += bytes.length;
            fontBytesByName[entry.name] = bytes;
          }
        }
        if (fontBytesByName.isNotEmpty &&
            !_disposed &&
            generation == _loadGeneration) {
          final resolved = await _fontPoolManager.ingestRemoteFontFiles(
            fontBytesByName,
          );
          applySubFontsDir(resolved.directoryPath);
        }
      } on Object catch (e) {
        logStore?.record('mpv-fonts', '拉取远程 Fonts/ 字体目录失败：$e');
      }
    }
  }

  Future<Uint8List?> _downloadCappedBytes(
    ByteRangeReadableGateway gateway,
    String relativePath, {
    required int maxBytes,
    required int generation,
  }) async {
    final len = await gateway.probeFileLength(relativePath);
    if (len != null && len > maxBytes) return null;
    final builder = BytesBuilder(copy: false);
    final stream = await gateway.openByteRange(relativePath, start: 0);
    await for (final chunk in stream) {
      if (_disposed || generation != _loadGeneration) return null;
      builder.add(chunk);
      if (builder.length > maxBytes) return null;
    }
    return builder.takeBytes();
  }

  Future<void> _unregisterTokens(List<String> tokens) async {
    for (final token in tokens) {
      try {
        await streamBridge.unregisterSession(token);
      } on Object catch (e) {
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

    // 拆分外挂文本字幕与图形字幕（.sup/.idx/.sub）：文本字幕一律经单一内存引擎归一挂载，图形字幕静态 `cached` 入轨。
    final idxStems = _pendingExternalSubtitles
        .where((s) => SubtitleAndAudioChoices.extensionOf(s) == '.idx')
        .map((s) => s.replaceAll('\\', '/').toLowerCase())
        .toSet();
    final pendingTextSubs = <String>[];
    for (final sub in _pendingExternalSubtitles) {
      final base = p.basename(sub.split('?').first).toLowerCase();
      if (mountedNames.contains(base)) continue;
      if (SubtitleAndAudioChoices.extensionOf(sub) == '.sub') {
        final stem = '${sub.substring(0, sub.length - 4)}.idx'
            .replaceAll('\\', '/')
            .toLowerCase();
        if (idxStems.contains(stem)) continue;
      }
      if (_isTextSubtitlePath(sub) && onMountExternalTextSubtitles != null) {
        pendingTextSubs.add(sub);
      } else {
        client.command(['sub-add', sub, 'cached']);
        mountedNames.add(base);
      }
    }

    for (final aud in _pendingExternalAudioPaths) {
      final base = p.basename(aud.split('?').first).toLowerCase();
      if (mountedNames.contains(base)) continue;
      client.command(['audio-add', aud, 'auto']);
      mountedNames.add(base);
    }

    // 基于 CrossEpisodeTrackMemory 或默认日语偏好锁定音轨。
    final refreshedTracks = client.readTrackList();
    final chosenAudio = _trackMemory.resolveAudioTrack(
      refreshedTracks,
      fallback: _trackPreferences,
    );
    if (chosenAudio != null && !chosenAudio.selected) {
      client.setPropertyInt64('aid', chosenAudio.id);
    }

    // 若上层已挂载单一串行内存字幕引擎，全部文本外挂字幕与字幕选轨统一交由其原子提交；
    // 否则按偏好安全选轨（用于无控制器的底层会话测试）。
    if (onMountExternalTextSubtitles != null && pendingTextSubs.isNotEmpty) {
      unawaited(
        onMountExternalTextSubtitles!(
          pendingTextSubs,
          _trackMemory,
          _trackPreferences,
        ),
      );
    } else if (_trackMemory.subtitleDisabled) {
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

  /// 切换或挂载非文本图形字幕轨道（`.sup` / `.idx` / 内封轨兜底；文本字幕统一由 `SubtitleMemoryEngine` 接管）。
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

  /// 挂载并选中非文本图形外挂字幕路径（`.sup` / `.idx`）。
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
