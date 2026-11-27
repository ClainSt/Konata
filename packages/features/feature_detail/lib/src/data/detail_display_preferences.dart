import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

/// 番剧详情页展示偏好设置（与设置中心共享 `feature_detail.display` 持久化切片）。
class DetailDisplayPreferences {
  /// 创建详情页展示偏好快照。
  const DetailDisplayPreferences({
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

  static const String _keyShowTitleText = 'showTitleText';
  static const String _keyShowTitleLogo = 'showTitleLogo';
  static const String _keyShowOverview = 'showOverview';
  static const String _keyShowRawVideoFilename = 'showRawVideoFilename';
  static const String _keyShowCdTab = 'showCdTab';
  static const String _keyShowScanTab = 'showScanTab';
  static const String _keyShowMainHeroBackdrop = 'showMainHeroBackdrop';
  static const String _keyShowEpisodeStillThumbnails =
      'showEpisodeStillThumbnails';
  static const String _keyShowOriginalSubtitlesOnCards =
      'showOriginalSubtitlesOnCards';
  static const String _keyAutoSilentWarmup = 'autoSilentWarmup';

  static const Set<String> _knownKeys = <String>{
    _keyShowTitleText,
    _keyShowTitleLogo,
    _keyShowOverview,
    _keyShowRawVideoFilename,
    _keyShowCdTab,
    _keyShowScanTab,
    _keyShowMainHeroBackdrop,
    _keyShowEpisodeStillThumbnails,
    _keyShowOriginalSubtitlesOnCards,
    _keyAutoSilentWarmup,
  };

  /// 是否显示详情页标题文字。
  bool get showTitleText => !showTitleLogo;

  /// 是否优先显示作品透明标题徽标（ClearLogo）。
  final bool showTitleLogo;

  /// 是否显示作品简介正文。
  final bool showOverview;

  /// 是否在选集卡上附加展示原始视频文件名（默认开启）。
  final bool showRawVideoFilename;

  /// 是否在底部分类胶囊显示 `CD` 分类入口。
  final bool showCdTab;

  /// 是否在底部分类胶囊显示 `Scan` 分类入口。
  final bool showScanTab;

  /// 是否在宽屏顶部主舞台展示全幅 16:9 背景原画。
  final bool showMainHeroBackdrop;

  /// 是否在选集轨道卡片加载 16:9 剧照缩略图。
  final bool showEpisodeStillThumbnails;

  /// 是否在卡片上保留原文副标题（如日文原题）。
  final bool showOriginalSubtitlesOnCards;

  /// 是否在详情加载后静默预热首帧与剧照缓存。
  final bool autoSilentWarmup;

  /// 未识别的未来扩展键（往返写回时原样透传保留）。
  final Map<String, Object?> extraFields;

  /// 应用显示偏好，保留作品可见性过滤后的其他扩展标签。
  List<DetailTabContribution> filterTabs(List<DetailTabContribution> tabs) =>
      showScanTab
      ? tabs
      : tabs
            .where((tab) => tab.kind != DetailTabKind.scan)
            .toList(growable: false);

  /// 返回更新指定展示开关后的新偏好实例。
  DetailDisplayPreferences copyWith({
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
    return DetailDisplayPreferences(
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

  /// 绑定到统一设置系统的分命名空间类型化切片（跨端便携同步）。
  static const TypedPrefsSlice<DetailDisplayPreferences> prefsSlice =
      TypedPrefsSlice<DetailDisplayPreferences>(
        namespace: 'feature_detail.display',
        schemaVersion: 1,
        syncPolicy: SyncPolicy.portable,
        mergeByField: true,
        defaultValue: DetailDisplayPreferences(),
        encode: encodeJson,
        decode: decodeJson,
      );

  /// 序列化为 `ScopedPrefsStore` 兼容字典载荷（完整保留 10 个共享键与未知扩展字段）。
  static Map<String, Object?> encodeJson(DetailDisplayPreferences value) =>
      <String, Object?>{
        ...value.extraFields,
        _keyShowTitleText: value.showTitleText,
        _keyShowTitleLogo: value.showTitleLogo,
        _keyShowOverview: value.showOverview,
        _keyShowRawVideoFilename: value.showRawVideoFilename,
        _keyShowCdTab: value.showCdTab,
        _keyShowScanTab: value.showScanTab,
        _keyShowMainHeroBackdrop: value.showMainHeroBackdrop,
        _keyShowEpisodeStillThumbnails: value.showEpisodeStillThumbnails,
        _keyShowOriginalSubtitlesOnCards: value.showOriginalSubtitlesOnCards,
        _keyAutoSilentWarmup: value.autoSilentWarmup,
      };

  /// 从共享字典载荷反序列化展示偏好，兼容缺省字段与未来版本字段保留。
  static DetailDisplayPreferences decodeJson(
    Map<String, Object?> raw,
    int schemaVersion,
  ) {
    final extras = <String, Object?>{};
    for (final entry in raw.entries) {
      if (!_knownKeys.contains(entry.key)) {
        extras[entry.key] = entry.value;
      }
    }
    return DetailDisplayPreferences(
      // 旧版双选或全不选均归一为徽标优先；保留明确的文字模式。
      showTitleLogo:
          raw[_keyShowTitleLogo] != false || raw[_keyShowTitleText] == false,
      showOverview: _readBool(raw[_keyShowOverview], fallback: true),
      showRawVideoFilename: _readBool(
        raw[_keyShowRawVideoFilename],
        fallback: true,
      ),
      showCdTab: _readBool(raw[_keyShowCdTab], fallback: true),
      showScanTab: _readBool(raw[_keyShowScanTab], fallback: true),
      showMainHeroBackdrop: _readBool(
        raw[_keyShowMainHeroBackdrop],
        fallback: true,
      ),
      showEpisodeStillThumbnails: _readBool(
        raw[_keyShowEpisodeStillThumbnails],
        fallback: true,
      ),
      showOriginalSubtitlesOnCards: _readBool(
        raw[_keyShowOriginalSubtitlesOnCards],
        fallback: true,
      ),
      autoSilentWarmup: _readBool(raw[_keyAutoSilentWarmup], fallback: true),
      extraFields: extras.isEmpty
          ? const <String, Object?>{}
          : Map<String, Object?>.unmodifiable(extras),
    );
  }

  static bool _readBool(Object? raw, {required bool fallback}) {
    if (raw is bool) return raw;
    return fallback;
  }

  static bool _shallowMapEquals(
    Map<String, Object?> a,
    Map<String, Object?> b,
  ) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key) || b[entry.key] != entry.value) {
        return false;
      }
    }
    return true;
  }

  @override
  bool operator ==(Object other) {
    return other is DetailDisplayPreferences &&
        other.showTitleText == showTitleText &&
        other.showTitleLogo == showTitleLogo &&
        other.showOverview == showOverview &&
        other.showRawVideoFilename == showRawVideoFilename &&
        other.showCdTab == showCdTab &&
        other.showScanTab == showScanTab &&
        other.showMainHeroBackdrop == showMainHeroBackdrop &&
        other.showEpisodeStillThumbnails == showEpisodeStillThumbnails &&
        other.showOriginalSubtitlesOnCards == showOriginalSubtitlesOnCards &&
        other.autoSilentWarmup == autoSilentWarmup &&
        _shallowMapEquals(other.extraFields, extraFields);
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
    Object.hashAllUnordered(
      extraFields.entries.map((e) => Object.hash(e.key, e.value)),
    ),
  );
}

/// 基于 `ScopedPrefsStore` 的详情页展示偏好读写与监听仓库（零 Riverpod）。
final class DetailDisplayPreferencesStore {
  /// 构造展示偏好切片仓储。
  const DetailDisplayPreferencesStore(this._scopedPrefs);

