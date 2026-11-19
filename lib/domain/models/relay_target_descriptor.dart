/// 跨平台外部接力目标轻量摘要（Android 始终为空列表，桌面由组装根投影外部程序配置）。
class RelayTargetDescriptor {
  /// 创建外部接力目标摘要。
  const RelayTargetDescriptor({
    required this.id,
    required this.name,
    required this.kindKey,
    required this.isDefault,
    required this.configured,
  });

  /// 目标唯一主键。
  final String id;

  /// 面向用户的展示名称。
  final String name;

  /// 类别键名（如 `mpv`、`custom`）。
  final String kindKey;

  /// 是否为默认接力目标。
  final bool isDefault;

  /// 是否已填写有效可执行路径。
  final bool configured;
}
