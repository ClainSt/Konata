import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:engine_sources/engine_sources.dart';
import 'package:konata_contracts/konata_contracts.dart';

import 'library_catalog_sync_slice.dart';
import 'playback_history_sync_slice.dart';
import 'prefs_sync_slice.dart';
import 'sync_models.dart';

/// 将可无损识别的旧版快照转换为新版归档，不读写数据库或媒体文件。
/// 未覆盖的语义一律阻止转换；目录迁移仅允许空目标目录。
final class LegacyBackupMigration {
  const LegacyBackupMigration._();

  /// 判断是否为旧版快照信封，而非新版分片归档。
  static bool isLegacy(Object? decoded) =>
      decoded is Map && decoded['schema'] == 'konata.sync.snapshot.v1';

  /// 完整校验旧快照并构造独立的新版归档。
  static KonataBackupArchive convert(
    Object? decoded, {
    required Map<String, Object?> localCatalog,
  }) {
    final root = _object(decoded, '信封');
    final version = root['formatVersion'];
    if (!isLegacy(root) || (version != 1 && version != 2) || version is! int) {
      _fail('协议版本不支持');
    }
    final payload = _object(root['payload'], '载荷');
    final expected = root['payloadSha256'];
    // 黄金源采用保留字段顺序的 JSON 摘要，不使用新版的键排序算法。
    if (expected !=
        sha256.convert(utf8.encode(jsonEncode(payload))).toString()) {
      _fail('旧版 SHA-256 校验失败');
    }
    _onlyKeys(payload, {
      'playbackEntries',
      'workOverrides',
      'tombstones',
      'preferences',
      'libraryCatalog',
    }, '载荷');
    final device = _string(root['deviceId'], '设备标识');
    final exportedAt = _integer(root['exportedAtMs'], '导出时间');
    final slices = <SyncSlicePayload>[];
    void add(String id, Map<String, Object?> data) => slices.add(
      SyncSlicePayload(
        sliceId: id,
        schemaVersion: 1,
        exportedAtMs: exportedAt,
        sourceDeviceId: device,
        data: data,
      ),
    );

    final tombstones = _rows(payload['tombstones'], '删除墓碑');
    final overrides = _rows(payload['workOverrides'], '整理状态');
    final playbacks = _rows(payload['playbackEntries'], '播放记录');
    final prefs = _object(payload['preferences'], '偏好');
    _onlyKeys(prefs, {'updatedAtMs', 'values'}, '偏好');
    final values = _object(prefs['values'], '偏好值');
    if (values.isNotEmpty) {
      const keys = {
        'konata_v2_theme_mode',
        'konata_v2_window_material',
        'konata_v2_ambient_canvas_enabled',
      };
      if (values.length != keys.length ||
          !values.keys.every(keys.contains) ||
          !{
            'dark',
            'light',
            'system',
          }.contains(values['konata_v2_theme_mode']) ||
          !{
            'acrylic',
            'mica',
            'tabbed',
          }.contains(values['konata_v2_window_material']) ||
          values['konata_v2_ambient_canvas_enabled'] is! bool) {
        _fail('旧偏好含未映射项目或外观设置不完整，不能安全覆盖同一设置域');
      }
      add(PrefsSyncSlice.id, {
        'entries': [
          {
            'namespace': 'feature_settings.appearance',
            'schemaVersion': 1,
            'payload': {
              'themeMode': values['konata_v2_theme_mode'],
              'windowMaterial': values['konata_v2_window_material'],
              'ambientBackdropEnabled':
                  values['konata_v2_ambient_canvas_enabled'],
            },
            'updatedAtMs': _integer(prefs['updatedAtMs'], '偏好时间'),
            'sourceDeviceId': device,
          },
        ],
      });
    }

    final Map<String, Object?> catalog;
    if (version == 2) {
      if (_catalogKeys.any((key) => _rows(localCatalog[key], key).isNotEmpty)) {
        _fail('完整目录迁移仅允许空目标媒体库，请在独立空库中恢复');
      }
      catalog = _convertCatalog(
        _object(payload['libraryCatalog'], '完整目录'),
        device,
      );
      add(LibraryCatalogSyncSlice.id, catalog);
      _checkMirroredOverrides(overrides, catalog);
    } else {
      if (payload.containsKey('libraryCatalog')) _fail('v1 信封不应含完整目录');
      if (overrides.isNotEmpty) _fail('v1 整理状态缺少完整目录，尚不能安全转换');
      catalog = localCatalog;
    }

    if (playbacks.isNotEmpty || tombstones.isNotEmpty) {
      final active = _convertPlaybacks(playbacks, catalog, device);
      add(PlaybackHistorySyncSlice.id, {
        'records': _mergePlaybackTombstones(
          active,
          tombstones,
          catalog,
          device,
        ),
      });
    }
    if (slices.isEmpty) _fail('旧文件没有可恢复的有效数据');
    return KonataBackupArchive.create(
      exportedAtMs: exportedAt,
      deviceId: device,
      deviceName: _string(root['deviceName'], '设备名称', allowEmpty: true),
      platform: _string(root['platform'], '平台', allowEmpty: true),
      appVersion: _string(root['appVersion'], '应用版本', allowEmpty: true),
      slicePayloads: slices,
    );
  }

