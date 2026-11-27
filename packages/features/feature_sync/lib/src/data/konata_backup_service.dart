import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import 'legacy_backup_migration.dart';
import 'library_catalog_sync_slice.dart';
import 'playback_history_sync_slice.dart';
import 'prefs_sync_slice.dart';
import 'sync_device_store.dart';
import 'sync_models.dart';

/// 本地 `.konata` 选择性备份导出、恢复预览与切片恢复服务。
final class KonataBackupService {
  /// 与旧版文件选择上限一致，防止误选大视频。
  static const int maxArchiveBytes = 32 * 1024 * 1024;

  /// 独立解压上限，防止小体积 gzip 耗尽设备内存。
  static const int maxDecodedArchiveBytes = 128 * 1024 * 1024;

  /// 在读取前检查大小，且读取期间继续限制增长中的文件。
  static Future<Uint8List> readArchiveFile(String path) async {
    final file = File(path);
    if (await file.length() > maxArchiveBytes) {
      throw const FormatException('备份文件超过 32 MiB 安全上限');
    }
    final bytes = _BoundedArchiveSink(maxArchiveBytes, '备份文件超过 32 MiB 安全上限');
    try {
      await for (final chunk in file.openRead()) {
        bytes.add(chunk);
      }
      return bytes.takeBytes();
    } finally {
      bytes.close();
    }
  }

  /// 创建备份恢复服务。
  KonataBackupService({
    required KonataDatabaseBundle databases,
    required ScopedPrefsStore scopedPrefs,
    required this._deviceStore,
    List<SyncSliceContributor<Object?>> extraSlices =
        const <SyncSliceContributor<Object?>>[],
    this._appVersion = '3.0.0',
    int Function()? nowMs,
    this._eventBus,
    this._diagnosticLog,
  }) : _databases = databases,
       _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
       _slices = _buildOrderedSlices(
         databases: databases,
         scopedPrefs: scopedPrefs,
         extraSlices: extraSlices,
         nowMs: nowMs,
       );

  final KonataDatabaseBundle _databases;
  final SyncDeviceStore _deviceStore;
  final String _appVersion;
  final int Function() _nowMs;
  final DomainEventBus? _eventBus;
  final DiagnosticLogPort? _diagnosticLog;
  final List<SyncSliceContributor<Object?>> _slices;

  /// 已注册的全部同步切片列表（内置切片在前，外部热插拔切片按注入顺序紧随其后）。
  List<SyncSliceContributor<Object?>> get registeredSlices => _slices;

  /// 根据 `sliceId` 查找已注册切片贡献者。
  SyncSliceContributor<Object?>? findSlice(String sliceId) {
    for (final slice in _slices) {
      if (slice.sliceId == sliceId) return slice;
    }
    return null;
  }

  /// 将选定的切片集合导出为 `.konata` 字节流（默认采用高压缩率 `gzip` 封装，未选切片或为空则抛出 [ArgumentError]）。
  Future<Uint8List> exportArchiveBytes({
    Set<String>? sliceIds,
    bool compressGzip = true,
  }) async {
    final selected = <SyncSliceContributor<Object?>>[
      for (final slice in _slices)
        if (sliceIds == null || sliceIds.contains(slice.sliceId)) slice,
    ];
    if (selected.isEmpty) {
      throw ArgumentError('请至少选择一个要导出的同步切片');
    }

    final deviceId = _deviceStore.getOrCreateDeviceId();
    final deviceName = _deviceStore.resolveLocalDeviceName();
    final now = _nowMs();

    final payloads = <SyncSlicePayload>[];
    for (final slice in selected) {
      payloads.add(await slice.exportSlice(localDeviceId: deviceId));
    }

    final archive = KonataBackupArchive.create(
      exportedAtMs: now,
      deviceId: deviceId,
      deviceName: deviceName,
      platform: Platform.operatingSystem,
      appVersion: _appVersion,
      slicePayloads: payloads,
    );

    final rawJson = jsonEncode(archive.toJson());
    final utf8Bytes = utf8.encode(rawJson);
    if (utf8Bytes.length > maxDecodedArchiveBytes) {
      throw const FormatException('备份解压后超过 128 MiB 安全上限，请分批导出');
    }
    final result = compressGzip ? gzip.encode(utf8Bytes) : utf8Bytes;
    if (result.length > maxArchiveBytes) {
      throw const FormatException('备份文件超过 32 MiB 安全上限，请分批导出');
    }
    return Uint8List.fromList(result);
  }

