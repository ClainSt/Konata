import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:feature_sync/feature_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

Map<String, Object?> _encode(Map<String, Object?> value) => value;
Map<String, Object?> _decode(Map<String, Object?> value, int version) => value;
const _appearance = TypedPrefsSlice<Map<String, Object?>>(
  namespace: 'feature_settings.appearance',
  schemaVersion: 1,
  syncPolicy: SyncPolicy.portable,
  defaultValue: {},
  encode: _encode,
  decode: _decode,
);
const _local = TypedPrefsSlice<Map<String, Object?>>(
  namespace: 'sync_webdav',
  schemaVersion: 1,
  syncPolicy: SyncPolicy.deviceLocal,
  defaultValue: {},
  encode: _encode,
  decode: _decode,
);
KonataBackupService _service(KonataDatabaseBundle db) => KonataBackupService(
  databases: db,
  scopedPrefs: ScopedPrefsStore(db.userState),
  deviceStore: SyncDeviceStore(db.userState.syncMeta),
  nowMs: () => 1800000000000,
);
Future<Uint8List> _fixture(int version, [String extension = 'konata']) => File(
  'test/fixtures/legacy_backup/legacy-complete-v$version.$extension',
).readAsBytes();
Future<Uint8List> _mutate(
  int version,
  void Function(Map<String, Object?>) change, {
  bool rehash = true,
}) async {
  final root =
      jsonDecode(utf8.decode(await _fixture(version, 'json')))
          as Map<String, Object?>;
  final payload = root['payload']! as Map<String, Object?>;
  change(payload);
  if (rehash) {
    root['payloadSha256'] = sha256
        .convert(utf8.encode(jsonEncode(payload)))
        .toString();
  }
  return Uint8List.fromList(utf8.encode(jsonEncode(root)));
}

void _seedV1(KonataDatabaseBundle db) {
  db.library.mediaSources.upsert(
    const MediaSourceRecord(
      id: SourceId.trusted('local-source'),
      kind: MediaSourceKind.local,
      label: '隔离源',
      location: 'D:/isolated',
    ),
  );
  db.library.works.upsert(
    const WorkRecord(
      id: WorkId.trusted('local-work'),
      title: '合成作品',
      tmdbId: 100565,
      tmdbMediaType: TmdbMediaType.tv,
      matchedSeason: 1,
      bangumiId: 293049,
    ),
  );
  db.library.episodes.upsert(
    const EpisodeRecord(
      id: EpisodeId.trusted('local-ep'),
      workId: WorkId.trusted('local-work'),
      seasonNumber: 1,
      episodeNumber: 1,
    ),
  );
  db.library.mediaVariants.upsert(
    const MediaVariantRecord(
      id: VariantId.trusted('local-video'),
      workId: WorkId.trusted('local-work'),
      episodeId: EpisodeId.trusted('local-ep'),
      sourceId: SourceId.trusted('local-source'),
      relativePath: '01.mkv',
      fileName: '01.mkv',
      fileSize: 1024,
    ),
  );
}

void _addLegacyAudio(Map<String, Object?> payload) {
  (payload['playbackEntries']! as List<Object?>).add({
    'playbackKey': 'playback::tmdb:tv:100565:s1::audio::01',
    'canonicalWorkKey': 'tmdb:tv:100565:s1',
    'secondaryWorkKeys': ['bgm:293049'],
    'seasonNumber': 1,
    'episodeNumber': 7,
    'isAudio': true,
    'episodeTitle': '01',
    'positionSeconds': 12,
    'durationSeconds': 100,
    'isCompleted': false,
    'playedAtMs': 1700000000000,
    'updatedAtMs': 1700000000000,
    'sourceDeviceId': 'golden-fixture',
  });
}

