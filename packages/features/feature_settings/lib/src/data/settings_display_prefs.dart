import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

/// 作品详情页展示偏好设置实体（共享 `'feature_detail.display'` 分片，数据层保持零 Riverpod）。
///
/// 除显示设置面板直接编辑的 6 个字段外，完整透传并保留 `feature_detail`
/// 自有的 4 个字段与未知扩展字段，确保跨包读写零字段覆盖。
final class SettingsDisplayPrefs {
  /// 创建详情页展示偏好配置。
  const SettingsDisplayPrefs({
    this.showTitleLogo = true,
    this.showOverview = true,
    this.showRawVideoFilename = true,
    this.showCdTab = true,
    this.showScanTab = true,
    this.showMainHeroBackdrop = true,
    this.showEpisodeStillThumbnails = true,
    this.showOriginalSubtitlesOnCards = true,
    this.autoSilentWarmup = true,
    this.extraFields = const <String, Object?>{},
  });

  /// 详情页主视觉区是否展示文字标题。
  bool get showTitleText => !showTitleLogo;

  /// 详情页主视觉区是否展示透明标题徽标。
  final bool showTitleLogo;

  /// 详情页主视觉区是否展示作品简介。
  final bool showOverview;

  /// 选集与特典卡片是否显示原始视频文件名。
  final bool showRawVideoFilename;

  /// 是否在作品详情页展示「CD」分类页签。
  final bool showCdTab;

  /// 是否在作品详情页展示「Scan」分类页签。
  final bool showScanTab;

  /// 详情页舞台是否渲染全幅背景原画与智能框选渐变（`feature_detail` 共有字段）。
  final bool showMainHeroBackdrop;

  /// 是否显示单集剧照缩略图并按需静默补帧（`feature_detail` 共有字段）。
  final bool showEpisodeStillThumbnails;

  /// 是否在卡片上展示原始文件名副标题（`feature_detail` 共有字段）。
  final bool showOriginalSubtitlesOnCards;

  /// 进入详情页时是否静默预热同级字幕目录（`feature_detail` 共有字段）。
  final bool autoSilentWarmup;

  /// 保留未识别的历史或扩展 JSON 字段，避免跨版本读写丢失。
  final Map<String, Object?> extraFields;

  /// 复制并修改部分详情展示偏好字段。
  SettingsDisplayPrefs copyWith({
    bool? showTitleLogo,
    bool? showOverview,
    bool? showRawVideoFilename,
    bool? showCdTab,
    bool? showScanTab,
    bool? showMainHeroBackdrop,
    bool? showEpisodeStillThumbnails,
    bool? showOriginalSubtitlesOnCards,
    bool? autoSilentWarmup,
    Map<String, Object?>? extraFields,
  }) {
    return SettingsDisplayPrefs(
      showTitleLogo: showTitleLogo ?? this.showTitleLogo,
      showOverview: showOverview ?? this.showOverview,
      showRawVideoFilename: showRawVideoFilename ?? this.showRawVideoFilename,
      showCdTab: showCdTab ?? this.showCdTab,
      showScanTab: showScanTab ?? this.showScanTab,
      showMainHeroBackdrop: showMainHeroBackdrop ?? this.showMainHeroBackdrop,
      showEpisodeStillThumbnails:
          showEpisodeStillThumbnails ?? this.showEpisodeStillThumbnails,
      showOriginalSubtitlesOnCards:
          showOriginalSubtitlesOnCards ?? this.showOriginalSubtitlesOnCards,
      autoSilentWarmup: autoSilentWarmup ?? this.autoSilentWarmup,
      extraFields: extraFields ?? this.extraFields,
    );
  }

  /// 序列化为持久化 JSON 字典（完整保留所有已知及扩展字段）。
  Map<String, Object?> toJson() => <String, Object?>{
    ...extraFields,
    'showTitleText': showTitleText,
    'showTitleLogo': showTitleLogo,
    'showOverview': showOverview,
    'showRawVideoFilename': showRawVideoFilename,
    'showCdTab': showCdTab,
    'showScanTab': showScanTab,
    'showMainHeroBackdrop': showMainHeroBackdrop,
    'showEpisodeStillThumbnails': showEpisodeStillThumbnails,
    'showOriginalSubtitlesOnCards': showOriginalSubtitlesOnCards,
    'autoSilentWarmup': autoSilentWarmup,
  };

