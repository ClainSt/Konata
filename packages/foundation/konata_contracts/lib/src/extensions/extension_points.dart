import 'dart:async';

import '../ports/read_query_ports.dart';
import '../sources/source_gateway_ports.dart';
import '../value_objects/domain_enums.dart';
import '../value_objects/ids.dart';

/// 界面扩展槽位渲染上下文（纯 Dart 无 Flutter 依赖，由宿主外壳透传真实绘制上下文与参数）。
final class ViewSlotContext {
  /// 创建界面槽位渲染上下文。
  const ViewSlotContext({
    this.platformContext,
    this.workId,
    this.episodeId,
    this.variantId,
    this.arguments = const <String, Object?>{},
  });

  /// 宿主界面框架透传的平台构建上下文对象（Flutter 端为 `BuildContext`）。
  final Object? platformContext;

  /// 可选目标作品标识。
  final WorkId? workId;

  /// 可选目标剧集标识。
  final EpisodeId? episodeId;

  /// 可选目标物理版本标识。
  final VariantId? variantId;

  /// 可选命名扩展参数。
  final Map<String, Object?> arguments;
}

/// 纯 Dart 声明式界面槽位工厂函数签名（返回由宿主渲染的视图对象）。
typedef ViewSlotBuilder = Object Function(ViewSlotContext context);

/// 全部支持的默认运行平台集合。
const Set<KonataPlatform> allKonataPlatforms = <KonataPlatform>{
  KonataPlatform.windows,
  KonataPlatform.androidPhone,
  KonataPlatform.androidTablet,
};

/// 扩展点 1：顶层主导航分区贡献声明（如媒体库、媒体源、播放记录、设置）。
final class NavSectionContribution {
  /// 创建顶层导航分区贡献。
  const NavSectionContribution({
    required this.id,
    required this.label,
    required this.iconKey,
    required this.order,
    required this.viewBuilder,
    this.supportedPlatforms = allKonataPlatforms,
    this.keepAlive = true,
    this.supportsSearch = false,
  });

  /// 稳定分区唯一标识。
  final String id;

  /// 中文导航展示名称。
  final String label;

  /// 设计系统图标键名。
  final String iconKey;

  /// 排序权重（升序排列）。
  final int order;

  /// 页面视图构建工厂。
  final ViewSlotBuilder viewBuilder;

  /// 支持展示的平台集合。
  final Set<KonataPlatform> supportedPlatforms;

  /// 是否启用懒加载保活。
  final bool keepAlive;

  /// 是否接收宿主顶栏的搜索词。
  final bool supportsSearch;

  /// 判断当前运行平台是否支持挂载该导航分区。
  bool isSupportedOn(KonataPlatform platform) =>
      supportedPlatforms.contains(platform);
}

/// 显示与存储设置分区的稳定标识。
const displaySettingsSectionId = 'display';

/// 扩展点 2：设置分区贡献声明（支持按 Windows / Android 手机 / 平板过滤）。
final class SettingsSectionContribution {
  /// 创建设置分区贡献。
  const SettingsSectionContribution({
    required this.id,
    required this.title,
    required this.iconKey,
    required this.order,
    required this.viewBuilder,
    this.subtitle,
    this.parentSectionId,
    this.supportedPlatforms = allKonataPlatforms,
  });

  /// 稳定设置分区标识。
  final String id;

  /// 指定父分区时按顺序嵌入其面板，随父分区一起显示。
  final String? parentSectionId;

  /// 分区标题。
  final String title;

  /// 可选简短说明。
  final String? subtitle;

  /// 图标键名。
  final String iconKey;

  /// 排序权重（升序排列）。
  final int order;

  /// 设置面板构建工厂。
  final ViewSlotBuilder viewBuilder;

  /// 支持显示的平台集合（例如外置播放器仅在 `windows` 显示）。
  final Set<KonataPlatform> supportedPlatforms;

  /// 判断当前运行平台是否应显示该设置分区。
  bool isSupportedOn(KonataPlatform platform) =>
      supportedPlatforms.contains(platform);
}

/// 详情标签的内容类型，由标签注册方声明。
enum DetailTabKind {
  /// 通用扩展内容。
  general,

  /// 扫图画廊，受 Scan 显示偏好控制。
  scan,
}

/// 扩展点 3：作品详情页标签页贡献声明（如 `feature_scan_viewer` 扫图画廊挂载入口）。
final class DetailTabContribution {
  /// 创建详情页标签页贡献。
  const DetailTabContribution({
    required this.id,
    required this.label,
    required this.iconKey,
    required this.order,
    required this.viewBuilder,
    this.supportedPlatforms = allKonataPlatforms,
    this.isVisibleForWork,
    this.kind = DetailTabKind.general,
  });

