import 'dart:io';
import 'dart:typed_data';

import 'package:ccplayer/application/playback/unified_playback_engine.dart';
import 'package:ccplayer/domain/models/media_source.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/infrastructure/sources/byte_stream_source_gateway.dart';
import 'package:ccplayer/infrastructure/sources/source_credential_store.dart';
import 'package:ccplayer/infrastructure/sources/source_gateway_factory.dart';
import 'package:ccplayer/infrastructure/sources/webdav_source_gateway.dart';
import 'package:ccplayer/infrastructure/sources/work_detail_warmup_service.dart';
import 'package:ccplayer/infrastructure/stream_bridge/remote_window_reader.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/phase3_test_fixtures.dart';

class _MemoryCredentialStore extends SourceCredentialStore {
  const _MemoryCredentialStore(this._secrets);

  final Map<String, String> _secrets;

  @override
  Future<String?> readPassword(String sourceId) async => _secrets[sourceId];
}

void main() {
  group('UnifiedPlaybackEngine 四维代数隔离与熔断契约', () {
    test('CUE 跨轨与音频路由重载均不中断物理媒体代数与主流租约', () {
      final engine = UnifiedPlaybackEngine();
      final instId = engine.attachNativeInstance();
      final mediaEpoch = engine.beginPhysicalMedia(nativeInstanceId: instId);
      engine.bindPlaylistEntryId(7);
      engine.bindMainStreamLease('lease-main-1');
      engine.bindPrefetchStreamLease('lease-prefetch-2', playlistEntryId: 8);

      final subToken = engine.acquireTaskToken(PlaybackTaskDomain.rawSubtitleFetch);
      final cloudToken = engine.acquireTaskToken(PlaybackTaskDomain.cloudSubset);
      final lyricToken = engine.acquireTaskToken(PlaybackTaskDomain.lyricLookup);
      final colorToken = engine.acquireTaskToken(PlaybackTaskDomain.artworkColor);

      // 1. 仅取消云端子集域，严禁误杀其他三域任务
      engine.cancelTaskDomain(PlaybackTaskDomain.cloudSubset);
      expect(engine.isTaskAlive(cloudToken), isFalse);
      expect(engine.isTaskAlive(subToken), isTrue);
      expect(engine.isTaskAlive(lyricToken), isTrue);
      expect(engine.isTaskAlive(colorToken), isTrue);

      // 2. 音频设备热切（audioOutputEpoch 递增）不得破坏物理媒体代数与流租约
      final prevAo = engine.audioOutputEpoch;
      engine.advanceAudioOutputRoute();
      expect(engine.audioOutputEpoch, prevAo + 1);
      expect(engine.physicalMediaEpoch, mediaEpoch);
      expect(engine.mainStreamLease?.leaseToken, 'lease-main-1');
      expect(engine.prefetchStreamLease?.leaseToken, 'lease-prefetch-2');

      // 3. CUE 同母文件跨轨（logicalTrackEpoch 递增）保持物理代数与主流租约存活，仅刷新歌词域
      final prevLogical = engine.logicalTrackEpoch;
      engine.advanceLogicalTrack();
      expect(engine.logicalTrackEpoch, prevLogical + 1);
      expect(engine.physicalMediaEpoch, mediaEpoch);
      expect(engine.mainStreamLease?.leaseToken, 'lease-main-1');
      expect(engine.isTaskAlive(lyricToken), isFalse);
      expect(engine.isTaskAlive(subToken), isTrue);

      // 4. 预取项无缝晋升为主流，精准返回待回收旧主流令牌
      final retiredMain = engine.promotePrefetchLeaseToMain(playlistEntryId: 8);
      expect(retiredMain, 'lease-main-1');
      expect(engine.mainStreamLease?.leaseToken, 'lease-prefetch-2');
      expect(engine.prefetchStreamLease, isNull);
      expect(
        engine.matchesPhysicalEvent(
          physicalMediaEpoch: mediaEpoch,
          nativeInstanceId: instId,
          playlistEntryId: 7,
        ),
        isFalse,
      );
    });

    test('连续 3 个物理坏文件熔断：FILE_LOADED 不清零，仅手动点选或有效进展清零', () {
      final engine = UnifiedPlaybackEngine();
      engine.beginPhysicalMedia();

      // 坏文件 1：即便收到 FILE_LOADED，不得提前清零坏文件计数
      engine.recordFileLoaded();
      expect(engine.recordPhysicalMediaFailure(), isFalse);
      expect(engine.consecutiveBadFiles, 1);

      // 坏文件 2：收到 FILE_LOADED 但音频仅推进 300ms（不足 500ms）仍不准清零
      engine.beginPhysicalMedia();
      engine.recordFileLoaded();
      expect(engine.recordEffectiveProgress(audioAdvancedMs: 300), isFalse);
      expect(engine.recordPhysicalMediaFailure(), isFalse);
      expect(engine.consecutiveBadFiles, 2);

      // 坏文件 3：达到阈值立即触发熔断
      engine.beginPhysicalMedia();
      engine.recordFileLoaded();
      expect(engine.recordPhysicalMediaFailure(), isTrue);
      expect(engine.isCircuitBreakerTripped, isTrue);

      // 有效音频推进 >= 500ms 解除熔断
      expect(engine.recordEffectiveProgress(audioAdvancedMs: 500), isTrue);
      expect(engine.consecutiveBadFiles, 0);
      expect(engine.isCircuitBreakerTripped, isFalse);

      // 首帧上屏同样解除累计失败计数
      engine.recordPhysicalMediaFailure();
      engine.recordPhysicalMediaFailure();
      expect(engine.recordEffectiveProgress(firstFrameRendered: true), isTrue);
      expect(engine.consecutiveBadFiles, 0);

      // 用户手动点选显式解除熔断
      engine.recordPhysicalMediaFailure();
      engine.recordPhysicalMediaFailure();
      engine.recordPhysicalMediaFailure();
      expect(engine.isCircuitBreakerTripped, isTrue);
      engine.recordManualSelection();
      expect(engine.consecutiveBadFiles, 0);
      expect(engine.isCircuitBreakerTripped, isFalse);
    });
  });

  group('详情页静默预热与网桥 206 强一致续传', () {
    test('详情页预热完成 Digest 质询握手并命中 0 ms 内存字幕目录表', () async {
      final server = await MockWebDavLoopbackServer.start(
        files: {
          'Anime/EP01.mkv': Uint8List.fromList([1, 2, 3, 4]),
          'Anime/Subs/EP01.chs.ass': Uint8List.fromList('[Script Info]'.codeUnits),
        },
        requireDigestAuth: true,
      );
      addTearDown(server.close);

      final pool = WebDavConnectionPool();
      addTearDown(pool.dispose);
      final factory = MediaSourceGatewayFactory(
        webDavPool: pool,
        credentialStore: const _MemoryCredentialStore({'src-dav-1': 'secret'}),
      );
      final index = SubtitleDirectoryIndex();
      final warmup = WorkDetailWarmupService(
        gatewayFactory: factory,
        directoryIndex: index,
      );
      final source = MediaSource(
        id: 'src-dav-1',
        label: '测试 WebDAV',
        kind: MediaSourceKind.webdav,
        location: server.baseUri.toString(),
        username: 'konata',
      );
      final variant = MediaVariant(
        id: 'var-1',
        workId: 'work-1',
        episodeId: 'ep-1',
        sourceId: source.id,
        relativePath: 'Anime/EP01.mkv',
        fileName: 'EP01.mkv',
        fileSize: 4,
      );

      await warmup.warmupForVariants(
        variants: [variant],
        sourcesById: {source.id: source},
      );

      // 预热已完成 Digest 握手与目录列举，且字幕路径已驻留内存表
      final snap = index.lookup(source.id, 'Anime');
      expect(snap, isNotNull);
      expect(snap!.siblingPaths, contains('Anime/Subs/EP01.chs.ass'));
      expect(snap.incompleteForSimplified, isFalse);

      // 点播复用连接池发起首个 Range 请求：零额外 401 往返！
      final beforePlayReqs = server.requests.length;
      final gw = WebDavSourceGateway(
        rootUri: server.baseUri,
        username: 'konata',
        password: 'secret',
        connectionPool: pool,
      );
      final validated = await gw.openValidatedByteRange(
        'Anime/EP01.mkv',
        start: 0,
        endInclusive: 3,
      );
      final data = (await validated.stream.toList()).expand((e) => e).toList();
      expect(data, [1, 2, 3, 4]);
      final playReqs = server.requests.sublist(beforePlayReqs);
      expect(playReqs.length, 1);
      expect(playReqs.single.statusCode, HttpStatus.partialContent);
    });

    test('目录超过 4 个子目录且前 4 个仅含非简中字幕时标记 incompleteForSimplified', () {
      final index = SubtitleDirectoryIndex();
      final snap = index.put(
        sourceId: 'src-1',
        dirRelativePath: 'Show',
        siblingPaths: const ['Show/Subs1/EP01.jpn.ass', 'Show/Subs2/EP01.cht.ass'],
        hasUnscannedSubdirs: true,
        scannedSubdirCount: 4,
      );
      expect(snap.incompleteForSimplified, isTrue);
    });

    test('RemoteWindowReader 半途断流按强 ETag + 206 精确续接，换版与 200 整包及 403 立即熔断', () async {
      final payload = Uint8List.fromList(List<int>.generate(4096, (i) => i & 0xFF));
      final server = await MockWebDavLoopbackServer.start(
        files: {'video/ep01.mkv': payload},
        initialEtag: '"strong-v1"',
      );
      addTearDown(server.close);

      final pool = WebDavConnectionPool();
      addTearDown(pool.dispose);
      final gw = WebDavSourceGateway(
        rootUri: server.baseUri,
        connectionPool: pool,
      );

      // 场景 1：前 1024 字节后模拟 TCP 断开，强 ETag 匹配且返 206 精确无缝续传完整 4096 字节
      server.abortAfterBytesOnce = 1024;
      final reader = RemoteWindowReader(
        gateway: gw,
        relativePath: 'video/ep01.mkv',
        totalLength: payload.length,
      );
      final received = (await reader.read(start: 0, endInclusive: 4095).toList())
          .expand((e) => e)
          .toList();
      expect(received, payload);
      expect(reader.lockedStrongValidator, '"strong-v1"');
      // 第二次续传请求必须精确从 bytes=1024-4095 起续接并携带 If-Range
      expect(server.requests.length, 2);
      expect(server.requests[1].rangeHeader, 'bytes=1024-4095');
      expect(server.requests[1].ifRangeHeader, '"strong-v1"');

      // 场景 2：断流后服务端文件换版（ETag 变更），必须立即抛 UpstreamRangeMismatchException
      final reader2 = RemoteWindowReader(
        gateway: gw,
        relativePath: 'video/ep01.mkv',
        totalLength: payload.length,
      );
      server.abortAfterBytesOnce = 512;
      // 首次请求返回前 512 字节后由服务端切换 ETag，触发 If-Range 失配返回 200 拒绝拼接
      final stream2 = reader2.read(start: 0, endInclusive: 4095);
      // 等待首块发出后立即换版
      var firstChunkSeen = false;
      await expectLater(
        () async {
          await for (final _ in stream2) {
            if (!firstChunkSeen) {
              firstChunkSeen = true;
              server.currentEtag = '"strong-v2"';
            }
          }
        }(),
        throwsA(isA<UpstreamRangeMismatchException>()),
      );

      // 场景 3：遇到 403 认证终态错误立即终止，仅发 1 次请求绝不空转重试
      server.force403 = true;
      final before403 = server.requests.length;
      final reader3 = RemoteWindowReader(
        gateway: gw,
        relativePath: 'video/ep01.mkv',
        totalLength: payload.length,
      );
      await expectLater(
        reader3.read(start: 0, endInclusive: 1023).toList(),
        throwsA(isA<TerminalSourceAuthException>()),
      );
      expect(server.requests.length - before403, 1);
    });
  });
}
