import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:engine_sources/engine_sources.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';
import 'package:test/test.dart';

class _InMemoryByteGateway implements ByteRangeReadableGateway {
  _InMemoryByteGateway(this.files);

  final Map<String, Uint8List> files;
  bool closed = false;

  @override
  Future<int?> probeFileLength(String relativePath) async {
    return files[relativePath]?.length;
  }

  @override
  Future<Stream<List<int>>> openByteRange(
    String relativePath, {
    required int start,
    int? endInclusive,
  }) async {
    final data = files[relativePath];
    if (data == null) {
      throw PathNotFoundException(relativePath, const OSError('Not Found'));
    }
    final safeStart = start.clamp(0, data.length);
    final safeEnd = endInclusive == null
        ? data.length
        : (endInclusive + 1).clamp(safeStart, data.length);
    return Stream<List<int>>.value(data.sublist(safeStart, safeEnd));
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

class _RecordingByteGateway extends _InMemoryByteGateway {
  _RecordingByteGateway(super.files);
  final List<(int, int?)> ranges = <(int, int?)>[];

  @override
  Future<Stream<List<int>>> openByteRange(
    String relativePath, {
    required int start,
    int? endInclusive,
  }) {
    ranges.add((start, endInclusive));
    return super.openByteRange(
      relativePath,
      start: start,
      endInclusive: endInclusive,
    );
  }
}

class _ValidatedResumeGateway implements ValidatedByteRangeGateway {
  _ValidatedResumeGateway(this.data, {required this.etag});

  final Uint8List data;
  String etag;
  bool dropMidwayOnce = false;
  bool forceWrongStartOnResume = false;
  int calls = 0;

  @override
  Future<int?> probeFileLength(String relativePath) async => data.length;

  @override
  Future<Stream<List<int>>> openByteRange(
    String relativePath, {
    required int start,
    int? endInclusive,
  }) async {
    final res = await openValidatedByteRange(
      relativePath,
      start: start,
      endInclusive: endInclusive,
    );
    return res.stream;
  }

  @override
  Future<ValidatedByteRangeStream> openValidatedByteRange(
    String relativePath, {
    required int start,
    int? endInclusive,
    String? expectedStrongValidator,
  }) async {
    calls += 1;
    final actualStart = forceWrongStartOnResume && calls > 1 ? 0 : start;
    final end = (endInclusive ?? data.length - 1).clamp(start, data.length - 1);
    if (dropMidwayOnce && calls == 1) {
      final mid = start + ((end - start + 1) ~/ 2);
      return ValidatedByteRangeStream(
        stream: Stream<List<int>>.value(data.sublist(start, mid)),
        start: actualStart,
        endInclusive: end,
        totalLength: data.length,
        strongValidator: etag,
        isPartialContent: true,
      );
    }
    return ValidatedByteRangeStream(
      stream: Stream<List<int>>.value(data.sublist(start, end + 1)),
      start: actualStart,
      endInclusive: end,
      totalLength: data.length,
      strongValidator: etag,
      isPartialContent: true,
    );
  }

  @override
  Future<void> close() async {}
}

void main() {
  group('LocalStreamBridge HTTP 206 流网桥、Digest 认证与外挂字幕匹配测试', () {
    late Directory tempRoot;
    late LocalStreamBridge bridge;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('konata_bridge_test_');
      bridge = LocalStreamBridge(
        storageRoot: PortableStorageRootService(overrideRootPath: tempRoot.path),
      );
    });

    tearDown(() async {
      await bridge.close();
      if (tempRoot.existsSync()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('回环流网桥支持完整 200 OK、206 精确字节区间、ETag/If-Range 校验与 416 越界防护', () async {
      final videoPayload = Uint8List.fromList(
        List<int>.generate(1024, (i) => i % 251),
      );
      final gateway = _InMemoryByteGateway(<String, Uint8List>{
        'Anime/01.mkv': videoPayload,
      });
      final session = await bridge.registerSession(
        gateway: gateway,
        relativePath: 'Anime/01.mkv',
        fileName: '01.mkv',
        knownLength: videoPayload.length,
        ownsGateway: true,
      );

      expect(session.url.host, '127.0.0.1');
      expect(bridge.port, greaterThan(0));
      expect(bridge.activeSessionCount, 1);

      final client = HttpClient();
      try {
        // 1. 合法区间请求返回 206 Partial Content 与强 ETag。
        final req206 = await client.getUrl(session.url);
        req206.headers.set(HttpHeaders.rangeHeader, 'bytes=100-199');
        final res206 = await req206.close();
        final body206 = await res206.fold<List<int>>(
          <int>[],
          (buf, chunk) => buf..addAll(chunk),
        );
        expect(res206.statusCode, HttpStatus.partialContent);
        expect(
          res206.headers.value(HttpHeaders.contentRangeHeader),
          'bytes 100-199/1024',
        );
        expect(res206.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');
        final etag = res206.headers.value(HttpHeaders.etagHeader);
        expect(etag, isNotNull);
        expect(body206.length, 100);
        expect(body206, equals(videoPayload.sublist(100, 200)));

        // 2. 携带匹配强 ETag 的 If-Range 返回 206。
        final reqIfRangeHit = await client.getUrl(session.url);
        reqIfRangeHit.headers.set(HttpHeaders.rangeHeader, 'bytes=0-15');
        reqIfRangeHit.headers.set(HttpHeaders.ifRangeHeader, etag!);
        final resIfRangeHit = await reqIfRangeHit.close();
        final bodyHit = await resIfRangeHit.fold<List<int>>(
          <int>[],
          (buf, chunk) => buf..addAll(chunk),
        );
        expect(resIfRangeHit.statusCode, HttpStatus.partialContent);
        expect(bodyHit, equals(videoPayload.sublist(0, 16)));

        // 3. 携带不匹配或弱验证器 If-Range 回退为 200 全量流。
        final reqIfRangeMiss = await client.getUrl(session.url);
        reqIfRangeMiss.headers.set(HttpHeaders.rangeHeader, 'bytes=0-15');
        reqIfRangeMiss.headers.set(HttpHeaders.ifRangeHeader, 'W/$etag');
        final resIfRangeMiss = await reqIfRangeMiss.close();
        final bodyMiss = await resIfRangeMiss.fold<List<int>>(
          <int>[],
          (buf, chunk) => buf..addAll(chunk),
        );
        expect(resIfRangeMiss.statusCode, HttpStatus.ok);
        expect(bodyMiss, equals(videoPayload));

        // 4. 无 Range 请求头返回 200 完整流。
        final req200 = await client.getUrl(session.url);
        final res200 = await req200.close();
        final body200 = await res200.fold<List<int>>(
          <int>[],
          (buf, chunk) => buf..addAll(chunk),
        );
        expect(res200.statusCode, HttpStatus.ok);
        expect(body200, equals(videoPayload));

        // 5. 越界区间返回 416。
        final req416 = await client.getUrl(session.url);
        req416.headers.set(HttpHeaders.rangeHeader, 'bytes=5000-6000');
        final res416 = await req416.close();
        await res416.drain<void>();
        expect(res416.statusCode, HttpStatus.requestedRangeNotSatisfiable);
      } finally {
        client.close();
      }

      await bridge.unregisterSession(session.token);
      expect(gateway.closed, isTrue);
      expect(bridge.activeSessionCount, 0);
    });

    test('支持虚拟 CUE 与 M3U8 专辑会话（含 UTF-8 BOM）与本地影子 CUE 落盘', () async {
      final track1 = Uint8List.fromList(List<int>.generate(512, (i) => i % 256));
      final track2 = Uint8List.fromList(
        List<int>.generate(256, (i) => (i + 7) % 256),
      );
      final gateway = _InMemoryByteGateway(<String, Uint8List>{
        'Music/CD1/disc.flac': track1,
        'Music/CD1/bonus.flac': track2,
      });

      final cueReg = await bridge.registerCueAlbumSession(
        gateway: gateway,
        normalizedCueText: 'TITLE "测试专辑"\nFILE "disc.flac" WAVE\n',
        audioEntries: const <VirtualAlbumAudioEntry>[
          VirtualAlbumAudioEntry(
            entryFileName: 'disc.flac',
            relativePath: 'Music/CD1/disc.flac',
            knownLength: 512,
          ),
        ],
        ownsGateway: false,
      );
      expect(bridge.activeSessionCount, 1);

      final m3uReg = await bridge.registerPlaylistM3u8Session(
        gateway: gateway,
        audioEntries: const <VirtualAlbumAudioEntry>[
          VirtualAlbumAudioEntry(
            entryFileName: 'disc.flac',
            relativePath: 'Music/CD1/disc.flac',
            knownLength: 512,
            title: '第一首',
            performer: '测试歌手',
            durationSeconds: 180,
          ),
          VirtualAlbumAudioEntry(
            entryFileName: 'bonus.flac',
            relativePath: 'Music/CD1/bonus.flac',
            knownLength: 256,
          ),
        ],
        ownsGateway: true,
      );
      expect(bridge.activeSessionCount, 2);

      final client = HttpClient();
      try {
        final cueReq = await client.getUrl(cueReg.manifestUrl);
        final cueRes = await cueReq.close();
        final cueBytes = await cueRes.fold<List<int>>(
          <int>[],
          (b, c) => b..addAll(c),
        );
        expect(cueRes.statusCode, HttpStatus.ok);
        expect(cueBytes.sublist(0, 3), equals(const <int>[0xEF, 0xBB, 0xBF]));
        expect(utf8.decode(cueBytes.sublist(3)), contains('测试专辑'));

        final audioReq = await client.getUrl(cueReg.primaryAudioUrl);
        audioReq.headers.set(HttpHeaders.rangeHeader, 'bytes=10-19');
        final audioRes = await audioReq.close();
        final audioSlice = await audioRes.fold<List<int>>(
          <int>[],
          (b, c) => b..addAll(c),
        );
        expect(audioRes.statusCode, HttpStatus.partialContent);
        expect(audioSlice, equals(track1.sublist(10, 20)));

        final m3uReq = await client.getUrl(m3uReg.manifestUrl);
        final m3uRes = await m3uReq.close();
        final m3uBody = await utf8.decoder.bind(m3uRes).join();
        expect(m3uRes.statusCode, HttpStatus.ok);
        expect(m3uBody, startsWith('#EXTM3U'));
        expect(m3uBody, contains('#EXTINF:180,测试歌手 - 第一首'));
      } finally {
        client.close();
      }

      final shadowPath = await bridge.writeLocalShadowCue(
        seedKey: 'album_seed_1',
        normalizedCueText: 'TITLE "影子清单"\n',
      );
      final shadowBytes = File(shadowPath).readAsBytesSync();
      expect(shadowBytes.sublist(0, 3), equals(const <int>[0xEF, 0xBB, 0xBF]));
      expect(utf8.decode(shadowBytes.sublist(3)), contains('影子清单'));

      bridge.touchAlbumSession(cueReg.albumToken);
      await bridge.unregisterAlbumSession(cueReg.albumToken);
      expect(gateway.closed, isFalse);
      await bridge.unregisterAlbumSession(m3uReg.albumToken);
      expect(gateway.closed, isTrue);
    });

    test('支持元信息预热、故障诊断追踪与空闲会话回收', () async {
      final payload = Uint8List.fromList(List<int>.generate(2048, (i) => i % 251));
      final gw = _InMemoryByteGateway(<String, Uint8List>{
        'Anime/ep01.mkv': payload,
      });
      final session = await bridge.registerSession(
        gateway: gw,
        relativePath: 'Anime/ep01.mkv',
        fileName: 'ep01.mkv',
        knownLength: payload.length,
        ownsGateway: true,
      );

      final prewarmed = await bridge.prewarmSessionMetadata(
        session.token,
        headBytes: 512,
        tailBytes: 256,
      );
      expect(prewarmed, isTrue);

      final missingGw = _InMemoryByteGateway(const <String, Uint8List>{});
      final missingSession = await bridge.registerSession(
        gateway: missingGw,
        relativePath: 'Anime/missing.mkv',
        fileName: 'missing.mkv',
      );
      final client = HttpClient();
      try {
        final req = await client.getUrl(missingSession.url);
        final res = await req.close();
        await res.drain<void>();
        expect(res.statusCode, HttpStatus.notFound);
      } finally {
        client.close();
      }
      expect(
        bridge.lastErrorKind(token: missingSession.token),
        SourceAccessProblemKind.path,
      );
      expect(
        bridge.describeLastError(relativePath: 'Anime/missing.mkv'),
        contains('Anime/missing.mkv'),
      );

      await Future<void>.delayed(const Duration(milliseconds: 20));
      final pruned = await bridge.pruneIdleSessions(
        maxIdle: Duration.zero,
        now: DateTime.now().add(const Duration(minutes: 1)),
      );
      expect(pruned, 2);
      expect(bridge.activeSessionCount, 0);
      expect(gw.closed, isTrue);
    });

    test('远程分块窗口有界且完整热块缓存可复用，不再发送全文件 Range', () async {
      const mib = 1024 * 1024;
      final payload = Uint8List.fromList(
        List<int>.generate(6 * mib, (i) => i % 251),
      );
      final gw = _RecordingByteGateway(<String, Uint8List>{
        'Anime/01.mkv': payload,
      });
      final reader = RemoteWindowReader(
        gateway: gw,
        relativePath: 'Anime/01.mkv',
        totalLength: payload.length,
      );
      final first = await reader
          .read(start: 0, endInclusive: payload.length - 1)
          .expand((chunk) => chunk)
          .toList();
      expect(first, payload);
      expect(gw.ranges, <(int, int?)>[
        (0, mib - 1),
        (mib, 5 * mib - 1),
        (5 * mib, 6 * mib - 1),
      ]);
      expect(reader.cachedBytes, payload.length);

      final before = gw.ranges.length;
      final repeat = await reader
          .read(start: 0, endInclusive: 1023)
          .expand((chunk) => chunk)
          .toList();
      expect(repeat, payload.sublist(0, 1024));
      final seek = await reader
          .read(start: 2 * mib, endInclusive: 2 * mib + 255)
          .expand((chunk) => chunk)
          .toList();
      expect(seek, payload.sublist(2 * mib, 2 * mib + 256));
      expect(gw.ranges.length, before);
    });

    test('RemoteWindowReader 断流续传核验强 ETag，起点错位时立即熔断', () async {
      final data = Uint8List.fromList(List<int>.generate(1024, (i) => i % 251));
      final okGw = _ValidatedResumeGateway(data, etag: '"v1"')
        ..dropMidwayOnce = true;
      final okReader = RemoteWindowReader(
        gateway: okGw,
        relativePath: 'a.mkv',
        totalLength: data.length,
      );
      final bytes = await okReader
          .read(start: 0, endInclusive: 511)
          .expand((c) => c)
          .toList();
      expect(bytes, equals(data.sublist(0, 512)));
      expect(okGw.calls, 2);

      final badGw = _ValidatedResumeGateway(data, etag: '"v1"')
        ..dropMidwayOnce = true
        ..forceWrongStartOnResume = true;
      final badReader = RemoteWindowReader(
        gateway: badGw,
        relativePath: 'a.mkv',
        totalLength: data.length,
      );
      await expectLater(
        badReader.read(start: 0, endInclusive: 511).drain<void>(),
        throwsA(isA<UpstreamRangeMismatchException>()),
      );
    });

    test('远程分块对局部 Range 严格只取所需字节，不做无关大块读取', () async {
      final gw = _RecordingByteGateway(<String, Uint8List>{
        'Anime/01.flac': Uint8List.fromList(
          List<int>.generate(4096, (i) => i % 251),
        ),
      });
      final reader = RemoteWindowReader(
        gateway: gw,
        relativePath: 'Anime/01.flac',
        totalLength: 4096,
      );
      final bytes = await reader
          .read(start: 100, endInclusive: 199)
          .expand((chunk) => chunk)
          .toList();
      expect(bytes, gw.files['Anime/01.flac']!.sublist(100, 200));
      expect(gw.ranges, <(int, int?)>[(100, 199)]);
    });

    test('远程外挂字幕原子落盘、校验摘要并支持零网络本地缓存命中', () async {
      const assText = '[Script Info]\nTitle: Frieren EP01 CHS\n';
      final gateway = _InMemoryByteGateway(<String, Uint8List>{
        'Frieren/01_chs.ass': Uint8List.fromList(assText.codeUnits),
      });

      final records = await bridge.materializeRemoteSubtitleRecords(
        gateway: gateway,
        workId: 'test_work_sub_1',
        sourceId: 'src_1',
        subtitleRelativePaths: const <String>['Frieren/01_chs.ass'],
      );
      expect(records, hasLength(1));
      final rec = records.first;
      expect(rec.byteLength, assText.length);
      expect(rec.sourceSha1, hasLength(40));
      final subFile = File(rec.localFilePath);
      expect(subFile.existsSync(), isTrue);
      expect(await subFile.readAsString(), assText);

      final cached = await bridge.resolveExistingCachedSubtitles(
        workId: 'test_work_sub_1',
        sourceId: 'src_1',
        subtitleRelativePaths: const <String>['Frieren/01_chs.ass'],
      );
      expect(cached, equals(<String>[rec.localFilePath]));
    });

    test('SubtitleMatcher 剥离语言后缀并支持同目录按集号跨文件名匹配', () {
      expect(
        SubtitleMatcher.stripLanguageSuffixes(
          '[VCB-Studio] Frieren [03]_chs.ass',
        ),
        '[VCB-Studio] Frieren [03]',
      );
      expect(
        SubtitleMatcher.stripLanguageSuffixes('Frieren - 03[SC].ass'),
        'Frieren - 03',
      );
      expect(
        SubtitleMatcher.stripLanguageSuffixes('Frieren - 03.tc.srt'),
        'Frieren - 03',
      );
      expect(
        SubtitleMatcher.stripLanguageSuffixes('Frieren - 03.jpn.ass'),
        'Frieren - 03',
      );

      final matched = SubtitleMatcher.matchForVideo(
        videoRelativePath: 'Frieren/[VCB-Studio] Frieren [03][1080p].mkv',
        allSubtitleRelativePaths: const <String>[
          'Frieren/[SweetSub] Frieren - 03_chs.ass',
          'Frieren/Subs/[VCB-Studio] Frieren [03].SC.srt',
          'Frieren/[SweetSub] Frieren - 04_chs.ass',
        ],
      );

      expect(
        matched.subtitlePaths,
        containsAll(<String>[
          'Frieren/[SweetSub] Frieren - 03_chs.ass',
          'Frieren/Subs/[VCB-Studio] Frieren [03].SC.srt',
        ]),
      );
      expect(
        matched.subtitlePaths,
        isNot(contains('Frieren/[SweetSub] Frieren - 04_chs.ass')),
      );
      expect(matched.subtitleGroupHint, 'SweetSub');
    });

    test('WebDavDigestAuth 对 401 Digest 质询正确计算请求头', () {
      final header = WebDavDigestAuth.buildAuthorizationHeader(
        wwwAuthenticateHeader:
            'Digest realm="Synology WebDAV", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", qop="auth", algorithm=MD5, opaque="5ccc069c403ebaf9f0171e9517f40e41"',
        method: 'PROPFIND',
        uri: Uri.parse('https://nas.local:5006/Anime/'),
        username: 'konata',
        password: 'secret_password',
      );

      expect(header, isNotNull);
      expect(header, startsWith('Digest '));
      expect(header, contains('username="konata"'));
      expect(header, contains('realm="Synology WebDAV"'));
      expect(header, contains('nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093"'));
      expect(header, contains('uri="/Anime/"'));
      expect(header, contains('qop=auth'));
      expect(header, contains('response="'));
    });

    test('WebDavConnectionPool 复用保活客户端与质询并保护凭据不落明文', () async {
      const rawPassword = 'super_secret_webdav_password';
      final keyA = WebDavConnectionPool.buildOriginKey(
        rootUri: Uri.parse('https://NAS.local:5006/Anime'),
        username: 'konata',
        password: rawPassword,
      );
      final keyB = WebDavConnectionPool.buildOriginKey(
        rootUri: Uri.parse('https://nas.local:5006/OtherRoot/'),
        username: 'konata',
        password: rawPassword,
      );
      final keyDiffPwd = WebDavConnectionPool.buildOriginKey(
        rootUri: Uri.parse('https://nas.local:5006/Anime'),
        username: 'konata',
        password: 'another_password',
      );
      expect(keyA, equals(keyB));
      expect(keyA, isNot(equals(keyDiffPwd)));
      expect(keyA, isNot(contains(rawPassword)));

      var createdClients = 0;
      var closedClients = 0;
      var unauthRequests = 0;
      var digestRequests = 0;

      const propfindXml = '''<?xml version="1.0" encoding="utf-8" ?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/Anime/01.mkv</D:href>
    <D:propstat>
      <D:prop><D:getcontentlength>1234</D:getcontentlength></D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
  </D:response>
</D:multistatus>''';

      final pool = WebDavConnectionPool(
        clientBuilder: () {
          createdClients += 1;
          return _CountingMockClient(
            onRequest: (request) async {
              final auth =
                  request.headers[HttpHeaders.authorizationHeader] ?? '';
              if (auth.startsWith('Digest ')) {
                digestRequests += 1;
                return http.Response(propfindXml, 207);
              }
              unauthRequests += 1;
              return http.Response(
                '',
                401,
                headers: const <String, String>{
                  'www-authenticate':
                      'Digest realm="Synology", nonce="abc123", qop="auth", algorithm=MD5',
                },
              );
            },
            onClose: () => closedClients += 1,
          );
        },
      );

      final gw1 = WebDavSourceGateway(
        rootUri: Uri.parse('https://nas.local:5006/Anime/'),
        username: 'konata',
        password: rawPassword,
        connectionPool: pool,
      );
      final entries1 = await gw1.listDirectory('');
      expect(entries1, hasLength(1));
      await gw1.close();
      expect(closedClients, equals(0));
      expect(pool.activeHostCount, equals(1));
      expect(unauthRequests, equals(1));
      expect(digestRequests, equals(1));

      final gw2 = WebDavSourceGateway(
        rootUri: Uri.parse('https://nas.local:5006/Anime/'),
        username: 'konata',
        password: rawPassword,
        connectionPool: pool,
      );
      final entries2 = await gw2.listDirectory('');
      expect(entries2, hasLength(1));
      await gw2.close();
      expect(createdClients, equals(1));
      expect(unauthRequests, equals(1));
      expect(digestRequests, equals(2));

      final secureStorage = InMemorySecureStorage();
      final credStore = SourceCredentialStore(storage: secureStorage);
      await credStore.savePassword('src_dav', rawPassword);
      final factory = MediaSourceGatewayFactory(
        credentialStore: credStore,
        webDavPool: pool,
      );
      final src = MediaSourceView(
        id: SourceId('src_dav'),
        kind: MediaSourceKind.webdav,
        label: 'NAS',
        location: 'https://nas.local:5006/Anime/',
        username: 'konata',
      );
      final pooledFromFactory = await factory.create(src);
      await pooledFromFactory.close();
      expect(createdClients, equals(1));

      final overrideFromFactory = await factory.create(
        src,
        passwordOverride: 'temp_pwd',
      );
      expect(pool.activeHostCount, equals(1));
      await overrideFromFactory.close();

      pool.dispose();
      expect(closedClients, equals(1));
    });

    test(
      'WebDavSourceGateway 精确编码特殊字符路径且内网地址强制直连绕过代理',
      () async {
        Uri? capturedUri;
        final mockClient = MockClient((request) async {
          capturedUri = request.url;
          return http.Response.bytes(
            const <int>[0x66, 0x4C, 0x61, 0x43],
            206,
            headers: const <String, String>{'content-range': 'bytes 0-3/4'},
          );
        });
        final gw = WebDavSourceGateway(
          rootUri: Uri.parse('http://192.168.1.247:29798/dav'),
          httpClient: mockClient,
        );
        final stream = await gw.openByteRange(
          '未添加TMDB ID/加速世界 TV+Movie/[SweetSub&VCB] {tmdb-217512}/ドラマ + CD-1.flac',
          start: 0,
          endInclusive: 3,
        );
        final bytes = await stream.expand((c) => c).toList();
        expect(bytes, equals(const <int>[0x66, 0x4C, 0x61, 0x43]));
        expect(capturedUri, isNotNull);
        final rawUrl = capturedUri.toString();
        expect(rawUrl, contains('TV%2BMovie'));
        expect(rawUrl, contains('SweetSub%26VCB'));
        expect(rawUrl, contains('%20%2B%20CD-1.flac'));
        expect(rawUrl, isNot(contains('%25')));

        expect(
          WebDavGatewayConfig.resolveSmartProxy(
            Uri.parse('http://192.168.1.247:29798/dav'),
          ),
          equals('DIRECT'),
        );
        expect(
          WebDavGatewayConfig.resolveSmartProxy(
            Uri.parse('http://100.88.12.34:5244/dav'),
          ),
          equals('DIRECT'),
        );
        expect(
          WebDavGatewayConfig.resolveSmartProxy(
            Uri.parse('http://127.0.0.1:61325/stream/abc/01.flac'),
          ),
          equals('DIRECT'),
        );
      },
    );

    test('WebDAV 206 必须校验 Content-Range，并正确返回精确切片', () async {
      final gateway = WebDavSourceGateway(
        rootUri: Uri.parse('http://localhost:29798/dav/'),
        httpClient: MockClient((request) async {
          expect(request.headers['range'], 'bytes=10-14');
          return http.Response.bytes(
            <int>[10, 11, 12, 13, 14],
            206,
            headers: const <String, String>{'content-range': 'bytes 10-14/100'},
          );
        }),
      );
      final result = await gateway.openByteRange(
        '音频/加速世界.flac',
        start: 10,
        endInclusive: 14,
      );
      expect(await result.expand((chunk) => chunk).toList(), <int>[
        10,
        11,
        12,
        13,
        14,
      ]);
      await gateway.close();
    });

    test('WebDAV 不得把忽略 Range 的 200 完整响应透传为非零区间', () async {
      final gateway = WebDavSourceGateway(
        rootUri: Uri.parse('http://localhost:29798/dav/'),
        httpClient: MockClient((_) async => http.Response('whole file', 200)),
      );
      await expectLater(
        gateway.openByteRange('test.flac', start: 128, endInclusive: 255),
        throwsA(isA<UpstreamRangeMismatchException>()),
      );
      await gateway.close();
    });

    test('WebDAV 206 偏移错误与提前 EOF 都必须报错', () async {
      final wrongRange = WebDavSourceGateway(
        rootUri: Uri.parse('http://localhost:29798/dav/'),
        httpClient: MockClient(
          (_) async => http.Response.bytes(
            <int>[1, 2, 3, 4],
            206,
            headers: const <String, String>{'content-range': 'bytes 0-3/100'},
          ),
        ),
      );
      await expectLater(
        wrongRange.openByteRange('test.flac', start: 20, endInclusive: 23),
        throwsA(isA<UpstreamRangeMismatchException>()),
      );
      await wrongRange.close();

      final truncated = WebDavSourceGateway(
        rootUri: Uri.parse('http://localhost:29798/dav/'),
        httpClient: MockClient(
          (_) async => http.Response.bytes(
            <int>[1, 2],
            206,
            headers: const <String, String>{'content-range': 'bytes 20-23/100'},
          ),
        ),
      );
      final data = await truncated.openByteRange(
        'test.flac',
        start: 20,
        endInclusive: 23,
      );
      await expectLater(
        data.expand((chunk) => chunk).toList(),
        throwsA(isA<HttpException>()),
      );
      await truncated.close();
    });
  });
}

class _CountingMockClient extends MockClient {
  _CountingMockClient({
    required Future<http.Response> Function(http.Request request) onRequest,
    required this.onClose,
  }) : super(onRequest);

  final void Function() onClose;

  @override
  void close() {
    onClose();
    super.close();
  }
}
