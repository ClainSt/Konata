import 'package:ccplayer/domain/models/episode.dart';
import 'package:ccplayer/domain/models/external_player_config.dart';
import 'package:ccplayer/domain/models/media_source.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/infrastructure/database/drift_library_repository.dart';
import 'package:ccplayer/infrastructure/database/konata_database.dart';
import 'package:ccplayer/infrastructure/players/desktop_external_player_store.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late KonataDatabase db;
  late DriftLibraryRepository repo;

  setUp(() {
    db = KonataDatabase(NativeDatabase.memory());
    repo = DriftLibraryRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('媒体源、作品、剧集、多版本文件与外部播放器配置读写往返一致', () async {
    const source = MediaSource(
      id: 'src-1',
      kind: MediaSourceKind.local,
      label: '本地动画库',
      location: r'D:\Anime',
    );
    await repo.upsertMediaSource(source);

    const work = Work(
      id: 'work-86',
      tmdbId: 100565,
      tmdbMediaType: TmdbMediaType.tv,
      title: '86 -不存在的战区-',
      originalTitle: '86―エイティシックス―',
      year: 2021,
      overview: '圣玛格诺利亚共和国...',
      posterPath: '/poster.jpg',
      backdropPath: '/backdrop.jpg',
      folderTmdbHint: 100565,
      isManualLocked: true,
      scrapeStatus: ScrapeStatus.matched,
    );
    await repo.upsertWork(work);

    const episode = Episode(
      id: 'ep-86-s1e1',
      workId: 'work-86',
      seasonNumber: 1,
      episodeNumber: 1,
      category: EpisodeCategory.main,
      title: '送葬者',
    );
    await repo.upsertEpisode(episode);

    const variant = MediaVariant(
      id: 'var-1',
      workId: 'work-86',
      episodeId: 'ep-86-s1e1',
      sourceId: 'src-1',
      relativePath: '86/[VCB-Studio] 86 [01].mkv',
      fileName: '[VCB-Studio] 86 [01].mkv',
      fileSize: 104857600,
      assetKind: AssetKind.video,
      releaseGroup: 'VCB-Studio',
      subtitleGroup: 'SweetSub',
      videoCodec: 'HEVC',
      bitDepth: '10bit',
      resolution: '1080p',
      audioCodec: 'FLAC',
      externalSubtitles: ['86/[VCB-Studio] 86 [01].sc.ass'],
    );
    await repo.upsertMediaVariant(variant);

    const mpv = ExternalPlayerConfig(
      id: 'player-mpv',
      name: 'MPV',
      kind: ExternalPlayerKind.mpv,
      executablePath: r'C:\Tools\mpv\mpv.exe',
      argumentsTemplate: '--fs "{url}"',
      isDefault: true,
    );
    final playerStore = DesktopExternalPlayerStore(db);
    await playerStore.upsertExternalPlayer(mpv);

    final loadedSource = (await repo.getMediaSources()).single;
    expect(loadedSource.kind, MediaSourceKind.local);
    expect(loadedSource.label, '本地动画库');

    final loadedWork = await repo.findWorkById('work-86');
    expect(loadedWork, isNotNull);
    expect(loadedWork!.tmdbId, 100565);
    expect(loadedWork.folderTmdbHint, 100565);
    expect(loadedWork.isManualLocked, isTrue);
    expect(loadedWork.scrapeStatus, ScrapeStatus.matched);

    final loadedEps = await repo.getEpisodesByWork('work-86');
    expect(loadedEps.single.title, '送葬者');

    final loadedVariant = (await repo.getVariantsByWork('work-86')).single;
    expect(loadedVariant.assetKind, AssetKind.video);
    expect(loadedVariant.releaseGroup, 'VCB-Studio');
    expect(loadedVariant.subtitleGroup, 'SweetSub');
    expect(loadedVariant.videoCodec, 'HEVC');
    expect(loadedVariant.bitDepth, '10bit');
    expect(loadedVariant.resolution, '1080p');
    expect(loadedVariant.audioCodec, 'FLAC');
    expect(loadedVariant.externalSubtitles, ['86/[VCB-Studio] 86 [01].sc.ass']);

    final loadedPlayers = await playerStore.getExternalPlayers();
    expect(loadedPlayers.single.kind, ExternalPlayerKind.mpv);
    expect(loadedPlayers.single.isDefault, isTrue);
  });
}