  static const _catalogKeys = [
    'mediaSources',
    'seriesGroups',
    'works',
    'episodes',
    'variants',
    'ignoredFolders',
  ];

  static Map<String, Object?> _convertCatalog(
    Map<String, Object?> raw,
    String device,
  ) {
    _onlyKeys(raw, _catalogKeys.toSet(), '完整目录');
    final result = <String, Object?>{};
    final ids = <String, Set<String>>{};
    final aliases = <String>{};
    final locations = <String>{};
    final slots = <String>{};
    final paths = <String>{};
    final seriesTitles = <String>{};
    final collections = <Object?>{};
    final episodeOwners = <String, Object?>{};
    for (final key in _catalogKeys) {
      final converted = <Map<String, Object?>>[];
      ids[key] = <String>{};
      for (final row in _rows(raw[key], key)) {
        final item = <String, Object?>{...row};
        if (item.containsKey('deletedAtMs')) _fail('目录中存在未支持的删除标记');
        item.putIfAbsent('sourceDeviceId', () => device);
        item.putIfAbsent('updatedAtMs', () => 0);
        Map<String, Object?>? normalized;
        switch (key) {
          case 'mediaSources':
            final source = SyncLibrarySourceItem.tryFromJson(item);
            if (source == null || source.kind == MediaSourceKind.cloudDrive) {
              _fail('媒体源类型或地址不能转换');
            }
            final checked = SourceLocationValidator.validate(
              source.kind,
              source.location,
            );
            if (!checked.isValid) _fail('媒体源地址无效');
            if (source.kind != MediaSourceKind.local) {
              final uri = Uri.tryParse(source.location);
              if (uri == null ||
                  uri.userInfo.isNotEmpty ||
                  uri.hasQuery ||
                  uri.hasFragment) {
                _fail('媒体源地址含凭据或额外参数');
              }
            }
            if (!locations.add(source.normalizedLocationKey)) _fail('媒体源地址重复');
            normalized = source.toJson();
          case 'seriesGroups':
            final group = SyncLibrarySeriesItem.tryFromJson(item);
            if (group == null) _fail('系列标识无效');
            final title = SyncSanitizer.normalizeTitleKey(group.title);
            if (title.isEmpty ||
                !seriesTitles.add(title) ||
                (group.tmdbCollectionId != null &&
                    !collections.add(group.tmdbCollectionId))) {
              _fail('系列标识或标题重复');
            }
            normalized = group.toJson();
          case 'works':
            for (final field in ['isHidden', 'keepHidden']) {
              if (item.remove(field) == true) _fail('旧作品存在已移除的隐藏语义');
            }
            for (final slot in ['poster', 'backdrop', 'logo']) {
              final path = item.remove('${slot}Path');
              final locked = item.remove('${slot}Locked') ?? false;
              if (locked is! bool) _fail('艺术图锁定状态无效');
              if (path != null) {
                item['${slot}Ref'] = _artwork(path, locked);
              } else if (locked) {
                _fail('艺术图锁定缺少可移植引用');
              }
            }
            final work = SyncLibraryWorkItem.tryFromJson(item);
            if (work == null ||
                work.title.trim().isEmpty ||
                work.canonicalWorkKey.isEmpty) {
              _fail('作品身份无效');
            }
            if (work.seriesId != null &&
                !ids['seriesGroups']!.contains(work.seriesId)) {
              _fail('作品关联的系列不存在');
            }
            for (final alias in work.allWorkKeys.toSet()) {
              if (!aliases.add(alias)) _fail('多个作品共享同一身份，需人工复核');
            }
            normalized = work.toJson();
          case 'episodes':
            final episode = SyncLibraryEpisodeItem.tryFromJson(item);
            if (episode == null || !ids['works']!.contains(episode.workId)) {
              _fail('分集所属作品不存在');
            }
            final slot =
                episode.category == EpisodeCategory.main &&
                    episode.episodeNumber != null
                ? '${episode.workId}::main::${episode.seasonNumber}::${episode.episodeNumber}::${episode.episodeNumberEnd}'
                : '${episode.workId}::${episode.category.name}::${episode.extraType?.name}::${episode.episodeNumber}::${SyncSanitizer.normalizeTitleKey(episode.title ?? '')}';
            if (!slots.add(slot)) _fail('逻辑分集重复');
            episodeOwners[episode.id] = episode.workId;
            normalized = episode.toJson();
          case 'variants':
            final relative = _relative(item['relativePath']);
            item['relativePath'] = relative;
            for (final subtitle
                in item['externalSubtitles'] == null
                    ? <Object?>[]
                    : _list(item['externalSubtitles'], '外挂字幕')) {
              _relative(subtitle);
            }
            final variant = SyncLibraryVariantItem.tryFromJson(item);
            if (variant == null ||
                !ids['works']!.contains(variant.workId) ||
                !ids['mediaSources']!.contains(variant.sourceId) ||
                (variant.episodeId != null &&
                    episodeOwners[variant.episodeId] != variant.workId)) {
              _fail('媒体版本的作品、分集或媒体源关联无效');
            }
            if (variant.fileName.isEmpty ||
                variant.fileSize < 0 ||
                !paths.add('${variant.sourceId}::${relative.toLowerCase()}')) {
              _fail('媒体版本路径或大小无效，或存在重复路径');
            }
            normalized = variant.toJson();
          case 'ignoredFolders':
            final source = _string(item['sourceId'], '忽略目录媒体源');
            if (!ids['mediaSources']!.contains(source)) _fail('忽略目录所属媒体源不存在');
            final relative = _relative(item['relativePath']);
            item['relativePath'] = relative;
            item['id'] = '$source::$relative';
            final folder = SyncLibraryIgnoredFolderItem.tryFromJson(item);
            if (folder == null) _fail('忽略目录无效');
            normalized = folder.toJson();
          default:
            _fail('未知目录分类');
        }
        // 利用新版强类型序列化验证字段是否真正保留，避免默认值吞掉未知数据。
        for (final entry in item.entries) {
          if (SyncSanitizer.canonicalJsonEncode(normalized[entry.key]) !=
              SyncSanitizer.canonicalJsonEncode(entry.value)) {
            _fail('目录 $key 中字段 ${entry.key} 无法无损转换');
          }
        }
        final id = _string(normalized['id'], '目录标识');
        if (!ids[key]!.add(id)) _fail('目录 $key 存在重复主键');
        converted.add(normalized);
      }
      result[key] = converted;
    }
    if (_catalogKeys.every((k) => _rows(result[k], k).isEmpty)) {
      _fail('v2 完整目录为空');
    }
    return result;
  }

