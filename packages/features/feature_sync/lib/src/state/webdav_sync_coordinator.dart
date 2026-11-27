import 'dart:io';
import 'dart:math' as math;

import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import '../data/konata_backup_service.dart';
import '../data/prefs_sync_slice.dart';
import '../data/sync_device_store.dart';
import '../data/sync_models.dart';
import '../data/webdav_sync_transport.dart';

/// WebDAV 多设备分片双向协同调度器（零框架依赖）。
///
/// 协调逻辑遵循以下协议步骤：
/// 1. 准备远端 `<remoteDir>/` 与 `slices/` 目录并拉取 `manifest.json`；
/// 2. 对比远端各设备切片水位 `sha256` 与本机已合并水位，跳过未变分片零无效下载；
/// 3. 将有变更的远端切片分轮次在统一双库写事务中调用 `planMerge` / `applyMergePlan` 合并落盘；
/// 4. 重新导出本机参与同步的切片并按 `sha256` 跳过未变切片，仅上传变化分片并更新 `manifest.json`。
final class WebDavSyncCoordinator {
  /// 创建 WebDAV 多设备协同调度器。
  WebDavSyncCoordinator({
    required KonataDatabaseBundle databases,
    required ScopedPrefsStore scopedPrefs,
    required this._deviceStore,
    required this._transport,
    List<SyncSliceContributor<Object?>> extraSlices =
        const <SyncSliceContributor<Object?>>[],
    int Function()? nowMs,
    this._eventBus,
    this._diagnosticLog,
  }) : _databases = databases,
       _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
       _slices = KonataBackupService(
         databases: databases,
         scopedPrefs: scopedPrefs,
         deviceStore: _deviceStore,
         extraSlices: extraSlices,
         nowMs: nowMs,
       ).registeredSlices;

  final KonataDatabaseBundle _databases;
  final SyncDeviceStore _deviceStore;
  final WebDavSyncTransport _transport;
  final int Function() _nowMs;
  final DomainEventBus? _eventBus;
  final DiagnosticLogPort? _diagnosticLog;
  final List<SyncSliceContributor<Object?>> _slices;

  Future<KonataSyncOutcome>? _inFlightSync;

  /// 已注册的全部可协同切片清单。
  List<SyncSliceContributor<Object?>> get registeredSlices => _slices;

  /// 验证当前 WebDAV 配置连通性与远端同步目录可访问性。
  Future<void> testConnection(WebDavSyncConfig config) async {
    await _transport.testConnection(config);
  }

  /// 执行一次端到端 WebDAV 多设备分片同步（单飞并发保护，防止定时轮询与手动点击重入冲突）。
  Future<KonataSyncOutcome> syncNow(WebDavSyncConfig config) {
    final active = _inFlightSync;
    if (active != null) {
      return active;
    }
    final future = _runSync(config).whenComplete(() {
      _inFlightSync = null;
    });
    _inFlightSync = future;
    return future;
  }

