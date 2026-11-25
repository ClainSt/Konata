part of 'local_stream_bridge.dart';

class _VirtualAlbumDirectorySession {
  _VirtualAlbumDirectorySession({
    required this.albumToken,
    required this.gateway,
    required this.ownsGateway,
    required this.manifestName,
    required this.manifestBytes,
    required this.manifestMimeType,
    required this.manifestEtag,
    required this.audioSessionsByLowerName,
    DateTime? createdAt,
  }) : lastAccessedAt = createdAt ?? DateTime.now();

  final String albumToken;
  final ByteRangeReadableGateway gateway;
  final bool ownsGateway;
  final String manifestName;
  final Uint8List manifestBytes;
  final String manifestMimeType;
  final String manifestEtag;
  final Map<String, _RegisteredStreamSession> audioSessionsByLowerName;
  DateTime lastAccessedAt;

  bool get hasActiveStreams =>
      audioSessionsByLowerName.values.any((s) => s.activeStreams > 0);
}

Uint8List _encodeWithUtf8Bom(String text) {
  return Uint8List.fromList(<int>[0xEF, 0xBB, 0xBF, ...utf8.encode(text)]);
}

String _sanitizePlaylistLine(String raw) {
  return raw.replaceAll('\r', ' ').replaceAll('\n', ' ').trim();
}

String _buildExtendedM3u8Text(
  List<VirtualAlbumAudioEntry> audioEntries,
  List<Uri> audioUrls,
) {
  final buf = StringBuffer('#EXTM3U\r\n');
  for (var i = 0; i < audioEntries.length; i++) {
    final entry = audioEntries[i];
    final target = audioUrls[i].toString().trim();
    if (target.isEmpty) continue;
    final dur = entry.durationSeconds > 0 ? entry.durationSeconds : -1;
    final cleanTitle = _sanitizePlaylistLine(
      entry.title.isNotEmpty ? entry.title : entry.entryFileName,
    );
    final cleanPerformer = _sanitizePlaylistLine(entry.performer);
    final display = cleanPerformer.isNotEmpty
        ? '$cleanPerformer - $cleanTitle'
        : cleanTitle;
    buf.writeln('#EXTINF:$dur,$display\r');
    buf.writeln('$target\r');
  }
  return buf.toString();
}

extension _LocalStreamBridgeAlbumImpl on LocalStreamBridge {
  Future<VirtualAlbumRegistration> _registerCueAlbumSessionImpl({
    required ByteRangeReadableGateway gateway,
    required String normalizedCueText,
    required List<VirtualAlbumAudioEntry> audioEntries,
    bool ownsGateway = true,
    MediaSourceKind sourceKind = MediaSourceKind.webdav,
  }) {
    final cueBytes = _encodeWithUtf8Bom(normalizedCueText);
    return _registerVirtualAlbumInternal(
      gateway: gateway,
      manifestName: 'index.cue',
      manifestBytes: cueBytes,
      manifestMimeType: 'application/x-cue; charset=utf-8',
      audioEntries: audioEntries,
      ownsGateway: ownsGateway,
      sourceKind: sourceKind,
    );
  }

  Future<VirtualAlbumRegistration> _registerPlaylistM3u8SessionImpl({
    required ByteRangeReadableGateway gateway,
    required List<VirtualAlbumAudioEntry> audioEntries,
    bool ownsGateway = true,
    MediaSourceKind sourceKind = MediaSourceKind.webdav,
  }) => _registerVirtualAlbumInternal(
    gateway: gateway,
    manifestName: 'album.m3u8',
    manifestMimeType: 'audio/x-mpegurl; charset=utf-8',
    audioEntries: audioEntries,
    ownsGateway: ownsGateway,
    sourceKind: sourceKind,
    prefixTrackIndex: true,
    buildManifestBytes: (audioUrls) => Uint8List.fromList(
      utf8.encode(_buildExtendedM3u8Text(audioEntries, audioUrls)),
    ),
  );

