import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/formatting/network_error_sanitizer.dart';
import '../../domain/models/network_config.dart';
import '../../domain/scraping/bangumi_tmdb_index.dart';
import '../network/priority_http_scheduler.dart';
import '../network/tmdb_http_client.dart';
import '../storage/atomic_file_writer.dart';
import '../storage/storage_root_provider.dart';

/// Bangumi ↔ TMDB 离线映射表加载器与静默热更新服务。
///
/// 职责边界：
/// 1. 优先从便携 `userdata/` 与安装包内置资产择新载入不可变二进制索引，损坏文件自动自愈回退；
/// 2. 扫描前按 24 小时冷却周期静默经多镜像（jsDelivr 双节点 + GitHub Raw）校验 `manifest.json`；
/// 3. 通过版本兼容检查、大小上限检查、SHA-256 摘要比对、二进制头解析校验与同卷原子替换落盘，
///    严禁半包污染或覆盖当前可用索引。
class BangumiTmdbMapUpdater {
  /// 创建映射表加载与热更新服务实例。
  BangumiTmdbMapUpdater({
    required this._storageRoot,
    Future<SharedPreferences> Function()? prefsLoader,
    Future<ByteData> Function(String assetPath)? assetLoader,
    http.Client? httpClient,
    DateTime Function()? nowProvider,
    List<String>? mirrorBases,
  }) : _prefsLoader = prefsLoader ?? SharedPreferences.getInstance,
       _assetLoader = assetLoader ?? rootBundle.load,
       _injectedHttpClient = httpClient,
       _now = nowProvider ?? DateTime.now,
       _mirrorBases = mirrorBases ?? TmdbNetworkConfig.mappingMirrorBases;

  static const String _prefLastCheckedMs = 'konata_mapping_last_checked_ms';
  static const String _prefEtag = 'konata_mapping_etag';
  static const String _prefLastMirror = 'konata_mapping_last_mirror';

  final StorageRootService _storageRoot;
  final Future<SharedPreferences> Function() _prefsLoader;
  final Future<ByteData> Function(String assetPath) _assetLoader;
  final http.Client? _injectedHttpClient;
  final DateTime Function() _now;
  final List<String> _mirrorBases;

  /// 载入当前生效映射表快照：对比本地热更新与安装包内置版本并择新返回，损坏自动回退。
  Future<BangumiTmdbSnapshot> loadActiveSnapshot() async {
    final prefsState = await _readPrefsState();
    final localLoaded = await _tryLoadLocalSnapshot();
    final bundledLoaded = await _tryLoadBundledSnapshot();

    if (localLoaded != null && bundledLoaded != null) {
      final localNewerOrSame =
          localLoaded.index.snapshotDateYyyymmdd >
              bundledLoaded.index.snapshotDateYyyymmdd ||
          (localLoaded.index.snapshotDateYyyymmdd ==
                  bundledLoaded.index.snapshotDateYyyymmdd &&
              (localLoaded.index.version > bundledLoaded.index.version ||
                  (localLoaded.index.version == bundledLoaded.index.version &&
                      localLoaded.index.recordCount >=
                          bundledLoaded.index.recordCount)));
      final chosen = localNewerOrSame ? localLoaded : bundledLoaded;
      return chosen.copyWith(
        etag: prefsState.etag,
        lastCheckedAt: prefsState.lastCheckedAt,
        lastMirrorBase: prefsState.lastMirrorBase,
      );
    }
    if (localLoaded != null) {
      return localLoaded.copyWith(
        etag: prefsState.etag,
        lastCheckedAt: prefsState.lastCheckedAt,
        lastMirrorBase: prefsState.lastMirrorBase,
      );
    }
    if (bundledLoaded != null) {
      return bundledLoaded.copyWith(
        etag: prefsState.etag,
        lastCheckedAt: prefsState.lastCheckedAt,
        lastMirrorBase: prefsState.lastMirrorBase,
      );
    }
    return BangumiTmdbSnapshot(
      index: BangumiTmdbIndex.empty(),
      source: BangumiTmdbMapSource.staticFallback,
      snapshotDate: '',
      sha256Hex: '',
      etag: prefsState.etag,
      lastCheckedAt: prefsState.lastCheckedAt,
      lastMirrorBase: prefsState.lastMirrorBase,
    );
  }

