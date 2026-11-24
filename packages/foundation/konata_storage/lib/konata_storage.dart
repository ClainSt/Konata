/// Konata v3 纯 Dart 存储底座唯一公开出口。
///
/// 严禁跨包导入本包 `src/` 内部路径；所有调用方统一导入本文件。
library;

export 'src/bundle/konata_database_bundle.dart';
export 'src/cache/cache.dart';
export 'src/engine/konata_sqlite_engine.dart';
export 'src/engine/table_change_bus.dart';
export 'src/library/library.dart';
export 'src/logging/diagnostic_log_store.dart';
export 'src/paths/portable_storage_root_service.dart';
export 'src/prefs/scoped_prefs_store.dart';
export 'src/user_state/user_state.dart';
