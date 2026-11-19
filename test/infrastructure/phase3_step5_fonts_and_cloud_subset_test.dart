import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:ccplayer/application/playback/cloud_subset_coordinator.dart';
import 'package:ccplayer/application/playback/unified_playback_engine.dart';
import 'package:ccplayer/domain/playback/ass_uue_font_decoder.dart';
import 'package:ccplayer/infrastructure/storage/storage_root_provider.dart';
import 'package:ccplayer/infrastructure/subtitles/fontinass_cloud_client.dart';
import 'package:ccplayer/infrastructure/subtitles/subtitle_font_pool_manager.dart';

import '../support/phase3_test_fixtures.dart';

/// 构造标准最小 ZIP 二进制（支持 Stored / Deflate 压缩方式，用于测试正常包与 Zip-Slip 拦截）。
Uint8List _buildMinimalZip(
  Map<String, Uint8List> entries, {
  bool deflate = false,
}) {
  final localChunks = BytesBuilder();
  final centralChunks = BytesBuilder();
  var entryCount = 0;

  for (final entry in entries.entries) {
    final nameBytes = utf8.encode(entry.key);
    final raw = entry.value;
    final payload = deflate
        ? Uint8List.fromList(ZLibEncoder(raw: true).convert(raw))
        : raw;
    final method = deflate ? 8 : 0;
    final localOffset = localChunks.length;

    final localHeader = ByteData(30);
    localHeader.setUint32(0, 0x04034b50, Endian.little);
    localHeader.setUint16(4, 20, Endian.little);
    localHeader.setUint16(8, method, Endian.little);
    localHeader.setUint32(18, payload.length, Endian.little);
    localHeader.setUint32(22, raw.length, Endian.little);
    localHeader.setUint16(26, nameBytes.length, Endian.little);

    localChunks
      ..add(localHeader.buffer.asUint8List())
      ..add(nameBytes)
      ..add(payload);

    final cdHeader = ByteData(46);
    cdHeader.setUint32(0, 0x02014b50, Endian.little);
    cdHeader.setUint16(4, 20, Endian.little);
    cdHeader.setUint16(6, 20, Endian.little);
    cdHeader.setUint16(10, method, Endian.little);
    cdHeader.setUint32(20, payload.length, Endian.little);
    cdHeader.setUint32(24, raw.length, Endian.little);
    cdHeader.setUint16(28, nameBytes.length, Endian.little);
    cdHeader.setUint32(42, localOffset, Endian.little);

    centralChunks
      ..add(cdHeader.buffer.asUint8List())
      ..add(nameBytes);
    entryCount += 1;
  }

  final cdOffset = localChunks.length;
  final cdBytes = centralChunks.takeBytes();
  final eocd = ByteData(22);
  eocd.setUint32(0, 0x06054b50, Endian.little);
  eocd.setUint16(8, entryCount, Endian.little);
  eocd.setUint16(10, entryCount, Endian.little);
  eocd.setUint32(12, cdBytes.length, Endian.little);
  eocd.setUint32(16, cdOffset, Endian.little);

  final full = BytesBuilder()
    ..add(localChunks.takeBytes())
    ..add(cdBytes)
    ..add(eocd.buffer.asUint8List());
  return full.takeBytes();
}