  /// 按冷却周期（或 [force] 手动触发）检查并拉取最新映射表快照。
  Future<BangumiTmdbUpdateResult> checkAndUpdateIfDue({
    bool force = false,
    TmdbNetworkConfig? networkConfig,
  }) async {
    final current = await loadActiveSnapshot();
    final now = _now();
    if (!force && current.lastCheckedAt != null) {
      final elapsed = now.difference(current.lastCheckedAt!);
      if (elapsed >= Duration.zero &&
          elapsed < TmdbNetworkConfig.mappingAutoCheckInterval) {
        return BangumiTmdbUpdateResult(
          state: BangumiTmdbUpdateState.skippedNotDue,
          snapshot: current,
          message: '24 小时内已检查，沿用当前映射表',
        );
      }
    }

    final cfg = networkConfig ?? const TmdbNetworkConfig();
    final budget = force
        ? TmdbNetworkConfig.mappingManualCheckBudget
        : TmdbNetworkConfig.mappingSilentCheckBudget;
    final deadline = now.add(budget);

    final checkClient = TmdbHttpClient(
      config: cfg,
      scheduler: PriorityHttpScheduler(maxRetries: 0),
      httpClient: _injectedHttpClient,
      primaryTimeout: TmdbNetworkConfig.mappingCheckTimeout,
      backupTimeout: TmdbNetworkConfig.mappingCheckTimeout,
      nowProvider: _now,
    );
    final downloadClient = TmdbHttpClient(
      config: cfg,
      scheduler: PriorityHttpScheduler(maxRetries: 0),
      httpClient: _injectedHttpClient,
      primaryTimeout: TmdbNetworkConfig.mappingDownloadTimeout,
      backupTimeout: TmdbNetworkConfig.mappingDownloadTimeout,
      nowProvider: _now,
    );

    String? lastFailure;
    try {
      for (final rawBase in _mirrorBases) {
        final base = rawBase.trim().replaceAll(RegExp(r'/+$'), '');
        if (base.isEmpty) continue;
        final remaining = deadline.difference(_now());
        if (remaining <= const Duration(milliseconds: 250)) {
          lastFailure ??= '检查超时，已跳过';
          break;
        }

        try {
          // 优先探测 v2 含 `tvdb_id` 清单；若镜像尚未发布 v2（返回 404），同节点无缝回退 v1 清单。
          final manifestCandidates =
              const <({String manifestFile, String binFile, String channel})>[
                (
                  manifestFile: TmdbNetworkConfig.mappingV2ManifestFileName,
                  binFile: TmdbNetworkConfig.mappingV2BinaryFileName,
                  channel: 'v2',
                ),
                (
                  manifestFile: TmdbNetworkConfig.mappingManifestFileName,
                  binFile: TmdbNetworkConfig.mappingBinaryFileName,
                  channel: 'v1',
                ),
              ];

          http.Response? manifestResp;
          String activeBinFile = TmdbNetworkConfig.mappingBinaryFileName;
          String activeMirrorKey = base;

          for (final cand in manifestCandidates) {
            final probeRemaining = deadline.difference(_now());
            if (probeRemaining <= const Duration(milliseconds: 250)) {
              lastFailure ??= '检查超时，已跳过';
              break;
            }
            final manifestUri = Uri.parse('$base/${cand.manifestFile}');
            final mirrorKey =
                cand.channel == 'v2' ? '$base#v2' : base;
            final headers = <String, String>{'Accept': 'application/json'};
            final canSendEtag =
                current.etag != null &&
                current.etag!.isNotEmpty &&
                current.sha256Hex.isNotEmpty &&
                current.lastMirrorBase == mirrorKey;
            if (canSendEtag) {
              headers['If-None-Match'] = current.etag!;
            }
            final manifestTimeout =
                probeRemaining < TmdbNetworkConfig.mappingCheckTimeout
                ? probeRemaining
                : TmdbNetworkConfig.mappingCheckTimeout;
            final resp = await checkClient
                .get(
                  manifestUri,
                  headers: headers,
                  priority: RequestPriority.interactive,
                )
                .timeout(manifestTimeout);
            if (resp.statusCode == 404 && cand.channel == 'v2') {
              continue;
            }
            manifestResp = resp;
            activeBinFile = cand.binFile;
            activeMirrorKey = mirrorKey;
            break;
          }

          if (manifestResp == null) {
            lastFailure ??= '镜像未返回有效清单';
            continue;
          }

          if (manifestResp.statusCode == 304) {
            await _savePrefsState(
              checkedAt: now,
              etag: current.etag,
              mirrorBase: activeMirrorKey,
            );
            final updatedSnap = current.copyWith(
              lastCheckedAt: now,
              lastMirrorBase: activeMirrorKey,
            );
            return BangumiTmdbUpdateResult(
              state: BangumiTmdbUpdateState.upToDate,
              snapshot: updatedSnap,
              message: '映射表已是最新（${updatedSnap.uniqueBangumiCount} 条）',
              mirrorUsed: base,
            );
          }

          if (manifestResp.statusCode != 200) {
            lastFailure = '镜像返回 HTTP ${manifestResp.statusCode}';
            continue;
          }

          final parsed = _parseManifest(manifestResp.bodyBytes);
          if (parsed == null) {
            lastFailure = '清单格式校验失败';
            continue;
          }

          final nextEtag = _extractHeader(manifestResp.headers, 'etag');
          final sameHash =
              current.sha256Hex.isNotEmpty &&
              parsed.binSha256 == current.sha256Hex;
          final remoteOlder =
              current.index.isNotEmpty &&
              parsed.snapshotDateYyyymmdd > 0 &&
              (current.index.snapshotDateYyyymmdd >
                      parsed.snapshotDateYyyymmdd ||
                  (current.index.snapshotDateYyyymmdd ==
                          parsed.snapshotDateYyyymmdd &&
                      current.index.version > parsed.schemaVersion));
          if (sameHash || remoteOlder) {
            await _savePrefsState(
              checkedAt: now,
              etag: nextEtag ?? current.etag,
              mirrorBase: activeMirrorKey,
            );
            final updatedSnap = current.copyWith(
              etag: nextEtag ?? current.etag,
              lastCheckedAt: now,
              lastMirrorBase: activeMirrorKey,
            );
            return BangumiTmdbUpdateResult(
              state: BangumiTmdbUpdateState.upToDate,
              snapshot: updatedSnap,
              message: '映射表已是最新（${updatedSnap.uniqueBangumiCount} 条）',
              mirrorUsed: base,
            );
          }

          final downloadRemaining = deadline.difference(_now());
          if (downloadRemaining <= const Duration(milliseconds: 500)) {
            lastFailure = '下载时间预算不足';
            break;
          }
          final binUri = Uri.parse('$base/$activeBinFile');
          final downloadTimeout =
              downloadRemaining < TmdbNetworkConfig.mappingDownloadTimeout
              ? downloadRemaining
              : TmdbNetworkConfig.mappingDownloadTimeout;
          final binResp = await downloadClient
              .get(
                binUri,
                headers: const {'Accept': 'application/octet-stream'},
                priority: RequestPriority.interactive,
              )
              .timeout(downloadTimeout);

          if (binResp.statusCode != 200) {
            lastFailure = '二进制表返回 HTTP ${binResp.statusCode}';
            continue;
          }

          final binBytes = Uint8List.fromList(binResp.bodyBytes);
          if (binBytes.isEmpty ||
              binBytes.length > TmdbNetworkConfig.maxMappingBinaryBytes) {
            lastFailure = '映射表文件大小超出安全范围';
            continue;
          }
          if (parsed.binBytes > 0 && binBytes.length != parsed.binBytes) {
            lastFailure = '映射表字节数与清单声明不一致';
            continue;
          }
          final actualSha = sha256.convert(binBytes).toString().toLowerCase();
          if (actualSha != parsed.binSha256) {
            lastFailure = '映射表 SHA-256 校验未通过';
            continue;
          }

          final nextIndex = BangumiTmdbIndex.fromBytes(binBytes);
          if (nextIndex.isEmpty) {
            lastFailure = '映射表内容为空';
            continue;
          }

          await _persistAtomically(
            binBytes: binBytes,
            manifestBytes: Uint8List.fromList(manifestResp.bodyBytes),
          );
          await _savePrefsState(
            checkedAt: now,
            etag: nextEtag,
            mirrorBase: activeMirrorKey,
          );
          final nextDate = nextIndex.formattedSnapshotDate.isNotEmpty
              ? nextIndex.formattedSnapshotDate
              : parsed.snapshotDate;
          final nextSnapshot = BangumiTmdbSnapshot(
            index: nextIndex,
            source: BangumiTmdbMapSource.localHotUpdate,
            snapshotDate: nextDate,
            sha256Hex: actualSha,
            etag: nextEtag,
            lastCheckedAt: now,
            lastMirrorBase: activeMirrorKey,
          );
          return BangumiTmdbUpdateResult(
            state: BangumiTmdbUpdateState.updated,
            snapshot: nextSnapshot,
            message: nextDate.isNotEmpty
                ? '已更新至 ${nextIndex.uniqueBangumiCount} 条（$nextDate）'
                : '已更新至 ${nextIndex.uniqueBangumiCount} 条',
            mirrorUsed: base,
          );
        } catch (error) {
          lastFailure = NetworkErrorSanitizer.toUserMessage(error);
          developer.log(
            '映射表镜像检查失败，将尝试备用节点',
            name: 'konata.bangumi_tmdb_map_updater',
            error: error,
          );
        }
      }
    } finally {
      checkClient.close();
      downloadClient.close();
    }

    return BangumiTmdbUpdateResult(
      state: BangumiTmdbUpdateState.failed,
      snapshot: current,
      message: lastFailure ?? '无法连接更新镜像，已保留当前映射表',
    );
  }

