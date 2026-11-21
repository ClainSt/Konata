part of 'local_stream_bridge.dart';

/// 虚拟专辑远程音频文件输入描述（供同源 `.cue` 目录与 `.m3u8` 播放列表共用）。
class VirtualAlbumAudioEntry {
  /// 创建虚拟专辑远程音频条目。
  const VirtualAlbumAudioEntry({
    required this.entryFileName,
    required this.relativePath,
    this.knownLength,
    this.title = '',
    this.performer = '',
    this.durationSeconds = -1,
  });

  /// 挂载在虚拟目录下的文件名（与 `.cue` `FILE` 声明或 `.m3u8` 相对项严格一致）。
  final String entryFileName;

  /// 在上游远程源中的真实相对路径。
  final String relativePath;

  /// 已知文件字节长度（可选，省去额外 `HEAD` 探测）。
  final int? knownLength;

  /// 曲目展示标题（供生成 `#EXTINF` 使用）。
  final String title;

  /// 曲目演唱者（供生成 `#EXTINF` 使用）。
  final String performer;

  /// 曲目整秒时长（供生成 `#EXTINF` 使用）。
  final int durationSeconds;
}

/// 虚拟专辑目录注册结果（含主清单 URL 与首条音频流兜底 URL）。
class VirtualAlbumRegistration {
  /// 创建虚拟专辑注册结果。
  const VirtualAlbumRegistration({
    required this.albumToken,
    required this.manifestUrl,
    required this.primaryAudioUrl,
    required this.audioUrls,
  });

  /// 虚拟专辑会话令牌（用于追踪结束注销或暂停心跳续期）。
  final String albumToken;

  /// 主清单地址（`index.cue` 或 `album.m3u8`）。
  final Uri manifestUrl;

  /// 首条物理音频流直达地址（供旧版外部播放器拒绝网络清单时无缝回退）。
  final Uri primaryAudioUrl;

  /// 虚拟目录下按序排列的全部音频流地址列表。
  final List<Uri> audioUrls;
}

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

