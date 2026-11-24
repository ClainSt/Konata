import '../value_objects/ids.dart';

/// 音频舞台向歌词模块传递的不可变曲目检索描述（严禁跨包传递重型数据库行或 UI 对象）。
final class LyricTrackQuery {
  /// 创建歌词检索曲目描述。
  const LyricTrackQuery({
    required this.trackKey,
    required this.title,
    this.workId,
    this.variantId,
    this.sourceId,
    this.artist = '',
    this.album = '',
    this.albumKey,
    this.fileName = '',
    this.relativePath = '',
    this.durationSeconds = 0.0,
    this.bangumiSubjectId,
    this.embeddedLrcText,
    this.cueTrackIndex,
  });

  /// 物理曲目稳定唯一键（用于缓存、手选歌词与偏移锁定）。
  final String trackKey;

  /// 曲目标题。
  final String title;

  /// 所属作品主键（可选）。
  final WorkId? workId;

  /// 物理变体主键（可选）。
  final VariantId? variantId;

  /// 所属媒体源主键（可选）。
  final SourceId? sourceId;

  /// 演唱者或艺术家名。
  final String artist;

  /// 所属专辑名称。
  final String album;

  /// 专辑规范键（用于专辑级偏移共享）。
  final String? albumKey;

  /// 音频文件名。
  final String fileName;

  /// 相对路径。
  final String relativePath;

  /// 曲目时长（秒）。
  final double durationSeconds;

  /// 关联 Bangumi 条目编号（可选，用于曲目信息增强）。
  final int? bangumiSubjectId;

  /// 文件或外挂侧车内嵌歌词原文（可选）。
  final String? embeddedLrcText;

  /// 分轨序号（可选）。
  final int? cueTrackIndex;
}

/// 跨 Feature 歌词协同抽象端口（由 `feature_lyrics` 实现，由宿主按需注入 `feature_player_audio`）。
///
/// 通过纯 Dart 端口彻底解耦音频舞台与歌词模块，确保删除 `feature_lyrics` 仍可零报错编译。
abstract interface class LyricDisplayPort {
  /// 为当前播放曲目触发歌词解析（优先本地覆盖/缓存，未命中则启动多源竞速）。
  Future<void> resolveForTrack(LyricTrackQuery query);

  /// 针对播放队列后续曲目执行分级后台预取。
  Future<void> prefetchQueue(List<LyricTrackQuery> upcoming);

  /// 清空当前活跃歌词会话状态。
  void clearActive();
}

/// 播控页面对宿主窗口、全屏、置顶与屏幕常亮的控制抽象端口。
///
/// 由 `apps/konata` 按平台注入（Windows 经 `window_manager`，Android 经系统栏与方向控制），
/// 业务 Feature 严禁直接导入任何桌面窗口原生插件。
abstract interface class PlaybackHostWindowPort {
  /// 查询当前是否处于全屏模式。
  Future<bool> isFullScreen();

  /// 切换全屏模式。
  Future<void> setFullScreen(bool enable);

  /// 切换窗口置顶状态（移动端忽略）。
  Future<void> setAlwaysOnTop(bool enable);

  /// 进入桌面置顶迷你窗口形态并指定目标尺寸（移动端忽略）。
  Future<void> enterDesktopMiniWindow({
    required double width,
    required double height,
  });

  /// 退出桌面置顶迷你窗口形态并恢复主窗口几何尺寸。
  Future<void> exitDesktopMiniWindow();

  /// 控制播放期间屏幕常亮开关。
  Future<void> setKeepScreenOn(bool enable);

  /// 切换移动端期望横屏或跟随系统方向（桌面端忽略）。
  Future<void> setPreferredLandscape(bool landscape);
}

/// 默认空宿主窗口控制端口（供测试与无窗口宿主环境兜底）。
final class NoopPlaybackHostWindowPort implements PlaybackHostWindowPort {
  /// 创建默认空窗口控制端口。
  const NoopPlaybackHostWindowPort();

  @override
  Future<bool> isFullScreen() async => false;

  @override
  Future<void> setFullScreen(bool enable) async {}

  @override
  Future<void> setAlwaysOnTop(bool enable) async {}

  @override
  Future<void> enterDesktopMiniWindow({
    required double width,
    required double height,
  }) async {}

  @override
  Future<void> exitDesktopMiniWindow() async {}

  @override
  Future<void> setKeepScreenOn(bool enable) async {}

  @override
  Future<void> setPreferredLandscape(bool landscape) async {}
}