  /// 从持久化 JSON 反序列化，对缺省字段平滑回落安全默认值。
  static SettingsDisplayPrefs fromJson(
    Map<String, Object?> json,
    int storedSchemaVersion,
  ) {
    const knownKeys = <String>{
      'showTitleText',
      'showTitleLogo',
      'showOverview',
      'showRawVideoFilename',
      'showCdTab',
      'showScanTab',
      'showMainHeroBackdrop',
      'showEpisodeStillThumbnails',
      'showOriginalSubtitlesOnCards',
      'autoSilentWarmup',
    };
    final preservedExtra = <String, Object?>{
      for (final entry in json.entries)
        if (!knownKeys.contains(entry.key)) entry.key: entry.value,
    };

    return SettingsDisplayPrefs(
      // 旧版双选或全不选均归一为徽标优先；保留明确的文字模式。
      showTitleLogo:
          json['showTitleLogo'] != false || json['showTitleText'] == false,
      showOverview: _readBool(json, 'showOverview', true),
      showRawVideoFilename: _readBool(json, 'showRawVideoFilename', true),
      showCdTab: _readBool(json, 'showCdTab', true),
      showScanTab: _readBool(json, 'showScanTab', true),
      showMainHeroBackdrop: _readBool(json, 'showMainHeroBackdrop', true),
      showEpisodeStillThumbnails: _readBool(
        json,
        'showEpisodeStillThumbnails',
        true,
      ),
      showOriginalSubtitlesOnCards: _readBool(
        json,
        'showOriginalSubtitlesOnCards',
        true,
      ),
      autoSilentWarmup: _readBool(json, 'autoSilentWarmup', true),
      extraFields: Map<String, Object?>.unmodifiable(preservedExtra),
    );
  }

  static bool _readBool(Map<String, Object?> json, String key, bool fallback) {
    final value = json[key];
    return value is bool ? value : fallback;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SettingsDisplayPrefs &&
        other.showTitleText == showTitleText &&
        other.showTitleLogo == showTitleLogo &&
        other.showOverview == showOverview &&
        other.showRawVideoFilename == showRawVideoFilename &&
        other.showCdTab == showCdTab &&
        other.showScanTab == showScanTab &&
        other.showMainHeroBackdrop == showMainHeroBackdrop &&
        other.showEpisodeStillThumbnails == showEpisodeStillThumbnails &&
        other.showOriginalSubtitlesOnCards == showOriginalSubtitlesOnCards &&
        other.autoSilentWarmup == autoSilentWarmup;
  }

  @override
  int get hashCode => Object.hash(
    showTitleText,
    showTitleLogo,
    showOverview,
    showRawVideoFilename,
    showCdTab,
    showScanTab,
    showMainHeroBackdrop,
    showEpisodeStillThumbnails,
    showOriginalSubtitlesOnCards,
    autoSilentWarmup,
  );
}

/// 详情页展示偏好仓储（直接读写共享命名空间 `'feature_detail.display'`，不跨包导入 `feature_detail`）。
final class SettingsDisplayRepository {
  /// 创建详情页展示偏好仓储。
  const SettingsDisplayRepository(this._scopedPrefs);

  /// 与 `feature_detail` 共用的便携配置分片定义。
  static final TypedPrefsSlice<SettingsDisplayPrefs> slice =
      TypedPrefsSlice<SettingsDisplayPrefs>(
        namespace: 'feature_detail.display',
        schemaVersion: 1,
        syncPolicy: SyncPolicy.portable,
        defaultValue: const SettingsDisplayPrefs(),
        decode: SettingsDisplayPrefs.fromJson,
        encode: (value) => value.toJson(),
      );

  final ScopedPrefsStore _scopedPrefs;

  /// 读取当前展示偏好。
  SettingsDisplayPrefs read() => _scopedPrefs.read(slice);

  /// 持久化更新展示偏好。
  void save(SettingsDisplayPrefs value) {
    _scopedPrefs.write(slice, value);
  }

  /// 基于最新存储快照执行局部字段合并写入，防止覆盖其他模块同时更新的字段。
  SettingsDisplayPrefs update(
    SettingsDisplayPrefs Function(SettingsDisplayPrefs current) transform,
  ) {
    final latest = read();
    final next = transform(latest);
    save(next);
    return next;
  }

  /// 响应式监听展示偏好变化。
  Stream<SettingsDisplayPrefs> watch() => _scopedPrefs.watch(slice);
}
