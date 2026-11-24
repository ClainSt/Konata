import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

/// 作品详情页展示偏好设置实体。
class DetailDisplayPreferences {
  /// 创建详情页展示偏好快照。
  const DetailDisplayPreferences({
    this.showMainHeroBackdrop = true,
    this.showEpisodeStillThumbnails = true,
    this.showOriginalSubtitlesOnCards = true,
    this.autoSilentWarmup = true,
  });

  /// 是否在详情页舞台渲染全幅背景原画与智能框选渐变。
  final bool showMainHeroBackdrop;

  /// 是否显示单集剧照缩略图并按需对正片执行静默抽帧补图。
  final bool showEpisodeStillThumbnails;

  /// 是否在单集、特典与 CD 卡片上展示原始文件名副标题。
  final bool showOriginalSubtitlesOnCards;

  /// 进入详情页时是否静默预热同级字幕目录与远程连接池。
  final bool autoSilentWarmup;

  /// 复制并按需替换偏好开关。
  DetailDisplayPreferences copyWith({
    bool? showMainHeroBackdrop,
    bool? showEpisodeStillThumbnails,
    bool? showOriginalSubtitlesOnCards,
    bool? autoSilentWarmup,
  }) {
    return DetailDisplayPreferences(
      showMainHeroBackdrop: showMainHeroBackdrop ?? this.showMainHeroBackdrop,
      showEpisodeStillThumbnails:
          showEpisodeStillThumbnails ?? this.showEpisodeStillThumbnails,
      showOriginalSubtitlesOnCards:
          showOriginalSubtitlesOnCards ?? this.showOriginalSubtitlesOnCards,
      autoSilentWarmup: autoSilentWarmup ?? this.autoSilentWarmup,
    );
  }

  /// 持久化分命名空间偏好切片描述（参与跨设备配置同步）。
  static const TypedPrefsSlice<DetailDisplayPreferences> prefsSlice =
      TypedPrefsSlice<DetailDisplayPreferences>(
        namespace: 'feature_detail.display',
        schemaVersion: 1,
        syncPolicy: SyncPolicy.portable,
        defaultValue: DetailDisplayPreferences(),
        encode: encodeJson,
        decode: decodeJson,
      );

  /// 序列化为 JSON 字典。
  static Map<String, Object?> encodeJson(DetailDisplayPreferences value) =>
      <String, Object?>{
        'showMainHeroBackdrop': value.showMainHeroBackdrop,
        'showEpisodeStillThumbnails': value.showEpisodeStillThumbnails,
        'showOriginalSubtitlesOnCards': value.showOriginalSubtitlesOnCards,
        'autoSilentWarmup': value.autoSilentWarmup,
      };

  /// 从 JSON 字典反序列化（兼容缺省字段平滑回落默认值）。
  static DetailDisplayPreferences decodeJson(
    Map<String, Object?> json,
    int storedSchemaVersion,
  ) {
    return DetailDisplayPreferences(
      showMainHeroBackdrop: json['showMainHeroBackdrop'] as bool? ?? true,
      showEpisodeStillThumbnails:
          json['showEpisodeStillThumbnails'] as bool? ?? true,
      showOriginalSubtitlesOnCards:
          json['showOriginalSubtitlesOnCards'] as bool? ?? true,
      autoSilentWarmup: json['autoSilentWarmup'] as bool? ?? true,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DetailDisplayPreferences &&
        other.showMainHeroBackdrop == showMainHeroBackdrop &&
        other.showEpisodeStillThumbnails == showEpisodeStillThumbnails &&
        other.showOriginalSubtitlesOnCards == showOriginalSubtitlesOnCards &&
        other.autoSilentWarmup == autoSilentWarmup;
  }

  @override
  int get hashCode => Object.hash(
    showMainHeroBackdrop,
    showEpisodeStillThumbnails,
    showOriginalSubtitlesOnCards,
    autoSilentWarmup,
  );
}

/// 详情页展示偏好自治存储访问器（零 Riverpod 纯构造函数注入）。
final class DetailDisplayPreferencesStore {
  /// 使用分命名空间配置存储器构造偏好访问器。
  const DetailDisplayPreferencesStore(this._scopedPrefs);

  final ScopedPrefsStore _scopedPrefs;

  /// 读取当前展示偏好。
  DetailDisplayPreferences read() =>
      _scopedPrefs.read(DetailDisplayPreferences.prefsSlice);

  /// 响应式监听展示偏好变化流。
  Stream<DetailDisplayPreferences> watch() =>
      _scopedPrefs.watch(DetailDisplayPreferences.prefsSlice);

  /// 持久化更新展示偏好。
  void write(DetailDisplayPreferences next) =>
      _scopedPrefs.write(DetailDisplayPreferences.prefsSlice, next);

  /// 便捷切换单集剧照缩略图开关。
  void setShowEpisodeStillThumbnails(bool enabled) =>
      write(read().copyWith(showEpisodeStillThumbnails: enabled));

  /// 便捷切换卡片原始文件名副标题开关。
  void setShowOriginalSubtitlesOnCards(bool enabled) =>
      write(read().copyWith(showOriginalSubtitlesOnCards: enabled));

  /// 便捷切换详情舞台背景原画显示开关。
  void setShowMainHeroBackdrop(bool enabled) =>
      write(read().copyWith(showMainHeroBackdrop: enabled));
}
