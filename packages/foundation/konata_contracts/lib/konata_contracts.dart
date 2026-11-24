/// Konata v3 核心跨包契约底座唯一公开出口。
///
/// 严禁跨包导入本包 `src/` 内部路径；所有调用方统一导入本文件。
library;

export 'src/extensions/extension_points.dart';
export 'src/media/media_extensions.dart';
export 'src/network/network_ports.dart';
export 'src/ports/app_navigator.dart';
export 'src/ports/diagnostic_log_port.dart';
export 'src/ports/domain_event_bus.dart';
export 'src/ports/read_query_ports.dart';
export 'src/ports/storage_ports.dart';
export 'src/sources/source_gateway_ports.dart';
export 'src/value_objects/artwork_ref.dart';
export 'src/value_objects/domain_enums.dart';
export 'src/value_objects/ids.dart';
export 'src/value_objects/lane_config.dart';
