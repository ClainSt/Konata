import 'dart:io';
import 'dart:typed_data';

import 'package:engine_scraping/engine_scraping.dart';
import 'package:feature_detail/feature_detail.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/detail_test_fixtures.dart';

void main() {
  group('MainEpisodeFrameExtractor 全局单并发串行护栏', () {
    test('同时发起多个抽帧任务时严格串行排队，任意时刻并发会话上限为 1', () async {
      final harness = await DetailTestHarness.create(
        gateway: FakeByteRangeGateway(<String, Uint8List>{
          'Show/EP01.mkv': Uint8List(4096),
          'Show/EP02.mkv': Uint8List(4096),
        }),
      );
      final ep1File = File(p.join(harness.tempRoot.path, 'ep01.mkv'))
        ..writeAsBytesSync(Uint8List(128));
      final ep2File = File(p.join(harness.tempRoot.path, 'ep02.mkv'))
        ..writeAsBytesSync(Uint8List(128));

      var activeSessions = 0;
      var maxObservedConcurrency = 0;

      final extractor = MainEpisodeFrameExtractor(
        streamBridge: harness.streamBridge,
        gatewayFactory: harness.gatewayFactory,
        logStore: harness.diagnosticLog,
        pngEncoder: (_) async => kMinimalValidPngBytes,
        clientFactory: () => FakeSoftwareFrameMpvClient(
          seekDelay: const Duration(milliseconds: 35),
          onEnterSession: () {
            activeSessions++;
            if (activeSessions > maxObservedConcurrency) {
              maxObservedConcurrency = activeSessions;
            }
          },
          onExitSession: () {
            activeSessions--;
          },
        ),
      );

      final v1 = MediaVariant(
        id: 'var_1',
        workId: 'w1',
        sourceId: 'src_local',
        relativePath: ep1File.path,
        fileName: 'ep01.mkv',
        fileSize: 128,
      );
      final v2 = MediaVariant(
        id: 'var_2',
        workId: 'w1',
        sourceId: 'src_local',
        relativePath: ep2File.path,
        fileName: 'ep02.mkv',
        fileSize: 128,
      );

      final results = await Future.wait<List<VideoFrameSample>>([
        extractor.extractCandidateFrames(variant: v1, sampleCount: 2),
        extractor.extractCandidateFrames(variant: v2, sampleCount: 2),
      ]);

      expect(maxObservedConcurrency, 1);
      expect(activeSessions, 0);
      expect(results[0], isNotEmpty);
      expect(results[1], isNotEmpty);
    });
  });

  group('MainEpisodeFrameBackfillService 仅限正片抽帧且严格免疫特典', () {
    test('对正片自动抽帧落盘 thumbnails/ 并更新数据库，绝不触发特典抽帧', () async {
      final harness = await DetailTestHarness.create();
      final mediaDir = Directory(p.join(harness.tempRoot.path, 'media'))
        ..createSync(recursive: true);
      final mainFile = File(p.join(mediaDir.path, '01.mkv'))
        ..writeAsBytesSync(Uint8List(256));
      final extraFile = File(p.join(mediaDir.path, 'NCOP01.mkv'))
        ..writeAsBytesSync(Uint8List(256));

      await harness.repository.upsertMediaSource(
        MediaSource(
          id: 'src_1',
          kind: MediaSourceKind.local,
          label: '本地源',
          location: mediaDir.path,
        ),
      );
      const work = Work(
        id: 'w_frame_test',
        title: '测试动画',
        scrapeStatus: ScrapeStatus.matched,
      );
      await harness.repository.upsertWork(work);

      const mainEp = Episode(
        id: 'ep_main_1',
        workId: 'w_frame_test',
        seasonNumber: 1,
        episodeNumber: 1,
        category: EpisodeCategory.main,
        title: '第一话',
      );
      const extraEp = Episode(
        id: 'ep_extra_1',
        workId: 'w_frame_test',
        seasonNumber: 0,
        episodeNumber: 1,
        category: EpisodeCategory.extra,
        extraType: ExtraKind.ncop,
        title: 'NCOP01',
      );
      await harness.repository.upsertEpisode(mainEp);
      await harness.repository.upsertEpisode(extraEp);

      const mainVar = MediaVariant(
        id: 'v_main_1',
        workId: 'w_frame_test',
        episodeId: 'ep_main_1',
        sourceId: 'src_1',
        relativePath: '01.mkv',
        fileName: '01.mkv',
        fileSize: 256,
      );
      const extraVar = MediaVariant(
        id: 'v_extra_1',
        workId: 'w_frame_test',
        episodeId: 'ep_extra_1',
        sourceId: 'src_1',
        relativePath: 'NCOP01.mkv',
        fileName: 'NCOP01.mkv',
        fileSize: 256,
      );
      await harness.repository.upsertMediaVariant(mainVar);
      await harness.repository.upsertMediaVariant(extraVar);

      expect(MainEpisodeFrameBackfillService.needsAutoMainEpisodeStill(mainEp), isTrue);
      expect(MainEpisodeFrameBackfillService.needsAutoMainEpisodeStill(extraEp), isFalse);

      final createdClients = <FakeSoftwareFrameMpvClient>[];
      final extractor = MainEpisodeFrameExtractor(
        streamBridge: harness.streamBridge,
        gatewayFactory: harness.gatewayFactory,
        logStore: harness.diagnosticLog,
        pngEncoder: (_) async => kMinimalValidPngBytes,
        clientFactory: () {
          final client = FakeSoftwareFrameMpvClient(
            seekDelay: const Duration(milliseconds: 5),
            onEnterSession: () {},
            onExitSession: () {},
          );
          createdClients.add(client);
          return client;
        },
      );

      final backfill = MainEpisodeFrameBackfillService(
        repository: harness.repository,
        photosStorage: harness.photosStorage,
        extractor: extractor,
      );

      final changed = await backfill.backfillMissingMainVisuals(
        work: work,
        episodes: const <Episode>[mainEp, extraEp],
        variants: const <MediaVariant>[mainVar, extraVar],
        sourcesById: <String, MediaSource>{
          'src_1': MediaSource(
            id: 'src_1',
            kind: MediaSourceKind.local,
            label: '本地源',
            location: mediaDir.path,
          ),
        },
      );

      final loadedTargets = <String>[
        for (final client in createdClients) ...client.loadedTargets,
      ];
      expect(changed, isTrue);
      expect(loadedTargets, <String>[mainFile.path]);
      expect(loadedTargets, isNot(contains(extraFile.path)));

      final persistedEpisodes = await harness.repository.getEpisodesByWork(
        'w_frame_test',
      );
      final persistedMain = persistedEpisodes.firstWhere(
        (e) => e.id == 'ep_main_1',
      );
      final persistedExtra = persistedEpisodes.firstWhere(
        (e) => e.id == 'ep_extra_1',
      );

      expect(persistedMain.stillPath, isNotNull);
      expect(
        MainEpisodeFrameBackfillService.isAutoExtractedEpisodeStillPath(
          persistedMain.stillPath,
        ),
        isTrue,
      );
      expect(File(persistedMain.stillPath!).existsSync(), isTrue);
      expect(persistedExtra.stillPath, isNull);
    });
  });
}
