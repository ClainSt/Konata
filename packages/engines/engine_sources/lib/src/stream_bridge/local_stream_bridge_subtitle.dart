part of 'local_stream_bridge.dart';

extension _LocalStreamBridgeSubtitleImpl on LocalStreamBridge {
  static String _subtitlePathBucket(
    String sourceId,
    String canonicalRelPath,
  ) {
    return sha1
        .convert(utf8.encode('$sourceId\x00$canonicalRelPath'))
        .toString()
        .substring(0, 16);
  }

  static String _subtitleVersionBucket(String validator) {
    if (validator.isEmpty) return 'v_default';
    final digest = sha1.convert(utf8.encode(validator)).toString();
    return 'v_${digest.substring(0, 12)}';
  }

  Future<Directory> _ensureWorkSubtitleStageDir(String workId) async {
    final dirHash = sha1
        .convert(utf8.encode(workId))
        .toString()
        .substring(0, 12);
    final tempRoot = await _storageRoot.ensureTempDirPath();
    final targetDir = Directory(
      p.join(tempRoot, StoragePathNames.subtitleStageSubdir, dirHash),
    );
    if (!targetDir.existsSync()) {
      await targetDir.create(recursive: true);
    }
    return targetDir;
  }

  Future<bool> _isValidCachedSubtitleFile(File file) async {
    if (!file.existsSync()) return false;
    final len = await file.length();
    return len > 0 && len <= StreamBridgeConfig.maxSubtitleMaterializeBytes;
  }

  Future<String> _computeFileSha1(File file) async {
    final digestSink = _SingleDigestSink();
    final input = sha1.startChunkedConversion(digestSink);
    await for (final chunk in file.openRead()) {
      input.add(chunk);
    }
    input.close();
    return digestSink.digest?.toString() ?? '';
  }

  Future<List<String>> _resolveExistingCachedSubtitlesImpl({
    required String workId,
    required List<String> subtitleRelativePaths,
    String? sourceId,
    Map<String, String>? validatorsByPath,
  }) async {
    if (subtitleRelativePaths.isEmpty) return const <String>[];
    final targetDir = await _ensureWorkSubtitleStageDir(workId);
    final resolvedSourceId = (sourceId == null || sourceId.isEmpty)
        ? workId
        : sourceId;
    final hits = <String>[];
    for (final relPath in subtitleRelativePaths) {
      final canonical = LocalStreamBridge.canonicalizeSubtitleRelativePath(
        relPath,
      );
      final baseName = p.posix.basename(canonical);
      if (!SubtitleMatcher.isSubtitleFile(baseName)) continue;

      final pathBucketDir = Directory(
        p.join(targetDir.path, _subtitlePathBucket(resolvedSourceId, canonical)),
      );
      if (!pathBucketDir.existsSync()) continue;

      final explicitValidator = validatorsByPath?[relPath]?.trim();
      if (explicitValidator != null && explicitValidator.isNotEmpty) {
        final destFile = File(
          p.join(
            pathBucketDir.path,
            _subtitleVersionBucket(explicitValidator),
            baseName,
          ),
        );
        if (await _isValidCachedSubtitleFile(destFile)) {
          hits.add(destFile.path);
        }
        continue;
      }

      // 未显式提供源版本验证器时，仅在当前隔离桶内检索最新有效文件。
      final defaultFile = File(
        p.join(pathBucketDir.path, 'v_default', baseName),
      );
      if (await _isValidCachedSubtitleFile(defaultFile)) {
        hits.add(defaultFile.path);
        continue;
      }

      File? newestCandidate;
      DateTime? newestMtime;
      await for (final entity in pathBucketDir.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final candidate = File(p.join(entity.path, baseName));
        if (!await _isValidCachedSubtitleFile(candidate)) continue;
        final stat = candidate.statSync();
        if (newestMtime == null || stat.modified.isAfter(newestMtime)) {
          newestMtime = stat.modified;
          newestCandidate = candidate;
        }
      }
      if (newestCandidate != null) {
        hits.add(newestCandidate.path);
      }
    }
    return hits;
  }

