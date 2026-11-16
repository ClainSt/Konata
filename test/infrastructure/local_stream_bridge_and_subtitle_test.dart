import 'dart:io';
import 'dart:typed_data';

import 'package:ccplayer/domain/models/media_source.dart';
import 'package:ccplayer/infrastructure/sources/byte_stream_source_gateway.dart';
import 'package:ccplayer/infrastructure/sources/source_credential_store.dart';
import 'package:ccplayer/infrastructure/sources/source_gateway_factory.dart';
import 'package:ccplayer/infrastructure/sources/subtitle_matcher.dart';
import 'package:ccplayer/infrastructure/sources/webdav_digest_auth.dart';
import 'package:ccplayer/infrastructure/sources/webdav_source_gateway.dart';
import 'package:ccplayer/infrastructure/storage/storage_root_provider.dart';
import 'package:ccplayer/infrastructure/stream_bridge/local_stream_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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

void main() {
  group('LocalStreamBridge HTTP 206 流网桥、Digest 认证与外挂字幕匹配测试', () {
    late Directory tempRoot;
    late LocalStreamBridge bridge;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('konata_bridge_test_');
      bridge = LocalStreamBridge(
        storageRoot: StorageRootService(overrideRoot: tempRoot),
      );
    });

    tearDown(() async {
      await bridge.dispose();
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('回环流网桥支持完整 200 OK、206 Partial Content 精确字节区间与 416 越界防护', () async {
      final videoPayload = Uint8List.fromList(
        List<int>.generate(1024, (i) => i % 251),
      );
      final gateway = _InMemoryByteGateway({'Anime/01.mkv': videoPayload});
      final session = await bridge.registerSession(
        gateway: gateway,
        relativePath: 'Anime/01.mkv',
        fileName: '01.mkv',
        knownLength: videoPayload.length,
        ownsGateway: true,
      );

      expect(session.url.host, '127.0.0.1');
      expect(bridge.port, greaterThan(0));

      final client = HttpClient();
      try {
        // 1. Range: bytes=100-199 -> HTTP 206 + Content-Range + 精确 100 字节切片
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
        expect(body206.length, 100);
        expect(body206, equals(videoPayload.sublist(100, 200)));

        // 2. 无 Range 头 -> HTTP 200 完整返回
        final req200 = await client.getUrl(session.url);
        final res200 = await req200.close();
        final body200 = await res200.fold<List<int>>(
          <int>[],
          (buf, chunk) => buf..addAll(chunk),
        );
        expect(res200.statusCode, HttpStatus.ok);
        expect(body200, equals(videoPayload));

        // 3. 越界 Range -> HTTP 416
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
    });

    test('远程外挂字幕 materializeRemoteSubtitles 完整拉取到系统临时目录', () async {
      const assText = '[Script Info]\nTitle: Frieren EP01 CHS\n';
      final gateway = _InMemoryByteGateway({
        'Frieren/01_chs.ass': Uint8List.fromList(assText.codeUnits),
      });

      final localPaths = await bridge.materializeRemoteSubtitles(
        gateway: gateway,
        workId: 'test_work_sub_1',
        subtitleRelativePaths: const ['Frieren/01_chs.ass'],
      );
      expect(localPaths.length, 1);
      final subFile = File(localPaths.first);
      expect(await subFile.exists(), isTrue);
      expect(await subFile.readAsString(), assText);
      if (await subFile.exists()) {
        await subFile.parent.delete(recursive: true);
      }
    });

    test('SubtitleMatcher 剥离 _chs/[SC]/.tc/.jpn 语言后缀并支持同目录按集号跨文件名匹配', () {
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
        allSubtitleRelativePaths: const [
          'Frieren/[SweetSub] Frieren - 03_chs.ass',
          'Frieren/Subs/[VCB-Studio] Frieren [03].SC.srt',
          'Frieren/[SweetSub] Frieren - 04_chs.ass',
        ],
      );

      expect(
        matched.subtitlePaths,
        containsAll([
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

    test('WebDavDigestAuth 对 401 Digest 质询正确计算 RFC 2617 响应头', () {
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

    test('WebDavConnectionPool 复用 Keep-Alive 客户端与 Digest 质询并保护凭据不落明文', () async {
      final rawPassword = 'super_secret_webdav_password';
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
              final auth = request.headers[HttpHeaders.authorizationHeader] ?? '';
              if (auth.startsWith('Digest ')) {
                digestRequests += 1;
                return http.Response(propfindXml, 207);
              }
              unauthRequests += 1;
              return http.Response(
                '',
                401,
                headers: const {
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
      // 池化网关 close() 不销毁底层复用 Client，且缓存 Digest 质询
      expect(closedClients, equals(0));
      expect(pool.activeHostCount, equals(1));
      expect(unauthRequests, equals(1));
      expect(digestRequests, equals(1));

      // 第二个网关直接复用已有连接与 Digest 质询，首次 PROPFIND 即命中 207，零多余 401 往返
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

      // Factory 对正常建联传递连接池，对 passwordOverride / clearPassword 隔离连接池
      final factory = MediaSourceGatewayFactory(
        credentialStore: _MemoryCredentialStore(rawPassword),
        webDavPool: pool,
      );
      const src = MediaSource(
        id: 'src_dav',
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
  });
}

class _MemoryCredentialStore implements SourceCredentialStore {
  _MemoryCredentialStore(this._password);

  String? _password;

  @override
  Future<void> deletePassword(String sourceId) async {
    _password = null;
  }

  @override
  Future<String?> readPassword(String sourceId) async => _password;

  @override
  Future<void> savePassword(String sourceId, String? password) async {
    _password = password;
  }
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