  Future<KonataSyncOutcome> _runSync(WebDavSyncConfig config) async {
    if (!config.hasValidServerUrl) {
      throw const WebDavSyncException('请先配置有效的 WebDAV 服务器地址');
    }

    final localDeviceId = _deviceStore.getOrCreateDeviceId();
    final localDeviceName = _deviceStore.resolveLocalDeviceName();
    final activeSliceIds = config.resolveActiveSliceIds(
      _slices.map((s) => s.sliceId),
    );
    if (activeSliceIds.isEmpty) {
      return const KonataSyncOutcome(
        channel: SyncChannelIds.webDav,
        updatedSliceIds: <String>{},
        sliceOutcomes: <KonataSlicePreview>[],
      );
    }

    final activeSlices = <SyncSliceContributor<Object?>>[
      for (final s in _slices)
        if (activeSliceIds.contains(s.sliceId)) s,
    ];

    await _transport.ensureSyncDirectories(config);
    final initialSnapshot = await _transport.fetchManifest(config);
    final existingManifest = initialSnapshot.manifest;
    _requireCompatibleVersions(existingManifest, activeSlices);

    // 第一阶段：按 SHA-256 过滤并下载存在更新的远端切片分片。
    var downloadedShardsCount = 0;
    var skippedDownloadsCount = 0;
    final remoteDevicesMerged = <String>{};
    final downloadedBySlice = <String, List<DownloadedSliceShard>>{};

    for (final contributor in activeSlices) {
      final remoteEntries = existingManifest.remoteEntriesForSlice(
        sliceId: contributor.sliceId,
        localDeviceId: localDeviceId,
      );
      final shardsForSlice = <DownloadedSliceShard>[];
      for (final wm in remoteEntries) {
        final lastMergedSha = _deviceStore.readRemoteSliceSha256(
          wm.sliceId,
          wm.deviceId,
        );
        if (wm.sha256.isNotEmpty && lastMergedSha == wm.sha256) {
          skippedDownloadsCount++;
          continue;
        }
        final downloaded = await _transport.downloadSliceShard(config, wm);
        downloadedShardsCount++;
        remoteDevicesMerged.add(wm.deviceId);
        shardsForSlice.add(downloaded);
      }
      if (shardsForSlice.isNotEmpty) {
        downloadedBySlice[contributor.sliceId] = shardsForSlice;
      }
    }

    // 第二阶段：分轮次在统一双库写事务中应用合并计划，并记录各切片变更计数。
    final aggregatedCounts = <String, _MutableSliceCounts>{
      for (final s in activeSlices)
        s.sliceId: _MutableSliceCounts(
          sliceId: s.sliceId,
          displayName: s.displayName,
        ),
    };
    final updatedSliceIds = <String>{};

    var maxRounds = 0;
    for (final list in downloadedBySlice.values) {
      maxRounds = math.max(maxRounds, list.length);
    }

    for (var round = 0; round < maxRounds; round++) {
      final plannedRuns = <_CoordinatorPlannedApply>[];
      final roundWatermarks = <WebDavSliceWatermark>[];

      for (final contributor in activeSlices) {
        final shards = downloadedBySlice[contributor.sliceId];
        if (shards == null || round >= shards.length) {
          continue;
        }
        final shard = shards[round];
        final localPayload = await contributor.exportSlice(
          localDeviceId: localDeviceId,
        );
        final plan = contributor.planMerge(
          local: localPayload,
          remote: shard.payload,
        );
        aggregatedCounts[contributor.sliceId]!.addPlan(plan);
        if (plan.hasChanges) {
          updatedSliceIds.add(contributor.sliceId);
        }
        plannedRuns.add(
          _CoordinatorPlannedApply(contributor: contributor, plan: plan),
        );
        roundWatermarks.add(shard.watermark);
      }

      if (plannedRuns.isEmpty) continue;

      final roundNow = _nowMs();
      _databases.library.engine.runTransaction((libTx) {
        _databases.userState.engine.runTransaction((userTx) {
          final txCtx = DatabaseBundleSyncTransactionContext(
            localDeviceId: localDeviceId,
            appliedAtMs: roundNow,
            libraryTx: libTx,
            userStateTx: userTx,
          );
          for (final item in plannedRuns) {
            item.apply(txCtx);
          }
        });
      });

      for (final wm in roundWatermarks) {
        _deviceStore.writeRemoteSliceSha256(wm.sliceId, wm.deviceId, wm.sha256);
      }
    }

    // 第三阶段：导出本机最新切片并按 SHA-256 跳过未变分片，仅上传改动项并更新 manifest.json。
    var uploadedShardsCount = 0;
    var skippedUploadsCount = 0;
    final pendingWatermarks = <WebDavSliceWatermark>[];
    final uploadNow = _nowMs();

    for (final contributor in activeSlices) {
      final localPayload = await contributor.exportSlice(
        localDeviceId: localDeviceId,
      );
      final localSha = SyncSanitizer.computeSliceDataSha256(
        sliceId: contributor.sliceId,
        schemaVersion: contributor.schemaVersion,
        data: localPayload.data,
      );

      final existingSelfEntry = existingManifest.findEntry(
        contributor.sliceId,
        localDeviceId,
      );
      if (existingSelfEntry != null && existingSelfEntry.sha256 == localSha) {
        skippedUploadsCount++;
        _deviceStore.writeLocalSliceSha256(contributor.sliceId, localSha);
        continue;
      }

      initialSnapshot.requireWritable();
      final shardPath = WebDavSyncTransport.buildShardRelativePath(
        sliceId: contributor.sliceId,
        deviceId: localDeviceId,
        sha256: localSha,
      );
      final nextWatermark = WebDavSliceWatermark(
        sliceId: contributor.sliceId,
        deviceId: localDeviceId,
        deviceName: localDeviceName,
        platform: Platform.operatingSystem,
        schemaVersion: contributor.schemaVersion,
        updatedAtMs: uploadNow,
        shardPath: shardPath,
        sha256: localSha,
      );

      await _transport.uploadSliceShard(
        config: config,
        watermark: nextWatermark,
        payload: localPayload,
      );
      pendingWatermarks.add(nextWatermark);
      uploadedShardsCount++;
    }

    if (pendingWatermarks.isNotEmpty) {
      var snapshot = initialSnapshot;
      for (var attempt = 0; ; attempt++) {
        var nextManifest = snapshot.manifest;
        for (final wm in pendingWatermarks) {
          final original = existingManifest.findEntry(wm.sliceId, wm.deviceId);
          final latest = snapshot.manifest.findEntry(wm.sliceId, wm.deviceId);
          if (latest?.sha256 != original?.sha256 &&
              latest?.sha256 != wm.sha256) {
            throw const WebDavSyncException('同一设备分片已被其他会话更新，请重新同步');
          }
          nextManifest = nextManifest.withEntry(wm);
        }
        try {
          await _transport.uploadManifest(
            config,
            nextManifest,
            expected: snapshot,
          );
          break;
        } on WebDavSyncException catch (error) {
          if (error.statusCode != 412 || attempt >= 3) rethrow;
          // 仅合并本轮变更，保留其他设备已经发布的水位。
          snapshot = await _transport.fetchManifest(config);
          _requireCompatibleVersions(snapshot.manifest, activeSlices);
        }
      }
      // 清单成功发布后才记录本机上传水位。
      for (final wm in pendingWatermarks) {
        _deviceStore.writeLocalSliceSha256(wm.sliceId, wm.sha256);
      }
    }

    final outcomes = <KonataSlicePreview>[
      for (final s in activeSlices) aggregatedCounts[s.sliceId]!.build(),
    ];

    final result = KonataSyncOutcome(
      channel: SyncChannelIds.webDav,
      updatedSliceIds: Set<String>.unmodifiable(updatedSliceIds),
      sliceOutcomes: List<KonataSlicePreview>.unmodifiable(outcomes),
      downloadedShards: downloadedShardsCount,
      uploadedShards: uploadedShardsCount,
      skippedUnchangedDownloads: skippedDownloadsCount,
      skippedUnchangedUploads: skippedUploadsCount,
      remoteDevicesMerged: remoteDevicesMerged.length,
    );

    final finishedAt = _nowMs();
    _deviceStore.writeMeta(
      SyncDeviceStore.metaKeyWebDavLastSyncMs,
      '$finishedAt',
      updatedAtMs: finishedAt,
    );
    _deviceStore.writeMeta(
      SyncDeviceStore.metaKeyWebDavLastSummary,
      result.toSummaryMessage(),
      updatedAtMs: finishedAt,
    );

    _diagnosticLog?.logEvent(
      subsystem: DiagnosticSubsystem.sync,
      severity: DiagnosticSeverity.info,
      code: 'sync.webdav.completed',
      message: 'WebDAV 同步完成：${result.toSummaryMessage()}',
      context: <String, Object?>{
        'downloadedShards': downloadedShardsCount,
        'uploadedShards': uploadedShardsCount,
        'skippedDownloads': skippedDownloadsCount,
        'skippedUploads': skippedUploadsCount,
        'updatedSlices': updatedSliceIds.toList()..sort(),
      },
    );

    if (updatedSliceIds.isNotEmpty) {
      _eventBus?.publish(
        SyncCompletedEvent(
          channel: SyncChannelIds.webDav,
          updatedSliceIds: result.updatedSliceIds,
          occurredAtMs: finishedAt,
        ),
      );
    }

    return result;
  }