  /// 稳定标签页标识。
  final String id;

  /// 标签内容类型。
  final DetailTabKind kind;

  /// 标签展示文案。
  final String label;

  /// 图标键名。
  final String iconKey;

  /// 排序权重（升序排列）。
  final int order;

  /// 标签页内容视图构建工厂。
  final ViewSlotBuilder viewBuilder;

  /// 支持的平台集合。
  final Set<KonataPlatform> supportedPlatforms;

  /// 可选按作品动态判定是否显示该标签（未提供时默认始终显示）。
  final FutureOr<bool> Function(WorkId workId)? isVisibleForWork;

  /// 判断当前平台是否支持该标签页。
  bool isSupportedOn(KonataPlatform platform) =>
      supportedPlatforms.contains(platform);
}

/// 详情页动作按钮摆放区域枚举。
enum DetailActionPlacement {
  /// 主操作区快捷动作按钮。
  primaryBar,

  /// 齿轮更多菜单项。
  gearMenu,
}

/// 扩展点 4：作品详情页动作贡献声明（如重新刮削、编辑元数据、推送追番进度）。
final class DetailActionContribution {
  /// 创建详情页动作贡献。
  const DetailActionContribution({
    required this.id,
    required this.label,
    required this.iconKey,
    required this.order,
    required this.onInvoke,
    this.placement = DetailActionPlacement.gearMenu,
    this.supportedPlatforms = allKonataPlatforms,
    this.isEnabledForWork,
  });

  /// 稳定动作标识。
  final String id;

  /// 中文动作文案。
  final String label;

  /// 图标键名。
  final String iconKey;

  /// 排序权重（升序排列）。
  final int order;

  /// 点击触发执行回调。
  final FutureOr<void> Function(ViewSlotContext context) onInvoke;

  /// 建议摆放区域。
  final DetailActionPlacement placement;

  /// 支持的平台集合。
  final Set<KonataPlatform> supportedPlatforms;

  /// 可选按作品动态判定该动作是否启用。
  final FutureOr<bool> Function(WorkId workId)? isEnabledForWork;

  /// 判断当前平台是否支持该动作。
  bool isSupportedOn(KonataPlatform platform) =>
      supportedPlatforms.contains(platform);
}

/// 扩展点 5：全屏播放器侧栏面板贡献声明（如字幕控制、选集抽屉、发烧音频、歌词校准）。
final class PlayerSidePanelContribution {
  /// 创建播放器侧栏贡献。
  const PlayerSidePanelContribution({
    required this.id,
    required this.label,
    required this.iconKey,
    required this.order,
    required this.viewBuilder,
    this.supportedModes = const <PlayerMediaMode>{PlayerMediaMode.video},
    this.supportedPlatforms = allKonataPlatforms,
  });

  /// 稳定侧栏面板标识。
  final String id;

  /// 中文面板名称。
  final String label;

  /// 图标键名。
  final String iconKey;

  /// 排序权重（升序排列）。
  final int order;

  /// 侧栏面板视图构建工厂。
  final ViewSlotBuilder viewBuilder;

  /// 支持的播放器模式（视频 / 音频）。
  final Set<PlayerMediaMode> supportedModes;

  /// 支持的平台集合。
  final Set<KonataPlatform> supportedPlatforms;

  /// 判断指定平台与媒体模式下是否启用该侧栏面板。
  bool isSupportedOn(KonataPlatform platform, PlayerMediaMode mode) =>
      supportedPlatforms.contains(platform) && supportedModes.contains(mode);
}

/// 第三方追番平台观看进度同步条目载荷。
final class TrackerProgressPayload {
  /// 创建追番进度同步条目。
  const TrackerProgressPayload({
    required this.trackerId,
    required this.externalSubjectId,
    required this.seasonNumber,
    required this.completed,
    this.episodeNumber,
    this.extraMetadata = const <String, Object?>{},
  });

  /// 目标追番平台唯一标识（例如 `bangumi`、`mal`、`anilist`、`simkl`）。
  final String trackerId;

  /// 第三方平台条目编号（字符串形式以兼容纯数字与字母编码平台）。
  final String externalSubjectId;

  /// 本地季号（用于区分正片与特典 SP）。
  final int seasonNumber;

  /// 目标是否标记为已看完。
  final bool completed;

  /// 单集集号（剧场版或单部条目可为空）。
  final int? episodeNumber;

  /// 平台专用附加字段。
  final Map<String, Object?> extraMetadata;
}

/// 第三方追番平台单次同步执行结果。
final class TrackerSyncResult {
  /// 创建同步成功结果。
  const TrackerSyncResult.succeeded({this.remoteSummary})
    : success = true,
      retryable = false,
      errorMessage = null;

