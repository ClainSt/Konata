part of 'foobar_beefweb_tracker.dart';

class _BeefwebPlayerSnapshot {
  const _BeefwebPlayerSnapshot({
    required this.playbackState,
    required this.playlistId,
    required this.playlistIndex,
    required this.itemIndex,
    required this.subsong,
    required this.positionSeconds,
    required this.durationSeconds,
    required this.path,
    required this.trackNumberText,
    required this.title,
  });

  final String playbackState;
  final String playlistId;
  final int playlistIndex;
  final int itemIndex;
  final int subsong;
  final double positionSeconds;
  final double durationSeconds;
  final String path;
  final String trackNumberText;
  final String title;
}

class _BeefwebPlaylistItem {
  const _BeefwebPlaylistItem({
    required this.index,
    required this.path,
    required this.subsongText,
    required this.trackNumberText,
    required this.title,
  });

  final int index;
  final String path;
  final String subsongText;
  final String trackNumberText;
  final String title;
}

HttpClient _createDirectClient() {
  return HttpClient()
    ..connectionTimeout = const Duration(milliseconds: 500)
    ..findProxy = (_) => 'DIRECT';
}

Future<bool> _hasInstalledBeefwebDll({
  required String executablePath,
  String? appDataDirOverride,
}) async {
  final exeDir = p.dirname(executablePath);
  final candidates = <String>[
    p.join(
      exeDir,
      'profile',
      'user-components-x64',
      'foo_beefweb',
      'foo_beefweb.dll',
    ),
    p.join(
      exeDir,
      'profile',
      'user-components',
      'foo_beefweb',
      'foo_beefweb.dll',
    ),
    p.join(exeDir, 'user-components-x64', 'foo_beefweb', 'foo_beefweb.dll'),
    p.join(exeDir, 'user-components', 'foo_beefweb', 'foo_beefweb.dll'),
  ];

  final appData =
      appDataDirOverride ?? Platform.environment['APPDATA']?.trim() ?? '';
  if (appData.isNotEmpty) {
    candidates.addAll(<String>[
      p.join(
        appData,
        'foobar2000-v2',
        'user-components-x64',
        'foo_beefweb',
        'foo_beefweb.dll',
      ),
      p.join(
        appData,
        'foobar2000-v2',
        'user-components',
        'foo_beefweb',
        'foo_beefweb.dll',
      ),
      p.join(
        appData,
        'foobar2000',
        'user-components',
        'foo_beefweb',
        'foo_beefweb.dll',
      ),
    ]);
  }

  for (final dllPath in candidates) {
    try {
      if (await File(dllPath).exists()) {
        return true;
      }
    } catch (error) {
      developer.log(
        '只读检查组件文件状态忽略',
        name: 'konata.foobar_beefweb_tracker',
        error: error,
      );
    }
  }
  return false;
}

Future<bool> _waitUntilBeefwebReady(
  HttpClient client,
  String baseUrl, {
  required Duration timeout,
  required bool Function()? isCancelled,
  required bool Function() hasProcessExitedSlowly,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    if (isCancelled != null && isCancelled()) return false;
    final snap = await _BeefwebProtocol.queryPlayerState(client, baseUrl);
    if (snap != null) return true;
    if (hasProcessExitedSlowly() || DateTime.now().isAfter(deadline)) {
      return false;
    }
    await Future<void>.delayed(const Duration(milliseconds: 220));
  }
}

Future<bool> _finishWithoutBeefweb({
  required Future<int>? processExitFuture,
  required DateTime launchedAt,
  required bool processExited,
  required bool exitedFast,
  required bool keepRemoteSessionAlive,
}) async {
  var exitedFastFinal = exitedFast;
  if (!processExited && processExitFuture != null) {
    try {
      await processExitFuture;
      exitedFastFinal =
          DateTime.now().difference(launchedAt) < const Duration(seconds: 4);
    } catch (error) {
      developer.log(
        '等待无组件外部音频进程结束异常已记录',
        name: 'konata.foobar_beefweb_tracker',
        error: error,
      );
    }
  }
  if (exitedFastFinal && keepRemoteSessionAlive) {
    return false;
  }
  return true;
}