  final ScopedPrefsStore _scopedPrefs;

  /// 读取当前展示偏好快照。
  DetailDisplayPreferences read() =>
      _scopedPrefs.read(DetailDisplayPreferences.prefsSlice);

  /// 监听详情页展示偏好实时变化。
  Stream<DetailDisplayPreferences> watch() =>
      _scopedPrefs.watch(DetailDisplayPreferences.prefsSlice);

  /// 覆写保存完整的展示偏好快照。
  void write(DetailDisplayPreferences next) =>
      _scopedPrefs.write(DetailDisplayPreferences.prefsSlice, next);

  /// 更新是否显示标题徽标（ClearLogo）。
  void setShowTitleLogo(bool enabled) =>
      write(read().copyWith(showTitleLogo: enabled));

  /// 更新是否显示作品简介正文。
  void setShowOverview(bool enabled) =>
      write(read().copyWith(showOverview: enabled));

  /// 更新是否在选集卡显示原始视频文件名。
  void setShowRawVideoFilename(bool enabled) =>
      write(read().copyWith(showRawVideoFilename: enabled));

  /// 更新是否显示 `CD` 分类标签。
  void setShowCdTab(bool enabled) => write(read().copyWith(showCdTab: enabled));

  /// 更新是否显示 `Scan` 分类标签。
  void setShowScanTab(bool enabled) =>
      write(read().copyWith(showScanTab: enabled));

  /// 更新是否显示宽屏主背景原画。
  void setShowMainHeroBackdrop(bool enabled) =>
      write(read().copyWith(showMainHeroBackdrop: enabled));

  /// 更新是否显示选集剧照缩略图。
  void setShowEpisodeStillThumbnails(bool enabled) =>
      write(read().copyWith(showEpisodeStillThumbnails: enabled));

  /// 更新是否在卡片上展示原文副标题。
  void setShowOriginalSubtitlesOnCards(bool enabled) =>
      write(read().copyWith(showOriginalSubtitlesOnCards: enabled));

  /// 更新是否自动静默预热首帧与剧照缓存。
  void setAutoSilentWarmup(bool enabled) =>
      write(read().copyWith(autoSilentWarmup: enabled));
}