void main() {
  group('Step 5.1 ASS [Fonts] UUEncode 精确截断与 SFNT 魔数校验', () {
    test('无行首长度字节且余数 1/2 字节精确截断零尾补，完整往返微型 SFNT TTF', () {
      // 长度 % 3 == 0, 1, 2 全部精确字节还原，绝不引入多余尾 0 字节。
      for (final sample in [
        Uint8List.fromList([0x00, 0x01, 0x00, 0x00, 0xAA, 0xBB]),
        Uint8List.fromList([0x00, 0x01, 0x00, 0x00, 0x11, 0x22, 0x33]),
        Uint8List.fromList([0x4F, 0x54, 0x54, 0x4F, 0xFE, 0xDC, 0xBA, 0x98]),
      ]) {
        final encoded = AssUueFontDecoder.encode(sample);
        final decoded = AssUueFontDecoder.decode(encoded);
        expect(decoded, equals(sample));
        expect(decoded.length, equals(sample.length));
      }

      final ttfBytes = Phase3TestFixtures.generateMinimalDualGlyphTtf(
        familyName: 'KonataUueProbe',
      );
      expect(AssUueFontDecoder.isValidFontMagic(ttfBytes), isTrue);
      expect(AssUueFontDecoder.isValidFontMagic(utf8.encode('NOT_A_FONT_HEADER')), isFalse);

      final uueBlock = AssUueFontDecoder.encode(ttfBytes);
      final assWithFonts = '''
[Script Info]
ScriptType: v4.00+
[Events]
Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,测试中文字形
[Fonts]
fontname: KonataUueProbe.ttf
$uueBlock
''';
      final extracted = AssUueFontDecoder.extractEmbeddedFonts(assWithFonts);
      expect(extracted, hasLength(1));
      expect(extracted.first.fontName, equals('KonataUueProbe.ttf'));
      expect(extracted.first.bytes, equals(ttfBytes));
    });
  });

  group('Step 5.2 原位 Fonts/ 0 拷贝直挂、安全 ZIP 入池、3 集合热租约与系统 CJK 实证扫描', () {
    late Directory tempRoot;
    late SubtitleFontPoolManager manager;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('konata_step5_fonts_');
      manager = SubtitleFontPoolManager(
        storageRoot: StorageRootService(overrideRoot: tempRoot),
        maxHotSetLeases: 3,
      );
    });

    tearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('本地媒体同级 Fonts/ 原位只读直挂 0 拷贝，跨集 0ms 复用', () async {
      final workDir = Directory(p.join(tempRoot.path, 'media', 'Frieren'));
      final siblingFonts = Directory(p.join(workDir.path, 'Fonts'));
      await siblingFonts.create(recursive: true);
      final ttf = Phase3TestFixtures.generateMinimalDualGlyphTtf(
        familyName: 'SiblingFont',
      );
      await File(p.join(siblingFonts.path, 'SiblingFont.ttf')).writeAsBytes(ttf);
      final ep1Path = p.join(workDir.path, '01.mkv');
      final ep2Path = p.join(workDir.path, '02.mkv');

      final res1 = await manager.resolveInPlaceSiblingFontsDir(ep1Path);
      final res2 = await manager.resolveInPlaceSiblingFontsDir(ep2Path);

      expect(res1, isNotNull);
      expect(res1!.kind, equals(FontSetResolutionKind.inPlaceSiblingDirectory));
      expect(res1.directoryPath, equals(siblingFonts.path));
      expect(res1.fontCount, equals(1));
      expect(res2?.directoryPath, equals(siblingFonts.path));

      // 哈希池目录未被创建，证明 0 拷贝直挂。
      final poolDir = Directory(p.join(tempRoot.path, 'cache', 'tmp', 'konata_fonts'));
      expect(await poolDir.exists(), isFalse);
    });

    test('Fonts.zip 拦截 Zip-Slip 穿越，合法包 Deflate 解压入池并严格维持 3 集合热租约', () async {
      final ttfBase = Phase3TestFixtures.generateMinimalDualGlyphTtf(
        familyName: 'ZipFontA',
      );

      // 1. Zip-Slip 恶意穿越路径必须拦截。
      final maliciousZip = _buildMinimalZip({
        '../../escape_evil.ttf': ttfBase,
      });
      await expectLater(
        () => manager.ingestFontZipBytes(maliciousZip),
        throwsA(isA<FormatException>()),
      );

      // 2. 合法 Deflate ZIP 入单级池，二次同包直接热租约 0ms 复用。
      final zip1 = _buildMinimalZip({'Fonts/Font1.ttf': ttfBase}, deflate: true);
      final first = await manager.ingestFontZipBytes(zip1);
      expect(first.reusedFromLease, isFalse);
      expect(first.fontCount, equals(1));
      expect(await Directory(first.directoryPath).exists(), isTrue);

      final reused = await manager.ingestFontZipBytes(zip1);
      expect(reused.reusedFromLease, isTrue);
      expect(reused.directoryPath, equals(first.directoryPath));

      // 3. 连续再入池 3 个新集合（总计 4 个），验证仅保留最近 3 个热集合，第 1 个被驱逐删除。
      final zip2 = _buildMinimalZip({
        'Font2.ttf': Phase3TestFixtures.generateMinimalDualGlyphTtf(familyName: 'F2'),
      });
      final zip3 = _buildMinimalZip({
        'Font3.ttf': Phase3TestFixtures.generateMinimalDualGlyphTtf(familyName: 'F3'),
      });
      final zip4 = _buildMinimalZip({
        'Font4.ttf': Phase3TestFixtures.generateMinimalDualGlyphTtf(familyName: 'F4'),
      });
      final s2 = await manager.ingestFontZipBytes(zip2);
      final s3 = await manager.ingestFontZipBytes(zip3);
      final s4 = await manager.ingestFontZipBytes(zip4);

      expect(manager.activeLeaseHashes, hasLength(3));
      expect(manager.activeLeaseHashes, equals([s2.setHash, s3.setHash, s4.setHash]));
      expect(await Directory(first.directoryPath).exists(), isFalse);
      expect(await Directory(s2.directoryPath).exists(), isTrue);
      expect(await Directory(s4.directoryPath).exists(), isTrue);
    });

    test('运行时实证扫描系统真实 CJK 字体，过滤伪造损坏文件并在 Windows 命中真系统字体', () async {
      final mockSysDir = Directory(p.join(tempRoot.path, 'mock_sys_fonts'));
      await mockSysDir.create(recursive: true);
      final realCjk = File(p.join(mockSysDir.path, 'NotoSansCJK-Regular.ttc'));
      final fakeCjk = File(p.join(mockSysDir.path, 'NotoSerifCJK-Broken.ttf'));
      await realCjk.writeAsBytes(
        Phase3TestFixtures.generateMinimalDualGlyphTtf(familyName: 'MockCJK'),
      );
      await fakeCjk.writeAsString('not a valid sfnt font file');

      final found = await SubtitleFontPoolManager.discoverVerifiedSystemCjkFonts(
        searchRootsOverride: [mockSysDir],
      );
      expect(found.map((f) => p.basename(f.path)), equals(['NotoSansCJK-Regular.ttc']));

      if (Platform.isWindows) {
        final winFonts =
            await SubtitleFontPoolManager.discoverVerifiedSystemCjkFonts();
        expect(winFonts, isNotEmpty);
      }
    });
  });

  group('Step 5.3 逐 Origin 云端子集化、禁 307 重定向、逐事件语义检验与中途撤权分域隔离', () {
    late Directory tempRoot;
    late HttpServer mainServer;
    late HttpServer redirectTargetServer;
    late int redirectTargetHitCount;
    late int mainServerHitCount;
    late Map<String, String> lastReceivedHeaders;

    const originalAss = '''
[Script Info]
ScriptType: v4.00+
[V4+ Styles]
Format: Name, Fontname, Fontsize
Style: Default,SourceHanSans,48
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:04.00,Default,,0,0,0,,{\\fnSourceHanSans\\pos(640,680)}葬送的芙莉莲
Dialogue: 0,0:00:05.00,0:00:08.50,Default,,0,0,0,,{\\fad(100,100)}第二句对白
''';

    String buildValidSubsettedAss() {
      final ttf = Phase3TestFixtures.generateMinimalDualGlyphTtf(
        familyName: 'KNT001Alias',
      );
      final uue = AssUueFontDecoder.encode(ttf);
      return '''
[Script Info]
ScriptType: v4.00+
[V4+ Styles]
Format: Name, Fontname, Fontsize
Style: Default,KNT001Alias,48
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:04.00,Default,,0,0,0,,{\\fnKNT001Alias\\pos(640,680)}葬送的芙莉莲
Dialogue: 0,0:00:05.00,0:00:08.50,Default,,0,0,0,,{\\fad(100,100)}第二句对白
[Fonts]
fontname: KNT001Alias.ttf
$uue
''';
    }

    late Completer<void> holdRequestStarted;
    late Completer<void> holdRelease;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('konata_step5_cloud_');
      redirectTargetHitCount = 0;
      mainServerHitCount = 0;
      lastReceivedHeaders = {};
      holdRequestStarted = Completer<void>();
      holdRelease = Completer<void>();

      redirectTargetServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      redirectTargetServer.listen((req) async {
        redirectTargetHitCount += 1;
        await req.drain<void>();
        req.response.statusCode = HttpStatus.ok;
        req.response.write('should never receive subtitle body');
        await req.response.close();
      });

      mainServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      mainServer.listen((req) async {
        mainServerHitCount += 1;
        final headers = <String, String>{};
        req.headers.forEach((name, values) {
          headers[name.toLowerCase()] = values.join(',');
        });
        lastReceivedHeaders = headers;
        await req.drain<void>();

        switch (req.uri.path) {
          case '/ok':
            req.response.statusCode = HttpStatus.ok;
            req.response.write(buildValidSubsettedAss());
            await req.response.close();
          case '/redirect307':
            req.response.statusCode = HttpStatus.temporaryRedirect;
            req.response.headers.set(
              HttpHeaders.locationHeader,
              'http://127.0.0.1:${redirectTargetServer.port}/steal',
            );
            await req.response.close();
          case '/tamper_text':
            req.response.statusCode = HttpStatus.ok;
            req.response.write(
              buildValidSubsettedAss().replaceFirst('葬送的芙莉莲', '被篡改文字'),
            );
            await req.response.close();
          case '/tamper_font':
            req.response.statusCode = HttpStatus.ok;
            req.response.write('''
$originalAss
[Fonts]
fontname: Broken.ttf
${AssUueFontDecoder.encode(Uint8List.fromList(utf8.encode('NOT_VALID_SFNT_FONT_DATA')))}
''');
            await req.response.close();
          case '/hold':
            if (!holdRequestStarted.isCompleted) {
              holdRequestStarted.complete();
            }
            await holdRelease.future.timeout(
              const Duration(seconds: 5),
              onTimeout: () {},
            );
            try {
              req.response.statusCode = HttpStatus.ok;
              req.response.write(buildValidSubsettedAss());
              await req.response.close();
            } on SocketException catch (e) {
              // 客户端主动取消长连接后套接字已断开，属预期取消行为。
              expect(e.message, isNotNull);
            } on HttpException catch (e) {
              expect(e.message, isNotNull);
            }
          default:
            req.response.statusCode = HttpStatus.notFound;
            await req.response.close();
        }
      });
    });

    tearDown(() async {
      if (!holdRelease.isCompleted) holdRelease.complete();
      await mainServer.close(force: true);
      await redirectTargetServer.close(force: true);
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('逐 Origin 严格鉴权、省略 X-Filename、阻断 307 跨源转发、拒绝语义篡改并原子落盘缓存', () async {
      final authStore = CloudSubsetAuthorizationStore();
      final client = FontInAssCloudClient(
        authorizationStore: authStore,
        storageRoot: StorageRootService(overrideRoot: tempRoot),
      );
      final okUri = Uri.parse('http://127.0.0.1:${mainServer.port}/ok');
      final otherPortUri = Uri.parse(
        'http://127.0.0.1:${redirectTargetServer.port}/ok',
      );

      // 1. 未授权直接拒绝。
      await expectLater(
        () => client.requestSubset(
          endpointUri: okUri,
          originalAssContent: originalAss,
        ),
        throwsA(isA<CloudSubsetUnauthorizedException>()),
      );

      // 2. 仅授权 mainServer Origin：不同端口仍严禁放行。
      authStore.grant(okUri);
      expect(authStore.isAuthorized(okUri), isTrue);
      expect(authStore.isAuthorized(otherPortUri), isFalse);

      // 3. 307 跨源重定向必须强制拦截，且跳转目标服务器收到 0 请求。
      final redirectUri = Uri.parse(
        'http://127.0.0.1:${mainServer.port}/redirect307',
      );
      await expectLater(
        () => client.requestSubset(
          endpointUri: redirectUri,
          originalAssContent: originalAss,
        ),
        throwsA(isA<CloudSubsetRedirectBlockedException>()),
      );
      expect(redirectTargetHitCount, equals(0));
      expect(lastReceivedHeaders.containsKey('x-filename'), isFalse);
      expect(lastReceivedHeaders['x-font-name-mode'], equals('alias'));
      expect(lastReceivedHeaders['x-fonts-check'], equals('0'));

      // 4. 篡改对白文本或返回非法 SFNT 字体必须被逐事件语义校验拒绝。
      await expectLater(
        () => client.requestSubset(
          endpointUri: Uri.parse(
            'http://127.0.0.1:${mainServer.port}/tamper_text',
          ),
          originalAssContent: originalAss,
        ),
        throwsA(isA<CloudSubsetSemanticRejectedException>()),
      );
      await expectLater(
        () => client.requestSubset(
          endpointUri: Uri.parse(
            'http://127.0.0.1:${mainServer.port}/tamper_font',
          ),
          originalAssContent: originalAss,
        ),
        throwsA(isA<CloudSubsetSemanticRejectedException>()),
      );

      // 5. 合法响应通过逐事件语义与魔数检验，原子落盘；二次请求直接命中本地缓存（0 网络请求）。
      final hitsBeforeOk = mainServerHitCount;
      final res1 = await client.requestSubset(
        endpointUri: okUri,
        originalAssContent: originalAss,
      );
      expect(res1.fromLocalCache, isFalse);
      expect(res1.verification.isValid, isTrue);
      expect(res1.verification.verifiedEventCount, equals(2));
      expect(res1.verification.verifiedEmbeddedFontCount, equals(1));
      expect(await File(res1.cachedFilePath).exists(), isTrue);
      expect(mainServerHitCount, equals(hitsBeforeOk + 1));

      final res2 = await client.requestSubset(
        endpointUri: okUri,
        originalAssContent: originalAss,
      );
      expect(res2.fromLocalCache, isTrue);
      expect(mainServerHitCount, equals(hitsBeforeOk + 1));
    });

    test('在途撤权仅取消 cloudSubset 任务域并中断网络连接，绝不误杀其余三域在途任务', () async {
      final engine = UnifiedPlaybackEngine();
      engine.beginPhysicalMedia();

      final rawSubToken = engine.acquireTaskToken(
        PlaybackTaskDomain.rawSubtitleFetch,
      );
      final lyricToken = engine.acquireTaskToken(PlaybackTaskDomain.lyricLookup);
      final colorToken = engine.acquireTaskToken(PlaybackTaskDomain.artworkColor);

      final authStore = CloudSubsetAuthorizationStore();
      final client = FontInAssCloudClient(
        authorizationStore: authStore,
        storageRoot: StorageRootService(overrideRoot: tempRoot),
      );
      final coordinator = CloudSubsetCoordinator(
        playbackEngine: engine,
        cloudClient: client,
      );

      final holdUri = Uri.parse('http://127.0.0.1:${mainServer.port}/hold');
      coordinator.authorizeOrigin(holdUri);

      final inflightFuture = coordinator.runCloudSubset(
        endpointUri: holdUri,
        originalAssContent: originalAss,
      );

      // 等待请求到达远端服务器后在途撤权。
      await holdRequestStarted.future.timeout(const Duration(seconds: 3));
      coordinator.revokeOriginAndCancel(holdUri);

      await expectLater(
        inflightFuture,
        throwsA(isA<CloudSubsetCancelledException>()),
      );

      // 其余三个异步任务域令牌必须 100% 保持存活！
      expect(engine.isTaskAlive(rawSubToken), isTrue);
      expect(engine.isTaskAlive(lyricToken), isTrue);
      expect(engine.isTaskAlive(colorToken), isTrue);
    });
  });
}