int _resolvePlaylistIndexForTrack({
  required List<_BeefwebPlaylistItem> loadedItems,
  required ExternalAudioTrackDescriptor targetTrack,
  required int fallbackIndex,
}) {
  if (loadedItems.isEmpty) return 0;
  final targetNum = targetTrack.trackNumber;
  if (targetNum != null) {
    for (final item in loadedItems) {
      final subNo = int.tryParse(item.subsongText.trim());
      if (subNo != null && subNo == targetNum) {
        return item.index;
      }
    }
    for (final item in loadedItems) {
      final trkNo = int.tryParse(item.trackNumberText.trim());
      if (trkNo != null && trkNo == targetNum) {
        return item.index;
      }
    }
  }
  return fallbackIndex.clamp(0, loadedItems.length - 1);
}

Future<void> _applyInitialSeekWhenReady(
  HttpClient client,
  String baseUrl, {
  required String playlistId,
  required int targetSeekSeconds,
  required bool Function()? isCancelled,
}) async {
  final deadline = DateTime.now().add(const Duration(milliseconds: 2800));
  while (DateTime.now().isBefore(deadline)) {
    if (isCancelled != null && isCancelled()) return;
    final snap = await _BeefwebProtocol.queryPlayerState(client, baseUrl);
    if (snap != null &&
        (snap.playbackState == 'playing' || snap.playbackState == 'paused') &&
        (snap.playlistId.isEmpty || snap.playlistId == playlistId) &&
        snap.durationSeconds > targetSeekSeconds) {
      await _BeefwebProtocol.postSeek(client, baseUrl, targetSeekSeconds);
      await Future<void>.delayed(const Duration(milliseconds: 180));
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 120));
  }
  // 超时兜底：即便流总时长尚未解析完毕也尝试提交一次定位请求。
  await _BeefwebProtocol.postSeek(client, baseUrl, targetSeekSeconds);
}

bool _belongsToKonataSession({
  required _BeefwebPlayerSnapshot snap,
  required String playlistId,
  required Set<String> expectedItemSet,
}) {
  if (playlistId.isNotEmpty &&
      playlistId != 'active' &&
      snap.playlistId == playlistId) {
    return true;
  }
  if (snap.path.trim().isEmpty) return false;
  final normPath = _normalizeComparable(snap.path);
  if (expectedItemSet.contains(normPath)) return true;
  final parent = _parentDir(normPath);
  if (parent.isNotEmpty) {
    for (final candidate in expectedItemSet) {
      if (_parentDir(candidate) == parent) {
        return true;
      }
    }
  }
  return false;
}

({
  ExternalAudioTrackDescriptor track,
  int relativePosition,
  int relativeDuration,
})
_mapSnapshotToTrackProgress({
  required _BeefwebPlayerSnapshot snap,
  required List<ExternalAudioTrackDescriptor> tracks,
  required ExternalAudioTrackDescriptor fallbackCurrent,
  required bool singleStreamCueFallback,
}) {
  if (singleStreamCueFallback && tracks.length >= 2) {
    final rawPos = snap.positionSeconds;
    ExternalAudioTrackDescriptor matched = tracks.first;
    for (final t in tracks) {
      final start = t.cueStartSeconds ?? 0.0;
      final end = t.cueEndSeconds;
      if (rawPos + 0.25 >= start && (end == null || rawPos < end - 0.05)) {
        matched = t;
        break;
      }
      if (rawPos >= start) {
        matched = t;
      }
    }
    final cueStart = matched.cueStartSeconds ?? 0.0;
    final cueEnd =
        matched.cueEndSeconds ??
        (snap.durationSeconds > cueStart ? snap.durationSeconds : null);
    final dur = cueEnd != null && cueEnd > cueStart
        ? (cueEnd - cueStart).round()
        : matched.resolvedDurationSeconds;
    final rawRel = (rawPos - cueStart).round();
    final clampedPos = dur > 0
        ? rawRel.clamp(0, dur)
        : (rawRel < 0 ? 0 : rawRel);
    return (
      track: matched,
      relativePosition: clampedPos,
      relativeDuration: dur,
    );
  }

  ExternalAudioTrackDescriptor? matched;
  if (snap.subsong > 0) {
    for (final t in tracks) {
      if (t.isCueSubtrack && t.trackNumber == snap.subsong) {
        matched = t;
        break;
      }
    }
  }
  if (matched == null && snap.itemIndex >= 0 && snap.itemIndex < tracks.length) {
    matched = tracks[snap.itemIndex];
  }
  if (matched == null) {
    final trkNo = int.tryParse(snap.trackNumberText.trim());
    if (trkNo != null) {
      for (final t in tracks) {
        if (t.trackNumber == trkNo) {
          matched = t;
          break;
        }
      }
    }
  }
  matched ??= fallbackCurrent;

  final dur = snap.durationSeconds > 0
      ? snap.durationSeconds.round()
      : matched.resolvedDurationSeconds;
  final rawPos = snap.positionSeconds >= 0 ? snap.positionSeconds.round() : 0;
  final clampedPos = dur > 0 ? rawPos.clamp(0, dur) : rawPos;
  return (
    track: matched,
    relativePosition: clampedPos,
    relativeDuration: dur,
  );
}