  Future<BangumiTmdbSnapshot?> _tryLoadLocalSnapshot() async {
    try {
      final root = await _storageRoot.resolveAppRoot();
      final binFile = File(
        p.join(
          root.path,
          StoragePathConfig.userdataDirName,
          TmdbNetworkConfig.mappingBinaryFileName,
        ),
      );
      if (!await binFile.exists()) return null;
      final length = await binFile.length();
      if (length <= 0 || length > TmdbNetworkConfig.maxMappingBinaryBytes) {
        await _removeCorruptedLocalFile(binFile);
        return null;
      }
      final bytes = await binFile.readAsBytes();
      final index = BangumiTmdbIndex.fromBytes(bytes);
      if (index.isEmpty) {
        await _removeCorruptedLocalFile(binFile);
        return null;
      }
      final digest = sha256.convert(bytes).toString().toLowerCase();
      return BangumiTmdbSnapshot(
        index: index,
        source: BangumiTmdbMapSource.localHotUpdate,
        snapshotDate: index.formattedSnapshotDate,
        sha256Hex: digest,
      );
    } on FormatException catch (error) {
      developer.log(
        '本地映射表格式损坏，自动回退内置快照',
        name: 'konata.bangumi_tmdb_map_updater',
        error: error,
      );
      await _cleanupCorruptedLocalFiles();
      return null;
    } catch (error) {
      developer.log(
        '读取本地映射表失败，将回退内置快照',
        name: 'konata.bangumi_tmdb_map_updater',
        error: error,
      );
      return null;
    }
  }

