import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:path/path.dart' as p;

import '../data/konata_backup_service.dart';
import '../data/sync_device_store.dart';
import '../data/sync_models.dart';
import '../data/webdav_sync_config_repository.dart';
import '../data/webdav_sync_transport.dart';
import 'webdav_sync_coordinator.dart';

/// 供设置面板动态展示的切片元信息条目。
final class SyncSliceInfo {
  /// 创建切片元信息条目。
  const SyncSliceInfo({
    required this.sliceId,
    required this.displayName,
    required this.schemaVersion,
  });

  /// 切片稳定唯一标识。
  final String sliceId;

  /// 切片简体中文展示名称。
  final String displayName;

  /// 切片数据结构版本号。
  final int schemaVersion;
}

/// 选中 `.konata` 备份文件并完成干跑解析后的预览数据包。
final class PickedBackupArchiveData {
  /// 创建备份干跑预览数据包。
  const PickedBackupArchiveData({
    required this.fileName,
    required this.bytes,
    required this.report,
    required this.mode,
  });

  /// 所选备份文件名。
  final String fileName;

  /// 原始归档字节流（确认恢复后直接复用）。
  final Uint8List bytes;

  /// 干跑 `planMerge` 生成的恢复变更预览报告。
  final KonataBackupPreviewReport report;

  /// 本次预览采用的目标恢复策略。
  final KonataRestoreMode mode;
}

/// `feature_sync` 备份与同步页面的不可变视图状态快照（零 `Riverpod` 依赖）。
final class SyncBackupState {
  /// 创建同步与备份视图状态。
  const SyncBackupState({
    this.isInitialized = false,
    this.isExporting = false,
    this.isPreparingImport = false,
    this.isRestoring = false,
    this.isTestingWebDav = false,
    this.isSyncingWebDav = false,
    this.deviceId = '',
    this.deviceName = '',
    this.availableSlices = const <SyncSliceInfo>[],
    this.exportSelectedSliceIds = const <String>{},
    this.restoreMode = KonataRestoreMode.smartMerge,
    this.lastLocalBackupAtMs,
    this.lastLocalBackupSummary,
    this.webDavConfig = const WebDavSyncConfig(),
    this.lastWebDavSyncAtMs,
    this.lastWebDavSyncSummary,
    this.webDavTestSuccessMessage,
    this.lastErrorMessage,
  });

  /// 是否已完成初始状态读取。
  final bool isInitialized;

  /// 是否正在执行本地备份导出。
  final bool isExporting;

  /// 是否正在读取并解析待导入备份。
  final bool isPreparingImport;

  /// 是否正在应用备份恢复事务。
  final bool isRestoring;

  /// 是否正在测试 WebDAV 连通性。
  final bool isTestingWebDav;

  /// 是否正在执行 WebDAV 多设备分片同步。
  final bool isSyncingWebDav;

  /// 本机持久化设备标识。
  final String deviceId;

  /// 本机展示名称。
  final String deviceName;

  /// 当前已注册的全部可选同步切片元信息。
  final List<SyncSliceInfo> availableSlices;

  /// 当前勾选用于本地备份导出的切片集合。
  final Set<String> exportSelectedSliceIds;

  /// 默认本地恢复策略。
  final KonataRestoreMode restoreMode;

  /// 最近一次本地备份导出或恢复时间（UTC 毫秒）。
  final int? lastLocalBackupAtMs;

  /// 最近一次本地备份操作摘要。
  final String? lastLocalBackupSummary;

  /// 当前持久化读取的 WebDAV 配置。
  final WebDavSyncConfig webDavConfig;

  /// 最近一次 WebDAV 同步时间（UTC 毫秒）。
  final int? lastWebDavSyncAtMs;

  /// 最近一次 WebDAV 同步摘要。
  final String? lastWebDavSyncSummary;

  /// 最近一次测试连接的成功提示。
  final String? webDavTestSuccessMessage;

  /// 最近一次操作异常提示（脱敏后中文说明）。
  final String? lastErrorMessage;

  /// 当前是否存在任意阻塞式后台操作。
  bool get isBusy =>
      isExporting ||
      isPreparingImport ||
      isRestoring ||
      isTestingWebDav ||
      isSyncingWebDav;