String _normalizeComparable(String input) {
  var s = input.trim();
  try {
    s = Uri.decodeFull(s);
  } catch (error) {
    developer.log(
      '解码路径比较字符串忽略',
      name: 'konata.foobar_beefweb_tracker',
      error: error,
    );
  }
  return s.replaceAll('\\', '/').toLowerCase();
}

String _parentDir(String normalized) {
  final idx = normalized.lastIndexOf('/');
  return idx > 0 ? normalized.substring(0, idx) : '';
}

MediaVariant _placeholderVariant(String pathOrUrl) {
  return MediaVariant(
    id: 'single_audio_target',
    workId: 'single_work',
    sourceId: 'local',
    relativePath: pathOrUrl,
    fileName: p.basename(pathOrUrl),
    fileSize: 0,
    assetKind: AssetKind.cdAlbum,
  );
}

abstract final class _BeefwebProtocol {
  static const String _columnsQuery =
      '%25path%25,%25subsong%25,%25tracknumber%25,%25title%25';

  static Future<_BeefwebPlayerSnapshot?> queryPlayerState(
    HttpClient client,
    String baseUrl,
  ) async {
    try {
      final uri = Uri.parse('$baseUrl/api/player?columns=$_columnsQuery');
      final req = await client
          .getUrl(uri)
          .timeout(const Duration(milliseconds: 700));
      final resp = await req.close().timeout(const Duration(milliseconds: 700));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        await resp.drain<void>();
        return null;
      }
      final raw = await resp
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(milliseconds: 700));
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final player = decoded['player'];
      if (player is! Map) return null;

      final playbackState = player['playbackState']?.toString() ?? '';
      final activeItem = player['activeItem'];
      var playlistId = '';
      var playlistIndex = -1;
      var itemIndex = -1;
      var subsong = 0;
      var posSec = 0.0;
      var durSec = 0.0;
      var pathStr = '';
      var trackNoStr = '';
      var titleStr = '';

      if (activeItem is Map) {
        playlistId = activeItem['playlistId']?.toString() ?? '';
        final rawPlIdx = activeItem['playlistIndex'];
        if (rawPlIdx is num) playlistIndex = rawPlIdx.toInt();
        final rawIdx = activeItem['index'];
        if (rawIdx is num) itemIndex = rawIdx.toInt();
        final rawSub = activeItem['subsong'];
        if (rawSub is num) subsong = rawSub.toInt();
        final rawPos = activeItem['position'];
        if (rawPos is num && rawPos.isFinite && rawPos >= 0) {
          posSec = rawPos.toDouble();
        }
        final rawDur = activeItem['duration'];
        if (rawDur is num && rawDur.isFinite && rawDur > 0) {
          durSec = rawDur.toDouble();
        }
        final cols = activeItem['columns'];
        if (cols is List) {
          if (cols.isNotEmpty && cols[0] != null) {
            pathStr = cols[0].toString();
          }
          if (cols.length > 1 && cols[1] != null && subsong <= 0) {
            subsong = int.tryParse(cols[1].toString().trim()) ?? 0;
          }
          if (cols.length > 2 && cols[2] != null) {
            trackNoStr = cols[2].toString();
          }
          if (cols.length > 3 && cols[3] != null) {
            titleStr = cols[3].toString();
          }
        }
      }

