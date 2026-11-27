import 'dart:async';
import 'dart:typed_data';

import 'package:engine_sources/engine_sources.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import 'data/konata_backup_service.dart';
import 'data/legacy_backup_migration.dart';
import 'data/sync_device_store.dart';
import 'data/sync_models.dart';
import 'data/webdav_sync_config_repository.dart';
import 'data/webdav_sync_transport.dart';
import 'state/sync_backup_controller.dart';
import 'state/webdav_sync_coordinator.dart';

/// 备份与同步特性模块由宿主注入的全部外部基础依赖与动态扩展切片集合。
final class FeatureSyncDependencies {
  /// 创建备份与同步模块外部依赖集合。
  const FeatureSyncDependencies({
    required this.databases,
    required this.scopedPrefs,
    required this.secureStorage,
    this.backupFilePort = const NoopBackupFilePort(),
    this.eventBus,
    this.diagnosticLog,
    this.extraSlices = const <SyncSliceContributor<Object?>>[],
    this.appVersion = '3.0.0',
    this.connectionPool,
    this.httpClientFactory,
    this.readFileBytes,
    this.readLegacyCue,
    this.nowMs,
  });

  /// 三库统一存储实例（提供 `library` 与 `userState` 数据库读写及事务控制）。
  final KonataDatabaseBundle databases;

  /// 作用域偏好存储器（非敏感配置存放处）。
  final ScopedPrefsStore scopedPrefs;

  /// 安全凭据存储端口（WebDAV 登录密码唯一读写来源）。
  final SecureStoragePort secureStorage;

  /// 本地备份文件选取与保存抽象端口。
  final BackupFilePort backupFilePort;

  /// 领域事件总线（同步与恢复落盘后发布 `SyncCompletedEvent`）。
  final DomainEventBus? eventBus;

  /// 可选结构化诊断日志端口。
  final DiagnosticLogPort? diagnosticLog;

  /// 外部业务模块动态挂载的自定义同步切片（如歌词人工修正切片等）。
  final List<SyncSliceContributor<Object?>> extraSlices;

  /// 宿主当前应用版本号（写入导出归档清单）。
  final String appVersion;

  /// 可选复用 WebDAV HTTP 连接池。
  final WebDavConnectionPool? connectionPool;

  /// 可选 HTTP 客户端构造工厂（测试注入离线模拟传输层使用）。
  final http.Client Function(WebDavSyncConfig config)? httpClientFactory;

  /// 可选文件字节流读取函数（测试注入内存文件读取使用）。
  final Future<Uint8List> Function(String path)? readFileBytes;

  /// 本机已索引 CUE 的只读核验端口。
  final LegacyCueReader? readLegacyCue;

  /// 可选统一时钟函数（返回 UTC 毫秒）。
  final int Function()? nowMs;
}

/// 宿主注入点：未在根容器中覆盖时抛出明确配置异常。
final Provider<FeatureSyncDependencies> featureSyncDependenciesProvider =
    Provider<FeatureSyncDependencies>((ref) {
      throw UnimplementedError('必须在宿主应用根容器中覆盖 featureSyncDependenciesProvider');
    });

/// 同步设备元信息与增量水位仓储提供者。
final Provider<SyncDeviceStore> syncDeviceStoreProvider =
    Provider<SyncDeviceStore>((ref) {
      final deps = ref.watch(featureSyncDependenciesProvider);
      return SyncDeviceStore(
        deps.databases.userState.syncMeta,
        nowMs: deps.nowMs,
      );
    });

/// WebDAV 非敏感配置与安全存储密码联合仓储提供者。
final Provider<WebDavSyncConfigRepository> webDavSyncConfigRepositoryProvider =
    Provider<WebDavSyncConfigRepository>((ref) {
      final deps = ref.watch(featureSyncDependenciesProvider);
      return WebDavSyncConfigRepository(
        scopedPrefs: deps.scopedPrefs,
        secureStorage: deps.secureStorage,
      );
    });

/// WebDAV 远端切片压缩传输客户端提供者。
final Provider<WebDavSyncTransport> webDavSyncTransportProvider =
    Provider<WebDavSyncTransport>((ref) {
      final deps = ref.watch(featureSyncDependenciesProvider);
      return WebDavSyncTransport(
        connectionPool: deps.connectionPool,
        clientFactory: deps.httpClientFactory,
      );
    });

/// `.konata` 本地选择性备份导出与干跑恢复服务提供者。
final Provider<KonataBackupService> konataBackupServiceProvider =
    Provider<KonataBackupService>((ref) {
      final deps = ref.watch(featureSyncDependenciesProvider);
      final deviceStore = ref.watch(syncDeviceStoreProvider);
      return KonataBackupService(
        databases: deps.databases,
        scopedPrefs: deps.scopedPrefs,
        deviceStore: deviceStore,
        extraSlices: deps.extraSlices,
        appVersion: deps.appVersion,
        nowMs: deps.nowMs,
        eventBus: deps.eventBus,
        diagnosticLog: deps.diagnosticLog,
        readLegacyCue: deps.readLegacyCue,
      );
    });

/// WebDAV 多设备分片协同调度器提供者。
final Provider<WebDavSyncCoordinator> webDavSyncCoordinatorProvider =
    Provider<WebDavSyncCoordinator>((ref) {
      final deps = ref.watch(featureSyncDependenciesProvider);
      final deviceStore = ref.watch(syncDeviceStoreProvider);
      final transport = ref.watch(webDavSyncTransportProvider);
      return WebDavSyncCoordinator(
        databases: deps.databases,
        scopedPrefs: deps.scopedPrefs,
        deviceStore: deviceStore,
        transport: transport,
        extraSlices: deps.extraSlices,
        nowMs: deps.nowMs,
        eventBus: deps.eventBus,
        diagnosticLog: deps.diagnosticLog,
      );
    });

/// 设置面板与宿主事件联动使用的备份同步控制器提供者。
final Provider<SyncBackupController> syncBackupControllerProvider =
    Provider<SyncBackupController>((ref) {
      final deps = ref.watch(featureSyncDependenciesProvider);
      final backupService = ref.watch(konataBackupServiceProvider);
      final configRepo = ref.watch(webDavSyncConfigRepositoryProvider);
      final coordinator = ref.watch(webDavSyncCoordinatorProvider);
      final deviceStore = ref.watch(syncDeviceStoreProvider);

      final controller = SyncBackupController(
        backupService: backupService,
        configRepository: configRepo,
        webDavCoordinator: coordinator,
        deviceStore: deviceStore,
        backupFilePort: deps.backupFilePort,
        readFileBytes: deps.readFileBytes,
        nowMs: deps.nowMs,
      );
      unawaited(controller.initialize(triggerStartupAutoSync: true));
      ref.onDispose(controller.dispose);
      return controller;
    });