  /// 复制并修改指定状态字段。
  SyncBackupState copyWith({
    bool? isInitialized,
    bool? isExporting,
    bool? isPreparingImport,
    bool? isRestoring,
    bool? isTestingWebDav,
    bool? isSyncingWebDav,
    String? deviceId,
    String? deviceName,
    List<SyncSliceInfo>? availableSlices,
    Set<String>? exportSelectedSliceIds,
    KonataRestoreMode? restoreMode,
    int? lastLocalBackupAtMs,
    String? lastLocalBackupSummary,
    WebDavSyncConfig? webDavConfig,
    int? lastWebDavSyncAtMs,
    String? lastWebDavSyncSummary,
    String? webDavTestSuccessMessage,
    bool clearWebDavTestSuccessMessage = false,
    String? lastErrorMessage,
    bool clearLastErrorMessage = false,
  }) {
    return SyncBackupState(
      isInitialized: isInitialized ?? this.isInitialized,
      isExporting: isExporting ?? this.isExporting,
      isPreparingImport: isPreparingImport ?? this.isPreparingImport,
      isRestoring: isRestoring ?? this.isRestoring,
      isTestingWebDav: isTestingWebDav ?? this.isTestingWebDav,
      isSyncingWebDav: isSyncingWebDav ?? this.isSyncingWebDav,
      deviceId: deviceId ?? this.deviceId,
      deviceName: deviceName ?? this.deviceName,
      availableSlices: availableSlices ?? this.availableSlices,
      exportSelectedSliceIds:
          exportSelectedSliceIds ?? this.exportSelectedSliceIds,
      restoreMode: restoreMode ?? this.restoreMode,
      lastLocalBackupAtMs: lastLocalBackupAtMs ?? this.lastLocalBackupAtMs,
      lastLocalBackupSummary:
          lastLocalBackupSummary ?? this.lastLocalBackupSummary,
      webDavConfig: webDavConfig ?? this.webDavConfig,
      lastWebDavSyncAtMs: lastWebDavSyncAtMs ?? this.lastWebDavSyncAtMs,
      lastWebDavSyncSummary:
          lastWebDavSyncSummary ?? this.lastWebDavSyncSummary,
      webDavTestSuccessMessage: clearWebDavTestSuccessMessage
          ? null
          : (webDavTestSuccessMessage ?? this.webDavTestSuccessMessage),
      lastErrorMessage: clearLastErrorMessage
          ? null
          : (lastErrorMessage ?? this.lastErrorMessage),
    );
  }
}

/// 备份导出、干跑预览恢复与 WebDAV 自动/手动同步核心控制器（纯 `ChangeNotifier`，零 `Riverpod` 依赖）。
final class SyncBackupController extends ChangeNotifier {
  /// 创建备份与同步状态控制器。
  SyncBackupController({
    required this._backupService,
    required this._configRepository,
    required this._webDavCoordinator,
    required this._deviceStore,
    this._backupFilePort = const NoopBackupFilePort(),
    Future<Uint8List> Function(String path)? readFileBytes,
    int Function()? nowMs,
  }) : _readFileBytes = readFileBytes ?? _defaultReadFileBytes,
       _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final KonataBackupService _backupService;
  final WebDavSyncConfigRepository _configRepository;
  final WebDavSyncCoordinator _webDavCoordinator;
  final SyncDeviceStore _deviceStore;
  final BackupFilePort _backupFilePort;
  final Future<Uint8List> Function(String path) _readFileBytes;
  final int Function() _nowMs;

  SyncBackupState _state = const SyncBackupState();
  Timer? _periodicTimer;
  Timer? _playbackStopDebounce;
  bool _disposed = false;

  /// 当前同步与备份状态快照。
  SyncBackupState get state => _state;