  Future<BangumiTmdbSnapshot?> _tryLoadBundledSnapshot() async {
    try {
      final data = await _assetLoader(
        TmdbNetworkConfig.bundledMappingAssetPath,
      );
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      if (bytes.isEmpty ||
          bytes.length > TmdbNetworkConfig.maxMappingBinaryBytes) {
        return null;
      }
      final index = BangumiTmdbIndex.fromBytes(bytes);
      if (index.isEmpty) return null;
      final digest = sha256.convert(bytes).toString().toLowerCase();
      return BangumiTmdbSnapshot(
        index: index,
        source: BangumiTmdbMapSource.bundledAsset,
        snapshotDate: index.formattedSnapshotDate,
        sha256Hex: digest,
      );
    } catch (error) {
      developer.log(
        '读取内置映射表资产失败，将回退静态表',
        name: 'konata.bangumi_tmdb_map_updater',
        error: error,
      );
      return null;
    }
  }

  Future<void> _persistAtomically({
    required Uint8List binBytes,
    required Uint8List manifestBytes,
  }) async {
    final userdataDir = await _storageRoot.ensureUserdataDir();
    final stamp = _now().microsecondsSinceEpoch;
    final targetBin = File(
      p.join(userdataDir.path, TmdbNetworkConfig.mappingBinaryFileName),
    );
    final partBin = File('${targetBin.path}.part.$stamp');
    try {
      await partBin.writeAsBytes(binBytes, flush: true);
      await AtomicFileWriter.replaceFile(
        partBin,
        targetBin,
        expectedLength: binBytes.length,
      );
    } catch (_) {
      if (await partBin.exists()) {
        await partBin.delete().catchError((_) => partBin);
      }
      rethrow;
    }

    final targetManifest = File(
      p.join(userdataDir.path, TmdbNetworkConfig.localMappingManifestFileName),
    );
    final partManifest = File('${targetManifest.path}.part.$stamp');
    try {
      await partManifest.writeAsBytes(manifestBytes, flush: true);
      await AtomicFileWriter.replaceFile(
        partManifest,
        targetManifest,
        expectedLength: manifestBytes.length,
      );
    } catch (error) {
      if (await partManifest.exists()) {
        await partManifest.delete().catchError((_) => partManifest);
      }
      developer.log(
        '写入映射表本地清单缓存失败，保留已生效二进制索引',
        name: 'konata.bangumi_tmdb_map_updater',
        error: error,
      );
    }
  }