  /// 解析并校验 `.konata` 备份字节流（自动识别 `gzip` 或明文结构，并验证 `SHA-256` 完整性）。
  Future<KonataBackupArchive> decodeAndVerifyArchiveBytes(
    Uint8List rawBytes,
  ) async {
    return KonataBackupArchive.parseAndVerify(_decodeArchiveJson(rawBytes));
  }

  String _decodeArchiveJson(Uint8List rawBytes) {
    if (rawBytes.isEmpty) {
      throw const FormatException('备份文件为空');
    }

    if (rawBytes.length > maxArchiveBytes) {
      throw const FormatException('备份文件超过 32 MiB 安全上限');
    }
    List<int> jsonBytes = rawBytes;
    if (rawBytes.length >= 2 && rawBytes[0] == 0x1f && rawBytes[1] == 0x8b) {
      final output = _BoundedArchiveSink(
        maxDecodedArchiveBytes,
        '备份解压后超过 128 MiB 安全上限',
      );
      try {
        final decoder = gzip.decoder.startChunkedConversion(output);
        // 分段输入，解码器不能一次接收整个压缩文件。
        const chunkSize = 16 * 1024;
        for (var start = 0; start < rawBytes.length; start += chunkSize) {
          final end = (start + chunkSize).clamp(0, rawBytes.length);
          decoder.add(Uint8List.sublistView(rawBytes, start, end));
        }
        decoder.close();
        jsonBytes = output.takeBytes();
      } on _ArchiveSizeException catch (error) {
        throw FormatException(error.message);
      } catch (_) {
        throw const FormatException('备份压缩数据已损坏，无法解压');
      }
    }

    final String rawJson;
    try {
      rawJson = utf8.decode(jsonBytes);
    } catch (_) {
      throw const FormatException('备份文件编码不是有效的 UTF-8 文本');
    }

    return rawJson;
  }

  Future<(KonataBackupArchive, int?)> _decodeForRestore(
    Uint8List rawBytes,
    KonataRestoreMode mode,
  ) async {
    final rawJson = _decodeArchiveJson(rawBytes);
    final Object? decoded;
    try {
      decoded = jsonDecode(rawJson);
    } on FormatException {
      throw const FormatException('备份文件不是有效的 JSON 格式');
    }
    if (!LegacyBackupMigration.isLegacy(decoded)) {
      return (KonataBackupArchive.parseAndVerify(rawJson), null);
    }
    if (mode != KonataRestoreMode.smartMerge) {
      throw const FormatException('旧版 Konata v1/v2 备份仅支持智能合并；未导入任何数据');
    }
    final localCatalog = await findSlice(
      LibraryCatalogSyncSlice.id,
    )!.exportSlice(localDeviceId: '');
    try {
      final archive = LegacyBackupMigration.convert(
        decoded,
        localCatalog: localCatalog.data,
      );
      return (archive, (decoded as Map)['formatVersion'] as int);
    } on FormatException {
      rethrow;
    } on TypeError {
      throw const FormatException('旧版 Konata v1/v2 备份字段类型不合法；未导入任何数据');
    }
  }

  /// 导入前对指定 `.konata` 字节流执行干跑预览，输出每个切片的新增/更新/删除计数。
  Future<KonataBackupPreviewReport> previewRestore(
    Uint8List rawBytes, {
    KonataRestoreMode mode = KonataRestoreMode.smartMerge,
    Set<String>? sliceIds,
  }) async {
    final (archive, legacyVersion) = await _decodeForRestore(rawBytes, mode);
    final deviceId = _deviceStore.getOrCreateDeviceId();
    final previews = <KonataSlicePreview>[];

    for (final contributor in _slices) {
      if (sliceIds != null && !sliceIds.contains(contributor.sliceId)) {
        continue;
      }
      final remotePayload = archive.slices[contributor.sliceId];
      if (remotePayload == null) {
        previews.add(
          KonataSlicePreview(
            sliceId: contributor.sliceId,
            displayName: contributor.displayName,
            insertCount: 0,
            updateCount: 0,
            deleteCount: 0,
            skippedCount: 0,
            remoteAvailable: false,
            summaryLines: const <String>['备份文件中未包含此切片'],
          ),
        );
        continue;
      }

      final localPayload = await contributor.exportSlice(
        localDeviceId: deviceId,
      );
      final plan = _planForContributor(
        contributor: contributor,
        localPayload: localPayload,
        remotePayload: remotePayload,
        mode: mode,
        localDeviceId: deviceId,
      );
      previews.add(
        KonataSlicePreview(
          sliceId: contributor.sliceId,
          displayName: contributor.displayName,
          insertCount: plan.insertCount,
          updateCount: plan.updateCount,
          deleteCount: plan.deleteCount,
          skippedCount: plan.skippedCount,
          summaryLines: plan.summaryLines,
        ),
      );
    }

    final unrecognized = <String>[
      for (final id in archive.sliceIds)
        if (findSlice(id) == null) id,
    ];

    return KonataBackupPreviewReport(
      exportedAt: DateTime.fromMillisecondsSinceEpoch(archive.exportedAtMs),
      deviceId: archive.deviceId,
      deviceName: archive.deviceName,
      platform: archive.platform,
      appVersion: archive.appVersion,
      archiveSliceIds: archive.sliceIds,
      slicePreviews: List<KonataSlicePreview>.unmodifiable(previews),
      unrecognizedSliceIds: List<String>.unmodifiable(unrecognized),
      legacyFormatVersion: legacyVersion,
    );
  }