  /// 读取持久化设备信息、切片注册清单及 WebDAV 配置，并按需开启后台定时同步。
  Future<void> initialize({bool triggerStartupAutoSync = false}) async {
    final deviceId = _deviceStore.getOrCreateDeviceId();
    final deviceName = _deviceStore.resolveLocalDeviceName();
    final webDavConfig = await _configRepository.load();

    final sliceInfos = <SyncSliceInfo>[
      for (final slice in _backupService.registeredSlices)
        SyncSliceInfo(
          sliceId: slice.sliceId,
          displayName: slice.displayName,
          schemaVersion: slice.schemaVersion,
        ),
    ];

    final allSliceIds = <String>{for (final info in sliceInfos) info.sliceId};
    final selectedExport = _state.exportSelectedSliceIds.isEmpty
        ? allSliceIds
        : _state.exportSelectedSliceIds.where(allSliceIds.contains).toSet();

    _setState(
      _state.copyWith(
        isInitialized: true,
        deviceId: deviceId,
        deviceName: deviceName,
        availableSlices: List<SyncSliceInfo>.unmodifiable(sliceInfos),
        exportSelectedSliceIds: Set<String>.unmodifiable(selectedExport),
        lastLocalBackupAtMs: int.tryParse(
          _deviceStore.readMeta(SyncDeviceStore.metaKeyLocalBackupLastAtMs) ??
              '',
        ),
        lastLocalBackupSummary: _deviceStore.readMeta(
          SyncDeviceStore.metaKeyLocalBackupLastSummary,
        ),
        webDavConfig: webDavConfig,
        lastWebDavSyncAtMs: int.tryParse(
          _deviceStore.readMeta(SyncDeviceStore.metaKeyWebDavLastSyncMs) ?? '',
        ),
        lastWebDavSyncSummary: _deviceStore.readMeta(
          SyncDeviceStore.metaKeyWebDavLastSummary,
        ),
      ),
    );

    _reschedulePeriodicTimer();

    if (triggerStartupAutoSync &&
        webDavConfig.enabled &&
        webDavConfig.autoSyncOnStartup &&
        webDavConfig.hasValidServerUrl) {
      unawaited(syncNow(silent: true));
    }
  }

  /// 切换本地导出切片勾选状态。
  void toggleExportSlice(String sliceId, bool selected) {
    final next = Set<String>.of(_state.exportSelectedSliceIds);
    if (selected) {
      next.add(sliceId);
    } else {
      next.remove(sliceId);
    }
    _setState(
      _state.copyWith(exportSelectedSliceIds: Set<String>.unmodifiable(next)),
    );
  }

  /// 批量设置本地导出切片勾选集合。
  void setExportSelectedSliceIds(Set<String> sliceIds) {
    _setState(
      _state.copyWith(
        exportSelectedSliceIds: Set<String>.unmodifiable(sliceIds),
      ),
    );
  }

  /// 更新本地恢复默认策略。
  void setRestoreMode(KonataRestoreMode mode) {
    _setState(_state.copyWith(restoreMode: mode));
  }

  /// 打包选定切片为 `.konata` 归档并通过 `BackupFilePort.saveFile` 导出，用户取消则返回 `null`。
  Future<String?> exportBackupToFilePort({Set<String>? sliceIds}) async {
    final targetIds = sliceIds ?? _state.exportSelectedSliceIds;
    _setState(_state.copyWith(isExporting: true, clearLastErrorMessage: true));
    try {
      final bytes = await _backupService.exportArchiveBytes(
        sliceIds: targetIds,
      );
      final now = DateTime.fromMillisecondsSinceEpoch(_nowMs());
      final suffix = _formatFileTimestamp(now);
      final savedPath = await _backupFilePort.saveFile(
        fileName: 'konata_backup_$suffix.konata',
        bytes: bytes,
        dialogTitle: '导出 Konata 备份文件',
      );
      if (savedPath == null || savedPath.trim().isEmpty) {
        return null;
      }

      final nowMsValue = _nowMs();
      final summary = '已导出 ${targetIds.length} 个切片（${p.basename(savedPath)}）';
      _deviceStore.writeMeta(
        SyncDeviceStore.metaKeyLocalBackupLastAtMs,
        '$nowMsValue',
        updatedAtMs: nowMsValue,
      );
      _deviceStore.writeMeta(
        SyncDeviceStore.metaKeyLocalBackupLastSummary,
        summary,
        updatedAtMs: nowMsValue,
      );
      _setState(
        _state.copyWith(
          lastLocalBackupAtMs: nowMsValue,
          lastLocalBackupSummary: summary,
        ),
      );
      return savedPath;
    } catch (error) {
      _setState(_state.copyWith(lastErrorMessage: _toUserError(error)));
      rethrow;
    } finally {
      _setState(_state.copyWith(isExporting: false));
    }
  }

