import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../domain/formatting/network_error_sanitizer.dart';
import '../../domain/logging/diagnostic_event.dart';
import '../../domain/sync/konata_sync_merge_engine.dart';
import '../../domain/sync/konata_sync_models.dart';
import '../../infrastructure/logging/diagnostics_log_store.dart';
import '../../infrastructure/sources/webdav_source_gateway.dart';
import '../../infrastructure/sync/konata_sync_store.dart';
import '../../infrastructure/sync/webdav_sync_transport.dart';
import 'konata_backup_service.dart';

/// WebDAV 多设备分片同步协调器（单飞互斥、设备分片零锁竞争、确定性无冲突合并）。
class WebDavSyncCoordinator {
  /// 创建 WebDAV 同步协调器。
  WebDavSyncCoordinator({
    required this._backupService,
    required this._syncStore,
    WebDavConnectionPool? connectionPool,
    this._logStore,
    this._httpClientForTest,
    DateTime Function()? clock,
  }) : _pool = connectionPool,
       _clock = clock ?? DateTime.now;

  final KonataBackupService _backupService;
  final KonataSyncStore _syncStore;
  final WebDavConnectionPool? _pool;
  final DiagnosticsLogStore? _logStore;
  final http.Client? _httpClientForTest;
  final DateTime Function() _clock;

  Future<KonataSyncOutcome>? _inFlightSync;

  /// 测试目标 WebDAV 同步目录连接与读写认证（成功返回 `null`，失败返回中文原因）。
  Future<String?> testConnection(WebDavSyncConfig config) {
    final transport = _createTransport(config);
    return transport.testConnection();
  }

  /// 执行一次完整的「拉取其它设备分片 -> 冲突消解落库 -> 上传本机最新分片与清单」多设备同步。
  Future<KonataSyncOutcome> syncNow(WebDavSyncConfig config) {
    final active = _inFlightSync;
    if (active != null) return active;
    final run = _runSyncInternal(config);
    _inFlightSync = run;
    return run.whenComplete(() {
      if (identical(_inFlightSync, run)) {
        _inFlightSync = null;
      }
    });
  }