      return _BeefwebPlayerSnapshot(
        playbackState: playbackState,
        playlistId: playlistId,
        playlistIndex: playlistIndex,
        itemIndex: itemIndex,
        subsong: subsong,
        positionSeconds: posSec,
        durationSeconds: durSec,
        path: pathStr,
        trackNumberText: trackNoStr,
        title: titleStr,
      );
    } catch (error) {
      developer.log(
        '查询 Beefweb 播放状态忽略',
        name: 'konata.foobar_beefweb_tracker',
        error: error,
      );
      return null;
    }
  }

  static Future<String?> findPlaylistIdByTitle(
    HttpClient client,
    String baseUrl,
    String targetTitle,
  ) async {
    try {
      final uri = Uri.parse('$baseUrl/api/playlists');
      final req = await client
          .getUrl(uri)
          .timeout(const Duration(milliseconds: 800));
      final resp = await req.close().timeout(const Duration(milliseconds: 800));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        await resp.drain<void>();
        return null;
      }
      final raw = await resp
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(milliseconds: 800));
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final playlists = decoded['playlists'];
      if (playlists is! List) return null;
      for (final p in playlists) {
        if (p is Map &&
            p['title']?.toString().trim().toLowerCase() ==
                targetTitle.trim().toLowerCase()) {
          final id = p['id']?.toString() ?? '';
          if (id.isNotEmpty) return id;
        }
      }
    } catch (error) {
      developer.log(
        '查询 Beefweb 播放列表忽略',
        name: 'konata.foobar_beefweb_tracker',
        error: error,
      );
    }
    return null;
  }

  static Future<String> ensureDedicatedPlaylist(
    HttpClient client,
    String baseUrl,
    String title,
  ) async {
    final existing = await findPlaylistIdByTitle(client, baseUrl, title);
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }
    try {
      final uri = Uri.parse('$baseUrl/api/playlists/add');
      final req = await client
          .postUrl(uri)
          .timeout(const Duration(milliseconds: 900));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(<String, Object>{'title': title}));
      final resp = await req.close().timeout(const Duration(milliseconds: 900));
      final raw = await resp
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(milliseconds: 900));
      if (raw.trim().isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map && decoded['id'] != null) {
          final id = decoded['id'].toString();
          if (id.isNotEmpty) return id;
        }
      }
    } catch (error) {
      developer.log(
        '创建专属 Beefweb 播放列表异常已记录',
        name: 'konata.foobar_beefweb_tracker',
        error: error,
      );
    }
    return await findPlaylistIdByTitle(client, baseUrl, title) ?? 'active';
  }

  static Future<void> replacePlaylistItems(
    HttpClient client,
    String baseUrl, {
    required String playlistId,
    required List<String> items,
  }) async {
    try {
      final safeId = Uri.encodeComponent(playlistId);
      final uri = Uri.parse('$baseUrl/api/playlists/$safeId/items/add');
      final req = await client
          .postUrl(uri)
          .timeout(const Duration(seconds: 4));
      req.headers.contentType = ContentType.json;
      req.write(
        jsonEncode(<String, Object>{
          'items': items,
          'replace': true,
          'play': false,
          'async': false,
        }),
      );
      final resp = await req.close().timeout(const Duration(seconds: 6));
      await resp.drain<void>().timeout(const Duration(seconds: 2));
    } catch (error) {
      developer.log(
        '装填 Beefweb 播放列表条目异常已记录',
        name: 'konata.foobar_beefweb_tracker',
        error: error,
      );
    }
  }

  static Future<List<_BeefwebPlaylistItem>> queryPlaylistItems(
    HttpClient client,
    String baseUrl, {
    required String playlistId,
    int maxCount = 200,
  }) async {
    try {
      final safeId = Uri.encodeComponent(playlistId);
      final uri = Uri.parse(
        '$baseUrl/api/playlists/$safeId/items/0:$maxCount?columns=$_columnsQuery',
      );
      final req = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 2));
      final resp = await req.close().timeout(const Duration(seconds: 2));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        await resp.drain<void>();
        return const <_BeefwebPlaylistItem>[];
      }
      final raw = await resp
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 2));
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const <_BeefwebPlaylistItem>[];
      final playlistItems = decoded['playlistItems'];
      if (playlistItems is! Map) return const <_BeefwebPlaylistItem>[];
      final items = playlistItems['items'];
      if (items is! List) return const <_BeefwebPlaylistItem>[];

      final out = <_BeefwebPlaylistItem>[];
      for (var i = 0; i < items.length; i++) {
        final row = items[i];
        if (row is! Map) continue;
        final cols = row['columns'];
        var pathStr = '';
        var subStr = '';
        var trkStr = '';
        var titleStr = '';
        if (cols is List) {
          if (cols.isNotEmpty && cols[0] != null) pathStr = cols[0].toString();
          if (cols.length > 1 && cols[1] != null) subStr = cols[1].toString();
          if (cols.length > 2 && cols[2] != null) trkStr = cols[2].toString();
          if (cols.length > 3 && cols[3] != null) titleStr = cols[3].toString();
        }
        out.add(
          _BeefwebPlaylistItem(
            index: i,
            path: pathStr,
            subsongText: subStr,
            trackNumberText: trkStr,
            title: titleStr,
          ),
        );
      }
      return out;
    } catch (error) {
      developer.log(
        '读取 Beefweb 播放列表已展开条目忽略',
        name: 'konata.foobar_beefweb_tracker',
        error: error,
      );
      return const <_BeefwebPlaylistItem>[];
    }
  }

  static Future<void> postPlayItem(
    HttpClient client,
    String baseUrl, {
    required String playlistId,
    required int index,
  }) async {
    try {
      final safeId = Uri.encodeComponent(playlistId);
      final uri = Uri.parse('$baseUrl/api/player/play/$safeId/$index');
      final req = await client
          .postUrl(uri)
          .timeout(const Duration(milliseconds: 900));
      final resp = await req.close().timeout(const Duration(milliseconds: 900));
      await resp.drain<void>().timeout(const Duration(milliseconds: 900));
    } catch (error) {
      developer.log(
        '触发 Beefweb 指定条目播放异常已记录',
        name: 'konata.foobar_beefweb_tracker',
        error: error,
      );
    }
  }

  static Future<void> postSeek(
    HttpClient client,
    String baseUrl,
    int positionSeconds,
  ) async {
    try {
      final uri = Uri.parse('$baseUrl/api/player');
      final req = await client
          .postUrl(uri)
          .timeout(const Duration(milliseconds: 800));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(<String, Object>{'position': positionSeconds}));
      final resp = await req.close().timeout(const Duration(milliseconds: 800));
      await resp.drain<void>().timeout(const Duration(milliseconds: 800));
    } catch (error) {
      developer.log(
        '提交 Beefweb 进度定位异常已记录',
        name: 'konata.foobar_beefweb_tracker',
        error: error,
      );
    }
  }

  static Future<void> postStop(HttpClient client, String baseUrl) async {
    try {
      final uri = Uri.parse('$baseUrl/api/player/stop');
      final req = await client
          .postUrl(uri)
          .timeout(const Duration(milliseconds: 700));
      final resp = await req.close().timeout(const Duration(milliseconds: 700));
      await resp.drain<void>().timeout(const Duration(milliseconds: 700));
    } catch (error) {
      developer.log(
        '提交 Beefweb 停止指令异常已记录',
        name: 'konata.foobar_beefweb_tracker',
        error: error,
      );
    }
  }
}