  /// 创建同步失败结果。
  const TrackerSyncResult.failed({
    required this.errorMessage,
    this.retryable = true,
  }) : success = false,
       remoteSummary = null;

  /// 是否同步成功。
  final bool success;

  /// 失败时是否允许按退避策略离线重试（如 401 令牌过期应置 `false`）。
  final bool retryable;

  /// 已脱敏的中文失败原因。
  final String? errorMessage;

  /// 可选远端确认摘要。
  final String? remoteSummary;
}

/// 第三方追番平台进度同步提供者契约（支持 Bangumi / MAL / AniList / Simkl 零侵入插拔）。
abstract interface class ProgressTrackerProvider {
  /// 平台唯一稳定标识（如 `bangumi`）。
  String get trackerId;

  /// 面向用户的平台展示名称（如 `Bangumi 番组计划`）。
  String get displayName;

  /// 判断当前用户是否已完成该平台鉴权并启用同步。
  Future<bool> isConfigured();

  /// 向第三方平台推送单条观看进度变更。
  Future<TrackerSyncResult> pushProgress(TrackerProgressPayload payload);
}

/// 扩展点 6：外部数据与能力提供者声明（元数据源 / 歌词源 / 第三方追番进度提供者）。
sealed class DataProviderContribution {
  /// 构造数据提供者贡献基类。
  const DataProviderContribution({
    required this.id,
    required this.displayName,
    required this.priority,
  });

  /// 提供者唯一标识。
  final String id;

  /// 中文或品牌展示名称。
  final String displayName;

  /// 调度优先级（数值越小越优先）。
  final int priority;
}

/// 元数据刮削提供者贡献声明（如 TMDB、Bangumi、Fanart）。
final class MetadataProviderContribution extends DataProviderContribution {
  /// 创建元数据提供者贡献。
  const MetadataProviderContribution({
    required super.id,
    required super.displayName,
    required super.priority,
    required this.provider,
  });

  /// 具体元数据提供者实例。
  final Object provider;
}

/// 在线歌词源提供者贡献声明（如 AMLL、网易云、QQ 音乐、LRCLIB）。
final class LyricSourceProviderContribution extends DataProviderContribution {
  /// 创建歌词源提供者贡献。
  const LyricSourceProviderContribution({
    required super.id,
    required super.displayName,
    required super.priority,
    required this.provider,
  });

  /// 具体歌词源提供者实例。
  final Object provider;
}

/// 第三方追番平台进度同步提供者贡献声明。
final class ProgressTrackerProviderContribution
    extends DataProviderContribution {
  /// 创建第三方追番平台提供者贡献。
  const ProgressTrackerProviderContribution({
    required super.id,
    required super.displayName,
    required super.priority,
    required this.provider,
  });

  /// 实现 [ProgressTrackerProvider] 的平台适配器。
  final ProgressTrackerProvider provider;
}

/// 跨设备同步与 `.konata` 本地备份统一切片载荷信封。
final class SyncSlicePayload {
  /// 创建切片导出载荷。
  const SyncSlicePayload({
    required this.sliceId,
    required this.schemaVersion,
    required this.exportedAtMs,
    required this.sourceDeviceId,
    required this.data,
  });

  /// 切片稳定标识（如 `prefs_slice`、`playback_history_slice`）。
  final String sliceId;

  /// 切片数据结构版本号。
  final int schemaVersion;

  /// 导出时间的 UTC 毫秒时间戳。
  final int exportedAtMs;

  /// 产出该切片的设备标识。
  final String sourceDeviceId;

  /// 可 JSON 序列化的切片主体数据（严禁携带任何本机密码或绝对文件路径）。
  final Map<String, Object?> data;

  /// 序列化为统一 JSON 字典。
  Map<String, Object?> toJson() => <String, Object?>{
    'sliceId': sliceId,
    'schemaVersion': schemaVersion,
    'exportedAtMs': exportedAtMs,
    'sourceDeviceId': sourceDeviceId,
    'data': data,
  };
}

/// 纯函数合并预览计划（先算后落，支持同步前预览与纯单测验证）。
final class SyncMergePlan<TPlan> {
  /// 创建切片合并计划。
  const SyncMergePlan({
    required this.sliceId,
    required this.insertCount,
    required this.updateCount,
    required this.deleteCount,
    required this.skippedCount,
    required this.planData,
    this.summaryLines = const <String>[],
  });

  /// 对应切片标识。
  final String sliceId;

  /// 预计新增记录数。
  final int insertCount;

  /// 预计覆盖更新记录数。
  final int updateCount;

  /// 预计软删除或移除记录数。
  final int deleteCount;

  /// 冲突判定后保留本地而跳过的记录数。
  final int skippedCount;

  /// 供事务阶段执行的强类型合并指令数据。
  final TPlan planData;