  Future<KonataSyncOutcome> _runSyncInternal(WebDavSyncConfig config) async {
    if (!config.hasValidServerUrl) {
      throw StateError('请先填写有效的 WebDAV 同步服务器地址');
    }
    final scope = config.syncScope;
    if (!scope.hasAnySelected) {
      throw StateError('请至少选择一项要同步的内容');
    }

    final startedAt = _clock();
    final deviceId = await _syncStore.getOrCreateDeviceId();
    final deviceName = _syncStore.resolveLocalDeviceName();
    final transport = _createTransport(config);

    _logStore?.recordBreadcrumb(
      category: 'sync',
      label: '开始 WebDAV 多设备同步',
      detail: scope.describeLabel(),
      source: 'lib/application/sync/webdav_sync_coordinator.dart:syncNow',
    );
    _logStore?.logEvent(
      subsystem: DiagnosticSubsystem.sync,
      code: 'SYNC_WEBDAV_STARTED',
      message: '开始执行 WebDAV 分片多设备同步（${scope.describeLabel()}）',
      source: 'lib/application/sync/webdav_sync_coordinator.dart:_runSyncInternal',
      context: <String, Object?>{
        'deviceId': deviceId,
        'remoteDir': config.normalizedRemoteDir,
        'scope': scope.describeLabel(),
        'intervalMinutes': config.autoSyncIntervalMinutes,
      },
    );

    try {
      await transport.ensureDeviceDirectories(deviceId);
      final existingManifest =
          await transport.fetchManifest() ?? const WebDavSyncManifest();

      // 仅下载除本机外的其余活跃设备分片，避免重复拉取自身历史数据。
      final remoteSnapshots = <KonataSyncSnapshotEnvelope>[];
      for (final entry in existingManifest.devices.entries) {
        if (entry.key == deviceId) continue;
        final shardPath = entry.value.shardPath;
        if (shardPath.trim().isEmpty) continue;
        try {
          final snap = await transport.downloadDeviceShard(shardPath);
          if (snap != null) {
            remoteSnapshots.add(snap);
          }
        } catch (error, stackTrace) {
          // 单个远端设备分片损坏时记录诊断异常并跳过，不阻塞其余健康设备同步。
          _logStore?.logError(
            subsystem: DiagnosticSubsystem.sync,
            severity: DiagnosticSeverity.warn,
            code: 'SYNC_WEBDAV_SHARD_SKIPPED',
            message: '跳过无法读取或校验失败的远端设备分片：${entry.key}',
            error: error,
            stackTrace: stackTrace,
            source:
                'lib/application/sync/webdav_sync_coordinator.dart:_runSyncInternal',
            context: <String, Object?>{
              'remoteDeviceId': entry.key,
              'shardPath': shardPath,
            },
          );
        }
      }

      final localBefore = await _backupService.buildLocalSnapshotEnvelope(
        scope: scope,
      );
      final nowMs = _clock().millisecondsSinceEpoch;
      final merged = KonataSyncMergeEngine.merge(
        localPlaybacks: localBefore.playbackEntries,
        localOverrides: localBefore.workOverrides,
        localTombstones: localBefore.tombstones,
        localPreferences: localBefore.preferences,
        remoteSnapshots: remoteSnapshots,
        nowMs: nowMs,
        localCatalog: scope.includeWorkOverrides
            ? localBefore.libraryCatalog
            : null,
        localDeviceId: deviceId,
      );

      final applyOutcome = await _backupService.applyMergedState(
        merged,
        applyLibraryCatalog:
            scope.includeWorkOverrides &&
            (merged.hasMergedCatalog || merged.suppressedWorkKeys.isNotEmpty),
        applyPlaybacks: scope.includePlaybacks,
        applyWorkOverrides: scope.includeWorkOverrides,
        applyPreferences:
            scope.includePreferences &&
            remoteSnapshots.isNotEmpty &&
            merged.mergedPreferences.updatedAtMs >
                localBefore.preferences.updatedAtMs,
        remoteDevicesMerged: remoteSnapshots.length,
        uploadedShard: true,
      );

      // 落库后再按当前勾选范围重建本机最新分片并上传，未勾选项绝不向外泄露或误改他端状态。
      final postMergeSnapshot = await _backupService.buildLocalSnapshotEnvelope(
        scope: scope,
      );
      final shardPath = await transport.uploadDeviceShard(
        deviceId: deviceId,
        envelope: postMergeSnapshot,
      );

      final updatedManifest = existingManifest.withDevice(
        WebDavSyncDeviceWatermark(
          deviceId: deviceId,
          deviceName: deviceName,
          platform: Platform.operatingSystem,
          updatedAtMs: postMergeSnapshot.exportedAtMs,
          shardPath: shardPath,
          shardSha256: postMergeSnapshot.payloadSha256,
        ),
      );
      await transport.uploadManifest(updatedManifest);

      final summary = applyOutcome.toSummaryMessage();
      final finishedMs = _clock().millisecondsSinceEpoch;
      await _syncStore.writeMeta(
        KonataSyncStore.metaKeyWebDavLastSyncMs,
        finishedMs.toString(),
        updatedAtMs: finishedMs,
      );
      await _syncStore.writeMeta(
        KonataSyncStore.metaKeyWebDavLastSummary,
        summary,
        updatedAtMs: finishedMs,
      );

      final elapsedMs = _clock().difference(startedAt).inMilliseconds;
      _logStore?.logEvent(
        subsystem: DiagnosticSubsystem.sync,
        code: 'SYNC_WEBDAV_COMPLETED',
        message: 'WebDAV 多设备同步完成：$summary',
        source:
            'lib/application/sync/webdav_sync_coordinator.dart:_runSyncInternal',
        context: <String, Object?>{
          'elapsedMs': elapsedMs,
          'remoteDevices': remoteSnapshots.length,
          'playbacksUpdated': applyOutcome.playbacksUpdated,
          'workOverridesApplied': applyOutcome.workOverridesApplied,
          'tombstonesApplied': applyOutcome.tombstonesApplied,
        },
      );
      return applyOutcome;
    } catch (error, stackTrace) {
      final friendly = NetworkErrorSanitizer.toUserMessage(
        error,
        prefix: 'WebDAV 同步失败',
      );
      _logStore?.logError(
        subsystem: DiagnosticSubsystem.sync,
        code: 'SYNC_WEBDAV_FAILED',
        message: friendly,
        error: error,
        stackTrace: stackTrace,
        source:
            'lib/application/sync/webdav_sync_coordinator.dart:_runSyncInternal',
      );
      rethrow;
    }
  }

  WebDavSyncTransport _createTransport(WebDavSyncConfig config) {
    return WebDavSyncTransport(
      config: config,
      connectionPool: _pool,
      httpClient: _httpClientForTest,
      logStore: _logStore,
    );
  }
}