  /// 通过 `BackupFilePort.pickBackupFile` 选择 `.konata` 文件并执行干跑预览，取消选择返回 `null`。
  Future<PickedBackupArchiveData?> pickAndPreviewBackup({
    KonataRestoreMode? mode,
  }) async {
    _setState(
      _state.copyWith(isPreparingImport: true, clearLastErrorMessage: true),
    );
    try {
      final selectedPath = await _backupFilePort.pickBackupFile(
        dialogTitle: '选择 Konata 备份文件',
        allowedExtensions: const <String>['konata', 'json'],
      );
      if (selectedPath == null || selectedPath.trim().isEmpty) {
        return null;
      }
      final bytes = await _readFileBytes(selectedPath);
      final effectiveMode = mode ?? _state.restoreMode;
      final report = await _backupService.previewRestore(
        bytes,
        mode: effectiveMode,
      );
      return PickedBackupArchiveData(
        fileName: p.basename(selectedPath),
        bytes: bytes,
        report: report,
        mode: effectiveMode,
      );
    } catch (error) {
      _setState(_state.copyWith(lastErrorMessage: _toUserError(error)));
      rethrow;
    } finally {
      _setState(_state.copyWith(isPreparingImport: false));
    }
  }

  /// 对给定内存字节流执行导入前干跑 `planMerge` 预览（适用于重新切换恢复模式刷新计数）。
  Future<PickedBackupArchiveData> previewBackupBytes(
    Uint8List bytes, {
    required String fileName,
    KonataRestoreMode? mode,
  }) async {
    _setState(
      _state.copyWith(isPreparingImport: true, clearLastErrorMessage: true),
    );
    try {
      final effectiveMode = mode ?? _state.restoreMode;
      final report = await _backupService.previewRestore(
        bytes,
        mode: effectiveMode,
      );
      return PickedBackupArchiveData(
        fileName: fileName,
        bytes: bytes,
        report: report,
        mode: effectiveMode,
      );
    } catch (error) {
      _setState(_state.copyWith(lastErrorMessage: _toUserError(error)));
      rethrow;
    } finally {
      _setState(_state.copyWith(isPreparingImport: false));
    }
  }

  /// 应用选定切片的备份恢复并在落盘后刷新元信息摘要。
  Future<KonataSyncOutcome> restoreBackupBytes(
    Uint8List bytes, {
    required Set<String> selectedSliceIds,
    KonataRestoreMode? mode,
  }) async {
    _setState(_state.copyWith(isRestoring: true, clearLastErrorMessage: true));
    try {
      final outcome = await _backupService.restoreFromArchiveBytes(
        bytes,
        selectedSliceIds: selectedSliceIds,
        mode: mode ?? _state.restoreMode,
      );
      _setState(
        _state.copyWith(
          lastLocalBackupAtMs: int.tryParse(
            _deviceStore.readMeta(SyncDeviceStore.metaKeyLocalBackupLastAtMs) ??
                '',
          ),
          lastLocalBackupSummary: _deviceStore.readMeta(
            SyncDeviceStore.metaKeyLocalBackupLastSummary,
          ),
        ),
      );
      return outcome;
    } catch (error) {
      _setState(_state.copyWith(lastErrorMessage: _toUserError(error)));
      rethrow;
    } finally {
      _setState(_state.copyWith(isRestoring: false));
    }
  }

  /// 持久化保存 WebDAV 配置（URL/用户名/开关写入 `ScopedPrefsStore`，密码仅写入 `SecureStoragePort`）。
  Future<void> saveWebDavConfig(WebDavSyncConfig config) async {
    final deviceId = _state.deviceId.isEmpty
        ? _deviceStore.getOrCreateDeviceId()
        : _state.deviceId;
    await _configRepository.save(config, sourceDeviceId: deviceId);
    final saved = await _configRepository.load();
    _setState(
      _state.copyWith(
        deviceId: deviceId,
        webDavConfig: saved,
        clearWebDavTestSuccessMessage: true,
        clearLastErrorMessage: true,
      ),
    );
    _reschedulePeriodicTimer();
  }

