import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import 'library_models.dart';

/// 媒体库海报墙排序与多维筛选的持久化视图配置快照。
class LibraryPrefsState {
  /// 创建媒体库筛选与排序配置。
  const LibraryPrefsState({
    this.sortMode = LibrarySortMode.title,
    this.sortOrder = LibrarySortOrder.ascending,
    this.yearFilter,
    this.releaseGroupFilter,
    this.sourceIdFilter,
    this.onlyMultiSource = false,
  });

  /// 从 JSON 字典解码，非法字段自动回退默认值。
  factory LibraryPrefsState.fromJson(Map<String, Object?> json) {
    final modeName = json['sortMode'] as String?;
    final sortMode = LibrarySortMode.values.firstWhere(
      (e) => e.name == modeName,
      orElse: () => LibrarySortMode.title,
    );
    final orderName = json['sortOrder'] as String?;
    final sortOrder = LibrarySortOrder.values.firstWhere(
      (e) => e.name == orderName,
      orElse: () => LibrarySortOrder.ascending,
    );
    final rawYear = json['yearFilter'];
    final yearFilter = rawYear is int ? rawYear : int.tryParse('${rawYear ?? ''}');
    final group = (json['releaseGroupFilter'] as String?)?.trim();
    final sourceId = (json['sourceIdFilter'] as String?)?.trim();
    return LibraryPrefsState(
      sortMode: sortMode,
      sortOrder: sortOrder,
      yearFilter: yearFilter,
      releaseGroupFilter: group == null || group.isEmpty ? null : group,
      sourceIdFilter: sourceId == null || sourceId.isEmpty ? null : sourceId,
      onlyMultiSource: json['onlyMultiSource'] == true,
    );
  }

  /// 当前激活排序字段。
  final LibrarySortMode sortMode;

  /// 当前升降序方向。
  final LibrarySortOrder sortOrder;

  /// 可选按发行年份精确筛选。
  final int? yearFilter;

  /// 可选按压制组 / 字幕组筛选。
  final String? releaseGroupFilter;

  /// 可选按所属媒体源 ID 筛选。
  final String? sourceIdFilter;

  /// 是否仅查看存在多版本/跨源的条目。
  final bool onlyMultiSource;

  /// 当前是否启用了除默认排序外的任意筛选条件。
  bool get hasActiveFilters =>
      yearFilter != null ||
      (releaseGroupFilter != null && releaseGroupFilter!.isNotEmpty) ||
      (sourceIdFilter != null && sourceIdFilter!.isNotEmpty) ||
      onlyMultiSource;

  /// 返回修改指定字段后的配置副本。
  LibraryPrefsState copyWith({
    LibrarySortMode? sortMode,
    LibrarySortOrder? sortOrder,
    int? yearFilter,
    bool clearYearFilter = false,
    String? releaseGroupFilter,
    bool clearReleaseGroupFilter = false,
    String? sourceIdFilter,
    bool clearSourceIdFilter = false,
    bool? onlyMultiSource,
  }) {
    return LibraryPrefsState(
      sortMode: sortMode ?? this.sortMode,
      sortOrder: sortOrder ?? this.sortOrder,
      yearFilter: clearYearFilter ? null : (yearFilter ?? this.yearFilter),
      releaseGroupFilter: clearReleaseGroupFilter
          ? null
          : (releaseGroupFilter ?? this.releaseGroupFilter),
      sourceIdFilter: clearSourceIdFilter
          ? null
          : (sourceIdFilter ?? this.sourceIdFilter),
      onlyMultiSource: onlyMultiSource ?? this.onlyMultiSource,
    );
  }

  /// 仅重置筛选项而保留用户习惯的排序方式。
  LibraryPrefsState clearFiltersOnly() {
    return copyWith(
      clearYearFilter: true,
      clearReleaseGroupFilter: true,
      clearSourceIdFilter: true,
      onlyMultiSource: false,
    );
  }

  /// 序列化为 JSON 对象以便写入 `ScopedPrefsStore`。
  Map<String, Object?> toJson() => <String, Object?>{
    'sortMode': sortMode.name,
    'sortOrder': sortOrder.name,
    if (yearFilter != null) 'yearFilter': yearFilter,
    if (releaseGroupFilter != null) 'releaseGroupFilter': releaseGroupFilter,
    if (sourceIdFilter != null) 'sourceIdFilter': sourceIdFilter,
    'onlyMultiSource': onlyMultiSource,
  };
}

/// 媒体库视图偏好强类型配置切片注册器（零 `Riverpod`）。
abstract final class LibraryFilterPrefs {
  /// 持久化海报墙排序与筛选偏好的 `TypedPrefsSlice` 定义。
  static final TypedPrefsSlice<LibraryPrefsState> slice =
      TypedPrefsSlice<LibraryPrefsState>(
        namespace: 'feature_library.view_state',
        schemaVersion: 1,
        syncPolicy: SyncPolicy.portable,
        defaultValue: const LibraryPrefsState(),
        encode: (value) => value.toJson(),
        decode: (json, schemaVersion) => LibraryPrefsState.fromJson(json),
      );
}