  static Map<String, Object?> _artwork(Object? raw, bool locked) {
    final path = _string(raw, '艺术图引用');
    ArtworkSource? source;
    if (RegExp(
      r'^/[A-Za-z0-9_-]+\.(jpg|jpeg|png|webp)$',
      caseSensitive: false,
    ).hasMatch(path)) {
      source = ArtworkSource.tmdb;
    } else {
      final uri = Uri.tryParse(path);
      if (uri != null &&
          uri.scheme == 'https' &&
          uri.userInfo.isEmpty &&
          !uri.hasQuery &&
          !uri.hasFragment &&
          !uri.hasPort) {
        if (uri.host == 'image.tmdb.org') source = ArtworkSource.tmdb;
        if ([
          'lain.bgm.tv',
          'bgm.tv',
          'bangumi.tv',
          'images.bgm.tv',
        ].contains(uri.host)) {
          source = ArtworkSource.bangumi;
        }
        if (['assets.fanart.tv', 'fanart.tv'].contains(uri.host)) {
          source = ArtworkSource.fanart;
        }
      }
    }
    if (source == null) _fail('艺术图来源不明确或为本机路径');
    return RemoteArtworkRef(
      source: source,
      uri: path,
      locked: locked,
    ).toLocalJson();
  }

  static void _checkMirroredOverrides(
    List<Map<String, Object?>> overrides,
    Map<String, Object?> catalog,
  ) {
    final works = _rows(catalog['works'], '作品');
    final groups = _rows(catalog['seriesGroups'], '系列');
    for (final row in overrides) {
      final matched = works
          .where((w) => w['canonicalWorkKey'] == row['canonicalWorkKey'])
          .toList();
      if (matched.length != 1) _fail('整理状态无法唯一关联完整目录');
      final work = matched.single;
      for (final entry in row.entries) {
        final key = entry.key;
        if (['updatedAtMs', 'sourceDeviceId'].contains(key)) continue;
        Object? existing = work[key];
        if (key == 'seriesTitle') {
          final group = groups
              .where((g) => g['id'] == work['seriesId'])
              .toList();
          existing = group.length == 1 ? group.single['title'] : null;
        }
        if (existing == null &&
            entry.value == false &&
            [
              'isManualLocked',
              'metadataLocked',
              'seriesLocked',
              'isHidden',
              'keepHidden',
            ].contains(key)) {
          continue;
        }
        if (SyncSanitizer.canonicalJsonEncode(existing) !=
            SyncSanitizer.canonicalJsonEncode(entry.value)) {
          _fail('整理状态字段 $key 与完整目录不一致');
        }
      }
    }
  }