  /// 测试当前表单或已保存的 WebDAV 配置连通性。
  Future<void> testWebDavConnection(WebDavSyncConfig config) async {
    _setState(
      _state.copyWith(
        isTestingWebDav: true,
        clearWebDavTestSuccessMessage: true,
        clearLastErrorMessage: true,
      ),
    );
    try {
      await _webDavCoordinator.testConnection(config);
      _setState(_state.copyWith(webDavTestSuccessMessage: '连接成功，已验证同步目录读写'));
    } catch (error) {
      _setState(_state.copyWith(lastErrorMessage: _toUserError(error)));
      rethrow;
    } finally {
      _setState(_state.copyWith(isTestingWebDav: false));
    }
  }

  /// 触发一次 WebDAV 多设备双向同步（若传入草稿配置则先持久化保存再执行）。
  Future<KonataSyncOutcome?> syncNow({
    WebDavSyncConfig? draftConfig,
    bool silent = false,
  }) async {
    _setState(
      _state.copyWith(isSyncingWebDav: true, clearLastErrorMessage: true),
    );
    try {
      if (draftConfig != null) {
        await saveWebDavConfig(draftConfig);
      }
      final activeConfig = _state.webDavConfig;
      final outcome = await _webDavCoordinator.syncNow(activeConfig);
      _setState(
        _state.copyWith(
          lastWebDavSyncAtMs: int.tryParse(
            _deviceStore.readMeta(SyncDeviceStore.metaKeyWebDavLastSyncMs) ??
                '',
          ),
          lastWebDavSyncSummary: _deviceStore.readMeta(
            SyncDeviceStore.metaKeyWebDavLastSummary,
          ),
        ),
      );
      return outcome;
    } catch (error) {
      _setState(_state.copyWith(lastErrorMessage: _toUserError(error)));
      if (!silent) {
        rethrow;
      }
      return null;
    } finally {
      _setState(_state.copyWith(isSyncingWebDav: false));
    }
  }

  /// 通知播放停止，若启用“停播自动同步”则在防抖后静默触发一次上传同步。
  void notifyPlaybackStopped() {
    if (_disposed) return;
    final config = _state.webDavConfig;
    if (!config.enabled ||
        !config.autoSyncOnPlaybackStop ||
        !config.hasValidServerUrl) {
      return;
    }
    _playbackStopDebounce?.cancel();
    _playbackStopDebounce = Timer(const Duration(seconds: 2), () {
      if (!_disposed) {
        unawaited(syncNow(silent: true));
      }
    });
  }

  void _reschedulePeriodicTimer() {
    _periodicTimer?.cancel();
    _periodicTimer = null;
    final config = _state.webDavConfig;
    if (!config.enabled ||
        config.autoSyncIntervalMinutes <= 0 ||
        !config.hasValidServerUrl) {
      return;
    }
    _periodicTimer = Timer.periodic(
      Duration(minutes: config.autoSyncIntervalMinutes),
      (_) {
        if (!_disposed) {
          unawaited(syncNow(silent: true));
        }
      },
    );
  }

  void _setState(SyncBackupState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _periodicTimer?.cancel();
    _playbackStopDebounce?.cancel();
    super.dispose();
  }

  static Future<Uint8List> _defaultReadFileBytes(String path) =>
      KonataBackupService.readArchiveFile(path);

  static String _formatFileTimestamp(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}${two(dt.month)}${two(dt.day)}_${two(dt.hour)}${two(dt.minute)}';
  }

  static String _toUserError(Object error) {
    if (error is WebDavSyncException) {
      return error.message;
    }
    if (error is FormatException) {
      return error.message;
    }
    if (error is ArgumentError) {
      return error.message?.toString() ?? '参数无效';
    }
    return NetworkErrorSanitizer.toUserMessage(error);
  }
}