  Future<List<MaterializedSubtitleRecord>>
  _materializeRemoteSubtitleRecordsImpl({
    required ByteRangeReadableGateway gateway,
    required String workId,
    required List<String> subtitleRelativePaths,
    String? sourceId,
    Map<String, String>? validatorsByPath,
  }) async {
    if (subtitleRelativePaths.isEmpty) {
      return const <MaterializedSubtitleRecord>[];
    }
    final targetDir = await _ensureWorkSubtitleStageDir(workId);
    final resolvedSourceId = (sourceId == null || sourceId.isEmpty)
        ? workId
        : sourceId;

    final results = await Future.wait(
      subtitleRelativePaths.asMap().entries.map((entry) async {
        final relPath = entry.value;
        final canonical = LocalStreamBridge.canonicalizeSubtitleRelativePath(
          relPath,
        );
        final baseName = p.posix.basename(canonical);
        if (!SubtitleMatcher.isSubtitleFile(baseName)) {
          return null;
        }

        int? probedLen;
        String? probedValidator;
        final explicitValidator = validatorsByPath?[relPath]?.trim() ?? '';
        try {
          if (gateway is FileValidatorProbeGateway) {
            final meta = await gateway.probeFileMetadata(relPath);
            probedLen = meta.length;
            probedValidator = meta.validator?.trim();
          } else {
            probedLen = await gateway.probeFileLength(relPath);
          }
          if (probedLen != null &&
              probedLen > StreamBridgeConfig.maxSubtitleMaterializeBytes) {
            return null;
          }
        } on Object catch (error) {
          developer.log(
            '探测字幕元信息失败，继续直接拉取',
            name: 'konata.local_stream_bridge',
            error: error,
          );
        }

        final effectiveValidator = explicitValidator.isNotEmpty
            ? explicitValidator
            : ((probedValidator != null && probedValidator.isNotEmpty)
                  ? probedValidator
                  : (probedLen != null && probedLen > 0
                        ? 'len:$probedLen'
                        : ''));
        final cacheKey = LocalStreamBridge.buildSubtitleCacheKey(
          sourceId: resolvedSourceId,
          relativePath: canonical,
          validator: effectiveValidator,
        );
        final pathBucket = _subtitlePathBucket(resolvedSourceId, canonical);
        final versionBucket = _subtitleVersionBucket(effectiveValidator);
        final versionDir = Directory(
          p.join(targetDir.path, pathBucket, versionBucket),
        );
        final destFile = File(p.join(versionDir.path, baseName));

        // 命中同键且字节完整的已落盘缓存直接计算校验和返回，零重复下载。
        if (destFile.existsSync()) {
          final existingLen = await destFile.length();
          final lenMatches =
              probedLen == null || probedLen <= 0 || existingLen == probedLen;
          if (existingLen > 0 &&
              existingLen <= StreamBridgeConfig.maxSubtitleMaterializeBytes &&
              lenMatches) {
            final digest = await _computeFileSha1(destFile);
            return MaterializedSubtitleRecord(
              relativePath: relPath,
              localFilePath: destFile.path,
              sourceSha1: digest,
              byteLength: existingLen,
              cacheKey: cacheKey,
              validator: effectiveValidator,
            );
          }
        }

        await versionDir.create(recursive: true);
        final uniqueSuffix =
            '${DateTime.now().microsecondsSinceEpoch}_${entry.key}';
        final partFile = File('${destFile.path}.part.$uniqueSuffix');
        final digestSink = _SingleDigestSink();
        final sha1Input = sha1.startChunkedConversion(digestSink);
        final sink = partFile.openWrite();
        var writtenBytes = 0;
        var failed = false;
        String? streamValidator;
        try {
          Stream<List<int>> stream;
          if (gateway is ValidatedByteRangeGateway &&
              explicitValidator.isEmpty &&
              (probedValidator == null || probedValidator.isEmpty)) {
            final validated = await gateway.openValidatedByteRange(
              relPath,
              start: 0,
            );
            streamValidator = validated.strongValidator?.trim();
            stream = validated.stream;
          } else {
            stream = await gateway.openByteRange(relPath, start: 0);
          }
          await for (final chunk in stream) {
            if (chunk.isEmpty) continue;
            writtenBytes += chunk.length;
            if (writtenBytes > StreamBridgeConfig.maxSubtitleMaterializeBytes) {
              failed = true;
              break;
            }
            sink.add(chunk);
            sha1Input.add(chunk);
          }
          if (!failed) {
            await sink.flush();
          }
        } on Object {
          failed = true;
        } finally {
          await sink.close();
          sha1Input.close();
        }

        final lengthValid =
            writtenBytes > 0 &&
            writtenBytes <= StreamBridgeConfig.maxSubtitleMaterializeBytes &&
            (probedLen == null || probedLen <= 0 || writtenBytes == probedLen);
        final srcDigest = digestSink.digest;
        if (failed || !lengthValid || srcDigest == null) {
          if (partFile.existsSync()) {
            await partFile.delete().catchError((_) => partFile);
          }
          return null;
        }

        var finalValidator = effectiveValidator;
        var finalCacheKey = cacheKey;
        var finalDestFile = destFile;
        if (explicitValidator.isEmpty &&
            (probedValidator == null || probedValidator.isEmpty) &&
            streamValidator != null &&
            streamValidator.isNotEmpty &&
            streamValidator != effectiveValidator) {
          finalValidator = streamValidator;
          finalCacheKey = LocalStreamBridge.buildSubtitleCacheKey(
            sourceId: resolvedSourceId,
            relativePath: canonical,
            validator: finalValidator,
          );
          final upgradedDir = Directory(
            p.join(
              targetDir.path,
              pathBucket,
              _subtitleVersionBucket(finalValidator),
            ),
          );
          await upgradedDir.create(recursive: true);
          finalDestFile = File(p.join(upgradedDir.path, baseName));
        }

        try {
          await AtomicFileWriter.replaceFile(
            partFile,
            finalDestFile,
            expectedLength: writtenBytes,
          );
        } on Object {
          if (partFile.existsSync()) {
            await partFile.delete().catchError((_) => partFile);
          }
          return null;
        }

        return MaterializedSubtitleRecord(
          relativePath: relPath,
          localFilePath: finalDestFile.path,
          sourceSha1: srcDigest.toString(),
          byteLength: writtenBytes,
          cacheKey: finalCacheKey,
          validator: finalValidator,
        );
      }),
    );

    return results
        .whereType<MaterializedSubtitleRecord>()
        .toList(growable: false);
  }
}