void main() {
  test('旧版部分外观和完整详情偏好迁移保留新版专有字段', () async {
    final db = KonataDatabaseBundle.openInMemory();
    addTearDown(db.close);
    _seedV1(db);
    const detail = TypedPrefsSlice<Map<String, Object?>>(
      namespace: 'feature_detail.display',
      schemaVersion: 1,
      syncPolicy: SyncPolicy.portable,
      defaultValue: {},
      encode: _encode,
      decode: _decode,
    );
    final prefs = ScopedPrefsStore(db.userState);
    prefs.write(_appearance, {
      'themeMode': 'dark',
      'windowMaterial': 'mica',
      'ambientBackdropEnabled': true,
    }, updatedAtMs: 100);
    prefs.write(detail, {
      'showMainHeroBackdrop': false,
      'showEpisodeStillThumbnails': false,
      'autoSilentWarmup': false,
      'futureSafeFlag': 7,
    }, updatedAtMs: 100);
    final bytes = await _mutate(1, (p) {
      p['preferences'] = {
        'updatedAtMs': 1700000000000,
        'values': {
          'konata_v2_theme_mode': 'light',
          'konata.detail.show_title_text': true,
          'konata.detail.show_title_logo': false,
          'konata.detail.show_overview': false,
          'konata.detail.show_raw_video_filename': false,
          'konata.detail.show_cd_tab': false,
          'konata.detail.show_scan_tab': true,
        },
      };
    });
    final service = _service(db);
    final before = prefs.read(detail);
    final preview = await service.previewRestore(bytes);
    expect(preview.legacyFormatVersion, 1);
    expect(prefs.read(detail), before);
    await service.restoreFromArchiveBytes(bytes);
    expect(prefs.read(_appearance), {
      'themeMode': 'light',
      'windowMaterial': 'mica',
      'ambientBackdropEnabled': true,
    });
    final expected = {
      'showTitleText': true,
      'showTitleLogo': false,
      'showOverview': false,
      'showRawVideoFilename': false,
      'showCdTab': false,
      'showScanTab': true,
      'showMainHeroBackdrop': false,
      'showEpisodeStillThumbnails': false,
      'autoSilentWarmup': false,
      'futureSafeFlag': 7,
    };
    expect(prefs.read(detail), expected);
    await service.restoreFromArchiveBytes(bytes);
    expect(prefs.read(detail), expected);
    expect(db.userState.playbackRecords.listAllWithTombstones(), hasLength(1));
  });

  test('旧版偏好尊重新版较新时间，非法值与不可移植字段整份拒绝', () async {
    final db = KonataDatabaseBundle.openInMemory();
    addTearDown(db.close);
    _seedV1(db);
    const detail = TypedPrefsSlice<Map<String, Object?>>(
      namespace: 'feature_detail.display',
      schemaVersion: 1,
      syncPolicy: SyncPolicy.portable,
      defaultValue: {},
      encode: _encode,
      decode: _decode,
    );
    final prefs = ScopedPrefsStore(db.userState);
    final service = _service(db);
    final bytes = await _mutate(1, (p) {
      p['preferences'] = {
        'updatedAtMs': 1700000000000,
        'values': {'konata.detail.show_title_logo': false},
      };
    });
    prefs.write(detail, {
      'showTitleLogo': true,
      'showTitleText': false,
      'showOverview': false,
    }, updatedAtMs: 1800000000000);
    await service.restoreFromArchiveBytes(bytes);
    expect(prefs.read(detail), {
      'showTitleLogo': true,
      'showTitleText': false,
      'showOverview': false,
    });
    final invalid = await _mutate(1, (p) {
      p['preferences'] = {
        'updatedAtMs': 1800000000001,
        'values': {'konata.detail.show_cd_tab': 'false'},
      };
    });
    await expectLater(service.previewRestore(invalid), throwsFormatException);
    prefs.write(detail, {
      'showTitleLogo': true,
      'localPath': 'D:/private',
    }, updatedAtMs: 100);
    final before = prefs.read(detail);
    await expectLater(
      service.restoreFromArchiveBytes(bytes),
      throwsFormatException,
    );
    expect(prefs.read(detail), before);
  });

  test('八项旧网络设置迁移，迁址默认值更新且自定义地址保留', () async {
    final db = KonataDatabaseBundle.openInMemory();
    addTearDown(db.close);
    _seedV1(db);
    const network = TypedPrefsSlice<Map<String, Object?>>(
      namespace: 'feature_settings.network',
      schemaVersion: 1,
      syncPolicy: SyncPolicy.portable,
      defaultValue: {},
      encode: _encode,
      decode: _decode,
    );
    final prefs = ScopedPrefsStore(db.userState);
    prefs.write(network, {'futureNetworkFlag': true}, updatedAtMs: 100);
    final bytes = await _mutate(1, (p) {
      p['preferences'] = {
        'updatedAtMs': 1700000000000,
        'values': {
          'konata_v2_tmdb_backup_api': 'https://mirror.example/3',
          'konata_v2_tmdb_backup_image': 'https://image.example/t/p/',
          'konata_v2_bangumi_backup_api': 'https://api.bangumi.lat/v0/',
          'konata_v2_bangumi_backup_image': 'https://lain.bangumi.lat',
          'konata_v2_fanart_backup_api': 'https://fanart.example/v3',
          'konata_v2_fanart_backup_image': '',
          'konata_v2_proxy_mode': 'custom',
          'konata_v2_proxy_url': '127.0.0.1:7890',
        },
      };
    });
    final service = _service(db);
    final before = prefs.read(network);
    await service.previewRestore(bytes);
    expect(prefs.read(network), before);
    await service.restoreFromArchiveBytes(bytes);
    final expected = {
      'tmdbBackupApiBase': 'https://mirror.example/3',
      'tmdbBackupImageBase': 'https://image.example/t/p/',
      'bangumiBackupApiBase': KonataNetworkConfig.defaultBangumiBackupApiBase,
      'bangumiBackupImageBase':
          KonataNetworkConfig.defaultBangumiBackupImageBase,
      'fanartBackupApiBase': 'https://fanart.example/v3',
      'fanartBackupImageBase': '',
      'proxyMode': 'custom',
      'proxyUrl': 'http://127.0.0.1:7890',
      'futureNetworkFlag': true,
    };
    expect(prefs.read(network), expected);
    await service.restoreFromArchiveBytes(bytes);
    expect(prefs.read(network), expected);
  });

  test('旧网络部分恢复保留代理配置并拒绝含凭据或无效地址', () async {
    final db = KonataDatabaseBundle.openInMemory();
    addTearDown(db.close);
    _seedV1(db);
    const network = TypedPrefsSlice<Map<String, Object?>>(
      namespace: 'feature_settings.network',
      schemaVersion: 1,
      syncPolicy: SyncPolicy.portable,
      defaultValue: {},
      encode: _encode,
      decode: _decode,
    );
    final prefs = ScopedPrefsStore(db.userState);
    prefs.write(network, {
      'proxyMode': 'custom',
      'proxyUrl': 'socks5://127.0.0.1:1080',
      'tmdbBackupApiBase': 'https://keep.example/3',
    }, updatedAtMs: 100);
    final service = _service(db);
    Future<Uint8List> archive(Map<String, Object?> values) => _mutate(1, (p) {
      p['preferences'] = {'updatedAtMs': 1700000000000, 'values': values};
    });
    await service.restoreFromArchiveBytes(
      await archive({'konata_v2_fanart_backup_image': 'https://art.example/'}),
    );
    final before = prefs.read(network);
    expect(before['proxyMode'], 'custom');
    expect(before['proxyUrl'], 'socks5://127.0.0.1:1080');
    expect(before['tmdbBackupApiBase'], 'https://keep.example/3');
    for (final bad in <Map<String, Object?>>[
      {'konata_v2_tmdb_backup_api': 'https://user:password@example.invalid/3'},
      {'konata_v2_tmdb_backup_api': 'https://user@example.invalid/3'},
      {'konata_v2_tmdb_backup_api': 'https://example.invalid/3?api_key=secret'},
      {'konata_v2_tmdb_backup_api': 'file:///D:/private'},
      {'konata_v2_proxy_mode': 'unknown'},
      {'konata_v2_proxy_url': 'socks5://127.0.0.1'},
      {'konata_v2_proxy_url': 'http://user:password@127.0.0.1:7890'},
      {'konata_v2_proxy_mode': 'custom', 'konata_v2_proxy_url': ''},
    ]) {
      final bytes = await archive(bad);
      await expectLater(service.previewRestore(bytes), throwsFormatException);
      await expectLater(
        service.restoreFromArchiveBytes(bytes),
        throwsFormatException,
      );
      expect(prefs.read(network), before);
    }
  });

  test('旧播放 JSON 拆分三个自治偏好且不授予上传、外设或歌词权限', () async {
    final db = KonataDatabaseBundle.openInMemory();
    addTearDown(db.close);
    _seedV1(db);
    final prefs = ScopedPrefsStore(db.userState);
    const video = TypedPrefsSlice<Map<String, Object?>>(
      namespace: 'playback_video',
      schemaVersion: 2,
      syncPolicy: SyncPolicy.portable,
      defaultValue: {},
      encode: _encode,
      decode: _decode,
    );
    const audio = TypedPrefsSlice<Map<String, Object?>>(
      namespace: 'playback_audio',
      schemaVersion: 1,
      syncPolicy: SyncPolicy.portable,
      defaultValue: {},
      encode: _encode,
      decode: _decode,
    );
    const lyrics = TypedPrefsSlice<Map<String, Object?>>(
      namespace: 'lyrics',
      schemaVersion: 1,
      syncPolicy: SyncPolicy.portable,
      defaultValue: {},
      encode: _encode,
      decode: _decode,
    );
    prefs.write(video, {
      'qualityConfig': {'activeShaderPaths': <String>[], 'debandEnabled': true},
      'preferredAudioLangs': ['jpn'],
    }, updatedAtMs: 100);
    prefs.write(audio, {
      'loopMode': 'loopAll',
      'audiophileSafetyLimiterEnabled': true,
    }, updatedAtMs: 100);
    prefs.write(lyrics, {'showTranslation': false}, updatedAtMs: 100);
    final payload = {
      'defaultVideoEngine': 'desktopRelay',
      'defaultAudioEngine': 'builtinLibmpv',
      'preferredRelayKindKey': 'mpv',
      'autoNextEpisode': false,
      'promptChapterSkip': true,
      'autoSkipChapter': true,
      'autoEnterPip': false,
      'videoFloatingMiniEnabled': true,
      'audioFloatingMiniEnabled': false,
      'defaultVolume': 72.5,
      'bitstreamPassthrough': true,
      'androidBitPerfectUsb': true,
      'cloudSubsetEnabled': true,
      'cloudSubsetEndpoint': 'https://font.anibt.net/api/subset',
      'foobarBeefwebPort': 9090,
      'skipFoobarBeefwebPrompt': true,
      'lyricSourceNeteaseEnabled': false,
      'lyricSourceAmllEnabled': true,
      'lyricSourceLrclibEnabled': true,
      'lyricSourceQqEnabled': true,
      'qqLyricDisclaimerAccepted': true,
      'showLyricRomaji': true,
      'lyricWiredOffsetMillis': -250,
      'lyricBluetoothOffsetMillis': 650,
      'preset': 'standard',
      'outputPipelineMode': 'gpu_next',
      'outputPipelineSchemaVersion': 2,
      'hardwareDecode': false,
      'debandEnabled': false,
      'demuxerMaxBytesMiB': 128,
      'demuxerMaxBackBytesMiB': 32,
      'cacheSecs': 60,
      'audioResamplerPrecision': 28,
      'exclusiveAudioOutput': true,
      'audioDevice': 'wasapi/test',
      'activeShaderPaths': ['D:/private/old.glsl'],
      'defaultSpeed': 1.25,
      'keepPitch': false,
      'subFontSize': 48,
      'subFontName': 'Noto Sans',
      'subBottomMargin': 24,
      'subOverrideMode': 'preserveAss',
      'subColorHex': '#FFFFFF',
    };
    Future<Uint8List> archive(Map<String, Object?> data) => _mutate(1, (p) {
      p['preferences'] = {
        'updatedAtMs': 1700000000000,
        'values': {'konata.playback.preferences.v1': jsonEncode(data)},
      };
    });
    final service = _service(db);
    final bytes = await archive(payload);
    final before = prefs.read(video);
    await service.previewRestore(bytes);
    expect(prefs.read(video), before);
    await service.restoreFromArchiveBytes(bytes);
    final v = prefs.read(video);
    final a = prefs.read(audio);
    final l = prefs.read(lyrics);
    expect(v['preferredEngine'], 'desktopRelay');
    expect(v['volume'], 0.725);
    expect(v['autoPlayNextEpisode'], false);
    expect(v['autoSkipChapters'], true);
    expect(v['fontInAssEndpoint'], 'https://font.anibt.net/api/subset');
    expect(v['enableCloudSubset'], false);
    expect(v['authorizedCloudSubsetOrigins'], isNull);
    expect(v['preferredAudioLangs'], ['jpn']);
    expect(v['bitstreamPassthrough'], isNull);
    final quality = v['qualityConfig'] as Map;
    expect(quality['preset'], 'standard');
    expect(quality['defaultSpeed'], 1.25);
    expect(quality['subFontName'], 'Noto Sans');
    expect(quality['hardwareDecode'], false);
    expect(quality['exclusiveAudioOutput'], isNull);
    expect(quality['audioDevice'], isNull);
    expect(quality['outputPipelineMode'], isNull);
    expect(quality['activeShaderPaths'], isNull);
    expect(a['defaultVolume'], 72.5);
    expect(a['preferredAudioEngine'], 'builtinLibmpv');
    expect(a['audioResamplerPrecision'], 28);
    expect(a['loopMode'], 'loopAll');
    expect(a['audiophileSafetyLimiterEnabled'], true);
    expect(a['foobarBeefwebPort'], isNull);
    expect(a['skipFoobarBeefwebPrompt'], isNull);
    expect(l['showRomaji'], true);
    expect(l['showTranslation'], false);
    expect(l['wiredOffsetMillis'], -250);
    expect(l['bluetoothOffsetMillis'], 650);
    expect(l['qqEnabled'], isNull);
    expect(l['qqDisclaimerAccepted'], isNull);
    await service.restoreFromArchiveBytes(bytes);
    expect(prefs.read(video), v);
    expect(prefs.read(audio), a);
    expect(prefs.read(lyrics), l);
    final bad = await archive({...payload, 'unknownFutureField': true});
    await expectLater(
      service.restoreFromArchiveBytes(bad),
      throwsFormatException,
    );
    expect(prefs.read(video), v);
    final badEndpoint = await archive({
      ...payload,
      'cloudSubsetEndpoint': 'https://user:secret@example.invalid/subset',
    });
    await expectLater(
      service.previewRestore(badEndpoint),
      throwsFormatException,
    );
    expect(prefs.read(video), v);
    final malformed = await _mutate(1, (p) {
      p['preferences'] = {
        'updatedAtMs': 1700000000000,
        'values': {'konata.playback.preferences.v1': '{"broken":'},
      };
    });
    await expectLater(service.previewRestore(malformed), throwsFormatException);
    expect(prefs.read(video), v);
    prefs.write(video, {...v, 'volume': 0.25}, updatedAtMs: 1800000000000);
    await service.restoreFromArchiveBytes(bytes);
    expect(prefs.read(video)['volume'], 0.25);
    final withLocalShader = <String, Object?>{
      ...v,
      'qualityConfig': {
        'activeShaderPaths': ['D:/private/current.glsl'],
      },
    };
    prefs.write(video, withLocalShader, updatedAtMs: 100);
    await expectLater(
      service.restoreFromArchiveBytes(bytes),
      throwsFormatException,
    );
    expect(prefs.read(video), withLocalShader);
  });

  test('真实黄金源 v2 压缩备份迁移空磁盘库，重开保留六类目录、锁及进度', () async {
    final root = await Directory.systemTemp.createTemp(
      'konata-legacy-complete-',
    );
    addTearDown(() => root.delete(recursive: true));
    final storage = PortableStorageRootService(overrideRootPath: root.path);
    final db = await KonataDatabaseBundle.openFromStorageRoot(storage);
    try {
      final prefs = ScopedPrefsStore(db.userState);
      prefs.write(_local, {
        'baseUrl': 'https://device-only.invalid',
        'password': 'fixture-secret',
      });
      final service = _service(db);
      final bytes = await _fixture(2);
      for (final ext in ['json', 'konata']) {
        final preview = await service.previewRestore(await _fixture(2, ext));
        expect(preview.legacyFormatVersion, 2);
        expect(preview.archiveSliceIds.toSet(), {
          PrefsSyncSlice.id,
          LibraryCatalogSyncSlice.id,
          PlaybackHistorySyncSlice.id,
        });
        expect(preview.totalInserts, 12);
      }
      expect(db.library.works.listVisible(), isEmpty);
      expect(db.userState.playbackRecords.listAllWithTombstones(), isEmpty);
      await expectLater(
        service.restoreFromArchiveBytes(
          bytes,
          mode: KonataRestoreMode.overwrite,
        ),
        throwsFormatException,
      );
      await expectLater(
        service.restoreFromArchiveBytes(
          bytes,
          selectedSliceIds: {PlaybackHistorySyncSlice.id},
        ),
        throwsFormatException,
      );
      for (final ids in [
        {LibraryCatalogSyncSlice.id},
        {LibraryCatalogSyncSlice.id, PlaybackHistorySyncSlice.id},
        {PrefsSyncSlice.id},
      ]) {
        await expectLater(
          service.restoreFromArchiveBytes(bytes, selectedSliceIds: ids),
          throwsFormatException,
        );
      }
      expect(db.library.works.listVisible(), isEmpty);
      await service.restoreFromArchiveBytes(bytes);
    } finally {
      await db.close();
    }
    final reopened = await KonataDatabaseBundle.openFromStorageRoot(storage);
    try {
      final work = reopened.library.works.listVisible().single;
      expect(work.id.value, 'old-work');
      expect(work.seriesId?.value, 'old-series');
      expect(work.metadataLocked, isTrue);
      expect(work.seriesLocked, isTrue);
      expect(
        work.posterRef,
        const RemoteArtworkRef(
          source: ArtworkSource.tmdb,
          uri: '/synthetic.jpg',
          locked: true,
        ),
      );
      expect(
        work.logoRef,
        const RemoteArtworkRef(
          source: ArtworkSource.fanart,
          uri: 'https://assets.fanart.tv/synthetic.png',
          locked: true,
        ),
      );
      expect(reopened.library.episodes.listByWork(work.id), hasLength(2));
      final variants = reopened.library.mediaVariants.listByWork(work.id);
      expect(variants, hasLength(4));
      expect(
        variants.singleWhere((v) => v.id.value == 'old-extra').assetScope,
        SupplementaryAssetScope.seriesShared,
      );
      expect(
        variants.singleWhere((v) => v.id.value == 'old-extra').scopeLocked,
        isTrue,
      );
      expect(
        variants
            .singleWhere((v) => v.id.value == 'old-video')
            .externalSubtitles,
        ['Series/01.sc.ass'],
      );
      expect(
        variants.singleWhere((v) => v.id.value == 'old-video').mappingLocked,
        isTrue,
      );
      expect(
        reopened.library.ignoredFolders
            .listBySource(const SourceId.trusted('old-src'))
            .single
            .relativePath,
        'Ignore',
      );
      final history = reopened.userState.playbackRecords
          .listAllWithTombstones()
          .single;
      expect(history.workId, work.id);
      expect(history.variantId.value, 'old-video');
      expect(history.episodeId.value, 'old-ep');
      expect(history.positionSeconds, 42);
      final prefs = ScopedPrefsStore(reopened.userState);
      expect(prefs.read(_appearance), {
        'themeMode': 'light',
        'windowMaterial': 'mica',
        'ambientBackdropEnabled': true,
      });
      expect(prefs.read(_local)['baseUrl'], 'https://device-only.invalid');
      await _service(reopened).restoreFromArchiveBytes(await _fixture(2));
      expect(reopened.library.works.listVisible(), hasLength(1));
      expect(
        reopened.userState.playbackRecords.listAllWithTombstones(),
        hasLength(1),
      );
    } finally {
      await reopened.close();
    }
  });

  test('v2 完整目录智能合并至非空独立库且保留既有媒体、锁及历史', () async {
    final db = KonataDatabaseBundle.openInMemory();
    addTearDown(db.close);
    const src = SourceId.trusted('existing-source');
    const work = WorkId.trusted('existing-work');
    const ep = EpisodeId.trusted('existing-ep');
    const variant = VariantId.trusted('existing-video');
    db.library.mediaSources.upsert(
      const MediaSourceRecord(
        id: src,
        kind: MediaSourceKind.local,
        label: '本机独立源',
        location: 'D:/existing-fixture',
      ),
    );
    db.library.works.upsert(
      const WorkRecord(
        id: work,
        title: '独立已有作品',
        tmdbId: 999999,
        tmdbMediaType: TmdbMediaType.tv,
        matchedSeason: 1,
        metadataLocked: true,
      ),
    );
    db.library.episodes.upsert(
      const EpisodeRecord(
        id: ep,
        workId: work,
        seasonNumber: 1,
        episodeNumber: 1,
      ),
    );
    db.library.mediaVariants.upsert(
      const MediaVariantRecord(
        id: variant,
        workId: work,
        episodeId: ep,
        sourceId: src,
        relativePath: 'existing.mkv',
        fileName: 'existing.mkv',
        fileSize: 100,
        mappingLocked: true,
      ),
    );
    db.userState.playbackRecords.upsert(
      const PlaybackRecordEntity(
        id: 'existing-record',
        workId: work,
        episodeId: ep,
        variantId: variant,
        playedAtMs: 1800000000000,
        positionSeconds: 61,
        durationSeconds: 120,
      ),
    );
    final service = _service(db);
    final bytes = await _fixture(2);
    final preview = await service.previewRestore(bytes);
    expect(preview.totalInserts, 12);
    expect(db.library.works.listVisible(), hasLength(1));
    expect(db.userState.playbackRecords.listAllWithTombstones(), hasLength(1));
    await service.restoreFromArchiveBytes(bytes);
    expect(db.library.works.listVisible(), hasLength(2));
    expect(db.library.works.findById(work)?.metadataLocked, isTrue);
    expect(db.library.mediaVariants.findById(variant)?.mappingLocked, isTrue);
    expect(
      db.library.mediaVariants.findById(variant)?.relativePath,
      'existing.mkv',
    );
    final histories = db.userState.playbackRecords.listAllWithTombstones();
    expect(histories, hasLength(2));
    expect(
      histories.singleWhere((r) => r.id == 'existing-record').positionSeconds,
      61,
    );
    final restored = histories.singleWhere((r) => r.workId.value == 'old-work');
    expect(restored.episodeId.value, 'old-ep');
    expect(restored.variantId.value, 'old-video');
    expect(restored.positionSeconds, 42);
    await service.restoreFromArchiveBytes(bytes);
    expect(db.library.works.listVisible(), hasLength(2));
    expect(db.userState.playbackRecords.listAllWithTombstones(), hasLength(2));
  });

  test('v2 复用已有 WebDAV 源及本机标识，重复恢复不增加记录', () async {
    final db = KonataDatabaseBundle.openInMemory();
    addTearDown(db.close);
    const source = SourceId.trusted('existing-webdav');
    db.library.mediaSources.upsert(
      const MediaSourceRecord(
        id: source,
        kind: MediaSourceKind.webdav,
        label: '本机连接名称',
        location: 'https://fixture.example.invalid/dav',
        updatedAtMs: 1800000000000,
      ),
    );
    final service = _service(db);
    final bytes = await _fixture(2);
    expect((await service.previewRestore(bytes)).totalInserts, 11);
    await service.restoreFromArchiveBytes(bytes);
    expect(db.library.mediaSources.findById(source)?.label, '本机连接名称');
    expect(
      db.library.mediaSources.findById(const SourceId.trusted('old-src')),
      isNull,
    );
    final work = db.library.works.listVisible().single;
    expect(
      db.library.mediaVariants
          .listByWork(work.id)
          .every((v) => v.sourceId == source),
      isTrue,
    );
    expect(
      db.library.ignoredFolders.listBySource(source).single.relativePath,
      'Ignore',
    );
    expect(
      db.userState.playbackRecords
          .listAllWithTombstones()
          .single
          .positionSeconds,
      42,
    );
    final preview = await service.previewRestore(bytes);
    expect(preview.totalInserts, 0);
    await service.restoreFromArchiveBytes(bytes);
    expect(db.library.works.listVisible(), hasLength(1));
    expect(db.library.mediaVariants.listByWork(work.id), hasLength(4));
    expect(db.userState.playbackRecords.listAllWithTombstones(), hasLength(1));
  });

  test('v2 同作品、系列、分集与物理文件不同主键安全对齐，保留新历史', () async {
    final db = KonataDatabaseBundle.openInMemory();
    addTearDown(db.close);
    final service = _service(db);
    final original = await _fixture(2);
    final rekeyed = await _mutate(2, (p) {
      final catalog = p['libraryCatalog']! as Map<String, Object?>;
      for (final key in [
        'mediaSources',
        'seriesGroups',
        'works',
        'episodes',
        'variants',
        'ignoredFolders',
      ]) {
        for (final value in catalog[key]! as List) {
          final row = value as Map<String, Object?>;
          for (final field in [
            'id',
            'sourceId',
            'seriesId',
            'workId',
            'episodeId',
          ]) {
            if (row[field] != null) row[field] = 'new-${row[field]}';
          }
        }
      }
    });
    await service.restoreFromArchiveBytes(rekeyed);
    const work = WorkId.trusted('new-old-work');
    const episode = EpisodeId.trusted('new-old-ep');
    const variant = VariantId.trusted('new-old-video');
    db.userState.playbackRecords.upsert(
      const PlaybackRecordEntity(
        id: 'new-old-work::new-old-ep',
        workId: work,
        episodeId: episode,
        variantId: variant,
        seasonNumber: 1,
        episodeNumber: 1,
        episodeTitle: '第一集',
        sourceKind: MediaSourceKind.webdav,
        playedAtMs: 1800000000000,
        updatedAtMs: 1800000000000,
        positionSeconds: 77,
        durationSeconds: 120,
      ),
    );
    final preview = await service.previewRestore(original);
    expect(preview.totalInserts, 0);
    expect(db.library.works.listVisible().single.id, work);
    await service.restoreFromArchiveBytes(original);
    final restored = db.library.works.listVisible().single;
    expect(restored.id, work);
    expect(restored.metadataLocked, isTrue);
    expect(restored.seriesId?.value, 'new-old-series');
    expect(db.library.episodes.listByWork(work), hasLength(2));
    final variants = db.library.mediaVariants.listByWork(work);
    expect(variants, hasLength(4));
    expect(variants.singleWhere((v) => v.id == variant).mappingLocked, isTrue);
    expect(variants.singleWhere((v) => v.id == variant).episodeId, episode);
    final record = db.userState.playbackRecords.listAllWithTombstones().single;
    expect(record.workId, work);
    expect(record.episodeId, episode);
    expect(record.variantId, variant);
    expect(record.positionSeconds, 77);
    await service.restoreFromArchiveBytes(original);
    expect(db.userState.playbackRecords.listAllWithTombstones(), hasLength(1));
    db.library.mediaVariants.upsert(
      const MediaVariantRecord(
        id: VariantId.trusted('extra-local-version'),
        workId: work,
        episodeId: episode,
        sourceId: SourceId.trusted('new-old-src'),
        relativePath: 'Series/other.mkv',
        fileName: 'other.mkv',
        fileSize: 999,
      ),
    );
    await expectLater(
      service.restoreFromArchiveBytes(original),
      throwsFormatException,
    );
    expect(db.library.mediaVariants.listByWork(work), hasLength(5));
    expect(
      db.userState.playbackRecords
          .listAllWithTombstones()
          .single
          .positionSeconds,
      77,
    );
  });

  test('v2 强身份分散至多个本机作品时拒绝，不按标题或任意候选合并', () async {
    final db = KonataDatabaseBundle.openInMemory();
    addTearDown(db.close);
    db.library.works.upsert(
      const WorkRecord(
        id: WorkId.trusted('tmdb-local'),
        title: 'TMDB 作品',
        tmdbId: 100565,
        tmdbMediaType: TmdbMediaType.tv,
        matchedSeason: 1,
        metadataLocked: true,
      ),
    );
    db.library.works.upsert(
      const WorkRecord(
        id: WorkId.trusted('bgm-local'),
        title: 'Bangumi 作品',
        bangumiId: 293049,
        metadataLocked: true,
      ),
    );
    final service = _service(db);
    final bytes = await _fixture(2);
    await expectLater(
      service.previewRestore(bytes),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('多个候选身份'),
        ),
      ),
    );
    await expectLater(
      service.restoreFromArchiveBytes(bytes),
      throwsFormatException,
    );
    expect(db.library.works.listVisible(), hasLength(2));
    expect(db.userState.playbackRecords.listAllWithTombstones(), isEmpty);
  });

  test('v2 同源文件路径碰撞或已编辑目录实体不会被重复恢复覆盖', () async {
    final bytes = await _fixture(2);
    final db = KonataDatabaseBundle.openInMemory();
    addTearDown(db.close);
    final service = _service(db);
    await service.restoreFromArchiveBytes(bytes);
    final work = db.library.works.listVisible().single;
    db.library.works.upsert(
      WorkRecord(
        id: work.id,
        title: '人工重新整理',
        tmdbId: work.tmdbId,
        tmdbMediaType: work.tmdbMediaType,
        matchedSeason: work.matchedSeason,
        bangumiId: work.bangumiId,
        metadataLocked: true,
      ),
    );
    await expectLater(
      service.restoreFromArchiveBytes(bytes),
      throwsFormatException,
    );
    expect(db.library.works.findById(work.id)?.title, '人工重新整理');
    expect(db.userState.playbackRecords.listAllWithTombstones(), hasLength(1));

    final other = KonataDatabaseBundle.openInMemory();
    addTearDown(other.close);
    const source = SourceId.trusted('local-dav');
    const otherWork = WorkId.trusted('different-work');
    other.library.mediaSources.upsert(
      const MediaSourceRecord(
        id: source,
        kind: MediaSourceKind.webdav,
        label: '本机源',
        location: 'https://fixture.example.invalid/dav',
      ),
    );
    other.library.works.upsert(
      const WorkRecord(
        id: otherWork,
        title: '其他归属',
        tmdbId: 999999,
        tmdbMediaType: TmdbMediaType.tv,
      ),
    );
    other.library.mediaVariants.upsert(
      const MediaVariantRecord(
        id: VariantId.trusted('different-file'),
        workId: otherWork,
        sourceId: source,
        relativePath: 'Series/01.mkv',
        fileName: '01.mkv',
        fileSize: 1024,
        mappingLocked: true,
      ),
    );
    await expectLater(
      _service(other).restoreFromArchiveBytes(bytes),
      throwsFormatException,
    );
    expect(other.library.works.listVisible(), hasLength(1));
    expect(
      other.library.mediaVariants.listByWork(otherWork).single.mappingLocked,
      isTrue,
    );
    expect(other.userState.playbackRecords.listAllWithTombstones(), isEmpty);
  });

  test('v2 非空目标存在作品身份或媒体源地址冲突时整份拒绝', () async {
    final bytes = await _fixture(2);
    for (final kind in ['work', 'source', 'id']) {
      final db = KonataDatabaseBundle.openInMemory();
      addTearDown(db.close);
      if (kind == 'work') {
        _seedV1(db);
      } else {
        db.library.mediaSources.upsert(
          MediaSourceRecord(
            id: SourceId.trusted(kind == 'id' ? 'old-src' : 'different-id'),
            kind: MediaSourceKind.webdav,
            label: '已有源',
            username: kind == 'source' ? 'different-account' : null,
            location: kind == 'source'
                ? 'https://fixture.example.invalid/dav'
                : 'https://other.example.invalid/dav',
          ),
        );
      }
      final prefs = ScopedPrefsStore(db.userState);
      prefs.write(_appearance, {'themeMode': 'dark'}, updatedAtMs: 100);
      final service = _service(db);
      await expectLater(service.previewRestore(bytes), throwsFormatException);
      await expectLater(
        service.restoreFromArchiveBytes(bytes),
        throwsFormatException,
      );
      expect(db.library.works.listVisible(), hasLength(kind == 'work' ? 1 : 0));
      expect(db.userState.playbackRecords.listAllWithTombstones(), isEmpty);
      expect(prefs.read(_appearance), {'themeMode': 'dark'});
    }
  });

  test('v1 通过唯一逻辑身份恢复至不同物理ID，重复合并不增加记录', () async {
    final db = KonataDatabaseBundle.openInMemory();
    addTearDown(db.close);
    _seedV1(db);
    final service = _service(db);
    for (final ext in ['json', 'konata']) {
      final bytes = await _fixture(1, ext);
      expect((await service.previewRestore(bytes)).legacyFormatVersion, 1);
      await service.restoreFromArchiveBytes(bytes);
    }
    final history = db.userState.playbackRecords.listAllWithTombstones().single;
    expect(history.positionSeconds, 42);
    expect(history.workId.value, 'local-work');
    expect(history.episodeId.value, 'local-ep');
    expect(history.variantId.value, 'local-video');
  });

  for (final version in [1, 2]) {
    test('v$version 旧备份按唯一曲名恢复普通音频断点与原曲目编号', () async {
      final root = await Directory.systemTemp.createTemp(
        'konata-legacy-audio-',
      );
      addTearDown(() => root.delete(recursive: true));
      final storage = PortableStorageRootService(overrideRootPath: root.path);
      final db = await KonataDatabaseBundle.openFromStorageRoot(storage);
      try {
        if (version == 1) {
          _seedV1(db);
          db.library.mediaVariants.upsert(
            const MediaVariantRecord(
              id: VariantId.trusted('local-cd'),
              workId: WorkId.trusted('local-work'),
              sourceId: SourceId.trusted('local-source'),
              relativePath: 'CD/01.flac',
              fileName: '01.flac',
              fileSize: 512,
              assetKind: AssetKind.cdAlbum,
            ),
          );
        }
        final service = _service(db);
        final bytes = await _mutate(version, _addLegacyAudio);
        expect(
          (await service.previewRestore(bytes)).legacyFormatVersion,
          version,
        );
        expect(db.userState.playbackRecords.listAllWithTombstones(), isEmpty);
        await service.restoreFromArchiveBytes(bytes);
        if (version == 1) await service.restoreFromArchiveBytes(bytes);
      } finally {
        await db.close();
      }

      final reopened = await KonataDatabaseBundle.openFromStorageRoot(storage);
      addTearDown(reopened.close);
      final prefix = version == 1 ? 'local' : 'old';
      final records = reopened.userState.playbackRecords
          .listAllWithTombstones();
      expect(records, hasLength(2));
      final audio = records.singleWhere(
        (record) => record.episodeId.value == 'cd::$prefix-cd',
      );
      expect(audio.id, 'cd::$prefix-work::$prefix-cd');
      expect(audio.variantId.value, '$prefix-cd');
      expect(audio.canonicalKey, 'playback::tmdb:tv:100565:s1::audio::01::t7');
      expect(audio.positionSeconds, 12);
      expect(audio.episodeNumber, 7);
      expect(
        records.singleWhere((record) => record != audio).positionSeconds,
        42,
      );
    });
  }

  test('旧 CUE 曲名与轨号唯一核验后恢复母轨断点，拒绝未索引和歧义清单', () async {
    final db = KonataDatabaseBundle.openInMemory();
    addTearDown(db.close);
    _seedV1(db);
    const work = WorkId.trusted('local-work');
    const source = SourceId.trusted('local-source');
    db.library.mediaVariants.upsert(
      const MediaVariantRecord(
        id: VariantId.trusted('local-album'),
        workId: work,
        sourceId: source,
        relativePath: 'CD/album.flac',
        fileName: 'album.flac',
        fileSize: 100,
        assetKind: AssetKind.cdAlbum,
      ),
    );
    db.library.mediaVariants.upsert(
      const MediaVariantRecord(
        id: VariantId.trusted('local-cue'),
        workId: work,
        sourceId: source,
        relativePath: 'CD/album.cue',
        fileName: 'album.cue',
        fileSize: 100,
        assetKind: AssetKind.cdAlbum,
      ),
    );
    final bytes = await _mutate(1, (payload) {
      _addLegacyAudio(payload);
      final audio =
          (payload['playbackEntries'] as List).last as Map<String, Object?>;
      audio['episodeTitle'] = 'Second';
      audio['playbackKey'] = 'playback::tmdb:tv:100565:s1::audio::second';
      audio['episodeNumber'] = 2;
    });
    final noReader = _service(db);
    await expectLater(noReader.previewRestore(bytes), throwsFormatException);
    var reads = 0;
    var tracks = <LegacyCueTrack>[
      (number: 1, title: 'First', fileName: 'album.flac'),
      (number: 2, title: 'Second', fileName: 'album.flac'),
    ];
    final service = KonataBackupService(
      databases: db,
      scopedPrefs: ScopedPrefsStore(db.userState),
      deviceStore: SyncDeviceStore(db.userState.syncMeta),
      readLegacyCue: (id) async {
        expect(id, 'local-cue');
        reads++;
        return tracks;
      },
    );
    await service.previewRestore(bytes);
    expect(reads, 1);
    expect(db.userState.playbackRecords.listAllWithTombstones(), isEmpty);
    await service.restoreFromArchiveBytes(bytes);
    expect(reads, 2);
    final audio = db.userState.playbackRecords
        .listAllWithTombstones()
        .singleWhere((r) => r.episodeId.value.startsWith('cd::'));
    expect(audio.id, 'cd::local-work::local-album#cue:2');
    expect(audio.episodeId.value, 'cd::local-album#cue:2');
    expect(audio.variantId.value, 'local-album');
    expect(audio.positionSeconds, 12);
    expect(audio.episodeNumber, 2);
    await service.restoreFromArchiveBytes(bytes);
    expect(db.userState.playbackRecords.listAllWithTombstones(), hasLength(2));
    tracks = [(number: 2, title: 'Second', fileName: '../album.flac')];
    await expectLater(
      service.restoreFromArchiveBytes(bytes),
      throwsFormatException,
    );
    tracks = [(number: 2, title: 'Second', fileName: 'missing.flac')];
    await expectLater(
      service.restoreFromArchiveBytes(bytes),
      throwsFormatException,
    );
    tracks = [
      (number: 2, title: 'Second', fileName: 'album.flac'),
      (number: 2, title: 'Second', fileName: 'album.flac'),
    ];
    await expectLater(
      service.restoreFromArchiveBytes(bytes),
      throwsFormatException,
    );
    expect(db.userState.playbackRecords.listAllWithTombstones(), hasLength(2));
  });

  test('旧音频遇到同名文件或 CUE 清单时拒绝整份归档', () async {
    for (final (fileName, errorText) in [
      ('01.flac', '无法按曲名唯一关联可播放文件'),
      ('另一张专辑.cue', '归档无法区分普通曲目与分轨'),
    ]) {
      final db = KonataDatabaseBundle.openInMemory();
      try {
        final bytes = await _mutate(2, (payload) {
          _addLegacyAudio(payload);
          final catalog = payload['libraryCatalog']! as Map<String, Object?>;
          final variants = (catalog['variants']! as List<Object?>)
              .cast<Map<String, Object?>>();
          final cd = variants.singleWhere(
            (variant) => variant['id'] == 'old-cd',
          );
          variants.add({
            ...cd,
            'id': 'other-cd',
            'relativePath': 'CD2/$fileName',
            'fileName': fileName,
          });
        });
        final service = _service(db);
        final rejects = throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            '原因',
            contains(errorText),
          ),
        );
        await expectLater(service.previewRestore(bytes), rejects);
        await expectLater(service.restoreFromArchiveBytes(bytes), rejects);
        expect(db.library.works.listVisible(), isEmpty);
        expect(db.userState.playbackRecords.listAllWithTombstones(), isEmpty);
        expect(ScopedPrefsStore(db.userState).read(_appearance), isEmpty);
      } finally {
        await db.close();
      }
    }
  });

  test('旧归档音频墓碑借助同归档记录，按更新时间裁决', () async {
    for (final (includeAudio, deletedAt, expectedDeletedAt) in [
      (true, 1700000000001, 1700000000001),
      (true, 1699999999999, null),
      (false, 1700000000001, null),
    ]) {
      final db = KonataDatabaseBundle.openInMemory();
      try {
        final bytes = await _mutate(2, (payload) {
          if (includeAudio) _addLegacyAudio(payload);
          (payload['tombstones']! as List<Object?>).add({
            'entityKey': 'playback::tmdb:tv:100565:s1::audio::01',
            'entityType': 'playback',
            'deletedAtMs': deletedAt,
            'deviceId': 'legacy-delete',
          });
        });
        final service = _service(db);
        if (!includeAudio) {
          await expectLater(
            service.restoreFromArchiveBytes(bytes),
            throwsFormatException,
          );
          expect(db.library.works.listVisible(), isEmpty);
          expect(db.userState.playbackRecords.listAllWithTombstones(), isEmpty);
          continue;
        }
        await service.restoreFromArchiveBytes(bytes);
        final records = db.userState.playbackRecords.listAllWithTombstones();
        final audio = records.singleWhere(
          (record) => record.episodeId.value == 'cd::old-cd',
        );
        expect(audio.deletedAtMs, expectedDeletedAt);
        expect(audio.episodeNumber, 7);
        expect(
          records.singleWhere((record) => record != audio).deletedAtMs,
          isNull,
        );
      } finally {
        await db.close();
      }
    }
  });

  test('篡改、未知偏好、墓碑、旧音频、路径穿越、未知目录字段与隐藏语义拒绝', () async {
    final db = KonataDatabaseBundle.openInMemory();
    addTearDown(db.close);
    final service = _service(db);
    final cases = <Uint8List>[
      await _mutate(
        2,
        (p) => (p['playbackEntries']! as List).clear(),
        rehash: false,
      ),
      await _mutate(
        2,
        (p) =>
            ((p['preferences']! as Map<String, Object?>)['values']!
                    as Map<String, Object?>)['unknown_pref'] =
                true,
      ),
      await _mutate(
        2,
        (p) => (p['tombstones']! as List).add({
          'entityKey': 'test',
          'entityType': 'playback',
          'deletedAtMs': 1700000000000,
          'deviceId': 'old',
        }),
      ),
      await _mutate(
        2,
        (p) =>
            ((p['playbackEntries']! as List).first
                    as Map<String, Object?>)['isAudio'] =
                true,
      ),
      await _mutate(
        2,
        (p) =>
            (((p['libraryCatalog']! as Map<String, Object?>)['variants']!
                            as List)
                        .first
                    as Map<String, Object?>)['relativePath'] =
                '../outside.mkv',
      ),
      await _mutate(
        2,
        (p) =>
            (((p['libraryCatalog']! as Map<String, Object?>)['works']! as List)
                        .first
                    as Map<String, Object?>)['futureField'] =
                'unsupported',
      ),
      await _mutate(
        2,
        (p) =>
            (((p['libraryCatalog']! as Map<String, Object?>)['works']! as List)
                        .first
                    as Map<String, Object?>)['isHidden'] =
                true,
      ),
      await _mutate(
        2,
        (p) =>
            (((p['libraryCatalog']! as Map<String, Object?>)['works']! as List)
                        .first
                    as Map<String, Object?>)['posterPath'] =
                'D:/private/custom.jpg',
      ),
    ];
    for (final bytes in cases) {
      await expectLater(service.previewRestore(bytes), throwsFormatException);
      await expectLater(
        service.restoreFromArchiveBytes(bytes),
        throwsFormatException,
      );
      expect(db.library.works.listVisible(), isEmpty);
      expect(db.userState.playbackRecords.listAllWithTombstones(), isEmpty);
      expect(ScopedPrefsStore(db.userState).read(_appearance), isEmpty);
    }
  });

  test('旧视频墓碑在无历史与有历史目标均正确落盘，旧进度不复活，新进度可恢复', () async {
    for (final seedHistory in [false, true]) {
      final db = KonataDatabaseBundle.openInMemory();
      try {
        _seedV1(db);
        final service = _service(db);
        final active = await _fixture(1);
        if (seedHistory) await service.restoreFromArchiveBytes(active);
        const deletedAt = 1700000000001;
        final tombstone = await _mutate(1, (p) {
          (p['playbackEntries']! as List).clear();
          (p['tombstones']! as List).add({
            'entityKey': 'playback::tmdb:tv:100565:s1::s1::e1',
            'entityType': 'playback',
            'deletedAtMs': deletedAt,
            'deviceId': 'legacy-delete',
          });
        });
        final preview = await service.previewRestore(tombstone);
        expect(preview.totalDeletes, seedHistory ? 1 : 0);
        await service.restoreFromArchiveBytes(tombstone);
        await service.restoreFromArchiveBytes(tombstone);
        var record = db.userState.playbackRecords
            .listAllWithTombstones()
            .single;
        expect(record.deletedAtMs, deletedAt);
        expect(record.variantId.value, 'local-video');
        await service.restoreFromArchiveBytes(active);
        expect(
          db.userState.playbackRecords
              .listAllWithTombstones()
              .single
              .deletedAtMs,
          deletedAt,
        );
        final newer = await _mutate(1, (p) {
          final row =
              (p['playbackEntries']! as List).first as Map<String, Object?>;
          row['updatedAtMs'] = deletedAt + 1;
          row['playedAtMs'] = deletedAt + 1;
          row['positionSeconds'] = 55;
        });
        await service.restoreFromArchiveBytes(newer);
        record = db.userState.playbackRecords.listAllWithTombstones().single;
        expect(record.deletedAtMs, isNull);
        expect(record.positionSeconds, 55);
        await service.restoreFromArchiveBytes(tombstone);
        expect(
          db.userState.playbackRecords
              .listAllWithTombstones()
              .single
              .deletedAtMs,
          isNull,
        );
      } finally {
        await db.close();
      }
    }
  });

  test('v2 同一备份内活跃记录与墓碑按时间裁决，未知墓碑类型拒绝', () async {
    final db = KonataDatabaseBundle.openInMemory();
    addTearDown(db.close);
    final service = _service(db);
    final unsupported = await _mutate(2, (p) {
      (p['tombstones']! as List).add({
        'entityKey': 'series::old-series',
        'entityType': 'series',
        'deletedAtMs': 1700000000001,
        'deviceId': 'legacy-delete',
      });
    });
    await expectLater(
      service.restoreFromArchiveBytes(unsupported),
      throwsFormatException,
    );
    final bytes = await _mutate(2, (p) {
      (p['tombstones']! as List).add({
        'entityKey': 'playback::tmdb:tv:100565:s1::s1::e1',
        'entityType': 'playback',
        'deletedAtMs': 1700000000001,
        'deviceId': 'legacy-delete',
      });
    });
    await service.restoreFromArchiveBytes(bytes);
    expect(db.library.works.listVisible(), hasLength(1));
    final record = db.userState.playbackRecords.listAllWithTombstones().single;
    expect(record.deletedAtMs, 1700000000001);
    expect(record.variantId.value, 'old-video');
  });

  test('v2 作品墓碑晚于作品时删除作品并跳过其播放记录，较早墓碑保留作品', () async {
    for (final key in ['work_id::old-work', 'work_catalog::bgm:293049']) {
      final db = KonataDatabaseBundle.openInMemory();
      try {
        final bytes = await _mutate(2, (p) {
          (p['tombstones']! as List).add({
            'entityKey': key,
            'entityType': 'work_catalog',
            'deletedAtMs': 1700000000001,
            'deviceId': 'legacy-delete',
          });
        });
        await _service(db).restoreFromArchiveBytes(bytes);
        expect(db.library.works.listVisible(), isEmpty, reason: key);
        final work = db.library.works.listAllWithTombstones().single;
        expect(work.deletedAtMs, 1700000000001);
        final episodes = db.library.episodes.listByWork(
          work.id,
          includeDeleted: true,
        );
        final variants = db.library.mediaVariants.listByWork(
          work.id,
          includeDeleted: true,
        );
        expect(episodes, hasLength(2));
        expect(variants, hasLength(4));
        expect(
          episodes.map((row) => row.deletedAtMs),
          everyElement(1700000000001),
        );
        expect(
          variants.map((row) => row.deletedAtMs),
          everyElement(1700000000001),
        );
        expect(
          db.userState.playbackRecords.listAllWithTombstones().where(
            (r) => r.deletedAtMs == null,
          ),
          isEmpty,
          reason: key,
        );
      } finally {
        await db.close();
      }
    }

    final db = KonataDatabaseBundle.openInMemory();
    addTearDown(db.close);
    final older = await _mutate(2, (p) {
      (p['tombstones']! as List).add({
        'entityKey': 'work_catalog::tmdb:tv:100565:s1',
        'entityType': 'work_catalog',
        'deletedAtMs': 1699999999999,
        'deviceId': 'legacy-delete',
      });
    });
    await _service(db).restoreFromArchiveBytes(older);
    expect(db.library.works.listVisible(), hasLength(1));
    expect(db.userState.playbackRecords.listAllWithTombstones(), hasLength(1));
  });

  test('v2 缺少对应实体的作品墓碑拒绝，目标库保持空库', () async {
    final db = KonataDatabaseBundle.openInMemory();
    addTearDown(db.close);
    final bytes = await _mutate(2, (p) {
      (p['tombstones']! as List).add({
        'entityKey': 'work_id::absent-work',
        'entityType': 'work_catalog',
        'deletedAtMs': 1700000000001,
        'deviceId': 'legacy-delete',
      });
    });
    await expectLater(
      _service(db).restoreFromArchiveBytes(bytes),
      throwsFormatException,
    );
    expect(db.library.works.listAllWithTombstones(), isEmpty);
    expect(db.userState.playbackRecords.listAllWithTombstones(), isEmpty);
  });

  test('v2 整理状态墓碑裁决不清除完整目录内的资料锁', () async {
    for (final newer in [true, false]) {
      final db = KonataDatabaseBundle.openInMemory();
      try {
        final bytes = await _mutate(2, (p) {
          final row = (p['workOverrides']! as List).single as Map;
          row['title'] = '已过期的整理状态';
          (p['tombstones']! as List).add({
            'entityKey': 'work_override::tmdb:tv:100565:s1',
            'entityType': 'work_override',
            'deletedAtMs': newer ? 1700000000001 : 1699999999999,
            'deviceId': 'legacy-delete',
          });
        });
        if (newer) {
          await _service(db).restoreFromArchiveBytes(bytes);
          final work = db.library.works.listVisible().single;
          expect(work.title, '合成作品');
          expect(work.metadataLocked, isTrue);
        } else {
          await expectLater(
            _service(db).restoreFromArchiveBytes(bytes),
            throwsFormatException,
          );
          expect(db.library.works.listAllWithTombstones(), isEmpty);
        }
      } finally {
        await db.close();
      }
    }
  });

  test('v1 作品墓碑缺少完整目录时拒绝', () async {
    final db = KonataDatabaseBundle.openInMemory();
    addTearDown(db.close);
    _seedV1(db);
    final bytes = await _mutate(1, (p) {
      (p['tombstones']! as List).add({
        'entityKey': 'work_id::local-work',
        'entityType': 'work_catalog',
        'deletedAtMs': 1700000000001,
        'deviceId': 'legacy-delete',
      });
    });
    await expectLater(
      _service(db).restoreFromArchiveBytes(bytes),
      throwsFormatException,
    );
    expect(db.library.works.listVisible(), hasLength(1));
  });

  test('v1 未匹配与歧义物理版本拒绝，现有库保持不变', () async {
    final db = KonataDatabaseBundle.openInMemory();
    addTearDown(db.close);
    final bytes = await _fixture(1);
    final service = _service(db);
    await expectLater(
      service.restoreFromArchiveBytes(bytes),
      throwsFormatException,
    );
    _seedV1(db);
    db.library.mediaVariants.upsert(
      const MediaVariantRecord(
        id: VariantId.trusted('second-video'),
        workId: WorkId.trusted('local-work'),
        episodeId: EpisodeId.trusted('local-ep'),
        sourceId: SourceId.trusted('local-source'),
        relativePath: '01-alt.mkv',
        fileName: '01-alt.mkv',
        fileSize: 1024,
      ),
    );
    await expectLater(service.previewRestore(bytes), throwsFormatException);
    await expectLater(
      service.restoreFromArchiveBytes(bytes),
      throwsFormatException,
    );
    expect(db.library.works.listVisible(), hasLength(1));
    expect(db.userState.playbackRecords.listAllWithTombstones(), isEmpty);
  });
}