  static List<Map<String, Object?>> _convertPlaybacks(
    List<Map<String, Object?>> rows,
    Map<String, Object?> catalog,
    String device,
  ) {
    final works = _rows(catalog['works'], '作品');
    final episodes = _rows(catalog['episodes'], '分集');
    final variants = _rows(catalog['variants'], '媒体版本');
    final sources = _rows(catalog['mediaSources'], '媒体源');
    final result = <Map<String, Object?>>[];
    final keys = <String>{};
    final targets = <String>{};
    for (final row in rows) {
      _onlyKeys(row, {
        'playbackKey',
        'canonicalWorkKey',
        'secondaryWorkKeys',
        'seasonNumber',
        'episodeNumber',
        'isAudio',
        'episodeTitle',
        'positionSeconds',
        'durationSeconds',
        'isCompleted',
        'playedAtMs',
        'updatedAtMs',
        'sourceDeviceId',
      }, '播放记录');
      final isAudio = row['isAudio'];
      if (isAudio is! bool) _fail('播放媒体类型无效');
      final primary = _string(row['canonicalWorkKey'], '播放作品身份');
      final rawSecondary = row['secondaryWorkKeys'] == null
          ? <Object?>[]
          : _list(row['secondaryWorkKeys'], '辅助身份');
      final aliases = {
        primary,
        for (final key in rawSecondary) _string(key, '辅助身份'),
      };
      final matches = works.where((w) {
        if (w['deletedAtMs'] != null) return false;
        return aliases.contains(w['canonicalWorkKey']) ||
            (w['secondaryWorkKeys'] is List &&
                (w['secondaryWorkKeys']! as List).any(aliases.contains));
      }).toList();
      if (matches.length != 1) _fail('播放记录无法唯一关联作品');
      final work = matches.single;
      final season = _integer(row['seasonNumber'], '季号');
      final number = row['episodeNumber'] == null
          ? null
          : _integer(row['episodeNumber'], '集号');
      final title = _string(row['episodeTitle'], '播放标题', allowEmpty: true);
      final workVariants = variants.where(
        (v) => v['workId'] == work['id'] && v['deletedAtMs'] == null,
      );
      final workId = _string(work['id'], '作品标识');
      final Map<String, Object?> variant;
      final String epId;
      final String id;
      if (isAudio) {
        variant = _resolvePlainAudio(workVariants, title);
        final variantId = _string(variant['id'], '物理版本');
        epId = 'cd::$variantId';
        id = 'cd::$workId::$variantId';
      } else {
        final eps = episodes
            .where(
              (e) =>
                  e['workId'] == workId &&
                  e['deletedAtMs'] == null &&
                  e['seasonNumber'] == season &&
                  e['episodeNumber'] == number,
            )
            .toList();
        if (eps.length != 1 || eps.single['category'] != 'main') {
          _fail('播放记录无法唯一关联正片分集');
        }
        final ep = eps.single;
        final candidates = workVariants
            .where((v) => v['episodeId'] == ep['id'])
            .toList();
        if (candidates.length != 1 ||
            candidates.single['assetKind'] != 'video') {
          _fail('播放记录无法唯一关联物理视频版本');
        }
        variant = candidates.single;
        epId = _string(ep['id'], '分集标识');
        id = '$workId::$epId';
      }
      final srcs = sources
          .where(
            (s) => s['id'] == variant['sourceId'] && s['deletedAtMs'] == null,
          )
          .toList();
      if (srcs.length != 1) _fail('播放记录媒体源不存在');
      final kind = MediaSourceKind.values
          .where((k) => k.name == srcs.single['kind'])
          .singleOrNull;
      if (kind == null) _fail('播放来源无效');
      final legacyKey = SyncSanitizer.buildPlaybackKey(
        canonicalWorkKey: primary,
        seasonNumber: season,
        episodeNumber: isAudio ? null : number,
        isAudio: isAudio,
        audioTrackHint: isAudio ? title : null,
      );
      if (legacyKey != row['playbackKey'] || !keys.add(legacyKey)) {
        _fail('旧播放逻辑键无效或重复');
      }
      if (!targets.add(id)) _fail('多个旧播放记录指向同一播放条目');
      final pos = _integer(row['positionSeconds'], '播放位置');
      final duration = _integer(row['durationSeconds'], '播放时长');
      if (row['isCompleted'] is! bool) _fail('播放完成状态无效');
      result.add(
        SyncPlaybackHistoryItem(
          id: id,
          playbackKey: SyncSanitizer.buildPlaybackKey(
            canonicalWorkKey: primary,
            seasonNumber: season,
            episodeNumber: number,
            isAudio: isAudio,
            audioTrackHint: isAudio ? title : null,
          ),
          canonicalWorkKey: primary,
          secondaryWorkKeys: aliases.where((k) => k != primary).toList(),
          workId: workId,
          episodeId: epId,
          variantId: _string(variant['id'], '物理版本'),
          seasonNumber: season,
          episodeNumber: number,
          isAudio: isAudio,
          episodeTitle: title,
          sourceKind: kind,
          playedAtMs: _integer(row['playedAtMs'], '播放时间'),
          positionSeconds: pos,
          durationSeconds: duration,
          isCompleted: row['isCompleted'] == true,
          updatedAtMs: _integer(row['updatedAtMs'], '播放更新时间'),
          sourceDeviceId: row['sourceDeviceId'] == null
              ? device
              : _string(row['sourceDeviceId'], '播放设备'),
        ).toJson(),
      );
    }
    return result;
  }