  /// 供诊断日志与预览界面的简短中文变更摘要。
  final List<String> summaryLines;

  /// 本次合并计划是否包含实际需要落盘的改动。
  bool get hasChanges => insertCount > 0 || updateCount > 0 || deleteCount > 0;
}

/// 同步切片事务应用上下文端口（由 `konata_storage` 在统一数据库事务内注入）。
abstract interface class SyncTransactionContext {
  /// 当前执行合并的本机设备标识。
  String get localDeviceId;

  /// 本次同步落盘时间戳（UTC 毫秒）。
  int get appliedAtMs;

  /// 获取底层事务执行句柄（按数据库标识如 `library` / `user_state` 提取）。
  Object? rawHandleFor(String databaseName);
}

/// 同步切片应用完成标记。原生同步事务不能等待 Future。
enum SyncApplyCompletion {
  /// 本次计划已在当前调用栈中执行完毕，尚待宿主提交事务。
  completed,
}

/// 扩展点 7：统一备份与 WebDAV 多设备同步的切片贡献者契约。
abstract interface class SyncSliceContributor<TPlan> {
  /// 切片全局唯一稳定标识（如 `prefs_slice`、`library_catalog_slice`）。
  String get sliceId;

  /// 切片展示名称（供选择性备份与同步预览展示）。
  String get displayName;

  /// 当前切片协议版本号。
  int get schemaVersion;

  /// 导出本机当前切片数据（仅导出可便携同步数据，绝不包含敏感凭据与本机自定义图片绝对路径）。
  Future<SyncSlicePayload> exportSlice({required String localDeviceId});

  /// 纯函数计算本地载荷与远端载荷的差异合并计划（严禁产生任何 I/O 副作用）。
  SyncMergePlan<TPlan> planMerge({
    required SyncSlicePayload local,
    required SyncSlicePayload remote,
  });

  /// 同步执行 [plan]，仅使用宿主事务句柄，失败须同步抛出；禁止异步或外部写入。
  SyncApplyCompletion applyMergePlan(
    SyncTransactionContext tx,
    SyncMergePlan<TPlan> plan,
  );
}

/// 按无凭据虚拟地址协议注册可拔插的只读云盘驱动。
final class CloudDriveProviderContribution {
  const CloudDriveProviderContribution({
    required this.scheme,
    required this.displayName,
    required this.create,
  });

  /// 仅用于同步的无凭据虚拟地址协议。
  final String scheme;
  final String displayName;
  final Future<CloudDriveGateway> Function(MediaSourceView source) create;
}

/// 业务 Feature 包向应用壳声明能力的统一清单（在 `apps/konata` 按字母序显式注册）。
final class FeatureManifest {
  /// 创建业务模块声明清单。
  const FeatureManifest({
    required this.id,
    required this.displayName,
    this.supportedPlatforms = allKonataPlatforms,
    this.navSections = const <NavSectionContribution>[],
    this.settingsSections = const <SettingsSectionContribution>[],
    this.detailTabs = const <DetailTabContribution>[],
    this.detailActions = const <DetailActionContribution>[],
    this.playerSidePanels = const <PlayerSidePanelContribution>[],
    this.dataProviders = const <DataProviderContribution>[],
    this.syncSlices = const <SyncSliceContributor<Object?>>[],
    this.cloudDriveProviders = const <CloudDriveProviderContribution>[],
    this.wrapRuntime,
  });

  /// 模块唯一稳定标识（建议与包名一致，如 `feature_library`）。
  final String id;

  /// 模块中文展示名称。
  final String displayName;

  /// 模块支持的运行平台集合。
  final Set<KonataPlatform> supportedPlatforms;

  /// 注册的顶层主导航分区列表。
  final List<NavSectionContribution> navSections;

  /// 注册的设置分区列表。
  final List<SettingsSectionContribution> settingsSections;

  /// 注册的作品详情页标签页列表。
  final List<DetailTabContribution> detailTabs;

  /// 注册的作品详情页动作列表。
  final List<DetailActionContribution> detailActions;

  /// 注册的播放器侧栏面板列表。
  final List<PlayerSidePanelContribution> playerSidePanels;

  /// 注册的外部数据/追番同步提供者列表。
  final List<DataProviderContribution> dataProviders;

  /// 注册的同步与备份切片贡献者列表。
  final List<SyncSliceContributor<Object?>> syncSlices;

  /// 可选只读云盘驱动贡献。
  final List<CloudDriveProviderContribution> cloudDriveProviders;

  /// 可选应用生命周期挂载，用宿主传入的根视图构造包装视图。
  final Object Function(Object child)? wrapRuntime;

  /// 判断模块是否在当前平台启用。
  bool isSupportedOn(KonataPlatform platform) =>
      supportedPlatforms.contains(platform);
}
