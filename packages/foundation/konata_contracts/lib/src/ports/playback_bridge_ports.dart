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

  /// 同步曲内播放时钟，独立于低频歌词解析与事件总线。
  void updatePlaybackPosition(Duration position, {bool? isPlaying});

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

/// 可选音频异形窗口能力，仅用于音频小窗，不改变视频窗口契约。
abstract interface class DesktopAudioMiniWindowPort {
  /// 桌面音频小窗失去焦点时通知展开胶囊收起。
  Stream<void> get desktopAudioMiniBlur;

  /// 按音频小窗视觉形态和外层预留边距调整真实窗口裁剪。
  Future<void> enterDesktopAudioMiniWindow({
    required double width,
    required double height,
  });
}

/// 桌面小窗所吸附的屏幕工作区水平边缘。
enum DesktopMiniDockSide { left, right }

/// 可选桌面吸附能力；未实现此端口的平台不参与系统窗口吸附。
abstract interface class DesktopMiniDockPort {
  /// 仅在系统完成窗口移动时通知，不转发高频坐标。
  Stream<void> get desktopMiniMoveEnded;

  /// 按真实窗口所在显示器工作区吸附；远离边缘时只修正越界，不收起。
  Future<DesktopMiniDockSide?> snapDesktopMiniWindow();
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

/// Android 原生音频焦点管理抽象端口（纯 Dart 契约，由宿主按平台注入）。
abstract interface class AndroidAudioFocusPort {
  /// 请求媒体播放音频焦点并绑定失去/闪避/恢复回调。
  Future<void> requestAudioFocus({
    void Function()? onLoss,
    void Function()? onDuck,
    void Function()? onGain,
  });

  /// 释放已持有的音频焦点并清理监听回调。
  Future<void> abandonAudioFocus();

  /// 销毁底层通道监听。
  void dispose();
}

/// 默认空 Android 音频焦点实现（桌面端与纯单元测试兜底）。
final class NoopAndroidAudioFocusPort implements AndroidAudioFocusPort {
  /// 创建空音频焦点适配器。
  const NoopAndroidAudioFocusPort();

  @override
  Future<void> requestAudioFocus({
    void Function()? onLoss,
    void Function()? onDuck,
    void Function()? onGain,
  }) async {}

  @override
  Future<void> abandonAudioFocus() async {}

  @override
  void dispose() {}
}

/// Android 原生画中画（PiP）状态快照载荷。
final class AndroidPipState {
  /// 创建画中画同步状态载荷。
  const AndroidPipState({
    required this.eligible,
    required this.isPlaying,
    required this.canPrevious,
    required this.canNext,
    this.aspectNumerator = 16,
    this.aspectDenominator = 9,
    this.sourceRect,
  });

  /// 当前是否允许切后台自动进入画中画。
  final bool eligible;

  /// 当前是否处于播放态。
  final bool isPlaying;

  /// 是否允许上一话操作。
  final bool canPrevious;

  /// 是否允许下一话操作。
  final bool canNext;

  /// 画中画宽高比分子。
  final int aspectNumerator;

  /// 画中画宽高比分母。
  final int aspectDenominator;

  /// 可选视频渲染视口物理边界。
  final ({int left, int top, int right, int bottom})? sourceRect;

  /// 序列化为平台通道参数字典。
  Map<String, Object?> toChannelMap() => <String, Object?>{
    'eligible': eligible,
    'isPlaying': isPlaying,
    'canPrevious': canPrevious,
    'canNext': canNext,
    'aspectNumerator': aspectNumerator,
    'aspectDenominator': aspectDenominator,
    if (sourceRect != null) ...<String, Object?>{
      'left': sourceRect!.left,
      'top': sourceRect!.top,
      'right': sourceRect!.right,
      'bottom': sourceRect!.bottom,
    },
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AndroidPipState &&
          other.eligible == eligible &&
          other.isPlaying == isPlaying &&
          other.canPrevious == canPrevious &&
          other.canNext == canNext &&
          other.aspectNumerator == aspectNumerator &&
          other.aspectDenominator == aspectDenominator &&
          other.sourceRect == sourceRect;

  @override
  int get hashCode => Object.hash(
    eligible,
    isPlaying,
    canPrevious,
    canNext,
    aspectNumerator,
    aspectDenominator,
    sourceRect,
  );
}

/// Android 原生画中画通道抽象端口（纯 Dart 契约，隔离平台通道实现）。
abstract interface class AndroidPipPort {
  /// 绑定原生画中画状态切换、远程操作按钮与用户滑走关闭回调。
  void bindCallbacks({
    required void Function(bool active) onPipModeChanged,
    required void Function(String action) onRemoteAction,
    void Function()? onPipDismissed,
  });

  /// 解绑通道监听。
  void unbindCallbacks();

  /// 向原生宿主同步当前画中画可用资格与远程按钮状态。
  Future<void> syncState(AndroidPipState state);

  /// 主动请求立即进入系统画中画。
  Future<bool> enterPipNow();
}

/// 默认空 Android 画中画实现（桌面端与无原生宿主测试兜底）。
final class NoopAndroidPipPort implements AndroidPipPort {
  /// 创建空画中画适配器。
  const NoopAndroidPipPort();

  @override
  void bindCallbacks({
    required void Function(bool active) onPipModeChanged,
    required void Function(String action) onRemoteAction,
    void Function()? onPipDismissed,
  }) {}

  @override
  void unbindCallbacks() {}

  @override
  Future<void> syncState(AndroidPipState state) async {}

  @override
  Future<bool> enterPipNow() async => false;
}
