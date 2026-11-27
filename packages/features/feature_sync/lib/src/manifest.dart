import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import 'data/library_catalog_sync_slice.dart';
import 'data/playback_history_sync_slice.dart';
import 'data/prefs_sync_slice.dart';
import 'providers.dart';
import 'ui/settings_backup_sync_panel.dart';

Widget _buildBackupSyncSettingsSection(ViewSlotContext ctx) {
  return const SettingsBackupSyncPanel(embedded: true);
}

Widget _mountSyncRuntime(Object child) => Consumer(
  child: child as Widget,
  builder: (context, ref, child) {
    ref.watch(syncBackupControllerProvider);
    return child!;
  },
);

/// 备份与同步功能模块静态注册清单（默认声明设置分组与内置三切片元数据）。
const FeatureManifest featureSyncManifest = FeatureManifest(
  id: 'feature_sync',
  displayName: '备份与同步',
  wrapRuntime: _mountSyncRuntime,
  settingsSections: <SettingsSectionContribution>[
    SettingsSectionContribution(
      id: 'backup_sync',
      title: '备份与同步',
      subtitle: '本地 .konata 选择性归档备份还原与 WebDAV 多设备分片协同',
      iconKey: 'sync',
      order: 50,
      viewBuilder: _buildBackupSyncSettingsSection,
    ),
  ],
  syncSlices: <SyncSliceContributor<Object?>>[
    PrefsSyncSlice.unbound(),
    PlaybackHistorySyncSlice.unbound(),
    LibraryCatalogSyncSlice.unbound(),
  ],
);

/// 构造绑定持久化存储句柄的 `feature_sync` 模块扩展清单（供需要直接持有可读写切片的场景使用）。
FeatureManifest createFeatureSyncManifest({
  required KonataDatabaseBundle databases,
  required ScopedPrefsStore scopedPrefs,
  int Function()? nowMs,
}) {
  return FeatureManifest(
    id: 'feature_sync',
    displayName: '备份与同步',
    wrapRuntime: featureSyncManifest.wrapRuntime,
    settingsSections: featureSyncManifest.settingsSections,
    syncSlices: <SyncSliceContributor<Object?>>[
      PrefsSyncSlice(
        userStateDb: databases.userState,
        scopedPrefs: scopedPrefs,
        nowMs: nowMs,
      ),
      PlaybackHistorySyncSlice(databases: databases, nowMs: nowMs),
      LibraryCatalogSyncSlice(libraryDb: databases.library, nowMs: nowMs),
    ],
  );
}