  Future<String> _writeLocalShadowCueImpl({
    required String seedKey,
    required String normalizedCueText,
  }) async {
    final tempRoot = await _storageRoot.ensureTempDirPath();
    final stageDir = Directory(p.join(tempRoot, 'konata_cues'));
    if (!stageDir.existsSync()) {
      await stageDir.create(recursive: true);
    }
    final hash = sha1.convert(utf8.encode(seedKey)).toString().substring(0, 16);
    final partFile = File(p.join(stageDir.path, '$hash.cue.part'));
    final destFile = File(p.join(stageDir.path, '$hash.cue'));
    final bytes = _encodeWithUtf8Bom(normalizedCueText);
    await partFile.writeAsBytes(bytes, flush: true);
    await AtomicFileWriter.replaceFile(
      partFile,
      destFile,
      expectedLength: bytes.length,
    );
    return destFile.path;
  }

  void _touchAlbumSessionImpl(String albumToken) {
    final now = DateTime.now();
    final album = _albumSessions[albumToken];
    if (album != null) {
      album.lastAccessedAt = now;
      for (final sub in album.audioSessionsByLowerName.values) {
        sub.lastAccessedAt = now;
      }
    }
    final single = _sessions[albumToken];
    if (single != null) {
      single.lastAccessedAt = now;
    }
  }

  Future<void> _unregisterAlbumSessionImpl(String albumToken) async {
    final album = _albumSessions.remove(albumToken);
    if (album == null) {
      await unregisterSession(albumToken);
      return;
    }
    for (final sub in album.audioSessionsByLowerName.values) {
      sub.windowReader?.clear();
    }
    if (album.ownsGateway) {
      try {
        await album.gateway.close();
      } catch (error) {
        developer.log(
          '释放虚拟专辑网关异常已忽略',
          name: 'konata.local_stream_bridge',
          error: error,
        );
      }
    }
  }