  Future<void> _cleanupCorruptedLocalFiles() async {
    try {
      final root = await _storageRoot.resolveAppRoot();
      final binFile = File(
        p.join(
          root.path,
          StoragePathConfig.userdataDirName,
          TmdbNetworkConfig.mappingBinaryFileName,
        ),
      );
      await _removeCorruptedLocalFile(binFile);
    } catch (error) {
      developer.log(
        '清理损坏本地映射表时发生可恢复异常',
        name: 'konata.bangumi_tmdb_map_updater',
        error: error,
      );
    }
  }

  Future<void> _removeCorruptedLocalFile(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (error) {
      developer.log(
        '删除损坏映射表文件失败',
        name: 'konata.bangumi_tmdb_map_updater',
        error: error,
      );
    }
  }

  Future<({DateTime? lastCheckedAt, String? etag, String? lastMirrorBase})>
  _readPrefsState() async {
    try {
      final prefs = await _prefsLoader();
      final ms = prefs.getInt(_prefLastCheckedMs);
      final etag = prefs.getString(_prefEtag)?.trim();
      final mirror = prefs.getString(_prefLastMirror)?.trim();
      return (
        lastCheckedAt: ms != null && ms > 0
            ? DateTime.fromMillisecondsSinceEpoch(ms)
            : null,
        etag: (etag != null && etag.isNotEmpty) ? etag : null,
        lastMirrorBase: (mirror != null && mirror.isNotEmpty) ? mirror : null,
      );
    } catch (error) {
      developer.log(
        '读取映射表检查状态偏好失败，采用默认值',
        name: 'konata.bangumi_tmdb_map_updater',
        error: error,
      );
      return (lastCheckedAt: null, etag: null, lastMirrorBase: null);
    }
  }

  Future<void> _savePrefsState({
    required DateTime checkedAt,
    required String? etag,
    required String mirrorBase,
  }) async {
    try {
      final prefs = await _prefsLoader();
      await prefs.setInt(_prefLastCheckedMs, checkedAt.millisecondsSinceEpoch);
      if (etag != null && etag.trim().isNotEmpty) {
        await prefs.setString(_prefEtag, etag.trim());
      } else {
        await prefs.remove(_prefEtag);
      }
      await prefs.setString(_prefLastMirror, mirrorBase);
    } catch (error) {
      developer.log(
        '保存映射表检查状态偏好失败',
        name: 'konata.bangumi_tmdb_map_updater',
        error: error,
      );
    }
  }

  static _ParsedManifest? _parseManifest(List<int> bodyBytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bodyBytes));
      if (decoded is! Map) return null;
      final schemaVersion = (decoded['schemaVersion'] as num?)?.toInt();
      if (schemaVersion != BangumiTmdbIndex.formatVersionV1 &&
          schemaVersion != BangumiTmdbIndex.formatVersionV2) {
        return null;
      }
      final sha = (decoded['binSha256'] ?? '').toString().trim().toLowerCase();
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) return null;
      final binBytes = (decoded['binBytes'] as num?)?.toInt() ?? 0;
      if (binBytes < 0 || binBytes > TmdbNetworkConfig.maxMappingBinaryBytes) {
        return null;
      }
      final snapshotDate = (decoded['snapshotDate'] ?? '').toString().trim();
      final dateInt = _parseDateYyyymmdd(snapshotDate);
      return _ParsedManifest(
        schemaVersion: schemaVersion!,
        binSha256: sha,
        binBytes: binBytes,
        snapshotDate: snapshotDate,
        snapshotDateYyyymmdd: dateInt,
      );
    } catch (_) {
      return null;
    }
  }

  static int _parseDateYyyymmdd(String raw) {
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(raw);
    if (m == null) return 0;
    final y = int.tryParse(m.group(1)!) ?? 0;
    final mo = int.tryParse(m.group(2)!) ?? 0;
    final d = int.tryParse(m.group(3)!) ?? 0;
    return y * 10000 + mo * 100 + d;
  }

  static String? _extractHeader(Map<String, String> headers, String key) {
    final lower = key.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == lower) {
        final v = entry.value.trim();
        return v.isEmpty ? null : v;
      }
    }
    return null;
  }
}

class _ParsedManifest {
  const _ParsedManifest({
    required this.schemaVersion,
    required this.binSha256,
    required this.binBytes,
    required this.snapshotDate,
    required this.snapshotDateYyyymmdd,
  });

  final int schemaVersion;
  final String binSha256;
  final int binBytes;
  final String snapshotDate;
  final int snapshotDateYyyymmdd;
}
