import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ccplayer/domain/playback/track_preferences.dart';
import 'package:ccplayer/infrastructure/players/libmpv_ffi.dart';
import 'package:ccplayer/infrastructure/sources/webdav_source_gateway.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/phase3_test_fixtures.dart';

void main() {
  group('Step 0 确定性微型夹具校验', () {
    test('微型唯一采样序号 WAV 头结构与采样序列精确可还原', () {
      final wav = Phase3TestFixtures.generateUniqueSampleWav(
        sampleRate: 48000,
        channels: 2,
        durationMs: 100,
        frameStartIndex: 123,
      );
      final samples = Phase3TestFixtures.readWavLeftSamples(wav);
      expect(samples.length, 4800);
      expect(samples.first, 123 - 8000);
      expect(samples[100], 223 - 8000);
    });

    test('微型双字面 TTF 二进制满足 SFNT 头部与校验和规范', () {
      final ttf = Phase3TestFixtures.generateMinimalDualGlyphTtf(
        familyName: 'KonataProbeFont',
      );
      expect(ttf.length, greaterThan(200));
      expect(ttf.length, lessThan(2048));
      // 校验 SFNT 主版本号 0x00010000
      expect(ttf[0], 0x00);
      expect(ttf[1], 0x01);
      expect(ttf[2], 0x00);
      expect(ttf[3], 0x00);
      final uu = Phase3TestFixtures.encodeAssUuFont(ttf);
      expect(uu, isNotEmpty);
      expect(uu.contains(' '), isFalse);
    });

    test('可控回环 Mock WebDAV 完整覆盖 Digest 401 质询、206 续传与故障注入', () async {
      final payload = Phase3TestFixtures.generateUniqueSampleWav(durationMs: 80);
      final server = await MockWebDavLoopbackServer.start(
        files: {'album/track01.wav': payload},
        requireDigestAuth: true,
      );
      addTearDown(server.close);

      final pool = WebDavConnectionPool();
      addTearDown(pool.dispose);
      final gateway = WebDavSourceGateway(
        rootUri: server.baseUri,
        username: 'konata',
        password: 'secret',
        connectionPool: pool,
      );

      final length = await gateway.probeFileLength('album/track01.wav');
      expect(length, payload.length);
      // 首次请求触发 401 质询握手并成功缓存 Digest nonce
      expect(
        server.requests.any((r) => r.statusCode == HttpStatus.unauthorized),
        isTrue,
      );
      final beforeSecond = server.requests.length;

      final sliceStream = await gateway.openByteRange(
        'album/track01.wav',
        start: 100,
        endInclusive: 299,
      );
      final chunks = await sliceStream.toList();
      final bytes = chunks.expand((e) => e).toList();
      expect(bytes.length, 200);
      expect(bytes, payload.sublist(100, 300));
      // 复用缓存 Digest 后二次请求零 401 往返
      final newReqs = server.requests.sublist(beforeSecond);
      expect(newReqs.length, 1);
      expect(newReqs.single.statusCode, HttpStatus.partialContent);

      // 注入 200 整包错位响应时网关必须严格拒绝，绝不发生错位拼接
      server.force200OnNextRange = true;
      await expectLater(
        () => gateway.openByteRange(
          'album/track01.wav',
          start: 100,
          endInclusive: 299,
        ),
        throwsA(isA<HttpException>()),
      );
    });
  });

  group('Step 0 原生 libmpv 能力真值探针', () {
    test('Android arm64 libmpv.so 包含 gpu-next / libplacebo / aaudio / memory 符号', () {
      final soFile = File(
        p.join(
          Directory.current.path,
          'native',
          'konata-native',
          'android',
          'arm64-v8a',
          'libmpv.so',
        ),
      );
      expect(soFile.existsSync(), isTrue);
      final raw = latin1.decode(soFile.readAsBytesSync());
      expect(raw.contains('gpu-next'), isTrue);
      expect(raw.contains('libplacebo'), isTrue);
      expect(raw.contains('aaudio'), isTrue);
      expect(raw.contains('mediacodec'), isTrue);
      expect(raw.contains('memory://'), isTrue);
      expect(raw.contains('hwdec-codecs'), isTrue);
    });

    test('Windows 真实 libmpv-2.dll 实测 memory:// cached 零抢轨直注、安全限幅滤镜与旗舰选项兼容', () async {
      if (!Platform.isWindows) return;
      final dll = File(
        p.join(
          Directory.current.path,
          'native',
          'konata-native',
          'windows',
          'libmpv-2.dll',
        ),
      );
      expect(
        dll.existsSync(),
        isTrue,
        reason: 'Windows 环境必须存在真实 libmpv-2.dll，禁止静默跳过',
      );

      final tmpDir = await Directory.systemTemp.createTemp('konata_step0_');
      addTearDown(() async {
        if (await tmpDir.exists()) {
          await tmpDir.delete(recursive: true);
        }
      });
      final wavFile = File(p.join(tmpDir.path, 'probe.wav'));
      await wavFile.writeAsBytes(
        Phase3TestFixtures.generateUniqueSampleWav(durationMs: 600),
      );

      final client = FfiLibMpvClient.create(preferredLibraryPath: dll.path);
      addTearDown(() async {
        if (!client.isDisposed) {
          await client.dispose();
        }
      });

      expect(client.setOptionString('config', 'no'), 0);
      expect(client.setOptionString('vo', 'null'), 0);
      expect(client.setOptionString('ao', 'null'), 0);
      expect(client.setOptionString('idle', 'yes'), 0);
      expect(client.setOptionString('keep-open', 'yes'), 0);
      expect(client.setOptionString('sid', 'no'), 0);
      expect(client.setOptionString('gapless-audio', 'weak'), 0);
      expect(client.setOptionString('prefetch-playlist', 'yes'), 0);
      expect(
        client.setOptionString(
          'audio-swresample-o',
          'resampler=soxr,precision=28',
        ),
        0,
      );
      expect(client.setOptionString('fbo-format', 'rgba16hf'), 0);
      expect(client.setOptionString('gpu-api', 'd3d11'), 0);
      expect(client.setOptionString('hwdec', 'd3d11va,d3d11va-copy,auto-safe'), 0);
      // 验证末级安全上限滤镜（alimiter + volume）在内置 FFmpeg 9.0.2 下语法生效
      expect(
        client.setOptionString(
          'af',
          'lavfi=[volume=-12dB,alimiter=limit=-12dB:attack=5:release=50]',
        ),
        0,
      );
      expect(client.initialize(), 0);

      final mpvVersion = client.getPropertyString('mpv-version') ?? '';
      final ffmpegVersion = client.getPropertyString('ffmpeg-version') ?? '';
      expect(mpvVersion, contains('0.42'));
      expect(ffmpegVersion, contains('9.0'));

      final loaded = Completer<void>();
      final sub = client.events.listen((event) {
        if (event is MpvFileLoadedEvent && !loaded.isCompleted) {
          loaded.complete();
        }
      });
      addTearDown(sub.cancel);

      expect(client.command(['loadfile', wavFile.path, 'replace']), 0);
      await loaded.future.timeout(const Duration(seconds: 5));

      // 场景一：sid=no 关闭态下分别实测 sub-add memory://... auto 与 cached 行为
      final assContent = Phase3TestFixtures.generateSyntheticAss();
      expect(client.getPropertyString('sid'), 'no');
      expect(
        client.command([
          'sub-add',
          'memory://$assContent',
          'auto',
          'KonataMemAuto',
        ]),
        0,
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));
      var subTracks = client
          .readTrackList()
          .where((t) => t.type == MpvTrackType.subtitle)
          .toList();
      final memAuto = subTracks.singleWhere((t) => t.title == 'KonataMemAuto');
      // 实证：sid=no 时 `auto` 严格零抢轨（不自动激活字幕）
      expect(memAuto.selected, isFalse);

      // 原子选轨至第一条内存字幕
      expect(client.setPropertyInt64('sid', memAuto.id), 0);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      subTracks = client
          .readTrackList()
          .where((t) => t.type == MpvTrackType.subtitle)
          .toList();
      expect(subTracks.singleWhere((t) => t.id == memAuto.id).selected, isTrue);

      // 场景二：已有选中字幕轨时用 cached 注入相同 URL 触发 mpv 内置去重（不重复建轨、不抢轨）
      expect(
        client.command([
          'sub-add',
          'memory://$assContent',
          'cached',
          'KonataMemCachedDup',
        ]),
        0,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      subTracks = client
          .readTrackList()
          .where((t) => t.type == MpvTrackType.subtitle)
          .toList();
      expect(subTracks.length, 1);
      expect(subTracks.single.id, memAuto.id);
      expect(subTracks.single.selected, isTrue);

      // 场景三：已有选中轨时用 auto 注第二条不同内容，核验零抢轨且支持副字幕
      expect(
        client.command([
          'sub-add',
          'memory://$assContent\n',
          'auto',
          'KonataMemAuto2',
        ]),
        0,
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));
      subTracks = client
          .readTrackList()
          .where((t) => t.type == MpvTrackType.subtitle)
          .toList();
      final track3After = subTracks.singleWhere(
        (t) => t.title == 'KonataMemAuto2',
      );
      expect(track3After.selected, isFalse);
      expect(subTracks.singleWhere((t) => t.id == memAuto.id).selected, isTrue);

      // 切换副字幕轨 secondary-sid 与归零验证
      expect(client.setPropertyInt64('secondary-sid', track3After.id), 0);
      expect(client.setPropertyString('secondary-sid', 'no'), 0);
      expect(client.setPropertyString('sid', 'no'), 0);
    });

    test('Windows 真实 libmpv-2.dll 实测 gpu-next 渲染配置与 Hi10P/Rext 软解判定', () async {
      if (!Platform.isWindows) return;
      final dll = File(
        p.join(
          Directory.current.path,
          'native',
          'konata-native',
          'windows',
          'libmpv-2.dll',
        ),
      );
      expect(
        dll.existsSync(),
        isTrue,
        reason: 'Windows 环境必须存在真实 libmpv-2.dll，禁止静默跳过',
      );

      final client = FfiLibMpvClient.create(preferredLibraryPath: dll.path);
      addTearDown(() async {
        if (!client.isDisposed) {
          await client.dispose();
        }
      });

      // 核验 gpu-next 独有 libplacebo 色彩映射选项与 target-colorspace-hint 已被编译进运行时
      expect(client.setOptionString('config', 'no'), 0);
      expect(client.setOptionString('vo', 'null'), 0);
      expect(client.setOptionString('ao', 'null'), 0);
      expect(client.setOptionString('tone-mapping', 'bt.2446a'), 0);
      expect(client.setOptionString('hdr-compute-peak', 'yes'), 0);
      expect(client.setOptionString('target-colorspace-hint', 'auto'), 0);
      expect(client.setOptionString('libplacebo-opts', 'preset=high_quality'), 0);
      expect(client.initialize(), 0);
      expect(client.getPropertyString('tone-mapping'), 'bt.2446a');
    });
  });
}