  Future<VirtualAlbumRegistration> _registerVirtualAlbumInternal({
    required ByteRangeReadableGateway gateway,
    required String manifestName,
    Uint8List? manifestBytes,
    Uint8List Function(List<Uri> audioUrls)? buildManifestBytes,
    required String manifestMimeType,
    required List<VirtualAlbumAudioEntry> audioEntries,
    required bool ownsGateway,
    required MediaSourceKind sourceKind,
    bool prefixTrackIndex = false,
  }) async {
    if (audioEntries.isEmpty) {
      throw ArgumentError('虚拟专辑至少需要包含一个音频文件条目');
    }
    final server = await ensureStarted();
    final albumToken = _newSessionToken();

    final audioByLower = <String, _RegisteredStreamSession>{};
    final audioUrls = <Uri>[];
    for (var i = 0; i < audioEntries.length; i++) {
      final entry = audioEntries[i];
      final exposedName = prefixTrackIndex
          ? '${(i + 1).toString().padLeft(2, '0')}_${entry.entryFileName}'
          : entry.entryFileName;
      final key = exposedName.toLowerCase();
      audioByLower.putIfAbsent(
        key,
        () => _createSubStreamSession(
          albumToken: albumToken,
          index: i,
          gateway: gateway,
          entry: entry,
          exposedFileName: exposedName,
          sourceKind: sourceKind,
        ),
      );
      audioUrls.add(
        Uri(
          scheme: 'http',
          host: '127.0.0.1',
          port: server.port,
          pathSegments: <String>['album', albumToken, exposedName],
        ),
      );
    }

    final resolvedBytes = manifestBytes ?? buildManifestBytes!(audioUrls);
    final manifestEtag =
        '"${sha1.convert(resolvedBytes).toString().substring(0, 12)}"';
    _albumSessions[albumToken] = _VirtualAlbumDirectorySession(
      albumToken: albumToken,
      gateway: gateway,
      ownsGateway: ownsGateway,
      manifestName: manifestName,
      manifestBytes: resolvedBytes,
      manifestMimeType: manifestMimeType,
      manifestEtag: manifestEtag,
      audioSessionsByLowerName: audioByLower,
    );

    final manifestUrl = Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: server.port,
      pathSegments: <String>['album', albumToken, manifestName],
    );
    return VirtualAlbumRegistration(
      albumToken: albumToken,
      manifestUrl: manifestUrl,
      primaryAudioUrl: audioUrls.first,
      audioUrls: audioUrls,
    );
  }

  _RegisteredStreamSession _createSubStreamSession({
    required String albumToken,
    required int index,
    required ByteRangeReadableGateway gateway,
    required VirtualAlbumAudioEntry entry,
    required String exposedFileName,
    required MediaSourceKind sourceKind,
  }) {
    final sanitizedLength =
        (entry.knownLength != null && entry.knownLength! > 0)
        ? entry.knownLength
        : null;
    final subToken = '${albumToken}_$index';
    final etagDigest = sha1
        .convert(
          utf8.encode(
            '${entry.relativePath}#${sanitizedLength ?? 0}#$subToken',
          ),
        )
        .toString()
        .substring(0, 12);
    final normRel = entry.relativePath.replaceAll('\\', '/');
    _recentErrorsByPath.remove(normRel);
    _recentKindsByPath.remove(normRel);
    return _RegisteredStreamSession(
      token: subToken,
      gateway: gateway,
      relativePath: entry.relativePath,
      fileName: exposedFileName,
      ownsGateway: false,
      etag: '"$etagDigest"',
      sourceKind: sourceKind,
      cachedLength: sanitizedLength,
    );
  }

  List<String> _collectExpiredAlbumTokens({
    required Duration threshold,
    required DateTime current,
  }) {
    final expired = <String>[];
    for (final entry in _albumSessions.entries) {
      final album = entry.value;
      if (album.hasActiveStreams) continue;
      if (current.difference(album.lastAccessedAt) >= threshold) {
        expired.add(entry.key);
      }
    }
    return expired;
  }

  Future<void> _handleVirtualAlbumRequest(
    HttpRequest request,
    List<String> segments,
  ) async {
    final response = request.response;
    final albumToken = segments[1];
    final album = _albumSessions[albumToken];
    if (album == null) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }

    album.lastAccessedAt = DateTime.now();
    final requestedEntry = segments.sublist(2).join('/');
    if (requestedEntry.toLowerCase() == album.manifestName.toLowerCase()) {
      await _serveInMemoryManifest(request, response, album);
      return;
    }

    final audioSession =
        album.audioSessionsByLowerName[requestedEntry.toLowerCase()];
    if (audioSession == null) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    await _serveStreamSession(request, response, audioSession);
  }

  Future<void> _serveInMemoryManifest(
    HttpRequest request,
    HttpResponse response,
    _VirtualAlbumDirectorySession album,
  ) async {
    if (request.method != 'GET' && request.method != 'HEAD') {
      response.statusCode = HttpStatus.methodNotAllowed;
      await response.close();
      return;
    }

    final bytes = album.manifestBytes;
    final totalLength = bytes.length;
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    response.headers.set(HttpHeaders.etagHeader, album.manifestEtag);
    response.headers.set(HttpHeaders.contentTypeHeader, album.manifestMimeType);
    response.headers.set('Cache-Control', 'no-store');

    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    final ifRangeHeader = request.headers.value(HttpHeaders.ifRangeHeader);
    final allowPartial = LocalStreamBridge._matchesIfRange(
      ifRangeHeader,
      album.manifestEtag,
    );

    if (allowPartial && rangeHeader != null && rangeHeader.trim().isNotEmpty) {
      final parsed = HttpByteRange.parse(rangeHeader, totalLength);
      final range = parsed.range;
      if (!parsed.valid || range == null) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */$totalLength',
        );
        await response.close();
        return;
      }
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        range.toContentRangeHeader(),
      );
      response.headers.contentLength = range.length;
      if (request.method != 'HEAD') {
        response.add(
          Uint8List.sublistView(bytes, range.start, range.endInclusive + 1),
        );
      }
      await response.close();
      return;
    }

    response.statusCode = HttpStatus.ok;
    response.headers.contentLength = totalLength;
    if (request.method != 'HEAD') {
      response.add(bytes);
    }
    await response.close();
  }
}
