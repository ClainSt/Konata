import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:engine_playback/engine_playback.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';
import 'package:test/test.dart';

class _InMemoryWebDavGateway
    implements MediaSourceGateway, ByteRangeReadableGateway {
  _InMemoryWebDavGateway(this.files);

  final Map<String, Uint8List> files;
  bool closed = false;

  @override
  Future<List<RemoteEntry>> listDirectory(String relativePath) async =>
      const [];

  @override
  Future<String?> readTextFile(
    String relativePath, {
    int maxBytes = 256 * 1024,
  }) async {
    final norm = relativePath.replaceAll('\\', '/');
    final data = files[norm];
    if (data == null) {
      return null;
    }
    return utf8.decode(data);
  }

  @override
  Future<String?> testConnection() async => null;

  @override
  Future<int?> probeFileLength(String relativePath) async {
    return files[relativePath.replaceAll('\\', '/')]?.length;
  }

  @override
  Future<Stream<List<int>>> openByteRange(
    String relativePath, {
    required int start,
    int? endInclusive,
  }) async {
    final data = files[relativePath.replaceAll('\\', '/')];
    if (data == null) {
      throw const PathNotFoundException('', OSError('404'), '文件不存在');
    }
    final safeStart = start.clamp(0, data.length);
    final safeEnd = endInclusive != null
        ? (endInclusive + 1).clamp(safeStart, data.length)
        : data.length;
    return Stream<List<int>>.value(
      Uint8List.sublistView(data, safeStart, safeEnd),
    );
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

class _StrictCloudGateway extends _InMemoryWebDavGateway
    implements CloudDriveGateway {
  _StrictCloudGateway(super.files);

  @override
  Future<({int? length, String? validator})> probeFileMetadata(
    String relativePath,
  ) async => (length: await probeFileLength(relativePath), validator: null);

  @override
  Future<Stream<List<int>>> openByteRange(
    String relativePath, {
    required int start,
    int? endInclusive,
  }) async {
    final length = files[relativePath]!.length;
    if (start >= length || (endInclusive != null && endInclusive >= length)) {
      throw const UpstreamRangeMismatchException('range past EOF');
    }
    return super.openByteRange(
      relativePath,
      start: start,
      endInclusive: endInclusive,
    );
  }

  @override
  Future<ValidatedByteRangeStream> openValidatedByteRange(
    String relativePath, {
    required int start,
    int? endInclusive,
    String? expectedStrongValidator,
  }) async => ValidatedByteRangeStream(
    stream: await openByteRange(
      relativePath,
      start: start,
      endInclusive: endInclusive,
    ),
    start: start,
    endInclusive: endInclusive,
    totalLength: files[relativePath]!.length,
  );
}

class _FakeGatewayFactory implements MediaSourceGatewayFactoryPort {
  const _FakeGatewayFactory(this.gateway);

  final _InMemoryWebDavGateway gateway;

  @override
  Future<MediaSourceGateway> create(
    MediaSourceView source, {
    String? passwordOverride,
    bool clearPassword = false,
  }) async => gateway;
}

class _FakeMpvPipeClient implements MpvPipeClient {
  _FakeMpvPipeClient(this.samples);

  final List<(double? pos, double? dur)> samples;
  int _index = 0;

  @override
  Future<double?> queryNumericProperty(String pipePath, String property) async {
    final safeIdx = _index.clamp(0, samples.length - 1);
    final pair = samples[safeIdx];
    if (property == 'time-pos') {
      return pair.$1;
    }
    if (property == 'duration') {
      _index = (_index + 1).clamp(0, samples.length - 1);
      return pair.$2;
    }
    return null;
  }
}

class _FakePotWindowProbe implements PotPlayerWindowProbe {
  _FakePotWindowProbe(this.samples);

  final List<({int positionSeconds, int durationSeconds})?> samples;
  int _index = 0;

  @override
  Future<({int positionSeconds, int durationSeconds})?> queryProgress({
    required int processId,
  }) async {
    if (_index >= samples.length) {
      return samples.last;
    }
    return samples[_index++];
  }
}

class _FakeBeefwebServer {
  late HttpServer _server;

  String get baseUrl => 'http://127.0.0.1:${_server.port}';
  int get port => _server.port;

  final List<({String id, String title, List<Map<String, Object>> items})>
  playlists = [
    (
      id: 'p_default',
      title: 'Default Playlist',
      items: <Map<String, Object>>[
        {
          'columns': ['D:/MyMusic/keep_me.flac', '0', '1', 'My Favorite Song'],
        },
      ],
    ),
  ];

  String playbackState = 'stopped';
  String activePlaylistId = 'p_default';
  int activeIndex = 0;
  int activeSubsong = 0;
  double activePosition = 0.0;
  double activeDuration = 240.0;
  int stopCallCount = 0;
  final List<int> receivedSeeks = <int>[];

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> close() async {
    await _server.close(force: true);
  }

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    final resp = req.response;
    resp.headers.contentType = ContentType.json;

    if (req.method == 'GET' && path == '/api/player') {
      final pl = playlists.where((e) => e.id == activePlaylistId).firstOrNull;
      final itemCols =
          (pl != null && activeIndex >= 0 && activeIndex < pl.items.length)
          ? pl.items[activeIndex]['columns']
          : <String>['', '0', '1', ''];
      resp.write(
        jsonEncode({
          'player': {
            'playbackState': playbackState,
            'activeItem': {
              'playlistId': activePlaylistId,
              'playlistIndex': 0,
              'index': activeIndex,
              'subsong': activeSubsong,
              'position': activePosition,
              'duration': activeDuration,
              'columns': itemCols,
            },
          },
        }),
      );
      await resp.close();
      return;
    }

    if (req.method == 'POST' && path == '/api/player') {
      final raw = await utf8.decoder.bind(req).join();
      final body = jsonDecode(raw) as Map<String, Object?>;
      final pos = body['position'];
      if (pos is num) {
        receivedSeeks.add(pos.toInt());
        activePosition = pos.toDouble();
      }
      resp.statusCode = HttpStatus.noContent;
      await resp.close();
      return;
    }

    if (req.method == 'POST' && path == '/api/player/stop') {
      stopCallCount += 1;
      playbackState = 'stopped';
      resp.statusCode = HttpStatus.noContent;
      await resp.close();
      return;
    }

    if (req.method == 'GET' && path == '/api/playlists') {
      resp.write(
        jsonEncode({
          'playlists': [
            for (var i = 0; i < playlists.length; i++)
              {
                'id': playlists[i].id,
                'index': i,
                'title': playlists[i].title,
                'itemCount': playlists[i].items.length,
              },
          ],
        }),
      );
      await resp.close();
      return;
    }

    if (req.method == 'POST' && path == '/api/playlists/add') {
      final raw = await utf8.decoder.bind(req).join();
      final body = jsonDecode(raw) as Map<String, Object?>;
      final title = body['title']?.toString() ?? 'Untitled';
      final newId = 'p_${playlists.length + 1}';
      playlists.add((id: newId, title: title, items: <Map<String, Object>>[]));
      resp.write(jsonEncode({'id': newId, 'title': title}));
      await resp.close();
      return;
    }

    final addMatch = RegExp(
      r'^/api/playlists/([^/]+)/items/add$',
    ).firstMatch(path);
    if (req.method == 'POST' && addMatch != null) {
      final plId = Uri.decodeComponent(addMatch.group(1)!);
      final raw = await utf8.decoder.bind(req).join();
      final body = jsonDecode(raw) as Map<String, Object?>;
      final incoming = (body['items'] as List).cast<String>();
      final replace = body['replace'] == true;
      final idx = playlists.indexWhere((e) => e.id == plId);
      if (idx >= 0) {
        if (replace) {
          playlists[idx].items.clear();
        }
        for (var i = 0; i < incoming.length; i++) {
          playlists[idx].items.add({
            'columns': [incoming[i], '${i + 1}', '${i + 1}', 'Track ${i + 1}'],
          });
        }
      }
      resp.statusCode = HttpStatus.noContent;
      await resp.close();
      return;
    }

    final getMatch = RegExp(r'^/api/playlists/([^/]+)/items/').firstMatch(path);
    if (req.method == 'GET' && getMatch != null) {
      final plId = Uri.decodeComponent(getMatch.group(1)!);
      final pl = playlists.where((e) => e.id == plId).firstOrNull;
      resp.write(
        jsonEncode({
          'playlistItems': {
            'offset': 0,
            'totalCount': pl?.items.length ?? 0,
            'items': pl?.items ?? const <Map<String, Object>>[],
          },
        }),
      );
      await resp.close();
      return;
    }

    final playMatch = RegExp(
      r'^/api/player/play/([^/]+)/(\d+)$',
    ).firstMatch(path);
    if (req.method == 'POST' && playMatch != null) {
      activePlaylistId = Uri.decodeComponent(playMatch.group(1)!);
      activeIndex = int.parse(playMatch.group(2)!);
      playbackState = 'playing';
      resp.statusCode = HttpStatus.noContent;
      await resp.close();
      return;
    }

    resp.statusCode = HttpStatus.notFound;
    await resp.close();
  }
}

void main() {
  test('严格云盘范围读取不越过短文件 EOF', () async {
    final data = Uint8List.fromList([1, 2, 3, 4, 5]);
    final gateway = _StrictCloudGateway({'cover.webp': data});
    expect(
      await AudioAssetExtractor.readBoundedBytes(
        gateway,
        'cover.webp',
        maxBytes: 1024,
      ),
      data,
    );
    expect(
      await AudioAssetExtractor.readBoundedRange(
        gateway,
        'cover.webp',
        start: 3,
        maxBytes: 1024,
      ),
      [4, 5],
    );
    expect(
      await AudioAssetExtractor.readBoundedRange(
        gateway,
        'cover.webp',
        start: 5,
        maxBytes: 1024,
      ),
      isNull,
    );
  });
  group('MPV IPC / PotPlayer Win32 参数构造与防抖追踪', () {
    test('MPV 启动参数前置选项剥离冗余引号，并过滤瞬态归零', () async {
      final args = MpvIpcTracker.buildLaunchArguments(
        targetUrlOrPath: 'http://127.0.0.1:49152/stream/1/ep01.mkv',
        pipePath: r'\\.\pipe\konata_mpv_test',
        displayTitle: 'Frieren - 01',
        startSeconds: 868,
        subtitlePaths: const [r'C:\subs\01.ass'],
        argumentsTemplate: '--fs "{url}"',
      );
      expect(
        args,
        contains('--input-ipc-server=${r'\\.\pipe\konata_mpv_test'}'),
      );
      expect(args, contains('--start=+868'));
      expect(args, contains('--sub-files=${r'C:\subs\01.ass'}'));
      expect(args, contains('--fs'));
      expect(args.last, equals('http://127.0.0.1:49152/stream/1/ep01.mkv'));

      final fakeMpv = _FakeMpvPipeClient(const [
        (0.0, 1440.0),
        (870.0, 1440.0),
        (878.0, 1440.0),
        (0.0, 1440.0),
      ]);
      final exitCompleter = Completer<int>();
      final saved = <(int, int, bool)>[];
      final future = MpvIpcTracker.trackProcess(
        pipePath: r'\\.\pipe\test',
        exitCodeFuture: exitCompleter.future,
        startSeconds: 868,
        pipeClient: fakeMpv,
        pollInterval: const Duration(milliseconds: 10),
        persistInterval: const Duration(minutes: 1),
        onPersist: (pos, dur, {required isFinal}) async {
          saved.add((pos, dur, isFinal));
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 55));
      exitCompleter.complete(0);
      final res = await future;
      expect(res?.positionSeconds, equals(878));
      expect(saved.last.$1, equals(878));
      expect(saved.last.$3, isTrue);
    });

    test('PotPlayer 参数构造与瞬态归零防抖', () async {
      final args = PotPlayerWin32Tracker.buildLaunchArguments(
        targetUrlOrPath: r'D:\Anime\ep01.mkv',
        startSeconds: 868,
        subtitlePaths: const [r'D:\Anime\ep01.ass'],
      );
      expect(args, contains('/seek=00:14:28'));
      expect(args, contains(r'/sub=D:\Anime\ep01.ass'));

      final probe = _FakePotWindowProbe([
        (positionSeconds: 0, durationSeconds: 1440),
        (positionSeconds: 900, durationSeconds: 1440),
        (positionSeconds: 912, durationSeconds: 1440),
        (positionSeconds: 0, durationSeconds: 1440),
      ]);
      final exitCompleter = Completer<int>();
      final resFuture = PotPlayerWin32Tracker.trackProcess(
        processId: 999999,
        exitCodeFuture: exitCompleter.future,
        startSeconds: 868,
        probe: probe,
        pollInterval: const Duration(milliseconds: 10),
        persistInterval: Duration.zero,
        onPersist: (_, _, {required isFinal}) async {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 55));
      exitCompleter.complete(0);
      final res = await resFuture;
      expect(res?.positionSeconds, equals(912));
    });
  });

  group('DesktopExternalPlayerStore 与 FoobarBeefwebTracker 协议验证', () {
    test('SqliteDesktopExternalPlayerStore 自动过滤历史看图器记录并支持 CRUD', () async {
      final engine = KonataSqliteEngine.openInMemory(
        databaseName: 'ext_test',
        migrations: const [],
      );
      addTearDown(engine.close);
      final store = SqliteDesktopExternalPlayerStore(engine);

      await store.upsertExternalPlayer(
        const ExternalPlayerConfig(
          id: 'player_image_viewer',
          name: 'Legacy Viewer',
          kind: ExternalPlayerKind.custom,
          executablePath: r'C:\viewer.exe',
        ),
      );
      await store.upsertExternalPlayer(
        const ExternalPlayerConfig(
          id: 'mpv_1',
          name: 'MPV',
          kind: ExternalPlayerKind.mpv,
          executablePath: r'C:\mpv.exe',
          isDefault: true,
        ),
      );

      final list = await store.getExternalPlayers();
      expect(list, hasLength(1));
      expect(list.first.id, equals('mpv_1'));

      await store.deleteExternalPlayer('mpv_1');
      expect(await store.getExternalPlayers(), isEmpty);
    });

    test('FoobarBeefwebTracker 专属列表装填、子轨定位续播与切回内置舞台自动停播释放声卡', () async {
      final server = _FakeBeefwebServer();
      await server.start();
      addTearDown(server.close);

      final tracks = <ExternalAudioTrackDescriptor>[
        const ExternalAudioTrackDescriptor(
          recordId: 'cd::track_1',
          episodeId: EpisodeId.trusted('cd::ep_1'),
          variant: MediaVariantRecord(
            id: VariantId.trusted('v1'),
            workId: WorkId.trusted('w1'),
            sourceId: SourceId.trusted('s1'),
            relativePath: '01.flac',
            fileName: '01.flac',
            fileSize: 1024,
            assetKind: AssetKind.cdAlbum,
          ),
          title: 'Track 1',
          trackNumber: 1,
          knownDurationSeconds: 200,
        ),
        const ExternalAudioTrackDescriptor(
          recordId: 'cd::track_2',
          episodeId: EpisodeId.trusted('cd::ep_2'),
          variant: MediaVariantRecord(
            id: VariantId.trusted('v2'),
            workId: WorkId.trusted('w1'),
            sourceId: SourceId.trusted('s1'),
            relativePath: '02.flac',
            fileName: '02.flac',
            fileSize: 1024,
            assetKind: AssetKind.cdAlbum,
          ),
          title: 'Track 2',
          trackNumber: 2,
          knownDurationSeconds: 240,
        ),
      ];

      final progressEvents = <({String recordId, int pos, bool isFinal})>[];
      var cancelled = false;
      final attached = await FoobarBeefwebTracker.attachAlbumAndTrack(
        playlistLoadItems: const [
          'http://127.0.0.1:49152/01.flac',
          'http://127.0.0.1:49152/02.flac',
        ],
        tracks: tracks,
        initialTrackIndex: 1,
        startSeconds: 45,
        baseUrl: server.baseUrl,
        pollInterval: const Duration(milliseconds: 25),
        persistInterval: const Duration(milliseconds: 10),
        isCancelled: () => cancelled,
        onTrackProgress:
            (track, pos, dur, {required isCompleted, required isFinal}) async {
              progressEvents.add((
                recordId: track.recordId,
                pos: pos,
                isFinal: isFinal,
              ));
            },
      );

      expect(attached.attachedToBeefweb, isTrue);
      expect(server.playlists.any((p) => p.title == 'Konata'), isTrue);
      expect(server.activeIndex, equals(1));
      expect(server.receivedSeeks, contains(45));

      server.activePosition = 88.0;
      await Future<void>.delayed(const Duration(milliseconds: 60));

      final stopped = await FoobarBeefwebTracker.stopKonataSessionIfActive(
        baseUrlOverride: server.baseUrl,
      );
      expect(stopped, isTrue);
      expect(server.stopCallCount, equals(1));

      cancelled = true;
      await attached.trackingDone;
      expect(
        progressEvents.any((e) => e.recordId == 'cd::track_2' && e.pos == 88),
        isTrue,
      );
    });
  });

  group('AudioAssetExtractor 头部内嵌封面/歌词提取', () {
    test('AudioAssetExtractor 读取远程 WebDAV CUE 文本并正确解析', () async {
      final gw = _InMemoryWebDavGateway({
        'Album/disc.cue': Uint8List.fromList(
          utf8.encode('''
TITLE "Ost"
FILE "disc.flac" WAVE
  TRACK 01 AUDIO
    TITLE "Opening"
    INDEX 01 00:00:00
'''),
        ),
      });
      final factory = _FakeGatewayFactory(gw);
      final sheet = await AudioAssetExtractor.loadCueSheet(
        source: const MediaSourceView(
          id: SourceId.trusted('s1'),
          kind: MediaSourceKind.webdav,
          label: 'WebDAV',
          location: 'http://127.0.0.1:8080',
        ),
        cueRelativePath: 'Album/disc.cue',
        gatewayFactory: factory,
      );
      expect(sheet, isNotNull);
      expect(sheet!.tracks.single.title, equals('Opening'));
      expect(gw.closed, isTrue);
    });
  });
}
