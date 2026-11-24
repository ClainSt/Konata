/// 强类型业务实体标识符定义（消除裸 `String` ID 混传导致的编译期漏检）。
library;

/// 校验强类型标识符非空白的统一辅助函数。
String _requireNonBlankId(String raw, String typeName) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    throw ArgumentError.value(raw, typeName, '$typeName 不能为空白字符串');
  }
  return trimmed;
}

/// 作品强类型主键（与磁盘物理目录路径解耦）。
extension type const WorkId._(String value) {
  /// 构造并校验非空作品标识。
  factory WorkId(String raw) => WorkId._(_requireNonBlankId(raw, 'WorkId'));

  /// 从已校验存储记录构造常量标识。
  const WorkId.trusted(this.value);
}

/// 逻辑剧集 / 特典强类型主键。
extension type const EpisodeId._(String value) {
  /// 构造并校验非空剧集标识。
  factory EpisodeId(String raw) =>
      EpisodeId._(_requireNonBlankId(raw, 'EpisodeId'));

  /// 从已校验存储记录构造常量标识。
  const EpisodeId.trusted(this.value);
}

/// 媒体源强类型主键。
extension type const SourceId._(String value) {
  /// 构造并校验非空媒体源标识。
  factory SourceId(String raw) =>
      SourceId._(_requireNonBlankId(raw, 'SourceId'));

  /// 从已校验存储记录构造常量标识。
  const SourceId.trusted(this.value);
}

/// 系列（Series）编组强类型主键。
extension type const SeriesGroupId._(String value) {
  /// 构造并校验非空系列标识。
  factory SeriesGroupId(String raw) =>
      SeriesGroupId._(_requireNonBlankId(raw, 'SeriesGroupId'));

  /// 从已校验存储记录构造常量标识。
  const SeriesGroupId.trusted(this.value);
}

/// 物理媒体文件版本强类型主键。
extension type const VariantId._(String value) {
  /// 构造并校验非空物理版本标识。
  factory VariantId(String raw) =>
      VariantId._(_requireNonBlankId(raw, 'VariantId'));

  /// 从已校验存储记录构造常量标识。
  const VariantId.trusted(this.value);
}