/// `LocalStreamBridge` 同源虚拟专辑目录（`.cue` / `.m3u8`）与本地归一化影子 `.cue` 扩展。
extension LocalStreamBridgeAlbumExtension on LocalStreamBridge {
  /// 注册远程 WebDAV / SMB 整轨 + `.cue` 同源虚拟目录会话：
  /// - `/album/<albumToken>/index.cue` 直接内存返回带 UTF-8 BOM 的归一化 `.cue`；
  /// - `/album/<albumToken>/<audioFile>` 同目录映射至上游 `206 Partial Content` 字节流。
  Future<VirtualAlbumRegistration> registerCueAlbumSession({
    required ByteRangeReadableGateway gateway,
    required String normalizedCueText,
    required List<VirtualAlbumAudioEntry> audioEntries,
    bool ownsGateway = true,
    MediaSourceKind sourceKind = MediaSourceKind.webdav,
  }) {
    final cueBytes = CueSheetSerializer.encodeCueWithUtf8Bom(normalizedCueText);
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

  /// 注册远程 WebDAV / SMB 散装多曲目 `.m3u8` 虚拟播放列表会话（内置 `#EXTINF` 防并发探测风控）。
  Future<VirtualAlbumRegistration> registerPlaylistM3u8Session({
    required ByteRangeReadableGateway gateway,
    required List<VirtualAlbumAudioEntry> audioEntries,
    bool ownsGateway = true,
    MediaSourceKind sourceKind = MediaSourceKind.webdav,
  }) async {
    final server = await ensureStarted();
    _tokenCounter += 1;
    final rawSeed =
        '${DateTime.now().microsecondsSinceEpoch}_${_tokenCounter}_m3u8';
    final albumToken = sha1
        .convert(utf8.encode(rawSeed))
        .toString()
        .substring(0, 16);

    final m3uItems = <ExtendedM3uTrackEntry>[];
    final audioByLower = <String, _RegisteredStreamSession>{};
    final audioUrls = <Uri>[];

    for (var i = 0; i < audioEntries.length; i++) {
      final entry = audioEntries[i];
      final uniqueEntryName =
          '${(i + 1).toString().padLeft(2, '0')}_${entry.entryFileName}';
      final subSession = _createSubStreamSession(
        albumToken: albumToken,
        index: i,
        gateway: gateway,
        entry: entry,
        exposedFileName: uniqueEntryName,
        sourceKind: sourceKind,
      );
      audioByLower[uniqueEntryName.toLowerCase()] = subSession;
      final itemUrl = Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: server.port,
        pathSegments: ['album', albumToken, uniqueEntryName],
      );
      audioUrls.add(itemUrl);
      m3uItems.add(
        ExtendedM3uTrackEntry(
          targetUriOrPath: itemUrl.toString(),
          title: entry.title.isNotEmpty ? entry.title : entry.entryFileName,
          performer: entry.performer,
          durationSeconds: entry.durationSeconds,
        ),
      );
    }

    final m3uText = CueSheetSerializer.buildExtendedM3u8Text(m3uItems);
    final manifestBytes = Uint8List.fromList(utf8.encode(m3uText));
    final manifestEtag =
        '"${sha1.convert(manifestBytes).toString().substring(0, 12)}"';

    _albumSessions[albumToken] = _VirtualAlbumDirectorySession(
      albumToken: albumToken,
      gateway: gateway,
      ownsGateway: ownsGateway,
      manifestName: 'album.m3u8',
      manifestBytes: manifestBytes,
      manifestMimeType: 'audio/x-mpegurl; charset=utf-8',
      manifestEtag: manifestEtag,
      audioSessionsByLowerName: audioByLower,
    );

    final manifestUrl = Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: server.port,
      pathSegments: ['album', albumToken, 'album.m3u8'],
    );
    return VirtualAlbumRegistration(
      albumToken: albumToken,
      manifestUrl: manifestUrl,
      primaryAudioUrl: audioUrls.first,
      audioUrls: audioUrls,
    );
  }

  /// 在应用便携缓存目录 `<Root>/cache/tmp/konata_cues/` 原子写入带 UTF-8 BOM 的本地影子 `.cue` 文件。
  Future<String> writeLocalShadowCue({
    required String seedKey,
    required String normalizedCueText,
  }) async {
    final stageDir = await _storageRoot.ensureCueStageDir();
    final hash = sha1.convert(utf8.encode(seedKey)).toString().substring(0, 16);
    final partFile = File(p.join(stageDir.path, '$hash.cue.part'));
    final destFile = File(p.join(stageDir.path, '$hash.cue'));
    final bytes = CueSheetSerializer.encodeCueWithUtf8Bom(normalizedCueText);
    await partFile.writeAsBytes(bytes, flush: true);
    await AtomicFileWriter.replaceFile(
      partFile,
      destFile,
      expectedLength: bytes.length,
    );
    return destFile.path;
  }

  /// 刷新指定虚拟专辑会话及子流心跳时间（供外部播放器暂停期间保活，避免 20 分钟空闲回收断流）。
  void touchAlbumSession(String albumToken) {
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

  /// 注销整个虚拟专辑会话并统一释放其持有的共享远程网关。
  Future<void> unregisterAlbumSession(String albumToken) async {
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
          '可恢复异常已记录',
          name: 'konata.local_stream_bridge',
          error: error,
        );
      }
    }
  }

  Future<VirtualAlbumRegistration> _registerVirtualAlbumInternal({
    required ByteRangeReadableGateway gateway,
    required String manifestName,
    required Uint8List manifestBytes,
    required String manifestMimeType,
    required List<VirtualAlbumAudioEntry> audioEntries,
    required bool ownsGateway,
    required MediaSourceKind sourceKind,
  }) async {
    if (audioEntries.isEmpty) {
      throw ArgumentError('虚拟专辑至少需要包含一个音频文件条目');
    }
    final server = await ensureStarted();
    _tokenCounter += 1;
    final rawSeed =
        '${DateTime.now().microsecondsSinceEpoch}_${_tokenCounter}_$manifestName';
    final albumToken = sha1
        .convert(utf8.encode(rawSeed))
        .toString()
        .substring(0, 16);

    final audioByLower = <String, _RegisteredStreamSession>{};
    final audioUrls = <Uri>[];
    for (var i = 0; i < audioEntries.length; i++) {
      final entry = audioEntries[i];
      final key = entry.entryFileName.toLowerCase();
      if (!audioByLower.containsKey(key)) {
        audioByLower[key] = _createSubStreamSession(
          albumToken: albumToken,
          index: i,
          gateway: gateway,
          entry: entry,
          exposedFileName: entry.entryFileName,
          sourceKind: sourceKind,
        );
      }
      audioUrls.add(
        Uri(
          scheme: 'http',
          host: '127.0.0.1',
          port: server.port,
          pathSegments: ['album', albumToken, entry.entryFileName],
        ),
      );
    }

    final manifestEtag =
        '"${sha1.convert(manifestBytes).toString().substring(0, 12)}"';
    _albumSessions[albumToken] = _VirtualAlbumDirectorySession(
      albumToken: albumToken,
      gateway: gateway,
      ownsGateway: ownsGateway,
      manifestName: manifestName,
      manifestBytes: manifestBytes,
      manifestMimeType: manifestMimeType,
      manifestEtag: manifestEtag,
      audioSessionsByLowerName: audioByLower,
    );

    final manifestUrl = Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: server.port,
      pathSegments: ['album', albumToken, manifestName],
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
