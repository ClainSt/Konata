import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:engine_sources/engine_sources.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';
import 'package:path/path.dart' as p;

import 'library_catalog_sync_slice.dart';
import 'playback_history_sync_slice.dart';
import 'prefs_sync_slice.dart';
import 'sync_models.dart';

/// 本机已索引 CUE 的只读解析结果，不含源凭据。
typedef LegacyCueTrack = ({int number, String title, String fileName});
typedef LegacyCueReader =
    Future<List<LegacyCueTrack>?> Function(String cueVariantId);

/// 将可无损识别的旧版快照转换为新版归档；只允许宿主核验已索引的 CUE。
/// 未覆盖的语义一律阻止转换；非空目录仅允许安全复用和独立新增。
final class LegacyBackupMigration {
  const LegacyBackupMigration._();

  /// 判断是否为旧版快照信封，而非新版分片归档。
  static bool isLegacy(Object? decoded) =>
      decoded is Map && decoded['schema'] == 'konata.sync.snapshot.v1';

  /// 完整校验旧快照并构造独立的新版归档。
  static Future<KonataBackupArchive> convert(
    Object? decoded, {
    required Map<String, Object?> localCatalog,
    List<PortablePrefEntry> localPrefs = const [],
    LegacyCueReader? readCue,
  }) async {
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

    final playbackTombstones = <Map<String, Object?>>[];
    final workTombstones = <String, int>{};
    final overrideTombstones = <String, int>{};
    for (final row in _rows(payload['tombstones'], '删除墓碑')) {
      _onlyKeys(row, {
        'entityKey',
        'entityType',
        'deletedAtMs',
        'deviceId',
      }, '删除墓碑');
      final key = _string(row['entityKey'], '删除墓碑标识');
      final deletedAt = _integer(row['deletedAtMs'], '删除时间');
      if (deletedAt == 0) _fail('删除时间无效');
      _string(row['deviceId'], '删除设备');
      switch (row['entityType']) {
        case 'playback':
          playbackTombstones.add(row);
        case 'work_catalog':
          // 黄金源删除作品时按作品 ID 与全部身份键各写一条墓碑。
          final validPrefix =
              key.startsWith('work_id::') || key.startsWith('work_catalog::');
          if (!validPrefix || key.endsWith('::')) _fail('作品删除墓碑标识无效');
          final previous = workTombstones[key] ?? 0;
          workTombstones[key] = deletedAt > previous ? deletedAt : previous;
        case 'work_override':
          if (!key.startsWith('work_override::') || key.endsWith('::')) {
            _fail('整理状态删除墓碑标识无效');
          }
          final previous = overrideTombstones[key] ?? 0;
          overrideTombstones[key] = deletedAt > previous ? deletedAt : previous;
        default:
          _fail('未知类型的旧版墓碑尚不能安全转换');
      }
    }
    // 与黄金源合并引擎一致：晚于整理状态的墓碑使该整理状态失效。
    final overrides = [
      for (final row in _rows(payload['workOverrides'], '整理状态'))
        if (!_isOverrideSuppressed(row, overrideTombstones)) row,
    ];
    var playbacks = _rows(payload['playbackEntries'], '播放记录');
    final prefs = _object(payload['preferences'], '偏好');
    _onlyKeys(prefs, {'updatedAtMs', 'values'}, '偏好');
    final values = _object(prefs['values'], '偏好值');
    if (values.isNotEmpty) {
      add(PrefsSyncSlice.id, {
        'entries': _convertPreferences(
          values,
          localPrefs,
          _integer(prefs['updatedAtMs'], '偏好时间'),
          device,
        ),
      });
    }

    final Map<String, Object?> catalog;
    var deletedAliases = <String>{};
    if (version == 2) {
      catalog = _convertCatalog(
        _object(payload['libraryCatalog'], '完整目录'),
        device,
      );
      _applyWorkTombstones(catalog, workTombstones);
      _checkMirroredOverrides(overrides, catalog);
      _prepareCatalogMerge(localCatalog, catalog);
      deletedAliases = _deletedWorkAliases(catalog);
      add(LibraryCatalogSyncSlice.id, catalog);
    } else {
      if (payload.containsKey('libraryCatalog')) _fail('v1 信封不应含完整目录');
      if (overrides.isNotEmpty) _fail('v1 整理状态缺少完整目录，尚不能安全转换');
      if (workTombstones.isNotEmpty || overrideTombstones.isNotEmpty) {
        _fail('v1 作品或整理状态墓碑缺少完整目录，尚不能安全转换');
      }
      catalog = localCatalog;
    }

    // 黄金源对已删除作品的播放记录按“未匹配”跳过，这里保持一致。
    playbacks = [
      for (final row in playbacks)
        if (!_rowAliases(row).any(deletedAliases.contains)) row,
    ];
    if (playbacks.isNotEmpty || playbackTombstones.isNotEmpty) {
      final active = await _convertPlaybacks(
        playbacks,
        catalog,
        device,
        localCatalog,
        readCue,
      );
      add(PlaybackHistorySyncSlice.id, {
        'records': await _mergePlaybackTombstones(
          active,
          playbackTombstones,
          catalog,
          device,
          deletedAliases,
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

  /// 将旧版扁平偏好按实际命名空间合并；未出现的字段不得覆盖新版设置。
  static List<Map<String, Object?>> _convertPreferences(
    Map<String, Object?> values,
    List<PortablePrefEntry> localPrefs,
    int updatedAtMs,
    String device,
  ) {
    const appearance = {
      'konata_v2_theme_mode': 'themeMode',
      'konata_v2_window_material': 'windowMaterial',
      'konata_v2_ambient_canvas_enabled': 'ambientBackdropEnabled',
    };
    const detail = {
      'konata.detail.show_title_text': 'showTitleText',
      'konata.detail.show_title_logo': 'showTitleLogo',
      'konata.detail.show_overview': 'showOverview',
      'konata.detail.show_raw_video_filename': 'showRawVideoFilename',
      'konata.detail.show_cd_tab': 'showCdTab',
      'konata.detail.show_scan_tab': 'showScanTab',
    };
    const network = {
      'konata_v2_tmdb_backup_api': 'tmdbBackupApiBase',
      'konata_v2_tmdb_backup_image': 'tmdbBackupImageBase',
      'konata_v2_bangumi_backup_api': 'bangumiBackupApiBase',
      'konata_v2_bangumi_backup_image': 'bangumiBackupImageBase',
      'konata_v2_fanart_backup_api': 'fanartBackupApiBase',
      'konata_v2_fanart_backup_image': 'fanartBackupImageBase',
      'konata_v2_proxy_mode': 'proxyMode',
      'konata_v2_proxy_url': 'proxyUrl',
    };
    const playbackKey = 'konata.playback.preferences.v1';
    for (final entry in values.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key == playbackKey) {
        if (value is! String) _fail('旧播放偏好必须是 JSON 字符串');
        continue;
      }
      if (!appearance.containsKey(key) &&
          !detail.containsKey(key) &&
          !network.containsKey(key)) {
        _fail('旧偏好含未映射项目：$key');
      }
      final valid = switch (key) {
        'konata_v2_theme_mode' => {'dark', 'light', 'system'}.contains(value),
        'konata_v2_window_material' => {
          'acrylic',
          'mica',
          'tabbed',
        }.contains(value),
        'konata_v2_proxy_mode' => ProxyMode.values.any(
          (mode) => mode.name == value,
        ),
        _ =>
          network.containsKey(key)
              ? value is String &&
                    _safeLegacyNetworkUrl(
                          value,
                          proxy: key == 'konata_v2_proxy_url',
                        ) !=
                        null
              : value is bool,
      };
      if (!valid) _fail('旧偏好字段类型或值不合法：$key');
    }

    final entries = <Map<String, Object?>>[];
    void addDomain(
      String namespace,
      Map<String, String> mapping,
      Map<String, Object?> defaults,
    ) {
      final imported = <String, Object?>{
        for (final key in mapping.keys)
          if (values.containsKey(key)) mapping[key]!: values[key],
      };
      if (imported.isEmpty) return;
      final previous = localPrefs
          .where((entry) => entry.namespace == namespace)
          .firstOrNull;
      if (previous != null && previous.schemaVersion != 1) {
        _fail('新版偏好结构版本未知，无法安全迁移 $namespace');
      }
      final merged = <String, Object?>{
        ...defaults,
        ...?previous?.payload,
        ...imported,
      };
      if (namespace == 'feature_detail.display' &&
          (imported.containsKey('showTitleText') ||
              imported.containsKey('showTitleLogo'))) {
        // 新版标题模式互斥；两项同时出现时沿用详情页解码的徽标优先规则。
        final bool logo;
        if (imported.containsKey('showTitleLogo') &&
            imported.containsKey('showTitleText')) {
          logo =
              imported['showTitleLogo'] != false ||
              imported['showTitleText'] == false;
        } else if (imported.containsKey('showTitleLogo')) {
          logo = imported['showTitleLogo'] == true;
        } else {
          logo = imported['showTitleText'] != true;
        }
        merged['showTitleLogo'] = logo;
        merged['showTitleText'] = !logo;
      }
      if (namespace == 'feature_settings.network') {
        for (final key in imported.keys) {
          if (key == 'proxyMode') continue;
          final normalized = _safeLegacyNetworkUrl(
            imported[key] as String,
            proxy: key == 'proxyUrl',
          )!;
          final retired = switch (key) {
            'bangumiBackupApiBase' =>
              KonataNetworkConfig.retiredBangumiBackupApiBases,
            'bangumiBackupImageBase' =>
              KonataNetworkConfig.retiredBangumiBackupImageBases,
            _ => const <String>{},
          };
          merged[key] =
              retired.contains(normalized.replaceAll(RegExp(r'/+$'), ''))
              ? (key == 'bangumiBackupApiBase'
                    ? KonataNetworkConfig.defaultBangumiBackupApiBase
                    : KonataNetworkConfig.defaultBangumiBackupImageBase)
              : normalized;
        }
        if (merged['proxyMode'] == 'custom' &&
            (merged['proxyUrl'] is! String ||
                (_safeLegacyNetworkUrl(
                          merged['proxyUrl'] as String,
                          proxy: true,
                        ) ??
                        '')
                    .isEmpty)) {
          _fail('旧版自定义代理缺少有效地址');
        }
      }
      // 禁止把本机敏感或不可移植字段带入迁移后的归档，也不能静默丢弃它们。
      if (SyncSanitizer.canonicalJsonEncode(
            PrefsSyncSlice.sanitizePayloadMap(merged),
          ) !=
          SyncSanitizer.canonicalJsonEncode(merged)) {
        _fail('目标偏好含不可移植字段，无法安全合并 $namespace');
      }
      entries.add({
        'namespace': namespace,
        'schemaVersion': 1,
        'payload': merged,
        'updatedAtMs': updatedAtMs,
        'sourceDeviceId': device,
      });
    }

    addDomain('feature_settings.appearance', appearance, {
      'themeMode': 'dark',
      'windowMaterial': 'acrylic',
      'ambientBackdropEnabled': false,
    });
    addDomain('feature_detail.display', detail, {
      'showTitleText': false,
      'showTitleLogo': true,
      'showOverview': true,
      'showRawVideoFilename': true,
      'showCdTab': true,
      'showScanTab': true,
    });
    addDomain('feature_settings.network', network, {
      'tmdbBackupApiBase': '',
      'tmdbBackupImageBase': '',
      'bangumiBackupApiBase': '',
      'bangumiBackupImageBase': '',
      'fanartBackupApiBase': '',
      'fanartBackupImageBase': '',
      'proxyMode': 'system',
      'proxyUrl': '',
    });
    final rawPlayback = values[playbackKey];
    if (rawPlayback is String) {
      entries.addAll(
        _convertPlaybackPreferences(
          rawPlayback,
          localPrefs,
          updatedAtMs,
          device,
        ),
      );
    }
    return entries;
  }

  /// 旧播放 JSON 只迁移已验证的跨设备语义，本机权限及设备选择不导入。
  static List<Map<String, Object?>> _convertPlaybackPreferences(
    String raw,
    List<PortablePrefEntry> localPrefs,
    int updatedAtMs,
    String device,
  ) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      _fail('旧播放偏好 JSON 损坏');
    }
    final old = _object(decoded, '旧播放偏好');
    final video = <String, Object?>{};
    final audio = <String, Object?>{};
    final lyrics = <String, Object?>{};
    final quality = <String, Object?>{};
    const boolVideo = {
      'autoNextEpisode': 'autoPlayNextEpisode',
      'autoSkipChapter': 'autoSkipChapters',
      'autoEnterPip': 'autoEnterPip',
    };
    const boolLyrics = {
      'lyricSourceNeteaseEnabled': 'neteaseEnabled',
      'lyricSourceAmllEnabled': 'amllEnabled',
      'lyricSourceLrclibEnabled': 'lrclibEnabled',
      'showLyricRomaji': 'showRomaji',
    };
    const ignoredBool = {
      'promptChapterSkip',
      'videoFloatingMiniEnabled',
      'bitstreamPassthrough',
      'androidBitPerfectUsb',
      'skipFoobarBeefwebPrompt',
      'qqLyricDisclaimerAccepted',
      'exclusiveAudioOutput',
    };
    const ignoredString = {
      'preferredRelayKindKey',
      'audioDevice',
      'outputPipelineMode',
    };
    for (final entry in old.entries) {
      final key = entry.key;
      final value = entry.value;
      void require(bool valid) {
        if (!valid) _fail('旧播放偏好字段类型或值不合法：$key');
      }

      if (boolVideo.containsKey(key)) {
        require(value is bool);
        video[boolVideo[key]!] = value;
      } else if (boolLyrics.containsKey(key)) {
        require(value is bool);
        lyrics[boolLyrics[key]!] = value;
      } else if (ignoredBool.contains(key)) {
        require(value is bool);
      } else if (ignoredString.contains(key)) {
        require(value is String);
      } else {
        switch (key) {
          case 'defaultVideoEngine':
          case 'defaultAudioEngine':
            require({'builtinLibmpv', 'desktopRelay'}.contains(value));
            if (key == 'defaultVideoEngine') {
              video['preferredEngine'] = value;
            } else {
              audio['preferredAudioEngine'] = value;
            }
          case 'audioFloatingMiniEnabled':
            require(value is bool);
            audio[key] = value;
          case 'defaultVolume':
            require(
              value is num && value.isFinite && value >= 0 && value <= 100,
            );
            audio[key] = (value as num).toDouble();
            video['volume'] = value / 100;
          case 'cloudSubsetEnabled':
            require(value is bool);
            // 旧开关不代表本机同意向目标服务发送字幕。
            video['enableCloudSubset'] = false;
          case 'cloudSubsetEndpoint':
            require(
              value is String &&
                  _safeLegacyNetworkUrl(value, proxy: false) != null,
            );
            final endpoint = _safeLegacyNetworkUrl(
              value as String,
              proxy: false,
            )!;
            video['fontInAssEndpoint'] = endpoint.isEmpty
                ? 'https://font.anibt.net/api/subset'
                : endpoint;
            video['enableCloudSubset'] = false;
          case 'lyricSourceQqEnabled':
            require(value is bool);
            // 允许关闭，但不得将旧免责声明当成本机的新授权。
            if (value == false) lyrics['qqEnabled'] = false;
          case 'lyricWiredOffsetMillis':
          case 'lyricBluetoothOffsetMillis':
            require(value is int && value >= -5000 && value <= 5000);
            lyrics[key == 'lyricWiredOffsetMillis'
                    ? 'wiredOffsetMillis'
                    : 'bluetoothOffsetMillis'] =
                value;
          case 'hardwareDecode':
          case 'debandEnabled':
          case 'keepPitch':
            require(value is bool);
            quality[key] = value;
            if (key == 'keepPitch') audio[key] = value;
          case 'preset':
            require(
              {
                'highFidelity',
                'standard',
                'lightweight',
                'softwareFallback',
              }.contains(value),
            );
            quality[key] = value;
          case 'demuxerMaxBytesMiB':
          case 'demuxerMaxBackBytesMiB':
          case 'cacheSecs':
          case 'subFontSize':
          case 'subBottomMargin':
            final (min, max) = switch (key) {
              'demuxerMaxBytesMiB' => (4, 512),
              'demuxerMaxBackBytesMiB' => (2, 256),
              'cacheSecs' => (10, 600),
              'subFontSize' => (12, 140),
              _ => (0, 200),
            };
            require(value is int && value >= min && value <= max);
            quality[key] = value;
          case 'audioResamplerPrecision':
            require(value is int && value >= 16 && value <= 33);
            // 新版音频只接受四种精度，超出共同范围时保留本机默认。
            if ({20, 24, 28, 32}.contains(value)) {
              quality[key] = value;
              audio[key] = value;
            }
          case 'defaultSpeed':
            require(
              value is num && value.isFinite && value >= 0.25 && value <= 4,
            );
            quality[key] = value;
          case 'subFontName':
            require(
              value is String && !SyncSanitizer.isUnsafePrefStringValue(value),
            );
            quality[key] = value;
          case 'subOverrideMode':
            require({'preserveAss', 'scaleOnly', 'forceStyle'}.contains(value));
            quality[key] = value;
          case 'subColorHex':
            require(
              value is String &&
                  RegExp(
                    r'^#?[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$',
                  ).hasMatch(value),
            );
            quality[key] = value;
          case 'activeShaderPaths':
            require(value is List && value.every((item) => item is String));
          case 'foobarBeefwebPort':
            require(value is int && value >= 1 && value <= 65535);
          case 'outputPipelineSchemaVersion':
            require(value is int && value >= 1 && value <= 2);
          default:
            _fail('旧播放偏好含未映射项目：$key');
        }
      }
    }
    final result = <Map<String, Object?>>[];
    void merge(String namespace, int schema, Map<String, Object?> imported) {
      if (imported.isEmpty &&
          (namespace != 'playback_video' || quality.isEmpty)) {
        return;
      }
      final previous = localPrefs
          .where((entry) => entry.namespace == namespace)
          .firstOrNull;
      if (previous != null &&
          (previous.schemaVersion < 1 || previous.schemaVersion > schema)) {
        _fail('新版播放偏好结构版本未知：$namespace');
      }
      final merged = <String, Object?>{...?previous?.payload, ...imported};
      if (namespace == 'playback_video') {
        final currentQuality = merged['qualityConfig'];
        if (currentQuality != null && currentQuality is! Map) {
          _fail('本机视频画质配置结构无效');
        }
        final combined = <String, Object?>{
          if (currentQuality is Map) ..._object(currentQuality, '本机画质配置'),
          ...quality,
        };
        // 默认空着色器列表无需进入便携归档；非空本机路径则拒绝以免被清除。
        if (combined['activeShaderPaths'] is List &&
            (combined['activeShaderPaths'] as List).isEmpty) {
          combined.remove('activeShaderPaths');
        }
        if (combined.isNotEmpty) merged['qualityConfig'] = combined;
      }
      if (SyncSanitizer.canonicalJsonEncode(
            PrefsSyncSlice.sanitizePayloadMap(merged),
          ) !=
          SyncSanitizer.canonicalJsonEncode(merged)) {
        _fail('本机播放偏好含不可移植字段，无法安全合并 $namespace');
      }
      result.add({
        'namespace': namespace,
        'schemaVersion': schema,
        'payload': merged,
        'updatedAtMs': updatedAtMs,
        'sourceDeviceId': device,
      });
    }

    merge('playback_video', 2, video);
    merge('playback_audio', 1, audio);
    merge('lyrics', 1, lyrics);
    return result;
  }

  /// 仅迁移非敏感地址；不接受认证信息、查询参数、片段或本地文件。
  static String? _safeLegacyNetworkUrl(String raw, {required bool proxy}) {
    final value = raw.trim();
    if (value.isEmpty) return '';
    if (SyncSanitizer.isUnsafePrefStringValue(value) ||
        RegExp(r'[\x00-\x20\x7f\\]').hasMatch(value)) {
      return null;
    }
    final candidate = proxy && !value.contains('://') ? 'http://$value' : value;
    final uri = Uri.tryParse(candidate);
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.authority.contains('@') ||
        uri.hasQuery ||
        uri.hasFragment) {
      return null;
    }
    final schemes = proxy
        ? {'http', 'https', 'socks', 'socks5'}
        : {'http', 'https'};
    if (!schemes.contains(uri.scheme.toLowerCase())) return null;
    if (uri.hasPort && (uri.port <= 0 || uri.port > 65535)) return null;
    if (proxy && (!uri.hasPort || (uri.path.isNotEmpty && uri.path != '/'))) {
      return null;
    }
    return candidate;
  }

  static const _catalogKeys = [
    'mediaSources',
    'seriesGroups',
    'works',
    'episodes',
    'variants',
    'ignoredFolders',
  ];

  /// 复用唯一且同账号的媒体源，并按完整身份链对齐语义一致的目录实体。
  static void _prepareCatalogMerge(
    Map<String, Object?> local,
    Map<String, Object?> incoming,
  ) {
    final localSources = _rows(local['mediaSources'], '媒体源');
    final sourceRemap = <String, String>{};
    final sources = <Map<String, Object?>>[];
    for (final row in _rows(incoming['mediaSources'], '媒体源')) {
      final source = SyncLibrarySourceItem.tryFromJson(row)!;
      final matches = localSources.where((item) {
        final candidate = SyncLibrarySourceItem.tryFromJson(item)!;
        return candidate.id == source.id ||
            candidate.normalizedLocationKey == source.normalizedLocationKey;
      }).toList();
      if (matches.isEmpty) {
        sourceRemap[source.id] = source.id;
        sources.add(row);
        continue;
      }
      if (matches.length != 1) _fail('媒体源身份不唯一，需人工复核');
      final candidate = SyncLibrarySourceItem.tryFromJson(matches.single)!;
      final uri = Uri.tryParse(candidate.location);
      if (candidate.isDeleted ||
          source.isDeleted ||
          candidate.normalizedLocationKey != source.normalizedLocationKey ||
          (candidate.username ?? '') != (source.username ?? '') ||
          (candidate.kind != MediaSourceKind.local &&
              (uri == null ||
                  uri.userInfo.isNotEmpty ||
                  uri.hasQuery ||
                  uri.hasFragment))) {
        _fail('媒体源地址、账号或删除状态冲突，需人工复核');
      }
      sourceRemap[source.id] = candidate.id;
      // 保留本机源标识、标签、时间及安全存储关联，不用旧备份改写连接。
      sources.add(matches.single);
    }
    incoming['mediaSources'] = sources;
    for (final key in ['variants', 'ignoredFolders']) {
      incoming[key] = [
        for (final row in _rows(incoming[key], key))
          {
            ...row,
            'sourceId': sourceRemap[row['sourceId']]!,
            if (key == 'ignoredFolders')
              'id': '${sourceRemap[row['sourceId']]}::${row['relativePath']}',
          },
      ];
    }

    bool sameEntity(
      Map<String, Object?> existing,
      Map<String, Object?> remote,
    ) {
      if (existing['deletedAtMs'] != remote['deletedAtMs']) return false;
      for (final entry in remote.entries) {
        if ({
          'updatedAtMs',
          'createdAtMs',
          'sourceDeviceId',
        }.contains(entry.key)) {
          continue;
        }
        if (entry.key == 'secondaryWorkKeys') {
          final existingKeys = _list(existing[entry.key], '作品身份').toSet();
          if (!_list(entry.value, '作品身份').every(existingKeys.contains)) {
            return false;
          }
          continue;
        }
        if (SyncSanitizer.canonicalJsonEncode(existing[entry.key]) !=
            SyncSanitizer.canonicalJsonEncode(entry.value)) {
          return false;
        }
      }
      return true;
    }

    Map<String, Set<Object?>> index(
      String kind,
      Iterable<String> Function(Map<String, Object?>) keys,
    ) {
      final result = <String, Set<Object?>>{};
      for (final row in _rows(local[kind], kind)) {
        for (final key in keys(row)) {
          result.putIfAbsent(key, () => <Object?>{}).add(row['id']);
        }
      }
      return result;
    }

    Iterable<String> seriesKeys(Map<String, Object?> row) sync* {
      final series = SyncLibrarySeriesItem.tryFromJson(row)!;
      yield 'title:${SyncSanitizer.normalizeTitleKey(series.title)}';
      if (series.tmdbCollectionId != null) {
        yield 'collection:${series.tmdbCollectionId}';
      }
    }

    Iterable<String> workKeys(Map<String, Object?> row) =>
        SyncLibraryWorkItem.tryFromJson(row)!.allWorkKeys;
    Iterable<String> pathKeys(Map<String, Object?> row) sync* {
      yield '${row['sourceId']}::${SyncSanitizer.normalizeRelativePath(row['relativePath'] as String).toLowerCase()}';
    }

    Iterable<String> episodeKeys(Map<String, Object?> row) sync* {
      final ep = SyncLibraryEpisodeItem.tryFromJson(row)!;
      if (ep.category == EpisodeCategory.main && ep.episodeNumber != null) {
        yield '${ep.workId}::main::s${ep.seasonNumber}::e${ep.episodeNumber}::${ep.episodeNumberEnd ?? ''}';
      } else if (ep.category == EpisodeCategory.extra) {
        yield '${ep.workId}::extra::${ep.extraType?.name ?? ''}::${ep.episodeNumber ?? ''}::${SyncSanitizer.normalizeTitleKey(ep.title ?? '')}';
      } else {
        yield '${ep.workId}::single::${ep.category.name}::${SyncSanitizer.normalizeTitleKey(ep.title ?? '')}';
      }
    }

    final indexes = {
      'seriesGroups': index('seriesGroups', seriesKeys),
      'works': index('works', workKeys),
      'episodes': index('episodes', episodeKeys),
      'variants': index('variants', pathKeys),
      'ignoredFolders': index('ignoredFolders', pathKeys),
    };
    final keyBuilders = {
      'seriesGroups': seriesKeys,
      'works': workKeys,
      'episodes': episodeKeys,
      'variants': pathKeys,
      'ignoredFolders': pathKeys,
    };
    final seriesRemap = <Object?, Object?>{};
    final workRemap = <Object?, Object?>{};
    final episodeRemap = <Object?, Object?>{};
    final matchedWorkIds = <Object?>{};

    for (final key in _catalogKeys.where((key) => key != 'mediaSources')) {
      final existing = _rows(local[key], key);
      final byId = {for (final row in existing) row['id']: row};
      final merged = <Map<String, Object?>>[];
      final claimedIds = <Object?>{};
      final builder = keyBuilders[key]!;
      for (final original in _rows(incoming[key], key)) {
        final row = <String, Object?>{...original};
        // 先对齐父级，再按季集号或物理路径查找，禁止跨作品重新归档。
        if (key == 'works' && row['seriesId'] != null) {
          row['seriesId'] = seriesRemap[row['seriesId']];
        }
        if (key == 'episodes' || key == 'variants') {
          row['workId'] = workRemap[row['workId']];
        }
        if (key == 'variants' && row['episodeId'] != null) {
          row['episodeId'] = episodeRemap[row['episodeId']];
        }
        final identities = <Object?>{
          if (byId.containsKey(row['id'])) row['id'],
          for (final identity in builder(row)) ...?indexes[key]![identity],
        };
        if (identities.length > 1) {
          _fail('非空目标目录 $key 存在多个候选身份，需人工复核');
        }
        final match = identities.isEmpty ? null : byId[identities.single];
        if (match != null) {
          if (match['id'] != row['id']) {
            if (match['deletedAtMs'] != null || row['deletedAtMs'] != null) {
              _fail('不同主键的已删除目录实体不能自动对齐');
            }
            if (key == 'works') {
              final localStrong = workKeys(
                match,
              ).where(_strongWorkIdentity).toSet();
              final remoteStrong = workKeys(
                row,
              ).where(_strongWorkIdentity).toSet();
              if (!remoteStrong.any(localStrong.contains) ||
                  !remoteStrong.every(localStrong.contains)) {
                _fail('作品缺少一致的强身份，需人工复核');
              }
            }
            row['id'] = match['id'];
          }
          // 缺省的父级关联也属于语义，不得悄悄沿用不同的本机归属。
          if ((key == 'works' && match['seriesId'] != row['seriesId']) ||
              (key == 'variants' && match['episodeId'] != row['episodeId']) ||
              !sameEntity(match, row)) {
            _fail('非空目标目录 $key 存在实体差异，需人工复核');
          }
          if (key == 'works') matchedWorkIds.add(match['id']);
        }
        final target = match ?? row;
        if (!claimedIds.add(target['id'])) {
          _fail('多个旧目录实体指向同一目标 $key');
        }
        switch (key) {
          case 'seriesGroups':
            seriesRemap[original['id']] = target['id'];
          case 'works':
            workRemap[original['id']] = target['id'];
          case 'episodes':
            episodeRemap[original['id']] = target['id'];
        }
        merged.add(target);
      }
      if (key == 'episodes' || key == 'variants') {
        // 历史恢复仅凭逻辑身份；本机额外分集/版本可能令目标不再唯一。
        if (existing.any(
          (row) =>
              row['deletedAtMs'] == null &&
              matchedWorkIds.contains(row['workId']) &&
              !claimedIds.contains(row['id']),
        )) {
          _fail('已有作品包含未对齐的分集或媒体版本，需人工复核');
        }
      }
      incoming[key] = merged;
    }
  }

  static bool _strongWorkIdentity(String key) =>
      key.startsWith('tmdb:') || key.startsWith('bgm:');

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
      // 黄金源只把整理状态应用到现存作品，已删除作品的整理状态不再生效。
      if (work['deletedAtMs'] != null) continue;
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

  static bool _isOverrideSuppressed(
    Map<String, Object?> row,
    Map<String, int> overrideTombstones,
  ) {
    var latest = 0;
    for (final key in _rowAliases(row)) {
      final deletedAt = overrideTombstones['work_override::$key'] ?? 0;
      if (deletedAt > latest) latest = deletedAt;
    }
    final updatedAt = row['updatedAtMs'];
    return latest > 0 && updatedAt is int && latest > updatedAt;
  }

  /// 按黄金源合并引擎的规则，把晚于作品更新时间的作品墓碑写成目录内的删除标记，
  /// 并同时标记该作品的分集与媒体版本。缺少实体的墓碑不能安全持久化，拒绝转换。
  static void _applyWorkTombstones(
    Map<String, Object?> catalog,
    Map<String, int> workTombstones,
  ) {
    if (workTombstones.isEmpty) return;
    final works = catalog['works']! as List<Map<String, Object?>>;
    final deletedAtByWork = <String, int>{};
    final matchedKeys = <String>{};
    for (final work in works) {
      final id = work['id']! as String;
      final idKey = 'work_id::$id';
      if (workTombstones.containsKey(idKey)) matchedKeys.add(idKey);
      var latest = workTombstones[idKey] ?? 0;
      for (final key in _rowAliases(work)) {
        final aliasKey = 'work_catalog::$key';
        if (workTombstones.containsKey(aliasKey)) matchedKeys.add(aliasKey);
        final deletedAt = workTombstones[aliasKey] ?? 0;
        if (deletedAt > latest) latest = deletedAt;
      }
      if (latest > (work['updatedAtMs']! as int)) {
        work['deletedAtMs'] = latest;
        deletedAtByWork[id] = latest;
      }
    }
    if (matchedKeys.length != workTombstones.length) {
      _fail('作品删除墓碑缺少对应目录实体，无法保留删除身份');
    }
    for (final key in ['episodes', 'variants']) {
      for (final row in catalog[key]! as List<Map<String, Object?>>) {
        final deletedAt = deletedAtByWork[row['workId']];
        if (deletedAt != null) row['deletedAtMs'] = deletedAt;
      }
    }
  }

  /// 仅收集已删除作品独占的身份键，避免误伤仍然有效的同名作品。
  static Set<String> _deletedWorkAliases(Map<String, Object?> catalog) {
    final deleted = <String>{};
    final active = <String>{};
    for (final work in _rows(catalog['works'], '作品')) {
      (work['deletedAtMs'] == null ? active : deleted).addAll(
        _rowAliases(work),
      );
    }
    return deleted.difference(active);
  }

  static Set<String> _rowAliases(Map<String, Object?> row) {
    final secondary = row['secondaryWorkKeys'];
    return {
      if (row['canonicalWorkKey'] case final String key when key.isNotEmpty)
        key,
      if (secondary is List)
        for (final key in secondary)
          if (key is String && key.isNotEmpty) key,
    };
  }

  static Future<List<Map<String, Object?>>> _convertPlaybacks(
    List<Map<String, Object?>> rows,
    Map<String, Object?> catalog,
    String device,
    Map<String, Object?> localCatalog,
    LegacyCueReader? readCue,
  ) async {
    final works = _rows(catalog['works'], '作品');
    final trustedCues = {
      for (final row in _rows(localCatalog['variants'], '本机文件'))
        if (row['deletedAtMs'] == null &&
            row['assetKind'] == 'cdAlbum' &&
            KonataMediaExtensions.isCueSheetFile(row['fileName'] as String))
          row['id']: row,
    };
    final trustedLocalSources = {
      for (final row in _rows(localCatalog['mediaSources'], '本机媒体源'))
        if (row['deletedAtMs'] == null && row['kind'] == 'local') row['id'],
    };
    final cueCache = <String, List<LegacyCueTrack>>{};
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
        final resolved = await _resolveLegacyAudio(
          workVariants,
          title,
          number,
          trustedCues,
          trustedLocalSources,
          cueCache,
          readCue,
        );
        variant = resolved.variant;
        final variantId = _string(variant['id'], '物理版本');
        final suffix = resolved.track == null ? '' : '#cue:${resolved.track}';
        epId = 'cd::$variantId$suffix';
        id = 'cd::$workId::$variantId$suffix';
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

  static Future<({Map<String, Object?> variant, int? track})>
  _resolveLegacyAudio(
    Iterable<Map<String, Object?>> workVariants,
    String title,
    int? number,
    Map<Object?, Map<String, Object?>> trustedCues,
    Set<Object?> trustedLocalSources,
    Map<String, List<LegacyCueTrack>> cueCache,
    LegacyCueReader? readCue,
  ) async {
    final titleKey = SyncSanitizer.normalizeTitleKey(title);
    if (titleKey.isEmpty) _fail('旧音频缺少可用于匹配的曲名');
    final matches = <({Map<String, Object?> variant, int? track})>[];
    final referencedIds = <Object?>{};
    for (final variant in workVariants) {
      if (variant['assetKind'] != 'cdAlbum') continue;
      final fileName = _string(variant['fileName'], '音频文件名');
      if (KonataMediaExtensions.isCueSheetFile(fileName)) {
        final cueId = _string(variant['id'], 'CUE 标识');
        final trusted = trustedCues[cueId];
        if (readCue == null ||
            trusted == null ||
            !trustedLocalSources.contains(variant['sourceId']) ||
            trusted['sourceId'] != variant['sourceId'] ||
            trusted['workId'] != variant['workId'] ||
            trusted['relativePath'] != variant['relativePath']) {
          _fail('旧音频所属作品含 CUE，归档无法区分普通曲目与分轨；请先索引本机清单');
        }
        var tracks = cueCache[cueId];
        if (tracks == null) {
          if (cueCache.length >= 64) _fail('旧音频 CUE 核验超出单次上限');
          tracks = await readCue(cueId);
          if (tracks == null || tracks.isEmpty || tracks.length > 99) {
            _fail('本机 CUE 清单无法安全读取');
          }
          cueCache[cueId] = tracks;
        }
        final numbers = <int>{};
        final dir = p.posix.dirname(
          SyncSanitizer.normalizeRelativePath(
            variant['relativePath'] as String,
          ),
        );
        for (final track in tracks) {
          final ref = track.fileName.replaceAll('\\', '/');
          if (track.number < 1 ||
              track.number > 99 ||
              !numbers.add(track.number) ||
              ref.isEmpty ||
              ref.startsWith('/') ||
              ref.contains(':') ||
              ref.contains('\x00') ||
              ref.split('/').contains('..')) {
            _fail('本机 CUE 分轨编号或文件引用不合法');
          }
          final expected = p.posix.normalize(p.posix.join(dir, ref));
          final physical = workVariants
              .where(
                (v) =>
                    v['assetKind'] == 'cdAlbum' &&
                    v['sourceId'] == variant['sourceId'] &&
                    SyncSanitizer.normalizeRelativePath(
                          v['relativePath'] as String,
                        ) ==
                        expected &&
                    KonataMediaExtensions.isPlayableAudioFile(
                      v['fileName'] as String,
                    ),
              )
              .toList();
          if (physical.length != 1) _fail('本机 CUE 母轨无法唯一关联索引文件');
          referencedIds.add(physical.single['id']);
          if (number == track.number &&
              SyncSanitizer.normalizeTitleKey(track.title) == titleKey) {
            matches.add((variant: physical.single, track: track.number));
          }
        }
        continue;
      }
      final dot = fileName.lastIndexOf('.');
      final stem = dot > 0 ? fileName.substring(0, dot) : fileName;
      if (SyncSanitizer.normalizeTitleKey(stem) == titleKey) {
        matches.add((variant: variant, track: null));
      }
    }
    if (matches.any(
      (match) =>
          match.track == null && referencedIds.contains(match.variant['id']),
    )) {
      _fail('旧音频同时指向整轨文件与 CUE，无法安全区分');
    }
    if (matches.length != 1 ||
        !KonataMediaExtensions.isPlayableAudioFile(
          matches.single.variant['fileName']! as String,
        )) {
      _fail('旧音频无法按曲名唯一关联可播放文件');
    }
    return matches.single;
  }

  /// 旧墓碑没有物理标识，视频按逻辑键解析，音频借助同归档内已解析的记录。
  static Future<List<Map<String, Object?>>> _mergePlaybackTombstones(
    List<Map<String, Object?>> active,
    List<Map<String, Object?>> tombstones,
    Map<String, Object?> catalog,
    String device,
    Set<String> deletedAliases,
  ) async {
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
      // 作品已按墓碑删除时，其播放墓碑没有可作用的现存条目。
      if (deletedAliases.contains(parsed.group(1))) continue;
      final number = parsed.group(3)!;
      final converted = await _convertPlaybacks(
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
        catalog,
        null,
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
