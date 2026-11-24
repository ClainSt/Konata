import 'dart:io';
import 'dart:math';

import 'package:konata_storage/konata_storage.dart';

/// 同步设备标识与增量水位仓储（基于 `user_state.db` 的 `sync_meta` 表，严禁存放敏感凭据）。
final class SyncDeviceStore {
  /// 创建同步元信息仓储。
  SyncDeviceStore(
    this._syncMetaDao, {
    this._random,
    int Function()? nowMs,
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// 元信息键：本机持久设备标识。
  static const String metaKeyDeviceId = 'device_id';

  /// 元信息键：WebDAV 最近同步时间（UTC 毫秒）。
  static const String metaKeyWebDavLastSyncMs = 'webdav_last_sync_ms';

  /// 元信息键：WebDAV 最近同步摘要。
  static const String metaKeyWebDavLastSummary = 'webdav_last_summary';

  /// 元信息键：本地备份最近恢复时间（UTC 毫秒）。
  static const String metaKeyLocalBackupLastAtMs = 'local_backup_last_at_ms';

  /// 元信息键：本地备份最近恢复摘要。
  static const String metaKeyLocalBackupLastSummary =
      'local_backup_last_summary';

  static const String _remoteShaPrefix = 'webdav_remote_sha256::';
  static const String _localShaPrefix = 'webdav_local_sha256::';

  final SyncMetaDao _syncMetaDao;
  final Random? _random;
  final int Function() _nowMs;

  /// 读取或首次生成持久不变的本机设备标识。
  String getOrCreateDeviceId() {
    final existing = _syncMetaDao.get(metaKeyDeviceId)?.value.trim() ?? '';
    if (existing.isNotEmpty) {
      return existing;
    }
    final rng = _random ?? Random.secure();
    final bytes = List<int>.generate(12, (_) => rng.nextInt(256));
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final prefix = Platform.operatingSystem.toLowerCase();
    final generated = '${prefix}_$hex';
    _syncMetaDao.put(metaKeyDeviceId, generated, updatedAtMs: _nowMs());
    return generated;
  }

  /// 获取用于远端同步清单展示的可读设备名称。
  String resolveLocalDeviceName() {
    try {
      final host = Platform.localHostname.trim();
      if (host.isNotEmpty) {
        return '$host (${Platform.operatingSystem})';
      }
    } catch (_) {
      return 'Konata (${Platform.operatingSystem})';
    }
    return 'Konata (${Platform.operatingSystem})';
  }

  /// 读取指定元信息键。
  String? readMeta(String key) => _syncMetaDao.get(key)?.value;

  /// 写入指定元信息键。
  void writeMeta(String key, String value, {int? updatedAtMs}) {
    _syncMetaDao.put(key, value, updatedAtMs: updatedAtMs ?? _nowMs());
  }

  /// 读取远端设备某切片上次成功合并时的 `SHA-256`。
  String? readRemoteSliceSha256(String sliceId, String remoteDeviceId) {
    return readMeta('$_remoteShaPrefix$sliceId::$remoteDeviceId');
  }

  /// 记录远端设备某切片最近成功合并时的 `SHA-256`。
  void writeRemoteSliceSha256(
    String sliceId,
    String remoteDeviceId,
    String sha256,
  ) {
    writeMeta('$_remoteShaPrefix$sliceId::$remoteDeviceId', sha256);
  }

  /// 读取本机某切片上次成功上传至 WebDAV 的 `SHA-256`。
  String? readLocalSliceSha256(String sliceId) {
    return readMeta('$_localShaPrefix$sliceId');
  }

  /// 记录本机某切片最近成功上传至 WebDAV 的 `SHA-256`。
  void writeLocalSliceSha256(String sliceId, String sha256) {
    writeMeta('$_localShaPrefix$sliceId', sha256);
  }
}
