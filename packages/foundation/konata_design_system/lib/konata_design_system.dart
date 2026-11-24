/// Konata v3 三端同源视觉设计系统唯一公开出口。
///
/// 严格 0 Riverpod、0 业务依赖、0 桌面原生插件依赖；
/// 严禁跨包导入本包 `src/` 内部路径，所有上层模块统一导入本文件。
library;

export 'src/shell/shell.dart';
export 'src/tokens/tokens.dart';
export 'src/widgets/widgets.dart';