  /// 已启用切片的所有设备须使用兼容版本；降级后的本机水位也不能覆盖。
  void _requireCompatibleVersions(
    WebDavSyncManifest manifest,
    List<SyncSliceContributor<Object?>> activeSlices,
  ) {
    final contributors = {
      for (final slice in activeSlices) slice.sliceId: slice,
    };
    for (final entry in manifest.slices.values) {
      final contributor = contributors[entry.sliceId];
      final compatible = contributor is PrefsSyncSlice
          ? contributor.canReadVersion(entry.schemaVersion)
          : contributor == null ||
                entry.schemaVersion == contributor.schemaVersion;
      if (!compatible) {
        throw WebDavSyncException('同步切片 ${entry.sliceId} 版本不兼容，请统一客户端版本');
      }
    }
  }
}

final class _CoordinatorPlannedApply {
  const _CoordinatorPlannedApply({
    required this.contributor,
    required this.plan,
  });

  final SyncSliceContributor<Object?> contributor;
  final SyncMergePlan<Object?> plan;

  SyncApplyCompletion apply(SyncTransactionContext tx) {
    return contributor.applyMergePlan(tx, plan);
  }
}

final class _MutableSliceCounts {
  _MutableSliceCounts({required this.sliceId, required this.displayName});

  final String sliceId;
  final String displayName;
  int insertCount = 0;
  int updateCount = 0;
  int deleteCount = 0;
  int skippedCount = 0;
  final List<String> summaryLines = <String>[];

  void addPlan(SyncMergePlan<Object?> plan) {
    insertCount += plan.insertCount;
    updateCount += plan.updateCount;
    deleteCount += plan.deleteCount;
    skippedCount += plan.skippedCount;
    summaryLines.addAll(plan.summaryLines);
  }

  KonataSlicePreview build() => KonataSlicePreview(
    sliceId: sliceId,
    displayName: displayName,
    insertCount: insertCount,
    updateCount: updateCount,
    deleteCount: deleteCount,
    skippedCount: skippedCount,
    summaryLines: List<String>.unmodifiable(summaryLines),
  );
}