  static Map<String, Object?> _resolvePlainAudio(
    Iterable<Map<String, Object?>> workVariants,
    String title,
  ) {
    final titleKey = SyncSanitizer.normalizeTitleKey(title);
    if (titleKey.isEmpty) _fail('旧音频缺少可用于匹配的曲名');
    final matches = <Map<String, Object?>>[];
    for (final variant in workVariants) {
      if (variant['assetKind'] != 'cdAlbum') continue;
      final fileName = _string(variant['fileName'], '音频文件名');
      // 旧归档只保存曲名与编号，有分轨清单时无法证明曲名来自普通文件。
      if (KonataMediaExtensions.isCueSheetFile(fileName)) {
        _fail('旧音频所属作品含 CUE，归档无法区分普通曲目与分轨');
      }
      final dot = fileName.lastIndexOf('.');
      final stem = dot > 0 ? fileName.substring(0, dot) : fileName;
      if (SyncSanitizer.normalizeTitleKey(stem) == titleKey) {
        matches.add(variant);
      }
    }
    if (matches.length != 1 ||
        !KonataMediaExtensions.isPlayableAudioFile(
          matches.single['fileName']! as String,
        )) {
      _fail('旧音频无法按曲名唯一关联可播放文件');
    }
    return matches.single;
  }

