import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:engine_playback/engine_playback.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/playback_test_fixtures.dart';

void main() {
  group('AssUueFontDecoder 编解码与 SFNT 字形实证', () {
    test('任意余数长度字体字节流经 UUE 编解码后精确无损还原且无零填充', () {
      final ttfBytes = PlaybackTestFixtures.generateMinimalDualGlyphTtf(
        familyName: 'KonataTestSubset',
        includeCjk: true,
      );
      expect(AssUueFontDecoder.isValidFontMagic(ttfBytes), isTrue);
      expect(AssUueFontDecoder.fontBytesContainCodePoint(ttfBytes), isTrue);

      for (final extraLen in const [0, 1, 2]) {
        final sample = Uint8List.fromList([
          ...ttfBytes,
          for (var i = 0; i < extraLen; i++) 0xA0 + i,
        ]);
        final encoded = AssUueFontDecoder.encode(sample);
        final decoded = AssUueFontDecoder.decode(encoded);
        expect(decoded.length, sample.length);
        expect(decoded, equals(sample));
      }
    });

    test('从 ASS [Fonts] 段落精准提取多字体与过滤损坏头部字体', () {
      final ttfA = PlaybackTestFixtures.generateMinimalDualGlyphTtf(
        familyName: 'KonataFontA',
        includeCjk: true,
      );
      final ttfLatinOnly = PlaybackTestFixtures.generateMinimalDualGlyphTtf(
        familyName: 'KonataLatinOnly',
        includeCjk: false,
      );
      final assText =
          '''
[Script Info]
ScriptType: v4.00+

[Fonts]
fontname: KonataFontA_0.ttf
${AssUueFontDecoder.encode(ttfA)}
fontname: KonataLatinOnly_0.ttf
${AssUueFontDecoder.encode(ttfLatinOnly)}

[Events]
Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,测试字幕
''';
      final extracted = AssUueFontDecoder.extractEmbeddedFonts(assText);
      expect(extracted.length, 2);
      expect(extracted[0].fontName, 'KonataFontA_0.ttf');
      expect(extracted[0].bytes, equals(ttfA));
      expect(
        AssUueFontDecoder.fontBytesContainCodePoint(extracted[0].bytes),
        isTrue,
      );
      expect(
        AssUueFontDecoder.fontBytesContainCodePoint(extracted[1].bytes),
        isFalse,
      );
    });
  });

  group('SubtitleFontPoolManager 原位零拷贝、哈希池热租约与 CJK 兜底字体修复', () {
    late Directory tempRoot;
    late PortableStorageRootService storageRoot;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('konata_font_pool_');
      storageRoot = PortableStorageRootService(overrideRootPath: tempRoot.path);
    });

    tearDown(() {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    test('本地视频同级或上级 Fonts 目录原位 0 字节直挂且不创建哈希池目录', () async {
      final albumDir = Directory(p.join(tempRoot.path, 'Media', 'Episode01'))
        ..createSync(recursive: true);
      final siblingFontsDir = Directory(p.join(albumDir.path, 'Fonts'))
        ..createSync(recursive: true);
      final validFont = File(p.join(siblingFontsDir.path, 'MainSub.ttf'));
      validFont.writeAsBytesSync(
        PlaybackTestFixtures.generateMinimalDualGlyphTtf(),
      );
      final videoFile = File(p.join(albumDir.path, '01.mkv'))
        ..writeAsBytesSync(const [0, 1, 2, 3]);

      final pool = SubtitleFontPoolManager(storageRoot: storageRoot);
      final resolved = await pool.resolveInPlaceSiblingFontsDir(videoFile.path);
      expect(resolved, isNotNull);
      expect(resolved!.kind, FontSetResolutionKind.inPlaceSiblingDirectory);
      expect(
        p.canonicalize(resolved.directoryPath),
        p.canonicalize(siblingFontsDir.path),
      );
      expect(resolved.fontCount, 1);

      final cacheRoot = await storageRoot.resolveCacheRootPath();
      final poolDir = Directory(
        p.join(cacheRoot, StoragePathNames.fontPoolSubdir),
      );
      expect(poolDir.existsSync(), isFalse);
    });

    test('Fonts.zip 拦截 Zip-Slip、支持后台 Isolate 解压复用并严格执行 3 集合 LRU 驱逐', () async {
      final pool = SubtitleFontPoolManager(
        storageRoot: storageRoot,
        maxHotSetLeases: 3,
      );

      final maliciousZip = PlaybackTestFixtures.buildMinimalZip({
        '../../evil.ttf': PlaybackTestFixtures.generateMinimalDualGlyphTtf(),
      });
      await expectLater(
        pool.ingestFontZipBytes(maliciousZip),
        throwsA(isA<FormatException>()),
      );

      final ttfA = PlaybackTestFixtures.generateMinimalDualGlyphTtf(
        familyName: 'PackA',
      );
      final paddedA = Uint8List.fromList([
        ...ttfA,
        ...List<int>.filled(70 * 1024, 0),
      ]);
      final largeZip = PlaybackTestFixtures.buildMinimalZip({
        'sub/PackA.ttf': paddedA,
      });
      final first = await pool.ingestFontZipBytes(largeZip);
      expect(first.kind, FontSetResolutionKind.hashedPoolLease);
      expect(first.reusedFromLease, isFalse);
      expect(first.fontCount, 1);

      final reused = await pool.ingestFontZipBytes(largeZip);
      expect(reused.setHash, first.setHash);
      expect(reused.reusedFromLease, isTrue);

      for (final name in const ['PackB', 'PackC', 'PackD']) {
        final smallZip = PlaybackTestFixtures.buildMinimalZip({
          '$name.ttf': PlaybackTestFixtures.generateMinimalDualGlyphTtf(
            familyName: name,
          ),
        }, deflate: true);
        await pool.ingestFontZipBytes(smallZip);
      }

      expect(pool.activeLeaseHashes.length, 3);
      expect(pool.activeLeaseHashes, isNot(contains(first.setHash)));
      expect(Directory(first.directoryPath).existsSync(), isFalse);
    });

    test('实证筛选真实含中文 cmap 字形系统字体并自动修复 Android 损坏 subfont.ttf', () async {
      final systemFontsDir = Directory(p.join(tempRoot.path, 'system_fonts'))
        ..createSync(recursive: true);

      File(
        p.join(systemFontsDir.path, 'NotoSansLatin-Regular.ttf'),
      ).writeAsBytesSync(
        PlaybackTestFixtures.generateMinimalDualGlyphTtf(
          familyName: 'NotoLatin',
          includeCjk: false,
        ),
      );
      File(p.join(systemFontsDir.path, 'NotoColorEmoji.ttf')).writeAsBytesSync(
        PlaybackTestFixtures.generateMinimalDualGlyphTtf(
          familyName: 'Emoji',
          includeCjk: true,
        ),
      );
      File(
        p.join(systemFontsDir.path, 'CorruptCJK.ttf'),
      ).writeAsBytesSync(utf8.encode('not-a-valid-sfnt-font'));
      final realCjkFont =
          File(p.join(systemFontsDir.path, 'NotoSansCJKsc-Regular.ttf'))
            ..writeAsBytesSync(
              PlaybackTestFixtures.generateMinimalDualGlyphTtf(
                familyName: 'NotoSansCJK',
                includeCjk: true,
              ),
            );

      final verified =
          await SubtitleFontPoolManager.discoverVerifiedSystemCjkFonts(
            searchRootsOverride: [systemFontsDir],
          );
      expect(verified.map((f) => p.basename(f.path)).toList(), [
        'NotoSansCJKsc-Regular.ttf',
      ]);

      final mpvDir = Directory(p.join(tempRoot.path, 'mpv_android'))
        ..createSync(recursive: true);
      final preFontsDir = Directory(p.join(mpvDir.path, 'fonts'))
        ..createSync(recursive: true);
      final brokenStale = File(p.join(preFontsDir.path, 'stale_broken.ttf'))
        ..writeAsBytesSync(const [1, 2, 3, 4]);
      final badSubfont = File(p.join(mpvDir.path, 'subfont.ttf'))
        ..writeAsBytesSync(
          PlaybackTestFixtures.generateMinimalDualGlyphTtf(
            familyName: 'BrokenLatinSubfont',
            includeCjk: false,
          ),
        );

      await AndroidCjkFontHelper.preparePortableCjkFontSymlinks(
        mpvDir,
        isAndroidOverride: false,
        systemFontRootsOverride: [systemFontsDir],
      );
      expect(brokenStale.existsSync(), isTrue);

      await AndroidCjkFontHelper.preparePortableCjkFontSymlinks(
        mpvDir,
        isAndroidOverride: true,
        systemFontRootsOverride: [systemFontsDir],
      );
      expect(brokenStale.existsSync(), isFalse);
      expect(badSubfont.existsSync(), isTrue);
      expect(
        AssUueFontDecoder.fontBytesContainCodePoint(
          badSubfont.readAsBytesSync(),
        ),
        isTrue,
      );
      expect(
        File(
          p.join(preFontsDir.path, p.basename(realCjkFont.path)),
        ).existsSync(),
        isTrue,
      );

      final emptySystemFonts = Directory(p.join(tempRoot.path, 'empty_fonts'))
        ..createSync(recursive: true);
      final fallbackMpvDir = Directory(
        p.join(tempRoot.path, 'mpv_asset_fallback'),
      )..createSync(recursive: true);
      final fallbackBytes = Uint8List.fromList([
        ...PlaybackTestFixtures.generateMinimalDualGlyphTtf(
          familyName: 'BundledCJK',
          includeCjk: true,
        ),
        ...List<int>.filled(2048, 0),
      ]);
      await AndroidCjkFontHelper.preparePortableCjkFontSymlinks(
        fallbackMpvDir,
        isAndroidOverride: true,
        systemFontRootsOverride: [emptySystemFonts],
        assetLoaderOverride: (assetKey) async {
          expect(assetKey, 'assets/fonts/KonataNotoCJK-VF.ttf');
          return ByteData.sublistView(fallbackBytes);
        },
      );
      final assetSubfont = File(p.join(fallbackMpvDir.path, 'subfont.ttf'));
      expect(assetSubfont.existsSync(), isTrue);
      expect(assetSubfont.readAsBytesSync().length, fallbackBytes.length);
    });
  });

  group('FontInAssCloudClient 与 CloudSubsetCoordinator 安全隔离测试', () {
    late Directory tempRoot;
    late PortableStorageRootService storageRoot;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('konata_cloud_subset_');
      storageRoot = PortableStorageRootService(overrideRootPath: tempRoot.path);
    });

    tearDown(() {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    test('逐 Origin 授权隔离、防重定向、禁用 X-Filename、防语义篡改与原子缓存命中', () async {
      const originalAss = '''
[Script Info]
ScriptType: v4.00+

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Noto Sans CJK SC,48,&H00FFFFFF,&H000000FF,&H00000000,&H64000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:04.00,Default,,0,0,0,,{\\an8\\pos(640,120)}第一行字幕
''';
      final validTtf = PlaybackTestFixtures.generateMinimalDualGlyphTtf(
        familyName: 'SubsetAlias',
      );
      final validSubsetAss =
          '''
[Script Info]
ScriptType: v4.00+

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,SubsetAlias_0,48,&H00FFFFFF,&H000000FF,&H00000000,&H64000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1

[Fonts]
fontname: SubsetAlias_0.ttf
${AssUueFontDecoder.encode(validTtf)}

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:04.00,Default,,0,0,0,,{\\an8\\pos(640,120)}第一行字幕
''';

      var requestCount = 0;
      String? mode = 'ok';
      HttpHeaders? lastHeaders;

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        requestCount++;
        lastHeaders = req.headers;
        await req.drain<void>();
        if (mode == 'redirect') {
          req.response
            ..statusCode = HttpStatus.temporaryRedirect
            ..headers.set(
              HttpHeaders.locationHeader,
              'https://evil.example/leak',
            );
          await req.response.close();
          return;
        }
        if (mode == 'tamper_text') {
          req.response
            ..statusCode = HttpStatus.ok
            ..write(validSubsetAss.replaceAll('第一行字幕', '被恶意篡改的字幕'));
          await req.response.close();
          return;
        }
        req.response
          ..statusCode = HttpStatus.ok
          ..write(validSubsetAss);
        await req.response.close();
      });

      final endpoint = Uri.parse('http://127.0.0.1:${server.port}/api/subset');
      final otherPortEndpoint = Uri.parse(
        'http://127.0.0.1:${server.port + 1}/api/subset',
      );
      final persistedKeys = <String>[];
      final authStore = CloudSubsetAuthorizationStore(
        onLoad: () async => persistedKeys,
        onPersist: (keys) async {
          persistedKeys
            ..clear()
            ..addAll(keys);
        },
      );
      await authStore.ensureHydrated();
      final client = FontInAssCloudClient(
        authorizationStore: authStore,
        storageRoot: storageRoot,
      );

      await expectLater(
        client.requestSubset(
          endpointUri: endpoint,
          originalAssContent: originalAss,
        ),
        throwsA(isA<CloudSubsetUnauthorizedException>()),
      );
      expect(requestCount, 0);

      authStore.grant(endpoint);
      await authStore.flushPendingPersistence();
      expect(persistedKeys, ['http://127.0.0.1:${server.port}']);

      await expectLater(
        client.requestSubset(
          endpointUri: otherPortEndpoint,
          originalAssContent: originalAss,
        ),
        throwsA(isA<CloudSubsetUnauthorizedException>()),
      );

      mode = 'redirect';
      await expectLater(
        client.requestSubset(
          endpointUri: endpoint,
          originalAssContent: originalAss,
        ),
        throwsA(isA<CloudSubsetRedirectBlockedException>()),
      );
      expect(requestCount, 1);

      mode = 'tamper_text';
      await expectLater(
        client.requestSubset(
          endpointUri: endpoint,
          originalAssContent: originalAss,
        ),
        throwsA(isA<CloudSubsetSemanticRejectedException>()),
      );
      expect(requestCount, 2);

      mode = 'ok';
      final first = await client.requestSubset(
        endpointUri: endpoint,
        originalAssContent: originalAss,
      );
      expect(requestCount, 3);
      expect(first.fromLocalCache, isFalse);
      expect(first.verification.isValid, isTrue);
      expect(File(first.cachedFilePath).existsSync(), isTrue);
      expect(lastHeaders?.value('X-Filename'), isNull);
      expect(lastHeaders?.value('X-Font-Name-Mode'), 'alias');
      expect(lastHeaders?.value('X-Fonts-Check'), '0');

      final cached = await client.requestSubset(
        endpointUri: endpoint,
        originalAssContent: originalAss,
      );
      expect(cached.fromLocalCache, isTrue);
      expect(cached.cachedFilePath, first.cachedFilePath);
      expect(requestCount, 3);
      // 读取已验证缓存期间意图失效，同样不得向播放器返回结果。
      var checks = 0;
      await expectLater(
        client.requestSubset(
          endpointUri: endpoint,
          originalAssContent: originalAss,
          isTaskAlive: () => ++checks == 1,
        ),
        throwsA(isA<CloudSubsetCancelledException>()),
      );
      expect(requestCount, 3);
    });

    test('在途撤权通过 CloudSubsetCoordinator 即时中止连接且不误杀其余三域任务', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final arrived = Completer<void>();
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        await req.drain<void>();
        if (!arrived.isCompleted) {
          arrived.complete();
        }
        // 故意挂起响应以模拟慢速云端连接，等待撤权即时断开。
      });

      final engine = UnifiedPlaybackEngine();
      final rawSubToken = engine.acquireTaskToken(
        PlaybackTaskDomain.rawSubtitleFetch,
      );
      final lyricToken = engine.acquireTaskToken(
        PlaybackTaskDomain.lyricLookup,
      );
      final colorToken = engine.acquireTaskToken(
        PlaybackTaskDomain.artworkColor,
      );

      final authStore = CloudSubsetAuthorizationStore();
      final client = FontInAssCloudClient(
        authorizationStore: authStore,
        storageRoot: storageRoot,
        requestTimeout: const Duration(seconds: 5),
      );
      final coordinator = CloudSubsetCoordinator(
        playbackEngine: engine,
        cloudClient: client,
      );

      final endpoint = Uri.parse('http://127.0.0.1:${server.port}/api/subset');
      coordinator.authorizeOrigin(endpoint);

      final future = coordinator.runCloudSubset(
        endpointUri: endpoint,
        originalAssContent:
            '[Events]\nDialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,测试\n',
      );
      await arrived.future;

      coordinator.revokeOriginAndCancel(endpoint);
      await expectLater(future, throwsA(isA<CloudSubsetCancelledException>()));

      expect(engine.isTaskAlive(rawSubToken), isTrue);
      expect(engine.isTaskAlive(lyricToken), isTrue);
      expect(engine.isTaskAlive(colorToken), isTrue);
      expect(authStore.isAuthorized(endpoint), isFalse);
    });
  });
}