  /// 在两个数据库各自的事务内应用选中的恢复切片，两库提交后记录元信息并发布同步完成事件。
  Future<KonataSyncOutcome> restoreFromArchiveBytes(
    Uint8List rawBytes, {
    Set<String>? selectedSliceIds,
    KonataRestoreMode mode = KonataRestoreMode.smartMerge,
  }) async {
    final (archive, legacyVersion) = await _decodeForRestore(rawBytes, mode);
    if (legacyVersion == 2 &&
        selectedSliceIds != null &&
        !selectedSliceIds.containsAll(archive.sliceIds)) {
      throw const FormatException('旧版完整目录必须与备份中其余切片一次性恢复，避免部分导入后无法继续迁移');
    }
    final deviceId = _deviceStore.getOrCreateDeviceId();
    final now = _nowMs();

    final plannedRuns = <_PlannedSliceApply>[];
    final outcomes = <KonataSlicePreview>[];
    final updatedSliceIds = <String>{};

    for (final contributor in _slices) {
      if (selectedSliceIds != null &&
          !selectedSliceIds.contains(contributor.sliceId)) {
        continue;
      }
      final remotePayload = archive.slices[contributor.sliceId];
      if (remotePayload == null) {
        continue;
      }

      final localPayload = await contributor.exportSlice(
        localDeviceId: deviceId,
      );
      final plan = _planForContributor(
        contributor: contributor,
        localPayload: localPayload,
        remotePayload: remotePayload,
        mode: mode,
        localDeviceId: deviceId,
      );

      final preview = KonataSlicePreview(
        sliceId: contributor.sliceId,
        displayName: contributor.displayName,
        insertCount: plan.insertCount,
        updateCount: plan.updateCount,
        deleteCount: plan.deleteCount,
        skippedCount: plan.skippedCount,
        summaryLines: plan.summaryLines,
      );
      outcomes.add(preview);

      final shouldApply =
          plan.hasChanges || mode == KonataRestoreMode.overwrite;
      if (shouldApply) {
        updatedSliceIds.add(contributor.sliceId);
      }
      plannedRuns.add(_PlannedSliceApply(contributor: contributor, plan: plan));
    }

    _databases.library.engine.runTransaction((libTx) {
      _databases.userState.engine.runTransaction((userTx) {
        final txCtx = DatabaseBundleSyncTransactionContext(
          localDeviceId: deviceId,
          appliedAtMs: now,
          libraryTx: libTx,
          userStateTx: userTx,
        );
        for (final item in plannedRuns) {
          item.apply(txCtx);
        }
      });
    });

    final result = KonataSyncOutcome(
      channel: SyncChannelIds.localBackup,
      updatedSliceIds: Set<String>.unmodifiable(updatedSliceIds),
      sliceOutcomes: List<KonataSlicePreview>.unmodifiable(outcomes),
    );

    _deviceStore.writeMeta(
      SyncDeviceStore.metaKeyLocalBackupLastAtMs,
      '$now',
      updatedAtMs: now,
    );
    _deviceStore.writeMeta(
      SyncDeviceStore.metaKeyLocalBackupLastSummary,
      result.toSummaryMessage(),
      updatedAtMs: now,
    );

    _diagnosticLog?.logEvent(
      subsystem: DiagnosticSubsystem.sync,
      severity: DiagnosticSeverity.info,
      code: 'sync.local_backup.restored',
      message: '完成本地备份恢复：${result.toSummaryMessage()}',
      context: <String, Object?>{
        'mode': mode.name,
        'sliceCount': outcomes.length,
        'updatedSlices': updatedSliceIds.toList()..sort(),
      },
    );

    _eventBus?.publish(
      SyncCompletedEvent(
        channel: SyncChannelIds.localBackup,
        updatedSliceIds: result.updatedSliceIds,
        occurredAtMs: now,
      ),
    );

    return result;
  }