  /// 旧墓碑没有物理标识，视频按逻辑键解析，音频借助同归档内已解析的记录。
  static List<Map<String, Object?>> _mergePlaybackTombstones(
    List<Map<String, Object?>> active,
    List<Map<String, Object?>> tombstones,
    Map<String, Object?> catalog,
    String device,
  ) {
    final byId = <String, SyncPlaybackHistoryItem>{
      for (final item in active)
        item['id']! as String: SyncPlaybackHistoryItem.tryFromJson(item)!,
    };
    final audioByLegacyKey = {
      for (final item in byId.values)
        if (item.isAudio)
          SyncSanitizer.buildPlaybackKey(
            canonicalWorkKey: item.canonicalWorkKey,
            seasonNumber: item.seasonNumber,
            episodeNumber: null,
            isAudio: true,
            audioTrackHint: item.episodeTitle,
          ): item,
    };
    final seen = <String>{};
    for (final row in tombstones) {
      _onlyKeys(row, {
        'entityKey',
        'entityType',
        'deletedAtMs',
        'deviceId',
      }, '删除墓碑');
      if (row['entityType'] != 'playback') _fail('作品或其他旧版墓碑尚不能安全转换');
      final key = _string(row['entityKey'], '删除墓碑标识');
      final deletedAt = _integer(row['deletedAtMs'], '删除时间');
      if (deletedAt == 0) _fail('删除时间无效');
      final source = _string(row['deviceId'], '删除设备');
      final audio = audioByLegacyKey[key];
      if (audio != null) {
        if (!seen.add(audio.id)) _fail('多个旧删除墓碑指向同一音频条目');
        if (audio.effectiveTimestampMs <= deletedAt) {
          byId[audio.id] = audio.copyWith(
            updatedAtMs: deletedAt,
            sourceDeviceId: source,
            deletedAtMs: deletedAt,
          );
        }
        continue;
      }
      final parsed = RegExp(
        r'^playback::(.+)::s([0-9]+)::(e[0-9]+|feature)$',
      ).firstMatch(key);
      if (parsed == null) _fail('旧删除墓碑无法唯一关联播放条目');
      final number = parsed.group(3)!;
      final converted = _convertPlaybacks(
        [
          {
            'playbackKey': key,
            'canonicalWorkKey': parsed.group(1),
            'seasonNumber': int.parse(parsed.group(2)!),
            if (number != 'feature')
              'episodeNumber': int.parse(number.substring(1)),
            'isAudio': false,
            'episodeTitle': '',
            'positionSeconds': 0,
            'durationSeconds': 0,
            'isCompleted': false,
            'playedAtMs': deletedAt,
            'updatedAtMs': deletedAt,
            'sourceDeviceId': source,
          },
        ],
        catalog,
        device,
      );
      final candidate = SyncPlaybackHistoryItem.tryFromJson(converted.single)!;
      if (!seen.add(candidate.id)) _fail('多个旧删除墓碑指向同一物理分集');
      final record = byId[candidate.id];
      if (record != null && record.effectiveTimestampMs > deletedAt) continue;
      byId[candidate.id] = (record ?? candidate).copyWith(
        updatedAtMs: deletedAt,
        sourceDeviceId: source,
        deletedAtMs: deletedAt,
      );
    }
    return [for (final item in byId.values) item.toJson()];
  }

  static String _relative(Object? value) {
    final path = _string(value, '相对路径').replaceAll('\\', '/');
    final decoded = path
        .replaceAll(RegExp('%2e', caseSensitive: false), '.')
        .replaceAll(RegExp('%2f|%5c', caseSensitive: false), '/');
    if (decoded.startsWith('/') ||
        decoded.contains(':') ||
        decoded.split('/').any((s) => s.isEmpty || s == '.' || s == '..')) {
      _fail('媒体相对路径不安全');
    }
    return path;
  }

  static Map<String, Object?> _object(Object? value, String name) {
    if (value is! Map) _fail('$name 结构无效');
    return SyncSanitizer.coerceStringKeyMap(value);
  }

  static List<Object?> _list(Object? value, String name) {
    if (value is! List) _fail('$name 结构无效');
    return List<Object?>.of(value);
  }

  static List<Map<String, Object?>> _rows(Object? value, String name) => [
    for (final item in _list(value, name)) _object(item, name),
  ];

  static String _string(Object? value, String name, {bool allowEmpty = false}) {
    if (value is! String || (!allowEmpty && value.trim().isEmpty)) {
      _fail('$name 无效');
    }
    return value;
  }

  static int _integer(Object? value, String name) {
    if (value is! int || value < 0) _fail('$name 无效');
    return value;
  }

  static void _onlyKeys(
    Map<String, Object?> map,
    Set<String> allowed,
    String name,
  ) {
    if (!map.keys.every(allowed.contains)) _fail('$name 包含尚未映射的字段');
  }

  static Never _fail(String message) =>
      throw FormatException('旧版 Konata v1/v2 备份：$message；未导入任何数据');
}