  SyncMergePlan<Object?> _planForContributor({
    required SyncSliceContributor<Object?> contributor,
    required SyncSlicePayload localPayload,
    required SyncSlicePayload remotePayload,
    required KonataRestoreMode mode,
    required String localDeviceId,
  }) {
    if (remotePayload.schemaVersion != contributor.schemaVersion) {
      throw FormatException(
        '备份切片 ${contributor.sliceId} 版本不兼容：${remotePayload.schemaVersion}',
      );
    }
    if (mode == KonataRestoreMode.smartMerge) {
      return contributor.planMerge(local: localPayload, remote: remotePayload);
    }

    if (contributor is PrefsSyncSlice) {
      return contributor.planOverwrite(
        local: localPayload,
        remote: remotePayload,
        localDeviceId: localDeviceId,
      );
    }

    if (contributor is LibraryCatalogSyncSlice) {
      return contributor.planOverwrite(
        local: localPayload,
        remote: remotePayload,
      );
    }

    if (contributor is PlaybackHistorySyncSlice) {
      final emptyLocal = SyncSlicePayload(
        sliceId: contributor.sliceId,
        schemaVersion: contributor.schemaVersion,
        exportedAtMs: 0,
        sourceDeviceId: localDeviceId,
        data: const <String, Object?>{},
      );
      final rawPlan = contributor.planMerge(
        local: emptyLocal,
        remote: remotePayload,
      );
      return SyncMergePlan<PlaybackHistoryMergePlan>(
        sliceId: rawPlan.sliceId,
        insertCount: rawPlan.insertCount,
        updateCount: rawPlan.updateCount,
        deleteCount: rawPlan.deleteCount,
        skippedCount: rawPlan.skippedCount,
        planData: PlaybackHistoryMergePlan(
          recordsToUpsert: rawPlan.planData.recordsToUpsert,
          clearExistingBeforeApply: true,
        ),
        summaryLines: <String>[
          '观看进度（覆盖还原）：重建 ${rawPlan.planData.recordsToUpsert.length} 条记录',
        ],
      );
    }

    final emptyLocal = SyncSlicePayload(
      sliceId: contributor.sliceId,
      schemaVersion: contributor.schemaVersion,
      exportedAtMs: 0,
      sourceDeviceId: localDeviceId,
      data: const <String, Object?>{},
    );
    return contributor.planMerge(local: emptyLocal, remote: remotePayload);
  }

  static List<SyncSliceContributor<Object?>> _buildOrderedSlices({
    required KonataDatabaseBundle databases,
    required ScopedPrefsStore scopedPrefs,
    required List<SyncSliceContributor<Object?>> extraSlices,
    required int Function()? nowMs,
  }) {
    final result = <SyncSliceContributor<Object?>>[
      PrefsSyncSlice(
        userStateDb: databases.userState,
        scopedPrefs: scopedPrefs,
        nowMs: nowMs,
      ),
      PlaybackHistorySyncSlice(databases: databases, nowMs: nowMs),
      LibraryCatalogSyncSlice(libraryDb: databases.library, nowMs: nowMs),
    ];
    final seenIds = <String>{for (final item in result) item.sliceId};
    for (final extra in extraSlices) {
      if (seenIds.add(extra.sliceId)) {
        result.add(extra);
      }
    }
    return List<SyncSliceContributor<Object?>>.unmodifiable(result);
  }
}

/// 仅在上限内累计字节，供文件读取与流式解压共享。
final class _BoundedArchiveSink implements Sink<List<int>> {
  _BoundedArchiveSink(this.limit, this.message);
  final int limit;
  final String message;
  final BytesBuilder _bytes = BytesBuilder(copy: false);

  @override
  void add(List<int> data) {
    if (data.length > limit - _bytes.length) {
      throw _ArchiveSizeException(message);
    }
    _bytes.add(data);
  }

  @override
  void close() {}

  Uint8List takeBytes() => _bytes.takeBytes();
}

final class _ArchiveSizeException extends FormatException {
  const _ArchiveSizeException(super.message);
}

final class _PlannedSliceApply {
  const _PlannedSliceApply({required this.contributor, required this.plan});

  final SyncSliceContributor<Object?> contributor;
  final SyncMergePlan<Object?> plan;

  SyncApplyCompletion apply(SyncTransactionContext tx) {
    return contributor.applyMergePlan(tx, plan);
  }
}
